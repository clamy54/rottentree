// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdifTargetCheck;

{$mode objfpc}{$H+}

// Confronte un enregistrement LDIF au schema lu de la cible, comme le serveur le fera:
// types geres par le serveur, types inconnus, classes, obligations, syntaxes, RDN.
// Avertissements seulement. Le serveur reste juge, et un schema lu a moitie n'a pas voix
// au chapitre.

interface

uses
  SysUtils, Classes, uChangeSet, uLdapEntry, uLdapSchema, uConnectionProfile;

type
  TTargetFinding = record
    ServerManaged: TStringArray;
    Unknown: TStringArray;
  end;

type
  TSchemaIssueKind = (
    sikUnknownClass,
    sikClassProblem,
    sikNoStructural,
    sikMissingRequired,
    sikNotAllowed,
    sikBadValue,
    sikSingleValue,
    sikRdnValue);

  TSchemaIssue = record
    Kind: TSchemaIssueKind;
    Attr: string;
    Value: string;
    Detail: string;
    SyntaxName: string;
    SyntaxOid: string;
    Count: Integer;
    Classes: TStringArray;
    Suggest: TStringArray;
    SuggestMust: TStringArray;
    // False: schema incomplet (AD sans metadonnees, erreurs de lecture). Le serveur peut
    // accepter, on se contente de prevenir.
    Certain: Boolean;
  end;
  TSchemaIssueArray = array of TSchemaIssue;

function CheckContentAgainstSchema(AChange: TLdapChange; ASchema: TSchemaSnapshot;
  AProvider: TProviderKind): TSchemaIssueArray;

function CheckChangeAgainstSchema(AChange: TLdapChange; ASchema: TSchemaSnapshot): TTargetFinding;
function FindingIsEmpty(const AFinding: TTargetFinding): Boolean;
// Type produit par le serveur: NO-USER-MODIFICATION dans le schema lu, ou operationnel
// connu d'OpenLDAP, 389 DS, ApacheDS ou AD quand le schema se tait. Les operationnels
// modifiables (pwdPolicySubentry...) n'en sont pas.
function IsServerManagedAttribute(ASchema: TSchemaSnapshot; const AAttr: string): Boolean;
function StripServerManaged(AEntry: TLdapEntry; ASchema: TSchemaSnapshot): TStringArray;
function JoinNames(const ANames: TStringArray): string;

implementation

uses
  uEntryCreationPlan, uAttributeCodec, uLdapDn, uLdapSyntaxCheck, uSyntaxInfo, uMatchingRules;

const
  KNOWN_SERVER_MANAGED: array[0..29] of string = (
    'createtimestamp', 'modifytimestamp', 'creatorsname', 'modifiersname',
    'entrycsn', 'entryuuid', 'entrydn', 'hassubordinates', 'subschemasubentry',
    'structuralobjectclass', 'contextcsn', 'numsubordinates', 'nsuniqueid',
    'entryid', 'parentid', 'entryusn', 'nscpentrydn',
    'entryparentid', 'nbchildren', 'nbsubordinates',
    'whencreated', 'whenchanged', 'usncreated', 'usnchanged', 'objectguid',
    'dscorepropagationdata', 'replpropertymetadata', 'pwdchangedtime',
    'pwdfailuretime', 'pwdhistory');

function IsServerManagedAttribute(ASchema: TSchemaSnapshot; const AAttr: string): Boolean;
var
  base, low: string;
  i: Integer;
begin
  base := AttrBaseName(AAttr);
  if (ASchema <> nil) and (ASchema.AttributeType(base) <> nil) then
    Exit(ASchema.IsNoUserModification(base));
  low := LowerCase(base);
  for i := 0 to High(KNOWN_SERVER_MANAGED) do
    if KNOWN_SERVER_MANAGED[i] = low then Exit(True);
  Result := False;
end;

function StripServerManaged(AEntry: TLdapEntry; ASchema: TSchemaSnapshot): TStringArray;
var
  i: Integer;
  names: TStringArray;
