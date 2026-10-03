// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uFontEmbed;

{$mode objfpc}{$H+}

// Polices embarquees (Monaspace Frozen, JetBrainsMono NL Nerd Font Mono), enregistrees
// pour ce seul process depuis les ressources du binaire. Pas de dossier fonts/ externe:
// si ca rate, le widgetset garde sa fonte systeme et l'echec est signale. Aucune LCL ici.

interface

type
  IEmbeddedFontManager = interface
    ['{5B0C8F3A-2D71-4E86-9AE4-7C51D20B93F4}']
    procedure RegisterFonts;
    procedure UnregisterFonts;
    function UiFontName: UnicodeString;
    function TerminalFontName: UnicodeString;
    function IsFallbackActive: Boolean;
  end;

function EmbeddedFontManager: IEmbeddedFontManager;

procedure LoadEmbeddedFonts;

function MonaspaceAvailable: Boolean;
function MonaspaceFamilyCount: Integer;
function MonaspaceFamilyKey(AIndex: Integer): string;
function MonaspaceFamilyLabel(AIndex: Integer): string;
function MonaspaceDefaultFamily: string;
function MonaspaceTerminalDefaultFamily: string;
function ResolveMonaspace(const AValue: string): string;

implementation

uses
  Classes, SysUtils,
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  {$IFDEF LINUX}dynlibs,{$ENDIF}
  {$IFDEF DARWIN}MacOSAll,{$ENDIF}
  {$IF DEFINED(LINUX) OR DEFINED(DARWIN)}BaseUnix,{$ENDIF}
  uSafeSave;

{$R rottenui_fonts.res}

const
  FontRes: array[0..23] of string = (
    'NEON_REGULAR', 'NEON_BOLD', 'NEON_ITALIC', 'NEON_BOLDITALIC',
    'ARGON_REGULAR', 'ARGON_BOLD', 'ARGON_ITALIC', 'ARGON_BOLDITALIC',
    'XENON_REGULAR', 'XENON_BOLD', 'XENON_ITALIC', 'XENON_BOLDITALIC',
    'RADON_REGULAR', 'RADON_BOLD', 'RADON_ITALIC', 'RADON_BOLDITALIC',
    'KRYPTON_REGULAR', 'KRYPTON_BOLD', 'KRYPTON_ITALIC', 'KRYPTON_BOLDITALIC',
    'JETBRAINSMONO_REGULAR', 'JETBRAINSMONO_BOLD', 'JETBRAINSMONO_ITALIC',
    'JETBRAINSMONO_BOLDITALIC');
  ResFam: array[0..23] of Integer = (
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5);
  ResStyle: array[0..23] of Integer = (
    0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3);
  FontFamily = 'Monaspace Neon Frozen';

  // Liste blanche: un theme ou des prefs ne choisissent que parmi ces familles.
  FamKeys: array[0..5] of string =
    ('Neon', 'Argon', 'Xenon', 'Radon', 'Krypton', 'JetBrainsMono');
  // Noms exacts de la table name des TTF: CreateFont ne reconnait rien d'autre.
  FamFull: array[0..5] of string = (
    'Monaspace Neon Frozen', 'Monaspace Argon Frozen', 'Monaspace Xenon Frozen',
    'Monaspace Radon Frozen', 'Monaspace Krypton Frozen', 'JetBrainsMonoNL NFM');
  FamLabel: array[0..5] of string = (
    'Monaspace Neon Frozen', 'Monaspace Argon Frozen', 'Monaspace Xenon Frozen',
    'Monaspace Radon Frozen', 'Monaspace Krypton Frozen',
    'JetBrains Mono NL Nerd Font');
  FamFile: array[0..5] of string = (
    'MonaspaceNeonFrozen-', 'MonaspaceArgonFrozen-', 'MonaspaceXenonFrozen-',
    'MonaspaceRadonFrozen-', 'MonaspaceKryptonFrozen-',
    'JetBrainsMonoNLNerdFontMono-');
  FamStyleCount: array[0..5] of Integer = (4, 4, 4, 4, 4, 4);
  StyleSuffix: array[0..3] of string = ('Regular', 'Bold', 'Italic', 'BoldItalic');

var
  FamStyleLoaded: array[0..5, 0..3] of Boolean;
  FontsLoaded: Boolean;

// Famille incomplete, famille refusee: CreateFont par nom retomberait en silence sur
// une autre police pour le style manquant.
function FamComplete(AFam: Integer): Boolean;
var
  s: Integer;
begin
  Result := False;
  if (AFam < 0) or (AFam > High(FamKeys)) then Exit;
  for s := 0 to FamStyleCount[AFam] - 1 do
    if not FamStyleLoaded[AFam, s] then Exit;
  Result := True;
end;

