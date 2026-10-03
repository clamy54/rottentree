// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uRtButton;

{$mode objfpc}{$H+}

// Boutons plats, segments et etapes d'assistant, dessines aux couleurs du theme.
// Les boutons natifs ignorent le theme avec une constance qu'on aimerait voir ailleurs.

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, Types;

type
  TRtButtonGlyph = (rbgIcon, rbgDots);

  TRtFlatButton = class(TCustomControl)
  private
    FIconId: string;
    FGlyph: TRtButtonGlyph;
    FText: string;
    FHot, FDown: Boolean;
    FInk: TColor;
    FFill: TColor;
    FBorder: TColor;
    FInsetY: Integer;
    procedure SetText(const AValue: string);
    procedure SetIconId(const AValue: string);
    function InkColor: TColor;
    function BackColor: TColor;
  protected
    procedure Paint; override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Setup(const AIconId, AText: string; AInk: TColor = clDefault);
    function PreferredWidth: Integer;
    function PreferredHeight: Integer;
    procedure FitWidth;
    property Text: string read FText write SetText;
    property IconId: string read FIconId write SetIconId;
    property Glyph: TRtButtonGlyph read FGlyph write FGlyph;
    property Ink: TColor read FInk write FInk;
    property Fill: TColor read FFill write FFill;
    property Border: TColor read FBorder write FBorder;
    property InsetY: Integer read FInsetY write FInsetY;
    property OnClick;
  end;

  TRtSegmented = class(TCustomControl)
  private
    FItems: TStringList;
    FItemIndex: Integer;
    FOnChange: TNotifyEvent;
    procedure SetItemIndex(AValue: Integer);
    function SegmentAt(X: Integer): Integer;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetChoices(const AItems: array of string; AIndex: Integer);
    function PreferredWidth: Integer;
    property ItemIndex: Integer read FItemIndex write SetItemIndex;
    property Items: TStringList read FItems;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  TRtStepper = class(TCustomControl)
  private
    FSteps: TStringList;
    FCurrent: Integer;
    procedure SetCurrent(AValue: Integer);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetSteps(const ASteps: array of string);
    function PreferredHeight: Integer;
    property Current: Integer read FCurrent write SetCurrent;
  end;

// Mesure sur un bitmap a part: un controle sans fenetre n'a pas encore de canevas
// digne de ce nom.
function MeasureText(AFont: TFont; const AText: string; AStyle: TFontStyles = []): Integer;

implementation

uses
  Math, uTheme, uIcons, uUiKit;

const
  ICON_LOGICAL = 16;
  PAD_H = 8;
  GAP = 6;

var
  GMeasure: TBitmap = nil;

function MeasureText(AFont: TFont; const AText: string; AStyle: TFontStyles): Integer;
begin
  if GMeasure = nil then GMeasure := TBitmap.Create;
  GMeasure.Canvas.Font.Assign(AFont);
  GMeasure.Canvas.Font.Style := AFont.Style + AStyle;
  Result := GMeasure.Canvas.TextWidth(AText);
end;

constructor TRtFlatButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // csClickEvents retire: le clic part de MouseUp et du clavier, sinon la LCL en ajoute
  // un second.
  ControlStyle := ControlStyle + [csOpaque] - [csClickEvents, csDoubleClicks, csAcceptsControls];
  TabStop := True;
  FInk := clDefault;
  FFill := clNone;
  FBorder := clNone;
  Width := 28;
  Height := 26;
end;

procedure TRtFlatButton.Setup(const AIconId, AText: string; AInk: TColor);
begin
  FIconId := AIconId;
  FText := AText;
  FInk := AInk;
  FitWidth;
  Invalidate;
end;

procedure TRtFlatButton.SetText(const AValue: string);
begin
  if FText = AValue then Exit;
  FText := AValue;
  Invalidate;
end;

procedure TRtFlatButton.SetIconId(const AValue: string);
begin
  if FIconId = AValue then Exit;
  FIconId := AValue;
  Invalidate;
end;

function TRtFlatButton.InkColor: TColor;
begin
  if FInk = clDefault then Result := clAppFg else Result := FInk;
  if not Enabled then Result := BlendColor(Result, BackColor, 45);
