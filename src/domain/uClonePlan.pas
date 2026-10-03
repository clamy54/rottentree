// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uClonePlan;

{$mode objfpc}{$H+}

// Clonage d'une entree et copie de branche. Le clone laisse au serveur ce qui
// lui appartient (UUID, GUID, SID, etat de compte, memberOf) et ne recopie aucun
// secret: un jumeau qui partage le SID de l'original partage aussi ses ennuis.
// Les references DN internes ne sont reecrites que sur demande explicite.

interface

uses
  SysUtils, Classes, uLdapEntry, uLdapSchema, uSensitive, uLdapDn;

const
  SYNTAX_DN = '1.3.6.1.4.1.1466.115.121.1.12';
  SYNTAX_NAME_AND_UID = '1.3.6.1.4.1.1466.115.121.1.34';

  // Plafond cumule de la collecte d'une copie de branche, en octets et en entrees:
  // au-dela, la lecture s'arrete avant la moindre ecriture.
  COLLECT_MAX_BYTES = Int64(256) * 1024 * 1024;
  COLLECT_MAX_ENTRIES = 200000;

type
  TCloneReason = (
    crKept,
    crOperational,
    crServerIdentifier,
    crServerState,
    crBackLink,
    crSecret
  );

  TCloneAttrNote = record
    Attr: string;
    Reason: TCloneReason;
  end;
  TCloneAttrNotes = array of TCloneAttrNote;

  TCloneOptions = record
    Schema: TSchemaSnapshot;
    Sensitive: TSensitivePolicy;
  end;

  TBranchRefKind = (brkInternal, brkExternal);

  TBranchRef = record
    EntryIndex: Integer;
    Attr: string;
    Value: string;
    Rewritten: string;
    Kind: TBranchRefKind;
  end;
  TBranchRefArray = array of TBranchRef;

  TBranchCopyPlan = class
  private
    FSourceBase: string;
    FTargetBase: string;
    FSameDirectory: Boolean;
    FSources: TList;
    FSourceBytes: Int64;
    FTargets: TList;
    FOrder: array of Integer;
    FRefs: TBranchRefArray;
    FExcluded: TCloneAttrNotes;
    FReview: TStringList;
    function GetTarget(AIndex: Integer): TLdapEntry;
    function GetSource(AIndex: Integer): TLdapEntry;
    function GetSourceDn(AIndex: Integer): string;
    procedure ClearTargets;
    procedure NoteExcluded(const ANotes: TCloneAttrNotes);
  public
    constructor Create(const ASourceBase, ATargetBase: string;
      ASameDirectory: Boolean = True);
    destructor Destroy; override;
    function AddSource(AEntry: TLdapEntry): Boolean;
    function SourceCount: Integer;
    function Build(const AOptions: TCloneOptions; ARewriteInternal: Boolean;
      out AError: string): Boolean;
    function Count: Integer;
    property SourceBase: string read FSourceBase;
    property TargetBase: string read FTargetBase;
    property SameDirectory: Boolean read FSameDirectory;
    property SourceBytes: Int64 read FSourceBytes;
    property Targets[AIndex: Integer]: TLdapEntry read GetTarget;
    property Sources[AIndex: Integer]: TLdapEntry read GetSource;
    property SourceDns[AIndex: Integer]: string read GetSourceDn;
    property Refs: TBranchRefArray read FRefs;
    property Excluded: TCloneAttrNotes read FExcluded;
    property Review: TStringList read FReview;
  end;

resourcestring
  rsCloneKept = 'kept';
  rsCloneOperational = 'operational or not user-modifiable';
  rsCloneIdentifier = 'identifier assigned by the server';
  rsCloneState = 'account state kept by the server';
  rsCloneBackLink = 'computed back-link';
  rsCloneSecret = 'secret';
  rsCloneBadDn = 'invalid DN: %s';
  rsCloneNotUnder = '%s is not under %s';
  rsCloneNoRoot = 'the branch root %s was not read';
  rsCloneTargetInside = 'the destination is inside the copied branch';
  rsCloneRdnMissing = 'the new RDN attribute %s is not allowed to be empty';
  rsCloneTruncated = '%s was not read completely: re-read the entry before copying it';

function DefaultCloneOptions: TCloneOptions;
function CloneReasonText(AReason: TCloneReason): string;
function CloneExclusion(const AAttr: string; const AOptions: TCloneOptions): TCloneReason;
function CloneNeedsReview(const AAttr: string): Boolean;
function CloneEntry(ASource: TLdapEntry; const ANewDn: string; const AOptions: TCloneOptions;
  out ANotes: TCloneAttrNotes; out AError: string): TLdapEntry;
