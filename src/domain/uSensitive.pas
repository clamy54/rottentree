// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSensitive;

{$mode objfpc}{$H+}

// Attributs sensibles: masques dans les vues, journaux, rapports et comparaisons,
// mais presents dans les exports d'entrees. Masquage par nom d'attribut, jamais
// par motif dans le texte, et le mode debug n'y touche pas.

interface

uses
  SysUtils, Classes, uLdapSchema;

const
  MASK_TEXT = '[masked]';

type
  TSensitivePolicy = class
  private
    FExtra: TStringList;
    FAliases: TStringList;
    FGroups: TStringList;
    function BaseSensitive(const ALowerBase: string): Boolean;
    procedure Relearn;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddExtra(const AAttr: string);
    procedure ClearExtra;
    procedure SetExtra(const AList: array of string);
    // Un serveur peut repondre avec n'importe quel nom ou l'OID d'un attribut: si l'un
    // est sensible, tous le deviennent. Les types appris sont gardes pour qu'un ajout
    // tardif entraine ses alias sans relire le schema.
    procedure LearnSchema(ASchema: TSchemaSnapshot);
    function IsSensitive(const AAttrDescription: string): Boolean;
    function ExtraList: TStrings;
  end;

function IsBuiltinSensitiveAttr(const AAttrDescription: string): Boolean;
function BuiltinSensitiveCount: Integer;
function BuiltinSensitiveAt(AIndex: Integer): string;
function MaskedValuesText(ACount: Integer): string;

function DefaultComparisonExclusions: TStringArray;

implementation

uses
  uLdapEntry;

const
  // Une reponse ou un LDIF peut designer userPassword par 2.5.4.35. Masquer le nom
  // sans l'OID, c'est fermer la porte et laisser la fenetre.
  BuiltinSensitiveOids: array[0..17] of string = (
    '2.5.4.35',                        // userPassword
    '1.3.6.1.4.1.4203.1.3.4',          // authPassword (RFC 3112)
    '1.2.840.113556.1.4.90',           // unicodePwd
    '1.2.840.113556.1.4.55',           // dBCSPwd
    '1.2.840.113556.1.4.94',           // ntPwdHistory
    '1.2.840.113556.1.4.160',          // lmPwdHistory
    '1.2.840.113556.1.4.125',          // supplementalCredentials
    '1.2.840.113556.1.4.2196',         // msDS-ManagedPassword
    '1.2.840.113556.1.4.2197',         // msDS-ManagedPasswordId
    '1.2.840.113556.1.4.2198',         // msDS-ManagedPasswordPreviousId
    '1.2.840.113556.1.4.2328',         // msDS-KeyCredentialLink
    '1.3.6.1.4.1.7165.2.1.25',         // sambaNTPassword
    '1.3.6.1.4.1.7165.2.1.24',         // sambaLMPassword
    '1.3.6.1.4.1.42.2.27.8.1.20',      // pwdHistory
    '2.16.840.1.113730.3.1.216',       // userPKCS12
    '2.16.840.1.113719.1.301.4.7.1',   // krbPrincipalKey
    '1.3.6.1.4.1.5322.10.1.10',        // krb5Key
    '1.3.6.1.4.1.4203.666.11.1.3.2.2'  // olcRootPW (OpenLDAP config)
  );

  BuiltinSensitive: array[0..27] of string = (
    'userpassword', 'unicodepwd', 'authpassword', 'clearpassword',
    'sambantpassword', 'sambalmpassword', 'ntpwdhistory', 'lmpwdhistory',
    'supplementalcredentials', 'dbcspwd', 'msds-managedpassword',
    'msds-managedpasswordid', 'msds-managedpasswordpreviousid',
    'userpkcs12', 'krbprincipalkey', 'krb5key', 'pwdhistory', 'olcrootpw',
    'olcdbrootpw', 'olcdbacl-bindpw', 'nsds5replicacredentials',
    'nsmultiplexorcredentials', 'nspkcs12', 'sambapasswordhistory',
    'userprivatekey', 'dsaprivatekey', 'msds-keycredentiallink',
    'nspassword');

function IsBuiltinSensitiveAttr(const AAttrDescription: string): Boolean;
var
  base: string;
  i: Integer;
begin
  base := AsciiLowerCase(AttrBaseName(AAttrDescription));
  for i := 0 to High(BuiltinSensitive) do
    if BuiltinSensitive[i] = base then Exit(True);
  for i := 0 to High(BuiltinSensitiveOids) do
    if BuiltinSensitiveOids[i] = base then Exit(True);
  Result := False;
end;

function BuiltinSensitiveCount: Integer;
begin
  Result := Length(BuiltinSensitive);
end;

