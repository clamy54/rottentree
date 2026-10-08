// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uHomonyms;

{$mode objfpc}{$H+}

// Homonymes d'un annuaire: les comptes au meme nom et au meme prenom, et pour chaque groupe si
// le login et le mail les distinguent encore. Les noms se comparent sans casse, sans accents et
// sans separateurs: c'est ainsi que les generateurs de login les voient, et c'est la que deux
// personnes finissent par recevoir le courrier l'une de l'autre. L'outil ne sait pas si deux
// homonymes sont deux personnes ou la meme avec deux comptes: il montre, il ne juge pas.

interface

uses
  SysUtils, uLdapEntry, uSearchModel, uDirectoryWorker, uDirectoryScan, uCancel;

const
  // Au-dela on cesse de retenir et on le dit.
  HOMONYM_SCAN_MAX = 2000000;

type
  THomonymRow = record
    Key: string;
    Name, GivenName, Login, Dn: string;
    // Forme canonique du DN (ScanDnKey): deux ecritures d'une meme entree ne font pas
    // deux homonymes.
    DnKey: string;
    // Toutes les adresses, telles que lues.
    Mails: TStringArray;
    Shared: Integer;
    // Ce compte partage son login, ou une adresse, avec un autre du groupe.
    SameLogin, SameMail: Boolean;
    // Un conflit quelque part dans le groupe, pas forcement sur ce compte.
    GroupConflict: Boolean;
  end;
  THomonymRows = array of THomonymRow;

  THomonymTotals = record
    Accounts: Int64;
    // Sans nom ou sans prenom: rien a comparer, comptes de service pour la plupart.
    Unnamed: Int64;
    Groups: Int64;
    GroupAccounts: Int64;
    LoginGroups: Int64;
    MailGroups: Int64;
    // Groupes sans conflit ou un login ou un mail manque: ni fautifs ni verifies.
    UncheckedGroups: Int64;
    Overflow: Boolean;
  end;

  // TEntriesMsg pour Final, Completion et Error: le suivi des taches ne solde une recherche
  // qu'a son lot final. Entries reste vide; Rows n'arrive qu'avec ce dernier lot.
  THomonymMsg = class(TEntriesMsg)
  public
    Rows: THomonymRows;
    Totals: THomonymTotals;
  end;

  THomonymCmd = class(TDirectoryScanCmd)
  private
    FAll: THomonymRows;
    FCount: Integer;
    FTotals: THomonymTotals;
    FSinceFlush: Integer;
    procedure OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
    procedure Progress;
  public
    Filter: string;
    // uid, ou sAMAccountName sur Active Directory.
    LoginAttr: string;
    procedure Execute(AWorker: TDirectoryWorker); override;
  end;

// Nom ramene a ce qui le distingue: minuscules, sans accents latins, sans espaces, tirets,
// points ni apostrophes. "Jean-Pierre" et "jean pierre" donnent la meme chose, "José" et
// "Jose" aussi.
function FoldName(const AName: string): string;
// Vide si le nom ou le prenom manque.
function HomonymKey(const ASn, AGivenName: string): string;
// Groupes de deux comptes et plus, ranges par nom plie puis par DN, conflits marques. ARows
// est trie sur place. Annule, le resultat s'arrete la ou il en etait; annule pendant le
// tri, il est vide.
function HomonymGroups(var ARows: THomonymRows; ACount: Integer;
  var ATotals: THomonymTotals; ACancel: TCancelToken = nil): THomonymRows;

implementation

uses
  uUiInbox;

const
  PROGRESS_ENTRIES = 1000;

