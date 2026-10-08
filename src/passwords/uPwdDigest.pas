// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPwdDigest;

{$mode objfpc}{$H+}

// {MD5} {SMD5} {SHA} {SSHA} {SHA256}... (base64 du condensat et du sel) et valeurs en
// clair, avec ou sans prefixe. Des empreintes rapides: un GPU en fait son quatre-heures.

interface

uses
  SysUtils, uPwdCore;

type
  TDigestScheme = class(TPasswordScheme)
  private
    FId, FPrefix, FAlgo: string;
    FSalted: Boolean;
    FDigestLen: Integer;
    FRec: TPwdRecommendation;
    function Decode(const AValue: RawByteString; out ADigest, ASalt: RawByteString): Boolean;
  public
    constructor Create(const AId, APrefix, AAlgo: string; ADigestLen: Integer;
      ASalted: Boolean; ARec: TPwdRecommendation);
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

  TCleartextScheme = class(TPasswordScheme)
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

  // Du clair avec une etiquette ({CLEAR}, {PLAIN}) ou un deguisement ({BASE64}): du clair.
  TTaggedCleartextScheme = class(TPasswordScheme)
  private
    FId, FPrefix, FGenNote: string;
    FBase64: Boolean;
    FServers: TPwdServers;
    function Decode(const AValue: RawByteString; out AClear: RawByteString): Boolean;
  public
    constructor Create(const AId, APrefix: string; AServers: TPwdServers; const AGenNote: string;
      ABase64: Boolean = False);
    function Id: string; override;
    function DisplayName: string; override;
    function Recommendation: TPwdRecommendation; override;
    function Matches(const AValue: RawByteString): Boolean; override;
    function Inspect(const AValue: RawByteString): TPwdInfo; override;
    function Verify(const AValue, APassword: RawByteString; out ADetail: string): TPwdStatus; override;
    function CanGenerate: Boolean; override;
    function Generate(const APassword: RawByteString; const AParams: TPwdGenParams): RawByteString; override;
    function GenerationNote: string; override;
    function Servers: TPwdServers; override;
  end;

implementation

uses
  uRtBytes, uOpenSslApi;

constructor TDigestScheme.Create(const AId, APrefix, AAlgo: string; ADigestLen: Integer;
  ASalted: Boolean; ARec: TPwdRecommendation);
begin
  inherited Create;
  FId := AId;
  FPrefix := APrefix;
  FAlgo := AAlgo;
  FDigestLen := ADigestLen;
  FSalted := ASalted;
  FRec := ARec;
end;

function TDigestScheme.Id: string;
begin
  Result := FId;
end;

function TDigestScheme.DisplayName: string;
begin
  if FSalted then
    Result := 'Salted ' + FAlgo + ' ' + FPrefix
  else
    Result := FAlgo + ' ' + FPrefix;
end;

function TDigestScheme.Recommendation: TPwdRecommendation;
begin
  Result := FRec;
end;

function TDigestScheme.Matches(const AValue: RawByteString): Boolean;
var
  rest: RawByteString;
begin
  Result := HasPrefix(AValue, FPrefix, rest);
end;

function TDigestScheme.Decode(const AValue: RawByteString; out ADigest, ASalt: RawByteString): Boolean;
var
  rest, raw: RawByteString;
begin
  Result := False;
  ADigest := '';
  ASalt := '';
  if not HasPrefix(AValue, FPrefix, rest) then Exit;
  if Length(rest) > PWD_MAX_VALUE_BYTES then Exit;
  if not Base64DecodeStrict(Trim(rest), raw) then Exit;
  if FSalted then
  begin
    if (Length(raw) <= FDigestLen) or (Length(raw) - FDigestLen > PWD_MAX_SALT_BYTES) then Exit;
    ADigest := Copy(raw, 1, FDigestLen);
    ASalt := Copy(raw, FDigestLen + 1, MaxInt);
  end
  else
  begin
    if Length(raw) <> FDigestLen then Exit;
    ADigest := raw;
  end;
  Result := True;
end;

function TDigestScheme.Inspect(const AValue: RawByteString): TPwdInfo;
var
  d, s: RawByteString;
begin
  Result := BaseInfo(Self, FPrefix);
  // Une passe de condensat, meme salee, se brute-force compte par compte au tarif GPU.
  // Sans sel, MD5 et SHA-1 ne se cassent meme plus: ils se consultent.
  if not FSalted and ((FAlgo = 'MD5') or (FAlgo = 'SHA1')) then
    Result.Storage := pslBroken
  else
    Result.Storage := pslWeak;
  if not Decode(AValue, d, s) then
  begin
    Result.Valid := False;
    Result.CanVerify := False;
    Result.Note := 'malformed base64 or unexpected length';
    Exit;
  end;
  if FSalted then
    Result.Params := Format('salt=%d bytes', [Length(s)]);
  Result.Note := 'one digest pass; no adaptive cost';
end;

function TDigestScheme.Verify(const AValue, APassword: RawByteString;
  out ADetail: string): TPwdStatus;
var
  d, s: RawByteString;
begin
  ADetail := '';
  if not Decode(AValue, d, s) then
  begin
    ADetail := 'malformed value';
    Exit(psInvalid);
  end;
  if ConstantTimeEquals(DigestOf(FAlgo, APassword + s), d) then
    Result := psMatch
  else
    Result := psNoMatch;
end;

function TDigestScheme.CanGenerate: Boolean;
begin
  Result := True;
end;

