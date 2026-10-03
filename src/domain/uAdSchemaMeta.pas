// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAdSchemaMeta;

{$mode objfpc}{$H+}

// Schema Active Directory lu dans attributeSchema / classSchema. Le CN=Aggregate d'AD
// declare un SID en Octet String, ce qui est techniquement vrai et parfaitement
// inutile: le vrai type vient de attributeSyntax / oMSyntax (MS-ADTS 3.1.1.2.2.2).
// Une lecture incomplete garde sa raison; une metadonnee absente n'est pas un type.

interface

uses
  SysUtils, Classes, Contnrs, uLdapEntry;

const
  AD_META_MAX_OBJECTS = 50000;
  AD_META_MAX_LIST = 1024;

  AD_SYNTAX_DN = '2.5.5.1';
  AD_SYNTAX_OID = '2.5.5.2';
  AD_SYNTAX_CASE_STRING = '2.5.5.3';
  AD_SYNTAX_TELETEX = '2.5.5.4';
  AD_SYNTAX_PRINTABLE = '2.5.5.5';
  AD_SYNTAX_NUMERIC = '2.5.5.6';
  AD_SYNTAX_DN_BINARY = '2.5.5.7';
  AD_SYNTAX_BOOLEAN = '2.5.5.8';
  AD_SYNTAX_INTEGER = '2.5.5.9';
  AD_SYNTAX_OCTET = '2.5.5.10';
  AD_SYNTAX_TIME = '2.5.5.11';
  AD_SYNTAX_UNICODE = '2.5.5.12';
  AD_SYNTAX_PRESENTATION = '2.5.5.13';
  AD_SYNTAX_DN_STRING = '2.5.5.14';
  AD_SYNTAX_SD = '2.5.5.15';
  AD_SYNTAX_LARGE_INTEGER = '2.5.5.16';
  AD_SYNTAX_SID = '2.5.5.17';

  AD_OM_UTC_TIME = 23;
  AD_OM_GENERALIZED_TIME = 24;

  AD_FLAG_SCHEMA_BASE_OBJECT = $10;

  AD_SCHEMA_READ_ATTRS: array[0..27] of string = ('objectClass', 'lDAPDisplayName',
    'attributeID', 'attributeSyntax', 'oMSyntax', 'oMObjectClass', 'isSingleValued',
    'systemOnly', 'rangeLower', 'rangeUpper', 'schemaIDGUID', 'systemFlags', 'isDefunct',
    'searchFlags', 'linkID', 'governsID', 'objectClassCategory', 'subClassOf',
    'systemMustContain', 'mustContain', 'systemMayContain', 'mayContain',
    'systemAuxiliaryClass', 'auxiliaryClass', 'systemPossSuperiors', 'possSuperiors',
    'defaultObjectCategory', 'cn');

type
  TAdAttributeMeta = class
  public
    Name: string;
    Cn: string;
    AttributeId: string;
    AttributeSyntax: string;
    OmSyntax: Integer;
    OmObjectClassHex: string;
    SingleValued: Boolean;
    SystemOnly: Boolean;
    HasRangeLower, HasRangeUpper: Boolean;
    RangeLower, RangeUpper: Int64;
    SchemaIdGuid: RawByteString;
    SystemFlags: Int64;
    IsDefunct: Boolean;
    LinkId: Integer;
    function IsBaseSchema: Boolean;
  end;

  TAdClassCategory = (accClass88, accStructural, accAbstract, accAuxiliary, accUnknown);

  TAdClassMeta = class
  public
    Name: string;
    Cn: string;
    GovernsId: string;
    Category: TAdClassCategory;
    SubClassOf: string;
    SystemMust, Must, SystemMay, May: TStringArray;
    SystemAux, Aux, SystemPossSuperiors, PossSuperiors: TStringArray;
    DefaultObjectCategory: string;
    SystemOnly: Boolean;
    IsDefunct: Boolean;
    SchemaIdGuid: RawByteString;
    SystemFlags: Int64;
    function IsBaseSchema: Boolean;
  end;

  TAdSchemaMeta = class
  private
    FAttrs: TObjectList;
    FClasses: TObjectList;
    FAttrIndex: TStringList;
    FClassIndex: TStringList;
    FComplete: Boolean;
    FReason: string;
    FSchemaDn: string;
    FIgnored: Integer;
    FRoleOwner: string;
  public
    constructor Create(const ASchemaDn: string);
    destructor Destroy; override;
    function Feed(AEntry: TLdapEntry): Boolean;
    function Attribute(const AName: string): TAdAttributeMeta;
    function ObjectClass(const AName: string): TAdClassMeta;
    function AttributeCount: Integer;
    function ClassCount: Integer;
    function AttributeAt(AIndex: Integer): TAdAttributeMeta;
    function ClassAt(AIndex: Integer): TAdClassMeta;
    procedure MarkComplete;
    procedure MarkIncomplete(const AReason: string);
    property Complete: Boolean read FComplete;
    property Reason: string read FReason;
    property SchemaDn: string read FSchemaDn;
    property RoleOwner: string read FRoleOwner write FRoleOwner;
    property Ignored: Integer read FIgnored;
  end;

