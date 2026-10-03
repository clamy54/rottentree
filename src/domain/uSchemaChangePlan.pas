// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSchemaChangePlan;

{$mode objfpc}{$H+}

// Plans de modification du schema. OpenLDAP: entrees olcSchemaConfig sous
// cn=config, schemas distribues proteges. 389 DS: seules les definitions
// X-ORIGIN 'user defined' bougent. Ailleurs, consultation et export LDIF.
// Une modification vise la valeur exacte, sans cascade.

interface

uses
  SysUtils, Classes, uLdapSchema, uSchemaDefinition, uChangeSet, uConnectionProfile, uLdapEntry;

type
  TSchemaAdapterKind = (sakConsultOnly, sakOpenLdapConfig, sak389Ds, sakActiveDirectory);
  TSchemaOp = (soCreate, soModify, soDelete);

  TSchemaCapabilities = record
    Adapter: TSchemaAdapterKind;
    Context: string;
    Supported: array[TSchemaOp] of Boolean;
    Qualified: array[TSchemaOp] of Boolean;
    Reason: array[TSchemaOp] of string;
  end;

  TSchemaSource = record
    Known: Boolean;
    EntryDn: string;
    Attribute: string;
    RawValue: string;
    System: Boolean;
    NewEntry: Boolean;
  end;

  TDependency = record
    Relation: string;
    Name: string;
  end;

  TDependencyReport = record
    Items: array of TDependency;
    SchemaComplete: Boolean;
    Coverage: string;
  end;

  TSchemaIssue = record
    IsError: Boolean;
    Text: string;
  end;
  TSchemaIssues = array of TSchemaIssue;

  TSchemaChangePlan = class
  public
    Operation: TSchemaOp;
    Kind: TDefinitionKind;
    Adapter: TSchemaAdapterKind;
    Before, After: string;
    Source: TSchemaSource;
    SchemaKey: string;
    Issues: TSchemaIssues;
    Dependencies: TDependencyReport;
    Change: TLdapChange;
    Extra: TLdapChange;
    Sendable: Boolean;
    Reason: string;
    destructor Destroy; override;
    function Ldif: string;
    function HasErrors: Boolean;
  end;

resourcestring
  rsScNotQualified = 'not qualified against a real %s server: the plan can be exported as LDIF but is not sent';
  rsScConsultOnly = 'this server type has no qualified schema adapter: consultation and export only';
  rsScAdLater = 'changing the properties of an Active Directory schema object is not available in this version';
  rsScNotEditable = 'the definition cannot be changed safely: %s';
  rsScOidUsed = 'OID %s is already used by %s';
  rsScOidChanged = 'the OID of an existing definition cannot change';
  rsScOidPrivate = 'use an OID from the arc your organization administers';
  rsScNameUsed = 'name %s is already used by %s';
  rsScNoName = 'the definition has no NAME: it can only be referred to by its OID';
  rsScSupMissing = 'superior %s is not defined';
  rsScSupSelf = 'a definition cannot be its own superior';
  rsScCycle = 'superior %s leads back to this definition (cycle)';
  rsScNoSyntax = 'an attribute type needs a SYNTAX or a superior (SUP)';
  rsScSyntaxUnknown = 'syntax %s is not described by the server; the server decides';
  rsScRuleMissing = 'matching rule %s is not defined';
  rsScCollective = 'a COLLECTIVE attribute must have the usage userApplications';
  rsScAttrMissing = 'attribute %s is not defined';
  rsScKindSup = 'a %s class cannot inherit from %s class %s';
  rsScSystem = '%s is a system definition: it is not changed';
  rsScSourceUnknown = 'the entry holding this definition on the server is unknown: it cannot be targeted';
  rsScTargetUnknown = 'the schema entries under cn=config were not read completely: the target entry cannot be chosen';
  rsScInUse = 'still used: %s';
  rsScEntriesNotSearched = 'entries using it were not searched: absence of use is not established';
  rsScSchemaErrors = 'the schema was read with %d error(s): dependencies may be incomplete';
  rsScStale = 'the schema changed since the plan was checked: check it again';
  rsDepRequired = 'required by class';
  rsDepAllowed = 'allowed by class';
  rsDepSubtype = 'attribute derived from it';
  rsDepSubclass = 'class derived from it';

