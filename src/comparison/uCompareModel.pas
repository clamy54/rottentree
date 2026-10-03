// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCompareModel;

{$mode objfpc}{$H+}

// Profils et executions de comparaison. Le verdict a plusieurs axes (execution,
// couverture, stabilite, resultat), jamais un booleen "synchronise": lire plusieurs
// serveurs l'un apres l'autre ne fait pas un instantane, n'en deplaise a l'optimisme.

interface

uses
  SysUtils, Classes, fpjson, uSearchModel;

const
  COMPARE_PROFILE_VERSION = 1;
  COMPARE_MIN_SOURCES = 2;
  COMPARE_MAX_SOURCES = 16;
  CANONICAL_FORMAT_VERSION = 1;
  REPORT_FORMAT_VERSION = 1;

  PERMANENT_CAVEAT =
    'Reading several directories over LDAP is not a distributed snapshot. Identical ' +
    'reads do not prove equality of data hidden by access controls, of secrets, or ' +
    'of internal replication state.';

type
  TCompareMode = (cmIndicators, cmSample, cmFull);
  TCompareTopology = (ctReference, ctSymmetric);
  TCompareStrictness = (csStrict, csSemantic);
  TIdentityMode = (imRelativeDn, imEntryUuid, imObjectGuid, imBusinessKey);

  TCompareSource = record
    ProfileUuid: string;
    Name: string;
    BaseDn: string;
    LdifPath: string;
  end;

  TComparisonProfile = class
  public
    Uuid: string;
    Name: string;
    Version: Integer;
    Sources: array of TCompareSource;
    ReferenceIndex: Integer;
    Topology: TCompareTopology;
    Mode: TCompareMode;
    Strictness: TCompareStrictness;
    Identity: TIdentityMode;
    BusinessKeyAttr: string;
    Scope: TSearchScope;
    Filter: string;
    IncludeAttrs: TStringList;
    ExcludeAttrs: TStringList;
    IncludeOperational: Boolean;
    RewriteDnValues: Boolean;
    SampleSize: Integer;
    SecondPass: Boolean;
    PassDelaySec: Integer;
    StabilizationWindowSec: Integer;
    DerefAliases: TAliasDeref;
    AclAttestation: Boolean;
    MemoryBudgetMiB: Integer;
    TempQuotaMiB: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Assign(ASource: TComparisonProfile);
    function Validate(out AErrors: TStringArray): Boolean;
    function IsExcluded(const AAttr: string): Boolean;
    function IsIncluded(const AAttr: string): Boolean;
    function ToJson: TJSONObject;
    procedure LoadJson(AObj: TJSONObject);
  end;

  TExecutionState = (esRunning, esCompleted, esFailed, esCancelled);
  TCoverageState = (cvComplete, cvPartial, cvUnknown);
  TStabilityState = (stNotAssessed, stPresumedStable, stMoving);
  TResultState = (rsEqualObserved, rsDivergencesObserved, rsUndetermined,
    rsIndicatorsOnly, rsSampleConcordant, rsSampleDivergent, rsNone);

  TSourceObservation = record
    Name: string;
    Endpoint: string;
    TransportLabel: string;
    BoundIdentity: string;
    AuthzId: string;
    BaseDn: string;
    Completion: TSearchCompletion;
    EntryCount: Int64;
    DuplicateKeys: Int64;
    MissingIdentity: Int64;
    OutsideBase: Int64;
    TruncatedEntries: Int64;
    SkippedRecords: Int64;
    SchemaAvailable: Boolean;
    MarkersBefore: TStringArray;
    MarkersAfter: TStringArray;
    Errors: TStringArray;
    StartedUtc: TDateTime;
    FinishedUtc: TDateTime;
  end;

  TVerdict = record
    Execution: TExecutionState;
    Coverage: TCoverageState;
    Stability: TStabilityState;
    Result: TResultState;
    CoverageReasons: TStringArray;
    StabilityReasons: TStringArray;
    Headline: string;
  end;

function ModeName(AMode: TCompareMode): string;
function IdentityName(AMode: TIdentityMode): string;
function ResultStateName(AState: TResultState): string;
function CoverageName(AState: TCoverageState): string;
function StabilityName(AState: TStabilityState): string;
function ExecutionName(AState: TExecutionState): string;

function VerdictHeadline(const V: TVerdict; AMode: TCompareMode): string;

implementation

