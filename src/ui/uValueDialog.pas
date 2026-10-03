// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uValueDialog;

{$mode objfpc}{$H+}

// Vue et edition typees d'une valeur d'attribut, inspecteur de certificat d'attribut.
// Rien n'est ecrit ici: on rend au plus une nouvelle valeur a l'editeur. Les octets d'origine
// ne sont jamais reecrits tant que la saisie ne change pas.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, uAttributeCodec;

type
  TValueDialogFn = function(AOwner: TComponent; const AEndpoint, ABadge, AAttr: string;
    const AView: TAttributeValueView; AEditable: Boolean; const AReadOnlyWhy: string;
    out ANew: RawByteString): Boolean;

var
  ValueDialogOverride: TValueDialogFn = nil;

function ShowValueDialog(AOwner: TComponent; const AEndpoint, ABadge, AAttr: string;
  const AView: TAttributeValueView; AEditable: Boolean; const AReadOnlyWhy: string;
  out ANew: RawByteString): Boolean;

procedure ShowCertificateValue(AOwner: TComponent; const AEndpoint, ABadge, AAttr: string;
  const AValue: RawByteString; AExportOwner: Pointer);

resourcestring
  rsValTitle = 'Value of %s';
  rsValAttribute = 'Attribute: %s';
  rsValReadOnly = 'Read only: %s';
  rsValNewValue = 'Value';
  rsValValid = 'Valid. OK puts it in the entry; Apply writes the entry.';
  rsValUnchanged = 'Unchanged.';
  rsValInvalid = 'Invalid: %s';
  rsValHexShown = '-- first %d of %d bytes --';
  rsValHexTitle = 'Hexadecimal';
  rsValNotUtf8 = 'the value is not valid UTF-8: replace it from a file';
  rsValControl = 'the value contains control characters: replace it from a file';
  rsValTooLargeToEdit = 'the value is larger than %d bytes: replace it from a file';
  rsValProfileReadOnly = 'the profile or the entry cannot be edited now';
  rsValTypeNotText = 'this type is not edited as text';
  rsValCurrentInvalid = '%s (current, invalid)';
  rsCertValTitle = 'Certificate in %s';
  rsCertExportDer = 'Export DER (.cer)...';
  rsCertExportPem = 'Export PEM...';
  rsCertExportStarted = 'Writing %s...';
  rsCertExportBusy = 'Too many background tasks: try again in a moment.';

const
  VALUE_HEX_VIEW_BYTES = 64 * 1024;
  VALUE_TEXT_EDIT_BYTES = 1024 * 1024;

implementation

uses
  Graphics, Dialogs, uTheme, uUiKit, uRtCombo, uRtBytes, uCertificateInfo, uValueFile, uCancel;

type
  TValueDialog = class(TRtDialog)
  private
    FView: TAttributeValueView;
    FMemo: TMemo;
    FEdit: TEdit;
    FCombo: TRtComboBox;
    FStatus: TLabel;
    FOk: TButton;
    FNew: RawByteString;
    FNewValid: Boolean;
    function InputText: string;
    procedure InputChanged(Sender: TObject);
  end;

function TValueDialog.InputText: string;
begin
  if FCombo <> nil then
  begin
    // Index 2: 'valeur actuelle invalide', les octets d'origine repartent tels quels.
    if FCombo.ItemIndex = 2 then Result := string(FView.Bytes)
    else Result := FCombo.Text;
  end
  else if FMemo <> nil then Result := FMemo.Text
  else if FEdit <> nil then Result := FEdit.Text
  else Result := '';
end;

procedure TValueDialog.InputChanged(Sender: TObject);
var
  b: RawByteString;
  err: string;
begin
  FNewValid := False;
  FNew := '';
  if EncodeTyped(FView.Resolution, InputText, FView.Bytes, b, err) then
  begin
    if b = FView.Bytes then
      FStatus.Caption := rsValUnchanged
    else
    begin
      FNew := b;
      FNewValid := True;
      FStatus.Caption := rsValValid;
    end;
  end
  else
    FStatus.Caption := Format(rsValInvalid, [err]);
  FOk.Enabled := FNewValid;
end;

function HasEditUnsafeControl(const S: RawByteString): Boolean;
var
  i: Integer;