function DetectSchemaCapabilities(AKind: TProviderKind; ARootDse: TLdapEntry): TSchemaCapabilities;
function IsOpenLdapSystemSchema(const AEntryDn: string): Boolean;
function LocateSource(AAdapter: TSchemaAdapterKind; const AEntryDn, AAttribute: string;
  const AValues: array of string; const AOid: string; out ASource: TSchemaSource): Boolean;
function StripOrderPrefix(const AValue: string; out APrefix: string): string;
function ValidateDefinition(ASchema: TSchemaSnapshot; ADef: TSchemaDefinition; AIsNew: Boolean;
  const AOriginalOid: string): TSchemaIssues;
function FindDependencies(ASchema: TSchemaSnapshot; AKind: TDefinitionKind;
  const ANameOrOid: string): TDependencyReport;
function BuildSchemaPlan(ASchema: TSchemaSnapshot; const ACaps: TSchemaCapabilities; AOp: TSchemaOp;
  ABefore, AAfter: TSchemaDefinition; const ASource: TSchemaSource): TSchemaChangePlan;
function PlanStillValid(APlan: TSchemaChangePlan; ASchema: TSchemaSnapshot; out AReason: string): Boolean;

implementation

uses
  uEntryCreationPlan, uLdif, uSyntaxInfo;

const
  OPENLDAP_SYSTEM: array[0..15] of string = ('core', 'cosine', 'inetorgperson', 'nis', 'misc',
    'openldap', 'dyngroup', 'duaconf', 'java', 'corba', 'collective', 'pmi', 'ppolicy', 'dsee',
    'msuser', 'namedobject');

destructor TSchemaChangePlan.Destroy;
begin
  Change.Free;
  Extra.Free;
  inherited Destroy;
end;

function TSchemaChangePlan.Ldif: string;
begin
  if Change = nil then Exit('');
  Result := string(LdifChangeToString(Change));
  if Extra <> nil then Result := Result + LineEnding + string(LdifChangeToString(Extra));
end;

function TSchemaChangePlan.HasErrors: Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Issues) do
    if Issues[i].IsError then Exit(True);
  Result := False;
end;

procedure AddIssue(var AIssues: TSchemaIssues; AError: Boolean; const AText: string);
begin
  SetLength(AIssues, Length(AIssues) + 1);
  AIssues[High(AIssues)].IsError := AError;
  AIssues[High(AIssues)].Text := AText;
end;

function DetectSchemaCapabilities(AKind: TProviderKind; ARootDse: TLdapEntry): TSchemaCapabilities;
var
  op: TSchemaOp;
  hasConfig: Boolean;
begin
  Result := Default(TSchemaCapabilities);
  Result.Adapter := sakConsultOnly;
  hasConfig := (ARootDse <> nil) and SameText(string(ARootDse.FirstValue('configContext', '')), 'cn=config');
  case AKind of
    pkOpenLdap:
      if hasConfig then
      begin
        Result.Adapter := sakOpenLdapConfig;
        Result.Context := 'cn=schema,cn=config';
      end;
    pk389Ds:
      begin
        Result.Adapter := sak389Ds;
        Result.Context := 'cn=schema';
      end;
    pkActiveDirectory:
      Result.Adapter := sakActiveDirectory;
  end;
  for op := Low(TSchemaOp) to High(TSchemaOp) do
  begin
    Result.Supported[op] := (Result.Adapter in [sakOpenLdapConfig, sak389Ds]) or
      ((Result.Adapter = sakActiveDirectory) and (op in [soCreate, soDelete]));
    // Aucune ecriture n'a ete verifiee contre un vrai serveur de ce type: le plan
    // s'exporte, il ne s'envoie pas. Le schema n'est pas un bac a sable.
    Result.Qualified[op] := False;
    case Result.Adapter of
      sakOpenLdapConfig: Result.Reason[op] := Format(rsScNotQualified, ['OpenLDAP']);
      sak389Ds: Result.Reason[op] := Format(rsScNotQualified, ['389 Directory Server']);
      sakActiveDirectory:
        if op = soModify then Result.Reason[op] := rsScAdLater
        else Result.Reason[op] := Format(rsScNotQualified, ['Active Directory']);
    else
      Result.Reason[op] := rsScConsultOnly;
    end;
  end;
end;

function IsOpenLdapSystemSchema(const AEntryDn: string): Boolean;
var
  rdn, name: string;
  p, q, i: Integer;
