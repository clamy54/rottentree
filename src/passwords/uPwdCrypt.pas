// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPwdCrypt;

{$mode objfpc}{$H+}

// {CRYPT}: DES, MD5-crypt, SHA-256/512-crypt, bcrypt, Argon2. yescrypt, scrypt et
// compagnie sont reconnus mais pas verifiables: conserves tels quels.

interface

uses
  SysUtils, uPwdCore;

type
  TSubFormat = (sfNone, sfDes, sfMd5, sfSha256, sfSha512, sfBcrypt, sfArgon2,
    sfBcrypt2x, sfExtDes, sfYescrypt, sfScrypt, sfGostYescrypt, sfSunMd5,
    sfSha1Crypt, sfUnknownCrypt);

  TCryptScheme = class(TPasswordScheme)
  private
    FGenFormat: TSubFormat;
    function Parse(const ACrypt: RawByteString; out AFmt: TSubFormat;
      out ASalt: RawByteString; out ARounds: Integer; out AExplicit: Boolean;
      out ANote: string): Boolean;
  public
    constructor Create(AGenFormat: TSubFormat);
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

implementation

uses
  uRtBytes, uOpenSslApi, uSodiumApi, uArgon2Api, uBcrypt, uCryptAlgos, uPwdArgon2;

constructor TCryptScheme.Create(AGenFormat: TSubFormat);
begin
  inherited Create;
  FGenFormat := AGenFormat;
end;

function TCryptScheme.Id: string;
begin
  case FGenFormat of
    sfDes: Result := 'CRYPT-DES';
    sfMd5: Result := 'CRYPT-MD5';
    sfSha256: Result := 'CRYPT-SHA256';
    sfSha512: Result := 'CRYPT-SHA512';
    sfBcrypt: Result := 'CRYPT-BCRYPT';
  else
    Result := 'CRYPT';
  end;
end;

function TCryptScheme.DisplayName: string;
begin
  case FGenFormat of
    sfDes: Result := '{CRYPT} DES (legacy)';
    sfMd5: Result := '{CRYPT} MD5-crypt $1$ (legacy)';
    sfSha256: Result := '{CRYPT} SHA-256-crypt $5$';
    sfSha512: Result := '{CRYPT} SHA-512-crypt $6$';
    sfBcrypt: Result := '{CRYPT} bcrypt $2b$';
  else
    Result := '{CRYPT}';
  end;
end;

function TCryptScheme.Recommendation: TPwdRecommendation;
begin
  case FGenFormat of
    sfDes, sfMd5: Result := prLegacy;
    sfSha256, sfSha512, sfBcrypt: Result := prAcceptable;
  else
    Result := prAcceptable;
  end;
end;

function TCryptScheme.Matches(const AValue: RawByteString): Boolean;
var
  rest: RawByteString;
begin
  Result := HasPrefix(AValue, '{CRYPT}', rest);
end;

function TCryptScheme.Parse(const ACrypt: RawByteString; out AFmt: TSubFormat;
  out ASalt: RawByteString; out ARounds: Integer; out AExplicit: Boolean;
  out ANote: string): Boolean;
var
  parts: TStringArray;
  cost: Integer;
  saltBuf: array[0..15] of Byte;
  body: string;
  rounds64: Int64;
