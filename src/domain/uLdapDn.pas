// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdapDn;

{$mode objfpc}{$H+}

// DN RFC 4514: analyse, serialisation, comparaison, remplacement de suffixe.
// Jamais de LowerCase ni de decoupe sur les virgules: le premier "Dupont\, Jean"
// ou RDN multivalue transforme ce raccourci en suppression au mauvais endroit.

interface

uses
  SysUtils;

const
  DN_MAX_RDNS = 256;
  DN_MAX_AVAS_PER_RDN = 32;
  DN_MAX_CHARS = 64 * 1024;

type
  TDnAva = record
    AttrType: string;
    Value: RawByteString;
    HexForm: Boolean;
  end;
  TDnAvaArray = array of TDnAva;

  TDnRdn = record
    Avas: TDnAvaArray;
  end;
  TDnRdnArray = array of TDnRdn;

  TLdapDn = record
    Rdns: TDnRdnArray;
  end;

  TDnMatch = (dmEqual, dmDifferent, dmUndetermined);

  TDnValueMatcher = function(const AType: string; const A, B: RawByteString): TDnMatch
    of object;
  TDnTypeCanon = function(const AType: string): string of object;
  // Ce que la regle d'egalite d'un attribut fait des valeurs: tout compte, les espaces de bord et
  // les doublons d'espaces ne comptent pas (caseExactMatch), ni la casse (caseIgnoreMatch).
  TDnValueFold = (dfExact, dfCaseExact, dfCaseIgnore);
  TDnFoldProbe = function(const AType: string): TDnValueFold of object;

  TDnParseMode = (
    dpmStrict,
    dpmLenient
  );

  TDnComparer = class
  private
    FMatcher: TDnValueMatcher;
    FTypeCanon: TDnTypeCanon;
    function DefaultMatcher(const AType: string; const A, B: RawByteString): TDnMatch;
  public
    constructor Create;
    property Matcher: TDnValueMatcher read FMatcher write FMatcher;
    property TypeCanon: TDnTypeCanon read FTypeCanon write FTypeCanon;
    function CanonType(const AType: string): string;
    function CompareAva(const A, B: TDnAva): TDnMatch;
    function CompareRdn(const A, B: TDnRdn): TDnMatch;
    function CompareDn(const A, B: TLdapDn): TDnMatch;
    function IsUnder(const ADn, ABase: TLdapDn; AAllowEqual: Boolean): TDnMatch;
  end;

// "DC=Base" et "dc=base" designent la meme entree, quoi qu'en pense memcmp.
function CaseIgnoreDnComparer: TDnComparer;

function DnParse(const S: string; out ADn: TLdapDn; out AError: string;
  AMode: TDnParseMode = dpmLenient): Boolean;
function DnTryParse(const S: string; out ADn: TLdapDn): Boolean;
function DnToString(const ADn: TLdapDn): string;
function RdnToString(const ARdn: TDnRdn): string;
function DnEscapeValue(const AValue: RawByteString): string;

function DnIsEmpty(const ADn: TLdapDn): Boolean;
function DnRdnCount(const ADn: TLdapDn): Integer;
function DnParent(const ADn: TLdapDn): TLdapDn;
function DnLeaf(const ADn: TLdapDn): TDnRdn;
function DnChild(const ABase: TLdapDn; const ARdn: TDnRdn): TLdapDn;
function DnMakeRdn(const AType: string; const AValue: RawByteString): TDnRdn;
function DnRelative(const ADn: TLdapDn; ABaseRdnCount: Integer): TLdapDn;
function DnConcat(const ARelative, ABase: TLdapDn): TLdapDn;

// Comparaison indeterminee = pas de remplacement. Deviner un suffixe, c'est
// deplacer une branche dans un endroit que personne ne retrouvera.
function DnReplaceSuffix(AComparer: TDnComparer; const ADn, AOld, ANew: TLdapDn;
  out AResult: TLdapDn): Boolean;

function DnStrictKey(AComparer: TDnComparer; const ADn: TLdapDn): string;

