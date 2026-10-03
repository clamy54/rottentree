// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uConnectionProfile;

{$mode objfpc}{$H+}

// Profils de connexion et leur validation avant le moindre paquet. Le mot de
// passe n'est jamais dans le profil ni dans une URL, seulement sa reference. Les
// exceptions TLS retombent au strict a chaque changement d'hote ou de port.

interface

uses
  SysUtils, Classes;

const
  PROFILE_FORMAT_VERSION = 1;
  DEFAULT_LDAP_PORT = 389;
  DEFAULT_LDAPS_PORT = 636;
  AD_GC_PORT = 3268;
  AD_GC_SSL_PORT = 3269;
  PROFILE_TAG_MAX_CHARS = 16;

type
  TTransportMode = (tmStartTls, tmLdaps, tmPlain);
  TAuthMode = (amAnonymous, amSimple, amSaslExternal);
  TRevocationPolicy = (rpNotChecked, rpChecked, rpRequired);
  TReferralPolicy = (rfDisabled, rfAllowedDestinations);
  TProviderKind = (pkAuto, pkOpenLdap, pkActiveDirectory, pk389Ds, pkApacheDs, pkOther);

  TTlsExceptions = record
    VerifyCAChain: Boolean;
    VerifyValidityDates: Boolean;
    VerifyHostname: Boolean;
  end;

  TConnectionProfile = class
  public
    Uuid: string;
    FolderUuid: string;
    Name: string;
    Description: string;
    IconId: string;
    EnvironmentBadge: string;
    Host: string;
    Port: Integer;
    Transport: TTransportMode;
    AuthMode: TAuthMode;
    BindDn: string;
    AppendBaseDn: Boolean;
    AuthzId: string;
    SecretRef: string;
    AllowPlainSecrets: Boolean;
    Tls: TTlsExceptions;
    Revocation: TRevocationPolicy;
    TrustedCaDer: TStringList;
    PinnedSha256: TStringList;
    ClientCertPath: string;
    ClientKeyPath: string;
    BaseDns: TStringList;
    ShowServerConfig: Boolean;
    ReferralPolicy: TReferralPolicy;
    ReferralDestinations: TStringList;
    DerefAliases: Integer;
    ConnectTimeoutSec: Integer;
    TlsTimeoutSec: Integer;
    OperationTimeoutSec: Integer;
    PageSize: Integer;
    SizeLimit: Integer;
    ReadOnly: Boolean;
    AutoReconnect: Boolean;
    Provider: TProviderKind;
    ShowOperationalAttrs: Boolean;
    LdifPath: string;
    constructor Create;
    destructor Destroy; override;
    procedure Assign(ASource: TConnectionProfile);
    procedure SetEndpoint(const AHost: string; APort: Integer; AKeepTlsExceptions: Boolean = False);
    // Un double n'herite ni du secret ni des exceptions TLS, sauf demande explicite.
    function Duplicate(AKeepSecretRef, AKeepTlsExceptions: Boolean): TConnectionProfile;
    function DisplayEndpoint: string;
  end;

  TProfileIssueLevel = (pilError, pilWarning);

  TProfileIssue = record
    Level: TProfileIssueLevel;
    Field: string;
    Message: string;
  end;
  TProfileIssues = array of TProfileIssue;

function StrictTlsExceptions: TTlsExceptions;
function TlsExceptionsAreStrict(const E: TTlsExceptions): Boolean;
function DefaultPortFor(AMode: TTransportMode): Integer;
function TransportLabel(AMode: TTransportMode): string;
function ValidateProfile(AProfile: TConnectionProfile): TProfileIssues;
function HasBlockingIssue(const AIssues: TProfileIssues): Boolean;
// Refuse avant tout paquet: un DN avec un mot de passe vide, c'est un bind anonyme
// que le serveur accepte souvent et qui a tout l'air d'un succes (RFC 4513 5.1.2).
function SimpleBindCredentialsAcceptable(const ABindDn: string; ASecretLength: Integer;
  out AReason: string): Boolean;
function EffectiveBindDn(AProfile: TConnectionProfile): string;
function IsValidHostName(const AHost: string): Boolean;
function IsIpLiteral(const AHost: string): Boolean;
function BuildLdapUri(AProfile: TConnectionProfile): string;

