// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTemplateUnique;

{$mode objfpc}{$H+}

// Numero d'homonyme: le plus petit qui laisse libres toutes les valeurs qui le portent, le meme
// partout. L'annuaire est lu en entier, comme pour les uidNumber: une liste tronquee rendrait
// jdupont1 a son deuxieme proprietaire. Sur AD, compte, UPN et adresses sont controles meme sans
// numero: Exchange ne previent pas, il livre le courrier au premier arrive.
// Portee: le contexte lu, pas la foret. Rien n'est reserve: deux admins rapides peuvent encore
// se marcher dessus.

interface

uses
  SysUtils, Classes, Generics.Collections, uLdapEntry, uSearchModel, uConnectionProfile, uLdapSchema,
  uEntryTemplate;

const
  // valeurs et personnes, tout compris; au-dela, Overflow et personne ne pretend avoir tout vu
  UNIQUE_SCAN_MAX = 2000000;
  UNIQUE_SCAN_MAX_BYTES = 256 * 1024 * 1024;

type
  TUniqueCheck = record
    Field: Integer;
    // nom principal
    Attr: string;
    // "mail" reunit mail et proxyAddresses
    Kind: string;
    Counted: Boolean;
  end;

  TUniqueResult = record
    Counter: Integer;
    // valeurs sautees pour arriver au numero retenu, avec leur proprietaire
    Skipped: string;
    // bloquant
    Problem: string;
    ProblemField: Integer;
    // meme nom deja en place: homonyme ou doublon, a l'operateur de dire
    Lookalike: string;
  end;

  TUniqueHolders = specialize TDictionary<string, string>;

  TUniqueScan = class
  private
    FProvider: TProviderKind;
    FChecks: array of TUniqueCheck;
    FKinds: TStringArray;
    // nom, alias ou OID -> nom principal; le schema, lui, ne survit pas a une relecture
    FAlias: TUniqueHolders;
    FAttrKind: TUniqueHolders;
    FTaken: TUniqueHolders;
    FPersons: TUniqueHolders;
    // lignes deja retenues d'un lot, oubliees a chaque calcul
    FReserved: TUniqueHolders;
    FReservedPersons: TUniqueHolders;
    FPersonAttrs: TStringArray;
    FCount: Integer;
    FBytes: Int64;
    FOverflow: Boolean;
    FEntries: Integer;
    procedure Learn(ASchema: TSchemaSnapshot; const AAttr: string);
    function Canon(const AAttr: string): string;
    function FieldOf(const T: TEntryTemplate; const AAttr: string): Integer;
    procedure AddCheck(AField: Integer; const AAttr, AKind: string; ACounted: Boolean);
    procedure Keep(AInto: TUniqueHolders; const AKey, AHolder: string);
    function HolderOfKey(const AKey: string): string;
    function PersonKeyOf(AEntry: TLdapEntry): string;
  public
    constructor Create(const T: TEntryTemplate; AProvider: TProviderKind; ASchema: TSchemaSnapshot = nil);
    destructor Destroy; override;
    function Needed: Boolean;
    function Attributes: TStringArray;
    function Filter: string;
    procedure Feed(AEntry: TLdapEntry);
    // valeur telle que l'attribut la porte: "SMTP:a@b" pour proxyAddresses
    function Holder(const AAttr, AValue: string): string;
    function Resolve(const T: TEntryTemplate; var AValues: TStringArray; const AManual: array of Boolean;
      var ABudget: Int64): TUniqueResult;
    procedure Reserve(const T: TEntryTemplate; const AValues: TStringArray; const AHolder: string);
    procedure ClearReserved;
    function PersonKey(const T: TEntryTemplate; const AValues: TStringArray): string;
    property Overflow: Boolean read FOverflow;
    property Entries: Integer read FEntries;
  end;

function UniqueKindOf(const AAttr: string; AProvider: TProviderKind): string;
function UniqueSearchRequest(AProfile: TConnectionProfile; const ABase: string;
  AScan: TUniqueScan): TSearchRequest;
function ForestDomainsRequest(AProfile: TConnectionProfile; const AConfigNc: string): TSearchRequest;

resourcestring
  rsUqTaken = '%s %s is already used by %s';
  rsUqNoCounter = 'no free number up to %d for %s';
  rsUqSkipped = '%s taken by %s';
  rsUqBatchLine = 'line %d of the file';
  rsUqBudget = 'the values are too long to compose and check: shorten them or simplify the template';

