// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDirectoryService;

{$mode objfpc}{$H+}

// Regles de navigation et d'edition, sans interface: requetes de l'arbre, recherche rapide,
// preparation d'une ecriture (delta minimal, assertion de version), sort des ecritures orphelines.
// L'onglet annuaire ne fabrique plus ses requetes LDAP lui-meme, et tout le monde s'en porte mieux.

interface

uses
  SysUtils, Classes, uConnectionProfile, uLdapEntry, uLdapSchema, uSearchModel, uChangeSet,
  uLdapErrors, uUiInbox, uDirectoryWorker, uConnections, uWriteJournal;

const
  LDAP_CONTROL_ASSERTION_OID = '1.3.6.1.1.12';

  TREE_ATTRIBUTES: array[0..3] of string = ('objectClass', 'hasSubordinates', 'numSubordinates',
    'msDS-Approx-Immed-Subordinates');

  // Par ordre de preference: OpenLDAP, generique, AD. Le premier lu fait le jeton d'assertion.
  VERSION_MARKERS: array[0..3] of string = ('entryCSN', 'modifyTimestamp', 'uSNChanged',
    'whenChanged');

type
  TModifyPlan = record
    Change: TLdapChange;
    Assertion: string;
    AssertionUnavailable: Boolean;
    Error: string;
  end;

function TreeChildrenRequest(AProfile: TConnectionProfile; const AParentDn: string): TSearchRequest;
function SubtreeEnumerationRequest(AProfile: TConnectionProfile; const ABaseDn: string): TSearchRequest;
// Marqueurs de version toujours demandes, meme attributs operationnels masques: sans eux, la
// premiere modification partirait sans assertion.
function EntryReadAttributes(AProfile: TConnectionProfile): TStringArray;
// whenChanged et uSNChanged d'AD reviennent avec '*': un marqueur que le schema declare utilisateur
// reste affiche.
function IsHiddenVersionMarker(AProfile: TConnectionProfile; ASchema: TSchemaSnapshot;
  const AAttr: string): Boolean;
// Texte libre echappe selon la RFC 4515. Avec un schema connu, on ne nomme que ce qu'il declare:
// ApacheDS repond erreur 36 a tout filtre citant un attribut inconnu, au lieu du terme Undefined
// prevu par la RFC 4511.
function QuickSearchFilter(const AText: string; ASchema: TSchemaSnapshot = nil): string;
function FilterUnknownAttributes(const AFilter: string; ASchema: TSchemaSnapshot): TStringArray;
function OneLineText(const AText: string; AMax: Integer = 220): string;
function IsContainerEntry(AEntry: TLdapEntry): Boolean;
function EntryMayHaveChildren(AEntry: TLdapEntry): Boolean;
function ServerSupportsControl(ARootDse: TLdapEntry; const AOid: string): Boolean;
function VersionAssertion(AEntry: TLdapEntry): string;
function SchemaEqualityKnown(ASchema: TSchemaSnapshot; const AAttr: string): Boolean;
function PlanModify(AOriginal, AEdited: TLdapEntry; ASchema: TSchemaSnapshot;
  ARootDse: TLdapEntry; out APlan: TModifyPlan): Boolean;
// Comparaison volontairement stricte: un faux conflit coute une relecture, une egalite laxiste
// coute une modification perdue.
function TouchedAttributesUnchanged(AOriginal, ACurrent: TLdapEntry;
  AChange: TLdapChange): Boolean;
function NamingContexts(AConn: TDirectoryConnection): TStringArray;
function DirectoryBases(AConn: TDirectoryConnection): TStringArray;
function DomainNamingContext(AConn: TDirectoryConnection): string;
function DefaultSearchBase(AConn: TDirectoryConnection): string;
// cn=config et cn=monitor de 389 DS ne sont jamais annonces: on les connait par coeur. Leur
// lisibilite n'est pas presumee.
function KnownServerConfigRoots(AConn: TDirectoryConnection): TStringArray;
function ServerConfigRoots(AConn: TDirectoryConnection): TStringArray;
// Toute ecriture ici modifie le serveur lui-meme, immediatement. Pas de corbeille.
function IsServerConfigDn(AConn: TDirectoryConnection; const ADn: string): Boolean;
function DnUnderAny(const ADn: string; const ARoots: TStringArray): Boolean;
function NextIdBaseFor(AConn: TDirectoryConnection; const ADn: string): string;
function IsLdifPlaceholder(AConn: TDirectoryConnection; const AClasses: string): Boolean;
function IsLdifPlaceholderContext(AConn: TDirectoryConnection; const ADn: string): Boolean;
function RdnCaption(const ADn: string): string;
// Comparaison structurelle des DN (RFC 4514), jamais un LowerCase: deux DN qui se ressemblent ne
// designent pas forcement la meme entree.
function SameDnStrict(const A, B: string): Boolean;

