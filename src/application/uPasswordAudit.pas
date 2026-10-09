// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPasswordAudit;

{$mode objfpc}{$H+}

// Audit du stockage des mots de passe: qui garde un userPassword recuperable, ou casse en un
// week-end. Chaque valeur est classee a l'arrivee puis jetee: garder en memoire toutes les
// empreintes d'un annuaire, c'est emballer le cadeau du prochain dump. Les comptes sont
// cherches par leurs classes, pas par la presence de userPassword: un attribut illisible ne
// se filtre pas, et zero resultat passerait pour un annuaire irreprochable.

interface

uses
  Classes, SysUtils, uLdapEntry, uLdapSchema, uSearchModel, uPwdCore, uDirectoryWorker,
  uDirectoryScan;

const
  // Au-dela on compte encore, on ne liste plus: personne ne corrigera tout ca a la main.
  PWD_AUDIT_KEEP_MAX = 200000;

type
  TPwdAuditRow = record
    Dn, Name, GivenName, Mail, Format: string;
    Level: TPwdStorageLevel;
  end;
  TPwdAuditRows = array of TPwdAuditRow;

  TPwdAuditFormat = record
    Name: string;
    Level: TPwdStorageLevel;
    Count: Int64;
  end;
  TPwdAuditFormats = array of TPwdAuditFormat;

  TPwdAuditTotals = record
    Accounts: Int64;
    Readable: Int64;
    Dropped: Int64;
    ByLevel: array[TPwdStorageLevel] of Int64;
  end;

  // TEntriesMsg pour Final, Completion et Error: le suivi des taches ne solde une recherche
  // qu'a son lot final. Entries reste vide. Totals et Formats sont cumules, Rows ne l'est pas.
  TPwdAuditMsg = class(TEntriesMsg)
  public
    Rows: TPwdAuditRows;
    Totals: TPwdAuditTotals;
    Formats: TPwdAuditFormats;
  end;

  TPasswordAuditCmd = class(TDirectoryScanCmd)
  private
    FRows: TPwdAuditRows;
    FRowCount: Integer;
    FCost: Int64;
    FKept: Int64;
    FSinceFlush: Integer;
    FTotals: TPwdAuditTotals;
    FFormats: TPwdAuditFormats;
    procedure OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
    procedure CountFormat(const AName: string; ALevel: TPwdStorageLevel);
    procedure Flush(AFinal: Boolean; const ACompletion: TSearchCompletion);
  public
    Filter: string;
    procedure Execute(AWorker: TDirectoryWorker); override;
  end;

  // Comptes exportes et empreintes ecrites. Entries reste vide: rien ne remonte en memoire.
  TPwdCrackMsg = class(TEntriesMsg)
  public
    Accounts: Int64;
    Written: Int64;
  end;

  // Un type de hash = un bloc du fichier. Chaque groupe accumule dans son propre temporaire
  // prive pendant la relecture; rien ne reste en memoire.
  TCrackGroup = record
    Key: string;
    Order: Integer;
    Header: string;
    Stream: TStream;
  end;

  // Relit userPassword et ecrit "identite:valeur" regroupe par type de hash dans un fichier
  // prive. Aucune empreinte n'est gardee: elles passent de l'annuaire aux temporaires puis au
  // fichier final, sans escale en memoire.
  TPwdCrackExportCmd = class(TDirectoryScanCmd)
  private
    FGroups: array of TCrackGroup;
    FWritten: Int64;
    FAccounts: Int64;
    FSinceFlush: Integer;
    FCompletion: TSearchCompletion;
    function GroupStream(const AKey: string; AOrder: Integer; const AHeader: string): TStream;
    procedure OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
    procedure FillFromScan(ADest: TStream);
    procedure PostProgress(AFinal: Boolean);
  public
    Filter: string;
    FilePath: string;
    procedure Execute(AWorker: TDirectoryWorker); override;
  end;

function PwdAuditListed(ALevel: TPwdStorageLevel): Boolean;
// Un format non juge passe avant un format correct: le doute ne profite pas a l'accuse.
function PwdAuditRank(ALevel: TPwdStorageLevel): Integer;
// Faux si aucune valeur n'a ete lue: absente ou illisible, d'ici on ne saura jamais.
function ClassifyPasswords(AAttr: TLdapAttribute; out ALevel: TPwdStorageLevel;
  out AWorst, AOthers: string): Boolean;
