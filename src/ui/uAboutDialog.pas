// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAboutDialog;

{$mode objfpc}{$H+}

// A propos: version, licence, versions des bibliotheques natives vraiment chargees, etat des fontes.
// Les licences viennent des ressources du binaire: pas besoin de reseau pour lire ce qu'on doit a qui.

interface

uses
  Classes, SysUtils;

procedure ShowAbout(AOwner: TComponent);
procedure ShowLicenses(AOwner: TComponent);

implementation

uses
  uRtAbout, uVersion, uFontEmbed, uComponentInfo;

resourcestring
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

procedure ShowAbout(AOwner: TComponent);
var
  d: TRtAboutDialog;
  lines: TStrings;
  i: Integer;
  libs: TComponentVersions;
  fams: string;
begin
  libs := LoadedComponentVersions;
  d := TRtAboutDialog.CreateAbout(AOwner, RT_APP_NAME, RT_VERSION);
  try
    d.AddLine(RT_SLOGAN);
    d.AddLine(RT_COPYRIGHT);
    d.AddLine(rsAboutLicense);
    d.AddLine(rsAboutSource);
    lines := d.AddDetails(rsAboutComponents);
    for i := 0 to High(libs) do
      lines.Add(Format('%s  %s  (%s)', [libs[i].Name, libs[i].Version, libs[i].Path]));
    if Length(libs) = 0 then lines.Add(rsAboutNotLoaded);
    lines.Add(Format('Lazarus LCL, Free Pascal %s', [{$I %FPCVERSION%}]));
    fams := '';
    for i := 0 to MonaspaceFamilyCount - 1 do
      if ResolveMonaspace(MonaspaceFamilyKey(i)) <> '' then
        fams := fams + MonaspaceFamilyLabel(i) + '; ';
    if fams = '' then fams := 'none (system font fallback)';
    lines.Add(Format(rsAboutFonts, [fams]));
    d.Execute;
  finally
    d.Free;
  end;
end;

procedure ShowLicenses(AOwner: TComponent);
var
  captions: array[0..High(LICENSE_RESOURCES)] of string;
  i: Integer;
begin
  // LICENSE_OPENSSL_APACHE_2_0 se lit "OPENSSL APACHE 2 0": le nom de ressource fait le titre
  for i := 0 to High(LICENSE_RESOURCES) do
    captions[i] := StringReplace(Copy(LICENSE_RESOURCES[i], 9, MaxInt), '_', ' ', [rfReplaceAll]);
  RtShowLicenses(AOwner, '', captions, LICENSE_RESOURCES);
end;

end.
