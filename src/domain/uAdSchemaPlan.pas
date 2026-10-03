// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAdSchemaPlan;

{$mode objfpc}{$H+}

// Extensions du schema Active Directory: attributeSchema, classSchema, isDefunct
// sur ce qu'on a ajoute (jamais sur le schema de base) et schemaUpdateNow. Tout
// part vers le maitre de schema, sans redirection. Portee: la foret entiere, sans
// retour arriere. A faire un mardi matin, pas un vendredi soir.

interface

uses
  SysUtils, uAdSchemaMeta, uLdapSchema, uLdapEntry, uChangeSet;

type
  TAdSyntaxChoice = (ascUnicodeString, ascCaseInsensitiveString, ascPrintableString, ascIA5String,
    ascNumericString, ascInteger, ascLargeInteger, ascBoolean, ascOctetString, ascDn,
    ascGeneralizedTime, ascSid);

  TAdAttributeDraft = record
    Cn: string;
    LdapDisplayName: string;
    AttributeId: string;
    Syntax: TAdSyntaxChoice;
    SingleValued: Boolean;
    Description: string;
    HasRangeUpper: Boolean;
    RangeUpper: Int64;
  end;

  TAdClassDraft = record
    Cn: string;
    LdapDisplayName: string;
    GovernsId: string;
    Category: Integer;
    SubClassOf: string;
    Must, May, PossSuperiors: array of string;
    Description: string;
  end;

  TAdSchemaPlan = record
    Ok: Boolean;
    Errors: array of string;
    Warnings: array of string;
    Change: TLdapChange;
    Refresh: TLdapChange;
  end;

resourcestring
  rsAsNoMeta = 'The Active Directory schema objects were not read: nothing can be planned.';
  rsAsMetaIncomplete = 'The schema objects were read partially (%s): collisions may be missed.';
  rsAsNotMaster = 'This domain controller is not the schema master (%s): schema changes are refused here, ' +
    'and the assistant does not redirect to another server.';
  rsAsMasterUnknown = 'The schema master could not be determined: schema changes are not planned.';
  rsAsForest = 'A schema extension applies to the whole forest and cannot be removed; it can only be deactivated.';
  rsAsBadCn = 'The common name is required and cannot hold "," "=" "+" "<" ">" ";" "\" or quotes.';
  rsAsBadName = '"%s" is not a valid lDAPDisplayName (a letter, then letters, digits or hyphens).';
  rsAsBadOid = '"%s" is not a numeric OID from your organization''s arc.';
  rsAsNameUsed = '%s is already used by %s.';
  rsAsOidUsed = 'OID %s is already used by %s.';
  rsAsCnUsed = 'The common name %s is already used by %s.';
  rsAsSupMissing = 'Superior class %s is not defined.';
  rsAsAttrMissing = 'Attribute %s is not defined.';
  rsAsDefunctRef = '%s is defunct and cannot be used.';
  rsAsCategory = 'Invalid class category.';
  rsAsBase = '%s belongs to the base schema: it cannot be deactivated.';
  rsAsAlreadyDefunct = '%s is already deactivated.';
  rsAsInUse = '%s is still required or allowed by the active class %s: deactivate the class first.';
  rsAsUnknownObject = '%s is not an object of the schema that was read.';
  rsAsDefunctNote = 'Deactivation keeps existing values and the schema object; it is not a deletion.';

function AdSyntaxChoiceName(AChoice: TAdSyntaxChoice): string;
procedure AdSyntaxValues(AChoice: TAdSyntaxChoice; out AAttributeSyntax: string; out AOmSyntax: Integer;
  out AOmObjectClassHex: string);
function IsSchemaMaster(const ARoleOwner, ADsServiceName: string): Boolean;
function PlanAdAttribute(AMeta: TAdSchemaMeta; ASchema: TSchemaSnapshot; const ADraft: TAdAttributeDraft;
  const ARoleOwner, ADsServiceName: string): TAdSchemaPlan;
function PlanAdClass(AMeta: TAdSchemaMeta; ASchema: TSchemaSnapshot; const ADraft: TAdClassDraft;
  const ARoleOwner, ADsServiceName: string): TAdSchemaPlan;
function PlanAdDefunct(AMeta: TAdSchemaMeta; const AName: string; const ARoleOwner,
  ADsServiceName: string): TAdSchemaPlan;
procedure FreeAdSchemaPlan(var APlan: TAdSchemaPlan);

implementation

uses
  uSchemaDefinition, uLdapDn, uRtBytes;