function IsDnValuedAttr(const AAttr: string; ASchema: TSchemaSnapshot): Boolean;

implementation

const
  // TotalBytes ne compte que les octets: sans surcharge par valeur et par attribut,
  // un million de valeurs vides passeraient gratis.
  COLLECT_VALUE_OVERHEAD_BYTES = 32;

  IDENTIFIER_ATTRS: array[0..9] of string = (
    'objectguid', 'objectsid', 'sidhistory', 'entryuuid', 'nsuniqueid', 'guid',
    'ipauniqueid', 'ms-ds-consistencyguid', 'msds-externaldirectoryobjectid', 'uniqueidentifier');

  // Attributs geres par le serveur que tout schema ne declare pas operationnels:
  // AD, entre autres, les publie comme attributs utilisateur.
  OPERATIONAL_ATTRS: array[0..27] of string = (
    'createtimestamp', 'modifytimestamp', 'creatorsname', 'modifiersname', 'entrycsn',
    'entrydn', 'subschemasubentry', 'hassubordinates', 'numsubordinates',
    'structuralobjectclass', 'contextcsn', 'whencreated', 'whenchanged', 'usncreated',
    'usnchanged', 'instancetype', 'distinguishedname', 'name', 'iscriticalsystemobject',
    'systemflags', 'dscorepropagationdata', 'replpropertymetadata', 'objectcategory',
    'msds-approx-immed-subordinates', 'revision', 'nsparentuniqueid', 'entryid', 'parentid');

  STATE_ATTRS: array[0..22] of string = (
    'pwdlastset', 'lastlogon', 'lastlogontimestamp', 'lastlogoff', 'logoncount',
    'badpwdcount', 'badpasswordtime', 'lockouttime', 'admincount',
    'pwdchangedtime', 'pwdfailuretime', 'pwdaccountlockedtime', 'pwdgraceusetime',
    'pwdreset', 'pwdlastsuccess',
    'passwordretrycount', 'retrycountresettime', 'accountunlocktime',
    'passwordexpirationtime', 'passwordexpwarned', 'passwordgraceusertime',
    'passwordallowchangetime', 'lastlogintime');

  BACKLINK_ATTRS: array[0..3] of string = (
    'memberof', 'ismemberof', 'directreports', 'managedobjects');

  REVIEW_ATTRS: array[0..9] of string = (
    'samaccountname', 'userprincipalname', 'serviceprincipalname', 'mail', 'uidnumber',
    'employeeid', 'employeenumber', 'uid', 'gidnumber', 'krbprincipalname');

  DN_ATTRS: array[0..12] of string = (
    'member', 'uniquemember', 'owner', 'manager', 'secretary', 'seealso', 'roleoccupant',
    'nsroledn', 'managedby', 'memberof', 'aliasedobjectname', 'pwdpolicysubentry',
    'distinguishedname');

function InList(const ALower: string; const AList: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AList) do
    if AList[i] = ALower then Exit(True);
  Result := False;
end;

function DefaultCloneOptions: TCloneOptions;
begin
  Result := Default(TCloneOptions);
end;

function CloneReasonText(AReason: TCloneReason): string;
begin
  case AReason of
    crOperational: Result := rsCloneOperational;
    crServerIdentifier: Result := rsCloneIdentifier;
    crServerState: Result := rsCloneState;
    crBackLink: Result := rsCloneBackLink;
    crSecret: Result := rsCloneSecret;
  else
    Result := rsCloneKept;
  end;
end;

function CloneExclusion(const AAttr: string; const AOptions: TCloneOptions): TCloneReason;
var
  base, canon: string;
begin
  base := AsciiLowerCase(AttrBaseName(AAttr));
  canon := base;
  if AOptions.Schema <> nil then
  begin
    canon := AsciiLowerCase(AOptions.Schema.CanonicalAttrName(base));
    if canon = '' then canon := base;
  end;
  if (AOptions.Sensitive <> nil) and AOptions.Sensitive.IsSensitive(AAttr) then
    Exit(crSecret);
  if IsBuiltinSensitiveAttr(AAttr) then Exit(crSecret);
  if InList(base, IDENTIFIER_ATTRS) or InList(canon, IDENTIFIER_ATTRS) then
    Exit(crServerIdentifier);
  if InList(base, BACKLINK_ATTRS) or InList(canon, BACKLINK_ATTRS) then
    Exit(crBackLink);
  if InList(base, STATE_ATTRS) or InList(canon, STATE_ATTRS) then
    Exit(crServerState);
  if InList(base, OPERATIONAL_ATTRS) or InList(canon, OPERATIONAL_ATTRS) then
    Exit(crOperational);
  if (AOptions.Schema <> nil) and (AOptions.Schema.IsOperational(base) or
     AOptions.Schema.IsNoUserModification(base)) then
    Exit(crOperational);
  Result := crKept;
