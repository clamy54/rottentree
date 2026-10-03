// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSchemaFiles;

{$mode objfpc}{$H+}

// Schema lu dans des fichiers, pour un LDIF ouvert comme un annuaire: sous-schema exporte d'un
// serveur, fichiers cn=config d'OpenLDAP ou vieux .schema facon slapd.conf. Les macros
// objectidentifier ne sont pas developpees: ce qui en depend est ecarte et compte.

interface

uses
  SysUtils, Classes, uLdapSchema;

const
  SCHEMA_FILE_MAX_BYTES = 16 * 1024 * 1024;

resourcestring
  rsSchemaFilesReport = '%d attribute types and %d object classes read from %d file(s)';
  rsSchemaFilesRejected = '%d definitions could not be read';
  rsSchemaFilesTooLarge = '%s is too large for a schema file';
  rsSchemaFilesNone = 'no schema definition found in %s';

function SchemaFromFiles(const APaths: array of string; out AReport: string): TSchemaSnapshot;
procedure CollectSchemaDefinitions(const AText: RawByteString; ADefs: array of TStrings);

implementation

uses
  uLdif, uChangeSet, uLdapEntry;

const
  DEF_SYNTAX = 0;
  DEF_RULE = 1;
  DEF_ATTR = 2;
  DEF_CLASS = 3;
  DEF_CONTENT = 4;

function DefIndex(const AAttr: string): Integer;
var
  a: string;
begin
  a := LowerCase(AttrBaseName(AAttr));
  if (a = 'attributetypes') or (a = 'olcattributetypes') then Result := DEF_ATTR
  else if (a = 'objectclasses') or (a = 'olcobjectclasses') then Result := DEF_CLASS
  else if (a = 'ldapsyntaxes') or (a = 'olcldapsyntaxes') then Result := DEF_SYNTAX
  else if a = 'matchingrules' then Result := DEF_RULE
  else if (a = 'ditcontentrules') or (a = 'olcditcontentrules') then Result := DEF_CONTENT
  else Result := -1;
end;

// cn=config prefixe chaque valeur d'un ordre: "{12}( 2.5.4.3 ...".
function StripOrder(const S: string): string;
var
  p: Integer;
begin
  Result := Trim(S);
  if (Result <> '') and (Result[1] = '{') then
  begin
    p := Pos('}', Result);
    if p > 0 then Result := Trim(Copy(Result, p + 1, MaxInt));
  end;
end;

