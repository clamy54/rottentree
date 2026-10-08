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
  SysUtils, uLdapEntry, uLdapSchema, uSearchModel, uPwdCore, uDirectoryWorker,
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

function PwdAuditListed(ALevel: TPwdStorageLevel): Boolean;
// Un format non juge passe avant un format correct: le doute ne profite pas a l'accuse.
function PwdAuditRank(ALevel: TPwdStorageLevel): Integer;
// Faux si aucune valeur n'a ete lue: absente ou illisible, d'ici on ne saura jamais.
function ClassifyPasswords(AAttr: TLdapAttribute; out ALevel: TPwdStorageLevel;
  out AWorst, AOthers: string): Boolean;
function PwdAuditFilter(ASchema: TSchemaSnapshot): string;

implementation

uses
  uPasswordSchemes, uUiInbox;

const
  AUDIT_ATTRS: array[0..5] of string = ('userPassword', 'cn', 'sn', 'givenName', 'mail', 'uid');
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

end.
