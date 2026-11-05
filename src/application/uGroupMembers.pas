// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uGroupMembers;

{$mode objfpc}{$H+}

// Membres de groupes: ou une chaine apparait parmi les valeurs member, uniqueMember et
// memberUid, et si l'entree visee existe encore. Le serveur ne sait pas chercher une
// sous-chaine dans un DN (distinguishedNameMatch n'a pas de regle SUBSTR): (member=*bob*)
// rend zero resultat sans la moindre erreur, et le compte supprime l'an dernier reste membre
// de tout. On lit donc les groupes et on compare ici.

interface

uses
  SysUtils, uLdapEntry, uLdapSchema, uSearchModel, uDirectoryWorker, uDirectoryScan, uSortKey;

const
  GROUP_MEMBER_KEEP_MAX = 200000;
  // Lectures une a une au-dela desquelles on s'arrete: dix mille allers-retours, c'est deja
  // long, et un audit qui ne finit jamais n'a rien audite.
  GROUP_MEMBER_READ_MAX = 10000;
  // DN retenus au listage. Au-dela, listage partiel: personne n'est declare introuvable sur la
  // foi d'une liste tronquee.
  GROUP_MEMBER_LIST_MAX = 2000000;

type
  TMemberMode = (mmGone, mmContains, mmStarts, mmEnds, mmEquals);
  // msNotFound: le serveur repond noSuchObject. Supprimee, ou cachee a cette identite par une ACL:
  // vu d'ici, aucune difference. msNotDn: une valeur memberUid, un nom de compte.
  TMemberState = (msExists, msNotFound, msUnchecked, msNotDn);
  TMemberPhase = (mpListing, mpGroups, mpChecking);

  TGroupMemberRow = record
    GroupDn, Attr, Value: string;
    // Cle du DN vise (ScanDnKey), vide pour memberUid.
    TargetKey: string;
    State: TMemberState;
    // A verifier par une lecture directe.
    Pending: Boolean;
  end;
  TGroupMemberRows = array of TGroupMemberRow;

  TGroupMemberTotals = record
    Phase: TMemberPhase;
    Listed: Int64;
    Groups: Int64;
    MatchGroups: Int64;
    Values: Int64;
    Matches: Int64;
    Gone: Int64;
    Unchecked: Int64;
    Checked: Int64;
    // Listage incomplet: une absence n'y prouve rien.
    ListingPartial: Boolean;
    Overflow: Boolean;
  end;

  // TEntriesMsg pour Final, Completion et Error. Rows n'arrive qu'avec le dernier lot.
  TGroupMemberMsg = class(TEntriesMsg)
  public
    Rows: TGroupMemberRows;
    Totals: TGroupMemberTotals;
  end;

  TGroupMemberCmd = class(TDirectoryScanCmd)
  private
    FRows: TGroupMemberRows;
    FCount: Integer;
    FTotals: TGroupMemberTotals;
    FSinceProgress: Integer;
    FListed: TStringArray;
    FListedCount: Integer;
    FExisting: TStringArray;
    FBaseKeys: TStringArray;
    FNeedle: string;
    FNeedleKey: string;
    FProbeHit: Boolean;
    procedure OnListed(AEntry: TLdapEntry; var AStop: Boolean);
    procedure OnGroup(AEntry: TLdapEntry; var AStop: Boolean);
    procedure OnProbe(AEntry: TLdapEntry; var AStop: Boolean);
    function Probe(const ADn: string): TMemberState;
    function Keep(const AGroupDn, AAttr, AValue, AKey: string; AState: TMemberState;
      APending: Boolean): Boolean;
    function Exists(const AKey: string): Boolean;
    function UnderBases(const AKey: string): Boolean;
    procedure CheckByRead;
    procedure Finish(const ACompletion: TSearchCompletion);
    procedure Progress;
  public
    Mode: TMemberMode;
    Text: string;
    Attributes: TStringArray;
    Filter: string;
    procedure Execute(AWorker: TDirectoryWorker); override;
  end;

