// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uMatchingRules;

{$mode objfpc}{$H+}

// Regles d'egalite de la comparaison semantique. Une regle ne s'applique que si elle
// est connue ici ET identique dans les schemas compares; sinon on retombe sur les
// octets. Jamais de pliage global des accents, des espaces ou de la casse.

interface

uses
  SysUtils;

type
  TNormResult = (
    nrOk,
    nrUnsupported,
    nrUndetermined
  );

  TRuleKind = (rkOctet, rkCaseIgnore, rkCaseExact, rkCaseIgnoreIA5, rkCaseExactIA5,
    rkNumericString, rkInteger, rkBoolean, rkGeneralizedTime, rkTelephone, rkDn,
    rkObjectIdentifier, rkUuid, rkUnknown);

function RuleKindFromName(const ARule: string): TRuleKind;
// ANorm en var et non en out: FPC vide un parametre out des l'entree, et un appelant
// qui passe la meme variable des deux cotes perdrait sa valeur avant qu'on la lise.
function NormalizeValue(AKind: TRuleKind; const AValue: RawByteString;
  var ANorm: RawByteString): TNormResult;
function PrepareSpacesAscii(const S: RawByteString): RawByteString;
function ParseGeneralizedTime(const S: RawByteString; out AUtc: RawByteString): Boolean;

implementation

uses
  uRtBytes, uLdapDn;

function RuleKindFromName(const ARule: string): TRuleKind;
var
  r: string;
begin
  r := LowerCase(ARule);
  if (r = 'octetstringmatch') or (r = '2.5.13.17') then Result := rkOctet
  else if (r = 'caseignorematch') or (r = '2.5.13.2') then Result := rkCaseIgnore
  else if (r = 'caseexactmatch') or (r = '2.5.13.5') then Result := rkCaseExact
  else if (r = 'caseignoreia5match') or (r = '1.3.6.1.4.1.1466.109.114.2') then Result := rkCaseIgnoreIA5
  else if (r = 'caseexactia5match') or (r = '1.3.6.1.4.1.1466.109.114.1') then Result := rkCaseExactIA5
  else if (r = 'numericstringmatch') or (r = '2.5.13.8') then Result := rkNumericString
  else if (r = 'integermatch') or (r = '2.5.13.14') then Result := rkInteger
  else if (r = 'booleanmatch') or (r = '2.5.13.13') then Result := rkBoolean
  else if (r = 'generalizedtimematch') or (r = '2.5.13.27') then Result := rkGeneralizedTime
  else if (r = 'telephonenumbermatch') or (r = '2.5.13.20') then Result := rkTelephone
  else if (r = 'distinguishednamematch') or (r = '2.5.13.1') then Result := rkDn
  else if (r = 'objectidentifiermatch') or (r = '2.5.13.0') then Result := rkObjectIdentifier
  else if (r = 'uuidmatch') or (r = '1.3.6.1.1.16.2') then Result := rkUuid
  else Result := rkUnknown;
end;

function PrepareSpacesAscii(const S: RawByteString): RawByteString;
var
  i: Integer;
  lastSpace: Boolean;
begin
  Result := '';
  lastSpace := False;
  for i := 1 to Length(S) do
  begin
    if S[i] = ' ' then
    begin
      if (Result <> '') and not lastSpace then
        Result := Result + ' ';
      lastSpace := True;
    end
    else
    begin
      Result := Result + S[i];
      lastSpace := False;
    end;
  end;
  if (Result <> '') and (Result[Length(Result)] = ' ') then
    SetLength(Result, Length(Result) - 1);
end;

function IsAscii(const S: RawByteString): Boolean;
var
  i: Integer;
begin
  for i := 1 to Length(S) do
    if Byte(S[i]) >= $80 then Exit(False);
  Result := True;
end;

function AsciiLower(const S: RawByteString): RawByteString;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then
      Result[i] := Chr(Ord(Result[i]) + 32);
end;

function AllDigits(const S: RawByteString): Boolean;
var
  i: Integer;
begin
  if S = '' then Exit(False);
  for i := 1 to Length(S) do
    if not (S[i] in ['0'..'9']) then Exit(False);
  Result := True;
end;

function ParseGeneralizedTime(const S: RawByteString; out AUtc: RawByteString): Boolean;
var
  y, mo, d, h, mi, sec: Integer;
  frac, rest, fracSec: RawByteString;
  p, i, fracUnit: Integer;
  dt: TDateTime;
  offSign, offH, offM: Integer;
  scale, fracNum, secs, whole, remain: Int64;
  days: Int64;
