// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTabBar;

{$mode objfpc}{$H+}

// Barre d'onglets dessinee a la main, qui pilote un TPageControl aux onglets natifs
// masques. Elle ignore tout des sessions: on lui parle par evenements, comme a un
// collegue d'un autre service.

interface

uses
  Classes, SysUtils, Types, Controls, Graphics, ComCtrls, ExtCtrls, Forms,
  LCLType, uTheme;

type
  TTabGlyphKind = (tgkNone, tgkBusy, tgkConnected, tgkFailed, tgkDead);

  TTabInfoEvent = procedure(APage: TTabSheet; out AName: string;
    out AGlyph: TTabGlyphKind) of object;
  TTabActionEvent = procedure(APage: TTabSheet) of object;
  TTabThumbEvent = function(APage: TTabSheet): TBitmap of object;

  TTabSlot = record
    Page: TTabSheet;
    Full: TRect;
    Marker: TRect;
  end;

  TSessionTabBar = class(TCustomControl)
  private
    FPages: TPageControl;
    FSlots: array of TTabSlot;
    FScroll: Integer;
    FHoverTab: Integer;
    FHoverClose: Integer;
    FLeftArrow, FRightArrow: TRect;
    FShowArrows: Boolean;
    FTabsLeft, FTabsRight: Integer;
    FContentW: Integer;
    FOnInfo: TTabInfoEvent;
    FOnActivate: TTabActionEvent;
    FOnClose: TTabActionEvent;
    FOnThumb: TTabThumbEvent;
    FDwellTimer: TTimer;
    FThumb: TObject;
    FThumbPage: TTabSheet;
    FHoverPage: TTabSheet;
    FPressedPage: TTabSheet;
    FDragging: Boolean;
    FDragStartX: Integer;
    FDragCurX: Integer;
    FDragGrabOffset: Integer;
    function DragOverPage(X: Integer): TTabSheet;
    procedure DragTo(X: Integer);
    procedure DwellFired(Sender: TObject);
    procedure ShowThumbFor(APage: TTabSheet);
    procedure HideThumb;
    procedure BuildLayout;
    procedure ClampScroll;
    procedure EnsureVisible(APage: TTabSheet);
    procedure DrawTab(ASlot: Integer; AOffsetX: Integer = 0;
      AFloating: Boolean = False);
    procedure DrawGlyphClose(const R: TRect; AColor: TColor);
    procedure DrawGlyphArrow(const R: TRect; ALeft: Boolean; AColor: TColor);
    procedure DrawStateGlyph(const R: TRect; AKind: TTabGlyphKind);
    function InfoFor(APage: TTabSheet; out AGlyph: TTabGlyphKind): string;
    function TabAt(X: Integer; out AClose: Boolean): Integer;
    procedure Track(APage: TTabSheet);
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Attach(APages: TPageControl);
    procedure RefreshBar;
    procedure RefreshTheme;
    procedure CancelGesture;
    property OnInfo: TTabInfoEvent read FOnInfo write FOnInfo;
    property OnActivateTab: TTabActionEvent read FOnActivate write FOnActivate;
    property OnCloseTab: TTabActionEvent read FOnClose write FOnClose;
    property OnThumb: TTabThumbEvent read FOnThumb write FOnThumb;
  end;

implementation

const
  TAB_MAXW  = 220;
  TAB_MINW  = 90;
  PADX      = 11;
  LPAD      = 9;
  MARK_SZ   = 16;
  MARK_GAP  = 7;
  ARROW_W   = 24;
  DOT_D     = 9;
  DWELL_MS  = 850;
  THUMB_MAXW = 260;
  THUMB_MAXH = 172;
  THUMB_PAD = 4;
  DRAG_THRESH = 6;

type
  // THintWindow ne vole pas le focus, mais son Paint ignore OnPaint: on peint nous-memes.
  TThumbHint = class(THintWindow)
  private
    FBmp: TBitmap;
  protected
    procedure Paint; override;
  public
    destructor Destroy; override;
    procedure SetImage(ABmp: TBitmap);
  end;

destructor TThumbHint.Destroy;
begin
  FreeAndNil(FBmp);
  inherited Destroy;
end;

