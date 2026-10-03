// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uFilterBuilder;

{$mode objfpc}{$H+}

// Constructeur graphique de filtres RFC 4515. La valeur saisie est toujours
// litterale: '*' et parentheses sont echappes, jamais interpretes. Seul
// "matches pattern" lit '*' comme joker, et il le dit. L'injection LDAP, ce
// sera pour un autre outil.

interface

uses
  SysUtils, uLdapFilter;

type
  TFilterOp = (
    foEquals,
    foNotEquals,
    foStartsWith,
    foEndsWith,
    foContains,
    foPattern,
    foPresent,
    foAbsent,
    foGreaterOrEqual,
    foLessOrEqual,
    foApprox,
    foExtensible
  );

  TFilterCondition = record
    Attr: string;
    Op: TFilterOp;
    Value: RawByteString;
    MatchingRule: string;
    DnAttributes: Boolean;
  end;

const
  FILTER_OP_NAMES: array[TFilterOp] of string = ('equals', 'differs from', 'starts with',
    'ends with', 'contains', 'matches pattern (* = any)', 'is present', 'is absent',
    '>=', '<=', 'approximately (~=)', 'extensible match');

function ConditionToNode(const C: TFilterCondition; out AError: string): TFilterNode;
function NodeToCondition(ANode: TFilterNode; out C: TFilterCondition): Boolean;
function IsConditionNode(ANode: TFilterNode): Boolean;
function FilterNodeCaption(ANode: TFilterNode): string;
function DefaultCondition: TFilterCondition;

function FindParent(ARoot, ANode: TFilterNode; out AIndex: Integer): TFilterNode;
procedure BuilderAdd(var ARoot: TFilterNode; ATarget, ANew: TFilterNode);
procedure BuilderAddAfter(var ARoot: TFilterNode; ATarget, ANew: TFilterNode);
function BuilderWrap(var ARoot: TFilterNode; ANode: TFilterNode; AOr: Boolean): TFilterNode;
function BuilderClone(ANode: TFilterNode): TFilterNode;
procedure BuilderDelete(var ARoot: TFilterNode; ANode: TFilterNode);
procedure BuilderReplace(var ARoot: TFilterNode; AOld, ANew: TFilterNode);
function BuilderToggleNot(var ARoot: TFilterNode; ANode: TFilterNode): TFilterNode;
function BuilderToggleAndOr(ANode: TFilterNode): Boolean;
function BuilderMove(ARoot, ANode: TFilterNode; ADelta: Integer): Boolean;
function BuilderProblem(ARoot: TFilterNode): string;
function FilterInWords(ANode: TFilterNode; AMaxLen: Integer = 600): string;

resourcestring
  rsFbNoAttr = 'choose an attribute';
  rsFbBadAttr = '"%s" is not a valid attribute description';
  rsFbBadRule = '"%s" is not a valid matching rule (name or numeric OID)';
  rsFbExtNeeds = 'an extensible match needs an attribute or a matching rule';
  rsFbEmptyPattern = 'the pattern needs at least one "*"';
  rsFbEmpty = 'the filter is empty: add a condition';
  rsFbEmptyGroup = 'a group has no condition';
  rsFbTooDeep = 'the filter is nested deeper than %d levels';
  rsFbTooLarge = 'the filter has more than %d elements';
  rsFbAnd = 'AND (all of)';
  rsFbOr = 'OR (any of)';
  rsFbNot = 'NOT';
  rsFbRaw = 'expression %s';
  rsFbWordAnd = ' and ';
  rsFbWordOr = ' or ';
  rsFbWordNot = 'not ';
  rsFbWordAll = 'everything';
  rsFbWordNothing = 'nothing';

implementation

uses
  uLdapDn, uRtBytes;

function DefaultCondition: TFilterCondition;
begin
  Result := Default(TFilterCondition);
  Result.Attr := 'cn';
  Result.Op := foEquals;
end;