implementation

uses
  uLdapDn;

function StrictTlsExceptions: TTlsExceptions;
begin
  Result.VerifyCAChain := True;
  Result.VerifyValidityDates := True;
  Result.VerifyHostname := True;
end;

function TlsExceptionsAreStrict(const E: TTlsExceptions): Boolean;
begin
  Result := E.VerifyCAChain and E.VerifyValidityDates and E.VerifyHostname;
end;

function DefaultPortFor(AMode: TTransportMode): Integer;
begin
  if AMode = tmLdaps then
    Result := DEFAULT_LDAPS_PORT
  else
    Result := DEFAULT_LDAP_PORT;
end;

function TransportLabel(AMode: TTransportMode): string;
begin
  case AMode of
    tmStartTls: Result := 'LDAP - StartTLS';
    tmLdaps: Result := 'LDAPS - TLS/SSL';
  else
    Result := 'LDAP - unencrypted';
  end;
end;

constructor TConnectionProfile.Create;
begin
  inherited Create;
  TrustedCaDer := TStringList.Create;
  PinnedSha256 := TStringList.Create;
  BaseDns := TStringList.Create;
  ReferralDestinations := TStringList.Create;
  Transport := tmStartTls;
  Port := DEFAULT_LDAP_PORT;
  AuthMode := amAnonymous;
  Tls := StrictTlsExceptions;
  Revocation := rpNotChecked;
  ReferralPolicy := rfDisabled;
  ShowServerConfig := True;
  DerefAliases := 0;
  ConnectTimeoutSec := 10;
  TlsTimeoutSec := 10;
  OperationTimeoutSec := 30;
  PageSize := 500;
  SizeLimit := 10000;
  ReadOnly := True;
  AutoReconnect := False;
  Provider := pkAuto;
end;

destructor TConnectionProfile.Destroy;
begin
  TrustedCaDer.Free;
  PinnedSha256.Free;
  BaseDns.Free;
  ReferralDestinations.Free;
  inherited Destroy;
end;

procedure TConnectionProfile.Assign(ASource: TConnectionProfile);
begin
  Uuid := ASource.Uuid;
  FolderUuid := ASource.FolderUuid;
  Name := ASource.Name;
  Description := ASource.Description;
  IconId := ASource.IconId;
  EnvironmentBadge := ASource.EnvironmentBadge;
  Host := ASource.Host;
  Port := ASource.Port;
  Transport := ASource.Transport;
  AuthMode := ASource.AuthMode;
  BindDn := ASource.BindDn;
  AppendBaseDn := ASource.AppendBaseDn;
  AuthzId := ASource.AuthzId;
  SecretRef := ASource.SecretRef;
  AllowPlainSecrets := ASource.AllowPlainSecrets;
  Tls := ASource.Tls;
  Revocation := ASource.Revocation;
  TrustedCaDer.Assign(ASource.TrustedCaDer);
  PinnedSha256.Assign(ASource.PinnedSha256);
  ClientCertPath := ASource.ClientCertPath;
  ClientKeyPath := ASource.ClientKeyPath;
  BaseDns.Assign(ASource.BaseDns);
  ShowServerConfig := ASource.ShowServerConfig;
  ReferralPolicy := ASource.ReferralPolicy;
  ReferralDestinations.Assign(ASource.ReferralDestinations);
  DerefAliases := ASource.DerefAliases;
  ConnectTimeoutSec := ASource.ConnectTimeoutSec;
  TlsTimeoutSec := ASource.TlsTimeoutSec;
  OperationTimeoutSec := ASource.OperationTimeoutSec;
  PageSize := ASource.PageSize;
  SizeLimit := ASource.SizeLimit;
  ReadOnly := ASource.ReadOnly;
  AutoReconnect := ASource.AutoReconnect;
  Provider := ASource.Provider;
  ShowOperationalAttrs := ASource.ShowOperationalAttrs;
  LdifPath := ASource.LdifPath;
end;

procedure TConnectionProfile.SetEndpoint(const AHost: string; APort: Integer;
  AKeepTlsExceptions: Boolean);