procedure MarkRes(AResIdx: Integer);
begin
  if (AResIdx >= 0) and (AResIdx <= High(FontRes)) then
    FamStyleLoaded[ResFam[AResIdx], ResStyle[AResIdx]] := True;
end;

function ResIndexOfFile(const AName: string): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(FontRes) do
    if SameText(AName, FamFile[ResFam[i]] + StyleSuffix[ResStyle[i]] + '.ttf') then
      Exit(i);
end;

function MonaspaceAvailable: Boolean;
begin
  Result := FamComplete(0);
end;

function MonaspaceFamilyCount: Integer;
begin
  Result := Length(FamKeys);
end;

function MonaspaceFamilyKey(AIndex: Integer): string;
begin
  if (AIndex >= 0) and (AIndex <= High(FamKeys)) then
    Result := FamKeys[AIndex]
  else
    Result := '';
end;

function MonaspaceFamilyLabel(AIndex: Integer): string;
begin
  if (AIndex >= 0) and (AIndex <= High(FamLabel)) then
    Result := FamLabel[AIndex]
  else
    Result := '';
end;

function MonaspaceDefaultFamily: string;
begin
  Result := FontFamily;
end;

function MonaspaceTerminalDefaultFamily: string;
begin
  Result := ResolveMonaspace('Radon');
  if Result = '' then
    Result := FontFamily;
end;

function ResolveMonaspace(const AValue: string): string;
var
  i: Integer;
  v: string;
begin
  Result := '';
  v := Trim(AValue);
  for i := 0 to High(FamKeys) do
    if SameText(v, FamKeys[i]) or SameText(v, FamFull[i]) then
    begin
      if FamComplete(i) then Result := FamFull[i];
      Exit;
    end;
end;

function OpenFontRes(const AName: string): TResourceStream;
begin
  try
    Result := TResourceStream.Create(HINSTANCE, AName, PChar(PtrUInt(10)));
  except
    on EResNotFound do Result := nil;
  end;
end;

{$IF DEFINED(WINDOWS)}

const
  FR_PRIVATE = $10;

function AddFontResourceExW(lpszFilename: PWideChar; fl: DWORD; pdv: Pointer): LongInt;
  stdcall; external 'gdi32.dll' name 'AddFontResourceExW';
function AddFontMemResourceEx(pbFont: Pointer; cbFont: DWORD; pdv: Pointer;
  pcFonts: PDWORD): THandle; stdcall; external 'gdi32.dll' name 'AddFontMemResourceEx';

function AddFontFile(const APath: string): Boolean;
begin
  Result := AddFontResourceExW(PWideChar(UTF8Decode(APath)), FR_PRIVATE, nil) > 0;
end;

function LoadFromResources: Boolean;
var
  i: Integer;
  rs: TResourceStream;
  n: DWORD;
begin
  Result := False;
  for i := 0 to High(FontRes) do
  begin
    rs := OpenFontRes(FontRes[i]);
    if rs = nil then Continue;
    try
      n := 0;
      if AddFontMemResourceEx(rs.Memory, DWORD(rs.Size), nil, @n) <> 0 then
      begin
        MarkRes(i);
        Result := True;
      end;
    finally
      rs.Free;
    end;
  end;
end;

{$ELSEIF DEFINED(LINUX) OR DEFINED(DARWIN)}

{$IFDEF LINUX}
function AddFontFile(const APath: string): Boolean;
type
  TFcAppFontAddFile = function(config: Pointer; fname: PAnsiChar): LongInt; cdecl;
var
  lib: TLibHandle;
  fn: TFcAppFontAddFile;
begin
  Result := False;
  lib := LoadLibrary('libfontconfig.so.1');
  if lib = NilHandle then Exit;
  fn := TFcAppFontAddFile(GetProcedureAddress(lib, 'FcConfigAppFontAddFile'));
  if fn <> nil then
    Result := fn(nil, PAnsiChar(APath)) <> 0;
end;

// Pango fige sa liste de familles avant notre main. Sans ce rappel, la police enregistree
// reste invisible et le texte sort en fonte systeme, sans la moindre erreur.
procedure NotifyFontconfigChanged;
type
  TGetDefaultMap = function: Pointer; cdecl;
  TConfigChanged = procedure(fontmap: Pointer); cdecl;
var
  pc, ft: TLibHandle;
  getmap: TGetDefaultMap;
  changed: TConfigChanged;
  fm: Pointer;
begin
  pc := LoadLibrary('libpangocairo-1.0.so.0');
  ft := LoadLibrary('libpangoft2-1.0.so.0');
  if (pc = NilHandle) or (ft = NilHandle) then Exit;
  getmap := TGetDefaultMap(GetProcedureAddress(pc, 'pango_cairo_font_map_get_default'));
  changed := TConfigChanged(GetProcedureAddress(ft, 'pango_fc_font_map_config_changed'));
  if (getmap = nil) or (changed = nil) then Exit;
  fm := getmap();
  if fm <> nil then changed(fm);