function PwdAuditFilter(ASchema: TSchemaSnapshot): string;
// Une valeur hachee qu'un outil de crack peut ingerer: ni clair, ni delegue (SASL), ni
// prefixe inconnu.
function PwdCrackable(const AValue: RawByteString): Boolean;

implementation

uses
  uPasswordSchemes, uUiInbox, uSafeSave, uLdapDn;

const
  AUDIT_ATTRS: array[0..5] of string = ('userPassword', 'cn', 'sn', 'givenName', 'mail', 'uid');
  CRACK_ATTRS: array[0..1] of string = ('userPassword', 'uid');
  FLUSH_ROWS = 200;
  FLUSH_ENTRIES = 1000;
  QUEUE_MAX_BYTES = 16 * 1024 * 1024;

function PwdAuditListed(ALevel: TPwdStorageLevel): Boolean;
begin
  Result := ALevel in [pslBroken, pslWeak, pslUnknown];
end;

function PwdAuditRank(ALevel: TPwdStorageLevel): Integer;
begin
  case ALevel of
    pslBroken: Result := 0;
    pslWeak: Result := 1;
    pslUnknown: Result := 2;
    pslFair: Result := 3;
    pslStrong: Result := 4;
  else
    Result := 5;
  end;
end;

function ClassifyPasswords(AAttr: TLdapAttribute; out ALevel: TPwdStorageLevel;
  out AWorst, AOthers: string): Boolean;
var
  i, worst: Integer;
  names: array of string;
  info: TPwdInfo;
  lvl: TPwdStorageLevel;
begin
  ALevel := pslUnknown;
  AWorst := '';
  AOthers := '';
  if (AAttr = nil) or (AAttr.ValueCount = 0) then Exit(False);
  names := nil;
  SetLength(names, AAttr.ValueCount);
  worst := -1;
  for i := 0 to AAttr.ValueCount - 1 do
  begin
    info := PasswordRegistry.Inspect(AAttr.Values[i]);
    names[i] := info.DisplayName;
    lvl := info.Storage;
    // Prefixe solide, contenu invalide: le niveau de la famille ne couvre pas les debris.
    // Non juge, et dit tel quel; un format inconnu reste juste inconnu.
    if not info.Valid then
    begin
      names[i] := names[i] + ' (malformed)';
      lvl := pslUnknown;
    end;
    if (worst < 0) or (PwdAuditRank(lvl) < PwdAuditRank(ALevel)) then
    begin
      worst := i;
      ALevel := lvl;
    end;
  end;
  AWorst := names[worst];
  // Le serveur accepte n'importe laquelle: une seule valeur pourrie suffit a ouvrir la porte.
  for i := 0 to High(names) do
    if (names[i] <> AWorst) and (Pos(names[i], AOthers) = 0) then
    begin
      if AOthers <> '' then AOthers := AOthers + ', ';
      AOthers := AOthers + names[i];
    end;
  Result := True;
end;

function PwdAuditFilter(ASchema: TSchemaSnapshot): string;
begin
  // Rattrape les comptes d'une autre classe quand l'attribut est lisible.
  Result := '(|' + AccountClassTerms(ASchema) + '(userPassword=*))';
end;

procedure TPasswordAuditCmd.CountFormat(const AName: string; ALevel: TPwdStorageLevel);
var
  i: Integer;
begin
  for i := 0 to High(FFormats) do
    if FFormats[i].Name = AName then
    begin
      Inc(FFormats[i].Count);
      Exit;
    end;
  SetLength(FFormats, Length(FFormats) + 1);
  FFormats[High(FFormats)].Name := AName;
  FFormats[High(FFormats)].Level := ALevel;
  FFormats[High(FFormats)].Count := 1;
end;

procedure TPasswordAuditCmd.OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
var
  level: TPwdStorageLevel;
  fmt, others: string;
  r: ^TPwdAuditRow;
