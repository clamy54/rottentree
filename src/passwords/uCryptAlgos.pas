// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCryptAlgos;

{$mode objfpc}{$H+}
{$Q-}{$R-}

// Algorithmes crypt(3) poses sur les condensats OpenSSL: MD5-crypt ($1$) et SHA-crypt
// ($5$, $6$), plus le base64 de crypt et le format "adapte" de passlib et de pw-pbkdf2
// d'OpenLDAP. Personne ne les dessinerait ainsi aujourd'hui.

interface

uses
  SysUtils;

const
  CRYPT_ITOA64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  SHACRYPT_ROUNDS_DEFAULT = 5000;
  SHACRYPT_ROUNDS_MIN = 1000;
  SHACRYPT_ROUNDS_MAX = 999999999;
  SHACRYPT_SALT_MAX = 16;
  MD5CRYPT_SALT_MAX = 8;

function Md5Crypt(const APassword, ASalt: RawByteString): RawByteString;

function ShaCrypt(ASha512: Boolean; const APassword, ASalt: RawByteString;
  ARounds: Integer; AExplicitRounds: Boolean): RawByteString;

function Ab64Encode(const S: RawByteString): string;
function Ab64Decode(const S: string; out AOut: RawByteString): Boolean;

function IsCryptSaltChars(const S: string): Boolean;

implementation

uses
  uOpenSslApi, uRtBytes;

procedure To64(var AOut: RawByteString; V: LongWord; N: Integer);
begin
  while N > 0 do
  begin
    AOut := AOut + CRYPT_ITOA64[(V and $3F) + 1];
    V := V shr 6;
    Dec(N);
  end;
end;

function IsCryptSaltChars(const S: string): Boolean;
var
  i: Integer;
begin
  for i := 1 to Length(S) do
    if Pos(S[i], CRYPT_ITOA64) = 0 then Exit(False);
  Result := True;
end;

function Md5Crypt(const APassword, ASalt: RawByteString): RawByteString;
const
  Magic = '$1$';
var
  ctx, ctx1: TDigestCtx;
  fin: RawByteString;
  pl, i: Integer;
  l: LongWord;
