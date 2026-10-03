// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uConnectFlow;

{$mode objfpc}{$H+}

// Preparation d'une connexion: secret lu dans le document chiffre, sinon demande une fois a
// l'utilisateur, sans nouvel essai automatique. Avertissement avant d'envoyer un secret en clair.

interface

uses
  SysUtils, uConnectionProfile, uRtDocument;

type
  TAskSecretFunc = function(AProfile: TConnectionProfile; out ASecret: RawByteString): Boolean of object;

// L'appelant efface ASecret apres usage.
function ResolveBindSecret(ADoc: TRtDocument; AProfile: TConnectionProfile;
  AAsk: TAskSecretFunc; out ASecret: RawByteString): Boolean;
function NeedsPlainSecretConfirmation(AProfile: TConnectionProfile): Boolean;

implementation

uses
  uSecureBytes;

function ResolveBindSecret(ADoc: TRtDocument; AProfile: TConnectionProfile;
  AAsk: TAskSecretFunc; out ASecret: RawByteString): Boolean;
var
  sec: TSecureBytes;
begin
  ASecret := '';
  Result := True;
  if AProfile.AuthMode <> amSimple then Exit;
  sec := nil;
  if (AProfile.SecretRef <> '') and (ADoc <> nil) then
    sec := ADoc.LoadSecret(AProfile.SecretRef);
  if sec <> nil then
  begin
    try
      SetLength(ASecret, sec.Len);
      if sec.Len > 0 then Move(sec.Data^, ASecret[1], sec.Len);
    finally
      sec.Free;
    end;
    Exit;
  end;
  Result := Assigned(AAsk) and AAsk(AProfile, ASecret);
  if not Result then ASecret := '';
end;

function NeedsPlainSecretConfirmation(AProfile: TConnectionProfile): Boolean;
begin
  Result := (AProfile.Transport = tmPlain) and (AProfile.AuthMode <> amAnonymous);
end;

end.