type
  TOrphanWriteKind = (owkNone, owkSuccess, owkUnknownOutcome, owkFailed);

// L'ecriture n'est JAMAIS relancee: rejouer une issue inconnue, c'est parfois appliquer deux fois
// la meme modification.
function ClassifyOrphanWrite(AMsg: TUiMessage; AConnections: TConnectionManager;
  out AProfileUuid, AText: string): TOrphanWriteKind;
function SettleWriteOutcome(AMsg: TUiMessage; AConnections: TConnectionManager;
  AJournal: TWriteJournal; out AText: string; const AUnknownDetail: string = ''): TOrphanWriteKind;
function IsUnsettledWrite(AMsg: TUiMessage; AJournal: TWriteJournal): Boolean;

implementation

uses
  uLdapFilter, uLdapDn, uNextId, uLdifStore, uServerKind;

function IsLdifPlaceholder(AConn: TDirectoryConnection; const AClasses: string): Boolean;
begin
  Result := (AConn <> nil) and (AConn.Profile.LdifPath <> '') and
    (Pos(',' + LDIF_GLUE_CLASS + ',', AClasses) > 0);
end;

function IsLdifPlaceholderContext(AConn: TDirectoryConnection; const ADn: string): Boolean;
var
  a: TLdapAttribute;
  i: Integer;
begin
  Result := False;
  if (AConn = nil) or (AConn.Profile.LdifPath = '') or (AConn.RootDse = nil) then Exit;
  a := AConn.RootDse.Find(LDIF_GLUE_CONTEXTS_ATTR);
  if a <> nil then
    for i := 0 to a.ValueCount - 1 do
      if SameDnStrict(string(a.Values[i]), ADn) then Exit(True);
end;

function NamingContexts(AConn: TDirectoryConnection): TStringArray;
var
  a: TLdapAttribute;
  i: Integer;
begin
  Result := nil;
  if (AConn = nil) or (AConn.RootDse = nil) then Exit;
  a := AConn.RootDse.Find('namingContexts');
  if a = nil then Exit;
  SetLength(Result, a.ValueCount);
  for i := 0 to a.ValueCount - 1 do
    Result[i] := string(a.Values[i]);
end;

function DirectoryBases(AConn: TDirectoryConnection): TStringArray;
var
  i: Integer;
begin
  Result := nil;
  if AConn = nil then Exit;
  if AConn.Profile.BaseDns.Count = 0 then Exit(NamingContexts(AConn));
  SetLength(Result, AConn.Profile.BaseDns.Count);
  for i := 0 to AConn.Profile.BaseDns.Count - 1 do
    Result[i] := AConn.Profile.BaseDns[i];
end;

function DomainNamingContext(AConn: TDirectoryConnection): string;
begin
  Result := '';
  if (AConn <> nil) and (AConn.RootDse <> nil) then
    Result := string(AConn.RootDse.FirstValue('defaultNamingContext', ''));
end;

function DefaultSearchBase(AConn: TDirectoryConnection): string;
var
  contexts: TStringArray;
begin
  Result := '';
  if AConn = nil then Exit;
  if AConn.Profile.BaseDns.Count > 0 then Exit(AConn.Profile.BaseDns[0]);
  Result := DomainNamingContext(AConn);
  if Result <> '' then Exit;
  contexts := NamingContexts(AConn);
  if Length(contexts) > 0 then Result := contexts[0];
end;

function KnownServerConfigRoots(AConn: TDirectoryConnection): TStringArray;
var
  dse: TLdapEntry;
  roots: TStringArray;
  cmp: TDnComparer;

  procedure AddRoot(const ADn: string);
  var
    i: Integer;
    a, b: TLdapDn;
  begin
    if not DnTryParse(Trim(ADn), a) or DnIsEmpty(a) then Exit;
    for i := 0 to High(roots) do
      if DnTryParse(roots[i], b) and (cmp.CompareDn(a, b) = dmEqual) then Exit;
    SetLength(roots, Length(roots) + 1);
    roots[High(roots)] := Trim(ADn);
  end;

  procedure AddAnnounced(const AAttr: string);
  var
    a: TLdapAttribute;
    i: Integer;
  begin
    if dse = nil then Exit;
    a := dse.Find(AAttr);
    if a <> nil then
      for i := 0 to a.ValueCount - 1 do AddRoot(string(a.Values[i]));
  end;