begin
  Result := False;
  p := Pos(',', AEntryDn);
  if p = 0 then Exit;
  rdn := LowerCase(Trim(Copy(AEntryDn, 1, p - 1)));
  if Copy(rdn, 1, 3) <> 'cn=' then Exit;
  name := Copy(rdn, 4, MaxInt);
  if (name <> '') and (name[1] = '{') then
  begin
    q := Pos('}', name);
    if q > 0 then name := Copy(name, q + 1, MaxInt);
  end;
  for i := 0 to High(OPENLDAP_SYSTEM) do
    if name = OPENLDAP_SYSTEM[i] then Exit(True);
end;

function StripOrderPrefix(const AValue: string; out APrefix: string): string;
var
  q: Integer;
begin
  APrefix := '';
  Result := AValue;
  if (AValue <> '') and (AValue[1] = '{') then
  begin
    q := Pos('}', AValue);
    if q > 0 then
    begin
      APrefix := Copy(AValue, 1, q);
      Result := Copy(AValue, q + 1, MaxInt);
    end;
  end;
end;

function LocateSource(AAdapter: TSchemaAdapterKind; const AEntryDn, AAttribute: string;
  const AValues: array of string; const AOid: string; out ASource: TSchemaSource): Boolean;
var
  i: Integer;
  body, prefix: string;
  d: TSchemaDefinition;
  origin: TStringArray;
  j: Integer;
  kind: TDefinitionKind;
begin
  ASource := Default(TSchemaSource);
  Result := False;
  if SameText(AAttribute, 'olcObjectClasses') or SameText(AAttribute, 'objectClasses') then
    kind := dkClass
  else
    kind := dkAttribute;
  for i := 0 to High(AValues) do
  begin
    body := StripOrderPrefix(AValues[i], prefix);
    d := TSchemaDefinition.Create(kind, body);
    try
      if d.Oid <> AOid then Continue;
      ASource.Known := True;
      ASource.EntryDn := AEntryDn;
      ASource.Attribute := AAttribute;
      ASource.RawValue := AValues[i];
      case AAdapter of
        sakOpenLdapConfig: ASource.System := IsOpenLdapSystemSchema(AEntryDn);
        sak389Ds:
          begin
            ASource.System := True;
            origin := d.Values('X-ORIGIN');
            for j := 0 to High(origin) do
              if SameText(origin[j], 'user defined') then ASource.System := False;
          end;
      else
        ASource.System := True;
      end;
      Exit(True);
    finally
      d.Free;
    end;
  end;
end;

function Described(ASchema: TSchemaSnapshot; const AOid: string): string;
var
  a: TSchemaAttributeType;
  c: TSchemaObjectClass;
begin
  a := ASchema.AttributeType(AOid);
  if a <> nil then Exit('attribute type ' + a.PrimaryName);
  c := ASchema.ObjectClass(AOid);
  if c <> nil then Exit('object class ' + c.PrimaryName);
  if ASchema.MatchingRule(AOid) <> nil then Exit('matching rule ' + ASchema.MatchingRule(AOid).PrimaryName);
  if ASchema.Syntax(AOid) <> nil then Exit('syntax ' + AOid);
  Result := '';
end;

function ValidateDefinition(ASchema: TSchemaSnapshot; ADef: TSchemaDefinition; AIsNew: Boolean;
  const AOriginalOid: string): TSchemaIssues;
var
  names, sups, list: TStringArray;
  i, j, depth: Integer;
  used, synOid, usage, n1, n2: string;
  a: TSchemaAttributeType;
  c, sc: TSchemaObjectClass;
  len: Integer;
  cur: string;
  kind, supKind: string;

  function IsSelf(const AName: string): Boolean;
  var
    k: Integer;
  begin
    if SameText(AName, ADef.Oid) then Exit(True);
    for k := 0 to High(names) do
      if SameText(names[k], AName) then Exit(True);
    Result := False;
  end;

  function OtherHolder(const AName: string): string;
  var
    x: TSchemaAttributeType;
    y: TSchemaObjectClass;
  begin
    Result := '';
    if ADef.Kind = dkAttribute then
    begin
      x := ASchema.AttributeType(AName);
      if (x <> nil) and (AIsNew or (x.Oid <> AOriginalOid)) then Result := 'attribute type ' + x.PrimaryName;
    end
    else
    begin
      y := ASchema.ObjectClass(AName);
      if (y <> nil) and (AIsNew or (y.Oid <> AOriginalOid)) then Result := 'object class ' + y.PrimaryName;
    end;
  end;

  function KindText(AClass: TSchemaObjectClass): string;
  begin
    case AClass.Kind of
      ockAbstract: Result := 'abstract';
      ockAuxiliary: Result := 'auxiliary';
    else
      Result := 'structural';
    end;
  end;

