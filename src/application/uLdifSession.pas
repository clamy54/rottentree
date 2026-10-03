// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdifSession;

{$mode objfpc}{$H+}

// Fichier LDIF ouvert comme un annuaire: lu une fois par le fil de travail, puis servi depuis un
// magasin en memoire, reecrit seulement a l'enregistrement par remplacement atomique. UTF-16
// (ldifde -u) converti; references externes file:// refusees, un LDIF n'a pas a aller fouiller le
// disque.

interface

uses
  SysUtils, Classes, uDirectorySession, uConnectionProfile, uLdapEntry, uSearchModel,
  uLdapErrors, uChangeSet, uCancel, uSessionModel, uLdifStore, uLdapSchema;

const
  // Texte et entrees analysees tiennent ensemble en memoire pendant la lecture: d'ou la borne.
  LDIF_OPEN_MAX_BYTES = Int64(1024) * 1024 * 1024;
  LDIF_OPEN_MAX_WARNINGS = 20;

resourcestring
  rsLdifReadOnly = 'this LDIF file is open read-only';
  rsLdifNotSupported = 'not available for an LDIF file';
  rsLdifStatus = 'LDIF file';
  rsLdifSummary = '%d entries read from %s';
  rsLdifSummaryGlue = '%d entries read from %s; %d missing levels shown as placeholders';
  rsLdifMoreIssues = '... and %d more';
  rsLdifNoEntry = 'no entry could be read from this file';
  rsLdifTooLarge = 'the file is too large to open (%d MiB, limit %d MiB)';
  rsLdifMissing = 'the file does not exist';
  rsLdifNotOpened = '%d records that were not opened';
  rsLdifComments = 'its comments';

type
  TLdifSession = class(TDirectorySession)
  private
    FStore: TLdifStore;
    FEol: RawByteString;
    FHadComments: Boolean;
    function ReadOnlyResult(const AStep: string): TWriteResult;
    function WriteGuard(const AStep: string; out AResult: TWriteResult): Boolean;
    function Applied(const AError: TLdapError): TWriteResult;
    procedure FillFile(ADest: TStream);
  public
    destructor Destroy; override;
    function Connect(const ASecret: RawByteString; ACancel: TCancelToken): Boolean; override;
    procedure Close; override;
    function Search(const AReq: TSearchRequest; AOnEntry: TSearchEntryEvent;
      ACancel: TCancelToken; out ACompletion: TSearchCompletion;
      AAssembleRanges: Boolean = False): Boolean; override;
    function ReadEntry(const ADn: string; const AAttrs: array of string;
      ACancel: TCancelToken; AAssembleRanges: Boolean = True): TLdapEntry; overload; override;
    function ReadEntry(const ADn: string; const AAttrs: array of string;
      const AControls: TRequestControlArray; ACancel: TCancelToken): TLdapEntry; overload; override;
    function ReadRootDse(ACancel: TCancelToken): TLdapEntry; override;
    function WhoAmI(ACancel: TCancelToken; out AAuthzId: string): Boolean; override;
    function Modify(const ADn: string; const AMods: TLdapModArray;
      const AAssertionFilter: string; ACancel: TCancelToken): TWriteResult; overload; override;
    function Modify(const ADn: string; const AMods: TLdapModArray;
      const AAssertionFilter: string; const AControls: TRequestControlArray;
      ACancel: TCancelToken): TWriteResult; overload; override;
    function Add(AEntry: TLdapEntry; ACancel: TCancelToken): TWriteResult; override;
    function Delete(const ADn: string; const AAssertionFilter: string;
      ACancel: TCancelToken): TWriteResult; override;
    function Rename(const ADn, ANewRdn, ANewSuperior: string; AHasNewSuperior,
      ADeleteOldRdn: Boolean; ACancel: TCancelToken): TWriteResult; override;
    function PasswordModify(const AUserDn: string; const AOld, ANew: RawByteString;
      AHasOld, AHasNew: Boolean; ACancel: TCancelToken): TWriteResult; override;
    function Compare(const ADn, AAttr: string; const AValue: RawByteString;
      ACancel: TCancelToken; out AMatch: Boolean): Boolean; override;
    function IsConnected: Boolean; override;
    function SaveTo(const APath: string): Boolean;
    procedure UseSchema(ASchema: TSchemaSnapshot);
    property Store: TLdifStore read FStore;
    property HadComments: Boolean read FHadComments;
  end;

function LdifTextToUtf8(const ARaw: RawByteString): RawByteString;

implementation

uses
  uLdif, uSafeSave, bufstream, uSchemaReader;