begin
  try
    Inc(FTotals.Accounts);
    if ClassifyPasswords(AEntry.Find('userPassword'), level, fmt, others) then
    begin
      Inc(FTotals.Readable);
      Inc(FTotals.ByLevel[level]);
      CountFormat(fmt, level);
      if PwdAuditListed(level) then
        if FKept >= PWD_AUDIT_KEEP_MAX then
          Inc(FTotals.Dropped)
        else
        begin
          if FRowCount = Length(FRows) then SetLength(FRows, FRowCount + FLUSH_ROWS);
          r := @FRows[FRowCount];
          r^.Dn := AEntry.Dn;
          r^.Name := ScanText(AEntry.FirstValue('sn'));
          if r^.Name = '' then r^.Name := ScanText(AEntry.FirstValue('cn'));
          if r^.Name = '' then r^.Name := ScanText(AEntry.FirstValue('uid'));
          r^.GivenName := ScanText(AEntry.FirstValue('givenName'));
          r^.Mail := ScanText(AEntry.FirstValue('mail'));
          r^.Format := fmt;
          if others <> '' then r^.Format := fmt + ' (+ ' + others + ')';
          r^.Level := level;
          Inc(FRowCount);
          Inc(FKept);
          Inc(FCost, Length(r^.Dn) + Length(r^.Name) + Length(r^.GivenName) + Length(r^.Mail) +
            Length(r^.Format) + SizeOf(TPwdAuditRow));
        end;
    end;
  finally
    AEntry.Free;
  end;
  Inc(FSinceFlush);
  if (FRowCount >= FLUSH_ROWS) or (FSinceFlush >= FLUSH_ENTRIES) then
    Flush(False, Default(TSearchCompletion));
end;

procedure TPasswordAuditCmd.Flush(AFinal: Boolean; const ACompletion: TSearchCompletion);
var
  m: TPwdAuditMsg;
begin
  m := TPwdAuditMsg.Create;
  FWorker.Stamp(m, Self);
  m.Rows := Copy(FRows, 0, FRowCount);
  m.Totals := FTotals;
  m.Formats := Copy(FFormats, 0, Length(FFormats));
  m.Final := AFinal;
  m.Cost := FCost;
  if AFinal then
  begin
    m.Completion := ACompletion;
    m.Error := FWorker.Session.LastError;
  end
  else
    // Une interface occupee ne laisse pas la file grossir: le fil attend. Le lot final, jamais.
    UiInbox.WaitForRoom(Owner, FCost, QUEUE_MAX_BYTES, Cancel);
  UiInbox.Post(m);
  FRows := nil;
  FRowCount := 0;
  FCost := 0;
  FSinceFlush := 0;
end;

procedure TPasswordAuditCmd.Execute(AWorker: TDirectoryWorker);
begin
  FWorker := AWorker;
  Flush(True, ScanAll(Filter, AUDIT_ATTRS, @OnEntry));
end;

function PwdCrackable(const AValue: RawByteString): Boolean;
var
  info: TPwdInfo;
begin
  info := PasswordRegistry.Inspect(AValue);
  Result := info.Valid and (info.Recommendation in [prPreferred, prAcceptable, prLegacy]);
end;

// uid d'abord, sinon la valeur du RDN, sinon le DN. Le deux-points separe l'identite de la
// valeur: on le remplace, comme tout caractere de controle, pour ne pas casser la ligne.
function CrackIdentity(AEntry: TLdapEntry): string;
var
  dn: TLdapDn;
  i: Integer;
begin
  Result := ScanText(AEntry.FirstValue('uid'));
  if (Result = '') and DnTryParse(AEntry.Dn, dn) and (Length(dn.Rdns) > 0) and
     (Length(dn.Rdns[0].Avas) > 0) then
    Result := ScanText(dn.Rdns[0].Avas[0].Value);
  if Result = '' then Result := AEntry.Dn;
  for i := 1 to Length(Result) do
    if (Result[i] = ':') or (Result[i] < ' ') then Result[i] := '_';
end;

// En-tete d'un bloc: le type lisible et le mode hashcat; john detecte seul le format a partir
// de la ligne. Le mode hashcat est l'information qui ne se devine pas.
function CrackHeader(const ATitle, ATools: string): string;
begin
  Result := '# ' + ATitle + #10 + '# ' + ATools + #10;
end;

// Classe une valeur hachee: groupe, ordre d'affichage, en-tete, et la forme a ecrire. Pour
// hashcat le prefixe {CRYPT}/{ARGON2} doit sauter, alors que {SSHA}/{SHA} doit rester.
function CrackClassify(const AValue: RawByteString; out AKey: string; out AOrder: Integer;
  out AHeader: string; out ALine: RawByteString): Boolean;
