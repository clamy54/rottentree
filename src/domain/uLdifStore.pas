// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdifStore;

{$mode objfpc}{$H+}

// Annuaire en memoire tire d'un fichier LDIF de n'importe quel serveur, dans
// n'importe quel ordre. Les niveaux manquants deviennent des noeuds 'glue', comme
// chez OpenLDAP. Recherches et ecritures suivent RFC 4511 pour que le reste de
// l'outil ne voie pas la difference. Les ecritures restent en memoire.

interface

uses
  SysUtils, Classes, Generics.Collections, uLdapEntry, uLdapDn, uLdif, uChangeSet,
  uSearchModel, uLdapErrors, uLdapFilter, uEntryFilter, uCancel, uSensitive, uDirectorySession,
  uLdapSchema;

const
  LDIF_GLUE_CLASS = 'glue';
  LDIF_GLUE_CONTEXTS_ATTR = 'x-rottentree-glueContexts';
  LDIF_STORE_MAX_ISSUES = 200;

resourcestring
  rsLdifGlueNotInFile = 'this level is not in the file: it only groups the entries below it';
  rsLdifChangeIgnored = 'line %d: "%s" record ignored (only entries are opened)';
  rsLdifDuplicate = 'line %d: duplicate entry %s ignored (first occurrence kept, line %d)';
  rsLdifRootDseIgnored = 'line %d: an entry with an empty DN (root DSE) is not opened';
  rsLdifParseIssue = 'line %d: %s';
  rsLdifValueExists = 'value already present in %s';
  rsLdifNoValue = 'value not present in %s';
  rsLdifNoAttribute = 'no attribute %s';
  rsLdifDuplicateValues = 'duplicate values for %s';
  rsLdifRdnValue = 'the RDN value of %s cannot be removed';
  rsLdifNoClass = 'an entry needs an objectClass';
  rsLdifComputed = '%s is computed and cannot be modified';
  rsLdifSubtreeTaken = '%s already exists outside the moved subtree';
  rsLdifIncrement = 'increment needs a single integer value in %s';
  rsLdifHasChildren = 'the entry has subordinate entries';
  rsLdifUnderItself = 'an entry cannot be moved under itself';
  rsLdifAssertion = 'the assertion is not true for this entry';
  rsLdifBadDn = 'invalid DN: %s';
  rsLdifBadRdn = 'invalid RDN';

type
  TLdifNode = class
  public
    Key: string;
    Dn: string;
    Entry: TLdapEntry;
    Glue: Boolean;
    Parent: TLdifNode;
    // Enfants chaines: retrait et deplacement en temps constant, meme sous une OU de
    // trois cent mille comptes que personne n'a jamais rangee.
    FirstChild, LastChild, PrevSibling, NextSibling: TLdifNode;
    ChildCount: Integer;
    Line: Integer;
    constructor Create(const AKey, ADn: string; AEntry: TLdapEntry; AGlue: Boolean);
    destructor Destroy; override;
  end;

  TLdifNodeIndex = specialize TDictionary<string, TLdifNode>;

  TLdifStore = class
  private
    FTop: TLdifNode;
    FIndex: TLdifNodeIndex;
    FIssues: TStringList;
    FIssueCount: Integer;
    FEntryCount: Integer;
    FGlueCount: Integer;
    FLooksLikeAd: Boolean;
    FDomainDn: string;
    FSubschemaDn: string;
    FChangeCount: Int64;
    FAddRecords: Boolean;
    FSchema: TSchemaSnapshot;
    procedure AddIssue(const AText: string);
    function NewNode(const AKey, ADn: string; AEntry: TLdapEntry; AGlue: Boolean): TLdifNode;
    function GlueAt(const AKey, ADn: string): TLdifNode;
    procedure Link(AChild, AParent: TLdifNode);
    procedure Unlink(ANode: TLdifNode);
    procedure PruneGlue(AParent: TLdifNode);
    procedure Observe(AEntry: TLdapEntry);
    function Computed(AEntry: TLdapEntry; const ABase: string; out AValues: TValueArray): Boolean;
    function EntryByDn(const ADn: string): TLdapEntry;
    function SchemaKind(const AAttr: string; out AKind: TMatchKind): Boolean;
    function Context: TFilterContext;
    function NearestReal(const ADn: string): TLdifNode;
    function IsOperationalAttr(const ABase: string): Boolean;
    function SameValue(const AAttr: string; const A, B: RawByteString): Boolean;
    function IndexOfValue(AAttr: TLdapAttribute; const AValue: RawByteString): Integer;
    function NotFound(const AStep, ADn: string; ANode: TLdifNode): TLdapError;
    function CheckAssertion(ANode: TLdifNode; const AAssertion, AStep: string;
      out AError: TLdapError): Boolean;
    function RdnValuesKept(AEntry: TLdapEntry; const ADn: TLdapDn; out AAttr: string): Boolean;
    procedure Rekey(ANode: TLdifNode; const AOldBase, ANewBase: TLdapDn);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Load(ADoc: TLdifDocument);
    function FindNode(const ADn: string): TLdifNode;
    function Search(const AReq: TSearchRequest; AOnEntry: TSearchEntryEvent;
      ACancel: TCancelToken; ASensitive: TSensitivePolicy; out ACompletion: TSearchCompletion;
      out AError: TLdapError): Boolean;
    function SelectAttributes(ANode: TLdifNode; const AAttrs: array of string;
      ATypesOnly: Boolean; ASensitive: TSensitivePolicy): TLdapEntry;
    function RootDse: TLdapEntry;
    function Compare(const ADn, AAttr: string; const AValue: RawByteString;
      out AMatch: Boolean): TLdapError;
    function Modify(const ADn: string; const AMods: TLdapModArray;
      const AAssertion: string): TLdapError;
    function Add(AEntry: TLdapEntry): TLdapError;
    function Delete(const ADn, AAssertion: string): TLdapError;
    function Rename(const ADn, ANewRdn, ANewSuperior: string; AHasNewSuperior,
      ADeleteOldRdn: Boolean): TLdapError;
    procedure WriteTo(AStream: TStream; AAddRecords: Boolean; const AEol: RawByteString);
    procedure SetSchema(ASchema: TSchemaSnapshot);
    function RootCount: Integer;
    function Root(AIndex: Integer): TLdifNode;
    property EntryCount: Integer read FEntryCount;
    property GlueCount: Integer read FGlueCount;
    property Issues: TStringList read FIssues;
    property IssueCount: Integer read FIssueCount;
    property LooksLikeActiveDirectory: Boolean read FLooksLikeAd;
    property SubschemaDn: string read FSubschemaDn;
    property ChangeCount: Int64 read FChangeCount;
    property AddRecords: Boolean read FAddRecords;
  end;

