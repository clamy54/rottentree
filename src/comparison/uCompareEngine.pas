// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCompareEngine;

{$mode objfpc}{$H+}

// Moteur de comparaison, sans reseau: canonise les entrees de chaque source, les
// regroupe par cle d'identite et produit des variantes. Une cle dupliquee ou absente
// reste une ambiguite, jamais un pari. Aucune ecriture LDAP ici, et personne ne s'en
// plaint.

interface

uses
  SysUtils, Classes, Contnrs, uCompareModel, uCanonical, uSpillStore, uLdapEntry,
  uLdapSchema, uLdapDn, uSearchModel;

type
  TDiffKind = (dkMissing, dkContent, dkRenamed, dkAmbiguous);
  TDiffKinds = set of TDiffKind;
  TPersistence = (psUnverified, psTransient, psPersistent);

  TVariant = record
    Hash: RawByteString;
    Members: array of Integer;
    Handle: Int64;
  end;

  TAttrDiff = record
    Attr: string;
    BaseVariant: Integer;
    OtherVariant: Integer;
    OnlyInBase: array of RawByteString;
    OnlyInOther: array of RawByteString;
    SemanticUndetermined: Boolean;
  end;

  TEntryDiff = class
  public
    KeyHash: string;
    DisplayKey: string;
    Kinds: TDiffKinds;
    Variants: array of TVariant;
    Absent: array of Integer;
    Duplicated: array of Integer;
    Dns: array of string;
    AttrDiffs: array of TAttrDiff;
    ObjectClass: string;
    Persistence: TPersistence;
    OnlySemanticUndetermined: Boolean;
  end;

  TCompareCounters = record
    Keys: Int64;
    EqualKeys: Int64;
    DifferingKeys: Int64;
    MissingKeys: Int64;
    ContentKeys: Int64;
    RenamedKeys: Int64;
    AmbiguousKeys: Int64;
    TransientKeys: Int64;
    PersistentKeys: Int64;
    PerSourceEntries: array of Int64;
    PerSourceAbsent: array of Int64;
  end;

  TComparisonEngine = class
  private
    FProfile: TComparisonProfile;
    FSchemas: array of TSchemaSnapshot;
    FBaseDns: array of TLdapDn;
    FDnCmp: TDnComparer;
    FKeys: TFPHashObjectList;
    FStore: TSpillStore;
    FDiffs: TObjectList;
    FObservations: array of TSourceObservation;
    FCounters: TCompareCounters;
    FFinished: Boolean;
    FSemanticRuleMismatch: TStringList;
    function SourceCount: Integer;
    function IdentityKey(ASource: Integer; AEntry: TLdapEntry; out AKey, ADisplay: RawByteString): Boolean;
    function EntryTruncated(AEntry: TLdapEntry): Boolean;
    function Canonicalize(ASource: Integer; AEntry: TLdapEntry): TCanonAttrs;
    function CanonName(ASource: Integer; const ADescription: string): string;
    function RuleFor(const AAttr: string; out ARule: string): Boolean;
    function BaseVariantIndex(ADiff: TEntryDiff): Integer;
    procedure ComputeAttrDiffs(ADiff: TEntryDiff);
    function BuildDiff(AObj: TObject; const AKeyHash: string): TEntryDiff;
  public
    constructor Create(AProfile: TComparisonProfile; const ASchemas: array of TSchemaSnapshot;
      const ATempDir: string);
    destructor Destroy; override;
    procedure SetObservation(ASource: Integer; const AObs: TSourceObservation);
    function Observation(ASource: Integer): TSourceObservation;
    function AddEntry(ASource: Integer; AEntry: TLdapEntry): Boolean;
    procedure Recheck(const AKeyHash: string; ASource: Integer; AEntry: TLdapEntry);
    procedure Finish;
    procedure FinishRecheck;
    function Verdict(AExecution: TExecutionState; AMarkersMoved: Boolean): TVerdict;
    function DiffCount: Integer;
    function Diff(AIndex: Integer): TEntryDiff;
    function FindDiff(const AKeyHash: string): TEntryDiff;
    function VariantAttributes(ADiff: TEntryDiff; AVariant: Integer): TCanonAttrs;
    function KeysForRecheck: TStringArray;
    property Counters: TCompareCounters read FCounters;
    property Profile: TComparisonProfile read FProfile;
    property Store: TSpillStore read FStore;
  end;

function DiffKindsText(AKinds: TDiffKinds): string;

implementation

uses
  uRtBytes, uOpenSslApi, uMatchingRules, uSensitive;