implementation

uses
  LazUTF8;

const
  KIND_MAIL = 'mail';
  KIND_UPN = 'upn';
  KIND_SAM = 'sam';
  // cout d'une entree de dictionnaire hors chaines, a la louche
  ENTRY_OVERHEAD = 64;

function UniqueKindOf(const AAttr: string; AProvider: TProviderKind): string;
begin
  if SameAttr(AAttr, 'mail') then Exit(KIND_MAIL);
  if AProvider = pkActiveDirectory then
  begin
    if SameAttr(AAttr, 'proxyAddresses') then Exit(KIND_MAIL);
    if SameAttr(AAttr, 'userPrincipalName') then Exit(KIND_UPN);
    if SameAttr(AAttr, 'sAMAccountName') then Exit(KIND_SAM);
  end;
  Result := LowerCase(AttrBaseName(AAttr));
end;

function KindAttrs(const AKind: string; AProvider: TProviderKind): TStringArray;
begin
  if AKind = KIND_MAIL then
  begin
    if AProvider = pkActiveDirectory then Result := ['mail', 'proxyAddresses'] else Result := ['mail'];
  end
  else if AKind = KIND_UPN then Result := ['userPrincipalName']
  else if AKind = KIND_SAM then Result := ['sAMAccountName']
  else Result := [AKind];
end;

function Folded(const AValue: string): string;
begin
  // Plus strict que le schema: deux valeurs qui ne different que par la casse, c'est deja un
  // homonyme de trop.
  Result := UTF8LowerCase(Trim(AValue));
end;

// Meme cle a la lecture, au controle et a la reservation. Vide: rien a comparer.
function ValueKey(const AKind, AAttr, AValue: string): string;
var
  v: string;
begin
  v := Trim(AValue);
  if SameAttr(AAttr, 'proxyAddresses') then
  begin
    // X500: et consorts ne recoivent pas de courrier
    if not SameText(Copy(v, 1, 5), 'smtp:') then Exit('');
    Delete(v, 1, 5);
  end;
  v := Folded(v);
  if v = '' then Exit('');
  Result := AKind + #0 + v;
end;

constructor TUniqueScan.Create(const T: TEntryTemplate; AProvider: TProviderKind; ASchema: TSchemaSnapshot);
const
  KNOWN: array[0..7] of string = ('mail', 'proxyAddresses', 'userPrincipalName', 'sAMAccountName',
    'givenName', 'sn', 'displayName', 'cn');
var
  counted: TTplIndexes;
  i, j: Integer;
  isCounted: array of Boolean;
  attrs: TStringArray;

  // Toutes les occurrences: un deuxieme mail ou un alias fixe se heurtent autant que le premier.
  procedure Extra(const AAttr: string);
  var
    f: Integer;
  begin
    for f := 0 to High(T.Fields) do
      if SameAttr(Canon(T.Fields[f].Attr), AAttr) and not isCounted[f] then
        AddCheck(f, Canon(T.Fields[f].Attr), UniqueKindOf(Canon(AAttr), AProvider), False);
  end;

begin
  inherited Create;
  FProvider := AProvider;
  FAlias := TUniqueHolders.Create;
  FAttrKind := TUniqueHolders.Create;
  FTaken := TUniqueHolders.Create;
  FPersons := TUniqueHolders.Create;
  FReserved := TUniqueHolders.Create;
  FReservedPersons := TUniqueHolders.Create;
  for i := 0 to High(KNOWN) do Learn(ASchema, KNOWN[i]);
  for i := 0 to High(T.Fields) do Learn(ASchema, T.Fields[i].Attr);
  isCounted := nil;
  SetLength(isCounted, Length(T.Fields));
  counted := TemplateCounterFields(T);
  for i := 0 to High(counted) do
  begin
    isCounted[counted[i]] := True;
    if not TemplatePasswordField(T.Fields[counted[i]], nil) then
      AddCheck(counted[i], Canon(T.Fields[counted[i]].Attr),
        UniqueKindOf(Canon(T.Fields[counted[i]].Attr), AProvider), True);
  end;
  if AProvider = pkActiveDirectory then
  begin
    Extra('sAMAccountName');
    Extra('userPrincipalName');
    Extra('mail');
    Extra('proxyAddresses');
  end;
  if Length(FChecks) = 0 then Exit;
  for i := 0 to High(FKinds) do
  begin
    attrs := KindAttrs(FKinds[i], FProvider);
    for j := 0 to High(attrs) do FAttrKind.AddOrSetValue(LowerCase(Canon(attrs[j])), FKinds[i]);
  end;
  if (FieldOf(T, 'givenName') >= 0) and (FieldOf(T, 'sn') >= 0) then
    FPersonAttrs := [Canon('givenName'), Canon('sn')]
  else if FieldOf(T, 'displayName') >= 0 then FPersonAttrs := [Canon('displayName')]
  else if FieldOf(T, 'cn') >= 0 then FPersonAttrs := [Canon('cn')];