function ConditionToNode(const C: TFilterCondition; out AError: string): TFilterNode;
var
  attr: string;
  parts: TStringArray;
  i: Integer;
  anys: array of RawByteString;
begin
  Result := nil;
  AError := '';
  attr := Trim(C.Attr);
  if C.Op = foExtensible then
  begin
    if (attr = '') and (Trim(C.MatchingRule) = '') then
    begin
      AError := rsFbExtNeeds;
      Exit;
    end;
    if (Trim(C.MatchingRule) <> '') and not (IsNumericOid(Trim(C.MatchingRule)) or
       IsDescr(Trim(C.MatchingRule))) then
    begin
      AError := Format(rsFbBadRule, [C.MatchingRule]);
      Exit;
    end;
  end
  else if attr = '' then
  begin
    AError := rsFbNoAttr;
    Exit;
  end;
  if (attr <> '') and not IsValidAttributeDescription(attr) then
  begin
    AError := Format(rsFbBadAttr, [attr]);
    Exit;
  end;
  case C.Op of
    foEquals: Result := FltEq(attr, C.Value);
    foNotEquals: Result := FltNot(FltEq(attr, C.Value));
    foStartsWith: Result := FltSubstr(attr, True, C.Value, [], False, '');
    foEndsWith: Result := FltSubstr(attr, False, '', [], True, C.Value);
    foContains: Result := FltSubstr(attr, False, '', [C.Value], False, '');
    foPattern:
      begin
        if Pos('*', C.Value) = 0 then
        begin
          AError := rsFbEmptyPattern;
          Exit;
        end;
        parts := string(C.Value).Split(['*']);
        anys := nil;
        for i := 1 to High(parts) - 1 do
          if parts[i] <> '' then
          begin
            SetLength(anys, Length(anys) + 1);
            anys[High(anys)] := parts[i];
          end;
        if (parts[0] = '') and (parts[High(parts)] = '') and (Length(anys) = 0) then
          Result := FltPresent(attr)
        else
          Result := FltSubstr(attr, parts[0] <> '', parts[0], anys, parts[High(parts)] <> '',
            parts[High(parts)]);
      end;
    foPresent: Result := FltPresent(attr);
    foAbsent: Result := FltNot(FltPresent(attr));
    foGreaterOrEqual: Result := FltGe(attr, C.Value);
    foLessOrEqual: Result := FltLe(attr, C.Value);
    foApprox: Result := FltApprox(attr, C.Value);
    foExtensible: Result := FltExt(attr, Trim(C.MatchingRule), C.DnAttributes, C.Value);
  end;
end;

function NodeToCondition(ANode: TFilterNode; out C: TFilterCondition): Boolean;
var
  child: TFilterNode;
  i: Integer;
  v: RawByteString;