begin
  if (not SameText(AHost, Host)) or (APort <> Port) then
  begin
    if not AKeepTlsExceptions then
      Tls := StrictTlsExceptions;
    // Nouvel hote, nouveau certificat: une empreinte epinglee sur l'ancien ne garantit
    // plus rien.
    if not AKeepTlsExceptions then
      PinnedSha256.Clear;
  end;
  Host := AHost;
  Port := APort;
end;

function TConnectionProfile.Duplicate(AKeepSecretRef, AKeepTlsExceptions: Boolean): TConnectionProfile;
begin
  Result := TConnectionProfile.Create;
  Result.Assign(Self);
  Result.Uuid := '';
  Result.Name := Name + ' (copy)';
  if not AKeepSecretRef then
    Result.SecretRef := '';
  if not AKeepTlsExceptions then
    Result.Tls := StrictTlsExceptions;
end;

function TConnectionProfile.DisplayEndpoint: string;
begin
  if LdifPath <> '' then
    Result := LdifPath
  else if Pos(':', Host) > 0 then
    Result := '[' + Host + ']:' + IntToStr(Port)
  else
    Result := Host + ':' + IntToStr(Port);
end;

function IsIpv4Literal(const AHost: string): Boolean;
var
  parts: TStringArray;
  i, n: Integer;
begin
  Result := False;
  parts := AHost.Split(['.']);
  if Length(parts) <> 4 then Exit;
  for i := 0 to 3 do
  begin
    if (parts[i] = '') or (Length(parts[i]) > 3) then Exit;
    if not TryStrToInt(parts[i], n) or (n < 0) or (n > 255) then Exit;
    if (Length(parts[i]) > 1) and (parts[i][1] = '0') then Exit;
  end;
  Result := True;
end;

function ValidHexGroup(const G: string): Boolean;
var
  k: Integer;
begin
  if (G = '') or (Length(G) > 4) then Exit(False);
  for k := 1 to Length(G) do
    if not (G[k] in ['0'..'9', 'a'..'f', 'A'..'F']) then Exit(False);
  Result := True;
end;

// Validation stricte RFC 4291, zone d'interface (%) refusee. Une chaine invalide
// n'est pas un litteral: elle sera traitee comme un nom et echouera a la
// resolution, jamais confiee a set1_ip_asc d'OpenSSL.
function ValidIpv6Literal(const AHost: string): Boolean;
var
  left, right: string;
  lparts, rparts: TStringArray;
  i, p, groups: Integer;
  hasDouble: Boolean;

  function CountSide(const AParts: TStringArray; ALastMayBeIpv4: Boolean;
    out ACount: Integer): Boolean;
  var
    k: Integer;
  begin
    Result := True;
    ACount := 0;
    for k := 0 to High(AParts) do
      if ALastMayBeIpv4 and (k = High(AParts)) and (Pos('.', AParts[k]) > 0) then
      begin
        if not IsIpv4Literal(AParts[k]) then Exit(False);
        Inc(ACount, 2);
      end
      else if ValidHexGroup(AParts[k]) then
        Inc(ACount)
      else
        Exit(False);
  end;

begin
  Result := False;
  if AHost = '' then Exit;
  if Pos(':::', AHost) > 0 then Exit;
  p := Pos('::', AHost);
  hasDouble := p > 0;
  if hasDouble then
  begin
    if Pos('::', AHost, p + 1) > 0 then Exit;
    left := Copy(AHost, 1, p - 1);
    right := Copy(AHost, p + 2, MaxInt);
  end
  else
  begin
    left := AHost;
    right := '';
  end;
  if not hasDouble and ((AHost[1] = ':') or (AHost[Length(AHost)] = ':')) then Exit;
  groups := 0;
  if left <> '' then
  begin
    lparts := left.Split([':']);
    if not CountSide(lparts, not hasDouble, i) then Exit;
    Inc(groups, i);
  end;
  if right <> '' then
  begin
    rparts := right.Split([':']);
    if not CountSide(rparts, True, i) then Exit;
    Inc(groups, i);
  end;
  if hasDouble then
    Result := groups < 8
  else
    Result := groups = 8;
end;

function IsIpLiteral(const AHost: string): Boolean;
begin
  if Pos(':', AHost) > 0 then
    Result := ValidIpv6Literal(AHost)
  else
    Result := IsIpv4Literal(AHost);
end;

function IsValidHostName(const AHost: string): Boolean;
var
  labels: TStringArray;
  i, j: Integer;
  l: string;
