// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDllHarden;

{$mode objfpc}{$H+}

// Durcissement contre le detournement de DLL, a appliquer avant tout chargement: cette
// unite sans LCL ouvre le uses du programme. Recherche limitee a System32, au dossier
// de l'executable et aux ajouts explicites: ni repertoire courant ni PATH, tant pis
// pour la DLL piegee posee a cote d'un document. Sans effet hors Windows.

interface

implementation

{$IFDEF WINDOWS}
uses
  Windows;

procedure HardenDllSearchPath;
const
  LOAD_LIBRARY_SEARCH_DEFAULT_DIRS = DWORD($00001000);
type
  TSetDefaultDllDirectories = function(AFlags: DWORD): BOOL; stdcall;
  TSetDllDirectoryW = function(APath: PWideChar): BOOL; stdcall;
var
  h: HMODULE;
  setDirs: TSetDefaultDllDirectories;
  setDllDir: TSetDllDirectoryW;
begin
  h := GetModuleHandle('kernel32.dll');
  if h = 0 then Exit;
  // Chaine vide: retire le repertoire courant de l'ordre de recherche classique.
  Pointer(setDllDir) := GetProcAddress(h, 'SetDllDirectoryW');
  if Assigned(setDllDir) then
    setDllDir('');
  Pointer(setDirs) := GetProcAddress(h, 'SetDefaultDllDirectories');
  if Assigned(setDirs) then
    setDirs(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
end;
{$ENDIF}

initialization
{$IFDEF WINDOWS}
  HardenDllSearchPath;
{$ENDIF}

end.