procedure TThumbHint.SetImage(ABmp: TBitmap);
begin
  if ABmp = FBmp then Exit;
  FreeAndNil(FBmp);
  FBmp := ABmp;
  // Fenetre remontree aux memes dimensions: pas de repeint, et l'ancienne image reste.
  if HandleAllocated then
    Invalidate;
end;

procedure TThumbHint.Paint;
var
  r, inner: TRect;
begin
  r := ClientRect;
  Canvas.Brush.Color := clTabStrip;
  Canvas.FillRect(r);
  Canvas.Pen.Color := clBorder;
  Canvas.Brush.Style := bsClear;
  Canvas.Rectangle(r);
  Canvas.Brush.Style := bsSolid;
  if FBmp = nil then Exit;
  inner := Rect(r.Left + THUMB_PAD, r.Top + THUMB_PAD,
    r.Right - THUMB_PAD, r.Bottom - THUMB_PAD);
  Canvas.StretchDraw(inner, FBmp);
end;

constructor TSessionTabBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FHoverTab := -1;
  FHoverClose := -1;
  FScroll := 0;
  if RSUiFontName <> '' then Font.Name := RSUiFontName;
  if RSUiFontSize > 0 then Font.Size := RSUiFontSize;
  FDwellTimer := TTimer.Create(Self);
  FDwellTimer.Enabled := False;
  FDwellTimer.Interval := DWELL_MS;
  FDwellTimer.OnTimer := @DwellFired;
end;

destructor TSessionTabBar.Destroy;
begin
  HideThumb;
  FreeAndNil(FThumb);
  inherited Destroy;
end;

procedure TSessionTabBar.Attach(APages: TPageControl);
begin
  FPages := APages;
end;

procedure TSessionTabBar.Track(APage: TTabSheet);
begin
  if APage <> nil then APage.FreeNotification(Self);
end;

// Une page detruite pendant un geste (verrouillage, fermeture par un autre chemin) ne
// reste jamais referencee: appui, survol et miniature sont oublies avant qu'un
// relachement ne transmette un pointeur vers une page qui n'existe plus.
procedure TSessionTabBar.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if Operation <> opRemove then Exit;
  if AComponent = FPressedPage then CancelGesture;
  if AComponent = FHoverPage then
  begin
    FDwellTimer.Enabled := False;
    FHoverPage := nil;
  end;
  if AComponent = FThumbPage then HideThumb;
end;

procedure TSessionTabBar.CancelGesture;
var
  was: Boolean;
begin
  was := FPressedPage <> nil;
  FPressedPage := nil;
  FDragging := False;
  HideThumb;
  FHoverPage := nil;
  if was and MouseCapture then MouseCapture := False;
  if was then Invalidate;
end;

procedure TSessionTabBar.RefreshBar;
begin
  HideThumb;
  if FPages <> nil then
    EnsureVisible(FPages.ActivePage);
  Invalidate;
end;

procedure TSessionTabBar.RefreshTheme;
begin
  if RSUiFontName <> '' then Font.Name := RSUiFontName;
  if RSUiFontSize > 0 then Font.Size := RSUiFontSize;
  Invalidate;
end;

function TSessionTabBar.InfoFor(APage: TTabSheet; out AGlyph: TTabGlyphKind): string;
begin
  AGlyph := tgkNone;
  Result := '';
  if Assigned(FOnInfo) then
    FOnInfo(APage, Result, AGlyph);
  if Result = '' then
    Result := APage.Caption;
end;

procedure TSessionTabBar.ClampScroll;
var
  maxScroll: Integer;
begin
  maxScroll := FContentW - (FTabsRight - FTabsLeft);
  if maxScroll < 0 then maxScroll := 0;
  if FScroll > maxScroll then FScroll := maxScroll;
  if FScroll < 0 then FScroll := 0;
end;

procedure TSessionTabBar.BuildLayout;

  function TabW(const ACap: string): Integer;
  begin
    Result := LPAD + MARK_SZ + MARK_GAP + Canvas.TextWidth(ACap) + PADX;
    if Result > TAB_MAXW then Result := TAB_MAXW;
    if Result < TAB_MINW then Result := TAB_MINW;
  end;

