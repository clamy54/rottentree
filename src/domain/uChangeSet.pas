// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uChangeSet;

{$mode objfpc}{$H+}

// Ecritures LDAP en attente: ajout, modification, suppression, renommage. Le
// delta se calcule valeur par valeur: remplacer en bloc une entree lue a moitie,
// c'est effacer tout ce qu'on n'a pas vu.

interface

uses
  SysUtils, Classes, Contnrs, uLdapEntry, uRtBytes;

type
  TModOp = (moAdd, moDelete, moReplace, moIncrement);

  TLdapMod = record
    Op: TModOp;
    Attr: string;
    Values: array of RawByteString;
  end;
  TLdapModArray = array of TLdapMod;

  TChangeKind = (ckAdd, ckModify, ckDelete, ckModDn);

  TLdapControlSpec = record
    Oid: string;
    Critical: Boolean;
    HasValue: Boolean;
    Value: RawByteString;
  end;
  TLdapControlSpecArray = array of TLdapControlSpec;

  TLdapChange = class
  public
    Kind: TChangeKind;
    Dn: string;
    Mods: TLdapModArray;
    Entry: TLdapEntry;
    NewRdn: string;
    DeleteOldRdn: Boolean;
    NewSuperior: string;
    HasNewSuperior: Boolean;
    Controls: TLdapControlSpecArray;
    SourceLine: Integer;
    destructor Destroy; override;
    procedure AddMod(AOp: TModOp; const AAttr: string; const AValues: array of RawByteString);
    function Clone: TLdapChange;
    function Describe: string; // sans les valeurs, donc sans les secrets
  end;

  TAttrEqualityKnown = function(const AAttr: string): Boolean of object;

  TDeltaOptions = record
    EqualityKnown: TAttrEqualityKnown;
  end;

// Un attribut tronque a la lecture n'est jamais remplace ni supprime en bloc:
// AError dit pourquoi le delta est refuse.
function ComputeModifications(AOriginal, AEdited: TLdapEntry;
  const AOptions: TDeltaOptions; out AMods: TLdapModArray; out AError: string): Boolean;

function ModOpName(AOp: TModOp): string;
function ChangeKindName(AKind: TChangeKind): string;
function NewChange(AKind: TChangeKind; const ADn: string): TLdapChange;

implementation

function ModOpName(AOp: TModOp): string;
begin
  case AOp of
    moAdd: Result := 'add';
    moDelete: Result := 'delete';
    moReplace: Result := 'replace';
  else
    Result := 'increment';
  end;
end;

function ChangeKindName(AKind: TChangeKind): string;
begin
  case AKind of
    ckAdd: Result := 'add';
    ckModify: Result := 'modify';
    ckDelete: Result := 'delete';
  else
    Result := 'moddn';
  end;
end;

function NewChange(AKind: TChangeKind; const ADn: string): TLdapChange;
begin
  Result := TLdapChange.Create;
  Result.Kind := AKind;
  Result.Dn := ADn;
  if AKind = ckAdd then
    Result.Entry := TLdapEntry.Create(ADn);
end;

destructor TLdapChange.Destroy;
var
  i, k: Integer;
begin
  // Les valeurs peuvent porter des secrets, effaces avant liberation. Les tableaux
  // dynamiques sont partages par reference: SetLength les rend uniques d'abord,
  // sinon on viderait aussi ceux de l'autre detenteur. Tir ami, mais tir quand meme.
  SetLength(Mods, Length(Mods));
  for i := 0 to High(Mods) do
  begin
    SetLength(Mods[i].Values, Length(Mods[i].Values));
    for k := 0 to High(Mods[i].Values) do
      WipeString(Mods[i].Values[k]);
  end;
  Entry.Free;
  inherited Destroy;
end;

procedure TLdapChange.AddMod(AOp: TModOp; const AAttr: string;
  const AValues: array of RawByteString);
var
  i: Integer;
begin
  SetLength(Mods, Length(Mods) + 1);
  Mods[High(Mods)].Op := AOp;
  Mods[High(Mods)].Attr := AAttr;
  SetLength(Mods[High(Mods)].Values, Length(AValues));
  for i := 0 to High(AValues) do
    Mods[High(Mods)].Values[i] := AValues[i];
end;

function TLdapChange.Clone: TLdapChange;
var
  i: Integer;
begin
  Result := TLdapChange.Create;
  Result.Kind := Kind;
  Result.Dn := Dn;
  SetLength(Result.Mods, Length(Mods));
  for i := 0 to High(Mods) do
  begin
    Result.Mods[i].Op := Mods[i].Op;
    Result.Mods[i].Attr := Mods[i].Attr;
    Result.Mods[i].Values := Copy(Mods[i].Values);
  end;
  if Entry <> nil then
    Result.Entry := Entry.Clone;
  Result.NewRdn := NewRdn;
  Result.DeleteOldRdn := DeleteOldRdn;
  Result.NewSuperior := NewSuperior;
  Result.HasNewSuperior := HasNewSuperior;
  Result.Controls := Copy(Controls);
  Result.SourceLine := SourceLine;