resourcestring
  rsAdSynDn = 'Distinguished name';
  rsAdSynOid = 'Object identifier';
  rsAdSynCaseString = 'Case-sensitive string';
  rsAdSynTeletex = 'Case-insensitive string';
  rsAdSynPrintable = 'Printable or IA5 string';
  rsAdSynNumeric = 'Numeric string';
  rsAdSynDnBinary = 'DN with binary';
  rsAdSynOrName = 'OR-Name';
  rsAdSynBoolean = 'Boolean';
  rsAdSynInteger = 'Integer';
  rsAdSynEnumeration = 'Enumeration';
  rsAdSynOctet = 'Octet string';
  rsAdSynUtcTime = 'UTC time';
  rsAdSynGenTime = 'Generalized time';
  rsAdSynUnicode = 'Unicode string';
  rsAdSynPresentation = 'Presentation address';
  rsAdSynDnString = 'DN with string';
  rsAdSynAccessPoint = 'Access point';
  rsAdSynSd = 'NT security descriptor';
  rsAdSynLargeInteger = 'Large integer';
  rsAdSynSid = 'SID';
  rsAdSynReplicaLink = 'Replica link';
  rsAdSynUnknown = 'unknown AD syntax %s (oMSyntax %d)';

function AdSyntaxName(const AAttributeSyntax: string; AOmSyntax: Integer;
  const AOmObjectClassHex: string): string;

implementation

uses
  uRtBytes;

const
  OMOC_DS_DN = '2b0c0287731c00854a';
  OMOC_DN_BINARY = '2a864886f7140101010b';
  OMOC_DN_STRING = '2a864886f7140101010c';
  OMOC_OR_NAME = '56060102050b1d';
  OMOC_ACCESS_POINT = '2b0c0287731c00853e';
  OMOC_PRESENTATION = '2b0c0287731c00855c';
  OMOC_REPLICA_LINK = '2a864886f71401010106';

function AdSyntaxName(const AAttributeSyntax: string; AOmSyntax: Integer;
  const AOmObjectClassHex: string): string;
var
  s: string;
begin
  s := AAttributeSyntax;
  if s = AD_SYNTAX_DN then Result := rsAdSynDn
  else if s = AD_SYNTAX_OID then Result := rsAdSynOid
  else if s = AD_SYNTAX_CASE_STRING then Result := rsAdSynCaseString
  else if s = AD_SYNTAX_TELETEX then Result := rsAdSynTeletex
  else if s = AD_SYNTAX_PRINTABLE then Result := rsAdSynPrintable
  else if s = AD_SYNTAX_NUMERIC then Result := rsAdSynNumeric
  else if s = AD_SYNTAX_DN_BINARY then
  begin
    if AOmObjectClassHex = OMOC_OR_NAME then Result := rsAdSynOrName
    else Result := rsAdSynDnBinary;
  end
  else if s = AD_SYNTAX_BOOLEAN then Result := rsAdSynBoolean
  else if s = AD_SYNTAX_INTEGER then
  begin
    if AOmSyntax = 10 then Result := rsAdSynEnumeration else Result := rsAdSynInteger;
  end
  else if s = AD_SYNTAX_OCTET then
  begin
    if AOmObjectClassHex = OMOC_REPLICA_LINK then Result := rsAdSynReplicaLink
    else Result := rsAdSynOctet;
  end
  else if s = AD_SYNTAX_TIME then
  begin
    if AOmSyntax = AD_OM_UTC_TIME then Result := rsAdSynUtcTime else Result := rsAdSynGenTime;
  end
  else if s = AD_SYNTAX_UNICODE then Result := rsAdSynUnicode
  else if s = AD_SYNTAX_PRESENTATION then Result := rsAdSynPresentation
  else if s = AD_SYNTAX_DN_STRING then
  begin
    if AOmObjectClassHex = OMOC_ACCESS_POINT then Result := rsAdSynAccessPoint
    else Result := rsAdSynDnString;
  end
  else if s = AD_SYNTAX_SD then Result := rsAdSynSd
  else if s = AD_SYNTAX_LARGE_INTEGER then Result := rsAdSynLargeInteger
  else if s = AD_SYNTAX_SID then Result := rsAdSynSid
  else Result := Format(rsAdSynUnknown, [AAttributeSyntax, AOmSyntax]);
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
    if AsciiLowerCase(string(a.Values[i])) = AsciiLowerCase(AClass) then Exit(True);
