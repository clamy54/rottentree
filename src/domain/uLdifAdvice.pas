// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdifAdvice;

{$mode objfpc}{$H+}

// Problemes d'un LDIF expliques en mots simples: pourquoi, comment corriger, un
// exemple juste. "invalid attribute syntax, line 48213" n'a jamais aide personne.

interface

uses
  Classes, SysUtils, uLdif, uLdifTargetCheck;

type
  TLdifProblemSeverity = (lpsError, lpsWarning, lpsNote);
  TLineArray = array of Integer;

  TLdifProblem = record
    Line: Integer;
    Rec: Integer;
    Severity: TLdifProblemSeverity;
    Title: string;
    Explanation: string;
    HowToFix: string;
    Example: string;
    ExampleTitle: string;
    FixLabel: string;
    FixLines: TLineArray;
  end;
  TLdifProblemArray = array of TLdifProblem;

function ExplainParseIssue(const AIssue: TLdifIssue): TLdifProblem;
function ServerManagedProblem(ALines: TStrings; ARecLine, ARec: Integer;
  const AAttrs: array of string): TLdifProblem;
function UnknownAttributesProblem(ARecLine, ARec: Integer; const AAttrs: array of string;
  const ATarget: string): TLdifProblem;
function SchemaIssueProblem(ALines: TStrings; ARecLine, ARec: Integer; const AIssue: TSchemaIssue;
  const ATarget: string): TLdifProblem;
function CriticalControlProblem(ARecLine, ARec: Integer; const AOid: string): TLdifProblem;
function IgnoredControlProblem(ARecLine, ARec: Integer; const AOid: string): TLdifProblem;

function FindAttributeLines(ALines: TStrings; ARecLine: Integer;
  const AAttrs: array of string): TLineArray;
function RemoveLines(const AText: string; const ALines: array of Integer): string;
function SeverityName(ASeverity: TLdifProblemSeverity): string;
// Tri fusion stable: sur des dizaines de milliers d'operations, un tri quadratique
// fige l'interface le temps d'un cafe, et pas un petit.
procedure SortProblemsByLine(var AProblems: TLdifProblemArray);

implementation

uses
  uLdapEntry, uSyntaxInfo;

procedure SortProblemsByLine(var AProblems: TLdifProblemArray);
var
  tmp: TLdifProblemArray;

  procedure Merge(ALo, AMid, AHi: Integer);
  var
    i, j, k: Integer;
  begin
    i := ALo;
    j := AMid;
    k := ALo;
    while (i < AMid) and (j < AHi) do
    begin
      if AProblems[i].Line <= AProblems[j].Line then
      begin
        tmp[k] := AProblems[i];
        Inc(i);
      end
      else
      begin
        tmp[k] := AProblems[j];
        Inc(j);
      end;
      Inc(k);
    end;
    while i < AMid do
    begin
      tmp[k] := AProblems[i];
      Inc(i);
      Inc(k);
    end;
    while j < AHi do
    begin
      tmp[k] := AProblems[j];
      Inc(j);
      Inc(k);
    end;
    for k := ALo to AHi - 1 do AProblems[k] := tmp[k];
  end;

var
  width, lo, mid, hi, n: Integer;
begin
  n := Length(AProblems);
  if n < 2 then Exit;
  SetLength(tmp, n);
  width := 1;
  while width < n do
  begin
    lo := 0;
    while lo < n - width do
    begin
      mid := lo + width;
      hi := lo + 2 * width;
      if hi > n then hi := n;
      Merge(lo, mid, hi);
      Inc(lo, 2 * width);
    end;
    width := width * 2;
  end;
end;

const
  EX_ADD = 'dn: ou=people,dc=example,dc=com'#10'changetype: add'#10'objectClass: organizationalUnit'#10 +
    'ou: people';
  EX_MODIFY = 'dn: uid=jdoe,ou=people,dc=example,dc=com'#10'changetype: modify'#10 +
    'replace: mail'#10'mail: john.doe@example.com'#10'-';
  EX_MODRDN = 'dn: uid=jdoe,ou=people,dc=example,dc=com'#10'changetype: modrdn'#10 +
    'newrdn: uid=john.doe'#10'deleteoldrdn: 1';
  EX_ENTRY = 'dn: uid=jdoe,ou=people,dc=example,dc=com'#10'objectClass: inetOrgPerson'#10 +
    'uid: jdoe'#10'cn: John Doe'#10'sn: Doe';
  EX_BASE64 = 'description:: IFN0YXJ0cyB3aXRoIGEgc3BhY2U=';