// Lettres latines accentuees ramenees a leur base, pour U+00C0 a U+017F. Vide: pas une lettre
// de ces blocs, a garder telle quelle.
function LatinBase(ACode: Cardinal): string;
begin
  case ACode of
    $C0..$C5, $E0..$E5, $100..$105: Result := 'a';
    $C6, $E6: Result := 'ae';
    $C7, $E7, $106..$10D: Result := 'c';
    $D0, $F0, $10E..$111: Result := 'd';
    $C8..$CB, $E8..$EB, $112..$11B: Result := 'e';
    $11C..$123: Result := 'g';
    $124..$127: Result := 'h';
    $CC..$CF, $EC..$EF, $128..$131: Result := 'i';
    $132, $133: Result := 'ij';
    $134, $135: Result := 'j';
    $136..$138: Result := 'k';
    $139..$142: Result := 'l';
    $D1, $F1, $143..$14B: Result := 'n';
    $D2..$D6, $D8, $F2..$F6, $F8, $14C..$151: Result := 'o';
    $152, $153: Result := 'oe';
    $154..$159: Result := 'r';
    $DF: Result := 'ss';
    $15A..$161, $17F: Result := 's';
    $DE, $FE: Result := 'th';
    $162..$167: Result := 't';
    $D9..$DC, $F9..$FC, $168..$173: Result := 'u';
    $174, $175: Result := 'w';
    $DD, $FD, $FF, $176..$178: Result := 'y';
    $179..$17E: Result := 'z';
  else
    Result := '';
  end;
end;

function FoldName(const AName: string): string;
var
  i, len, n: Integer;
  b: Byte;
  code: Cardinal;
  base: string;
