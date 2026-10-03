// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uRtList;

{$mode objfpc}{$H+}

// Liste en colonnes dessinee aux couleurs du theme: l'en-tete du TListView natif de
// Windows reste clair, meme a minuit. Mode virtuel pour les dizaines de milliers de
// resultats, tri a l'affichage seulement: les indices exposes restent ceux des donnees.

interface

uses
  Classes, SysUtils, Controls, Grids, Graphics, LCLType;

type
  TRtGetCellEvent = function(Sender: TObject; AIndex, ACol: Integer): string of object;
  TRtSelectEvent = procedure(Sender: TObject; AIndex: Integer) of object;
  TRtGetCellIconEvent = function(Sender: TObject; AIndex, ACol: Integer;
    out AColor: TColor): string of object;

  TRtListGrid = class(TDrawGrid)
  private
    FCaptions: TStringList;
    FRows: TList;
    FCount: Integer;
    FOnGetCell: TRtGetCellEvent;
    FOnSelectRow: TRtSelectEvent;
    FLastSelected: Integer;
    FWeights: array of Integer;
    FFillWidth: Boolean;
    FFitting: Boolean;
    FOnActivateRow: TRtSelectEvent;
    FOnGetCellIcon: TRtGetCellIconEvent;
    FSortable: Boolean;
    FSortCol: Integer;
    FSortDesc: Boolean;
    FOrder: array of Integer;
    FPlace: array of Integer;
    FShowHeader: Boolean;
    FStretchLast: Boolean;
    FRowColor: TColor;
    FRowTextColor: TColor;
    function DataIndex(ADisplay: Integer): Integer;
    function DisplayIndex(AData: Integer): Integer;
    procedure ApplySort;
    procedure SetCount(AValue: Integer);
    procedure SetFillWidth(AValue: Boolean);
    procedure FitColumns;
    function GetItemIndex: Integer;
    procedure SetItemIndex(AValue: Integer);
    procedure ClearRows;
    procedure SetShowHeader(AValue: Boolean);
    procedure SetStretchLast(AValue: Boolean);
    procedure ApplyHeaderHeight;
  protected
    procedure DrawCell(ACol, ARow: Longint; ARect: TRect; AState: TGridDrawState); override;
    procedure SelectionChanged; virtual;
    procedure AfterMoveSelection(const aPrevCol, aPrevRow: Integer); override;
    procedure DoOnResize; override;
    procedure HeaderSized(IsColumn: Boolean; Index: Integer); override;
    procedure DblClick; override;
    procedure Click; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure HeaderClick(IsColumn: Boolean; index: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ClearColumns;
    procedure AddColumn(const ACaption: string; AWidth: Integer);
    procedure Clear;
    function AddRow(const AValues: array of string): Integer;
    function CellText(AIndex, ACol: Integer): string;
    procedure RefreshMetrics;
    property Count: Integer read FCount write SetCount;
    property ItemIndex: Integer read GetItemIndex write SetItemIndex;
    property OnGetCell: TRtGetCellEvent read FOnGetCell write FOnGetCell;
    property OnSelectRow: TRtSelectEvent read FOnSelectRow write FOnSelectRow;
    property OnActivateRow: TRtSelectEvent read FOnActivateRow write FOnActivateRow;
    property FillWidth: Boolean read FFillWidth write SetFillWidth;
    property OnGetCellIcon: TRtGetCellIconEvent read FOnGetCellIcon write FOnGetCellIcon;
    function CellIcon(AIndex, ACol: Integer; out AColor: TColor): string;
    procedure SortBy(ACol: Integer; ADescending: Boolean);
    property Sortable: Boolean read FSortable write FSortable;
    property SortedColumn: Integer read FSortCol;
    property SortedDescending: Boolean read FSortDesc;
    property ShowHeader: Boolean read FShowHeader write SetShowHeader;
    property StretchLastColumn: Boolean read FStretchLast write SetStretchLast;
    property RowColor: TColor read FRowColor write FRowColor;
    property RowTextColor: TColor read FRowTextColor write FRowTextColor;
  end;

implementation

uses
  Forms, Math, LazUTF8, uTheme, uIcons;

const
  CELL_ICON = 16;

function TRtListGrid.CellIcon(AIndex, ACol: Integer; out AColor: TColor): string;
begin
  AColor := clNone;
  Result := '';
  if Assigned(FOnGetCellIcon) and (AIndex >= 0) and (AIndex < FCount) then
    Result := FOnGetCellIcon(Self, AIndex, ACol, AColor);
end;

constructor TRtListGrid.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCaptions := TStringList.Create;
  FRows := TList.Create;
  FLastSelected := -1;
  FSortCol := -1;
  FShowHeader := True;
  FRowColor := clDefault;
  FRowTextColor := clDefault;
  FixedCols := 0;
  ColCount := 1;
  RowCount := 1;
  FixedRows := 1;
  BorderStyle := bsNone;
  Options := [goRowSelect, goColSizing, goThumbTracking, goSmoothScroll];
  Flat := True;
  DefaultDrawing := False;
  FocusRectVisible := False;
  AutoFillColumns := False;
  ExtendedSelect := False;
end;

destructor TRtListGrid.Destroy;
begin
  ClearRows;
  FRows.Free;
  FCaptions.Free;
  inherited Destroy;
end;

procedure TRtListGrid.ClearRows;
var
  i: Integer;
begin
  for i := 0 to FRows.Count - 1 do
    TStringList(FRows[i]).Free;
  FRows.Clear;
end;

procedure TRtListGrid.ClearColumns;
begin
  FCaptions.Clear;
  FWeights := nil;
  ColCount := 1;
  ColWidths[0] := 100;
end;

procedure TRtListGrid.AddColumn(const ACaption: string; AWidth: Integer);
begin
  FCaptions.Add(ACaption);
  SetLength(FWeights, FCaptions.Count);
  FWeights[High(FWeights)] := AWidth;
  ColCount := FCaptions.Count;
  ColWidths[FCaptions.Count - 1] := AWidth;
  FitColumns;
  Invalidate;
end;

procedure TRtListGrid.SetFillWidth(AValue: Boolean);
begin
  FFillWidth := AValue;
  FitColumns;
end;

procedure TRtListGrid.SetStretchLast(AValue: Boolean);
begin
  FStretchLast := AValue;
  FitColumns;
end;

procedure TRtListGrid.FitColumns;
var
  i, total, avail, used, w: Integer;
begin
  if not (FFillWidth or FStretchLast) or FFitting or (Length(FWeights) = 0) or
    (Length(FWeights) <> ColCount) then Exit;
  avail := ClientWidth - 2;
  if avail <= 0 then Exit;
  if not FFillWidth then
  begin
    used := 0;
    for i := 0 to High(FWeights) - 1 do
      Inc(used, ColWidths[i]);
    FFitting := True;
    try
      ColWidths[High(FWeights)] := Max(FWeights[High(FWeights)], avail - used);
    finally
      FFitting := False;
    end;
    Exit;
  end;
  total := 0;
  for i := 0 to High(FWeights) do
    Inc(total, FWeights[i]);
  if total <= 0 then Exit;
  FFitting := True;
  try
    used := 0;
    for i := 0 to High(FWeights) do
    begin
      if i = High(FWeights) then
        w := avail - used
      else
        w := (avail * FWeights[i]) div total;
      if w < 40 then w := 40;
      ColWidths[i] := w;
      Inc(used, w);
    end;
  finally
    FFitting := False;
  end;
end;

procedure TRtListGrid.DoOnResize;
begin
  inherited DoOnResize;
  FitColumns;
end;

procedure TRtListGrid.HeaderSized(IsColumn: Boolean; Index: Integer);
var
  i: Integer;
begin
  inherited HeaderSized(IsColumn, Index);
  if IsColumn and FStretchLast and not FFillWidth then
  begin
    FitColumns;
    Exit;
  end;
  if not IsColumn or not FFillWidth or (Length(FWeights) <> ColCount) then Exit;
  for i := 0 to High(FWeights) do
    FWeights[i] := ColWidths[i];
  FitColumns;
end;

procedure TRtListGrid.DblClick;
var
  pt: TPoint;
  c, r: Integer;
begin
  inherited DblClick;
  pt := ScreenToClient(Mouse.CursorPos);
  MouseToCell(pt.X, pt.Y, c, r);
  if (r >= 1) and (r - 1 < FCount) and Assigned(FOnActivateRow) then
    FOnActivateRow(Self, DataIndex(r - 1));
end;

// Clic sur la ligne deja courante: la grille ne bouge pas, donc pas d'AfterMoveSelection.
// La selection est signalee ici si personne ne l'a encore vue.
procedure TRtListGrid.Click;
begin
  inherited Click;
  SelectionChanged;
end;

procedure TRtListGrid.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_RETURN) and (Shift = []) and (ItemIndex >= 0) and Assigned(FOnActivateRow) then
  begin
    FOnActivateRow(Self, ItemIndex);
    Key := 0;
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TRtListGrid.RefreshMetrics;
var
  bmp: Graphics.TBitmap;