begin
  Result := False;
  C := Default(TFilterCondition);
  if ANode = nil then Exit;
  C.Attr := ANode.Attr;
  case ANode.Kind of
    fkEquality: begin C.Op := foEquals; C.Value := ANode.Value; end;
    fkGreaterOrEqual: begin C.Op := foGreaterOrEqual; C.Value := ANode.Value; end;
    fkLessOrEqual: begin C.Op := foLessOrEqual; C.Value := ANode.Value; end;
    fkApprox: begin C.Op := foApprox; C.Value := ANode.Value; end;
    fkPresent: C.Op := foPresent;
    fkExtensible:
      begin
        C.Op := foExtensible;
        C.Value := ANode.Value;
        C.MatchingRule := ANode.MatchingRule;
        C.DnAttributes := ANode.DnAttributes;
      end;
    fkSubstrings:
      begin
        if ANode.HasInitial and not ANode.HasFinal and (Length(ANode.SubAny) = 0) then
        begin
          C.Op := foStartsWith;
          C.Value := ANode.SubInitial;
        end
        else if ANode.HasFinal and not ANode.HasInitial and (Length(ANode.SubAny) = 0) then
        begin
          C.Op := foEndsWith;
          C.Value := ANode.SubFinal;
        end
        else if not ANode.HasInitial and not ANode.HasFinal and (Length(ANode.SubAny) = 1) then
        begin
          C.Op := foContains;
          C.Value := ANode.SubAny[0];
        end
        else
        begin
          // Un '*' litteral dans un morceau rendrait le motif ambigu: on ne le relit pas.
          if (Pos('*', ANode.SubInitial) > 0) or (Pos('*', ANode.SubFinal) > 0) then Exit;
          for i := 0 to High(ANode.SubAny) do
            if Pos('*', ANode.SubAny[i]) > 0 then Exit;
          v := '';
          if ANode.HasInitial then v := ANode.SubInitial;
          v := v + '*';
          for i := 0 to High(ANode.SubAny) do
            v := v + ANode.SubAny[i] + '*';
          if ANode.HasFinal then v := v + ANode.SubFinal;
          C.Op := foPattern;
          C.Value := v;
        end;
      end;
    fkNot:
      begin
        if ANode.ChildCount <> 1 then Exit;
        child := ANode.Children[0];
        C.Attr := child.Attr;
        if child.Kind = fkEquality then
        begin
          C.Op := foNotEquals;
          C.Value := child.Value;
        end
        else if child.Kind = fkPresent then
          C.Op := foAbsent
        else
          Exit;
      end;
  else
    Exit;
  end;
  Result := True;
end;

function IsConditionNode(ANode: TFilterNode): Boolean;
var
  c: TFilterCondition;
begin
  Result := NodeToCondition(ANode, c);
end;

function ValueCaption(const V: RawByteString): string;
begin
  if not IsValidUtf8(V) then Exit('[' + IntToStr(Length(V)) + ' bytes]');
  Result := '"' + EscapeControlChars(V) + '"';
end;

function FilterNodeCaption(ANode: TFilterNode): string;
var
  c: TFilterCondition;
begin
  Result := '';
  if ANode = nil then Exit;
  case ANode.Kind of
    fkAnd: Exit(rsFbAnd);
    fkOr: Exit(rsFbOr);
  end;
  if not NodeToCondition(ANode, c) then
  begin
    if ANode.Kind = fkNot then Exit(rsFbNot);
    Exit(Format(rsFbRaw, [FilterToString(ANode)]));
  end;
  case c.Op of
    foPresent, foAbsent:
      Result := c.Attr + ' ' + FILTER_OP_NAMES[c.Op];
    foExtensible:
      begin
        Result := c.Attr;
        if c.DnAttributes then Result := Result + ':dn';
        if c.MatchingRule <> '' then Result := Result + ':' + c.MatchingRule;
        Result := Result + ' := ' + ValueCaption(c.Value);
      end;
    foPattern:
      Result := c.Attr + ' matches ' + ValueCaption(c.Value);
  else
    Result := c.Attr + ' ' + FILTER_OP_NAMES[c.Op] + ' ' + ValueCaption(c.Value);
  end;
end;

function FindParent(ARoot, ANode: TFilterNode; out AIndex: Integer): TFilterNode;
var
  i: Integer;
begin
  Result := nil;
  AIndex := -1;
  if (ARoot = nil) or (ANode = nil) or (ARoot = ANode) then Exit;
  for i := 0 to ARoot.ChildCount - 1 do
  begin
    if ARoot.Children[i] = ANode then
    begin
      AIndex := i;
      Exit(ARoot);
    end;
    Result := FindParent(ARoot.Children[i], ANode, AIndex);
    if Result <> nil then Exit;
  end;
end;

function IsGroup(ANode: TFilterNode): Boolean;
begin
  Result := (ANode <> nil) and (ANode.Kind in [fkAnd, fkOr]);
end;

procedure BuilderAdd(var ARoot: TFilterNode; ATarget, ANew: TFilterNode);
begin
  if ARoot = nil then
  begin
    ARoot := ANew;
    Exit;
  end;
  if IsGroup(ATarget) then
  begin
    ATarget.AddChild(ANew);
    Exit;
  end;
  BuilderAddAfter(ARoot, ATarget, ANew);
