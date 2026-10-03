// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCompareRunner;

{$mode objfpc}{$H+}

// Execution d'une comparaison: lecture paginee simultanee des sources, marqueurs avant et apres,
// puis relecture des differences une fois l'annuaire stabilise. Aucune ecriture ici: on regarde, on
// ne touche pas. Une source peut etre un fichier LDIF.

interface

uses
  SysUtils, Classes, SyncObjs, uCompareModel, uCompareEngine, uConnectionProfile,
  uDirectorySession, uLdapSchema, uLdapEntry, uSearchModel, uUiInbox, uCancel, uCsn, uOwnedThread;

type
  TCompareSourceInput = record
    Profile: TConnectionProfile;
    Secret: RawByteString; // efface des que la connexion est faite
  end;

  TCompareProgressMsg = class(TUiMessage)
  public
    Source: Integer;
    Phase: string;
    Count: Int64;
  end;

  TMarkerComparison = record
    SourceA, SourceB: Integer;
    Sids: TSidComparisons;
  end;

  TCompareRunResult = class
  public
    Engine: TComparisonEngine;
    Execution: TExecutionState;
    MarkersMoved: Boolean;
    Verdict: TVerdict;
    ParametersJson: string;
    StartedUtc, FinishedUtc: TDateTime;
    DurationMs: Int64;
    Passes: Integer;
    MarkerComparisons: array of TMarkerComparison;
    Notes: TStringArray;
    Schemas: array of TSchemaSnapshot;
    destructor Destroy; override;
  end;

  TCompareDoneMsg = class(TUiMessage)
  public
    Run: TCompareRunResult;
    destructor Destroy; override;
    function TakeRun: TCompareRunResult;
  end;

  TComparisonRun = class(TOwnedThread)
  private
    FOwner: Pointer;
    FTaskId: Int64;
    FProfile: TComparisonProfile;
    FInputs: array of TCompareSourceInput;
    FCancel: TCancelToken;
    FSessions: array of TDirectorySession;
    FTempDir: string;
    procedure Stamp(AMsg: TUiMessage);
    procedure Progress(ASource: Integer; const APhase: string; ACount: Int64);
    function ReadMarkers(ASource: Integer): TStringArray;
    function EntryAttributes: TStringArray;
    function RecheckRead(AEngine: TComparisonEngine; ADiff: TEntryDiff; ASource: Integer;
      out AEntry: TLdapEntry): Boolean;
    procedure RecheckPass(AEngine: TComparisonEngine; ALock: TCriticalSection);
    procedure WaitSeconds(ASeconds: Integer);
  protected
    procedure Run; override;
    procedure RequestStop; override;
  public
    constructor Create(AOwner: Pointer; AProfile: TComparisonProfile;
      var AInputs: array of TCompareSourceInput; const ATempDir: string);
    destructor Destroy; override;
    procedure Cancel;
    // Release annule, attend un temps borne, puis libere ou detache le fil. Pas de Free ensuite:
    // l'objet n'est peut-etre plus a vous.
    property TaskId: Int64 read FTaskId;
  end;

implementation

uses
  uLdapDn, uLdapFilter, uSchemaReader, uLdapErrors, uSodiumApi, uRtBytes, uLdapSession,
  uLdifSession, uEntryFilter;

type
  TSourceReader = class(TThread)
  public
    Run: TComparisonRun;
    Index: Integer;
    Session: TDirectorySession;
    Engine: TComparisonEngine;
    Lock: TCriticalSection;
    Cancel: TCancelToken;
    Req: TSearchRequest;
    Completion: TSearchCompletion;
    Count: Int64;
    LastPostMs: Int64;
    ErrorText: string;
    procedure OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
  protected
    procedure Execute; override;
  end;

type
  TRecheckCollector = class
  public
    Items: TList;
    constructor Create;
    destructor Destroy; override;
    procedure Collect(AEntry: TLdapEntry; var AStop: Boolean);
    function Take(AIndex: Integer): TLdapEntry;
  end;