end;

function CloneNeedsReview(const AAttr: string): Boolean;
begin
  Result := InList(AsciiLowerCase(AttrBaseName(AAttr)), REVIEW_ATTRS);
end;

function IsDnValuedAttr(const AAttr: string; ASchema: TSchemaSnapshot): Boolean;
var
  syn: string;
begin
  if ASchema <> nil then
  begin
    syn := ASchema.EffectiveSyntax(AttrBaseName(AAttr));
    if syn <> '' then
      Exit((syn = SYNTAX_DN) or (syn = SYNTAX_NAME_AND_UID));
  end;
  Result := InList(AsciiLowerCase(AttrBaseName(AAttr)), DN_ATTRS);
end;

procedure AddNote(var ANotes: TCloneAttrNotes; const AAttr: string; AReason: TCloneReason);
begin
  SetLength(ANotes, Length(ANotes) + 1);
  ANotes[High(ANotes)].Attr := AAttr;
  ANotes[High(ANotes)].Reason := AReason;
end;

function StripRangeOption(const ADescription: string): string;
var
  d: TAttrDescription;
  i: Integer;
begin
  d := ParseAttrDescription(ADescription);
  Result := d.Base;
  for i := 0 to High(d.Options) do
    if not SameText(Copy(d.Options[i], 1, 6), 'range=') then
      Result := Result + ';' + d.Options[i];
end;

function IndexOfValueCi(AAttr: TLdapAttribute; const AValue: RawByteString): Integer;
var
  i: Integer;
begin
  Result := AAttr.IndexOfValue(AValue);
  if Result >= 0 then Exit;
  for i := 0 to AAttr.ValueCount - 1 do
    if SameText(AAttr.Values[i], AValue) then Exit(i);
  Result := -1;
end;

function CloneEntry(ASource: TLdapEntry; const ANewDn: string; const AOptions: TCloneOptions;
  out ANotes: TCloneAttrNotes; out AError: string): TLdapEntry;
var
  oldDn, newDn: TLdapDn;
  i, k: Integer;
  src: TLdapAttribute;
  reason: TCloneReason;
  a: TLdapAttribute;
  oldRdn, newRdn: TDnRdn;
begin
  Result := nil;
  ANotes := nil;
  AError := '';
  if not DnParse(ASource.Dn, oldDn, AError) then
  begin
    AError := Format(rsCloneBadDn, [ASource.Dn]);
    Exit;
  end;
  if not DnParse(ANewDn, newDn, AError) or (DnRdnCount(newDn) = 0) then
  begin
    AError := Format(rsCloneBadDn, [ANewDn]);
    Exit;
  end;
  Result := TLdapEntry.Create(ANewDn);
  for i := 0 to ASource.AttrCount - 1 do
  begin
    src := ASource.Attrs[i];
    reason := CloneExclusion(src.Description, AOptions);
    if reason <> crKept then
    begin
      AddNote(ANotes, src.Description, reason);
      Continue;
    end;
    // Une copie partielle d'un attribut multivalue passerait pour complete.
    if src.Truncated then
    begin
      AError := Format(rsCloneTruncated, [src.Description]);
      FreeAndNil(Result);
      Exit;
    end;
    // L'option de plage AD decrit la lecture, pas l'attribut a ecrire. Les autres
    // options (;binary, ;lang-xx) restent.
    a := Result.Ensure(StripRangeOption(src.Description));
    for k := 0 to src.ValueCount - 1 do
      if a.IndexOfValue(src.Values[k]) < 0 then
        a.AddValue(src.Values[k]);
  end;
  if DnRdnCount(oldDn) > 0 then
  begin
    oldRdn := DnLeaf(oldDn);
    for i := 0 to High(oldRdn.Avas) do
    begin
      a := Result.Find(oldRdn.Avas[i].AttrType);
      if a = nil then Continue;
      k := IndexOfValueCi(a, oldRdn.Avas[i].Value);
      if k >= 0 then a.DeleteValue(k);
      if a.ValueCount = 0 then Result.Remove(a.Description);
    end;
  end;
  newRdn := DnLeaf(newDn);
  for i := 0 to High(newRdn.Avas) do
  begin
    if newRdn.Avas[i].Value = '' then
    begin
      AError := Format(rsCloneRdnMissing, [newRdn.Avas[i].AttrType]);
      FreeAndNil(Result);
      Exit;
    end;
    a := Result.Ensure(newRdn.Avas[i].AttrType);
    if IndexOfValueCi(a, newRdn.Avas[i].Value) < 0 then
      a.AddValue(newRdn.Avas[i].Value);
  end;
