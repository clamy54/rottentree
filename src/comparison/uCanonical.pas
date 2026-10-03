// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCanonical;

{$mode objfpc}{$H+}

// Forme canonique d'une entree pour la comparaison: attributs et options tries, chaque
// suite d'octets precedee de sa longueur. Sans les longueurs, deux entrees differentes
// finissent un jour par se concatener en la meme empreinte.

interface

uses
  SysUtils;

type
  TCanonAttr = record
    Name: string;
    Values: array of RawByteString;
    RawValues: array of RawByteString;
    SemanticUndetermined: Boolean;
    Ordered: Boolean;
  end;
  TCanonAttrs = array of TCanonAttr;

  ECanonical = class(Exception);

procedure SortCanonAttrs(var AAttrs: TCanonAttrs);
procedure SortValues(var AValues: array of RawByteString);
procedure SortValuePairs(var AValues, ARaw: array of RawByteString);
function EncodeCompared(const AAttrs: TCanonAttrs): RawByteString;
function EncodeRecord(const AAttrs: TCanonAttrs): RawByteString;
function DecodeRecord(const AData: RawByteString): TCanonAttrs;
function CanonicalHash(const AAttrs: TCanonAttrs): RawByteString;

implementation

uses
  uOpenSslApi;

const
  CANON_MAGIC = 'RWCANON1';
  MAX_ATTRS = 100000;
  MAX_VALUES = 10000000;

procedure PutLen(var S: RawByteString; ALen: Int64);
var
  b: array[0..7] of Byte;
  i: Integer;
begin
  for i := 0 to 7 do
    b[i] := (ALen shr (8 * (7 - i))) and $FF;
  SetLength(S, Length(S) + 8);
  Move(b[0], S[Length(S) - 7], 8);
end;

procedure PutBytes(var S: RawByteString; const AData: RawByteString);
begin
  PutLen(S, Length(AData));
  S := S + AData;
end;

function CompareRaw(const A, B: RawByteString): Integer;
var
  n, c: Integer;
begin
  n := Length(A);
  if Length(B) < n then n := Length(B);
  if n > 0 then
  begin
    c := CompareMemRange(@A[1], @B[1], n);
    if c <> 0 then Exit(c);
  end;
  Result := Length(A) - Length(B);
end;

procedure SortValues(var AValues: array of RawByteString);
var
  gap, i, j: Integer;
  tmp: RawByteString;
begin
  if Length(AValues) < 2 then Exit;
  gap := Length(AValues) div 2;
  while gap > 0 do
  begin
    i := gap;
    while i <= High(AValues) do
    begin
      tmp := AValues[i];
      j := i;
      while (j >= gap) and (CompareRaw(AValues[j - gap], tmp) > 0) do
      begin
        AValues[j] := AValues[j - gap];
        Dec(j, gap);
      end;
      AValues[j] := tmp;
      Inc(i);
    end;
    gap := gap div 2;
  end;
end;

procedure SortValuePairs(var AValues, ARaw: array of RawByteString);
var
  gap, i, j, c: Integer;
  tv, tr: RawByteString;

  function Cmp(const AV, AR, BV, BR: RawByteString): Integer;
  begin
    Result := CompareRaw(AV, BV);
    if Result = 0 then Result := CompareRaw(AR, BR);
  end;

begin
  if Length(AValues) <> Length(ARaw) then
    raise ECanonical.Create('value arrays of different lengths');
  if Length(AValues) < 2 then Exit;
  gap := Length(AValues) div 2;
  while gap > 0 do
  begin
    i := gap;
    while i <= High(AValues) do
    begin
      tv := AValues[i];
      tr := ARaw[i];
      j := i;
      while j >= gap do
      begin
        c := Cmp(AValues[j - gap], ARaw[j - gap], tv, tr);
        if c <= 0 then Break;
        AValues[j] := AValues[j - gap];
        ARaw[j] := ARaw[j - gap];
        Dec(j, gap);
      end;
      AValues[j] := tv;
      ARaw[j] := tr;
      Inc(i);
    end;
    gap := gap div 2;
  end;
