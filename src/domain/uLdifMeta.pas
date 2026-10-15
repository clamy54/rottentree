// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdifMeta;

{$mode objfpc}{$H+}

// Fichier compagnon d'un LDIF fabrique ici: le schema, le type d'annuaire et les conteneurs qui
// existent dans la cible sans etre dans le fichier. Le LDIF reste pur: ldapadd, ldifde et
// l'import de Rottentree le prennent tel quel, sans y trouver un cn=Subschema a creer.

interface

uses
  SysUtils, Classes, uLdapEntry, uLdapSchema;

const
  LDIF_META_SUFFIX = '.rtschema';
  LDIF_META_MAX_BYTES = 64 * 1024 * 1024;
  LDIF_META_DN = 'cn=Subschema';
  LDIF_META_KIND = 'x-rottentree-kind';
  LDIF_META_BASE = 'x-rottentree-base';

type
  TLdifMeta = record
    ActiveDirectory: Boolean;
    // conteneurs de la cible, absents du fichier
    Bases: TStringArray;
  end;

function LdifMetaPath(const ALdifPath: string): string;
// Le schema est recopie tel que le serveur l'a ecrit (Raw), pas reconstruit.
function BuildLdifMeta(ASchema: TSchemaSnapshot; const AMeta: TLdifMeta): TLdapEntry;
function LdifMetaText(AEntry: TLdapEntry): RawByteString;
// AEntry: le sous-schema seul, sans les attributs propres a Rottentree.
function ParseLdifMeta(const ARaw: RawByteString; out AEntry: TLdapEntry; out AMeta: TLdifMeta;
  out AError: string): Boolean;
// Entree du conteneur quand le fichier le cree lui-meme. nil et AError sinon.
function NewContainerEntry(const ADn: string; AActiveDirectory: Boolean; ASchema: TSchemaSnapshot;
  out AError: string): TLdapEntry;
// Partie DC= d'un DN: le domaine annonce par le root DSE d'un LDIF Active Directory.
function DomainPartOf(const ADn: string): string;

resourcestring
  rsLmNotLdif = 'the schema file is not readable LDIF: %s';
  rsLmNoSchema = 'the schema file holds no schema';
  rsLmBadDn = 'not a DN: %s';
  rsLmAdKind = 'Active Directory: an LDIF file creates OUs (ou=) and containers (cn=), not domains';
  rsLmLdapKind = 'only ou=, o=, dc= and l= containers are created here; for another kind, keep it ' +
    'as an existing container and create its entry from the tree';
  rsLmNoClass = 'the schema has no %s class';

implementation

uses
  uLdif, uLdapDn;

const
  SCHEMA_ATTRS: array[TSchemaDefKind] of string = ('attributeTypes', 'objectClasses',
    'matchingRules', 'ldapSyntaxes', 'dITContentRules');

function LdifMetaPath(const ALdifPath: string): string;
begin
  Result := ALdifPath + LDIF_META_SUFFIX;
end;

function BuildLdifMeta(ASchema: TSchemaSnapshot; const AMeta: TLdifMeta): TLdapEntry;
var
  k: TSchemaDefKind;
  i: Integer;
  a: TLdapAttribute;
begin
  Result := TLdapEntry.Create(LDIF_META_DN);
  Result.Ensure('objectClass').AddValue('top');
  Result.Ensure('objectClass').AddValue('subentry');
  Result.Ensure('objectClass').AddValue('subschema');
  Result.Ensure('cn').AddValue('Subschema');
  if AMeta.ActiveDirectory then Result.Ensure(LDIF_META_KIND).AddValue('ad')
  else Result.Ensure(LDIF_META_KIND).AddValue('ldap');
  for i := 0 to High(AMeta.Bases) do
    Result.Ensure(LDIF_META_BASE).AddValue(AMeta.Bases[i]);
  if ASchema = nil then Exit;
  for k := Low(TSchemaDefKind) to High(TSchemaDefKind) do
  begin
    if ASchema.ElementCount(k) = 0 then Continue;
    a := Result.Ensure(SCHEMA_ATTRS[k]);
    for i := 0 to ASchema.ElementCount(k) - 1 do
      if ASchema.ElementAt(k, i).Raw <> '' then a.AddValue(ASchema.ElementAt(k, i).Raw);
  end;
end;

function LdifMetaText(AEntry: TLdapEntry): RawByteString;
var
  ms: TStringStream;
  w: TLdifWriter;
begin
  ms := TStringStream.Create('');
  try
    w := TLdifWriter.Create(ms);
    try
      w.WriteVersion;
      w.WriteComment('Rottentree: schema and target of the LDIF file next to this one. Not to be imported.');
      w.WriteEntry(AEntry);
    finally
      w.Free;
    end;
    Result := ms.DataString;
  finally
    ms.Free;
  end;