end;

constructor TBranchCopyPlan.Create(const ASourceBase, ATargetBase: string;
  ASameDirectory: Boolean);
begin
  inherited Create;
  FSourceBase := ASourceBase;
  FTargetBase := ATargetBase;
  FSameDirectory := ASameDirectory;
  FSources := TList.Create;
  FTargets := TList.Create;
  FReview := TStringList.Create;
  FReview.Sorted := True;
  FReview.Duplicates := dupIgnore;
  FReview.CaseSensitive := False;
end;

destructor TBranchCopyPlan.Destroy;
var
  i: Integer;
begin
  ClearTargets;
  for i := 0 to FSources.Count - 1 do
    TLdapEntry(FSources[i]).Free;
  FSources.Free;
  FTargets.Free;
  FReview.Free;
  inherited Destroy;
end;

procedure TBranchCopyPlan.ClearTargets;
var
  i: Integer;
begin
  for i := 0 to FTargets.Count - 1 do
    TLdapEntry(FTargets[i]).Free;
  FTargets.Clear;
  FOrder := nil;
  FRefs := nil;
  FExcluded := nil;
  FReview.Clear;
end;

function TBranchCopyPlan.AddSource(AEntry: TLdapEntry): Boolean;
var
  cmp: TDnComparer;
  d, b: TLdapDn;
  kept: TLdapEntry;
begin
  Result := False;
  if not (DnTryParse(AEntry.Dn, d) and DnTryParse(FSourceBase, b)) then Exit;
  cmp := TDnComparer.Create;
  try
    if cmp.IsUnder(d, b, True) <> dmEqual then Exit;
  finally
    cmp.Free;
  end;
  kept := AEntry.Clone;
  FSources.Add(kept);
  Inc(FSourceBytes, kept.TotalBytes +
    COLLECT_VALUE_OVERHEAD_BYTES * Int64(kept.TotalValueCount) +
    COLLECT_VALUE_OVERHEAD_BYTES * Int64(kept.AttrCount));
  Result := True;
end;

function TBranchCopyPlan.SourceCount: Integer;
begin
  Result := FSources.Count;
end;

function TBranchCopyPlan.Count: Integer;
begin
  Result := FTargets.Count;
end;

function TBranchCopyPlan.GetTarget(AIndex: Integer): TLdapEntry;
begin
  Result := TLdapEntry(FTargets[AIndex]);
end;

function TBranchCopyPlan.GetSource(AIndex: Integer): TLdapEntry;
begin
  Result := TLdapEntry(FSources[FOrder[AIndex]]);
end;

function TBranchCopyPlan.GetSourceDn(AIndex: Integer): string;
begin
  Result := TLdapEntry(FSources[FOrder[AIndex]]).Dn;
end;

procedure TBranchCopyPlan.NoteExcluded(const ANotes: TCloneAttrNotes);
var
  i, j: Integer;
  found: Boolean;
begin
  for i := 0 to High(ANotes) do
  begin
    found := False;
    for j := 0 to High(FExcluded) do
      if SameText(FExcluded[j].Attr, ANotes[i].Attr) and (FExcluded[j].Reason = ANotes[i].Reason) then
      begin
        found := True;
        Break;
      end;
    if not found then AddNote(FExcluded, ANotes[i].Attr, ANotes[i].Reason);
  end;
end;

// Syntaxe "Name and Optional UID": un DN suivi de #'bits'B. Un DN tout seul
// aurait ete trop simple.
procedure SplitOptionalUid(const AValue: string; out ADn, ASuffix: string);
var
  p: Integer;