end;

destructor TUniqueScan.Destroy;
begin
  FAlias.Free;
  FAttrKind.Free;
  FTaken.Free;
  FPersons.Free;
  FReserved.Free;
  FReservedPersons.Free;
  inherited Destroy;
end;

procedure TUniqueScan.Learn(ASchema: TSchemaSnapshot; const AAttr: string);
var
  at: TSchemaAttributeType;
  base: string;
  i: Integer;
begin
  base := AttrBaseName(AAttr);
  if base = '' then Exit;
  at := nil;
  if ASchema <> nil then at := ASchema.AttributeType(base);
  if at = nil then
  begin
    FAlias.TryAdd(LowerCase(base), base);
    Exit;
  end;
  // "0.9.2342.19200300.100.1.3" et "mail": meme boite aux lettres, meme cle.
  FAlias.AddOrSetValue(LowerCase(at.Oid), at.PrimaryName);
  for i := 0 to High(at.Names) do FAlias.AddOrSetValue(LowerCase(at.Names[i]), at.PrimaryName);
  FAlias.AddOrSetValue(LowerCase(base), at.PrimaryName);
end;

function TUniqueScan.Canon(const AAttr: string): string;
var
  base: string;
begin
  base := AttrBaseName(AAttr);
  if not FAlias.TryGetValue(LowerCase(base), Result) then Result := base;
end;

function TUniqueScan.FieldOf(const T: TEntryTemplate; const AAttr: string): Integer;
var
  i: Integer;
  want: string;
begin
  want := Canon(AAttr);
  for i := 0 to High(T.Fields) do
    if SameAttr(Canon(T.Fields[i].Attr), want) then Exit(i);
  Result := -1;
end;

procedure TUniqueScan.AddCheck(AField: Integer; const AAttr, AKind: string; ACounted: Boolean);
var
  i: Integer;
begin
  for i := 0 to High(FChecks) do
    if FChecks[i].Field = AField then Exit;
  SetLength(FChecks, Length(FChecks) + 1);
  FChecks[High(FChecks)].Field := AField;
  FChecks[High(FChecks)].Attr := AAttr;
  FChecks[High(FChecks)].Kind := AKind;
  FChecks[High(FChecks)].Counted := ACounted;
  for i := 0 to High(FKinds) do
    if FKinds[i] = AKind then Exit;
  SetLength(FKinds, Length(FKinds) + 1);
  FKinds[High(FKinds)] := AKind;
end;

function TUniqueScan.Needed: Boolean;
begin
  Result := Length(FChecks) > 0;
end;

function TUniqueScan.Attributes: TStringArray;
var
  i, j: Integer;
  a: TStringArray;
begin
  Result := nil;
  for i := 0 to High(FKinds) do
  begin
    a := KindAttrs(FKinds[i], FProvider);
    for j := 0 to High(a) do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Canon(a[j]);
    end;
  end;
  for i := 0 to High(FPersonAttrs) do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := FPersonAttrs[i];
  end;
end;

function TUniqueScan.Filter: string;
var
  a: TStringArray;
  i: Integer;
begin
  a := Attributes;
  Result := '';
  for i := 0 to High(a) do Result := Result + '(' + a[i] + '=*)';
  if Length(a) > 1 then Result := '(|' + Result + ')';
end;