begin
  Result := nil;
  roots := nil;
  if (AConn = nil) or (AConn.Profile.LdifPath <> '') then Exit;
  dse := AConn.RootDse;
  cmp := CaseIgnoreDnComparer;
  try
    AddAnnounced('configContext');
    AddAnnounced('monitorContext');
    case EffectiveServerKind(AConn.Profile, dse) of
      pk389Ds:
        begin
          AddRoot('cn=config');
          AddRoot('cn=monitor');
        end;
      pkActiveDirectory:
        begin
          AddAnnounced('configurationNamingContext');
          AddAnnounced('schemaNamingContext');
        end;
      pkApacheDs:
        begin
          AddRoot('ou=config');
          AddRoot('ou=schema');
          AddRoot('ou=system');
        end;
    end;
  finally
    cmp.Free;
  end;
  Result := roots;
end;

function ServerConfigRoots(AConn: TDirectoryConnection): TStringArray;
var
  known, bases: TStringArray;
  cmp: TDnComparer;
  a, b: TLdapDn;
  i, j: Integer;
  listed: Boolean;
begin
  Result := nil;
  known := KnownServerConfigRoots(AConn);
  if Length(known) = 0 then Exit;
  bases := DirectoryBases(AConn);
  cmp := CaseIgnoreDnComparer;
  try
    for i := 0 to High(known) do
    begin
      listed := False;
      if DnTryParse(known[i], a) then
        for j := 0 to High(bases) do
          if DnTryParse(bases[j], b) and (cmp.CompareDn(a, b) = dmEqual) then listed := True;
      if listed then Continue;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := known[i];
    end;
  finally
    cmp.Free;
  end;
end;

function DnUnderAny(const ADn: string; const ARoots: TStringArray): Boolean;
var
  d, r: TLdapDn;
  cmp: TDnComparer;
  i: Integer;
begin
  Result := False;
  if (Length(ARoots) = 0) or not DnTryParse(ADn, d) then Exit;
  cmp := CaseIgnoreDnComparer;
  try
    for i := 0 to High(ARoots) do
      if DnTryParse(ARoots[i], r) and (cmp.IsUnder(d, r, True) = dmEqual) then Exit(True);
  finally
    cmp.Free;
  end;
end;

function IsServerConfigDn(AConn: TDirectoryConnection; const ADn: string): Boolean;
begin
  Result := DnUnderAny(ADn, KnownServerConfigRoots(AConn));
end;

function NextIdBaseFor(AConn: TDirectoryConnection; const ADn: string): string;
var
  bases: TStringArray;
  i: Integer;
begin
  Result := '';
  if AConn = nil then Exit;
  bases := nil;
  SetLength(bases, AConn.Profile.BaseDns.Count);
  for i := 0 to AConn.Profile.BaseDns.Count - 1 do
    bases[i] := AConn.Profile.BaseDns[i];
  // Un identifiant est unique dans tout l'arbre, pas dans une branche.
  Result := NextIdSearchBase(ADn, NamingContexts(AConn), bases);
end;

function RdnCaption(const ADn: string): string;
var
  d: TLdapDn;
begin
  if DnTryParse(ADn, d) and (DnRdnCount(d) > 0) then
    Result := RdnToString(DnLeaf(d))
  else
    Result := ADn;
end;

function SameDnStrict(const A, B: string): Boolean;
var
  da, db: TLdapDn;
  err: string;
  cmp: TDnComparer;
begin
  if not (DnParse(A, da, err) and DnParse(B, db, err)) then Exit(SameText(A, B));
  cmp := TDnComparer.Create;
  try
    Result := DnStrictKey(cmp, da) = DnStrictKey(cmp, db);
  finally
    cmp.Free;
  end;
end;

function ClassifyOrphanWrite(AMsg: TUiMessage; AConnections: TConnectionManager;
  out AProfileUuid, AText: string): TOrphanWriteKind;
var
  wm: TWriteMsg;
  pm: TPasswordMsg;
  c: TDirectoryConnection;