function IsKnownOperationalAttr(const ABase: string): Boolean;

implementation

uses
  uServerKind;

var
  GOperational: TStringList = nil;

function IsKnownOperationalAttr(const ABase: string): Boolean;
begin
  Result := GOperational.IndexOf(ABase) >= 0;
end;

procedure BuildOperational;
const
  NAMES: array[0..30] of string = ('createTimestamp', 'modifyTimestamp', 'creatorsName',
    'modifiersName', 'entryUUID', 'entryCSN', 'entryDN', 'structuralObjectClass',
    'subschemaSubentry', 'hasSubordinates', 'numSubordinates', 'contextCSN',
    'pwdChangedTime', 'pwdAccountLockedTime', 'pwdFailureTime', 'pwdHistory',
    'pwdGraceUseTime', 'pwdReset', 'pwdPolicySubentry', 'pwdLastSuccess', 'entryParentId',
    'nbChildren', 'nbSubordinates', 'nsUniqueId', 'entryid', 'parentid', 'governingStructureRule',
    'collectiveAttributeSubentries', 'collectiveExclusions', 'administrativeRole',
    'msDS-Approx-Immed-Subordinates');
var
  i: Integer;
begin
  GOperational := TStringList.Create;
  GOperational.CaseSensitive := False;
  GOperational.Sorted := True;
  GOperational.Duplicates := dupIgnore;
  for i := 0 to High(NAMES) do
    GOperational.Add(NAMES[i]);
end;

function IsComputedAttr(const ABase: string): Boolean;
begin
  Result := SameText(ABase, 'hasSubordinates') or SameText(ABase, 'numSubordinates');
end;

function WriteError(ACode: Integer; const AStep, ADiag: string): TLdapError;
begin
  Result := MakeError(CategoryFromResultCode(ACode), ACode, AStep, ADiag);
end;

constructor TLdifNode.Create(const AKey, ADn: string; AEntry: TLdapEntry; AGlue: Boolean);
begin
  inherited Create;
  Key := AKey;
  Dn := ADn;
  Entry := AEntry;
  Glue := AGlue;
end;

destructor TLdifNode.Destroy;
begin
  Entry.Free;
  inherited Destroy;
end;

constructor TLdifStore.Create;
begin
  inherited Create;
  FTop := TLdifNode.Create('', '', nil, True);
  FIndex := TLdifNodeIndex.Create;
  FIssues := TStringList.Create;
end;

destructor TLdifStore.Destroy;
var
  node: TLdifNode;
begin
  for node in FIndex.Values do
    node.Free;
  FIndex.Free;
  FTop.Free;
  FIssues.Free;
  FSchema.Free;
  inherited Destroy;
end;

procedure TLdifStore.AddIssue(const AText: string);
begin
  Inc(FIssueCount);
  if FIssues.Count < LDIF_STORE_MAX_ISSUES then
    FIssues.Add(AText);
end;

function TLdifStore.NewNode(const AKey, ADn: string; AEntry: TLdapEntry;
  AGlue: Boolean): TLdifNode;
begin
  Result := TLdifNode.Create(AKey, ADn, AEntry, AGlue);
  FIndex.Add(AKey, Result);
end;

function TLdifStore.GlueAt(const AKey, ADn: string): TLdifNode;
var
  e: TLdapEntry;
begin
  if FIndex.TryGetValue(AKey, Result) then Exit;
  e := TLdapEntry.Create(ADn);
  e.Ensure('objectClass').AddValue(LDIF_GLUE_CLASS);
  Result := NewNode(AKey, ADn, e, True);
  Inc(FGlueCount);
end;

procedure TLdifStore.Link(AChild, AParent: TLdifNode);
begin
  AChild.Parent := AParent;
  AChild.NextSibling := nil;
  AChild.PrevSibling := AParent.LastChild;
  if AParent.LastChild <> nil then
    AParent.LastChild.NextSibling := AChild
  else
    AParent.FirstChild := AChild;
  AParent.LastChild := AChild;
  Inc(AParent.ChildCount);
end;

procedure TLdifStore.Unlink(ANode: TLdifNode);
var
  p: TLdifNode;
begin
  p := ANode.Parent;
  if p = nil then Exit;
  if ANode.PrevSibling <> nil then
    ANode.PrevSibling.NextSibling := ANode.NextSibling
  else
    p.FirstChild := ANode.NextSibling;
  if ANode.NextSibling <> nil then
    ANode.NextSibling.PrevSibling := ANode.PrevSibling
  else
    p.LastChild := ANode.PrevSibling;
  Dec(p.ChildCount);
  ANode.Parent := nil;
  ANode.PrevSibling := nil;
  ANode.NextSibling := nil;
end;

procedure TLdifStore.PruneGlue(AParent: TLdifNode);
var
  p, up: TLdifNode;
begin
  p := AParent;
  while (p <> nil) and (p <> FTop) and p.Glue and (p.ChildCount = 0) do
  begin
    up := p.Parent;
    Unlink(p);
    FIndex.Remove(p.Key);
    Dec(FGlueCount);
    p.Free;
    p := up;
  end;
end;

procedure TLdifStore.Observe(AEntry: TLdapEntry);
var
  oc: TLdapAttribute;
  i: Integer;