// Garde les DN qui ne sont sous aucun autre, dans l'ordre. Sans AFold, comparaison a l'octet:
// mieux vaut ne pas elaguer que confondre.
function DnOutermost(const ADns: array of string; AFold: TDnFoldProbe = nil;
  ACanon: TDnTypeCanon = nil): TStringArray;
// Cle d'identite d'un DN: decode, puis regle d'egalite de chaque attribut (AFold), types ramenes
// a leur nom (ACanon). "cn=\41" et "cn=a" ont la meme si cn ignore la casse.
function DnFoldKey(const ADn: string; AFold: TDnFoldProbe = nil; ACanon: TDnTypeCanon = nil): string;
// Espaces de bord retires, suites d'espaces reduites a une seule (RFC 4518).
function SqueezeSpaces(const S: RawByteString): RawByteString;

function IsNumericOid(const S: string): Boolean;
function IsDescr(const S: string): Boolean;

implementation

uses
  Generics.Collections, uRtBytes;

function IsAlpha(C: Char): Boolean; inline;
begin
  Result := C in ['A'..'Z', 'a'..'z'];
end;

function IsDigit(C: Char): Boolean; inline;
begin
  Result := C in ['0'..'9'];
end;

function IsHexChar(C: Char): Boolean; inline;
begin
  Result := C in ['0'..'9', 'a'..'f', 'A'..'F'];
end;

function HexVal(C: Char): Byte; inline;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
  else
    Result := Ord(C) - Ord('A') + 10;
  end;
end;

function AsciiLower(const S: string): string;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then
      Result[i] := Chr(Ord(Result[i]) + 32);
end;

function IsNumericOid(const S: string): Boolean;
var
  i, start: Integer;
  dots: Integer;
begin
  Result := False;
  if S = '' then Exit;
  dots := 0;
  start := 1;
  for i := 1 to Length(S) + 1 do
  begin
    if (i > Length(S)) or (S[i] = '.') then
    begin
      if i = start then Exit;
      if (S[start] = '0') and (i - start > 1) then Exit;
      if i <= Length(S) then Inc(dots);
      start := i + 1;
    end
    else if not IsDigit(S[i]) then
      Exit;
  end;
  Result := dots >= 1;
end;

