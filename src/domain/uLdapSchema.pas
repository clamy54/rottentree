// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdapSchema;

{$mode objfpc}{$H+}

// Schema LDAP (RFC 4512) lu depuis le sous-schema du serveur. Une entree hostile comme
// une autre: taille, nombre de definitions et profondeur d'heritage bornes, cycles SUP
// detectes, une definition illisible est ecartee sans entrainer les autres dans sa chute.

interface

uses
  SysUtils, Classes, Contnrs, uAdSchemaMeta;

const
  SCHEMA_MAX_DEFINITIONS = 50000;
  SCHEMA_MAX_DEF_CHARS = 64 * 1024;
  SCHEMA_MAX_NAMES = 64;
  // MUST/MAY: olcGlobal (cn=config d'OpenLDAP) depasse la centaine d'elements, la borne
  // doit le laisser passer.
  SCHEMA_MAX_LIST = 1024;
  SCHEMA_MAX_SUP_DEPTH = 64;
  SCHEMA_MAX_ERRORS = 200;

type
  TAttrUsage = (auUserApplications, auDirectoryOperation, auDistributedOperation,
    auDsaOperation);
  TObjectClassKind = (ockStructural, ockAbstract, ockAuxiliary);

  TSchemaExtension = record
    Name: string;
    Values: array of string;
  end;

  TSchemaElement = class
  public
    Oid: string;
    Names: array of string;
    Desc: string;
    Obsolete: Boolean;
    Extensions: array of TSchemaExtension;
    Raw: string;
    function PrimaryName: string;
    function HasName(const AName: string): Boolean;
    function ExtensionValue(const AName: string): string;
  end;

  TSchemaAttributeType = class(TSchemaElement)
  public
    Sup: string;
    Equality: string;
    Ordering: string;
    Substr: string;
    Syntax: string;
    SyntaxLen: Integer;
    SingleValue: Boolean;
    Collective: Boolean;
    NoUserModification: Boolean;
    Usage: TAttrUsage;
  end;

  TSchemaObjectClass = class(TSchemaElement)
  public
    Sups: array of string;
    Kind: TObjectClassKind;
    Must: array of string;
    May: array of string;
  end;

  TSchemaMatchingRule = class(TSchemaElement)
  public
    Syntax: string;
  end;

  TSchemaSyntax = class(TSchemaElement);

  TSchemaDitContentRule = class(TSchemaElement)
  public
    Aux: array of string;
    Must: array of string;
    May: array of string;
    Precluded: array of string;
  end;

  TSchemaDefKind = (sdkAttributeType, sdkObjectClass, sdkMatchingRule, sdkSyntax,
    sdkDitContentRule);

  TSchemaSuggestionKind = (sskAllowedMust, sskAllowedMay, sskOther, sskOperational);

  TSchemaSuggestion = record
    Name: string;
    Oid: string;
    Kind: TSchemaSuggestionKind;
    ReadOnly: Boolean;
    SingleValue: Boolean;
    Obsolete: Boolean;
    Help: string;
  end;
  TSchemaSuggestionArray = array of TSchemaSuggestion;

  TSchemaSnapshot = class
  private
    FAttrs: TObjectList;
    FClasses: TObjectList;
    FRules: TObjectList;
    FSyntaxes: TObjectList;
    FContentRules: TObjectList;
    FIndex: TStringList;
    FErrors: TStringList;
    FSourceKey: string;
    FSubschemaDn: string;
    FFetchedUtc: TDateTime;
    FStale: Boolean;
    FIncompleteReason: string;
    FAdMeta: TAdSchemaMeta;
    FAdMetaReason: string;
    FSerial: Int64;
    procedure SetAdMeta(AValue: TAdSchemaMeta);
    procedure AddIndex(const APrefix: string; AElem: TSchemaElement);
    procedure AddError(const AMsg: string);
    function Lookup(const APrefix, AName: string): TSchemaElement;
  public
    constructor Create;
    destructor Destroy; override;
    function AddDefinition(AKind: TSchemaDefKind; const AText: string): Boolean;
    function Clone: TSchemaSnapshot;
    procedure Clear;
    function AttributeType(const ANameOrOid: string): TSchemaAttributeType;
    function ObjectClass(const ANameOrOid: string): TSchemaObjectClass;
    function MatchingRule(const ANameOrOid: string): TSchemaMatchingRule;
    function Syntax(const AOid: string): TSchemaSyntax;
    function DitContentRule(const AClass: string): TSchemaDitContentRule;
    function DitContentRuleCount: Integer;
    // Lecture incomplete (entree tronquee par un budget, valeurs non decodees): une
    // absence dans ce schema ne prouve rien.
    procedure MarkIncomplete(const AReason: string);
    function Complete: Boolean;
    function AttributeTypeCount: Integer;
    function ObjectClassCount: Integer;
    function AttributeTypeAt(AIndex: Integer): TSchemaAttributeType;
    function ObjectClassAt(AIndex: Integer): TSchemaObjectClass;
    function EffectiveEquality(const AAttr: string): string;
    function EffectiveSyntax(const AAttr: string): string;
    function IsOperational(const AAttr: string): Boolean;
    function IsSingleValue(const AAttr: string): Boolean;
    function IsNoUserModification(const AAttr: string): Boolean;
    function CanonicalAttrName(const AAttr: string): string;
    function CollectAllowed(const AClasses: array of string; AMust, AMay: TStrings): Boolean;
    function ClassChain(const AClass: string; AOut: TStrings): Boolean;
    function SuggestAttributes(const APrefix: string;
      const AContextClasses: array of string; AMax: Integer = 50): TSchemaSuggestionArray;
    function SuggestObjectClasses(const APrefix: string; AMax: Integer = 50): TSchemaSuggestionArray;
    property Errors: TStringList read FErrors;
    property SourceKey: string read FSourceKey write FSourceKey;
    property SubschemaDn: string read FSubschemaDn write FSubschemaDn;
    property FetchedUtc: TDateTime read FFetchedUtc write FFetchedUtc;
    property Stale: Boolean read FStale write FStale;
    property IncompleteReason: string read FIncompleteReason;
    property AdMeta: TAdSchemaMeta read FAdMeta write SetAdMeta;
    property AdMetaReason: string read FAdMetaReason write FAdMetaReason;
    property Serial: Int64 read FSerial;
  end;

  ESchemaParse = class(Exception);