begin
  Result := False;
  if (AHost = '') or (Length(AHost) > 253) then Exit;
  if IsIpLiteral(AHost) then Exit(True);
  labels := AHost.Split(['.']);
  for i := 0 to High(labels) do
  begin
    l := labels[i];
    if (l = '') and (i = High(labels)) and (i > 0) then Continue;
    if (l = '') or (Length(l) > 63) then Exit;
    if (l[1] = '-') or (l[Length(l)] = '-') then Exit;
    for j := 1 to Length(l) do
      if not (l[j] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '_']) then Exit;
  end;
  Result := True;
end;

procedure AddIssue(var AIssues: TProfileIssues; ALevel: TProfileIssueLevel;
  const AField, AMsg: string);
begin
  SetLength(AIssues, Length(AIssues) + 1);
  AIssues[High(AIssues)].Level := ALevel;
  AIssues[High(AIssues)].Field := AField;
  AIssues[High(AIssues)].Message := AMsg;
end;

function ValidateProfile(AProfile: TConnectionProfile): TProfileIssues;
var
  d: TLdapDn;
  err: string;
  i: Integer;
begin
  Result := nil;
  if Trim(AProfile.Name) = '' then
    AddIssue(Result, pilError, 'name', 'A profile needs a name.');
  if not IsValidHostName(AProfile.Host) then
    AddIssue(Result, pilError, 'host', 'Enter a DNS name or an IP address.');
  if (AProfile.Port < 1) or (AProfile.Port > 65535) then
    AddIssue(Result, pilError, 'port', 'The port must be between 1 and 65535.');
  if (AProfile.Port = AD_GC_PORT) or (AProfile.Port = AD_GC_SSL_PORT) then
    AddIssue(Result, pilWarning, 'port',
      'Global catalog ports expose a partial replica of the forest, not a complete partition.');
  if (AProfile.Transport = tmLdaps) and (AProfile.Port = DEFAULT_LDAP_PORT) then
    AddIssue(Result, pilWarning, 'port', 'LDAPS usually listens on port 636.');
  if (AProfile.Transport <> tmLdaps) and (AProfile.Port = DEFAULT_LDAPS_PORT) then
    AddIssue(Result, pilWarning, 'port', 'Port 636 usually expects LDAPS.');
  if AProfile.AuthMode = amSimple then
  begin
    if Trim(AProfile.BindDn) = '' then
      AddIssue(Result, pilError, 'bindDn',
        'Simple bind needs a bind DN or user name; choose anonymous explicitly otherwise.')
    else if AProfile.AppendBaseDn and (AProfile.BaseDns.Count = 0) then
      AddIssue(Result, pilError, 'bindDn', 'Append base DN needs a base DN (Base DNs tab).')
    else if AProfile.AppendBaseDn and not DnParse(Trim(AProfile.BindDn), d, err) then
      AddIssue(Result, pilWarning, 'bindDn',
        'The bind identity is not a DN: the base DN is not appended to it.');
    if (AProfile.Transport = tmPlain) and not AProfile.AllowPlainSecrets then
      AddIssue(Result, pilError, 'transport',
        'Sending a password without encryption must be allowed explicitly for this profile.');
  end;
  if AProfile.AuthMode = amSaslExternal then
  begin
    if AProfile.Transport = tmPlain then
      AddIssue(Result, pilError, 'transport', 'SASL EXTERNAL needs TLS with a client certificate.');
    if (AProfile.ClientCertPath = '') or (AProfile.ClientKeyPath = '') then
      AddIssue(Result, pilError, 'clientCert', 'SASL EXTERNAL needs a client certificate and key.');
    // RFC 4513 5.2.1.8: les prefixes "dn:" et "u:" sont des chaines ABNF, donc
    // insensibles a la casse. Vide = identite du certificat.
    if AProfile.AuthzId <> '' then
    begin
      if SameText(Copy(AProfile.AuthzId, 1, 3), 'dn:') then
      begin
        if not DnParse(Copy(AProfile.AuthzId, 4, MaxInt), d, err) then
          AddIssue(Result, pilError, 'authzId',
            Format('Invalid DN in the authorization identity: %s', [err]));
      end
      else if not SameText(Copy(AProfile.AuthzId, 1, 2), 'u:') then
        AddIssue(Result, pilError, 'authzId',
          'The authorization identity starts with dn: or u: (or stays empty to use the certificate''s identity).');
    end;
  end;
  if (AProfile.Revocation = rpRequired) and not AProfile.Tls.VerifyCAChain then
    AddIssue(Result, pilError, 'revocation',
      'Revocation cannot be required while the CA chain is not verified.');
  if (AProfile.Transport = tmPlain) and (AProfile.Revocation <> rpNotChecked) then
    AddIssue(Result, pilWarning, 'revocation', 'Revocation applies only to TLS connections.');
  for i := 0 to AProfile.BaseDns.Count - 1 do
    if not DnParse(AProfile.BaseDns[i], d, err) then
      AddIssue(Result, pilError, 'baseDns', Format('Invalid base DN "%s": %s', [AProfile.BaseDns[i], err]));
  for i := 0 to AProfile.PinnedSha256.Count - 1 do
    if Length(StringReplace(AProfile.PinnedSha256[i], ':', '', [rfReplaceAll])) <> 64 then
      AddIssue(Result, pilError, 'pinning', 'A SHA-256 fingerprint has 64 hexadecimal digits.');
  if (AProfile.PageSize < 0) or (AProfile.PageSize > 100000) then
    AddIssue(Result, pilError, 'pageSize', 'The page size must be between 0 and 100000.');
  if (AProfile.ConnectTimeoutSec < 1) or (AProfile.ConnectTimeoutSec > 600) or
     (AProfile.TlsTimeoutSec < 1) or (AProfile.TlsTimeoutSec > 600) or
     (AProfile.OperationTimeoutSec < 1) or (AProfile.OperationTimeoutSec > 3600) then
    AddIssue(Result, pilError, 'timeouts', 'Timeouts are out of range.');
  if (AProfile.DerefAliases < 0) or (AProfile.DerefAliases > 3) then
    AddIssue(Result, pilError, 'aliases', 'Invalid alias policy.');
  if AProfile.Transport = tmPlain then
    AddIssue(Result, pilWarning, 'transport', 'This connection is not encrypted.');
  if not TlsExceptionsAreStrict(AProfile.Tls) and (AProfile.Transport <> tmPlain) then
    AddIssue(Result, pilWarning, 'tls',
      'The connection stays encrypted, but the server identity is no longer fully verified.');