type
  TSlot = record
    Count: Integer;
    Hash: RawByteString;
    Handle: Int64;
    Dn: string;
    RelKey: string;
    ObjectClass: string;
    Recheck: Integer;
  end;

  TKeyRecord = class
    Key: RawByteString;
    Display: string;
    Slots: array of TSlot;
  end;

function DiffKindsText(AKinds: TDiffKinds): string;

  procedure Add(const S: string);
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + S;
  end;

begin
  Result := '';
  if dkAmbiguous in AKinds then Add('ambiguous identity');
  if dkMissing in AKinds then Add('not observed on some directories');
  if dkRenamed in AKinds then Add('renamed or moved');
  if dkContent in AKinds then Add('values differ');
end;

constructor TComparisonEngine.Create(AProfile: TComparisonProfile;
  const ASchemas: array of TSchemaSnapshot; const ATempDir: string);
var
  i: Integer;
  err: string;
begin
  inherited Create;
  FProfile := TComparisonProfile.Create;
  FProfile.Assign(AProfile);
  SetLength(FSchemas, Length(AProfile.Sources));
  for i := 0 to High(FSchemas) do
    if i <= High(ASchemas) then
      FSchemas[i] := ASchemas[i]
    else
      FSchemas[i] := nil;
  SetLength(FBaseDns, Length(AProfile.Sources));
  for i := 0 to High(FBaseDns) do
    if not DnParse(AProfile.Sources[i].BaseDn, FBaseDns[i], err) then
      raise Exception.CreateFmt('invalid base DN for directory %d', [i + 1]);
  SetLength(FObservations, Length(AProfile.Sources));
  SetLength(FCounters.PerSourceEntries, Length(AProfile.Sources));
  SetLength(FCounters.PerSourceAbsent, Length(AProfile.Sources));
  FDnCmp := TDnComparer.Create;
  FKeys := TFPHashObjectList.Create(True);
  FStore := TSpillStore.Create(Int64(AProfile.MemoryBudgetMiB) * 1024 * 1024,
    Int64(AProfile.TempQuotaMiB) * 1024 * 1024, ATempDir);
  FDiffs := TObjectList.Create(True);
  FSemanticRuleMismatch := TStringList.Create;
  FSemanticRuleMismatch.Sorted := True;
  FSemanticRuleMismatch.Duplicates := dupIgnore;
end;

destructor TComparisonEngine.Destroy;
begin
  FDiffs.Free;
  FKeys.Free;
  FStore.Free;
  FDnCmp.Free;
  FProfile.Free;
  FSemanticRuleMismatch.Free;
  inherited Destroy;
end;

function TComparisonEngine.SourceCount: Integer;
begin
  Result := Length(FProfile.Sources);
end;

procedure TComparisonEngine.SetObservation(ASource: Integer; const AObs: TSourceObservation);
begin
  FObservations[ASource] := AObs;
end;

function TComparisonEngine.Observation(ASource: Integer): TSourceObservation;
begin
  Result := FObservations[ASource];
end;

function TComparisonEngine.CanonName(ASource: Integer; const ADescription: string): string;
var
  d: TAttrDescription;
  base: string;
  opts: TStringList;
  i: Integer;
begin
  d := ParseAttrDescription(ADescription);
  base := '';
  if FSchemas[ASource] <> nil then
    base := FSchemas[ASource].CanonicalAttrName(d.Base);
  if base = '' then
    base := AsciiLowerCase(d.Base);
  opts := TStringList.Create;
  try
    opts.Sorted := True;
    opts.Duplicates := dupIgnore;
    for i := 0 to High(d.Options) do
      if Copy(AsciiLowerCase(d.Options[i]), 1, 6) <> 'range=' then
        opts.Add(AsciiLowerCase(d.Options[i]));
    Result := base;
    for i := 0 to opts.Count - 1 do
      Result := Result + ';' + opts[i];
  finally
    opts.Free;
  end;
end;

function TComparisonEngine.RuleFor(const AAttr: string; out ARule: string): Boolean;
var
  i: Integer;
  r: string;
begin
  ARule := '';
  Result := False;
  for i := 0 to High(FSchemas) do
  begin
    if FSchemas[i] = nil then Exit;
    r := LowerCase(FSchemas[i].EffectiveEquality(AAttr));
    if r = '' then Exit;
    if (i > 0) and (r <> ARule) then
    begin
      FSemanticRuleMismatch.Add(AAttr);
      Exit;
    end;
    ARule := r;
  end;
  Result := ARule <> '';
end;

function TComparisonEngine.EntryTruncated(AEntry: TLdapEntry): Boolean;
var
  i: Integer;
  a: TLdapAttribute;