function SeverityName(ASeverity: TLdifProblemSeverity): string;
begin
  case ASeverity of
    lpsError: Result := 'error';
    lpsWarning: Result := 'warning';
  else
    Result := 'note';
  end;
end;

function NewProblem(ALine, ARec: Integer; ASeverity: TLdifProblemSeverity;
  const ATitle, AExplanation, AHowToFix, AExample: string): TLdifProblem;
begin
  Result.Line := ALine;
  Result.Rec := ARec;
  Result.Severity := ASeverity;
  Result.Title := ATitle;
  Result.Explanation := AExplanation;
  Result.HowToFix := AHowToFix;
  Result.Example := AExample;
  Result.ExampleTitle := '';
  Result.FixLabel := '';
  Result.FixLines := nil;
end;

function Starts(const AMsg, APrefix: string): Boolean;
begin
  Result := Copy(AMsg, 1, Length(APrefix)) = APrefix;
end;

function ExplainParseIssue(const AIssue: TLdifIssue): TLdifProblem;
var
  m: string;
begin
  m := AIssue.Message;
  if m = 'content and change records cannot be mixed' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Entries and changes mixed in one file',
      'An LDIF file either lists entries to create (records with a "dn:" line and attributes only) ' +
      'or describes changes (every record has a "changetype:" line). This record is not of the same ' +
      'kind as the first record of the file.',
      'Add "changetype: add" under the "dn:" line of each entry to create, so that the whole file ' +
      'describes changes; or put the entries and the changes in two separate files.', EX_ADD)
  else if m = '"name: value" expected' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Line not understood',
      'Each line of a record is "attribute: value" (or "attribute:: value" for a value written in ' +
      'base64). A line that starts with one space continues the previous line, and an empty line ' +
      'ends the record.',
      'Check the colon after the attribute name, or remove the line. If the text continues the ' +
      'previous line, start it with one space.', EX_ENTRY)
  else if m = '"dn:" expected' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Record without a "dn:" line',
      'Every record starts with the name (DN) of the entry it is about. Records are separated by ' +
      'one empty line: an empty line in the middle of an entry cuts it in two.',
      'Add the "dn:" line at the start of the record, or remove the empty line above.', EX_ENTRY)
  else if Starts(m, 'invalid DN') or (m = 'invalid new superior DN') then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Invalid DN',
      'A DN is a list of "attribute=value" pairs separated by commas, from the entry up to the ' +
      'root, for example "uid=jdoe,ou=people,dc=example,dc=com". Inside a value, the characters ' +
      ', + " \ < > ; = must be preceded by a backslash. (' + m + ')',
      'Correct the DN, escaping the special characters (for example "cn=Doe\, John,ou=people,...").', '')
  else if m = 'invalid attribute description' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Invalid attribute name',
      'An attribute name starts with a letter and contains only letters, digits and hyphens (or is a ' +
      'numeric OID such as 2.5.4.3). Options follow a semicolon, for example "userCertificate;binary".',
      'Correct the name before the colon.', '')
  else if (m = 'value must be base64-encoded') or (m = 'non-ASCII value must be base64-encoded') or
          (m = 'value is not valid UTF-8; use base64') then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Value to write in base64',
      'Some values cannot be written as plain text in LDIF: those that start with a space, a colon ' +
      'or "<", and those with special or non-text characters. (' + m + ')',
      'Write the value in base64 after two colons ("attribute:: ..."). Values exported by ' +
      'Rottentree are already written this way.', EX_BASE64)
  else if m = 'invalid base64 value' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Invalid base64 value',
      'After two colons ("attribute:: ..."), the value must be base64 (letters, digits, + / and = ' +
      'padding). This one cannot be decoded.',
      'Encode the value again, or write it as plain text after a single colon if it is ordinary text.',
      EX_BASE64)
  else if (m = 'value too large') or (m = 'referenced file too large') or (m = 'line too long') then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Value too large',
      'This value exceeds the size Rottentree accepts for one value (' + m + ').',
      'Check that the line is really meant to hold this value; a very large value usually comes ' +
      'from a missing line break.', '')
  else if m = 'add record without attributes' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Entry without attributes',
      'An entry to create needs at least its object classes and the attribute used in its name.',
      'Add the objectClass lines and the naming attribute (the one in the first part of the DN).',
      EX_ADD)
  else if m = 'unexpected line in delete record' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Extra line in a deletion',
      'A "changetype: delete" record contains only the "dn:" and "changetype:" lines: it removes ' +
      'the whole entry.',
      'Remove the other lines. To remove only some values, use "changetype: modify" with "delete:".',
      EX_MODIFY)
  else if (m = '"newrdn:" expected') or (m = '"deleteoldrdn:" expected') or (m = 'invalid new RDN') or
          (m = 'deleteoldrdn must be 0 or 1') or (m = 'unexpected line in moddn record') then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Incomplete rename',
      'A rename ("changetype: modrdn" or "moddn") gives the new name ("newrdn:"), then ' +
      '"deleteoldrdn: 1" to drop the old name value or 0 to keep it, and optionally "newsuperior:" ' +
      'to move the entry. (' + m + ')',
      'Complete the record as in the example.', EX_MODRDN)
  else if m = '"add:", "delete:", "replace:" or "increment:" expected' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Modification not understood',
      'In a "changetype: modify" record, each modification starts with "add:", "delete:", ' +
      '"replace:" or "increment:" followed by the attribute name, then its values, and ends with a ' +
      'line containing only "-".',
      'Start the modification with one of these words, and end the previous one with "-".', EX_MODIFY)
  else if m = 'attribute does not match the modification' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Wrong attribute in a modification',
      'After "replace: mail", the value lines must be "mail: ...". A line for another attribute ' +
      'means the previous modification was not closed.',
      'Add a line containing only "-" before the next modification.', EX_MODIFY)
  else if m = 'increment needs exactly one value' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Increment without a single value',
      '"increment:" adds a number to an integer attribute: it takes exactly one value, the amount.',
      'Give one value, for example "uidNumber: 1".', '')
  else if m = 'add needs at least one value' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Addition without a value',
      '"add:" adds values to an attribute: at least one value line must follow it.',
      'Add the value lines, or use "delete:" to remove the attribute.', EX_MODIFY)
  else if m = 'unknown changetype' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Unknown changetype',
      'The possible values are add, delete, modify, modrdn and moddn.',
      'Correct the "changetype:" line.', EX_MODIFY)
  else if (m = 'controls require a changetype') or (m = 'control OID expected') or
          (m = 'invalid control value') then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Invalid control line',
      'A "control:" line asks the server for a special behaviour. It is written after "dn:", before ' +
      '"changetype:", as "control: <OID> [true|false] [: value]". (' + m + ')',
      'Correct the line, or remove it if the control is not needed.', '')
  else if m = 'unsupported LDIF version' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Unsupported LDIF version',
      'Only "version: 1" exists.', 'Write "version: 1" or remove the line.', '')
  else if m = 'continuation line without a preceding line' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Line starting with a space',
      'A line that starts with a space continues the previous line. Here there is nothing to ' +
      'continue (it follows an empty line or starts the file).',
      'Remove the space at the start of the line.', '')
  else if m = 'record limit reached; remainder ignored' then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Too many records',
      'The file holds more records than Rottentree reads at once; the rest is ignored.',
      'Split the file into several smaller files.', '')
  else if Pos('referenced files exceed the total limit', m) > 0 then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Too much data read from files',
      'Together, the values read from local files exceed what Rottentree reads for one LDIF (' + m +
      '). Each reference reads its file again, even the same file.',
      'Split the LDIF into several smaller files, or reference fewer or smaller files.', '')
  else if (Pos('":<"', m) > 0) or (Pos('file reference', m) > 0) or (Pos('referenced file', m) > 0) or
          (Pos('reference', m) > 0) or (Pos('symbolic links', m) > 0) then
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Value read from a file',
      'A value written "attribute:< file:///path" is read from a local file. This is off by default: ' +
      'only files under a folder you allow are read. (' + m + ')',
      'Tick "Allow local file references" and choose the folder that holds the files, or write the ' +
      'value in the file itself.', '')
  else
    Result := NewProblem(AIssue.Line, -1, lpsError, 'Line not understood',
      'The line does not follow the LDIF format (' + m + ').', 'Correct or remove the line.', EX_ENTRY);