begin
  Result := False;
  AFmt := sfUnknownCrypt;
  ASalt := '';
  ARounds := 0;
  AExplicit := False;
  ANote := '';
  if Length(ACrypt) > PWD_MAX_VALUE_BYTES then
  begin
    ANote := 'value too long';
    Exit;
  end;
  if (Length(ACrypt) = 13) and IsCryptSaltChars(ACrypt) then
  begin
    AFmt := sfDes;
    ASalt := Copy(ACrypt, 1, 2);
    Exit(True);
  end;
  if (Length(ACrypt) > 0) and (ACrypt[1] = '_') then
  begin
    AFmt := sfExtDes;
    ANote := 'BSDi extended DES is recognised but not verified locally';
    Exit(True);
  end;
  if Copy(ACrypt, 1, 3) = '$1$' then
  begin
    AFmt := sfMd5;
    parts := string(ACrypt).Split(['$']);
    if (Length(parts) <> 4) or (Length(parts[2]) > MD5CRYPT_SALT_MAX) or
       (Length(parts[3]) <> 22) or not IsCryptSaltChars(parts[3]) then
    begin
      ANote := 'malformed MD5-crypt value';
      Exit;
    end;
    ASalt := parts[2];
    Exit(True);
  end;
  if (Copy(ACrypt, 1, 3) = '$5$') or (Copy(ACrypt, 1, 3) = '$6$') then
  begin
    if ACrypt[2] = '5' then AFmt := sfSha256 else AFmt := sfSha512;
    parts := string(ACrypt).Split(['$']);
    if (Length(parts) = 5) and (Copy(parts[2], 1, 7) = 'rounds=') then
    begin
      // Int64 puis plafond: TryStrToInt ne signale pas tous les debordements.
      if not TryStrToInt64(Copy(parts[2], 8, MaxInt), rounds64) or (rounds64 < 1) then
      begin
        ANote := 'invalid rounds';
        Exit;
      end;
      if rounds64 > High(Integer) then
        ARounds := High(Integer)
      else
        ARounds := rounds64;
      AExplicit := True;
      ASalt := parts[3];
      body := parts[4];
    end
    else if Length(parts) = 4 then
    begin
      ARounds := SHACRYPT_ROUNDS_DEFAULT;
      ASalt := parts[2];
      body := parts[3];
    end
    else
    begin
      ANote := 'malformed SHA-crypt value';
      Exit;
    end;
    if (Length(ASalt) > SHACRYPT_SALT_MAX) or
       ((AFmt = sfSha256) and (Length(body) <> 43)) or
       ((AFmt = sfSha512) and (Length(body) <> 86)) or not IsCryptSaltChars(body) then
    begin
      ANote := 'malformed SHA-crypt value';
      Exit;
    end;
    if ARounds < SHACRYPT_ROUNDS_MIN then ARounds := SHACRYPT_ROUNDS_MIN;
    Exit(True);
  end;
  if (Copy(ACrypt, 1, 4) = '$2a$') or (Copy(ACrypt, 1, 4) = '$2b$') or
     (Copy(ACrypt, 1, 4) = '$2y$') then
  begin
    AFmt := sfBcrypt;
    if (Length(ACrypt) <> 60) or not BcryptParseSalt(ACrypt, cost, saltBuf) or
       not IsCryptSaltChars(Copy(ACrypt, 8, 53)) then
    begin
      ANote := 'malformed bcrypt value';
      Exit;
    end;
    ARounds := cost;
    Exit(True);
  end;
  if Copy(ACrypt, 1, 4) = '$2x$' then
  begin
    AFmt := sfBcrypt2x;
    ANote := '$2x$ reproduces a historical bug and is not verified locally';
    Exit(True);
  end;
  if Copy(ACrypt, 1, 7) = '$argon2' then
  begin
    AFmt := sfArgon2;
    Exit(True);
  end;
  if Copy(ACrypt, 1, 3) = '$y$' then
  begin
    AFmt := sfYescrypt;
    ANote := 'yescrypt is recognised; no qualified local verifier';
    Exit(True);
  end;
  if Copy(ACrypt, 1, 4) = '$gy$' then
  begin
    AFmt := sfGostYescrypt;
    ANote := 'gost-yescrypt is recognised; no qualified local verifier';
    Exit(True);
  end;
  if Copy(ACrypt, 1, 3) = '$7$' then
  begin
    AFmt := sfScrypt;
    ANote := 'scrypt crypt format is recognised; no qualified local verifier';
    Exit(True);
  end;
  if Copy(ACrypt, 1, 4) = '$md5' then
  begin
    AFmt := sfSunMd5;
    ANote := 'Sun MD5 crypt is recognised but not verified locally';
    Exit(True);
  end;
  if Copy(ACrypt, 1, 6) = '$sha1$' then
  begin
    AFmt := sfSha1Crypt;
    ANote := 'NetBSD sha1crypt is recognised but not verified locally';
    Exit(True);
  end;
  ANote := 'unknown crypt(3) format';
