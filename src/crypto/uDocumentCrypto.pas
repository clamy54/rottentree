// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDocumentCrypto;

{$mode objfpc}{$H+}

// Cryptographie du document .rtt. Mot de passe -> Argon2id -> cle maitresse, puis une
// sous-cle par usage (enveloppe, secrets) via crypto_kdf. En-tete fixe de 72 octets
// authentifie en AAD, XChaCha20-Poly1305 sur l'image SQLite. Mauvais mot de passe et
// fichier trafique donnent la meme erreur, et c'est voulu.

interface

uses
  SysUtils, uSecureBytes;

const
  RTT_MAGIC: array[0..7] of AnsiChar = 'RTTRDOC1';
  RTT_FORMAT_VERSION = 1;
  RTT_CRYPTO_VERSION = 1;
  RTT_HEADER_BYTES = 72;

  DOC_KDF_OPS_DEFAULT = 3;
  DOC_KDF_MEM_DEFAULT = 256 * 1024 * 1024;
  DOC_KDF_SALT_BYTES = 16;
  DOC_KDF_OPS_MIN = 1;
  DOC_KDF_OPS_MAX = 16;
  DOC_KDF_MEM_MIN = 8 * 1024 * 1024;
  DOC_KDF_MEM_MAX = 1024 * 1024 * 1024;

  DOC_MAX_BYTES = 512 * 1024 * 1024;
  AEAD_KEY_BYTES = 32;
  AEAD_NONCE_BYTES = 24;
  AEAD_TAG_BYTES = 16;

  KDF_CTX_ENVELOPE = 'RTTRenv1';  // crypto_kdf exige 8 octets pile
  KDF_CTX_SECRETS = 'RTTRsec1';
  KDF_ID_ENVELOPE = 1;
  KDF_ID_SECRETS = 2;

type
  EDocumentCrypto = class(Exception);

  THeaderStatus = (hsOk, hsTooShort, hsNotRtt, hsFutureFormat, hsUnsupportedCrypto,
    hsBadKdfParams);

  TEnvelopeHeader = record
    FormatVersion: LongWord;
    CryptoVersion: LongWord;
    Salt: RawByteString;
    Ops: Int64;
    Mem: Int64;
  end;

function KdfParamsAcceptable(ASaltLen: Integer; AOps, AMem: Int64): Boolean;
function ParseEnvelopeHeader(const AData: RawByteString; out AHeader: TEnvelopeHeader): THeaderStatus;
// Parametres KDF hors bornes refuses avant toute allocation: un en-tete hostile ne
// choisit pas la quantite de memoire qu'on lui sacrifie.
function DeriveMasterKey(const APassword: RawByteString; const ASalt: RawByteString;
  AOps, AMem: Int64): TSecureBytes;
function DeriveSubKey(AMaster: TSecureBytes; AId: Int64; const AContext: string): TSecureBytes;
function SealEnvelope(const APayload: RawByteString; AEnvKey: TSecureBytes;
  const AHeader: TEnvelopeHeader): RawByteString;
function OpenEnvelope(const AData: RawByteString; AEnvKey: TSecureBytes;
  out APayload: RawByteString): Boolean;
function SealSecret(ASecretKey: TSecureBytes; const ASecretUuid: string;
  APlain: TSecureBytes): RawByteString;
function OpenSecret(ASecretKey: TSecureBytes; const ASecretUuid: string;
  const ABlob: RawByteString; out APlain: TSecureBytes): Boolean;
function NewUuidV4: string;

implementation

uses
  ctypes, uSodiumApi, uRtBytes;

procedure PutU32(var S: RawByteString; AOffset: Integer; AValue: LongWord);
begin
  S[AOffset] := Char(AValue and $FF);
  S[AOffset + 1] := Char((AValue shr 8) and $FF);
  S[AOffset + 2] := Char((AValue shr 16) and $FF);
  S[AOffset + 3] := Char((AValue shr 24) and $FF);
end;

procedure PutI64(var S: RawByteString; AOffset: Integer; AValue: Int64);
var
  i: Integer;
begin
  for i := 0 to 7 do
    S[AOffset + i] := Char((AValue shr (8 * i)) and $FF);
end;

function GetI64(const S: RawByteString; AOffset: Integer): Int64;
var
  i: Integer;
begin
  Result := 0;
  for i := 7 downto 0 do
    Result := (Result shl 8) or Int64(Byte(S[AOffset + i]));
end;