end;

function Text1(AEntry: TLdapEntry; const AAttr: string): string;
begin
  Result := string(AEntry.FirstValue(AAttr, ''));
end;

function Bool1(AEntry: TLdapEntry; const AAttr: string): Boolean;
begin
  // Boolean LDAP: TRUE en majuscules (RFC 4517 3.3.3). "true", "Yes" et "1" sont des
  // opinions, pas des valeurs.
  Result := Text1(AEntry, AAttr) = 'TRUE';
end;

function Int1(AEntry: TLdapEntry; const AAttr: string; out AValue: Int64): Boolean;
begin
  Result := TryStrToInt64(Text1(AEntry, AAttr), AValue);
end;

function List(AEntry: TLdapEntry; const AAttr: string): TStringArray;
var
  a: TLdapAttribute;
  i, n: Integer;
begin
  Result := nil;
  a := AEntry.Find(AAttr);
  if a = nil then Exit;
  n := a.ValueCount;
  if n > AD_META_MAX_LIST then n := AD_META_MAX_LIST;
  SetLength(Result, n);
  for i := 0 to n - 1 do
    Result[i] := string(a.Values[i]);
end;

function TAdAttributeMeta.IsBaseSchema: Boolean;
begin
  Result := (SystemFlags and AD_FLAG_SCHEMA_BASE_OBJECT) <> 0;
end;

function TAdClassMeta.IsBaseSchema: Boolean;
begin
  Result := (SystemFlags and AD_FLAG_SCHEMA_BASE_OBJECT) <> 0;
end;

constructor TAdSchemaMeta.Create(const ASchemaDn: string);
begin
  inherited Create;
  FSchemaDn := ASchemaDn;
  FAttrs := TObjectList.Create(True);
  FClasses := TObjectList.Create(True);
  FAttrIndex := TStringList.Create;
  FAttrIndex.Sorted := True;
  FAttrIndex.CaseSensitive := True;
  FAttrIndex.Duplicates := dupIgnore;
  FClassIndex := TStringList.Create;
  FClassIndex.Sorted := True;
  FClassIndex.CaseSensitive := True;
  FClassIndex.Duplicates := dupIgnore;
  FReason := '';
end;

destructor TAdSchemaMeta.Destroy;
begin
  FAttrIndex.Free;
  FClassIndex.Free;
  FAttrs.Free;
  FClasses.Free;
  inherited Destroy;
end;

procedure IndexKey(AIndex: TStringList; const AKey: string; AObj: TObject);
begin
  // Premier arrive, premier servi: AddObject de FPC ecrase l'objet d'une cle deja
  // presente, meme en dupIgnore. On teste avant.
  if (AKey <> '') and (AIndex.IndexOf(AKey) < 0) then
    AIndex.AddObject(AKey, AObj);
end;

function TAdSchemaMeta.Feed(AEntry: TLdapEntry): Boolean;
var
  am: TAdAttributeMeta;
  cm: TAdClassMeta;
  v: Int64;
  oc: RawByteString;