begin
  AText := '';
  AProfileUuid := '';
  Result := owkNone;
  if not ((AMsg is TWriteMsg) or (AMsg is TPasswordMsg)) then Exit;
  AProfileUuid := AMsg.SessionId;
  if AConnections <> nil then
  begin
    c := AConnections.FindSession(AMsg.SessionId);
    if c <> nil then AProfileUuid := c.Profile.Uuid;
  end;
  // Password Modify: aucun secret dans le texte du journal.
  if AMsg is TPasswordMsg then
  begin
    pm := TPasswordMsg(AMsg);
    AText := 'password modify ' + RdnCaption(pm.UserDn);
    if pm.Result.Ok then Exit(owkSuccess);
    if pm.Result.Error.Category = lecUnknownOutcome then Exit(owkUnknownOutcome);
    AText := ErrorToText(pm.Result.Error) + ' - ' + AText;
    Exit(owkFailed);
  end;
  wm := TWriteMsg(AMsg);
  if wm.Change = nil then Exit;
  if wm.Result.Ok then
  begin
    AText := wm.Change.Describe;
    Exit(owkSuccess);
  end;
  if wm.Result.Error.Category = lecUnknownOutcome then
  begin
    AText := wm.Change.Describe;
    Exit(owkUnknownOutcome);
  end;
  AText := ErrorToText(wm.Result.Error) + ' - ' + wm.Change.Describe;
  Result := owkFailed;
end;

function SettleWriteOutcome(AMsg: TUiMessage; AConnections: TConnectionManager;
  AJournal: TWriteJournal; out AText: string; const AUnknownDetail: string): TOrphanWriteKind;
var
  uuid: string;
begin
  Result := ClassifyOrphanWrite(AMsg, AConnections, uuid, AText);
  if AJournal = nil then Exit;
  case Result of
    owkSuccess, owkFailed:
      AJournal.Resolve(AMsg.TaskId);
    owkUnknownOutcome:
      // Document d'origine de la soumission, jamais le document courant: l'utilisateur a pu en
      // ouvrir un autre entre-temps.
      if AMsg is TPasswordMsg then
        AJournal.RecordUnknownOutcomeRaw(AMsg.TaskId, uuid, 'password modify',
          TPasswordMsg(AMsg).UserDn, TPasswordMsg(AMsg).Result.Error, AUnknownDetail)
      else
        AJournal.RecordUnknownOutcome(AMsg.TaskId, uuid, TWriteMsg(AMsg).Change,
          TWriteMsg(AMsg).Result.Error, AUnknownDetail);
  end;
end;

function IsUnsettledWrite(AMsg: TUiMessage; AJournal: TWriteJournal): Boolean;
begin
  Result := (AJournal <> nil) and ((AMsg is TWriteMsg) or (AMsg is TPasswordMsg)) and
    AJournal.IsPending(AMsg.TaskId);
end;

type
  TEqualityProbe = class
    Schema: TSchemaSnapshot;
    function Known(const AAttr: string): Boolean;
  end;

function TEqualityProbe.Known(const AAttr: string): Boolean;
begin
  Result := SchemaEqualityKnown(Schema, AAttr);
end;

function TreeChildrenRequest(AProfile: TConnectionProfile; const AParentDn: string): TSearchRequest;
var
  i: Integer;
begin
  Result := DefaultSearchRequest;
  Result.BaseDn := AParentDn;
  Result.Scope := ssOneLevel;
  Result.Filter := '(objectClass=*)';
  SetLength(Result.Attributes, Length(TREE_ATTRIBUTES));
  for i := 0 to High(TREE_ATTRIBUTES) do
    Result.Attributes[i] := TREE_ATTRIBUTES[i];
  Result.PageSize := AProfile.PageSize;
  Result.SizeLimit := AProfile.SizeLimit;
  Result.TimeLimitSec := AProfile.OperationTimeoutSec;
end;

function SubtreeEnumerationRequest(AProfile: TConnectionProfile; const ABaseDn: string): TSearchRequest;
begin
  Result := DefaultSearchRequest;
  Result.BaseDn := ABaseDn;
  Result.Scope := ssSubtree;
  Result.Filter := '(objectClass=*)';
  // '1.1': aucun attribut (RFC 4511), seulement les DN.
  Result.Attributes := ['1.1'];
  // Aucune limite: une enumeration tronquee avant suppression ne doit jamais passer pour complete.
  Result.SizeLimit := 0;
  Result.TimeLimitSec := 0;
  Result.PageSize := AProfile.PageSize;
end;

function EntryReadAttributes(AProfile: TConnectionProfile): TStringArray;
var
  i: Integer;
