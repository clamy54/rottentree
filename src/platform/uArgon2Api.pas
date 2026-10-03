// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uArgon2Api;

{$mode objfpc}{$H+}

// Liaison libargon2, l'implementation de reference: Argon2d, Argon2i et Argon2id avec
// parallelisme, sel et longueur quelconques. crypto_pwhash de libsodium ne sait faire
// ni Argon2d, ni p > 1, ni un sel autre que 16 octets, d'ou cette dependance de plus.
// Les bornes de cout sont verifiees par l'appelant AVANT tout appel.

interface

uses
  SysUtils, ctypes, dynlibs;

const
  ARGON2_OK = 0;
  ARGON2_VERSION_10 = $10;
  ARGON2_VERSION_13 = $13;

type
  TArgon2Type = (atArgon2d = 0, atArgon2i = 1, atArgon2id = 2);
  EArgon2Error = class(Exception);

procedure Argon2EnsureLoaded;
function Argon2Available: Boolean;

function Argon2RawHash(AType: TArgon2Type; AVersion: Integer; ATimeCost,
  AMemoryKiB, AParallelism: LongWord; const APassword, ASalt: RawByteString;
  AHashLen: Integer): RawByteString;

function Argon2VerifyEncoded(AType: TArgon2Type; const AEncoded,
  APassword: RawByteString): Integer;

implementation

uses
  uNativeLib;

var
  argon2_hash: function(t_cost, m_cost, parallelism: cuint32; pwd: Pointer;
    pwdlen: csize_t; salt: Pointer; saltlen: csize_t; hash: Pointer; hashlen: csize_t;
    encoded: PAnsiChar; encodedlen: csize_t; typ: cint; version: cint): cint; cdecl = nil;
  argon2_error_message: function(error_code: cint): PAnsiChar; cdecl = nil;
  argon2_verify: function(encoded: PAnsiChar; pwd: Pointer; pwdlen: csize_t;
    typ: cint): cint; cdecl = nil;
  GLib: TLibHandle = NilHandle;
  GReady: Boolean = False;
  GLock: TRTLCriticalSection;

function LibNames: TStringArray;
begin
  {$IFDEF WINDOWS}
  Result := ['libargon2.dll'];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := ['libargon2.so.1'];
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := ['libargon2.1.dylib', 'libargon2.dylib'];
  {$ENDIF}
end;

procedure Argon2EnsureLoaded;
var
  path: string;
begin
  // Lecture hors verrou: la barriere publie les pointeurs de fonction avant GReady,
  // indispensable sur les processeurs a ordre faible (ARM64).
  if GReady then
  begin
    ReadBarrier;
    Exit;
  end;
  EnterCriticalSection(GLock);
  try
    if GReady then Exit;
    GLib := LoadNativeLibrary('libargon2', LibNames, path);
    if GLib = NilHandle then
      raise EArgon2Error.Create('libargon2 not found in the expected locations');
    Pointer(argon2_hash) := NativeSymbol(GLib, 'libargon2', 'argon2_hash');
    Pointer(argon2_error_message) := NativeSymbol(GLib, 'libargon2', 'argon2_error_message');
    Pointer(argon2_verify) := NativeSymbol(GLib, 'libargon2', 'argon2_verify');
    SetLoadedLibVersion('libargon2', '20190702');
    // Symboles publies avant le drapeau lu hors verrou.
    WriteBarrier;
    GReady := True;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function Argon2Available: Boolean;
begin
  try
    Argon2EnsureLoaded;
    Result := True;
  except
    on EArgon2Error do
      Result := False;
  end;
end;

function Argon2VerifyEncoded(AType: TArgon2Type; const AEncoded,
  APassword: RawByteString): Integer;
var
  pw: Pointer;
begin
  Argon2EnsureLoaded;
  if APassword = '' then pw := nil else pw := @APassword[1];
  Result := argon2_verify(PAnsiChar(AEncoded), pw, Length(APassword), Ord(AType));
end;

function Argon2RawHash(AType: TArgon2Type; AVersion: Integer; ATimeCost,
  AMemoryKiB, AParallelism: LongWord; const APassword, ASalt: RawByteString;
  AHashLen: Integer): RawByteString;
var
  rc: cint;
  pw, salt: Pointer;
begin
  Argon2EnsureLoaded;
  if AHashLen < 4 then
    raise EArgon2Error.Create('argon2: hash length too small');
  SetLength(Result, AHashLen);
  if APassword = '' then pw := nil else pw := @APassword[1];
  if ASalt = '' then salt := nil else salt := @ASalt[1];
  rc := argon2_hash(ATimeCost, AMemoryKiB, AParallelism, pw, Length(APassword),
    salt, Length(ASalt), @Result[1], AHashLen, nil, 0, Ord(AType), AVersion);
  if rc <> ARGON2_OK then
    raise EArgon2Error.Create('argon2: ' + string(argon2_error_message(rc)));
end;

initialization
  InitCriticalSection(GLock);

finalization
  DoneCriticalSection(GLock);

end.
