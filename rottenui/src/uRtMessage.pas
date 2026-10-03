// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uRtMessage;

{$mode objfpc}{$H+}

// Messages, questions et saisies courtes aux couleurs du theme: MessageDlg, QuestionDlg et
// InputQuery restent obstinement clairs sur un theme sombre. Memes signatures que la LCL;
// Echap rend mrCancel, et tout ce qui n'est pas mrYes ou mrOk vaut refus.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs, Graphics;

function RtMessageDlg(const ACaption, AMsg: string; ADlgType: TMsgDlgType;
  AButtons: TMsgDlgButtons; AHelpCtx: Longint = 0): TModalResult;

type
  TRtMessageOverride = function(const ACaption, AMsg: string; ADlgType: TMsgDlgType): TModalResult;

var
  RtMessageOverride: TRtMessageOverride = nil;

function RtQuestionDlg(const ACaption, AMsg: string; ADlgType: TMsgDlgType;
  const AButtons: array of const; AHelpCtx: Longint = 0): TModalResult;
function RtInputQuery(const ACaption, APrompt: string; var AValue: string): Boolean;

implementation

uses
  LCLType, LCLIntf, uTheme, uUiKit, uIcons;

const
  MSG_WIDTH = 520;
  MSG_ICON = 32;
  MSG_FRAME = 120;

type
  TRtMessageForm = class(TRtDialog)
  private
    FIcon: TRtIcon;
    FMemo: TMemo;
    FDlgType: TMsgDlgType;
  protected
    procedure ApplyShellColors; override;
  public
    constructor CreateMessage(const ACaption, AMsg: string; ADlgType: TMsgDlgType);
  end;

function IconFor(ADlgType: TMsgDlgType): string;
begin
  case ADlgType of
    mtError: Result := 'circle-x';
    mtWarning: Result := 'alert-triangle';
    mtConfirmation: Result := 'help-circle';
  else
    Result := 'info-circle';
  end;
end;

function StripColorFor(ADlgType: TMsgDlgType): TColor;
begin
  case ADlgType of
    mtError: Result := ShellStateColor(usError);
    mtWarning: Result := ShellStateColor(usWarning);
  else
    Result := clAccent;
  end;
end;

function WrappedHeight(AFont: TFont; const AText: string; AWidth: Integer): Integer;
var
  bmp: Graphics.TBitmap;
  r: TRect;