begin
  Result := nil;
  if AEntry = nil then Exit;
  names := nil;
  for i := 0 to AEntry.AttrCount - 1 do
    if IsServerManagedAttribute(ASchema, AEntry.Attrs[i].Description) then
    begin
      SetLength(names, Length(names) + 1);
      names[High(names)] := AEntry.Attrs[i].Description;
    end;
  for i := 0 to High(names) do
    AEntry.Remove(names[i]);
  Result := names;
end;

procedure AddOnce(var AList: TStringArray; const AName: string);
var
  i: Integer;
begin
  for i := 0 to High(AList) do
    if SameText(AList[i], AName) then Exit;
  SetLength(AList, Length(AList) + 1);
  AList[High(AList)] := AName;
end;

procedure CheckAttr(ASchema: TSchemaSnapshot; const ADescription: string; var AFinding: TTargetFinding);
var
  base: string;
begin
  base := AttrBaseName(ADescription);
  if base = '' then Exit;
  if IsServerManagedAttribute(ASchema, base) then
    AddOnce(AFinding.ServerManaged, base)
  else if ASchema.AttributeType(base) = nil then
    AddOnce(AFinding.Unknown, base);
end;

function CheckChangeAgainstSchema(AChange: TLdapChange; ASchema: TSchemaSnapshot): TTargetFinding;
var
  i: Integer;
begin
  Result.ServerManaged := nil;
  Result.Unknown := nil;
  if (AChange = nil) or (ASchema = nil) then Exit;
  case AChange.Kind of
    ckAdd:
      if AChange.Entry <> nil then
        for i := 0 to AChange.Entry.AttrCount - 1 do
          CheckAttr(ASchema, AChange.Entry.Attrs[i].Description, Result);
    ckModify:
      for i := 0 to High(AChange.Mods) do
        CheckAttr(ASchema, AChange.Mods[i].Attr, Result);
  end;
end;

function FindingIsEmpty(const AFinding: TTargetFinding): Boolean;
begin
  Result := (Length(AFinding.ServerManaged) = 0) and (Length(AFinding.Unknown) = 0);
end;

procedure AddStr(var AList: TStringArray; const S: string);
begin
  SetLength(AList, Length(AList) + 1);
  AList[High(AList)] := S;
end;

function NewIssue(AKind: TSchemaIssueKind; const AAttr: string; ACertain: Boolean): TSchemaIssue;
begin
  Result.Kind := AKind;
  Result.Attr := AAttr;
  Result.Value := '';
  Result.Detail := '';
  Result.SyntaxName := '';
  Result.SyntaxOid := '';
  Result.Count := 0;
  Result.Classes := nil;
  Result.Suggest := nil;
  Result.SuggestMust := nil;
  Result.Certain := ACertain;
end;

procedure Push(var AIssues: TSchemaIssueArray; const AIssue: TSchemaIssue);
begin
  SetLength(AIssues, Length(AIssues) + 1);
  AIssues[High(AIssues)] := AIssue;
end;

function RequirementOf(const AAnalysis: TClassAnalysis; ASchema: TSchemaSnapshot;
  const AAttr: string): Integer;
var
  at: TSchemaAttributeType;
  i: Integer;
begin
  at := ASchema.AttributeType(AttrBaseName(AAttr));
  for i := 0 to High(AAnalysis.Requirements) do
    if ((at <> nil) and (AAnalysis.Requirements[i].Oid <> '') and
        SameText(AAnalysis.Requirements[i].Oid, at.Oid)) or
       SameText(AAnalysis.Requirements[i].Name, AttrBaseName(AAttr)) then
      Exit(i);
  Result := -1;
end;

function ClassesAllowing(ASchema: TSchemaSnapshot; const AAttr: string): TStringArray;
var
  pass, i, j: Integer;
  oc: TSchemaObjectClass;
  at: TSchemaAttributeType;
  hit: Boolean;

  function Same(const AName: string): Boolean;
  var
    other: TSchemaAttributeType;
  begin
    other := ASchema.AttributeType(AName);
    if (at <> nil) and (other <> nil) then Result := other = at
    else Result := SameText(AName, AAttr);
  end;