end;

function ServerManagedProblem(ALines: TStrings; ARecLine, ARec: Integer;
  const AAttrs: array of string): TLdifProblem;
var
  names: string;
  i: Integer;
begin
  names := '';
  for i := 0 to High(AAttrs) do
  begin
    if i > 0 then names := names + ', ';
    names := names + AAttrs[i];
  end;
  Result := NewProblem(ARecLine, ARec, lpsWarning, 'Attributes written by the server: ' + names,
    'These attributes are kept up to date by the directory server itself: creation and change ' +
    'dates, author of the change, unique identifier, replication stamps... They appear in exports, ' +
    'but a server refuses them when an entry is created or changed.',
    'Remove these lines from the file. The server sets these attributes again by itself.', '');
  Result.FixLines := FindAttributeLines(ALines, ARecLine, AAttrs);
  if Length(Result.FixLines) > 0 then Result.Line := Result.FixLines[0];
  if Length(Result.FixLines) = 1 then
    Result.FixLabel := 'Remove this line'
  else if Length(Result.FixLines) > 1 then
    Result.FixLabel := Format('Remove these %d lines', [Length(Result.FixLines)]);
end;

function UnknownAttributesProblem(ARecLine, ARec: Integer; const AAttrs: array of string;
  const ATarget: string): TLdifProblem;