procedure CollectSlapdSchema(const AText: string; ADefs: array of TStrings);
var
  lines: TStringList;
  i: Integer;
  stmt, line, word, rest: string;

  procedure Flush;
  var
    p, idx: Integer;
  begin
    stmt := Trim(stmt);
    if stmt = '' then Exit;
    p := 1;
    while (p <= Length(stmt)) and not (stmt[p] in [' ', #9, '(']) do Inc(p);
    word := LowerCase(Copy(stmt, 1, p - 1));
    rest := Trim(Copy(stmt, p, MaxInt));
    idx := -1;
    if word = 'attributetype' then idx := DEF_ATTR
    else if word = 'objectclass' then idx := DEF_CLASS
    else if word = 'ldapsyntax' then idx := DEF_SYNTAX
    else if word = 'ditcontentrule' then idx := DEF_CONTENT;
    if (idx >= 0) and (rest <> '') then ADefs[idx].Add(rest);
    stmt := '';
  end;

begin
  lines := TStringList.Create;
  try
    lines.Text := AText;
    stmt := '';
    for i := 0 to lines.Count - 1 do
    begin
      line := lines[i];
      if (line = '') or (Trim(line) = '') then
      begin
        Flush;
        Continue;
      end;
      if line[1] = '#' then Continue;
      if line[1] in [' ', #9] then
        stmt := stmt + ' ' + Trim(line)
      else
      begin
        Flush;
        stmt := line;
      end;
    end;
    Flush;
  finally
    lines.Free;
  end;
end;

procedure CollectSchemaDefinitions(const AText: RawByteString; ADefs: array of TStrings);
var
  doc: TLdifDocument;
  i, j, k, idx, before: Integer;
  rec: TLdapChange;
  a: TLdapAttribute;
begin
  before := 0;
  for k := 0 to High(ADefs) do Inc(before, ADefs[k].Count);
  doc := LdifParse(AText, DefaultLdifParseOptions);
  try
    for i := 0 to doc.RecordCount - 1 do
    begin
      rec := doc[i];
      if (rec.Kind = ckAdd) and (rec.Entry <> nil) then
        for j := 0 to rec.Entry.AttrCount - 1 do
        begin
          a := rec.Entry.Attrs[j];
          idx := DefIndex(a.Description);
          if idx >= 0 then
            for k := 0 to a.ValueCount - 1 do
              ADefs[idx].Add(StripOrder(a.Values[k]));
        end
      else if rec.Kind = ckModify then
        for j := 0 to High(rec.Mods) do
          if rec.Mods[j].Op in [moAdd, moReplace] then
          begin
            idx := DefIndex(rec.Mods[j].Attr);
            if idx >= 0 then
              for k := 0 to High(rec.Mods[j].Values) do
                ADefs[idx].Add(StripOrder(rec.Mods[j].Values[k]));
          end;
    end;
  finally
    doc.Free;
  end;
  k := 0;
  for i := 0 to High(ADefs) do Inc(k, ADefs[i].Count);
  if k = before then
    CollectSlapdSchema(AText, ADefs);
end;

function ReadFileText(const APath: string): RawByteString;
var
  fs: TFileStream;
begin
  Result := '';
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    if fs.Size > SCHEMA_FILE_MAX_BYTES then
      raise EStreamError.CreateFmt(rsSchemaFilesTooLarge, [ExtractFileName(APath)]);
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[1], fs.Size);
  finally
    fs.Free;
  end;
end;

function SchemaFromFiles(const APaths: array of string; out AReport: string): TSchemaSnapshot;
const
  KINDS: array[0..4] of TSchemaDefKind = (sdkSyntax, sdkMatchingRule, sdkAttributeType,
    sdkObjectClass, sdkDitContentRule);
var
  defs: array[0..4] of TStrings;
  i, k, files, total: Integer;
  text: RawByteString;
begin
  Result := nil;
  AReport := '';
  for k := 0 to High(defs) do defs[k] := TStringList.Create;
  try
    files := 0;
    for i := 0 to High(APaths) do
    begin
      try
        text := ReadFileText(APaths[i]);
      except
        on E: Exception do
        begin
          if AReport <> '' then AReport := AReport + '; ';
          AReport := AReport + ExtractFileName(APaths[i]) + ': ' + E.Message;
          Continue;
        end;
      end;
      total := 0;
      for k := 0 to High(defs) do Inc(total, defs[k].Count);
      CollectSchemaDefinitions(text, defs);
      for k := 0 to High(defs) do Dec(total, defs[k].Count);
      if total = 0 then
      begin
        if AReport <> '' then AReport := AReport + '; ';
        AReport := AReport + Format(rsSchemaFilesNone, [ExtractFileName(APaths[i])]);
      end
      else
        Inc(files);
    end;
    if files = 0 then Exit;
    Result := TSchemaSnapshot.Create;
    // Syntaxes et regles d'abord, puis types, classes et regles de contenu: chacun s'appuie sur les
    // precedents.
    for k := 0 to High(defs) do
      for i := 0 to defs[k].Count - 1 do
        Result.AddDefinition(KINDS[k], defs[k][i]);
    Result.FetchedUtc := Now;
    Result.SourceKey := 'schema-files';
    if AReport <> '' then AReport := '; ' + AReport;
    AReport := Format(rsSchemaFilesReport, [Result.AttributeTypeCount, Result.ObjectClassCount,
      files]) + AReport;
    if Result.Errors.Count > 0 then
      AReport := AReport + '; ' + Format(rsSchemaFilesRejected, [Result.Errors.Count]);
  finally
    for k := 0 to High(defs) do defs[k].Free;
  end;
end;

end.