begin
  Result := nil;
  at := ASchema.AttributeType(AAttr);
  for pass := 0 to 1 do
    for i := 0 to ASchema.ObjectClassCount - 1 do
    begin
      if Length(Result) >= 3 then Exit;
      oc := ASchema.ObjectClassAt(i);
      if oc.Obsolete then Continue;
      if (pass = 0) <> (oc.Kind = ockAuxiliary) then Continue;
      hit := False;
      for j := 0 to High(oc.Must) do
        if Same(oc.Must[j]) then hit := True;
      for j := 0 to High(oc.May) do
        if Same(oc.May[j]) then hit := True;
      if hit then AddStr(Result, oc.PrimaryName);
    end;
end;

function MustOf(ASchema: TSchemaSnapshot; const AClass: string): TStringArray;
var
  must, may: TStringList;
  i: Integer;
begin
  Result := nil;
  must := TStringList.Create;
  may := TStringList.Create;
  try
    ASchema.CollectAllowed([AClass], must, may);
    for i := 0 to must.Count - 1 do
      if not SameText(must[i], 'objectClass') then AddStr(Result, must[i]);
  finally
    must.Free;
    may.Free;
  end;
end;

function NameIn(const AName: string; const AList: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AList) do
    if SameText(AList[i], AName) then Exit(True);
  Result := False;
end;

// Le suffixe {n} n'est qu'une capacite minimale recommandee (RFC 4512 4.1.2): le depasser
// est un doute, pas un refus. La grammaire de la syntaxe, elle, ne se negocie pas.
procedure CheckValues(ASchema: TSchemaSnapshot; AProvider: TProviderKind; const AAttr: string;
  const AValues: array of RawByteString; var AIssues: TSchemaIssueArray);
var
  res: TValueResolution;
  err, syntax, synName, synExpl: string;
  i, maxLen, len: Integer;
  issue: TSchemaIssue;
  certain: Boolean;
begin
  if ASchema.AttributeType(AttrBaseName(AAttr)) = nil then Exit;
  res := ResolveValueKind(ASchema, AAttr, AProvider);
  syntax := EffectiveSyntaxAndLen(ASchema, AttrBaseName(AAttr), maxLen);
  for i := 0 to High(AValues) do
  begin
    certain := True;
    err := CheckSyntaxValue(syntax, 0, AValues[i]);
    if err = '' then err := ValidateValue(res, AValues[i]);
    if (err = '') and (maxLen > 0) and IsSyntaxChecked(syntax) then
    begin
      len := Utf8Length(AValues[i]);
      if len > maxLen then
      begin
        certain := False;
        err := Format('%d characters where the schema suggests at most %d ({%d} is a minimum ' +
          'capacity the server must support, not a hard limit: the server may accept this value)',
          [len, maxLen, maxLen]);
      end;
    end;
    if err = '' then Continue;
    issue := NewIssue(sikBadValue, AttrBaseName(AAttr), certain);
    issue.Value := string(AValues[i]);
    issue.Detail := err;
    issue.SyntaxOid := syntax;
    if SyntaxDescription(syntax, synName, synExpl) then
      issue.SyntaxName := synName
    else
      issue.SyntaxName := res.SyntaxName;
    if issue.SyntaxName = '' then issue.SyntaxName := ValueKindName(res.Kind);
    Push(AIssues, issue);
  end;
end;

function ValuesEqualByRule(AKind: TRuleKind; const A, B: RawByteString;
  out ADeterminate: Boolean): Boolean;
var
  na, nb: RawByteString;
begin
  ADeterminate := True;
  if A = B then Exit(True);
  if AKind = rkUnknown then
  begin
    ADeterminate := False;
    Exit(False);
  end;
  na := A;
  nb := B;
  if (NormalizeValue(AKind, A, na) <> nrOk) or (NormalizeValue(AKind, B, nb) <> nrOk) then
  begin
    ADeterminate := False;
    Exit(False);
  end;
  Result := na = nb;
end;

procedure CheckAdd(AEntry: TLdapEntry; ASchema: TSchemaSnapshot; AProvider: TProviderKind;
  var AIssues: TSchemaIssueArray);
