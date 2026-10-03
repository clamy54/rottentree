// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uEntryCreationPlan;

{$mode objfpc}{$H+}

// Plan de creation d'une entree: classes, obligations heritees, nommage, valeurs,
// etapes. Ce que le serveur pose lui-meme vient d'une regle nommee par fournisseur
// (AD: MS-ADTS 3.1.1.5.2.2), jamais du seul fait qu'un attribut est operationnel.
//
// Un compte AD nait desactive et s'active apres son mot de passe. LDAP n'a pas de
// transaction: un compte actif sans mot de passe est un cadeau, pas un etat.

interface

uses
  SysUtils, Classes, uLdapSchema, uLdapEntry, uLdapDn, uConnectionProfile, uSensitive;

const
  CREATE_MAX_CLASSES = 64;
  CREATE_MAX_CHAIN_NODES = 512;
  CREATE_MAX_RDN_AVAS = 8;

  CREATE_UF_ACCOUNTDISABLE = $2;
  CREATE_UF_NORMAL_ACCOUNT = $200;
  CREATE_UF_WORKSTATION_TRUST_ACCOUNT = $1000;

type
  TReqKind = (rqMust, rqMay);

  TReqSupply = (
    rsUser,
    rsPlan,
    rsServerGenerated,
    rsServerOnly);

  TAttrRequirement = record
    Name: string;
    Oid: string;
    Kind: TReqKind;
    Origin: string;
    Supply: TReqSupply;
    Rule: string;
    SingleValued: Boolean;
    Desc: string;
  end;
  TAttrRequirements = array of TAttrRequirement;

  TIssueSeverity = (isError, isWarning);

  TPlanIssue = record
    Severity: TIssueSeverity;
    Attr: string;
    Text: string;
  end;
  TPlanIssues = array of TPlanIssue;

  TClassAnalysis = record
    Ok: Boolean;
    Issues: TPlanIssues;
    ObjectClasses: array of string;
    MostSpecific: string;
    Requirements: TAttrRequirements;
    ExtensibleObject: Boolean;
    AllowedIncomplete: Boolean;
    Precluded: array of string;
    ContentRule: string;
    PartialChains: array of string;
  end;

  TRdnAva = record
    Attr: string;
    Value: RawByteString;
  end;
  TRdnAvas = array of TRdnAva;

  TCreationStepKind = (cskAdd, cskSetPassword, cskEnable);

  TStepOutcome = (
    sotPending,
    sotNotSent,
    sotRefused,
    sotApplied,
    sotAppliedUnverified,
    // Emise, issue inconnue: on relit avant toute reprise. Rejouer un Add a
    // l'aveugle, c'est fabriquer un doublon ou un message d'erreur trompeur.
    sotUnknown,
    sotSkipped);

  TCreationStep = record
    Kind: TCreationStepKind;
    Outcome: TStepOutcome;
    Detail: string;
    TaskId: Int64;
  end;

  TEntryCreationPlan = class
  private
    FValues: TLdapEntry;
  public
    // Le plan n'est soumis qu'a la session qui l'a vu naitre: reconnecte entre-temps,
    // c'est peut-etre un autre serveur, ou un autre compte.
    ProfileUuid: string;
    SessionId: string;
    Generation: Int64;
    SchemaKey: string;
    Provider: TProviderKind;
    ParentDn: string;
    Structural: array of string;
    Auxiliaries: array of string;
    Rdn: TRdnAvas;
    Steps: array of TCreationStep;
    // Secrets admis seulement s'ils sortent des outils de mot de passe. Un
    // userPassword tape en clair dans une grille finit toujours dans un LDIF.
    ComputedSecrets: array of string;
    constructor Create;
    destructor Destroy; override;
    property Values: TLdapEntry read FValues;
    procedure SetRdn(const AAttr: string; const AValue: RawByteString);
    procedure AddRdnAva(const AAttr: string; const AValue: RawByteString);
    function StepIndex(AKind: TCreationStepKind): Integer;
  end;

resourcestring
  rsCpUnknownClass = 'Unknown object class %s.';
  rsCpNoStructural = 'Choose a structural object class.';
  rsCpAbstract = '%s is an abstract class: it cannot be the structural class of an entry.';
  rsCpAuxiliaryAsStructural = '%s is an auxiliary class: it is added next to a structural class.';
  rsCpNotAuxiliary = '%s is not an auxiliary class.';
  rsCpAuxNotPermitted = 'The DIT content rule of %s does not permit the auxiliary class %s.';
  rsCpIncompatible = 'The structural classes %s and %s are on different branches: an entry has one structural chain.';
  rsCpCycle = 'The inheritance of %s is cyclic (SUP): the schema is inconsistent.';
  rsCpUnresolvedSup = '%s inherits from %s, which the schema does not define.';
  rsCpUnresolvedSupPartial = '%s The schema was read incompletely: the attributes required or ' +
    'allowed by the missing classes are unknown, the server decides.';
  rsCpIncompatibleMaybe = '%s and %s may be on different structural branches (schema read incompletely).';
  rsCpPrecluded = '%s is precluded by the DIT content rule %s.';
  rsCpTooDeep = 'The inheritance of %s is too deep or too wide.';
  rsCpUnknownAttr = '%s requires or allows %s, which the schema does not define.';
  rsCpNoSchema = 'The schema of the server is unavailable: the assistant cannot check the entry. Use an LDIF document instead.';
  rsCpSchemaIncomplete = 'The schema was read with errors (%d): checks may be incomplete.';
  rsCpSchemaPartial = 'The schema was read incompletely (%s): attributes outside the known lists are only warned about, the server decides.';
  rsCpAdMetaMissing = 'Active Directory schema metadata was not read: auxiliary classes attached by the schema are unknown, so extra attributes are only warned about.';
  rsCpRuleAd = 'set by Active Directory when the entry is added';
  rsCpRuleAdSam = 'generated by Active Directory when absent; supply it to choose the logon name';
  rsCpNoRdn = 'Choose the naming attribute and its value.';
  rsCpRdnEmpty = 'The naming value of %s is empty.';
  rsCpRdnNotAllowed = '%s is not allowed by the selected classes: it cannot name the entry.';
  rsCpRdnReadOnly = '%s cannot be set by a client: it cannot name the entry.';
  rsCpRdnDuplicate = '%s appears twice in the name.';
  rsCpRdnConflict = '%s is single-valued and already holds another value than the name.';
  rsCpRdnCase = 'The value of %s differs from the name only by case: use the same value.';
  rsCpBadParent = 'The parent DN is not valid: %s';
  rsCpBadName = 'The resulting DN is not valid: %s';
  rsCpMissing = '%s is required by %s.';
  rsCpServerOnlyRequired = '%s is required by %s but cannot be set by a client: the server must provide it, or the addition will fail.';
  rsCpNotAllowed = '%s is not allowed by the selected classes.';
  rsCpNotAllowedMaybe = '%s is not in the classes known to the assistant; the server decides.';
  rsCpReadOnly = '%s cannot be set by a client (%s).';
  rsCpSingle = '%s is single-valued but has %d values.';
  rsCpSyntax = '%s: %s';
  rsCpOverride = '%s is normally set by the server; the supplied value replaces it.';
  rsCpSecret = '%s is a secret: set it with the password tools (double click its value), never by typing it.';
  rsCpSecretAd = '%s: on Active Directory the password is set after the creation, as a separate step.';
  rsCpDisabled = 'The account is created disabled; enable it as a separate step once its password is set.';
  rsCpUacForcedDisabled = 'userAccountControl keeps the supplied bits but the account is created disabled.';
  rsCpUacInvalid = 'userAccountControl is not an integer.';

