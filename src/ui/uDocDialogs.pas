// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDocDialogs;

{$mode objfpc}{$H+}

// Saisie masquee des mots de passe (document chiffre, secrets LDAP). Pas d'historique
// de saisie, controle vide a la fermeture; la copie rendue est a effacer par l'appelant.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, uUiKit, uRtCheck;

resourcestring
  rsNewDocTitle = 'Create a new document';
  rsNewDocIntro = 'Choose a password to protect the new document %s. It encrypts the connection ' +
    'profiles and remembered secrets.';
  rsNewDocButton = 'Create document';
  rsChangePwTitle = 'Change the document password';
  rsChangePwIntro = 'Choose a new password for %s. The document is saved right away; from then ' +
    'on, only the new password opens it.';
  rsChangePwButton = 'Change password';
  rsNoRecovery = 'Rottentree cannot recover a forgotten password: keep it somewhere safe.';
  rsNewPassword = 'New password';
  rsRepeatPassword = 'Repeat it';
  rsMinLength = 'At least 8 characters.';
  rsOpenDocTitle = 'Open document';
  rsUnlockTitle = 'Unlock document';
  rsPassword = 'Password';
  rsConfirm = 'Confirm';
  rsOk = 'OK';
  rsCancel = 'Cancel';
  rsMismatch = 'The two passwords differ.';
  rsTooShort = 'Use at least 8 characters.';
  rsSecretTitle = 'Password for %s';
  rsRememberSecret = 'Remember this password in the encrypted document';
  rsShow = 'Show';

function AskNewDocumentPassword(AOwner: TComponent; const AFileName: string; AChange: Boolean;
  out APassword: RawByteString): Boolean;
function AskDocumentPassword(AOwner: TComponent; const AFileName: string; AUnlock: Boolean;
  out APassword: RawByteString): Boolean;
function AskBindSecret(AOwner: TComponent; const AServer, ABadge, AIdentity: string;
  AOfferRemember: Boolean; out ASecret: RawByteString; out ARemember: Boolean): Boolean;

implementation

uses
  Dialogs, uTheme;

type
  TPasswordDialog = class(TRtDialog)
  public
    Edit1, Edit2: TEdit;
    Info: TLabel;
    Remember: TRtCheckBox;
    Confirm: Boolean;
    procedure ShowClick(Sender: TObject);
    procedure OkClick(Sender: TObject);
    procedure CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
  end;

procedure TPasswordDialog.ShowClick(Sender: TObject);
begin
  if TRtCheckBox(Sender).Checked then
  begin
    Edit1.PasswordChar := #0;
    if Edit2 <> nil then Edit2.PasswordChar := #0;
  end
  else
  begin
    Edit1.PasswordChar := '*';
    if Edit2 <> nil then Edit2.PasswordChar := '*';
  end;
end;

procedure TPasswordDialog.OkClick(Sender: TObject);
begin
  ModalResult := mrOk;
end;

procedure TPasswordDialog.CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
begin
  if (ModalResult <> mrOk) or not Confirm then Exit;
  if Edit1.Text <> Edit2.Text then
  begin
    Info.Caption := rsMismatch;
    Info.Font.Color := DialogStateColor(usError);
    CanClose := False;
  end
  else if Length(Edit1.Text) < 8 then
  begin
    Info.Caption := rsTooShort;
    Info.Font.Color := DialogStateColor(usError);
    CanClose := False;
  end;
end;

function MakePasswordEdit(AParent: TWinControl; const ACaption: string): TEdit;
var
  row: TPanel;
begin
  row := MakeFieldRow(AParent, ACaption, 110);
  Result := TEdit.Create(row);
  Result.Parent := row;
  Result.Align := alClient;
  Result.BorderSpacing.Around := 3;
  Result.PasswordChar := '*';
  Result.AutoSelect := False;
end;

procedure WipeEdit(AEdit: TEdit);
begin
  if AEdit = nil then Exit;
  // Le widget natif peut garder sa propre copie du texte, hors de notre portee.
  // On ecrase ce qu'on peut et on n'en dit pas plus qu'on n'en sait.
  AEdit.Text := StringOfChar(' ', Length(AEdit.Text));
  AEdit.Text := '';