procedure ScanLayout(const AText: RawByteString; out AEol: RawByteString; out AComments: Boolean);
var
  i, n: Integer;
begin
  AEol := #10;
  AComments := False;
  n := Length(AText);
  i := Pos(#10, AText);
  if (i > 1) and (AText[i - 1] = #13) then AEol := #13#10;
  if (n > 0) and (AText[1] = '#') then AComments := True;
  i := 1;
  while (not AComments) and (i < n) do
  begin
    if (AText[i] = #10) and (AText[i + 1] = '#') then AComments := True;
    Inc(i);
  end;
end;

function LdifTextToUtf8(const ARaw: RawByteString): RawByteString;
var
  w: UnicodeString;
  n, i: Integer;
  bigEndian: Boolean;
  b: Byte;
begin
  Result := ARaw;
  if Length(ARaw) < 2 then Exit;
  if (ARaw[1] = #$FF) and (ARaw[2] = #$FE) then bigEndian := False
  else if (ARaw[1] = #$FE) and (ARaw[2] = #$FF) then bigEndian := True
  else Exit;
  n := (Length(ARaw) - 2) div 2;
  SetLength(w, n);
  if n > 0 then
    Move(ARaw[3], w[1], n * 2);
  if bigEndian then
    for i := 1 to n do
    begin
      b := Byte(Ord(w[i]) shr 8);
      w[i] := WideChar((Ord(w[i]) shl 8) and $FF00 or b);
    end;
  Result := UTF8Encode(w);
end;

destructor TLdifSession.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TLdifSession.ReadOnlyResult(const AStep: string): TWriteResult;
begin
  Result := Default(TWriteResult);
  Result.Error := MakeError(lecReadOnly, 0, AStep, rsLdifReadOnly);
end;

function TLdifSession.WriteGuard(const AStep: string; out AResult: TWriteResult): Boolean;
begin
  Result := False;
  AResult := Default(TWriteResult);
  if FProfile.ReadOnly then
  begin
    AResult := ReadOnlyResult(AStep);
    Exit;
  end;
  if not IsConnected then
  begin
    AResult.Error := MakeError(lecNetwork, LDAP_RC_SERVER_DOWN, AStep, 'not open');
    Exit;
  end;
  Result := True;
end;

function TLdifSession.Applied(const AError: TLdapError): TWriteResult;
begin
  Result := Default(TWriteResult);
  // En memoire, l'issue est toujours connue: rien n'est jamais emis sans reponse.
  Result.Sent := True;
  Result.Error := AError;
  Result.Ok := AError.Category = lecNone;
  FLastError := AError;
end;

function TLdifSession.Connect(const ASecret: RawByteString; ACancel: TCancelToken): Boolean;
var
  fs: TFileStream;
  raw: RawByteString;
  doc: TLdifDocument;
  size: Int64;
  i, shown: Integer;
  reason: string;
begin
  Result := False;
  FLastError := NoError;
  FConnectSummary := '';
  FConnectWarnings := nil;
  FConnectRewriteNote := '';
  FreeAndNil(FStore);
  FState := csConnecting;
  try
    if not FileExists(FProfile.LdifPath) then
    begin
      FLastError := MakeError(lecConfiguration, 0, 'open', rsLdifMissing);
      FState := csFailed;
      Exit;
    end;
    fs := TFileStream.Create(FProfile.LdifPath, fmOpenRead or fmShareDenyWrite);
    try
      size := fs.Size;
      if size > LDIF_OPEN_MAX_BYTES then
      begin
        FLastError := MakeError(lecConfiguration, 0, 'open', Format(rsLdifTooLarge,
          [size div (1024 * 1024), LDIF_OPEN_MAX_BYTES div (1024 * 1024)]));
        FState := csFailed;
        Exit;
      end;
      raw := '';
      SetLength(raw, size);
      if size > 0 then
        fs.ReadBuffer(raw[1], size);
    finally
      fs.Free;
    end;
    if (ACancel <> nil) and ACancel.IsCancelled then
    begin
      FLastError := MakeError(lecCancelled, 0, 'open', 'cancelled');
      FState := csCancelled;
      Exit;
    end;
    raw := LdifTextToUtf8(raw);
    ScanLayout(raw, FEol, FHadComments);
    doc := LdifParse(raw, DefaultLdifParseOptions);
    try
      raw := '';
      FStore := TLdifStore.Create;
      FStore.Load(doc);
    finally
      doc.Free;
    end;
  except
    on E: EStreamError do
    begin
      FreeAndNil(FStore);
      FLastError := MakeError(lecConfiguration, 0, 'open', E.Message);
      FState := csFailed;
      Exit;
    end;
  end;
  if FStore.EntryCount = 0 then
  begin
    if FStore.Issues.Count > 0 then
      FLastError := MakeError(lecConfiguration, 0, 'open', rsLdifNoEntry + ': ' + FStore.Issues[0])
    else
      FLastError := MakeError(lecConfiguration, 0, 'open', rsLdifNoEntry);
    FreeAndNil(FStore);
    FState := csFailed;
    Exit;
  end;
  if FStore.GlueCount > 0 then
    FConnectSummary := Format(rsLdifSummaryGlue, [FStore.EntryCount,
      ExtractFileName(FProfile.LdifPath), FStore.GlueCount])
  else
    FConnectSummary := Format(rsLdifSummary, [FStore.EntryCount,
      ExtractFileName(FProfile.LdifPath)]);
  shown := FStore.Issues.Count;
  if shown > LDIF_OPEN_MAX_WARNINGS then shown := LDIF_OPEN_MAX_WARNINGS;
  SetLength(FConnectWarnings, shown);
  for i := 0 to shown - 1 do
    FConnectWarnings[i] := FStore.Issues[i];
  if FStore.IssueCount > shown then
  begin
    SetLength(FConnectWarnings, shown + 1);
    FConnectWarnings[shown] := Format(rsLdifMoreIssues, [FStore.IssueCount - shown]);
  end;
  if FStore.IssueCount > 0 then
    FConnectRewriteNote := Format(rsLdifNotOpened, [FStore.IssueCount]);
  if FHadComments then
  begin
    if FConnectRewriteNote <> '' then FConnectRewriteNote := FConnectRewriteNote + ', ';
    FConnectRewriteNote := FConnectRewriteNote + rsLdifComments;
  end;
  FTransport := Default(TTransportInfo);
  FTransport.Mode := FProfile.Transport;
  FTransport.StatusLabel := rsLdifStatus;
  FState := csReady;
  Result := True;
  if FStore.SubschemaDn <> '' then
    UseSchema(ReadSchema(Self, FStore.SubschemaDn, ACancel, reason));
end;

procedure TLdifSession.UseSchema(ASchema: TSchemaSnapshot);
begin
  if FStore = nil then
  begin
    ASchema.Free;
    Exit;
  end;
  if ASchema <> nil then FSensitive.LearnSchema(ASchema);
  FStore.SetSchema(ASchema);
end;

procedure TLdifSession.FillFile(ADest: TStream);
var
  buf: TWriteBufStream;
begin
  buf := TWriteBufStream.Create(ADest, 1024 * 1024);
  try
    FStore.WriteTo(buf, FStore.AddRecords, FEol);
  finally
    // Vidage du tampon dans le fichier temporaire: une erreur ici abandonne l'ecriture, le fichier
    // precedent reste en place.
    buf.Free;
  end;
end;

function TLdifSession.SaveTo(const APath: string): Boolean;
begin
  Result := False;
  if not IsConnected then
  begin
    FLastError := MakeError(lecNetwork, LDAP_RC_SERVER_DOWN, 'save', 'not open');
    Exit;
  end;
  try
    SavePrivateFill(APath, @FillFile);
  except
    on E: Exception do
    begin
      FLastError := MakeError(lecOther, 0, 'save', E.Message);
      Exit;
    end;
  end;
  FProfile.LdifPath := APath;
  FProfile.Name := ExtractFileName(APath);
  FConnectRewriteNote := '';
  FHadComments := False;
  FLastError := NoError;
  Result := True;
end;

procedure TLdifSession.Close;
begin
  FreeAndNil(FStore);
  if FState in [csReady, csClosing] then FState := csDisconnected;
end;

function TLdifSession.IsConnected: Boolean;
begin
  Result := (FStore <> nil) and (FState = csReady);
end;

function TLdifSession.Search(const AReq: TSearchRequest; AOnEntry: TSearchEntryEvent;
  ACancel: TCancelToken; out ACompletion: TSearchCompletion; AAssembleRanges: Boolean): Boolean;
begin
  if not IsConnected then
  begin
    ACompletion := Default(TSearchCompletion);
    ACompletion.HasResult := True;
    ACompletion.ResultCode := LDAP_RC_SERVER_DOWN;
    FLastError := MakeError(lecNetwork, LDAP_RC_SERVER_DOWN, 'search', 'not open');
    Exit(False);
  end;
  Result := FStore.Search(AReq, AOnEntry, ACancel, FSensitive, ACompletion, FLastError);
end;

function TLdifSession.ReadEntry(const ADn: string; const AAttrs: array of string;
  ACancel: TCancelToken; AAssembleRanges: Boolean): TLdapEntry;
var
  node: TLdifNode;
  i: Integer;
  attrs: array of string;
begin
  Result := nil;
  if not IsConnected then
  begin
    FLastError := MakeError(lecNetwork, LDAP_RC_SERVER_DOWN, 'read', 'not open');
    Exit;
  end;
  FLastError := NoError;
  if ADn = '' then
    Exit(FStore.RootDse);
  node := FStore.FindNode(ADn);
  if (node = nil) or node.Glue then
  begin
    if node <> nil then
      FLastError := MakeError(lecNoSuchObject, LDAP_RC_NO_SUCH_OBJECT, 'read', rsLdifGlueNotInFile)
    else
      FLastError := MakeError(lecNoSuchObject, LDAP_RC_NO_SUCH_OBJECT, 'read', 'entry not returned');
    Exit;
  end;
  attrs := nil;
  SetLength(attrs, Length(AAttrs));
  for i := 0 to High(AAttrs) do attrs[i] := AAttrs[i];
  Result := FStore.SelectAttributes(node, attrs, False, FSensitive);
end;

function TLdifSession.ReadEntry(const ADn: string; const AAttrs: array of string;
  const AControls: TRequestControlArray; ACancel: TCancelToken): TLdapEntry;
begin
  Result := ReadEntry(ADn, AAttrs, ACancel, False);
end;

function TLdifSession.ReadRootDse(ACancel: TCancelToken): TLdapEntry;
begin
  Result := nil;
  if FStore <> nil then Result := FStore.RootDse;
end;

function TLdifSession.WhoAmI(ACancel: TCancelToken; out AAuthzId: string): Boolean;
begin
  AAuthzId := '';
  FLastError := MakeError(lecProtocol, LDAP_RC_NOT_SUPPORTED, 'who am I', rsLdifNotSupported);
  Result := False;
end;

function TLdifSession.Modify(const ADn: string; const AMods: TLdapModArray;
  const AAssertionFilter: string; ACancel: TCancelToken): TWriteResult;
begin
  if WriteGuard('modify', Result) then
    Result := Applied(FStore.Modify(ADn, AMods, AAssertionFilter));
end;

function TLdifSession.Modify(const ADn: string; const AMods: TLdapModArray;
  const AAssertionFilter: string; const AControls: TRequestControlArray;
  ACancel: TCancelToken): TWriteResult;
begin
  Result := Modify(ADn, AMods, AAssertionFilter, ACancel);
end;

function TLdifSession.Add(AEntry: TLdapEntry; ACancel: TCancelToken): TWriteResult;
begin
  if WriteGuard('add', Result) then
    Result := Applied(FStore.Add(AEntry));
end;

function TLdifSession.Delete(const ADn: string; const AAssertionFilter: string;
  ACancel: TCancelToken): TWriteResult;
begin
  if WriteGuard('delete', Result) then
    Result := Applied(FStore.Delete(ADn, AAssertionFilter));
end;

function TLdifSession.Rename(const ADn, ANewRdn, ANewSuperior: string; AHasNewSuperior,
  ADeleteOldRdn: Boolean; ACancel: TCancelToken): TWriteResult;
begin
  if WriteGuard('moddn', Result) then
    Result := Applied(FStore.Rename(ADn, ANewRdn, ANewSuperior, AHasNewSuperior, ADeleteOldRdn));
end;

function TLdifSession.PasswordModify(const AUserDn: string; const AOld, ANew: RawByteString;
  AHasOld, AHasNew: Boolean; ACancel: TCancelToken): TWriteResult;
begin
  // Password Modify (RFC 3062): le serveur hache selon sa politique. Un fichier n'a pas de
  // politique, donc pas d'operation: la valeur hachee s'ecrit telle quelle.
  Result := Default(TWriteResult);
  Result.Error := MakeError(lecProtocol, LDAP_RC_NOT_SUPPORTED, 'password modify', rsLdifNotSupported);
end;

function TLdifSession.Compare(const ADn, AAttr: string; const AValue: RawByteString;
  ACancel: TCancelToken; out AMatch: Boolean): Boolean;
begin
  AMatch := False;
  if not IsConnected then
  begin
    FLastError := MakeError(lecNetwork, LDAP_RC_SERVER_DOWN, 'compare', 'not open');
    Exit(False);
  end;
  FLastError := FStore.Compare(ADn, AAttr, AValue, AMatch);
  Result := FLastError.Category = lecNone;
end;

end.