function FindClasses(ASchema: TSchemaSnapshot; const AFilter: string; AKind: TObjectClassKind;
  AMax: Integer): TStringArray;
function ClassMatchingAttributes(ASchema: TSchemaSnapshot; const AClass, AFilter: string;
  out ARequired, AAllowed: TStringArray): Boolean;
function InheritanceChain(ASchema: TSchemaSnapshot; const AClass: string; out AChain: TStringArray;
  out AIssue: string): Boolean;
function InheritanceChainEx(ASchema: TSchemaSnapshot; const AClass: string; out AChain: TStringArray;
  out AIssue: string; out AUnresolved: Boolean): Boolean;
function IsPrecluded(const AAnalysis: TClassAnalysis; ASchema: TSchemaSnapshot;
  const AAttr: string): Boolean;
function AnalyzeClasses(ASchema: TSchemaSnapshot; const AStructural, AAuxiliaries: array of string;
  AProvider: TProviderKind): TClassAnalysis;
function IsServerGeneratedOnCreate(AProvider: TProviderKind; const AAttr: string;
  out ARule: string): Boolean;
function DefaultRdnAttribute(const AAnalysis: TClassAnalysis): string;
function IsAdAccount(const AAnalysis: TClassAnalysis; AProvider: TProviderKind): Boolean;
// DN produit par le serialiseur, jamais par concatenation: une virgule dans un nom
// de famille ne doit pas creer une OU au passage.
function BuildCreationDn(const AParentDn: string; const ARdn: TRdnAvas; out ADn: string;
  out AError: string): Boolean;
function BuildCreationEntry(ASchema: TSchemaSnapshot; APlan: TEntryCreationPlan;
  const AAnalysis: TClassAnalysis; ASensitive: TSensitivePolicy; out AIssues: TPlanIssues): TLdapEntry;
function ValidateCreation(ASchema: TSchemaSnapshot; APlan: TEntryCreationPlan;
  const AAnalysis: TClassAnalysis; ASensitive: TSensitivePolicy): TPlanIssues;
function HasErrors(const AIssues: TPlanIssues): Boolean;
procedure PrepareSteps(APlan: TEntryCreationPlan; const AAnalysis: TClassAnalysis);
function SchemaIdentity(ASchema: TSchemaSnapshot): string;

implementation

uses
  uAdSchemaMeta, uAttributeCodec;

const
  AD_GENERATED: array[0..10] of string = ('instanceType', 'objectCategory', 'nTSecurityDescriptor',
    'objectGUID', 'name', 'distinguishedName', 'whenCreated', 'whenChanged', 'uSNCreated',
    'uSNChanged', 'objectSid');

procedure AddIssue(var AIssues: TPlanIssues; ASeverity: TIssueSeverity; const AAttr, AText: string);
begin
  SetLength(AIssues, Length(AIssues) + 1);
  AIssues[High(AIssues)].Severity := ASeverity;
  AIssues[High(AIssues)].Attr := AAttr;
  AIssues[High(AIssues)].Text := AText;
end;

function HasErrors(const AIssues: TPlanIssues): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AIssues) do
    if AIssues[i].Severity = isError then Exit(True);
  Result := False;
end;

function SameName(const A, B: string): Boolean;
begin
  Result := AsciiLowerCase(A) = AsciiLowerCase(B);
end;

function InArray(const AName: string; const AList: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AList) do
    if SameName(AList[i], AName) then Exit(True);
  Result := False;
end;

function SchemaIdentity(ASchema: TSchemaSnapshot): string;
begin
  Result := SchemaSnapshotKey(ASchema);
end;

constructor TEntryCreationPlan.Create;
begin
  inherited Create;
  FValues := TLdapEntry.Create('');
end;

destructor TEntryCreationPlan.Destroy;
begin
  FValues.Free;
  inherited Destroy;
end;

procedure TEntryCreationPlan.SetRdn(const AAttr: string; const AValue: RawByteString);
begin
  SetLength(Rdn, 1);
  Rdn[0].Attr := AAttr;
  Rdn[0].Value := AValue;
end;

procedure TEntryCreationPlan.AddRdnAva(const AAttr: string; const AValue: RawByteString);
begin
  SetLength(Rdn, Length(Rdn) + 1);
  Rdn[High(Rdn)].Attr := AAttr;
  Rdn[High(Rdn)].Value := AValue;
