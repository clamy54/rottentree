// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDocDialogs;

{$mode objfpc}{$H+}

// Mots de passe du document et secrets de bind, sur le dialogue du kit: champ masque a la
// main, vide a la fermeture. La copie rendue est a effacer par l'appelant.

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
  uRtPassword;

type
  TDocPasswordDialog = class(TRtPasswordDialog)
  public
    procedure CheckLength(Sender: TObject; const ASecret: RawByteString; var ARefusal: string);
  end;

procedure TDocPasswordDialog.CheckLength(Sender: TObject; const ASecret: RawByteString;
  var ARefusal: string);
begin
  if Length(ASecret) < 8 then ARefusal := rsTooShort;
end;

function AskNewDocumentPassword(AOwner: TComponent; const AFileName: string; AChange: Boolean;
  out APassword: RawByteString): Boolean;
var
  d: TDocPasswordDialog;
  name: string;
begin
  name := ExtractFileName(AFileName);
  if AChange then
    d := TDocPasswordDialog.CreateDialog(AOwner, rsChangePwTitle, 520, 300)
  else
    d := TDocPasswordDialog.CreateDialog(AOwner, rsNewDocTitle, 520, 300);
  d.SetIcon('lock');
  try
    if AChange then
      d.AddText(Format(rsChangePwIntro, [name]))
    else
      d.AddText(Format(rsNewDocIntro, [name]));
    d.AddText(rsNoRecovery).Font.Color := DialogStateColor(usWarning);
    d.AddField(rsNewPassword);
    d.AddConfirm(rsRepeatPassword);
    d.AddReveal(rsShow);
    d.AddStatus(rsMinLength);
    d.MismatchText := rsMismatch;
    d.OnValidate := @d.CheckLength;
    if AChange then
      d.AddButton(rsChangePwButton, mrOk, True)
    else
      d.AddButton(rsNewDocButton, mrOk, True);
    d.AddButton(rsCancel, mrCancel, False, True);
    Result := d.Execute(APassword);
  finally
    d.Free;
  end;
end;

function AskDocumentPassword(AOwner: TComponent; const AFileName: string; AUnlock: Boolean;
  out APassword: RawByteString): Boolean;
var
  d: TRtPasswordDialog;
  title: string;
begin
  if AUnlock then title := rsUnlockTitle else title := rsOpenDocTitle;
  d := TRtPasswordDialog.CreateDialog(AOwner, title, 460, 180);
  d.SetIcon('lock');
  try
    d.AddText(AFileName);
    d.AddField(rsPassword);
    d.AddStatus;
    d.AddButton(rsOk, mrOk, True);
    d.AddButton(rsCancel, mrCancel, False, True);
    Result := d.Execute(APassword);
  finally
    d.Free;
  end;
end;

function AskBindSecret(AOwner: TComponent; const AServer, ABadge, AIdentity: string;
  AOfferRemember: Boolean; out ASecret: RawByteString; out ARemember: Boolean): Boolean;
var
  d: TRtPasswordDialog;
  remember: TRtCheckBox;
begin
  d := TRtPasswordDialog.CreateDialog(AOwner, Format(rsSecretTitle, [AIdentity]), 520, 200);
  d.SetIcon('key');
  try
    d.SetTarget(AServer, ABadge);
    d.AddText(AIdentity);
    d.AddField(rsPassword);
    remember := nil;
    if AOfferRemember then
      remember := MakeCheck(d.Body, rsRememberSecret);
    d.AddStatus;
    d.AddButton(rsOk, mrOk, True);
    d.AddButton(rsCancel, mrCancel, False, True);
    Result := d.Execute(ASecret);
    ARemember := Result and (remember <> nil) and remember.Checked;
  finally
    d.Free;
  end;
end;

end.
