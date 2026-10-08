// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uProfileJson;

{$mode objfpc}{$H+}

// Profils <-> JSON versionne. Aucun secret ici, seulement la reference opaque
// SecretRef, et jamais dans un export portable. Un ancien profil sans champs TLS recoit
// les valeurs strictes: l'anciennete ne donne pas droit a l'indulgence.

interface

uses
  SysUtils, Classes, fpjson, uConnectionProfile;

const
  PROFILE_JSON_VERSION = 1;
  PORTABLE_EXPORT_FORMAT = 'rottentree-profiles';
  PORTABLE_EXPORT_VERSION = 1;
  PROFILE_JSON_MAX_BYTES = 1024 * 1024;

type
  EProfileJson = class(Exception);

function ProfileToJson(AProfile: TConnectionProfile; AIncludeSecretRef: Boolean): TJSONObject;
function ProfileToJsonText(AProfile: TConnectionProfile; AIncludeSecretRef: Boolean): string;
function ProfileFromJson(AObj: TJSONObject): TConnectionProfile;
function ProfileFromJsonText(const AText: string): TConnectionProfile;

function TransportToText(AMode: TTransportMode): string;
function TextToTransport(const S: string): TTransportMode;

implementation

uses
  jsonparser, uJsonGuard;

function TransportToText(AMode: TTransportMode): string;
begin
  case AMode of
    tmLdaps: Result := 'ldaps';
    tmPlain: Result := 'plain';
  else
    Result := 'starttls';
  end;
end;

function TextToTransport(const S: string): TTransportMode;
begin
  if S = 'ldaps' then Result := tmLdaps
  else if S = 'plain' then Result := tmPlain
  else if S = 'starttls' then Result := tmStartTls
  else
    raise EProfileJson.Create('unknown transport');
end;

function AuthToText(AMode: TAuthMode): string;
begin
  case AMode of
    amAnonymous: Result := 'anonymous';
    amSaslExternal: Result := 'sasl-external';
  else
    Result := 'simple';
  end;
end;

function TextToAuth(const S: string): TAuthMode;
begin
  if S = 'anonymous' then Result := amAnonymous
  else if S = 'sasl-external' then Result := amSaslExternal
  else if S = 'simple' then Result := amSimple
  else
    raise EProfileJson.Create('unknown authentication mode');
end;

function RevocationToText(A: TRevocationPolicy): string;
begin
  case A of
    rpChecked: Result := 'checked';
    rpRequired: Result := 'required';
  else
    Result := 'not-checked';
  end;
end;

function TextToRevocation(const S: string): TRevocationPolicy;
begin
  if S = 'checked' then Result := rpChecked
  else if S = 'required' then Result := rpRequired
  else Result := rpNotChecked;
end;

function ProviderToText(A: TProviderKind): string;
begin
  case A of
    pkOpenLdap: Result := 'openldap';
    pkActiveDirectory: Result := 'active-directory';
    pk389Ds: Result := '389ds';
    pkApacheDs: Result := 'apacheds';
    pkOther: Result := 'other';
  else
    Result := 'auto';
  end;
end;

function TextToProvider(const S: string): TProviderKind;
begin
  if S = 'openldap' then Result := pkOpenLdap
  else if S = 'active-directory' then Result := pkActiveDirectory
  else if S = '389ds' then Result := pk389Ds
  else if S = 'apacheds' then Result := pkApacheDs
  else if S = 'other' then Result := pkOther
  else Result := pkAuto;
end;

function StringsToArray(AList: TStrings): TJSONArray;
var
  i: Integer;
begin
  Result := TJSONArray.Create;
  for i := 0 to AList.Count - 1 do
    Result.Add(AList[i]);
end;

procedure ArrayToStrings(AObj: TJSONObject; const AName: string; AList: TStrings);
var
  arr: TJSONArray;
  i: Integer;
begin
  AList.Clear;
  if AObj.IndexOfName(AName) < 0 then Exit;
  if not (AObj.Elements[AName] is TJSONArray) then
    raise EProfileJson.CreateFmt('"%s" must be an array', [AName]);
  arr := TJSONArray(AObj.Elements[AName]);
  if arr.Count > 10000 then
    raise EProfileJson.CreateFmt('"%s" is too long', [AName]);
  for i := 0 to arr.Count - 1 do
  begin
    if arr.Types[i] <> jtString then
      raise EProfileJson.CreateFmt('"%s" must contain strings', [AName]);
    AList.Add(arr.Strings[i]);
  end;
end;