end;

function TEntryCreationPlan.StepIndex(AKind: TCreationStepKind): Integer;
var
  i: Integer;
begin
  for i := 0 to High(Steps) do
    if Steps[i].Kind = AKind then Exit(i);
  Result := -1;
end;

{ Classes }

function AttributeMatches(AAttr: TSchemaAttributeType; const AFilterLower: string): Boolean;
var
  n: Integer;
begin
  if AFilterLower = '' then Exit(False);
  Result := AsciiLowerCase(AAttr.Oid) = AFilterLower;
  for n := 0 to High(AAttr.Names) do
    if Pos(AFilterLower, AsciiLowerCase(AAttr.Names[n])) > 0 then Exit(True);
end;

function FindClasses(ASchema: TSchemaSnapshot; const AFilter: string; AKind: TObjectClassKind;
  AMax: Integer): TStringArray;
var
  i, j: Integer;
  oc: TSchemaObjectClass;
  f: string;
  hit, byAttr: Boolean;
  required, allowed: TStringArray;
  list: TStringList;
begin
  Result := nil;
  if ASchema = nil then Exit;
  f := AsciiLowerCase(Trim(AFilter));
  byAttr := False;
  for i := 0 to ASchema.AttributeTypeCount - 1 do
  begin
    if byAttr or (f = '') then Break;
    byAttr := AttributeMatches(ASchema.AttributeTypeAt(i), f);
  end;
  list := TStringList.Create;
  try
    list.Sorted := True;
    list.Duplicates := dupIgnore;
    list.CaseSensitive := False;
    for i := 0 to ASchema.ObjectClassCount - 1 do
    begin
      oc := ASchema.ObjectClassAt(i);
      if oc.Kind <> AKind then Continue;
      hit := (f = '') or (Pos(f, AsciiLowerCase(oc.Oid)) > 0) or (Pos(f, AsciiLowerCase(oc.Desc)) > 0);
      for j := 0 to High(oc.Names) do
        if Pos(f, AsciiLowerCase(oc.Names[j])) > 0 then hit := True;
      if not hit and byAttr then
        hit := ClassMatchingAttributes(ASchema, oc.PrimaryName, Trim(AFilter), required, allowed);
      if hit then list.Add(oc.PrimaryName);
      if list.Count >= AMax then Break;
    end;
    SetLength(Result, list.Count);
    for i := 0 to list.Count - 1 do
      Result[i] := list[i];
  finally
    list.Free;
  end;
end;

function ClassMatchingAttributes(ASchema: TSchemaSnapshot; const AClass, AFilter: string;
  out ARequired, AAllowed: TStringArray): Boolean;
var
  f: string;
  chain: TStringArray;
  issue: string;
  oc: TSchemaObjectClass;
  seen, found: TStringList;
  i: Integer;

  procedure Scan(const AList: array of string);
  var
    k: Integer;
    at: TSchemaAttributeType;
    hit: Boolean;
    key, name: string;
  begin
    for k := 0 to High(AList) do
    begin
      at := ASchema.AttributeType(AList[k]);
      if at <> nil then
      begin
        hit := AttributeMatches(at, f);
        key := 'oid:' + AsciiLowerCase(at.Oid);
        name := at.PrimaryName;
      end
      else
      begin
        hit := Pos(f, AsciiLowerCase(AList[k])) > 0;
        key := 'name:' + AsciiLowerCase(AList[k]);
        name := AList[k];
      end;
      if not hit or (seen.IndexOf(key) >= 0) then Continue;
      seen.Add(key);
      found.Add(name);
    end;
  end;

  function Take: TStringArray;
  var
    k: Integer;
  begin
    SetLength(Result, found.Count);
    for k := 0 to found.Count - 1 do
      Result[k] := found[k];
    found.Clear;
  end;

begin
  Result := False;
  ARequired := nil;
  AAllowed := nil;
  f := AsciiLowerCase(Trim(AFilter));
  if (ASchema = nil) or (f = '') or (ASchema.ObjectClass(AClass) = nil) then Exit;
  if not InheritanceChain(ASchema, AClass, chain, issue) and (Length(chain) = 0) then
    chain := [AClass];
  seen := TStringList.Create;
  found := TStringList.Create;
  try
    seen.Sorted := True;
    found.Sorted := True;
    found.CaseSensitive := False;
    found.Duplicates := dupAccept;
    for i := 0 to High(chain) do
    begin
      oc := ASchema.ObjectClass(chain[i]);
      if oc <> nil then Scan(oc.Must);
    end;
    ARequired := Take;
    for i := 0 to High(chain) do
    begin
      oc := ASchema.ObjectClass(chain[i]);
      if oc <> nil then Scan(oc.May);
    end;
    AAllowed := Take;
  finally
    found.Free;
    seen.Free;
  end;
  Result := (Length(ARequired) > 0) or (Length(AAllowed) > 0);
end;

function InheritanceChain(ASchema: TSchemaSnapshot; const AClass: string; out AChain: TStringArray;
  out AIssue: string): Boolean;
var
  unresolved: Boolean;
begin
  Result := InheritanceChainEx(ASchema, AClass, AChain, AIssue, unresolved);
end;

function InheritanceChainEx(ASchema: TSchemaSnapshot; const AClass: string; out AChain: TStringArray;
  out AIssue: string; out AUnresolved: Boolean): Boolean;
