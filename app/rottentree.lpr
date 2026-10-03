// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
program rottentree;

{$mode objfpc}{$H+}

// Rottentree, client LDAP et Active Directory. Point d'entree: le reste est ailleurs,
// comme toujours quand on cherche le coupable.

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  uDllHarden,   // en tete: la recherche de DLL est durcie avant l'init de la LCL
  SysUtils, Interfaces, Forms,
  uMainForm, uTheme, uThemeLoad, uFontEmbed, uVersion, uPreferences, uAppPaths, uSpillStore;

{$R *.res}

begin
  {$IFDEF UNIX}
  // Un pair qui raccroche ne doit pas tuer le processus: SIGPIPE ignore, EPIPE traite
  // la ou il survient.
  FpSignal(SigPipe, SignalHandler(SIG_IGN));
  {$ENDIF}
  Application.Title := RT_APP_NAME;
  Application.Scaled := True;
  Application.Initialize;
  EmbeddedFontManager.RegisterFonts;
  ApplyDefaultFonts;
  LoadPreferences;
  ThemesUserDir := AppDataDir + PathDelim + 'themes';
  InitThemes(PrefThemeName);
  // Fichiers de debordement chiffres laisses par une execution interrompue.
  try
    CleanOrphanSpillFiles(GetTempDir(False));
  except
  end;
  Application.CreateForm(TMainForm, MainForm);
  MainForm.Show;
  Application.Run;
end.