constructor TRecheckCollector.Create;
begin
  inherited Create;
  Items := TList.Create;
end;

destructor TRecheckCollector.Destroy;
var
  i: Integer;
begin
  for i := 0 to Items.Count - 1 do
    TObject(Items[i]).Free;
  Items.Free;
  inherited Destroy;
end;

procedure TRecheckCollector.Collect(AEntry: TLdapEntry; var AStop: Boolean);
begin
  Items.Add(AEntry);
  AStop := Items.Count > 1;
end;

function TRecheckCollector.Take(AIndex: Integer): TLdapEntry;
begin
  Result := TLdapEntry(Items[AIndex]);
  Items[AIndex] := nil;
end;

procedure TSourceReader.OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
begin
  try
    Lock.Enter;
    try
      Engine.AddEntry(Index, AEntry);
    finally
      Lock.Leave;
    end;
  finally
    AEntry.Free;
  end;
  Inc(Count);
  if MonotonicMs - LastPostMs >= 250 then
  begin
    LastPostMs := MonotonicMs;
    Run.Progress(Index, 'read', Count);
  end;
  AStop := Cancel.IsCancelled;
end;

procedure TSourceReader.Execute;
begin
  try
    Session.Search(Req, @OnEntry, Cancel, Completion, True);
  except
    on E: Exception do
    begin
      ErrorText := E.Message;
      Completion.HasResult := True;
      Completion.ResultCode := -1;
      Completion.DiagnosticMessage := E.Message;
    end;
  end;
  Run.Progress(Index, 'read', Count);
end;

destructor TCompareRunResult.Destroy;
var
  i: Integer;
begin
  // Le moteur d'abord: il reference les schemas.
  FreeAndNil(Engine);
  for i := 0 to High(Schemas) do
    Schemas[i].Free;
  inherited Destroy;
end;

destructor TCompareDoneMsg.Destroy;
begin
  Run.Free;
  inherited Destroy;
end;

function TCompareDoneMsg.TakeRun: TCompareRunResult;
begin
  Result := Run;
  Run := nil;
end;

constructor TComparisonRun.Create(AOwner: Pointer; AProfile: TComparisonProfile;
  var AInputs: array of TCompareSourceInput; const ATempDir: string);
var
  i: Integer;
begin
  FOwner := AOwner;
  FTaskId := NextTaskId;
  FProfile := TComparisonProfile.Create;
  FProfile.Assign(AProfile);
  FTempDir := ATempDir;
  FCancel := TCancelToken.Create;
  SetLength(FInputs, Length(AInputs));
  for i := 0 to High(AInputs) do
  begin
    FInputs[i].Profile := TConnectionProfile.Create;
    FInputs[i].Profile.Assign(AInputs[i].Profile);
    FInputs[i].Secret := AInputs[i].Secret;
    UniqueString(FInputs[i].Secret);
    WipeString(AInputs[i].Secret);
  end;
  SetLength(FSessions, Length(FInputs));
  inherited Create;
end;

destructor TComparisonRun.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FSessions) do
    FreeAndNil(FSessions[i]);
  for i := 0 to High(FInputs) do
  begin
    WipeString(FInputs[i].Secret);
    FInputs[i].Profile.Free;
  end;
  FProfile.Free;
  FCancel.Free;
  inherited Destroy;
end;

procedure TComparisonRun.Cancel;
begin
  FCancel.Cancel;
end;

procedure TComparisonRun.RequestStop;
begin
  FCancel.Cancel;
end;

procedure TComparisonRun.Stamp(AMsg: TUiMessage);
begin
  AMsg.Owner := FOwner;
  AMsg.TaskId := FTaskId;
  AMsg.SessionId := 'compare-' + IntToStr(FTaskId);
  AMsg.Generation := 1;
end;

procedure TComparisonRun.Progress(ASource: Integer; const APhase: string; ACount: Int64);
var
  m: TCompareProgressMsg;