begin
  Result := nil;
  if not ADef.Editable then
  begin
    AddIssue(Result, True, Format(rsScNotEditable, [ADef.Reason]));
    Exit;
  end;
  if not IsNumericOidText(ADef.Oid) then
    AddIssue(Result, True, rsScOidPrivate)
  else if AIsNew then
  begin
    used := Described(ASchema, ADef.Oid);
    if used <> '' then AddIssue(Result, True, Format(rsScOidUsed, [ADef.Oid, used]));
  end
  else if ADef.Oid <> AOriginalOid then
    AddIssue(Result, True, rsScOidChanged);
  names := ADef.Values('NAME');
  if Length(names) = 0 then AddIssue(Result, False, rsScNoName);
  for i := 0 to High(names) do
  begin
    used := OtherHolder(names[i]);
    if used <> '' then AddIssue(Result, True, Format(rsScNameUsed, [names[i], used]));
    for j := i + 1 to High(names) do
      if SameText(names[i], names[j]) then AddIssue(Result, True, Format(rsScNameUsed, [names[j], names[i]]));
  end;
  if ADef.Kind = dkAttribute then
  begin
    cur := ADef.Value('SUP');
    if cur <> '' then
    begin
      if IsSelf(cur) then AddIssue(Result, True, rsScSupSelf)
      else
      begin
        a := ASchema.AttributeType(cur);
        if a = nil then AddIssue(Result, True, Format(rsScSupMissing, [cur]))
        else
        begin
          depth := 0;
          while (a <> nil) and (depth < SCHEMA_MAX_SUP_DEPTH) do
          begin
            if (not AIsNew and (a.Oid = AOriginalOid)) or IsSelf(a.PrimaryName) then
            begin
              AddIssue(Result, True, Format(rsScCycle, [cur]));
              Break;
            end;
            if a.Sup = '' then Break;
            a := ASchema.AttributeType(a.Sup);
            Inc(depth);
          end;
        end;
      end;
    end;
    synOid := ADef.Value('SYNTAX');
    if (synOid = '') and (cur = '') then AddIssue(Result, True, rsScNoSyntax);
    if synOid <> '' then
    begin
      synOid := SplitSyntaxLength(synOid, len);
      if (ASchema.Syntax(synOid) = nil) and not SyntaxDescription(synOid, n1, n2) then
        AddIssue(Result, False, Format(rsScSyntaxUnknown, [synOid]));
    end;
    for i := 0 to 2 do
    begin
      case i of
        0: cur := ADef.Value('EQUALITY');
        1: cur := ADef.Value('ORDERING');
      else
        cur := ADef.Value('SUBSTR');
      end;
      if cur = '' then Continue;
      if ASchema.MatchingRule(cur) = nil then
        // Un serveur qui ne publie pas ses matchingRules ne prouve pas leur absence.
        AddIssue(Result, ASchema.MatchingRule('caseIgnoreMatch') <> nil, Format(rsScRuleMissing, [cur]));
    end;
    usage := ADef.Value('USAGE');
    if ADef.Has('COLLECTIVE') and (usage <> '') and (usage <> 'userApplications') then
      AddIssue(Result, True, rsScCollective);
  end
  else
  begin
    if ADef.Has('ABSTRACT') then kind := 'abstract'
    else if ADef.Has('AUXILIARY') then kind := 'auxiliary'
    else kind := 'structural';
    sups := ADef.Values('SUP');
    for i := 0 to High(sups) do
    begin
      if IsSelf(sups[i]) then
      begin
        AddIssue(Result, True, rsScSupSelf);
        Continue;
      end;
      sc := ASchema.ObjectClass(sups[i]);
      if sc = nil then
      begin
        AddIssue(Result, True, Format(rsScSupMissing, [sups[i]]));
        Continue;
      end;
      supKind := KindText(sc);
      if (supKind <> 'abstract') and (supKind <> kind) then
        AddIssue(Result, True, Format(rsScKindSup, [kind, supKind, sc.PrimaryName]));
      if not AIsNew then
      begin
        list := nil;
        if InheritanceChain(ASchema, sups[i], list, used) then
          for j := 0 to High(list) do
          begin
            c := ASchema.ObjectClass(list[j]);
            if (c <> nil) and (c.Oid = AOriginalOid) then
              AddIssue(Result, True, Format(rsScCycle, [sups[i]]));
          end;
      end;
    end;
    for i := 0 to 1 do
    begin
      if i = 0 then list := ADef.Values('MUST') else list := ADef.Values('MAY');
      for j := 0 to High(list) do
        if ASchema.AttributeType(list[j]) = nil then
          AddIssue(Result, True, Format(rsScAttrMissing, [list[j]]));
    end;
  end;