var
  i, x, tw, n: Integer;
  glyph: TTabGlyphKind;
begin
  SetLength(FSlots, 0);
  if FPages = nil then Exit;
  Canvas.Font := Font;

  n := FPages.PageCount;
  FContentW := 0;
  for i := 0 to n - 1 do
    Inc(FContentW, TabW(InfoFor(FPages.Pages[i], glyph)));

  FTabsLeft := 0;
  FTabsRight := ClientWidth;
  FShowArrows := FContentW > (FTabsRight - FTabsLeft);
  if FShowArrows then
  begin
    FLeftArrow := Rect(0, 0, ARROW_W, ClientHeight);
    FRightArrow := Rect(ARROW_W, 0, ARROW_W * 2, ClientHeight);
    FTabsLeft := ARROW_W * 2;
  end;

  ClampScroll;

  SetLength(FSlots, n);
  x := FTabsLeft - FScroll;
  for i := 0 to n - 1 do
  begin
    tw := TabW(InfoFor(FPages.Pages[i], glyph));
    FSlots[i].Page := FPages.Pages[i];
    FSlots[i].Full := Rect(x, 0, x + tw, ClientHeight);
    FSlots[i].Marker := Rect(x + LPAD, (ClientHeight - MARK_SZ) div 2,
      x + LPAD + MARK_SZ, (ClientHeight - MARK_SZ) div 2 + MARK_SZ);
    Inc(x, tw);
  end;
end;

procedure TSessionTabBar.EnsureVisible(APage: TTabSheet);
var
  s, i, slotLeft, slotRight, viewW: Integer;
begin
  BuildLayout;
  s := -1;
  for i := 0 to High(FSlots) do
    if FSlots[i].Page = APage then
    begin
      s := i;
      Break;
    end;
  if s < 0 then Exit;
  viewW := FTabsRight - FTabsLeft;
  slotLeft := FSlots[s].Full.Left - (FTabsLeft - FScroll);
  slotRight := FSlots[s].Full.Right - (FTabsLeft - FScroll);
  if slotLeft < FScroll then
    FScroll := slotLeft
  else if slotRight > FScroll + viewW then
    FScroll := slotRight - viewW;
  ClampScroll;
end;

procedure TSessionTabBar.DrawGlyphClose(const R: TRect; AColor: TColor);
var
  m: Integer;
begin
  Canvas.Pen.Color := AColor;
  Canvas.Pen.Width := 1;
  m := 4;
  Canvas.Line(R.Left + m, R.Top + m, R.Right - m, R.Bottom - m);
  Canvas.Line(R.Right - m, R.Top + m, R.Left + m, R.Bottom - m);
end;

procedure TSessionTabBar.DrawGlyphArrow(const R: TRect; ALeft: Boolean; AColor: TColor);
var
  cx, cy, s: Integer;
begin
  cx := (R.Left + R.Right) div 2;
  cy := (R.Top + R.Bottom) div 2;
  s := 4;
  Canvas.Brush.Color := AColor;
  Canvas.Pen.Color := AColor;
  if ALeft then
    Canvas.Polygon([Point(cx + s, cy - s), Point(cx - s, cy), Point(cx + s, cy + s)])
  else
    Canvas.Polygon([Point(cx - s, cy - s), Point(cx + s, cy), Point(cx - s, cy + s)]);
end;

procedure TSessionTabBar.DrawStateGlyph(const R: TRect; AKind: TTabGlyphKind);
var
  cx, cy, rr: Integer;
begin
  cx := (R.Left + R.Right) div 2;
  cy := (R.Top + R.Bottom) div 2;
  rr := DOT_D div 2;
  case AKind of
    tgkConnected:
      begin
        Canvas.Brush.Color := clTabIcon;
        Canvas.Pen.Color := clTabIcon;
        Canvas.Ellipse(cx - rr, cy - rr, cx + rr + 1, cy + rr + 1);
      end;
    tgkBusy:
      begin
        Canvas.Brush.Style := bsClear;
        Canvas.Pen.Color := clTabInactiveText;
        Canvas.Pen.Width := 1;
        Canvas.Ellipse(cx - rr, cy - rr, cx + rr + 1, cy + rr + 1);
        Canvas.Brush.Style := bsSolid;
      end;
    tgkFailed:
      DrawGlyphClose(R, clAccent);
    tgkDead:
      begin
        Canvas.Brush.Color := clTabDead;
        Canvas.Pen.Color := clTabDead;
        Canvas.Ellipse(cx - rr, cy - rr, cx + rr + 1, cy + rr + 1);
      end;
  end;
