// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPwdPbkdf2;

{$mode objfpc}{$H+}

// PBKDF2-HMAC-SHA1/SHA256/SHA512 au format pw-pbkdf2 d'OpenLDAP (contrib) et passlib:
// {PBKDF2-SHA256}rounds$ab64sel$ab64dk.

interface

uses
  SysUtils, uPwdCore;

type
  TPbkdf2Scheme = class(TPasswordScheme)
  private
    FPrefix, FAlgo, FId: string;
    FDkLen: Integer;
    function Parse(const AValue: RawByteString; out AIter: Int64;
      out ASalt, ADk: RawByteString): Boolean;
  public
    constructor Create(const AId, APrefix, AAlgo: string; ADkLen: Integer);
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
  uRtBytes, uOpenSslApi, uSodiumApi, uCryptAlgos;

constructor TPbkdf2Scheme.Create(const AId, APrefix, AAlgo: string; ADkLen: Integer);
begin
  inherited Create;
  FId := AId;
  FPrefix := APrefix;
  FAlgo := AAlgo;
  FDkLen := ADkLen;
end;

function TPbkdf2Scheme.Id: string;
begin
  Result := FId;
end;

function TPbkdf2Scheme.DisplayName: string;
begin
  Result := 'PBKDF2-HMAC-' + FAlgo + ' ' + FPrefix + ' (OpenLDAP pw-pbkdf2 / passlib)';
end;

function TPbkdf2Scheme.Recommendation: TPwdRecommendation;
begin
  if FAlgo = 'SHA1' then Result := prLegacy else Result := prAcceptable;
end;

function TPbkdf2Scheme.Matches(const AValue: RawByteString): Boolean;
var
  rest: RawByteString;
begin
  Result := HasPrefix(AValue, FPrefix, rest);
end;

function TPbkdf2Scheme.Parse(const AValue: RawByteString; out AIter: Int64;
  out ASalt, ADk: RawByteString): Boolean;
var
  rest: RawByteString;
  parts: TStringArray;
begin
  Result := False;
  AIter := 0;
  if not HasPrefix(AValue, FPrefix, rest) then Exit;
  if Length(rest) > PWD_MAX_VALUE_BYTES then Exit;
  parts := string(rest).Split(['$']);
  if Length(parts) <> 3 then Exit;
  if not TryStrToInt64(parts[0], AIter) or (AIter < 1) then Exit;
  if not Ab64Decode(parts[1], ASalt) or (Length(ASalt) > PWD_MAX_SALT_BYTES) then Exit;
  if not Ab64Decode(parts[2], ADk) or (Length(ADk) <> FDkLen) then Exit;
  Result := True;
end;

function TPbkdf2Scheme.Inspect(const AValue: RawByteString): TPwdInfo;
var
  it: Int64;
  s, dk: RawByteString;
begin
  Result := BaseInfo(Self, FPrefix);
  if not Parse(AValue, it, s, dk) then
  begin
    Result.Valid := False;
    Result.CanVerify := False;
    Result.Note := 'malformed PBKDF2 value';
    Exit;
  end;
  Result.Params := Format('iterations=%d, salt=%d bytes', [it, Length(s)]);
  if it > PWD_PBKDF2_MAX_ITERATIONS then
    Result.Note := 'iterations exceed the verification limit';
end;

function TPbkdf2Scheme.Verify(const AValue, APassword: RawByteString;
  out ADetail: string): TPwdStatus;
var
  it: Int64;
  s, dk: RawByteString;
begin
  ADetail := '';
  if not Parse(AValue, it, s, dk) then
  begin
    ADetail := 'malformed PBKDF2 value';
    Exit(psInvalid);
  end;
  if it > PWD_PBKDF2_MAX_ITERATIONS then
  begin
    ADetail := Format('iterations=%d exceed the verification limit', [it]);
    Exit(psOutOfBounds);
  end;
  if ConstantTimeEquals(Pbkdf2Hmac(FAlgo, APassword, s, it, FDkLen), dk) then
    Result := psMatch
  else
    Result := psNoMatch;
end;

function TPbkdf2Scheme.CanGenerate: Boolean;
begin
  Result := True;
end;

function TPbkdf2Scheme.GenerationNote: string;
begin
  Result := 'Format of the OpenLDAP pw-pbkdf2 module (not built in); 389 DS uses its own PBKDF2 formats.';
end;

function TPbkdf2Scheme.Generate(const APassword: RawByteString;
  const AParams: TPwdGenParams): RawByteString;
var
  s: RawByteString;
begin
  if (AParams.Pbkdf2Iterations < 1000) or (AParams.Pbkdf2Iterations > PWD_PBKDF2_MAX_ITERATIONS) then
    raise Exception.Create('PBKDF2 iterations out of the generation policy');
  s := SystemRandomBytes(AParams.SaltBytes);
  Result := FPrefix + IntToStr(AParams.Pbkdf2Iterations) + '$' + Ab64Encode(s) + '$' +
    Ab64Encode(Pbkdf2Hmac(FAlgo, APassword, s, AParams.Pbkdf2Iterations, FDkLen));
end;

end.