begin
  if AEntry.DecodeIncomplete then Exit(True);
  for i := 0 to AEntry.AttrCount - 1 do
  begin
    a := AEntry.Attrs[i];
    if not a.Truncated then Continue;
    if FProfile.IsExcluded(a.BaseName) or not FProfile.IsIncluded(a.BaseName) then Continue;
    Exit(True);
  end;
  Result := False;
end;

function TComparisonEngine.Canonicalize(ASource: Integer; AEntry: TLdapEntry): TCanonAttrs;
var
  i, j, n: Integer;
  a: TLdapAttribute;
  ca: TCanonAttr;
  rule: string;
  kind: TRuleKind;
  norm, normOut: RawByteString;
  nr: TNormResult;
  sch: TSchemaSnapshot;
  at: TSchemaAttributeType;
  mapped: TLdapDn;
  dnVal: TLdapDn;
  err: string;
  isDnSyntax: Boolean;
begin
  Result := nil;
  sch := FSchemas[ASource];
  for i := 0 to AEntry.AttrCount - 1 do
  begin
    a := AEntry.Attrs[i];
    if FProfile.IsExcluded(a.BaseName) or not FProfile.IsIncluded(a.BaseName) then Continue;
    if (not FProfile.IncludeOperational) and (sch <> nil) and sch.IsOperational(a.BaseName) then
      Continue;
    ca := Default(TCanonAttr);
    ca.Name := CanonName(ASource, a.Description);
    at := nil;
    if sch <> nil then at := sch.AttributeType(a.BaseName);
    ca.Ordered := (at <> nil) and SameText(at.ExtensionValue('X-ORDERED'), 'VALUES');
    isDnSyntax := (sch <> nil) and (sch.EffectiveSyntax(a.BaseName) = '1.3.6.1.4.1.1466.115.121.1.12');
    SetLength(ca.Values, a.ValueCount);
    SetLength(ca.RawValues, a.ValueCount);
    kind := rkUnknown;
    if FProfile.Strictness = csSemantic then
    begin
      if RuleFor(a.BaseName, rule) then
        kind := RuleKindFromName(rule);
      if kind = rkUnknown then
        ca.SemanticUndetermined := True;
    end;
    for j := 0 to a.ValueCount - 1 do
    begin
      ca.RawValues[j] := a.Values[j];
      norm := a.Values[j];
      if FProfile.RewriteDnValues and isDnSyntax and (ASource <> 0) then
        if DnParse(norm, dnVal, err) then
          if DnReplaceSuffix(FDnCmp, dnVal, FBaseDns[ASource], FBaseDns[0], mapped) then
            norm := DnToString(mapped);
      if FProfile.Strictness = csSemantic then
      begin
        if kind <> rkUnknown then
        begin
          nr := NormalizeValue(kind, norm, normOut);
          if nr = nrOk then
            norm := normOut
          else
          begin
            norm := a.Values[j];
            ca.SemanticUndetermined := True;
          end;
        end;
      end;
      ca.Values[j] := norm;
    end;
    if not ca.Ordered then
      SortValuePairs(ca.Values, ca.RawValues);
    n := Length(Result);
    SetLength(Result, n + 1);
    Result[n] := ca;
  end;
  SortCanonAttrs(Result);
end;

function TComparisonEngine.IdentityKey(ASource: Integer; AEntry: TLdapEntry;
  out AKey, ADisplay: RawByteString): Boolean;
var
  d, rel: TLdapDn;
  err: string;
  a: TLdapAttribute;
  attrName: string;
  i, j: Integer;
  sch: TSchemaSnapshot;
  rule: string;
  norm: RawByteString;
