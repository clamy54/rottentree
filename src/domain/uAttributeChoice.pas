// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAttributeChoice;

{$mode objfpc}{$H+}

// Ce qu'on peut encore ajouter a une entree, d'apres son schema: attributs permis
// par ses classes et classes auxiliaires manquantes. Proposer un attribut que le
// serveur refusera (objectClassViolation), c'est faire perdre du temps a deux
// personnes, dont une a 3 h du matin.

interface

uses
  SysUtils, Classes, uLdapSchema, uLdapEntry, uConnectionProfile;

type
  TAttrChoiceKind = (
    ackMissing,
    ackAllowed,
    ackOperational,
    ackOpen);

  TAttrChoice = record
    Name: string;
    Oid: string;
    Kind: TAttrChoiceKind;
    Origin: string;
    SyntaxOid: string;
    SingleValued: Boolean;
    Desc: string;
  end;
  TAttrChoiceArray = array of TAttrChoice;

  TClassChoice = record
    Name: string;
    Oid: string;
    Desc: string;
    Must: TStringArray;
    May: TStringArray;
  end;
  TClassChoiceArray = array of TClassChoice;

function AttributeChoicesFor(ASchema: TSchemaSnapshot; AEntry: TLdapEntry;
  AProvider: TProviderKind; out AChoices: TAttrChoiceArray; out AReason: string): Boolean;
function AuxiliaryClassChoicesFor(ASchema: TSchemaSnapshot; AEntry: TLdapEntry): TClassChoiceArray;
function AttrChoiceKindText(const AChoice: TAttrChoice): string;

implementation

uses
  uEntryCreationPlan;

function HasValues(AEntry: TLdapEntry; ASchema: TSchemaSnapshot; const AName, AOid: string): Boolean;
var
  i: Integer;
  at: TSchemaAttributeType;
begin
  for i := 0 to AEntry.AttrCount - 1 do
  begin
    if AEntry.Attrs[i].ValueCount = 0 then Continue;
    if SameText(AEntry.Attrs[i].BaseName, AName) then Exit(True);
    at := ASchema.AttributeType(AEntry.Attrs[i].BaseName);
    if (at <> nil) and (AOid <> '') and SameText(at.Oid, AOid) then Exit(True);
  end;
  Result := False;
end;

function ContainsName(const AList: TAttrChoiceArray; const AOid, AName: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AList) do
    if ((AOid <> '') and SameText(AList[i].Oid, AOid)) or SameText(AList[i].Name, AName) then
      Exit(True);
  Result := False;
end;

procedure SortByName(var AList: TAttrChoiceArray; ALo, AHi: Integer);
var
  i, j: Integer;
  t: TAttrChoice;
begin
  for i := ALo + 1 to AHi do
  begin
    t := AList[i];
    j := i - 1;
    while (j >= ALo) and (CompareText(AList[j].Name, t.Name) > 0) do
    begin
      AList[j + 1] := AList[j];
      Dec(j);
    end;
    AList[j + 1] := t;
  end;
end;

function AttributeChoicesFor(ASchema: TSchemaSnapshot; AEntry: TLdapEntry;
  AProvider: TProviderKind; out AChoices: TAttrChoiceArray; out AReason: string): Boolean;
var
  oca: TLdapAttribute;
  structural, aux: array of string;
  i, k, start: Integer;
  oc: TSchemaObjectClass;
  a: TClassAnalysis;
  at: TSchemaAttributeType;
  c: TAttrChoice;
  open: Boolean;
  groups: array[TAttrChoiceKind] of TAttrChoiceArray;
  g: TAttrChoiceKind;

  procedure Push(AKind: TAttrChoiceKind; const AChoice: TAttrChoice);
  begin
    SetLength(groups[AKind], Length(groups[AKind]) + 1);
    groups[AKind][High(groups[AKind])] := AChoice;
    groups[AKind][High(groups[AKind])].Kind := AKind;
  end;

  function Known(const AOid, AName: string): Boolean;
  var
    kk: TAttrChoiceKind;
  begin
    for kk := Low(TAttrChoiceKind) to High(TAttrChoiceKind) do
      if ContainsName(groups[kk], AOid, AName) then Exit(True);
    Result := False;
  end;

  function FromType(AType: TSchemaAttributeType): TAttrChoice;
  begin
    Result := Default(TAttrChoice);
    Result.Name := AType.PrimaryName;
    Result.Oid := AType.Oid;
    Result.SyntaxOid := ASchema.EffectiveSyntax(AType.PrimaryName);
    Result.SingleValued := AType.SingleValue;
    Result.Desc := AType.Desc;
  end;

