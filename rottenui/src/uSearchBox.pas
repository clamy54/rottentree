// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSearchBox;

{$mode objfpc}{$H+}

// Champ de recherche du panneau lateral: un TEdit sans bordure dans une pilule dessinee
// a la main. Le TextHint natif est illisible sur fond sombre, d'ou une invite maison qui
// n'apparait jamais dans SearchText.

interface

uses
  Classes, SysUtils, Types, Controls, StdCtrls, Graphics, LCLType
  {$IFDEF LCLGtk2}, gtk2, gdk2, glib2{$ENDIF};

type
  TSearchBoxGlyph = (sbgSearch, sbgGoTo);

  TRottenSearchBox = class(TCustomControl)
  private
    FGlyph: TSearchBoxGlyph;
    FOnSubmit: TNotifyEvent;
    FEdit: TEdit;
    FHintText: string;
    FEnabledLook: Boolean;
    FShowingHint: Boolean;
    FInternalEdit: Boolean;
    FClearHot: Boolean;
    {$IFDEF LCLGtk2}
    // GTK2: recolorer l'entry exige un handle realise, et ApplyTheme passe trop tot.
    FGtkColorDone: Boolean;
    {$ENDIF}
    FOnSearchChange: TNotifyEvent;
    FOnEscape: TNotifyEvent;
    FColBg: TColor;
    FColField: TColor;
    FColBorder: TColor;
    FColBorderFocus: TColor;
    FColText: TColor;
    FColHint: TColor;
    FColIcon: TColor;

    procedure EditChange(Sender: TObject);
    procedure EditEnter(Sender: TObject);
    procedure EditExit(Sender: TObject);
    procedure EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    function FieldRect: TRect;
    function ClearRect: TRect;
    function HasText: Boolean;
    procedure LayoutEdit;
    procedure ShowHint;
    procedure HideHint;
    procedure DrawMagnifier(const AIconRect: TRect);
    procedure DrawClear(const R: TRect);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;

    procedure ApplyTheme(ABg, AField, ABorder, ABorderFocus, AText, AHint,
      AIcon: TColor);
    procedure SetEnabledLook(AEnabled: Boolean);
    procedure Clear;
    procedure FocusEdit;
    function CanFocusEdit: Boolean;
    procedure SetText(const AText: string);
    procedure SelectAll;
    function SearchText: string;

    property HintText: string read FHintText write FHintText;
    property OnSearchChange: TNotifyEvent read FOnSearchChange write FOnSearchChange;
    property OnEscape: TNotifyEvent read FOnEscape write FOnEscape;
    property OnSubmit: TNotifyEvent read FOnSubmit write FOnSubmit;
    property Glyph: TSearchBoxGlyph read FGlyph write FGlyph;
  end;

implementation

const
  MARGIN_H    = 6;
  // Plus serre sous GTK2: l'entry y est plus haute et mangerait la bordure.
  {$IFDEF LCLGtk2}
  MARGIN_V    = 4;
  {$ELSE}
  MARGIN_V    = 5;
  {$ENDIF}
  ICON_ZONE_W = 28;
  CLEAR_ZONE_W = 24;

function Mix(A, B: TColor; P: Integer): TColor;
var
  ca, cb: LongInt;
  r, g, bl: Integer;
begin
  ca := ColorToRGB(A);
  cb := ColorToRGB(B);
  r  := ((ca and $FF) * P + (cb and $FF) * (100 - P)) div 100;
  g  := (((ca shr 8) and $FF) * P + ((cb shr 8) and $FF) * (100 - P)) div 100;
  bl := (((ca shr 16) and $FF) * P + ((cb shr 16) and $FF) * (100 - P)) div 100;
  Result := TColor(r or (g shl 8) or (bl shl 16));
end;