begin
  Result := False;
  AKey := '';
  ADisplay := '';
  case FProfile.Identity of
    imRelativeDn:
      begin
        if not DnParse(AEntry.Dn, d, err) then Exit;
        if FDnCmp.IsUnder(d, FBaseDns[ASource], True) <> dmEqual then Exit;
        rel := DnRelative(d, DnRdnCount(FBaseDns[ASource]));
        ADisplay := DnToString(rel);
        if ADisplay = '' then ADisplay := '(base)';
        sch := FSchemas[ASource];
        if FProfile.Strictness = csSemantic then
          for i := 0 to High(rel.Rdns) do
            for j := 0 to High(rel.Rdns[i].Avas) do
              if RuleFor(rel.Rdns[i].Avas[j].AttrType, rule) then
                if NormalizeValue(RuleKindFromName(rule), rel.Rdns[i].Avas[j].Value, norm) = nrOk then
                  rel.Rdns[i].Avas[j].Value := norm;
        if sch <> nil then
          for i := 0 to High(rel.Rdns) do
            for j := 0 to High(rel.Rdns[i].Avas) do
              if sch.CanonicalAttrName(rel.Rdns[i].Avas[j].AttrType) <> '' then
                rel.Rdns[i].Avas[j].AttrType := sch.CanonicalAttrName(rel.Rdns[i].Avas[j].AttrType);
        AKey := 'dn:' + DnStrictKey(FDnCmp, rel);
        Result := True;
      end;
    imEntryUuid, imObjectGuid, imBusinessKey:
      begin
        case FProfile.Identity of
          imEntryUuid: attrName := 'entryUUID';
          imObjectGuid: attrName := 'objectGUID';
        else
          attrName := FProfile.BusinessKeyAttr;
        end;
        a := AEntry.Find(attrName);
        if (a = nil) or (a.ValueCount <> 1) then Exit;
        if FProfile.Identity = imEntryUuid then
          AKey := 'id:' + AsciiLowerCase(a.Values[0])
        else
          AKey := 'id:' + HexEncode(a.Values[0]);
        if IsValidUtf8(a.Values[0]) and IsAsciiPrintable(a.Values[0]) then
          ADisplay := attrName + '=' + a.Values[0]
        else
          ADisplay := attrName + '=#' + HexEncode(a.Values[0]);
        Result := True;
      end;
  end;
end;

function SlotStringBytes(const ASlot: TSlot): Int64;
begin
  Result := Length(ASlot.Dn) + Length(ASlot.RelKey) + Length(ASlot.ObjectClass) +
    Length(ASlot.Hash);
end;

// L'identite du slot se reconstruit en entier a chaque lecture: DN, classe et cle
// relative vont ensemble. Rafraichis a moitie, ils inventent des renommages.
procedure FillSlotIdentity(var ASlot: TSlot; AEntry: TLdapEntry;
  ACmp: TDnComparer; const ABase: TLdapDn);
var
  d, rel: TLdapDn;
  err: string;
  i: Integer;
begin
  ASlot.Dn := AEntry.Dn;
  ASlot.ObjectClass := '';
  for i := 0 to AEntry.AttrCount - 1 do
    if SameText(AEntry.Attrs[i].BaseName, 'objectClass') and (AEntry.Attrs[i].ValueCount > 0) then
      ASlot.ObjectClass := AEntry.Attrs[i].Values[AEntry.Attrs[i].ValueCount - 1];
  if DnParse(AEntry.Dn, d, err) and (ACmp.IsUnder(d, ABase, True) = dmEqual) then
  begin
    rel := DnRelative(d, DnRdnCount(ABase));
    ASlot.RelKey := DnStrictKey(ACmp, rel);
  end
  else
    ASlot.RelKey := '#outside:' + AEntry.Dn;
end;

function TComparisonEngine.AddEntry(ASource: Integer; AEntry: TLdapEntry): Boolean;
var
  key, display: RawByteString;
  keyHash: string;
  rec: TKeyRecord;
  attrs: TCanonAttrs;
  slot: ^TSlot;
begin
  Result := False;
  if not IdentityKey(ASource, AEntry, key, display) then
  begin
    if (FProfile.Identity = imRelativeDn) then
      Inc(FObservations[ASource].OutsideBase)
    else
      Inc(FObservations[ASource].MissingIdentity);
    Exit;
  end;
  Inc(FCounters.PerSourceEntries[ASource]);
  if EntryTruncated(AEntry) then
    Inc(FObservations[ASource].TruncatedEntries);
  keyHash := HexEncode(DigestOf('SHA256', key));
  rec := TKeyRecord(FKeys.Find(keyHash));
  if rec = nil then
  begin
    rec := TKeyRecord.Create;
    rec.Key := key;
    rec.Display := display;
    SetLength(rec.Slots, SourceCount);
    FKeys.Add(keyHash, rec);
    FStore.Account(Length(key) + Length(keyHash) + Length(display) + SourceCount * 64 + 64);
    if FStore.IndexOverBudget then
      // L'index des identites ne se deporte pas sur disque: arret explicite plutot
      // qu'un verdict qui aurait l'air complet.
      raise ESpillStore.Create('memory budget reached by the identity index: the comparison stops explicitly');
  end;
  slot := @rec.Slots[ASource];
  Inc(slot^.Count);
  if slot^.Count > 1 then
  begin
    Inc(FObservations[ASource].DuplicateKeys);
    Exit(True);
  end;
  attrs := Canonicalize(ASource, AEntry);
  slot^.Hash := CanonicalHash(attrs);
  slot^.Handle := FStore.Put(EncodeRecord(attrs));
  FillSlotIdentity(slot^, AEntry, FDnCmp, FBaseDns[ASource]);
  FStore.Account(SlotStringBytes(slot^));
  if FStore.IndexOverBudget then
    raise ESpillStore.Create('memory budget reached by the identity index: the comparison stops explicitly');
  Result := True;
