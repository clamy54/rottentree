// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uRtCombo;

{$mode objfpc}{$H+}
{$IFDEF LCLCocoa}{$modeswitch objectivec1}{$ENDIF}

// Liste de choix dessinee aux couleurs du theme, facon TComboBox en lecture seule. La
// combo native de Windows impose son cadre et son bouton clairs, et un menu plus haut que
// l'ecran n'offrait que ses fleches natives: cinquante attributs pour inetOrgPerson, des
// centaines pour un compte AD. D'ou une liste maison qui defile et se filtre.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Graphics, Forms, LCLType, Types;

const
  DROP_MAX_ROWS = 20;
  DROP_FILTER_MIN = 16;

type
  TRtComboBox = class;

  TRtDropList = class(TForm)
  private
    FCombo: TRtComboBox;
    FFrame: TPanel;
    FFilter: TEdit;
    FList: TListBox;
    FMap: array of Integer;
    FRowObjs: array of TObject;
    FRowHeight: Integer;
    FDone: Boolean;
    procedure Refill;
    procedure FilterChange(Sender: TObject);
    procedure KeysDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ListMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure ListMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure ListDrawItem(Control: TWinControl; Index: Integer; ARect: TRect; State: TOwnerDrawState);
    procedure FormDeactivate(Sender: TObject);
    procedure Choose(ARow: Integer);
    procedure MoveBy(ADelta: Integer);
  public
    constructor CreateFor(ACombo: TRtComboBox);
    procedure Place;
    procedure CloseDrop;
    // Elements changes liste ouverte (suffixes UPN arrives en retard, par exemple): lignes et
    // index sont reconstruits, sinon un clic choisirait l'element qui squatte l'ancien index.
    // La ligne surlignee est retrouvee par son objet, ou par libelle et rang de doublon.
    procedure ItemsUpdated;
    procedure SetFilterText(const AText: string);
    procedure PressKey(AKey: Word);
    function VisibleCount: Integer;
    function VisibleItem(ARow: Integer): string;
    function HasFilter: Boolean;
    function SelectedRow: Integer;
    property RowHeight: Integer read FRowHeight;
  end;

  TRtComboBox = class(TCustomControl)
  private
    FItems: TStringList;
    FItemIndex: Integer;
    FOnChange: TNotifyEvent;
    FOnDropDown: TNotifyEvent;
    FDrop: TRtDropList;
    FDropClosedAt: QWord;
    FHot: Boolean;
    FStyle: TComboBoxStyle;
    procedure SetItemIndex(AValue: Integer);
    function GetItems: TStrings;
    function GetText: string;
    procedure ItemsChanged(Sender: TObject);
    procedure SelectIndex(AIndex: Integer);
    procedure DropClosed;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure DropDown;
    function PreferredHeight: Integer;
    property Items: TStrings read GetItems;
    property ItemIndex: Integer read FItemIndex write SetItemIndex;
    property Text: string read GetText;
    property DropList: TRtDropList read FDrop;
    property Style: TComboBoxStyle read FStyle write FStyle;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property OnDropDown: TNotifyEvent read FOnDropDown write FOnDropDown;
  end;

implementation

uses
  Math, LCLIntf, uTheme, uUiKit{$IFDEF LCLCocoa}, CocoaAll{$ENDIF};

{$IFDEF LCLCocoa}
// Cocoa: une session modale ne livre les clics qu'a la fenetre modale et a ses enfants,
// et PopupParent n'en fait pas une enfant tant que le handle n'existe pas. On rattache
// apres Show, comme la LCL le fait pour son propre calendrier.
procedure AttachToParentWindow(ADrop, AParent: TCustomForm);
begin
  if (AParent = nil) or not AParent.HandleAllocated or not ADrop.HandleAllocated then Exit;
  NSView(AParent.Handle).window.addChildWindow_ordered(NSView(ADrop.Handle).window,
    NSWindowAbove);
end;

procedure DetachFromParentWindow(ADrop: TCustomForm);
var
  win: NSWindow;
begin
  if not ADrop.HandleAllocated then Exit;
  win := NSView(ADrop.Handle).window;
  if Assigned(win.parentWindow) then win.parentWindow.removeChildWindow(win);
