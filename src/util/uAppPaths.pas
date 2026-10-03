// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAppPaths;

{$mode objfpc}{$H+}

// Repertoires applicatifs et verrou consultatif de document. Le verrou porte sur un
// temoin dans <app-data>/locks, pas sur le .rtt, que la sauvegarde atomique remplace.

interface

const
  RT_APP_DIR_NAME = 'Rottentree';

function AppDataDir: string;
function EnsurePrivateDir(const APath: string): Boolean;
function DocumentLockPath(const APath: string): string;
type
  // Une erreur (permissions, dossier inaccessible) n'autorise jamais l'ecriture.
  TLockOutcome = (loAcquired, loHeldByOther, loError);

function TryLockDocument(const APath: string; out AOutcome: TLockOutcome): THandle;
procedure UnlockDocument(AHandle: THandle);

implementation

uses
  SysUtils, sha1, uSafeSave
  {$IFDEF UNIX}, BaseUnix, Unix{$ENDIF};

{$IFDEF WINDOWS}
const
  ERROR_SHARING_VIOLATION_ = 32;
  ERROR_LOCK_VIOLATION_ = 33;

function GetLastError: LongWord; stdcall; external 'kernel32.dll';
{$ENDIF}

function AppDataDir: string;
{$IFDEF DARWIN}
begin
  Result := GetEnvironmentVariable('HOME') + '/Library/Application Support/' + RT_APP_DIR_NAME;
end;
{$ELSE}
{$IFDEF WINDOWS}
begin
  Result := GetEnvironmentVariable('APPDATA') + '\' + RT_APP_DIR_NAME;
end;
{$ELSE}
var
  base: string;
begin
  base := GetEnvironmentVariable('XDG_DATA_HOME');
  if base = '' then
    base := GetEnvironmentVariable('HOME') + '/.local/share';
  Result := base + '/' + RT_APP_DIR_NAME;
end;
{$ENDIF}
{$ENDIF}

function EnsurePrivateDir(const APath: string): Boolean;
begin
  Result := DirectoryExists(APath) or ForceDirectories(APath);
  if Result then
    MakePrivateDir(APath);
end;

function DocumentLockPath(const APath: string): string;
var
  canon, dir: string;
begin
  Result := '';
  if APath = '' then Exit;
  // Identite physique complete: un lien sur un dossier intermediaire, une jonction ou
  // un nom court ne donnent jamais un second nom de verrou pour le meme fichier.
  // Identite introuvable: pas de verrou, donc pas d'ecriture.
  try
    canon := CanonicalFilePath(APath);
  except
    Exit;
  end;
  {$IFDEF WINDOWS}
  canon := LowerCase(canon);
  {$ENDIF}
  dir := AppDataDir + PathDelim + 'locks';
  if not (EnsurePrivateDir(AppDataDir) and EnsurePrivateDir(dir)) then Exit;
  Result := dir + PathDelim + SHA1Print(SHA1String(canon)) + '.lock';
end;

function TryLockDocument(const APath: string; out AOutcome: TLockOutcome): THandle;
{$IFDEF UNIX}
var
  fd: cint;
  err: cint;
  lockPath: string;
begin
  Result := THandle(-1);
  AOutcome := loError;
  lockPath := DocumentLockPath(APath);
  if lockPath = '' then Exit;
  fd := FpOpen(lockPath, O_RDWR or O_CREAT, &600);
  if fd < 0 then Exit;
  // flock et non fcntl: un verrou POSIX tombe au premier fd ferme sur le fichier.
  // fpFlock et non le flock de la libc: sous Linux la RTL tient son propre errno, et
  // fpgeterrno ne lit pas celui de la libc.
  if fpFlock(fd, LOCK_EX or LOCK_NB) = 0 then
  begin
    Result := THandle(fd);
    AOutcome := loAcquired;
  end
  else
  begin
    // Pas d'ensemble: sous Darwin EWOULDBLOCK = EAGAIN, element duplique.
    err := fpgeterrno;
    if (err = ESysEWOULDBLOCK) or (err = ESysEAGAIN) then
      AOutcome := loHeldByOther;
    FpClose(fd);
  end;
end;
{$ELSE}
var
  lockPath: string;
  err: LongWord;
begin
  Result := THandle(-1);
  AOutcome := loError;
  lockPath := DocumentLockPath(APath);
  if lockPath = '' then Exit;
  if not FileExists(lockPath) then
  begin
    Result := FileCreate(lockPath, fmShareExclusive, &600);
    if Result <> THandle(-1) then
    begin
      AOutcome := loAcquired;
      Exit;
    end;
  end;
  Result := FileOpen(lockPath, fmOpenReadWrite or fmShareExclusive);
  if Result <> THandle(-1) then
    AOutcome := loAcquired
  else
  begin
    err := GetLastError;
    if (err = ERROR_SHARING_VIOLATION_) or (err = ERROR_LOCK_VIOLATION_) then
      AOutcome := loHeldByOther;
  end;
end;
{$ENDIF}

procedure UnlockDocument(AHandle: THandle);
begin
  if AHandle = THandle(-1) then Exit;
  {$IFDEF UNIX}
  FpClose(AHandle);
  {$ELSE}
  FileClose(AHandle);
  {$ENDIF}
end;

end.
