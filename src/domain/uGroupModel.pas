// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uGroupModel;

{$mode objfpc}{$H+}

// Groupes: le modele d'appartenance se deduit des classes (member, uniqueMember,
// memberUid, memberURL). On ecrit dans l'attribut du groupe, jamais dans memberOf
// qui est calcule. Le graphe imbrique est explore borne, cycles compris, et une
// information illisible reste "inconnue", jamais "non membre".

interface

uses
  SysUtils, Classes, uLdapEntry, uChangeSet, uConnectionProfile, uSearchModel;

const
  AD_IN_CHAIN_RULE = '1.2.840.113556.1.4.1941';
  GROUP_MAX_NODES = 2000;
  GROUP_MAX_DEPTH = 32;

  GROUP_READ_ATTRS: array[0..6] of string = ('objectClass', 'member', 'uniqueMember',
    'memberUid', 'memberURL', 'primaryGroupToken', 'groupType');
  DYNAMIC_MAX_CRITERIA = 64;

type
  TGroupKind = (
    gkNotGroup,
    gkGroupOfNames,
    gkGroupOfUniqueNames,
    gkPosixGroup,
    gkAdGroup,
    gkDynamicUrl
  );

  TGroupModel = record
    Kind: TGroupKind;
    MemberAttr: string;
    ValuesAreDns: Boolean;
    DynamicAttr: string;
    MustHaveMember: Boolean;
    // Groupe principal AD: ses membres par primaryGroupID n'apparaissent pas dans
    // member. Ils sont bien la, AD prefere simplement ne pas en parler.
    HasPrimaryMembers: Boolean;
  end;

  TMembershipKind = (
    mkDirect,
    mkIndirect,
    mkDynamic,
    mkPrimary,
    mkUnknown
  );

  TMemberNode = record
    Dn: string;
    Parent: Integer;
    Depth: Integer;
    Kind: TMembershipKind;
    IsGroup: Boolean;
    Read: Boolean;
    Unreadable: Boolean;
    Leaf: Boolean;
    Cycle: Boolean;
    SameAs: Integer;
    Note: string;
  end;

  TMemberRef = record
    Value: string;
    Kind: TMembershipKind;
    Leaf: Boolean;
  end;
  TMemberRefArray = array of TMemberRef;

  TMembershipGraph = class
  private
    FNodes: array of TMemberNode;
    FQueue: TList;
    FMaxNodes: Integer;
    FMaxDepth: Integer;
    FLimitHit: Boolean;
    FIndex: TStringList;
    function Key(const ADn: string): string;
    function AddNode(const ADn: string; AParent: Integer; AKind: TMembershipKind): Integer;
    function OnPath(ANode: Integer; const AKey: string): Boolean;
    function GetNode(AIndex: Integer): TMemberNode;
  public
    constructor Create(const ARootDn: string; AMaxNodes: Integer = GROUP_MAX_NODES;
      AMaxDepth: Integer = GROUP_MAX_DEPTH);
    destructor Destroy; override;
    function NextToRead(out ANode: Integer; out ADn: string): Boolean;
    procedure Feed(ANode: Integer; AIsGroup: Boolean; const ANeighbours: TMemberRefArray;
      AUnreadable: Boolean; const ANote: string = '');
    function Count: Integer;
    function PathText(ANode: Integer): string;
    function CycleCount: Integer;
    property Nodes[AIndex: Integer]: TMemberNode read GetNode; default;
    property LimitHit: Boolean read FLimitHit;
  end;

  TLdapUrl = record
    Scheme: string;
    Host: string;
    BaseDn: string;
    Attributes: array of string;
    Scope: TSearchScope;
    Filter: string;
    // Extensions gardees telles que lues: une extension non critique ne doit pas
    // disparaitre en silence a la reecriture.
    Extensions: string;
  end;