var
  names: string;
  i: Integer;
begin
  names := '';
  for i := 0 to High(AAttrs) do
  begin
    if i > 0 then names := names + ', ';
    names := names + AAttrs[i];
  end;
  Result := NewProblem(ARecLine, ARec, lpsWarning, 'Attributes unknown to ' + ATarget + ': ' + names,
    'The schema of ' + ATarget + ' does not define these attributes, so the server will refuse the ' +
    'record. Either the name is misspelled, or it belongs to a schema that this server does not ' +
    'have (another directory product, a custom extension).',
    'Check the spelling. If the attributes come from another server, remove them or ask the ' +
    'administrator of ' + ATarget + ' to add the schema that defines them.', '');
end;

function Joined(const ANames: array of string): string;
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

function ShortValue(const S: string): string;
begin
  Result := StringReplace(StringReplace(S, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]);
  if Length(Result) > 60 then Result := Copy(Result, 1, 57) + '...';
end;

function ExampleValue(const ASyntax: string): string;
var
  low: string;
begin
  low := LowerCase(ASyntax);
  if Pos('integer', low) > 0 then Result := '10001'
  else if Pos('boolean', low) > 0 then Result := 'TRUE (or FALSE)'
  else if (Pos('time', low) > 0) or (Pos('date', low) > 0) then Result := '20260930120000Z'
  else if (Pos('dn', low) > 0) or (Pos('distinguished', low) > 0) then
    Result := 'uid=jdoe,ou=people,dc=example,dc=com'
  else if Pos('numeric', low) > 0 then Result := '42'
  else Result := '';
end;

function SchemaIssueProblem(ALines: TStrings; ARecLine, ARec: Integer; const AIssue: TSchemaIssue;
  const ATarget: string): TLdifProblem;
var
  sev: TLdifProblemSeverity;
  lines: TLineArray;
  where, ex, synName, synExpl: string;
