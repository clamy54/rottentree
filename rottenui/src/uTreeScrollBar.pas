// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTreeScrollBar;

{$mode objfpc}{$H+}

// Barre de defilement themee: la LCL laisse celles de la TTreeView au widgetset natif,
// gris systeme en plein theme sombre. La molette glisse vers une cible accumulee, un
// positionnement direct (pouce, clavier) annule l'animation.

interface

uses
  Classes, SysUtils, Types, Controls, ComCtrls, ExtCtrls, Graphics, LMessages;

type
  IThemedScrollTarget = interface
    ['{4E3C1A62-9B7D-4C0E-8F21-5A6D2B9C1E44}']
    function ScrollViewportHeight: Integer;
    function ScrollMaxTop: Integer;
    function ScrollGetTop: Integer;
    procedure ScrollSetTop(AValue: Integer);
    procedure ScrollAnimateBy(ADelta: Integer);
    procedure ScrollWheelBy(AWheelDelta: Integer);
    procedure SetOnScrollViewChanged(AHandler: TNotifyEvent);
  end;

  TScrollTreeView = class(TTreeView, IThemedScrollTarget)
  private
    FOnViewChanged: TNotifyEvent;
    FWheelTimer: TTimer;
    FWheelTarget: Integer;
    FWheelActive: Boolean;
    function GetScrollTop: Integer;
    procedure SetScrollTop(AValue: Integer);
    procedure WheelStop;
    procedure WheelTick(Sender: TObject);
  protected
    procedure Paint; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    function DoMouseWheelHorz(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure WMHScroll(var Msg: TLMScroll); message LM_HSCROLL;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    function MaxScrollTop: Integer;
    function ViewportHeight: Integer;
    procedure AnimateScrollBy(ADelta: Integer);
    procedure WheelScrollBy(AWheelDelta: Integer);
    function ScrollViewportHeight: Integer;
    function ScrollMaxTop: Integer;
    function ScrollGetTop: Integer;
    procedure ScrollSetTop(AValue: Integer);
    procedure ScrollAnimateBy(ADelta: Integer);
    procedure ScrollWheelBy(AWheelDelta: Integer);
    procedure SetOnScrollViewChanged(AHandler: TNotifyEvent);
    property ScrollTop: Integer read GetScrollTop write SetScrollTop;
    property OnViewChanged: TNotifyEvent read FOnViewChanged write FOnViewChanged;
  end;

  TTreeScrollBar = class(TCustomControl)
  private
    // Le meme objet deux fois: l'interface pilote, le TControl recoit FreeNotification.
    FTarget: IThemedScrollTarget;
    FTargetCtl: TControl;
    FDragging: Boolean;
    FDragOffset: Integer;
    FDragThumbTop: Integer;
    FHover: Boolean;
    FTrough: TColor;
    FThumb: TColor;
    FThumbHover: TColor;
    function ThumbMetrics(out AThumbH, ATrack: Integer): Boolean;
    function ThumbRect: TRect;
    procedure TreeViewChanged(Sender: TObject);
    procedure ScrollToThumbTop(AThumbTop: Integer);
  protected
    procedure Paint; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Bind(ATarget: TControl);
    procedure ApplyTheme(ATrough, AThumb, AThumbHover: TColor);
  end;

implementation

const
  THUMB_INSET = 2;
  MIN_THUMB   = 28;
  THUMB_RADIUS = 6;
  WHEEL_TICK_MS = 15;  // WM_TIMER ne descend pas plus bas

function TScrollTreeView.GetScrollTop: Integer;
begin
  Result := ScrolledTop;
end;

procedure TScrollTreeView.SetScrollTop(AValue: Integer);
begin
  WheelStop;
  ScrolledTop := AValue;
end;

procedure TScrollTreeView.WheelStop;
begin
  FWheelActive := False;
  if FWheelTimer <> nil then
    FWheelTimer.Enabled := False;
end;

procedure TScrollTreeView.AnimateScrollBy(ADelta: Integer);
var
  target, maxTop: Integer;
begin
  if ADelta = 0 then Exit;
  if FWheelActive then
    target := FWheelTarget + ADelta
  else
    target := ScrolledTop + ADelta;
  maxTop := GetMaxScrollTop;
  if target < 0 then target := 0;
  if target > maxTop then target := maxTop;
  FWheelTarget := target;
  if FWheelTimer = nil then
  begin
    FWheelTimer := TTimer.Create(Self);
    FWheelTimer.Interval := WHEEL_TICK_MS;
    FWheelTimer.OnTimer := @WheelTick;
  end;
  FWheelActive := True;
  FWheelTimer.Enabled := True;
end;

procedure TScrollTreeView.WheelTick(Sender: TObject);
var
  cur, dist, step: Integer;
begin
  cur := ScrolledTop;
  dist := FWheelTarget - cur;
  if dist = 0 then
  begin
    WheelStop;
    Exit;
  end;
  step := dist div 3;
  if step = 0 then
    if dist > 0 then step := 1 else step := -1;
  ScrolledTop := cur + step;
  if ScrolledTop = cur then
    WheelStop;   // cible inatteignable, l'arbre s'est replie sous nos pieds
end;

procedure TScrollTreeView.WheelScrollBy(AWheelDelta: Integer);
var
  px: Integer;
begin
  px := -((AWheelDelta * Mouse.WheelScrollLines * DefaultItemHeight) div 120);
  // macOS: AUCUNE correction de signe. Cocoa a deja applique le defilement naturel, et
  // le terminal fait pareil: sinon les deux moities de la fenetre defilent en sens contraire.
  AnimateScrollBy(px);
end;

// Aucun defilement horizontal: sans barre horizontale, rien ne ramenerait au bord gauche
// et la racine resterait tronquee. Sous macOS le trackpad passe par la molette
// horizontale ou, via l'hote de defilement de Cocoa, par LM_HSCROLL. On bouche les deux.
function TScrollTreeView.DoMouseWheelHorz(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  Result := True;
  if ScrolledLeft <> 0 then ScrolledLeft := 0;
end;

procedure TScrollTreeView.WMHScroll(var Msg: TLMScroll);
begin
  if ScrolledLeft <> 0 then ScrolledLeft := 0;
end;

function TScrollTreeView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  // Pas d'inherited: TCustomTreeView sauterait d'un bloc, sans animation.
  WheelScrollBy(WheelDelta);
  Result := True;
end;

function TScrollTreeView.ScrollViewportHeight: Integer;
begin
  Result := ViewportHeight;
end;

function TScrollTreeView.ScrollMaxTop: Integer;
begin
  Result := MaxScrollTop;
end;

function TScrollTreeView.ScrollGetTop: Integer;
begin
  Result := ScrollTop;
end;

procedure TScrollTreeView.ScrollSetTop(AValue: Integer);
begin
  ScrollTop := AValue;
end;

procedure TScrollTreeView.ScrollAnimateBy(ADelta: Integer);
begin
  AnimateScrollBy(ADelta);
end;

procedure TScrollTreeView.ScrollWheelBy(AWheelDelta: Integer);
begin
  WheelScrollBy(AWheelDelta);
end;

procedure TScrollTreeView.SetOnScrollViewChanged(AHandler: TNotifyEvent);
begin
  OnViewChanged := AHandler;
end;

procedure TScrollTreeView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  // La LCL repositionne au clavier sans passer par SetScrollTop: l'animation en cours
  // tirerait ailleurs.
  WheelStop;
  inherited KeyDown(Key, Shift);
end;

// La LCL ne connait que Ctrl+clic pour la selection multiple. Sous macOS c'est Cmd, et
// Ctrl+clic y vaut clic droit: on deguise Cmd en Ctrl avant de laisser faire.
procedure TScrollTreeView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  {$IFDEF DARWIN}
  if ssMeta in Shift then
    Shift := Shift + [ssCtrl];
  {$ENDIF}
  inherited MouseDown(Button, Shift, X, Y);
end;

function TScrollTreeView.MaxScrollTop: Integer;
begin
  Result := GetMaxScrollTop;
end;

function TScrollTreeView.ViewportHeight: Integer;
begin
  Result := GetNodeDrawAreaHeight;
end;

procedure TScrollTreeView.Paint;
begin
  inherited Paint;
  if Assigned(FOnViewChanged) then
    FOnViewChanged(Self);
end;

constructor TTreeScrollBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 12;
  DoubleBuffered := True;
  FTrough := clBtnFace;
  FThumb := clScrollBar;
  FThumbHover := clGrayText;
end;

procedure TTreeScrollBar.ApplyTheme(ATrough, AThumb, AThumbHover: TColor);
begin
  FTrough := ATrough;
  FThumb := AThumb;
  FThumbHover := AThumbHover;
  Color := ATrough;
  Invalidate;
end;

procedure TTreeScrollBar.Bind(ATarget: TControl);
var
  iface: IThemedScrollTarget;
begin
  if FTargetCtl = ATarget then Exit;
  if FTargetCtl <> nil then
  begin
    if FTarget <> nil then
      FTarget.SetOnScrollViewChanged(nil);
    FTargetCtl.RemoveFreeNotification(Self);
  end;
  FTarget := nil;
  FTargetCtl := nil;
  if (ATarget <> nil) and Supports(ATarget, IThemedScrollTarget, iface) then
  begin
    FTargetCtl := ATarget;
    FTarget := iface;
    FTargetCtl.FreeNotification(Self);
    FTarget.SetOnScrollViewChanged(@TreeViewChanged);
  end;
  Invalidate;
end;

procedure TTreeScrollBar.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FTargetCtl) then
  begin
    FTarget := nil;
    FTargetCtl := nil;
  end;
end;

procedure TTreeScrollBar.TreeViewChanged(Sender: TObject);
begin
  Invalidate;
end;

function TTreeScrollBar.ThumbMetrics(out AThumbH, ATrack: Integer): Boolean;
var
  viewport, maxScroll, content, h: Integer;
begin
  Result := False;
  AThumbH := 0;
  ATrack := 0;
  if FTarget = nil then Exit;
  viewport := FTarget.ScrollViewportHeight;
  maxScroll := FTarget.ScrollMaxTop;
  content := viewport + maxScroll;
  h := ClientHeight;
  if (maxScroll <= 0) or (content <= 0) or (h <= 0) then Exit;
  AThumbH := Round(viewport / content * h);
  if AThumbH < MIN_THUMB then AThumbH := MIN_THUMB;
  if AThumbH > h then AThumbH := h;
  ATrack := h - AThumbH;
  Result := True;
end;

function TTreeScrollBar.ThumbRect: TRect;
var
  thumbH, track, maxScroll, thumbTop: Integer;
begin
  Result := Rect(0, 0, 0, 0);
  if not ThumbMetrics(thumbH, track) then Exit;
  if FDragging then
    thumbTop := FDragThumbTop
  else
  begin
    maxScroll := FTarget.ScrollMaxTop;
    if maxScroll > 0 then
      thumbTop := Round(FTarget.ScrollGetTop / maxScroll * track)
    else
      thumbTop := 0;
  end;
  if thumbTop < 0 then thumbTop := 0;
  if thumbTop > track then thumbTop := track;
  Result := Rect(THUMB_INSET, thumbTop, ClientWidth - THUMB_INSET, thumbTop + thumbH);
end;

procedure TTreeScrollBar.ScrollToThumbTop(AThumbTop: Integer);
var
  thumbH, track: Integer;
  frac: Double;
begin
  if not ThumbMetrics(thumbH, track) then Exit;
  if track <= 0 then
    frac := 0
  else
    frac := AThumbTop / track;
  if frac < 0 then frac := 0;
  if frac > 1 then frac := 1;
  FTarget.ScrollSetTop(Round(frac * FTarget.ScrollMaxTop));
end;

procedure TTreeScrollBar.Paint;
var
  r: TRect;
  c: TColor;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FTrough;
  Canvas.FillRect(ClientRect);
  r := ThumbRect;
  if r.Bottom > r.Top then
  begin
    if FHover or FDragging then c := FThumbHover else c := FThumb;
    Canvas.Brush.Color := c;
    Canvas.Pen.Color := c;
    Canvas.RoundRect(r.Left, r.Top, r.Right, r.Bottom, THUMB_RADIUS, THUMB_RADIUS);
  end;
end;

procedure TTreeScrollBar.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  r: TRect;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or (FTarget = nil) then Exit;
  r := ThumbRect;
  if r.Bottom <= r.Top then Exit;
  if (Y >= r.Top) and (Y < r.Bottom) then
  begin
    FDragging := True;
    FDragOffset := Y - r.Top;
    FDragThumbTop := r.Top;
  end
  else if Y < r.Top then
    FTarget.ScrollAnimateBy(-FTarget.ScrollViewportHeight)
  else
    FTarget.ScrollAnimateBy(FTarget.ScrollViewportHeight);
end;

function TTreeScrollBar.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
  if (not Result) and (FTarget <> nil) then
  begin
    FTarget.ScrollWheelBy(WheelDelta);
    Result := True;
  end;
end;

procedure TTreeScrollBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  r: TRect;
  over: Boolean;
  newTop, thumbH, track: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FDragging then
  begin
    newTop := Y - FDragOffset;
    if ThumbMetrics(thumbH, track) then
    begin
      if newTop < 0 then newTop := 0;
      if newTop > track then newTop := track;
    end;
    FDragThumbTop := newTop;
    ScrollToThumbTop(newTop);
    // Update force: sous capture, le flot de WM_MOUSEMOVE affame les WM_PAINT differes et
    // le pouce reste fige pendant qu'on le tire.
    Invalidate;
    Update;
    if FTargetCtl <> nil then
      FTargetCtl.Update;
    Exit;
  end;
  r := ThumbRect;
  over := (r.Bottom > r.Top) and (Y >= r.Top) and (Y < r.Bottom);
  if over <> FHover then
  begin
    FHover := over;
    Invalidate;
  end;
end;

procedure TTreeScrollBar.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button = mbLeft then
  begin
    FDragging := False;
    Invalidate;
  end;
end;

procedure TTreeScrollBar.MouseLeave;
begin
  inherited MouseLeave;
  if FHover then
  begin
    FHover := False;
    Invalidate;
  end;
end;

end.