function KdfParamsAcceptable(ASaltLen: Integer; AOps, AMem: Int64): Boolean;
begin
  Result := (ASaltLen = DOC_KDF_SALT_BYTES) and (AOps >= DOC_KDF_OPS_MIN) and
    (AOps <= DOC_KDF_OPS_MAX) and (AMem >= DOC_KDF_MEM_MIN) and (AMem <= DOC_KDF_MEM_MAX);
end;

function ParseEnvelopeHeader(const AData: RawByteString; out AHeader: TEnvelopeHeader): THeaderStatus;
var
  i: Integer;
begin
  AHeader := Default(TEnvelopeHeader);
  if Length(AData) < 8 then Exit(hsTooShort);
  for i := 0 to 7 do
    if AData[i + 1] <> RTT_MAGIC[i] then Exit(hsNotRtt);
  if Length(AData) < RTT_HEADER_BYTES + AEAD_TAG_BYTES + 1 then Exit(hsTooShort);
  AHeader.FormatVersion := ReadUInt32LE(AData, 9);
  AHeader.CryptoVersion := ReadUInt32LE(AData, 13);
  // Version future: refus sans rien ecraser. Reenregistrer un format qu'on ne comprend
  // pas, c'est le perdre.
  if AHeader.FormatVersion > RTT_FORMAT_VERSION then Exit(hsFutureFormat);
  if (AHeader.FormatVersion = 0) or (AHeader.CryptoVersion <> RTT_CRYPTO_VERSION) then
    Exit(hsUnsupportedCrypto);
  AHeader.Salt := Copy(AData, 17, DOC_KDF_SALT_BYTES);
  AHeader.Ops := GetI64(AData, 33);
  AHeader.Mem := GetI64(AData, 41);
  if not KdfParamsAcceptable(Length(AHeader.Salt), AHeader.Ops, AHeader.Mem) then
    Exit(hsBadKdfParams);
  Result := hsOk;
end;

function DeriveMasterKey(const APassword: RawByteString; const ASalt: RawByteString;
  AOps, AMem: Int64): TSecureBytes;
var
  pw: PAnsiChar;
begin
  SodiumEnsureLoaded;
  if not KdfParamsAcceptable(Length(ASalt), AOps, AMem) then
    raise EDocumentCrypto.Create('key derivation parameters out of bounds');
  Result := TSecureBytes.Create(AEAD_KEY_BYTES);
  try
    if APassword = '' then pw := PAnsiChar('') else pw := @APassword[1];
    if crypto_pwhash(Result.Data, AEAD_KEY_BYTES, pw, Length(APassword), @ASalt[1],
        AOps, AMem, crypto_pwhash_ALG_ARGON2ID13) <> 0 then
      raise EDocumentCrypto.Create('key derivation failed (not enough memory?)');
  except
    Result.Free;
    raise;
  end;
end;

function DeriveSubKey(AMaster: TSecureBytes; AId: Int64; const AContext: string): TSecureBytes;
begin
  SodiumEnsureLoaded;
  if (AMaster = nil) or (AMaster.Len <> crypto_kdf_KEYBYTES) or (Length(AContext) <> 8) then
    raise EDocumentCrypto.Create('invalid key derivation input');
  Result := TSecureBytes.Create(AEAD_KEY_BYTES);
  try
    if crypto_kdf_derive_from_key(Result.Data, AEAD_KEY_BYTES, AId, PAnsiChar(AContext),
        AMaster.Data) <> 0 then
      raise EDocumentCrypto.Create('subkey derivation failed');
  except
    Result.Free;
    raise;
  end;
end;

function SealEnvelope(const APayload: RawByteString; AEnvKey: TSecureBytes;
  const AHeader: TEnvelopeHeader): RawByteString;
var
  nonce: RawByteString;
  clen: cuint64;
begin
  SodiumEnsureLoaded;
  if (AEnvKey = nil) or (AEnvKey.Len <> AEAD_KEY_BYTES) then
    raise EDocumentCrypto.Create('invalid envelope key');
  if APayload = '' then
    raise EDocumentCrypto.Create('empty document');
  if Length(AHeader.Salt) <> DOC_KDF_SALT_BYTES then
    raise EDocumentCrypto.Create('invalid salt');
  nonce := SystemRandomBytes(AEAD_NONCE_BYTES);
  SetLength(Result, RTT_HEADER_BYTES + Length(APayload) + AEAD_TAG_BYTES);
  Move(RTT_MAGIC[0], Result[1], 8);
  PutU32(Result, 9, RTT_FORMAT_VERSION);
  PutU32(Result, 13, RTT_CRYPTO_VERSION);
  Move(AHeader.Salt[1], Result[17], DOC_KDF_SALT_BYTES);
  PutI64(Result, 33, AHeader.Ops);
  PutI64(Result, 41, AHeader.Mem);
  Move(nonce[1], Result[49], AEAD_NONCE_BYTES);
  clen := 0;
  // AAD = en-tete complet: versions et parametres KDF sont authentifies, pas juste lus.
  if crypto_aead_xchacha20poly1305_ietf_encrypt(@Result[RTT_HEADER_BYTES + 1], @clen,
      @APayload[1], Length(APayload), @Result[1], RTT_HEADER_BYTES, nil, @nonce[1],
      AEnvKey.Data) <> 0 then
    raise EDocumentCrypto.Create('document encryption failed');
  SetLength(Result, RTT_HEADER_BYTES + clen);