uses
  uLdapEntry, uSensitive, uLdapDn, uLdapFilter;

function ModeName(AMode: TCompareMode): string;
begin
  case AMode of
    cmIndicators: Result := 'indicators';
    cmSample: Result := 'sample';
  else
    Result := 'full';
  end;
end;

function IdentityName(AMode: TIdentityMode): string;
begin
  case AMode of
    imEntryUuid: Result := 'entryUUID';
    imObjectGuid: Result := 'objectGUID';
    imBusinessKey: Result := 'business key';
  else
    Result := 'DN relative to base';
  end;
end;

function ResultStateName(AState: TResultState): string;
begin
  case AState of
    rsEqualObserved: Result := 'Equal on the observed scope';
    rsDivergencesObserved: Result := 'Divergences observed';
    rsUndetermined: Result := 'Undetermined';
    rsIndicatorsOnly: Result := 'Indicators only (no data equality claim)';
    rsSampleConcordant: Result := 'Sample concordant (not a global verdict)';
    rsSampleDivergent: Result := 'Sample divergent';
  else
    Result := 'No result';
  end;
end;

function CoverageName(AState: TCoverageState): string;
begin
  case AState of
    cvComplete: Result := 'complete read';
    cvPartial: Result := 'partial / visibility not established';
  else
    Result := 'unknown';
  end;
end;

function StabilityName(AState: TStabilityState): string;
begin
  case AState of
    stPresumedStable: Result := 'presumed stable';
    stMoving: Result := 'moving read';
  else
    Result := 'not assessed';
  end;
end;

function ExecutionName(AState: TExecutionState): string;
begin
  case AState of
    esRunning: Result := 'running';
    esCompleted: Result := 'completed';
    esFailed: Result := 'failed';
  else
    Result := 'cancelled';
  end;
end;

function VerdictHeadline(const V: TVerdict; AMode: TCompareMode): string;
begin
  if V.Execution in [esFailed, esCancelled] then
    Exit('Failed / cancelled (results already read are partial)');
  if AMode = cmIndicators then
    Exit(ResultStateName(rsIndicatorsOnly));
  case V.Result of
    rsDivergencesObserved: Result := ResultStateName(rsDivergencesObserved);
    rsUndetermined: Result := ResultStateName(rsUndetermined);
    rsSampleConcordant, rsSampleDivergent: Result := ResultStateName(V.Result);
    rsEqualObserved:
      begin
        if V.Coverage <> cvComplete then
          Result := 'Partial / visibility not established'
        else if V.Stability = stMoving then
          Result := 'Moving read (limited temporal conclusion)'
        else
          Result := ResultStateName(rsEqualObserved);
      end;
  else
    Result := ResultStateName(V.Result);
  end;
end;

constructor TComparisonProfile.Create;
var
  ex: TStringArray;
  i: Integer;
begin
  inherited Create;
  IncludeAttrs := TStringList.Create;
  IncludeAttrs.CaseSensitive := False;
  ExcludeAttrs := TStringList.Create;
  ExcludeAttrs.CaseSensitive := False;
  ex := DefaultComparisonExclusions;
  for i := 0 to High(ex) do
    ExcludeAttrs.Add(ex[i]);
  Version := 1;
  Topology := ctSymmetric;
  Mode := cmFull;
  Strictness := csStrict;
  Identity := imRelativeDn;
  Scope := ssSubtree;
  Filter := '(objectClass=*)';
  SampleSize := 1000;
  SecondPass := True;
  PassDelaySec := 5;
  StabilizationWindowSec := 30;
  DerefAliases := adNever;
  MemoryBudgetMiB := 256;
  TempQuotaMiB := 2048;
end;

destructor TComparisonProfile.Destroy;
begin
  IncludeAttrs.Free;
  ExcludeAttrs.Free;
  inherited Destroy;
end;