var
  visited: TStringList;
  nodes: Integer;
  ok: Boolean;

  // La pile des ancetres detecte les cycles, les visites ecartent les losanges
  // legitimes. Un schema circulaire existe: quelqu'un l'a forcement charge un jour.
  procedure Walk(const AName: string; APath: TStringList; ADepth: Integer);
  var
    oc: TSchemaObjectClass;
    key: string;
    i: Integer;
  begin
    if not ok then Exit;
    Inc(nodes);
    if (ADepth > SCHEMA_MAX_SUP_DEPTH) or (nodes > CREATE_MAX_CHAIN_NODES) then
    begin
      ok := False;
      AIssue := Format(rsCpTooDeep, [AClass]);
      Exit;
    end;
    oc := ASchema.ObjectClass(AName);
    if oc = nil then
    begin
      ok := False;
      if APath.Count = 0 then AIssue := Format(rsCpUnknownClass, [AName])
      else
      begin
        AIssue := Format(rsCpUnresolvedSup, [APath[APath.Count - 1], AName]);
        AUnresolved := True;
      end;
      Exit;
    end;
    key := AsciiLowerCase(oc.Oid);
    if APath.IndexOf(key) >= 0 then
    begin
      ok := False;
      AIssue := Format(rsCpCycle, [AClass]);
      Exit;
    end;
    if visited.IndexOf(key) >= 0 then Exit;
    visited.Add(key);
    SetLength(AChain, Length(AChain) + 1);
    AChain[High(AChain)] := oc.PrimaryName;
    APath.Add(key);
    for i := 0 to High(oc.Sups) do
    begin
      Walk(oc.Sups[i], APath, ADepth + 1);
      if not ok then Break;
    end;
    APath.Delete(APath.Count - 1);
  end;

var
  path: TStringList;
begin
  AChain := nil;
  AIssue := '';
  AUnresolved := False;
  ok := True;
  nodes := 0;
  visited := TStringList.Create;
  path := TStringList.Create;
  try
    visited.CaseSensitive := True;
    path.CaseSensitive := True;
    Walk(AClass, path, 0);
  finally
    path.Free;
    visited.Free;
  end;
  Result := ok;
end;

function IsServerGeneratedOnCreate(AProvider: TProviderKind; const AAttr: string;
  out ARule: string): Boolean;
var
  b: string;
begin
  ARule := '';
  Result := False;
  if AProvider <> pkActiveDirectory then Exit;
  b := AttrBaseName(AAttr);
  if InArray(b, AD_GENERATED) then
  begin
    ARule := rsCpRuleAd;
    Exit(True);
  end;
  if SameName(b, 'sAMAccountName') then
  begin
    ARule := rsCpRuleAdSam;
    Exit(True);
  end;
end;

function ClassInList(ASchema: TSchemaSnapshot; const AClass: string; const AList: array of string): Boolean;
var
  i: Integer;
  oc: TSchemaObjectClass;
begin
  oc := ASchema.ObjectClass(AClass);
  for i := 0 to High(AList) do
    if ((oc <> nil) and (ASchema.ObjectClass(AList[i]) = oc)) or SameName(AList[i], AClass) then
      Exit(True);
  Result := False;
end;

function IsPrecluded(const AAnalysis: TClassAnalysis; ASchema: TSchemaSnapshot;
  const AAttr: string): Boolean;
var
  i: Integer;
  at, pat: TSchemaAttributeType;
  base: string;
begin
  Result := False;
  base := AttrBaseName(AAttr);
  at := nil;
  if ASchema <> nil then at := ASchema.AttributeType(base);
  for i := 0 to High(AAnalysis.Precluded) do
  begin
    if SameName(AAnalysis.Precluded[i], base) then Exit(True);
    if (at = nil) or (ASchema = nil) then Continue;
    pat := ASchema.AttributeType(AAnalysis.Precluded[i]);
    if (pat <> nil) and SameName(pat.Oid, at.Oid) then Exit(True);
  end;
end;

procedure RemoveRequirement(ASchema: TSchemaSnapshot; var AAnalysis: TClassAnalysis; const AAttr: string);
var
  i, n: Integer;
  at: TSchemaAttributeType;
  name: string;
begin
  at := ASchema.AttributeType(AAttr);
  if at <> nil then name := at.PrimaryName else name := AAttr;
  SetLength(AAnalysis.Precluded, Length(AAnalysis.Precluded) + 1);
  AAnalysis.Precluded[High(AAnalysis.Precluded)] := name;
  n := 0;
  for i := 0 to High(AAnalysis.Requirements) do
    if not (((at <> nil) and SameName(AAnalysis.Requirements[i].Oid, at.Oid)) or
            SameName(AAnalysis.Requirements[i].Name, name)) then
    begin
      AAnalysis.Requirements[n] := AAnalysis.Requirements[i];
      Inc(n);
    end;
  SetLength(AAnalysis.Requirements, n);
end;

function AnalyzeClasses(ASchema: TSchemaSnapshot; const AStructural, AAuxiliaries: array of string;
  AProvider: TProviderKind): TClassAnalysis;
