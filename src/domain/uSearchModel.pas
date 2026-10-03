// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSearchModel;

{$mode objfpc}{$H+}

// Requete de recherche, pagination RFC 2696, plages Active Directory et verdict de fin.
// Une page manquante n'est pas un annuaire vide, quoi qu'en dise le rapport d'audit.

interface

uses
  SysUtils, Classes;

const
  LDAP_RC_SUCCESS = 0;
  LDAP_RC_OPERATIONS_ERROR = 1;
  LDAP_RC_PROTOCOL_ERROR = 2;
  LDAP_RC_TIMELIMIT_EXCEEDED = 3;
  LDAP_RC_SIZELIMIT_EXCEEDED = 4;
  LDAP_RC_COMPARE_FALSE = 5;
  LDAP_RC_COMPARE_TRUE = 6;
  LDAP_RC_AUTH_METHOD_NOT_SUPPORTED = 7;
  LDAP_RC_STRONGER_AUTH_REQUIRED = 8;
  LDAP_RC_REFERRAL = 10;
  LDAP_RC_ADMINLIMIT_EXCEEDED = 11;
  LDAP_RC_UNAVAILABLE_CRITICAL_EXTENSION = 12;
  LDAP_RC_CONFIDENTIALITY_REQUIRED = 13;
  LDAP_RC_SASL_BIND_IN_PROGRESS = 14;
  LDAP_RC_NO_SUCH_ATTRIBUTE = 16;
  LDAP_RC_UNDEFINED_TYPE = 17;
  LDAP_RC_INAPPROPRIATE_MATCHING = 18;
  LDAP_RC_CONSTRAINT_VIOLATION = 19;
  LDAP_RC_TYPE_OR_VALUE_EXISTS = 20;
  LDAP_RC_INVALID_SYNTAX = 21;
  LDAP_RC_NO_SUCH_OBJECT = 32;
  LDAP_RC_ALIAS_PROBLEM = 33;
  LDAP_RC_INVALID_DN_SYNTAX = 34;
  LDAP_RC_INAPPROPRIATE_AUTH = 48;
  LDAP_RC_INVALID_CREDENTIALS = 49;
  LDAP_RC_INSUFFICIENT_ACCESS = 50;
  LDAP_RC_BUSY = 51;
  LDAP_RC_UNAVAILABLE = 52;
  LDAP_RC_UNWILLING_TO_PERFORM = 53;
  LDAP_RC_LOOP_DETECT = 54;
  LDAP_RC_NAMING_VIOLATION = 64;
  LDAP_RC_OBJECT_CLASS_VIOLATION = 65;
  LDAP_RC_NOT_ALLOWED_ON_NONLEAF = 66;
  LDAP_RC_NOT_ALLOWED_ON_RDN = 67;
  LDAP_RC_ALREADY_EXISTS = 68;
  LDAP_RC_NO_OBJECT_CLASS_MODS = 69;
  LDAP_RC_AFFECTS_MULTIPLE_DSAS = 71;
  LDAP_RC_OTHER = 80;
  LDAP_RC_CANCELED = 118;
  LDAP_RC_ASSERTION_FAILED = 122;

  LDAP_RC_SERVER_DOWN = -1;
  LDAP_RC_LOCAL_ERROR = -2;
  LDAP_RC_ENCODING_ERROR = -3;
  LDAP_RC_DECODING_ERROR = -4;
  LDAP_RC_TIMEOUT = -5;
  LDAP_RC_AUTH_UNKNOWN = -6;
  LDAP_RC_FILTER_ERROR = -7;
  LDAP_RC_USER_CANCELLED = -8;
  LDAP_RC_PARAM_ERROR = -9;
  LDAP_RC_NO_MEMORY = -10;
  LDAP_RC_CONNECT_ERROR = -11;
  LDAP_RC_NOT_SUPPORTED = -12;
  LDAP_RC_CONTROL_NOT_FOUND = -13;
  LDAP_RC_NO_RESULTS_RETURNED = -14;
  LDAP_RC_MORE_RESULTS_TO_RETURN = -15;
  LDAP_RC_CLIENT_LOOP = -16;
  LDAP_RC_REFERRAL_LIMIT_EXCEEDED = -17;

  AD_RANGE_MAX_ITERATIONS = 10000;
  PAGING_MAX_PAGES = 1000000;

