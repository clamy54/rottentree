// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPwdArgon2;

{$mode objfpc}{$H+}

// Argon2: chaines PHC {ARGON2} du module argon2 d'OpenLDAP et sous-format
// {CRYPT}$argon2. Meme grammaire que les decodeurs de libargon2 et de libsodium,
// verifiee contre un slapd compile avec chacune.

interface

uses
  SysUtils, uPwdCore, uArgon2Api;

type
  TArgon2Parsed = record
    Kind: TArgon2Type;
    HasVersion: Boolean;
    Version: Integer;
    Memory, Time, Parallelism: Int64;
    Salt, Hash: RawByteString;
  end;

  TArgon2Provider = (apAuto, apLibArgon2, apLibSodium);

  TArgon2ServerSupport = record
    Parsed: Boolean;
    LibArgon2: Boolean;
    LibSodium: Boolean;
    Reason: string;
  end;

  TArgon2Scheme = class(TPasswordScheme)
  public
    function Id: string; override;
    function DisplayName: string; override;
    function Recommendation: TPwdRecommendation; override;
    function Matches(const AValue: RawByteString): Boolean; override;
    function Inspect(const AValue: RawByteString): TPwdInfo; override;
    function Verify(const AValue, APassword: RawByteString; out ADetail: string): TPwdStatus; override;
    function CanGenerate: Boolean; override;
    function Generate(const APassword: RawByteString; const AParams: TPwdGenParams): RawByteString; override;
    function GenerationNote: string; override;
  end;

function Argon2ServerSupport(const APhc: RawByteString): TArgon2ServerSupport;
function VerifyArgon2Phc(const APhc, APassword: RawByteString; AProvider: TArgon2Provider;
  out ADetail: string): TPwdStatus;
function ParseArgon2Phc(const S: RawByteString; out A: TArgon2Parsed; out AErr: string): Boolean;
function Argon2WithinBounds(const A: TArgon2Parsed): Boolean;
// Plancher d'audit: 8 Mio de memoire, sel de 8 octets, empreinte de 16. En dessous, le
// papier a en-tete d'Argon2 sur un calcul qui tient dans un cache L2.
function Argon2BelowFloor(const A: TArgon2Parsed): Boolean;
function Argon2VariantName(K: TArgon2Type): string;

implementation

uses
  ctypes, uRtBytes, uSodiumApi;

// Entier decimal facon decode_decimal (libargon2, libsodium): chiffres seuls, pas de
// zero de tete, au plus 2^32 - 1. TryStrToInt64 avalerait '0x10', '$10' ou '+5', que le
// serveur refuse.
function ParsePhcDecimal(const S: string; out AValue: Int64): Boolean;
var
  i: Integer;
begin
  Result := False;
  AValue := 0;
  if (S = '') or (Length(S) > 10) then Exit;
  if (S[1] = '0') and (Length(S) > 1) then Exit;
  for i := 1 to Length(S) do
  begin
    if not (S[i] in ['0'..'9']) then Exit;
    AValue := AValue * 10 + (Ord(S[i]) - Ord('0'));
  end;
  Result := AValue <= High(LongWord);
end;

// Grammaire de decode_string (libargon2 20190702, libsodium): v= facultatif, puis m, t,
// p dans cet ordre exact. Ce que les deux serveurs refusent n'est jamais declare
// correspondant.
function ParseArgon2Phc(const S: RawByteString; out A: TArgon2Parsed; out AErr: string): Boolean;
var
  parts, params: TStringArray;
  idx: Integer;
  v: Int64;

  function Field(const AText, AKey: string; out AValue: Int64): Boolean;
  begin
    Result := (Copy(AText, 1, Length(AKey) + 1) = AKey + '=') and
      ParsePhcDecimal(Copy(AText, Length(AKey) + 2, MaxInt), AValue);
  end;