resourcestring
  rsGroupNotGroup = 'this entry is not a group';
  rsGroupDynamic = 'dynamic group: members come from its criteria (%s), edit the criteria instead';
  rsGroupLastMember = 'the schema requires at least one %s value; add another member first';
  rsGroupAlreadyMember = 'already a direct member';
  rsGroupNotMember = 'not a direct member';
  rsGroupNeedUid = 'this group lists members by uid: the member has no uid value';
  rsGroupNotDn = '"%s" is not a DN: choose the entry in the search results, or type its full DN';
  rsGroupBadUrl = 'invalid LDAP URL: %s';
  rsGroupUrlCritical = 'unsupported critical LDAP URL extension: %s';
  rsGroupUrlHost = 'the URL designates another server (%s): not evaluated';
  rsGroupKindNames = 'groupOfNames';
  rsGroupKindUnique = 'groupOfUniqueNames';
  rsGroupKindPosix = 'posixGroup (memberUid)';
  rsGroupKindAd = 'Active Directory group';
  rsGroupKindUrl = 'dynamic group (LDAP URL criteria)';
  rsGroupNotDynamic = 'this entry has no dynamic criteria (it is not a groupOfURLs)';
  rsGroupCriterionMissing = 'the criterion was changed or removed meanwhile: read the group again';
  rsGroupCriterionExists = 'this criterion is already present';
  rsGroupCriterionEmpty = 'no change to apply';
  rsGroupTooManyCriteria = 'more than %d criteria';
  rsGroupUrlBase = 'invalid base DN: %s';
  rsGroupUrlFilter = 'invalid filter: %s';
  rsGroupUrlAttr = 'invalid attribute: %s';
  rsGroupKindNone = 'not a group';
  rsMemberDirect = 'direct';
  rsMemberIndirect = 'indirect';
  rsMemberDynamic = 'dynamic';
  rsMemberPrimary = 'primary group';
  rsMemberUnknown = 'unknown';
  rsMemberCycle = 'cycle: already on the path';
  rsMemberLimit = 'exploration bound reached';

function DetectGroupModel(AEntry: TLdapEntry; AServer: TProviderKind): TGroupModel;
function DnIdentityKey(const ADn: string): string;
function GroupKindName(AKind: TGroupKind): string;
function MembershipKindName(AKind: TMembershipKind): string;
function MemberValue(const AModel: TGroupModel; const AMemberDn, AMemberUid: string): string;
function LooksLikeDn(const S: string): Boolean;
function PlanAddMember(AGroup: TLdapEntry; const AModel: TGroupModel;
  const AMemberDn, AMemberUid: string; out AError: string): TLdapChange;
function PlanRemoveMember(AGroup: TLdapEntry; const AModel: TGroupModel;
  const AMemberDn, AMemberUid: string; out AError: string): TLdapChange;
function DirectGroupsFilter(const ADn, AUid: string): string;
function AdNestedGroupsFilter(const ADn: string): string;
function AdPrimaryMembersFilter(const APrimaryGroupToken: string): string;
function AdPrimaryGroupSid(const AUserSid: RawByteString; ARid: Cardinal;
  out ASid: RawByteString): Boolean;
function SidToText(const ASid: RawByteString): string;
function ParseLdapUrl(const AUrl: string; out AResult: TLdapUrl; out AError: string): Boolean;
function DynamicPreviewRequest(const AUrl: TLdapUrl; ALimit: Integer): TSearchRequest;
function BuildLdapUrl(const AUrl: TLdapUrl): string;
function DynamicCriterionProblem(const AUrl: TLdapUrl): string;
function PlanDynamicCriteria(AGroup: TLdapEntry; const AModel: TGroupModel;
  const AOld, ANew: array of string; out AError: string): TLdapChange;
function DynamicCriteriaAttr(AEntry: TLdapEntry; AServer: TProviderKind): string;

implementation

uses
  uLdapFilter, uLdapDn;

function DnIdentityKey(const ADn: string): string;
var
  d: TLdapDn;
  cmp: TDnComparer;
begin
  if not DnTryParse(AsciiLowerCase(ADn), d) then Exit('?' + AsciiLowerCase(Trim(ADn)));
  cmp := TDnComparer.Create;
  try
    Result := DnStrictKey(cmp, d);
  finally
    cmp.Free;
  end;
end;

function RdnOrDn(const ADn: string): string;
var
  d: TLdapDn;
begin
  if DnTryParse(ADn, d) and (DnRdnCount(d) > 0) then
    Result := RdnToString(DnLeaf(d))
  else
    Result := ADn;
end;

function HasClass(AEntry: TLdapEntry; const AClass: string): Boolean;
var
  a: TLdapAttribute;
  i: Integer;
