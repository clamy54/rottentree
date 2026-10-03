// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSqliteDb;

{$mode objfpc}{$H+}

// Base SQLite en memoire uniquement. Un document ouvert est une entree non fiable:
// Harden passe avant toute requete. Serialize/Deserialize remplacent tout fichier de
// travail: un fichier temporaire en clair ruinerait tout le chiffrement.

interface

uses
  SysUtils, uSqlite3Api;

type
  ESqliteDbError = class(Exception)
  private
    FResultCode: Integer;
  public
    constructor CreateRc(ARc: Integer; const AMsg: string);
    property ResultCode: Integer read FResultCode;
  end;

  TSqliteDb = class;

  TSqliteStmt = class
  private
    FStmt: Psqlite3_stmt;
    FDb: TSqliteDb;
  public
    constructor Create(ADb: TSqliteDb; AStmt: Psqlite3_stmt);
    destructor Destroy; override;
    procedure BindText(AIdx: Integer; const AValue: string);
    procedure BindBlob(AIdx: Integer; const AValue: RawByteString);
    procedure BindInt64(AIdx: Integer; AValue: Int64);
    procedure BindNull(AIdx: Integer);
    function Step: Boolean;
    procedure Reset;
    function ColInt64(ACol: Integer): Int64;
    function ColText(ACol: Integer): string;
    function ColBlob(ACol: Integer): RawByteString;
    function ColIsNull(ACol: Integer): Boolean;
  end;

  TSqliteDb = class
  private
    FDb: Psqlite3;
    FTxDepth: Integer;
    procedure Check(ARc: Integer; const AContext: string);
  public
    constructor CreateMemory;
    destructor Destroy; override;
    procedure LoadImage(const AImage: RawByteString);
    function SaveImage: RawByteString;
    procedure Harden;
    function Prepare(const ASql: string): TSqliteStmt;
    procedure ExecScript(const ASql: string);
    function ExecScalarInt(const ASql: string): Int64;
    function ExecScalarText(const ASql: string): string;
    procedure BeginImmediate;
    procedure Commit;
    procedure Rollback;
    function IntegrityCheckOk: Boolean;
    function GetUserVersion: Int64;
    procedure SetUserVersion(AValue: Int64);
    function GetApplicationId: Int64;
    procedure SetApplicationId(AValue: Int64);
    function Changes: Integer;
    property Handle: Psqlite3 read FDb;
  end;

implementation

uses
  ctypes;

constructor ESqliteDbError.CreateRc(ARc: Integer; const AMsg: string);
begin
  inherited Create(AMsg);
  FResultCode := ARc;
end;

constructor TSqliteStmt.Create(ADb: TSqliteDb; AStmt: Psqlite3_stmt);
begin
  inherited Create;
  FDb := ADb;
  FStmt := AStmt;
end;

destructor TSqliteStmt.Destroy;
begin
  if FStmt <> nil then
    sqlite3_finalize(FStmt);
  inherited Destroy;
end;

procedure TSqliteStmt.BindText(AIdx: Integer; const AValue: string);
begin
  FDb.Check(sqlite3_bind_text(FStmt, AIdx, PAnsiChar(AValue), Length(AValue),
    SQLITE_TRANSIENT), 'bind_text');
end;

procedure TSqliteStmt.BindBlob(AIdx: Integer; const AValue: RawByteString);
var
  p: Pointer;
begin
  if Length(AValue) > 0 then
    p := @AValue[1]
  else
    p := PAnsiChar('');
  FDb.Check(sqlite3_bind_blob(FStmt, AIdx, p, Length(AValue), SQLITE_TRANSIENT), 'bind_blob');
end;

procedure TSqliteStmt.BindInt64(AIdx: Integer; AValue: Int64);
begin
  FDb.Check(sqlite3_bind_int64(FStmt, AIdx, AValue), 'bind_int64');
end;

procedure TSqliteStmt.BindNull(AIdx: Integer);
begin
  FDb.Check(sqlite3_bind_null(FStmt, AIdx), 'bind_null');
end;

function TSqliteStmt.Step: Boolean;
var
  rc: Integer;
begin
  rc := sqlite3_step(FStmt);
  case rc of
    SQLITE_ROW: Result := True;
    SQLITE_DONE: Result := False;
  else
    begin
      Result := False;
      FDb.Check(rc, 'step');
    end;
  end;
end;

procedure TSqliteStmt.Reset;
begin
  FDb.Check(sqlite3_reset(FStmt), 'reset');
end;

function TSqliteStmt.ColInt64(ACol: Integer): Int64;
begin
  Result := sqlite3_column_int64(FStmt, ACol);
end;

function TSqliteStmt.ColText(ACol: Integer): string;
var
  p: PAnsiChar;
  n: Integer;