end;

procedure TComparisonEngine.Recheck(const AKeyHash: string; ASource: Integer; AEntry: TLdapEntry);
var
  rec: TKeyRecord;
  attrs: TCanonAttrs;
  before: Int64;
begin
  rec := TKeyRecord(FKeys.Find(AKeyHash));
  if rec = nil then Exit;
  // Les chaines remplacees sortent du budget, les nouvelles y entrent. Sans cette
  // comptabilite, une serie de relectures creve le plafond annonce sans que rien ne
  // l'arrete.
  before := SlotStringBytes(rec.Slots[ASource]);
  if AEntry = nil then
  begin
    rec.Slots[ASource].Recheck := 2;
    rec.Slots[ASource].Count := 0;
    rec.Slots[ASource].Hash := '';
    rec.Slots[ASource].Dn := '';
    rec.Slots[ASource].RelKey := '';
    rec.Slots[ASource].ObjectClass := '';
    FStore.Account(-before);
    Exit;
  end;
  if EntryTruncated(AEntry) then
    Inc(FObservations[ASource].TruncatedEntries);
  attrs := Canonicalize(ASource, AEntry);
  rec.Slots[ASource].Recheck := 1;
  rec.Slots[ASource].Count := 1;
  rec.Slots[ASource].Hash := CanonicalHash(attrs);
  rec.Slots[ASource].Handle := FStore.Put(EncodeRecord(attrs));
  FillSlotIdentity(rec.Slots[ASource], AEntry, FDnCmp, FBaseDns[ASource]);
  FStore.Account(SlotStringBytes(rec.Slots[ASource]) - before);
  if FStore.IndexOverBudget then
    raise ESpillStore.Create('memory budget reached by the identity index: the comparison stops explicitly');
end;

function TComparisonEngine.BuildDiff(AObj: TObject; const AKeyHash: string): TEntryDiff;
var
  rec: TKeyRecord;
  i, v, n: Integer;
  found: Boolean;
  relKeys: TStringList;
begin
  rec := TKeyRecord(AObj);
  Result := TEntryDiff.Create;
  Result.KeyHash := AKeyHash;
  Result.DisplayKey := rec.Display;
  SetLength(Result.Dns, SourceCount);
  relKeys := TStringList.Create;
  try
    relKeys.Sorted := True;
    relKeys.Duplicates := dupIgnore;
    for i := 0 to SourceCount - 1 do
    begin
      Result.Dns[i] := rec.Slots[i].Dn;
      if rec.Slots[i].Count = 0 then
      begin
        SetLength(Result.Absent, Length(Result.Absent) + 1);
        Result.Absent[High(Result.Absent)] := i;
        Continue;
      end;
      if rec.Slots[i].Count > 1 then
      begin
        SetLength(Result.Duplicated, Length(Result.Duplicated) + 1);
        Result.Duplicated[High(Result.Duplicated)] := i;
      end;
      if Result.ObjectClass = '' then
        Result.ObjectClass := rec.Slots[i].ObjectClass;
      relKeys.Add(rec.Slots[i].RelKey);
      found := False;
      for v := 0 to High(Result.Variants) do
        if Result.Variants[v].Hash = rec.Slots[i].Hash then
        begin
          n := Length(Result.Variants[v].Members);
          SetLength(Result.Variants[v].Members, n + 1);
          Result.Variants[v].Members[n] := i;
          found := True;
          Break;
        end;
      if not found then
      begin
        SetLength(Result.Variants, Length(Result.Variants) + 1);
        with Result.Variants[High(Result.Variants)] do
        begin
          Hash := rec.Slots[i].Hash;
          Handle := rec.Slots[i].Handle;
          SetLength(Members, 1);
          Members[0] := i;
        end;
      end;
    end;
    if Length(Result.Duplicated) > 0 then Include(Result.Kinds, dkAmbiguous);
    if Length(Result.Absent) > 0 then Include(Result.Kinds, dkMissing);
    if Length(Result.Variants) > 1 then Include(Result.Kinds, dkContent);
    if (FProfile.Identity <> imRelativeDn) and (relKeys.Count > 1) then
      Include(Result.Kinds, dkRenamed);
  finally
    relKeys.Free;
  end;
end;

function TComparisonEngine.BaseVariantIndex(ADiff: TEntryDiff): Integer;
var
  v, m: Integer;
