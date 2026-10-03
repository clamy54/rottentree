// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdapFilter;

{$mode objfpc}{$H+}

// Filtres de recherche RFC 4515: arbre, analyse bornee, serialisation.
// L'echappement des filtres n'est PAS celui des DN (RFC 4514). Les melanger, c'est offrir
// une injection au premier nom de famille qui contient une parenthese.

interface

uses
  SysUtils;

const
  FILTER_MAX_DEPTH = 64;
  FILTER_MAX_CHARS = 256 * 1024;
  FILTER_MAX_NODES = 4096;

type
  TFilterKind = (fkAnd, fkOr, fkNot, fkEquality, fkSubstrings, fkGreaterOrEqual,
    fkLessOrEqual, fkPresent, fkApprox, fkExtensible);

  TFilterNode = class
  private
    FChildren: array of TFilterNode;
    function GetChild(AIndex: Integer): TFilterNode;
  public
    Kind: TFilterKind;
    Attr: string;
    Value: RawByteString;
    SubInitial: RawByteString;
    HasInitial: Boolean;
    SubAny: array of RawByteString;
    SubFinal: RawByteString;
    HasFinal: Boolean;
    MatchingRule: string;
    DnAttributes: Boolean;
    destructor Destroy; override;
    procedure AddChild(ANode: TFilterNode);
    procedure InsertChild(AIndex: Integer; ANode: TFilterNode);
    function ExtractChild(AIndex: Integer): TFilterNode;
    function ReplaceChild(AIndex: Integer; ANode: TFilterNode): TFilterNode;
    function IndexOfChild(ANode: TFilterNode): Integer;
    function ChildCount: Integer;
    property Children[AIndex: Integer]: TFilterNode read GetChild;
    function Clone: TFilterNode;
  end;

  EFilterError = class(Exception);

// Echappe *, (, ), \, NUL, controles et octets non UTF-8 en \XX: une valeur saisie ne
// reecrit pas le filtre qui la contient.
function FilterEscapeValue(const AValue: RawByteString): string;

function FilterParse(const S: string; out AError: string;
  AAllowBare: Boolean = False): TFilterNode;
function FilterToString(ANode: TFilterNode): string;
function FilterDepth(ANode: TFilterNode): Integer;

function FltEq(const AAttr: string; const AValue: RawByteString): TFilterNode;
function FltPresent(const AAttr: string): TFilterNode;
function FltGe(const AAttr: string; const AValue: RawByteString): TFilterNode;
function FltLe(const AAttr: string; const AValue: RawByteString): TFilterNode;
function FltApprox(const AAttr: string; const AValue: RawByteString): TFilterNode;
function FltSubstr(const AAttr: string; AHasInitial: Boolean;
  const AInitial: RawByteString; const AAny: array of RawByteString;
  AHasFinal: Boolean; const AFinal: RawByteString): TFilterNode;
function FltExt(const AAttr, ARule: string; ADnAttrs: Boolean;
  const AValue: RawByteString): TFilterNode;
function FltAnd(const AItems: array of TFilterNode): TFilterNode;
function FltOr(const AItems: array of TFilterNode): TFilterNode;
function FltNot(AItem: TFilterNode): TFilterNode;

function IsValidAttributeDescription(const S: string): Boolean;

implementation

uses
  uRtBytes, uLdapDn;

destructor TFilterNode.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FChildren) do
    FChildren[i].Free;
  inherited Destroy;
end;

procedure TFilterNode.AddChild(ANode: TFilterNode);
begin
  SetLength(FChildren, Length(FChildren) + 1);
  FChildren[High(FChildren)] := ANode;
end;

procedure TFilterNode.InsertChild(AIndex: Integer; ANode: TFilterNode);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex > Length(FChildren)) then
    raise EFilterError.Create('child index out of range');
  SetLength(FChildren, Length(FChildren) + 1);
  for i := High(FChildren) downto AIndex + 1 do
    FChildren[i] := FChildren[i - 1];
  FChildren[AIndex] := ANode;
end;

function TFilterNode.ExtractChild(AIndex: Integer): TFilterNode;
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FChildren)) then
    raise EFilterError.Create('child index out of range');
  Result := FChildren[AIndex];
  for i := AIndex to High(FChildren) - 1 do
    FChildren[i] := FChildren[i + 1];
  SetLength(FChildren, Length(FChildren) - 1);
end;

function TFilterNode.ReplaceChild(AIndex: Integer; ANode: TFilterNode): TFilterNode;
begin
  if (AIndex < 0) or (AIndex > High(FChildren)) then
    raise EFilterError.Create('child index out of range');
  Result := FChildren[AIndex];
  FChildren[AIndex] := ANode;
end;

function TFilterNode.IndexOfChild(ANode: TFilterNode): Integer;
begin
  for Result := 0 to High(FChildren) do
    if FChildren[Result] = ANode then Exit;
  Result := -1;