end;

function RunPassword(ADlg: TPasswordDialog; out APassword: RawByteString): Boolean;
begin
  ADlg.OnCloseQuery := @ADlg.CloseQueryHandler;
  ADlg.ApplyTheme;
  ADlg.ActiveControl := ADlg.Edit1;
  Result := ADlg.ShowModal = mrOk;
  if Result then
    APassword := ADlg.Edit1.Text
  else
    APassword := '';
  WipeEdit(ADlg.Edit1);
  WipeEdit(ADlg.Edit2);
end;

function AskNewDocumentPassword(AOwner: TComponent; const AFileName: string; AChange: Boolean;
  out APassword: RawByteString): Boolean;
var
  d: TPasswordDialog;
  show: TRtCheckBox;
  intro: TLabel;
  name: string;
begin
  name := ExtractFileName(AFileName);
  if AChange then
    d := TPasswordDialog.CreateDialog(AOwner, rsChangePwTitle, 520, 300)
  else
    d := TPasswordDialog.CreateDialog(AOwner, rsNewDocTitle, 520, 300);
  d.SetIcon('lock');
  try
    d.Confirm := True;
    if AChange then
      intro := MakeLabel(d.Body, Format(rsChangePwIntro, [name]))
    else
      intro := MakeLabel(d.Body, Format(rsNewDocIntro, [name]));
    intro.WordWrap := True;
    MakeLabel(d.Body, rsNoRecovery).Font.Color := DialogStateColor(usWarning);
    d.Edit1 := MakePasswordEdit(d.Body, rsNewPassword);
    d.Edit2 := MakePasswordEdit(d.Body, rsRepeatPassword);
    show := MakeCheck(d.Body, rsShow);
    show.OnClick := @d.ShowClick;
    d.Info := MakeLabel(d.Body, rsMinLength);
    d.Info.Font.Color := DialogStateColor(usMuted);
    if AChange then
      d.AddButton(rsChangePwButton, mrOk, True)
    else
      d.AddButton(rsNewDocButton, mrOk, True);
    d.AddButton(rsCancel, mrCancel, False, True);
    Result := RunPassword(d, APassword);
  finally
    d.Free;
  end;
end;

function AskDocumentPassword(AOwner: TComponent; const AFileName: string; AUnlock: Boolean;
  out APassword: RawByteString): Boolean;
var
  d: TPasswordDialog;
  title: string;
begin
  if AUnlock then title := rsUnlockTitle else title := rsOpenDocTitle;
  d := TPasswordDialog.CreateDialog(AOwner, title, 460, 180);
  d.SetIcon('lock');
  try
    MakeLabel(d.Body, AFileName);
    d.Edit1 := MakePasswordEdit(d.Body, rsPassword);
    d.Info := MakeLabel(d.Body, '');
    d.AddButton(rsOk, mrOk, True);
    d.AddButton(rsCancel, mrCancel, False, True);
    Result := RunPassword(d, APassword);
  finally
    d.Free;
  end;
end;

function AskBindSecret(AOwner: TComponent; const AServer, ABadge, AIdentity: string;
  AOfferRemember: Boolean; out ASecret: RawByteString; out ARemember: Boolean): Boolean;
var
  d: TPasswordDialog;
begin
  d := TPasswordDialog.CreateDialog(AOwner, Format(rsSecretTitle, [AIdentity]), 520, 200);
  d.SetIcon('key');
  try
    d.SetTarget(AServer, ABadge);
    MakeLabel(d.Body, AIdentity);
    d.Edit1 := MakePasswordEdit(d.Body, rsPassword);
    if AOfferRemember then
      d.Remember := MakeCheck(d.Body, rsRememberSecret);
    d.Info := MakeLabel(d.Body, '');
    d.AddButton(rsOk, mrOk, True);
    d.AddButton(rsCancel, mrCancel, False, True);
    Result := RunPassword(d, ASecret);
    ARemember := Result and (d.Remember <> nil) and d.Remember.Checked;
  finally
    d.Free;
  end;
end;

end.
