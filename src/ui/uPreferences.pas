// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPreferences;

{$mode objfpc}{$H+}

// Preferences visuelles locales, en INI dans le dossier applicatif, jamais dans le document:
// un document se partage, les gouts de son proprietaire non. Aucun secret, aucun DN ici.
// Le fichier est une entree non fiable: valeurs bornees, lecture ratee = defauts.

interface

uses
  Classes, SysUtils;

var
  PrefThemeName: string = 'Rotten';
  PrefRecentDocuments: TStringList = nil;
  PrefWindowLeft: Integer = -1;
  PrefWindowTop: Integer = -1;
  PrefWindowWidth: Integer = 1280;
  PrefWindowHeight: Integer = 820;
  PrefWindowMaximized: Boolean = False;
  PrefSidebarWidth: Integer = 260;
  PrefMessagesHeight: Integer = 120;
  PrefMessagesVisible: Boolean = True;
  PrefSidebarVisible: Boolean = True;
  PrefLogEnabled: Boolean = False;
  PrefExtraSensitiveAttrs: string = '';

procedure LoadPreferences;
procedure SavePreferences;
procedure AddRecentDocument(const APath: string);
function PreferencesPath: string;

implementation

uses
  IniFiles, uAppPaths, uTheme;

const
  MAX_RECENT = 10;

function PreferencesPath: string;
begin
  Result := AppDataDir + PathDelim + 'preferences.ini';
end;

function Clamp(V, AMin, AMax: Integer): Integer;
begin
  if V < AMin then Result := AMin
  else if V > AMax then Result := AMax
  else Result := V;
end;

procedure LoadPreferences;
var
  ini: TIniFile;
  i: Integer;
  s: string;
begin
  if PrefRecentDocuments = nil then
    PrefRecentDocuments := TStringList.Create;
  PrefRecentDocuments.Clear;
  if not FileExists(PreferencesPath) then Exit;
  try
    ini := TIniFile.Create(PreferencesPath);
    try
      PrefThemeName := Copy(Trim(ini.ReadString('View', 'Theme', 'Rotten')), 1, 80);
      PrefWindowLeft := ini.ReadInteger('Window', 'Left', -1);
      PrefWindowTop := ini.ReadInteger('Window', 'Top', -1);
      PrefWindowWidth := Clamp(ini.ReadInteger('Window', 'Width', 1280), 640, 10000);
      PrefWindowHeight := Clamp(ini.ReadInteger('Window', 'Height', 820), 480, 10000);
      PrefWindowMaximized := ini.ReadBool('Window', 'Maximized', False);
      PrefSidebarWidth := Clamp(ini.ReadInteger('Window', 'Sidebar', 260), 120, 1200);
      PrefMessagesHeight := Clamp(ini.ReadInteger('Window', 'Messages', 120), 40, 1200);
      PrefMessagesVisible := ini.ReadBool('Window', 'MessagesVisible', True);
      PrefSidebarVisible := ini.ReadBool('Window', 'SidebarVisible', True);
      PrefLogEnabled := ini.ReadBool('Diagnostics', 'LogEnabled', False);
      PrefExtraSensitiveAttrs := Copy(ini.ReadString('Security', 'ExtraSensitive', ''), 1, 4096);
      PrefUiFontSize := ClampFontSize(ini.ReadInteger('View', 'UiFontSize', 10));
      PrefEditorFontSize := ini.ReadInteger('View', 'EditorFontSize', 0);
      if PrefEditorFontSize <> 0 then
        PrefEditorFontSize := ClampFontSize(PrefEditorFontSize);
      for i := 0 to MAX_RECENT - 1 do
      begin
        s := ini.ReadString('Recent', 'Doc' + IntToStr(i), '');
        if s <> '' then PrefRecentDocuments.Add(s);
      end;
    finally
      ini.Free;
    end;
  except
    PrefThemeName := 'Rotten';
  end;
end;

procedure SavePreferences;
var
  ini: TIniFile;
  i: Integer;
begin
  try
    ForceDirectories(AppDataDir);
    ini := TIniFile.Create(PreferencesPath);
    try
      ini.WriteString('View', 'Theme', PrefThemeName);
      ini.WriteInteger('View', 'UiFontSize', PrefUiFontSize);
      ini.WriteInteger('View', 'EditorFontSize', PrefEditorFontSize);
      ini.WriteInteger('Window', 'Left', PrefWindowLeft);
      ini.WriteInteger('Window', 'Top', PrefWindowTop);
      ini.WriteInteger('Window', 'Width', PrefWindowWidth);
      ini.WriteInteger('Window', 'Height', PrefWindowHeight);
      ini.WriteBool('Window', 'Maximized', PrefWindowMaximized);
      ini.WriteInteger('Window', 'Sidebar', PrefSidebarWidth);
      ini.WriteInteger('Window', 'Messages', PrefMessagesHeight);
      ini.WriteBool('Window', 'MessagesVisible', PrefMessagesVisible);
      ini.WriteBool('Window', 'SidebarVisible', PrefSidebarVisible);
      // Le verrouillage automatique a disparu; sa vieille cle part avec lui.
      ini.DeleteKey('Security', 'AutoLockMinutes');
      ini.WriteString('Security', 'ExtraSensitive', PrefExtraSensitiveAttrs);
      ini.WriteBool('Diagnostics', 'LogEnabled', PrefLogEnabled);
      ini.EraseSection('Recent');
      if PrefRecentDocuments <> nil then
        for i := 0 to PrefRecentDocuments.Count - 1 do
          ini.WriteString('Recent', 'Doc' + IntToStr(i), PrefRecentDocuments[i]);
      ini.UpdateFile;
    finally
      ini.Free;
    end;
  except
    // Ne pas pouvoir ecrire ses preferences n'a jamais merite un plantage.
  end;
end;

procedure AddRecentDocument(const APath: string);
var
  i: Integer;
begin
  if PrefRecentDocuments = nil then
    PrefRecentDocuments := TStringList.Create;
  for i := PrefRecentDocuments.Count - 1 downto 0 do
    if SameFileName(PrefRecentDocuments[i], APath) then
      PrefRecentDocuments.Delete(i);
  PrefRecentDocuments.Insert(0, APath);
  while PrefRecentDocuments.Count > MAX_RECENT do
    PrefRecentDocuments.Delete(PrefRecentDocuments.Count - 1);
end;

finalization
  PrefRecentDocuments.Free;

end.