{$IFDEF LCLGtk2}
// Les themes GTK2 a moteur (Yaru) ignorent modify_base: on leur impose un GtkStyle neuf,
// complet, sans rien leur demander.
procedure ForceGtk2EntryColors(AEdit: TWinControl; ABase, AText: TColor);
  function GC(c: TColor): TGdkColor;
  var r: LongInt;
  begin
    r := ColorToRGB(c);
    Result.pixel := 0;
    Result.red   := (r and $FF) * 257;
    Result.green := ((r shr 8) and $FF) * 257;
    Result.blue  := ((r shr 16) and $FF) * 257;
  end;
var
  w: PGtkWidget;
  cb, ct: TGdkColor;
  st: TGtkStateType;
  style: PGtkStyle;
begin
  AEdit.HandleNeeded;
  if not AEdit.HandleAllocated then Exit;
  w := PGtkWidget(AEdit.Handle);
  cb := GC(ABase);
  ct := GC(AText);
  style := gtk_style_new;
  for st := GTK_STATE_NORMAL to GTK_STATE_INSENSITIVE do
  begin
    style^.base[st] := cb;
    style^.bg[st]   := cb;
    style^.text[st] := ct;
    style^.fg[st]   := ct;
  end;
  // Epaisseurs a zero, sinon l'entry deborde du pill et recouvre sa bordure.
  style^.xthickness := 0;
  style^.ythickness := 0;
  gtk_widget_set_style(w, style);
  g_object_unref(style);   // le widget garde sa propre reference
  gtk_widget_queue_resize(w);
end;
{$ENDIF}

constructor TRottenSearchBox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  TabStop := False;
  FHintText := 'Search…';
  FEnabledLook := False;
  FColBg := clBlack;
  FColField := clBlack;
  FColBorder := clGray;
  FColBorderFocus := clHighlight;
  FColText := clWhite;
  FColHint := clGray;
  FColIcon := clGray;

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.BorderStyle := bsNone;
  FEdit.AutoSize := True;
  FEdit.TabStop := True;
  FEdit.Enabled := False;
  FEdit.OnChange := @EditChange;
  FEdit.OnEnter := @EditEnter;
  FEdit.OnExit := @EditExit;
  FEdit.OnKeyDown := @EditKeyDown;
end;

function TRottenSearchBox.FieldRect: TRect;
begin
  Result := Rect(MARGIN_H, MARGIN_V, ClientWidth - MARGIN_H,
    ClientHeight - MARGIN_V);
end;

function TRottenSearchBox.ClearRect: TRect;
var
  f: TRect;
begin
  f := FieldRect;
  Result := Rect(f.Right - CLEAR_ZONE_W, f.Top, f.Right, f.Bottom);
end;

function TRottenSearchBox.HasText: Boolean;
begin
  Result := (not FShowingHint) and (Trim(FEdit.Text) <> '');
end;

procedure TRottenSearchBox.LayoutEdit;
var
  f: TRect;
  eh: Integer;
begin
  if FEdit = nil then Exit;
  f := FieldRect;
  {$IFDEF LCLGtk3}
  // GTK3 impose a l'entry la hauteur minimale de son theme et la laisse deborder du cadre.
  // On la contraint. Elle boude, mais elle reste dedans.
  if f.Bottom - f.Top > 2 then
    FEdit.Constraints.MaxHeight := f.Bottom - f.Top - 2;
  {$ENDIF}
  eh := FEdit.Height;
  FEdit.SetBounds(
    f.Left + ICON_ZONE_W,
    f.Top + (f.Bottom - f.Top - eh) div 2,
    (f.Right - CLEAR_ZONE_W) - (f.Left + ICON_ZONE_W),
    eh);
end;

procedure TRottenSearchBox.Resize;
begin
  inherited Resize;
  LayoutEdit;
end;

procedure TRottenSearchBox.ShowHint;
begin
  if FShowingHint then Exit;
  if not FEnabledLook then Exit;
  if FEdit.Focused then Exit;
  if FEdit.Text <> '' then Exit;
  FInternalEdit := True;
  try
    FEdit.Font.Color := FColHint;
    FEdit.Text := FHintText;
    FShowingHint := True;
  finally
    FInternalEdit := False;
  end;
