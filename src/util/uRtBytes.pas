// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uRtBytes;

{$mode objfpc}{$H+}

// Octets et texte aux frontieres: hexadecimal, base64 strict, UTF-8. Aucune conversion
// implicite de page de code: une valeur LDAP reste une suite d'octets tant qu'une
// syntaxe n'autorise pas son affichage. Windows-1252 n'aura pas le dernier mot.

interface

uses
  SysUtils;

function BytesOf(const S: RawByteString): TBytes;
function StringOfBytes(const B: TBytes): RawByteString;
function SameBytes(const A, B: TBytes): Boolean;
// Temps constant sur la longueur commune; longueurs differentes = False.
function ConstantTimeEquals(const A, B: RawByteString): Boolean;
// Efface la copie de S detenue par l'appelant puis la vide. Une chaine partagee est
// d'abord rendue unique: on n'efface pas sous les pieds des autres detenteurs.
procedure WipeString(var S: RawByteString);

function HexEncode(const S: RawByteString; AUpper: Boolean = False): string;
function HexDecode(const S: string; out AOut: RawByteString): Boolean;

function Base64EncodeStr(const S: RawByteString): string;
function Base64DecodeStrict(const S: string; out AOut: RawByteString): Boolean;
function Base64DecodeNoPad(const S: string; out AOut: RawByteString): Boolean;

function IsValidUtf8(const S: RawByteString): Boolean;
function IsAsciiPrintable(const S: RawByteString): Boolean;
function EscapeControlChars(const S: RawByteString): string;

function ReadUInt32LE(const S: RawByteString; AOffset: Integer): LongWord;

implementation

const
  B64Chars: array[0..63] of Char =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function BytesOf(const S: RawByteString): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

function StringOfBytes(const B: TBytes): RawByteString;
begin
  Result := '';
  SetLength(Result, Length(B));
  if Length(B) > 0 then
    Move(B[0], Result[1], Length(B));
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function ConstantTimeEquals(const A, B: RawByteString): Boolean;
var
  i: Integer;
  diff: Byte;
begin
  if Length(A) <> Length(B) then Exit(False);
  diff := 0;
  for i := 1 to Length(A) do
    diff := diff or (Byte(A[i]) xor Byte(B[i]));
  Result := diff = 0;
end;

procedure WipeString(var S: RawByteString);
begin
  if S = '' then Exit;
  UniqueString(S);
  FillChar(S[1], Length(S), 0);
  S := '';
end;

function HexEncode(const S: RawByteString; AUpper: Boolean): string;
const
  HL: array[0..15] of Char = '0123456789abcdef';
  HU: array[0..15] of Char = '0123456789ABCDEF';
var
  i: Integer;
  b: Byte;
begin
  SetLength(Result, Length(S) * 2);
  for i := 1 to Length(S) do
  begin
    b := Byte(S[i]);
    if AUpper then
    begin
      Result[i * 2 - 1] := HU[b shr 4];
      Result[i * 2] := HU[b and $0F];
    end
    else
    begin
      Result[i * 2 - 1] := HL[b shr 4];
      Result[i * 2] := HL[b and $0F];
    end;
  end;
end;

function HexNibble(C: Char; out V: Byte): Boolean;
begin
  Result := True;
  case C of
    '0'..'9': V := Ord(C) - Ord('0');
    'a'..'f': V := Ord(C) - Ord('a') + 10;
    'A'..'F': V := Ord(C) - Ord('A') + 10;
  else
    V := 0;
    Result := False;
  end;
end;

function HexDecode(const S: string; out AOut: RawByteString): Boolean;
var
  i: Integer;
  hi, lo: Byte;
begin
  AOut := '';
  Result := False;
  if Odd(Length(S)) then Exit;
  SetLength(AOut, Length(S) div 2);
  for i := 1 to Length(S) div 2 do
  begin
    if not HexNibble(S[i * 2 - 1], hi) then Exit;
    if not HexNibble(S[i * 2], lo) then Exit;
    AOut[i] := Char((hi shl 4) or lo);
  end;
  Result := True;
end;

function Base64EncodeStr(const S: RawByteString): string;
var
  i, n, o: Integer;
  v: LongWord;
begin
  n := Length(S);
  SetLength(Result, ((n + 2) div 3) * 4);
  i := 1;
  o := 1;
  while i + 2 <= n do
  begin
    v := (LongWord(Byte(S[i])) shl 16) or (LongWord(Byte(S[i + 1])) shl 8) or
      Byte(S[i + 2]);
    Result[o] := B64Chars[(v shr 18) and 63];
    Result[o + 1] := B64Chars[(v shr 12) and 63];
    Result[o + 2] := B64Chars[(v shr 6) and 63];
    Result[o + 3] := B64Chars[v and 63];
    Inc(i, 3);
    Inc(o, 4);
  end;
  case n - i + 1 of
    1:
      begin
        v := LongWord(Byte(S[i])) shl 16;
        Result[o] := B64Chars[(v shr 18) and 63];
        Result[o + 1] := B64Chars[(v shr 12) and 63];
        Result[o + 2] := '=';
        Result[o + 3] := '=';
      end;
    2:
      begin
        v := (LongWord(Byte(S[i])) shl 16) or (LongWord(Byte(S[i + 1])) shl 8);
        Result[o] := B64Chars[(v shr 18) and 63];
        Result[o + 1] := B64Chars[(v shr 12) and 63];
        Result[o + 2] := B64Chars[(v shr 6) and 63];
        Result[o + 3] := '=';
      end;
  end;