const
  SYNTAX_TABLE: array[TAdSyntaxChoice] of record
    Name, AttrSyntax: string;
    Om: Integer;
    OmClass: string;
  end = (
    (Name: 'Unicode string'; AttrSyntax: '2.5.5.12'; Om: 64; OmClass: ''),
    (Name: 'Case-insensitive string'; AttrSyntax: '2.5.5.4'; Om: 20; OmClass: ''),
    (Name: 'Printable string'; AttrSyntax: '2.5.5.5'; Om: 19; OmClass: ''),
    (Name: 'IA5 string'; AttrSyntax: '2.5.5.5'; Om: 22; OmClass: ''),
    (Name: 'Numeric string'; AttrSyntax: '2.5.5.6'; Om: 18; OmClass: ''),
    (Name: 'Integer'; AttrSyntax: '2.5.5.9'; Om: 2; OmClass: ''),
    (Name: 'Large integer'; AttrSyntax: '2.5.5.16'; Om: 65; OmClass: ''),
    (Name: 'Boolean'; AttrSyntax: '2.5.5.8'; Om: 1; OmClass: ''),
    (Name: 'Octet string'; AttrSyntax: '2.5.5.10'; Om: 4; OmClass: ''),
    (Name: 'Distinguished name'; AttrSyntax: '2.5.5.1'; Om: 127; OmClass: '2b0c0287731c00854a'),
    (Name: 'Generalized time'; AttrSyntax: '2.5.5.11'; Om: 24; OmClass: ''),
    (Name: 'SID'; AttrSyntax: '2.5.5.17'; Om: 4; OmClass: ''));

function AdSyntaxChoiceName(AChoice: TAdSyntaxChoice): string;
begin
  Result := SYNTAX_TABLE[AChoice].Name;
end;

procedure AdSyntaxValues(AChoice: TAdSyntaxChoice; out AAttributeSyntax: string; out AOmSyntax: Integer;
  out AOmObjectClassHex: string);
begin
  AAttributeSyntax := SYNTAX_TABLE[AChoice].AttrSyntax;
  AOmSyntax := SYNTAX_TABLE[AChoice].Om;
  AOmObjectClassHex := SYNTAX_TABLE[AChoice].OmClass;
end;

function IsSchemaMaster(const ARoleOwner, ADsServiceName: string): Boolean;
var
  a, b: TLdapDn;
  cmp: TDnComparer;
begin
  Result := False;
  if (ARoleOwner = '') or (ADsServiceName = '') then Exit;
  if not DnTryParse(ARoleOwner, a) or not DnTryParse(ADsServiceName, b) then Exit;
  cmp := TDnComparer.Create;
  try
    Result := cmp.CompareDn(a, b) = dmEqual;
  finally
    cmp.Free;
  end;
end;

procedure AddError(var P: TAdSchemaPlan; const S: string);
begin
  SetLength(P.Errors, Length(P.Errors) + 1);
  P.Errors[High(P.Errors)] := S;
end;

procedure AddWarning(var P: TAdSchemaPlan; const S: string);
begin
  SetLength(P.Warnings, Length(P.Warnings) + 1);
  P.Warnings[High(P.Warnings)] := S;
end;

procedure FreeAdSchemaPlan(var APlan: TAdSchemaPlan);
begin
  FreeAndNil(APlan.Change);
  FreeAndNil(APlan.Refresh);
end;

function ValidCn(const S: string): Boolean;
var
  i: Integer;