end;

function OpenEnvelope(const AData: RawByteString; AEnvKey: TSecureBytes;
  out APayload: RawByteString): Boolean;
var
  mlen: cuint64;
  clen: Int64;
begin
  Result := False;
  APayload := '';
  SodiumEnsureLoaded;
  if (AEnvKey = nil) or (AEnvKey.Len <> AEAD_KEY_BYTES) then Exit;
  if (Length(AData) <= RTT_HEADER_BYTES + AEAD_TAG_BYTES) or (Length(AData) > DOC_MAX_BYTES) then
    Exit;
  clen := Length(AData) - RTT_HEADER_BYTES;
  SetLength(APayload, clen - AEAD_TAG_BYTES);
  mlen := 0;
  if crypto_aead_xchacha20poly1305_ietf_decrypt(@APayload[1], @mlen, nil,
      @AData[RTT_HEADER_BYTES + 1], clen, @AData[1], RTT_HEADER_BYTES,
      @AData[49], AEnvKey.Data) <> 0 then
  begin
    APayload := '';
    Exit;
  end;
  SetLength(APayload, mlen);
  Result := True;
end;

function SecretAad(const AUuid: string): RawByteString;
begin
  Result := 'Rottentree/secret/v1' + #10 + AUuid;
end;

function SealSecret(ASecretKey: TSecureBytes; const ASecretUuid: string;
  APlain: TSecureBytes): RawByteString;
var
  nonce, aad: RawByteString;
  clen: cuint64;
  p: PByte;
begin
  SodiumEnsureLoaded;
  nonce := SystemRandomBytes(AEAD_NONCE_BYTES);
  aad := SecretAad(ASecretUuid);
  SetLength(Result, AEAD_NONCE_BYTES + APlain.Len + AEAD_TAG_BYTES);
  Move(nonce[1], Result[1], AEAD_NONCE_BYTES);
  clen := 0;
  if APlain.Len = 0 then p := nil else p := APlain.Data;
  if crypto_aead_xchacha20poly1305_ietf_encrypt(@Result[AEAD_NONCE_BYTES + 1], @clen,
      p, APlain.Len, @aad[1], Length(aad), nil, @nonce[1], ASecretKey.Data) <> 0 then
    raise EDocumentCrypto.Create('secret encryption failed');
  SetLength(Result, AEAD_NONCE_BYTES + clen);
end;

function OpenSecret(ASecretKey: TSecureBytes; const ASecretUuid: string;
  const ABlob: RawByteString; out APlain: TSecureBytes): Boolean;
var
  aad: RawByteString;
  mlen: cuint64;
  clen: Integer;
begin
  Result := False;
  APlain := nil;
  SodiumEnsureLoaded;
  if Length(ABlob) < AEAD_NONCE_BYTES + AEAD_TAG_BYTES then Exit;
  if Length(ABlob) > 1024 * 1024 then Exit;
  clen := Length(ABlob) - AEAD_NONCE_BYTES;
  aad := SecretAad(ASecretUuid);
  APlain := TSecureBytes.Create(clen - AEAD_TAG_BYTES);
  mlen := 0;
  if crypto_aead_xchacha20poly1305_ietf_decrypt(APlain.Data, @mlen, nil,
      @ABlob[AEAD_NONCE_BYTES + 1], clen, @aad[1], Length(aad), @ABlob[1],
      ASecretKey.Data) <> 0 then
  begin
    FreeAndNil(APlain);
    Exit;
  end;
  Result := True;
end;

function NewUuidV4: string;
var
  b: RawByteString;
  h: string;
begin
  b := SystemRandomBytes(16);
  b[7] := Char((Byte(b[7]) and $0F) or $40);
  b[9] := Char((Byte(b[9]) and $3F) or $80);
  h := HexEncode(b);
  Result := Copy(h, 1, 8) + '-' + Copy(h, 9, 4) + '-' + Copy(h, 13, 4) + '-' +
    Copy(h, 17, 4) + '-' + Copy(h, 21, 12);
end;

end.