begin
  Result := 0;
  if FProfile.Topology = ctReference then
    for v := 0 to High(ADiff.Variants) do
      for m := 0 to High(ADiff.Variants[v].Members) do
        if ADiff.Variants[v].Members[m] = FProfile.ReferenceIndex then
          Exit(v);
end;

procedure TComparisonEngine.ComputeAttrDiffs(ADiff: TEntryDiff);
var
  base, v, i, j, k: Integer;
  ba, oa: TCanonAttrs;
  names: TStringList;
  d: TAttrDiff;
  bi, oi: Integer;
  onlySemantic: Boolean;

  function FindAttr(const A: TCanonAttrs; const AName: string): Integer;
  var
    x: Integer;
  begin
    for x := 0 to High(A) do
      if A[x].Name = AName then Exit(x);
    Result := -1;
  end;

  function Contains(const AValues: array of RawByteString; const AValue: RawByteString): Boolean;
  var
    x: Integer;
  begin
    for x := 0 to High(AValues) do
      if AValues[x] = AValue then Exit(True);
    Result := False;
  end;

begin
  ADiff.AttrDiffs := nil;
  if Length(ADiff.Variants) < 2 then Exit;
  base := BaseVariantIndex(ADiff);
  ba := DecodeRecord(FStore.Get(ADiff.Variants[base].Handle));
  onlySemantic := True;
  names := TStringList.Create;
  try
    names.Sorted := True;
    names.Duplicates := dupIgnore;
    for v := 0 to High(ADiff.Variants) do
    begin
      if v = base then Continue;
      oa := DecodeRecord(FStore.Get(ADiff.Variants[v].Handle));
      names.Clear;
      for i := 0 to High(ba) do names.Add(ba[i].Name);
      for i := 0 to High(oa) do names.Add(oa[i].Name);
      for k := 0 to names.Count - 1 do
      begin
        bi := FindAttr(ba, names[k]);
        oi := FindAttr(oa, names[k]);
        d := Default(TAttrDiff);
        d.Attr := names[k];
        d.BaseVariant := base;
        d.OtherVariant := v;
        if bi >= 0 then
          for j := 0 to High(ba[bi].Values) do
            if (oi < 0) or not Contains(oa[oi].Values, ba[bi].Values[j]) then
            begin
              SetLength(d.OnlyInBase, Length(d.OnlyInBase) + 1);
              if j <= High(ba[bi].RawValues) then
                d.OnlyInBase[High(d.OnlyInBase)] := ba[bi].RawValues[j]
              else
                d.OnlyInBase[High(d.OnlyInBase)] := ba[bi].Values[j];
            end;
        if oi >= 0 then
          for j := 0 to High(oa[oi].Values) do
            if (bi < 0) or not Contains(ba[bi].Values, oa[oi].Values[j]) then
            begin
              SetLength(d.OnlyInOther, Length(d.OnlyInOther) + 1);
              if j <= High(oa[oi].RawValues) then
                d.OnlyInOther[High(d.OnlyInOther)] := oa[oi].RawValues[j]
              else
                d.OnlyInOther[High(d.OnlyInOther)] := oa[oi].Values[j];
            end;
        if (Length(d.OnlyInBase) = 0) and (Length(d.OnlyInOther) = 0) and (bi >= 0) and (oi >= 0) and
           (EncodeCompared([ba[bi]]) <> EncodeCompared([oa[oi]])) then
        begin
          d.OnlyInBase := Copy(ba[bi].RawValues);
          d.OnlyInOther := Copy(oa[oi].RawValues);
        end;
        if (Length(d.OnlyInBase) = 0) and (Length(d.OnlyInOther) = 0) then Continue;
        d.SemanticUndetermined := ((bi >= 0) and ba[bi].SemanticUndetermined) or
          ((oi >= 0) and oa[oi].SemanticUndetermined);
        if not (d.SemanticUndetermined and (FProfile.Strictness = csSemantic)) then
          onlySemantic := False;
        SetLength(ADiff.AttrDiffs, Length(ADiff.AttrDiffs) + 1);
        ADiff.AttrDiffs[High(ADiff.AttrDiffs)] := d;
      end;
    end;
  finally
    names.Free;
  end;
  ADiff.OnlySemanticUndetermined := (FProfile.Strictness = csSemantic) and onlySemantic and
    (Length(ADiff.AttrDiffs) > 0) and (ADiff.Kinds = [dkContent]);
end;

procedure TComparisonEngine.Finish;
var
  i, s: Integer;
  ed: TEntryDiff;
  sample: TStringList;
