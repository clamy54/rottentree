// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uThemePreview;

{$mode objfpc}{$H+}

// Apercu d'un theme sans l'appliquer: maquette reduite de la fenetre, dessinee avec les
// couleurs et les fontes du theme choisi. Le 'modfy' de l'exemple LDIF est volontaire,
// il faut bien une ligne fausse pour montrer la couleur des erreurs.

interface

uses
  Classes, SysUtils, Controls, Graphics, uThemeData;

type
  TThemePreview = class(TCustomControl)
  private
    FColors: TThemeColors;
    FUiFont, FEditorFont: string;
    FValid: Boolean;
    function Col(T: TThemeToken): TColor;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure ShowTheme(AIndex: Integer);
    function PreferredHeight: Integer;
  end;

implementation

uses
  uThemeLoad, uTheme;

resourcestring
  rsPvMenu = 'File   Edit   View   Connection   Directory';
  rsPvProfile1 = 'Production';
  rsPvBadge = '[Prod]';
  rsPvProfile2 = 'Lab OpenLDAP';
  rsPvProfile3 = 'Test 389 DS';
  rsPvProfile4 = 'Legacy AD';
  rsPvTab1 = 'ldap1.example.org';
  rsPvTab2 = 'Search';
  rsPvStatus = 'cn=admin  |  ldap1.example.org:636  |  TLS - verified  |  ready';
  rsPvEqual = '= equal';
  rsPvAdded = '+ added';
  rsPvAbsent = '- not observed';
  rsPvChanged = '~ changed';

constructor TThemePreview.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Height := 240;
  FColors := EmptyColors;
end;

function TThemePreview.Col(T: TThemeToken): TColor;
begin
  Result := TColor(FColors[T]);
end;

procedure TThemePreview.ShowTheme(AIndex: Integer);
begin
  FValid := ThemePreview(AIndex, FColors, FUiFont, FEditorFont);
  Height := PreferredHeight;
  Invalidate;
end;

function TThemePreview.PreferredHeight: Integer;
var
  bmp: TBitmap;
  uiH, edH: Integer;
begin
  bmp := TBitmap.Create;
  try
    if FUiFont <> '' then bmp.Canvas.Font.Name := FUiFont;
    bmp.Canvas.Font.Size := RSUiFontSize - 1;
    uiH := bmp.Canvas.TextHeight('Ag') + 4;
    if FEditorFont <> '' then bmp.Canvas.Font.Name := FEditorFont;
    bmp.Canvas.Font.Size := RSUiFontSize;
    edH := bmp.Canvas.TextHeight('Ag') + 3;
  finally
    bmp.Free;
  end;
  Result := 2 + (uiH + 4) + (uiH + 8) + 4 + 7 * edH + 8 + uiH + 4 + (uiH + 4) + 4;
end;

procedure TThemePreview.Paint;
var
  r: TRect;
  menuH, statusH, sideW, tabH, lineH, x, y, gutterW, i, textY: Integer;

  procedure Fill(const AR: TRect; AColor: TColor);
  begin
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := AColor;
    Canvas.FillRect(AR);
  end;

  procedure TextAt(AX, AY: Integer; const S: string; AColor: TColor);
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Color := AColor;
    Canvas.TextOut(AX, AY, S);
  end;

  function Seg(AX, AY: Integer; const S: string; AColor: TColor): Integer;
  begin
    TextAt(AX, AY, S, AColor);
    Result := AX + Canvas.TextWidth(S);
  end;

  procedure UseUiFont(ADelta: Integer);
  begin
    if FUiFont <> '' then Canvas.Font.Name := FUiFont;
    Canvas.Font.Size := RSUiFontSize + ADelta;
    Canvas.Font.Style := [];
  end;

