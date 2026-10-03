// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSqlite3Api;

{$mode objfpc}{$H+}

// Liaison dynamique SQLite, avec sqlite3_serialize/sqlite3_deserialize: le document
// dechiffre ne vit qu'en memoire, jamais dans un fichier temporaire ni dans un WAL.
// sqlite3_db_config est variadique, d'ou le cdecl varargs.

interface

uses
  SysUtils, ctypes;

const
  SQLITE_OK = 0;
  SQLITE_ROW = 100;
  SQLITE_DONE = 101;

  SQLITE_OPEN_READONLY = $0001;
  SQLITE_OPEN_READWRITE = $0002;
  SQLITE_OPEN_CREATE = $0004;
  SQLITE_OPEN_MEMORY = $0080;
  SQLITE_OPEN_NOMUTEX = $8000;

  SQLITE_INTEGER = 1;
  SQLITE_FLOAT = 2;
  SQLITE_TEXT = 3;
  SQLITE_BLOB = 4;
  SQLITE_NULL = 5;

  SQLITE_DBCONFIG_ENABLE_TRIGGER = 1003;
  SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION = 1005;
  SQLITE_DBCONFIG_DEFENSIVE = 1010;
  SQLITE_DBCONFIG_ENABLE_VIEW = 1015;
  SQLITE_DBCONFIG_TRUSTED_SCHEMA = 1017;

  SQLITE_LIMIT_LENGTH = 0;
  SQLITE_LIMIT_SQL_LENGTH = 1;
  SQLITE_LIMIT_COLUMN = 2;
  SQLITE_LIMIT_EXPR_DEPTH = 3;
  SQLITE_LIMIT_COMPOUND_SELECT = 4;
  SQLITE_LIMIT_VDBE_OP = 5;
  SQLITE_LIMIT_FUNCTION_ARG = 6;
  SQLITE_LIMIT_ATTACHED = 7;
  SQLITE_LIMIT_LIKE_PATTERN_LENGTH = 8;
  SQLITE_LIMIT_VARIABLE_NUMBER = 9;
  SQLITE_LIMIT_TRIGGER_DEPTH = 10;

  SQLITE_DESERIALIZE_FREEONCLOSE = 1;
  SQLITE_DESERIALIZE_RESIZEABLE = 2;

  // 3.36: premiere version ou serialize/deserialize sont compiles par defaut.
  SQLITE_MIN_VERSION_NUMBER = 3036000;

type
  ESqliteApiError = class(Exception);

  Psqlite3 = Pointer;
  Psqlite3_stmt = Pointer;

var
  sqlite3_libversion_number: function: cint; cdecl = nil;
  sqlite3_libversion: function: PAnsiChar; cdecl = nil;
  sqlite3_open_v2: function(filename: PAnsiChar; out db: Psqlite3; flags: cint;
    vfs: PAnsiChar): cint; cdecl = nil;
  sqlite3_close: function(db: Psqlite3): cint; cdecl = nil;
  sqlite3_errmsg: function(db: Psqlite3): PAnsiChar; cdecl = nil;
  sqlite3_extended_errcode: function(db: Psqlite3): cint; cdecl = nil;
  sqlite3_prepare_v2: function(db: Psqlite3; zSql: PAnsiChar; nByte: cint;
    out stmt: Psqlite3_stmt; out zTail: PAnsiChar): cint; cdecl = nil;
  sqlite3_step: function(stmt: Psqlite3_stmt): cint; cdecl = nil;
  sqlite3_finalize: function(stmt: Psqlite3_stmt): cint; cdecl = nil;
  sqlite3_reset: function(stmt: Psqlite3_stmt): cint; cdecl = nil;
  sqlite3_bind_int64: function(stmt: Psqlite3_stmt; idx: cint; v: cint64): cint; cdecl = nil;
  sqlite3_bind_text: function(stmt: Psqlite3_stmt; idx: cint; v: PAnsiChar; n: cint;
    destr: Pointer): cint; cdecl = nil;
  sqlite3_bind_blob: function(stmt: Psqlite3_stmt; idx: cint; v: Pointer; n: cint;
    destr: Pointer): cint; cdecl = nil;
  sqlite3_bind_null: function(stmt: Psqlite3_stmt; idx: cint): cint; cdecl = nil;
  sqlite3_column_count: function(stmt: Psqlite3_stmt): cint; cdecl = nil;
  sqlite3_column_type: function(stmt: Psqlite3_stmt; col: cint): cint; cdecl = nil;
  sqlite3_column_int64: function(stmt: Psqlite3_stmt; col: cint): cint64; cdecl = nil;
  sqlite3_column_text: function(stmt: Psqlite3_stmt; col: cint): PAnsiChar; cdecl = nil;
  sqlite3_column_blob: function(stmt: Psqlite3_stmt; col: cint): Pointer; cdecl = nil;
  sqlite3_column_bytes: function(stmt: Psqlite3_stmt; col: cint): cint; cdecl = nil;
  sqlite3_changes: function(db: Psqlite3): cint; cdecl = nil;
  sqlite3_limit: function(db: Psqlite3; id, newVal: cint): cint; cdecl = nil;
  sqlite3_db_config: function(db: Psqlite3; op: cint): cint; cdecl; varargs = nil;
  sqlite3_serialize: function(db: Psqlite3; zSchema: PAnsiChar; piSize: pcint64;
    mFlags: cuint): Pointer; cdecl = nil;
  sqlite3_deserialize: function(db: Psqlite3; zSchema: PAnsiChar; pData: Pointer;
    szDb, szBuf: cint64; mFlags: cuint): cint; cdecl = nil;
  sqlite3_malloc64: function(n: cuint64): Pointer; cdecl = nil;
  sqlite3_free: procedure(p: Pointer); cdecl = nil;