end;

function TLdapChange.Describe: string;
var
  i: Integer;
begin
  Result := ChangeKindName(Kind) + ' ' + Dn;
  case Kind of
    ckModify:
      for i := 0 to High(Mods) do
        Result := Result + Format(' [%s %s x%d]',
          [ModOpName(Mods[i].Op), Mods[i].Attr, Length(Mods[i].Values)]);
    ckAdd:
      if Entry <> nil then
        Result := Result + Format(' (%d attributes)', [Entry.AttrCount]);
    ckModDn:
      begin
        Result := Result + ' -> ' + NewRdn;
        if HasNewSuperior then Result := Result + ',' + NewSuperior;
        if DeleteOldRdn then Result := Result + ' (deleteOldRDN)';
      end;
  end;
end;

procedure AppendMod(var AMods: TLdapModArray; AOp: TModOp; const AAttr: string;
  const AValues: array of RawByteString);
var
  i: Integer;
begin
  SetLength(AMods, Length(AMods) + 1);
  AMods[High(AMods)].Op := AOp;
  AMods[High(AMods)].Attr := AAttr;
  SetLength(AMods[High(AMods)].Values, Length(AValues));
  for i := 0 to High(AValues) do
    AMods[High(AMods)].Values[i] := AValues[i];
end;

function ComputeModifications(AOriginal, AEdited: TLdapEntry;
  const AOptions: TDeltaOptions; out AMods: TLdapModArray; out AError: string): Boolean;
var
  i, j: Integer;
  oa, ea: TLdapAttribute;
  added, removed, all: array of RawByteString;
  eqKnown: Boolean;
begin
  AMods := nil;
  AError := '';
  for i := 0 to AOriginal.AttrCount - 1 do
  begin
    oa := AOriginal.Attrs[i];
    ea := AEdited.Find(oa.Description);
    eqKnown := (not Assigned(AOptions.EqualityKnown)) or AOptions.EqualityKnown(oa.BaseName);
    added := nil;
    removed := nil;
    if ea = nil then
    begin
      if oa.Truncated then
      begin
        AError := Format('attribute %s was not fully read; it cannot be removed as a whole',
          [oa.Description]);
        Exit(False);
      end;
      if eqKnown then
      begin
        SetLength(removed, oa.ValueCount);
        for j := 0 to oa.ValueCount - 1 do
          removed[j] := oa.Values[j];
        AppendMod(AMods, moDelete, oa.Description, removed);
      end
      else
        AppendMod(AMods, moDelete, oa.Description, []);
      Continue;
    end;
    for j := 0 to ea.ValueCount - 1 do
      if oa.IndexOfValue(ea.Values[j]) < 0 then
      begin
        SetLength(added, Length(added) + 1);
        added[High(added)] := ea.Values[j];
      end;
    for j := 0 to oa.ValueCount - 1 do
      if ea.IndexOfValue(oa.Values[j]) < 0 then
      begin
        SetLength(removed, Length(removed) + 1);
        removed[High(removed)] := oa.Values[j];
      end;
    if (Length(added) = 0) and (Length(removed) = 0) then Continue;
    if (not eqKnown) and (Length(removed) > 0) then
    begin
      if oa.Truncated then
      begin
        AError := Format('attribute %s has no equality rule and was not fully read',
          [oa.Description]);
        Exit(False);
      end;
      // Sans regle d'egalite, le serveur refuse la suppression par valeur: seul un
      // remplacement complet passe.
      SetLength(all, ea.ValueCount);
      for j := 0 to ea.ValueCount - 1 do
        all[j] := ea.Values[j];
      AppendMod(AMods, moReplace, oa.Description, all);
      Continue;
    end;
    // Suppression puis ajout dans le meme Modify: si la valeur a change depuis la
    // lecture, la suppression echoue au lieu d'ecraser le travail d'un collegue.
    if Length(removed) > 0 then
      AppendMod(AMods, moDelete, oa.Description, removed);
    if Length(added) > 0 then
      AppendMod(AMods, moAdd, oa.Description, added);
  end;
  for i := 0 to AEdited.AttrCount - 1 do
  begin
    ea := AEdited.Attrs[i];
    if AOriginal.Find(ea.Description) <> nil then Continue;
    if ea.ValueCount = 0 then Continue;
    SetLength(added, ea.ValueCount);
    for j := 0 to ea.ValueCount - 1 do
      added[j] := ea.Values[j];
    AppendMod(AMods, moAdd, ea.Description, added);
  end;
  Result := True;
end;

end.
