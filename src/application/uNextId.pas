// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uNextId;

{$mode objfpc}{$H+}

// Prochain uidNumber ou gidNumber libre: plus grande valeur de l'annuaire + 1. LDAP n'a pas
// d'agregat, donc on lit tout le contexte; une enumeration incomplete ne donne rien plutot qu'un
// numero deja pris. Aucune reservation: deux admins rapides peuvent tomber sur le meme, le serveur
// arbitrera.

interface

uses
  SysUtils, Classes, uLdapEntry, uSearchModel, uConnectionProfile, uLdapDn, uLdapSchema;

const
  NEXT_ID_FIRST = 1000;
  // (uid_t)-2 et -1 sont reserves.
  NEXT_ID_LAST = 4294967293;
  // Valeurs gardees par une recherche de numero libre. Au-dela, aucun numero n'est propose: un
  // annuaire qui rend plus de deux millions de uidNumber n'est pas un annuaire, c'est une attaque.
  NEXT_ID_SCAN_MAX = 2000000;

type
  TNextIdScan = class
  private
    FAttr: string;
    FMax: Int64;
    FFound: Integer;
    FIgnored: Integer;
  public
    constructor Create(const AAttr: string);
    procedure Feed(AEntry: TLdapEntry);
    function NextId: Int64;
    function HighestText: string;
    property Attr: string read FAttr;
    property Found: Integer read FFound;
    property Ignored: Integer read FIgnored;
  end;

  TInt64Array = array of Int64;

  // Numero libre pour un attribut entier quelconque, dans une plage: apres le plus grand, ou le
  // premier trou. Reprendre un trou, c'est parfois heriter des fichiers d'un compte supprime.
  TFreeNumberScan = class
  private
    FAttr: string;
    FFirstFree: Boolean;
    FPosix: Boolean;
    FLow, FHigh: Int64;
    FUsed: array of Int64;
    FCount: Integer;
    FIgnored: Integer;
    FSorted, FOverflow: Boolean;
    FNames: TStringArray;
    procedure Sort(ALo, AHi: Integer);
    procedure Add(AValue: Int64);
    procedure EnsureSorted;
    function Collect(ACount: Integer): TInt64Array;
  public
    // ASchema: l'attribut est ramene a son nom principal, et reconnu sous tous ses noms et son OID.
    constructor Create(const AAttr: string; AFirstFree, AHasMin, AHasMax: Boolean;
      AMin, AMax: Int64; AKind: TProviderKind = pkAuto; ASchema: TSchemaSnapshot = nil);
    procedure Feed(AEntry: TLdapEntry);
    function Pick(out AValue: Int64): Boolean;
    // Un numero par entree d'un lot, tous distincts; moins que demande si la plage s'epuise.
    function PickMany(ACount: Integer): TInt64Array;
    // Numeros apportes par le lot lui-meme: pris, on ne les redonne pas.
    procedure Reserve(const AValues: array of Int64);
    function UsedValues: TInt64Array;
    property Attr: string read FAttr;
    property Found: Integer read FCount;
    property Ignored: Integer read FIgnored;
    property RangeLow: Int64 read FLow;
    property RangeHigh: Int64 read FHigh;
    // Trop de valeurs recues: le resultat ne vaut rien, Pick et PickMany ne rendent rien.
    property Overflow: Boolean read FOverflow;
  end;

// Nom principal selon le schema, sinon le nom de base tel quel: "1.3.6.1.1.1.1.0" est uidNumber,
// et merite le meme traitement.
function CanonicalIdAttr(ASchema: TSchemaSnapshot; const AAttr: string): string;
// Active Directory traine aussi l'ancien schema SFU (msSFU30UidNumber, msSFU30GidNumber).
function IsNextIdAttribute(const AAttr: string; AKind: TProviderKind = pkAuto;
  ASchema: TSchemaSnapshot = nil): Boolean;
function IsReservedId(AValue: Int64): Boolean;
function NextIdSearchBase(const AEntryDn: string; const ANamingContexts,
  ABaseDns: array of string): string;
function NextIdSearchRequest(AProfile: TConnectionProfile; const ABase, AAttr: string): TSearchRequest;

implementation

function BaseName(const AAttr: string): string;
var
  p: Integer;
begin
  p := Pos(';', AAttr);
  if p > 0 then Result := Copy(AAttr, 1, p - 1) else Result := AAttr;
end;

function CanonicalIdAttr(ASchema: TSchemaSnapshot; const AAttr: string): string;
var
  at: TSchemaAttributeType;
begin
  Result := BaseName(AAttr);
  if ASchema = nil then Exit;
  at := ASchema.AttributeType(Result);
  if at <> nil then Result := at.PrimaryName;
end;

function IsNextIdAttribute(const AAttr: string; AKind: TProviderKind; ASchema: TSchemaSnapshot): Boolean;
var
  a: string;