var
  p: Integer;
  scheme, rest, pre3: string;

  procedure Grp(AOrd: Integer; const AKeyS, ATitle, ATools: string; AStrip: Boolean);
  begin
    AOrder := AOrd;
    AKey := AKeyS;
    AHeader := CrackHeader(ATitle, ATools);
    if AStrip then ALine := rest else ALine := AValue;
  end;

begin
  Result := False;
  AKey := '';
  AOrder := 99;
  AHeader := '';
  ALine := '';
  if not PwdCrackable(AValue) then Exit;
  scheme := '';
  rest := AValue;
  if (Length(AValue) >= 3) and (AValue[1] = '{') then
  begin
    p := Pos('}', AValue);
    if p > 2 then
    begin
      scheme := UpperCase(Copy(AValue, 2, p - 2));
      rest := Copy(AValue, p + 1, MaxInt);
    end;
  end;
  pre3 := Copy(rest, 1, 3);

  if scheme = 'CRYPT' then
  begin
    if pre3 = '$6$' then
      Grp(10, 'crypt-sha512', '{CRYPT} SHA-512-crypt ($6$)',
        'hashcat -m 1800   john: detection auto', True)
    else if pre3 = '$5$' then
      Grp(11, 'crypt-sha256', '{CRYPT} SHA-256-crypt ($5$)',
        'hashcat -m 7400   john: detection auto', True)
    else if (pre3 = '$2a') or (pre3 = '$2b') or (pre3 = '$2y') or (pre3 = '$2x') then
      Grp(12, 'crypt-bcrypt', '{CRYPT} bcrypt ($2)',
        'hashcat -m 3200   john: detection auto', True)
    else if pre3 = '$1$' then
      Grp(13, 'crypt-md5', '{CRYPT} MD5-crypt ($1$)',
        'hashcat -m 500   john: detection auto', True)
    else if Length(rest) = 13 then
      Grp(14, 'crypt-des', '{CRYPT} DES (traditionnel)',
        'hashcat -m 1500   john: detection auto', True)
    else if (Length(rest) > 0) and (rest[1] = '_') then
      Grp(15, 'crypt-bsdi', '{CRYPT} BSDi extended DES',
        'john: detection auto   hashcat: non pris en charge', True)
    else
      Grp(19, 'crypt-autre', '{CRYPT} sous-type non reconnu',
        'identifier le sous-type crypt avant de lancer un outil', True);
    Exit(True);
  end;

  if scheme = 'SSHA' then
    Grp(20, 'ssha1', '{SSHA} salted SHA-1 (base64)',
      'hashcat -m 111   john: detection auto', False)
  else if scheme = 'SHA' then
    Grp(21, 'sha1', '{SHA} SHA-1 (base64)',
      'hashcat -m 101   john: detection auto', False)
  else if scheme = 'SSHA256' then
    Grp(22, 'ssha256', '{SSHA256} salted SHA-256 (base64)',
      'hashcat -m 1411   john: detection auto', False)
  else if scheme = 'SSHA512' then
    Grp(23, 'ssha512', '{SSHA512} salted SHA-512 (base64)',
      'hashcat -m 1711   john: detection auto', False)
  else if scheme = 'ARGON2' then
    Grp(30, 'argon2', '{ARGON2} (chaine PHC $argon2...)',
      'hashcat -m 34000 (selon la version)   john: detection auto', True)
  else if scheme <> '' then
    // Hachage reconnu mais mode outil pas certain ici: on exporte, prefixe garde, note neutre.
    Grp(40, 'ldap-' + LowerCase(scheme), '{' + scheme + '}',
      'format a confirmer selon la version de john/hashcat', False)
  else
    Grp(50, 'autre', 'format sans prefixe reconnu', 'format a confirmer', False);
  Result := True;
end;

function TPwdCrackExportCmd.GroupStream(const AKey: string; AOrder: Integer;
  const AHeader: string): TStream;
var
  i, attempt: Integer;
  h: THandle;
  name: string;