end;

function TRtFlatButton.BackColor: TColor;
begin
  if FFill <> clNone then Exit(FFill);
  if Parent <> nil then Result := Parent.Brush.Color else Result := clAppBg;
end;

function TRtFlatButton.PreferredWidth: Integer;
var
  w: Integer;
begin
  w := 0;
  if (FIconId <> '') or (FGlyph = rbgDots) then w := ScreenIconSize(ICON_LOGICAL);
  if FText <> '' then
  begin
    if w > 0 then Inc(w, GAP);
    Inc(w, MeasureText(Font, FText));
    Result := w + 2 * PAD_H;
  end
  else
    Result := w + 10;
end;

function TRtFlatButton.PreferredHeight: Integer;
begin
  Result := FontTextHeight(Font) + 10 + 2 * FInsetY;
  if Result < ScreenIconSize(ICON_LOGICAL) + 8 + 2 * FInsetY then
    Result := ScreenIconSize(ICON_LOGICAL) + 8 + 2 * FInsetY;
end;

procedure TRtFlatButton.FitWidth;
begin
  Width := PreferredWidth;
end;

procedure TRtFlatButton.Paint;
var
  r: TRect;
  bg, back, fg: TColor;
  bmp: TBitmap;
  px, x, cx, cy, i, tw: Integer;
begin
  back := BackColor;
  Canvas.Brush.Style := bsSolid;
  if Parent <> nil then Canvas.Brush.Color := Parent.Brush.Color else Canvas.Brush.Color := clAppBg;
  Canvas.FillRect(ClientRect);
  fg := InkColor;
  bg := back;
  if Enabled and FDown then bg := BlendColor(fg, back, 24)
  else if Enabled and FHot then bg := BlendColor(fg, back, 13);
  r := Rect(0, FInsetY, ClientWidth, ClientHeight - FInsetY);
  Canvas.Brush.Color := bg;
  if Focused then
    Canvas.Pen.Color := clAccent
  else if FBorder <> clNone then
    Canvas.Pen.Color := FBorder
  else
    Canvas.Pen.Color := bg;
  Canvas.Pen.Width := 1;
  Canvas.RoundRect(r.Left, r.Top, r.Right, r.Bottom, 8, 8);
  px := ScreenIconSize(ICON_LOGICAL);
  Canvas.Font.Assign(Font);
  Canvas.Font.Color := fg;
  tw := 0;
  if FText <> '' then tw := Canvas.TextWidth(FText);
  x := 0;
  if (FIconId <> '') or (FGlyph = rbgDots) then x := px;
  if (x > 0) and (tw > 0) then Inc(x, GAP);
  Inc(x, tw);
  x := (ClientWidth - x) div 2;
  cy := (r.Top + r.Bottom) div 2;
  if FGlyph = rbgDots then
  begin
    Canvas.Brush.Color := fg;
    Canvas.Pen.Color := fg;
    cx := x + px div 2;
    for i := -1 to 1 do
      Canvas.Ellipse(cx + i * 5 - 2, cy - 2, cx + i * 5 + 2, cy + 2);
    Inc(x, px);
    if tw > 0 then Inc(x, GAP);
  end
  else if FIconId <> '' then
  begin
    bmp := IconBitmap(FIconId, px, fg);
    if bmp <> nil then Canvas.Draw(x, cy - px div 2, bmp);
    Inc(x, px);
    if tw > 0 then Inc(x, GAP);
  end;
  if tw > 0 then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(x, cy - Canvas.TextHeight('Ag') div 2, FText);
  end;
end;

procedure TRtFlatButton.MouseEnter;
begin
  inherited MouseEnter;
  FHot := True;
  Invalidate;
end;

procedure TRtFlatButton.MouseLeave;
begin
  inherited MouseLeave;
  FHot := False;
  FDown := False;
  Invalidate;
end;

procedure TRtFlatButton.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and Enabled then
  begin
    FDown := True;
    Invalidate;
  end;
end;