procedure TComparisonProfile.Assign(ASource: TComparisonProfile);
begin
  Uuid := ASource.Uuid;
  Name := ASource.Name;
  Version := ASource.Version;
  Sources := Copy(ASource.Sources);
  ReferenceIndex := ASource.ReferenceIndex;
  Topology := ASource.Topology;
  Mode := ASource.Mode;
  Strictness := ASource.Strictness;
  Identity := ASource.Identity;
  BusinessKeyAttr := ASource.BusinessKeyAttr;
  Scope := ASource.Scope;
  Filter := ASource.Filter;
  IncludeAttrs.Assign(ASource.IncludeAttrs);
  ExcludeAttrs.Assign(ASource.ExcludeAttrs);
  IncludeOperational := ASource.IncludeOperational;
  RewriteDnValues := ASource.RewriteDnValues;
  SampleSize := ASource.SampleSize;
  SecondPass := ASource.SecondPass;
  PassDelaySec := ASource.PassDelaySec;
  StabilizationWindowSec := ASource.StabilizationWindowSec;
  DerefAliases := ASource.DerefAliases;
  AclAttestation := ASource.AclAttestation;
  MemoryBudgetMiB := ASource.MemoryBudgetMiB;
  TempQuotaMiB := ASource.TempQuotaMiB;
end;

function TComparisonProfile.Validate(out AErrors: TStringArray): Boolean;

  procedure Add(const S: string);
  begin
    SetLength(AErrors, Length(AErrors) + 1);
    AErrors[High(AErrors)] := S;
  end;

var
  i: Integer;
  d: TLdapDn;
  err: string;
  f: TFilterNode;
begin
  AErrors := nil;
  if (Length(Sources) < COMPARE_MIN_SOURCES) or (Length(Sources) > COMPARE_MAX_SOURCES) then
    Add(Format('A comparison needs between %d and %d directories.', [COMPARE_MIN_SOURCES,
      COMPARE_MAX_SOURCES]));
  for i := 0 to High(Sources) do
  begin
    if (Sources[i].ProfileUuid = '') and (Sources[i].LdifPath = '') then
      Add(Format('Directory %d has no connection profile.', [i + 1]));
    if not DnParse(Sources[i].BaseDn, d, err) then
      Add(Format('Directory %d: invalid base DN (%s).', [i + 1, err]));
  end;
  if (Topology = ctReference) and ((ReferenceIndex < 0) or (ReferenceIndex > High(Sources))) then
    Add('Choose the reference directory.');
  f := FilterParse(Filter, err);
  if f = nil then
    Add('Invalid filter: ' + err)
  else
    f.Free;
  if (Identity = imBusinessKey) and (Trim(BusinessKeyAttr) = '') then
    Add('A business key attribute is required.');
  if (Mode = cmSample) and (SampleSize < 1) then
    Add('The sample size must be positive.');
  if (PassDelaySec < 0) or (PassDelaySec > 3600) or (StabilizationWindowSec < 0) or
     (StabilizationWindowSec > 86400) then
    Add('Stabilization delays are out of range.');
  if (MemoryBudgetMiB < 16) or (TempQuotaMiB < 16) then
    Add('Budgets are too small.');
  Result := Length(AErrors) = 0;
end;

function TComparisonProfile.IsExcluded(const AAttr: string): Boolean;
begin
  Result := ExcludeAttrs.IndexOf(AttrBaseName(AAttr)) >= 0;
end;

function TComparisonProfile.IsIncluded(const AAttr: string): Boolean;
begin
  Result := (IncludeAttrs.Count = 0) or (IncludeAttrs.IndexOf(AttrBaseName(AAttr)) >= 0);
end;

function StringsJson(AList: TStrings): TJSONArray;
var
  i: Integer;
begin
  Result := TJSONArray.Create;
  for i := 0 to AList.Count - 1 do
    Result.Add(AList[i]);
end;

function TComparisonProfile.ToJson: TJSONObject;
var
  arr: TJSONArray;
  src: TJSONObject;
  i: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('format', COMPARE_PROFILE_VERSION);
  Result.Add('uuid', Uuid);
  Result.Add('name', Name);
  Result.Add('version', Version);
  arr := TJSONArray.Create;
  for i := 0 to High(Sources) do
  begin
    src := TJSONObject.Create;
    src.Add('profile', Sources[i].ProfileUuid);
    src.Add('name', Sources[i].Name);
    src.Add('baseDn', Sources[i].BaseDn);
    if Sources[i].LdifPath <> '' then
      src.Add('ldifPath', Sources[i].LdifPath);
    arr.Add(src);
  end;
  Result.Add('sources', arr);
  Result.Add('referenceIndex', ReferenceIndex);
  Result.Add('topology', Ord(Topology));
  Result.Add('mode', Ord(Mode));
  Result.Add('strictness', Ord(Strictness));
  Result.Add('identity', Ord(Identity));
  Result.Add('businessKey', BusinessKeyAttr);
  Result.Add('scope', Ord(Scope));
  Result.Add('filter', Filter);
  Result.Add('include', StringsJson(IncludeAttrs));
  Result.Add('exclude', StringsJson(ExcludeAttrs));
  Result.Add('includeOperational', IncludeOperational);
  Result.Add('rewriteDnValues', RewriteDnValues);
  Result.Add('sampleSize', SampleSize);
  Result.Add('secondPass', SecondPass);
  Result.Add('passDelaySec', PassDelaySec);
  Result.Add('stabilizationWindowSec', StabilizationWindowSec);
  Result.Add('derefAliases', Ord(DerefAliases));
  Result.Add('aclAttestation', AclAttestation);
  Result.Add('memoryBudgetMiB', MemoryBudgetMiB);
  Result.Add('tempQuotaMiB', TempQuotaMiB);