end;

function MentionsAny(const AList: array of string; ASchema: TSchemaSnapshot; const AOid: string): Boolean;
var
  i: Integer;
  a: TSchemaAttributeType;
begin
  for i := 0 to High(AList) do
  begin
    a := ASchema.AttributeType(AList[i]);
    if ((a <> nil) and (a.Oid = AOid)) or SameText(AList[i], AOid) then Exit(True);
  end;
  Result := False;
end;

function FindDependencies(ASchema: TSchemaSnapshot; AKind: TDefinitionKind;
  const ANameOrOid: string): TDependencyReport;
var
  i, j: Integer;
  oid: string;
  a, x: TSchemaAttributeType;
  c, y: TSchemaObjectClass;

  procedure Add(const ARelation, AName: string);
  begin
    SetLength(Result.Items, Length(Result.Items) + 1);
    Result.Items[High(Result.Items)].Relation := ARelation;
    Result.Items[High(Result.Items)].Name := AName;
  end;

begin
  Result := Default(TDependencyReport);
  Result.SchemaComplete := ASchema.Errors.Count = 0;
  if AKind = dkAttribute then
  begin
    a := ASchema.AttributeType(ANameOrOid);
    if a = nil then Exit;
    oid := a.Oid;
    for i := 0 to ASchema.ObjectClassCount - 1 do
    begin
      c := ASchema.ObjectClassAt(i);
      if MentionsAny(c.Must, ASchema, oid) then Add(rsDepRequired, c.PrimaryName)
      else if MentionsAny(c.May, ASchema, oid) then Add(rsDepAllowed, c.PrimaryName);
    end;
    for i := 0 to ASchema.AttributeTypeCount - 1 do
    begin
      x := ASchema.AttributeTypeAt(i);
      if (x.Sup <> '') and (ASchema.AttributeType(x.Sup) <> nil) and (ASchema.AttributeType(x.Sup).Oid = oid) then
        Add(rsDepSubtype, x.PrimaryName);
    end;
  end
  else
  begin
    c := ASchema.ObjectClass(ANameOrOid);
    if c = nil then Exit;
    for i := 0 to ASchema.ObjectClassCount - 1 do
    begin
      y := ASchema.ObjectClassAt(i);
      for j := 0 to High(y.Sups) do
        if (ASchema.ObjectClass(y.Sups[j]) <> nil) and (ASchema.ObjectClass(y.Sups[j]).Oid = c.Oid) then
          Add(rsDepSubclass, y.PrimaryName);
    end;
  end;
  // Les entrees n'ont pas ete cherchees: on n'affirme pas qu'aucune ne s'en sert.
  Result.Coverage := rsScEntriesNotSearched;
  if not Result.SchemaComplete then
    Result.Coverage := Result.Coverage + '; ' + Format(rsScSchemaErrors, [ASchema.Errors.Count]);
end;

function SchemaAttributeName(AAdapter: TSchemaAdapterKind; AKind: TDefinitionKind): string;
begin
  if AAdapter = sakOpenLdapConfig then
  begin
    if AKind = dkClass then Result := 'olcObjectClasses' else Result := 'olcAttributeTypes';
  end
  else if AKind = dkClass then Result := 'objectClasses'
  else Result := 'attributeTypes';
end;

function BuildSchemaPlan(ASchema: TSchemaSnapshot; const ACaps: TSchemaCapabilities; AOp: TSchemaOp;
  ABefore, AAfter: TSchemaDefinition; const ASource: TSchemaSource): TSchemaChangePlan;
var
  issues: TSchemaIssues;
  i: Integer;
  attr, prefix, name, oid: string;
  deps: TDependencyReport;
  e: TLdapEntry;