type
  TSearchScope = (ssBase, ssOneLevel, ssSubtree);
  TAliasDeref = (adNever, adSearching, adFinding, adAlways);

  TRequestControl = record
    Oid: string;
    Critical: Boolean;
    HasValue: Boolean;
    Value: RawByteString;
  end;
  TRequestControlArray = array of TRequestControl;

  TSearchRequest = record
    BaseDn: string;
    Scope: TSearchScope;
    Filter: string;
    Attributes: array of string;
    TypesOnly: Boolean;
    PageSize: Integer;
    SizeLimit: Integer;
    ServerSizeLimit: Integer;
    TimeLimitSec: Integer;
    Deref: TAliasDeref;
    FollowReferrals: Boolean;
    Controls: TRequestControlArray;
  end;

  TSearchOutcome = (
    soComplete,
    soPartial,
    soFailed,
    soCancelled
  );

  TSearchCompletion = record
    // Renseigne par une vraie fin de recherche. Une completion restee a zero n'est JAMAIS
    // presentee comme complete: un faux "tout est la" coute plus cher qu'un "je ne sais
    // pas".
    HasResult: Boolean;
    ResultCode: Integer;
    DiagnosticMessage: string; // expurge par l'appelant avant affichage
    MatchedDn: string;
    EntryCount: Int64;
    PageCount: Integer;
    // Taille de page reellement appliquee: le serveur peut rendre moins que demande (RFC
    // 2696).
    FirstPageSize: Integer;
    SizeLimitHit: Boolean;
    TimeLimitHit: Boolean;
    ReferralsIgnored: Integer;
    ContinuationsIgnored: Integer;
    PagingAnomaly: string;
    RangeIncomplete: Boolean;
    Cancelled: Boolean;
    ClientLimitHit: Boolean;
    DecodeFailures: Integer;
    TruncatedEntries: Integer;
  end;

  TSearchRunState = (srsNoRun, srsRunning, srsDone, srsFailed);

  TPageVerdict = (pvContinue, pvDone, pvAnomaly);

  // Le cookie de pagination appartient a UNE session. Le resservir apres reconnexion,
  // c'est demander la suite d'une conversation que le serveur a deja oubliee.
  TPagingTracker = class
  private
    FSessionId: string;
    FGeneration: Int64;
    FSeen: TStringList;
    FLastCookie: RawByteString;
    FPages: Integer;
    FAnomaly: string;
  public
    constructor Create(const ASessionId: string; AGeneration: Int64);
    destructor Destroy; override;
    function OnPage(const ACookie: RawByteString; AEntriesInPage: Integer): TPageVerdict;
    function CookieUsableOn(const ASessionId: string; AGeneration: Int64): Boolean;
    property LastCookie: RawByteString read FLastCookie;
    property Pages: Integer read FPages;
    property Anomaly: string read FAnomaly;
  end;

  TRangeState = (rsComplete, rsNeedMore, rsPartial);

  // Une option range= malformee (vide, borne non numerique ou inversee, repetee) n'est
  // jamais prise pour un attribut ordinaire.
  TRangeParse = (rpNone, rpValid, rpMalformed);

  // Attribut AD livre par plages (member;range=0-1499). Une plage seule n'est jamais le
  // groupe entier, meme quand elle en a la tete.
  TRangeAssembler = class
  private
    FBase: string;
    FValues: array of RawByteString;
    FNextLow: Int64;
    FIterations: Integer;
    FState: TRangeState;
    FReason: string;
    FSeenRanges: TStringList;
  public
    constructor Create(const ABaseName: string);
    destructor Destroy; override;
    function Feed(const ADescription: string; const AValues: array of RawByteString): TRangeState;
    function NextRequest: string;
    function ValueCount: Integer;
    function Value(AIndex: Integer): RawByteString;
    property State: TRangeState read FState;
    property Reason: string read FReason;
  end;