begin
  FDiffs.Clear;
  sample := nil;
  if FProfile.Mode = cmSample then
  begin
    sample := TStringList.Create;
    sample.Sorted := True;
    for i := 0 to FKeys.Count - 1 do
      sample.Add(FKeys.NameOfIndex(i));
    while sample.Count > FProfile.SampleSize do
      sample.Delete(sample.Count - 1);
  end;
  try
  FCounters.Keys := FKeys.Count;
  FCounters.EqualKeys := 0;
  FCounters.DifferingKeys := 0;
  FCounters.MissingKeys := 0;
  FCounters.ContentKeys := 0;
  FCounters.RenamedKeys := 0;
  FCounters.AmbiguousKeys := 0;
  for s := 0 to SourceCount - 1 do
    FCounters.PerSourceAbsent[s] := 0;
  for i := 0 to FKeys.Count - 1 do
  begin
    if (sample <> nil) and (sample.IndexOf(FKeys.NameOfIndex(i)) < 0) then Continue;
    ed := BuildDiff(FKeys.Items[i], FKeys.NameOfIndex(i));
    if ed.Kinds = [] then
    begin
      Inc(FCounters.EqualKeys);
      ed.Free;
      Continue;
    end;
    ComputeAttrDiffs(ed);
    Inc(FCounters.DifferingKeys);
    if dkMissing in ed.Kinds then Inc(FCounters.MissingKeys);
    if dkContent in ed.Kinds then Inc(FCounters.ContentKeys);
    if dkRenamed in ed.Kinds then Inc(FCounters.RenamedKeys);
    if dkAmbiguous in ed.Kinds then Inc(FCounters.AmbiguousKeys);
    for s := 0 to High(ed.Absent) do
      Inc(FCounters.PerSourceAbsent[ed.Absent[s]]);
    FDiffs.Add(ed);
  end;
  finally
    sample.Free;
  end;
  FFinished := True;
end;

function TComparisonEngine.KeysForRecheck: TStringArray;
var
  i: Integer;
begin
  Result := nil;
  SetLength(Result, FDiffs.Count);
  for i := 0 to FDiffs.Count - 1 do
    Result[i] := TEntryDiff(FDiffs[i]).KeyHash;
end;

procedure TComparisonEngine.FinishRecheck;
var
  before: TStringList;
  i: Integer;
  d: TEntryDiff;
  oldDiffs: TObjectList;
begin
  before := TStringList.Create;
  oldDiffs := TObjectList.Create(True);
  try
    before.Sorted := True;
    for i := 0 to FDiffs.Count - 1 do
      before.Add(TEntryDiff(FDiffs[i]).KeyHash);
    FDiffs.OwnsObjects := False;
    for i := 0 to FDiffs.Count - 1 do
      oldDiffs.Add(FDiffs[i]);
    FDiffs.Clear;
    FDiffs.OwnsObjects := True;
    Finish;
    FCounters.TransientKeys := 0;
    FCounters.PersistentKeys := 0;
    for i := 0 to FDiffs.Count - 1 do
    begin
      d := TEntryDiff(FDiffs[i]);
      if before.IndexOf(d.KeyHash) >= 0 then
      begin
        d.Persistence := psPersistent;
        Inc(FCounters.PersistentKeys);
      end;
    end;
    for i := oldDiffs.Count - 1 downto 0 do
    begin
      d := TEntryDiff(oldDiffs[i]);
      if FindDiff(d.KeyHash) = nil then
      begin
        oldDiffs.Extract(d);
        d.Persistence := psTransient;
        FDiffs.Add(d);
        Inc(FCounters.TransientKeys);
      end;
    end;
  finally
    before.Free;
    oldDiffs.Free;
  end;
end;

function TComparisonEngine.Verdict(AExecution: TExecutionState; AMarkersMoved: Boolean): TVerdict;
var
  i: Integer;
  oc: TSearchOutcome;
  certain, undetermined: Boolean;
  d: TEntryDiff;

  procedure AddCov(const S: string);
  begin
    SetLength(Result.CoverageReasons, Length(Result.CoverageReasons) + 1);
    Result.CoverageReasons[High(Result.CoverageReasons)] := S;
  end;

  procedure AddStab(const S: string);
  begin
    SetLength(Result.StabilityReasons, Length(Result.StabilityReasons) + 1);
    Result.StabilityReasons[High(Result.StabilityReasons)] := S;
  end;