var
  chains: array of TStringArray;
  chain, allClasses: TStringArray;
  issue, rule: string;
  i, j, k, best: Integer;
  oc, cls: TSchemaObjectClass;
  keys: TStringList;
  adMeta: TAdSchemaMeta;
  cm: TAdClassMeta;
  implied: TStringList;
  dcr: TSchemaDitContentRule;
  unresolved, keep: Boolean;

  procedure AddClass(const AName: string);
  begin
    if not InArray(AName, allClasses) then
    begin
      SetLength(allClasses, Length(allClasses) + 1);
      allClasses[High(allClasses)] := AName;
    end;
  end;

  procedure AddChainRootFirst(const AChain: TStringArray);
  var
    n: Integer;
  begin
    for n := High(AChain) downto 0 do
      AddClass(AChain[n]);
  end;

  procedure AddRequirement(const AAttr, AOrigin: string; AKind: TReqKind);
  var
    at: TSchemaAttributeType;
    key: string;
    idx: Integer;
    r: TAttrRequirement;
  begin
    at := ASchema.AttributeType(AAttr);
    if at = nil then
    begin
      AddIssue(Result.Issues, isWarning, AAttr, Format(rsCpUnknownAttr, [AOrigin, AAttr]));
      key := 'name:' + AsciiLowerCase(AAttr);
    end
    else
      key := 'oid:' + AsciiLowerCase(at.Oid);
    idx := keys.IndexOf(key);
    if idx >= 0 then
    begin
      if (AKind = rqMust) and (Result.Requirements[PtrInt(keys.Objects[idx])].Kind = rqMay) then
      begin
        Result.Requirements[PtrInt(keys.Objects[idx])].Kind := rqMust;
        Result.Requirements[PtrInt(keys.Objects[idx])].Origin := AOrigin;
      end;
      Exit;
    end;
    r := Default(TAttrRequirement);
    r.Kind := AKind;
    r.Origin := AOrigin;
    if at <> nil then
    begin
      r.Name := at.PrimaryName;
      r.Oid := at.Oid;
      r.SingleValued := at.SingleValue;
      r.Desc := at.Desc;
    end
    else
      r.Name := AAttr;
    if SameName(r.Name, 'objectClass') then
      r.Supply := rsPlan
    else if IsServerGeneratedOnCreate(AProvider, r.Name, rule) then
    begin
      r.Supply := rsServerGenerated;
      r.Rule := rule;
    end
    else if (at <> nil) and at.NoUserModification then
      r.Supply := rsServerOnly
    else
      r.Supply := rsUser;
    SetLength(Result.Requirements, Length(Result.Requirements) + 1);
    Result.Requirements[High(Result.Requirements)] := r;
    keys.AddObject(key, TObject(PtrInt(High(Result.Requirements))));
  end;

  // SUP introuvable sur un schema lu en partie: la classe manque peut-etre a notre
  // lecture, pas au serveur. Avertissement, et le serveur decide. Sur un schema
  // complet, ou en cas de cycle, c'est une erreur: le schema est vraiment casse.
  procedure ChainFailed(const AClass: string; const AChain: TStringArray; const AIssue: string;
    AUnresolved: Boolean; out AKeep: Boolean);
  begin
    AKeep := AUnresolved and (Length(AChain) > 0) and
      (not ASchema.Complete or (ASchema.Errors.Count > 0));
    if not AKeep then
    begin
      AddIssue(Result.Issues, isError, '', AIssue);
      Exit;
    end;
    Result.AllowedIncomplete := True;
    SetLength(Result.PartialChains, Length(Result.PartialChains) + 1);
    Result.PartialChains[High(Result.PartialChains)] := AClass;
    AddIssue(Result.Issues, isWarning, '', Format(rsCpUnresolvedSupPartial, [AIssue]));
  end;

begin
  Result := Default(TClassAnalysis);
  if ASchema = nil then
  begin
    AddIssue(Result.Issues, isError, '', rsCpNoSchema);
    Exit;
  end;
  if ASchema.Errors.Count > 0 then
    AddIssue(Result.Issues, isWarning, '', Format(rsCpSchemaIncomplete, [ASchema.Errors.Count]));
  if not ASchema.Complete then
  begin
    Result.AllowedIncomplete := True;
    AddIssue(Result.Issues, isWarning, '', Format(rsCpSchemaPartial, [ASchema.IncompleteReason]));
  end;
  if Length(AStructural) = 0 then
  begin
    AddIssue(Result.Issues, isError, '', rsCpNoStructural);
    Exit;
  end;
  if Length(AStructural) + Length(AAuxiliaries) > CREATE_MAX_CLASSES then
  begin
    AddIssue(Result.Issues, isError, '', Format(rsCpTooDeep, ['objectClass']));
    Exit;
  end;
  chains := nil;
  allClasses := nil;
  for i := 0 to High(AStructural) do
  begin
    oc := ASchema.ObjectClass(AStructural[i]);
    if oc = nil then
    begin
      AddIssue(Result.Issues, isError, '', Format(rsCpUnknownClass, [AStructural[i]]));
      Continue;
    end;
    if oc.Kind = ockAbstract then
      AddIssue(Result.Issues, isError, '', Format(rsCpAbstract, [oc.PrimaryName]))
    else if oc.Kind = ockAuxiliary then
      AddIssue(Result.Issues, isError, '', Format(rsCpAuxiliaryAsStructural, [oc.PrimaryName]));
    if not InheritanceChainEx(ASchema, AStructural[i], chain, issue, unresolved) then
    begin
      ChainFailed(oc.PrimaryName, chain, issue, unresolved, keep);
      if not keep then Continue;
    end;
    SetLength(chains, Length(chains) + 1);
    chains[High(chains)] := chain;
  end;
  if HasErrors(Result.Issues) then Exit;
  best := 0;
  for i := 1 to High(chains) do
    if Length(chains[i]) > Length(chains[best]) then best := i;
  for i := 0 to High(chains) do
    if not InArray(chains[i][0], chains[best]) then
    begin
      if InArray(chains[i][0], Result.PartialChains) or InArray(chains[best][0], Result.PartialChains) then
        AddIssue(Result.Issues, isWarning, '', Format(rsCpIncompatibleMaybe, [chains[best][0], chains[i][0]]))
      else
        AddIssue(Result.Issues, isError, '', Format(rsCpIncompatible, [chains[best][0], chains[i][0]]));
    end;
  if HasErrors(Result.Issues) then Exit;
  Result.MostSpecific := chains[best][0];
  AddChainRootFirst(chains[best]);
  for i := 0 to High(AAuxiliaries) do
  begin
    oc := ASchema.ObjectClass(AAuxiliaries[i]);
    if oc = nil then
    begin
      AddIssue(Result.Issues, isError, '', Format(rsCpUnknownClass, [AAuxiliaries[i]]));
      Continue;
    end;
    if oc.Kind <> ockAuxiliary then
    begin
      AddIssue(Result.Issues, isError, '', Format(rsCpNotAuxiliary, [oc.PrimaryName]));
      Continue;
    end;
    if not InheritanceChainEx(ASchema, AAuxiliaries[i], chain, issue, unresolved) then
    begin
      ChainFailed(oc.PrimaryName, chain, issue, unresolved, keep);
      if not keep then Continue;
    end;
    AddChainRootFirst(chain);
  end;
  if HasErrors(Result.Issues) then Exit;
  Result.ObjectClasses := Copy(allClasses, 0, Length(allClasses));
  // AD attache des auxiliaires par le schema (systemAuxiliaryClass): leurs
  // attributs sont permis sans jamais apparaitre dans objectClass. Merci AD.
  adMeta := ASchema.AdMeta;
  implied := TStringList.Create;
  try
    if AProvider = pkActiveDirectory then
    begin
      if adMeta = nil then
      begin
        Result.AllowedIncomplete := True;
        AddIssue(Result.Issues, isWarning, '', rsCpAdMetaMissing);
      end
      else
        for i := 0 to High(Result.ObjectClasses) do
        begin
          cm := adMeta.ObjectClass(Result.ObjectClasses[i]);
          if cm = nil then Continue;
          for j := 0 to High(cm.SystemAux) + Length(cm.Aux) do
          begin
            if j <= High(cm.SystemAux) then issue := cm.SystemAux[j]
            else issue := cm.Aux[j - Length(cm.SystemAux)];
            if InheritanceChain(ASchema, issue, chain, rule) then
              for k := 0 to High(chain) do
                if not InArray(chain[k], allClasses) and (implied.IndexOf(chain[k]) < 0) then
                  implied.Add(chain[k]);
          end;
        end;
    end;
    keys := TStringList.Create;
    try
      keys.Sorted := True;
      keys.CaseSensitive := True;
      for i := 0 to High(allClasses) + implied.Count do
      begin
        if i <= High(allClasses) then cls := ASchema.ObjectClass(allClasses[i])
        else cls := ASchema.ObjectClass(implied[i - Length(allClasses)]);
        if cls = nil then Continue;
        if SameName(cls.PrimaryName, 'extensibleObject') then Result.ExtensibleObject := True;
        for j := 0 to High(cls.Must) do
          AddRequirement(cls.Must[j], cls.PrimaryName, rqMust);
        for j := 0 to High(cls.May) do
          AddRequirement(cls.May[j], cls.PrimaryName, rqMay);
      end;
      dcr := ASchema.DitContentRule(Result.MostSpecific);
      if (dcr <> nil) and not dcr.Obsolete then
      begin
        Result.ContentRule := dcr.PrimaryName;
        issue := 'content rule of ' + Result.MostSpecific;
        for j := 0 to High(dcr.Must) do AddRequirement(dcr.Must[j], issue, rqMust);
        for j := 0 to High(dcr.May) do AddRequirement(dcr.May[j], issue, rqMay);
        for i := 0 to High(AAuxiliaries) do
          if not ClassInList(ASchema, AAuxiliaries[i], dcr.Aux) then
            AddIssue(Result.Issues, isError, '', Format(rsCpAuxNotPermitted, [Result.MostSpecific, AAuxiliaries[i]]));
        for j := 0 to High(dcr.Precluded) do
          RemoveRequirement(ASchema, Result, dcr.Precluded[j]);
      end;
    finally
      keys.Free;
    end;
  finally
    implied.Free;
  end;
  Result.Ok := not HasErrors(Result.Issues);
