// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uUniqueCheck;

{$mode objfpc}{$H+}

// Unicite d'un identifiant de compte: les autres entrees du contexte qui portent la meme valeur,
// selon la regle d'egalite du serveur, jamais une comparaison locale. gidNumber ne se verifie
// qu'entre groupes, un compte partage celui de son groupe principal. Sur AD, un mail est aussi
// cherche dans proxyAddresses, ou Exchange le tient deja pour pris.

interface

uses
  SysUtils, Classes, uLdapEntry, uSearchModel, uConnectionProfile;

const
  UNIQUE_MAX_LISTED = 20;

type
  TUniqueCheck = class
  private
    FAttr: string;
    FValue: RawByteString;
    FSelfDn: string;
    FOthers: TStringList;
    FOtherCount: Integer;
  public
    constructor Create(const AAttr: string; const AValue: RawByteString; const ASelfDn: string);
    destructor Destroy; override;
    procedure Feed(AEntry: TLdapEntry);
    property Attr: string read FAttr;
    property Value: RawByteString read FValue;
    property Others: TStringList read FOthers;
    property OtherCount: Integer read FOtherCount;
  end;

function EntryIsGroup(AEntry: TLdapEntry; AKind: TProviderKind): Boolean;
function IsUniqueCheckAttribute(const AAttr: string; AKind: TProviderKind; AIsGroup: Boolean): Boolean;
function UniqueCheckFilter(const AAttr: string; const AValue: RawByteString; AKind: TProviderKind;
  AIsGroup: Boolean): string;
function UniqueCheckRequest(AProfile: TConnectionProfile; const ABase, AFilter: string): TSearchRequest;

implementation

uses
  uLdapFilter, uDirectoryService;

function BaseName(const AAttr: string): string;
var
  p: Integer;
begin
  p := Pos(';', AAttr);
  if p > 0 then Result := Copy(AAttr, 1, p - 1) else Result := AAttr;
end;

function IsOneOf(const AAttr: string; const ANames: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(ANames) do
    if SameText(BaseName(AAttr), ANames[i]) then Exit(True);
  Result := False;
end;

function IsGidAttribute(const AAttr: string): Boolean;
begin
  Result := IsOneOf(AAttr, ['gidNumber', 'msSFU30GidNumber']);
end;

constructor TUniqueCheck.Create(const AAttr: string; const AValue: RawByteString; const ASelfDn: string);
begin
  inherited Create;
  FAttr := BaseName(AAttr);
  FValue := AValue;
  FSelfDn := ASelfDn;
  FOthers := TStringList.Create;
end;

destructor TUniqueCheck.Destroy;
begin
  FOthers.Free;
  inherited Destroy;
end;

procedure TUniqueCheck.Feed(AEntry: TLdapEntry);
begin
  if (AEntry = nil) or SameDnStrict(AEntry.Dn, FSelfDn) then Exit;
  Inc(FOtherCount);
  if FOthers.Count < UNIQUE_MAX_LISTED then FOthers.Add(AEntry.Dn);
end;

function EntryIsGroup(AEntry: TLdapEntry; AKind: TProviderKind): Boolean;
var
  oc: TLdapAttribute;
  i: Integer;
begin
  Result := False;
  if AEntry = nil then Exit;
  oc := AEntry.Find('objectClass');
  if oc = nil then Exit;
  for i := 0 to oc.ValueCount - 1 do
    if SameText(string(oc.Values[i]), 'posixGroup') or
       ((AKind = pkActiveDirectory) and SameText(string(oc.Values[i]), 'group')) then
      Exit(True);
end;

function IsUniqueCheckAttribute(const AAttr: string; AKind: TProviderKind; AIsGroup: Boolean): Boolean;
begin
  if IsGidAttribute(AAttr) then
    Exit(AIsGroup and ((AKind = pkActiveDirectory) or SameText(BaseName(AAttr), 'gidNumber')));
  if AKind = pkActiveDirectory then
    Result := IsOneOf(AAttr, ['sAMAccountName', 'userPrincipalName', 'mail', 'uid', 'uidNumber',
      'msSFU30UidNumber'])
  else
    // 389 DS / FreeIPA: le principal Kerberos en plus.
    Result := IsOneOf(AAttr, ['uid', 'mail', 'uidNumber', 'krbPrincipalName']);
end;

function UniqueCheckFilter(const AAttr: string; const AValue: RawByteString; AKind: TProviderKind;
  AIsGroup: Boolean): string;
var
  v: string;
begin
  v := FilterEscapeValue(AValue);
  Result := '(' + BaseName(AAttr) + '=' + v + ')';
  if (AKind = pkActiveDirectory) and SameText(BaseName(AAttr), 'mail') then
    Result := '(|' + Result + '(proxyAddresses=smtp:' + v + '))'
  else if IsGidAttribute(AAttr) and AIsGroup then
  begin
    if AKind = pkActiveDirectory then
      Result := '(&(objectClass=group)' + Result + ')'
    else
      Result := '(&(objectClass=posixGroup)' + Result + ')';
  end;
end;

function UniqueCheckRequest(AProfile: TConnectionProfile; const ABase, AFilter: string): TSearchRequest;
begin
  Result := DefaultSearchRequest;
  Result.BaseDn := ABase;
  Result.Scope := ssSubtree;
  Result.Filter := AFilter;
  // DN seuls ('1.1') et aucune limite: une enumeration tronquee sans doublon ne prouverait rien.
  Result.Attributes := ['1.1'];
  Result.SizeLimit := 0;
  Result.TimeLimitSec := 0;
  Result.PageSize := AProfile.PageSize;
end;

end.