begin
  // Le memo laisse passer tabulations et fins de ligne, le reste (NUL...) y serait tronque ou
  // altere: editer ca en texte, c'est reecrire autre chose que ce qu'on a lu.
  for i := 1 to Length(S) do
    if ((Byte(S[i]) < 32) and not (S[i] in [#9, #10, #13])) or (Byte(S[i]) = 127) then Exit(True);
  Result := False;
end;

function ShowValueDialog(AOwner: TComponent; const AEndpoint, ABadge, AAttr: string;
  const AView: TAttributeValueView; AEditable: Boolean; const AReadOnlyWhy: string;
  out ANew: RawByteString): Boolean;
var
  d: TValueDialog;
  info, editPanel: TPanel;
  details: TMemo;
  i, shown: Integer;
  why, s: string;
  kind: TValueKind;
begin
  if Assigned(ValueDialogOverride) then
    Exit(ValueDialogOverride(AOwner, AEndpoint, ABadge, AAttr, AView, AEditable, AReadOnlyWhy, ANew));
  Result := False;
  ANew := '';
  kind := AView.Resolution.Kind;
  why := AReadOnlyWhy;
  if AEditable and (why = '') then
  begin
    if not KindTextEditable(kind) then why := rsValTypeNotText
    else if (kind = vkBinary) and (Length(AView.Bytes) > VALUE_HEX_VIEW_BYTES) then
      why := Format(rsValTooLargeToEdit, [VALUE_HEX_VIEW_BYTES])
    else if (kind <> vkBinary) and (Length(AView.Bytes) > VALUE_TEXT_EDIT_BYTES) then
      why := Format(rsValTooLargeToEdit, [VALUE_TEXT_EDIT_BYTES])
    else if (kind = vkText) and not IsValidUtf8(AView.Bytes) then why := rsValNotUtf8
    else if (kind = vkText) and HasEditUnsafeControl(AView.Bytes) then why := rsValControl;
  end
  else if not AEditable and (why = '') then
    why := rsValProfileReadOnly;
  if why <> '' then AEditable := False;

  d := TValueDialog.CreateDialog(AOwner, Format(rsValTitle, [AAttr]), 860, 580);
  d.SetIcon('file-text');
  try
    d.FView := AView;
    d.SetTarget(AEndpoint, ABadge);
    info := MakePanel(d.Body, alTop);
    info.AutoSize := True;
    MakeLabel(info, Format(rsValAttribute, [AAttr]));
    if AView.Diagnostic <> '' then
      MakeLabel(info, AView.Diagnostic);
    if not AEditable then
      MakeLabel(info, Format(rsValReadOnly, [why]));

    if AEditable then
    begin
      editPanel := MakePanel(d.Body, alBottom);
      if kind in [vkText, vkBinary] then editPanel.Height := 190 else editPanel.Height := 96;
      d.FStatus := MakeLabel(editPanel, '', alBottom);
      d.FStatus.WordWrap := True;
      MakeLabel(editPanel, rsValNewValue);
      if kind = vkBoolean then
      begin
        d.FCombo := TRtComboBox.Create(editPanel);
        d.FCombo.Parent := editPanel;
        StackTop(d.FCombo);
        d.FCombo.Align := alTop;
        d.FCombo.Style := csDropDownList;
        d.FCombo.BorderSpacing.Around := 4;
        d.FCombo.Items.Add('TRUE');
        d.FCombo.Items.Add('FALSE');
        s := string(AView.Bytes);
        if s = 'TRUE' then d.FCombo.ItemIndex := 0
        else if s = 'FALSE' then d.FCombo.ItemIndex := 1
        else
        begin
          // Valeur invalide montree comme telle, jamais convertie en FALSE: desactiver quelque
          // chose en silence, non merci.
          d.FCombo.Items.Add(Format(rsValCurrentInvalid, [EscapeControlChars(Copy(AView.Bytes, 1, 64))]));
          d.FCombo.ItemIndex := 2;
        end;
        d.FCombo.OnChange := @d.InputChanged;
      end
      else if kind in [vkText, vkBinary] then
      begin
        d.FMemo := MakeMemo(editPanel, alClient);
        d.FMemo.ScrollBars := ssAutoBoth;
        d.FMemo.WordWrap := kind = vkBinary;
        d.FMemo.Text := EditableText(AView.Resolution, AView.Bytes);
        d.FMemo.OnChange := @d.InputChanged;
      end
      else
      begin
        d.FEdit := MakeEdit(editPanel);
        d.FEdit.Text := EditableText(AView.Resolution, AView.Bytes);
        d.FEdit.OnChange := @d.InputChanged;
      end;
    end;

    details := MakeMemo(d.Body, alClient);
    details.ReadOnly := True;
    details.ScrollBars := ssAutoBoth;
    details.WordWrap := False;
    details.Lines.BeginUpdate;
    try
      for i := 0 to High(AView.Details) do
        details.Lines.Add(AView.Details[i]);
      if kind in [vkBinary, vkCertificate, vkSecurityDescriptor, vkGuid, vkSid] then
      begin
        details.Lines.Add('');
        details.Lines.Add(rsValHexTitle);
        shown := Length(AView.Bytes);
        if shown > VALUE_HEX_VIEW_BYTES then shown := VALUE_HEX_VIEW_BYTES;
        details.Lines.Add(HexDump(AView.Bytes, shown));
        if shown < Length(AView.Bytes) then
          details.Lines.Add(Format(rsValHexShown, [shown, Length(AView.Bytes)]));
      end;
    finally
      details.Lines.EndUpdate;
    end;

    d.FOk := d.AddButton('OK', mrOk, True);
    d.AddButton('Cancel', mrCancel, False, True);
    d.FOk.Enabled := False;
    d.ApplyTheme;
    details.Color := clEditorBg;
    details.Font.Color := clEditorFg;
    StyleMemo(details);
    if d.FMemo <> nil then
    begin
      d.FMemo.Color := clEditorBg;
      d.FMemo.Font.Color := clEditorFg;
      StyleMemo(d.FMemo);
    end;
    if AEditable then d.InputChanged(nil);
    if (d.ShowModal = mrOk) and d.FNewValid then
    begin
      ANew := d.FNew;
      Result := True;
    end;
  finally
    d.Free;
  end;
end;

type
  TCertValueDialog = class(TRtDialog)
  private
    FValue: RawByteString;
    FDer: RawByteString;
    FAttr: string;
    FExportOwner: Pointer;
    FStatus: TLabel;
    procedure ExportTo(const AFilter, AExt: string; const AData: RawByteString);
    procedure DerClick(Sender: TObject);
    procedure PemClick(Sender: TObject);
  end;

procedure TCertValueDialog.ExportTo(const AFilter, AExt: string; const AData: RawByteString);
var
  sd: TSaveDialog;
begin
  sd := TSaveDialog.Create(Self);
  try
    sd.Filter := AFilter;
    sd.DefaultExt := AExt;
    sd.FileName := FAttr + '.' + AExt;
    sd.Options := sd.Options + [ofOverwritePrompt];
    if not sd.Execute then Exit;
    if StartValueSave(sd.FileName, AData, FExportOwner) = 0 then
      FStatus.Caption := rsCertExportBusy
    else
      FStatus.Caption := Format(rsCertExportStarted, [sd.FileName]);
  finally
    sd.Free;
  end;
end;

procedure TCertValueDialog.DerClick(Sender: TObject);
begin
  ExportTo('Certificate (*.cer)|*.cer|All files|*.*', 'cer', FDer);
end;

procedure TCertValueDialog.PemClick(Sender: TObject);
begin
  ExportTo('PEM certificate (*.pem)|*.pem|All files|*.*', 'pem', DerToPem(FDer));
end;

procedure ShowCertificateValue(AOwner: TComponent; const AEndpoint, ABadge, AAttr: string;
  const AValue: RawByteString; AExportOwner: Pointer);
var
  d: TCertValueDialog;
  memo: TMemo;
  bar: TPanel;
  rep: TCertValueReport;
  ders: TStringArray;
  err: string;
  i: Integer;
  bDer, bPem: TButton;
begin
  rep := InspectCertificateValue(AValue, UtcNow);
  d := TCertValueDialog.CreateDialog(AOwner, Format(rsCertValTitle, [AAttr]), 820, 600);
  d.SetIcon('certificate');
  try
    d.FValue := AValue;
    d.FAttr := AAttr;
    d.FExportOwner := AExportOwner;
    d.FDer := AValue;
    if rep.Decoded and (Pos('-----BEGIN CERTIFICATE-----', AValue) > 0) and
       ParseCertificates(AValue, ders, err) and (Length(ders) = 1) then
      d.FDer := ders[0];
    d.SetTarget(AEndpoint, ABadge);
    bar := MakePanel(d.Body, alTop, 38);
    bDer := MakeButton(bar, rsCertExportDer, @d.DerClick);
    bPem := MakeButton(bar, rsCertExportPem, @d.PemClick);
    bDer.Enabled := rep.Decoded;
    bPem.Enabled := rep.Decoded;
    d.FStatus := MakeLabel(d.Body, '', alBottom);
    memo := MakeMemo(d.Body);
    memo.ReadOnly := True;
    memo.ScrollBars := ssAutoVertical;
    memo.WordWrap := True;
    memo.Lines.BeginUpdate;
    try
      for i := 0 to High(rep.Lines) do
        memo.Lines.Add(rep.Lines[i]);
    finally
      memo.Lines.EndUpdate;
    end;
    d.AddButton('Close', mrOk, True, True);
    d.ApplyTheme;
    memo.Color := clEditorBg;
    memo.Font.Color := clEditorFg;
    StyleMemo(memo);
    d.ShowModal;
  finally
    d.Free;
  end;
end;

end.