begin
  a := CanonicalIdAttr(ASchema, AAttr);
  Result := SameText(a, 'uidNumber') or SameText(a, 'gidNumber') or
    ((AKind = pkActiveDirectory) and (SameText(a, 'msSFU30UidNumber') or SameText(a, 'msSFU30GidNumber')));
end;

function IsReservedId(AValue: Int64): Boolean;
begin
  // nobody/nogroup (65534), 65535, (uid_t)-1 et -2 ne sont pas des attributions et bloqueraient la
  // suite. Au-dela de 32 bits ou negatif, ce n'est pas un identifiant POSIX.
  Result := (AValue = 65534) or (AValue = 65535) or (AValue = 4294967294) or
    (AValue = 4294967295) or (AValue < 0) or (AValue > 4294967295);
end;

constructor TNextIdScan.Create(const AAttr: string);
begin
  inherited Create;
  FAttr := BaseName(AAttr);
  FMax := -1;
end;

procedure TNextIdScan.Feed(AEntry: TLdapEntry);
var
  a: TLdapAttribute;
  i: Integer;
  v: Int64;
begin
  if AEntry = nil then Exit;
  a := AEntry.Find(FAttr);
  if a = nil then Exit;
  for i := 0 to a.ValueCount - 1 do
    if TryStrToInt64(Trim(string(a.Values[i])), v) and not IsReservedId(v) then
    begin
      Inc(FFound);
      if v > FMax then FMax := v;
    end
    else
      Inc(FIgnored);
end;

function TNextIdScan.NextId: Int64;
begin
  // Teste avant l'addition: FMax est borne, pas de debordement. Domaine epuise: aucun candidat,
  // jamais un retour au debut de la plage.
  if FMax >= NEXT_ID_LAST then Exit(0);
  Result := FMax + 1;
  if Result < NEXT_ID_FIRST then Result := NEXT_ID_FIRST;
  while IsReservedId(Result) and (Result < NEXT_ID_LAST) do Inc(Result);
  if IsReservedId(Result) then Result := 0;
end;

function TNextIdScan.HighestText: string;
begin
  if FFound = 0 then Result := '' else Result := IntToStr(FMax);
end;

constructor TFreeNumberScan.Create(const AAttr: string; AFirstFree, AHasMin, AHasMax: Boolean;
  AMin, AMax: Int64; AKind: TProviderKind; ASchema: TSchemaSnapshot);
var
  at: TSchemaAttributeType;
  i: Integer;
begin
  inherited Create;
  FAttr := CanonicalIdAttr(ASchema, AAttr);
  FNames := [AsciiLowerCase(FAttr)];
  at := nil;
  if ASchema <> nil then at := ASchema.AttributeType(FAttr);
  if at <> nil then
  begin
    // Le serveur rend l'attribut sous le nom qui lui plait: tous sont admis.
    SetLength(FNames, Length(at.Names) + 1);
    for i := 0 to High(at.Names) do FNames[i] := AsciiLowerCase(at.Names[i]);
    FNames[High(FNames)] := AsciiLowerCase(at.Oid);
  end;
  FFirstFree := AFirstFree;
  FPosix := IsNextIdAttribute(FAttr, AKind, ASchema);
  if AHasMin then FLow := AMin
  else if FPosix then FLow := NEXT_ID_FIRST
  else FLow := 1;
  if AHasMax then FHigh := AMax
  else if FPosix then FHigh := NEXT_ID_LAST
  else FHigh := System.High(Int64) - 1;
  // Un identifiant POSIX tient entre 0 et (uid_t)-3. Plage ramenee a ces bornes d'entree, sinon
  // chercher un numero libre revient a compter jusqu'a zero depuis moins neuf milliards de milliards.
  if FPosix then
  begin
    if FLow < 0 then FLow := 0;
    if FHigh > NEXT_ID_LAST then FHigh := NEXT_ID_LAST;
  end;
end;

procedure TFreeNumberScan.Feed(AEntry: TLdapEntry);
var
  a: TLdapAttribute;
  i, j, n: Integer;
  v: Int64;
  base: string;
begin
  if (AEntry = nil) or FOverflow then Exit;
  for n := 0 to AEntry.AttrCount - 1 do
  begin
    a := AEntry.Attrs[n];
    base := AsciiLowerCase(a.BaseName);
    for j := 0 to High(FNames) do
      if FNames[j] = base then
      begin
        for i := 0 to a.ValueCount - 1 do
          if TryStrToInt64(Trim(string(a.Values[i])), v) and (v >= FLow) and (v <= FHigh) then
            Add(v)
          else
            Inc(FIgnored);
        Break;
      end;
  end;
end;

procedure TFreeNumberScan.Sort(ALo, AHi: Integer);
var
  i, j: Integer;
  pivot, t: Int64;