begin
  if (not FLooksLikeAd) and ((AEntry.Find('objectSid') <> nil) or
     (AEntry.Find('objectGUID') <> nil) or (AEntry.Find('sAMAccountName') <> nil) or
     (AEntry.Find('objectCategory') <> nil)) then
    FLooksLikeAd := True;
  if FDomainDn = '' then
  begin
    oc := AEntry.Find('objectClass');
    if oc <> nil then
      for i := 0 to oc.ValueCount - 1 do
        if SameText(oc.Values[i], 'domainDNS') then
        begin
          FDomainDn := AEntry.Dn;
          Break;
        end;
  end;
  if (FSubschemaDn = '') and (AEntry.Find('attributeTypes') <> nil) and
     (AEntry.Find('objectClasses') <> nil) then
    FSubschemaDn := AEntry.Dn;
end;

type
  TGroupCounts = specialize TDictionary<string, Integer>;

procedure TLdifStore.Load(ADoc: TLdifDocument);
type
  TPending = record
    Node: TLdifNode;
    Dn: TLdapDn;
  end;
var
  pending: array of TPending;
  i, n, k, adds: Integer;
  rec: TLdapChange;
  d, level: TLdapDn;
  err, key, parentKey: string;
  node, existing, cur, anc, glue: TLdifNode;
  tops: TFPList;
  groups: TGroupCounts;
  count: Integer;
begin
  for i := 0 to ADoc.IssueCount - 1 do
    AddIssue(Format(rsLdifParseIssue, [ADoc.Issue(i).Line, ADoc.Issue(i).Message]));
  FAddRecords := ADoc.Kind = lkChanges;
  pending := nil;
  SetLength(pending, ADoc.RecordCount);
  n := 0;
  adds := 0;
  for i := 0 to ADoc.RecordCount - 1 do
  begin
    rec := ADoc[i];
    if rec.Kind <> ckAdd then
    begin
      AddIssue(Format(rsLdifChangeIgnored, [rec.SourceLine, ChangeKindName(rec.Kind)]));
      Continue;
    end;
    Inc(adds);
    if not DnParse(rec.Dn, d, err) then
    begin
      AddIssue(Format(rsLdifParseIssue, [rec.SourceLine, 'invalid DN: ' + err]));
      Continue;
    end;
    if DnRdnCount(d) = 0 then
    begin
      AddIssue(Format(rsLdifRootDseIgnored, [rec.SourceLine]));
      Continue;
    end;
    key := DnMatchKey(d);
    if FIndex.TryGetValue(key, existing) then
    begin
      AddIssue(Format(rsLdifDuplicate, [rec.SourceLine, rec.Dn, existing.Line]));
      Continue;
    end;
    node := NewNode(key, rec.Dn, rec.Entry, False);
    rec.Entry := nil;
    node.Entry.Dn := rec.Dn;
    node.Line := rec.SourceLine;
    Observe(node.Entry);
    Inc(FEntryCount);
    pending[n].Node := node;
    pending[n].Dn := d;
    Inc(n);
  end;
  if adds = 0 then FAddRecords := False;
  tops := TFPList.Create;
  groups := TGroupCounts.Create;
  try
    for i := 0 to n - 1 do
    begin
      node := pending[i].Node;
      level := pending[i].Dn;
      cur := node;
      anc := nil;
      key := node.Key;
      k := 0;
      while DnRdnCount(level) > 1 do
      begin
        parentKey := Copy(key, Length(RdnMatchKey(level.Rdns[0])) + 2, MaxInt);
        level := DnParent(level);
        key := parentKey;
        Inc(k);
        if FIndex.TryGetValue(key, anc) then Break;
        anc := nil;
      end;
      if anc = nil then
      begin
        tops.Add(Pointer(PtrInt(i)));
        if DnRdnCount(pending[i].Dn) > 1 then
        begin
          parentKey := Copy(node.Key, Length(RdnMatchKey(pending[i].Dn.Rdns[0])) + 2, MaxInt);
          if groups.TryGetValue(parentKey, count) then
            groups[parentKey] := count + 1
          else
            groups.Add(parentKey, 1);
        end;
        Continue;
      end;
      level := pending[i].Dn;
      key := node.Key;
      while k > 1 do
      begin
        parentKey := Copy(key, Length(RdnMatchKey(level.Rdns[0])) + 2, MaxInt);
        level := DnParent(level);
        key := parentKey;
        Dec(k);
        glue := GlueAt(key, DnToString(level));
        Link(cur, glue);
        cur := glue;
      end;
      Link(cur, anc);
    end;
    for i := 0 to tops.Count - 1 do
    begin
      k := PtrInt(tops[i]);
      node := pending[k].Node;
      if DnRdnCount(pending[k].Dn) > 1 then
      begin
        parentKey := Copy(node.Key, Length(RdnMatchKey(pending[k].Dn.Rdns[0])) + 2, MaxInt);
        if groups.TryGetValue(parentKey, count) and (count >= 2) then
        begin
          if not FIndex.TryGetValue(parentKey, glue) then
          begin
            glue := GlueAt(parentKey, DnToString(DnParent(pending[k].Dn)));
            Link(glue, FTop);
          end;
          Link(node, glue);
          Continue;
        end;
      end;
      Link(node, FTop);
    end;
  finally
    groups.Free;
    tops.Free;
  end;
end;

function TLdifStore.FindNode(const ADn: string): TLdifNode;
var
  key: string;
begin
  Result := nil;
  if not DnStringMatchKey(ADn, key) then Exit;
  if not FIndex.TryGetValue(key, Result) then Result := nil;
end;

function TLdifStore.NearestReal(const ADn: string): TLdifNode;
var
  d: TLdapDn;
  err: string;
begin
  Result := nil;
  if not DnParse(ADn, d, err) then Exit;
  while DnRdnCount(d) > 0 do
  begin
    if FIndex.TryGetValue(DnMatchKey(d), Result) and not Result.Glue then Exit;
    Result := nil;
    d := DnParent(d);
  end;
end;

function TLdifStore.Computed(AEntry: TLdapEntry; const ABase: string;
  out AValues: TValueArray): Boolean;