end;

procedure TSessionTabBar.DrawTab(ASlot: Integer; AOffsetX: Integer;
  AFloating: Boolean);
var
  r, mk: TRect;
  active, hovered: Boolean;
  capName, cap: string;
  glyph: TTabGlyphKind;
  bg: TColor;
  ty, availW, textX: Integer;
begin
  r := FSlots[ASlot].Full;
  mk := FSlots[ASlot].Marker;
  if AOffsetX <> 0 then
  begin
    OffsetRect(r, AOffsetX, 0);
    OffsetRect(mk, AOffsetX, 0);
  end;
  active := (FSlots[ASlot].Page = FPages.ActivePage) or AFloating;
  hovered := (not AFloating) and (ASlot = FHoverTab);
  capName := InfoFor(FSlots[ASlot].Page, glyph);

  if active then bg := clTabActive
  else if hovered then bg := clTabHover
  else bg := clTabInactive;
  Canvas.Brush.Color := bg;
  Canvas.Pen.Color := bg;
  Canvas.RoundRect(r.Left, r.Top, r.Right, ClientHeight + 8, 7, 7);

  if active or hovered then
    Canvas.Font.Color := clTabActiveText
  else
    Canvas.Font.Color := clTabInactiveText;
  Canvas.Brush.Style := bsClear;
  cap := capName;
  textX := r.Left + LPAD + MARK_SZ + MARK_GAP;
  availW := (r.Right - PADX) - textX;
  while (Canvas.TextWidth(cap) > availW) and (Length(cap) > 1) do
    cap := Copy(cap, 1, Length(cap) - 1);
  if cap <> capName then
    cap := Copy(cap, 1, Length(cap) - 1) + '…';
  ty := (ClientHeight - Canvas.TextHeight('Ag')) div 2;
  Canvas.TextOut(textX, ty, cap);
  Canvas.Brush.Style := bsSolid;

  if hovered then
  begin
    if ASlot = FHoverClose then
      DrawGlyphClose(mk, clTabIconHi)
    else
      DrawGlyphClose(mk, clTabIcon);
  end
  else
    DrawStateGlyph(mk, glyph);
end;

procedure TSessionTabBar.HideThumb;
begin
  FDwellTimer.Enabled := False;
  FThumbPage := nil;
  if FThumb <> nil then
    TThumbHint(FThumb).Visible := False;
end;

procedure TSessionTabBar.ShowThumbFor(APage: TTabSheet);
var
  bmp: TBitmap;
  slot, i, anchorX: Integer;
  iw, ih, cw, ch: Integer;
  scale: Double;
  p: TPoint;
begin
  if not Assigned(FOnThumb) or (APage = nil) then Exit;
  if (FPages = nil) or (APage = FPages.ActivePage) then Exit;

  // Par PAGE et pas par index: les onglets bougent pendant le delai de survol.
  slot := -1;
  for i := 0 to High(FSlots) do
    if FSlots[i].Page = APage then
    begin
      slot := i;
      Break;
    end;
  if slot < 0 then Exit;

  bmp := FOnThumb(APage);
  if bmp = nil then Exit;
  if (bmp.Width <= 0) or (bmp.Height <= 0) then
  begin
    bmp.Free;
    Exit;
  end;

  iw := THUMB_MAXW - 2 * THUMB_PAD;
  ih := THUMB_MAXH - 2 * THUMB_PAD;
  scale := iw / bmp.Width;
  if (bmp.Height * scale) > ih then
    scale := ih / bmp.Height;
  if scale > 1 then scale := 1;
  cw := Round(bmp.Width * scale) + 2 * THUMB_PAD;
  ch := Round(bmp.Height * scale) + 2 * THUMB_PAD;

  if FThumb = nil then
    FThumb := TThumbHint.Create(Self);
  TThumbHint(FThumb).SetImage(bmp);
  FThumbPage := APage;
  Track(APage);

  anchorX := FSlots[slot].Full.Left;
  if anchorX < FTabsLeft then anchorX := FTabsLeft;
  p := ClientToScreen(Point(anchorX, ClientHeight + 1));
  // ActivateHint ne fait rien au meme rect (anti-scintillement LCL): d'ou le cache/montre.
  TThumbHint(FThumb).Visible := False;
  TThumbHint(FThumb).ActivateHint(Rect(p.X, p.Y, p.X + cw, p.Y + ch), '');
  TThumbHint(FThumb).Invalidate;
