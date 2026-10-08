// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDuplicateIds;

{$mode objfpc}{$H+}

// Identifiants partages: uidNumber, login ou adresse mail portes par plusieurs entrees. Deux
// comptes au meme uidNumber, c'est un seul utilisateur pour le systeme de fichiers, et un jour
// le mauvais des deux qui lit les fichiers de l'autre. On lit tout, on trie, on ne remonte que
// les groupes. Comparaison locale: un entier est ramene a son ecriture canonique, un login ou
// un mail se compare sans la casse.

interface

uses
  SysUtils, uLdapEntry, uSearchModel, uDirectoryWorker, uDirectoryScan, uCancel;

const
  // Au-dela on cesse de retenir et on le dit: un audit qui couche le poste n'a rien audite.
  DUP_ID_SCAN_MAX = 2000000;

type
  TDupIdRow = record
    // Valeur telle que lue; Key est ce qui se compare.
    Id, Key: string;
    Shared: Integer;
    Dn, Login, Name, GivenName, Mail: string;
    // Forme canonique du DN (ScanDnKey): deux ecritures d'une meme entree ne font pas
    // un doublon.
    DnKey: string;
  end;
  TDupIdRows = array of TDupIdRow;

  TDupIdTotals = record
    Entries: Int64;
    Distinct: Int64;
    SharedIds: Int64;
    SharedEntries: Int64;
    // Plafond atteint: des doublons ont pu passer entre les gouttes.
    Overflow: Boolean;
  end;

  // TEntriesMsg pour Final, Completion et Error: le suivi des taches ne solde une recherche
  // qu'a son lot final. Entries reste vide; Rows n'arrive qu'avec ce dernier lot.
  TDupIdMsg = class(TEntriesMsg)
  public
    Rows: TDupIdRows;
    Totals: TDupIdTotals;
  end;

  TDuplicateIdCmd = class(TDirectoryScanCmd)
  private
    FAll: TDupIdRows;
    FCount: Integer;
    FTotals: TDupIdTotals;
    FSinceFlush: Integer;
    procedure OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
    procedure Progress;
  public
    Attribute: string;
    // Attribut du login, pour la colonne: uid, ou sAMAccountName sur Active Directory.
    LoginAttr: string;
    Numeric: Boolean;
    procedure Execute(AWorker: TDirectoryWorker); override;
  end;

// ARows est trie sur place. Une entree vue deux fois n'est pas un doublon, juste une base
// declaree deux fois. Annule, le resultat s'arrete la ou il en etait; annule pendant le
// tri, il est vide.
function SharedIdRows(var ARows: TDupIdRows; ACount: Integer;
  out ATotals: TDupIdTotals; ACancel: TCancelToken = nil): TDupIdRows;
function DupIdKey(const AValue: string; ANumeric: Boolean): string;

implementation

uses
  uUiInbox;

const
  PROGRESS_ENTRIES = 1000;

function DupIdKey(const AValue: string; ANumeric: Boolean): string;
var
  n: Int64;
begin
  Result := Trim(AValue);
  if not ANumeric then
    Result := LowerCase(Result)
  else if TryStrToInt64(Result, n) then
    Result := IntToStr(n);
end;

// Les nombres dans l'ordre des nombres, le reste apres. Oui, il y a un reste.
function CompareKeys(const A, B: string): Integer;
var
  na, nb: Int64;
  ia, ib: Boolean;
begin
  ia := TryStrToInt64(A, na);
  ib := TryStrToInt64(B, nb);
  if ia and ib and (na <> nb) then
  begin
    if na < nb then Exit(-1) else Exit(1);
  end;
  if ia <> ib then
  begin
    if ia then Exit(-1) else Exit(1);
  end;
  Result := CompareStr(A, B);
end;

function CompareRows(const A, B: TDupIdRow): Integer;
begin
  Result := CompareKeys(A.Key, B.Key);
  if Result = 0 then Result := CompareStr(A.DnKey, B.DnKey);
end;

procedure SortRows(var ARows: TDupIdRows; ALo, AHi: Integer; ACancel: TCancelToken);
var
  i, j: Integer;
  pivot, t: TDupIdRow;
begin
  while ALo < AHi do
  begin
    // Abandonner laisse le tableau melange: l'appelant jette tout.
    if (ACancel <> nil) and ACancel.IsCancelled then Exit;
    i := ALo;
    j := AHi;
    pivot := ARows[ALo + (AHi - ALo) div 2];
    repeat
      while CompareRows(ARows[i], pivot) < 0 do Inc(i);
      while CompareRows(ARows[j], pivot) > 0 do Dec(j);
      if i <= j then
      begin
        t := ARows[i];
        ARows[i] := ARows[j];
        ARows[j] := t;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    // Recursion sur la plus petite moitie: la pile reste logarithmique.
    if j - ALo < AHi - i then
    begin
      SortRows(ARows, ALo, j, ACancel);
      ALo := i;
    end
    else
    begin
      SortRows(ARows, i, AHi, ACancel);
      AHi := j;
    end;
  end;