begin
  m := TCompareProgressMsg.Create;
  Stamp(m);
  m.Source := ASource;
  m.Phase := APhase;
  m.Count := ACount;
  UiInbox.Post(m);
end;

procedure TComparisonRun.WaitSeconds(ASeconds: Integer);
var
  until_: Int64;
begin
  until_ := MonotonicMs + Int64(ASeconds) * 1000;
  while (MonotonicMs < until_) and not FCancel.IsCancelled do
    Sleep(100);
end;

function TComparisonRun.ReadMarkers(ASource: Integer): TStringArray;
var
  e: TLdapEntry;
  a: TLdapAttribute;
  i: Integer;
begin
  // OpenLDAP: contextCSN sur l'entree de base ou le suffixe. Les marqueurs AD et 389 DS ne sont pas
  // interpretes ici.
  Result := nil;
  e := FSessions[ASource].ReadEntry(FProfile.Sources[ASource].BaseDn, ['contextCSN'], FCancel);
  if e = nil then Exit;
  try
    a := e.Find('contextCSN');
    if a <> nil then
      for i := 0 to a.ValueCount - 1 do
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := 'contextCSN=' + a.Values[i];
      end;
  finally
    e.Free;
  end;
end;

function TComparisonRun.EntryAttributes: TStringArray;
var
  i: Integer;

  procedure Add(const S: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := S;
  end;

begin
  Result := nil;
  if FProfile.Mode = cmIndicators then
  begin
    case FProfile.Identity of
      imEntryUuid: Add('entryUUID');
      imObjectGuid: Add('objectGUID');
      imBusinessKey: Add(FProfile.BusinessKeyAttr);
    else
      Add('1.1');
    end;
    Exit;
  end;
  if FProfile.IncludeAttrs.Count > 0 then
    for i := 0 to FProfile.IncludeAttrs.Count - 1 do
      Add(FProfile.IncludeAttrs[i])
  else
    Add('*');
  if FProfile.IncludeOperational then Add('+');
  case FProfile.Identity of
    imEntryUuid: Add('entryUUID');
    imObjectGuid: Add('objectGUID');
    imBusinessKey: Add(FProfile.BusinessKeyAttr);
  end;
end;

function TComparisonRun.RecheckRead(AEngine: TComparisonEngine; ADiff: TEntryDiff;
  ASource: Integer; out AEntry: TLdapEntry): Boolean;
var
  dn, attr: string;
  value, raw: RawByteString;
  d, oldBase, newBase, mapped: TLdapDn;
  err: string;
  t: Integer;
  cmp: TDnComparer;
  req: TSearchRequest;
  found: TRecheckCollector;
  comp: TSearchCompletion;
  sess: TDirectorySession;
  p: Integer;
begin
  Result := False;
  AEntry := nil;
  sess := FSessions[ASource];
  if FProfile.Identity = imRelativeDn then
  begin
    dn := ADiff.Dns[ASource];
    if dn = '' then
    begin
      cmp := TDnComparer.Create;
      try
        for t := 0 to High(ADiff.Dns) do
          if (ADiff.Dns[t] <> '') and DnParse(ADiff.Dns[t], d, err) and
             DnParse(FProfile.Sources[t].BaseDn, oldBase, err) and
             DnParse(FProfile.Sources[ASource].BaseDn, newBase, err) and
             DnReplaceSuffix(cmp, d, oldBase, newBase, mapped) then
          begin
            dn := DnToString(mapped);
            Break;
          end;
      finally
        cmp.Free;
      end;
      if dn = '' then Exit;
    end;
    // Meme filtre et meme dereferencement qu'a la lecture: une entree qui ne satisfait plus le
    // filtre reste absente.
    req := DefaultSearchRequest;
    req.BaseDn := dn;
    req.Scope := ssBase;
    req.Filter := FProfile.Filter;
  end
  else
  begin
    p := Pos('=', ADiff.DisplayKey);
    if p = 0 then Exit;
    attr := Copy(ADiff.DisplayKey, 1, p - 1);
    value := Copy(ADiff.DisplayKey, p + 1, MaxInt);
    if (value <> '') and (value[1] = '#') then
    begin
      if not HexDecode(Copy(value, 2, MaxInt), raw) then Exit;
      value := raw;
    end;
    req := DefaultSearchRequest;
    req.BaseDn := FProfile.Sources[ASource].BaseDn;
    req.Scope := FProfile.Scope;
    req.Filter := '(&' + FProfile.Filter + '(' + attr + '=' + FilterEscapeValue(value) + '))';
  end;
  req.Attributes := EntryAttributes;
  req.SizeLimit := 2;
  req.Deref := FProfile.DerefAliases;
  found := TRecheckCollector.Create;
  try
    if not sess.Search(req, @found.Collect, FCancel, comp, True) then Exit;
    if (FProfile.Identity = imRelativeDn) and (comp.ResultCode = LDAP_RC_NO_SUCH_OBJECT) and
      not comp.Cancelled then Exit(True);
    if SearchOutcome(comp) <> soComplete then Exit;
    if found.Items.Count = 1 then
    begin
      AEntry := found.Take(0);
      Result := True;
    end
    else if found.Items.Count = 0 then
      Result := True;
  finally
    found.Free;
  end;
end;

procedure TComparisonRun.RecheckPass(AEngine: TComparisonEngine; ALock: TCriticalSection);
var
  keys: TStringArray;
  i, s: Integer;
  ed: TEntryDiff;
  e: TLdapEntry;
begin
  keys := AEngine.KeysForRecheck;
  for i := 0 to High(keys) do
  begin
    if FCancel.IsCancelled then Exit;
    ed := AEngine.FindDiff(keys[i]);
    if (ed = nil) or (dkAmbiguous in ed.Kinds) then Continue;
    for s := 0 to High(FSessions) do
    begin
      if (FSessions[s] = nil) or not FSessions[s].IsConnected then Continue;
      if RecheckRead(AEngine, ed, s, e) then
      try
        ALock.Enter;
        try
          AEngine.Recheck(keys[i], s, e);
        finally
          ALock.Leave;
        end;
      finally
        e.Free;
      end;
    end;
    if (i mod 50) = 0 then
      Progress(-1, 'recheck', i);
  end;
  AEngine.FinishRecheck;
end;

procedure TComparisonRun.Run;
var
  msg: TCompareDoneMsg;
  done: TCompareRunResult;
  engine: TComparisonEngine;
  lock: TCriticalSection;
  readers: array of TSourceReader;
  obs: TSourceObservation;
  i, j: Integer;
  started: Int64;
  root: TLdapEntry;
  reason, authz: string;
  before, after: array of TStringArray;
  schemaReasons: TStringArray;
  failed: Boolean;
  va, vb: array of string;

  procedure Note(const S: string);
  begin
    SetLength(done.Notes, Length(done.Notes) + 1);
    done.Notes[High(done.Notes)] := S;
  end;

  function MarkerValues(const AList: TStringArray): TStringArray;
  var
    k: Integer;
  begin
    Result := nil;
    SetLength(Result, Length(AList));
    for k := 0 to High(AList) do
      Result[k] := Copy(AList[k], Pos('=', AList[k]) + 1, MaxInt);
  end;

  function TopEntries(ASession: TLdifSession): string;
  var
    k: Integer;
  begin
    Result := '';
    for k := 0 to ASession.Store.RootCount - 1 do
    begin
      if k = 5 then
      begin
        Result := Result + Format(', and %d more', [ASession.Store.RootCount - 5]);
        Break;
      end;
      if Result <> '' then Result := Result + ', ';
      Result := Result + ASession.Store.Root(k).Dn;
    end;
  end;

  function SameMarkers(const A, B: TStringArray): Boolean;
  var
    k: Integer;
  begin
    Result := Length(A) = Length(B);
    if Result then
      for k := 0 to High(A) do
        if A[k] <> B[k] then Exit(False);
  end;

  function DnWithin(const ADn, AContext: string): Boolean;
  var
    d, c: TLdapDn;
    e: string;
    k, off: Integer;
  begin
    Result := False;
    if (Trim(AContext) = '') or not DnParse(ADn, d, e) or not DnParse(AContext, c, e) then Exit;
    off := DnRdnCount(d) - DnRdnCount(c);
    if off < 0 then Exit;
    for k := 0 to DnRdnCount(c) - 1 do
      if RdnMatchKey(d.Rdns[off + k]) <> RdnMatchKey(c.Rdns[k]) then Exit;
    Result := True;
  end;

  // Sources sans base: OpenLDAP repond noSuchObject sous une base vide et un fichier rend des DN
  // complets, donc rien ne se rencontrerait. On emprunte la base d'une autre source qui la
  // contient, sinon le contexte par defaut ou unique du serveur. Chaque choix est dit dans les
  // notes.
  procedure ResolveBases;
  var
    k, m: Integer;
    given: TStringArray;
    contexts: array of TStringArray;
    defaults: TStringArray;
    rd: TLdapEntry;
    a: TLdapAttribute;

    function Holds(AIndex: Integer; const ADn: string): Boolean;
    var
      n: Integer;
    begin
      if FInputs[AIndex].Profile.LdifPath <> '' then
        Exit(TLdifSession(FSessions[AIndex]).Store.FindNode(ADn) <> nil);
      Result := False;
      for n := 0 to High(contexts[AIndex]) do
        if DnWithin(ADn, contexts[AIndex][n]) then Exit(True);
    end;

    procedure Borrow(AIndex: Integer; const ABases: TStringArray);
    var
      n: Integer;
    begin
      for n := 0 to High(FSessions) do
        if (n <> AIndex) and (ABases[n] <> '') and Holds(AIndex, ABases[n]) then
        begin
          FProfile.Sources[AIndex].BaseDn := ABases[n];
          Note(Format('%s: no base given, read under %s, the base of %s',
            [FProfile.Sources[AIndex].Name, ABases[n], FProfile.Sources[n].Name]));
          Exit;
        end;
    end;

  begin
    given := nil;
    SetLength(given, Length(FSessions));
    contexts := nil;
    SetLength(contexts, Length(FSessions));
    defaults := nil;
    SetLength(defaults, Length(FSessions));
    for k := 0 to High(FSessions) do
    begin
      given[k] := Trim(FProfile.Sources[k].BaseDn);
      if (given[k] <> '') or (FInputs[k].Profile.LdifPath <> '') then Continue;
      rd := FSessions[k].ReadRootDse(FCancel);
      try
        if rd = nil then Continue;
        a := rd.Find('namingContexts');
        if a <> nil then
        begin
          SetLength(contexts[k], a.ValueCount);
          for m := 0 to a.ValueCount - 1 do
            contexts[k][m] := string(a.Values[m]);
        end;
        defaults[k] := string(rd.FirstValue('defaultNamingContext', ''));
      finally
        rd.Free;
      end;
    end;
    for k := 0 to High(FSessions) do
      if given[k] = '' then Borrow(k, given);
    for k := 0 to High(FSessions) do
      if (Trim(FProfile.Sources[k].BaseDn) = '') and (FInputs[k].Profile.LdifPath = '') then
      begin
        if defaults[k] <> '' then
          FProfile.Sources[k].BaseDn := defaults[k]
        else if (Length(contexts[k]) = 1) and (Trim(contexts[k][0]) <> '') then
          FProfile.Sources[k].BaseDn := contexts[k][0]
        else
          Continue;
        Note(Format('%s: no base given, read under %s, the naming context of the server',
          [FProfile.Sources[k].Name, FProfile.Sources[k].BaseDn]));
      end;
    for k := 0 to High(FSessions) do
      given[k] := Trim(FProfile.Sources[k].BaseDn);
    for k := 0 to High(FSessions) do
      if (given[k] = '') and (FInputs[k].Profile.LdifPath <> '') then
        Borrow(k, given);
  end;

begin
  done := TCompareRunResult.Create;
  done.StartedUtc := UtcNow;
  done.ParametersJson := '';
  started := MonotonicMs;
  engine := nil;
  lock := TCriticalSection.Create;
  failed := False;
  SetLength(done.Schemas, Length(FInputs));
  SetLength(before, Length(FInputs));
  SetLength(after, Length(FInputs));
  schemaReasons := nil;
  SetLength(schemaReasons, Length(FInputs));
  try
    try
      with FProfile.ToJson do
      try
        done.ParametersJson := AsJSON;
      finally
        Free;
      end;
      for i := 0 to High(FInputs) do
      begin
        if FCancel.IsCancelled then Break;
        Progress(i, 'connect', 0);
        if FInputs[i].Profile.LdifPath <> '' then
          FSessions[i] := TLdifSession.Create(FInputs[i].Profile, 'compare-' + IntToStr(FTaskId), FTaskId)
        else
          FSessions[i] := TLdapSession.Create(FInputs[i].Profile, 'compare-' + IntToStr(FTaskId), FTaskId);
        try
          if not FSessions[i].Connect(FInputs[i].Secret, FCancel) then
          begin
            Note(Format('%s: connection failed: %s', [FProfile.Sources[i].Name,
              ErrorToText(FSessions[i].LastError)]));
            failed := True;
          end;
        finally
          WipeString(FInputs[i].Secret);
        end;
      end;
      if failed or FCancel.IsCancelled then
      begin
        if FCancel.IsCancelled then done.Execution := esCancelled else done.Execution := esFailed;
        Exit;
      end;
      ResolveBases;
      for i := 0 to High(FSessions) do
        if (FInputs[i].Profile.LdifPath <> '') and (Trim(FProfile.Sources[i].BaseDn) <> '') and
           (TLdifSession(FSessions[i]).Store.FindNode(FProfile.Sources[i].BaseDn) = nil) then
          Note(Format('%s: %s is not in the file; its top entries: %s', [FProfile.Sources[i].Name,
            FProfile.Sources[i].BaseDn, TopEntries(TLdifSession(FSessions[i]))]));
      for i := 0 to High(FSessions) do
      begin
        if (FProfile.Strictness = csSemantic) or not FProfile.IncludeOperational then
        begin
          Progress(i, 'schema', 0);
          root := FSessions[i].ReadRootDse(FCancel);
          try
            if root <> nil then
            begin
              if (FInputs[i].Profile.LdifPath <> '') and (SubschemaDnFromRootDse(root) = '') then
                schemaReasons[i] := 'the file holds no subschema entry'
              else
              begin
                done.Schemas[i] := ReadSchema(FSessions[i], SubschemaDnFromRootDse(root), FCancel, reason);
                if done.Schemas[i] = nil then
                  schemaReasons[i] := reason;
              end;
            end;
          finally
            root.Free;
          end;
        end;
        before[i] := ReadMarkers(i);
      end;
      // Fichier LDIF sans sous-schema: on emprunte celui d'une source serveur, sinon les regles
      // semantiques ne s'appliqueraient a aucun attribut.
      if (FProfile.Strictness = csSemantic) or not FProfile.IncludeOperational then
        for i := 0 to High(FSessions) do
          if (done.Schemas[i] = nil) and (FInputs[i].Profile.LdifPath <> '') then
            for j := 0 to High(FSessions) do
              if (done.Schemas[j] <> nil) and (FInputs[j].Profile.LdifPath = '') then
              begin
                done.Schemas[i] := done.Schemas[j].Clone;
                Note(Format('%s: compared with the schema of %s', [FProfile.Sources[i].Name,
                  FProfile.Sources[j].Name]));
                Break;
              end;
      for i := 0 to High(FSessions) do
        if (done.Schemas[i] = nil) and (schemaReasons[i] <> '') then
          Note(Format('%s: schema unavailable (%s)', [FProfile.Sources[i].Name, schemaReasons[i]]));
      engine := TComparisonEngine.Create(FProfile, done.Schemas, FTempDir);
      for i := 0 to High(FSessions) do
      begin
        obs := Default(TSourceObservation);
        obs.Name := FProfile.Sources[i].Name;
        obs.Endpoint := FInputs[i].Profile.DisplayEndpoint;
        obs.TransportLabel := FSessions[i].Transport.StatusLabel;
        obs.BoundIdentity := FSessions[i].Transport.BoundIdentity;
        if FSessions[i].WhoAmI(FCancel, authz) then
          obs.AuthzId := authz;
        obs.BaseDn := FProfile.Sources[i].BaseDn;
        obs.SchemaAvailable := done.Schemas[i] <> nil;
        if FSessions[i] is TLdifSession then
        begin
          obs.SkippedRecords := TLdifSession(FSessions[i]).Store.IssueCount;
          for j := 0 to High(FSessions[i].ConnectWarnings) do
            Note(FProfile.Sources[i].Name + ': ' + FSessions[i].ConnectWarnings[j]);
        end;
        obs.MarkersBefore := before[i];
        obs.StartedUtc := UtcNow;
        engine.SetObservation(i, obs);
      end;
      SetLength(readers, Length(FSessions));
      for i := 0 to High(FSessions) do
      begin
        readers[i] := TSourceReader.Create(True);
        readers[i].FreeOnTerminate := False;
        readers[i].Run := Self;
        readers[i].Index := i;
        readers[i].Session := FSessions[i];
        readers[i].Engine := engine;
        readers[i].Lock := lock;
        readers[i].Cancel := FCancel;
        readers[i].Req := DefaultSearchRequest;
        readers[i].Req.BaseDn := FProfile.Sources[i].BaseDn;
        readers[i].Req.Scope := FProfile.Scope;
        readers[i].Req.Filter := FProfile.Filter;
        readers[i].Req.Attributes := EntryAttributes;
        readers[i].Req.PageSize := FInputs[i].Profile.PageSize;
        readers[i].Req.SizeLimit := 0;
        readers[i].Req.ServerSizeLimit := 0;
        readers[i].Req.TimeLimitSec := 0;
        readers[i].Req.Deref := FProfile.DerefAliases;
        readers[i].Req.FollowReferrals := False;
      end;
      try
        for i := 0 to High(readers) do
          readers[i].Start;
        for i := 0 to High(readers) do
          readers[i].WaitFor;
        for i := 0 to High(readers) do
        begin
          obs := engine.Observation(i);
          obs.Completion := readers[i].Completion;
          obs.EntryCount := readers[i].Count;
          obs.FinishedUtc := UtcNow;
          if readers[i].ErrorText <> '' then
          begin
            SetLength(obs.Errors, Length(obs.Errors) + 1);
            obs.Errors[High(obs.Errors)] := readers[i].ErrorText;
          end
          else if SearchOutcome(readers[i].Completion) <> soComplete then
          begin
            SetLength(obs.Errors, Length(obs.Errors) + 1);
            obs.Errors[High(obs.Errors)] := ResultCodeName(readers[i].Completion.ResultCode) + ' ' +
              SanitizeDiagnostic(readers[i].Completion.DiagnosticMessage);
          end;
          engine.SetObservation(i, obs);
        end;
      finally
        for i := 0 to High(readers) do
          readers[i].Free;
      end;
      for i := 0 to High(FSessions) do
      begin
        after[i] := ReadMarkers(i);
        obs := engine.Observation(i);
        obs.MarkersAfter := after[i];
        engine.SetObservation(i, obs);
        if not SameMarkers(before[i], after[i]) then
          done.MarkersMoved := True;
      end;
      Progress(-1, 'variants', 0);
      engine.Finish;
      done.Passes := 1;
      if FProfile.SecondPass and (FProfile.Mode <> cmIndicators) and (engine.DiffCount > 0) and
         not FCancel.IsCancelled then
      begin
        Progress(-1, 'wait', FProfile.PassDelaySec);
        WaitSeconds(FProfile.PassDelaySec);
        if not FCancel.IsCancelled then
        begin
          RecheckPass(engine, lock);
          Inc(done.Passes);
        end;
        if (FProfile.StabilizationWindowSec > FProfile.PassDelaySec) and (engine.DiffCount > 0) and
           not FCancel.IsCancelled then
        begin
          Progress(-1, 'wait', FProfile.StabilizationWindowSec - FProfile.PassDelaySec);
          WaitSeconds(FProfile.StabilizationWindowSec - FProfile.PassDelaySec);
          if not FCancel.IsCancelled then
          begin
            RecheckPass(engine, lock);
            Inc(done.Passes);
          end;
        end;
        for i := 0 to High(FSessions) do
          if not SameMarkers(after[i], ReadMarkers(i)) then
            done.MarkersMoved := True;
      end;
      for i := 0 to High(FSessions) do
        for j := i + 1 to High(FSessions) do
          if (Length(after[i]) > 0) and (Length(after[j]) > 0) then
          begin
            SetLength(done.MarkerComparisons, Length(done.MarkerComparisons) + 1);
            with done.MarkerComparisons[High(done.MarkerComparisons)] do
            begin
              SourceA := i;
              SourceB := j;
              va := MarkerValues(after[i]);
              vb := MarkerValues(after[j]);
              Sids := CompareCsnVectors(va, vb);
            end;
          end;
      // Deux sources sans une seule entree commune: presque toujours des bases mal assorties,
      // rarement deux annuaires sans rapport.
      if (Length(FSessions) = 2) and not FCancel.IsCancelled and (engine.Counters.Keys > 0) and
         (engine.Counters.EqualKeys = 0) and (engine.Counters.ContentKeys = 0) and
         (engine.Counters.RenamedKeys = 0) and (engine.Counters.MissingKeys = engine.Counters.Keys) then
        Note('No entry was found in both sources: check the base DN of each source and the identity mode.');
      if FCancel.IsCancelled then
        done.Execution := esCancelled
      else
        done.Execution := esCompleted;
    except
      on E: Exception do
      begin
        Note('Execution error: ' + E.Message);
        done.Execution := esFailed;
      end;
    end;
  finally
    for i := 0 to High(FSessions) do
      if FSessions[i] <> nil then
        FSessions[i].Close;
    lock.Free;
    done.FinishedUtc := UtcNow;
    done.DurationMs := MonotonicMs - started;
    if engine <> nil then
    begin
      try
        if done.Passes = 0 then
          engine.Finish;
        done.Verdict := engine.Verdict(done.Execution, done.MarkersMoved);
        // Execution interrompue: aucune egalite ne peut etre annoncee. Ne rien avoir vu n'est pas
        // avoir tout vu.
        if (done.Execution <> esCompleted) and (done.Verdict.Result = rsEqualObserved) then
          done.Verdict.Result := rsUndetermined;
      except
        on E: Exception do
          Note('Verdict error: ' + E.Message);
      end;
    end
    else
    begin
      done.Verdict := Default(TVerdict);
      done.Verdict.Execution := done.Execution;
      done.Verdict.Coverage := cvUnknown;
      done.Verdict.Result := rsNone;
      done.Verdict.Headline := VerdictHeadline(done.Verdict, FProfile.Mode);
    end;
    done.Engine := engine;
    msg := TCompareDoneMsg.Create;
    Stamp(msg);
    msg.Run := done;
    UiInbox.Post(msg);
  end;
end;

end.