begin
  Result := False;
  a := AEntry.Find('objectClass');
  if a = nil then Exit;
  for i := 0 to a.ValueCount - 1 do
    if SameText(a.Values[i], AClass) then Exit(True);
end;

function DetectGroupModel(AEntry: TLdapEntry; AServer: TProviderKind): TGroupModel;
begin
  Result := Default(TGroupModel);
  Result.Kind := gkNotGroup;
  if AEntry = nil then Exit;
  if HasClass(AEntry, 'groupOfURLs') then
  begin
    Result.Kind := gkDynamicUrl;
    Result.DynamicAttr := 'memberURL';
    if HasClass(AEntry, 'groupOfUniqueNames') then
    begin
      Result.MemberAttr := 'uniqueMember';
      Result.ValuesAreDns := True;
    end
    else if HasClass(AEntry, 'groupOfNames') then
    begin
      Result.MemberAttr := 'member';
      Result.ValuesAreDns := True;
    end;
    Exit;
  end;
  if (AServer = pkActiveDirectory) and HasClass(AEntry, 'group') then
  begin
    Result.Kind := gkAdGroup;
    Result.MemberAttr := 'member';
    Result.ValuesAreDns := True;
    Result.HasPrimaryMembers := True;
    Exit;
  end;
  if HasClass(AEntry, 'groupOfUniqueNames') then
  begin
    Result.Kind := gkGroupOfUniqueNames;
    Result.MemberAttr := 'uniqueMember';
    Result.ValuesAreDns := True;
    Result.MustHaveMember := True;
    Exit;
  end;
  if HasClass(AEntry, 'groupOfNames') or HasClass(AEntry, 'group') then
  begin
    if HasClass(AEntry, 'group') and not HasClass(AEntry, 'groupOfNames') then
    begin
      Result.Kind := gkAdGroup;
      Result.HasPrimaryMembers := True;
    end
    else
      Result.Kind := gkGroupOfNames;
    Result.MemberAttr := 'member';
    Result.ValuesAreDns := True;
    // RFC 4519 impose au moins un member, le groupe AD s'en passe tres bien.
    Result.MustHaveMember := Result.Kind = gkGroupOfNames;
    Exit;
  end;
  if HasClass(AEntry, 'posixGroup') then
  begin
    Result.Kind := gkPosixGroup;
    Result.MemberAttr := 'memberUid';
    Result.ValuesAreDns := False;
  end;
end;

function GroupKindName(AKind: TGroupKind): string;
begin
  case AKind of
    gkGroupOfNames: Result := rsGroupKindNames;
    gkGroupOfUniqueNames: Result := rsGroupKindUnique;
    gkPosixGroup: Result := rsGroupKindPosix;
    gkAdGroup: Result := rsGroupKindAd;
    gkDynamicUrl: Result := rsGroupKindUrl;
  else
    Result := rsGroupKindNone;
  end;
end;

function MembershipKindName(AKind: TMembershipKind): string;
begin
  case AKind of
    mkDirect: Result := rsMemberDirect;
    mkIndirect: Result := rsMemberIndirect;
    mkDynamic: Result := rsMemberDynamic;
    mkPrimary: Result := rsMemberPrimary;
  else
    Result := rsMemberUnknown;
  end;
end;

function LooksLikeDn(const S: string): Boolean;
var
  d: TLdapDn;
begin
  Result := (Pos('=', S) > 0) and DnTryParse(S, d) and (DnRdnCount(d) > 0);
end;

function MemberValue(const AModel: TGroupModel; const AMemberDn, AMemberUid: string): string;
begin
  if AModel.ValuesAreDns then
    Result := AMemberDn
  else
    Result := AMemberUid;
end;

function FindMemberIndex(AAttr: TLdapAttribute; const AModel: TGroupModel;
  const AValue: string): Integer;
var
  v, key: string;
  p, i: Integer;