end;

function DefaultRdnAttribute(const AAnalysis: TClassAnalysis): string;
const
  Preferred: array[0..7] of string = ('ou', 'cn', 'uid', 'dc', 'o', 'c', 'l', 'name');
var
  i, j: Integer;
  pass: TReqKind;
begin
  Result := '';
  if SameName(AAnalysis.MostSpecific, 'organizationalUnit') then Exit('ou');
  if SameName(AAnalysis.MostSpecific, 'domain') or SameName(AAnalysis.MostSpecific, 'dcObject') or
     SameName(AAnalysis.MostSpecific, 'domainDNS') then Exit('dc');
  for pass := rqMust to rqMay do
    for i := 0 to High(Preferred) do
      for j := 0 to High(AAnalysis.Requirements) do
        if (AAnalysis.Requirements[j].Kind = pass) and
           (AAnalysis.Requirements[j].Supply = rsUser) and
           SameName(AAnalysis.Requirements[j].Name, Preferred[i]) then
          Exit(AAnalysis.Requirements[j].Name);
end;

function IsAdAccount(const AAnalysis: TClassAnalysis; AProvider: TProviderKind): Boolean;
begin
  Result := (AProvider = pkActiveDirectory) and
    (InArray('user', AAnalysis.ObjectClasses) or InArray('computer', AAnalysis.ObjectClasses));
end;

function BuildCreationDn(const AParentDn: string; const ARdn: TRdnAvas; out ADn: string;
  out AError: string): Boolean;
var
  parent, dn: TLdapDn;
  rdn: TDnRdn;
  i: Integer;
  check: TLdapDn;
begin
  Result := False;
  ADn := '';
  AError := '';
  if (Length(ARdn) = 0) or (Length(ARdn) > CREATE_MAX_RDN_AVAS) then
  begin
    AError := rsCpNoRdn;
    Exit;
  end;
  if not DnParse(AParentDn, parent, AError) then
  begin
    AError := Format(rsCpBadParent, [AError]);
    Exit;
  end;
  rdn := DnMakeRdn(ARdn[0].Attr, ARdn[0].Value);
  for i := 1 to High(ARdn) do
  begin
    SetLength(rdn.Avas, Length(rdn.Avas) + 1);
    rdn.Avas[High(rdn.Avas)] := DnMakeRdn(ARdn[i].Attr, ARdn[i].Value).Avas[0];
  end;
  dn := DnChild(parent, rdn);
  ADn := DnToString(dn);
  // Le DN produit doit se relire avec un RDN de plus que le parent, ni plus ni moins.
  // Sinon une valeur a reussi a ecrire du DN: c'est une injection, pas un nom.
  if not DnParse(ADn, check, AError, dpmStrict) or (DnRdnCount(check) <> DnRdnCount(parent) + 1) or
     (Length(check.Rdns[0].Avas) <> Length(ARdn)) then
  begin
    AError := Format(rsCpBadName, [AError]);
    ADn := '';
    Exit;
  end;
  for i := 0 to High(ARdn) do
    if check.Rdns[0].Avas[i].Value <> ARdn[i].Value then
    begin
      AError := Format(rsCpBadName, [ARdn[i].Attr]);
      ADn := '';
      Exit;
    end;
  Result := True;