end;

function TCryptScheme.Inspect(const AValue: RawByteString): TPwdInfo;
var
  rest, salt: RawByteString;
  fmt: TSubFormat;
  rounds: Integer;
  expl: Boolean;
  note: string;
  a: TArgon2Parsed;
begin
  Result := BaseInfo(Self, '{CRYPT}');
  Result.CanGenerate := False;
  HasPrefix(AValue, '{CRYPT}', rest);
  if not Parse(rest, fmt, salt, rounds, expl, note) then
  begin
    Result.Valid := False;
    Result.CanVerify := False;
    Result.Recommendation := prUnsupported;
    Result.Note := note;
    Exit;
  end;
  Result.Note := note;
  case fmt of
    sfDes:
      begin
        Result.SchemeId := 'CRYPT-DES';
        Result.DisplayName := '{CRYPT} DES (legacy)';
        Result.Recommendation := prLegacy;
        Result.Note := 'only the first 8 bytes of a password are used; 7-bit characters';
      end;
    sfMd5:
      begin
        Result.SchemeId := 'CRYPT-MD5';
        Result.DisplayName := '{CRYPT} MD5-crypt $1$ (legacy)';
        Result.Recommendation := prLegacy;
      end;
    sfSha256, sfSha512:
      begin
        if fmt = sfSha256 then
        begin
          Result.SchemeId := 'CRYPT-SHA256';
          Result.DisplayName := '{CRYPT} SHA-256-crypt $5$';
        end
        else
        begin
          Result.SchemeId := 'CRYPT-SHA512';
          Result.DisplayName := '{CRYPT} SHA-512-crypt $6$';
        end;
        Result.Params := 'rounds=' + IntToStr(rounds);
        if rounds > PWD_SHACRYPT_MAX_ROUNDS then
          Result.Note := 'rounds exceed the verification limit';
      end;
    sfBcrypt:
      begin
        Result.SchemeId := 'CRYPT-BCRYPT';
        Result.DisplayName := '{CRYPT} bcrypt ' + Copy(rest, 1, 4);
        Result.Params := 'cost=' + IntToStr(rounds);
        Result.Note := 'passwords longer than 72 bytes are refused, never truncated';
        if rounds > PWD_BCRYPT_MAX_COST then
          Result.Note := 'cost exceeds the verification limit';
      end;
    sfArgon2:
      begin
        if ParseArgon2Phc(rest, a, note) then
        begin
          Result.SchemeId := UpperCase(Argon2VariantName(a.Kind));
          Result.DisplayName := '{CRYPT} ' + Argon2VariantName(a.Kind);
          Result.Params := Format('v=%d,m=%d,t=%d,p=%d', [a.Version, a.Memory, a.Time, a.Parallelism]);
          if a.Kind = atArgon2id then Result.Recommendation := prPreferred;
        end
        else
        begin
          Result.Valid := False;
          Result.CanVerify := False;
          Result.Note := note;
        end;
      end;
  else
    begin
      Result.CanVerify := False;
      Result.Recommendation := prUnsupported;
    end;
  end;
end;

function TCryptScheme.Verify(const AValue, APassword: RawByteString;
  out ADetail: string): TPwdStatus;
var
  rest, salt, computed: RawByteString;
  fmt: TSubFormat;
  rounds, i: Integer;
  expl: Boolean;
  saltBuf: array[0..15] of Byte;
  cost: Integer;