begin
  Result := Default(TVerdict);
  Result.Execution := AExecution;
  Result.Coverage := cvComplete;
  for i := 0 to SourceCount - 1 do
  begin
    oc := SearchOutcome(FObservations[i].Completion);
    if oc <> soComplete then
    begin
      Result.Coverage := cvPartial;
      AddCov(Format('%s: read not complete (%s)', [FProfile.Sources[i].Name,
        ResultCodeName(FObservations[i].Completion.ResultCode)]));
    end;
    if FObservations[i].Completion.RangeIncomplete then
    begin
      Result.Coverage := cvPartial;
      AddCov(FProfile.Sources[i].Name + ': incomplete attribute ranges');
    end;
    if FObservations[i].Completion.DecodeFailures > 0 then
    begin
      Result.Coverage := cvPartial;
      AddCov(Format('%s: %d entries could not be decoded completely', [FProfile.Sources[i].Name,
        FObservations[i].Completion.DecodeFailures]));
    end;
    if FObservations[i].TruncatedEntries > 0 then
    begin
      Result.Coverage := cvPartial;
      AddCov(Format('%s: %d entries with omitted or truncated values', [FProfile.Sources[i].Name,
        FObservations[i].TruncatedEntries]));
    end;
    if FObservations[i].SkippedRecords > 0 then
    begin
      Result.Coverage := cvPartial;
      AddCov(Format('%s: %d records of the file were not opened', [FProfile.Sources[i].Name,
        FObservations[i].SkippedRecords]));
    end;
    if FObservations[i].Completion.ContinuationsIgnored + FObservations[i].Completion.ReferralsIgnored > 0 then
    begin
      Result.Coverage := cvPartial;
      AddCov(FProfile.Sources[i].Name + ': referrals were not followed');
    end;
    if FObservations[i].MissingIdentity > 0 then
    begin
      Result.Coverage := cvPartial;
      AddCov(Format('%s: %d entries without a usable identity', [FProfile.Sources[i].Name,
        FObservations[i].MissingIdentity]));
    end;
    if FObservations[i].OutsideBase > 0 then
      AddCov(Format('%s: %d entries outside the base were ignored', [FProfile.Sources[i].Name,
        FObservations[i].OutsideBase]));
    if (FProfile.Strictness = csSemantic) and not FObservations[i].SchemaAvailable then
      AddCov(FProfile.Sources[i].Name + ': schema unavailable, semantic rules not applied');
  end;
  if not FProfile.AclAttestation then
    AddCov('Access-control visibility is not attested: hidden data cannot be compared.')
  else
    AddCov('Hypothesis attested by the operator: identities see equivalent data.');
  if AExecution <> esCompleted then
    Result.Coverage := cvPartial;
  if AMarkersMoved then
  begin
    Result.Stability := stMoving;
    AddStab('replication markers changed during the read');
  end
  else if FCounters.TransientKeys + FCounters.PersistentKeys > 0 then
  begin
    Result.Stability := stPresumedStable;
    AddStab('differences were read again after the stabilization delay');
  end
  else
    Result.Stability := stNotAssessed;
  if FCounters.TransientKeys > 0 then
    AddStab(Format('%d transient divergences observed', [FCounters.TransientKeys]));
  certain := False;
  undetermined := False;
  for i := 0 to FDiffs.Count - 1 do
  begin
    d := TEntryDiff(FDiffs[i]);
    if d.Persistence = psTransient then Continue;
    if (dkAmbiguous in d.Kinds) or d.OnlySemanticUndetermined then
      undetermined := True
    else
      certain := True;
  end;
  if FProfile.Mode = cmIndicators then
    Result.Result := rsIndicatorsOnly
  else if FProfile.Mode = cmSample then
  begin
    if certain then Result.Result := rsSampleDivergent else Result.Result := rsSampleConcordant;
  end
  else if certain then
    Result.Result := rsDivergencesObserved
  else if undetermined then
    Result.Result := rsUndetermined
  else
    Result.Result := rsEqualObserved;
  Result.Headline := VerdictHeadline(Result, FProfile.Mode);
end;

function TComparisonEngine.DiffCount: Integer;
begin
  Result := FDiffs.Count;
end;

function TComparisonEngine.Diff(AIndex: Integer): TEntryDiff;
begin
  Result := TEntryDiff(FDiffs[AIndex]);
end;

function TComparisonEngine.FindDiff(const AKeyHash: string): TEntryDiff;
var
  i: Integer;
begin
  for i := 0 to FDiffs.Count - 1 do
    if TEntryDiff(FDiffs[i]).KeyHash = AKeyHash then
      Exit(TEntryDiff(FDiffs[i]));
  Result := nil;
end;

function TComparisonEngine.VariantAttributes(ADiff: TEntryDiff; AVariant: Integer): TCanonAttrs;
begin
  Result := DecodeRecord(FStore.Get(ADiff.Variants[AVariant].Handle));
end;

end.