end;

procedure TRottenSearchBox.HideHint;
begin
  if not FShowingHint then Exit;
  FInternalEdit := True;
  try
    FEdit.Text := '';
    FEdit.Font.Color := FColText;
    FShowingHint := False;
  finally
    FInternalEdit := False;
  end;
end;

procedure TRottenSearchBox.EditChange(Sender: TObject);
begin
  if FInternalEdit then Exit;
  Invalidate;
  if Assigned(FOnSearchChange) then
    FOnSearchChange(Self);
end;

procedure TRottenSearchBox.EditEnter(Sender: TObject);
begin
  HideHint;
  Invalidate;
end;

procedure TRottenSearchBox.EditExit(Sender: TObject);
begin
  ShowHint;
  Invalidate;
end;

procedure TRottenSearchBox.EditKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    Key := 0;
    if Assigned(FOnSubmit) then
      FOnSubmit(Self);
    Exit;
  end;
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    if FEdit.Text <> '' then
      FEdit.Text := '';
    if Assigned(FOnEscape) then
      FOnEscape(Self);
  end;
end;

procedure TRottenSearchBox.DrawMagnifier(const AIconRect: TRect);
var
  cx, cy, r, hx, hy: Integer;
begin
  cx := (AIconRect.Left + AIconRect.Right) div 2 - 1;
  cy := (AIconRect.Top + AIconRect.Bottom) div 2 - 1;
  r := 5;
  Canvas.Pen.Color := FColIcon;
  Canvas.Pen.Width := 2;
  Canvas.Pen.Style := psSolid;
  Canvas.Brush.Style := bsClear;
  if FGlyph = sbgGoTo then
  begin
    Canvas.Line(cx - 6, cy, cx + 5, cy);
    Canvas.Line(cx + 1, cy - 4, cx + 5, cy);
    Canvas.Line(cx + 1, cy + 4, cx + 5, cy);
    Exit;
  end;
  Canvas.Ellipse(cx - r, cy - r, cx + r, cy + r);
  hx := cx + Round(r * 0.7);
  hy := cy + Round(r * 0.7);
  Canvas.Line(hx, hy, hx + 4, hy + 4);
end;

procedure TRottenSearchBox.DrawClear(const R: TRect);
var
  cx, cy, d: Integer;
begin
  cx := (R.Left + R.Right) div 2;
  cy := (R.Top + R.Bottom) div 2;
  if FClearHot then
  begin
    Canvas.Brush.Color := Mix(FColText, FColField, 16);
    Canvas.Brush.Style := bsSolid;
    Canvas.Pen.Style := psClear;
    Canvas.Ellipse(cx - 9, cy - 9, cx + 9, cy + 9);
  end;
  d := 3;
  if FClearHot then
    Canvas.Pen.Color := FColText
  else
    Canvas.Pen.Color := FColIcon;
  Canvas.Pen.Width := 2;
  Canvas.Pen.Style := psSolid;
  Canvas.Line(cx - d, cy - d, cx + d + 1, cy + d + 1);
  Canvas.Line(cx - d, cy + d, cx + d + 1, cy - d - 1);
end;

procedure TRottenSearchBox.Paint;
var
  f: TRect;
  rad: Integer;
begin
  {$IFDEF LCLGtk2}
  // Au premier Paint l'entry est enfin realisee: seul moment sur pour reposer son fond.
  if (not FGtkColorDone) and FEdit.HandleAllocated then
  begin
    ForceGtk2EntryColors(FEdit, FColField, FColText);
    FEdit.AdjustSize;
    LayoutEdit;
    FGtkColorDone := True;
  end;
  {$ENDIF}
  Canvas.Brush.Color := FColBg;
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.FillRect(ClientRect);

  // RoundRect en un seul primitif: assemble a la main, GTK2 decale les jonctions d'un pixel.
  f := FieldRect;
  rad := f.Bottom - f.Top;
  Canvas.Brush.Color := FColField;
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psSolid;
  if FEdit.Focused then
  begin
    Canvas.Pen.Color := FColBorderFocus;
    Canvas.Pen.Width := 2;
  end
  else
  begin
    Canvas.Pen.Color := FColBorder;
    Canvas.Pen.Width := 1;
  end;
  Canvas.RoundRect(f.Left, f.Top, f.Right, f.Bottom, rad, rad);

  DrawMagnifier(Rect(f.Left, f.Top, f.Left + ICON_ZONE_W, f.Bottom));
  if HasText then
    DrawClear(ClearRect);