begin
  for i := 0 to High(FGroups) do
    if FGroups[i].Key = AKey then Exit(FGroups[i].Stream);
  h := THandle(-1);
  for attempt := 1 to 20 do
  begin
    name := Format('%s.rtk%.4x%.4x.tmp', [FilePath, Length(FGroups), Random($10000)]);
    h := CreatePrivateTempRW(name);
    if h <> THandle(-1) then Break;
  end;
  if h = THandle(-1) then
    raise EStreamError.Create('cannot create a temporary hash bucket');
  SetLength(FGroups, Length(FGroups) + 1);
  FGroups[High(FGroups)].Key := AKey;
  FGroups[High(FGroups)].Order := AOrder;
  FGroups[High(FGroups)].Header := AHeader;
  FGroups[High(FGroups)].Stream := TOwnedHandleStream.Create(h);
  Result := FGroups[High(FGroups)].Stream;
end;

procedure TPwdCrackExportCmd.OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
var
  a: TLdapAttribute;
  i, order: Integer;
  id, key, header: string;
  v, line: RawByteString;
  wroteAny: Boolean;
begin
  try
    a := AEntry.Find('userPassword');
    if a <> nil then
    begin
      id := CrackIdentity(AEntry);
      wroteAny := False;
      for i := 0 to a.ValueCount - 1 do
      begin
        v := a.Values[i];
        if (Pos(#10, v) = 0) and (Pos(#13, v) = 0) and
           CrackClassify(v, key, order, header, line) then
        begin
          WriteAllBuf(GroupStream(key, order, header), id + ':' + line + #10);
          Inc(FWritten);
          wroteAny := True;
        end;
      end;
      if wroteAny then Inc(FAccounts);
    end;
  finally
    AEntry.Free;
  end;
  Inc(FSinceFlush);
  if FSinceFlush >= FLUSH_ENTRIES then
  begin
    PostProgress(False);
    FSinceFlush := 0;
  end;
end;

// Parcours en flux vers les temporaires par groupe, puis concatenation triee dans le fichier
// final. La memoire ne garde que les en-tetes, jamais les empreintes.
procedure TPwdCrackExportCmd.FillFromScan(ADest: TStream);
var
  i, j: Integer;
  g: TCrackGroup;
  buf: array[0..65535] of Byte;
  n: LongInt;
begin
  FGroups := nil;
  try
    FCompletion := ScanAll(Filter, CRACK_ATTRS, @OnEntry);
    for i := 1 to High(FGroups) do
    begin
      g := FGroups[i];
      j := i - 1;
      while (j >= 0) and (FGroups[j].Order > g.Order) do
      begin
        FGroups[j + 1] := FGroups[j];
        Dec(j);
      end;
      FGroups[j + 1] := g;
    end;
    for i := 0 to High(FGroups) do
    begin
      WriteAllBuf(ADest, FGroups[i].Header);
      FGroups[i].Stream.Seek(Int64(0), soBeginning);
      repeat
        n := FGroups[i].Stream.Read(buf, SizeOf(buf));
        if n > 0 then ADest.WriteBuffer(buf, n);
      until n <= 0;
      WriteAllBuf(ADest, #10);
    end;
  finally
    for i := 0 to High(FGroups) do
      FGroups[i].Stream.Free;
    FGroups := nil;
  end;
end;

procedure TPwdCrackExportCmd.PostProgress(AFinal: Boolean);
var
  m: TPwdCrackMsg;
begin
  m := TPwdCrackMsg.Create;
  FWorker.Stamp(m, Self);
  m.Written := FWritten;
  m.Accounts := FAccounts;
  m.Final := AFinal;
  if AFinal then
  begin
    m.Completion := FCompletion;
    m.Error := FWorker.Session.LastError;
  end;
  UiInbox.Post(m);
end;

procedure TPwdCrackExportCmd.Execute(AWorker: TDirectoryWorker);
begin
  FWorker := AWorker;
  FWritten := 0;
  FAccounts := 0;
  FSinceFlush := 0;
  FCompletion := Default(TSearchCompletion);
  try
    // Flux direct vers un temporaire prive, rename atomique: pas de copie en memoire.
    SavePrivateFill(FilePath, @FillFromScan);
  except
    on E: Exception do
    begin
      Fail(AWorker, E.Message);
      Exit;
    end;
  end;
  PostProgress(True);
end;

end.