begin
  Result := False;
  AErr := 'malformed Argon2 string';
  A.HasVersion := False;
  A.Version := ARGON2_VERSION_10;
  A.Memory := 0;
  A.Time := 0;
  A.Parallelism := 0;
  A.Salt := '';
  A.Hash := '';
  parts := string(S).Split(['$']);
  if (Length(parts) < 5) or (parts[0] <> '') then Exit;
  // Variante sensible a la casse, comme le strncmp du module OpenLDAP.
  if parts[1] = 'argon2id' then A.Kind := atArgon2id
  else if parts[1] = 'argon2i' then A.Kind := atArgon2i
  else if parts[1] = 'argon2d' then A.Kind := atArgon2d
  else
  begin
    AErr := 'unknown Argon2 variant';
    Exit;
  end;
  idx := 2;
  if Copy(parts[idx], 1, 2) = 'v=' then
  begin
    if not Field(parts[idx], 'v', v) then Exit;
    if (v <> ARGON2_VERSION_10) and (v <> ARGON2_VERSION_13) then
    begin
      AErr := 'unsupported Argon2 version';
      Exit;
    end;
    A.HasVersion := True;
    A.Version := v;
    Inc(idx);
  end;
  if Length(parts) - idx <> 3 then Exit;
  params := parts[idx].Split([',']);
  if (Length(params) <> 3) or not Field(params[0], 'm', A.Memory) or
    not Field(params[1], 't', A.Time) or not Field(params[2], 'p', A.Parallelism) then Exit;
  if (A.Time < 1) or (A.Parallelism < 1) then Exit;
  // '=' hors alphabet pour les deux decodeurs: aucun bourrage tolere.
  if (Pos('=', parts[idx + 1]) > 0) or (Pos('=', parts[idx + 2]) > 0) then Exit;
  if not Base64DecodeNoPad(parts[idx + 1], A.Salt) then Exit;
  if not Base64DecodeNoPad(parts[idx + 2], A.Hash) then Exit;
  if (Length(A.Salt) < 8) or (Length(A.Salt) > PWD_MAX_SALT_BYTES) then
  begin
    AErr := 'invalid Argon2 salt length';
    Exit;
  end;
  if (Length(A.Hash) < 4) or (Length(A.Hash) > PWD_ARGON2_MAX_HASH_BYTES) then
  begin
    AErr := 'invalid Argon2 hash length';
    Exit;
  end;
  // validate_inputs des deux bibliotheques: au moins 8 Kio par voie.
  if A.Memory < 8 * A.Parallelism then
  begin
    AErr := 'Argon2 memory below 8 KiB per lane';
    Exit;
  end;
  AErr := '';
  Result := True;
end;

function Argon2WithinBounds(const A: TArgon2Parsed): Boolean;
begin
  Result := (A.Memory <= PWD_ARGON2_MAX_MEMORY_KIB) and (A.Time <= PWD_ARGON2_MAX_TIME) and
    (A.Parallelism <= PWD_ARGON2_MAX_PARALLELISM);
end;

function Argon2ServerSupport(const APhc: RawByteString): TArgon2ServerSupport;
var
  a: TArgon2Parsed;
  err: string;
begin
  Result.Parsed := ParseArgon2Phc(APhc, a, err);
  Result.LibArgon2 := Result.Parsed;
  Result.LibSodium := False;
  Result.Reason := err;
  if not Result.Parsed then Exit;
  // crypto_pwhash_str_verify ne connait que $argon2id et $argon2i en v=19, empreinte
  // d'au moins 16 octets (libargon2 descend a 4).
  if a.Kind = atArgon2d then
    Result.Reason := 'libsodium does not implement argon2d'
  else if not a.HasVersion then
    Result.Reason := 'libsodium requires the v=19 field'
  else if a.Version <> ARGON2_VERSION_13 then
    Result.Reason := 'libsodium only accepts version 19'
  else if Length(a.Hash) < 16 then
    Result.Reason := 'libsodium requires a hash of at least 16 bytes'
  else
  begin
    Result.LibSodium := True;
    Result.Reason := '';
  end;