procedure TRtFlatButton.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  wasDown: Boolean;
begin
  wasDown := FDown;
  FDown := False;
  Invalidate;
  inherited MouseUp(Button, Shift, X, Y);
  // TControl.MouseUp ne declenche pas OnClick pour un TCustomControl. Le clic part d'ici,
  // et seulement si le bouton est relache sur le controle.
  if wasDown and (Button = mbLeft) and Enabled and PtInRect(ClientRect, Point(X, Y)) then
    Click;
end;

procedure TRtFlatButton.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if (Key in [VK_SPACE, VK_RETURN]) and (Shift = []) and Enabled then
  begin
    Key := 0;
    Click;
  end;
end;

procedure TRtFlatButton.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TRtFlatButton.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

constructor TRtSegmented.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque] - [csClickEvents, csDoubleClicks, csAcceptsControls];
  TabStop := True;
  FItems := TStringList.Create;
  FItemIndex := -1;
  Width := 240;
  Height := 28;
end;

destructor TRtSegmented.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TRtSegmented.SetChoices(const AItems: array of string; AIndex: Integer);
var
  i: Integer;
begin
  FItems.Clear;
  for i := 0 to High(AItems) do FItems.Add(AItems[i]);
  FItemIndex := AIndex;
  Invalidate;
end;

function TRtSegmented.PreferredWidth: Integer;
var
  i, w: Integer;
begin
  w := 0;
  for i := 0 to FItems.Count - 1 do
    w := Max(w, MeasureText(Font, FItems[i], [fsBold]));
  Result := FItems.Count * (w + 22) + 4;
end;

procedure TRtSegmented.SetItemIndex(AValue: Integer);
begin
  if (AValue < 0) or (AValue >= FItems.Count) or (AValue = FItemIndex) then Exit;
  FItemIndex := AValue;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TRtSegmented.SegmentAt(X: Integer): Integer;
begin
  if FItems.Count = 0 then Exit(-1);
  Result := Max(0, Min(FItems.Count - 1, X * FItems.Count div Max(1, ClientWidth)));
end;

procedure TRtSegmented.Paint;
var
  bg, txt: TColor;
  i, x0, x1: Integer;
  seg: TRect;
begin
  if Parent <> nil then bg := Parent.Brush.Color else bg := clAppBg;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := bg;
  Canvas.FillRect(ClientRect);
  Canvas.Brush.Color := BlendColor(clEditorBg, bg, 60);
  if Focused then Canvas.Pen.Color := clAccent else Canvas.Pen.Color := BlendColor(clAppFg, bg, 28);
  Canvas.Pen.Width := 1;
  Canvas.RoundRect(0, 0, ClientWidth, ClientHeight, 10, 10);
  Canvas.Font.Assign(Font);
  Canvas.Font.Style := [fsBold];
  for i := 0 to FItems.Count - 1 do
  begin
    x0 := i * ClientWidth div FItems.Count;
    x1 := (i + 1) * ClientWidth div FItems.Count;
    seg := Rect(x0 + 2, 2, x1 - 2, ClientHeight - 2);
    if i = FItemIndex then
    begin
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := clAccent;
      Canvas.Pen.Color := clAccent;
      Canvas.RoundRect(seg.Left, seg.Top, seg.Right, seg.Bottom, 8, 8);
      if IsDarkColor(clAccent) then txt := clWhite else txt := RgbHexToColor($101010);
    end
    else
      txt := BlendColor(clAppFg, bg, 70);
    if not Enabled then txt := BlendColor(txt, bg, 50);
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Color := txt;
    Canvas.TextOut((seg.Left + seg.Right - Canvas.TextWidth(FItems[i])) div 2,
      (seg.Top + seg.Bottom - Canvas.TextHeight(FItems[i])) div 2, FItems[i]);
  end;
end;

procedure TRtSegmented.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or not Enabled then Exit;
  if CanFocus then SetFocus;
  ItemIndex := SegmentAt(X);
end;

procedure TRtSegmented.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if Shift <> [] then Exit;
  case Key of
    VK_LEFT:
      begin
        ItemIndex := FItemIndex - 1;
        Key := 0;
      end;
    VK_RIGHT:
      begin
        ItemIndex := FItemIndex + 1;
        Key := 0;
      end;
  end;