end;

function HasBlockingIssue(const AIssues: TProfileIssues): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AIssues) do
    if AIssues[i].Level = pilError then Exit(True);
  Result := False;
end;

function SimpleBindCredentialsAcceptable(const ABindDn: string; ASecretLength: Integer;
  out AReason: string): Boolean;
begin
  AReason := '';
  if (Trim(ABindDn) <> '') and (ASecretLength = 0) then
  begin
    AReason := 'An empty password with a bind DN would be an unauthenticated bind; refused.';
    Exit(False);
  end;
  Result := True;
end;

function EffectiveBindDn(AProfile: TConnectionProfile): string;
var
  bind, base: TLdapDn;
  baseText, err: string;
  cmp: TDnComparer;
  m: TDnMatch;
begin
  Result := Trim(AProfile.BindDn);
  if not AProfile.AppendBaseDn or (AProfile.AuthMode <> amSimple) or (Result = '') or
     (AProfile.BaseDns.Count = 0) then Exit;
  baseText := Trim(AProfile.BaseDns[0]);
  if not DnParse(Result, bind, err) or not DnParse(baseText, base, err) or DnIsEmpty(base) then
    Exit;
  cmp := CaseIgnoreDnComparer;
  try
    m := cmp.IsUnder(bind, base, True);
  finally
    cmp.Free;
  end;
  if m <> dmDifferent then Exit;
  Result := Result + ',' + baseText;
end;

function BuildLdapUri(AProfile: TConnectionProfile): string;
var
  h: string;
begin
  h := AProfile.Host;
  if Pos(':', h) > 0 then
    h := '[' + h + ']';
  if AProfile.Transport = tmLdaps then
    Result := 'ldaps://' + h + ':' + IntToStr(AProfile.Port)
  else
    Result := 'ldap://' + h + ':' + IntToStr(AProfile.Port);
end;

end.