procedure TUniqueScan.Keep(AInto: TUniqueHolders; const AKey, AHolder: string);
begin
  if (AKey = '') or FOverflow then Exit;
  // Un plafond pour tout: un million de contacts sans adresse remplit la memoire aussi bien
  // qu'un million d'adresses.
  if (FCount >= UNIQUE_SCAN_MAX) or (FBytes > UNIQUE_SCAN_MAX_BYTES) then
  begin
    FOverflow := True;
    Exit;
  end;
  // le premier proprietaire trouve reste celui qu'on cite
  if AInto.TryAdd(AKey, AHolder) then
  begin
    Inc(FCount);
    Inc(FBytes, Length(AKey) + Length(AHolder) + ENTRY_OVERHEAD);
  end;
end;

function TUniqueScan.PersonKeyOf(AEntry: TLdapEntry): string;
var
  i, j: Integer;
  v: string;
begin
  Result := '';
  for i := 0 to High(FPersonAttrs) do
  begin
    v := '';
    for j := 0 to AEntry.AttrCount - 1 do
      if SameAttr(Canon(AEntry.Attrs[j].Description), FPersonAttrs[i]) and (AEntry.Attrs[j].ValueCount > 0) then
      begin
        v := AEntry.Attrs[j].Values[0];
        Break;
      end;
    v := Folded(PlainAscii(v));
    if v = '' then Exit('');
    Result := Result + v + #0;
  end;
end;

procedure TUniqueScan.Feed(AEntry: TLdapEntry);
var
  i, k: Integer;
  a: TLdapAttribute;
  attr, kind: string;
begin
  if (AEntry = nil) or FOverflow then Exit;
  Inc(FEntries);
  // Le serveur nomme les attributs comme il veut, pas forcement comme on a demande.
  for i := 0 to AEntry.AttrCount - 1 do
  begin
    a := AEntry.Attrs[i];
    attr := Canon(a.Description);
    if not FAttrKind.TryGetValue(LowerCase(attr), kind) then Continue;
    for k := 0 to a.ValueCount - 1 do
      Keep(FTaken, ValueKey(kind, attr, a.Values[k]), AEntry.Dn);
  end;
  Keep(FPersons, PersonKeyOf(AEntry), AEntry.Dn);
end;

function TUniqueScan.HolderOfKey(const AKey: string): string;
begin
  Result := '';
  if AKey = '' then Exit;
  if not FTaken.TryGetValue(AKey, Result) and not FReserved.TryGetValue(AKey, Result) then Result := '';
end;

function TUniqueScan.Holder(const AAttr, AValue: string): string;
begin
  Result := HolderOfKey(ValueKey(UniqueKindOf(Canon(AAttr), FProvider), Canon(AAttr), AValue));
end;

function TUniqueScan.PersonKey(const T: TEntryTemplate; const AValues: TStringArray): string;
var
  i, f: Integer;
  v: string;
begin
  Result := '';
  if Length(FPersonAttrs) = 0 then Exit;
  for i := 0 to High(FPersonAttrs) do
  begin
    f := FieldOf(T, FPersonAttrs[i]);
    if (f < 0) or (f > High(AValues)) then Exit('');
    v := Folded(PlainAscii(AValues[f]));
    if v = '' then Exit('');
    Result := Result + v + #0;
  end;
end;

function TUniqueScan.Resolve(const T: TEntryTemplate; var AValues: TStringArray;
  const AManual: array of Boolean; var ABudget: Int64): TUniqueResult;
var
  base: TStringArray;
  n, i, f, cuts, hit: Integer;
  clear, varies: Boolean;
  owner, skipped, key, lookalike: string;

  function Moves(AIndex: Integer): Boolean;
  begin
    f := FChecks[AIndex].Field;
    Result := FChecks[AIndex].Counted and not ((f <= High(AManual)) and AManual[f]);
  end;

  function OwnerOf(AIndex: Integer): string;
  begin
    Result := HolderOfKey(ValueKey(FChecks[AIndex].Kind, FChecks[AIndex].Attr, AValues[FChecks[AIndex].Field]));
  end;

  procedure Block(const AText: string; AField: Integer);
  begin
    Result.Problem := AText;
    Result.ProblemField := AField;
  end;