begin
  ADn := AValue;
  ASuffix := '';
  if (Length(AValue) < 4) or (Copy(AValue, Length(AValue) - 1, 2) <> '''B') then Exit;
  p := Length(AValue) - 2;
  while (p > 1) and (AValue[p] in ['0', '1']) do Dec(p);
  if (p > 1) and (AValue[p] = '''') and (AValue[p - 1] = '#') then
  begin
    ADn := Copy(AValue, 1, p - 2);
    ASuffix := Copy(AValue, p - 1, MaxInt);
  end;
end;

function TBranchCopyPlan.Build(const AOptions: TCloneOptions; ARewriteInternal: Boolean;
  out AError: string): Boolean;
var
  cmp: TDnComparer;
  srcBase, tgtBase, d, mapped: TLdapDn;
  depths: array of Integer;
  i, j, k, t, rootIndex: Integer;
  src, target: TLdapEntry;
  notes: TCloneAttrNotes;
  a: TLdapAttribute;
  dnPart, suffix: string;
  valueDn: TLdapDn;
  ref: TBranchRef;
begin
  Result := False;
  AError := '';
  ClearTargets;
  if not DnTryParse(FSourceBase, srcBase) then
  begin
    AError := Format(rsCloneBadDn, [FSourceBase]);
    Exit;
  end;
  if not DnTryParse(FTargetBase, tgtBase) or (DnRdnCount(tgtBase) = 0) then
  begin
    AError := Format(rsCloneBadDn, [FTargetBase]);
    Exit;
  end;
  cmp := TDnComparer.Create;
  try
    // Sur le meme annuaire, une branche copiee sous elle-meme se recopierait sans
    // fin. Entre deux annuaires, le meme DN est legitime: le transfert prouve
    // l'identite de l'annuaire avant toute phase destructive.
    if FSameDirectory and (cmp.IsUnder(tgtBase, srcBase, True) <> dmDifferent) then
    begin
      AError := rsCloneTargetInside;
      Exit;
    end;
    SetLength(depths, FSources.Count);
    SetLength(FOrder, FSources.Count);
    rootIndex := -1;
    for i := 0 to FSources.Count - 1 do
    begin
      if not DnTryParse(TLdapEntry(FSources[i]).Dn, d) then
      begin
        AError := Format(rsCloneBadDn, [TLdapEntry(FSources[i]).Dn]);
        Exit;
      end;
      depths[i] := DnRdnCount(d);
      FOrder[i] := i;
      if cmp.CompareDn(d, srcBase) = dmEqual then rootIndex := i;
    end;
    if rootIndex < 0 then
    begin
      AError := Format(rsCloneNoRoot, [FSourceBase]);
      Exit;
    end;
    for i := 1 to High(FOrder) do
    begin
      t := FOrder[i];
      j := i - 1;
      while (j >= 0) and (depths[FOrder[j]] > depths[t]) do
      begin
        FOrder[j + 1] := FOrder[j];
        Dec(j);
      end;
      FOrder[j + 1] := t;
    end;
    for i := 0 to High(FOrder) do
    begin
      src := TLdapEntry(FSources[FOrder[i]]);
      DnTryParse(src.Dn, d);
      if not DnReplaceSuffix(cmp, d, srcBase, tgtBase, mapped) then
      begin
        AError := Format(rsCloneNotUnder, [src.Dn, FSourceBase]);
        Exit;
      end;
      target := CloneEntry(src, DnToString(mapped), AOptions, notes, AError);
      if target = nil then Exit;
      FTargets.Add(target);
      NoteExcluded(notes);
      for j := 0 to target.AttrCount - 1 do
      begin
        a := target.Attrs[j];
        if CloneNeedsReview(a.Description) then FReview.Add(AttrBaseName(a.Description));
        if not IsDnValuedAttr(a.Description, AOptions.Schema) then Continue;
        for k := 0 to a.ValueCount - 1 do
        begin
          SplitOptionalUid(a.Values[k], dnPart, suffix);
          if not DnTryParse(dnPart, valueDn) or DnIsEmpty(valueDn) then Continue;
          ref := Default(TBranchRef);
          ref.EntryIndex := i;
          ref.Attr := a.Description;
          ref.Value := a.Values[k];
          if cmp.IsUnder(valueDn, srcBase, True) = dmEqual then
          begin
            ref.Kind := brkInternal;
            if DnReplaceSuffix(cmp, valueDn, srcBase, tgtBase, mapped) then
              ref.Rewritten := DnToString(mapped) + suffix;
          end
          else
            ref.Kind := brkExternal;
          SetLength(FRefs, Length(FRefs) + 1);
          FRefs[High(FRefs)] := ref;
        end;
      end;
    end;
    if ARewriteInternal then
      for i := 0 to High(FRefs) do
        if (FRefs[i].Kind = brkInternal) and (FRefs[i].Rewritten <> '') then
        begin
          a := TLdapEntry(FTargets[FRefs[i].EntryIndex]).Find(FRefs[i].Attr);
          if a = nil then Continue;
          k := a.IndexOfValue(FRefs[i].Value);
          if k < 0 then Continue;
          a.DeleteValue(k);
          if a.IndexOfValue(FRefs[i].Rewritten) < 0 then
            a.AddValue(FRefs[i].Rewritten);
        end;
    Result := True;
  finally
    cmp.Free;
    if not Result then ClearTargets;
  end;
end;

end.