end;

function TFilterNode.ChildCount: Integer;
begin
  Result := Length(FChildren);
end;

function TFilterNode.GetChild(AIndex: Integer): TFilterNode;
begin
  Result := FChildren[AIndex];
end;

function TFilterNode.Clone: TFilterNode;
var
  i: Integer;
begin
  Result := TFilterNode.Create;
  Result.Kind := Kind;
  Result.Attr := Attr;
  Result.Value := Value;
  Result.SubInitial := SubInitial;
  Result.HasInitial := HasInitial;
  Result.SubAny := Copy(SubAny);
  Result.SubFinal := SubFinal;
  Result.HasFinal := HasFinal;
  Result.MatchingRule := MatchingRule;
  Result.DnAttributes := DnAttributes;
  for i := 0 to High(FChildren) do
    Result.AddChild(FChildren[i].Clone);
end;

function FilterEscapeValue(const AValue: RawByteString): string;
var
  i: Integer;
  c: Char;
  utf8: Boolean;
begin
  Result := '';
  utf8 := IsValidUtf8(AValue);
  for i := 1 to Length(AValue) do
  begin
    c := AValue[i];
    if (c in ['*', '(', ')', '\', #0]) or (Byte(c) < 32) or (Byte(c) = 127) or
       ((not utf8) and (Byte(c) >= $80)) then
      Result := Result + '\' + HexEncode(c)
    else
      Result := Result + c;
  end;
end;

function IsKeyChar(C: Char): Boolean; inline;
begin
  Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '-'];
end;

function IsValidAttributeDescription(const S: string): Boolean;
var
  parts: TStringArray;
  i, j: Integer;
begin
  Result := False;
  if S = '' then Exit;
  parts := S.Split([';']);
  if not (IsDescr(parts[0]) or IsNumericOid(parts[0])) then Exit;
  for i := 1 to High(parts) do
  begin
    if parts[i] = '' then Exit;
    for j := 1 to Length(parts[i]) do
      if not IsKeyChar(parts[i][j]) then Exit;
  end;
  Result := True;
end;

function NewNode(AKind: TFilterKind; const AAttr: string): TFilterNode;
begin
  Result := TFilterNode.Create;
  Result.Kind := AKind;
  Result.Attr := AAttr;
end;

function FltEq(const AAttr: string; const AValue: RawByteString): TFilterNode;
begin
  Result := NewNode(fkEquality, AAttr);
  Result.Value := AValue;
end;

function FltPresent(const AAttr: string): TFilterNode;
begin
  Result := NewNode(fkPresent, AAttr);
end;

function FltGe(const AAttr: string; const AValue: RawByteString): TFilterNode;
begin
  Result := NewNode(fkGreaterOrEqual, AAttr);
  Result.Value := AValue;
end;

function FltLe(const AAttr: string; const AValue: RawByteString): TFilterNode;
begin
  Result := NewNode(fkLessOrEqual, AAttr);
  Result.Value := AValue;
end;

function FltApprox(const AAttr: string; const AValue: RawByteString): TFilterNode;
begin
  Result := NewNode(fkApprox, AAttr);
  Result.Value := AValue;
end;

function FltSubstr(const AAttr: string; AHasInitial: Boolean;
  const AInitial: RawByteString; const AAny: array of RawByteString;
  AHasFinal: Boolean; const AFinal: RawByteString): TFilterNode;
var
  i: Integer;
begin
  Result := NewNode(fkSubstrings, AAttr);
  Result.HasInitial := AHasInitial;
  Result.SubInitial := AInitial;
  SetLength(Result.SubAny, Length(AAny));
  for i := 0 to High(AAny) do
    Result.SubAny[i] := AAny[i];
  Result.HasFinal := AHasFinal;
  Result.SubFinal := AFinal;
end;

function FltExt(const AAttr, ARule: string; ADnAttrs: Boolean;
  const AValue: RawByteString): TFilterNode;
begin
  Result := NewNode(fkExtensible, AAttr);
  Result.MatchingRule := ARule;
  Result.DnAttributes := ADnAttrs;
  Result.Value := AValue;
end;

function FltAnd(const AItems: array of TFilterNode): TFilterNode;
var
  i: Integer;
begin
  Result := NewNode(fkAnd, '');
  for i := 0 to High(AItems) do
    Result.AddChild(AItems[i]);
end;

function FltOr(const AItems: array of TFilterNode): TFilterNode;
var
  i: Integer;
begin
  Result := NewNode(fkOr, '');
  for i := 0 to High(AItems) do
    Result.AddChild(AItems[i]);
end;

function FltNot(AItem: TFilterNode): TFilterNode;
begin
  Result := NewNode(fkNot, '');
  Result.AddChild(AItem);
end;

function FilterToString(ANode: TFilterNode): string;
var
  i: Integer;
begin
  if ANode = nil then Exit('');
  case ANode.Kind of
    fkAnd, fkOr:
      begin
        if ANode.Kind = fkAnd then Result := '(&' else Result := '(|';
        for i := 0 to ANode.ChildCount - 1 do
          Result := Result + FilterToString(ANode.Children[i]);
        Result := Result + ')';
      end;
    fkNot:
      Result := '(!' + FilterToString(ANode.Children[0]) + ')';
    fkEquality:
      Result := '(' + ANode.Attr + '=' + FilterEscapeValue(ANode.Value) + ')';
    fkGreaterOrEqual:
      Result := '(' + ANode.Attr + '>=' + FilterEscapeValue(ANode.Value) + ')';
    fkLessOrEqual:
      Result := '(' + ANode.Attr + '<=' + FilterEscapeValue(ANode.Value) + ')';
    fkApprox:
      Result := '(' + ANode.Attr + '~=' + FilterEscapeValue(ANode.Value) + ')';
    fkPresent:
      Result := '(' + ANode.Attr + '=*)';
    fkSubstrings:
      begin
        Result := '(' + ANode.Attr + '=';
        if ANode.HasInitial then
          Result := Result + FilterEscapeValue(ANode.SubInitial);
        Result := Result + '*';
        for i := 0 to High(ANode.SubAny) do
          Result := Result + FilterEscapeValue(ANode.SubAny[i]) + '*';
        if ANode.HasFinal then
          Result := Result + FilterEscapeValue(ANode.SubFinal);
        Result := Result + ')';
      end;
    fkExtensible:
      begin
        Result := '(' + ANode.Attr;
        if ANode.DnAttributes then Result := Result + ':dn';
        if ANode.MatchingRule <> '' then Result := Result + ':' + ANode.MatchingRule;
        Result := Result + ':=' + FilterEscapeValue(ANode.Value) + ')';
      end;
  end;
end;

function FilterDepth(ANode: TFilterNode): Integer;
var
  i, d: Integer;
begin
  Result := 1;
  if ANode = nil then Exit(0);
  for i := 0 to ANode.ChildCount - 1 do
  begin
    d := 1 + FilterDepth(ANode.Children[i]);
    if d > Result then Result := d;
  end;
end;

type
  TFilterParser = class
  private
    FS: string;
    FP: Integer;
    FNodes: Integer;
    procedure Error(const AMsg: string);
    function Peek: Char;
    function ParseFilter(ADepth: Integer): TFilterNode;
    function ParseItem: TFilterNode;
    function ReadValueUntil(const AStops: TSysCharSet; out AValue: RawByteString): Boolean;
  public
    constructor Create(const S: string);
    function Parse: TFilterNode;
  end;

constructor TFilterParser.Create(const S: string);
begin
  inherited Create;
  FS := S;
  FP := 1;
end;

procedure TFilterParser.Error(const AMsg: string);
begin
  raise EFilterError.CreateFmt('%s (position %d)', [AMsg, FP]);
end;

function TFilterParser.Peek: Char;
begin
  if FP <= Length(FS) then
    Result := FS[FP]
  else
    Result := #0;
end;

function TFilterParser.Parse: TFilterNode;
begin
  Result := ParseFilter(1);
  if FP <= Length(FS) then
  begin
    Result.Free;
    Error('unexpected characters after filter');
  end;
end;

function TFilterParser.ParseFilter(ADepth: Integer): TFilterNode;
var
  c: Char;
begin
  if ADepth > FILTER_MAX_DEPTH then
    Error('filter nested too deeply');
  Inc(FNodes);
  if FNodes > FILTER_MAX_NODES then
    Error('filter too large');
  if Peek <> '(' then
    Error('"(" expected');
  Inc(FP);
  c := Peek;
  Result := nil;
  try
    case c of
      '&', '|':
        begin
          if c = '&' then
            Result := NewNode(fkAnd, '')
          else
            Result := NewNode(fkOr, '');
          Inc(FP);
          // Ensemble vide admis par la RFC 4526: (&) vaut vrai, (|) vaut faux. Deroutant,
          // mais legal.
          while Peek = '(' do
            Result.AddChild(ParseFilter(ADepth + 1));
        end;
      '!':
        begin
          Result := NewNode(fkNot, '');
          Inc(FP);
          Result.AddChild(ParseFilter(ADepth + 1));
        end;
    else
      Result := ParseItem;
    end;
    if Peek <> ')' then
      Error('")" expected');
    Inc(FP);
  except
    Result.Free;
    raise;
  end;
end;

function TFilterParser.ReadValueUntil(const AStops: TSysCharSet;
  out AValue: RawByteString): Boolean;
var
  c: Char;
  hex: RawByteString;
begin
  AValue := '';
  while FP <= Length(FS) do
  begin
    c := FS[FP];
    if c in AStops then Exit(True);
    if c = '(' then Error('unescaped "(" in value');
    if c = #0 then Error('NUL in filter text');
    if c = '\' then
    begin
      if (FP + 2 > Length(FS)) or not HexDecode(Copy(FS, FP + 1, 2), hex) then
        Error('invalid escape in value');
      AValue := AValue + hex;
      Inc(FP, 3);
      Continue;
    end;
    AValue := AValue + c;
    Inc(FP);
  end;
  Result := False;
end;

function TFilterParser.ParseItem: TFilterNode;
var
  start: Integer;
  lhs, attr, rule: string;
  dnAttrs: Boolean;
  parts: TStringArray;
  i: Integer;
  v: RawByteString;
  pieces: array of RawByteString;
  op: string;
begin
  start := FP;
  while (FP <= Length(FS)) and not (FS[FP] in ['=', '~', '<', '>', '(', ')']) do
    Inc(FP);
  lhs := Copy(FS, start, FP - start);
  if FP > Length(FS) then Error('operator expected');
  op := '';
  case FS[FP] of
    '=': op := '=';
    '~', '<', '>':
      begin
        if (FP + 1 > Length(FS)) or (FS[FP + 1] <> '=') then
          Error('invalid operator');
        op := FS[FP] + '=';
      end;
  else
    Error('operator expected');
  end;
  if (op = '=') and (lhs <> '') and (lhs[Length(lhs)] = ':') then
  begin
    Inc(FP);
    parts := Copy(lhs, 1, Length(lhs) - 1).Split([':']);
    attr := parts[0];
    dnAttrs := False;
    rule := '';
    for i := 1 to High(parts) do
    begin
      if SameText(parts[i], 'dn') and (i = 1) and not dnAttrs then
        dnAttrs := True
      else if (rule = '') and (IsNumericOid(parts[i]) or IsDescr(parts[i])) and
              (i = High(parts)) then
        rule := parts[i]
      else
        Error('invalid extensible match');
    end;
    if (attr <> '') and not IsValidAttributeDescription(attr) then
      Error('invalid attribute description');
    if (attr = '') and (rule = '') then
      Error('extensible match needs a type or a matching rule');
    ReadValueUntil([')'], v);
    Exit(FltExt(attr, rule, dnAttrs, v));
  end;
  if not IsValidAttributeDescription(lhs) then
    Error('invalid attribute description');
  Inc(FP, Length(op));
  if op = '>=' then
  begin
    ReadValueUntil([')'], v);
    Exit(FltGe(lhs, v));
  end;
  if op = '<=' then
  begin
    ReadValueUntil([')'], v);
    Exit(FltLe(lhs, v));
  end;
  if op = '~=' then
  begin
    ReadValueUntil([')'], v);
    Exit(FltApprox(lhs, v));
  end;
  pieces := nil;
  while True do
  begin
    ReadValueUntil([')', '*'], v);
    SetLength(pieces, Length(pieces) + 1);
    pieces[High(pieces)] := v;
    if Peek = '*' then
    begin
      Inc(FP);
      Continue;
    end;
    Break;
  end;
  if Length(pieces) = 1 then
    Exit(FltEq(lhs, pieces[0]));
  if (Length(pieces) = 2) and (pieces[0] = '') and (pieces[1] = '') then
    Exit(FltPresent(lhs));
  Result := NewNode(fkSubstrings, lhs);
  Result.HasInitial := pieces[0] <> '';
  Result.SubInitial := pieces[0];
  Result.HasFinal := pieces[High(pieces)] <> '';
  Result.SubFinal := pieces[High(pieces)];
  for i := 1 to High(pieces) - 1 do
  begin
    if pieces[i] = '' then
    begin
      Result.Free;
      Error('empty substring component');
    end;
    SetLength(Result.SubAny, Length(Result.SubAny) + 1);
    Result.SubAny[High(Result.SubAny)] := pieces[i];
  end;
end;

function FilterParse(const S: string; out AError: string;
  AAllowBare: Boolean): TFilterNode;
var
  p: TFilterParser;
  txt: string;
begin
  Result := nil;
  AError := '';
  txt := Trim(S);
  if Length(txt) > FILTER_MAX_CHARS then
  begin
    AError := 'filter too long';
    Exit;
  end;
  if txt = '' then
  begin
    AError := 'empty filter';
    Exit;
  end;
  if AAllowBare and (txt[1] <> '(') then
    txt := '(' + txt + ')';
  p := TFilterParser.Create(txt);
  try
    try
      Result := p.Parse;
    except
      on E: EFilterError do
      begin
        AError := E.Message;
        Result := nil;
      end;
    end;
  finally
    p.Free;
  end;
end;

end.