end;

function B64Val(C: Char): Integer; inline;
begin
  case C of
    'A'..'Z': Result := Ord(C) - Ord('A');
    'a'..'z': Result := Ord(C) - Ord('a') + 26;
    '0'..'9': Result := Ord(C) - Ord('0') + 52;
    '+': Result := 62;
    '/': Result := 63;
  else
    Result := -1;
  end;
end;

function DecodeCore(const S: string; ARequirePad: Boolean;
  out AOut: RawByteString): Boolean;
var
  n, pad, i, o, q: Integer;
  v: LongWord;
  d: array[0..3] of Integer;
  body: string;
begin
  AOut := '';
  Result := False;
  n := Length(S);
  if n = 0 then Exit(True);
  pad := 0;
  if (n >= 1) and (S[n] = '=') then Inc(pad);
  if (n >= 2) and (S[n - 1] = '=') then Inc(pad);
  if ARequirePad then
  begin
    if (n mod 4) <> 0 then Exit;
  end
  else if pad = 0 then
  begin
    if (n mod 4) = 1 then Exit;
  end
  else if (n mod 4) <> 0 then
    Exit;
  body := Copy(S, 1, n - pad);
  n := Length(body);
  SetLength(AOut, (n * 3) div 4);
  o := 0;
  i := 1;
  while i <= n do
  begin
    q := 0;
    v := 0;
    while (q < 4) and (i <= n) do
    begin
      d[q] := B64Val(body[i]);
      if d[q] < 0 then Exit;
      v := (v shl 6) or LongWord(d[q]);
      Inc(q);
      Inc(i);
    end;
    case q of
      4:
        begin
          AOut[o + 1] := Char((v shr 16) and $FF);
          AOut[o + 2] := Char((v shr 8) and $FF);
          AOut[o + 3] := Char(v and $FF);
          Inc(o, 3);
        end;
      3:
        begin
          // Bits de bourrage non nuls: encodage non canonique, refuse.
          if (v and $3) <> 0 then Exit;
          v := v shr 2;
          AOut[o + 1] := Char((v shr 8) and $FF);
          AOut[o + 2] := Char(v and $FF);
          Inc(o, 2);
        end;
      2:
        begin
          if (v and $F) <> 0 then Exit;
          v := v shr 4;
          AOut[o + 1] := Char(v and $FF);
          Inc(o, 1);
        end;
    else
      Exit;
    end;
  end;
  SetLength(AOut, o);
  Result := True;
end;

function Base64DecodeStrict(const S: string; out AOut: RawByteString): Boolean;
begin
  Result := DecodeCore(S, True, AOut);
end;

function Base64DecodeNoPad(const S: string; out AOut: RawByteString): Boolean;
begin
  Result := DecodeCore(S, False, AOut);
end;

function IsValidUtf8(const S: RawByteString): Boolean;
var
  i, n, need: Integer;
  c: Byte;
  cp, minCp: LongWord;
begin
  Result := False;
  i := 1;
  n := Length(S);
  while i <= n do
  begin
    c := Byte(S[i]);
    if c < $80 then
    begin
      Inc(i);
      Continue;
    end
    else if (c and $E0) = $C0 then
    begin
      need := 1;
      cp := c and $1F;
      minCp := $80;
    end
    else if (c and $F0) = $E0 then
    begin
      need := 2;
      cp := c and $0F;
      minCp := $800;
    end
    else if (c and $F8) = $F0 then
    begin
      need := 3;
      cp := c and $07;
      minCp := $10000;
    end
    else
      Exit;
    if i + need > n then Exit;
    while need > 0 do
    begin
      Inc(i);
      c := Byte(S[i]);
      if (c and $C0) <> $80 then Exit;
      cp := (cp shl 6) or (c and $3F);
      Dec(need);
    end;
    if (cp < minCp) or (cp > $10FFFF) or ((cp >= $D800) and (cp <= $DFFF)) then
      Exit;
    Inc(i);
  end;
  Result := True;
end;

function IsAsciiPrintable(const S: RawByteString): Boolean;
var
  i: Integer;
begin
  for i := 1 to Length(S) do
    if (Byte(S[i]) < 32) or (Byte(S[i]) > 126) then
      Exit(False);
  Result := True;
end;

function EscapeControlChars(const S: RawByteString): string;
var
  i: Integer;
  b: Byte;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    b := Byte(S[i]);
    if (b < 32) or (b = 127) then
      Result := Result + '\x' + HexEncode(Char(b))
    else
      Result := Result + Char(b);
  end;
end;

function ReadUInt32LE(const S: RawByteString; AOffset: Integer): LongWord;
begin
  Result := LongWord(Byte(S[AOffset])) or (LongWord(Byte(S[AOffset + 1])) shl 8) or
    (LongWord(Byte(S[AOffset + 2])) shl 16) or (LongWord(Byte(S[AOffset + 3])) shl 24);
end;

end.