function ScopeName(AScope: TSearchScope): string;
function SearchOutcome(const C: TSearchCompletion): TSearchOutcome;
function CoverageDescription(AState: TSearchRunState; const C: TSearchCompletion): string;
function DefaultSearchRequest: TSearchRequest;
// Contournement d'ApacheDS 2.0.0.AM27, qui gere mal '1.1' seul: pagine, il oublie le
// controle de reponse apres une page pleine et la fin passe pour complete; non pagine,
// une limite de taille finit en erreur interne (80). On demande donc 'objectClass' avec
// AStrip = True et la session jette les attributs recus: l'appelant voit la meme chose.
function WireAttributes(const AAttributes: array of string; out AStrip: Boolean): TStringArray;
function ParseRangeOption(const ADescription: string; out ABase: string;
  out ALow, AHigh: Int64): Boolean;
function ParseRangeOptionEx(const ADescription: string; out ABase: string;
  out ALow, AHigh: Int64): TRangeParse;
function ResultCodeName(ACode: Integer): string;

implementation

uses
  uRtBytes;

function ScopeName(AScope: TSearchScope): string;
begin
  case AScope of
    ssBase: Result := 'base';
    ssOneLevel: Result := 'oneLevel';
  else
    Result := 'subtree';
  end;
end;

function DefaultSearchRequest: TSearchRequest;
begin
  Result.BaseDn := '';
  Result.Scope := ssSubtree;
  Result.Filter := '(objectClass=*)';
  Result.Attributes := nil;
  Result.TypesOnly := False;
  Result.PageSize := 500;
  Result.SizeLimit := 10000;
  Result.ServerSizeLimit := 0;
  Result.TimeLimitSec := 30;
  Result.Deref := adNever;
  Result.FollowReferrals := False;
  Result.Controls := nil;
end;

function WireAttributes(const AAttributes: array of string; out AStrip: Boolean): TStringArray;
var
  i: Integer;
begin
  AStrip := (Length(AAttributes) = 1) and (AAttributes[0] = '1.1');
  if AStrip then
    Exit(['objectClass']);
  Result := nil;
  SetLength(Result, Length(AAttributes));
  for i := 0 to High(AAttributes) do
    Result[i] := AAttributes[i];
end;

function SearchOutcome(const C: TSearchCompletion): TSearchOutcome;
begin
  // Completion jamais renseignee: pas de reussite par defaut. Un record a zero se prenait
  // pour soComplete, et personne ne s'en plaignait. C'est bien le probleme.
  if not C.HasResult then Exit(soFailed);
  if C.Cancelled then Exit(soCancelled);
  if (C.ResultCode <> LDAP_RC_SUCCESS) and (C.ResultCode <> LDAP_RC_SIZELIMIT_EXCEEDED) and
     (C.ResultCode <> LDAP_RC_TIMELIMIT_EXCEEDED) and (C.ResultCode <> LDAP_RC_ADMINLIMIT_EXCEEDED) then
  begin
    if C.EntryCount > 0 then Exit(soPartial);
    Exit(soFailed);
  end;
  if C.SizeLimitHit or C.TimeLimitHit or C.ClientLimitHit or
     (C.ResultCode <> LDAP_RC_SUCCESS) or (C.ReferralsIgnored > 0) or
     (C.ContinuationsIgnored > 0) or (C.PagingAnomaly <> '') or C.RangeIncomplete or
     (C.DecodeFailures > 0) or (C.TruncatedEntries > 0) then
    Exit(soPartial);
  Result := soComplete;
end;

function CoverageDescription(AState: TSearchRunState; const C: TSearchCompletion): string;
begin
  case AState of
    srsNoRun: Result := 'no search run';
    srsRunning: Result := 'in progress (partial)';
    srsFailed: Result := 'failed (partial)';
  else
    case SearchOutcome(C) of
      soComplete: Result := 'complete';
      soCancelled: Result := 'cancelled (partial)';
      soFailed: Result := 'failed';
    else
      Result := 'partial';
    end;
  end;
