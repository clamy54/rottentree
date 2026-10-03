// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uEntryLookup;

{$mode objfpc}{$H+}

// Recherche d'une entree depuis un bout de nom, d'uid, de mail ou un "attr=valeur", facon
// selecteur Windows. Sur AD: ANR par debut de valeur d'abord, puis n'importe ou dans la
// valeur, sans index, en completement. '*' saisi reste un joker; tout le reste est
// echappe, le filtre n'est pas un terrain de jeu.

interface

uses
  SysUtils, uSearchModel, uConnectionProfile;

const
  LOOKUP_LIMIT = 200;
  // La recherche n'importe ou ne sert aucun index et parcourt tout le domaine: jamais
  // sous cette longueur, sinon chaque lettre tapee lance un scan complet et le DC s'en
  // souvient.
  LOOKUP_ANYWHERE_MIN = 3;
  LOOKUP_ANYWHERE_TIME_SEC = 10;

function EntryLookupFilter(const AText: string; AServer: TProviderKind;
  AAnywhere: Boolean = False): string;
function EntryLookupWidens(const AText: string; AServer: TProviderKind): Boolean;
function EntryLookupRequest(const ABase, AText: string; AServer: TProviderKind;
  const AAttrs: array of string; ALimit: Integer; AAnywhere: Boolean = False): TSearchRequest;

implementation

uses
  uLdapFilter;

const
  LOOKUP_ATTRS: array[0..6] of string = ('cn', 'uid', 'sn', 'givenName', 'displayName', 'mail', 'ou');
  // AD: ANR couvre deja displayName, givenName, sn, sAMAccountName et le RDN.
  LOOKUP_AD_ATTRS: array[0..4] of string = ('cn', 'sAMAccountName', 'userPrincipalName',
    'displayName', 'mail');
  LOOKUP_AD_ANYWHERE_ATTRS: array[0..6] of string = ('cn', 'sAMAccountName', 'userPrincipalName',
    'displayName', 'mail', 'givenName', 'sn');

function IsAttrDescr(const S: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if S = '' then Exit;
  if S[1] in ['A'..'Z', 'a'..'z'] then
  begin
    for i := 2 to Length(S) do
      if not (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '-']) then Exit;
    Exit(True);
  end;
  for i := 1 to Length(S) do
    if not (S[i] in ['0'..'9', '.']) then Exit;
  Result := (S[1] <> '.') and (S[Length(S)] <> '.');
end;

function HexVal(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function FirstRdnValue(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = '\' then
    begin
      if (i + 2 <= Length(S)) and (HexVal(S[i + 1]) >= 0) and (HexVal(S[i + 2]) >= 0) then
      begin
        Result := Result + Chr(HexVal(S[i + 1]) * 16 + HexVal(S[i + 2]));
        Inc(i, 3);
        Continue;
      end;
      if i + 1 <= Length(S) then Result := Result + S[i + 1];
      Inc(i, 2);
      Continue;
    end;
    if S[i] in [',', '+'] then Break;
    Result := Result + S[i];
    Inc(i);
  end;
end;

function Contains(const AAttr, AValue: string; APrefix: Boolean = False): string;
var
  parts: TStringArray;
  i: Integer;
begin
  if APrefix and not AValue.StartsWith('*') then Result := '(' + AAttr + '='
  else Result := '(' + AAttr + '=*';
  parts := AValue.Split(['*']);
  for i := 0 to High(parts) do
    if parts[i] <> '' then Result := Result + FilterEscapeValue(parts[i]) + '*';
  Result := Result + ')';
end;

function EntryLookupFilter(const AText: string; AServer: TProviderKind; AAnywhere: Boolean): string;
var
  t, attr: string;
  p, i: Integer;
begin
  Result := '';
  t := Trim(AText);
  if t = '' then Exit;
  p := Pos('=', t);
  if p > 1 then
  begin
    attr := Trim(Copy(t, 1, p - 1));
    if IsAttrDescr(attr) then
      Exit(Contains(attr, Trim(FirstRdnValue(Copy(t, p + 1, MaxInt))),
        (AServer = pkActiveDirectory) and not AAnywhere));
  end;
  Result := '(|';
  if (AServer = pkActiveDirectory) and AAnywhere then
  begin
    for i := 0 to High(LOOKUP_AD_ANYWHERE_ATTRS) do
      Result := Result + Contains(LOOKUP_AD_ANYWHERE_ATTRS[i], t);
  end
  else if AServer = pkActiveDirectory then
  begin
    for i := 0 to High(LOOKUP_AD_ATTRS) do
      Result := Result + Contains(LOOKUP_AD_ATTRS[i], t, True);
    if Pos('*', t) = 0 then Result := Result + '(anr=' + FilterEscapeValue(t) + ')';
  end
  else
    for i := 0 to High(LOOKUP_ATTRS) do
      Result := Result + Contains(LOOKUP_ATTRS[i], t);
  Result := Result + ')';
end;

function EntryLookupWidens(const AText: string; AServer: TProviderKind): Boolean;
begin
  // Le seuil compte des caracteres, pas des octets UTF-8: une lettre accentuee n'a pas a
  // passer pour trois.
  Result := (AServer = pkActiveDirectory) and
    (Length(UTF8Decode(Trim(AText))) >= LOOKUP_ANYWHERE_MIN) and
    (Pos('*', AText) = 0);
end;

function EntryLookupRequest(const ABase, AText: string; AServer: TProviderKind;
  const AAttrs: array of string; ALimit: Integer; AAnywhere: Boolean): TSearchRequest;
var
  i: Integer;
begin
  Result := DefaultSearchRequest;
  Result.BaseDn := ABase;
  Result.Scope := ssSubtree;
  Result.Filter := EntryLookupFilter(AText, AServer, AAnywhere);
  SetLength(Result.Attributes, Length(AAttrs));
  for i := 0 to High(AAttrs) do
    Result.Attributes[i] := AAttrs[i];
  Result.SizeLimit := ALimit;
  Result.ServerSizeLimit := ALimit;
end;

end.