end;
{$ENDIF}

constructor TRtDropList.CreateFor(ACombo: TRtComboBox);
var
  pf: TCustomForm;
  box: TPanel;
begin
  inherited CreateNew(ACombo);
  FCombo := ACombo;
  BorderStyle := bsNone;
  ShowInTaskBar := stNever;
  pf := GetParentForm(ACombo);
  if pf <> nil then
  begin
    PopupMode := pmExplicit;
    PopupParent := pf;
  end;
  Font.Assign(ACombo.Font);
  KeyPreview := True;
  OnKeyDown := @KeysDown;
  OnDeactivate := @FormDeactivate;
  Color := clMenuSep;
  FFrame := TPanel.Create(Self);
  FFrame.Parent := Self;
  FFrame.Align := alClient;
  FFrame.BevelOuter := bvNone;
  FFrame.BorderSpacing.Around := 1;
  FFrame.ParentColor := False;
  FFrame.Color := clMenuPopupBg;
  FRowHeight := Max(FontTextHeight(Font) + 8, 20);
  if ACombo.Items.Count >= DROP_FILTER_MIN then
  begin
    // Champ plat aux couleurs de l'editeur: la bordure native reste claire en theme sombre.
    box := TPanel.Create(Self);
    box.Parent := FFrame;
    box.Align := alTop;
    box.BevelOuter := bvNone;
    box.BorderSpacing.Around := 4;
    box.Height := FontTextHeight(Font) + 10;
    box.ParentColor := False;
    box.Color := clEditorBg;
    FFilter := TEdit.Create(Self);
    FFilter.Parent := box;
    FFilter.Align := alClient;
    FFilter.BorderSpacing.Left := 6;
    FFilter.BorderSpacing.Top := 4;
    FFilter.BorderStyle := bsNone;
    FFilter.Color := clEditorBg;
    FFilter.Font.Assign(Font);
    FFilter.Font.Color := clEditorFg;
    FFilter.TextHint := 'Type to filter';
    FFilter.OnChange := @FilterChange;
  end;
  FList := TListBox.Create(Self);
  FList.Parent := FFrame;
  FList.Align := alClient;
  FList.BorderStyle := bsNone;
  FList.Style := lbOwnerDrawFixed;
  FList.ItemHeight := FRowHeight;
  FList.Color := clMenuPopupBg;
  FList.Font.Assign(Font);
  FList.OnDrawItem := @ListDrawItem;
  FList.OnMouseMove := @ListMouseMove;
  FList.OnMouseUp := @ListMouseUp;
  Refill;
end;

procedure TRtDropList.Refill;
var
  i, keep: Integer;
  f: string;
begin
  f := '';
  if FFilter <> nil then f := AnsiLowerCase(Trim(FFilter.Text));
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    SetLength(FMap, 0);
    SetLength(FRowObjs, 0);
    keep := -1;
    for i := 0 to FCombo.Items.Count - 1 do
      if (f = '') or (Pos(f, AnsiLowerCase(FCombo.Items[i])) > 0) then
      begin
        SetLength(FMap, Length(FMap) + 1);
        FMap[High(FMap)] := i;
        SetLength(FRowObjs, Length(FRowObjs) + 1);
        FRowObjs[High(FRowObjs)] := FCombo.Items.Objects[i];
        FList.Items.Add(FCombo.Items[i]);
        if i = FCombo.ItemIndex then keep := FList.Items.Count - 1;
      end;
  finally
    FList.Items.EndUpdate;
  end;
  if keep < 0 then keep := 0;
  if FList.Items.Count > 0 then FList.ItemIndex := keep;
end;

procedure TRtDropList.Place;
var
  pt: TPoint;
  wa: TRect;
  rows, want, h, w, below, above, i, tw, filterH: Integer;
  bmp: Graphics.TBitmap;