end;

function Argon2SupportNote(const S: TArgon2ServerSupport): string;
begin
  if not S.Parsed then
    Result := ''
  else if S.LibSodium then
    Result := 'OpenLDAP {ARGON2}: accepted with libargon2 and libsodium builds'
  else
    Result := 'OpenLDAP {ARGON2}: libargon2 build only (' + S.Reason + ')';
end;

function SodiumArgon2RawHash(const A: TArgon2Parsed; const APassword: RawByteString;
  out AHash: RawByteString): Boolean;
var
  alg: cint;
  pw: PAnsiChar;
begin
  AHash := '';
  SodiumEnsureLoaded;
  if A.Kind = atArgon2id then
    alg := crypto_pwhash_ALG_ARGON2ID13
  else
    alg := crypto_pwhash_ALG_ARGON2I13;
  if APassword = '' then pw := nil else pw := @APassword[1];
  SetLength(AHash, Length(A.Hash));
  Result := crypto_pwhash(@AHash[1], Length(AHash), pw, Length(APassword),
    @A.Salt[1], A.Time, csize_t(A.Memory) * 1024, alg) = 0;
  if not Result then WipeString(AHash);
end;

function VerifyArgon2Phc(const APhc, APassword: RawByteString; AProvider: TArgon2Provider;
  out ADetail: string): TPwdStatus;
var
  a: TArgon2Parsed;
  h: RawByteString;
  useSodium: Boolean;
begin
  if not ParseArgon2Phc(APhc, a, ADetail) then Exit(psInvalid);
  if not Argon2WithinBounds(a) then
  begin
    ADetail := Format('m=%d, t=%d, p=%d exceed the verification limits',
      [a.Memory, a.Time, a.Parallelism]);
    Exit(psOutOfBounds);
  end;
  case AProvider of
    apLibArgon2: useSodium := False;
    apLibSodium: useSodium := True;
  else
    useSodium := not Argon2Available;
  end;
  h := '';
  try
    if useSodium then
    begin
      if (a.Kind = atArgon2d) or (a.Version <> ARGON2_VERSION_13) or (a.Parallelism <> 1) or
        (Length(a.Salt) <> crypto_pwhash_SALTBYTES) or (Length(a.Hash) < 16) then
      begin
        ADetail := 'libargon2 unavailable; libsodium cannot recompute this value';
        Exit(psUnverifiable);
      end;
      if not SodiumArgon2RawHash(a, APassword, h) then
      begin
        ADetail := 'libsodium refused these parameters';
        Exit(psUnverifiable);
      end;
    end
    else
      h := Argon2RawHash(a.Kind, a.Version, a.Time, a.Memory, a.Parallelism, APassword,
        a.Salt, Length(a.Hash));
    if ConstantTimeEquals(h, a.Hash) then Result := psMatch else Result := psNoMatch;
  finally
    WipeString(h);
  end;
end;

function Argon2BelowFloor(const A: TArgon2Parsed): Boolean;
begin
  Result := (A.Memory < 8192) or (A.Time < 1) or (Length(A.Salt) < 8) or (Length(A.Hash) < 16);
end;

function Argon2VariantName(K: TArgon2Type): string;
begin
  case K of
    atArgon2d: Result := 'argon2d';
    atArgon2i: Result := 'argon2i';
  else
    Result := 'argon2id';
  end;
end;

const
  // Sel de 16 octets et empreinte de 32: ce que produit argon2.c d'OpenLDAP, quelle que
  // soit la bibliotheque derriere.
  ARGON2_OPENLDAP_SALT_BYTES = 16;
  ARGON2_OPENLDAP_HASH_BYTES = 32;

function TArgon2Scheme.Id: string;
begin
  Result := 'ARGON2ID';
end;

function TArgon2Scheme.DisplayName: string;
begin
  Result := 'Argon2id {ARGON2} (PHC string)';
end;