// Comparaison sans casse; AValueLow et ANeedleLow deja en minuscules. mmEquals n'est pas
// traite ici: un DN s'egale par sa forme canonique, pas par son texte.
function MemberTextMatches(AMode: TMemberMode; const AValueLow, ANeedleLow: string): Boolean;
// DN vise par une valeur: uniqueMember perd le #'0101'B final de nameAndOptionalUID.
function MemberTargetDn(const AAttr, AValue: string): string;
function IsDnMemberAttr(const AAttr: string): Boolean;
// Attributs d'appartenance connus du serveur; AD n'a que member.
function GroupMemberAttrs(ASchema: TSchemaSnapshot; AActiveDirectory: Boolean): TStringArray;
function GroupMemberFilter(const AAttrs: TStringArray): string;
// AKey sous ABaseKey ou egal, cles de ScanDnKey. Une virgule echappee n'est pas une frontiere.
function KeyUnderBase(const AKey, ABaseKey: string): Boolean;

implementation

uses
  uUiInbox;

const
  PROGRESS_ENTRIES = 1000;
  PROGRESS_READS = 100;

function MemberTextMatches(AMode: TMemberMode; const AValueLow, ANeedleLow: string): Boolean;
var
  n: Integer;
begin
  n := Length(ANeedleLow);
  case AMode of
    mmContains: Result := Pos(ANeedleLow, AValueLow) > 0;
    mmStarts: Result := Copy(AValueLow, 1, n) = ANeedleLow;
    mmEnds: Result := (Length(AValueLow) >= n) and
      (Copy(AValueLow, Length(AValueLow) - n + 1, n) = ANeedleLow);
  else
    Result := AValueLow = ANeedleLow;
  end;
end;

function IsDnMemberAttr(const AAttr: string): Boolean;
begin
  Result := not SameText(AAttr, 'memberUid');
end;

function MemberTargetDn(const AAttr, AValue: string): string;
var
  p, slashes: Integer;