end;

function ParseLdifMeta(const ARaw: RawByteString; out AEntry: TLdapEntry; out AMeta: TLdifMeta;
  out AError: string): Boolean;
var
  doc: TLdifDocument;
  i: Integer;
  e: TLdapEntry;
  a: TLdapAttribute;
  d: TLdapDn;
  err: string;
begin
  Result := False;
  AEntry := nil;
  AMeta := Default(TLdifMeta);
  AError := '';
  if Length(ARaw) > LDIF_META_MAX_BYTES then
  begin
    AError := Format(rsLmNotLdif, ['too large']);
    Exit;
  end;
  doc := LdifParse(ARaw, DefaultLdifParseOptions);
  try
    e := nil;
    for i := 0 to doc.RecordCount - 1 do
      if (doc[i].Entry <> nil) and (doc[i].Entry.Find('attributeTypes') <> nil) then
      begin
        e := doc[i].Entry;
        Break;
      end;
    if e = nil then
    begin
      if doc.IssueCount > 0 then AError := Format(rsLmNotLdif, [doc.Issue(0).Message])
      else AError := rsLmNoSchema;
      Exit;
    end;
    a := e.Find(LDIF_META_KIND);
    AMeta.ActiveDirectory := (a <> nil) and (a.ValueCount > 0) and SameText(Trim(a.Values[0]), 'ad');
    a := e.Find(LDIF_META_BASE);
    if a <> nil then
      for i := 0 to a.ValueCount - 1 do
        // une base qui ne se lit pas comme un DN est ignoree, pas inventee
        if DnParse(Trim(a.Values[i]), d, err) and (DnRdnCount(d) > 0) then
        begin
          SetLength(AMeta.Bases, Length(AMeta.Bases) + 1);
          AMeta.Bases[High(AMeta.Bases)] := Trim(a.Values[i]);
        end;
    AEntry := e.Clone;
    AEntry.Dn := e.Dn;
    AEntry.Remove(LDIF_META_KIND);
    AEntry.Remove(LDIF_META_BASE);
    Result := True;
  finally
    doc.Free;
  end;
end;

function NewContainerEntry(const ADn: string; AActiveDirectory: Boolean; ASchema: TSchemaSnapshot;
  out AError: string): TLdapEntry;
var
  d: TLdapDn;
  err, attr, cls: string;
  leaf: TDnRdn;
begin
  Result := nil;
  AError := '';
  if not DnParse(Trim(ADn), d, err) or (DnRdnCount(d) = 0) then
  begin
    AError := Format(rsLmBadDn, [ADn]);
    Exit;
  end;
  leaf := DnLeaf(d);
  if Length(leaf.Avas) <> 1 then
  begin
    AError := Format(rsLmBadDn, [ADn]);
    Exit;
  end;
  attr := LowerCase(leaf.Avas[0].AttrType);
  cls := '';
  if AActiveDirectory then
  begin
    if attr = 'ou' then cls := 'organizationalUnit'
    else if attr = 'cn' then cls := 'container'
    else AError := rsLmAdKind;
  end
  else
  begin
    if attr = 'ou' then cls := 'organizationalUnit'
    else if attr = 'o' then cls := 'organization'
    else if attr = 'dc' then cls := 'domain'
    else if attr = 'l' then cls := 'locality'
    else AError := rsLmLdapKind;
  end;
  if AError <> '' then Exit;
  if (ASchema <> nil) and (ASchema.ObjectClass(cls) = nil) then
  begin
    AError := Format(rsLmNoClass, [cls]);
    Exit;
  end;
  Result := TLdapEntry.Create(Trim(ADn));
  Result.Ensure('objectClass').AddValue('top');
  Result.Ensure('objectClass').AddValue(cls);
  Result.Ensure(leaf.Avas[0].AttrType).AddValue(leaf.Avas[0].Value);
end;

function DomainPartOf(const ADn: string): string;
var
  d, part: TLdapDn;
  err: string;
  i, first: Integer;
begin
  Result := '';
  if not DnParse(ADn, d, err) then Exit;
  first := -1;
  for i := 0 to DnRdnCount(d) - 1 do
    if (Length(d.Rdns[i].Avas) = 1) and SameText(d.Rdns[i].Avas[0].AttrType, 'dc') then
    begin
      if first < 0 then first := i;
    end
    else
      first := -1;
  if first < 0 then Exit;
  part := d;
  for i := 1 to first do part := DnParent(part);
  Result := DnToString(part);
end;

end.
