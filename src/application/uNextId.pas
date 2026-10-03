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
  SysUtils, Classes, uLdapEntry, uSearchModel, uConnectionProfile, uLdapDn;

const
  NEXT_ID_FIRST = 1000;
  // (uid_t)-2 et -1 sont reserves.
  NEXT_ID_LAST = 4294967293;

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

// Active Directory traine aussi l'ancien schema SFU (msSFU30UidNumber, msSFU30GidNumber).
function IsNextIdAttribute(const AAttr: string; AKind: TProviderKind = pkAuto): Boolean;
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

function IsNextIdAttribute(const AAttr: string; AKind: TProviderKind): Boolean;
begin
  Result := SameText(BaseName(AAttr), 'uidNumber') or SameText(BaseName(AAttr), 'gidNumber') or
    ((AKind = pkActiveDirectory) and (SameText(BaseName(AAttr), 'msSFU30UidNumber') or
      SameText(BaseName(AAttr), 'msSFU30GidNumber')));
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