function SQLITE_TRANSIENT: Pointer; inline;

procedure SqliteEnsureLoaded;
function SqliteIsLoaded: Boolean;
function SqliteHasLoadExtension: Boolean;

implementation

uses
  dynlibs, uNativeLib;

var
  GLib: TLibHandle = NilHandle;
  GReady: Boolean = False;
  GHasLoadExtension: Boolean = False;
  GInitLock: TRTLCriticalSection;

function SQLITE_TRANSIENT: Pointer; inline;
begin
  Result := {%H-}Pointer(PtrInt(-1));
end;

function LibNames: TStringArray;
begin
  {$IFDEF WINDOWS}
  Result := ['libsqlite3-0.dll', 'sqlite3.dll'];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := ['libsqlite3.so.0'];
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := ['libsqlite3.dylib', 'libsqlite3.0.dylib'];
  {$ENDIF}
end;

procedure SqliteEnsureLoaded;
var
  path: string;

  function S(const AName: string): Pointer;
  begin
    Result := NativeSymbol(GLib, 'sqlite3', AName);
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
    GLib := LoadNativeLibrary('SQLite', LibNames, path);
    if GLib = NilHandle then
      raise ESqliteApiError.Create('SQLite not found in the expected locations');
    Pointer(sqlite3_libversion_number) := S('sqlite3_libversion_number');
    if sqlite3_libversion_number() < SQLITE_MIN_VERSION_NUMBER then
      raise ESqliteApiError.CreateFmt('SQLite is too old (%d < %d)',
        [sqlite3_libversion_number(), SQLITE_MIN_VERSION_NUMBER]);
    Pointer(sqlite3_libversion) := S('sqlite3_libversion');
    Pointer(sqlite3_open_v2) := S('sqlite3_open_v2');
    Pointer(sqlite3_close) := S('sqlite3_close');
    Pointer(sqlite3_errmsg) := S('sqlite3_errmsg');
    Pointer(sqlite3_extended_errcode) := S('sqlite3_extended_errcode');
    Pointer(sqlite3_prepare_v2) := S('sqlite3_prepare_v2');
    Pointer(sqlite3_step) := S('sqlite3_step');
    Pointer(sqlite3_finalize) := S('sqlite3_finalize');
    Pointer(sqlite3_reset) := S('sqlite3_reset');
    Pointer(sqlite3_bind_int64) := S('sqlite3_bind_int64');
    Pointer(sqlite3_bind_text) := S('sqlite3_bind_text');
    Pointer(sqlite3_bind_blob) := S('sqlite3_bind_blob');
    Pointer(sqlite3_bind_null) := S('sqlite3_bind_null');
    Pointer(sqlite3_column_count) := S('sqlite3_column_count');
    Pointer(sqlite3_column_type) := S('sqlite3_column_type');
    Pointer(sqlite3_column_int64) := S('sqlite3_column_int64');
    Pointer(sqlite3_column_text) := S('sqlite3_column_text');
    Pointer(sqlite3_column_blob) := S('sqlite3_column_blob');
    Pointer(sqlite3_column_bytes) := S('sqlite3_column_bytes');
    Pointer(sqlite3_changes) := S('sqlite3_changes');
    Pointer(sqlite3_limit) := S('sqlite3_limit');
    Pointer(sqlite3_db_config) := S('sqlite3_db_config');
    Pointer(sqlite3_serialize) := S('sqlite3_serialize');
    Pointer(sqlite3_deserialize) := S('sqlite3_deserialize');
    Pointer(sqlite3_malloc64) := S('sqlite3_malloc64');
    Pointer(sqlite3_free) := S('sqlite3_free');
    GHasLoadExtension := GetProcedureAddress(GLib, 'sqlite3_enable_load_extension') <> nil;
    SetLoadedLibVersion('SQLite', string(sqlite3_libversion()));
    // Symboles publies avant le drapeau lu hors verrou.
    WriteBarrier;
    GReady := True;
  finally
    LeaveCriticalSection(GInitLock);
  end;
end;

function SqliteHasLoadExtension: Boolean;
begin
  Result := GHasLoadExtension;
end;

function SqliteIsLoaded: Boolean;
begin
  Result := GReady;
end;

initialization
  InitCriticalSection(GInitLock);

finalization
  DoneCriticalSection(GInitLock);

end.