begin
  // AD n'honore pas '+' (RFC 3673): les marqueurs sont nommes dans tous les cas.
  if AProfile.ShowOperationalAttrs then
    Result := ['*', '+']
  else
    Result := ['*'];
  for i := 0 to High(VERSION_MARKERS) do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := VERSION_MARKERS[i];
  end;
end;

function IsHiddenVersionMarker(AProfile: TConnectionProfile; ASchema: TSchemaSnapshot;
  const AAttr: string): Boolean;
var
  i: Integer;
  at: TSchemaAttributeType;
begin
  Result := False;
  if (AProfile = nil) or AProfile.ShowOperationalAttrs then Exit;
  for i := 0 to High(VERSION_MARKERS) do
    if SameText(AAttr, VERSION_MARKERS[i]) then
    begin
      at := nil;
      if ASchema <> nil then at := ASchema.AttributeType(AAttr);
      Exit((at = nil) or (at.Usage <> auUserApplications));
    end;
end;

function QuickSearchFilter(const AText: string; ASchema: TSchemaSnapshot): string;
const
  QUICK_ATTRS: array[0..5] of string = ('cn', 'uid', 'mail', 'ou', 'displayName', 'sAMAccountName');
var
  q, v, terms: string;
  i: Integer;
  checked: Boolean;
begin
  q := Trim(AText);
  if q = '' then
    Exit('(objectClass=*)');
  if q[1] = '(' then
    Exit(q);
  v := FilterEscapeValue(q);
  checked := (ASchema <> nil) and (ASchema.AttributeTypeCount > 0);
  terms := '';
  for i := 0 to High(QUICK_ATTRS) do
    if not checked or (ASchema.AttributeType(QUICK_ATTRS[i]) <> nil) then
      terms := terms + '(' + QUICK_ATTRS[i] + '=*' + v + '*)';
  if terms = '' then
    for i := 0 to High(QUICK_ATTRS) do
      terms := terms + '(' + QUICK_ATTRS[i] + '=*' + v + '*)';
  Result := '(|' + terms + ')';
end;

function FilterUnknownAttributes(const AFilter: string; ASchema: TSchemaSnapshot): TStringArray;
var
  root: TFilterNode;
  err: string;
  seen: TStringList;

  procedure Walk(ANode: TFilterNode);
  var
    i: Integer;
    name: string;
  begin
    if ANode = nil then Exit;
    if ANode.Attr <> '' then
    begin
      name := ANode.Attr;
      if Pos(';', name) > 0 then name := Copy(name, 1, Pos(';', name) - 1);
      if (ASchema.AttributeType(name) = nil) and (seen.IndexOf(name) < 0) then
        seen.Add(name);
    end;
    for i := 0 to ANode.ChildCount - 1 do
      Walk(ANode.Children[i]);
  end;

var
  i: Integer;
begin
  Result := nil;
  if (ASchema = nil) or (ASchema.AttributeTypeCount = 0) then Exit;
  root := FilterParse(AFilter, err);
  if root = nil then Exit;
  seen := TStringList.Create;
  try
    seen.CaseSensitive := False;
    Walk(root);
    SetLength(Result, seen.Count);
    for i := 0 to seen.Count - 1 do
      Result[i] := seen[i];
  finally
    seen.Free;
    root.Free;
  end;
end;

function OneLineText(const AText: string; AMax: Integer): string;
var
  i: Integer;
  c: Char;
  space: Boolean;