end;

procedure TSessionTabBar.DwellFired(Sender: TObject);
begin
  FDwellTimer.Enabled := False;
  ShowThumbFor(FHoverPage);
end;

procedure TSessionTabBar.Paint;
var
  i, dragSlot, floatLeft, off, tw: Integer;
begin
  BuildLayout;

  Canvas.Brush.Color := clTabStrip;
  Canvas.FillRect(ClientRect);

  dragSlot := -1;
  if FDragging and (FPressedPage <> nil) then
    for i := 0 to High(FSlots) do
      if FSlots[i].Page = FPressedPage then begin dragSlot := i; Break; end;

  for i := 0 to High(FSlots) do
    if (i <> dragSlot) and
       (FSlots[i].Full.Right > FTabsLeft) and (FSlots[i].Full.Left < FTabsRight) then
      DrawTab(i);

  if dragSlot >= 0 then
  begin
    tw := FSlots[dragSlot].Full.Right - FSlots[dragSlot].Full.Left;
    floatLeft := FDragCurX - FDragGrabOffset;
    if floatLeft < FTabsLeft then floatLeft := FTabsLeft;
    if floatLeft + tw > FTabsRight then floatLeft := FTabsRight - tw;
    off := floatLeft - FSlots[dragSlot].Full.Left;
    DrawTab(dragSlot, off, True);
  end;

  if FShowArrows then
  begin
    Canvas.Brush.Color := clTabStrip;
    Canvas.FillRect(Rect(0, 0, FTabsLeft, ClientHeight));
    DrawGlyphArrow(FLeftArrow, True, clTabInactiveText);
    DrawGlyphArrow(FRightArrow, False, clTabInactiveText);
    Canvas.Pen.Color := clBorder;
    Canvas.Line(FTabsLeft - 1, 4, FTabsLeft - 1, ClientHeight - 4);
  end;

  Canvas.Pen.Color := clBorder;
  Canvas.Line(0, ClientHeight - 1, ClientWidth, ClientHeight - 1);
end;

function TSessionTabBar.TabAt(X: Integer; out AClose: Boolean): Integer;
var
  i: Integer;
begin
  AClose := False;
  Result := -1;
  for i := 0 to High(FSlots) do
    if (X >= FSlots[i].Full.Left) and (X < FSlots[i].Full.Right)
       and (X >= FTabsLeft) and (X < FTabsRight) then
    begin
      Result := i;
      AClose := (X >= FSlots[i].Marker.Left) and (X < FSlots[i].Marker.Right);
      Exit;
    end;
end;

procedure TSessionTabBar.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  idx: Integer;
  onClose: Boolean;
  pg: TTabSheet;
begin
  inherited MouseDown(Button, Shift, X, Y);
  HideThumb;
  if FPages = nil then Exit;

  if FShowArrows and PtInRect(FLeftArrow, Point(X, Y)) then
  begin
    Dec(FScroll, 120); ClampScroll; Invalidate; Exit;
  end;
  if FShowArrows and PtInRect(FRightArrow, Point(X, Y)) then
  begin
    Inc(FScroll, 120); ClampScroll; Invalidate; Exit;
  end;

  idx := TabAt(X, onClose);
  if idx < 0 then Exit;
  pg := FSlots[idx].Page;

  if Button = mbLeft then
  begin
    if onClose and (idx = FHoverTab) then
    begin
      if Assigned(FOnClose) then FOnClose(pg);
    end
    else
    begin
      // Activer ICI couperait le suivi souris sous Cocoa: on arme seulement.
      FPressedPage := pg;
      Track(pg);
      FDragStartX := X;
      FDragCurX := X;
      FDragGrabOffset := X - FSlots[idx].Full.Left;
      FDragging := False;
      MouseCapture := True;
    end;
  end
  else if Button = mbMiddle then
    if Assigned(FOnClose) then FOnClose(pg);