var
  oca, a: TLdapAttribute;
  structural, aux, entryClasses: TStringArray;
  analysis: TClassAnalysis;
  oc: TSchemaObjectClass;
  i, j: Integer;
  certain, absenceCertain, found, determinate, doubt: Boolean;
  issue: TSchemaIssue;
  dn: TLdapDn;
  leaf: TDnRdn;
  values: array of RawByteString;
  rule, present: string;
  eq: TRuleKind;
begin
  // Une ABSENCE (classe ou permission introuvable) ne vaut refus certain que si le schema
  // a ete lu en entier. Ne pas trouver n'est pas prouver.
  certain := ASchema.Errors.Count = 0;
  absenceCertain := certain and ASchema.Complete;
  structural := nil;
  aux := nil;
  entryClasses := nil;
  oca := AEntry.Find('objectClass');
  if oca <> nil then
    for i := 0 to oca.ValueCount - 1 do
    begin
      AddStr(entryClasses, string(oca.Values[i]));
      oc := ASchema.ObjectClass(string(oca.Values[i]));
      if oc = nil then
      begin
        Push(AIssues, NewIssue(sikUnknownClass, string(oca.Values[i]), absenceCertain));
        Continue;
      end;
      case oc.Kind of
        ockStructural: AddStr(structural, string(oca.Values[i]));
        ockAuxiliary: AddStr(aux, string(oca.Values[i]));
      end;
    end;
  if Length(structural) = 0 then
  begin
    // 389 DS n'impose pas de classe structurelle (constate sur 2.4.6): simple doute.
    // OpenLDAP, ApacheDS et AD, eux, refusent.
    issue := NewIssue(sikNoStructural, '', absenceCertain and (AProvider <> pk389Ds));
    issue.Classes := entryClasses;
    Push(AIssues, issue);
    Exit;
  end;
  analysis := AnalyzeClasses(ASchema, structural, aux, AProvider);
  if not analysis.Ok then
  begin
    for i := 0 to High(analysis.Issues) do
      if analysis.Issues[i].Severity = isError then
      begin
        issue := NewIssue(sikClassProblem, '', absenceCertain);
        issue.Detail := analysis.Issues[i].Text;
        issue.Classes := entryClasses;
        Push(AIssues, issue);
      end;
    Exit;
  end;
  if analysis.AllowedIncomplete then absenceCertain := False;
  for i := 0 to High(analysis.Issues) do
    if (analysis.Issues[i].Severity = isWarning) and (Length(analysis.PartialChains) > 0) and
       (Pos('inherits from', analysis.Issues[i].Text) > 0) then
    begin
      issue := NewIssue(sikClassProblem, '', False);
      issue.Detail := analysis.Issues[i].Text;
      issue.Classes := entryClasses;
      Push(AIssues, issue);
    end;
  for i := 0 to High(analysis.Requirements) do
  begin
    if analysis.Requirements[i].Kind <> rqMust then Continue;
    if analysis.Requirements[i].Supply <> rsUser then Continue;
    if SameText(analysis.Requirements[i].Name, 'objectClass') then Continue;
    found := False;
    for j := 0 to AEntry.AttrCount - 1 do
      if (AEntry.Attrs[j].ValueCount > 0) and
         (RequirementOf(analysis, ASchema, AEntry.Attrs[j].Description) = i) then
        found := True;
    if not found then
    begin
      issue := NewIssue(sikMissingRequired, analysis.Requirements[i].Name, absenceCertain);
      issue.Detail := analysis.Requirements[i].Origin;
      Push(AIssues, issue);
    end;
  end;
  for i := 0 to AEntry.AttrCount - 1 do
  begin
    a := AEntry.Attrs[i];
    if SameText(a.BaseName, 'objectClass') then Continue;
    if IsServerManagedAttribute(ASchema, a.Description) then Continue;
    if ASchema.AttributeType(a.BaseName) = nil then Continue;
    // Interdit par une regle de contenu DIT (NOT): refus certain, extensibleObject n'y
    // deroge pas (RFC 4512 4.1.6).
    if IsPrecluded(analysis, ASchema, a.Description) then
    begin
      issue := NewIssue(sikNotAllowed, a.BaseName, True);
      issue.Classes := entryClasses;
      issue.Detail := 'precluded by the DIT content rule ' + analysis.ContentRule;
      Push(AIssues, issue);
    end
    // Operationnels (aci, pwdPolicySubentry...): hors du champ des classes (X.501).
    else if (not analysis.ExtensibleObject) and (RequirementOf(analysis, ASchema, a.Description) < 0) and
       not ASchema.IsOperational(a.BaseName) and
       not IsServerGeneratedOnCreate(AProvider, a.Description, rule) then
    begin
      issue := NewIssue(sikNotAllowed, a.BaseName, absenceCertain);
      issue.Classes := entryClasses;
      issue.Suggest := ClassesAllowing(ASchema, a.BaseName);
      if Length(issue.Suggest) > 0 then issue.SuggestMust := MustOf(ASchema, issue.Suggest[0]);
      Push(AIssues, issue);
    end;
    if ASchema.IsSingleValue(a.BaseName) and (a.ValueCount > 1) then
    begin
      issue := NewIssue(sikSingleValue, a.BaseName, True);
      issue.Count := a.ValueCount;
      Push(AIssues, issue);
    end;
    SetLength(values, a.ValueCount);
    for j := 0 to a.ValueCount - 1 do values[j] := a.Values[j];
    CheckValues(ASchema, AProvider, a.Description, values, AIssues);
  end;
  if DnTryParse(AEntry.Dn, dn) and (DnRdnCount(dn) > 0) then
  begin
    leaf := DnLeaf(dn);
    for i := 0 to High(leaf.Avas) do
    begin
      a := AEntry.Find(leaf.Avas[i].AttrType);
      found := False;
      doubt := False;
      present := '';
      eq := RuleKindFromName(ASchema.EffectiveEquality(leaf.Avas[i].AttrType));
      if a <> nil then
        for j := 0 to a.ValueCount - 1 do
        begin
          if present <> '' then present := present + ', ';
          present := present + string(a.Values[j]);
          if ValuesEqualByRule(eq, a.Values[j], leaf.Avas[i].Value, determinate) then found := True
          else if not determinate then doubt := True;
        end;
      // Absent: plusieurs serveurs l'ajoutent d'eux-memes. Present sans la valeur du nom:
      // refus (namingViolation), ou doute si la regle d'egalite ne sait pas conclure.
      if (a <> nil) and not found then
      begin
        issue := NewIssue(sikRdnValue, leaf.Avas[i].AttrType, certain and not doubt);
        issue.Value := string(leaf.Avas[i].Value);
        issue.Detail := present;
        Push(AIssues, issue);
      end;
    end;
  end;