begin
  if AIssue.Certain then sev := lpsError else sev := lpsWarning;
  where := AIssue.Attr;
  if AIssue.Kind in [sikUnknownClass, sikNoStructural, sikClassProblem] then where := 'objectClass';
  lines := nil;
  if (where <> '') and not (AIssue.Kind in [sikMissingRequired]) then
    lines := FindAttributeLines(ALines, ARecLine, [where]);
  case AIssue.Kind of
    sikUnknownClass:
      Result := NewProblem(ARecLine, ARec, sev, 'Unknown object class: ' + AIssue.Attr,
        'The schema of ' + ATarget + ' does not define the object class "' + AIssue.Attr + '". ' +
        'Either the name is misspelled, or the class comes from a schema that this server does not have.',
        'Check the spelling of the objectClass line, or replace the class by one that ' + ATarget +
        ' knows. The schema browser (Tools > Schema) lists them.', '');
    sikNoStructural:
      Result := NewProblem(ARecLine, ARec, sev, 'No structural object class',
        'Every entry has one structural object class that says what it is: person, inetOrgPerson, ' +
        'organizationalUnit, groupOfNames, device... Auxiliary classes only add attributes. The classes ' +
        'of this entry (' + Joined(AIssue.Classes) + ') include no structural class known to ' + ATarget + '.',
        'Add an "objectClass:" line with a structural class.', EX_ENTRY);
    sikClassProblem:
      Result := NewProblem(ARecLine, ARec, sev, 'Inconsistent object classes',
        'The object classes of this entry (' + Joined(AIssue.Classes) + ') cannot be combined: ' +
        AIssue.Detail,
        'Keep one chain of structural classes (for example top, person, organizationalPerson, ' +
        'inetOrgPerson) and add auxiliary classes next to it.', EX_ENTRY);
    sikMissingRequired:
      begin
        Result := NewProblem(ARecLine, ARec, sev, 'Required attribute missing: ' + AIssue.Attr,
          'The object class ' + AIssue.Detail + ' requires the attribute "' + AIssue.Attr + '": the ' +
          'server refuses an entry without it.',
          'Add a line "' + AIssue.Attr + ': ..." with its value, or remove the object class ' +
          AIssue.Detail + ' if the entry should not be of that kind.', '');
      end;
    sikNotAllowed:
      begin
        if Length(AIssue.Suggest) > 0 then
        begin
          ex := 'objectClass: ' + AIssue.Suggest[0];
          if Length(AIssue.SuggestMust) > 0 then
            ex := ex + #10 + '# ' + AIssue.Suggest[0] + ' also requires: ' + Joined(AIssue.SuggestMust);
          Result := NewProblem(ARecLine, ARec, sev, 'Object class missing for ' + AIssue.Attr +
            ' (add ' + AIssue.Suggest[0] + ')',
            'Each attribute of an entry must be allowed by one of its object classes. The classes of ' +
            'this entry (' + Joined(AIssue.Classes) + ') do not allow "' + AIssue.Attr + '". It is ' +
            'provided by: ' + Joined(AIssue.Suggest) + '.',
            'Add the object class that provides it ("objectClass: ' + AIssue.Suggest[0] + '") with ' +
            'the attributes that class requires, or remove the "' + AIssue.Attr + '" line.', ex);
          Result.ExampleTitle := 'Lines to add to the entry';
        end
        else
          Result := NewProblem(ARecLine, ARec, sev, 'Attribute not allowed: ' + AIssue.Attr,
            'Each attribute of an entry must be allowed by one of its object classes. The classes of ' +
            'this entry (' + Joined(AIssue.Classes) + ') do not allow "' + AIssue.Attr + '", and no ' +
            'class of ' + ATarget + ' provides it.',
            'Remove the "' + AIssue.Attr + '" line.', '');
      end;
    sikBadValue:
      begin
        ex := SyntaxExample(AIssue.SyntaxOid);
        if (ex = '') or (ex[1] = '(') then ex := ExampleValue(AIssue.SyntaxName);
        if ex <> '' then ex := AIssue.Attr + ': ' + ex;
        if not SyntaxDescription(AIssue.SyntaxOid, synName, synExpl) then synExpl := '';
        if synExpl <> '' then synExpl := ' (' + synExpl + ')';
        if AIssue.Certain then
          Result := NewProblem(ARecLine, ARec, sev, 'Invalid value for ' + AIssue.Attr + ': "' +
            ShortValue(AIssue.Value) + '"',
            'In the schema of ' + ATarget + ', "' + AIssue.Attr + '" holds values of type ' +
            AIssue.SyntaxName + synExpl + '. The value "' + ShortValue(AIssue.Value) + '" does not ' +
            'follow it: ' + AIssue.Detail + '. The server refuses the record (invalid attribute syntax).',
            'Write a value of the expected type.', ex)
        else
          // Simple doute: le {n} du schema est une capacite minimale recommandee,
          // pas une limite. La plupart des serveurs l'ignorent avec superbe.
          Result := NewProblem(ARecLine, ARec, sev, 'Long value for ' + AIssue.Attr + ': "' +
            ShortValue(AIssue.Value) + '"',
            'In the schema of ' + ATarget + ', "' + AIssue.Attr + '" holds values of type ' +
            AIssue.SyntaxName + synExpl + ': ' + AIssue.Detail + '.',
            'Nothing to change if the server accepts it; shorten the value if the import is refused ' +
            'for this line.', '');
        lines := FindAttributeLines(ALines, ARecLine, [AIssue.Attr]);
      end;
    sikSingleValue:
      Result := NewProblem(ARecLine, ARec, sev, 'Too many values for ' + AIssue.Attr,
        'The attribute "' + AIssue.Attr + '" is single-valued: an entry holds at most one value of it, ' +
        'and this record gives ' + IntToStr(AIssue.Count) + '.',
        'Keep only one "' + AIssue.Attr + ':" line.', '');
  else
    Result := NewProblem(ARecLine, ARec, sev, 'Naming value missing: ' + AIssue.Attr + '=' + AIssue.Value,
      'The first part of the DN ("' + AIssue.Attr + '=' + AIssue.Value + '") names the entry: this ' +
      'value must also be one of the values of "' + AIssue.Attr + '" in the entry. Here "' + AIssue.Attr +
      '" holds: ' + AIssue.Detail + '.',
      'Correct the value of "' + AIssue.Attr + '" or the DN so that they match, or add a line "' +
      AIssue.Attr + ': ' + AIssue.Value + '".', '');
  end;
  if Length(lines) > 0 then Result.Line := lines[0];