var
  node: TLdifNode;
  lb: string;
begin
  AValues := nil;
  lb := AsciiLowerCase(ABase);
  Result := (lb = 'hassubordinates') or (lb = 'numsubordinates');
  if not Result then Exit;
  node := FindNode(AEntry.Dn);
  SetLength(AValues, 1);
  if node = nil then
  begin
    if lb = 'hassubordinates' then AValues[0] := 'FALSE' else AValues[0] := '0';
    Exit;
  end;
  if lb = 'hassubordinates' then
  begin
    if node.ChildCount > 0 then AValues[0] := 'TRUE' else AValues[0] := 'FALSE';
  end
  else
    AValues[0] := IntToStr(node.ChildCount);
end;

function TLdifStore.EntryByDn(const ADn: string): TLdapEntry;
var
  node: TLdifNode;
begin
  node := FindNode(ADn);
  if (node = nil) or node.Glue then Result := nil else Result := node.Entry;
end;

function TLdifStore.SchemaKind(const AAttr: string; out AKind: TMatchKind): Boolean;
var
  eq: string;
begin
  Result := False;
  AKind := mkCaseIgnore;
  if (FSchema = nil) or (FSchema.AttributeType(AAttr) = nil) then Exit;
  eq := FSchema.EffectiveEquality(AAttr);
  if eq = '' then Exit;
  Result := MatchKindFromRuleName(eq, AKind);
end;

function TLdifStore.Context: TFilterContext;
begin
  Result.Computed := @Computed;
  Result.EntryByDn := @EntryByDn;
  if FSchema <> nil then
    Result.KindOf := @SchemaKind
  else
    Result.KindOf := nil;
end;

function TLdifStore.IsOperationalAttr(const ABase: string): Boolean;
begin
  if (FSchema <> nil) and (FSchema.AttributeType(ABase) <> nil) then
    Result := FSchema.IsOperational(ABase)
  else
    Result := IsKnownOperationalAttr(ABase);
end;

procedure TLdifStore.SetSchema(ASchema: TSchemaSnapshot);
begin
  if ASchema = FSchema then Exit;
  FSchema.Free;
  FSchema := ASchema;
end;

function RequestedMatches(const ARequested: string; AAttr: TLdapAttribute): Boolean;
var
  want: TAttrDescription;
  i: Integer;
begin
  want := ParseAttrDescription(ARequested);
  if AsciiLowerCase(want.Base) <> AsciiLowerCase(AAttr.BaseName) then Exit(False);
  for i := 0 to High(want.Options) do
    if not AAttr.HasOption(want.Options[i]) then Exit(False);
  Result := True;
end;

function TLdifStore.SelectAttributes(ANode: TLdifNode; const AAttrs: array of string;
  ATypesOnly: Boolean; ASensitive: TSensitivePolicy): TLdapEntry;
var
  allUser, allOper, none, take, named: Boolean;
  i, j: Integer;
  a, dup: TLdapAttribute;
  base: string;
  values: TValueArray;

  procedure AddCopy(ASource: TLdapAttribute);
  var
    k: Integer;
  begin
    dup := TLdapAttribute.Create(ASource.Description);
    if not ATypesOnly then
      for k := 0 to ASource.ValueCount - 1 do
        dup.AddValue(ASource.Values[k]);
    // Meme marquage qu'une entree recue d'un serveur: un secret lu est efface a la
    // liberation de l'attribut et de ses clones.
    if ASensitive <> nil then
      dup.Sensitive := ASensitive.IsSensitive(dup.Description);
    Result.Add(dup);
  end;

  procedure AddComputed(const AName: string);
  var
    k: Integer;
    wanted: Boolean;
  begin
    wanted := allOper;
    for k := 0 to High(AAttrs) do
      if SameText(AttrBaseName(AAttrs[k]), AName) then wanted := True;
    if not wanted or not Computed(ANode.Entry, AName, values) then Exit;
    dup := TLdapAttribute.Create(AName);
    if not ATypesOnly then
      for k := 0 to High(values) do
        dup.AddValue(values[k]);
    Result.Add(dup);
  end;

begin
  Result := TLdapEntry.Create(ANode.Dn);
  try
    Result.SetRequested(AAttrs);
    none := (Length(AAttrs) = 1) and (AAttrs[0] = '1.1');
    if none then Exit;
    allUser := Length(AAttrs) = 0;
    allOper := False;
    for i := 0 to High(AAttrs) do
      if AAttrs[i] = '*' then allUser := True
      else if AAttrs[i] = '+' then allOper := True;
    for i := 0 to ANode.Entry.AttrCount - 1 do
    begin
      a := ANode.Entry.Attrs[i];
      base := a.BaseName;
      // Valeurs calculees par le magasin, jamais celles du fichier: un hasSubordinates
      // exporte il y a six mois ment avec aplomb.
      if IsComputedAttr(base) then Continue;
      if IsOperationalAttr(base) then take := allOper else take := allUser;
      if not take then
      begin
        named := False;
        for j := 0 to High(AAttrs) do
          if (AAttrs[j] <> '*') and (AAttrs[j] <> '+') and RequestedMatches(AAttrs[j], a) then
          begin
            named := True;
            Break;
          end;
        take := named;
      end;
      if take then AddCopy(a);
    end;
    AddComputed('hasSubordinates');
    AddComputed('numSubordinates');
  except
    Result.Free;
    raise;
  end;
end;

function TLdifStore.Search(const AReq: TSearchRequest; AOnEntry: TSearchEntryEvent;
  ACancel: TCancelToken; ASensitive: TSensitivePolicy; out ACompletion: TSearchCompletion;
  out AError: TLdapError): Boolean;