begin
  Result := Default(TUniqueResult);
  Result.Counter := 1;
  Result.ProblemField := -1;
  base := Copy(AValues, 0, Length(AValues));
  ComposeValuesCounted(T, AValues, AManual, 1, ABudget);
  // Budget negatif: des "????" que personne n'a compares. Jamais libres.
  if ABudget < 0 then Block(rsUqBudget, FChecks[0].Field);
  varies := False;
  // Ce qui ne bouge pas avec le numero se juge une fois: un numero n'y changera rien.
  for i := 0 to High(FChecks) do
  begin
    if Result.Problem <> '' then Break;
    if Moves(i) then
    begin
      varies := True;
      Continue;
    end;
    if f > High(AValues) then Continue;
    owner := OwnerOf(i);
    if owner <> '' then Block(Format(rsUqTaken, [T.Fields[f].Attr, AValues[f], owner]), f);
  end;
  n := 1;
  hit := FChecks[0].Field;
  // On sort avec un candidat controle et libre, ou bloque. Pas de troisieme voie.
  while varies and (Result.Problem = '') do
  begin
    clear := True;
    for i := 0 to High(FChecks) do
    begin
      if not Moves(i) or (f > High(AValues)) then Continue;
      owner := OwnerOf(i);
      if owner = '' then Continue;
      clear := False;
      hit := f;
      skipped := Format(rsUqSkipped, [AValues[f], owner]);
      if Result.Skipped = '' then Result.Skipped := skipped
      else if Pos(skipped, Result.Skipped) = 0 then Result.Skipped := Result.Skipped + '; ' + skipped;
      Break;
    end;
    if clear then Break;
    Inc(n);
    if n > TEMPLATE_COUNTER_MAX then
    begin
      Block(Format(rsUqNoCounter, [TEMPLATE_COUNTER_MAX, T.Fields[hit].Attr]), hit);
      Break;
    end;
    AValues := Copy(base, 0, Length(base));
    ComposeValuesCounted(T, AValues, AManual, n, ABudget);
    if ABudget < 0 then Block(rsUqBudget, hit);
  end;
  Result.Counter := n;
  // L'ancien proprietaire du nom est peut-etre la meme personne, recreee par megarde.
  key := PersonKey(T, AValues);
  if (key <> '') and (FPersons.TryGetValue(key, lookalike) or FReservedPersons.TryGetValue(key, lookalike)) then
    Result.Lookalike := lookalike;
  // Trois raisons suffisent, personne ne lit la trois-centieme.
  cuts := 0;
  for i := 1 to Length(Result.Skipped) do
    if Result.Skipped[i] = ';' then
    begin
      Inc(cuts);
      if cuts = 3 then
      begin
        Result.Skipped := Copy(Result.Skipped, 1, i - 1) + '; ...';
        Break;
      end;
    end;
end;

procedure TUniqueScan.Reserve(const T: TEntryTemplate; const AValues: TStringArray; const AHolder: string);
var
  i, f: Integer;
  key: string;
begin
  for i := 0 to High(FChecks) do
  begin
    f := FChecks[i].Field;
    if f > High(AValues) then Continue;
    key := ValueKey(FChecks[i].Kind, FChecks[i].Attr, AValues[f]);
    if key <> '' then FReserved.TryAdd(key, AHolder);
  end;
  key := PersonKey(T, AValues);
  if key <> '' then FReservedPersons.TryAdd(key, AHolder);
end;

procedure TUniqueScan.ClearReserved;
begin
  FReserved.Clear;
  FReservedPersons.Clear;
end;

function UniqueSearchRequest(AProfile: TConnectionProfile; const ABase: string;
  AScan: TUniqueScan): TSearchRequest;
begin
  Result := DefaultSearchRequest;
  Result.BaseDn := ABase;
  Result.Scope := ssSubtree;
  Result.Filter := AScan.Filter;
  Result.Attributes := AScan.Attributes;
  Result.SizeLimit := 0;
  Result.TimeLimitSec := 0;
  Result.PageSize := AProfile.PageSize;
end;

function ForestDomainsRequest(AProfile: TConnectionProfile; const AConfigNc: string): TSearchRequest;
begin
  Result := DefaultSearchRequest;
  Result.BaseDn := 'CN=Partitions,' + AConfigNc;
  Result.Scope := ssOneLevel;
  // FLAG_CR_NTDS_DOMAIN: les domaines, pas les zones DNS
  Result.Filter := '(&(objectClass=crossRef)(systemFlags:1.2.840.113556.1.4.803:=2))';
  Result.Attributes := ['nCName'];
  Result.SizeLimit := 0;
  Result.PageSize := AProfile.PageSize;
end;

end.