begin
  Result := False;
  AUtc := '';
  if Length(S) < 11 then Exit;
  if not AllDigits(Copy(S, 1, 10)) then Exit;
  y := StrToInt(Copy(S, 1, 4));
  mo := StrToInt(Copy(S, 5, 2));
  d := StrToInt(Copy(S, 7, 2));
  h := StrToInt(Copy(S, 9, 2));
  p := 11;
  mi := 0;
  sec := 0;
  fracUnit := 3600;
  if (p + 1 <= Length(S)) and (S[p] in ['0'..'9']) then
  begin
    if not AllDigits(Copy(S, p, 2)) then Exit;
    mi := StrToInt(Copy(S, p, 2));
    Inc(p, 2);
    fracUnit := 60;
    if (p + 1 <= Length(S)) and (S[p] in ['0'..'9']) then
    begin
      if not AllDigits(Copy(S, p, 2)) then Exit;
      sec := StrToInt(Copy(S, p, 2));
      Inc(p, 2);
      fracUnit := 1;
    end;
  end;
  frac := '';
  if (p <= Length(S)) and (S[p] in ['.', ',']) then
  begin
    Inc(p);
    while (p <= Length(S)) and (S[p] in ['0'..'9']) do
    begin
      frac := frac + S[p];
      Inc(p);
    end;
    if frac = '' then Exit;
  end;
  rest := Copy(S, p, MaxInt);
  offSign := 0;
  offH := 0;
  offM := 0;
  if rest = 'Z' then
    offSign := 0
  else if (Length(rest) = 5) and (rest[1] in ['+', '-']) and AllDigits(Copy(rest, 2, 4)) then
  begin
    offH := StrToInt(Copy(rest, 2, 2));
    offM := StrToInt(Copy(rest, 4, 2));
    if (offH > 23) or (offM > 59) then Exit;
    if rest[1] = '+' then offSign := 1 else offSign := -1;
  end
  else
    Exit;
  if not TryEncodeDate(y, mo, d, dt) then Exit;
  if (h > 23) or (mi > 59) or (sec > 59) then Exit;
  fracSec := '';
  secs := Int64(h) * 3600 + Int64(mi) * 60 + sec;
  if frac <> '' then
  begin
    if Length(frac) > 12 then Exit;
    scale := 1;
    for i := 1 to Length(frac) do scale := scale * 10;
    fracNum := StrToInt64(frac) * fracUnit;
    whole := fracNum div scale;
    remain := fracNum mod scale;
    Inc(secs, whole);
    if remain > 0 then
    begin
      fracSec := IntToStr(remain);
      while Length(fracSec) < Length(frac) do fracSec := '0' + fracSec;
      while (fracSec <> '') and (fracSec[Length(fracSec)] = '0') do
        SetLength(fracSec, Length(fracSec) - 1);
    end;
  end;
  secs := secs - offSign * (Int64(offH) * 3600 + Int64(offM) * 60);
  days := 0;
  while secs < 0 do begin Inc(secs, 86400); Dec(days); end;
  while secs >= 86400 do begin Dec(secs, 86400); Inc(days); end;
  dt := dt + days;
  AUtc := FormatDateTime('yyyymmdd', dt) +
    Format('%.2d%.2d%.2d', [secs div 3600, (secs div 60) mod 60, secs mod 60]);
  if fracSec <> '' then AUtc := AUtc + '.' + fracSec;
  AUtc := AUtc + 'Z';
  Result := True;
end;

function NormalizeValue(AKind: TRuleKind; const AValue: RawByteString;
  var ANorm: RawByteString): TNormResult;
var
  i: Integer;
  n: Int64;
  d: TLdapDn;
  err: string;
  cmp: TDnComparer;
  v: RawByteString;
begin
  // Copie locale d'abord: meme variable en entree et en sortie, vider la sortie
  // viderait aussi l'entree.
  v := AValue;
  ANorm := '';
  Result := nrOk;
  case AKind of
    rkOctet:
      ANorm := v;
    rkCaseIgnore, rkCaseIgnoreIA5:
      begin
        if not IsAscii(v) then Exit(nrUndetermined);
        ANorm := AsciiLower(PrepareSpacesAscii(v));
      end;
    rkCaseExact, rkCaseExactIA5:
      begin
        if not IsAscii(v) then Exit(nrUndetermined);
        ANorm := PrepareSpacesAscii(v);
      end;
    rkNumericString:
      begin
        for i := 1 to Length(v) do
          if v[i] <> ' ' then
          begin
            if not (v[i] in ['0'..'9']) then Exit(nrUndetermined);
            ANorm := ANorm + v[i];
          end;
      end;
    rkInteger:
      begin
        if not TryStrToInt64(v, n) then Exit(nrUndetermined);
        ANorm := IntToStr(n);
      end;
    rkBoolean:
      begin
        if (v = 'TRUE') or (v = 'FALSE') then
          ANorm := v
        else
          Exit(nrUndetermined);
      end;
    rkGeneralizedTime:
      if not ParseGeneralizedTime(v, ANorm) then Exit(nrUndetermined);
    rkTelephone:
      begin
        if not IsAscii(v) then Exit(nrUndetermined);
        for i := 1 to Length(v) do
          if not (v[i] in [' ', '-']) then
            ANorm := ANorm + v[i];
      end;
    rkDn:
      begin
        if not DnParse(v, d, err) then Exit(nrUndetermined);
        cmp := TDnComparer.Create;
        try
          ANorm := DnStrictKey(cmp, d);
        finally
          cmp.Free;
        end;
      end;
    rkUuid:
      begin
        if Length(v) <> 36 then Exit(nrUndetermined);
        ANorm := AsciiLower(v);
      end;
    rkObjectIdentifier:
      begin
        if not IsNumericOid(v) then
        begin
          if IsDescr(v) then
          begin
            ANorm := 'descr:' + AsciiLower(v);
            Exit(nrOk);
          end;
          Exit(nrUndetermined);
        end;
        ANorm := v;
      end;
  else
    Result := nrUnsupported;
  end;
end;

end.
