// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSchemaDefinition;

{$mode objfpc}{$H+}

// Definition de schema RFC 4512 editee sans perte: on remplace le seul segment
// modifie, le reste est recopie a l'octet pres (alias, X-*, ordre, espaces).
// Un mot-cle inconnu rend la definition consultable seulement: reecrire un schema
// qu'on ne comprend pas, c'est la meilleure facon d'apprendre a restaurer cn=config.

interface

uses
  SysUtils;

const
  SCHEMA_DEF_MAX_CHARS = 64 * 1024;
  SCHEMA_DEF_MAX_FIELDS = 64;
  SCHEMA_DEF_MAX_LIST = 1024;

type
  TDefinitionKind = (dkAttribute, dkClass);

  TFieldShape = (fsFlag, fsQdescrs, fsQdstring, fsOid, fsOids, fsWord, fsQdstrings);

  TDefField = record
    Keyword: string;
    Values: array of string;
    StartPos: Integer;
    EndPos: Integer;
  end;

  TSchemaDefinition = class
  private
    FRaw: string;
    FKind: TDefinitionKind;
    FOid: string;
    FOidStart, FOidEnd: Integer;
    FFields: array of TDefField;
    FEditable: Boolean;
    FReason: string;
    procedure Parse;
    function FieldIndex(const AKeyword: string): Integer;
    procedure Splice(AStart, AEnd: Integer; const AText: string);
  public
    constructor Create(AKind: TDefinitionKind; const ARaw: string);
    constructor CreateNew(AKind: TDefinitionKind; const AOid: string);
    function Clone: TSchemaDefinition;
    function Has(const AKeyword: string): Boolean;
    function Values(const AKeyword: string): TStringArray;
    function Value(const AKeyword: string): string;
    function FieldCount: Integer;
    function FieldKeyword(AIndex: Integer): string;
    function SetValues(const AKeyword: string; const AValues: array of string; out AError: string): Boolean;
    function SetValue(const AKeyword, AValue: string; out AError: string): Boolean;
    function SetFlag(const AKeyword: string; AOn: Boolean; out AError: string): Boolean;
    function SetClassKind(const AKeyword: string; out AError: string): Boolean;
    function Remove(const AKeyword: string; out AError: string): Boolean;
    function SetOid(const AOid: string; out AError: string): Boolean;
    property Raw: string read FRaw;
    property Kind: TDefinitionKind read FKind;
    property Oid: string read FOid;
    property Editable: Boolean read FEditable;
    property Reason: string read FReason;
  end;

resourcestring
  rsSdfTooLong = 'definition too long';
  rsSdfParen = '"(" expected at the start';
  rsSdfOid = 'OID expected after "("';
  rsSdfUnterminated = 'unterminated quoted string';
  rsSdfEnd = '")" expected at the end';
  rsSdfTrailing = 'text after the closing ")"';
  rsSdfKeyword = 'keyword expected, found "%s"';
  rsSdfUnknownKeyword = 'unknown keyword %s: the definition is shown but not changed';
  rsSdfDuplicate = '%s appears twice';
  rsSdfValue = '%s: value expected';
  rsSdfList = '%s: invalid list';
  rsSdfTooMany = 'too many elements';
  rsSdfNotEditable = 'the definition cannot be changed: %s';
  rsSdfBadName = '"%s" is not a valid name (a letter, then letters, digits or hyphens)';
  rsSdfBadOid = '"%s" is not a numeric OID';
  rsSdfBadOidOrName = '"%s" is neither a numeric OID nor a name';
  rsSdfBadSyntax = '"%s" is not a syntax OID with an optional {length}';
  rsSdfBadText = 'descriptions cannot be empty or hold control characters';
  rsSdfBadUsage = '"%s" is not a usage (userApplications, directoryOperation, distributedOperation, dSAOperation)';
  rsSdfBadExtension = '"%s" is not an extension name (X- then letters, hyphens or underscores)';
  rsSdfNotForKind = '%s does not apply to this kind of definition';
  rsSdfEmptyList = '%s needs at least one value';