end;

procedure TRtSegmented.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TRtSegmented.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

constructor TRtStepper.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque] - [csAcceptsControls];
  FSteps := TStringList.Create;
  Height := 34;
end;

destructor TRtStepper.Destroy;
begin
  FSteps.Free;
  inherited Destroy;
end;

procedure TRtStepper.SetSteps(const ASteps: array of string);
var
  i: Integer;
begin
  FSteps.Clear;
  for i := 0 to High(ASteps) do FSteps.Add(ASteps[i]);
  Invalidate;
end;

procedure TRtStepper.SetCurrent(AValue: Integer);
begin
  if FCurrent = AValue then Exit;
  FCurrent := AValue;
  Invalidate;
end;

function TRtStepper.PreferredHeight: Integer;
begin
  Result := FontTextHeight(Font) + 16;
end;

procedure TRtStepper.Paint;
var
  bg, ok, muted, fill, ink: TColor;
  i, n, seg, x, cy, d, tx, nextX, tw: Integer;
  r: TRect;
  num: string;
begin
  if Parent <> nil then bg := Parent.Brush.Color else bg := clAppBg;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := bg;
  Canvas.FillRect(ClientRect);
  n := FSteps.Count;
  if n = 0 then Exit;
  ok := ShellStateColor(usOk);
  muted := BlendColor(clAppFg, bg, 45);
  Canvas.Font.Assign(Font);
  d := Canvas.TextHeight('Ag') + 6;
  cy := ClientHeight div 2;
  seg := ClientWidth div n;
  for i := 0 to n - 1 do
  begin
    x := i * seg + 2;
    r := Rect(x, cy - d div 2, x + d, cy + d div 2);
    Canvas.Font.Style := [];
    if i = FCurrent then Canvas.Font.Style := [fsBold];
    tw := Canvas.TextWidth(FSteps[i]);
    tx := r.Right + 6;
    if i < n - 1 then
    begin
      nextX := (i + 1) * seg + 2;
      if tx + tw + 8 < nextX - 6 then
      begin
        if i < FCurrent then Canvas.Pen.Color := ok else Canvas.Pen.Color := muted;
        Canvas.Pen.Width := 2;
        Canvas.Line(tx + tw + 8, cy, nextX - 6, cy);
        Canvas.Pen.Width := 1;
      end;
    end;
    if i < FCurrent then
    begin
      fill := ok;
      ink := bg;
    end
    else if i = FCurrent then
    begin
      fill := clAccent;
      ink := bg;
    end
    else
    begin
      fill := bg;
      ink := muted;
    end;
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := fill;
    if i > FCurrent then Canvas.Pen.Color := muted else Canvas.Pen.Color := fill;
    Canvas.Ellipse(r.Left, r.Top, r.Right, r.Bottom);
    Canvas.Brush.Style := bsClear;
    if i < FCurrent then
    begin
      Canvas.Pen.Color := ink;
      Canvas.Pen.Width := 2;
      Canvas.Line(r.Left + d div 4, cy, r.Left + d * 2 div 5 + 1, cy + d div 5);
      Canvas.Line(r.Left + d * 2 div 5 + 1, cy + d div 5, r.Right - d div 4, cy - d div 5);
      Canvas.Pen.Width := 1;
    end
    else
    begin
      num := IntToStr(i + 1);
      Canvas.Font.Style := [fsBold];
      Canvas.Font.Color := ink;
      Canvas.TextOut((r.Left + r.Right - Canvas.TextWidth(num)) div 2,
        cy - Canvas.TextHeight(num) div 2, num);
    end;
    if i = FCurrent then
    begin
      Canvas.Font.Style := [fsBold];
      Canvas.Font.Color := clAppFg;
    end
    else
    begin
      Canvas.Font.Style := [];
      if i < FCurrent then Canvas.Font.Color := BlendColor(clAppFg, bg, 75) else Canvas.Font.Color := muted;
    end;
    Canvas.TextOut(tx, cy - Canvas.TextHeight('Ag') div 2, FSteps[i]);
  end;
end;

finalization
  GMeasure.Free;

end.
