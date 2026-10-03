// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uToolsDialogs;

{$mode objfpc}{$H+}

// Outils: echappement DN (RFC 4514) et filtre (RFC 4515), chacun le sien, les confondre c'est
// ouvrir la porte a l'injection. Inspecteur Root DSE, preferences locales.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs, uConnections, uRtCombo;

procedure ShowEscapeTool(AOwner: TComponent);
procedure ShowRootDse(AOwner: TComponent; AConn: TDirectoryConnection);
function ShowPreferences(AOwner: TComponent): Boolean;

implementation

uses
  Spin, uTheme, uThemeLoad, uUiKit, uLdapDn, uLdapFilter, uLdapEntry, uPreferences, uRtBytes,
  uThemePreview;

resourcestring
  rsEscTitle = 'DN and filter escaping';
  rsEscInput = 'Raw value';
  rsEscDn = 'DN attribute value (RFC 4514)';
  rsEscFilter = 'Filter assertion value (RFC 4515)';
  rsEscParse = 'Parsed DN (one RDN per line)';
  rsEscWarning = 'The two escapings are different: never reuse one in place of the other.';
  rsRootTitle = 'Root DSE';
  rsPrefTitle = 'Preferences';
  rsPrefTheme = 'Theme';
  rsPrefSensitive = 'Extra sensitive attributes (comma separated)';
  rsPrefThemePreview = 'Preview';
  rsPrefUiFontSize = 'Interface font size (10 to 14 points)';
  rsPrefEditorFontSize = 'Editor font size (10 to 14 points, 0 = theme)';
  rsPrefSensitiveHint = 'Masked in views and logs, and written only over an encrypted connection. Exports contain every attribute that was read.';
  rsPrefRestartFonts = 'Font sizes apply to new windows and tabs; restart for a complete update.';

type
  TEscapeTool = class(TRtDialog)
  public
    Input, DnOut, FilterOut: TEdit;
    Parsed: TMemo;
    procedure InputChange(Sender: TObject);
  end;

procedure TEscapeTool.InputChange(Sender: TObject);
var
  d: TLdapDn;
  err: string;
  i: Integer;
begin
  DnOut.Text := DnEscapeValue(Input.Text);
  FilterOut.Text := FilterEscapeValue(Input.Text);
  Parsed.Clear;
  if DnParse(Input.Text, d, err) then
  begin
    for i := 0 to High(d.Rdns) do
      Parsed.Lines.Add(RdnToString(d.Rdns[i]));
  end
  else
    Parsed.Lines.Add('(not a DN: ' + err + ')');
end;

function ReadOnlyEdit(AParent: TWinControl; const ACaption: string): TEdit;
var
  row: TPanel;
begin
  row := MakeFieldRow(AParent, ACaption, 240);
  Result := TEdit.Create(row);
  Result.Parent := row;
  Result.Align := alClient;
  Result.ReadOnly := True;
  Result.BorderSpacing.Around := 3;
end;

procedure ShowEscapeTool(AOwner: TComponent);
var
  d: TEscapeTool;
  row: TPanel;
begin
  d := TEscapeTool.CreateDialog(AOwner, rsEscTitle, 760, 420);
  d.SetIcon('terminal-2');
  try
    row := MakeFieldRow(d.Body, rsEscInput, 240);
    d.Input := TEdit.Create(row);
    d.Input.Parent := row;
    d.Input.Align := alClient;
    d.Input.OnChange := @d.InputChange;
    d.DnOut := ReadOnlyEdit(d.Body, rsEscDn);
    d.FilterOut := ReadOnlyEdit(d.Body, rsEscFilter);
    MakeLabel(d.Body, rsEscWarning).Font.Color := DialogStateColor(usWarning);
    MakeLabel(d.Body, rsEscParse);
    d.Parsed := MakeMemo(d.Body);
    d.Parsed.ReadOnly := True;
    d.AddButton('Close', mrOk, True, True);
    d.ApplyTheme;
    d.ShowModal;
  finally
    d.Free;
  end;
end;

procedure ShowRootDse(AOwner: TComponent; AConn: TDirectoryConnection);
var
  d: TRtDialog;
  memo: TMemo;
  i, j: Integer;
  a: TLdapAttribute;
begin
  d := TRtDialog.CreateDialog(AOwner, rsRootTitle, 760, 600);
  d.SetIcon('database');
  try
    d.SetTarget(AConn.Profile.DisplayEndpoint + '  ' + AConn.Transport.StatusLabel, AConn.Profile.EnvironmentBadge);
    memo := MakeMemo(d.Body);
    memo.ReadOnly := True;
    if AConn.RootDse = nil then
      memo.Lines.Add('Root DSE not readable with this identity.')
    else
      for i := 0 to AConn.RootDse.AttrCount - 1 do
      begin
        a := AConn.RootDse.Attrs[i];
        for j := 0 to a.ValueCount - 1 do
          if IsValidUtf8(a.Values[j]) then
            memo.Lines.Add(a.Description + ': ' + EscapeControlChars(a.Values[j]))
          else
            memo.Lines.Add(a.Description + ':: ' + Base64EncodeStr(a.Values[j]));
      end;
    if AConn.Transport.AuthzId <> '' then
      memo.Lines.Add('# Who Am I: ' + AConn.Transport.AuthzId);
    d.AddButton('Close', mrOk, True, True);
    d.ApplyTheme;
    d.ShowModal;
  finally
    d.Free;
  end;