var
  flt: TFilterNode;
  ferr: string;
  base, near: TLdifNode;
  ctx: TFilterContext;
  stack: TFPList;
  stop: Boolean;
  visited: Int64;

  function Offer(ANode: TLdifNode): Boolean;
  var
    e: TLdapEntry;
  begin
    Result := True;
    Inc(visited);
    if (visited and 255 = 0) and (ACancel <> nil) and ACancel.IsCancelled then
    begin
      ACompletion.Cancelled := True;
      ACompletion.ResultCode := LDAP_RC_USER_CANCELLED;
      Exit(False);
    end;
    if EvaluateFilter(flt, ANode.Entry, ctx) <> frTrue then Exit;
    if (AReq.ServerSizeLimit > 0) and (ACompletion.EntryCount >= AReq.ServerSizeLimit) then
    begin
      ACompletion.SizeLimitHit := True;
      ACompletion.ResultCode := LDAP_RC_SIZELIMIT_EXCEEDED;
      Exit(False);
    end;
    e := SelectAttributes(ANode, AReq.Attributes, AReq.TypesOnly, ASensitive);
    Inc(ACompletion.EntryCount);
    stop := False;
    if Assigned(AOnEntry) then
      AOnEntry(e, stop)
    else
      e.Free;
    if (AReq.SizeLimit > 0) and (ACompletion.EntryCount >= AReq.SizeLimit) and not stop then
    begin
      ACompletion.ClientLimitHit := True;
      Exit(False);
    end;
    if stop then
    begin
      ACompletion.Cancelled := True;
      Exit(False);
    end;
  end;

var
  node, child: TLdifNode;
  e: TLdapEntry;
begin
  Result := False;
  ACompletion := Default(TSearchCompletion);
  // HasResult pose explicitement: une completion a zero ressemble trop a une
  // recherche reussie qui n'a rien trouve.
  ACompletion.HasResult := True;
  AError := NoError;
  flt := FilterParse(AReq.Filter, ferr);
  if flt = nil then
  begin
    AError := MakeError(lecConfiguration, LDAP_RC_FILTER_ERROR, 'search', 'invalid filter: ' + ferr);
    ACompletion.ResultCode := LDAP_RC_FILTER_ERROR;
    Exit;
  end;
  ctx := Context;
  visited := 0;
  stack := TFPList.Create;
  try
    base := nil;
    if Trim(AReq.BaseDn) <> '' then
    begin
      base := FindNode(AReq.BaseDn);
      // Un noeud glue n'est pas une entree: lu pour lui-meme, il est absent.
      if (base = nil) or (base.Glue and (AReq.Scope = ssBase)) then
      begin
        ACompletion.ResultCode := LDAP_RC_NO_SUCH_OBJECT;
        near := NearestReal(AReq.BaseDn);
        if near <> nil then ACompletion.MatchedDn := near.Dn;
        if base <> nil then ACompletion.DiagnosticMessage := rsLdifGlueNotInFile;
        AError := MakeError(lecNoSuchObject, LDAP_RC_NO_SUCH_OBJECT, 'search',
          ACompletion.DiagnosticMessage);
        AError.MatchedDn := ACompletion.MatchedDn;
        Exit(True);
      end;
    end;
    ACompletion.ResultCode := LDAP_RC_SUCCESS;
    case AReq.Scope of
      ssBase:
        if base = nil then
        begin
          e := RootDse;
          if EvaluateFilter(flt, e, ctx) = frTrue then
          begin
            Inc(ACompletion.EntryCount);
            stop := False;
            if Assigned(AOnEntry) then AOnEntry(e, stop) else e.Free;
          end
          else
            e.Free;
        end
        else
          Offer(base);
      ssOneLevel:
        begin
          // Seul cas ou un noeud glue est rendu: l'arbre doit le montrer. Le suivant est
          // pris avant l'offre, que le rappel ne scie pas la branche ou l'on est assis.
          if base = nil then base := FTop;
          child := base.FirstChild;
          while child <> nil do
          begin
            node := child.NextSibling;
            if not Offer(child) then Break;
            child := node;
          end;
        end;
    else
      begin
        if base = nil then base := FTop;
        stack.Add(base);
        while stack.Count > 0 do
        begin
          node := TLdifNode(stack[stack.Count - 1]);
          stack.Delete(stack.Count - 1);
          if (node <> FTop) and (not node.Glue) and not Offer(node) then Break;
          child := node.LastChild;
          while child <> nil do
          begin
            stack.Add(child);
            child := child.PrevSibling;
          end;
        end;
      end;
    end;
    if ACompletion.ResultCode <> LDAP_RC_SUCCESS then
      AError := MakeError(CategoryFromResultCode(ACompletion.ResultCode),
        ACompletion.ResultCode, 'search', ACompletion.DiagnosticMessage);
    Result := True;
  finally
    stack.Free;
    flt.Free;
  end;
end;

function TLdifStore.RootDse: TLdapEntry;
var
  nc: TLdapAttribute;
  node: TLdifNode;
begin
  Result := TLdapEntry.Create('');
  Result.Ensure('objectClass').AddValue('top');
  nc := Result.Ensure('namingContexts');
  node := FTop.FirstChild;
  while node <> nil do
  begin
    nc.AddValue(node.Dn);
    if node.Glue then
      Result.Ensure(LDIF_GLUE_CONTEXTS_ATTR).AddValue(node.Dn);
    node := node.NextSibling;
  end;
  if nc.ValueCount = 0 then Result.Remove('namingContexts');
  Result.Ensure('supportedLDAPVersion').AddValue('3');
  Result.Ensure('vendorName').AddValue('Rottentree LDIF file');
  if FSubschemaDn <> '' then
    Result.Ensure('subschemaSubentry').AddValue(FSubschemaDn);
  if FLooksLikeAd then
  begin
    Result.Ensure('supportedCapabilities').AddValue(OID_AD_CAP);
    if FDomainDn <> '' then
      Result.Ensure('defaultNamingContext').AddValue(FDomainDn);
  end;
end;

function TLdifStore.Compare(const ADn, AAttr: string; const AValue: RawByteString;
  out AMatch: Boolean): TLdapError;
var
  node: TLdifNode;
  flt: TFilterNode;