function ParseAttributeTypeDescription(const S: string): TSchemaAttributeType;
function ParseObjectClassDescription(const S: string): TSchemaObjectClass;
function ParseDitContentRuleDescription(const S: string): TSchemaDitContentRule;
// Identite d'un instantane: numero, origine, date de lecture, taille. Un plan valide
// garde cette cle; une autre cle veut dire schema relu, meme a contenu identique. Le
// numero et pas l'adresse: une adresse liberee se recycle, et valider contre un fantome
// n'est pas valider.
function SchemaSnapshotKey(ASchema: TSchemaSnapshot): string;

implementation

uses
  uLdapEntry;

type
  TTokKind = (tkLParen, tkRParen, tkQuoted, tkWord, tkEnd);

  TSchemaLexer = class
  private
    FS: string;
    FP: Integer;
  public
    constructor Create(const S: string);
    function Next(out AText: string): TTokKind;
    function PeekKind: TTokKind;
  end;

constructor TSchemaLexer.Create(const S: string);
begin
  inherited Create;
  FS := S;
  FP := 1;
end;

function TSchemaLexer.Next(out AText: string): TTokKind;
var
  start: Integer;
  c: Char;
begin
  AText := '';
  while (FP <= Length(FS)) and (FS[FP] in [' ', #9, #10, #13]) do Inc(FP);
  if FP > Length(FS) then Exit(tkEnd);
  c := FS[FP];
  if c = '(' then
  begin
    Inc(FP);
    Exit(tkLParen);
  end;
  if c = ')' then
  begin
    Inc(FP);
    Exit(tkRParen);
  end;
  if c = '''' then
  begin
    Inc(FP);
    start := FP;
    while (FP <= Length(FS)) and (FS[FP] <> '''') do Inc(FP);
    if FP > Length(FS) then
      raise ESchemaParse.Create('unterminated quoted string');
    AText := Copy(FS, start, FP - start);
    AText := StringReplace(AText, '\27', '''', [rfReplaceAll, rfIgnoreCase]);
    AText := StringReplace(AText, '\5C', '\', [rfReplaceAll, rfIgnoreCase]);
    Inc(FP);
    Exit(tkQuoted);
  end;
  start := FP;
  while (FP <= Length(FS)) and not (FS[FP] in [' ', #9, #10, #13, '(', ')', '''']) do
    Inc(FP);
  AText := Copy(FS, start, FP - start);
  Result := tkWord;
end;

function TSchemaLexer.PeekKind: TTokKind;
var
  save: Integer;
  t: string;
begin
  save := FP;
  Result := Next(t);
  FP := save;
end;

function ReadList(L: TSchemaLexer; AQuotedExpected: Boolean;
  AMax: Integer = SCHEMA_MAX_LIST): TStringArray;
var
  k: TTokKind;
  t: string;
begin
  Result := nil;
  k := L.Next(t);
  if k in [tkQuoted, tkWord] then
  begin
    SetLength(Result, 1);
    Result[0] := t;
    Exit;
  end;
  if k <> tkLParen then
    raise ESchemaParse.Create('list expected');
  while True do
  begin
    k := L.Next(t);
    case k of
      tkRParen: Break;
      tkEnd: raise ESchemaParse.Create('unterminated list');
      tkWord:
        if t <> '$' then
        begin
          if Length(Result) >= AMax then
            raise ESchemaParse.Create('list too long');
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := t;
        end;
      tkQuoted:
        begin
          if Length(Result) >= AMax then
            raise ESchemaParse.Create('list too long');
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := t;
        end;
    else
      raise ESchemaParse.Create('unexpected token in list');
    end;
  end;
end;

function ReadOne(L: TSchemaLexer): string;
var
  k: TTokKind;
begin
  k := L.Next(Result);
  if not (k in [tkWord, tkQuoted]) then
    raise ESchemaParse.Create('value expected');
end;

procedure AddExt(AElem: TSchemaElement; const AName: string; const AValues: TStringArray);
var
  i: Integer;
begin
  SetLength(AElem.Extensions, Length(AElem.Extensions) + 1);
  with AElem.Extensions[High(AElem.Extensions)] do
  begin
    Name := AName;
    SetLength(Values, Length(AValues));
    for i := 0 to High(AValues) do
      Values[i] := AValues[i];
  end;
end;

function ParseCommon(L: TSchemaLexer; AElem: TSchemaElement; const AKey: string): Boolean;
var
  k: string;
begin
  Result := True;
  k := UpperCase(AKey);
  if k = 'NAME' then
    AElem.Names := ReadList(L, True, SCHEMA_MAX_NAMES)
  else if k = 'DESC' then
    AElem.Desc := ReadOne(L)
  else if k = 'OBSOLETE' then
    AElem.Obsolete := True
  else if (Length(k) > 2) and (Copy(k, 1, 2) = 'X-') then
    AddExt(AElem, AKey, ReadList(L, True))
  else
    Result := False;
end;

procedure StartDefinition(L: TSchemaLexer; AElem: TSchemaElement; const S: string);
var
  t: string;
begin
  if Length(S) > SCHEMA_MAX_DEF_CHARS then
    raise ESchemaParse.Create('definition too long');
  AElem.Raw := S;
  if L.Next(t) <> tkLParen then
    raise ESchemaParse.Create('"(" expected');
  // OID numerique attendu, mais certains serveurs y mettent un nom "x-oid". On fait avec.
  if not (L.Next(t) in [tkWord, tkQuoted]) then
    raise ESchemaParse.Create('OID expected');
  AElem.Oid := t;
end;

procedure SkipUnknown(L: TSchemaLexer);
var
  t: string;
begin
  case L.PeekKind of
    tkLParen: ReadList(L, False);
    tkQuoted: L.Next(t);
  end;
end;

function SyntaxWithLen(const S: string; out ALen: Integer): string;
var
  p, q: Integer;
begin
  ALen := 0;
  p := Pos('{', S);
  if p = 0 then Exit(S);
  Result := Copy(S, 1, p - 1);
  q := Pos('}', S);
  if q > p then
    ALen := StrToIntDef(Copy(S, p + 1, q - p - 1), 0);
end;

function ParseAttributeTypeDescription(const S: string): TSchemaAttributeType;
var
  L: TSchemaLexer;
  k: TTokKind;
  t, u: string;
begin
  Result := TSchemaAttributeType.Create;
  L := TSchemaLexer.Create(S);
  try
    try
      StartDefinition(L, Result, S);
      while True do
      begin
        k := L.Next(t);
        if k = tkRParen then Break;
        if k = tkEnd then raise ESchemaParse.Create('")" expected');
        if k <> tkWord then raise ESchemaParse.Create('keyword expected');
        if ParseCommon(L, Result, t) then Continue;
        u := UpperCase(t);
        if u = 'SUP' then Result.Sup := ReadOne(L)
        else if u = 'EQUALITY' then Result.Equality := ReadOne(L)
        else if u = 'ORDERING' then Result.Ordering := ReadOne(L)
        else if u = 'SUBSTR' then Result.Substr := ReadOne(L)
        else if u = 'SYNTAX' then Result.Syntax := SyntaxWithLen(ReadOne(L), Result.SyntaxLen)
        else if u = 'SINGLE-VALUE' then Result.SingleValue := True
        else if u = 'COLLECTIVE' then Result.Collective := True
        else if u = 'NO-USER-MODIFICATION' then Result.NoUserModification := True
        else if u = 'USAGE' then
        begin
          u := LowerCase(ReadOne(L));
          if u = 'directoryoperation' then Result.Usage := auDirectoryOperation
          else if u = 'distributedoperation' then Result.Usage := auDistributedOperation
          else if u = 'dsaoperation' then Result.Usage := auDsaOperation
          else Result.Usage := auUserApplications;
        end
        else
          SkipUnknown(L);
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    L.Free;
  end;
end;

function ParseObjectClassDescription(const S: string): TSchemaObjectClass;
var
  L: TSchemaLexer;
  k: TTokKind;
  t, u: string;
begin
  Result := TSchemaObjectClass.Create;
  L := TSchemaLexer.Create(S);
  try
    try
      StartDefinition(L, Result, S);
      while True do
      begin
        k := L.Next(t);
        if k = tkRParen then Break;
        if k = tkEnd then raise ESchemaParse.Create('")" expected');
        if k <> tkWord then raise ESchemaParse.Create('keyword expected');
        if ParseCommon(L, Result, t) then Continue;
        u := UpperCase(t);
        if u = 'SUP' then Result.Sups := ReadList(L, False)
        else if u = 'ABSTRACT' then Result.Kind := ockAbstract
        else if u = 'STRUCTURAL' then Result.Kind := ockStructural
        else if u = 'AUXILIARY' then Result.Kind := ockAuxiliary
        else if u = 'MUST' then Result.Must := ReadList(L, False)
        else if u = 'MAY' then Result.May := ReadList(L, False)
        else
          SkipUnknown(L);
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    L.Free;
  end;
end;

function ParseDitContentRuleDescription(const S: string): TSchemaDitContentRule;
var
  L: TSchemaLexer;
  k: TTokKind;
  t, u: string;
begin
  Result := TSchemaDitContentRule.Create;
  L := TSchemaLexer.Create(S);
  try
    try
      StartDefinition(L, Result, S);
      while True do
      begin
        k := L.Next(t);
        if k = tkRParen then Break;
        if k = tkEnd then raise ESchemaParse.Create('")" expected');
        if k <> tkWord then raise ESchemaParse.Create('keyword expected');
        if ParseCommon(L, Result, t) then Continue;
        u := UpperCase(t);
        if u = 'AUX' then Result.Aux := ReadList(L, False)
        else if u = 'MUST' then Result.Must := ReadList(L, False)
        else if u = 'MAY' then Result.May := ReadList(L, False)
        else if u = 'NOT' then Result.Precluded := ReadList(L, False)
        else
          SkipUnknown(L);
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    L.Free;
  end;
end;

function SchemaSnapshotKey(ASchema: TSchemaSnapshot): string;
begin
  if ASchema = nil then Exit('');
  Result := IntToStr(ASchema.Serial) + '|' + ASchema.SourceKey + '|' + FloatToStr(ASchema.FetchedUtc) + '|' +
    IntToStr(ASchema.AttributeTypeCount) + '|' + IntToStr(ASchema.ObjectClassCount);
end;

function ParseSimpleElement(const S: string; AElem: TSchemaElement): TSchemaElement;
var
  L: TSchemaLexer;
  k: TTokKind;
  t: string;
begin
  Result := AElem;
  L := TSchemaLexer.Create(S);
  try
    try
      StartDefinition(L, Result, S);
      while True do
      begin
        k := L.Next(t);
        if k = tkRParen then Break;
        if k = tkEnd then raise ESchemaParse.Create('")" expected');
        if k <> tkWord then raise ESchemaParse.Create('keyword expected');
        if ParseCommon(L, Result, t) then Continue;
        if (UpperCase(t) = 'SYNTAX') and (Result is TSchemaMatchingRule) then
          TSchemaMatchingRule(Result).Syntax := ReadOne(L)
        else
          SkipUnknown(L);
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    L.Free;
  end;
end;

function TSchemaElement.PrimaryName: string;
begin
  if Length(Names) > 0 then
    Result := Names[0]
  else
    Result := Oid;
end;

function TSchemaElement.HasName(const AName: string): Boolean;
var
  i: Integer;
  l: string;
begin
  l := AsciiLowerCase(AName);
  if AsciiLowerCase(Oid) = l then Exit(True);
  for i := 0 to High(Names) do
    if AsciiLowerCase(Names[i]) = l then Exit(True);
  Result := False;
end;

function TSchemaElement.ExtensionValue(const AName: string): string;
var
  i: Integer;
begin
  for i := 0 to High(Extensions) do
    if SameText(Extensions[i].Name, AName) and (Length(Extensions[i].Values) > 0) then
      Exit(Extensions[i].Values[0]);
  Result := '';
end;

var
  GSchemaSerial: Int64 = 0;

constructor TSchemaSnapshot.Create;
begin
  inherited Create;
  // Des fils de lecture creent aussi des instantanes: increment atomique, sinon deux
  // schemas finissent un jour avec le meme numero.
  FSerial := InterLockedIncrement64(GSchemaSerial);
  FAttrs := TObjectList.Create(True);
  FClasses := TObjectList.Create(True);
  FRules := TObjectList.Create(True);
  FSyntaxes := TObjectList.Create(True);
  FContentRules := TObjectList.Create(True);
  FIndex := TStringList.Create;
  FIndex.Sorted := True;
  FIndex.Duplicates := dupIgnore;
  FIndex.CaseSensitive := True;
  FErrors := TStringList.Create;
end;

destructor TSchemaSnapshot.Destroy;
begin
  FAdMeta.Free;
  FIndex.Free;
  FAttrs.Free;
  FClasses.Free;
  FRules.Free;
  FSyntaxes.Free;
  FContentRules.Free;
  FErrors.Free;
  inherited Destroy;
end;

procedure TSchemaSnapshot.MarkIncomplete(const AReason: string);
begin
  if FIncompleteReason = '' then FIncompleteReason := AReason
  else if Pos(AReason, FIncompleteReason) = 0 then FIncompleteReason := FIncompleteReason + '; ' + AReason;
end;

function TSchemaSnapshot.Complete: Boolean;
begin
  Result := FIncompleteReason = '';
end;

procedure TSchemaSnapshot.SetAdMeta(AValue: TAdSchemaMeta);
begin
  if AValue = FAdMeta then Exit;
  FAdMeta.Free;
  FAdMeta := AValue;
end;

procedure TSchemaSnapshot.Clear;
begin
  FreeAndNil(FAdMeta);
  FIndex.Clear;
  FAttrs.Clear;
  FClasses.Clear;
  FRules.Clear;
  FSyntaxes.Clear;
  FContentRules.Clear;
  FErrors.Clear;
  FIncompleteReason := '';
end;

procedure TSchemaSnapshot.AddError(const AMsg: string);
begin
  if FErrors.Count < SCHEMA_MAX_ERRORS then
    FErrors.Add(AMsg);
end;

procedure TSchemaSnapshot.AddIndex(const APrefix: string; AElem: TSchemaElement);

  procedure AddKey(const AKey: string);
  begin
    // Premier arrive, premier servi. AddObject de FPC ecrase l'objet d'une cle deja
    // presente meme en dupIgnore: on teste avant d'ajouter.
    if FIndex.IndexOf(AKey) < 0 then
      FIndex.AddObject(AKey, AElem);
  end;

var
  i: Integer;
begin
  AddKey(APrefix + AsciiLowerCase(AElem.Oid));
  for i := 0 to High(AElem.Names) do
    AddKey(APrefix + AsciiLowerCase(AElem.Names[i]));
end;

function TSchemaSnapshot.Lookup(const APrefix, AName: string): TSchemaElement;
var
  i: Integer;
begin
  i := FIndex.IndexOf(APrefix + AsciiLowerCase(AName));
  if i < 0 then
    Result := nil
  else
    Result := TSchemaElement(FIndex.Objects[i]);
end;

function TSchemaSnapshot.AddDefinition(AKind: TSchemaDefKind; const AText: string): Boolean;
var
  e: TSchemaElement;
  total: Integer;
begin
  Result := False;
  total := FAttrs.Count + FClasses.Count + FRules.Count + FSyntaxes.Count + FContentRules.Count;
  if total >= SCHEMA_MAX_DEFINITIONS then
  begin
    AddError('too many schema definitions, remainder ignored');
    Exit;
  end;
  try
    case AKind of
      sdkAttributeType:
        begin
          e := ParseAttributeTypeDescription(AText);
          if Lookup('a:', e.Oid) <> nil then
            AddError('duplicate attribute type ' + e.Oid);
          FAttrs.Add(e);
          AddIndex('a:', e);
        end;
      sdkObjectClass:
        begin
          e := ParseObjectClassDescription(AText);
          if Lookup('o:', e.Oid) <> nil then
            AddError('duplicate object class ' + e.Oid);
          FClasses.Add(e);
          AddIndex('o:', e);
        end;
      sdkMatchingRule:
        begin
          e := ParseSimpleElement(AText, TSchemaMatchingRule.Create);
          FRules.Add(e);
          AddIndex('m:', e);
        end;
      sdkSyntax:
        begin
          e := ParseSimpleElement(AText, TSchemaSyntax.Create);
          FSyntaxes.Add(e);
          AddIndex('s:', e);
        end;
      sdkDitContentRule:
        begin
          e := ParseDitContentRuleDescription(AText);
          if Lookup('d:', e.Oid) <> nil then
            AddError('duplicate DIT content rule ' + e.Oid);
          FContentRules.Add(e);
          AddIndex('d:', e);
        end;
    end;
    Result := True;
  except
    on E: ESchemaParse do
      AddError(E.Message + ': ' + Copy(AText, 1, 120));
  end;
end;

function TSchemaSnapshot.Clone: TSchemaSnapshot;
var
  i: Integer;
begin
  Result := TSchemaSnapshot.Create;
  try
    for i := 0 to FSyntaxes.Count - 1 do
      Result.AddDefinition(sdkSyntax, TSchemaElement(FSyntaxes[i]).Raw);
    for i := 0 to FRules.Count - 1 do
      Result.AddDefinition(sdkMatchingRule, TSchemaElement(FRules[i]).Raw);
    for i := 0 to FAttrs.Count - 1 do
      Result.AddDefinition(sdkAttributeType, TSchemaElement(FAttrs[i]).Raw);
    for i := 0 to FClasses.Count - 1 do
      Result.AddDefinition(sdkObjectClass, TSchemaElement(FClasses[i]).Raw);
    for i := 0 to FContentRules.Count - 1 do
      Result.AddDefinition(sdkDitContentRule, TSchemaElement(FContentRules[i]).Raw);
    Result.FSourceKey := FSourceKey;
    Result.FSubschemaDn := FSubschemaDn;
    Result.FFetchedUtc := FFetchedUtc;
    Result.FStale := FStale;
    Result.FIncompleteReason := FIncompleteReason;
    if FAdMeta <> nil then
      Result.FAdMetaReason := 'Active Directory schema metadata are not copied';
  except
    Result.Free;
    raise;
  end;
end;

function TSchemaSnapshot.AttributeType(const ANameOrOid: string): TSchemaAttributeType;
begin
  Result := TSchemaAttributeType(Lookup('a:', AttrBaseName(ANameOrOid)));
end;

function TSchemaSnapshot.ObjectClass(const ANameOrOid: string): TSchemaObjectClass;
begin
  Result := TSchemaObjectClass(Lookup('o:', ANameOrOid));
end;

function TSchemaSnapshot.MatchingRule(const ANameOrOid: string): TSchemaMatchingRule;
begin
  Result := TSchemaMatchingRule(Lookup('m:', ANameOrOid));
end;

function TSchemaSnapshot.Syntax(const AOid: string): TSchemaSyntax;
begin
  Result := TSchemaSyntax(Lookup('s:', AOid));
end;

function TSchemaSnapshot.DitContentRule(const AClass: string): TSchemaDitContentRule;
var
  oc: TSchemaObjectClass;
begin
  Result := nil;
  oc := ObjectClass(AClass);
  if oc = nil then Exit;
  Result := TSchemaDitContentRule(Lookup('d:', oc.Oid));
end;

function TSchemaSnapshot.DitContentRuleCount: Integer;
begin
  Result := FContentRules.Count;
end;

function TSchemaSnapshot.AttributeTypeCount: Integer;
begin
  Result := FAttrs.Count;
end;

function TSchemaSnapshot.ObjectClassCount: Integer;
begin
  Result := FClasses.Count;
end;

function TSchemaSnapshot.AttributeTypeAt(AIndex: Integer): TSchemaAttributeType;
begin
  Result := TSchemaAttributeType(FAttrs[AIndex]);
end;

function TSchemaSnapshot.ObjectClassAt(AIndex: Integer): TSchemaObjectClass;
begin
  Result := TSchemaObjectClass(FClasses[AIndex]);
end;

function TSchemaSnapshot.EffectiveEquality(const AAttr: string): string;
var
  a: TSchemaAttributeType;
  depth: Integer;
begin
  Result := '';
  a := AttributeType(AAttr);
  depth := 0;
  while (a <> nil) and (depth < SCHEMA_MAX_SUP_DEPTH) do
  begin
    if a.Equality <> '' then Exit(a.Equality);
    if a.Sup = '' then Exit;
    a := AttributeType(a.Sup);
    Inc(depth);
  end;
end;

function TSchemaSnapshot.EffectiveSyntax(const AAttr: string): string;
var
  a: TSchemaAttributeType;
  depth: Integer;
begin
  Result := '';
  a := AttributeType(AAttr);
  depth := 0;
  while (a <> nil) and (depth < SCHEMA_MAX_SUP_DEPTH) do
  begin
    if a.Syntax <> '' then Exit(a.Syntax);
    if a.Sup = '' then Exit;
    a := AttributeType(a.Sup);
    Inc(depth);
  end;
end;

function TSchemaSnapshot.IsOperational(const AAttr: string): Boolean;
var
  a: TSchemaAttributeType;
begin
  a := AttributeType(AAttr);
  Result := (a <> nil) and (a.Usage <> auUserApplications);
end;

function TSchemaSnapshot.IsSingleValue(const AAttr: string): Boolean;
var
  a: TSchemaAttributeType;
begin
  a := AttributeType(AAttr);
  Result := (a <> nil) and a.SingleValue;
end;

function TSchemaSnapshot.IsNoUserModification(const AAttr: string): Boolean;
var
  a: TSchemaAttributeType;
begin
  a := AttributeType(AAttr);
  Result := (a <> nil) and a.NoUserModification;
end;

function TSchemaSnapshot.CanonicalAttrName(const AAttr: string): string;
var
  a: TSchemaAttributeType;
begin
  a := AttributeType(AAttr);
  if a = nil then
    Result := ''
  else
    Result := AsciiLowerCase(a.PrimaryName);
end;

function TSchemaSnapshot.ClassChain(const AClass: string; AOut: TStrings): Boolean;
var
  queue: TStringList;
  seen: TStringList;
  i, j: Integer;
  oc: TSchemaObjectClass;
  key: string;
begin
  Result := True;
  queue := TStringList.Create;
  seen := TStringList.Create;
  try
    seen.Sorted := True;
    queue.Add(AClass);
    i := 0;
    while i < queue.Count do
    begin
      if i > SCHEMA_MAX_SUP_DEPTH * 4 then
      begin
        Result := False;
        Break;
      end;
      oc := ObjectClass(queue[i]);
      if oc = nil then
      begin
        Result := False;
        Inc(i);
        Continue;
      end;
      key := AsciiLowerCase(oc.Oid);
      if seen.IndexOf(key) >= 0 then
      begin
        Inc(i);
        Continue;
      end;
      seen.Add(key);
      AOut.Add(oc.PrimaryName);
      for j := 0 to High(oc.Sups) do
        queue.Add(oc.Sups[j]);
      Inc(i);
    end;
    for i := 1 to queue.Count - 1 do
    begin
      oc := ObjectClass(queue[i]);
      if (oc <> nil) and oc.HasName(AClass) then
        Result := False;
    end;
  finally
    queue.Free;
    seen.Free;
  end;
end;

function TSchemaSnapshot.CollectAllowed(const AClasses: array of string;
  AMust, AMay: TStrings): Boolean;
var
  chain: TStringList;
  i, c, j: Integer;
  oc: TSchemaObjectClass;

  procedure AddUnique(AList: TStrings; const AName: string);
  var
    k: Integer;
    canon: string;
  begin
    canon := CanonicalAttrName(AName);
    if canon = '' then canon := AsciiLowerCase(AName);
    for k := 0 to AList.Count - 1 do
      if AsciiLowerCase(AList[k]) = canon then Exit;
    AList.Add(AName);
  end;

begin
  Result := True;
  chain := TStringList.Create;
  try
    for c := 0 to High(AClasses) do
    begin
      chain.Clear;
      if not ClassChain(AClasses[c], chain) then
        Result := False;
      for i := 0 to chain.Count - 1 do
      begin
        oc := ObjectClass(chain[i]);
        if oc = nil then Continue;
        for j := 0 to High(oc.Must) do
          AddUnique(AMust, oc.Must[j]);
        for j := 0 to High(oc.May) do
          AddUnique(AMay, oc.May[j]);
      end;
    end;
    for i := AMay.Count - 1 downto 0 do
      for j := 0 to AMust.Count - 1 do
        if SameText(CanonicalAttrName(AMay[i]), CanonicalAttrName(AMust[j])) and
           (CanonicalAttrName(AMay[i]) <> '') then
        begin
          AMay.Delete(i);
          Break;
        end;
  finally
    chain.Free;
  end;
end;

function MatchesPrefix(AElem: TSchemaElement; const APrefix: string; out AName: string): Boolean;
var
  i: Integer;
  lp: string;
begin
  lp := AsciiLowerCase(APrefix);
  for i := 0 to High(AElem.Names) do
    if Copy(AsciiLowerCase(AElem.Names[i]), 1, Length(lp)) = lp then
    begin
      AName := AElem.Names[i];
      Exit(True);
    end;
  if Copy(AsciiLowerCase(AElem.Oid), 1, Length(lp)) = lp then
  begin
    AName := AElem.PrimaryName;
    Exit(True);
  end;
  Result := False;
end;

function TSchemaSnapshot.SuggestAttributes(const APrefix: string;
  const AContextClasses: array of string; AMax: Integer): TSchemaSuggestionArray;
var
  must, may: TStringList;
  i, j: Integer;
  a: TSchemaAttributeType;
  name: string;
  s: TSchemaSuggestion;
  buckets: array[TSchemaSuggestionKind] of TSchemaSuggestionArray;
  k: TSchemaSuggestionKind;
begin
  Result := nil;
  for k := Low(k) to High(k) do
    buckets[k] := nil;
  must := TStringList.Create;
  may := TStringList.Create;
  try
    if Length(AContextClasses) > 0 then
      CollectAllowed(AContextClasses, must, may);
    for i := 0 to FAttrs.Count - 1 do
    begin
      a := TSchemaAttributeType(FAttrs[i]);
      if not MatchesPrefix(a, APrefix, name) then Continue;
      s.Name := name;
      s.Oid := a.Oid;
      s.ReadOnly := a.NoUserModification;
      s.SingleValue := a.SingleValue;
      s.Obsolete := a.Obsolete;
      s.Help := a.Desc;
      s.Kind := sskOther;
      if a.Usage <> auUserApplications then
        s.Kind := sskOperational
      else
      begin
        for j := 0 to must.Count - 1 do
          if a.HasName(must[j]) then s.Kind := sskAllowedMust;
        if s.Kind = sskOther then
          for j := 0 to may.Count - 1 do
            if a.HasName(may[j]) then s.Kind := sskAllowedMay;
      end;
      SetLength(buckets[s.Kind], Length(buckets[s.Kind]) + 1);
      buckets[s.Kind][High(buckets[s.Kind])] := s;
    end;
  finally
    must.Free;
    may.Free;
  end;
  for j := 0 to 1 do
    for k := Low(k) to High(k) do
      for i := 0 to High(buckets[k]) do
      begin
        a := AttributeType(buckets[k][i].Oid);
        if (a <> nil) and a.HasName(APrefix) then
        begin
          if j = 1 then Continue;
        end
        else if j = 0 then
          Continue;
        if Length(Result) >= AMax then Exit;
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := buckets[k][i];
      end;
end;

function TSchemaSnapshot.SuggestObjectClasses(const APrefix: string;
  AMax: Integer): TSchemaSuggestionArray;
var
  i: Integer;
  oc: TSchemaObjectClass;
  name: string;
begin
  Result := nil;
  for i := 0 to FClasses.Count - 1 do
  begin
    oc := TSchemaObjectClass(FClasses[i]);
    if not MatchesPrefix(oc, APrefix, name) then Continue;
    if Length(Result) >= AMax then Exit;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Name := name;
    Result[High(Result)].Oid := oc.Oid;
    Result[High(Result)].Kind := sskOther;
    Result[High(Result)].Obsolete := oc.Obsolete;
    Result[High(Result)].Help := oc.Desc;
    Result[High(Result)].ReadOnly := False;
    Result[High(Result)].SingleValue := False;
  end;
end;

end.