end;
{$ENDIF}

{$IFDEF DARWIN}
{$linkframework CoreFoundation}
{$linkframework CoreText}

function AddFontFile(const APath: string): Boolean;
const
  kCTFontManagerScopeProcess = 1;
var
  url: CFURLRef;
  err: CFErrorRef;
begin
  Result := False;
  url := CFURLCreateFromFileSystemRepresentation(nil, PAnsiChar(APath),
    Length(APath), False);
  if url = nil then Exit;
  // Le binding FPC prend le 3e parametre en var CFErrorRef, pas en pointeur nullable:
  // il lui faut une vraie variable, nil ne passe pas.
  err := nil;
  Result := CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, err) <> 0;
  if (not Result) and (err <> nil) then CFRelease(err);
  CFRelease(url);
end;
{$ENDIF}

function Elevated: Boolean;
begin
  Result := (FpGetEUid = 0) or (FpGetEUid <> FpGetUid) or (FpGetEGid <> FpGetGid);
end;

function PrivateDirOK(const ADir: string): Boolean;
var
  st: Stat;
begin
  Result := False;
  if fpLstat(PChar(ADir), st) <> 0 then Exit;
  if fpS_ISLNK(st.st_mode) or not fpS_ISDIR(st.st_mode) then Exit;
  if st.st_uid <> FpGetEUid then Exit;
  Result := fpChmod(PChar(ADir), &700) = 0;
end;

// Le cache disque n'est jamais cru: reecrit a chaque lancement, un .ttf glisse la par un
// tiers est ecrase avant d'etre lu.
function LoadFromResources: Boolean;
var
  i: Integer;
  rs: TResourceStream;
  st: TOwnedHandleStream;
  dir, path, tmp: string;
begin
  Result := False;
  dir := GetAppConfigDir(False) + 'fonts' + PathDelim;
  if not ForceDirectories(dir) then Exit;
  if not PrivateDirOK(ExcludeTrailingPathDelimiter(dir)) then Exit;
  for i := 0 to High(FontRes) do
  begin
    rs := OpenFontRes(FontRes[i]);
    if rs = nil then Continue;
    try
      try
        path := dir + FontRes[i] + '.ttf';
        tmp := '';
        st := CreateTempIn(path, tmp);
        try
          st.CopyFrom(rs, 0);
        finally
          st.Free;
        end;
        if ReplaceByRename(tmp, path) then
        begin
          if AddFontFile(path) then
          begin
            MarkRes(i);
            Result := True;
          end;
        end
        else
          DeleteFile(tmp);
      except
        if tmp <> '' then DeleteFile(tmp);
      end;
    finally
      rs.Free;
    end;
  end;
end;

{$ELSE}

function AddFontFile(const APath: string): Boolean;
begin
  Result := False;
end;

function LoadFromResources: Boolean;
begin
  Result := False;
end;

{$ENDIF}

procedure LoadEmbeddedFonts;
begin
  if FontsLoaded then Exit;
  FontsLoaded := True;
  {$IF DEFINED(LINUX) OR DEFINED(DARWIN)}
  // Process eleve: rien n'est lu sur disque. Un parseur de fontes nourri par un fichier
  // tiers, c'est une surface d'attaque avec de jolies ligatures.
  if Elevated then Exit;
  {$ENDIF}
  LoadFromResources;
  {$IFDEF LINUX}
  NotifyFontconfigChanged;
  {$ENDIF}
end;

type
  TEmbeddedFontManager = class(TInterfacedObject, IEmbeddedFontManager)
  public
    procedure RegisterFonts;
    procedure UnregisterFonts;
    function UiFontName: UnicodeString;
    function TerminalFontName: UnicodeString;
    function IsFallbackActive: Boolean;
  end;

procedure TEmbeddedFontManager.RegisterFonts;
begin
  LoadEmbeddedFonts;
end;

procedure TEmbeddedFontManager.UnregisterFonts;
begin
end;

function TEmbeddedFontManager.UiFontName: UnicodeString;
begin
  if MonaspaceAvailable then
    Result := UnicodeString(FontFamily)
  else
    Result := '';
end;

function TEmbeddedFontManager.TerminalFontName: UnicodeString;
begin
  Result := UiFontName;
end;

function TEmbeddedFontManager.IsFallbackActive: Boolean;
begin
  Result := not MonaspaceAvailable;
end;

var
  GFontManager: IEmbeddedFontManager;

function EmbeddedFontManager: IEmbeddedFontManager;
begin
  if GFontManager = nil then
    GFontManager := TEmbeddedFontManager.Create;
  Result := GFontManager;
end;

end.