end;

function ResultCodeName(ACode: Integer): string;
begin
  case ACode of
    LDAP_RC_SUCCESS: Result := 'success';
    LDAP_RC_OPERATIONS_ERROR: Result := 'operationsError';
    LDAP_RC_PROTOCOL_ERROR: Result := 'protocolError';
    LDAP_RC_TIMELIMIT_EXCEEDED: Result := 'timeLimitExceeded';
    LDAP_RC_SIZELIMIT_EXCEEDED: Result := 'sizeLimitExceeded';
    LDAP_RC_COMPARE_FALSE: Result := 'compareFalse';
    LDAP_RC_COMPARE_TRUE: Result := 'compareTrue';
    LDAP_RC_AUTH_METHOD_NOT_SUPPORTED: Result := 'authMethodNotSupported';
    LDAP_RC_STRONGER_AUTH_REQUIRED: Result := 'strongerAuthRequired';
    LDAP_RC_REFERRAL: Result := 'referral';
    LDAP_RC_ADMINLIMIT_EXCEEDED: Result := 'adminLimitExceeded';
    LDAP_RC_UNAVAILABLE_CRITICAL_EXTENSION: Result := 'unavailableCriticalExtension';
    LDAP_RC_CONFIDENTIALITY_REQUIRED: Result := 'confidentialityRequired';
    LDAP_RC_SASL_BIND_IN_PROGRESS: Result := 'saslBindInProgress';
    LDAP_RC_NO_SUCH_ATTRIBUTE: Result := 'noSuchAttribute';
    LDAP_RC_UNDEFINED_TYPE: Result := 'undefinedAttributeType';
    LDAP_RC_INAPPROPRIATE_MATCHING: Result := 'inappropriateMatching';
    LDAP_RC_CONSTRAINT_VIOLATION: Result := 'constraintViolation';
    LDAP_RC_TYPE_OR_VALUE_EXISTS: Result := 'attributeOrValueExists';
    LDAP_RC_INVALID_SYNTAX: Result := 'invalidAttributeSyntax';
    LDAP_RC_NO_SUCH_OBJECT: Result := 'noSuchObject';
    LDAP_RC_ALIAS_PROBLEM: Result := 'aliasProblem';
    LDAP_RC_INVALID_DN_SYNTAX: Result := 'invalidDNSyntax';
    LDAP_RC_INAPPROPRIATE_AUTH: Result := 'inappropriateAuthentication';
    LDAP_RC_INVALID_CREDENTIALS: Result := 'invalidCredentials';
    LDAP_RC_INSUFFICIENT_ACCESS: Result := 'insufficientAccessRights';
    LDAP_RC_BUSY: Result := 'busy';
    LDAP_RC_UNAVAILABLE: Result := 'unavailable';
    LDAP_RC_UNWILLING_TO_PERFORM: Result := 'unwillingToPerform';
    LDAP_RC_LOOP_DETECT: Result := 'loopDetect';
    LDAP_RC_NAMING_VIOLATION: Result := 'namingViolation';
    LDAP_RC_OBJECT_CLASS_VIOLATION: Result := 'objectClassViolation';
    LDAP_RC_NOT_ALLOWED_ON_NONLEAF: Result := 'notAllowedOnNonLeaf';
    LDAP_RC_NOT_ALLOWED_ON_RDN: Result := 'notAllowedOnRDN';
    LDAP_RC_ALREADY_EXISTS: Result := 'entryAlreadyExists';
    LDAP_RC_NO_OBJECT_CLASS_MODS: Result := 'objectClassModsProhibited';
    LDAP_RC_AFFECTS_MULTIPLE_DSAS: Result := 'affectsMultipleDSAs';
    LDAP_RC_OTHER: Result := 'other';
    LDAP_RC_CANCELED: Result := 'canceled';
    LDAP_RC_ASSERTION_FAILED: Result := 'assertionFailed';
    LDAP_RC_SERVER_DOWN: Result := 'serverDown';
    LDAP_RC_LOCAL_ERROR: Result := 'localError';
    LDAP_RC_ENCODING_ERROR: Result := 'encodingError';
    LDAP_RC_DECODING_ERROR: Result := 'decodingError';
    LDAP_RC_TIMEOUT: Result := 'timeout';
    LDAP_RC_AUTH_UNKNOWN: Result := 'authUnknown';
    LDAP_RC_FILTER_ERROR: Result := 'filterError';
    LDAP_RC_USER_CANCELLED: Result := 'userCancelled';
    LDAP_RC_PARAM_ERROR: Result := 'paramError';
    LDAP_RC_NO_MEMORY: Result := 'noMemory';
    LDAP_RC_CONNECT_ERROR: Result := 'connectError';
    LDAP_RC_NOT_SUPPORTED: Result := 'notSupported';
    LDAP_RC_CONTROL_NOT_FOUND: Result := 'controlNotFound';
    LDAP_RC_NO_RESULTS_RETURNED: Result := 'noResultsReturned';
    LDAP_RC_MORE_RESULTS_TO_RETURN: Result := 'moreResultsToReturn';
    LDAP_RC_CLIENT_LOOP: Result := 'clientLoop';
    LDAP_RC_REFERRAL_LIMIT_EXCEEDED: Result := 'referralLimitExceeded';
  else
    Result := 'code ' + IntToStr(ACode);
  end;