end;

function TSessionTabBar.DragOverPage(X: Integer): TTabSheet;
var
  i, cx: Integer;
begin
  Result := nil;
  for i := 0 to High(FSlots) do
  begin
    cx := (FSlots[i].Full.Left + FSlots[i].Full.Right) div 2;
    if X < cx then
      Exit(FSlots[i].Page);
  end;
  if Length(FSlots) > 0 then
    Result := FSlots[High(FSlots)].Page;
end;

procedure TSessionTabBar.DragTo(X: Integer);
var
  over: TTabSheet;
begin
  if (FPages = nil) or (FPressedPage = nil) then Exit;
  // Comparaison de pointeur seulement: rien n'est lu d'une page peut-etre deja liberee.
  if FPages.IndexOf(FPressedPage) < 0 then
  begin
    CancelGesture;
    Exit;
  end;
  over := DragOverPage(X);
  if (over = nil) or (over = FPressedPage) then Exit;
  FPressedPage.PageIndex := over.PageIndex;
  if FPages.ActivePage <> FPressedPage then
    FPages.ActivePage := FPressedPage;
  BuildLayout;
  Invalidate;
end;

procedure TSessionTabBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  idx, oldTab, oldClose: Integer;
  onClose: Boolean;
begin
  inherited MouseMove(Shift, X, Y);

  // Bouton relache hors de la barre (capture perdue, dialogue modal): aucun relachement ne
  // viendra, le geste est abandonne.
  if (FPressedPage <> nil) and not (ssLeft in Shift) then CancelGesture;
  if FPressedPage <> nil then
  begin
    FDragCurX := X;
    if (not FDragging) and (Abs(X - FDragStartX) > DRAG_THRESH) then
    begin
      FDragging := True;
      HideThumb;
      if Assigned(FOnActivate) then FOnActivate(FPressedPage);
    end;
    if FDragging then
    begin
      DragTo(X);
      Invalidate;
      Exit;
    end;
  end;

  oldTab := FHoverTab;
  oldClose := FHoverClose;
  idx := TabAt(X, onClose);
  FHoverTab := idx;
  if onClose then FHoverClose := idx else FHoverClose := -1;
  if (oldTab <> FHoverTab) or (oldClose <> FHoverClose) then
    Invalidate;

  if oldTab <> FHoverTab then
  begin
    HideThumb;
    if (FHoverTab >= 0) and (FHoverTab <= High(FSlots)) then
      FHoverPage := FSlots[FHoverTab].Page
    else
      FHoverPage := nil;
    Track(FHoverPage);
    if (FHoverPage <> nil) and (FPages <> nil) and
       (FHoverPage <> FPages.ActivePage) then
      FDwellTimer.Enabled := True;
  end;
end;

procedure TSessionTabBar.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  pg: TTabSheet;
  dragged: Boolean;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbLeft) and (FPressedPage <> nil) then
  begin
    // Geste clos AVANT le rappel: il peut fermer ou detruire des pages sous nos pieds.
    pg := FPressedPage;
    dragged := FDragging;
    FPressedPage := nil;
    FDragging := False;
    MouseCapture := False;
    if (not dragged) and Assigned(FOnActivate) and (FPages <> nil) and
       (FPages.IndexOf(pg) >= 0) then
      FOnActivate(pg);
  end;
end;

procedure TSessionTabBar.MouseLeave;
begin
  inherited MouseLeave;
  HideThumb;
  FHoverPage := nil;
  if (FHoverTab <> -1) or (FHoverClose <> -1) then
  begin
    FHoverTab := -1;
    FHoverClose := -1;
    Invalidate;
  end;
end;

function TSessionTabBar.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  Result := True;
  HideThumb;
  if not FShowArrows then Exit;
  if WheelDelta > 0 then Dec(FScroll, 60) else Inc(FScroll, 60);
  ClampScroll;
  Invalidate;
end;

end.
