// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPickDialog;

{$mode objfpc}{$H+}

// Choix d'un element dans une liste filtrable, description de la ligne en dessous.
// Un seul gagnant, double clic ou Entree. Le bouton facultatif rend mrRetry.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, uUiKit, uRtList;

type
  TPickRow = record
    Key: string;
    Cells: array of string;
    Info: string;
  end;
  TPickRows = array of TPickRow;

  TPickDialog = class(TRtDialog)
  private
    FFilter: TEdit;
    FList: TRtListGrid;
    FInfo: TMemo;
    FRows: TPickRows;
    FShown: array of Integer;
    FChosen: string;
    FOkButton: TButton;
    procedure FilterChange(Sender: TObject);
    procedure ListSelect(Sender: TObject; AIndex: Integer);
    procedure ListActivate(Sender: TObject; AIndex: Integer);
    procedure OkClick(Sender: TObject);
    procedure Refill;
  public
    constructor CreatePick(AOwner: TComponent; const ACaption, AHelp: string;
      const AColumns: array of string; const AWidths: array of Integer;
      const AExtraCaption: string = '');
    procedure SetRows(const ARows: TPickRows);
    function Chosen: string;
    procedure SetFilter(const AText: string);
    function VisibleKeys: string;
    function Choose(const AKey: string): Boolean;
    function InfoText: string;
  end;

  TPickOverride = function(ADialog: TPickDialog): TModalResult;

var
  PickDialogOverride: TPickOverride = nil;

function RunPick(ADialog: TPickDialog): TModalResult;

implementation

uses
  uTheme;

resourcestring
  rsPickSearch = 'Search';
  rsPickOk = 'Add';
  rsPickCancel = 'Cancel';

function RunPick(ADialog: TPickDialog): TModalResult;
begin
  if Assigned(PickDialogOverride) then
    Result := PickDialogOverride(ADialog)
  else
    Result := ADialog.ShowModal;
end;

constructor TPickDialog.CreatePick(AOwner: TComponent; const ACaption, AHelp: string;
  const AColumns: array of string; const AWidths: array of Integer; const AExtraCaption: string);
var
  lbl: TLabel;
  i: Integer;
  b: TButton;
begin
  inherited CreateDialog(AOwner, ACaption, 900, 620);
  lbl := MakeLabel(Body, AHelp);
  lbl.WordWrap := True;
  lbl.ShowAccelChar := False;
  MakeLabel(Body, rsPickSearch).BorderSpacing.Top := 6;
  FFilter := MakeEdit(Body);
  FFilter.OnChange := @FilterChange;
  FInfo := MakeMemo(Body, alBottom);
  FInfo.Height := 150;
  FInfo.ReadOnly := True;
  FInfo.ScrollBars := ssAutoVertical;
  FInfo.WordWrap := True;
  FList := TRtListGrid.Create(Body);
  FList.Parent := Body;
  FList.Align := alClient;
  FList.BorderSpacing.Top := 4;
  FList.BorderSpacing.Bottom := 4;
  FList.FillWidth := True;
  for i := 0 to High(AColumns) do
    if i <= High(AWidths) then FList.AddColumn(AColumns[i], AWidths[i])
    else FList.AddColumn(AColumns[i], 200);
  FList.OnSelectRow := @ListSelect;
  FList.OnActivateRow := @ListActivate;
  AddButton(rsPickCancel, mrCancel, False, True);
  FOkButton := AddButton(rsPickOk, mrNone, True);
  FOkButton.OnClick := @OkClick;
  if AExtraCaption <> '' then
  begin
    b := AddButton(AExtraCaption, mrRetry);
    b.Default := False;
  end;
  ApplyTheme;
  StyleMemo(FInfo);
  ActiveControl := FFilter;
end;

procedure TPickDialog.SetRows(const ARows: TPickRows);
begin
  FRows := ARows;
  Refill;
end;

procedure TPickDialog.Refill;
var
  i, j: Integer;
  f: string;
  hit: Boolean;
begin
  FList.Clear;
  FShown := nil;
  f := LowerCase(Trim(FFilter.Text));
  for i := 0 to High(FRows) do
  begin
    hit := (f = '') or (Pos(f, LowerCase(FRows[i].Key)) > 0);
    for j := 0 to High(FRows[i].Cells) do
      if not hit and (Pos(f, LowerCase(FRows[i].Cells[j])) > 0) then hit := True;
    if not hit then Continue;
    FList.AddRow(FRows[i].Cells);
    SetLength(FShown, Length(FShown) + 1);
    FShown[High(FShown)] := i;
  end;
  FInfo.Clear;
  if Length(FShown) > 0 then
  begin
    FList.ItemIndex := 0;
    ListSelect(FList, 0);
  end;
  FOkButton.Enabled := Length(FShown) > 0;
end;

procedure TPickDialog.FilterChange(Sender: TObject);
begin
  Refill;
end;

procedure TPickDialog.ListSelect(Sender: TObject; AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > High(FShown)) then Exit;
  FInfo.Text := StringReplace(FRows[FShown[AIndex]].Info, #10, LineEnding, [rfReplaceAll]);
end;

procedure TPickDialog.ListActivate(Sender: TObject; AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > High(FShown)) then Exit;
  FChosen := FRows[FShown[AIndex]].Key;
  ModalResult := mrOk;
end;

procedure TPickDialog.OkClick(Sender: TObject);
begin
  ListActivate(FList, FList.ItemIndex);
end;

function TPickDialog.Chosen: string;
begin
  Result := FChosen;
end;

procedure TPickDialog.SetFilter(const AText: string);
begin
  FFilter.Text := AText;
  Refill;
end;

function TPickDialog.VisibleKeys: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FShown) do Result := Result + FRows[FShown[i]].Key + '|';
end;

function TPickDialog.Choose(const AKey: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FShown) do
    if SameText(FRows[FShown[i]].Key, AKey) then
    begin
      FList.ItemIndex := i;
      ListSelect(FList, i);
      FChosen := FRows[FShown[i]].Key;
      Exit(True);
    end;
  Result := False;
end;

function TPickDialog.InfoText: string;
begin
  Result := FInfo.Text;
end;

end.