begin
  Result := -1;
  if AAttr = nil then Exit;
  if not AModel.ValuesAreDns then
  begin
    for i := 0 to AAttr.ValueCount - 1 do
      if AAttr.Values[i] = AValue then Exit(i);
    Exit(-1);
  end;
  key := DnIdentityKey(AValue);
  for i := 0 to AAttr.ValueCount - 1 do
  begin
    v := AAttr.Values[i];
    p := Pos('#''', v);
    if (p > 0) and (Copy(v, Length(v) - 1, 2) = '''B') then
      v := Copy(v, 1, p - 1);
    if DnIdentityKey(v) = key then Exit(i);
  end;
  Result := -1;
end;

function CheckWritable(const AModel: TGroupModel; out AError: string): Boolean;
begin
  Result := False;
  AError := '';
  if AModel.Kind = gkNotGroup then
  begin
    AError := rsGroupNotGroup;
    Exit;
  end;
  if AModel.MemberAttr = '' then
  begin
    AError := Format(rsGroupDynamic, [AModel.DynamicAttr]);
    Exit;
  end;
  Result := True;
end;

function PlanAddMember(AGroup: TLdapEntry; const AModel: TGroupModel;
  const AMemberDn, AMemberUid: string; out AError: string): TLdapChange;
var
  v: string;
begin
  Result := nil;
  if not CheckWritable(AModel, AError) then Exit;
  v := MemberValue(AModel, AMemberDn, AMemberUid);
  if v = '' then
  begin
    AError := rsGroupNeedUid;
    Exit;
  end;
  // Un bout de nom n'est pas un DN. AD le refuse avec 0000054F WILL_NOT_PERFORM,
  // sans dire pourquoi: on le dit a sa place.
  if AModel.ValuesAreDns and not LooksLikeDn(v) then
  begin
    AError := Format(rsGroupNotDn, [v]);
    Exit;
  end;
  if FindMemberIndex(AGroup.Find(AModel.MemberAttr), AModel, v) >= 0 then
  begin
    AError := rsGroupAlreadyMember;
    Exit;
  end;
  // Ajout de la seule valeur: les autres membres ne sont jamais reecrits.
  Result := NewChange(ckModify, AGroup.Dn);
  Result.AddMod(moAdd, AModel.MemberAttr, [v]);
end;

function PlanRemoveMember(AGroup: TLdapEntry; const AModel: TGroupModel;
  const AMemberDn, AMemberUid: string; out AError: string): TLdapChange;
var
  a: TLdapAttribute;
  i: Integer;
  v: string;
begin
  Result := nil;
  if not CheckWritable(AModel, AError) then Exit;
  v := MemberValue(AModel, AMemberDn, AMemberUid);
  a := AGroup.Find(AModel.MemberAttr);
  i := FindMemberIndex(a, AModel, v);
  if i < 0 then
  begin
    AError := rsGroupNotMember;
    Exit;
  end;
  if AModel.MustHaveMember and (a.ValueCount <= 1) and not a.Truncated then
  begin
    AError := Format(rsGroupLastMember, [AModel.MemberAttr]);
    Exit;
  end;
  // Valeur exacte telle que lue, suffixe uniqueMember compris.
  Result := NewChange(ckModify, AGroup.Dn);
  Result.AddMod(moDelete, AModel.MemberAttr, [a.Values[i]]);
end;

function DirectGroupsFilter(const ADn, AUid: string): string;
var
  e: string;
begin
  e := FilterEscapeValue(ADn);
  Result := '(|(member=' + e + ')(uniqueMember=' + e + ')';
  if AUid <> '' then
    Result := Result + '(memberUid=' + FilterEscapeValue(AUid) + ')';
  Result := Result + ')';
end;

function AdNestedGroupsFilter(const ADn: string): string;
begin
  Result := '(&(objectClass=group)(member:' + AD_IN_CHAIN_RULE + ':=' +
    FilterEscapeValue(ADn) + '))';
end;

function AdPrimaryMembersFilter(const APrimaryGroupToken: string): string;
begin
  Result := '(primaryGroupID=' + FilterEscapeValue(Trim(APrimaryGroupToken)) + ')';
end;

// SID binaire (MS-DTYP 2.4.2.2): autorite sur 6 octets gros-boutiste, sous-autorites
// 32 bits petit-boutiste. Deux boutismes dans la meme structure, pourquoi choisir.
function AdPrimaryGroupSid(const AUserSid: RawByteString; ARid: Cardinal;
  out ASid: RawByteString): Boolean;
var
  n: Integer;
begin
  Result := False;
  ASid := '';
  if Length(AUserSid) < 8 then Exit;
  n := Ord(AUserSid[2]);
  if (Ord(AUserSid[1]) <> 1) or (n < 1) or (n > 15) or (Length(AUserSid) <> 8 + 4 * n) then Exit;
  ASid := Copy(AUserSid, 1, Length(AUserSid) - 4) +
    Chr(ARid and $FF) + Chr((ARid shr 8) and $FF) + Chr((ARid shr 16) and $FF) +
    Chr((ARid shr 24) and $FF);
  Result := True;
end;

function SidToText(const ASid: RawByteString): string;
var
  n, i: Integer;
  auth: QWord;
  sub: Cardinal;
begin
  Result := '';
  if Length(ASid) < 8 then Exit;
  n := Ord(ASid[2]);
  if Length(ASid) <> 8 + 4 * n then Exit;
  auth := 0;
  for i := 3 to 8 do
    auth := (auth shl 8) or Ord(ASid[i]);
  Result := 'S-' + IntToStr(Ord(ASid[1])) + '-' + IntToStr(auth);
  for i := 0 to n - 1 do
  begin
    sub := Ord(ASid[9 + 4 * i]) or (Ord(ASid[10 + 4 * i]) shl 8) or
      (Ord(ASid[11 + 4 * i]) shl 16) or (Cardinal(Ord(ASid[12 + 4 * i])) shl 24);
    Result := Result + '-' + IntToStr(sub);
  end;
end;

function PercentDecode(const S: string; out AOut: string): Boolean;
var
  i: Integer;
  h: Integer;
begin
  AOut := '';
  Result := False;
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = '%' then
    begin
      if (i + 2 > Length(S)) or not TryStrToInt('$' + Copy(S, i + 1, 2), h) then Exit;
      AOut := AOut + Chr(h);
      Inc(i, 3);
    end
    else
    begin
      AOut := AOut + S[i];
      Inc(i);
    end;
  end;
  Result := True;
end;

function ParseLdapUrl(const AUrl: string; out AResult: TLdapUrl; out AError: string): Boolean;
var
  rest, hostPart, dnPart, s, ext: string;
  parts, exts: TStringArray;
  p, i: Integer;
  node: TFilterNode;
  d: TLdapDn;
begin
  Result := False;
  AError := '';
  AResult := Default(TLdapUrl);
  AResult.Scope := ssBase;
  AResult.Filter := '(objectClass=*)';
  rest := Trim(AUrl);
  if SameText(Copy(rest, 1, 7), 'ldap://') then
  begin
    AResult.Scheme := 'ldap';
    Delete(rest, 1, 7);
  end
  else if SameText(Copy(rest, 1, 8), 'ldaps://') or SameText(Copy(rest, 1, 8), 'ldapi://') then
  begin
    AResult.Scheme := LowerCase(Copy(rest, 1, 5));
    Delete(rest, 1, 8);
  end
  else
  begin
    AError := Format(rsGroupBadUrl, [AUrl]);
    Exit;
  end;
  p := Pos('/', rest);
  if p = 0 then
  begin
    hostPart := rest;
    rest := '';
  end
  else
  begin
    hostPart := Copy(rest, 1, p - 1);
    rest := Copy(rest, p + 1, MaxInt);
  end;
  AResult.Host := hostPart;
  parts := rest.Split(['?']);
  if Length(parts) > 5 then
  begin
    AError := Format(rsGroupBadUrl, [AUrl]);
    Exit;
  end;
  if Length(parts) >= 1 then
  begin
    if not PercentDecode(parts[0], dnPart) or ((dnPart <> '') and not DnTryParse(dnPart, d)) then
    begin
      AError := Format(rsGroupBadUrl, [AUrl]);
      Exit;
    end;
    AResult.BaseDn := dnPart;
  end;
  if (Length(parts) >= 2) and (parts[1] <> '') then
  begin
    AResult.Attributes := parts[1].Split([',']);
    for i := 0 to High(AResult.Attributes) do
      if not PercentDecode(AResult.Attributes[i], s) then
      begin
        AError := Format(rsGroupBadUrl, [AUrl]);
        Exit;
      end
      else
        AResult.Attributes[i] := s;
  end;
  if (Length(parts) >= 3) and (parts[2] <> '') then
  begin
    s := LowerCase(parts[2]);
    if s = 'base' then AResult.Scope := ssBase
    else if s = 'one' then AResult.Scope := ssOneLevel
    else if s = 'sub' then AResult.Scope := ssSubtree
    else
    begin
      AError := Format(rsGroupBadUrl, [AUrl]);
      Exit;
    end;
  end;
  if (Length(parts) >= 4) and (parts[3] <> '') then
  begin
    if not PercentDecode(parts[3], s) then
    begin
      AError := Format(rsGroupBadUrl, [AUrl]);
      Exit;
    end;
    node := FilterParse(s, AError);
    if node = nil then
    begin
      AError := Format(rsGroupBadUrl, [AError]);
      Exit;
    end;
    node.Free;
    AResult.Filter := s;
  end;
  if Length(parts) = 5 then
  begin
    AResult.Extensions := parts[4];
    exts := parts[4].Split([',']);
    for i := 0 to High(exts) do
    begin
      ext := exts[i];
      // RFC 4516: une extension critique inconnue rend l'URL inutilisable. On ne fait
      // pas semblant de l'avoir comprise.
      if (ext <> '') and (ext[1] = '!') then
      begin
        AError := Format(rsGroupUrlCritical, [Copy(ext, 2, MaxInt)]);
        Exit;
      end;
    end;
  end;
  Result := True;
end;

function DynamicPreviewRequest(const AUrl: TLdapUrl; ALimit: Integer): TSearchRequest;
begin
  Result := DefaultSearchRequest;
  Result.BaseDn := AUrl.BaseDn;
  Result.Scope := AUrl.Scope;
  Result.Filter := AUrl.Filter;
  Result.Attributes := ['1.1'];
  Result.SizeLimit := ALimit;
  Result.ServerSizeLimit := ALimit;
end;

// RFC 4516 2.1: tout octet hors des caracteres surs part en %XX, '?', '%', espace,
// '\' et non ASCII compris, pour qu'une valeur ne devienne pas un separateur.
function UrlEncodePart(const S: string; const ASafe: TSysCharSet): string;
const
  HEX: array[0..15] of Char = '0123456789ABCDEF';
var
  i: Integer;
  b: Byte;
begin
  Result := '';
  for i := 1 to Length(S) do
    if S[i] in ASafe then
      Result := Result + S[i]
    else
    begin
      b := Ord(S[i]);
      Result := Result + '%' + HEX[b shr 4] + HEX[b and 15];
    end;
end;

const
  URL_ALNUM = ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'];
  URL_DN_SAFE = URL_ALNUM + ['=', ',', '+', ';', ':', '@', '!', '$', '''', '*'];
  URL_ATTR_SAFE = URL_ALNUM + [';'];
  URL_FILTER_SAFE = URL_ALNUM + ['(', ')', '&', '|', '!', '=', '*', ':', ',', '+', ';', '@', '$', ''''];

function BuildLdapUrl(const AUrl: TLdapUrl): string;
var
  i: Integer;
  attrs, scope, scheme: string;
begin
  scheme := AUrl.Scheme;
  if scheme = '' then scheme := 'ldap';
  attrs := '';
  for i := 0 to High(AUrl.Attributes) do
  begin
    if i > 0 then attrs := attrs + ',';
    attrs := attrs + UrlEncodePart(AUrl.Attributes[i], URL_ATTR_SAFE);
  end;
  case AUrl.Scope of
    ssBase: scope := 'base';
    ssOneLevel: scope := 'one';
  else
    scope := 'sub';
  end;
  Result := scheme + '://' + AUrl.Host + '/' + UrlEncodePart(AUrl.BaseDn, URL_DN_SAFE) + '?' + attrs +
    '?' + scope + '?' + UrlEncodePart(AUrl.Filter, URL_FILTER_SAFE);
  if AUrl.Extensions <> '' then Result := Result + '?' + AUrl.Extensions;
end;

function DynamicCriterionProblem(const AUrl: TLdapUrl): string;
var
  d: TLdapDn;
  node: TFilterNode;
  err: string;
  i: Integer;
  back: TLdapUrl;
begin
  Result := '';
  if (AUrl.BaseDn <> '') and not DnTryParse(AUrl.BaseDn, d) then
    Exit(Format(rsGroupUrlBase, [AUrl.BaseDn]));
  node := FilterParse(AUrl.Filter, err);
  if node = nil then Exit(Format(rsGroupUrlFilter, [err]));
  node.Free;
  for i := 0 to High(AUrl.Attributes) do
    if not IsValidAttributeDescription(AUrl.Attributes[i]) then
      Exit(Format(rsGroupUrlAttr, [AUrl.Attributes[i]]));
  // Ce qui est ecrit doit se relire a l'identique, sinon on ne l'ecrit pas.
  if not ParseLdapUrl(BuildLdapUrl(AUrl), back, err) then Exit(err);
end;

function DynamicCriteriaAttr(AEntry: TLdapEntry; AServer: TProviderKind): string;
begin
  Result := DetectGroupModel(AEntry, AServer).DynamicAttr;
end;

function PlanDynamicCriteria(AGroup: TLdapEntry; const AModel: TGroupModel;
  const AOld, ANew: array of string; out AError: string): TLdapChange;
var
  a: TLdapAttribute;
  removed, added: array of RawByteString;
  i, j: Integer;
  found: Boolean;
begin
  Result := nil;
  AError := '';
  if (AGroup = nil) or (AModel.DynamicAttr = '') then
  begin
    AError := rsGroupNotDynamic;
    Exit;
  end;
  if Length(ANew) > DYNAMIC_MAX_CRITERIA then
  begin
    AError := Format(rsGroupTooManyCriteria, [DYNAMIC_MAX_CRITERIA]);
    Exit;
  end;
  a := AGroup.Find(AModel.DynamicAttr);
  removed := nil;
  added := nil;
  for i := 0 to High(AOld) do
  begin
    found := False;
    for j := 0 to High(ANew) do
      if ANew[j] = AOld[i] then found := True;
    if found then Continue;
    if (a = nil) or (a.IndexOfValue(AOld[i]) < 0) then
    begin
      AError := rsGroupCriterionMissing;
      Exit;
    end;
    SetLength(removed, Length(removed) + 1);
    removed[High(removed)] := AOld[i];
  end;
  for i := 0 to High(ANew) do
  begin
    found := False;
    for j := 0 to High(AOld) do
      if AOld[j] = ANew[i] then found := True;
    for j := 0 to High(added) do
      if added[j] = ANew[i] then
      begin
        AError := rsGroupCriterionExists;
        Exit;
      end;
    if found then Continue;
    SetLength(added, Length(added) + 1);
    added[High(added)] := ANew[i];
  end;
  if (Length(removed) = 0) and (Length(added) = 0) then
  begin
    AError := rsGroupCriterionEmpty;
    Exit;
  end;
  Result := NewChange(ckModify, AGroup.Dn);
  // Une seule requete, retrait exact puis ajout: echec si un autre client a
  // change la valeur entre-temps, plutot que d'ecraser son travail.
  if Length(removed) > 0 then Result.AddMod(moDelete, AModel.DynamicAttr, removed);
  if Length(added) > 0 then Result.AddMod(moAdd, AModel.DynamicAttr, added);
end;

constructor TMembershipGraph.Create(const ARootDn: string; AMaxNodes, AMaxDepth: Integer);
begin
  inherited Create;
  FMaxNodes := AMaxNodes;
  FMaxDepth := AMaxDepth;
  FQueue := TList.Create;
  FIndex := TStringList.Create;
  FIndex.Sorted := True;
  FIndex.Duplicates := dupIgnore;
  FIndex.CaseSensitive := True;
  AddNode(ARootDn, -1, mkDirect);
  FNodes[0].IsGroup := True;
  FQueue.Add(Pointer(PtrInt(0)));
end;

destructor TMembershipGraph.Destroy;
begin
  FQueue.Free;
  FIndex.Free;
  inherited Destroy;
end;

function TMembershipGraph.Key(const ADn: string): string;
begin
  Result := DnIdentityKey(ADn);
end;

function TMembershipGraph.AddNode(const ADn: string; AParent: Integer;
  AKind: TMembershipKind): Integer;
var
  n: TMemberNode;
  k: string;
  i: Integer;
begin
  n := Default(TMemberNode);
  n.Dn := ADn;
  n.Parent := AParent;
  n.Kind := AKind;
  n.SameAs := -1;
  if AParent >= 0 then n.Depth := FNodes[AParent].Depth + 1;
  k := Key(ADn);
  i := FIndex.IndexOf(k);
  if i >= 0 then
    n.SameAs := PtrInt(FIndex.Objects[i]);
  SetLength(FNodes, Length(FNodes) + 1);
  Result := High(FNodes);
  FNodes[Result] := n;
  if i < 0 then FIndex.AddObject(k, TObject(PtrInt(Result)));
end;

function TMembershipGraph.OnPath(ANode: Integer; const AKey: string): Boolean;
begin
  Result := False;
  while ANode >= 0 do
  begin
    if Key(FNodes[ANode].Dn) = AKey then Exit(True);
    ANode := FNodes[ANode].Parent;
  end;
end;

function TMembershipGraph.GetNode(AIndex: Integer): TMemberNode;
begin
  Result := FNodes[AIndex];
end;

function TMembershipGraph.Count: Integer;
begin
  Result := Length(FNodes);
end;

function TMembershipGraph.NextToRead(out ANode: Integer; out ADn: string): Boolean;
begin
  Result := False;
  ANode := -1;
  ADn := '';
  while FQueue.Count > 0 do
  begin
    ANode := PtrInt(FQueue[0]);
    FQueue.Delete(0);
    if FNodes[ANode].Read then Continue;
    ADn := FNodes[ANode].Dn;
    Exit(True);
  end;
end;

procedure TMembershipGraph.Feed(ANode: Integer; AIsGroup: Boolean;
  const ANeighbours: TMemberRefArray; AUnreadable: Boolean; const ANote: string);
var
  i, child: Integer;
  kind: TMembershipKind;
  k: string;
begin
  if (ANode < 0) or (ANode > High(FNodes)) then Exit;
  FNodes[ANode].Read := True;
  FNodes[ANode].IsGroup := AIsGroup;
  if ANote <> '' then FNodes[ANode].Note := ANote;
  if AUnreadable then
  begin
    FNodes[ANode].Unreadable := True;
    Exit;
  end;
  if not AIsGroup then Exit;
  for i := 0 to High(ANeighbours) do
  begin
    if Length(FNodes) >= FMaxNodes then
    begin
      FLimitHit := True;
      FNodes[ANode].Note := rsMemberLimit;
      Exit;
    end;
    kind := ANeighbours[i].Kind;
    if (kind = mkDirect) and (FNodes[ANode].Depth >= 1) then kind := mkIndirect;
    child := AddNode(ANeighbours[i].Value, ANode, kind);
    if ANeighbours[i].Leaf then
    begin
      FNodes[child].Leaf := True;
      FNodes[child].Read := True;
      Continue;
    end;
    k := Key(ANeighbours[i].Value);
    if OnPath(ANode, k) then
    begin
      FNodes[child].Cycle := True;
      FNodes[child].Note := rsMemberCycle;
      FNodes[child].Read := True;
      Continue;
    end;
    if FNodes[child].SameAs >= 0 then
    begin
      FNodes[child].Read := True;
      FNodes[child].IsGroup := FNodes[FNodes[child].SameAs].IsGroup;
      Continue;
    end;
    if kind in [mkDynamic, mkUnknown] then
    begin
      FNodes[child].Read := True;
      Continue;
    end;
    if FNodes[child].Depth >= FMaxDepth then
    begin
      FLimitHit := True;
      FNodes[child].Note := rsMemberLimit;
      FNodes[child].Read := True;
      Continue;
    end;
    FQueue.Add(Pointer(PtrInt(child)));
  end;
end;

function TMembershipGraph.PathText(ANode: Integer): string;
var
  parts: TStringList;
  i: Integer;
begin
  parts := TStringList.Create;
  try
    while ANode >= 0 do
    begin
      parts.Insert(0, RdnOrDn(FNodes[ANode].Dn));
      ANode := FNodes[ANode].Parent;
    end;
    Result := '';
    for i := 0 to parts.Count - 1 do
    begin
      if i > 0 then Result := Result + ' > ';
      Result := Result + parts[i];
    end;
  finally
    parts.Free;
  end;
end;

function TMembershipGraph.CycleCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FNodes) do
    if FNodes[i].Cycle then Inc(Result);
end;

end.