begin
  pt := FCombo.ClientToScreen(Point(0, 0));
  wa := Screen.MonitorFromPoint(pt).WorkareaRect;
  rows := EnsureRange(FCombo.Items.Count, 1, DROP_MAX_ROWS);
  filterH := 0;
  if FFilter <> nil then filterH := FontTextHeight(Font) + 18;
  want := rows * FRowHeight + filterH + 4;
  below := wa.Bottom - (pt.Y + FCombo.Height);
  above := pt.Y - wa.Top;
  tw := 0;
  bmp := Graphics.TBitmap.Create;
  try
    bmp.Canvas.Font.Assign(Font);
    for i := 0 to FCombo.Items.Count - 1 do
      tw := Max(tw, bmp.Canvas.TextWidth(FCombo.Items[i]));
  finally
    bmp.Free;
  end;
  w := Min(Max(FCombo.Width, tw + 28 + 16 + GetSystemMetrics(SM_CXVSCROLL)), wa.Right - wa.Left);
  if (want <= below) or (below >= above) then
  begin
    h := Min(want, below);
    SetBounds(EnsureRange(pt.X, wa.Left, wa.Right - w), pt.Y + FCombo.Height, w, h);
  end
  else
  begin
    h := Min(want, above);
    SetBounds(EnsureRange(pt.X, wa.Left, wa.Right - w), pt.Y - h, w, h);
  end;
end;

procedure TRtDropList.ListDrawItem(Control: TWinControl; Index: Integer; ARect: TRect;
  State: TOwnerDrawState);
var
  c: TCanvas;
  ty: Integer;
