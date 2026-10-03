// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uNativeLib;

{$mode objfpc}{$H+}

// Chargement des bibliotheques natives par chemins absolus maitrises: dossier de
// l'executable (et Frameworks/lib selon la plateforme), puis emplacements systeme
// connus. Jamais le repertoire courant, le PATH ou le dossier d'un document. Chaque
// chargement est consigne, pour savoir qui a ete charge le jour ou ca casse.

interface

uses
  SysUtils, dynlibs;

type
  ENativeLibError = class(Exception);

  TLoadedLibInfo = record
    Name: string;
    Path: string;
    Version: string;
  end;

function LoadNativeLibrary(const ALogicalName: string;
  const AFileNames: array of string; out APath: string): TLibHandle;
function NativeSymbol(AHandle: TLibHandle; const ALib, ASymbol: string): Pointer;
function OptionalSymbol(AHandle: TLibHandle; const ASymbol: string): Pointer;
procedure SetLoadedLibVersion(const ALogicalName, AVersion: string);
function LoadedLibCount: Integer;
function LoadedLibAt(AIndex: Integer): TLoadedLibInfo;
function ApplicationLibDirs: TStringArray;

implementation

{$IFDEF WINDOWS}
uses
  Windows;

const
  LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = $00000100;
  LOAD_LIBRARY_SEARCH_SYSTEM32 = $00000800;
{$ENDIF}

var
  GLock: TRTLCriticalSection;
  GLoaded: array of TLoadedLibInfo;

function ApplicationLibDirs: TStringArray;
var
  exeDir: string;
begin
  exeDir := ExtractFilePath(ParamStr(0));
  {$IFDEF WINDOWS}
  Result := [exeDir];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := [exeDir + 'lib/', exeDir, '/usr/lib/x86_64-linux-gnu/', '/usr/lib64/',
    '/usr/lib/'];
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := [exeDir + '../Frameworks/', exeDir, '/opt/homebrew/lib/', '/usr/local/lib/'];
  {$ENDIF}
end;

function IsAbsolutePath(const P: string): Boolean;
begin
  {$IFDEF WINDOWS}
  // 'C:chemin' est relatif au repertoire courant du lecteur: on exige 'C:\'.
  Result := ((Length(P) >= 3) and (P[2] = ':') and (P[3] in ['\', '/'])) or
    ((Length(P) >= 2) and (P[1] = '\') and (P[2] = '\'));
  {$ELSE}
  Result := (Length(P) >= 1) and (P[1] = '/');
  {$ENDIF}
end;

procedure Record_(const AName, APath: string);
var
  i: Integer;
begin
  EnterCriticalSection(GLock);
  try
    for i := 0 to High(GLoaded) do
      if GLoaded[i].Name = AName then
      begin
        GLoaded[i].Path := APath;
        Exit;
      end;
    SetLength(GLoaded, Length(GLoaded) + 1);
    GLoaded[High(GLoaded)].Name := AName;
    GLoaded[High(GLoaded)].Path := APath;
    GLoaded[High(GLoaded)].Version := '';
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function TryLoad(const APath: string): TLibHandle;
begin
  {$IFDEF WINDOWS}
  // Dependances resolues depuis le dossier de la DLL et System32 seulement.
  Result := TLibHandle(LoadLibraryExW(PWideChar(UnicodeString(APath)), 0,
    LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR or LOAD_LIBRARY_SEARCH_SYSTEM32));
  {$ELSE}
  Result := LoadLibrary(APath);
  {$ENDIF}
end;

function LoadNativeLibrary(const ALogicalName: string;
  const AFileNames: array of string; out APath: string): TLibHandle;
var
  dirs: TStringArray;
  d, f: Integer;
  candidate: string;
begin
  Result := NilHandle;
  APath := '';
  dirs := ApplicationLibDirs;
  for d := 0 to High(dirs) do
    for f := 0 to High(AFileNames) do
    begin
      candidate := dirs[d] + AFileNames[f];
      if not IsAbsolutePath(candidate) then Continue;
      {$IFDEF DARWIN}
      // Sous macOS, /usr/lib vit dans le cache dyld, pas sur le disque: FileExists
      // ment.
      if not FileExists(candidate) and (Pos('/usr/lib/', candidate) <> 1) then Continue;
      {$ELSE}
      if not FileExists(candidate) then Continue;
      {$ENDIF}
      Result := TryLoad(candidate);
      if Result <> NilHandle then
      begin
        APath := candidate;
        Record_(ALogicalName, candidate);
        Exit;
      end;
    end;
end;

function NativeSymbol(AHandle: TLibHandle; const ALib, ASymbol: string): Pointer;
begin
  Result := GetProcedureAddress(AHandle, ASymbol);
  if Result = nil then
    raise ENativeLibError.CreateFmt('%s: missing symbol %s', [ALib, ASymbol]);
end;

function OptionalSymbol(AHandle: TLibHandle; const ASymbol: string): Pointer;
begin
  Result := GetProcedureAddress(AHandle, ASymbol);
end;

procedure SetLoadedLibVersion(const ALogicalName, AVersion: string);
var
  i: Integer;
begin
  EnterCriticalSection(GLock);
  try
    for i := 0 to High(GLoaded) do
      if GLoaded[i].Name = ALogicalName then
        GLoaded[i].Version := AVersion;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function LoadedLibCount: Integer;
begin
  EnterCriticalSection(GLock);
  try
    Result := Length(GLoaded);
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function LoadedLibAt(AIndex: Integer): TLoadedLibInfo;
begin
  EnterCriticalSection(GLock);
  try
    Result := GLoaded[AIndex];
  finally
    LeaveCriticalSection(GLock);
  end;
end;

initialization
  InitCriticalSection(GLock);

finalization
  DoneCriticalSection(GLock);

end.