function TDigestScheme.GenerationNote: string;
begin
  if not FSalted or (FAlgo = 'MD5') then
    Result := 'Legacy format, for old servers and migrations only.'
  else if FAlgo = 'SHA1' then
    Result := 'Built into every LDAP server (OpenLDAP without module, 389 DS, ApacheDS, OpenDJ): ' +
      'the portable choice, but a single salted SHA-1 round. Prefer a stronger format when the ' +
      'server supports it.'
  else
    Result := 'OpenLDAP needs its pw-sha2 module; built into 389 DS, ApacheDS and OpenDJ.';
end;

function TDigestScheme.Generate(const APassword: RawByteString;
  const AParams: TPwdGenParams): RawByteString;
var
  s: RawByteString;
begin
  s := '';
  if FSalted then
    s := RandomSalt(8);
  Result := FPrefix + Base64EncodeStr(DigestOf(FAlgo, APassword + s) + s);
end;

function TCleartextScheme.Id: string;
begin
  Result := 'CLEARTEXT';
end;

function TCleartextScheme.DisplayName: string;
begin
  Result := 'Cleartext (no scheme)';
end;

function TCleartextScheme.Recommendation: TPwdRecommendation;
begin
  Result := prCleartext;
end;

function TCleartextScheme.Matches(const AValue: RawByteString): Boolean;
begin
  Result := not LooksLikeSchemePrefix(AValue);
end;

function TCleartextScheme.Inspect(const AValue: RawByteString): TPwdInfo;
begin
  Result := BaseInfo(Self, '');
  Result.Note := 'stored in cleartext';
end;

function TCleartextScheme.Verify(const AValue, APassword: RawByteString;
  out ADetail: string): TPwdStatus;
begin
  ADetail := '';
  if ConstantTimeEquals(AValue, APassword) then Result := psMatch else Result := psNoMatch;
end;

function TCleartextScheme.CanGenerate: Boolean;
begin
  Result := True;
end;

function TCleartextScheme.GenerationNote: string;
begin
  Result := 'Stored as typed: anyone who can read the entry reads the password.';
end;

function TCleartextScheme.Generate(const APassword: RawByteString;
  const AParams: TPwdGenParams): RawByteString;
begin
  if LooksLikeSchemePrefix(APassword) then
    raise Exception.Create('a cleartext value starting with a scheme prefix would be ambiguous: ' +
      'pick that format instead (SASL for a {SASL} identity)');
  Result := APassword;
end;

constructor TTaggedCleartextScheme.Create(const AId, APrefix: string; AServers: TPwdServers;
  const AGenNote: string; ABase64: Boolean);
begin
  inherited Create;
  FId := AId;
  FPrefix := APrefix;
  FServers := AServers;
  FGenNote := AGenNote;
  FBase64 := ABase64;
end;

function TTaggedCleartextScheme.CanGenerate: Boolean;
begin
  Result := True;
end;

function TTaggedCleartextScheme.GenerationNote: string;
begin
  Result := FGenNote;
end;

function TTaggedCleartextScheme.Servers: TPwdServers;
begin
  Result := FServers;
end;

function TTaggedCleartextScheme.Generate(const APassword: RawByteString;
  const AParams: TPwdGenParams): RawByteString;
begin
  if Length(APassword) > PWD_MAX_VALUE_BYTES then
    raise Exception.Create('the password is too long');
  if FBase64 then
    Result := FPrefix + Base64EncodeStr(APassword)
  else
    Result := FPrefix + APassword;
end;

function TTaggedCleartextScheme.Id: string;
begin
  Result := FId;
end;

function TTaggedCleartextScheme.DisplayName: string;
begin
  if FBase64 then
    Result := 'Base64-encoded cleartext ' + FPrefix
  else
    Result := 'Cleartext ' + FPrefix;
end;

function TTaggedCleartextScheme.Recommendation: TPwdRecommendation;
begin
  Result := prCleartext;
end;

function TTaggedCleartextScheme.Matches(const AValue: RawByteString): Boolean;
var
  rest: RawByteString;
begin
  Result := HasPrefix(AValue, FPrefix, rest);
end;

function TTaggedCleartextScheme.Decode(const AValue: RawByteString;
  out AClear: RawByteString): Boolean;
var
  rest: RawByteString;
begin
  AClear := '';
  if not HasPrefix(AValue, FPrefix, rest) then Exit(False);
  if Length(rest) > PWD_MAX_VALUE_BYTES then Exit(False);
  if FBase64 then
    Result := Base64DecodeStrict(rest, AClear)
  else
  begin
    AClear := rest;
    Result := True;
  end;
end;

function TTaggedCleartextScheme.Inspect(const AValue: RawByteString): TPwdInfo;
var
  clear: RawByteString;
begin
  Result := BaseInfo(Self, FPrefix);
  if not Decode(AValue, clear) then
  begin
    Result.Valid := False;
    Result.CanVerify := False;
    Result.Note := 'malformed base64';
  end
  else if FBase64 then
    Result.Note := 'stored in cleartext: base64 is an encoding, not a hash'
  else
    Result.Note := 'stored in cleartext behind a prefix';
  WipeString(clear);
end;

function TTaggedCleartextScheme.Verify(const AValue, APassword: RawByteString;
  out ADetail: string): TPwdStatus;
var
  clear: RawByteString;
begin
  ADetail := '';
  if not Decode(AValue, clear) then
  begin
    ADetail := 'malformed value';
    Exit(psInvalid);
  end;
  if ConstantTimeEquals(clear, APassword) then Result := psMatch else Result := psNoMatch;
  WipeString(clear);
end;

end.