end;

constructor TPagingTracker.Create(const ASessionId: string; AGeneration: Int64);
begin
  inherited Create;
  FSessionId := ASessionId;
  FGeneration := AGeneration;
  FSeen := TStringList.Create;
  FSeen.Sorted := True;
  FSeen.Duplicates := dupIgnore;
  FSeen.CaseSensitive := True;
end;

destructor TPagingTracker.Destroy;
begin
  FSeen.Free;
  inherited Destroy;
end;

function TPagingTracker.OnPage(const ACookie: RawByteString;
  AEntriesInPage: Integer): TPageVerdict;
var
  key: string;
begin
  Inc(FPages);
  if FAnomaly <> '' then Exit(pvAnomaly);
  if ACookie = '' then
  begin
    FLastCookie := '';
    Exit(pvDone);
  end;
  key := HexEncode(ACookie);
  // Le cookie est opaque et peut rester identique d'une page a l'autre: 389 DS renvoie
  // l'indice de son slot, ApacheDS son contexte de recherche. Seule une page VIDE avec le
  // meme cookie prouve que le serveur tourne en rond; PAGING_MAX_PAGES couvre le reste.
  if (AEntriesInPage = 0) and (FSeen.IndexOf(key) >= 0) and (ACookie = FLastCookie) then
  begin
    FAnomaly := 'paging makes no progress (empty page, same cookie)';
    Exit(pvAnomaly);
  end;
  if FPages >= PAGING_MAX_PAGES then
  begin
    FAnomaly := 'page count limit reached';
    Exit(pvAnomaly);
  end;
  if AEntriesInPage < 0 then
  begin
    FAnomaly := 'inconsistent page';
    Exit(pvAnomaly);
  end;
  FSeen.Add(key);
  FLastCookie := ACookie;
  Result := pvContinue;
end;

function TPagingTracker.CookieUsableOn(const ASessionId: string;
  AGeneration: Int64): Boolean;
begin
  Result := (ASessionId = FSessionId) and (AGeneration = FGeneration) and
    (FAnomaly = '');
end;

function ParseRangeOption(const ADescription: string; out ABase: string;
  out ALow, AHigh: Int64): Boolean;
begin
  Result := ParseRangeOptionEx(ADescription, ABase, ALow, AHigh) = rpValid;
end;

function ParseRangeOptionEx(const ADescription: string; out ABase: string;
  out ALow, AHigh: Int64): TRangeParse;
var
  parts: TStringArray;
  i, dash, seen: Integer;
  opt, lo, hi: string;
