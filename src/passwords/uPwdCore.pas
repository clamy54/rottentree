// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPwdCore;

{$mode objfpc}{$H+}

// Types communs aux formats userPassword. Les couts lus dans une empreinte viennent
// d'on ne sait ou: bornes verifiees avant tout calcul ou allocation, sinon une seule
// valeur suffit a mettre la machine a genoux.

interface

uses
  SysUtils, Classes;

const
  PWD_ARGON2_MAX_MEMORY_KIB = 256 * 1024;
  PWD_ARGON2_MAX_TIME = 10;
  PWD_ARGON2_MAX_PARALLELISM = 8;
  PWD_ARGON2_MAX_HASH_BYTES = 512;
  PWD_BCRYPT_MAX_COST = 16;
  PWD_PBKDF2_MAX_ITERATIONS = 2000000;
  PWD_SHACRYPT_MAX_ROUNDS = 5000000;
  PWD_MAX_VALUE_BYTES = 8192;
  PWD_MAX_SALT_BYTES = 1024;

  PWD_POLICY_VERSION = 1;

type
  TPwdStatus = (
    psMatch,
    psNoMatch,
    psUnverifiable,
    psInvalid,
    psOutOfBounds,  // jamais "mot de passe incorrect"
    psTooLong  // verifier imposerait une troncature du secret
  );

  TPwdRecommendation = (prPreferred, prAcceptable, prLegacy, prCleartext,
    prReference, prUnsupported);

  TPwdInfo = record
    SchemeId: string;
    DisplayName: string;
    Prefix: string;
    Params: string;
    Valid: Boolean;
    CanVerify: Boolean;
    CanGenerate: Boolean;
    Recommendation: TPwdRecommendation;
    Note: string;
  end;

  TPwdGenParams = record
    Argon2Memory: LongWord;
    Argon2Time: LongWord;
    Argon2Parallelism: LongWord;
    BcryptCost: Integer;
    Pbkdf2Iterations: Integer;
    ShaCryptRounds: Integer;
    SaltBytes: Integer;
  end;

  TPasswordScheme = class
  public
    function Id: string; virtual; abstract;
    function DisplayName: string; virtual; abstract;
    function Recommendation: TPwdRecommendation; virtual; abstract;
    function Matches(const AValue: RawByteString): Boolean; virtual; abstract;
    function Inspect(const AValue: RawByteString): TPwdInfo; virtual; abstract;
    function Verify(const AValue, APassword: RawByteString;
      out ADetail: string): TPwdStatus; virtual; abstract;
    function CanGenerate: Boolean; virtual;
    function Generate(const APassword: RawByteString;
      const AParams: TPwdGenParams): RawByteString; virtual;
    function GenerationNote: string; virtual;
  end;

function DefaultGenParams: TPwdGenParams;
function PwdStatusText(AStatus: TPwdStatus): string;
function HasPrefix(const AValue, APrefix: RawByteString; out ARest: RawByteString): Boolean;
function BaseInfo(AScheme: TPasswordScheme; const APrefix: string): TPwdInfo;
function RandomSalt(ACount: Integer): RawByteString;
function LooksLikeSchemePrefix(const AValue: RawByteString): Boolean;
function B64NoPad(const S: RawByteString): string;

implementation

uses
  uSodiumApi, uRtBytes;

function PwdStatusText(AStatus: TPwdStatus): string;
begin
  case AStatus of
    psMatch: Result := 'match';
    psNoMatch: Result := 'no match';
    psUnverifiable: Result := 'cannot be verified locally';
    psInvalid: Result := 'invalid value';
    psOutOfBounds: Result := 'parameters out of bounds';
    psTooLong: Result := 'password exceeds the format limit';
  end;
end;

function DefaultGenParams: TPwdGenParams;
begin
  Result.Argon2Memory := 65536;
  Result.Argon2Time := 3;
  Result.Argon2Parallelism := 1;
  Result.BcryptCost := 12;
  Result.Pbkdf2Iterations := 210000;
  Result.ShaCryptRounds := 656000;
  Result.SaltBytes := 16;
end;

function RandomSalt(ACount: Integer): RawByteString;
begin
  Result := SystemRandomBytes(ACount);
end;

function HasPrefix(const AValue, APrefix: RawByteString; out ARest: RawByteString): Boolean;
begin
  Result := (Length(AValue) >= Length(APrefix)) and
    SameText(Copy(AValue, 1, Length(APrefix)), APrefix);
  if Result then
    ARest := Copy(AValue, Length(APrefix) + 1, MaxInt)
  else
    ARest := '';
end;

function BaseInfo(AScheme: TPasswordScheme; const APrefix: string): TPwdInfo;
begin
  Result.SchemeId := AScheme.Id;
  Result.DisplayName := AScheme.DisplayName;
  Result.Prefix := APrefix;
  Result.Params := '';
  Result.Valid := True;
  Result.CanVerify := True;
  Result.CanGenerate := AScheme.CanGenerate;
  Result.Recommendation := AScheme.Recommendation;
  Result.Note := '';
end;

function TPasswordScheme.CanGenerate: Boolean;
begin
  Result := False;
end;

function TPasswordScheme.Generate(const APassword: RawByteString;
  const AParams: TPwdGenParams): RawByteString;
begin
  Result := '';
  raise Exception.CreateFmt('%s values cannot be generated', [DisplayName]);
end;

function TPasswordScheme.GenerationNote: string;
begin
  Result := '';
end;

function LooksLikeSchemePrefix(const AValue: RawByteString): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (Length(AValue) < 3) or (AValue[1] <> '{') then Exit;
  for i := 2 to Length(AValue) do
  begin
    if AValue[i] = '}' then Exit(i > 2);
    if not (AValue[i] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.']) then Exit;
    if i > 64 then Exit;
  end;
end;

function B64NoPad(const S: RawByteString): string;
begin
  Result := Base64EncodeStr(S);
  while (Result <> '') and (Result[Length(Result)] = '=') do
    SetLength(Result, Length(Result) - 1);
end;

end.
