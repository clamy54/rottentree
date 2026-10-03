// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSchemaReader;

{$mode objfpc}{$H+}

// Lecture du sous-schema annonce par le serveur (subschemaSubentry du Root DSE ou d'une
// entree). Cache indexe par profil, endpoint, identite effective et DN du sous-schema:
// deux comptes ne voient pas forcement le meme schema.

interface

uses
  SysUtils, uDirectorySession, uLdapSchema, uLdapEntry, uCancel, uAdSchemaMeta;

function ReadSchema(ASession: TDirectorySession; const ASubschemaDn: string;
  ACancel: TCancelToken; out AReason: string): TSchemaSnapshot;
function SubschemaDnFromRootDse(ARoot: TLdapEntry): string;
function SchemaCacheKey(ASession: TDirectorySession; const ASubschemaDn: string): string;
function ReadAdSchemaMeta(ASession: TDirectorySession; const ASchemaDn: string;
  ACancel: TCancelToken): TAdSchemaMeta;

implementation

uses
  uLdapErrors, uConnectionProfile, uSearchModel;

type
  TAdMetaCollector = class
  public
    Meta: TAdSchemaMeta;
    procedure OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
  end;

procedure TAdMetaCollector.OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
begin
  try
    Meta.Feed(AEntry);
  finally
    AEntry.Free;
  end;
  if Meta.Reason <> '' then AStop := True;
end;

function ReadAdSchemaMeta(ASession: TDirectorySession; const ASchemaDn: string;
  ACancel: TCancelToken): TAdSchemaMeta;
var
  req: TSearchRequest;
  col: TAdMetaCollector;
  completion: TSearchCompletion;
  i: Integer;
  root: TLdapEntry;
begin
  Result := TAdSchemaMeta.Create(ASchemaDn);
  if ASchemaDn = '' then
  begin
    Result.MarkIncomplete('the root DSE does not announce schemaNamingContext');
    Exit;
  end;
  req := DefaultSearchRequest;
  req.BaseDn := ASchemaDn;
  req.Scope := ssOneLevel;
  req.Filter := '(|(objectClass=attributeSchema)(objectClass=classSchema))';
  SetLength(req.Attributes, Length(AD_SCHEMA_READ_ATTRS));
  for i := 0 to High(AD_SCHEMA_READ_ATTRS) do
    req.Attributes[i] := AD_SCHEMA_READ_ATTRS[i];
  // Enumeration complete exigee: une limite de taille fabriquerait des types inconnus.
  req.SizeLimit := 0;
  req.TimeLimitSec := 0;
  req.PageSize := ASession.Profile.PageSize;
  if req.PageSize <= 0 then req.PageSize := 500;
  col := TAdMetaCollector.Create;
  try
    col.Meta := Result;
    ASession.Search(req, @col.OnEntry, ACancel, completion);
    // Les extensions de schema AD ne s'ecrivent que sur le maitre de schema.
    root := ASession.ReadEntry(ASchemaDn, ['fSMORoleOwner'], ACancel);
    if root <> nil then
    try
      Result.RoleOwner := string(root.FirstValue('fSMORoleOwner', ''));
    finally
      root.Free;
    end;
    if SearchOutcome(completion) = soComplete then
      Result.MarkComplete
    else if completion.Cancelled then
      Result.MarkIncomplete('cancelled')
    else if completion.SizeLimitHit then
      Result.MarkIncomplete('size limit')
    else if completion.TimeLimitHit then
      Result.MarkIncomplete('time limit')
    else
      // Le diagnostic du serveur n'est pas repris: il n'est pas expurge.
      Result.MarkIncomplete(ResultCodeName(completion.ResultCode));
  finally
    col.Free;
  end;
end;

function SubschemaDnFromRootDse(ARoot: TLdapEntry): string;
begin
  Result := '';
  if ARoot <> nil then
    Result := ARoot.FirstValue('subschemaSubentry');
end;

function SchemaCacheKey(ASession: TDirectorySession; const ASubschemaDn: string): string;
var
  identity: string;
begin
  identity := ASession.Transport.AuthzId;
  if identity = '' then identity := ASession.Transport.BoundIdentity;
  if ASession.Transport.Anonymous then identity := '(anonymous)';
  Result := ASession.Profile.Uuid + '|' + BuildLdapUri(ASession.Profile) + '|' + identity + '|' +
    ASubschemaDn;
end;

function ReadSchema(ASession: TDirectorySession; const ASubschemaDn: string;
  ACancel: TCancelToken; out AReason: string): TSchemaSnapshot;
var
  e: TLdapEntry;
  a: TLdapAttribute;
  i: Integer;
  dn: string;
begin
  Result := nil;
  AReason := '';
  dn := ASubschemaDn;
  if dn = '' then
  begin
    AReason := 'the server does not announce a subschema entry';
    Exit;
  end;
  e := ASession.ReadEntry(dn, ['attributeTypes', 'objectClasses', 'ldapSyntaxes',
    'matchingRules', 'matchingRuleUse', 'dITContentRules'], ACancel);
  if e = nil then
  begin
    AReason := 'schema unavailable: ' + ErrorToText(ASession.LastError);
    Exit;
  end;
  try
    Result := TSchemaSnapshot.Create;
    Result.SubschemaDn := dn;
    Result.SourceKey := SchemaCacheKey(ASession, dn);
    Result.FetchedUtc := UtcNow;
    if e.DecodeIncomplete then
      Result.MarkIncomplete('the subschema entry was not decoded completely');
    for i := 0 to e.AttrCount - 1 do
      if e.Attrs[i].Truncated then
        Result.MarkIncomplete(e.Attrs[i].BaseName + ' was truncated by a size limit');
    a := e.Find('ldapSyntaxes');
    if a <> nil then
      for i := 0 to a.ValueCount - 1 do
        Result.AddDefinition(sdkSyntax, a.Values[i]);
    a := e.Find('matchingRules');
    if a <> nil then
      for i := 0 to a.ValueCount - 1 do
        Result.AddDefinition(sdkMatchingRule, a.Values[i]);
    a := e.Find('attributeTypes');
    if a <> nil then
      for i := 0 to a.ValueCount - 1 do
        Result.AddDefinition(sdkAttributeType, a.Values[i]);
    a := e.Find('objectClasses');
    if a <> nil then
      for i := 0 to a.ValueCount - 1 do
        Result.AddDefinition(sdkObjectClass, a.Values[i]);
    a := e.Find('dITContentRules');
    if a <> nil then
      for i := 0 to a.ValueCount - 1 do
        Result.AddDefinition(sdkDitContentRule, a.Values[i]);
    if Result.AttributeTypeCount = 0 then
      AReason := 'the subschema entry returned no attribute types (access may be restricted)';
  finally
    e.Free;
  end;
end;

end.