begin
  bmp := Graphics.TBitmap.Create;
  try
    bmp.Canvas.Font.Assign(Font);
    DefaultRowHeight := bmp.Canvas.TextHeight('Ag') + 8;
    if Assigned(FOnGetCellIcon) and (DefaultRowHeight < ScreenIconSize(CELL_ICON) + 4) then
      DefaultRowHeight := ScreenIconSize(CELL_ICON) + 4;
  finally
    bmp.Free;
  end;
  ApplyHeaderHeight;
  Invalidate;
end;

procedure TRtListGrid.SetShowHeader(AValue: Boolean);
begin
  if FShowHeader = AValue then Exit;
  FShowHeader := AValue;
  ApplyHeaderHeight;
end;

procedure TRtListGrid.ApplyHeaderHeight;
begin
  if FShowHeader then
    RowHeights[0] := DefaultRowHeight
  else
    RowHeights[0] := 0;
end;

procedure TRtListGrid.SetCount(AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  FCount := AValue;
  FOrder := nil;
  FPlace := nil;
  RowCount := FCount + 1;
  if FSortCol >= 0 then ApplySort;
  Invalidate;
end;

function TRtListGrid.DataIndex(ADisplay: Integer): Integer;
begin
  if (ADisplay >= 0) and (ADisplay < Length(FOrder)) then
    Result := FOrder[ADisplay]
  else
    Result := ADisplay;
end;

function TRtListGrid.DisplayIndex(AData: Integer): Integer;
begin
  if (AData >= 0) and (AData < Length(FPlace)) then
    Result := FPlace[AData]
  else
    Result := AData;
end;

function CompareCellTexts(const A, B: string): Integer;
var
  na, nb: Int64;
begin
  if TryStrToInt64(Trim(A), na) and TryStrToInt64(Trim(B), nb) then
  begin
    if na < nb then Exit(-1);
    if na > nb then Exit(1);
    Exit(0);
  end;
  Result := UTF8CompareText(A, B);
  if Result = 0 then Result := CompareStr(A, B);
end;

procedure TRtListGrid.ApplySort;
var
  keys: array of string;
  src, tmp: array of Integer;
  i, n, span, lo, mid, hi, a, b, k, c: Integer;
  sel: Integer;
begin
  sel := ItemIndex;
  FOrder := nil;
  FPlace := nil;
  if (FSortCol >= 0) and (FCount > 1) then
  begin
    n := FCount;
    keys := nil;
    SetLength(keys, n);
    for i := 0 to n - 1 do
      keys[i] := CellText(i, FSortCol);
    src := nil;
    tmp := nil;
    SetLength(src, n);
    SetLength(tmp, n);
    for i := 0 to n - 1 do
      src[i] := i;
    span := 1;
    while span < n do
    begin
      lo := 0;
      while lo < n do
      begin
        mid := lo + span;
        if mid > n then mid := n;
        hi := lo + 2 * span;
        if hi > n then hi := n;
        a := lo;
        b := mid;
        k := lo;
        while (a < mid) and (b < hi) do
        begin
          c := CompareCellTexts(keys[src[a]], keys[src[b]]);
          if FSortDesc then c := -c;
          if c <= 0 then
          begin
            tmp[k] := src[a];
            Inc(a);
          end
          else
          begin
            tmp[k] := src[b];
            Inc(b);
          end;
          Inc(k);
        end;
        while a < mid do
        begin
          tmp[k] := src[a];
          Inc(a);
          Inc(k);
        end;
        while b < hi do
        begin
          tmp[k] := src[b];
          Inc(b);
          Inc(k);
        end;
        lo := hi;
      end;
      for i := 0 to n - 1 do
        src[i] := tmp[i];
      span := span * 2;
    end;
    FOrder := src;
    SetLength(FPlace, n);
    for i := 0 to n - 1 do
      FPlace[FOrder[i]] := i;
  end;
  if (sel >= 0) and (sel < FCount) then
    Row := DisplayIndex(sel) + 1;
  Invalidate;
end;

procedure TRtListGrid.SortBy(ACol: Integer; ADescending: Boolean);
begin
  if ACol >= ColCount then ACol := -1;
  FSortCol := ACol;
  FSortDesc := ADescending;
  ApplySort;
end;

procedure TRtListGrid.HeaderClick(IsColumn: Boolean; index: Integer);
begin
  inherited HeaderClick(IsColumn, index);
  if not FSortable or not IsColumn or (index < 0) or (index >= ColCount) then Exit;
  if index = FSortCol then
    SortBy(index, not FSortDesc)
  else
    SortBy(index, False);
end;

procedure TRtListGrid.Clear;
begin
  ClearRows;
  SetCount(0);
  FLastSelected := -1;
end;

function TRtListGrid.AddRow(const AValues: array of string): Integer;
var
  sl: TStringList;
  i: Integer;
begin
  sl := TStringList.Create;
  for i := 0 to High(AValues) do
    sl.Add(AValues[i]);
  FRows.Add(sl);
  Result := FRows.Count - 1;
  SetCount(FRows.Count);
end;

function TRtListGrid.CellText(AIndex, ACol: Integer): string;
var
  sl: TStringList;
begin
  Result := '';
  if Assigned(FOnGetCell) then
    Exit(FOnGetCell(Self, AIndex, ACol));
  if (AIndex < 0) or (AIndex >= FRows.Count) then Exit;
  sl := TStringList(FRows[AIndex]);
  if ACol < sl.Count then
    Result := sl[ACol];
end;

function TRtListGrid.GetItemIndex: Integer;
begin
  if (FCount = 0) or (Row < 1) then
    Result := -1
  else
    Result := DataIndex(Row - 1);
end;

procedure TRtListGrid.SetItemIndex(AValue: Integer);
begin
  if (AValue >= 0) and (AValue < FCount) then
    Row := DisplayIndex(AValue) + 1;
end;

procedure TRtListGrid.SelectionChanged;
var
  idx: Integer;
begin
  idx := GetItemIndex;
  if idx = FLastSelected then Exit;
  FLastSelected := idx;
  if Assigned(FOnSelectRow) and (idx >= 0) then
    FOnSelectRow(Self, idx);
end;

procedure TRtListGrid.AfterMoveSelection(const aPrevCol, aPrevRow: Integer);
begin
  inherited AfterMoveSelection(aPrevCol, aPrevRow);
  SelectionChanged;
end;

procedure TRtListGrid.DrawCell(ACol, ARow: Longint; ARect: TRect; AState: TGridDrawState);
var
  s, iconId: string;
  ts: TTextStyle;
  textLeft, textRight, px, cx, cy, h: Integer;
  iconColor: TColor;
  bmp: TBitmap;
begin
  Canvas.Font.Assign(Font);
  if ARow = 0 then
  begin
    Canvas.Brush.Color := clSideBg;
    Canvas.Font.Color := clSideTextHi;
    if ACol < FCaptions.Count then s := FCaptions[ACol] else s := '';
  end
  else
  begin
    if (FCount > 0) and (ARow = Row) then
    begin
      Canvas.Brush.Color := clSideSel;
      Canvas.Font.Color := clSideTextHi;
    end
    else
    begin
      if FRowColor = clDefault then Canvas.Brush.Color := clAppBg
      else Canvas.Brush.Color := FRowColor;
      if FRowTextColor = clDefault then Canvas.Font.Color := clAppFg
      else Canvas.Font.Color := FRowTextColor;
    end;
    if ARow - 1 < FCount then
      s := CellText(DataIndex(ARow - 1), ACol)
    else
      s := '';
  end;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(ARect);
  if ARow = 0 then
  begin
    Canvas.Pen.Color := clBorder;
    Canvas.Line(ARect.Right - 1, ARect.Top + 4, ARect.Right - 1, ARect.Bottom - 4);
    Canvas.Line(ARect.Left, ARect.Bottom - 1, ARect.Right, ARect.Bottom - 1);
  end;
  textLeft := ARect.Left + 6;
  textRight := ARect.Right - 4;
  if (ARow = 0) and (ACol = FSortCol) then
  begin
    h := (ARect.Bottom - ARect.Top) div 5;
    if h < 3 then h := 3;
    cx := ARect.Right - 8 - h;
    cy := (ARect.Top + ARect.Bottom) div 2;
    Canvas.Pen.Color := clSideTextHi;
    Canvas.Brush.Color := clSideTextHi;
    if FSortDesc then
      Canvas.Polygon([Point(cx - h, cy - h div 2), Point(cx + h, cy - h div 2), Point(cx, cy + h div 2 + 1)])
    else
      Canvas.Polygon([Point(cx - h, cy + h div 2), Point(cx + h, cy + h div 2), Point(cx, cy - h div 2 - 1)]);
    textRight := cx - h - 4;
  end;
  if ARow > 0 then
  begin
    iconId := CellIcon(DataIndex(ARow - 1), ACol, iconColor);
    if iconId <> '' then
    begin
      px := ScreenIconSize(CELL_ICON);
      bmp := IconBitmap(iconId, px, iconColor);
      if bmp <> nil then
        Canvas.Draw(textLeft, ARect.Top + (ARect.Bottom - ARect.Top - px) div 2, bmp);
      Inc(textLeft, px + 6);
    end;
  end;
  ts := Canvas.TextStyle;
  ts.Layout := tlCenter;
  ts.SingleLine := True;
  ts.Clipping := True;
  ts.EndEllipsis := True;
  ts.Opaque := False;
  Canvas.TextRect(Classes.Rect(textLeft, ARect.Top, textRight, ARect.Bottom),
    textLeft, ARect.Top, s, ts);
end;

end.
