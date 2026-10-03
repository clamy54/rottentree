// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTheme;

{$mode objfpc}{$H+}

// Jetons de couleur et polices en globales, remplacables a chaud par uThemeLoad. Chaque
// controle les relit en se dessinant: appliquer un theme, c'est ecrire les globales puis
// tout repeindre en esperant que personne n'a mis la couleur en cache.

interface

uses
  Graphics, Controls;

var
  RSUiFontName: string = '';
  RSUiFontSize: Integer = 10;
  RSTreeFontSize: Integer = 10;
  RSEditorFontName: string = '';
  RSEditorFontSize: Integer = 12;

  clAppBg, clAppFg, clAccent, clBorder: TColor;
  clSideBg, clSideText, clSideTextHi, clSideSel, clSideHover, clSideActive: TColor;
  clStatusBg, clStatusText: TColor;
  clMenuBg, clMenuText, clMenuHover, clMenuPopupBg, clMenuDisabled, clMenuSep: TColor;
  clTabStrip, clTabActive, clTabInactive, clTabHover, clTabActiveText,
    clTabInactiveText, clTabIcon, clTabIconHi, clTabDead: TColor;

  clEditorBg, clEditorFg, clCurrentLine, clSelectionBg, clSelectionFg, clCaret,
    clGutterBg, clGutterFg: TColor;
  clCodeComment, clCodeString, clCodeNumber, clCodeKeyword, clCodeType,
    clCodeInvalid, clCodeFunction, clCodeVariable: TColor;

  clDiffEqual, clDiffAdded, clDiffAbsent, clDiffChanged, clDiffWarning,
    clDiffUnknown: TColor;

  clTermBg, clTermFg: TColor;

  PrefUiFontSize: Integer = 10;
  PrefEditorFontSize: Integer = 0;

const
  FONT_SIZE_MIN = 10;
  FONT_SIZE_MAX = 14;

function ClampFontSize(ASize: Integer): Integer;

procedure ApplyDefaultFonts;
procedure ApplyUiFont(AControl: TControl);
// TColor est en BGR: on convertit, jamais de transtypage, sinon rouge et bleu s'echangent
// sans un bruit.
function RgbHexToColor(ARgb: Cardinal): TColor;
function ColorToRgbHex(AColor: TColor): Cardinal;
function BlendColor(A, B: TColor; APct: Integer): TColor;
function IsDarkColor(AColor: TColor): Boolean;
procedure ResetRottenDefaults;

implementation

uses
  uFontEmbed;

function ClampFontSize(ASize: Integer): Integer;
begin
  if ASize < FONT_SIZE_MIN then Result := FONT_SIZE_MIN
  else if ASize > FONT_SIZE_MAX then Result := FONT_SIZE_MAX
  else Result := ASize;
end;

function RgbHexToColor(ARgb: Cardinal): TColor;
begin
  Result := TColor(((ARgb shr 16) and $FF) or (((ARgb shr 8) and $FF) shl 8) or
    ((ARgb and $FF) shl 16));
end;

function ColorToRgbHex(AColor: TColor): Cardinal;
var
  c: LongInt;
begin
  c := ColorToRGB(AColor);
  Result := (Cardinal(c and $FF) shl 16) or (Cardinal((c shr 8) and $FF) shl 8) or
    Cardinal((c shr 16) and $FF);
end;

function BlendColor(A, B: TColor; APct: Integer): TColor;
var
  ca, cb: LongInt;
  r, g, bl: Integer;
begin
  ca := ColorToRGB(A);
  cb := ColorToRGB(B);
  r := ((ca and $FF) * APct + (cb and $FF) * (100 - APct)) div 100;
  g := (((ca shr 8) and $FF) * APct + ((cb shr 8) and $FF) * (100 - APct)) div 100;
  bl := (((ca shr 16) and $FF) * APct + ((cb shr 16) and $FF) * (100 - APct)) div 100;
  Result := TColor(r or (g shl 8) or (bl shl 16));
end;

function IsDarkColor(AColor: TColor): Boolean;
var
  c: LongInt;