begin
  Result := False;
  if AEntry = nil then Exit;
  if FAttrs.Count + FClasses.Count >= AD_META_MAX_OBJECTS then
  begin
    Inc(FIgnored);
    MarkIncomplete('too many schema objects');
    Exit;
  end;
  if HasClass(AEntry, 'attributeSchema') then
  begin
    if Text1(AEntry, 'lDAPDisplayName') = '' then
    begin
      Inc(FIgnored);
      Exit;
    end;
    am := TAdAttributeMeta.Create;
    am.Name := Text1(AEntry, 'lDAPDisplayName');
    am.Cn := Text1(AEntry, 'cn');
    am.AttributeId := Text1(AEntry, 'attributeID');
    am.AttributeSyntax := Text1(AEntry, 'attributeSyntax');
    if Int1(AEntry, 'oMSyntax', v) and (v >= 0) and (v <= 255) then
      am.OmSyntax := v
    else
      am.OmSyntax := -1;
    oc := AEntry.FirstValue('oMObjectClass', '');
    am.OmObjectClassHex := HexEncode(oc);
    am.SingleValued := Bool1(AEntry, 'isSingleValued');
    am.SystemOnly := Bool1(AEntry, 'systemOnly');
    am.HasRangeLower := Int1(AEntry, 'rangeLower', am.RangeLower);
    am.HasRangeUpper := Int1(AEntry, 'rangeUpper', am.RangeUpper);
    am.SchemaIdGuid := AEntry.FirstValue('schemaIDGUID', '');
    if not Int1(AEntry, 'systemFlags', am.SystemFlags) then am.SystemFlags := 0;
    am.IsDefunct := Bool1(AEntry, 'isDefunct');
    if Int1(AEntry, 'linkID', v) and (v >= Low(Integer)) and (v <= High(Integer)) then
      am.LinkId := v;
    FAttrs.Add(am);
    IndexKey(FAttrIndex, AsciiLowerCase(am.Name), am);
    IndexKey(FAttrIndex, AsciiLowerCase(am.AttributeId), am);
    Result := True;
  end
  else if HasClass(AEntry, 'classSchema') then
  begin
    if Text1(AEntry, 'lDAPDisplayName') = '' then
    begin
      Inc(FIgnored);
      Exit;
    end;
    cm := TAdClassMeta.Create;
    cm.Name := Text1(AEntry, 'lDAPDisplayName');
    cm.Cn := Text1(AEntry, 'cn');
    cm.GovernsId := Text1(AEntry, 'governsID');
    cm.Category := accUnknown;
    if Int1(AEntry, 'objectClassCategory', v) and (v >= 0) and (v <= 3) then
      cm.Category := TAdClassCategory(v);
    cm.SubClassOf := Text1(AEntry, 'subClassOf');
    cm.SystemMust := List(AEntry, 'systemMustContain');
    cm.Must := List(AEntry, 'mustContain');
    cm.SystemMay := List(AEntry, 'systemMayContain');
    cm.May := List(AEntry, 'mayContain');
    cm.SystemAux := List(AEntry, 'systemAuxiliaryClass');
    cm.Aux := List(AEntry, 'auxiliaryClass');
    cm.SystemPossSuperiors := List(AEntry, 'systemPossSuperiors');
    cm.PossSuperiors := List(AEntry, 'possSuperiors');
    cm.DefaultObjectCategory := Text1(AEntry, 'defaultObjectCategory');
    cm.SystemOnly := Bool1(AEntry, 'systemOnly');
    cm.IsDefunct := Bool1(AEntry, 'isDefunct');
    cm.SchemaIdGuid := AEntry.FirstValue('schemaIDGUID', '');
    if not Int1(AEntry, 'systemFlags', cm.SystemFlags) then cm.SystemFlags := 0;
    FClasses.Add(cm);
    IndexKey(FClassIndex, AsciiLowerCase(cm.Name), cm);
    IndexKey(FClassIndex, AsciiLowerCase(cm.GovernsId), cm);
    Result := True;
  end
  else
    Inc(FIgnored);
end;

function TAdSchemaMeta.Attribute(const AName: string): TAdAttributeMeta;
var
  i: Integer;
begin
  i := FAttrIndex.IndexOf(AsciiLowerCase(AttrBaseName(AName)));
  if i < 0 then Result := nil else Result := TAdAttributeMeta(FAttrIndex.Objects[i]);
end;

function TAdSchemaMeta.ObjectClass(const AName: string): TAdClassMeta;
var
  i: Integer;
begin
  i := FClassIndex.IndexOf(AsciiLowerCase(AName));
  if i < 0 then Result := nil else Result := TAdClassMeta(FClassIndex.Objects[i]);
end;

function TAdSchemaMeta.AttributeCount: Integer;
begin
  Result := FAttrs.Count;
end;

function TAdSchemaMeta.ClassCount: Integer;
begin
  Result := FClasses.Count;
end;

function TAdSchemaMeta.AttributeAt(AIndex: Integer): TAdAttributeMeta;
begin
  Result := TAdAttributeMeta(FAttrs[AIndex]);
end;

function TAdSchemaMeta.ClassAt(AIndex: Integer): TAdClassMeta;
begin
  Result := TAdClassMeta(FClasses[AIndex]);
end;

procedure TAdSchemaMeta.MarkComplete;
begin
  if FReason = '' then FComplete := True;
end;

procedure TAdSchemaMeta.MarkIncomplete(const AReason: string);
begin
  FComplete := False;
  if FReason = '' then FReason := AReason;
end;

end.