begin
  bmp := Graphics.TBitmap.Create;
  try
    bmp.Canvas.Font.Assign(AFont);
    r := Rect(0, 0, AWidth, 0);
    DrawText(bmp.Canvas.Handle, PChar(AText), Length(AText), r,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    Result := r.Bottom - r.Top;
  finally
    bmp.Free;
  end;
end;

procedure PlaceOnScreen(AForm: TForm);
begin
  if Screen.ActiveCustomForm <> nil then
    AForm.Position := poOwnerFormCenter
  else if Application.MainForm <> nil then
    AForm.Position := poMainFormCenter
  else
    AForm.Position := poScreenCenter;
end;

constructor TRtMessageForm.CreateMessage(const ACaption, AMsg: string; ADlgType: TMsgDlgType);
var
  lbl: TLabel;
  textW, textH, px, maxH: Integer;
begin
  inherited CreateDialog(Screen.ActiveCustomForm, ACaption, MSG_WIDTH, 200);
  PlaceOnScreen(Self);
  FDlgType := ADlgType;
  FIcon := TRtIcon.Create(Self);
  FIcon.Parent := Body;
  FIcon.Align := alLeft;
  FIcon.SetIcon(IconFor(ADlgType), MSG_ICON, StripColorFor(ADlgType));
  FIcon.BorderSpacing.Right := 14;
  FIcon.TopAligned := True;
  px := FIcon.PixelSize;
  textW := MSG_WIDTH - 2 * 8 - px - 14 - 2 * 4 - 8;
  textH := WrappedHeight(Font, AMsg, textW);
  if textH < px then textH := px;
  // Un message plus haut que l'ecran poussait les boutons hors champ, plus moyen de dire
  // non. Au-dela de la zone de travail, le texte defile et les boutons restent visibles.
  maxH := Screen.WorkAreaHeight - (2 * 8 + 2 * 4 + 16 + 44) - MSG_FRAME;
  if maxH < 4 * px then maxH := 4 * px;
  if textH > maxH then
  begin
    FMemo := TMemo.Create(Self);
    FMemo.Parent := Body;
    FMemo.Align := alClient;
    FMemo.ReadOnly := True;
    FMemo.WordWrap := True;
    FMemo.ScrollBars := ssAutoVertical;
    FMemo.BorderStyle := bsNone;
    FMemo.Text := AMsg;
    textH := maxH;
  end
  else
  begin
    lbl := MakeLabel(Body, AMsg, alClient);
    lbl.WordWrap := True;
    lbl.ShowAccelChar := False;
  end;
  ClientHeight := textH + 2 * 8 + 2 * 4 + 16 + 44;
end;

procedure TRtMessageForm.ApplyShellColors;
begin
  inherited ApplyShellColors;
  FIcon.IconColor := StripColorFor(FDlgType);
  if FMemo <> nil then
  begin
    FMemo.Color := clAppBg;
    FMemo.Font.Color := clAppFg;
    ApplyNativeDarkMode(FMemo);
  end;
end;

function ButtonCaption(ABtn: TMsgDlgBtn): string;
begin
  case ABtn of
    mbYes: Result := 'Yes';
    mbNo: Result := 'No';
    mbOK: Result := 'OK';
    mbCancel: Result := 'Cancel';
    mbAbort: Result := 'Abort';
    mbRetry: Result := 'Retry';
    mbIgnore: Result := 'Ignore';
    mbAll: Result := 'All';
    mbNoToAll: Result := 'No to all';
    mbYesToAll: Result := 'Yes to all';
    mbHelp: Result := 'Help';
    mbClose: Result := 'Close';
  else
    Result := '?';
  end;
end;

function ButtonResult(ABtn: TMsgDlgBtn): TModalResult;
begin
  case ABtn of
    mbYes: Result := mrYes;
    mbNo: Result := mrNo;
    mbOK: Result := mrOk;
    mbCancel: Result := mrCancel;
    mbAbort: Result := mrAbort;
    mbRetry: Result := mrRetry;
    mbIgnore: Result := mrIgnore;
    mbAll: Result := mrAll;
    mbNoToAll: Result := mrNoToAll;
    mbYesToAll: Result := mrYesToAll;
    mbClose: Result := mrClose;
  else
    Result := mrNone;
  end;
end;

type
  TBtnSpec = record
    Caption: string;
    Result: TModalResult;
  end;
  TBtnSpecs = array of TBtnSpec;

function RunMessage(const ACaption, AMsg: string; ADlgType: TMsgDlgType;
  const ASpecs: TBtnSpecs): TModalResult;
var
  f: TRtMessageForm;
  i, def: Integer;
  b, defBtn: TButton;
begin
  f := TRtMessageForm.CreateMessage(ACaption, AMsg, ADlgType);
  try
    def := 0;
    for i := 0 to High(ASpecs) do
      if ASpecs[i].Result = mrOk then begin def := i; Break; end;
    if (def = 0) and (Length(ASpecs) > 0) and (ASpecs[0].Result <> mrOk) then
      for i := 0 to High(ASpecs) do
        if ASpecs[i].Result = mrYes then begin def := i; Break; end;
    defBtn := nil;
    for i := High(ASpecs) downto 0 do
    begin
      b := f.AddButton(ASpecs[i].Caption, ASpecs[i].Result, i = def,
        ASpecs[i].Result = mrCancel);
      if i = def then defBtn := b;
    end;
    f.ApplyTheme;
    if defBtn <> nil then f.ActiveControl := defBtn;
    if ADlgType in [mtError, mtWarning] then Beep;
    Result := f.ShowModal;
  finally
    f.Free;
  end;
end;

function RtMessageDlg(const ACaption, AMsg: string; ADlgType: TMsgDlgType;
  AButtons: TMsgDlgButtons; AHelpCtx: Longint): TModalResult;
var
  specs: TBtnSpecs;
  b: TMsgDlgBtn;
begin
  if Assigned(RtMessageOverride) then Exit(RtMessageOverride(ACaption, AMsg, ADlgType));
  specs := nil;
  for b := Low(TMsgDlgBtn) to High(TMsgDlgBtn) do
    if (b in AButtons) and (b <> mbHelp) then
    begin
      SetLength(specs, Length(specs) + 1);
      specs[High(specs)].Caption := ButtonCaption(b);
      specs[High(specs)].Result := ButtonResult(b);
    end;
  if Length(specs) = 0 then
  begin
    SetLength(specs, 1);
    specs[0].Caption := 'OK';
    specs[0].Result := mrOk;
  end;
  Result := RunMessage(ACaption, AMsg, ADlgType, specs);
end;

function VarRecText(const V: TVarRec; out AText: string): Boolean;
begin
  Result := True;
  case V.VType of
    vtAnsiString: AText := AnsiString(V.VAnsiString);
    vtUnicodeString: AText := UTF8Encode(UnicodeString(V.VUnicodeString));
    vtWideString: AText := UTF8Encode(WideString(V.VWideString));
    vtString: AText := V.VString^;
    vtPChar: AText := V.VPChar;
    vtChar: AText := V.VChar;
  else
    Result := False;
  end;
end;

function RtQuestionDlg(const ACaption, AMsg: string; ADlgType: TMsgDlgType;
  const AButtons: array of const; AHelpCtx: Longint): TModalResult;
var
  specs: TBtnSpecs;
  i: Integer;
  s: string;
begin
  specs := nil;
  i := 0;
  while i <= High(AButtons) do
  begin
    if AButtons[i].VType = vtInteger then
    begin
      SetLength(specs, Length(specs) + 1);
      specs[High(specs)].Result := AButtons[i].VInteger;
      specs[High(specs)].Caption := '';
      // 'IsDefault' et 'IsCancel' de QuestionDlg ne sont pas des libelles: ignores.
      if (i < High(AButtons)) and VarRecText(AButtons[i + 1], s) then
      begin
        Inc(i);
        if not (SameText(s, 'IsDefault') or SameText(s, 'IsCancel')) then
          specs[High(specs)].Caption := s;
      end;
      if specs[High(specs)].Caption = '' then
        case specs[High(specs)].Result of
          mrYes: specs[High(specs)].Caption := 'Yes';
          mrNo: specs[High(specs)].Caption := 'No';
          mrCancel: specs[High(specs)].Caption := 'Cancel';
        else
          specs[High(specs)].Caption := 'OK';
        end;
    end;
    Inc(i);
  end;
  Result := RunMessage(ACaption, AMsg, ADlgType, specs);
end;

function RtInputQuery(const ACaption, APrompt: string; var AValue: string): Boolean;
var
  f: TRtDialog;
  lbl: TLabel;
  row: TPanel;
  ed: TEdit;
  textH: Integer;
begin
  f := TRtDialog.CreateDialog(Screen.ActiveCustomForm, ACaption, MSG_WIDTH, 200);
  try
    PlaceOnScreen(f);
    lbl := MakeLabel(f.Body, APrompt);
    lbl.ShowAccelChar := False;
    row := MakePanel(f.Body, alTop, 34);
    StackTop(row);
    ed := TEdit.Create(row);
    ed.Parent := row;
    ed.Align := alClient;
    ed.BorderSpacing.Around := 3;
    ed.Text := AValue;
    f.AddButton('Cancel', mrCancel, False, True);
    f.AddButton('OK', mrOk, True);
    textH := WrappedHeight(f.Font, APrompt, MSG_WIDTH - 2 * 8 - 2 * 4 - 8);
    f.ClientHeight := textH + 2 * 4 + 34 + 2 * 8 + 16 + 44;
    f.ApplyTheme;
    f.ActiveControl := ed;
    ed.SelectAll;
    Result := f.ShowModal = mrOk;
    if Result then AValue := ed.Text;
  finally
    f.Free;
  end;
end;

end.