end;

function SharedIdRows(var ARows: TDupIdRows; ACount: Integer;
  out ATotals: TDupIdTotals; ACancel: TCancelToken): TDupIdRows;
var
  i, first, k, n, size, kept: Integer;
begin
  ATotals := Default(TDupIdTotals);
  Result := nil;
  n := 0;
  SortRows(ARows, 0, ACount - 1, ACancel);
  if (ACancel <> nil) and ACancel.IsCancelled then Exit;
  first := 0;
  while first < ACount do
  begin
    if (ACancel <> nil) and ACancel.IsCancelled then Break;
    // Groupe [first, i): meme cle; size compte les DN distincts.
    i := first + 1;
    size := 1;
    while (i < ACount) and (ARows[i].Key = ARows[first].Key) do
    begin
      if ARows[i].DnKey <> ARows[i - 1].DnKey then Inc(size);
      Inc(i);
    end;
    Inc(ATotals.Distinct);
    if size > 1 then
    begin
      Inc(ATotals.SharedIds);
      Inc(ATotals.SharedEntries, size);
      if n + size > Length(Result) then SetLength(Result, (n + size) * 2);
      kept := 0;
      for k := first to i - 1 do
        if (k = first) or (ARows[k].DnKey <> ARows[k - 1].DnKey) then
        begin
          Result[n + kept] := ARows[k];
          Result[n + kept].Shared := size;
          Inc(kept);
        end;
      Inc(n, size);
    end;
    first := i;
  end;
  SetLength(Result, n);
end;

procedure TDuplicateIdCmd.OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
var
  a: TLdapAttribute;
  i: Integer;
  id, dnKey: string;
  r: ^TDupIdRow;
begin
  try
    a := AEntry.Find(Attribute);
    if (a <> nil) and (a.ValueCount > 0) then
    begin
      Inc(FTotals.Entries);
      dnKey := ScanDnKey(AEntry.Dn);
      for i := 0 to a.ValueCount - 1 do
      begin
        id := Trim(ScanText(a.Values[i]));
        if id = '' then Continue;
        if FCount >= DUP_ID_SCAN_MAX then
        begin
          FTotals.Overflow := True;
          Break;
        end;
        if FCount = Length(FAll) then SetLength(FAll, FCount * 2 + 1024);
        r := @FAll[FCount];
        r^.Id := id;
        r^.Key := DupIdKey(id, Numeric);
        r^.Dn := AEntry.Dn;
        r^.DnKey := dnKey;
        r^.Login := ScanText(AEntry.FirstValue(LoginAttr));
        r^.Name := ScanText(AEntry.FirstValue('sn'));
        if r^.Name = '' then r^.Name := ScanText(AEntry.FirstValue('cn'));
        r^.GivenName := ScanText(AEntry.FirstValue('givenName'));
        r^.Mail := ScanText(AEntry.FirstValue('mail'));
        Inc(FCount);
      end;
    end;
  finally
    AEntry.Free;
  end;
  Inc(FSinceFlush);
  if FSinceFlush >= PROGRESS_ENTRIES then Progress;
end;

procedure TDuplicateIdCmd.Progress;
var
  m: TDupIdMsg;
begin
  FSinceFlush := 0;
  m := TDupIdMsg.Create;
  FWorker.Stamp(m, Self);
  m.Totals.Entries := FTotals.Entries;
  UiInbox.Post(m);
end;

procedure TDuplicateIdCmd.Execute(AWorker: TDirectoryWorker);
var
  m: TDupIdMsg;
  done: TSearchCompletion;
  totals: TDupIdTotals;
begin
  FWorker := AWorker;
  if LoginAttr = '' then LoginAttr := 'uid';
  done := ScanAll('(' + Attribute + '=*)', [Attribute, LoginAttr, 'cn', 'sn', 'givenName',
    'mail'], @OnEntry);
  m := TDupIdMsg.Create;
  try
    AWorker.Stamp(m, Self);
    m.Rows := SharedIdRows(FAll, FCount, totals, Cancel);
    // Annulation pendant le depouillement: le bilan le dit, au lieu de passer pour complet.
    if Cancel.IsCancelled then done.Cancelled := True;
    totals.Entries := FTotals.Entries;
    totals.Overflow := FTotals.Overflow;
    m.Totals := totals;
    m.Final := True;
    m.Completion := done;
    m.Error := AWorker.Session.LastError;
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
  FAll := nil;
end;

end.