begin
  ADetail := '';
  HasPrefix(AValue, '{CRYPT}', rest);
  if not Parse(rest, fmt, salt, rounds, expl, ADetail) then
    Exit(psInvalid);
  case fmt of
    sfDes:
      begin
        // DES n'utilise que 8 octets de 7 bits: verifier un mot de passe plus long,
        // c'est valider sa troncature.
        if Length(APassword) > 8 then
        begin
          ADetail := 'DES crypt uses only 8 bytes; a longer password cannot be verified';
          Exit(psTooLong);
        end;
        for i := 1 to Length(APassword) do
          if Byte(APassword[i]) >= $80 then
          begin
            ADetail := 'DES crypt drops the 8th bit; non-ASCII passwords cannot be verified';
            Exit(psTooLong);
          end;
        computed := DesCrypt(APassword, salt);
      end;
    sfMd5:
      computed := Md5Crypt(APassword, salt);
    sfSha256, sfSha512:
      begin
        if rounds > PWD_SHACRYPT_MAX_ROUNDS then
        begin
          ADetail := Format('rounds=%d exceeds the verification limit', [rounds]);
          Exit(psOutOfBounds);
        end;
        computed := ShaCrypt(fmt = sfSha512, APassword, salt, rounds, expl);
      end;
    sfBcrypt:
      begin
        if rounds > PWD_BCRYPT_MAX_COST then
        begin
          ADetail := Format('cost=%d exceeds the verification limit', [rounds]);
          Exit(psOutOfBounds);
        end;
        if Length(APassword) > BCRYPT_MAX_PASSWORD_BYTES then
        begin
          ADetail := 'bcrypt ignores bytes beyond 72; the password is not truncated';
          Exit(psTooLong);
        end;
        BcryptParseSalt(rest, cost, saltBuf);
        computed := BcryptHash(APassword, cost, saltBuf, Copy(rest, 2, 2));
      end;
    sfArgon2:
      Exit(VerifyArgon2Phc(rest, APassword, apAuto, ADetail));
  else
    Exit(psUnverifiable);
  end;
  if ConstantTimeEquals(computed, rest) then Result := psMatch else Result := psNoMatch;
end;

function TCryptScheme.CanGenerate: Boolean;
begin
  Result := FGenFormat in [sfDes, sfMd5, sfSha256, sfSha512, sfBcrypt];
end;

function TCryptScheme.GenerationNote: string;
begin
  Result := 'OpenLDAP checks {CRYPT} with the system crypt(3): slapd must be built with crypt ' +
    'support and the system must know this variant.';
  if FGenFormat = sfBcrypt then
    Result := Result + ' bcrypt needs libxcrypt (not in older glibc).';
end;

function RandomCryptSalt(ALen: Integer): string;
var
  raw: RawByteString;
  i: Integer;
begin
  raw := SystemRandomBytes(ALen);
  SetLength(Result, ALen);
  for i := 1 to ALen do
    Result[i] := CRYPT_ITOA64[(Byte(raw[i]) and $3F) + 1];
end;

function TCryptScheme.Generate(const APassword: RawByteString;
  const AParams: TPwdGenParams): RawByteString;
var
  salt: RawByteString;
  i: Integer;
begin
  case FGenFormat of
    sfDes:
      begin
        if Length(APassword) > 8 then
          raise Exception.Create('DES crypt would silently ignore bytes beyond 8');
        for i := 1 to Length(APassword) do
          if Byte(APassword[i]) >= $80 then
            raise Exception.Create('DES crypt would drop the 8th bit of non-ASCII characters');
        Result := '{CRYPT}' + DesCrypt(APassword, RandomCryptSalt(2));
      end;
    sfMd5:
      Result := '{CRYPT}' + Md5Crypt(APassword, RandomCryptSalt(8));
    sfSha256, sfSha512:
      Result := '{CRYPT}' + ShaCrypt(FGenFormat = sfSha512, APassword, RandomCryptSalt(16),
        AParams.ShaCryptRounds, True);
    sfBcrypt:
      begin
        if (AParams.BcryptCost < 4) or (AParams.BcryptCost > PWD_BCRYPT_MAX_COST) then
          raise Exception.Create('bcrypt cost out of the generation policy');
        salt := SystemRandomBytes(16);
        Result := '{CRYPT}' + BcryptHash(APassword, AParams.BcryptCost, salt[1], '2b');
      end;
  else
    Result := inherited Generate(APassword, AParams);
  end;
end;

end.