begin
  AMatch := False;
  Result := NoError;
  node := FindNode(ADn);
  if (node = nil) or node.Glue then
    Exit(NotFound('compare', ADn, node));
  flt := FltEq(AAttr, AValue);
  try
    case EvaluateFilter(flt, node.Entry, Context) of
      frTrue: AMatch := True;
      frFalse: AMatch := False;
    else
      Result := MakeError(lecConstraint, LDAP_RC_UNDEFINED_TYPE, 'compare',
        'the value cannot be compared');
    end;
  finally
    flt.Free;
  end;
end;

function TLdifStore.RootCount: Integer;
begin
  Result := FTop.ChildCount;
end;

function TLdifStore.Root(AIndex: Integer): TLdifNode;
var
  i: Integer;
begin
  Result := FTop.FirstChild;
  for i := 1 to AIndex do
    Result := Result.NextSibling;
end;

function TLdifStore.NotFound(const AStep, ADn: string; ANode: TLdifNode): TLdapError;
var
  near: TLdifNode;
begin
  if ANode <> nil then
    Result := WriteError(LDAP_RC_NO_SUCH_OBJECT, AStep, rsLdifGlueNotInFile)
  else
    Result := WriteError(LDAP_RC_NO_SUCH_OBJECT, AStep, '');
  near := NearestReal(ADn);
  if near <> nil then Result.MatchedDn := near.Dn;
end;

function TLdifStore.SameValue(const AAttr: string; const A, B: RawByteString): Boolean;
var
  kind: TMatchKind;
  known: Boolean;
  na, nb: RawByteString;
begin
  if not SchemaKind(AAttr, kind) then kind := AttrMatchKind(AAttr, known);
  if NormalizeForMatch(kind, A, na) and NormalizeForMatch(kind, B, nb) then
    Result := na = nb
  else
    Result := A = B;
end;

function TLdifStore.IndexOfValue(AAttr: TLdapAttribute; const AValue: RawByteString): Integer;
var
  i: Integer;
begin
  for i := 0 to AAttr.ValueCount - 1 do
    if SameValue(AAttr.BaseName, AAttr.Values[i], AValue) then Exit(i);
  Result := -1;
end;

function TLdifStore.CheckAssertion(ANode: TLdifNode; const AAssertion, AStep: string;
  out AError: TLdapError): Boolean;
var
  flt: TFilterNode;
  err: string;
begin
  AError := NoError;
  Result := True;
  if AAssertion = '' then Exit;
  flt := FilterParse(AAssertion, err);
  if flt = nil then
  begin
    AError := WriteError(LDAP_RC_PROTOCOL_ERROR, AStep, 'invalid assertion: ' + err);
    Exit(False);
  end;
  try
    if EvaluateFilter(flt, ANode.Entry, Context) <> frTrue then
    begin
      AError := WriteError(LDAP_RC_ASSERTION_FAILED, AStep, rsLdifAssertion);
      Result := False;
    end;
  finally
    flt.Free;
  end;
end;

function TLdifStore.RdnValuesKept(AEntry: TLdapEntry; const ADn: TLdapDn;
  out AAttr: string): Boolean;
var
  i: Integer;
  a: TLdapAttribute;
  ava: TDnAva;
begin
  Result := True;
  AAttr := '';
  if DnRdnCount(ADn) = 0 then Exit;
  for i := 0 to High(ADn.Rdns[0].Avas) do
  begin
    ava := ADn.Rdns[0].Avas[i];
    if ava.HexForm then Continue;
    a := AEntry.Find(ava.AttrType);
    if (a = nil) or (IndexOfValue(a, ava.Value) < 0) then
    begin
      AAttr := ava.AttrType;
      Exit(False);
    end;
  end;
end;

function TLdifStore.Modify(const ADn: string; const AMods: TLdapModArray;
  const AAssertion: string): TLdapError;
var
  node: TLdifNode;
  work: TLdapEntry;
  a: TLdapAttribute;
  i, j, k, idx: Integer;
  d: TLdapDn;
  err, attr: string;
  n, inc64: Int64;
begin
  node := FindNode(ADn);
  if (node = nil) or node.Glue then Exit(NotFound('modify', ADn, node));
  if not CheckAssertion(node, AAssertion, 'modify', Result) then Exit;
  // Copie de travail: tout s'applique ou rien. Un Modify a moitie applique, c'est
  // un annuaire a moitie faux.
  work := node.Entry.Clone;
  try
    for i := 0 to High(AMods) do
    begin
      attr := AMods[i].Attr;
      if IsComputedAttr(AttrBaseName(attr)) then
        Exit(WriteError(LDAP_RC_CONSTRAINT_VIOLATION, 'modify', Format(rsLdifComputed, [attr])));
      for j := 0 to High(AMods[i].Values) do
        for k := j + 1 to High(AMods[i].Values) do
          if SameValue(attr, AMods[i].Values[j], AMods[i].Values[k]) then
            Exit(WriteError(LDAP_RC_TYPE_OR_VALUE_EXISTS, 'modify',
              Format(rsLdifDuplicateValues, [attr])));
      a := work.Find(attr);
      case AMods[i].Op of
        moAdd:
          begin
            if a = nil then a := work.Ensure(attr);
            for j := 0 to High(AMods[i].Values) do
            begin
              if IndexOfValue(a, AMods[i].Values[j]) >= 0 then
                Exit(WriteError(LDAP_RC_TYPE_OR_VALUE_EXISTS, 'modify',
                  Format(rsLdifValueExists, [attr])));
              a.AddValue(AMods[i].Values[j]);
            end;
          end;
        moDelete:
          begin
            if a = nil then
              Exit(WriteError(LDAP_RC_NO_SUCH_ATTRIBUTE, 'modify', Format(rsLdifNoAttribute, [attr])));
            if Length(AMods[i].Values) = 0 then
              work.Remove(a.Description)
            else
            begin
              for j := 0 to High(AMods[i].Values) do
              begin
                idx := IndexOfValue(a, AMods[i].Values[j]);
                if idx < 0 then
                  Exit(WriteError(LDAP_RC_NO_SUCH_ATTRIBUTE, 'modify', Format(rsLdifNoValue, [attr])));
                a.DeleteValue(idx);
              end;
              if a.ValueCount = 0 then work.Remove(a.Description);
            end;
          end;
        moReplace:
          if Length(AMods[i].Values) = 0 then
          begin
            if a <> nil then work.Remove(a.Description);
          end
          else
          begin
            if a = nil then a := work.Ensure(attr);
            a.SetValues(AMods[i].Values);
          end;
        moIncrement:
          begin
            if (a = nil) or (a.ValueCount <> 1) or not TryStrToInt64(Trim(a.Values[0]), n) or
               (Length(AMods[i].Values) <> 1) or not TryStrToInt64(Trim(AMods[i].Values[0]), inc64) then
              Exit(WriteError(LDAP_RC_CONSTRAINT_VIOLATION, 'modify', Format(rsLdifIncrement, [attr])));
            a.SetValues([IntToStr(n + inc64)]);
          end;
      end;
    end;
    if (work.Find('objectClass') = nil) or (work.Find('objectClass').ValueCount = 0) then
      Exit(WriteError(LDAP_RC_OBJECT_CLASS_VIOLATION, 'modify', rsLdifNoClass));
    if DnParse(node.Dn, d, err) and not RdnValuesKept(work, d, attr) then
      Exit(WriteError(LDAP_RC_NOT_ALLOWED_ON_RDN, 'modify', Format(rsLdifRdnValue, [attr])));
    work.Dn := node.Dn;
    node.Entry.Free;
    node.Entry := work;
    work := nil;
    Inc(FChangeCount);
    Result := NoError;
  finally
    work.Free;
  end;
