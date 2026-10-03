// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAboutDialog;

{$mode objfpc}{$H+}

// A propos: version, licence, versions des bibliotheques natives vraiment chargees, etat des fontes.
// Les licences viennent des ressources du binaire: pas besoin de reseau pour lire ce qu'on doit a qui.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs;

procedure ShowAbout(AOwner: TComponent);
procedure ShowLicenses(AOwner: TComponent);

implementation

uses
  LCLType, uTheme, uUiKit, uVersion, uFontEmbed, uComponentInfo, uPreferences;

resourcestring
  rsAboutTitle = 'About %s';
  rsLicensesTitle = 'Licenses';
  rsAboutLicense = 'Distributed under the GNU General Public License version 3 or later ' +
    '(GPL-3.0-or-later). Third-party components keep their own licenses: see Help > Licenses.';
  rsAboutSource = 'The corresponding source code of each release is published with the release archive.';
  rsAboutComponents = 'Native components loaded in this session:';
  rsAboutNotLoaded = '(not loaded yet)';
  rsAboutFonts = 'Embedded fonts available: %s';

const
  LICENSE_RESOURCES: array[0..11] of string = (
    'LICENSE_GPL_3_0_OR_LATER', 'LICENSE_THIRD_PARTY_NOTICES', 'LICENSE_OPENLDAP_PUBLIC_LICENSE_2_8',
    'LICENSE_OPENSSL_APACHE_2_0', 'LICENSE_CYRUS_SASL_BSD_ATTRIBUTION', 'LICENSE_LIBSODIUM_ISC',
    'LICENSE_SQLITE_PUBLIC_DOMAIN', 'LICENSE_ARGON2_CC0_OR_APACHE_2_0', 'LICENSE_MONASPACE_OFL_1_1',
    'LICENSE_JETBRAINSMONO_OFL_1_1', 'LICENSE_TABLER_MIT', 'LICENSE_FPC_LCL_MODIFIED_LGPL');

function ResourceText(const AName: string): string;
var
  rs: TResourceStream;
begin
  Result := '';
  try
    rs := TResourceStream.Create(HInstance, AName, RT_RCDATA);
    try
      SetLength(Result, rs.Size);
      if rs.Size > 0 then rs.ReadBuffer(Result[1], rs.Size);
    finally
      rs.Free;
    end;
  except
    Result := '';
  end;
end;

procedure ShowAbout(AOwner: TComponent);
var
  d: TRtDialog;
  memo: TMemo;
  i: Integer;
  libs: TComponentVersions;
  fams: string;
begin
  libs := LoadedComponentVersions;
  d := TRtDialog.CreateDialog(AOwner, Format(rsAboutTitle, [RT_APP_NAME]), 700, 520);
  d.SetIcon('info-circle');
  try
    MakeLabel(d.Body, RT_APP_NAME + ' ' + RT_VERSION).Font.Size := 14;
    MakeLabel(d.Body, RT_SLOGAN);
    MakeLabel(d.Body, RT_COPYRIGHT);
    MakeLabel(d.Body, rsAboutLicense);
    MakeLabel(d.Body, rsAboutSource);
    MakeLabel(d.Body, rsAboutComponents);
    memo := MakeMemo(d.Body);
    memo.ReadOnly := True;
    for i := 0 to High(libs) do
      memo.Lines.Add(Format('%s  %s  (%s)', [libs[i].Name, libs[i].Version, libs[i].Path]));
    if Length(libs) = 0 then memo.Lines.Add(rsAboutNotLoaded);
    memo.Lines.Add(Format('Lazarus LCL, Free Pascal %s', [{$I %FPCVERSION%}]));
    fams := '';
    for i := 0 to MonaspaceFamilyCount - 1 do
      if ResolveMonaspace(MonaspaceFamilyKey(i)) <> '' then
        fams := fams + MonaspaceFamilyLabel(i) + '; ';
    if fams = '' then fams := 'none (system font fallback)';
    memo.Lines.Add(Format(rsAboutFonts, [fams]));
    d.AddButton('Close', mrOk, True, True);
    d.ApplyTheme;
    d.ShowModal;
  finally
    d.Free;
  end;
end;

type
  TLicenseViewer = class(TRtDialog)
  public
    List: TListBox;
    Viewer: TMemo;
    procedure ListClick(Sender: TObject);
  end;

procedure TLicenseViewer.ListClick(Sender: TObject);
begin
  if List.ItemIndex < 0 then Exit;
  Viewer.Text := ResourceText(LICENSE_RESOURCES[List.ItemIndex]);
end;

procedure ShowLicenses(AOwner: TComponent);
var
  d: TLicenseViewer;
  left: TPanel;
  i: Integer;
begin
  d := TLicenseViewer.CreateDialog(AOwner, rsLicensesTitle, 980, 680);
  d.SetIcon('file-text');
  try
    left := MakePanel(d.Body, alLeft, 300);
    d.List := TListBox.Create(left);
    d.List.Parent := left;
    d.List.Align := alClient;
    d.List.OnClick := @d.ListClick;
    for i := 0 to High(LICENSE_RESOURCES) do
      d.List.Items.Add(StringReplace(Copy(LICENSE_RESOURCES[i], 9, MaxInt), '_', ' ', [rfReplaceAll]));
    d.Viewer := MakeMemo(d.Body);
    d.Viewer.ReadOnly := True;
    d.List.ItemIndex := 0;
    d.ListClick(nil);
    d.AddButton('Close', mrOk, True, True);
    d.ApplyTheme;
    d.ShowModal;
  finally
    d.Free;
  end;
end;

end.