end;

function FindRequirement(const AAnalysis: TClassAnalysis; ASchema: TSchemaSnapshot;
  const AAttr: string): Integer;
var
  i: Integer;
  at: TSchemaAttributeType;
begin
  at := nil;
  if ASchema <> nil then at := ASchema.AttributeType(AAttr);
  for i := 0 to High(AAnalysis.Requirements) do
    if ((at <> nil) and SameName(AAnalysis.Requirements[i].Oid, at.Oid)) or
       SameName(AAnalysis.Requirements[i].Name, AttrBaseName(AAttr)) then
      Exit(i);
  Result := -1;
end;

function IsSecret(ASensitive: TSensitivePolicy; const AAttr: string): Boolean;
begin
  Result := (ASensitive <> nil) and ASensitive.IsSensitive(AAttr);
end;

function ValidateCreation(ASchema: TSchemaSnapshot; APlan: TEntryCreationPlan;
  const AAnalysis: TClassAnalysis; ASensitive: TSensitivePolicy): TPlanIssues;
var
  i, j, k, ri: Integer;
  dn, err, rule: string;
  a: TLdapAttribute;
  at: TSchemaAttributeType;
  res: TValueResolution;
  seen: TStringList;
  req: TAttrRequirement;
  found: Boolean;
  uac: Int64;
begin
  Result := Copy(AAnalysis.Issues, 0, Length(AAnalysis.Issues));
  if not AAnalysis.Ok then Exit;
  if Length(APlan.Rdn) = 0 then
    AddIssue(Result, isError, '', rsCpNoRdn);
  seen := TStringList.Create;
  try
    for i := 0 to High(APlan.Rdn) do
    begin
      if APlan.Rdn[i].Value = '' then
        AddIssue(Result, isError, APlan.Rdn[i].Attr, Format(rsCpRdnEmpty, [APlan.Rdn[i].Attr]));
      ri := FindRequirement(AAnalysis, ASchema, APlan.Rdn[i].Attr);
      // Interdit par la regle de contenu DIT: refus meme avec extensibleObject et sur
      // un schema partiel. La regle, elle, a ete lue; on n'a pas d'excuse.
      if IsPrecluded(AAnalysis, ASchema, APlan.Rdn[i].Attr) then
        AddIssue(Result, isError, APlan.Rdn[i].Attr, Format(rsCpPrecluded, [APlan.Rdn[i].Attr, AAnalysis.ContentRule]))
      else if (ri < 0) and not AAnalysis.ExtensibleObject then
      begin
        if AAnalysis.AllowedIncomplete then
          AddIssue(Result, isWarning, APlan.Rdn[i].Attr, Format(rsCpNotAllowedMaybe, [APlan.Rdn[i].Attr]))
        else
          AddIssue(Result, isError, APlan.Rdn[i].Attr, Format(rsCpRdnNotAllowed, [APlan.Rdn[i].Attr]));
      end;
      at := ASchema.AttributeType(APlan.Rdn[i].Attr);
      if (at <> nil) and at.NoUserModification then
        AddIssue(Result, isError, APlan.Rdn[i].Attr, Format(rsCpRdnReadOnly, [APlan.Rdn[i].Attr]));
      if at <> nil then err := AsciiLowerCase(at.Oid) else err := AsciiLowerCase(APlan.Rdn[i].Attr);
      if seen.IndexOf(err) >= 0 then
        AddIssue(Result, isError, APlan.Rdn[i].Attr, Format(rsCpRdnDuplicate, [APlan.Rdn[i].Attr]));
      seen.Add(err);
      a := APlan.Values.Find(APlan.Rdn[i].Attr);
      if (a <> nil) and (a.IndexOfValue(APlan.Rdn[i].Value) < 0) then
      begin
        found := False;
        for j := 0 to a.ValueCount - 1 do
          if AsciiLowerCase(string(a.Values[j])) = AsciiLowerCase(string(APlan.Rdn[i].Value)) then
            found := True;
        if found then
          AddIssue(Result, isError, APlan.Rdn[i].Attr, Format(rsCpRdnCase, [APlan.Rdn[i].Attr]))
        else if (at <> nil) and at.SingleValue and (a.ValueCount > 0) then
          AddIssue(Result, isError, APlan.Rdn[i].Attr, Format(rsCpRdnConflict, [APlan.Rdn[i].Attr]));
      end;
    end;
  finally
    seen.Free;
  end;
  if Length(APlan.Rdn) > 0 then
    if not BuildCreationDn(APlan.ParentDn, APlan.Rdn, dn, err) then
      AddIssue(Result, isError, '', err);
  for i := 0 to High(AAnalysis.Requirements) do
  begin
    req := AAnalysis.Requirements[i];
    if req.Kind <> rqMust then Continue;
    found := APlan.Values.Find(req.Name) <> nil;
    if found then found := APlan.Values.Find(req.Name).ValueCount > 0;
    for k := 0 to High(APlan.Rdn) do
      if FindRequirement(AAnalysis, ASchema, APlan.Rdn[k].Attr) = i then found := True;
    case req.Supply of
      rsUser:
        if not found then
          AddIssue(Result, isError, req.Name, Format(rsCpMissing, [req.Name, req.Origin]));
      rsServerOnly:
        AddIssue(Result, isWarning, req.Name, Format(rsCpServerOnlyRequired, [req.Name, req.Origin]));
    end;
  end;
  for i := 0 to APlan.Values.AttrCount - 1 do
  begin
    a := APlan.Values.Attrs[i];
    if a.ValueCount = 0 then Continue;
    if SameName(a.BaseName, 'objectClass') then Continue;
    // Secret: seulement s'il sort des outils de mot de passe, et jamais sur AD, ou
    // unicodePwd est une etape a part apres la creation.
    if IsSecret(ASensitive, a.Description) then
    begin
      if APlan.Provider = pkActiveDirectory then
      begin
        AddIssue(Result, isError, a.Description, Format(rsCpSecretAd, [a.Description]));
        Continue;
      end;
      if not InArray(a.BaseName, APlan.ComputedSecrets) then
      begin
        AddIssue(Result, isError, a.Description, Format(rsCpSecret, [a.Description]));
        Continue;
      end;
    end;
    ri := FindRequirement(AAnalysis, ASchema, a.Description);
    if IsPrecluded(AAnalysis, ASchema, a.Description) then
      AddIssue(Result, isError, a.Description, Format(rsCpPrecluded, [a.Description, AAnalysis.ContentRule]))
    else if (ri < 0) and not AAnalysis.ExtensibleObject then
    begin
      if AAnalysis.AllowedIncomplete then
        AddIssue(Result, isWarning, a.Description, Format(rsCpNotAllowedMaybe, [a.Description]))
      else
        AddIssue(Result, isError, a.Description, Format(rsCpNotAllowed, [a.Description]));
    end;
    res := ResolveValueKind(ASchema, a.Description, APlan.Provider);
    if res.ReadOnly then
      AddIssue(Result, isError, a.Description, Format(rsCpReadOnly, [a.Description, res.ReadOnlyReason]))
    else if IsServerGeneratedOnCreate(APlan.Provider, a.Description, rule) and
      not SameName(a.BaseName, 'sAMAccountName') then
      AddIssue(Result, isWarning, a.Description, Format(rsCpOverride, [a.Description]));
    at := ASchema.AttributeType(a.Description);
    if (at <> nil) and at.SingleValue and (a.ValueCount > 1) then
      AddIssue(Result, isError, a.Description, Format(rsCpSingle, [a.Description, a.ValueCount]));
    for j := 0 to a.ValueCount - 1 do
    begin
      err := ValidateValue(res, a.Values[j]);
      if err <> '' then
        AddIssue(Result, isError, a.Description, Format(rsCpSyntax, [a.Description, err]));
    end;
  end;
  if IsAdAccount(AAnalysis, APlan.Provider) then
  begin
    a := APlan.Values.Find('userAccountControl');
    if (a <> nil) and (a.ValueCount > 0) then
    begin
      if not TryStrToInt64(string(a.Values[0]), uac) then
        AddIssue(Result, isError, 'userAccountControl', rsCpUacInvalid)
      else if (uac and CREATE_UF_ACCOUNTDISABLE) = 0 then
        AddIssue(Result, isWarning, 'userAccountControl', rsCpUacForcedDisabled);
    end;
    AddIssue(Result, isWarning, '', rsCpDisabled);
  end;