end;

type
  TPrefDialog = class(TRtDialog)
  public
    Theme: TRtComboBox;
    Preview: TThemePreview;
    FLastEditorSize: Integer;
    procedure ThemeChange(Sender: TObject);
    procedure EditorSizeChange(Sender: TObject);
  end;

// 0 veut dire taille du theme et 1 a 9 n'existent pas: la fleche saute de 0 a 10, et retour.
procedure TPrefDialog.EditorSizeChange(Sender: TObject);
var
  sp: TSpinEdit;
  v: Integer;
begin
  sp := TSpinEdit(Sender);
  v := sp.Value;
  if (v > 0) and (v < FONT_SIZE_MIN) then
  begin
    if FLastEditorSize >= FONT_SIZE_MIN then v := 0 else v := FONT_SIZE_MIN;
    sp.Value := v;
  end;
  FLastEditorSize := v;
end;

procedure TPrefDialog.ThemeChange(Sender: TObject);
begin
  Preview.ShowTheme(Theme.ItemIndex);
  if Visible then FitHeightToContent;
end;

function SpinRow(AParent: TWinControl; const ACaption: string; AMin, AMax, AValue: Integer): TSpinEdit;
var
  row: TPanel;
begin
  row := MakeFieldRow(AParent, ACaption, 200);
  Result := TSpinEdit.Create(row);
  Result.Parent := row;
  Result.Align := alLeft;
  Result.Width := 90;
  Result.BorderSpacing.Around := 3;
  Result.Constraints.MaxHeight := FontTextHeight(AParent.Font) + 12;
  Result.MinValue := AMin;
  Result.MaxValue := AMax;
  Result.Value := AValue;
end;

function ShowPreferences(AOwner: TComponent): Boolean;
var
  d: TPrefDialog;
  sensitive: TEdit;
  uiSize, edSize: TSpinEdit;
  row: TPanel;
  lbl: TLabel;
  i: Integer;
begin
  d := TPrefDialog.CreateDialog(AOwner, rsPrefTitle, 760, 640);
  d.SetIcon('settings');
  try
    row := MakeFieldRow(d.Body, rsPrefTheme, 200);
    d.Theme := TRtComboBox.Create(row);
    d.Theme.Parent := row;
    d.Theme.Align := alClient;
    d.Theme.Style := csDropDownList;
    d.Theme.BorderSpacing.Around := 3;
    for i := 0 to ThemeCount - 1 do
      d.Theme.Items.Add(ThemeName(i));
    d.Theme.ItemIndex := CurrentThemeIndex;
    d.Theme.OnChange := @d.ThemeChange;
    MakeLabel(d.Body, rsPrefThemePreview).Font.Color := DialogStateColor(usMuted);
    d.Preview := TThemePreview.Create(d.Body);
    d.Preview.Parent := d.Body;
    StackTop(d.Preview);
    d.Preview.Align := alTop;
    d.Preview.BorderSpacing.Around := 4;
    uiSize := SpinRow(d.Body, rsPrefUiFontSize, FONT_SIZE_MIN, FONT_SIZE_MAX,
      ClampFontSize(PrefUiFontSize));
    edSize := SpinRow(d.Body, rsPrefEditorFontSize, 0, FONT_SIZE_MAX, PrefEditorFontSize);
    d.FLastEditorSize := PrefEditorFontSize;
    edSize.OnChange := @d.EditorSizeChange;
    lbl := MakeLabel(d.Body, rsPrefRestartFonts);
    lbl.Font.Color := DialogStateColor(usMuted);
    lbl.WordWrap := True;
    row := MakeFieldRow(d.Body, rsPrefSensitive, 200);
    sensitive := TEdit.Create(row);
    sensitive.Parent := row;
    sensitive.Align := alClient;
    sensitive.BorderSpacing.Around := 3;
    sensitive.Text := PrefExtraSensitiveAttrs;
    lbl := MakeLabel(d.Body, rsPrefSensitiveHint);
    lbl.Font.Color := DialogStateColor(usMuted);
    lbl.WordWrap := True;
    d.AddButton('OK', mrOk, True);
    d.AddButton('Cancel', mrCancel, False, True);
    d.ApplyTheme;
    d.ThemeChange(nil);
    d.FitOnShow := True;
    Result := d.ShowModal = mrOk;
    if Result then
    begin
      ApplyThemeIndex(d.Theme.ItemIndex);
      PrefThemeName := CurrentThemeName;
      PrefExtraSensitiveAttrs := sensitive.Text;
      PrefUiFontSize := ClampFontSize(uiSize.Value);
      PrefEditorFontSize := edSize.Value;
      if PrefEditorFontSize <> 0 then PrefEditorFontSize := ClampFontSize(PrefEditorFontSize);
      ApplyThemeIndex(CurrentThemeIndex);
      SavePreferences;
    end;
  finally
    d.Free;
  end;
end;

end.