begin
  // La plus petite moitie en recursion, l'autre en boucle: la pile reste logarithmique.
  while ALo < AHi do
  begin
    i := ALo;
    j := AHi;
    pivot := FUsed[ALo + (AHi - ALo) div 2];
    repeat
      while FUsed[i] < pivot do Inc(i);
      while FUsed[j] > pivot do Dec(j);
      if i <= j then
      begin
        t := FUsed[i];
        FUsed[i] := FUsed[j];
        FUsed[j] := t;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    if j - ALo < AHi - i then
    begin
      Sort(ALo, j);
      ALo := i;
    end
    else
    begin
      Sort(i, AHi);
      AHi := j;
    end;
  end;
end;

procedure TFreeNumberScan.Add(AValue: Int64);
begin
  if FCount >= NEXT_ID_SCAN_MAX then
  begin
    FOverflow := True;
    FUsed := nil;
    FCount := 0;
    Exit;
  end;
  if FCount = Length(FUsed) then SetLength(FUsed, FCount * 2 + 256);
  FUsed[FCount] := AValue;
  Inc(FCount);
  FSorted := False;
end;

procedure TFreeNumberScan.EnsureSorted;
begin
  if FSorted then Exit;
  Sort(0, FCount - 1);
  FSorted := True;
end;

// Un seul tri, un seul parcours: distribuer mille numeros ne coute pas mille tris.
function TFreeNumberScan.Collect(ACount: Integer): TInt64Array;
var
  c: Int64;
  i, n: Integer;
begin
  Result := nil;
  if (ACount <= 0) or (FLow > FHigh) or FOverflow then Exit;
  EnsureSorted;
  i := 0;
  c := FLow;
  if not FFirstFree and (FCount > 0) then
  begin
    if FUsed[FCount - 1] >= FHigh then Exit;
    c := FUsed[FCount - 1] + 1;
    i := FCount;
  end;
  SetLength(Result, ACount);
  n := 0;
  while n < ACount do
  begin
    while FPosix and IsReservedId(c) and (c < FHigh) do Inc(c);
    if (c > FHigh) or (FPosix and IsReservedId(c)) then Break;
    while (i < FCount) and (FUsed[i] < c) do Inc(i);
    if (i < FCount) and (FUsed[i] = c) then
    begin
      if c >= FHigh then Break;
      Inc(c);
      Continue;
    end;
    Result[n] := c;
    Inc(n);
    if c >= FHigh then Break;
    Inc(c);
  end;
  SetLength(Result, n);
end;

function TFreeNumberScan.Pick(out AValue: Int64): Boolean;
var
  one: TInt64Array;
begin
  one := Collect(1);
  Result := Length(one) = 1;
  if Result then AValue := one[0] else AValue := 0;
end;

procedure TFreeNumberScan.Reserve(const AValues: array of Int64);
var
  i: Integer;
begin
  for i := 0 to High(AValues) do
    if (AValues[i] >= FLow) and (AValues[i] <= FHigh) then Add(AValues[i]);
end;

function TFreeNumberScan.UsedValues: TInt64Array;
begin
  EnsureSorted;
  Result := Copy(FUsed, 0, FCount);
end;

function TFreeNumberScan.PickMany(ACount: Integer): TInt64Array;
var
  i: Integer;
begin
  Result := Collect(ACount);
  // Les numeros pris rejoignent les occupes: l'appel suivant ne retombe pas dessus.
  for i := 0 to High(Result) do
    Add(Result[i]);
end;

function NextIdSearchBase(const AEntryDn: string; const ANamingContexts,
  ABaseDns: array of string): string;

  function Widest(const ACandidates: array of string; const AEntry: TLdapDn;
    ACmp: TDnComparer): string;
  var
    i, best: Integer;
    d: TLdapDn;
  begin
    Result := '';
    best := MaxInt;
    for i := 0 to High(ACandidates) do
    begin
      if Trim(ACandidates[i]) = '' then Continue;
      if not DnTryParse(ACandidates[i], d) then Continue;
      if (ACmp.IsUnder(AEntry, d, True) = dmEqual) and (DnRdnCount(d) < best) then
      begin
        best := DnRdnCount(d);
        Result := ACandidates[i];
      end;
    end;
  end;

var
  e: TLdapDn;
  cmp: TDnComparer;
begin
  Result := '';
  if not DnTryParse(AEntryDn, e) then Exit;
  cmp := TDnComparer.Create;
  try
    Result := Widest(ANamingContexts, e, cmp);
    if Result = '' then Result := Widest(ABaseDns, e, cmp);
  finally
    cmp.Free;
  end;
end;

function NextIdSearchRequest(AProfile: TConnectionProfile; const ABase, AAttr: string): TSearchRequest;
begin
  Result := DefaultSearchRequest;
  Result.BaseDn := ABase;
  Result.Scope := ssSubtree;
  Result.Filter := '(' + BaseName(AAttr) + '=*)';
  Result.Attributes := [BaseName(AAttr)];
  // Aucune limite: un maximum pris sur une enumeration tronquee proposerait un numero deja
  // attribue.
  Result.SizeLimit := 0;
  Result.TimeLimitSec := 0;
  Result.PageSize := AProfile.PageSize;
end;

end.