end;

procedure TRottenSearchBox.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  hot: Boolean;
begin
  inherited MouseMove(Shift, X, Y);
  hot := HasText and PtInRect(ClearRect, Point(X, Y));
  if hot <> FClearHot then
  begin
    FClearHot := hot;
    if hot then Cursor := crHandPoint else Cursor := crDefault;
    Invalidate;
  end;
end;

procedure TRottenSearchBox.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if not FEnabledLook then Exit;
  if HasText and PtInRect(ClearRect, Point(X, Y)) then
  begin
    FEdit.Text := '';
    FocusEdit;
    Exit;
  end;
  FocusEdit;
end;

procedure TRottenSearchBox.MouseLeave;
begin
  inherited MouseLeave;
  if FClearHot then
  begin
    FClearHot := False;
    Cursor := crDefault;
    Invalidate;
  end;
end;

procedure TRottenSearchBox.ApplyTheme(ABg, AField, ABorder, ABorderFocus,
  AText, AHint, AIcon: TColor);
begin
  FColBg := ABg;
  FColField := AField;
  FColBorder := ABorder;
  FColBorderFocus := ABorderFocus;
  FColText := AText;
  FColHint := AHint;
  FColIcon := AIcon;
  Color := ABg;
  FEdit.Color := AField;
  {$IFDEF LCLGtk2}
  FGtkColorDone := False;
  if FEdit.HandleAllocated then
  begin
    ForceGtk2EntryColors(FEdit, AField, AText);
    FGtkColorDone := True;
  end;
  {$ENDIF}
  if FShowingHint then
    FEdit.Font.Color := FColHint
  else
    FEdit.Font.Color := FColText;
  LayoutEdit;
  Invalidate;
end;

procedure TRottenSearchBox.SetEnabledLook(AEnabled: Boolean);
begin
  FEnabledLook := AEnabled;
  FEdit.Enabled := AEnabled;
  if AEnabled then
  begin
    if not FEdit.Focused then
      ShowHint;
  end
  else
  begin
    FInternalEdit := True;
    try
      FEdit.Text := '';
      FShowingHint := False;
    finally
      FInternalEdit := False;
    end;
  end;
  Invalidate;
end;

procedure TRottenSearchBox.Clear;
begin
  FInternalEdit := True;
  try
    FEdit.Text := '';
    FShowingHint := False;
  finally
    FInternalEdit := False;
  end;
  if FEnabledLook and (not FEdit.Focused) then
    ShowHint;
  Invalidate;
end;

procedure TRottenSearchBox.SetText(const AText: string);
begin
  FInternalEdit := True;
  try
    FShowingHint := False;
    FEdit.Font.Color := FColText;
    FEdit.Text := AText;
  finally
    FInternalEdit := False;
  end;
  if (AText = '') and FEnabledLook and (not FEdit.Focused) then
    ShowHint;
  Invalidate;
end;

procedure TRottenSearchBox.SelectAll;
begin
  if not FShowingHint then
    FEdit.SelectAll;
end;

procedure TRottenSearchBox.FocusEdit;
begin
  if FEdit.CanFocus then
    FEdit.SetFocus;
end;

function TRottenSearchBox.CanFocusEdit: Boolean;
begin
  Result := FEnabledLook and FEdit.Enabled and FEdit.CanFocus;
end;

function TRottenSearchBox.SearchText: string;
begin
  if FShowingHint then
    Result := ''
  else
    Result := Trim(FEdit.Text);
end;

end.