begin
  DigestInit(ctx, 'MD5');
  DigestInit(ctx1, 'MD5');
  try
    DigestUpdate(ctx, APassword + Magic + ASalt);
    DigestUpdate(ctx1, APassword + ASalt + APassword);
    fin := DigestFinal(ctx1);
    pl := Length(APassword);
    while pl > 0 do
    begin
      if pl > 16 then
        DigestUpdate(ctx, Copy(fin, 1, 16))
      else
        DigestUpdate(ctx, Copy(fin, 1, pl));
      Dec(pl, 16);
    end;
    i := Length(APassword);
    while i <> 0 do
    begin
      if (i and 1) <> 0 then
        DigestUpdate(ctx, #0)
      else if APassword <> '' then
        DigestUpdate(ctx, APassword[1]);
      i := i shr 1;
    end;
    fin := DigestFinal(ctx);
    for i := 0 to 999 do
    begin
      if (i and 1) <> 0 then DigestUpdate(ctx1, APassword) else DigestUpdate(ctx1, fin);
      if (i mod 3) <> 0 then DigestUpdate(ctx1, ASalt);
      if (i mod 7) <> 0 then DigestUpdate(ctx1, APassword);
      if (i and 1) <> 0 then DigestUpdate(ctx1, fin) else DigestUpdate(ctx1, APassword);
      fin := DigestFinal(ctx1);
    end;
  finally
    DigestFree(ctx);
    DigestFree(ctx1);
  end;
  Result := Magic + ASalt + '$';
  l := (LongWord(Byte(fin[1])) shl 16) or (LongWord(Byte(fin[7])) shl 8) or Byte(fin[13]);
  To64(Result, l, 4);
  l := (LongWord(Byte(fin[2])) shl 16) or (LongWord(Byte(fin[8])) shl 8) or Byte(fin[14]);
  To64(Result, l, 4);
  l := (LongWord(Byte(fin[3])) shl 16) or (LongWord(Byte(fin[9])) shl 8) or Byte(fin[15]);
  To64(Result, l, 4);
  l := (LongWord(Byte(fin[4])) shl 16) or (LongWord(Byte(fin[10])) shl 8) or Byte(fin[16]);
  To64(Result, l, 4);
  l := (LongWord(Byte(fin[5])) shl 16) or (LongWord(Byte(fin[11])) shl 8) or Byte(fin[6]);
  To64(Result, l, 4);
  l := Byte(fin[12]);
  To64(Result, l, 2);
end;

function ShaCrypt(ASha512: Boolean; const APassword, ASalt: RawByteString;
  ARounds: Integer; AExplicitRounds: Boolean): RawByteString;
const
  Order256: array[0..9, 0..2] of Byte = (
    (0, 10, 20), (21, 1, 11), (12, 22, 2), (3, 13, 23), (24, 4, 14),
    (15, 25, 5), (6, 16, 26), (27, 7, 17), (18, 28, 8), (9, 19, 29));
  Order512: array[0..20, 0..2] of Byte = (
    (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4),
    (47, 5, 26), (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51),
    (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13), (56, 14, 35),
    (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19),
    (62, 20, 41));
var
  algo, magic: string;
  hlen, plen, slen, i, rounds: Integer;
  ctx: TDigestCtx;
  a, b, c, dp, ds, p, s: RawByteString;

  function ByteAt(AIndex: Integer): LongWord; inline;
  begin
    Result := Byte(c[AIndex + 1]);
  end;

begin
  if ASha512 then
  begin
    algo := 'SHA512';
    magic := '$6$';
    hlen := 64;
  end
  else
  begin
    algo := 'SHA256';
    magic := '$5$';
    hlen := 32;
  end;
  rounds := ARounds;
  if rounds = 0 then rounds := SHACRYPT_ROUNDS_DEFAULT;
  if rounds < SHACRYPT_ROUNDS_MIN then rounds := SHACRYPT_ROUNDS_MIN;
  if rounds > SHACRYPT_ROUNDS_MAX then rounds := SHACRYPT_ROUNDS_MAX;
  s := Copy(ASalt, 1, SHACRYPT_SALT_MAX);
  plen := Length(APassword);
  slen := Length(s);
  DigestInit(ctx, algo);
  try
    DigestUpdate(ctx, APassword + s + APassword);
    b := DigestFinal(ctx);
    DigestUpdate(ctx, APassword + s);
    i := plen;
    while i > hlen do
    begin
      DigestUpdate(ctx, b);
      Dec(i, hlen);
    end;
    DigestUpdate(ctx, Copy(b, 1, i));
    i := plen;
    while i > 0 do
    begin
      if (i and 1) <> 0 then DigestUpdate(ctx, b) else DigestUpdate(ctx, APassword);
      i := i shr 1;
    end;
    a := DigestFinal(ctx);
    for i := 1 to plen do
      DigestUpdate(ctx, APassword);
    dp := DigestFinal(ctx);
    p := '';
    i := plen;
    while i >= hlen do
    begin
      p := p + dp;
      Dec(i, hlen);
    end;
    p := p + Copy(dp, 1, i);
    for i := 1 to 16 + Byte(a[1]) do
      DigestUpdate(ctx, s);
    ds := DigestFinal(ctx);
    s := '';
    i := slen;
    while i >= hlen do
    begin
      s := s + ds;
      Dec(i, hlen);
    end;
    s := s + Copy(ds, 1, i);
    c := a;
    for i := 0 to rounds - 1 do
    begin
      if (i and 1) <> 0 then DigestUpdate(ctx, p) else DigestUpdate(ctx, c);
      if (i mod 3) <> 0 then DigestUpdate(ctx, s);
      if (i mod 7) <> 0 then DigestUpdate(ctx, p);
      if (i and 1) <> 0 then DigestUpdate(ctx, c) else DigestUpdate(ctx, p);
      c := DigestFinal(ctx);
    end;
  finally
    DigestFree(ctx);
    if p <> '' then FillChar(p[1], Length(p), 0);
    if dp <> '' then FillChar(dp[1], Length(dp), 0);
  end;
  Result := magic;
  if AExplicitRounds then
    Result := Result + 'rounds=' + IntToStr(rounds) + '$';
  Result := Result + Copy(ASalt, 1, SHACRYPT_SALT_MAX) + '$';
  if ASha512 then
  begin
    for i := 0 to 20 do
      To64(Result, (ByteAt(Order512[i, 0]) shl 16) or (ByteAt(Order512[i, 1]) shl 8) or
        ByteAt(Order512[i, 2]), 4);
    To64(Result, ByteAt(63), 2);
  end
  else
  begin
    for i := 0 to 9 do
      To64(Result, (ByteAt(Order256[i, 0]) shl 16) or (ByteAt(Order256[i, 1]) shl 8) or
        ByteAt(Order256[i, 2]), 4);
    To64(Result, (ByteAt(31) shl 8) or ByteAt(30), 3);
  end;
end;

function Ab64Encode(const S: RawByteString): string;
begin
  Result := StringReplace(Base64EncodeStr(S), '+', '.', [rfReplaceAll]);
  while (Result <> '') and (Result[Length(Result)] = '=') do
    SetLength(Result, Length(Result) - 1);
end;

function Ab64Decode(const S: string; out AOut: RawByteString): Boolean;
begin
  if Pos('+', S) > 0 then Exit(False);
  Result := Base64DecodeNoPad(StringReplace(S, '.', '+', [rfReplaceAll]), AOut);
end;

end.
