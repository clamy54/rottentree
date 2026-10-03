// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdifExport;

{$mode objfpc}{$H+}

// Export LDIF d'une entree ou d'un sous-arbre, pret a reimporter: parents avant enfants,
// la recherche ne garantissant aucun ordre. Budget total en entrees et en octets:
// au-dela, l'export est refuse plutot que de manger toute la memoire de la machine.

interface

uses
  Classes, SysUtils, uLdapEntry, uLdapSchema, uCancel;

const
  EXPORT_MAX_ENTRIES = 200000;
  EXPORT_MAX_BYTES = Int64(512) * 1024 * 1024;

type
  TLdifExportCollector = class
  private
    FSchema: TSchemaSnapshot;
    FExclude: Boolean;
    FTexts: TStringList;
    FDepths: array of Integer;
    FStripped: TStringList;
    FBytes: Int64;
    FMaxEntries: Integer;
    FOverBudget: Boolean;
  public
    // ASchema n'est pas possede: un schema relu libere l'ancien, l'appelant le revalide
    // avant chaque Add.
    constructor Create(ASchema: TSchemaSnapshot; AExcludeServerManaged: Boolean);
    destructor Destroy; override;
    function Add(AEntry: TLdapEntry): Boolean;
    function Count: Integer;
    property Bytes: Int64 read FBytes;
    property MaxEntries: Integer read FMaxEntries write FMaxEntries;
    property OverBudget: Boolean read FOverBudget;
    function StrippedNames: string;
    // Une annulation leve EAbort entre deux entrees et l'appelant jette le fichier en
    // cours. Un LDIF a moitie ecrit, c'est une restauration a moitie faite.
    procedure WriteTo(AStream: TStream; const AHeader: array of string;
      ACancel: TCancelToken = nil);
  end;

function DnDepth(const ADn: string): Integer;

implementation

uses
  uLdapDn, uLdif, uLdifTargetCheck;

function DnDepth(const ADn: string): Integer;
var
  dn: TLdapDn;
begin
  if DnTryParse(ADn, dn) then
    Result := DnRdnCount(dn)
  else
    Result := MaxInt;
end;

constructor TLdifExportCollector.Create(ASchema: TSchemaSnapshot; AExcludeServerManaged: Boolean);
begin
  inherited Create;
  FSchema := ASchema;
  FExclude := AExcludeServerManaged;
  FTexts := TStringList.Create;
  FStripped := TStringList.Create;
  FStripped.CaseSensitive := False;
  FMaxEntries := EXPORT_MAX_ENTRIES;
end;

destructor TLdifExportCollector.Destroy;
begin
  FTexts.Free;
  FStripped.Free;
  inherited Destroy;
end;

function TLdifExportCollector.Add(AEntry: TLdapEntry): Boolean;
var
  e: TLdapEntry;
  removed: TStringArray;
  i: Integer;
  txt: RawByteString;
begin
  Result := False;
  if FOverBudget or (FTexts.Count >= FMaxEntries) then
  begin
    FOverBudget := True;
    Exit;
  end;
  e := AEntry.Clone;
  try
    if FExclude then
    begin
      removed := StripServerManaged(e, FSchema);
      for i := 0 to High(removed) do
        if FStripped.IndexOf(AttrBaseName(removed[i])) < 0 then
          FStripped.Add(AttrBaseName(removed[i]));
    end;
    e.SortForDisplay;
    txt := LdifEntryToString(e);
    if FBytes + Length(txt) > EXPORT_MAX_BYTES then
    begin
      FOverBudget := True;
      Exit;
    end;
    Inc(FBytes, Length(txt));
    FTexts.Add(string(txt));
    SetLength(FDepths, Length(FDepths) + 1);
    FDepths[High(FDepths)] := DnDepth(e.Dn);
    Result := True;
  finally
    e.Free;
  end;
end;

function TLdifExportCollector.Count: Integer;
begin
  Result := FTexts.Count;
end;

function TLdifExportCollector.StrippedNames: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to FStripped.Count - 1 do
  begin
    if i > 0 then Result := Result + ', ';
    Result := Result + FStripped[i];
  end;
end;

procedure TLdifExportCollector.WriteTo(AStream: TStream; const AHeader: array of string;
  ACancel: TCancelToken);
var
  w: TLdifWriter;
  i, d, minD, maxD: Integer;
  s: RawByteString;

  procedure CheckCancel;
  begin
    if (ACancel <> nil) and ACancel.IsCancelled then Abort;
  end;

begin
  w := TLdifWriter.Create(AStream);
  try
    w.WriteVersion;
    for i := 0 to High(AHeader) do
      w.WriteComment(AHeader[i]);
    w.WriteSeparator;
  finally
    w.Free;
  end;
  if FTexts.Count = 0 then Exit;
  minD := MaxInt;
  maxD := 0;
  for i := 0 to High(FDepths) do
  begin
    if FDepths[i] < minD then minD := FDepths[i];
    if (FDepths[i] > maxD) and (FDepths[i] <> MaxInt) then maxD := FDepths[i];
  end;
  for d := minD to maxD do
    for i := 0 to FTexts.Count - 1 do
      if FDepths[i] = d then
      begin
        CheckCancel;
        s := RawByteString(FTexts[i]);
        if s <> '' then AStream.WriteBuffer(s[1], Length(s));
      end;
  for i := 0 to FTexts.Count - 1 do
    if FDepths[i] = MaxInt then
    begin
      CheckCancel;
      s := RawByteString(FTexts[i]);
      if s <> '' then AStream.WriteBuffer(s[1], Length(s));
    end;
end;

end.
