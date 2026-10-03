// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSodiumApi;

{$mode objfpc}{$H+}

// Liaison dynamique de libsodium: alea systeme, Argon2id, XChaCha20-Poly1305,
// derivation de sous-cles, BLAKE2b et memoire protegee. Chargee par uNativeLib, jamais
// depuis le repertoire courant ni le PATH.

interface

uses
  SysUtils, ctypes;

const
  crypto_pwhash_ALG_ARGON2I13 = 1;
  crypto_pwhash_ALG_ARGON2ID13 = 2;
  crypto_pwhash_SALTBYTES = 16;

  crypto_aead_xchacha20poly1305_ietf_KEYBYTES = 32;
  crypto_aead_xchacha20poly1305_ietf_NPUBBYTES = 24;
  crypto_aead_xchacha20poly1305_ietf_ABYTES = 16;

  crypto_kdf_KEYBYTES = 32;
  crypto_kdf_CONTEXTBYTES = 8;

  crypto_generichash_BYTES = 32;
  crypto_generichash_KEYBYTES = 32;

type
  ESodiumError = class(Exception);

var
  sodium_init: function: cint; cdecl = nil;
  sodium_version_string: function: PAnsiChar; cdecl = nil;
  randombytes_buf: procedure(buf: Pointer; size: csize_t); cdecl = nil;
  crypto_pwhash: function(outp: PByte; outlen: cuint64; passwd: PAnsiChar;
    passwdlen: cuint64; salt: PByte; opslimit: cuint64; memlimit: csize_t;
    alg: cint): cint; cdecl = nil;
  crypto_pwhash_str_verify: function(str: PAnsiChar; passwd: PAnsiChar;
    passwdlen: cuint64): cint; cdecl = nil;
  crypto_aead_xchacha20poly1305_ietf_encrypt: function(c: PByte; clen_p: pcuint64;
    m: PByte; mlen: cuint64; ad: PByte; adlen: cuint64; nsec: PByte; npub: PByte;
    k: PByte): cint; cdecl = nil;
  crypto_aead_xchacha20poly1305_ietf_decrypt: function(m: PByte; mlen_p: pcuint64;
    nsec: PByte; c: PByte; clen: cuint64; ad: PByte; adlen: cuint64; npub: PByte;
    k: PByte): cint; cdecl = nil;
  crypto_kdf_derive_from_key: function(subkey: PByte; subkey_len: csize_t;
    subkey_id: cuint64; ctx: PAnsiChar; key: PByte): cint; cdecl = nil;
  crypto_generichash: function(outp: PByte; outlen: csize_t; inp: PByte;
    inlen: cuint64; key: PByte; keylen: csize_t): cint; cdecl = nil;
  sodium_malloc: function(size: csize_t): Pointer; cdecl = nil;
  sodium_free: procedure(ptr: Pointer); cdecl = nil;
  sodium_mlock: function(addr: Pointer; len: csize_t): cint; cdecl = nil;
  sodium_munlock: function(addr: Pointer; len: csize_t): cint; cdecl = nil;
  sodium_memzero: procedure(pnt: Pointer; len: csize_t); cdecl = nil;
  sodium_memcmp: function(b1, b2: Pointer; len: csize_t): cint; cdecl = nil;

procedure SodiumEnsureLoaded;

function SystemRandomBytes(ACount: Integer): RawByteString;

implementation

uses
  dynlibs, uNativeLib;

var
  GLib: TLibHandle = NilHandle;
  GReady: Boolean = False;
  GInitLock: TRTLCriticalSection;

function LibNames: TStringArray;
begin
  {$IFDEF WINDOWS}
  Result := ['libsodium-26.dll', 'libsodium.dll'];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := ['libsodium.so.26', 'libsodium.so.23'];
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := ['libsodium.26.dylib', 'libsodium.dylib'];
  {$ENDIF}
end;

procedure SodiumEnsureLoaded;
var
  path: string;

  function S(const AName: string): Pointer;
  begin
    Result := NativeSymbol(GLib, 'libsodium', AName);
  end;

begin
  // Lecture hors verrou: la barriere publie les pointeurs de fonction avant GReady,
  // indispensable sur les processeurs a ordre faible (ARM64).
  if GReady then
  begin
    ReadBarrier;
    Exit;
  end;
  EnterCriticalSection(GInitLock);
  try
    if GReady then Exit;
    GLib := LoadNativeLibrary('libsodium', LibNames, path);
    if GLib = NilHandle then
      raise ESodiumError.Create('libsodium not found in the expected locations');
    Pointer(sodium_init) := S('sodium_init');
    Pointer(sodium_version_string) := S('sodium_version_string');
    Pointer(randombytes_buf) := S('randombytes_buf');
    Pointer(crypto_pwhash) := S('crypto_pwhash');
    Pointer(crypto_pwhash_str_verify) := S('crypto_pwhash_str_verify');
    Pointer(crypto_aead_xchacha20poly1305_ietf_encrypt) :=
      S('crypto_aead_xchacha20poly1305_ietf_encrypt');
    Pointer(crypto_aead_xchacha20poly1305_ietf_decrypt) :=
      S('crypto_aead_xchacha20poly1305_ietf_decrypt');
    Pointer(crypto_kdf_derive_from_key) := S('crypto_kdf_derive_from_key');
    Pointer(crypto_generichash) := S('crypto_generichash');
    Pointer(sodium_malloc) := S('sodium_malloc');
    Pointer(sodium_free) := S('sodium_free');
    Pointer(sodium_mlock) := S('sodium_mlock');
    Pointer(sodium_munlock) := S('sodium_munlock');
    Pointer(sodium_memzero) := S('sodium_memzero');
    Pointer(sodium_memcmp) := S('sodium_memcmp');
    if sodium_init() < 0 then
      raise ESodiumError.Create('sodium_init failed');
    SetLoadedLibVersion('libsodium', string(sodium_version_string()));
    // Symboles publies avant le drapeau lu hors verrou.
    WriteBarrier;
    GReady := True;
  finally
    LeaveCriticalSection(GInitLock);
  end;
end;

function SystemRandomBytes(ACount: Integer): RawByteString;
begin
  SodiumEnsureLoaded;
  Result := '';
  SetLength(Result, ACount);
  if ACount > 0 then
    randombytes_buf(@Result[1], ACount);
end;

initialization
  InitCriticalSection(GInitLock);

finalization
  DoneCriticalSection(GInitLock);

end.