begin
  r := ClientRect;
  if not FValid then
  begin
    Fill(r, clBtnFace);
    Exit;
  end;
  UseUiFont(-1);
  lineH := Canvas.TextHeight('Ag') + 4;
  menuH := lineH + 4;
  statusH := lineH + 4;
  tabH := lineH + 8;
  sideW := r.Width * 30 div 100;

  Fill(r, Col(ttBorder));
  r := Rect(r.Left + 1, r.Top + 1, r.Right - 1, r.Bottom - 1);

  Fill(Rect(r.Left, r.Top, r.Right, r.Top + menuH), Col(ttMenuBg));
  TextAt(r.Left + 8, r.Top + 3, rsPvMenu, Col(ttMenuText));

  Fill(Rect(r.Left, r.Bottom - statusH, r.Right, r.Bottom), Col(ttStatusBg));
  TextAt(r.Left + 8, r.Bottom - statusH + 3, rsPvStatus, Col(ttStatusText));

  Fill(Rect(r.Left, r.Top + menuH, r.Left + sideW, r.Bottom - statusH), Col(ttSideBg));
  y := r.Top + menuH + 6;
  x := Seg(r.Left + 10, y, rsPvProfile1, Col(ttSideActive));
  TextAt(x + 6, y, rsPvBadge, Col(ttAccent));
  Inc(y, lineH + 2);
  Fill(Rect(r.Left, y - 2, r.Left + sideW, y + lineH), Col(ttSideSel));
  TextAt(r.Left + 10, y, rsPvProfile2, Col(ttSideTextHi));
  Inc(y, lineH + 2);
  Fill(Rect(r.Left, y - 2, r.Left + sideW, y + lineH), Col(ttSideHover));
  TextAt(r.Left + 10, y, rsPvProfile3, Col(ttSideText));
  Inc(y, lineH + 2);
  TextAt(r.Left + 10, y, rsPvProfile4, Col(ttTabDead));

  Fill(Rect(r.Left + sideW, r.Top + menuH, r.Right, r.Top + menuH + tabH), Col(ttTabStrip));
  x := r.Left + sideW + 6;
  y := r.Top + menuH + 4;
  Fill(Rect(x, y, x + Canvas.TextWidth(rsPvTab1) + 30, r.Top + menuH + tabH), Col(ttTabActive));
  Canvas.Brush.Color := Col(ttTabIcon);
  Canvas.Pen.Color := Col(ttTabIcon);
  Canvas.Ellipse(x + 7, y + lineH div 2 - 2, x + 13, y + lineH div 2 + 4);
  TextAt(x + 20, y + 2, rsPvTab1, Col(ttTabActiveText));
  x := x + Canvas.TextWidth(rsPvTab1) + 34;
  Fill(Rect(x, y, x + Canvas.TextWidth(rsPvTab2) + 20, r.Top + menuH + tabH), Col(ttTabInactive));
  TextAt(x + 10, y + 2, rsPvTab2, Col(ttTabInactiveText));

  x := r.Left + sideW;
  y := r.Top + menuH + tabH;
  Fill(Rect(x, y, r.Right, r.Bottom - statusH), Col(ttEditorBg));
  if FEditorFont <> '' then Canvas.Font.Name := FEditorFont;
  Canvas.Font.Size := RSUiFontSize;
  lineH := Canvas.TextHeight('Ag') + 3;
  gutterW := Canvas.TextWidth('00') + 12;
  Fill(Rect(x, y, x + gutterW, r.Bottom - statusH - lineH - 8), Col(ttGutterBg));
  for i := 1 to 7 do
    TextAt(x + 4, y + 4 + (i - 1) * lineH, Format('%2d', [i]), Col(ttGutterFg));
  x := x + gutterW + 6;
  textY := y + 4;
  Seg(x, textY, '# alice, people, example.org', Col(ttCodeComment));
  Inc(textY, lineH);
  x := Seg(x, textY, 'dn', Col(ttCodeKeyword));
  x := Seg(x, textY, ': ', Col(ttEditorFg));
  Seg(x, textY, 'uid=alice,ou=people,dc=example,dc=org', Col(ttEditorFg));
  x := r.Left + sideW + gutterW + 6;
  Inc(textY, lineH);
  Fill(Rect(x - 4, textY - 1, r.Right, textY + lineH - 1), Col(ttCurrentLine));
  x := Seg(x, textY, 'objectClass', Col(ttCodeKeyword));
  x := Seg(x, textY, ': ', Col(ttEditorFg));
  Fill(Rect(x, textY - 1, x + Canvas.TextWidth('inetOrgPerson'), textY + lineH - 1), Col(ttSelectionBg));
  Seg(x, textY, 'inetOrgPerson', Col(ttSelectionFg));
  Canvas.Pen.Color := Col(ttCaret);
  Canvas.Line(x + Canvas.TextWidth('inetOrgPerson') + 1, textY,
    x + Canvas.TextWidth('inetOrgPerson') + 1, textY + lineH - 2);
  x := r.Left + sideW + gutterW + 6;
  Inc(textY, lineH);
  x := Seg(x, textY, 'mail', Col(ttCodeKeyword));
  x := Seg(x, textY, ': ', Col(ttEditorFg));
  Seg(x, textY, 'alice@example.org', Col(ttCodeString));
  x := r.Left + sideW + gutterW + 6;
  Inc(textY, lineH);
  x := Seg(x, textY, 'uidNumber', Col(ttCodeKeyword));
  x := Seg(x, textY, ': ', Col(ttEditorFg));
  Seg(x, textY, '1001', Col(ttCodeNumber));
  x := r.Left + sideW + gutterW + 6;
  Inc(textY, lineH);
  x := Seg(x, textY, 'jpegPhoto', Col(ttCodeKeyword));
  x := Seg(x, textY, ':: ', Col(ttCodeType));
  Seg(x, textY, '/9j/4AAQSkZJRg==', Col(ttCodeFunction));
  x := r.Left + sideW + gutterW + 6;
  Inc(textY, lineH);
  Seg(x, textY, 'changetype: modfy', Col(ttCodeInvalid));

  x := r.Left + sideW + 10;
  y := r.Bottom - statusH - lineH - 4;
  UseUiFont(-1);
  x := Seg(x, y, rsPvEqual, Col(ttDiffEqual)) + 16;
  x := Seg(x, y, rsPvAdded, Col(ttDiffAdded)) + 16;
  x := Seg(x, y, rsPvAbsent, Col(ttDiffAbsent)) + 16;
  Seg(x, y, rsPvChanged, Col(ttDiffChanged));
end;

end.