begin
  Result := '';
  i := 1;
  len := Length(AName);
  while i <= len do
  begin
    b := Ord(AName[i]);
    if b < $80 then
    begin
      case AName[i] of
        'A'..'Z': Result := Result + Chr(b + 32);
        ' ', '-', '''', '.', '_', #9: ;
      else
        Result := Result + AName[i];
      end;
      Inc(i);
      Continue;
    end;
    // Longueur de la sequence UTF-8; un octet invalide est recopie tel quel.
    if (b and $E0) = $C0 then n := 2
    else if (b and $F0) = $E0 then n := 3
    else if (b and $F8) = $F0 then n := 4
    else n := 1;
    if (n = 1) or (i + n - 1 > len) then
    begin
      Result := Result + AName[i];
      Inc(i);
      Continue;
    end;
    if n = 2 then
      code := ((b and $1F) shl 6) or (Ord(AName[i + 1]) and $3F)
    else if n = 3 then
      code := ((b and $0F) shl 12) or ((Ord(AName[i + 1]) and $3F) shl 6) or
        (Ord(AName[i + 2]) and $3F)
    else
      code := 0;
    base := '';
    if (code >= $C0) and (code <= $17F) then base := LatinBase(code);
    if base <> '' then
      Result := Result + base
    // Diacritiques combinants, espace insecable, tirets et apostrophes typographiques: du
    // bruit, comme leurs cousins ASCII.
    else if not (((code >= $300) and (code <= $36F)) or (code = $A0) or
      ((code >= $2010) and (code <= $2015)) or (code = $2018) or (code = $2019)) then
      Result := Result + Copy(AName, i, n);
    Inc(i, n);
  end;
end;

function HomonymKey(const ASn, AGivenName: string): string;
var
  s, g: string;
begin
  s := FoldName(ASn);
  g := FoldName(AGivenName);
  if (s = '') or (g = '') then Exit('');
  Result := s + #1 + g;
end;

function CompareRows(const A, B: THomonymRow): Integer;
begin
  Result := CompareStr(A.Key, B.Key);
  if Result = 0 then Result := CompareStr(A.DnKey, B.DnKey);
end;

procedure SortRows(var ARows: THomonymRows; ALo, AHi: Integer; ACancel: TCancelToken);
var
  i, j: Integer;
  pivot, t: THomonymRow;
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

type
  // Un login ou un mail en minuscules, et le membre du groupe qui le porte.
  TKeyRef = record
    Key: string;
    Ref: Integer;
  end;
  TKeyRefs = array of TKeyRef;

procedure SortKeyRefs(var A: TKeyRefs; ALo, AHi: Integer);
var
  i, j: Integer;
  pivot, t: TKeyRef;
begin
  while ALo < AHi do
  begin
    i := ALo;
    j := AHi;
    pivot := A[ALo + (AHi - ALo) div 2];
    repeat
      while CompareStr(A[i].Key, pivot.Key) < 0 do Inc(i);
      while CompareStr(A[j].Key, pivot.Key) > 0 do Dec(j);
      if i <= j then
      begin
        t := A[i];
        A[i] := A[j];
        A[j] := t;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    if j - ALo < AHi - i then
    begin
      SortKeyRefs(A, ALo, j);
      ALo := i;
    end
    else
    begin
      SortKeyRefs(A, i, AHi);
      AHi := j;
    end;
  end;
end;

// Membres [AFirst, AFirst + ASize) de AOut: logins et adresses tries, les series marquent les
// partages. Lineaire au tri pres; un groupe entier de clones ne retient plus le fil.
procedure MarkConflicts(var AOut: THomonymRows; AFirst, ASize: Integer;
  var ATotals: THomonymTotals);
var
  refs: TKeyRefs;
  i, j, k, n: Integer;
  login, mail, missing, sharedRun: Boolean;
begin
  login := False;
  mail := False;
  missing := False;
  refs := nil;
  SetLength(refs, ASize);
  n := 0;
  for i := AFirst to AFirst + ASize - 1 do
  begin
    if (AOut[i].Login = '') or (Length(AOut[i].Mails) = 0) then missing := True;
    if AOut[i].Login <> '' then
    begin
      refs[n].Key := LowerCase(AOut[i].Login);
      refs[n].Ref := i;
      Inc(n);
    end;
  end;
  SortKeyRefs(refs, 0, n - 1);
  i := 0;
  while i < n do
  begin
    j := i + 1;
    while (j < n) and (refs[j].Key = refs[i].Key) do Inc(j);
    // Les DN sont dedoublonnes en amont: deux refs, deux comptes.
    if j - i > 1 then
    begin
      login := True;
      for k := i to j - 1 do AOut[refs[k].Ref].SameLogin := True;
    end;
    i := j;
  end;
  n := 0;
  for i := AFirst to AFirst + ASize - 1 do
    Inc(n, Length(AOut[i].Mails));
  SetLength(refs, n);
  n := 0;
  for i := AFirst to AFirst + ASize - 1 do
    for j := 0 to High(AOut[i].Mails) do
    begin
      refs[n].Key := LowerCase(AOut[i].Mails[j]);
      refs[n].Ref := i;
      Inc(n);
    end;
  SortKeyRefs(refs, 0, n - 1);
  i := 0;
  while i < n do
  begin
    j := i + 1;
    sharedRun := False;
    while (j < n) and (refs[j].Key = refs[i].Key) do
    begin
      // Une adresse presente deux fois sur le meme compte ne partage rien.
      if refs[j].Ref <> refs[i].Ref then sharedRun := True;
      Inc(j);
    end;
    if sharedRun then
    begin
      mail := True;
      for k := i to j - 1 do AOut[refs[k].Ref].SameMail := True;
    end;
    i := j;
  end;
  if login then Inc(ATotals.LoginGroups);
  if mail then Inc(ATotals.MailGroups);
  if login or mail then
    for i := AFirst to AFirst + ASize - 1 do
      AOut[i].GroupConflict := True
  else if missing then
    Inc(ATotals.UncheckedGroups);
end;

function HomonymGroups(var ARows: THomonymRows; ACount: Integer;
  var ATotals: THomonymTotals; ACancel: TCancelToken): THomonymRows;
var
  i, first, k, n, size, kept: Integer;
begin
  Result := nil;
  n := 0;
  SortRows(ARows, 0, ACount - 1, ACancel);
  if (ACancel <> nil) and ACancel.IsCancelled then Exit;
  first := 0;
  while first < ACount do
  begin
    if (ACancel <> nil) and ACancel.IsCancelled then Break;
    // Groupe [first, i): meme cle; size compte les DN distincts, une base declaree deux fois
    // ne fabrique pas d'homonymes.
    i := first + 1;
    size := 1;
    while (i < ACount) and (ARows[i].Key = ARows[first].Key) do
    begin
      if ARows[i].DnKey <> ARows[i - 1].DnKey then Inc(size);
      Inc(i);
    end;
    if size > 1 then
    begin
      Inc(ATotals.Groups);
      Inc(ATotals.GroupAccounts, size);
      if n + size > Length(Result) then SetLength(Result, (n + size) * 2);
      kept := 0;
      for k := first to i - 1 do
        if (k = first) or (ARows[k].DnKey <> ARows[k - 1].DnKey) then
        begin
          Result[n + kept] := ARows[k];
          Result[n + kept].Shared := size;
          Inc(kept);
        end;
      MarkConflicts(Result, n, size, ATotals);
      Inc(n, size);
    end;
    first := i;
  end;
  SetLength(Result, n);
end;

procedure THomonymCmd.OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
var
  a: TLdapAttribute;
  sn, given, key, mail: string;
  i, m: Integer;
  r: ^THomonymRow;
begin
  try
    Inc(FTotals.Accounts);
    sn := Trim(ScanText(AEntry.FirstValue('sn')));
    given := Trim(ScanText(AEntry.FirstValue('givenName')));
    key := HomonymKey(sn, given);
    if key = '' then
      Inc(FTotals.Unnamed)
    else if FCount >= HOMONYM_SCAN_MAX then
      FTotals.Overflow := True
    else
    begin
      if FCount = Length(FAll) then SetLength(FAll, FCount * 2 + 1024);
      r := @FAll[FCount];
      r^.Key := key;
      r^.Name := sn;
      r^.GivenName := given;
      r^.Dn := AEntry.Dn;
      r^.DnKey := ScanDnKey(AEntry.Dn);
      r^.Login := Trim(ScanText(AEntry.FirstValue(LoginAttr)));
      a := AEntry.Find('mail');
      if a <> nil then
      begin
        SetLength(r^.Mails, a.ValueCount);
        m := 0;
        for i := 0 to a.ValueCount - 1 do
        begin
          mail := Trim(ScanText(a.Values[i]));
          if mail = '' then Continue;
          r^.Mails[m] := mail;
          Inc(m);
        end;
        SetLength(r^.Mails, m);
      end;
      Inc(FCount);
    end;
  finally
    AEntry.Free;
  end;
  Inc(FSinceFlush);
  if FSinceFlush >= PROGRESS_ENTRIES then Progress;
end;

procedure THomonymCmd.Progress;
var
  m: THomonymMsg;
begin
  FSinceFlush := 0;
  m := THomonymMsg.Create;
  FWorker.Stamp(m, Self);
  m.Totals.Accounts := FTotals.Accounts;
  UiInbox.Post(m);
end;

procedure THomonymCmd.Execute(AWorker: TDirectoryWorker);
var
  m: THomonymMsg;
  done: TSearchCompletion;
begin
  FWorker := AWorker;
  if LoginAttr = '' then LoginAttr := 'uid';
  done := ScanAll(Filter, ['sn', 'givenName', LoginAttr, 'mail'], @OnEntry);
  m := THomonymMsg.Create;
  try
    AWorker.Stamp(m, Self);
    m.Rows := HomonymGroups(FAll, FCount, FTotals, Cancel);
    // Annulation pendant le depouillement: le bilan le dit, au lieu de passer pour complet.
    if Cancel.IsCancelled then done.Cancelled := True;
    m.Totals := FTotals;
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