end;

function TLdifStore.Add(AEntry: TLdapEntry): TLdapError;
var
  d: TLdapDn;
  err, key, parentKey: string;
  node, parent: TLdifNode;
  e: TLdapEntry;
begin
  if not DnParse(AEntry.Dn, d, err) or (DnRdnCount(d) = 0) then
    Exit(WriteError(LDAP_RC_INVALID_DN_SYNTAX, 'add', Format(rsLdifBadDn, [err])));
  if (AEntry.Find('objectClass') = nil) or (AEntry.Find('objectClass').ValueCount = 0) then
    Exit(WriteError(LDAP_RC_OBJECT_CLASS_VIOLATION, 'add', rsLdifNoClass));
  if not RdnValuesKept(AEntry, d, err) then
    Exit(WriteError(LDAP_RC_NAMING_VIOLATION, 'add', Format(rsLdifRdnValue, [err])));
  key := DnMatchKey(d);
  if FIndex.TryGetValue(key, node) and not node.Glue then
    Exit(WriteError(LDAP_RC_ALREADY_EXISTS, 'add', ''));
  e := AEntry.Clone;
  e.Dn := AEntry.Dn;
  e.Remove('hasSubordinates');
  e.Remove('numSubordinates');
  if node <> nil then
  begin
    node.Entry.Free;
    node.Entry := e;
    node.Dn := AEntry.Dn;
    node.Glue := False;
    Dec(FGlueCount);
  end
  else
  begin
    parent := FTop;
    if DnRdnCount(d) > 1 then
    begin
      parentKey := Copy(key, Length(RdnMatchKey(d.Rdns[0])) + 2, MaxInt);
      if not FIndex.TryGetValue(parentKey, parent) then
      begin
        e.Free;
        Exit(NotFound('add', DnToString(DnParent(d)), nil));
      end;
    end;
    node := NewNode(key, AEntry.Dn, e, False);
    Link(node, parent);
  end;
  Inc(FEntryCount);
  Observe(e);
  Inc(FChangeCount);
  Result := NoError;
end;

function TLdifStore.Delete(const ADn, AAssertion: string): TLdapError;
var
  node, parent: TLdifNode;
begin
  node := FindNode(ADn);
  if (node = nil) or node.Glue then Exit(NotFound('delete', ADn, node));
  if not CheckAssertion(node, AAssertion, 'delete', Result) then Exit;
  if node.ChildCount > 0 then
    Exit(WriteError(LDAP_RC_NOT_ALLOWED_ON_NONLEAF, 'delete', rsLdifHasChildren));
  parent := node.Parent;
  Unlink(node);
  FIndex.Remove(node.Key);
  node.Free;
  Dec(FEntryCount);
  PruneGlue(parent);
  Inc(FChangeCount);
  Result := NoError;
end;

procedure TLdifStore.Rekey(ANode: TLdifNode; const AOldBase, ANewBase: TLdapDn);
var
  d, nd: TLdapDn;
  err: string;
  child: TLdifNode;
begin
  if DnParse(ANode.Dn, d, err) then
  begin
    nd := DnConcat(DnRelative(d, DnRdnCount(AOldBase)), ANewBase);
    ANode.Dn := DnToString(nd);
    ANode.Key := DnMatchKey(nd);
    if ANode.Entry <> nil then ANode.Entry.Dn := ANode.Dn;
  end;
  FIndex.Add(ANode.Key, ANode);
  child := ANode.FirstChild;
  while child <> nil do
  begin
    Rekey(child, AOldBase, ANewBase);
    child := child.NextSibling;
  end;
end;

procedure RemoveKeys(AIndex: TLdifNodeIndex; ANode: TLdifNode);
var
  child: TLdifNode;
begin
  AIndex.Remove(ANode.Key);
  child := ANode.FirstChild;
  while child <> nil do
  begin
    RemoveKeys(AIndex, child);
    child := child.NextSibling;
  end;
end;

function TLdifStore.Rename(const ADn, ANewRdn, ANewSuperior: string; AHasNewSuperior,
  ADeleteOldRdn: Boolean): TLdapError;