begin
  c := ColorToRGB(AColor);
  Result := ((c and $FF) * 299 + ((c shr 8) and $FF) * 587 + ((c shr 16) and $FF) * 114)
    div 1000 < 128;
end;

procedure ApplyDefaultFonts;
begin
  if MonaspaceAvailable then
  begin
    RSUiFontName := MonaspaceDefaultFamily;
    RSEditorFontName := MonaspaceTerminalDefaultFamily;
  end
  else
  begin
    RSUiFontName := '';
    RSEditorFontName := '';
  end;
end;

procedure ApplyUiFont(AControl: TControl);
var
  i: Integer;
  wc: TWinControl;
begin
  if AControl = nil then Exit;
  if RSUiFontName <> '' then
    AControl.Font.Name := RSUiFontName;
  if AControl is TWinControl then
  begin
    wc := TWinControl(AControl);
    for i := 0 to wc.ControlCount - 1 do
      ApplyUiFont(wc.Controls[i]);
  end;
end;

procedure ResetRottenDefaults;
begin
  clAppBg := RgbHexToColor($1E1E1E);
  clAppFg := RgbHexToColor($D4D4D4);
  clAccent := RgbHexToColor($FB9E6B);
  clBorder := RgbHexToColor($161616);
  clSideBg := RgbHexToColor($252526);
  clSideText := RgbHexToColor($CCCCCC);
  clSideTextHi := RgbHexToColor($FFFFFF);
  clSideSel := RgbHexToColor($37414F);
  clSideHover := RgbHexToColor($2D2D30);
  clSideActive := RgbHexToColor($8FB84E);
  clStatusBg := RgbHexToColor($252526);
  clStatusText := RgbHexToColor($9D9D9D);
  clMenuBg := RgbHexToColor($252526);
  clMenuText := RgbHexToColor($CCCCCC);
  clMenuHover := RgbHexToColor($37414F);
  clMenuPopupBg := RgbHexToColor($2D2D30);
  clMenuDisabled := RgbHexToColor($808080);
  clMenuSep := RgbHexToColor($454549);
  clTabStrip := RgbHexToColor($3A3A3D);
  clTabActive := RgbHexToColor($646469);
  clTabInactive := RgbHexToColor($4C4C50);
  clTabHover := RgbHexToColor($59595E);
  clTabActiveText := RgbHexToColor($FFFFFF);
  clTabInactiveText := RgbHexToColor($D2D2D2);
  clTabIcon := RgbHexToColor($6A9955);
  clTabIconHi := RgbHexToColor($7AB069);
  clTabDead := RgbHexToColor($F14C4C);
  clEditorBg := RgbHexToColor($1E1E1E);
  clEditorFg := RgbHexToColor($D4D4D4);
  clCurrentLine := RgbHexToColor($282828);
  clSelectionBg := RgbHexToColor($FB9E6B);
  clSelectionFg := RgbHexToColor($1E1E1E);
  clCaret := RgbHexToColor($AEAFAD);
  clGutterBg := RgbHexToColor($1E1E1E);
  clGutterFg := RgbHexToColor($858585);
  clCodeComment := RgbHexToColor($6A9955);
  clCodeString := RgbHexToColor($CE9178);
  clCodeNumber := RgbHexToColor($B5CEA8);
  clCodeKeyword := RgbHexToColor($569CD6);
  clCodeType := RgbHexToColor($4EC9B0);
  clCodeInvalid := RgbHexToColor($F44747);
  clCodeFunction := RgbHexToColor($DCDCAA);
  clCodeVariable := RgbHexToColor($9CDCFE);
  clDiffEqual := RgbHexToColor($8FB84E);
  clDiffAdded := RgbHexToColor($4EC9B0);
  clDiffAbsent := RgbHexToColor($F14C4C);
  clDiffChanged := RgbHexToColor($FB9E6B);
  clDiffWarning := RgbHexToColor($DCDCAA);
  clDiffUnknown := RgbHexToColor($9D9D9D);
  clTermBg := clAppBg;
  clTermFg := clAppFg;
end;

initialization
  ResetRottenDefaults;

end.