end;

function CriticalControlProblem(ARecLine, ARec: Integer; const AOid: string): TLdifProblem;
begin
  Result := NewProblem(ARecLine, ARec, lpsError, 'Critical control ' + AOid + ' not supported',
    'This record asks for control ' + AOid + ' and marks it critical: the operation must not run ' +
    'without it. Rottentree does not send controls from LDIF files, so the import is blocked.',
    'Remove the "control:" line if the operation can run without it, or run this change with a ' +
    'tool that supports the control.', '');
end;

function IgnoredControlProblem(ARecLine, ARec: Integer; const AOid: string): TLdifProblem;
begin
  Result := NewProblem(ARecLine, ARec, lpsNote, 'Control ' + AOid + ' will not be sent',
    'This record asks for control ' + AOid + ', not marked critical. Rottentree does not send ' +
    'controls from LDIF files: the operation runs without it.',
    'Nothing to do if the operation is fine without the control.', '');
end;

function LineAttr(const S: string): string;
var
  p: Integer;
begin
  Result := '';
  if (S = '') or (S[1] in [' ', '#', '-']) then Exit;
  p := Pos(':', S);
  if p <= 1 then Exit;
  Result := AttrBaseName(Trim(Copy(S, 1, p - 1)));
end;

function FindAttributeLines(ALines: TStrings; ARecLine: Integer;
  const AAttrs: array of string): TLineArray;
var
  i, j: Integer;
  name: string;
  hit, inHit: Boolean;
begin
  Result := nil;
  if (ALines = nil) or (ARecLine < 1) then Exit;
  inHit := False;
  i := ARecLine - 1;
  while i < ALines.Count do
  begin
    if Trim(ALines[i]) = '' then Break;
    if (ALines[i] <> '') and (ALines[i][1] = ' ') then
    begin
      // Une continuation suit le sort de sa ligne: retirer l'une sans l'autre colle la
      // moitie d'une valeur base64 sur l'attribut suivant.
      if inHit then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := i + 1;
      end;
      Inc(i);
      Continue;
    end;
    name := LineAttr(ALines[i]);
    hit := False;
    if name <> '' then
      for j := 0 to High(AAttrs) do
        if SameText(name, AttrBaseName(AAttrs[j])) then
        begin
          hit := True;
          Break;
        end;
    inHit := hit;
    if hit then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := i + 1;
    end;
    Inc(i);
  end;
end;

function RemoveLines(const AText: string; const ALines: array of Integer): string;
var
  sl: TStringList;
  i, j: Integer;
  drop: Boolean;
  crlf: Boolean;
begin
  crlf := Pos(#13#10, AText) > 0;
  sl := TStringList.Create;
  try
    sl.Text := AText;
    Result := '';
    for i := 0 to sl.Count - 1 do
    begin
      drop := False;
      for j := 0 to High(ALines) do
        if ALines[j] = i + 1 then
        begin
          drop := True;
          Break;
        end;
      if drop then Continue;
      Result := Result + sl[i];
      if crlf then Result := Result + #13#10 else Result := Result + #10;
    end;
  finally
    sl.Free;
  end;
end;

end.