function ProfileToJson(AProfile: TConnectionProfile; AIncludeSecretRef: Boolean): TJSONObject;
var
  tls: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('version', PROFILE_JSON_VERSION);
  Result.Add('uuid', AProfile.Uuid);
  Result.Add('name', AProfile.Name);
  Result.Add('description', AProfile.Description);
  Result.Add('icon', AProfile.IconId);
  Result.Add('badge', AProfile.EnvironmentBadge);
  Result.Add('host', AProfile.Host);
  Result.Add('port', AProfile.Port);
  Result.Add('transport', TransportToText(AProfile.Transport));
  Result.Add('auth', AuthToText(AProfile.AuthMode));
  Result.Add('bindDn', AProfile.BindDn);
  Result.Add('appendBaseDn', AProfile.AppendBaseDn);
  Result.Add('authzId', AProfile.AuthzId);
  if AIncludeSecretRef then
    Result.Add('secretRef', AProfile.SecretRef);
  Result.Add('allowPlainSecrets', AProfile.AllowPlainSecrets);
  tls := TJSONObject.Create;
  tls.Add('verifyCAChain', AProfile.Tls.VerifyCAChain);
  tls.Add('verifyValidityDates', AProfile.Tls.VerifyValidityDates);
  tls.Add('verifyHostname', AProfile.Tls.VerifyHostname);
  tls.Add('revocation', RevocationToText(AProfile.Revocation));
  tls.Add('trustedCaDer', StringsToArray(AProfile.TrustedCaDer));
  tls.Add('pinnedSha256', StringsToArray(AProfile.PinnedSha256));
  tls.Add('clientCertPath', AProfile.ClientCertPath);
  tls.Add('clientKeyPath', AProfile.ClientKeyPath);
  Result.Add('tls', tls);
  Result.Add('baseDns', StringsToArray(AProfile.BaseDns));
  Result.Add('showServerConfig', AProfile.ShowServerConfig);
  if AProfile.ReferralPolicy = rfAllowedDestinations then
    Result.Add('referrals', 'allowed-destinations')
  else
    Result.Add('referrals', 'disabled');
  Result.Add('referralDestinations', StringsToArray(AProfile.ReferralDestinations));
  Result.Add('derefAliases', AProfile.DerefAliases);
  Result.Add('connectTimeoutSec', AProfile.ConnectTimeoutSec);
  Result.Add('tlsTimeoutSec', AProfile.TlsTimeoutSec);
  Result.Add('operationTimeoutSec', AProfile.OperationTimeoutSec);
  Result.Add('keepAliveSec', AProfile.KeepAliveSec);
  Result.Add('pageSize', AProfile.PageSize);
  Result.Add('sizeLimit', AProfile.SizeLimit);
  Result.Add('readOnly', AProfile.ReadOnly);
  Result.Add('autoReconnect', AProfile.AutoReconnect);
  Result.Add('provider', ProviderToText(AProfile.Provider));
  Result.Add('showOperationalAttributes', AProfile.ShowOperationalAttrs);
end;

function ProfileToJsonText(AProfile: TConnectionProfile; AIncludeSecretRef: Boolean): string;
var
  o: TJSONObject;
begin
  o := ProfileToJson(AProfile, AIncludeSecretRef);
  try
    Result := o.AsJSON;
  finally
    o.Free;
  end;
end;

function GetStr(AObj: TJSONObject; const AName, ADefault: string): string;
begin
  if AObj.IndexOfName(AName) < 0 then Exit(ADefault);
  if AObj.Types[AName] <> jtString then
    raise EProfileJson.CreateFmt('"%s" must be a string', [AName]);
  Result := AObj.Strings[AName];
end;

function GetInt(AObj: TJSONObject; const AName: string; ADefault, AMin, AMax: Integer): Integer;
begin
  if AObj.IndexOfName(AName) < 0 then Exit(ADefault);
  if AObj.Types[AName] <> jtNumber then
    raise EProfileJson.CreateFmt('"%s" must be a number', [AName]);
  Result := AObj.Integers[AName];
  if (Result < AMin) or (Result > AMax) then
    raise EProfileJson.CreateFmt('"%s" is out of range', [AName]);
end;

function GetBool(AObj: TJSONObject; const AName: string; ADefault: Boolean): Boolean;
begin
  if AObj.IndexOfName(AName) < 0 then Exit(ADefault);
  if AObj.Types[AName] <> jtBoolean then
    raise EProfileJson.CreateFmt('"%s" must be a boolean', [AName]);
  Result := AObj.Booleans[AName];
end;

function ProfileFromJson(AObj: TJSONObject): TConnectionProfile;
var
  version: Integer;
  tls: TJSONObject;