function TArgon2Scheme.Recommendation: TPwdRecommendation;
begin
  Result := prPreferred;
end;

function TArgon2Scheme.Matches(const AValue: RawByteString): Boolean;
var
  rest: RawByteString;
begin
  Result := HasPrefix(AValue, '{ARGON2}', rest);
end;

function TArgon2Scheme.Inspect(const AValue: RawByteString): TPwdInfo;
var
  rest: RawByteString;
  a: TArgon2Parsed;
  err: string;
begin
  Result := BaseInfo(Self, '{ARGON2}');
  HasPrefix(AValue, '{ARGON2}', rest);
  if not ParseArgon2Phc(rest, a, err) then
  begin
    Result.Valid := False;
    Result.CanVerify := False;
    Result.Note := err;
    Exit;
  end;
  Result.SchemeId := UpperCase(Argon2VariantName(a.Kind));
  Result.DisplayName := Argon2VariantName(a.Kind) + ' {ARGON2}';
  if a.Kind <> atArgon2id then Result.Recommendation := prAcceptable;
  Result.Params := Format('v=%d,m=%d,t=%d,p=%d', [a.Version, a.Memory, a.Time, a.Parallelism]);
  Result.Note := Argon2SupportNote(Argon2ServerSupport(rest));
  if Argon2BelowFloor(a) then
  begin
    Result.Storage := pslWeak;
    Result.Note := 'parameters below the audit floor; ' + Result.Note;
  end
  else if not Argon2WithinBounds(a) then
    Result.Note := 'parameters exceed the verification limits; ' + Result.Note;
end;

function TArgon2Scheme.Verify(const AValue, APassword: RawByteString;
  out ADetail: string): TPwdStatus;
var
  rest: RawByteString;
begin
  HasPrefix(AValue, '{ARGON2}', rest);
  Result := VerifyArgon2Phc(rest, APassword, apAuto, ADetail);
end;

function TArgon2Scheme.CanGenerate: Boolean;
begin
  Result := True;
end;

function TArgon2Scheme.Generate(const APassword: RawByteString;
  const AParams: TPwdGenParams): RawByteString;
var
  a: TArgon2Parsed;
  h: RawByteString;
begin
  a.Kind := atArgon2id;
  a.HasVersion := True;
  a.Version := ARGON2_VERSION_13;
  a.Memory := AParams.Argon2Memory;
  a.Time := AParams.Argon2Time;
  a.Parallelism := AParams.Argon2Parallelism;
  if not Argon2WithinBounds(a) or (a.Time < 1) or (a.Parallelism < 1) or
    (a.Memory < 8 * a.Parallelism) then
    raise Exception.Create('Argon2 parameters out of the generation policy');
  a.Salt := SystemRandomBytes(ARGON2_OPENLDAP_SALT_BYTES);
  SetLength(a.Hash, ARGON2_OPENLDAP_HASH_BYTES);
  h := '';
  try
    if Argon2Available then
      h := Argon2RawHash(a.Kind, a.Version, a.Time, a.Memory, a.Parallelism, APassword,
        a.Salt, ARGON2_OPENLDAP_HASH_BYTES)
    else if a.Parallelism <> 1 then
      raise Exception.Create('Argon2 with p > 1 requires libargon2')
    else if not SodiumArgon2RawHash(a, APassword, h) then
      raise Exception.Create('libsodium refused the Argon2 parameters');
    Result := Format('{ARGON2}$argon2id$v=19$m=%d,t=%d,p=%d$%s$%s',
      [a.Memory, a.Time, a.Parallelism, B64NoPad(a.Salt), B64NoPad(h)]);
  finally
    WipeString(h);
  end;
end;

function TArgon2Scheme.GenerationNote: string;
begin
  Result := 'argon2id, v=19, 16-byte salt, 32-byte hash: accepted by the OpenLDAP {ARGON2} ' +
    'module whether slapd was built with libargon2 or libsodium.';
end;

end.
