// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdapMods;

{$mode objfpc}{$H+}

// Modifications et ajouts tels que libldap les envoie. Un octet nul ne coupe aucune
// valeur binaire. Les copies
// des valeurs, secrets compris, sont effacees a la liberation de l'objet.

interface

uses
  SysUtils, uLdapApi, uLdapEntry, uChangeSet;

type
  TModBuffer = class
  public
    Strings: array of AnsiString;
    Values: array of RawByteString;
    Bervals: array of TBerval;
    BervalPtrs: array of PBerval;
    CMods: array of TLdapModC;
    ModPtrs: array of PLdapModC;
    destructor Destroy; override;
    procedure Build(const AMods: TLdapModArray);
    procedure BuildFromEntry(AEntry: TLdapEntry);
  end;

implementation

uses
  uRtBytes;

destructor TModBuffer.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(Values) do
    WipeString(Values[i]);
  inherited Destroy;
end;

procedure TModBuffer.Build(const AMods: TLdapModArray);
var
  i, j, nVals, vi, starts: Integer;
begin
  nVals := 0;
  for i := 0 to High(AMods) do
    Inc(nVals, Length(AMods[i].Values) + 1);
  SetLength(Strings, Length(AMods));
  SetLength(Values, nVals);
  SetLength(Bervals, nVals);
  SetLength(BervalPtrs, nVals);
  SetLength(CMods, Length(AMods));
  SetLength(ModPtrs, Length(AMods) + 1);
  vi := 0;
  for i := 0 to High(AMods) do
  begin
    Strings[i] := AMods[i].Attr;
    case AMods[i].Op of
      moAdd: CMods[i].mod_op := LDAP_MOD_ADD;
      moDelete: CMods[i].mod_op := LDAP_MOD_DELETE;
      moReplace: CMods[i].mod_op := LDAP_MOD_REPLACE;
    else
      CMods[i].mod_op := LDAP_MOD_INCREMENT;
    end;
    CMods[i].mod_op := CMods[i].mod_op or LDAP_MOD_BVALUES;
    CMods[i].mod_type := PAnsiChar(Strings[i]);
    starts := vi;
    for j := 0 to High(AMods[i].Values) do
    begin
      Values[vi] := AMods[i].Values[j];
      // Copie propre: l'effacement a la liberation ne doit pas toucher la chaine de
      // l'appelant.
      UniqueString(Values[vi]);
      Bervals[vi] := StringToBerval(Values[vi]);
      // Valeur vide: l'encodeur veut un pointeur non nul, meme pour zero octet.
      if Bervals[vi].bv_val = nil then Bervals[vi].bv_val := PAnsiChar('');
      BervalPtrs[vi] := @Bervals[vi];
      Inc(vi);
    end;
    BervalPtrs[vi] := nil;
    Inc(vi);
    if Length(AMods[i].Values) = 0 then
      CMods[i].mod_bvalues := nil
    else
      CMods[i].mod_bvalues := @BervalPtrs[starts];
    ModPtrs[i] := @CMods[i];
  end;
  ModPtrs[High(ModPtrs)] := nil;
end;

procedure TModBuffer.BuildFromEntry(AEntry: TLdapEntry);
var
  mods: TLdapModArray;
  i, j: Integer;
begin
  SetLength(mods, AEntry.AttrCount);
  for i := 0 to AEntry.AttrCount - 1 do
  begin
    mods[i].Op := moAdd;
    mods[i].Attr := AEntry.Attrs[i].Description;
    SetLength(mods[i].Values, AEntry.Attrs[i].ValueCount);
    for j := 0 to AEntry.Attrs[i].ValueCount - 1 do
      mods[i].Values[j] := AEntry.Attrs[i].Values[j];
  end;
  Build(mods);
end;

end.