begin
  version := GetInt(AObj, 'version', 0, 0, MaxInt);
  if version > PROFILE_JSON_VERSION then
    raise EProfileJson.CreateFmt('profile format %d is newer than this version supports', [version]);
  Result := TConnectionProfile.Create;
  try
    Result.Uuid := GetStr(AObj, 'uuid', '');
    Result.Name := GetStr(AObj, 'name', '');
    Result.Description := GetStr(AObj, 'description', '');
    Result.IconId := GetStr(AObj, 'icon', '');
    Result.EnvironmentBadge := GetStr(AObj, 'badge', '');
    Result.Host := GetStr(AObj, 'host', '');
    Result.Transport := TextToTransport(GetStr(AObj, 'transport', 'starttls'));
    Result.Port := GetInt(AObj, 'port', DefaultPortFor(Result.Transport), 0, 65535);
    Result.AuthMode := TextToAuth(GetStr(AObj, 'auth', 'simple'));
    Result.BindDn := GetStr(AObj, 'bindDn', '');
    Result.AppendBaseDn := GetBool(AObj, 'appendBaseDn', False);
    Result.AuthzId := GetStr(AObj, 'authzId', '');
    Result.SecretRef := GetStr(AObj, 'secretRef', '');
    Result.AllowPlainSecrets := GetBool(AObj, 'allowPlainSecrets', False);
    // Champs absents (ancien format): exceptions TLS au plus strict.
    Result.Tls := StrictTlsExceptions;
    if AObj.IndexOfName('tls') >= 0 then
    begin
      if not (AObj.Elements['tls'] is TJSONObject) then
        raise EProfileJson.Create('"tls" must be an object');
      tls := TJSONObject(AObj.Elements['tls']);
      Result.Tls.VerifyCAChain := GetBool(tls, 'verifyCAChain', True);
      Result.Tls.VerifyValidityDates := GetBool(tls, 'verifyValidityDates', True);
      Result.Tls.VerifyHostname := GetBool(tls, 'verifyHostname', True);
      Result.Revocation := TextToRevocation(GetStr(tls, 'revocation', 'not-checked'));
      ArrayToStrings(tls, 'trustedCaDer', Result.TrustedCaDer);
      ArrayToStrings(tls, 'pinnedSha256', Result.PinnedSha256);
      Result.ClientCertPath := GetStr(tls, 'clientCertPath', '');
      Result.ClientKeyPath := GetStr(tls, 'clientKeyPath', '');
    end;
    ArrayToStrings(AObj, 'baseDns', Result.BaseDns);
    Result.ShowServerConfig := GetBool(AObj, 'showServerConfig', True);
    if GetStr(AObj, 'referrals', 'disabled') = 'allowed-destinations' then
      Result.ReferralPolicy := rfAllowedDestinations
    else
      Result.ReferralPolicy := rfDisabled;
    ArrayToStrings(AObj, 'referralDestinations', Result.ReferralDestinations);
    Result.DerefAliases := GetInt(AObj, 'derefAliases', 0, 0, 3);
    Result.ConnectTimeoutSec := GetInt(AObj, 'connectTimeoutSec', 10, 1, 600);
    Result.TlsTimeoutSec := GetInt(AObj, 'tlsTimeoutSec', 10, 1, 600);
    Result.OperationTimeoutSec := GetInt(AObj, 'operationTimeoutSec', 30, 1, 3600);
    Result.KeepAliveSec := GetInt(AObj, 'keepAliveSec', 60, 0, 3600);
    Result.PageSize := GetInt(AObj, 'pageSize', 500, 0, 100000);
    Result.SizeLimit := GetInt(AObj, 'sizeLimit', 10000, 0, MaxInt);
    // Absent = lecture seule: dans le doute, on ne donne pas les cles.
    Result.ReadOnly := GetBool(AObj, 'readOnly', True);
    Result.AutoReconnect := GetBool(AObj, 'autoReconnect', False);
    Result.Provider := TextToProvider(GetStr(AObj, 'provider', 'auto'));
    Result.ShowOperationalAttrs := GetBool(AObj, 'showOperationalAttributes', False);
  except
    Result.Free;
    raise;
  end;
end;

function ProfileFromJsonText(const AText: string): TConnectionProfile;
var
  data: TJSONData;
begin
  if Length(AText) > PROFILE_JSON_MAX_BYTES then
    raise EProfileJson.Create('profile too large');
  if JsonNestingTooDeep(AText) then
    raise EProfileJson.Create('profile nested too deeply');
  try
    data := GetJSON(AText);
  except
    on E: Exception do
      raise EProfileJson.Create('invalid profile JSON');
  end;
  try
    if not (data is TJSONObject) then
      raise EProfileJson.Create('profile must be a JSON object');
    Result := ProfileFromJson(TJSONObject(data));
  finally
    data.Free;
  end;
end;

end.