begin
  Result := rpNone;
  ABase := ADescription;
  ALow := 0;
  AHigh := -1;
  parts := ADescription.Split([';']);
  if Length(parts) = 0 then Exit;
  ABase := parts[0];
  seen := 0;
  for i := 1 to High(parts) do
  begin
    opt := parts[i];
    if (Length(opt) >= 6) and SameText(Copy(opt, 1, 6), 'range=') then
    begin
      Inc(seen);
      if seen > 1 then Exit(rpMalformed);
      opt := Copy(opt, 7, MaxInt);
      dash := Pos('-', opt);
      if dash <= 1 then Exit(rpMalformed);
      lo := Copy(opt, 1, dash - 1);
      hi := Copy(opt, dash + 1, MaxInt);
      if not TryStrToInt64(lo, ALow) or (ALow < 0) then Exit(rpMalformed);
      if hi = '*' then
        AHigh := -1
      else if not TryStrToInt64(hi, AHigh) or (AHigh < ALow) then
        Exit(rpMalformed);
      Result := rpValid;
    end
    else
    begin
      ABase := ABase + ';' + opt;
    end;
  end;
end;

constructor TRangeAssembler.Create(const ABaseName: string);
begin
  inherited Create;
  FBase := ABaseName;
  FState := rsNeedMore;
  FSeenRanges := TStringList.Create;
  FSeenRanges.Sorted := True;
end;

destructor TRangeAssembler.Destroy;
begin
  FSeenRanges.Free;
  inherited Destroy;
end;

function TRangeAssembler.Feed(const ADescription: string;
  const AValues: array of RawByteString): TRangeState;
var
  base: string;
  lo, hi: Int64;
  i: Integer;
  key: string;
begin
  if FState <> rsNeedMore then Exit(FState);
  Inc(FIterations);
  if FIterations > AD_RANGE_MAX_ITERATIONS then
  begin
    FState := rsPartial;
    FReason := 'range iteration limit reached';
    Exit(FState);
  end;
  case ParseRangeOptionEx(ADescription, base, lo, hi) of
    rpMalformed:
      begin
        FState := rsPartial;
        FReason := 'malformed range option';
        Exit(FState);
      end;
    rpValid: ;
  else
    if FIterations = 1 then
    begin
      SetLength(FValues, Length(AValues));
      for i := 0 to High(AValues) do
        FValues[i] := AValues[i];
      FState := rsComplete;
    end
    else
    begin
      FState := rsPartial;
      FReason := 'range response without range option';
    end;
    Exit(FState);
  end;
  key := IntToStr(lo) + '-' + IntToStr(hi);
  if FSeenRanges.IndexOf(key) >= 0 then
  begin
    FState := rsPartial;
    FReason := 'repeated range';
    Exit(FState);
  end;
  FSeenRanges.Add(key);
  if lo > FNextLow then
  begin
    FState := rsPartial;
    FReason := Format('gap in ranges (expected %d, got %d)', [FNextLow, lo]);
    Exit(FState);
  end;
  if lo < FNextLow then
  begin
    FState := rsPartial;
    FReason := Format('overlapping ranges (expected %d, got %d)', [FNextLow, lo]);
    Exit(FState);
  end;
  for i := 0 to High(AValues) do
  begin
    SetLength(FValues, Length(FValues) + 1);
    FValues[High(FValues)] := AValues[i];
  end;
  if hi = -1 then
  begin
    FState := rsComplete;
    Exit(FState);
  end;
  if (hi - lo + 1) <> Length(AValues) then
  begin
    // Plage annoncee et valeurs livrees ne collent pas: partiel, on ne croit pas le
    // serveur sur parole.
    FState := rsPartial;
    FReason := 'range size does not match returned values';
    Exit(FState);
  end;
  FNextLow := hi + 1;
  Result := rsNeedMore;
end;

function TRangeAssembler.NextRequest: string;
begin
  Result := FBase + ';range=' + IntToStr(FNextLow) + '-*';
end;

function TRangeAssembler.ValueCount: Integer;
begin
  Result := Length(FValues);
end;

function TRangeAssembler.Value(AIndex: Integer): RawByteString;
begin
  Result := FValues[AIndex];
end;

end.