end;

procedure BuilderAddAfter(var ARoot: TFilterNode; ATarget, ANew: TFilterNode);
var
  parent: TFilterNode;
  idx: Integer;
begin
  if ARoot = nil then
  begin
    ARoot := ANew;
    Exit;
  end;
  if ATarget = ARoot then
  begin
    ARoot := FltAnd([ARoot, ANew]);
    Exit;
  end;
  parent := FindParent(ARoot, ATarget, idx);
  while (parent <> nil) and not IsGroup(parent) do
  begin
    ATarget := parent;
    parent := FindParent(ARoot, ATarget, idx);
  end;
  if parent <> nil then
  begin
    parent.InsertChild(idx + 1, ANew);
    Exit;
  end;
  if IsGroup(ARoot) then
  begin
    ARoot.AddChild(ANew);
    Exit;
  end;
  ARoot := FltAnd([ARoot, ANew]);
end;

function BuilderWrap(var ARoot: TFilterNode; ANode: TFilterNode; AOr: Boolean): TFilterNode;
var
  parent: TFilterNode;
  idx: Integer;
begin
  Result := nil;
  if (ARoot = nil) or (ANode = nil) then Exit;
  if ANode = ARoot then
  begin
    if AOr then ARoot := FltOr([ANode]) else ARoot := FltAnd([ANode]);
    Exit(ARoot);
  end;
  parent := FindParent(ARoot, ANode, idx);
  if parent = nil then Exit;
  parent.ExtractChild(idx);
  if AOr then Result := FltOr([ANode]) else Result := FltAnd([ANode]);
  parent.InsertChild(idx, Result);
end;

function BuilderClone(ANode: TFilterNode): TFilterNode;
var
  err: string;
begin
  Result := nil;
  if ANode = nil then Exit;
  Result := FilterParse(FilterToString(ANode), err);
end;

procedure BuilderDelete(var ARoot: TFilterNode; ANode: TFilterNode);
var
  parent: TFilterNode;
  idx: Integer;
begin
  if (ARoot = nil) or (ANode = nil) then Exit;
  if ANode = ARoot then
  begin
    FreeAndNil(ARoot);
    Exit;
  end;
  parent := FindParent(ARoot, ANode, idx);
  if parent = nil then Exit;
  if (parent.Kind = fkNot) and (parent.ChildCount = 1) then
  begin
    BuilderDelete(ARoot, parent);
    Exit;
  end;
  parent.ExtractChild(idx).Free;
end;

procedure BuilderReplace(var ARoot: TFilterNode; AOld, ANew: TFilterNode);
var
  parent: TFilterNode;
  idx: Integer;
begin
  if AOld = ARoot then
  begin
    ARoot := ANew;
    AOld.Free;
    Exit;
  end;
  parent := FindParent(ARoot, AOld, idx);
  if parent = nil then
  begin
    ANew.Free;
    Exit;
  end;
  parent.ReplaceChild(idx, ANew).Free;
end;

function BuilderToggleNot(var ARoot: TFilterNode; ANode: TFilterNode): TFilterNode;
var
  parent, child: TFilterNode;
  idx: Integer;
begin
  Result := ANode;
  if ANode = nil then Exit;
  parent := FindParent(ARoot, ANode, idx);
  if (ANode.Kind = fkNot) and (ANode.ChildCount = 1) then
  begin
    child := ANode.ExtractChild(0);
    if parent = nil then ARoot := child else parent.ReplaceChild(idx, child);
    ANode.Free;
    Exit(child);
  end;
  if parent = nil then
  begin
    ARoot := FltNot(ANode);
    Exit(ARoot);
  end;
  parent.ExtractChild(idx);
  Result := FltNot(ANode);
  parent.InsertChild(idx, Result);
end;

