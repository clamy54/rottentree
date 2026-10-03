// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uRtCheck;

{$mode objfpc}{$H+}

// Case a cocher dessinee aux couleurs du theme. La case native de Windows (visual styles)
// ignore la couleur du texte et l'ecrit en noir: sur fond sombre, autant cocher a l'aveugle.
// Meme contrat que TCheckBox: OnChange puis OnClick, par l'utilisateur comme par code.

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, LCLIntf;

type
  TRtCheckBox = class(TCustomControl)
  private
    FChecked: Boolean;
    FHot: Boolean;
    FPressed: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetChecked(AValue: Boolean);
    function BoxSize: Integer;
    function TextRectFor(AWidth: Integer): TRect;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure TextChanged; override;
    procedure FontChanged(Sender: TObject); override;
    procedure DoOnResize; override;
    procedure CalculatePreferredSize(var PreferredWidth, PreferredHeight: Integer;
      WithThemeSpace: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Toggle;
    property Checked: Boolean read FChecked write SetChecked;
    property Caption;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property OnClick;
  end;

implementation

uses
  uTheme;

const
  GAP = 7;
  PAD_Y = 3;
  // Cocoa trace le contour a cheval sur la coordonnee: un cadre pose en x = 0 perdait
  // son bord gauche.
  BOX_X = 1;

constructor TRtCheckBox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // Le clic passe par Toggle et jamais par la LCL, sinon OnClick part deux fois.
  ControlStyle := ControlStyle - [csClickEvents, csDoubleClicks, csAcceptsControls];
  TabStop := True;
  ParentColor := True;
  AutoSize := True;
  Width := 160;
  Height := 22;
end;

function TRtCheckBox.BoxSize: Integer;
begin
  Result := Canvas.TextHeight('Ag');
  if Result < 13 then Result := 13;
  Dec(Result, 2);
end;

function TRtCheckBox.TextRectFor(AWidth: Integer): TRect;
var
  flags: Cardinal;
begin
  Canvas.Font.Assign(Font);
  Result := Rect(0, 0, AWidth - BOX_X - BoxSize - GAP, 0);
  flags := DT_CALCRECT or DT_NOPREFIX;
  if Align in [alTop, alBottom, alClient] then
    flags := flags or DT_WORDBREAK
  else
    flags := flags or DT_SINGLELINE;
  if Result.Right < 20 then Result.Right := 20;
  DrawText(Canvas.Handle, PChar(Caption), Length(Caption), Result, flags);
end;

procedure TRtCheckBox.CalculatePreferredSize(var PreferredWidth, PreferredHeight: Integer;
  WithThemeSpace: Boolean);
var
  r: TRect;
  w: Integer;
begin
  if not (HandleAllocated or ((Parent <> nil) and Parent.HandleAllocated)) then
  begin
    inherited CalculatePreferredSize(PreferredWidth, PreferredHeight, WithThemeSpace);
    Exit;
  end;
  if Align in [alTop, alBottom, alClient] then w := Width else w := 10000;
  r := TextRectFor(w);
  PreferredWidth := BOX_X + BoxSize + GAP + (r.Right - r.Left) + 2;
  PreferredHeight := r.Bottom - r.Top;
  if PreferredHeight < BoxSize then PreferredHeight := BoxSize;
  Inc(PreferredHeight, 2 * PAD_Y);
end;

procedure TRtCheckBox.Paint;
var
  r, box, tr: TRect;
  b, cy: Integer;
  fg, frame: TColor;
  flags: Cardinal;
begin
  Canvas.Font.Assign(Font);
  Canvas.Brush.Style := bsSolid;
  if Parent <> nil then
    Canvas.Brush.Color := Parent.Brush.Color
  else
    Canvas.Brush.Color := clAppBg;
  r := ClientRect;
  Canvas.FillRect(r);
  b := BoxSize;
  cy := PAD_Y + (Canvas.TextHeight('Ag') - b) div 2;
  if cy < 0 then cy := 0;
  box := Rect(BOX_X, cy, BOX_X + b, cy + b);

  if Enabled then fg := Font.Color
  else fg := BlendColor(Font.Color, Canvas.Brush.Color, 45);
  if Focused then frame := clAccent
  else if FHot and Enabled then frame := BlendColor(clAppFg, clAppBg, 60)
  else frame := BlendColor(clAppFg, clAppBg, 40);

  Canvas.Pen.Width := 1;
  Canvas.Pen.Color := frame;
  if FChecked then
    Canvas.Brush.Color := clAccent
  else if FPressed then
    Canvas.Brush.Color := BlendColor(clEditorBg, clAppFg, 85)
  else
    Canvas.Brush.Color := clEditorBg;
  if FChecked and not Enabled then
    Canvas.Brush.Color := BlendColor(clAccent, clAppBg, 45);
  Canvas.RoundRect(box.Left, box.Top, box.Right, box.Bottom, 4, 4);
  if FChecked then
  begin
    Canvas.Pen.Color := clEditorBg;
    Canvas.Pen.Width := 2;
    Canvas.Line(box.Left + b * 22 div 100, box.Top + b * 52 div 100,
      box.Left + b * 42 div 100, box.Top + b * 72 div 100);
    Canvas.Line(box.Left + b * 42 div 100, box.Top + b * 72 div 100,
      box.Left + b * 78 div 100, box.Top + b * 30 div 100);
    Canvas.Pen.Width := 1;
  end;

  tr := Rect(BOX_X + b + GAP, PAD_Y, r.Right, r.Bottom);
  flags := DT_NOPREFIX;
  if Align in [alTop, alBottom, alClient] then
    flags := flags or DT_WORDBREAK
  else
    flags := flags or DT_SINGLELINE;
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := fg;
  DrawText(Canvas.Handle, PChar(Caption), Length(Caption), tr, flags);
  Canvas.Brush.Style := bsSolid;
end;

procedure TRtCheckBox.SetChecked(AValue: Boolean);
begin
  if FChecked = AValue then Exit;
  FChecked := AValue;
  Invalidate;
  if [csLoading, csDestroying] * ComponentState <> [] then Exit;
  if Assigned(FOnChange) then FOnChange(Self);
  Click;
end;

procedure TRtCheckBox.Toggle;
begin
  Checked := not FChecked;
end;

procedure TRtCheckBox.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  if CanFocus then SetFocus;
  FPressed := True;
  Invalidate;
end;

procedure TRtCheckBox.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  was: Boolean;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;
  was := FPressed;
  FPressed := False;
  Invalidate;
  if was and Enabled and PtInRect(ClientRect, Point(X, Y)) then Toggle;
end;

procedure TRtCheckBox.MouseEnter;
begin
  inherited MouseEnter;
  FHot := True;
  Invalidate;
end;

procedure TRtCheckBox.MouseLeave;
begin
  inherited MouseLeave;
  FHot := False;
  Invalidate;
end;

procedure TRtCheckBox.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if (Key = VK_SPACE) and (Shift = []) then
  begin
    Toggle;
    Key := 0;
  end;
end;

procedure TRtCheckBox.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TRtCheckBox.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

procedure TRtCheckBox.TextChanged;
begin
  inherited TextChanged;
  InvalidatePreferredSize;
  AdjustSize;
  Invalidate;
end;

procedure TRtCheckBox.FontChanged(Sender: TObject);
begin
  inherited FontChanged(Sender);
  InvalidatePreferredSize;
  AdjustSize;
  Invalidate;
end;

procedure TRtCheckBox.DoOnResize;
begin
  inherited DoOnResize;
  if Align in [alTop, alBottom, alClient] then
  begin
    InvalidatePreferredSize;
    AdjustSize;
  end;
end;

end.