function IsDescr(const S: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (S = '') or not IsAlpha(S[1]) then Exit;
  for i := 2 to Length(S) do
    if not (IsAlpha(S[i]) or IsDigit(S[i]) or (S[i] = '-')) then Exit;
  Result := True;
end;

// "OID.1.2.3": forme d'anciens serveurs qu'on croise encore dans des exports
// qui ont survecu a trois migrations. Normalisee sans prefixe.
function NormalizeTypeSyntax(const S: string; out AType: string): Boolean;
begin
  AType := S;
  if (Length(S) > 4) and SameText(Copy(S, 1, 4), 'oid.') and
     IsNumericOid(Copy(S, 5, MaxInt)) then
    AType := Copy(S, 5, MaxInt);
  Result := IsDescr(AType) or IsNumericOid(AType);
end;

function DnParse(const S: string; out ADn: TLdapDn; out AError: string;
  AMode: TDnParseMode): Boolean;
var
  p, n: Integer;

  procedure SkipSpaces;
  begin
    if AMode = dpmLenient then
      while (p <= n) and (S[p] = ' ') do Inc(p);
  end;

  function Fail(const AMsg: string): Boolean;
  begin
    AError := Format('%s (position %d)', [AMsg, p]);
    ADn.Rdns := nil;
    Result := False;
  end;

  function ParseType(out AType: string): Boolean;
  var
    start: Integer;
  begin
    start := p;
    while (p <= n) and (IsAlpha(S[p]) or IsDigit(S[p]) or (S[p] in ['-', '.'])) do
      Inc(p);
    Result := NormalizeTypeSyntax(Copy(S, start, p - start), AType);
  end;

  function ParseValue(out AValue: RawByteString; out AHex: Boolean;
    out AErr: string): Boolean;
  var
    b: Byte;
    lastEscapedLen, trimTo: Integer;
    c: Char;
  begin
    Result := False;
    AValue := '';
    AHex := False;
    AErr := '';
    if (p <= n) and (S[p] = '#') then
    begin
      AHex := True;
      Inc(p);
      while (p + 1 <= n) and IsHexChar(S[p]) and IsHexChar(S[p + 1]) do
      begin
        AValue := AValue + Char((HexVal(S[p]) shl 4) or HexVal(S[p + 1]));
        Inc(p, 2);
      end;
      if AValue = '' then
      begin
        AErr := 'empty or invalid hexadecimal value';
        Exit;
      end;
      if (p <= n) and not (S[p] in [',', '+', ';', ' ']) then
      begin
        AErr := 'invalid character after hexadecimal value';
        Exit;
      end;
      Exit(True);
    end;
    // Un blanc final echappe ("cn=x\ ") fait partie de la valeur; les suivants non.
    // Les confondre, c'est creer le jumeau invisible d'une entree.
    lastEscapedLen := 0;
    while p <= n do
    begin
      c := S[p];
      if c = '\' then
      begin
        if p + 1 > n then
        begin
          AErr := 'dangling escape';
          Exit;
        end;
        if IsHexChar(S[p + 1]) then
        begin
          if (p + 2 > n) or not IsHexChar(S[p + 2]) then
          begin
            AErr := 'invalid hexadecimal escape';
            Exit;
          end;
          b := (HexVal(S[p + 1]) shl 4) or HexVal(S[p + 2]);
          AValue := AValue + Char(b);
          Inc(p, 3);
        end
        else if S[p + 1] in ['"', '+', ',', ';', '<', '>', '\', ' ', '#', '='] then
        begin
          AValue := AValue + S[p + 1];
          Inc(p, 2);
        end
        else
        begin
          AErr := 'invalid escape sequence';
          Exit;
        end;
        lastEscapedLen := Length(AValue);
        Continue;
      end;
      if c in [',', '+', ';'] then Break;
      if c in ['"', '<', '>', #0] then
      begin
        AErr := 'character must be escaped';
        Exit;
      end;
      if (Length(AValue) = 0) and (c = '#') then
      begin
        AErr := 'leading # must be escaped';
        Exit;
      end;
      if (Length(AValue) = 0) and (c = ' ') and (AMode = dpmStrict) then
      begin
        AErr := 'leading space must be escaped';
        Exit;
      end;
      if (Length(AValue) = 0) and (c = ' ') then
      begin
        Inc(p);
        Continue;
      end;
      AValue := AValue + c;
      Inc(p);
    end;
    trimTo := Length(AValue);
    while (trimTo > lastEscapedLen) and (AValue[trimTo] = ' ') do
      Dec(trimTo);
    if trimTo < Length(AValue) then
    begin
      if AMode = dpmStrict then
      begin
        AErr := 'trailing space must be escaped';
        Exit;
      end;
      SetLength(AValue, trimTo);
    end;
    if not IsValidUtf8(AValue) then
    begin
      AErr := 'value is not valid UTF-8';
      Exit;
    end;
    Result := True;
  end;

var
  rdn: TDnRdn;
  ava: TDnAva;
  err: string;
  c: Char;
begin
  ADn.Rdns := nil;
  AError := '';
  n := Length(S);
  if n > DN_MAX_CHARS then
  begin
    AError := 'DN too long';
    Exit(False);
  end;
  p := 1;
  SkipSpaces;
  if p > n then Exit(True);
  while True do
  begin
    rdn.Avas := nil;
    while True do
    begin
      SkipSpaces;
      if not ParseType(ava.AttrType) then
        Exit(Fail('invalid attribute type'));
      SkipSpaces;
      if (p > n) or (S[p] <> '=') then
        Exit(Fail('"=" expected'));
      Inc(p);
      SkipSpaces;
      if not ParseValue(ava.Value, ava.HexForm, err) then
        Exit(Fail(err));
      if Length(rdn.Avas) >= DN_MAX_AVAS_PER_RDN then
        Exit(Fail('too many values in a RDN'));
      SetLength(rdn.Avas, Length(rdn.Avas) + 1);
      rdn.Avas[High(rdn.Avas)] := ava;
      SkipSpaces;
      if (p <= n) and (S[p] = '+') then
      begin
        Inc(p);
        Continue;
      end;
      Break;
    end;
    if Length(ADn.Rdns) >= DN_MAX_RDNS then
      Exit(Fail('too many RDNs'));
    SetLength(ADn.Rdns, Length(ADn.Rdns) + 1);
    ADn.Rdns[High(ADn.Rdns)] := rdn;
    if p > n then Break;
    c := S[p];
    if (c = ',') or ((c = ';') and (AMode = dpmLenient)) then
    begin
      Inc(p);
      SkipSpaces;
      if p > n then
        Exit(Fail('RDN expected after separator'));
      Continue;
    end;
    Exit(Fail('separator expected'));
  end;
  Result := True;
end;

function DnTryParse(const S: string; out ADn: TLdapDn): Boolean;
var
  err: string;
begin
  Result := DnParse(S, ADn, err, dpmLenient);
end;

function DnEscapeValue(const AValue: RawByteString): string;
var
  i, n: Integer;
  c: Char;
  utf8: Boolean;
begin
  Result := '';
  n := Length(AValue);
  utf8 := IsValidUtf8(AValue);
  for i := 1 to n do
  begin
    c := AValue[i];
    if (not utf8) and (Byte(c) >= $80) then
      Result := Result + '\' + HexEncode(c)
    else if (Byte(c) < 32) or (Byte(c) = 127) then
      Result := Result + '\' + HexEncode(c)
    else if c in ['"', '+', ',', ';', '<', '>', '\'] then
      Result := Result + '\' + c
    else if (i = 1) and (c in [' ', '#']) then
      Result := Result + '\' + c
    else if (i = n) and (c = ' ') then
      Result := Result + '\' + c
    else
      Result := Result + c;
  end;
end;

function AvaToString(const A: TDnAva): string;
begin
  if A.HexForm then
    Result := A.AttrType + '=#' + HexEncode(A.Value)
  else
    Result := A.AttrType + '=' + DnEscapeValue(A.Value);
end;

function RdnToString(const ARdn: TDnRdn): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(ARdn.Avas) do
  begin
    if i > 0 then Result := Result + '+';
    Result := Result + AvaToString(ARdn.Avas[i]);
  end;
end;

function DnToString(const ADn: TLdapDn): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(ADn.Rdns) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + RdnToString(ADn.Rdns[i]);
  end;
end;

function DnIsEmpty(const ADn: TLdapDn): Boolean;
begin
  Result := Length(ADn.Rdns) = 0;
end;

function DnRdnCount(const ADn: TLdapDn): Integer;
begin
  Result := Length(ADn.Rdns);
end;

function DnParent(const ADn: TLdapDn): TLdapDn;
var
  i: Integer;
begin
  Result.Rdns := nil;
  if Length(ADn.Rdns) <= 1 then Exit;
  SetLength(Result.Rdns, Length(ADn.Rdns) - 1);
  for i := 1 to High(ADn.Rdns) do
    Result.Rdns[i - 1] := ADn.Rdns[i];
end;

function DnLeaf(const ADn: TLdapDn): TDnRdn;
begin
  if Length(ADn.Rdns) = 0 then
    Result.Avas := nil
  else
    Result := ADn.Rdns[0];
end;

function DnChild(const ABase: TLdapDn; const ARdn: TDnRdn): TLdapDn;
var
  i: Integer;
begin
  Result.Rdns := nil;
  SetLength(Result.Rdns, Length(ABase.Rdns) + 1);
  Result.Rdns[0] := ARdn;
  for i := 0 to High(ABase.Rdns) do
    Result.Rdns[i + 1] := ABase.Rdns[i];
end;

function DnMakeRdn(const AType: string; const AValue: RawByteString): TDnRdn;
begin
  Result.Avas := nil;
  SetLength(Result.Avas, 1);
  Result.Avas[0].AttrType := AType;
  Result.Avas[0].Value := AValue;
  Result.Avas[0].HexForm := False;
end;

function DnRelative(const ADn: TLdapDn; ABaseRdnCount: Integer): TLdapDn;
var
  i, keep: Integer;
begin
  Result.Rdns := nil;
  keep := Length(ADn.Rdns) - ABaseRdnCount;
  if keep <= 0 then Exit;
  SetLength(Result.Rdns, keep);
  for i := 0 to keep - 1 do
    Result.Rdns[i] := ADn.Rdns[i];
end;

function DnConcat(const ARelative, ABase: TLdapDn): TLdapDn;
var
  i: Integer;
begin
  Result.Rdns := nil;
  SetLength(Result.Rdns, Length(ARelative.Rdns) + Length(ABase.Rdns));
  for i := 0 to High(ARelative.Rdns) do
    Result.Rdns[i] := ARelative.Rdns[i];
  for i := 0 to High(ABase.Rdns) do
    Result.Rdns[Length(ARelative.Rdns) + i] := ABase.Rdns[i];
end;

constructor TDnComparer.Create;
begin
  inherited Create;
  FMatcher := @DefaultMatcher;
  FTypeCanon := nil;
end;

function TDnComparer.DefaultMatcher(const AType: string;
  const A, B: RawByteString): TDnMatch;
begin
  if A = B then
    Result := dmEqual
  else
    Result := dmDifferent;
end;

function TDnComparer.CanonType(const AType: string): string;
begin
  Result := '';
  if Assigned(FTypeCanon) then
    Result := FTypeCanon(AType);
  if Result = '' then
    Result := AsciiLower(AType);
end;

function TDnComparer.CompareAva(const A, B: TDnAva): TDnMatch;
var
  ta, tb: string;
begin
  ta := CanonType(A.AttrType);
  tb := CanonType(B.AttrType);
  if ta <> tb then
  begin
    // Sans schema, "cn" et "2.5.4.3" ont l'air differents. Ils ne le sont pas:
    // indetermine plutot qu'un faux "different".
    if (not Assigned(FTypeCanon)) and (IsNumericOid(ta) <> IsNumericOid(tb)) then
      Exit(dmUndetermined);
    Exit(dmDifferent);
  end;
  if A.HexForm <> B.HexForm then
  begin
    if A.Value = B.Value then Exit(dmEqual);
    // BER contre texte: pas de conversion inventee
    Exit(dmUndetermined);
  end;
  if A.HexForm then
  begin
    if A.Value = B.Value then Exit(dmEqual);
    Exit(dmDifferent);
  end;
  Result := FMatcher(ta, A.Value, B.Value);
end;

function TDnComparer.CompareRdn(const A, B: TDnRdn): TDnMatch;
var
  i, j: Integer;
  used: array of Boolean;
  found, undetermined: Boolean;
  m: TDnMatch;
begin
  if Length(A.Avas) <> Length(B.Avas) then Exit(dmDifferent);
  used := nil;
  SetLength(used, Length(B.Avas));
  undetermined := False;
  for i := 0 to High(A.Avas) do
  begin
    found := False;
    for j := 0 to High(B.Avas) do
    begin
      if used[j] then Continue;
      m := CompareAva(A.Avas[i], B.Avas[j]);
      if m = dmEqual then
      begin
        used[j] := True;
        found := True;
        Break;
      end;
      if m = dmUndetermined then
        undetermined := True;
    end;
    if not found then
    begin
      if undetermined then Exit(dmUndetermined);
      Exit(dmDifferent);
    end;
  end;
  Result := dmEqual;
end;

function TDnComparer.CompareDn(const A, B: TLdapDn): TDnMatch;
var
  i: Integer;
  m: TDnMatch;
  undetermined: Boolean;
begin
  if Length(A.Rdns) <> Length(B.Rdns) then Exit(dmDifferent);
  undetermined := False;
  for i := 0 to High(A.Rdns) do
  begin
    m := CompareRdn(A.Rdns[i], B.Rdns[i]);
    if m = dmDifferent then Exit(dmDifferent);
    if m = dmUndetermined then undetermined := True;
  end;
  if undetermined then
    Result := dmUndetermined
  else
    Result := dmEqual;
end;

function TDnComparer.IsUnder(const ADn, ABase: TLdapDn; AAllowEqual: Boolean): TDnMatch;
var
  offset, i: Integer;
  m: TDnMatch;
  undetermined: Boolean;
begin
  offset := Length(ADn.Rdns) - Length(ABase.Rdns);
  if (offset < 0) or ((offset = 0) and not AAllowEqual) then Exit(dmDifferent);
  undetermined := False;
  for i := 0 to High(ABase.Rdns) do
  begin
    m := CompareRdn(ADn.Rdns[offset + i], ABase.Rdns[i]);
    if m = dmDifferent then Exit(dmDifferent);
    if m = dmUndetermined then undetermined := True;
  end;
  if undetermined then
    Result := dmUndetermined
  else
    Result := dmEqual;
end;

function DnReplaceSuffix(AComparer: TDnComparer; const ADn, AOld, ANew: TLdapDn;
  out AResult: TLdapDn): Boolean;
begin
  AResult.Rdns := nil;
  Result := AComparer.IsUnder(ADn, AOld, True) = dmEqual;
  if Result then
    AResult := DnConcat(DnRelative(ADn, Length(AOld.Rdns)), ANew);
end;

type
  TAsciiCaseIgnore = class
    function Match(const AType: string; const A, B: RawByteString): TDnMatch;
  end;

function TAsciiCaseIgnore.Match(const AType: string; const A, B: RawByteString): TDnMatch;
begin
  if LowerCase(A) = LowerCase(B) then Result := dmEqual else Result := dmDifferent;
end;

var
  GAsciiCaseIgnore: TAsciiCaseIgnore = nil;

function CaseIgnoreDnComparer: TDnComparer;
begin
  Result := TDnComparer.Create;
  Result.Matcher := @GAsciiCaseIgnore.Match;
end;

function DnStrictKey(AComparer: TDnComparer; const ADn: TLdapDn): string;
var
  i, j, k: Integer;
  parts: array of string;
  tmp, rdnKey: string;
begin
  Result := '';
  for i := 0 to High(ADn.Rdns) do
  begin
    parts := nil;
    SetLength(parts, Length(ADn.Rdns[i].Avas));
    for j := 0 to High(ADn.Rdns[i].Avas) do
    begin
      with ADn.Rdns[i].Avas[j] do
      begin
        parts[j] := AComparer.CanonType(AttrType) + '=';
        if HexForm then parts[j] := parts[j] + '#';
        parts[j] := parts[j] + HexEncode(Value);
      end;
    end;
    for j := 1 to High(parts) do
    begin
      tmp := parts[j];
      k := j - 1;
      while (k >= 0) and (parts[k] > tmp) do
      begin
        parts[k + 1] := parts[k];
        Dec(k);
      end;
      parts[k + 1] := tmp;
    end;
    rdnKey := '';
    for j := 0 to High(parts) do
    begin
      if j > 0 then rdnKey := rdnKey + '+';
      rdnKey := rdnKey + parts[j];
    end;
    if i > 0 then Result := Result + ',';
    Result := Result + rdnKey;
  end;
end;

// Cle d'un RDN, AVA tries. Une valeur BER (#04...) garde ses octets: 0x41 et 0x61 n'y sont pas
// la meme lettre.
function SqueezeSpaces(const S: RawByteString): RawByteString;
var
  i, n: Integer;
  last: Boolean;
begin
  Result := '';
  SetLength(Result, Length(S));
  n := 0;
  last := True;
  for i := 1 to Length(S) do
    if S[i] = ' ' then
    begin
      if not last then
      begin
        Inc(n);
        Result[n] := ' ';
      end;
      last := True;
    end
    else
    begin
      Inc(n);
      Result[n] := S[i];
      last := False;
    end;
  if (n > 0) and (Result[n] = ' ') then Dec(n);
  SetLength(Result, n);
end;

function RdnFoldKey(const ARdn: TDnRdn; AFold: TDnFoldProbe; ACanon: TDnTypeCanon): string;
var
  parts: array of string;
  tmp, t: string;
  j, k: Integer;
  fold: TDnValueFold;
begin
  parts := nil;
  SetLength(parts, Length(ARdn.Avas));
  for j := 0 to High(ARdn.Avas) do
    with ARdn.Avas[j] do
    begin
      t := '';
      if Assigned(ACanon) then t := ACanon(AttrType);
      if t = '' then t := AsciiLower(AttrType);
      parts[j] := t + '=';
      fold := dfExact;
      if Assigned(AFold) then fold := AFold(AttrType);
      if HexForm then
        parts[j] := parts[j] + '#' + HexEncode(Value)
      else
        case fold of
          dfCaseIgnore: parts[j] := parts[j] + HexEncode(SqueezeSpaces(LowerCase(Value)));
          dfCaseExact: parts[j] := parts[j] + HexEncode(SqueezeSpaces(Value));
        else
          parts[j] := parts[j] + HexEncode(Value);
        end;
    end;
  for j := 1 to High(parts) do
  begin
    tmp := parts[j];
    k := j - 1;
    while (k >= 0) and (parts[k] > tmp) do
    begin
      parts[k + 1] := parts[k];
      Dec(k);
    end;
    parts[k + 1] := tmp;
  end;
  Result := '';
  for j := 0 to High(parts) do
  begin
    if j > 0 then Result := Result + '+';
    Result := Result + parts[j];
  end;
end;

type
  TDnKeySet = specialize TDictionary<string, Boolean>;

function DnFoldKey(const ADn: string; AFold: TDnFoldProbe; ACanon: TDnTypeCanon): string;
var
  d: TLdapDn;
  k: Integer;
begin
  if not DnTryParse(ADn, d) then Exit(#1 + ADn);
  Result := '';
  for k := High(d.Rdns) downto 0 do
    Result := RdnFoldKey(d.Rdns[k], AFold, ACanon) + ',' + Result;
end;

function DnOutermost(const ADns: array of string; AFold: TDnFoldProbe;
  ACanon: TDnTypeCanon): TStringArray;
var
  // keys[i][k]: cle du DN reduit a ses RDN k..fin. [0] est le DN lui-meme, les suivants ses ancetres.
  keys: array of TStringArray;
  // Hachage et non liste triee: une insertion triee decale le tableau, quadratique sur des DN
  // freres en ordre decroissant.
  all, kept: TDnKeySet;
  d: TLdapDn;
  i, k, m, n: Integer;
  covered: Boolean;
begin
  Result := nil;
  SetLength(Result, Length(ADns));
  keys := nil;
  SetLength(keys, Length(ADns));
  n := 0;
  all := TDnKeySet.Create;
  kept := TDnKeySet.Create;
  try
    for i := 0 to High(ADns) do
    begin
      if DnTryParse(ADns[i], d) then
      begin
        m := Length(d.Rdns);
        SetLength(keys[i], m + 1);
        keys[i][m] := '';
        for k := m - 1 downto 0 do
          keys[i][k] := RdnFoldKey(d.Rdns[k], AFold, ACanon) + ',' + keys[i][k + 1];
      end
      else
      begin
        // Illisible: ne peut etre qu'un doublon exact, jamais parent ni enfant.
        SetLength(keys[i], 1);
        keys[i][0] := #1 + ADns[i];
      end;
      all.AddOrSetValue(keys[i][0], True);
    end;
    for i := 0 to High(ADns) do
    begin
      covered := kept.ContainsKey(keys[i][0]);
      k := 1;
      while (not covered) and (k <= High(keys[i])) do
      begin
        covered := all.ContainsKey(keys[i][k]);
        Inc(k);
      end;
      if covered then Continue;
      kept.Add(keys[i][0], True);
      Result[n] := ADns[i];
      Inc(n);
    end;
  finally
    all.Free;
    kept.Free;
  end;
  SetLength(Result, n);
end;

initialization
  GAsciiCaseIgnore := TAsciiCaseIgnore.Create;

finalization
  FreeAndNil(GAsciiCaseIgnore);

end.