function BuilderToggleAndOr(ANode: TFilterNode): Boolean;
begin
  Result := IsGroup(ANode);
  if not Result then Exit;
  if ANode.Kind = fkAnd then ANode.Kind := fkOr else ANode.Kind := fkAnd;
end;

function BuilderMove(ARoot, ANode: TFilterNode; ADelta: Integer): Boolean;
var
  parent, n: TFilterNode;
  idx, target: Integer;
begin
  Result := False;
  parent := FindParent(ARoot, ANode, idx);
  if parent = nil then Exit;
  target := idx + ADelta;
  if (target < 0) or (target >= parent.ChildCount) then Exit;
  n := parent.ExtractChild(idx);
  parent.InsertChild(target, n);
  Result := True;
end;

function CountNodes(ANode: TFilterNode): Integer;
var
  i: Integer;
begin
  Result := 1;
  for i := 0 to ANode.ChildCount - 1 do
    Inc(Result, CountNodes(ANode.Children[i]));
end;

function HasEmptyGroup(ANode: TFilterNode): Boolean;
var
  i: Integer;
begin
  if (ANode.Kind in [fkAnd, fkOr, fkNot]) and (ANode.ChildCount = 0) then Exit(True);
  for i := 0 to ANode.ChildCount - 1 do
    if HasEmptyGroup(ANode.Children[i]) then Exit(True);
  Result := False;
end;

function FilterInWords(ANode: TFilterNode; AMaxLen: Integer): string;

  function Words(N: TFilterNode; ANested: Boolean): string;
  var
    i: Integer;
    sep, part: string;
  begin
    if N = nil then Exit('');
    if N.Kind in [fkAnd, fkOr] then
    begin
      if N.ChildCount = 0 then
      begin
        if N.Kind = fkAnd then Exit(rsFbWordAll) else Exit(rsFbWordNothing);
      end;
      if N.ChildCount = 1 then Exit(Words(N.Children[0], ANested));
      if N.Kind = fkAnd then sep := rsFbWordAnd else sep := rsFbWordOr;
      Result := '';
      for i := 0 to N.ChildCount - 1 do
      begin
        part := Words(N.Children[i], True);
        if i > 0 then Result := Result + sep;
        Result := Result + part;
        if Length(Result) > AMaxLen then Break;
      end;
      if ANested then Result := '(' + Result + ')';
      Exit;
    end;
    if (N.Kind = fkNot) and not IsConditionNode(N) then
    begin
      if N.ChildCount = 1 then
      begin
        part := Words(N.Children[0], False);
        if N.Children[0].Kind in [fkAnd, fkOr] then part := '(' + part + ')';
        Exit(rsFbWordNot + part);
      end;
      Exit(rsFbWordNot + '()');
    end;
    Result := FilterNodeCaption(N);
  end;

begin
  Result := Words(ANode, False);
  if (AMaxLen > 1) and (Length(Result) > AMaxLen) then
    Result := Copy(Result, 1, AMaxLen - 1) + #$E2#$80#$A6;
end;

function BuilderProblem(ARoot: TFilterNode): string;
var
  node: TFilterNode;
  err: string;
begin
  Result := '';
  if ARoot = nil then Exit(rsFbEmpty);
  if FilterDepth(ARoot) > FILTER_MAX_DEPTH then Exit(Format(rsFbTooDeep, [FILTER_MAX_DEPTH]));
  if CountNodes(ARoot) > FILTER_MAX_NODES then Exit(Format(rsFbTooLarge, [FILTER_MAX_NODES]));
  // (&) et (|) sont valides (RFC 4526): vrai absolu et faux absolu. Presque
  // toujours un oubli, rarement une philosophie.
  if HasEmptyGroup(ARoot) then Exit(rsFbEmptyGroup);
  // Derniere garde: ce que le constructeur produit, l'analyseur doit l'accepter.
  node := FilterParse(FilterToString(ARoot), err);
  if node = nil then Exit(err);
  node.Free;
end;

end.