function KeywordShape(AKind: TDefinitionKind; const AKeyword: string; out AShape: TFieldShape): Boolean;
function IsSchemaDescr(const S: string): Boolean;
function IsNumericOidText(const S: string): Boolean;
function QuoteQdstring(const S: string): string;
// Controle apres modification: rien d'autre n'a bouge. Un schema qui change en
// douce, c'est un annuaire qui refuse les ecritures lundi matin.
function SameDefinitionExcept(A, B: TSchemaDefinition; const AIgnore: array of string): Boolean;

implementation

type
  TTokKind = (tkLParen, tkRParen, tkQuoted, tkWord, tkEnd);

  TToken = record
    Kind: TTokKind;
    Text: string;
    StartPos, EndPos: Integer;
  end;

const
  ATTR_ORDER: array[0..11] of string = ('NAME', 'DESC', 'OBSOLETE', 'SUP', 'EQUALITY', 'ORDERING',
    'SUBSTR', 'SYNTAX', 'SINGLE-VALUE', 'COLLECTIVE', 'NO-USER-MODIFICATION', 'USAGE');
  CLASS_ORDER: array[0..8] of string = ('NAME', 'DESC', 'OBSOLETE', 'SUP', 'ABSTRACT', 'STRUCTURAL',
    'AUXILIARY', 'MUST', 'MAY');

function IsExtensionKeyword(const K: string): Boolean;
var
  i: Integer;
begin
  Result := (Length(K) > 2) and (UpperCase(Copy(K, 1, 2)) = 'X-');
  if not Result then Exit;
  for i := 3 to Length(K) do
    if not (K[i] in ['A'..'Z', 'a'..'z', '-', '_']) then Exit(False);
end;

function KeywordShape(AKind: TDefinitionKind; const AKeyword: string; out AShape: TFieldShape): Boolean;
var
  k: string;
begin
  Result := True;
  k := UpperCase(AKeyword);
  if IsExtensionKeyword(AKeyword) then AShape := fsQdstrings
  else if k = 'NAME' then AShape := fsQdescrs
  else if k = 'DESC' then AShape := fsQdstring
  else if k = 'OBSOLETE' then AShape := fsFlag
  else if AKind = dkAttribute then
  begin
    if k = 'SUP' then AShape := fsOid
    else if (k = 'EQUALITY') or (k = 'ORDERING') or (k = 'SUBSTR') then AShape := fsOid
    else if k = 'SYNTAX' then AShape := fsWord
    else if (k = 'SINGLE-VALUE') or (k = 'COLLECTIVE') or (k = 'NO-USER-MODIFICATION') then AShape := fsFlag
    else if k = 'USAGE' then AShape := fsWord
    else Result := False;
  end
  else
  begin
    if k = 'SUP' then AShape := fsOids
    else if (k = 'ABSTRACT') or (k = 'STRUCTURAL') or (k = 'AUXILIARY') then AShape := fsFlag
    else if (k = 'MUST') or (k = 'MAY') then AShape := fsOids
    else Result := False;
  end;
end;

function IsSchemaDescr(const S: string): Boolean;
var
  i: Integer;
begin
  Result := (S <> '') and (S[1] in ['A'..'Z', 'a'..'z']);
  if not Result then Exit;
  for i := 2 to Length(S) do
    if not (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '-']) then Exit(False);
end;

function IsNumericOidText(const S: string): Boolean;
var
  parts: TStringArray;
  i, j: Integer;
begin
  Result := False;
  parts := S.Split(['.']);
  if Length(parts) < 2 then Exit;
  for i := 0 to High(parts) do
  begin
    if parts[i] = '' then Exit;
    for j := 1 to Length(parts[i]) do
      if not (parts[i][j] in ['0'..'9']) then Exit;
    if (Length(parts[i]) > 1) and (parts[i][1] = '0') then Exit;
  end;
  Result := parts[0][1] in ['0'..'2'];