begin
  Result := AValue;
  if not SameText(AAttr, 'uniqueMember') then Exit;
  p := Length(Result);
  if (p < 4) or (Result[p] <> 'B') or (Result[p - 1] <> '''') then Exit;
  p := p - 2;
  while (p > 1) and (Result[p] in ['0', '1']) do Dec(p);
  if (p <= 2) or (Result[p] <> '''') or (Result[p - 1] <> '#') then Exit;
  // \# appartient au DN, pas au suffixe.
  slashes := 0;
  while (p - 2 - slashes >= 1) and (Result[p - 2 - slashes] = '\') do Inc(slashes);
  if not Odd(slashes) then
    Result := Copy(Result, 1, p - 2);
end;

function GroupMemberAttrs(ASchema: TSchemaSnapshot; AActiveDirectory: Boolean): TStringArray;
const
  CANDIDATES: array[0..2] of string = ('member', 'uniqueMember', 'memberUid');
var
  i, n: Integer;
  all: Boolean;
begin
  Result := nil;
  if AActiveDirectory then
  begin
    SetLength(Result, 1);
    Result[0] := 'member';
    Exit;
  end;
  // Un attribut inconnu dans le filtre et certains serveurs jettent tout le filtre.
  all := (ASchema = nil) or not ASchema.Complete;
  SetLength(Result, Length(CANDIDATES));
  n := 0;
  for i := 0 to High(CANDIDATES) do
    if all or (ASchema.AttributeType(CANDIDATES[i]) <> nil) then
    begin
      Result[n] := CANDIDATES[i];
      Inc(n);
    end;
  if n = 0 then
  begin
    for i := 0 to High(CANDIDATES) do
      Result[i] := CANDIDATES[i];
    n := Length(CANDIDATES);
  end;
  SetLength(Result, n);
end;

function GroupMemberFilter(const AAttrs: TStringArray): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(AAttrs) do
    Result := Result + '(' + AAttrs[i] + '=*)';
  if Length(AAttrs) > 1 then Result := '(|' + Result + ')';
end;

function KeyUnderBase(const AKey, ABaseKey: string): Boolean;
var
  p, slashes: Integer;
begin
  if ABaseKey = '' then Exit(True);
  if AKey = ABaseKey then Exit(True);
  p := Length(AKey) - Length(ABaseKey);
  if (p < 2) or (AKey[p] <> ',') or (Copy(AKey, p + 1, MaxInt) <> ABaseKey) then Exit(False);
  slashes := 0;
  while (p - 1 - slashes >= 1) and (AKey[p - 1 - slashes] = '\') do Inc(slashes);
  Result := not Odd(slashes);
end;

procedure TGroupMemberCmd.Progress;
var
  m: TGroupMemberMsg;
begin
  FSinceProgress := 0;
  m := TGroupMemberMsg.Create;
  FWorker.Stamp(m, Self);
  m.Totals := FTotals;
  UiInbox.Post(m);
end;

procedure TGroupMemberCmd.OnListed(AEntry: TLdapEntry; var AStop: Boolean);
begin
  try
    if FListedCount >= GROUP_MEMBER_LIST_MAX then
    begin
      FTotals.ListingPartial := True;
      AStop := True;
      Exit;
    end;
    if FListedCount = Length(FListed) then SetLength(FListed, FListedCount * 2 + 4096);
    FListed[FListedCount] := ScanDnKey(AEntry.Dn);
    Inc(FListedCount);
    Inc(FTotals.Listed);
  finally
    AEntry.Free;
  end;
  Inc(FSinceProgress);
  if FSinceProgress >= PROGRESS_ENTRIES then Progress;
end;

function TGroupMemberCmd.Exists(const AKey: string): Boolean;
var
  lo, hi, mid, c: Integer;
begin
  lo := 0;
  hi := High(FExisting);
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    c := CompareStr(FExisting[mid], AKey);
    if c = 0 then Exit(True);
    if c < 0 then lo := mid + 1 else hi := mid - 1;
  end;
  Result := False;
end;

function TGroupMemberCmd.UnderBases(const AKey: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FBaseKeys) do
    if KeyUnderBase(AKey, FBaseKeys[i]) then Exit(True);
  Result := False;
end;

function TGroupMemberCmd.Keep(const AGroupDn, AAttr, AValue, AKey: string;
  AState: TMemberState; APending: Boolean): Boolean;
var
  r: ^TGroupMemberRow;
begin
  Inc(FTotals.Matches);
  if FCount >= GROUP_MEMBER_KEEP_MAX then
  begin
    FTotals.Overflow := True;
    Exit(False);
  end;
  if FCount = Length(FRows) then SetLength(FRows, FCount * 2 + 256);
  r := @FRows[FCount];
  r^.GroupDn := AGroupDn;
  r^.Attr := AAttr;
  r^.Value := AValue;
  r^.TargetKey := AKey;
  r^.State := AState;
  r^.Pending := APending;
  Inc(FCount);
  Result := True;
end;

procedure TGroupMemberCmd.OnGroup(AEntry: TLdapEntry; var AStop: Boolean);
var
  a: TLdapAttribute;
  i, k: Integer;
  attr, v, key: string;
begin
  try
    Inc(FTotals.Groups);
    for k := 0 to High(Attributes) do
    begin
      a := AEntry.Find(Attributes[k]);
      if a = nil then Continue;
      attr := Attributes[k];
      for i := 0 to a.ValueCount - 1 do
      begin
        v := ScanText(a.Values[i]);
        if v = '' then Continue;
        Inc(FTotals.Values);
        if not IsDnMemberAttr(attr) then
        begin
          // memberUid: un nom de compte, rien a verifier, et rien a signaler en mode disparus.
          if (Mode = mmGone) or not MemberTextMatches(Mode, FoldCase(v), FNeedle) then
            Continue;
          Keep(AEntry.Dn, attr, v, '', msNotDn, False);
          Continue;
        end;
        key := ScanDnKey(MemberTargetDn(attr, v));
        case Mode of
          // Absent du listage ne suffit pas: un DN ecrit autrement, une ACL qui masque au
          // listage. Chaque absence est relue avant d'etre affirmee.
          mmGone:
            if Exists(key) then
              Continue
            else
              Keep(AEntry.Dn, attr, v, key, msUnchecked, True);
          mmEquals:
            if key = FNeedleKey then
              Keep(AEntry.Dn, attr, v, key, msUnchecked, True)
            else
              Continue;
        else
          if MemberTextMatches(Mode, FoldCase(v), FNeedle) then
            Keep(AEntry.Dn, attr, v, key, msUnchecked, True)
          else
            Continue;
        end;
      end;
    end;
  finally
    AEntry.Free;
  end;
  Inc(FSinceProgress);
  if FSinceProgress >= PROGRESS_ENTRIES then Progress;
end;

procedure TGroupMemberCmd.OnProbe(AEntry: TLdapEntry; var AStop: Boolean);
begin
  FProbeHit := True;
  AEntry.Free;
end;

// Pas ReadEntry: il range un "succes sans entree" sous noSuchObject, et c'est justement la
// reponse d'une entree que les ACL cachent. Ici seul le code du serveur fait foi.
function TGroupMemberCmd.Probe(const ADn: string): TMemberState;
var
  req: TSearchRequest;
  c: TSearchCompletion;
begin
  req := DefaultSearchRequest;
  req.BaseDn := ADn;
  req.Scope := ssBase;
  req.Filter := '(objectClass=*)';
  req.PageSize := 0;
  req.SizeLimit := 0;
  req.TimeLimitSec := 0;
  SetLength(req.Attributes, 1);
  req.Attributes[0] := '1.1';
  FProbeHit := False;
  c := Default(TSearchCompletion);
  FWorker.Session.Search(req, @OnProbe, Cancel, c, False);
  if FProbeHit then
    Result := msExists
  else if c.HasResult and (c.ResultCode = LDAP_RC_NO_SUCH_OBJECT) then
    Result := msNotFound
  else
    Result := msUnchecked;
end;

procedure TGroupMemberCmd.CheckByRead;
var
  keys: TStringArray;
  order: TIndexArray;
  idx: array of Integer;
  i, j, k, n, reads: Integer;
  state: TMemberState;
begin
  n := 0;
  idx := nil;
  SetLength(idx, FCount);
  for i := 0 to FCount - 1 do
    if FRows[i].Pending then
    begin
      idx[n] := i;
      Inc(n);
    end;
  if n = 0 then Exit;
  FTotals.Phase := mpChecking;
  Progress;
  keys := nil;
  SetLength(keys, n);
  for i := 0 to n - 1 do
    // Pas la cle en minuscules: deux DN qui ne different que par la casse sont peut-etre deux
    // entrees (attribut de nommage caseExact), et une lecture ne vaut que pour la sienne.
    keys[i] := ScanDnText(MemberTargetDn(FRows[idx[i]].Attr, FRows[idx[i]].Value));
  order := KeyOrder(keys);
  reads := 0;
  i := 0;
  while i < n do
  begin
    j := i + 1;
    while (j < n) and (keys[order[j]] = keys[order[i]]) do Inc(j);
    state := msUnchecked;
    if (reads < GROUP_MEMBER_READ_MAX) and not Cancel.IsCancelled then
    begin
      Inc(reads);
      state := Probe(keys[order[i]]);
      // Sous nos bases seulement: ailleurs, c'est peut-etre un autre annuaire.
      if (state = msNotFound) and not UnderBases(FRows[idx[order[i]]].TargetKey) then
        state := msUnchecked;
      Inc(FTotals.Checked);
      if FTotals.Checked mod PROGRESS_READS = 0 then Progress;
    end;
    for k := i to j - 1 do
    begin
      FRows[idx[order[k]]].State := state;
      FRows[idx[order[k]]].Pending := False;
    end;
    i := j;
  end;
end;

procedure TGroupMemberCmd.Finish(const ACompletion: TSearchCompletion);
var
  m: TGroupMemberMsg;
  keys: TStringArray;
  order: TIndexArray;
  sorted: TGroupMemberRows;
  i, n: Integer;
  done: TSearchCompletion;
begin
  done := ACompletion;
  if Cancel.IsCancelled then done.Cancelled := True;
  // Le mode disparus ne garde que ce qui manque ou reste douteux.
  n := 0;
  sorted := nil;
  SetLength(sorted, FCount);
  for i := 0 to FCount - 1 do
    if (Mode <> mmGone) or (FRows[i].State <> msExists) then
    begin
      sorted[n] := FRows[i];
      Inc(n);
    end;
  Dec(FTotals.Matches, FCount - n);
  FRows := sorted;
  FCount := n;
  FTotals.Gone := 0;
  FTotals.Unchecked := 0;
  for i := 0 to FCount - 1 do
    case FRows[i].State of
      msNotFound: Inc(FTotals.Gone);
      msUnchecked: Inc(FTotals.Unchecked);
    end;
  keys := nil;
  SetLength(keys, FCount);
  for i := 0 to FCount - 1 do
    keys[i] := SortKey(FRows[i].GroupDn) + #1 + SortKey(FRows[i].Value);
  order := KeyOrder(keys);
  sorted := nil;
  SetLength(sorted, FCount);
  FTotals.MatchGroups := 0;
  for i := 0 to FCount - 1 do
  begin
    sorted[i] := FRows[order[i]];
    if (i = 0) or (sorted[i].GroupDn <> sorted[i - 1].GroupDn) then Inc(FTotals.MatchGroups);
  end;
  m := TGroupMemberMsg.Create;
  try
    FWorker.Stamp(m, Self);
    m.Rows := sorted;
    m.Totals := FTotals;
    m.Final := True;
    m.Completion := done;
    m.Error := FWorker.Session.LastError;
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
  FRows := nil;
  FListed := nil;
  FExisting := nil;
end;

procedure TGroupMemberCmd.Execute(AWorker: TDirectoryWorker);
var
  listed, done: TSearchCompletion;
  order: TIndexArray;
  i: Integer;
begin
  FWorker := AWorker;
  FNeedle := FoldCase(Trim(Text));
  FNeedleKey := ScanDnKey(Trim(Text));
  SetLength(FBaseKeys, Length(Bases));
  for i := 0 to High(Bases) do
    FBaseKeys[i] := ScanDnKey(Bases[i]);
  // Texte vide: "contient" accepterait tout l'annuaire, et c'est une liste, pas une reponse.
  if (Mode <> mmGone) and (FNeedle = '') then
  begin
    done := Default(TSearchCompletion);
    done.HasResult := True;
    Finish(done);
    Exit;
  end;
  if Mode = mmGone then
  begin
    FTotals.Phase := mpListing;
    listed := ScanAll('(objectClass=*)', ['1.1'], @OnListed);
    FTotals.ListingPartial := FTotals.ListingPartial or (SearchOutcome(listed) <> soComplete);
    // Le plafond arrete le listage comme une annulation; seule celle de l'utilisateur arrete
    // tout, le plafond laisse un listage partiel.
    if Cancel.IsCancelled or (SearchOutcome(listed) = soFailed) then
    begin
      Finish(listed);
      Exit;
    end;
    SetLength(FListed, FListedCount);
    order := KeyOrder(FListed);
    SetLength(FExisting, FListedCount);
    for i := 0 to FListedCount - 1 do
      FExisting[i] := FListed[order[i]];
    FListed := nil;
  end;
  FTotals.Phase := mpGroups;
  Progress;
  done := ScanAll(Filter, Attributes, @OnGroup, True);
  if not done.Cancelled and (SearchOutcome(done) <> soFailed) then
    CheckByRead;
  Finish(done);
end;

end.
