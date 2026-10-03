// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uRangeAssembly;

{$mode objfpc}{$H+}

// Recolle les attributs qu'AD livre par tranches (member;range=0-1499). Une
// tranche amputee ne devient jamais une valeur complete, et un budget cumule
// borne la somme: le decodeur ne borne que chaque reponse, et un groupe de
// trois cent mille membres finit toujours par arriver un vendredi.

interface

uses
  SysUtils, Classes, uLdapEntry, uSearchModel;

type
  TRangeFragmentReader = function(const ADn, ADescription: string): TLdapEntry of object;

function AssembleEntryRanges(AEntry: TLdapEntry; AReader: TRangeFragmentReader;
  AMaxBytes: Int64 = ENTRY_MAX_BYTES): Boolean;

function EntryBudgetBytes(AEntry: TLdapEntry): Int64;
function AttributeBudgetBytes(AAttr: TLdapAttribute): Int64;

implementation

function AttributeBudgetBytes(AAttr: TLdapAttribute): Int64;
begin
  Result := AAttr.TotalBytes + Int64(AAttr.ValueCount) * VALUE_OVERHEAD_BYTES;
end;

function EntryBudgetBytes(AEntry: TLdapEntry): Int64;
var
  i: Integer;
begin
  Result := Length(AEntry.Dn);
  for i := 0 to AEntry.AttrCount - 1 do
    Inc(Result, AttributeBudgetBytes(AEntry.Attrs[i]));
end;

function AssembleEntryRanges(AEntry: TLdapEntry; AReader: TRangeFragmentReader;
  AMaxBytes: Int64): Boolean;
var
  i, j, k: Integer;
  base: string;
  lo, hi, used: Int64;
  rng: TRangeAssembler;
  a, fresh: TLdapAttribute;
  e: TLdapEntry;
  st: TRangeState;
  values: array of RawByteString;
  next: string;
  found, lost: Boolean;
begin
  Result := True;
  values := nil;
  used := EntryBudgetBytes(AEntry);
  i := 0;
  while i < AEntry.AttrCount do
  begin
    a := AEntry.Attrs[i];
    case ParseRangeOptionEx(a.Description, base, lo, hi) of
      rpNone:
        begin
          if used > AMaxBytes then
          begin
            a.Truncated := True;
            Result := False;
          end;
          Inc(i);
          Continue;
        end;
      rpMalformed:
        begin
          // Option de plage invalide: couverture degradee, jamais un attribut ordinaire
          // presente comme complet.
          a.Truncated := True;
          AEntry.DecodeIncomplete := True;
          Result := False;
          Inc(i);
          Continue;
        end;
      rpValid: ;
    end;
    rng := TRangeAssembler.Create(base);
    try
      lost := a.Truncated;
      // Budget deja depasse avant le premier fragment: meme une plage terminale (n-*)
      // reste tronquee, et la garde de la boucle empeche toute lecture suivante.
      if used > AMaxBytes then
        lost := True;
      SetLength(values, a.ValueCount);
      for j := 0 to a.ValueCount - 1 do
        values[j] := a.Values[j];
      st := rng.Feed(a.Description, values);
      while st = rsNeedMore do
      begin
        if used >= AMaxBytes then
        begin
          st := rsPartial;
          lost := True;
          Break;
        end;
        next := rng.NextRequest;
        e := AReader(AEntry.Dn, next);
        if e = nil then
        begin
          st := rsPartial;
          Break;
        end;
        try
          if e.DecodeIncomplete then
          begin
            // Une lecture intermediaire non decodee rend l'entree parente incomplete.
            AEntry.DecodeIncomplete := True;
            lost := True;
          end;
          found := False;
          for k := 0 to e.AttrCount - 1 do
            if SameText(AttrBaseName(e.Attrs[k].Description), AttrBaseName(base)) then
            begin
              found := True;
              if e.Attrs[k].Truncated then lost := True;
              if used + AttributeBudgetBytes(e.Attrs[k]) > AMaxBytes then
              begin
                st := rsPartial;
                lost := True;
                Break;
              end;
              Inc(used, AttributeBudgetBytes(e.Attrs[k]));
              SetLength(values, e.Attrs[k].ValueCount);
              for j := 0 to e.Attrs[k].ValueCount - 1 do
                values[j] := e.Attrs[k].Values[j];
              st := rng.Feed(e.Attrs[k].Description, values);
              Break;
            end;
          if not found then
            st := rsPartial;
        finally
          e.Free;
        end;
      end;
      fresh := TLdapAttribute.Create(base);
      // Un secret assemble est efface a la liberation, comme ses fragments.
      fresh.Sensitive := a.Sensitive;
      for j := 0 to rng.ValueCount - 1 do
        fresh.AddValue(rng.Value(j));
      // Une plage terminale (n-*) ne prouve rien si un fragment a perdu des valeurs.
      fresh.Truncated := (st <> rsComplete) or lost;
      if fresh.Truncated then Result := False;
      AEntry.Remove(a.Description);
      AEntry.Add(fresh);
    finally
      rng.Free;
    end;
  end;
end;

end.