end;

function IsOidOrName(const S: string): Boolean;
begin
  Result := IsNumericOidText(S) or IsSchemaDescr(S);
end;

function IsSyntaxText(const S: string): Boolean;
var
  p, q, n: Integer;
begin
  p := Pos('{', S);
  if p = 0 then Exit(IsNumericOidText(S));
  q := Pos('}', S);
  Result := (q = Length(S)) and IsNumericOidText(Copy(S, 1, p - 1)) and
    TryStrToInt(Copy(S, p + 1, q - p - 1), n) and (n > 0);
end;

function QuoteQdstring(const S: string): string;
begin
  // \ et ' echappes en \5C et \27 (RFC 4512): une quote non echappee dans une
  // DESC et la definition suivante commence au milieu de la phrase.
  Result := '''' + StringReplace(StringReplace(S, '\', '\5C', [rfReplaceAll]), '''', '\27',
    [rfReplaceAll]) + '''';
end;

function UnquoteQdstring(const S: string): string;
begin
  Result := StringReplace(StringReplace(S, '\27', '''', [rfReplaceAll, rfIgnoreCase]), '\5C', '\',
    [rfReplaceAll, rfIgnoreCase]);
end;

{ Lexeur avec positions }

function NextToken(const S: string; var P: Integer; out AToken: TToken; out AError: string): Boolean;
var
  start: Integer;