begin
  p := sqlite3_column_text(FStmt, ACol);
  n := sqlite3_column_bytes(FStmt, ACol);
  SetLength(Result, n);
  if n > 0 then
    Move(p^, Result[1], n);
end;

function TSqliteStmt.ColBlob(ACol: Integer): RawByteString;
var
  p: Pointer;
  n: Integer;
begin
  Result := '';
  p := sqlite3_column_blob(FStmt, ACol);
  n := sqlite3_column_bytes(FStmt, ACol);
  SetLength(Result, n);
  if n > 0 then
    Move(p^, Result[1], n);
end;

function TSqliteStmt.ColIsNull(ACol: Integer): Boolean;
begin
  Result := sqlite3_column_type(FStmt, ACol) = SQLITE_NULL;
end;

procedure TSqliteDb.Check(ARc: Integer; const AContext: string);
var
  msg: string;
begin
  if ARc = SQLITE_OK then Exit;
  if FDb <> nil then
    msg := string(sqlite3_errmsg(FDb))
  else
    msg := 'SQLite error';
  raise ESqliteDbError.CreateRc(ARc, Format('SQLite [%s] rc=%d: %s', [AContext, ARc, msg]));
end;

constructor TSqliteDb.CreateMemory;
var
  rc: Integer;
begin
  inherited Create;
  SqliteEnsureLoaded;
  rc := sqlite3_open_v2(':memory:', FDb, SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or
    SQLITE_OPEN_MEMORY, nil);
  if rc <> SQLITE_OK then
  begin
    if FDb <> nil then
    begin
      sqlite3_close(FDb);
      FDb := nil;
    end;
    raise ESqliteDbError.CreateRc(rc, 'cannot open an in-memory database');
  end;
  Harden;
end;

destructor TSqliteDb.Destroy;
begin
  if FDb <> nil then
    sqlite3_close(FDb);
  inherited Destroy;
end;

procedure TSqliteDb.LoadImage(const AImage: RawByteString);
var
  buf: Pointer;
  rc: Integer;
begin
  if Length(AImage) < 512 then
    raise ESqliteDbError.CreateRc(0, 'database image too short');
  buf := sqlite3_malloc64(Length(AImage));
  if buf = nil then
    raise ESqliteDbError.CreateRc(0, 'out of memory');
  Move(AImage[1], buf^, Length(AImage));
  // FREEONCLOSE: SQLite devient proprietaire du tampon, meme en cas d'echec. Le liberer
  // soi-meme, c'est un double free garanti.
  rc := sqlite3_deserialize(FDb, 'main', buf, Length(AImage), Length(AImage),
    SQLITE_DESERIALIZE_FREEONCLOSE or SQLITE_DESERIALIZE_RESIZEABLE);
  Check(rc, 'deserialize');
  Harden;
end;

function TSqliteDb.SaveImage: RawByteString;
var
  p: Pointer;
  size: cint64;
begin
  Result := '';
  size := 0;
  p := sqlite3_serialize(FDb, 'main', @size, 0);
  if p = nil then
    raise ESqliteDbError.CreateRc(0, 'cannot serialize the database');
  try
    SetLength(Result, size);
    if size > 0 then
      Move(p^, Result[1], size);
    FillChar(p^, size, 0);
  finally
    sqlite3_free(p);
  end;
end;

procedure TSqliteDb.Harden;
begin
  Check(sqlite3_db_config(FDb, SQLITE_DBCONFIG_DEFENSIVE, cint(1), nil), 'defensive');
  if SqliteHasLoadExtension then
    Check(sqlite3_db_config(FDb, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, cint(0), nil),
      'no_load_extension');
  Check(sqlite3_db_config(FDb, SQLITE_DBCONFIG_ENABLE_TRIGGER, cint(0), nil), 'no_trigger');
  Check(sqlite3_db_config(FDb, SQLITE_DBCONFIG_ENABLE_VIEW, cint(0), nil), 'no_view');
  Check(sqlite3_db_config(FDb, SQLITE_DBCONFIG_TRUSTED_SCHEMA, cint(0), nil), 'no_trusted_schema');
  // temp_store=MEMORY: aucun fichier temporaire de tri ou d'index sur disque.
  ExecScript(
    'PRAGMA trusted_schema=OFF;' +
    'PRAGMA foreign_keys=ON;' +
    'PRAGMA recursive_triggers=OFF;' +
    'PRAGMA temp_store=MEMORY;' +
    'PRAGMA secure_delete=ON;');
  sqlite3_limit(FDb, SQLITE_LIMIT_ATTACHED, 0);
  sqlite3_limit(FDb, SQLITE_LIMIT_LENGTH, 32 * 1024 * 1024);
  sqlite3_limit(FDb, SQLITE_LIMIT_SQL_LENGTH, 256 * 1024);
  sqlite3_limit(FDb, SQLITE_LIMIT_COLUMN, 64);
  sqlite3_limit(FDb, SQLITE_LIMIT_EXPR_DEPTH, 100);
  sqlite3_limit(FDb, SQLITE_LIMIT_COMPOUND_SELECT, 8);
  sqlite3_limit(FDb, SQLITE_LIMIT_VDBE_OP, 5000000);
  sqlite3_limit(FDb, SQLITE_LIMIT_FUNCTION_ARG, 8);
  sqlite3_limit(FDb, SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 128);
  sqlite3_limit(FDb, SQLITE_LIMIT_VARIABLE_NUMBER, 64);
  sqlite3_limit(FDb, SQLITE_LIMIT_TRIGGER_DEPTH, 128);