begin
  c := FList.Canvas;
  c.Font.Assign(Font);
  if odSelected in State then c.Brush.Color := clMenuHover else c.Brush.Color := clMenuPopupBg;
  c.FillRect(ARect);
  c.Brush.Style := bsClear;
  c.Font.Color := clMenuText;
  ty := ARect.Top + (ARect.Bottom - ARect.Top - c.TextHeight('Ag')) div 2;
  if (Index >= 0) and (Index <= High(FMap)) and (FMap[Index] = FCombo.ItemIndex) then
    c.TextOut(ARect.Left + 10, ty, #$E2#$80#$A2);
  if (Index >= 0) and (Index < FList.Items.Count) then
    c.TextRect(Classes.Rect(ARect.Left + 28, ARect.Top, ARect.Right - 4, ARect.Bottom), ARect.Left + 28, ty,
      FList.Items[Index]);
  c.Brush.Style := bsSolid;
end;

procedure TRtDropList.ListMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  i := FList.ItemAtPos(Point(X, Y), True);
  if (i >= 0) and (i <> FList.ItemIndex) then FList.ItemIndex := i;
end;

procedure TRtDropList.ListMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  if Button <> mbLeft then Exit;
  i := FList.ItemAtPos(Point(X, Y), True);
  if i >= 0 then Choose(i);
end;

procedure TRtDropList.MoveBy(ADelta: Integer);
begin
  if FList.Items.Count = 0 then Exit;
  FList.ItemIndex := EnsureRange(FList.ItemIndex + ADelta, 0, FList.Items.Count - 1);
end;

procedure TRtDropList.KeysDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  page: Integer;
begin
  page := Max(1, FList.ClientHeight div FRowHeight - 1);
  case Key of
    VK_ESCAPE:
      begin
        CloseDrop;
        Key := 0;
      end;
    VK_RETURN:
      begin
        Choose(FList.ItemIndex);
        Key := 0;
      end;
    VK_DOWN: begin MoveBy(1); Key := 0; end;
    VK_UP: begin MoveBy(-1); Key := 0; end;
    VK_NEXT: begin MoveBy(page); Key := 0; end;
    VK_PRIOR: begin MoveBy(-page); Key := 0; end;
    VK_HOME:
      if FFilter = nil then begin MoveBy(-FList.Items.Count); Key := 0; end;
    VK_END:
      if FFilter = nil then begin MoveBy(FList.Items.Count); Key := 0; end;
  end;
end;

procedure TRtDropList.FilterChange(Sender: TObject);
begin
  Refill;
end;

procedure TRtDropList.FormDeactivate(Sender: TObject);
begin
  CloseDrop;
end;

procedure TRtDropList.Choose(ARow: Integer);
var
  combo: TRtComboBox;
  idx: Integer;
begin
  if FDone or (ARow < 0) or (ARow > High(FMap)) then Exit;
  combo := FCombo;
  idx := FMap[ARow];
  CloseDrop;
  combo.SelectIndex(idx);
  if combo.CanFocus then combo.SetFocus;
end;

procedure TRtDropList.ItemsUpdated;
var
  sel: string;
  obj: TObject;
  occ, cnt, i, match: Integer;
begin
  if FDone then Exit;
  if FCombo.Items.Count = 0 then
  begin
    CloseDrop;
    Exit;
  end;
  sel := '';
  obj := nil;
  occ := 0;
  i := FList.ItemIndex;
  if (i >= 0) and (i < FList.Items.Count) then
  begin
    sel := FList.Items[i];
    if i <= High(FRowObjs) then obj := FRowObjs[i];
    for cnt := 0 to i - 1 do
      if FList.Items[cnt] = sel then Inc(occ);
  end;
  Refill;
  if sel <> '' then
  begin
    match := -1;
    if obj <> nil then
    begin
      for i := 0 to High(FRowObjs) do
        if FRowObjs[i] = obj then
          if match < 0 then match := i
          else
          begin
            match := -1;
            Break;
          end;
    end
    else
    begin
      cnt := 0;
      for i := 0 to FList.Items.Count - 1 do
        if FList.Items[i] = sel then
        begin
          if cnt = occ then
          begin
            match := i;
            Break;
          end;
          Inc(cnt);
        end;
    end;
    if match >= 0 then FList.ItemIndex := match;
  end;
  Place;
end;

procedure TRtDropList.CloseDrop;
begin
  if FDone then Exit;
  FDone := True;
  FCombo.DropClosed;
  {$IFDEF LCLCocoa}
  DetachFromParentWindow(Self);
  {$ENDIF}
  Hide;
  // Release, pas Free: on est encore dans nos propres gestionnaires d'evenements.
  Release;
end;

procedure TRtDropList.SetFilterText(const AText: string);
begin
  if FFilter = nil then Exit;
  FFilter.Text := AText;
  Refill;
end;

procedure TRtDropList.PressKey(AKey: Word);
var
  k: Word;
begin
  k := AKey;
  KeysDown(Self, k, []);
end;

function TRtDropList.VisibleCount: Integer;
begin
  Result := FList.Items.Count;
end;

function TRtDropList.VisibleItem(ARow: Integer): string;
begin
  Result := FList.Items[ARow];
end;

function TRtDropList.HasFilter: Boolean;
begin
  Result := FFilter <> nil;
end;

function TRtDropList.SelectedRow: Integer;
begin
  Result := FList.ItemIndex;
end;

constructor TRtComboBox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FItems := TStringList.Create;
  FItems.OnChange := @ItemsChanged;
  FItemIndex := -1;
  FStyle := csDropDownList;
  TabStop := True;
  Width := 120;
  Height := 26;
  ControlStyle := ControlStyle + [csOpaque];
end;

destructor TRtComboBox.Destroy;
begin
  if FDrop <> nil then
  begin
    FDrop.FDone := True;
    FDrop := nil;
  end;
  FItems.Free;
  inherited Destroy;
end;

function TRtComboBox.GetItems: TStrings;
begin
  Result := FItems;
end;

procedure TRtComboBox.ItemsChanged(Sender: TObject);
begin
  if FItemIndex >= FItems.Count then
    FItemIndex := -1;
  if FDrop <> nil then FDrop.ItemsUpdated;
  Invalidate;
end;

function TRtComboBox.GetText: string;
begin
  if (FItemIndex >= 0) and (FItemIndex < FItems.Count) then
    Result := FItems[FItemIndex]
  else
    Result := '';
end;

procedure TRtComboBox.SetItemIndex(AValue: Integer);
begin
  if (AValue < -1) or (AValue >= FItems.Count) then
    AValue := -1;
  if AValue = FItemIndex then Exit;
  FItemIndex := AValue;
  Invalidate;
end;

procedure TRtComboBox.SelectIndex(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FItems.Count) or (AIndex = FItemIndex) then Exit;
  FItemIndex := AIndex;
  Invalidate;
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TRtComboBox.PreferredHeight: Integer;
var
  bmp: Graphics.TBitmap;
begin
  bmp := Graphics.TBitmap.Create;
  try
    bmp.Canvas.Font.Assign(Font);
    Result := bmp.Canvas.TextHeight('Ag') + 10;
  finally
    bmp.Free;
  end;
end;

procedure TRtComboBox.Paint;
var
  r: TRect;
  cx, cy, ty: Integer;
  bg: TColor;
begin
  Canvas.Brush.Style := bsSolid;
  if Parent <> nil then
    Canvas.Brush.Color := Parent.Brush.Color
  else
    Canvas.Brush.Color := clAppBg;
  Canvas.FillRect(ClientRect);
  r := ClientRect;
  bg := clEditorBg;
  if FHot and Enabled then
    bg := BlendColor(clEditorBg, clAppFg, 92);
  Canvas.Brush.Color := bg;
  if Focused or (FDrop <> nil) then
    Canvas.Pen.Color := clAccent
  else
    Canvas.Pen.Color := BlendColor(clAppFg, clAppBg, 35);
  Canvas.Pen.Width := 1;
  Canvas.RoundRect(r.Left, r.Top, r.Right, r.Bottom, 6, 6);
  Canvas.Font.Assign(Font);
  if Enabled then
    Canvas.Font.Color := clEditorFg
  else
    Canvas.Font.Color := BlendColor(clEditorFg, clEditorBg, 45);
  Canvas.Brush.Style := bsClear;
  ty := (ClientHeight - Canvas.TextHeight('Ag')) div 2;
  Canvas.TextRect(Classes.Rect(r.Left + 8, r.Top, r.Right - 22, r.Bottom), r.Left + 8, ty, GetText);
  cx := r.Right - 12;
  cy := ClientHeight div 2;
  Canvas.Pen.Color := Canvas.Font.Color;
  Canvas.Pen.Width := 2;
  Canvas.Line(cx - 4, cy - 2, cx, cy + 2);
  Canvas.Line(cx, cy + 2, cx + 4, cy - 2);
  Canvas.Pen.Width := 1;
end;

procedure TRtComboBox.DropDown;
begin
  if not Enabled or (FDrop <> nil) then Exit;
  // Le clic qui ferme la liste par perte de focus arrive ensuite ici: sans ce delai, il
  // la rouvrirait aussitot.
  if (FDropClosedAt <> 0) and (GetTickCount64 - FDropClosedAt < 250) then Exit;
  if Assigned(FOnDropDown) then FOnDropDown(Self);
  if FItems.Count = 0 then Exit;
  FDrop := TRtDropList.CreateFor(Self);
  FDrop.Place;
  FDrop.Show;
  {$IFDEF LCLCocoa}
  AttachToParentWindow(FDrop, GetParentForm(Self));
  // La TListBox de Cocoa perd la selection posee avant la creation du handle: on la repose
  // une fois la liste affichee.
  FDrop.Refill;
  {$ENDIF}
  {$IFDEF WINDOWS}
  ApplyNativeDarkMode(FDrop.FList);
  {$ENDIF}
  if FDrop.FFilter <> nil then FDrop.FFilter.SetFocus else FDrop.FList.SetFocus;
  Invalidate;
end;

procedure TRtComboBox.DropClosed;
begin
  FDrop := nil;
  FDropClosedAt := GetTickCount64;
  Invalidate;
end;

procedure TRtComboBox.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus then SetFocus;
  if Button = mbLeft then DropDown;
end;

procedure TRtComboBox.MouseEnter;
begin
  inherited MouseEnter;
  FHot := True;
  Invalidate;
end;

procedure TRtComboBox.MouseLeave;
begin
  inherited MouseLeave;
  FHot := False;
  Invalidate;
end;

procedure TRtComboBox.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_UP:
      begin
        SelectIndex(FItemIndex - 1);
        Key := 0;
      end;
    VK_DOWN:
      begin
        if ssAlt in Shift then DropDown else SelectIndex(FItemIndex + 1);
        Key := 0;
      end;
    VK_SPACE, VK_F4:
      begin
        DropDown;
        Key := 0;
      end;
  end;
end;

procedure TRtComboBox.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TRtComboBox.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

end.