var
  node, target, oldParent, p, existing: TLdifNode;
  oldDn, rdn, newDn, supDn: TLdapDn;
  err, key: string;
  work: TLdapEntry;
  i: Integer;
  ava: TDnAva;
  a: TLdapAttribute;
  stillUsed: Boolean;
  k: Integer;
  taken: string;

  function Within(P: TLdifNode): Boolean;
  begin
    while (P <> nil) and (P <> FTop) do
    begin
      if P = node then Exit(True);
      P := P.Parent;
    end;
    Result := False;
  end;

  // Fichier partiel: le futur DN d'un descendant peut deja appartenir a une entree
  // hors du sous-arbre. Refus avant toute mutation, le magasin reste intact.
  function SubtreeTaken(N: TLdifNode; out ADn: string): Boolean;
  var
    cd, cnd: TLdapDn;
    ce: string;
    c, found: TLdifNode;
  begin
    c := N.FirstChild;
    while c <> nil do
    begin
      if DnParse(c.Dn, cd, ce) then
      begin
        cnd := DnConcat(DnRelative(cd, DnRdnCount(oldDn)), newDn);
        if FIndex.TryGetValue(DnMatchKey(cnd), found) and not Within(found) then
        begin
          ADn := DnToString(cnd);
          Exit(True);
        end;
      end;
      if SubtreeTaken(c, ADn) then Exit(True);
      c := c.NextSibling;
    end;
    Result := False;
  end;

begin
  node := FindNode(ADn);
  if (node = nil) or node.Glue then Exit(NotFound('moddn', ADn, node));
  if not DnParse(node.Dn, oldDn, err) then
    Exit(WriteError(LDAP_RC_INVALID_DN_SYNTAX, 'moddn', Format(rsLdifBadDn, [err])));
  if not DnParse(ANewRdn, rdn, err) or (DnRdnCount(rdn) <> 1) then
    Exit(WriteError(LDAP_RC_INVALID_DN_SYNTAX, 'moddn', rsLdifBadRdn));
  target := nil;
  if AHasNewSuperior and (Trim(ANewSuperior) <> '') then
  begin
    target := FindNode(ANewSuperior);
    if target = nil then Exit(NotFound('moddn', ANewSuperior, nil));
    if not DnParse(target.Dn, supDn, err) then
      Exit(WriteError(LDAP_RC_INVALID_DN_SYNTAX, 'moddn', Format(rsLdifBadDn, [err])));
    p := target;
    while (p <> nil) and (p <> FTop) do
    begin
      if p = node then
        Exit(WriteError(LDAP_RC_UNWILLING_TO_PERFORM, 'moddn', rsLdifUnderItself));
      p := p.Parent;
    end;
  end
  else if AHasNewSuperior then
  begin
    target := FTop;
    supDn.Rdns := nil;
  end
  else
  begin
    target := node.Parent;
    supDn := DnParent(oldDn);
  end;
  newDn := DnConcat(rdn, supDn);
  key := DnMatchKey(newDn);
  if (key <> node.Key) and FIndex.TryGetValue(key, existing) then
    Exit(WriteError(LDAP_RC_ALREADY_EXISTS, 'moddn', ''));
  if (key <> node.Key) and SubtreeTaken(node, taken) then
    Exit(WriteError(LDAP_RC_ALREADY_EXISTS, 'moddn', Format(rsLdifSubtreeTaken, [taken])));
  work := node.Entry.Clone;
  try
    for i := 0 to High(rdn.Rdns[0].Avas) do
    begin
      ava := rdn.Rdns[0].Avas[i];
      a := work.Find(ava.AttrType);
      if a = nil then a := work.Ensure(ava.AttrType);
      if IndexOfValue(a, ava.Value) < 0 then a.AddValue(ava.Value);
    end;
    if ADeleteOldRdn then
      for i := 0 to High(oldDn.Rdns[0].Avas) do
      begin
        ava := oldDn.Rdns[0].Avas[i];
        stillUsed := False;
        for k := 0 to High(rdn.Rdns[0].Avas) do
          if SameText(rdn.Rdns[0].Avas[k].AttrType, ava.AttrType) and
             SameValue(ava.AttrType, rdn.Rdns[0].Avas[k].Value, ava.Value) then
            stillUsed := True;
        if stillUsed then Continue;
        a := work.Find(ava.AttrType);
        if a <> nil then
        begin
          k := IndexOfValue(a, ava.Value);
          if k >= 0 then a.DeleteValue(k);
          if a.ValueCount = 0 then work.Remove(a.Description);
        end;
      end;
    node.Entry.Free;
    node.Entry := work;
    work := nil;
  finally
    work.Free;
  end;
  oldParent := node.Parent;
  if target <> oldParent then
  begin
    Unlink(node);
    Link(node, target);
  end;
  RemoveKeys(FIndex, node);
  Rekey(node, oldDn, newDn);
  if target <> oldParent then
    PruneGlue(oldParent);
  Inc(FChangeCount);
  Result := NoError;
end;

procedure TLdifStore.WriteTo(AStream: TStream; AAddRecords: Boolean; const AEol: RawByteString);
var
  w: TLdifWriter;
  stack: TFPList;
  node, child: TLdifNode;
  ch: TLdapChange;
begin
  w := TLdifWriter.Create(AStream);
  stack := TFPList.Create;
  ch := TLdapChange.Create;
  try
    w.Eol := AEol;
    w.WriteVersion;
    ch.Kind := ckAdd;
    // Parents avant enfants, dans l'ordre du fichier: le resultat se reimporte tel
    // quel par slapadd, ldapadd ou ldifde.
    stack.Add(FTop);
    while stack.Count > 0 do
    begin
      node := TLdifNode(stack[stack.Count - 1]);
      stack.Delete(stack.Count - 1);
      if (node <> FTop) and not node.Glue then
      begin
        if AAddRecords then
        begin
          ch.Dn := node.Dn;
          ch.Entry := node.Entry;
          try
            w.WriteChange(ch);
          finally
            ch.Entry := nil;
          end;
        end
        else
          w.WriteEntry(node.Entry);
      end;
      child := node.LastChild;
      while child <> nil do
      begin
        stack.Add(child);
        child := child.PrevSibling;
      end;
    end;
  finally
    ch.Free;
    stack.Free;
    w.Free;
  end;
end;

initialization
  BuildOperational;

finalization
  FreeAndNil(GOperational);

end.