end;

procedure SortCanonAttrs(var AAttrs: TCanonAttrs);
var
  i, j: Integer;
  tmp: TCanonAttr;
begin
  for i := 1 to High(AAttrs) do
  begin
    tmp := AAttrs[i];
    j := i - 1;
    while (j >= 0) and (AAttrs[j].Name > tmp.Name) do
    begin
      AAttrs[j + 1] := AAttrs[j];
      Dec(j);
    end;
    AAttrs[j + 1] := tmp;
  end;
end;

function EncodeCompared(const AAttrs: TCanonAttrs): RawByteString;
var
  i, j: Integer;
begin
  Result := CANON_MAGIC;
  PutLen(Result, Length(AAttrs));
  for i := 0 to High(AAttrs) do
  begin
    PutBytes(Result, AAttrs[i].Name);
    PutLen(Result, Length(AAttrs[i].Values));
    for j := 0 to High(AAttrs[i].Values) do
      PutBytes(Result, AAttrs[i].Values[j]);
  end;
end;

function EncodeRecord(const AAttrs: TCanonAttrs): RawByteString;
var
  i, j: Integer;
  flags: Byte;
begin
  Result := EncodeCompared(AAttrs);
  for i := 0 to High(AAttrs) do
  begin
    flags := 0;
    if AAttrs[i].SemanticUndetermined then flags := flags or 1;
    if AAttrs[i].Ordered then flags := flags or 2;
    Result := Result + Char(flags);
    PutLen(Result, Length(AAttrs[i].RawValues));
    for j := 0 to High(AAttrs[i].RawValues) do
      PutBytes(Result, AAttrs[i].RawValues[j]);
  end;
end;

function DecodeRecord(const AData: RawByteString): TCanonAttrs;
var
  p: Int64;

  function GetLen: Int64;
  var
    i: Integer;
  begin
    if p + 7 > Length(AData) then
      raise ECanonical.Create('truncated canonical record');
    Result := 0;
    for i := 0 to 7 do
      Result := (Result shl 8) or Byte(AData[p + i]);
    Inc(p, 8);
  end;

  function GetBytes: RawByteString;
  var
    n: Int64;
  begin
    n := GetLen;
    if (n < 0) or (p + n - 1 > Length(AData)) then
      raise ECanonical.Create('truncated canonical record');
    Result := Copy(AData, p, n);
    Inc(p, n);
  end;

var
  n, i, j, nv: Int64;
begin
  Result := nil;
  if Copy(AData, 1, 8) <> CANON_MAGIC then
    raise ECanonical.Create('unknown canonical format');
  p := 9;
  n := GetLen;
  if (n < 0) or (n > MAX_ATTRS) then
    raise ECanonical.Create('invalid attribute count');
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    Result[i].Name := GetBytes;
    nv := GetLen;
    if (nv < 0) or (nv > MAX_VALUES) then
      raise ECanonical.Create('invalid value count');
    SetLength(Result[i].Values, nv);
    for j := 0 to nv - 1 do
      Result[i].Values[j] := GetBytes;
  end;
  for i := 0 to n - 1 do
  begin
    if p > Length(AData) then
      raise ECanonical.Create('truncated canonical record');
    Result[i].SemanticUndetermined := (Byte(AData[p]) and 1) <> 0;
    Result[i].Ordered := (Byte(AData[p]) and 2) <> 0;
    Inc(p);
    nv := GetLen;
    if (nv < 0) or (nv > MAX_VALUES) then
      raise ECanonical.Create('invalid value count');
    SetLength(Result[i].RawValues, nv);
    for j := 0 to nv - 1 do
      Result[i].RawValues[j] := GetBytes;
  end;
end;

function CanonicalHash(const AAttrs: TCanonAttrs): RawByteString;
begin
  Result := DigestOf('SHA256', EncodeCompared(AAttrs));
end;

end.