end;

function BuildCreationEntry(ASchema: TSchemaSnapshot; APlan: TEntryCreationPlan;
  const AAnalysis: TClassAnalysis; ASensitive: TSensitivePolicy; out AIssues: TPlanIssues): TLdapEntry;
var
  dn, err: string;
  i, j: Integer;
  a, dst: TLdapAttribute;
  uac: Int64;
begin
  Result := nil;
  AIssues := ValidateCreation(ASchema, APlan, AAnalysis, ASensitive);
  if HasErrors(AIssues) then Exit;
  if not BuildCreationDn(APlan.ParentDn, APlan.Rdn, dn, err) then Exit;
  Result := TLdapEntry.Create(dn);
  Result.Ensure('objectClass').SetValues([]);
  for i := 0 to High(AAnalysis.ObjectClasses) do
    Result.Find('objectClass').AddValue(AAnalysis.ObjectClasses[i]);
  for i := 0 to APlan.Values.AttrCount - 1 do
  begin
    a := APlan.Values.Attrs[i];
    if (a.ValueCount = 0) or SameName(a.BaseName, 'objectClass') then Continue;
    dst := Result.Ensure(a.Description);
    for j := 0 to a.ValueCount - 1 do
      dst.AddValue(a.Values[j]);
  end;
  for i := 0 to High(APlan.Rdn) do
  begin
    dst := Result.Ensure(APlan.Rdn[i].Attr);
    if dst.IndexOfValue(APlan.Rdn[i].Value) < 0 then
      dst.AddValue(APlan.Rdn[i].Value);
  end;
  if IsAdAccount(AAnalysis, APlan.Provider) then
  begin
    // Desactive a la creation, les autres bits fournis restent: on ne touche pas aux
    // drapeaux qu'on n'a pas compris.
    a := Result.Find('userAccountControl');
    if (a <> nil) and (a.ValueCount > 0) and TryStrToInt64(string(a.Values[0]), uac) then
      a.SetValues([RawByteString(IntToStr(uac or CREATE_UF_ACCOUNTDISABLE))])
    else if InArray('computer', AAnalysis.ObjectClasses) then
      Result.Ensure('userAccountControl').SetValues(
        [RawByteString(IntToStr(CREATE_UF_WORKSTATION_TRUST_ACCOUNT or CREATE_UF_ACCOUNTDISABLE))])
    else
      Result.Ensure('userAccountControl').SetValues(
        [RawByteString(IntToStr(CREATE_UF_NORMAL_ACCOUNT or CREATE_UF_ACCOUNTDISABLE))]);
  end;
end;

procedure PrepareSteps(APlan: TEntryCreationPlan; const AAnalysis: TClassAnalysis);

  procedure Add(AKind: TCreationStepKind);
  begin
    SetLength(APlan.Steps, Length(APlan.Steps) + 1);
    APlan.Steps[High(APlan.Steps)].Kind := AKind;
    APlan.Steps[High(APlan.Steps)].Outcome := sotPending;
  end;

begin
  APlan.Steps := nil;
  Add(cskAdd);
  if IsAdAccount(AAnalysis, APlan.Provider) then
  begin
    Add(cskSetPassword);
    Add(cskEnable);
  end;
end;

end.