end;

procedure TComparisonProfile.LoadJson(AObj: TJSONObject);
var
  arr: TJSONArray;
  i: Integer;
  src: TJSONObject;

  function Clamp(V, AMin, AMax: Integer): Integer;
  begin
    if (V < AMin) or (V > AMax) then
      raise Exception.Create('comparison profile value out of range');
    Result := V;
  end;

begin
  if AObj.Get('format', 0) > COMPARE_PROFILE_VERSION then
    raise Exception.Create('comparison profile format is newer than supported');
  Uuid := AObj.Get('uuid', '');
  Name := AObj.Get('name', '');
  Version := AObj.Get('version', 1);
  Sources := nil;
  arr := AObj.Get('sources', TJSONArray(nil));
  if arr <> nil then
  begin
    if arr.Count > COMPARE_MAX_SOURCES then
      raise Exception.Create('too many sources');
    SetLength(Sources, arr.Count);
    for i := 0 to arr.Count - 1 do
    begin
      if not (arr.Items[i] is TJSONObject) then
        raise Exception.Create('invalid source');
      src := TJSONObject(arr.Items[i]);
      Sources[i].ProfileUuid := src.Get('profile', '');
      Sources[i].Name := src.Get('name', '');
      Sources[i].BaseDn := src.Get('baseDn', '');
      Sources[i].LdifPath := src.Get('ldifPath', '');
    end;
  end;
  ReferenceIndex := AObj.Get('referenceIndex', 0);
  Topology := TCompareTopology(Clamp(AObj.Get('topology', 1), 0, Ord(High(TCompareTopology))));
  Mode := TCompareMode(Clamp(AObj.Get('mode', Ord(cmFull)), 0, Ord(High(TCompareMode))));
  Strictness := TCompareStrictness(Clamp(AObj.Get('strictness', 0), 0, Ord(High(TCompareStrictness))));
  Identity := TIdentityMode(Clamp(AObj.Get('identity', 0), 0, Ord(High(TIdentityMode))));
  BusinessKeyAttr := AObj.Get('businessKey', '');
  Scope := TSearchScope(Clamp(AObj.Get('scope', Ord(ssSubtree)), 0, Ord(High(TSearchScope))));
  Filter := AObj.Get('filter', '(objectClass=*)');
  IncludeAttrs.Clear;
  arr := AObj.Get('include', TJSONArray(nil));
  if arr <> nil then
    for i := 0 to arr.Count - 1 do IncludeAttrs.Add(arr.Strings[i]);
  arr := AObj.Get('exclude', TJSONArray(nil));
  if arr <> nil then
  begin
    ExcludeAttrs.Clear;
    for i := 0 to arr.Count - 1 do ExcludeAttrs.Add(arr.Strings[i]);
  end;
  IncludeOperational := AObj.Get('includeOperational', False);
  RewriteDnValues := AObj.Get('rewriteDnValues', False);
  SampleSize := AObj.Get('sampleSize', 1000);
  SecondPass := AObj.Get('secondPass', True);
  PassDelaySec := AObj.Get('passDelaySec', 5);
  StabilizationWindowSec := AObj.Get('stabilizationWindowSec', 30);
  DerefAliases := TAliasDeref(Clamp(AObj.Get('derefAliases', 0), 0, 3));
  AclAttestation := AObj.Get('aclAttestation', False);
  MemoryBudgetMiB := AObj.Get('memoryBudgetMiB', 256);
  TempQuotaMiB := AObj.Get('tempQuotaMiB', 2048);
end;

end.
