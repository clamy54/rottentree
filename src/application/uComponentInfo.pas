// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uComponentInfo;

{$mode objfpc}{$H+}

// Versions des bibliotheques natives vraiment chargees, pour la fenetre A propos. Une absence n'est
// pas une erreur ici: elle se voit dans la liste, ce qui est deja assez humiliant.

interface

uses
  SysUtils;

type
  TComponentVersion = record
    Name: string;
    Version: string;
    Path: string;
  end;
  TComponentVersions = array of TComponentVersion;

function LoadedComponentVersions: TComponentVersions;

implementation

uses
  uNativeLib, uOpenSslApi, uSodiumApi, uSqlite3Api, uArgon2Api, uLdapApi;

function LoadedComponentVersions: TComponentVersions;
var
  i: Integer;
  info: TLoadedLibInfo;
begin
  // Chargement avant lecture: une version annoncee sans bibliotheque derriere, c'est de la
  // publicite.
  try OpenSslEnsureLoaded; except end;
  try SodiumEnsureLoaded; except end;
  try SqliteEnsureLoaded; except end;
  try Argon2EnsureLoaded; except end;
  try LdapEnsureLoaded; except end;
  Result := nil;
  SetLength(Result, LoadedLibCount);
  for i := 0 to LoadedLibCount - 1 do
  begin
    info := LoadedLibAt(i);
    Result[i].Name := info.Name;
    Result[i].Version := info.Version;
    Result[i].Path := info.Path;
  end;
end;

end.