function BuiltinSensitiveAt(AIndex: Integer): string;
begin
  Result := BuiltinSensitive[AIndex];
end;

function MaskedValuesText(ACount: Integer): string;
begin
  if ACount = 1 then
    Result := '[masked: 1 value]'
  else
    Result := Format('[masked: %d values]', [ACount]);
end;

function DefaultComparisonExclusions: TStringArray;
begin
  Result := ['userPassword', 'unicodePwd', 'authPassword', 'sambaNTPassword',
    'sambaLMPassword', 'supplementalCredentials', 'pwdHistory',
    'contextCSN', 'entryCSN', 'uSNChanged', 'uSNCreated', 'highestCommittedUSN',
    'modifyTimestamp', 'modifiersName', 'whenChanged', 'lastLogon',
    'lastLogonTimestamp', 'logonCount', 'badPwdCount', 'badPasswordTime',
    'pwdFailureTime', 'authTimestamp', 'pwdLastSuccess', 'lastLogoff',
    'dSCorePropagationData', 'replPropertyMetaData', 'msDS-ReplAttributeMetaData',
    'msDS-ReplValueMetaData', 'nsds50ruv', 'nsruvReplicaLastModified',
    'numSubordinates', 'hasSubordinates', 'subschemaSubentry', 'entryDN',
    'structuralObjectClass', 'createTimestamp', 'creatorsName', 'whenCreated',
    'passwordRetryCount', 'retryCountResetTime', 'accountUnlockTime',
    'nsUniqueId', 'entryUUID', 'objectGUID'];
end;

constructor TSensitivePolicy.Create;
begin
  inherited Create;
  FExtra := TStringList.Create;
  FExtra.CaseSensitive := False;
  FExtra.Sorted := True;
  FExtra.Duplicates := dupIgnore;
  FAliases := TStringList.Create;
  FAliases.CaseSensitive := False;
  FAliases.Sorted := True;
  FAliases.Duplicates := dupIgnore;
  FGroups := TStringList.Create;
end;

destructor TSensitivePolicy.Destroy;
begin
  FGroups.Free;
  FAliases.Free;
  FExtra.Free;
  inherited Destroy;
end;

function TSensitivePolicy.BaseSensitive(const ALowerBase: string): Boolean;
begin
  Result := IsBuiltinSensitiveAttr(ALowerBase) or (FExtra.IndexOf(ALowerBase) >= 0);
end;

procedure TSensitivePolicy.Relearn;
var
  i, j: Integer;
  members: TStringArray;
  hit: Boolean;
begin
  FAliases.Clear;
  for i := 0 to FGroups.Count - 1 do
  begin
    members := FGroups[i].Split(['|']);
    hit := False;
    for j := 0 to High(members) do
      if (members[j] <> '') and BaseSensitive(members[j]) then hit := True;
    if not hit then Continue;
    for j := 0 to High(members) do
      if members[j] <> '' then FAliases.Add(members[j]);
  end;
end;

procedure TSensitivePolicy.LearnSchema(ASchema: TSchemaSnapshot);
var
  i, j: Integer;
  at: TSchemaAttributeType;
  g: string;
begin
  if ASchema = nil then Exit;
  for i := 0 to ASchema.AttributeTypeCount - 1 do
  begin
    at := ASchema.AttributeTypeAt(i);
    g := AsciiLowerCase(at.Oid);
    for j := 0 to High(at.Names) do
      g := g + '|' + AsciiLowerCase(at.Names[j]);
    if g <> '' then FGroups.Add(g);
  end;
  Relearn;
end;

procedure TSensitivePolicy.AddExtra(const AAttr: string);
begin
  if Trim(AAttr) <> '' then
  begin
    FExtra.Add(AsciiLowerCase(AttrBaseName(Trim(AAttr))));
    Relearn;
  end;
end;

procedure TSensitivePolicy.ClearExtra;
begin
  FExtra.Clear;
  Relearn;
end;

procedure TSensitivePolicy.SetExtra(const AList: array of string);
var
  i: Integer;
begin
  FExtra.Clear;
  for i := 0 to High(AList) do
    if Trim(AList[i]) <> '' then
      FExtra.Add(AsciiLowerCase(AttrBaseName(Trim(AList[i]))));
  Relearn;
end;

function TSensitivePolicy.IsSensitive(const AAttrDescription: string): Boolean;
var
  base: string;
begin
  base := AsciiLowerCase(AttrBaseName(AAttrDescription));
  Result := IsBuiltinSensitiveAttr(AAttrDescription) or (FExtra.IndexOf(base) >= 0) or
    (FAliases.IndexOf(base) >= 0);
end;

function TSensitivePolicy.ExtraList: TStrings;
begin
  Result := FExtra;
end;

end.