end;

function TSqliteDb.Prepare(const ASql: string): TSqliteStmt;
var
  stmt: Psqlite3_stmt;
  tail: PAnsiChar;
begin
  Check(sqlite3_prepare_v2(FDb, PAnsiChar(ASql), Length(ASql), stmt, tail), 'prepare');
  Result := TSqliteStmt.Create(Self, stmt);
end;

procedure TSqliteDb.ExecScript(const ASql: string);
var
  stmt: Psqlite3_stmt;
  cur, tail: PAnsiChar;
  remaining, rc: Integer;
begin
  cur := PAnsiChar(ASql);
  remaining := Length(ASql);
  while remaining > 0 do
  begin
    Check(sqlite3_prepare_v2(FDb, cur, remaining, stmt, tail), 'prepare');
    if stmt <> nil then
    begin
      repeat
        rc := sqlite3_step(stmt);
      until rc <> SQLITE_ROW;
      sqlite3_finalize(stmt);
      if rc <> SQLITE_DONE then
        Check(rc, 'exec');
    end;
    remaining := remaining - (tail - cur);
    cur := tail;
  end;
end;

function TSqliteDb.ExecScalarInt(const ASql: string): Int64;
var
  st: TSqliteStmt;
begin
  st := Prepare(ASql);
  try
    if not st.Step then
      raise ESqliteDbError.CreateRc(0, 'expected a scalar result');
    Result := st.ColInt64(0);
  finally
    st.Free;
  end;
end;

function TSqliteDb.ExecScalarText(const ASql: string): string;
var
  st: TSqliteStmt;
begin
  st := Prepare(ASql);
  try
    if not st.Step then
      raise ESqliteDbError.CreateRc(0, 'expected a scalar result');
    Result := st.ColText(0);
  finally
    st.Free;
  end;
end;

procedure TSqliteDb.BeginImmediate;
begin
  if FTxDepth = 0 then
    ExecScript('BEGIN IMMEDIATE;')
  else
    ExecScript('SAVEPOINT rt_sp' + IntToStr(FTxDepth) + ';');
  Inc(FTxDepth);
end;

procedure TSqliteDb.Commit;
begin
  if FTxDepth <= 0 then Exit;
  if FTxDepth = 1 then
  begin
    try
      ExecScript('COMMIT;');
    except
      try
        ExecScript('ROLLBACK;');
      except
      end;
      FTxDepth := 0;
      raise;
    end;
    FTxDepth := 0;
  end
  else
  begin
    ExecScript('RELEASE rt_sp' + IntToStr(FTxDepth - 1) + ';');
    Dec(FTxDepth);
  end;
end;

procedure TSqliteDb.Rollback;
begin
  if FTxDepth <= 0 then Exit;
  Dec(FTxDepth);
  if FTxDepth = 0 then
    ExecScript('ROLLBACK;')
  else
    ExecScript('ROLLBACK TO rt_sp' + IntToStr(FTxDepth) + '; RELEASE rt_sp' +
      IntToStr(FTxDepth) + ';');
end;

function TSqliteDb.IntegrityCheckOk: Boolean;
begin
  try
    Result := SameText(ExecScalarText('PRAGMA integrity_check(1);'), 'ok');
  except
    on ESqliteDbError do Result := False;
  end;
end;

function TSqliteDb.GetUserVersion: Int64;
begin
  Result := ExecScalarInt('PRAGMA user_version;');
end;

procedure TSqliteDb.SetUserVersion(AValue: Int64);
begin
  ExecScript(Format('PRAGMA user_version=%d;', [AValue]));
end;

function TSqliteDb.GetApplicationId: Int64;
begin
  Result := ExecScalarInt('PRAGMA application_id;');
end;

procedure TSqliteDb.SetApplicationId(AValue: Int64);
begin
  ExecScript(Format('PRAGMA application_id=%d;', [AValue]));
end;

function TSqliteDb.Changes: Integer;
begin
  Result := sqlite3_changes(FDb);
end;

end.