begin
  Result := '';
  space := False;
  for i := 1 to Length(AText) do
  begin
    c := AText[i];
    if c in [#9, #10, #13, ' '] then
    begin
      space := Result <> '';
      Continue;
    end;
    if space then Result := Result + ' ';
    space := False;
    Result := Result + c;
  end;
  if Length(Result) > AMax then
    Result := Copy(Result, 1, AMax - 3) + '...';
end;

function IsContainerEntry(AEntry: TLdapEntry): Boolean;
const
  CONTAINER_CLASSES: array[0..10] of string = ('organizationalunit', 'organization', 'domain',
    'dcobject', 'container', 'builtindomain', 'country', 'locality', 'nisdomain',
    'domaindns', 'msds-app-configuration');
var
  a: TLdapAttribute;
  i, k: Integer;
  oc: string;
begin
  Result := False;
  a := AEntry.Find('objectClass');
  if a <> nil then
    for i := 0 to a.ValueCount - 1 do
    begin
      oc := LowerCase(a.Values[i]);
      for k := 0 to High(CONTAINER_CLASSES) do
        if oc = CONTAINER_CLASSES[k] then
          Exit(True);
    end;
  if LowerCase(AEntry.FirstValue('hasSubordinates', '')) = 'true' then Exit(True);
  if StrToIntDef(AEntry.FirstValue('numSubordinates', '0'), 0) > 0 then Exit(True);
end;

function EntryMayHaveChildren(AEntry: TLdapEntry): Boolean;
var
  hasSub: string;
begin
  hasSub := LowerCase(AEntry.FirstValue('hasSubordinates', 'unknown'));
  if hasSub = 'unknown' then
    Result := IsContainerEntry(AEntry) and (AEntry.FirstValue('numSubordinates', '1') <> '0')
  else
    Result := (hasSub = 'true') and (AEntry.FirstValue('numSubordinates', '1') <> '0');
end;

function ServerSupportsControl(ARootDse: TLdapEntry; const AOid: string): Boolean;
var
  sc: TLdapAttribute;
begin
  Result := False;
  if ARootDse = nil then Exit;
  sc := ARootDse.Find('supportedControl');
  Result := (sc <> nil) and (sc.IndexOfValue(AOid) >= 0);
end;

function VersionAssertion(AEntry: TLdapEntry): string;
var
  i: Integer;
  v: RawByteString;
begin
  Result := '';
  for i := 0 to High(VERSION_MARKERS) do
  begin
    v := AEntry.FirstValue(VERSION_MARKERS[i]);
    if v <> '' then
      Exit(FilterToString(FltEq(VERSION_MARKERS[i], v)));
  end;
end;

function SchemaEqualityKnown(ASchema: TSchemaSnapshot; const AAttr: string): Boolean;
begin
  if (ASchema = nil) or (ASchema.AttributeType(AAttr) = nil) then
    Exit(True);
  Result := ASchema.EffectiveEquality(AAttr) <> '';
end;

function PlanModify(AOriginal, AEdited: TLdapEntry; ASchema: TSchemaSnapshot;
  ARootDse: TLdapEntry; out APlan: TModifyPlan): Boolean;
var
  probe: TEqualityProbe;
  opts: TDeltaOptions;
  mods: TLdapModArray;
  err: string;
begin
  APlan := Default(TModifyPlan);
  probe := TEqualityProbe.Create;
  try
    probe.Schema := ASchema;
    opts.EqualityKnown := @probe.Known;
    if not ComputeModifications(AOriginal, AEdited, opts, mods, err) then
    begin
      APlan.Error := err;
      Exit(False);
    end;
  finally
    probe.Free;
  end;
  Result := True;
  if Length(mods) = 0 then Exit;
  APlan.Change := NewChange(ckModify, AOriginal.Dn);
  APlan.Change.Mods := mods;
  if ServerSupportsControl(ARootDse, LDAP_CONTROL_ASSERTION_OID) then
    APlan.Assertion := VersionAssertion(AOriginal);
  APlan.AssertionUnavailable := APlan.Assertion = '';
end;

function SameAttrValues(A, B: TLdapEntry; const ADesc: string): Boolean;
var
  aa, ab: TLdapAttribute;
  la, lb: TStringList;
  i: Integer;
begin
  aa := A.Find(ADesc);
  ab := B.Find(ADesc);
  if (aa = nil) or (ab = nil) then
    Exit(((aa = nil) or (aa.ValueCount = 0)) and ((ab = nil) or (ab.ValueCount = 0)));
  if aa.ValueCount <> ab.ValueCount then Exit(False);
  la := TStringList.Create;
  lb := TStringList.Create;
  try
    for i := 0 to aa.ValueCount - 1 do la.Add(aa.Values[i]);
    for i := 0 to ab.ValueCount - 1 do lb.Add(ab.Values[i]);
    la.Sort;
    lb.Sort;
    Result := la.Equals(lb);
  finally
    la.Free;
    lb.Free;
  end;
end;

function TouchedAttributesUnchanged(AOriginal, ACurrent: TLdapEntry;
  AChange: TLdapChange): Boolean;
var
  i: Integer;
begin
  if (AOriginal = nil) or (ACurrent = nil) or (AChange = nil) or
    ACurrent.DecodeIncomplete or ACurrent.AnyTruncated or
    not SameDnStrict(ACurrent.Dn, AChange.Dn) then
    Exit(False);
  for i := 0 to High(AChange.Mods) do
    if not SameAttrValues(AOriginal, ACurrent, AChange.Mods[i].Attr) then
      Exit(False);
  Result := True;
end;

end.