begin
  Result := False;
  AChoices := nil;
  AReason := '';
  for g := Low(TAttrChoiceKind) to High(TAttrChoiceKind) do groups[g] := nil;
  if (ASchema = nil) or (AEntry = nil) then
  begin
    AReason := 'the schema of the server is not available';
    Exit;
  end;
  structural := nil;
  aux := nil;
  oca := AEntry.Find('objectClass');
  if oca <> nil then
    for i := 0 to oca.ValueCount - 1 do
    begin
      oc := ASchema.ObjectClass(string(oca.Values[i]));
      if oc = nil then
      begin
        AReason := Format('the object class %s is not in the schema of the server', [string(oca.Values[i])]);
        Exit;
      end;
      case oc.Kind of
        ockStructural:
          begin
            SetLength(structural, Length(structural) + 1);
            structural[High(structural)] := oc.PrimaryName;
          end;
        ockAuxiliary:
          begin
            SetLength(aux, Length(aux) + 1);
            aux[High(aux)] := oc.PrimaryName;
          end;
      end;
    end;
  if Length(structural) = 0 then
  begin
    AReason := 'the entry has no structural object class known to the schema';
    Exit;
  end;
  a := AnalyzeClasses(ASchema, structural, aux, AProvider);
  if not a.Ok then
  begin
    for i := 0 to High(a.Issues) do
      if a.Issues[i].Severity = isError then
      begin
        AReason := a.Issues[i].Text;
        Break;
      end;
    Exit;
  end;
  for i := 0 to High(a.Requirements) do
  begin
    if SameText(a.Requirements[i].Name, 'objectClass') then Continue;
    if a.Requirements[i].Supply = rsServerOnly then Continue;
    at := ASchema.AttributeType(a.Requirements[i].Name);
    if (at <> nil) and at.NoUserModification then Continue;
    if HasValues(AEntry, ASchema, a.Requirements[i].Name, a.Requirements[i].Oid) then Continue;
    if at <> nil then c := FromType(at)
    else
    begin
      c := Default(TAttrChoice);
      c.Name := a.Requirements[i].Name;
    end;
    c.Origin := a.Requirements[i].Origin;
    if (a.Requirements[i].Kind = rqMust) and (a.Requirements[i].Supply = rsUser) then
      Push(ackMissing, c)
    else
      Push(ackAllowed, c);
  end;
  open := a.ExtensibleObject or a.AllowedIncomplete or not ASchema.Complete;
  // Schema incomplet ou extensibleObject: on ne sait pas, donc on ne trie pas.
  // Le serveur tranchera, c'est son metier.
  for k := 0 to ASchema.AttributeTypeCount - 1 do
  begin
    at := ASchema.AttributeTypeAt(k);
    if at.NoUserModification or at.Obsolete then Continue;
    if SameText(at.PrimaryName, 'objectClass') then Continue;
    if Known(at.Oid, at.PrimaryName) then Continue;
    if HasValues(AEntry, ASchema, at.PrimaryName, at.Oid) then Continue;
    if at.Usage <> auUserApplications then
      Push(ackOperational, FromType(at))
    else if open then
      Push(ackOpen, FromType(at));
  end;
  for g := Low(TAttrChoiceKind) to High(TAttrChoiceKind) do
  begin
    SortByName(groups[g], 0, High(groups[g]));
    start := Length(AChoices);
    SetLength(AChoices, start + Length(groups[g]));
    for i := 0 to High(groups[g]) do AChoices[start + i] := groups[g][i];
  end;
  Result := True;
end;

function AuxiliaryClassChoicesFor(ASchema: TSchemaSnapshot; AEntry: TLdapEntry): TClassChoiceArray;
var
  i, j: Integer;
  oc: TSchemaObjectClass;
  oca: TLdapAttribute;
  present: Boolean;
  must, may: TStringList;
  c: TClassChoice;
begin
  Result := nil;
  if (ASchema = nil) or (AEntry = nil) then Exit;
  oca := AEntry.Find('objectClass');
  must := TStringList.Create;
  may := TStringList.Create;
  try
    for i := 0 to ASchema.ObjectClassCount - 1 do
    begin
      oc := ASchema.ObjectClassAt(i);
      if (oc.Kind <> ockAuxiliary) or oc.Obsolete then Continue;
      present := False;
      if oca <> nil then
        for j := 0 to oca.ValueCount - 1 do
          if ASchema.ObjectClass(string(oca.Values[j])) = oc then present := True;
      if present then Continue;
      c := Default(TClassChoice);
      c.Name := oc.PrimaryName;
      c.Oid := oc.Oid;
      c.Desc := oc.Desc;
      must.Clear;
      may.Clear;
      if ASchema.CollectAllowed([oc.PrimaryName], must, may) then
      begin
        if must.IndexOf('objectClass') >= 0 then must.Delete(must.IndexOf('objectClass'));
        SetLength(c.Must, must.Count);
        for j := 0 to must.Count - 1 do c.Must[j] := must[j];
        SetLength(c.May, may.Count);
        for j := 0 to may.Count - 1 do c.May[j] := may[j];
      end;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := c;
    end;
  finally
    must.Free;
    may.Free;
  end;
  for i := 1 to High(Result) do
  begin
    c := Result[i];
    j := i - 1;
    while (j >= 0) and (CompareText(Result[j].Name, c.Name) > 0) do
    begin
      Result[j + 1] := Result[j];
      Dec(j);
    end;
    Result[j + 1] := c;
  end;
end;

function AttrChoiceKindText(const AChoice: TAttrChoice): string;
begin
  case AChoice.Kind of
    ackMissing: Result := 'required by ' + AChoice.Origin + ', missing';
    ackAllowed: Result := 'allowed by ' + AChoice.Origin;
    ackOperational: Result := 'operational (any entry)';
  else
    Result := 'not in the known classes, the server decides';
  end;
end;

end.