begin
  Result := TSchemaChangePlan.Create;
  Result.Operation := AOp;
  Result.Adapter := ACaps.Adapter;
  Result.Source := ASource;
  Result.SchemaKey := SchemaIdentity(ASchema);
  if AAfter <> nil then
  begin
    Result.Kind := AAfter.Kind;
    Result.After := AAfter.Raw;
  end;
  if ABefore <> nil then
  begin
    Result.Kind := ABefore.Kind;
    Result.Before := ABefore.Raw;
  end;
  if AAfter <> nil then
  begin
    if ABefore <> nil then oid := ABefore.Oid else oid := '';
    issues := ValidateDefinition(ASchema, AAfter, AOp = soCreate, oid);
    for i := 0 to High(issues) do
      AddIssue(Result.Issues, issues[i].IsError, issues[i].Text);
  end;
  if (AOp = soCreate) and (ACaps.Adapter = sakOpenLdapConfig) and (ASource.EntryDn = '') then
    AddIssue(Result.Issues, True, rsScTargetUnknown);
  if AOp in [soModify, soDelete] then
  begin
    if not ASource.Known then AddIssue(Result.Issues, True, rsScSourceUnknown)
    else if ASource.System then
    begin
      if ABefore <> nil then name := ABefore.Value('NAME') else name := '';
      if name = '' then name := ASource.RawValue;
      AddIssue(Result.Issues, True, Format(rsScSystem, [name]));
    end;
  end;
  if (AOp = soDelete) and (ABefore <> nil) then
  begin
    if ABefore.Value('NAME') <> '' then name := ABefore.Value('NAME') else name := ABefore.Oid;
    deps := FindDependencies(ASchema, ABefore.Kind, name);
    Result.Dependencies := deps;
    // Suppression bloquee par toute dependance connue. Pas de cascade: le schema
    // n'a pas de corbeille.
    for i := 0 to High(deps.Items) do
      AddIssue(Result.Issues, True, Format(rsScInUse, [deps.Items[i].Relation + ' ' + deps.Items[i].Name]));
    AddIssue(Result.Issues, False, deps.Coverage);
  end;
  attr := SchemaAttributeName(ACaps.Adapter, Result.Kind);
  case AOp of
    soCreate:
      if ACaps.Adapter = sakOpenLdapConfig then
      begin
        if ASource.NewEntry then
        begin
          Result.Change := NewChange(ckAdd, ASource.EntryDn);
          e := Result.Change.Entry;
          e.Dn := ASource.EntryDn;
          e.Ensure('objectClass').AddValue('olcSchemaConfig');
          e.Ensure('cn').AddValue(Copy(ASource.EntryDn, 4, Pos(',', ASource.EntryDn) - 4));
          e.Ensure(attr).AddValue(AAfter.Raw);
        end
        else if ASource.EntryDn <> '' then
        begin
          Result.Change := NewChange(ckModify, ASource.EntryDn);
          Result.Change.AddMod(moAdd, attr, [RawByteString(AAfter.Raw)]);
        end;
      end
      else if ACaps.Adapter = sak389Ds then
      begin
        Result.Change := NewChange(ckModify, ACaps.Context);
        Result.Change.AddMod(moAdd, attr, [RawByteString(AAfter.Raw)]);
      end;
    soModify:
      if ASource.Known and (AAfter <> nil) then
      begin
        // Valeur ordonnee OpenLDAP: le prefixe {n} garde la place de la definition
        // dans son entree.
        StripOrderPrefix(ASource.RawValue, prefix);
        Result.Change := NewChange(ckModify, ASource.EntryDn);
        Result.Change.AddMod(moDelete, ASource.Attribute, [RawByteString(ASource.RawValue)]);
        Result.Change.AddMod(moAdd, ASource.Attribute, [RawByteString(prefix + AAfter.Raw)]);
      end;
    soDelete:
      if ASource.Known then
      begin
        Result.Change := NewChange(ckModify, ASource.EntryDn);
        Result.Change.AddMod(moDelete, ASource.Attribute, [RawByteString(ASource.RawValue)]);
      end;
  end;
  if Result.HasErrors then
    Result.Reason := Result.Issues[0].Text
  else if not ACaps.Supported[AOp] or not ACaps.Qualified[AOp] then
    Result.Reason := ACaps.Reason[AOp];
  Result.Sendable := (Result.Change <> nil) and not Result.HasErrors and ACaps.Supported[AOp] and
    ACaps.Qualified[AOp];
end;

function PlanStillValid(APlan: TSchemaChangePlan; ASchema: TSchemaSnapshot; out AReason: string): Boolean;
begin
  Result := (ASchema <> nil) and (SchemaIdentity(ASchema) = APlan.SchemaKey);
  if Result then AReason := '' else AReason := rsScStale;
end;

end.