begin
  Result := (Trim(S) <> '') and (Trim(S) = S) and (Length(S) <= 64);
  if not Result then Exit;
  for i := 1 to Length(S) do
    if (S[i] in [',', '=', '+', '<', '>', ';', '\', '"', '#']) or (Ord(S[i]) < 32) then Exit(False);
end;

procedure CommonChecks(var P: TAdSchemaPlan; AMeta: TAdSchemaMeta; const ARoleOwner,
  ADsServiceName: string);
begin
  if AMeta = nil then
  begin
    AddError(P, rsAsNoMeta);
    Exit;
  end;
  if not AMeta.Complete then AddWarning(P, Format(rsAsMetaIncomplete, [AMeta.Reason]));
  if ARoleOwner = '' then AddError(P, rsAsMasterUnknown)
  else if not IsSchemaMaster(ARoleOwner, ADsServiceName) then
    AddError(P, Format(rsAsNotMaster, [ARoleOwner]));
  AddWarning(P, rsAsForest);
end;

procedure CheckIdentity(var P: TAdSchemaPlan; AMeta: TAdSchemaMeta; const ACn, AName, AOid: string);
var
  i: Integer;
begin
  if not ValidCn(ACn) then AddError(P, rsAsBadCn);
  if not IsSchemaDescr(AName) then AddError(P, Format(rsAsBadName, [AName]));
  if not IsNumericOidText(AOid) then AddError(P, Format(rsAsBadOid, [AOid]));
  if AMeta = nil then Exit;
  for i := 0 to AMeta.AttributeCount - 1 do
  begin
    if SameText(AMeta.AttributeAt(i).Name, AName) then
      AddError(P, Format(rsAsNameUsed, [AName, 'attribute ' + AMeta.AttributeAt(i).Name]));
    if AMeta.AttributeAt(i).AttributeId = AOid then
      AddError(P, Format(rsAsOidUsed, [AOid, 'attribute ' + AMeta.AttributeAt(i).Name]));
    if SameText(AMeta.AttributeAt(i).Cn, ACn) then
      AddError(P, Format(rsAsCnUsed, [ACn, 'attribute ' + AMeta.AttributeAt(i).Name]));
  end;
  for i := 0 to AMeta.ClassCount - 1 do
  begin
    if SameText(AMeta.ClassAt(i).Name, AName) then
      AddError(P, Format(rsAsNameUsed, [AName, 'class ' + AMeta.ClassAt(i).Name]));
    if AMeta.ClassAt(i).GovernsId = AOid then
      AddError(P, Format(rsAsOidUsed, [AOid, 'class ' + AMeta.ClassAt(i).Name]));
    if SameText(AMeta.ClassAt(i).Cn, ACn) then
      AddError(P, Format(rsAsCnUsed, [ACn, 'class ' + AMeta.ClassAt(i).Name]));
  end;
end;

function SchemaChildDn(AMeta: TAdSchemaMeta; const ACn: string): string;
var
  base, dn: TLdapDn;
begin
  Result := '';
  if not DnTryParse(AMeta.SchemaDn, base) then Exit;
  dn := DnChild(base, DnMakeRdn('CN', ACn));
  Result := DnToString(dn);
end;

function RefreshChange: TLdapChange;
begin
  Result := NewChange(ckModify, '');
  Result.AddMod(moAdd, 'schemaUpdateNow', ['1']);
end;

function PlanAdAttribute(AMeta: TAdSchemaMeta; ASchema: TSchemaSnapshot; const ADraft: TAdAttributeDraft;
  const ARoleOwner, ADsServiceName: string): TAdSchemaPlan;
var
  syn, omClass: string;
  raw: RawByteString;
  om: Integer;
  e: TLdapEntry;
begin
  Result := Default(TAdSchemaPlan);
  CommonChecks(Result, AMeta, ARoleOwner, ADsServiceName);
  CheckIdentity(Result, AMeta, ADraft.Cn, ADraft.LdapDisplayName, ADraft.AttributeId);
  if (ASchema <> nil) and (ASchema.AttributeType(ADraft.LdapDisplayName) <> nil) then
    AddError(Result, Format(rsAsNameUsed, [ADraft.LdapDisplayName, 'the subschema']));
  Result.Ok := Length(Result.Errors) = 0;
  if not Result.Ok then Exit;
  AdSyntaxValues(ADraft.Syntax, syn, om, omClass);
  Result.Change := NewChange(ckAdd, SchemaChildDn(AMeta, ADraft.Cn));
  e := Result.Change.Entry;
  e.Dn := Result.Change.Dn;
  e.Ensure('objectClass').SetValues(['top', 'attributeSchema']);
  e.Ensure('cn').AddValue(ADraft.Cn);
  e.Ensure('lDAPDisplayName').AddValue(ADraft.LdapDisplayName);
  e.Ensure('attributeID').AddValue(ADraft.AttributeId);
  e.Ensure('attributeSyntax').AddValue(syn);
  e.Ensure('oMSyntax').AddValue(IntToStr(om));
  if omClass <> '' then
  begin
    HexDecode(omClass, raw);
    e.Ensure('oMObjectClass').AddValue(raw);
  end;
  if ADraft.SingleValued then e.Ensure('isSingleValued').AddValue('TRUE')
  else e.Ensure('isSingleValued').AddValue('FALSE');
  if ADraft.Description <> '' then e.Ensure('adminDescription').AddValue(ADraft.Description);
  if ADraft.HasRangeUpper then e.Ensure('rangeUpper').AddValue(IntToStr(ADraft.RangeUpper));
  Result.Refresh := RefreshChange;
end;

function ClassActive(AMeta: TAdSchemaMeta; const AName: string; var P: TAdSchemaPlan): Boolean;
var
  c: TAdClassMeta;
begin
  c := AMeta.ObjectClass(AName);
  Result := c <> nil;
  if not Result then AddError(P, Format(rsAsSupMissing, [AName]))
  else if c.IsDefunct then
  begin
    AddError(P, Format(rsAsDefunctRef, [AName]));
    Result := False;
  end;
end;

function PlanAdClass(AMeta: TAdSchemaMeta; ASchema: TSchemaSnapshot; const ADraft: TAdClassDraft;
  const ARoleOwner, ADsServiceName: string): TAdSchemaPlan;
var
  i, j: Integer;
  e: TLdapEntry;
  list: array of string;
  a: TAdAttributeMeta;
begin
  Result := Default(TAdSchemaPlan);
  CommonChecks(Result, AMeta, ARoleOwner, ADsServiceName);
  CheckIdentity(Result, AMeta, ADraft.Cn, ADraft.LdapDisplayName, ADraft.GovernsId);
  if not (ADraft.Category in [1, 2, 3]) then AddError(Result, rsAsCategory);
  if AMeta <> nil then
  begin
    ClassActive(AMeta, ADraft.SubClassOf, Result);
    for i := 0 to High(ADraft.PossSuperiors) do
      ClassActive(AMeta, ADraft.PossSuperiors[i], Result);
    for j := 0 to 1 do
    begin
      if j = 0 then list := ADraft.Must else list := ADraft.May;
      for i := 0 to High(list) do
      begin
        a := AMeta.Attribute(list[i]);
        if a = nil then AddError(Result, Format(rsAsAttrMissing, [list[i]]))
        else if a.IsDefunct then AddError(Result, Format(rsAsDefunctRef, [list[i]]));
      end;
    end;
  end;
  Result.Ok := Length(Result.Errors) = 0;
  if not Result.Ok then Exit;
  Result.Change := NewChange(ckAdd, SchemaChildDn(AMeta, ADraft.Cn));
  e := Result.Change.Entry;
  e.Dn := Result.Change.Dn;
  e.Ensure('objectClass').SetValues(['top', 'classSchema']);
  e.Ensure('cn').AddValue(ADraft.Cn);
  e.Ensure('lDAPDisplayName').AddValue(ADraft.LdapDisplayName);
  e.Ensure('governsID').AddValue(ADraft.GovernsId);
  e.Ensure('objectClassCategory').AddValue(IntToStr(ADraft.Category));
  e.Ensure('subClassOf').AddValue(ADraft.SubClassOf);
  for i := 0 to High(ADraft.Must) do e.Ensure('mustContain').AddValue(ADraft.Must[i]);
  for i := 0 to High(ADraft.May) do e.Ensure('mayContain').AddValue(ADraft.May[i]);
  for i := 0 to High(ADraft.PossSuperiors) do e.Ensure('possSuperiors').AddValue(ADraft.PossSuperiors[i]);
  if ADraft.Description <> '' then e.Ensure('adminDescription').AddValue(ADraft.Description);
  Result.Refresh := RefreshChange;
end;

function PlanAdDefunct(AMeta: TAdSchemaMeta; const AName: string; const ARoleOwner,
  ADsServiceName: string): TAdSchemaPlan;
var
  a: TAdAttributeMeta;
  c, other: TAdClassMeta;
  i, j, k: Integer;
  lists: array[0..3] of TStringArray;
  dn: string;
begin
  Result := Default(TAdSchemaPlan);
  CommonChecks(Result, AMeta, ARoleOwner, ADsServiceName);
  if AMeta = nil then Exit;
  a := AMeta.Attribute(AName);
  c := AMeta.ObjectClass(AName);
  if (a = nil) and (c = nil) then
  begin
    AddError(Result, Format(rsAsUnknownObject, [AName]));
    Exit;
  end;
  if a <> nil then
  begin
    if a.IsBaseSchema then AddError(Result, Format(rsAsBase, [a.Name]));
    if a.IsDefunct then AddError(Result, Format(rsAsAlreadyDefunct, [a.Name]));
    // Un attribut encore exige ou permis par une classe active reste actif.
    for i := 0 to AMeta.ClassCount - 1 do
    begin
      other := AMeta.ClassAt(i);
      if other.IsDefunct then Continue;
      lists[0] := other.Must;
      lists[1] := other.May;
      lists[2] := other.SystemMust;
      lists[3] := other.SystemMay;
      for j := 0 to 3 do
        for k := 0 to High(lists[j]) do
          if SameText(lists[j][k], a.Name) or (lists[j][k] = a.AttributeId) then
            AddError(Result, Format(rsAsInUse, [a.Name, other.Name]));
    end;
    dn := a.Cn;
  end
  else
  begin
    if c.IsBaseSchema then AddError(Result, Format(rsAsBase, [c.Name]));
    if c.IsDefunct then AddError(Result, Format(rsAsAlreadyDefunct, [c.Name]));
    dn := c.Cn;
  end;
  AddWarning(Result, rsAsDefunctNote);
  Result.Ok := Length(Result.Errors) = 0;
  if not Result.Ok then Exit;
  Result.Change := NewChange(ckModify, SchemaChildDn(AMeta, dn));
  Result.Change.AddMod(moReplace, 'isDefunct', ['TRUE']);
  Result.Refresh := RefreshChange;
end;

end.