begin
  Result := True;
  AError := '';
  while (P <= Length(S)) and (S[P] in [' ', #9, #10, #13]) do Inc(P);
  AToken.StartPos := P;
  AToken.Text := '';
  if P > Length(S) then
  begin
    AToken.Kind := tkEnd;
    AToken.EndPos := P;
    Exit;
  end;
  case S[P] of
    '(':
      begin
        AToken.Kind := tkLParen;
        Inc(P);
      end;
    ')':
      begin
        AToken.Kind := tkRParen;
        Inc(P);
      end;
    '''':
      begin
        Inc(P);
        start := P;
        while (P <= Length(S)) and (S[P] <> '''') do Inc(P);
        if P > Length(S) then
        begin
          AError := rsSdfUnterminated;
          Exit(False);
        end;
        AToken.Kind := tkQuoted;
        AToken.Text := UnquoteQdstring(Copy(S, start, P - start));
        Inc(P);
      end;
  else
    start := P;
    while (P <= Length(S)) and not (S[P] in [' ', #9, #10, #13, '(', ')', '''']) do Inc(P);
    AToken.Kind := tkWord;
    AToken.Text := Copy(S, start, P - start);
  end;
  AToken.EndPos := P;
end;

constructor TSchemaDefinition.Create(AKind: TDefinitionKind; const ARaw: string);
begin
  inherited Create;
  FKind := AKind;
  FRaw := ARaw;
  Parse;
end;

constructor TSchemaDefinition.CreateNew(AKind: TDefinitionKind; const AOid: string);
begin
  Create(AKind, '( ' + AOid + ' )');
  if not IsNumericOidText(AOid) then
  begin
    FEditable := False;
    FReason := Format(rsSdfBadOid, [AOid]);
  end;
end;

function TSchemaDefinition.Clone: TSchemaDefinition;
begin
  Result := TSchemaDefinition.Create(FKind, FRaw);
end;

procedure TSchemaDefinition.Parse;
var
  p: Integer;
  t: TToken;
  err, kw: string;
  shape: TFieldShape;
  f: TDefField;
  seen: array of string;
  i: Integer;

  procedure Fail(const AMsg: string);
  begin
    FEditable := False;
    if FReason = '' then FReason := AMsg;
  end;

  function ReadList(AQuoted, ADollar: Boolean; var AField: TDefField): Boolean;
  var
    u: TToken;
    expectItem: Boolean;
  begin
    Result := False;
    if not NextToken(FRaw, p, u, err) then Exit;
    if ((u.Kind = tkQuoted) and AQuoted) or ((u.Kind = tkWord) and not AQuoted) then
    begin
      SetLength(AField.Values, 1);
      AField.Values[0] := u.Text;
      AField.EndPos := u.EndPos;
      Exit(True);
    end;
    if u.Kind <> tkLParen then Exit;
    expectItem := True;
    while True do
    begin
      if not NextToken(FRaw, p, u, err) then Exit;
      if u.Kind = tkRParen then
      begin
        AField.EndPos := u.EndPos;
        Result := (Length(AField.Values) > 0) and (not ADollar or not expectItem);
        Exit;
      end;
      if u.Kind = tkEnd then Exit;
      if ADollar and (u.Kind = tkWord) and (u.Text = '$') then
      begin
        if expectItem then Exit;
        expectItem := True;
        Continue;
      end;
      if ADollar and not expectItem then Exit;
      if ((u.Kind = tkQuoted) and AQuoted) or ((u.Kind = tkWord) and not AQuoted) then
      begin
        if Length(AField.Values) >= SCHEMA_DEF_MAX_LIST then Exit;
        SetLength(AField.Values, Length(AField.Values) + 1);
        AField.Values[High(AField.Values)] := u.Text;
        expectItem := False;
      end
      else
        Exit;
    end;
  end;

begin
  FEditable := True;
  FReason := '';
  FFields := nil;
  FOid := '';
  seen := nil;
  if Length(FRaw) > SCHEMA_DEF_MAX_CHARS then
  begin
    Fail(rsSdfTooLong);
    Exit;
  end;
  p := 1;
  if not NextToken(FRaw, p, t, err) or (t.Kind <> tkLParen) then
  begin
    Fail(rsSdfParen);
    Exit;
  end;
  if not NextToken(FRaw, p, t, err) or not (t.Kind in [tkWord, tkQuoted]) then
  begin
    Fail(rsSdfOid);
    Exit;
  end;
  FOid := t.Text;
  FOidStart := t.StartPos;
  FOidEnd := t.EndPos;
  while True do
  begin
    if not NextToken(FRaw, p, t, err) then
    begin
      Fail(err);
      Exit;
    end;
    if t.Kind = tkRParen then Break;
    if t.Kind = tkEnd then
    begin
      Fail(rsSdfEnd);
      Exit;
    end;
    if t.Kind <> tkWord then
    begin
      Fail(Format(rsSdfKeyword, [t.Text]));
      Exit;
    end;
    kw := t.Text;
    if Length(FFields) >= SCHEMA_DEF_MAX_FIELDS then
    begin
      Fail(rsSdfTooMany);
      Exit;
    end;
    for i := 0 to High(seen) do
      if seen[i] = UpperCase(kw) then Fail(Format(rsSdfDuplicate, [kw]));
    SetLength(seen, Length(seen) + 1);
    seen[High(seen)] := UpperCase(kw);
    f := Default(TDefField);
    f.Keyword := kw;
    f.StartPos := t.StartPos;
    f.EndPos := t.EndPos;
    if not KeywordShape(FKind, kw, shape) then
    begin
      Fail(Format(rsSdfUnknownKeyword, [kw]));
      Exit;
    end;
    case shape of
      fsFlag: ;
      fsQdstring:
        begin
          if not NextToken(FRaw, p, t, err) or (t.Kind <> tkQuoted) then
          begin
            Fail(Format(rsSdfValue, [kw]));
            Exit;
          end;
          SetLength(f.Values, 1);
          f.Values[0] := t.Text;
          f.EndPos := t.EndPos;
        end;
      fsOid, fsWord:
        begin
          // AD publie certaines valeurs entre quotes (SYNTAX '1.2...'), RFC ou pas.
          if not NextToken(FRaw, p, t, err) or not (t.Kind in [tkWord, tkQuoted]) then
          begin
            Fail(Format(rsSdfValue, [kw]));
            Exit;
          end;
          SetLength(f.Values, 1);
          f.Values[0] := t.Text;
          f.EndPos := t.EndPos;
        end;
      fsQdescrs, fsQdstrings:
        if not ReadList(True, False, f) then
        begin
          Fail(Format(rsSdfList, [kw]));
          Exit;
        end;
      fsOids:
        if not ReadList(False, True, f) then
        begin
          Fail(Format(rsSdfList, [kw]));
          Exit;
        end;
    end;
    SetLength(FFields, Length(FFields) + 1);
    FFields[High(FFields)] := f;
  end;
  if not NextToken(FRaw, p, t, err) or (t.Kind <> tkEnd) then
    Fail(rsSdfTrailing);
end;

function TSchemaDefinition.FieldIndex(const AKeyword: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FFields) do
    if UpperCase(FFields[i].Keyword) = UpperCase(AKeyword) then Exit(i);
  Result := -1;
end;

function TSchemaDefinition.Has(const AKeyword: string): Boolean;
begin
  Result := FieldIndex(AKeyword) >= 0;
end;

function TSchemaDefinition.Values(const AKeyword: string): TStringArray;
var
  i: Integer;
begin
  i := FieldIndex(AKeyword);
  if i < 0 then Result := nil else Result := Copy(FFields[i].Values, 0, Length(FFields[i].Values));
end;

function TSchemaDefinition.Value(const AKeyword: string): string;
var
  v: TStringArray;
begin
  v := Values(AKeyword);
  if Length(v) > 0 then Result := v[0] else Result := '';
end;

function TSchemaDefinition.FieldCount: Integer;
begin
  Result := Length(FFields);
end;

function TSchemaDefinition.FieldKeyword(AIndex: Integer): string;
begin
  Result := FFields[AIndex].Keyword;
end;

procedure TSchemaDefinition.Splice(AStart, AEnd: Integer; const AText: string);
begin
  FRaw := Copy(FRaw, 1, AStart - 1) + AText + Copy(FRaw, AEnd, MaxInt);
  Parse;
end;

function OrderIndex(AKind: TDefinitionKind; const AKeyword: string): Integer;
var
  i: Integer;
  k: string;
begin
  k := UpperCase(AKeyword);
  if AKind = dkAttribute then
  begin
    for i := 0 to High(ATTR_ORDER) do
      if ATTR_ORDER[i] = k then Exit(i);
    Result := Length(ATTR_ORDER);
  end
  else
  begin
    for i := 0 to High(CLASS_ORDER) do
      if CLASS_ORDER[i] = k then Exit(i);
    Result := Length(CLASS_ORDER);
  end;
end;

function Segment(const AKeyword: string; AShape: TFieldShape; const AValues: array of string): string;
var
  i: Integer;
begin
  Result := AKeyword;
  case AShape of
    fsFlag: ;
    fsQdstring: Result := Result + ' ' + QuoteQdstring(AValues[0]);
    fsOid, fsWord: Result := Result + ' ' + AValues[0];
    fsQdescrs, fsQdstrings:
      if Length(AValues) = 1 then
        Result := Result + ' ' + QuoteQdstring(AValues[0])
      else
      begin
        Result := Result + ' (';
        for i := 0 to High(AValues) do
          Result := Result + ' ' + QuoteQdstring(AValues[i]);
        Result := Result + ' )';
      end;
    fsOids:
      if Length(AValues) = 1 then
        Result := Result + ' ' + AValues[0]
      else
      begin
        Result := Result + ' (';
        for i := 0 to High(AValues) do
        begin
          if i > 0 then Result := Result + ' $';
          Result := Result + ' ' + AValues[i];
        end;
        Result := Result + ' )';
      end;
  end;
end;

function ValidValues(const AKeyword: string; AShape: TFieldShape; const AValues: array of string;
  out AError: string): Boolean;
var
  i, j: Integer;
  k: string;
begin
  Result := False;
  AError := '';
  k := UpperCase(AKeyword);
  if (AShape <> fsFlag) and (Length(AValues) = 0) then
  begin
    AError := Format(rsSdfEmptyList, [AKeyword]);
    Exit;
  end;
  if (AShape in [fsQdstring, fsOid, fsWord]) and (Length(AValues) <> 1) then
  begin
    AError := Format(rsSdfValue, [AKeyword]);
    Exit;
  end;
  for i := 0 to High(AValues) do
    case AShape of
      fsQdescrs:
        if not IsSchemaDescr(AValues[i]) then
        begin
          AError := Format(rsSdfBadName, [AValues[i]]);
          Exit;
        end;
      fsQdstring, fsQdstrings:
        begin
          if AValues[i] = '' then
          begin
            AError := rsSdfBadText;
            Exit;
          end;
          for j := 1 to Length(AValues[i]) do
            if Ord(AValues[i][j]) < 32 then
            begin
              AError := rsSdfBadText;
              Exit;
            end;
        end;
      fsOid, fsOids:
        if not IsOidOrName(AValues[i]) then
        begin
          AError := Format(rsSdfBadOidOrName, [AValues[i]]);
          Exit;
        end;
      fsWord:
        if k = 'SYNTAX' then
        begin
          if not IsSyntaxText(AValues[i]) then
          begin
            AError := Format(rsSdfBadSyntax, [AValues[i]]);
            Exit;
          end;
        end
        else if k = 'USAGE' then
        begin
          if not ((AValues[i] = 'userApplications') or (AValues[i] = 'directoryOperation') or
            (AValues[i] = 'distributedOperation') or (AValues[i] = 'dSAOperation')) then
          begin
            AError := Format(rsSdfBadUsage, [AValues[i]]);
            Exit;
          end;
        end;
    end;
  Result := True;
end;

function TSchemaDefinition.SetValues(const AKeyword: string; const AValues: array of string;
  out AError: string): Boolean;
var
  shape: TFieldShape;
  i, pos, order: Integer;
  text: string;
begin
  Result := False;
  AError := '';
  if not FEditable then
  begin
    AError := Format(rsSdfNotEditable, [FReason]);
    Exit;
  end;
  if (UpperCase(Copy(AKeyword, 1, 2)) = 'X-') and not IsExtensionKeyword(AKeyword) then
  begin
    AError := Format(rsSdfBadExtension, [AKeyword]);
    Exit;
  end;
  if not KeywordShape(FKind, AKeyword, shape) then
  begin
    AError := Format(rsSdfNotForKind, [AKeyword]);
    Exit;
  end;
  if not ValidValues(AKeyword, shape, AValues, AError) then Exit;
  text := Segment(AKeyword, shape, AValues);
  i := FieldIndex(AKeyword);
  if i >= 0 then
    Splice(FFields[i].StartPos, FFields[i].EndPos, text)
  else
  begin
    order := OrderIndex(FKind, AKeyword);
    pos := -1;
    for i := 0 to High(FFields) do
      if OrderIndex(FKind, FFields[i].Keyword) > order then
      begin
        pos := FFields[i].StartPos;
        Break;
      end;
    if pos < 0 then
    begin
      pos := Length(FRaw);
      while (pos > 1) and (FRaw[pos] <> ')') do Dec(pos);
      Splice(pos, pos, text + ' ');
    end
    else
      Splice(pos, pos, text + ' ');
  end;
  Result := FEditable;
  if not Result then AError := FReason;
end;

function TSchemaDefinition.SetValue(const AKeyword, AValue: string; out AError: string): Boolean;
begin
  Result := SetValues(AKeyword, [AValue], AError);
end;

function TSchemaDefinition.SetFlag(const AKeyword: string; AOn: Boolean; out AError: string): Boolean;
var
  shape: TFieldShape;
begin
  AError := '';
  if not KeywordShape(FKind, AKeyword, shape) or (shape <> fsFlag) then
  begin
    AError := Format(rsSdfNotForKind, [AKeyword]);
    Exit(False);
  end;
  if AOn then
  begin
    if Has(AKeyword) then Exit(True);
    Result := SetValues(AKeyword, [], AError);
  end
  else
  begin
    if not Has(AKeyword) then Exit(True);
    Result := Remove(AKeyword, AError);
  end;
end;

function TSchemaDefinition.SetClassKind(const AKeyword: string; out AError: string): Boolean;
var
  k: string;
  i: Integer;
begin
  k := UpperCase(AKeyword);
  if (FKind <> dkClass) or not ((k = 'ABSTRACT') or (k = 'STRUCTURAL') or (k = 'AUXILIARY')) then
  begin
    AError := Format(rsSdfNotForKind, [AKeyword]);
    Exit(False);
  end;
  for i := 0 to High(FFields) do
    if (UpperCase(FFields[i].Keyword) = 'ABSTRACT') or (UpperCase(FFields[i].Keyword) = 'STRUCTURAL') or
       (UpperCase(FFields[i].Keyword) = 'AUXILIARY') then
    begin
      if UpperCase(FFields[i].Keyword) = k then Exit(True);
      if not FEditable then
      begin
        AError := Format(rsSdfNotEditable, [FReason]);
        Exit(False);
      end;
      Splice(FFields[i].StartPos, FFields[i].EndPos, k);
      AError := FReason;
      Exit(FEditable);
    end;
  Result := SetFlag(k, True, AError);
end;

function TSchemaDefinition.Remove(const AKeyword: string; out AError: string): Boolean;
var
  i, s, e: Integer;
begin
  AError := '';
  if not FEditable then
  begin
    AError := Format(rsSdfNotEditable, [FReason]);
    Exit(False);
  end;
  i := FieldIndex(AKeyword);
  if i < 0 then Exit(True);
  s := FFields[i].StartPos;
  e := FFields[i].EndPos;
  while (e <= Length(FRaw)) and (FRaw[e] in [' ', #9]) do Inc(e);
  Splice(s, e, '');
  Result := FEditable;
  if not Result then AError := FReason;
end;

function TSchemaDefinition.SetOid(const AOid: string; out AError: string): Boolean;
begin
  AError := '';
  if not IsNumericOidText(AOid) then
  begin
    AError := Format(rsSdfBadOid, [AOid]);
    Exit(False);
  end;
  if not FEditable then
  begin
    AError := Format(rsSdfNotEditable, [FReason]);
    Exit(False);
  end;
  Splice(FOidStart, FOidEnd, AOid);
  Result := FEditable;
end;

function SameDefinitionExcept(A, B: TSchemaDefinition; const AIgnore: array of string): Boolean;

  function Ignored(const K: string): Boolean;
  var
    i: Integer;
  begin
    for i := 0 to High(AIgnore) do
      if UpperCase(AIgnore[i]) = UpperCase(K) then Exit(True);
    Result := False;
  end;

  function Covered(X, Y: TSchemaDefinition): Boolean;
  var
    i, j: Integer;
    vx, vy: TStringArray;
  begin
    Result := False;
    for i := 0 to X.FieldCount - 1 do
    begin
      if Ignored(X.FieldKeyword(i)) then Continue;
      if not Y.Has(X.FieldKeyword(i)) then Exit;
      vx := X.Values(X.FieldKeyword(i));
      vy := Y.Values(X.FieldKeyword(i));
      if Length(vx) <> Length(vy) then Exit;
      for j := 0 to High(vx) do
        if vx[j] <> vy[j] then Exit;
    end;
    Result := True;
  end;

begin
  Result := (A.Kind = B.Kind) and (A.Oid = B.Oid) and Covered(A, B) and Covered(B, A);
end;

end.