end;

function CheckContentAgainstSchema(AChange: TLdapChange; ASchema: TSchemaSnapshot;
  AProvider: TProviderKind): TSchemaIssueArray;
var
  i, n: Integer;
  issue: TSchemaIssue;
begin
  Result := nil;
  if (AChange = nil) or (ASchema = nil) then Exit;
  case AChange.Kind of
    ckAdd:
      if AChange.Entry <> nil then CheckAdd(AChange.Entry, ASchema, AProvider, Result);
    ckModify:
      for i := 0 to High(AChange.Mods) do
      begin
        if AChange.Mods[i].Op = moDelete then Continue;
        if IsServerManagedAttribute(ASchema, AChange.Mods[i].Attr) then Continue;
        n := Length(AChange.Mods[i].Values);
        if (AChange.Mods[i].Op in [moAdd, moReplace]) and (n > 1) and
           ASchema.IsSingleValue(AttrBaseName(AChange.Mods[i].Attr)) then
        begin
          issue := NewIssue(sikSingleValue, AttrBaseName(AChange.Mods[i].Attr), True);
          issue.Count := n;
          Push(Result, issue);
        end;
        CheckValues(ASchema, AProvider, AChange.Mods[i].Attr, AChange.Mods[i].Values, Result);
      end;
  end;
end;

function JoinNames(const ANames: TStringArray): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(ANames) do
  begin
    if i > 0 then Result := Result + ', ';
    Result := Result + ANames[i];
  end;
end;

end.
