// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDirectoryWorker;

{$mode objfpc}{$H+}

// Fil de travail proprietaire d'une seule session, serveur LDAP ou fichier LDIF. Commandes en
// serie, resultats en messages immuables, une session par usage. Pas de TerminateThread: on demande
// poliment, puis on coupe la connexion.

interface

uses
  SysUtils, Classes, Contnrs, uDirectorySession, uSessionModel, uConnectionProfile, uLdapEntry, uSearchModel,
  uLdapErrors, uChangeSet, uLdapSchema, uCancel, uUiInbox, uTlsVerify, uPasswordWork,
  uOwnedThread;

type
  TDirectoryWorker = class;

  TWorkerCommand = class
  public
    TaskId: Int64;
    Owner: Pointer;
    Cancel: TCancelToken;
    constructor Create(AOwner: Pointer);
    destructor Destroy; override;
    procedure Execute(AWorker: TDirectoryWorker); virtual; abstract;
    // Exception dans Execute: un resultat terminal part quand meme, sinon la vue attend jusqu'a la
    // fin des temps.
    procedure Fail(AWorker: TDirectoryWorker; const AText: string); virtual;
  end;

  TTaskFailedMsg = class(TUiMessage)
  public
    Text: string;
  end;

  TStepMsg = class(TUiMessage)
  public
    Step: TConnectStepResult;
  end;

  TConnectedMsg = class(TUiMessage)
  public
    Ok: Boolean;
    Error: TLdapError;
    Transport: TTransportInfo;
    RootDse: TLdapEntry;
    Summary: string;
    Warnings: TStringArray;
    RewriteNote: string;
    destructor Destroy; override;
  end;

  TDisconnectedMsg = class(TUiMessage);

  TEntriesMsg = class(TUiMessage)
  public
    Entries: TObjectList;
    Final: Boolean;
    Completion: TSearchCompletion;
    Error: TLdapError;
    Tag: PtrInt;
    ServerPageSize: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TEntryMsg = class(TUiMessage)
  public
    Entry: TLdapEntry;
    Error: TLdapError;
    Tag: PtrInt;
    destructor Destroy; override;
  end;

  TWriteMsg = class(TUiMessage)
  public
    Change: TLdapChange;
    Result: TWriteResult;
    Reread: TLdapEntry;
    Note: string;
    Tag: PtrInt;
    destructor Destroy; override;
  end;

  TSchemaMsg = class(TUiMessage)
  public
    Schema: TSchemaSnapshot;
    Reason: string;
    destructor Destroy; override;
  end;

  TPasswordMsg = class(TUiMessage)
  public
    UserDn: string;
    Result: TWriteResult;
    destructor Destroy; override;
  end;

  TAuthTestMsg = class(TUiMessage)
  public
    Accepted: Boolean;
    Error: TLdapError;
    Transport: TTransportInfo;
  end;

  TLdifSavedMsg = class(TUiMessage)
  public
    Ok: Boolean;
    Error: TLdapError;
    Path: string;
    EntryCount: Integer;
    ChangeCount: Int64;
  end;

  TConnectCmd = class(TWorkerCommand)
  public
    Secret: RawByteString;
    WithSchema: Boolean;
    destructor Destroy; override;
    procedure Execute(AWorker: TDirectoryWorker); override;
    procedure Fail(AWorker: TDirectoryWorker; const AText: string); override;
  end;

  TSearchCmd = class(TWorkerCommand)
  public
    Request: TSearchRequest;
    BatchSize: Integer;
    AssembleRanges: Boolean;
    Tag: PtrInt;
    procedure Execute(AWorker: TDirectoryWorker); override;
    procedure Fail(AWorker: TDirectoryWorker; const AText: string); override;
  end;

  TReadEntryCmd = class(TWorkerCommand)
  public
    Dn: string;
    Attributes: array of string;
    Controls: TRequestControlArray;
    Tag: PtrInt;
    procedure Execute(AWorker: TDirectoryWorker); override;
    procedure Fail(AWorker: TDirectoryWorker; const AText: string); override;
  end;

  TWriteCmd = class(TWorkerCommand)
  private
    FSent: Boolean; // peut-etre emise: une exception rend l'issue inconnue
  public
    Change: TLdapChange;
    AssertionFilter: string;
    RereadAttributes: array of string;
    RequestControls: TRequestControlArray;
    Tag: PtrInt;
    destructor Destroy; override;
    procedure Execute(AWorker: TDirectoryWorker); override;
    procedure Fail(AWorker: TDirectoryWorker; const AText: string); override;
  end;

  TSchemaCmd = class(TWorkerCommand)
  public
    SubschemaDn: string;
    AdSchemaDn: string;
    procedure Execute(AWorker: TDirectoryWorker); override;
    procedure Fail(AWorker: TDirectoryWorker; const AText: string); override;
  end;

  TPasswordModifyCmd = class(TWorkerCommand)
  public
    UserDn: string;
    OldSecret, NewSecret: RawByteString;
    HasOld, HasNew: Boolean;
    destructor Destroy; override;
    procedure Execute(AWorker: TDirectoryWorker); override;
    procedure Fail(AWorker: TDirectoryWorker; const AText: string); override;
  end;

  TLdifSaveCmd = class(TWorkerCommand)
  public
    Path: string;
    procedure Execute(AWorker: TDirectoryWorker); override;
    procedure Fail(AWorker: TDirectoryWorker; const AText: string); override;
  end;

  TLdifSchemaCmd = class(TWorkerCommand)
  public
    Schema: TSchemaSnapshot;
    destructor Destroy; override;
    procedure Execute(AWorker: TDirectoryWorker); override;
  end;

  TDirectoryWorker = class(TOwnedThread)
  private
    FProfile: TConnectionProfile;
    FSession: TDirectorySession;
    FSessionId: string;
    FGeneration: Int64;
    FQueue: TThreadList;
    FWake: PRTLEvent;
    FCurrent: TWorkerCommand;
    FCurrentLock: TRTLCriticalSection;
    FStepOwner: Pointer;
    FStepTask: Int64;
    // Politique des secrets hors de la file annulable, versionnee sous verrou, appliquee avant
    // chaque commande, connexion comprise. Une purge ne peut pas la perdre, et la version monotone
    // interdit le retour a une ancienne liste.
    FPolicyLock: TRTLCriticalSection;
    FSensitiveExtra: array of string;
    FSensitiveVersion: Int64;
    FSensitiveApplied: Int64;
    procedure OnStep(const AResult: TConnectStepResult);
    procedure ApplySensitivePolicy;
    procedure DropQueued(AOwner: Pointer; AAll: Boolean; ATaskId: Int64 = 0);
  protected
    procedure Run; override;
    procedure RequestStop; override;
  public
    constructor Create(AProfile: TConnectionProfile; const ASessionId: string; AGeneration: Int64);
    destructor Destroy; override;
    procedure Enqueue(ACmd: TWorkerCommand);
    procedure CancelAll;
    procedure CancelOwned(AOwner: Pointer);
    procedure CancelTask(ATaskId: Int64);
    procedure SetSensitiveExtra(const AList: array of string);
    // Release est la seule autorite de destruction. Un fil coince dans une phase non annulable
    // (DNS, connexion) est detache et finit seul; ses messages tardifs sont ecartes par session et
    // generation.
    procedure Stamp(AMsg: TUiMessage; ACmd: TWorkerCommand);
    property Session: TDirectorySession read FSession;
    property SessionId: string read FSessionId;
    property Generation: Int64 read FGeneration;
  end;

// Test d'authentification: connexion independante, une seule tentative, fermee aussitot.
type
  TAuthTestThread = class(TPwdWorkThread)
  private
    FProfile: TConnectionProfile;
    FSecret: RawByteString;
  protected
    procedure Run; override;
  public
    constructor Create(AProfile: TConnectionProfile; const ABindDn: string;
      const ASecret: RawByteString; AOwner: Pointer; ATaskId: Int64);
    destructor Destroy; override;
  end;

implementation

uses
  uSchemaReader, uRtBytes, uSensitive, uLdapSession, uLdifSession;

constructor TWorkerCommand.Create(AOwner: Pointer);
begin
  inherited Create;
  Owner := AOwner;
  TaskId := NextTaskId;
  Cancel := TCancelToken.Create;
end;

destructor TWorkerCommand.Destroy;
begin
  Cancel.Free;
  inherited Destroy;
end;

procedure TWorkerCommand.Fail(AWorker: TDirectoryWorker; const AText: string);
var
  m: TTaskFailedMsg;
begin
  m := TTaskFailedMsg.Create;
  AWorker.Stamp(m, Self);
  m.Text := AText;
  UiInbox.Post(m);
end;

destructor TConnectedMsg.Destroy;
begin
  RootDse.Free;
  inherited Destroy;
end;

constructor TEntriesMsg.Create;
begin
  inherited Create;
  Entries := TObjectList.Create(True);
end;

destructor TEntriesMsg.Destroy;
begin
  Entries.Free;
  inherited Destroy;
end;

destructor TEntryMsg.Destroy;
begin
  Entry.Free;
  inherited Destroy;
end;

destructor TWriteMsg.Destroy;
begin
  Change.Free;
  Reread.Free;
  inherited Destroy;
end;

destructor TSchemaMsg.Destroy;
begin
  Schema.Free;
  inherited Destroy;
end;

constructor TDirectoryWorker.Create(AProfile: TConnectionProfile; const ASessionId: string;
  AGeneration: Int64);
begin
  FProfile := TConnectionProfile.Create;
  FProfile.Assign(AProfile);
  FSessionId := ASessionId;
  FGeneration := AGeneration;
  FQueue := TThreadList.Create;
  FWake := RTLEventCreate;
  InitCriticalSection(FCurrentLock);
  InitCriticalSection(FPolicyLock);
  inherited Create;
end;

destructor TDirectoryWorker.Destroy;
var
  l: TList;
  i: Integer;
begin
  l := FQueue.LockList;
  try
    for i := 0 to l.Count - 1 do
      TObject(l[i]).Free;
    l.Clear;
  finally
    FQueue.UnlockList;
  end;
  FQueue.Free;
  RTLEventDestroy(FWake);
  DoneCriticalSection(FCurrentLock);
  DoneCriticalSection(FPolicyLock);
  FProfile.Free;
  inherited Destroy;
end;

procedure TDirectoryWorker.Stamp(AMsg: TUiMessage; ACmd: TWorkerCommand);
begin
  AMsg.Owner := ACmd.Owner;
  AMsg.TaskId := ACmd.TaskId;
  AMsg.SessionId := FSessionId;
  AMsg.Generation := FGeneration;
end;

procedure TDirectoryWorker.Enqueue(ACmd: TWorkerCommand);
begin
  FQueue.Add(ACmd);
  RTLEventSetEvent(FWake);
end;

procedure TDirectoryWorker.DropQueued(AOwner: Pointer; AAll: Boolean; ATaskId: Int64);
var
  l, removed: TList;
  i: Integer;
  cmd: TWorkerCommand;
  hit: Boolean;
begin
  removed := TList.Create;
  try
    l := FQueue.LockList;
    try
      i := 0;
      while i < l.Count do
      begin
        cmd := TWorkerCommand(l[i]);
        if ATaskId <> 0 then
          hit := cmd.TaskId = ATaskId
        else
          hit := AAll or (cmd.Owner = AOwner);
        if hit then
        begin
          removed.Add(cmd);
          l.Delete(i);
        end
        else
          Inc(i);
      end;
    finally
      FQueue.UnlockList;
    end;
    // Chaque commande retiree poste son resultat terminal, hors du verrou de file: la vue voit
    // l'annulation au lieu d'attendre indefiniment.
    for i := 0 to removed.Count - 1 do
    begin
      cmd := TWorkerCommand(removed[i]);
      try
        cmd.Fail(Self, 'cancelled');
      except
      end;
      cmd.Free;
    end;
  finally
    removed.Free;
  end;
end;

procedure TDirectoryWorker.CancelAll;
begin
  DropQueued(nil, True);
  EnterCriticalSection(FCurrentLock);
  try
    if FCurrent <> nil then
      FCurrent.Cancel.Cancel;
  finally
    LeaveCriticalSection(FCurrentLock);
  end;
end;

procedure TDirectoryWorker.CancelOwned(AOwner: Pointer);
begin
  DropQueued(AOwner, False);
  EnterCriticalSection(FCurrentLock);
  try
    if (FCurrent <> nil) and (FCurrent.Owner = AOwner) then
      FCurrent.Cancel.Cancel;
  finally
    LeaveCriticalSection(FCurrentLock);
  end;
end;

procedure TDirectoryWorker.CancelTask(ATaskId: Int64);
begin
  if ATaskId = 0 then Exit;
  DropQueued(nil, False, ATaskId);
  EnterCriticalSection(FCurrentLock);
  try
    if (FCurrent <> nil) and (FCurrent.TaskId = ATaskId) then
      FCurrent.Cancel.Cancel;
  finally
    LeaveCriticalSection(FCurrentLock);
  end;
end;

procedure TDirectoryWorker.SetSensitiveExtra(const AList: array of string);
var
  i: Integer;
begin
  EnterCriticalSection(FPolicyLock);
  try
    SetLength(FSensitiveExtra, Length(AList));
    for i := 0 to High(AList) do
      FSensitiveExtra[i] := AList[i];
    Inc(FSensitiveVersion);
  finally
    LeaveCriticalSection(FPolicyLock);
  end;
end;

procedure TDirectoryWorker.ApplySensitivePolicy;
var
  ver: Int64;
  list: array of string;
  i: Integer;
begin
  EnterCriticalSection(FPolicyLock);
  try
    ver := FSensitiveVersion;
    if ver = FSensitiveApplied then Exit;
    SetLength(list, Length(FSensitiveExtra));
    for i := 0 to High(FSensitiveExtra) do
      list[i] := FSensitiveExtra[i];
  finally
    LeaveCriticalSection(FPolicyLock);
  end;
  FSession.Sensitive.SetExtra(list);
  FSensitiveApplied := ver;
end;

procedure TDirectoryWorker.RequestStop;
begin
  CancelAll;
  RTLEventSetEvent(FWake);
end;

procedure TDirectoryWorker.OnStep(const AResult: TConnectStepResult);
var
  m: TStepMsg;
begin
  m := TStepMsg.Create;
  m.Owner := FStepOwner;
  m.TaskId := FStepTask;
  m.SessionId := FSessionId;
  m.Generation := FGeneration;
  m.Step := AResult;
  UiInbox.Post(m);
end;

procedure TDirectoryWorker.Run;
var
  cmd: TWorkerCommand;
  l: TList;
begin
  if FProfile.LdifPath <> '' then
    FSession := TLdifSession.Create(FProfile, FSessionId, FGeneration)
  else
    FSession := TLdapSession.Create(FProfile, FSessionId, FGeneration);
  FSession.OnStep := @OnStep;
  try
    while not (Terminated or StopRequested) do
    begin
      cmd := nil;
      // Retrait de la file et prise en cours sous les deux verrous: CancelAll ne peut pas se
      // glisser entre les deux et rater la commande.
      l := FQueue.LockList;
      try
        if l.Count > 0 then
        begin
          cmd := TWorkerCommand(l[0]);
          l.Delete(0);
          EnterCriticalSection(FCurrentLock);
          FCurrent := cmd;
          LeaveCriticalSection(FCurrentLock);
        end;
      finally
        FQueue.UnlockList;
      end;
      if cmd = nil then
      begin
        RTLEventWaitFor(FWake, 500);
        Continue;
      end;
      try
        try
          ApplySensitivePolicy;
          cmd.Execute(Self);
        except
          on E: Exception do
            try
              cmd.Fail(Self, E.Message);
            except
            end;
        end;
      finally
        EnterCriticalSection(FCurrentLock);
        FCurrent := nil;
        LeaveCriticalSection(FCurrentLock);
        cmd.Free;
      end;
    end;
  finally
    FSession.Close;
    FreeAndNil(FSession);
  end;
end;

destructor TConnectCmd.Destroy;
begin
  WipeString(Secret);
  inherited Destroy;
end;

procedure TConnectCmd.Execute(AWorker: TDirectoryWorker);
var
  m: TConnectedMsg;
begin
  AWorker.FStepOwner := Owner;
  AWorker.FStepTask := TaskId;
  m := TConnectedMsg.Create;
  try
    AWorker.Stamp(m, Self);
    m.Ok := AWorker.Session.Connect(Secret, Cancel);
    WipeString(Secret);
    m.Error := AWorker.Session.LastError;
    m.Transport := AWorker.Session.Transport;
    if m.Ok then
    begin
      m.RootDse := AWorker.Session.ReadRootDse(Cancel);
      m.Summary := AWorker.Session.ConnectSummary;
      m.Warnings := AWorker.Session.ConnectWarnings;
      m.RewriteNote := AWorker.Session.ConnectRewriteNote;
    end;
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
end;

procedure TConnectCmd.Fail(AWorker: TDirectoryWorker; const AText: string);
var
  m: TConnectedMsg;
begin
  WipeString(Secret);
  m := TConnectedMsg.Create;
  AWorker.Stamp(m, Self);
  m.Ok := False;
  m.Error := MakeError(lecOther, 0, 'connect', AText);
  UiInbox.Post(m);
end;

type
  TBatcher = class
    Worker: TDirectoryWorker;
    Cmd: TSearchCmd;
    Batch: TEntriesMsg;
    BatchBytes: Int64;
    Completion: ^TSearchCompletion;
    destructor Destroy; override;
    procedure OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
    procedure Flush(AFinal: Boolean);
  end;

destructor TBatcher.Destroy;
begin
  Batch.Free;
  inherited Destroy;
end;

const
  // Borne en octets par lot: quelques entrees enormes partent seules au lieu d'empiler 200 x 64 Mio
  // dans un seul message.
  BATCH_MAX_BYTES = 8 * 1024 * 1024;
  SEARCH_QUEUE_MAX_BYTES = 32 * 1024 * 1024;

procedure TBatcher.Flush(AFinal: Boolean);
begin
  if (Batch = nil) and not AFinal then Exit;
  if Batch = nil then
  begin
    Batch := TEntriesMsg.Create;
    Worker.Stamp(Batch, Cmd);
    Batch.Tag := Cmd.Tag;
    BatchBytes := 0;
  end;
  Batch.Final := AFinal;
  Batch.Cost := BatchBytes;
  if Completion <> nil then
    Batch.ServerPageSize := Completion^.FirstPageSize;
  // Contre-pression: une interface lente ou coincee dans un dialogue modal ne laisse pas la file
  // grossir sans fin, le producteur attend. Le message final, lui, n'attend jamais.
  if not AFinal then
    UiInbox.WaitForRoom(Cmd.Owner, BatchBytes, SEARCH_QUEUE_MAX_BYTES, Cmd.Cancel);
  UiInbox.Post(Batch);
  Batch := nil;
  BatchBytes := 0;
end;

procedure TBatcher.OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
begin
  if Batch = nil then
  begin
    Batch := TEntriesMsg.Create;
    Worker.Stamp(Batch, Cmd);
    Batch.Tag := Cmd.Tag;
    BatchBytes := 0;
  end;
  Batch.Entries.Add(AEntry);
  Inc(BatchBytes, AEntry.MemoryCost);
  if (Batch.Entries.Count >= Cmd.BatchSize) or (BatchBytes >= BATCH_MAX_BYTES) then
    Flush(False);
end;

procedure TSearchCmd.Execute(AWorker: TDirectoryWorker);
var
  b: TBatcher;
  c: TSearchCompletion;
begin
  if BatchSize < 1 then BatchSize := 200;
  c := Default(TSearchCompletion);
  b := TBatcher.Create;
  try
    b.Worker := AWorker;
    b.Cmd := Self;
    b.Completion := @c;
    AWorker.Session.Search(Request, @b.OnEntry, Cancel, c, AssembleRanges);
    if b.Batch = nil then
    begin
      b.Batch := TEntriesMsg.Create;
      AWorker.Stamp(b.Batch, Self);
      b.Batch.Tag := Tag;
    end;
    b.Batch.Completion := c;
    b.Batch.Error := AWorker.Session.LastError;
    b.Flush(True);
  finally
    b.Free;
  end;
end;

procedure TSearchCmd.Fail(AWorker: TDirectoryWorker; const AText: string);
var
  m: TEntriesMsg;
begin
  m := TEntriesMsg.Create;
  AWorker.Stamp(m, Self);
  m.Tag := Tag;
  m.Final := True;
  m.Completion.HasResult := True;
  m.Completion.ResultCode := -1;
  m.Completion.DiagnosticMessage := AText;
  m.Error := MakeError(lecOther, 0, 'search', AText);
  UiInbox.Post(m);
end;

procedure TReadEntryCmd.Execute(AWorker: TDirectoryWorker);
var
  m: TEntryMsg;
begin
  m := TEntryMsg.Create;
  try
    AWorker.Stamp(m, Self);
    m.Tag := Tag;
    if Length(Controls) > 0 then
      m.Entry := AWorker.Session.ReadEntry(Dn, Attributes, Controls, Cancel)
    else if Length(Attributes) = 0 then
      m.Entry := AWorker.Session.ReadEntry(Dn, ['*', '+'], Cancel)
    else
      m.Entry := AWorker.Session.ReadEntry(Dn, Attributes, Cancel);
    m.Error := AWorker.Session.LastError;
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
end;

procedure TReadEntryCmd.Fail(AWorker: TDirectoryWorker; const AText: string);
var
  m: TEntryMsg;
begin
  m := TEntryMsg.Create;
  AWorker.Stamp(m, Self);
  m.Tag := Tag;
  m.Error := MakeError(lecOther, 0, 'read', AText);
  UiInbox.Post(m);
end;

destructor TWriteCmd.Destroy;
begin
  Change.Free;
  inherited Destroy;
end;

function MaskSensitiveModValues(const AText: string; AChange: TLdapChange;
  APolicy: TSensitivePolicy): string;
var
  i: Integer;
begin
  Result := AText;
  if (AChange = nil) or (APolicy = nil) then Exit;
  for i := 0 to High(AChange.Mods) do
    if APolicy.IsSensitive(AChange.Mods[i].Attr) then
      Result := MaskValueOccurrences(Result, AChange.Mods[i].Values);
end;

procedure TWriteCmd.Execute(AWorker: TDirectoryWorker);
var
  m: TWriteMsg;
  s: TDirectorySession;
  target: string;
begin
  m := TWriteMsg.Create;
  try
    AWorker.Stamp(m, Self);
    m.Tag := Tag;
    s := AWorker.Session;
    // A partir d'ici, une exception ne permet plus de jurer que rien n'est parti.
    FSent := True;
    case Change.Kind of
      ckModify: m.Result := s.Modify(Change.Dn, Change.Mods, AssertionFilter, RequestControls, Cancel);
      ckAdd: m.Result := s.Add(Change.Entry, Cancel);
      ckDelete: m.Result := s.Delete(Change.Dn, AssertionFilter, Cancel);
      ckModDn: m.Result := s.Rename(Change.Dn, Change.NewRdn, Change.NewSuperior,
        Change.HasNewSuperior, Change.DeleteOldRdn, Cancel);
    end;
    // Certains serveurs recopient la valeur refusee dans le diagnostic: celles des attributs
    // sensibles sont masquees.
    if (not m.Result.Ok) and (m.Result.Error.Diagnostic <> '') then
      m.Result.Error.Diagnostic := MaskSensitiveModValues(m.Result.Error.Diagnostic,
        Change, s.Sensitive);
    if m.Result.Ok and (Change.Kind in [ckModify, ckAdd]) and s.IsConnected then
    begin
      target := Change.Dn;
      try
        if Length(RereadAttributes) = 0 then
          m.Reread := s.ReadEntry(target, ['*', '+'], Cancel)
        else
          m.Reread := s.ReadEntry(target, RereadAttributes, Cancel);
      except
        on E: Exception do
        begin
          // Ecriture confirmee par le serveur: une relecture ratee n'en fait pas une issue
          // inconnue.
          FreeAndNil(m.Reread);
          m.Note := 'write applied; the entry could not be read again: ' + E.Message;
        end;
      end;
    end;
    m.Change := Change;
    Change := nil;
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
end;

procedure TWriteCmd.Fail(AWorker: TDirectoryWorker; const AText: string);
var
  m: TWriteMsg;
begin
  m := TWriteMsg.Create;
  AWorker.Stamp(m, Self);
  m.Tag := Tag;
  if FSent then
  begin
    // Exception peut-etre apres emission: jamais presentee comme un refus local.
    m.Result.Error := MakeError(lecUnknownOutcome, 0, 'write', AText);
    m.Result.Error.Action := SuggestedAction(lecUnknownOutcome);
    m.Result.Sent := True;
  end
  else
    m.Result.Error := MakeError(lecOther, 0, 'write', AText);
  m.Change := Change;
  Change := nil;
  UiInbox.Post(m);
end;

procedure TSchemaCmd.Execute(AWorker: TDirectoryWorker);
var
  m: TSchemaMsg;
begin
  m := TSchemaMsg.Create;
  try
    AWorker.Stamp(m, Self);
    m.Schema := ReadSchema(AWorker.Session, SubschemaDn, Cancel, m.Reason);
    // AD: les vrais types (SID, temps, descripteurs) vivent sous schemaNamingContext; le
    // sous-schema agrege seul ne les connait pas.
    if (m.Schema <> nil) and (AdSchemaDn <> '') then
    begin
      m.Schema.AdMeta := ReadAdSchemaMeta(AWorker.Session, AdSchemaDn, Cancel);
      if not m.Schema.AdMeta.Complete then
        m.Schema.AdMetaReason := m.Schema.AdMeta.Reason;
    end;
    // Alias et OID des secrets appris avant toute ecriture.
    if m.Schema <> nil then
      AWorker.Session.Sensitive.LearnSchema(m.Schema);
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
end;

procedure TSchemaCmd.Fail(AWorker: TDirectoryWorker; const AText: string);
var
  m: TSchemaMsg;
begin
  m := TSchemaMsg.Create;
  AWorker.Stamp(m, Self);
  m.Reason := AText;
  UiInbox.Post(m);
end;

destructor TPasswordMsg.Destroy;
begin
  // Un secret genere par le serveur ne survit pas au message.
  WipeString(Result.Generated);
  inherited Destroy;
end;

destructor TPasswordModifyCmd.Destroy;
begin
  WipeString(OldSecret);
  WipeString(NewSecret);
  inherited Destroy;
end;

procedure TPasswordModifyCmd.Execute(AWorker: TDirectoryWorker);
var
  m: TPasswordMsg;
begin
  m := TPasswordMsg.Create;
  try
    AWorker.Stamp(m, Self);
    m.UserDn := UserDn;
    m.Result := AWorker.Session.PasswordModify(UserDn, OldSecret, NewSecret, HasOld, HasNew, Cancel);
    // Le diagnostic serveur peut refleter la valeur soumise: masquee.
    m.Result.Error.Diagnostic := MaskValueOccurrences(m.Result.Error.Diagnostic,
      [OldSecret, NewSecret]);
    WipeString(OldSecret);
    WipeString(NewSecret);
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
end;

procedure TPasswordModifyCmd.Fail(AWorker: TDirectoryWorker; const AText: string);
var
  m: TPasswordMsg;
begin
  WipeString(OldSecret);
  WipeString(NewSecret);
  m := TPasswordMsg.Create;
  AWorker.Stamp(m, Self);
  m.UserDn := UserDn;
  m.Result.Error := MakeError(lecUnknownOutcome, 0, 'password modify', AText);
  m.Result.Error.Action := SuggestedAction(lecUnknownOutcome);
  UiInbox.Post(m);
end;

procedure TLdifSaveCmd.Execute(AWorker: TDirectoryWorker);
var
  m: TLdifSavedMsg;
  s: TLdifSession;
begin
  m := TLdifSavedMsg.Create;
  try
    AWorker.Stamp(m, Self);
    m.Path := Path;
    if not (AWorker.Session is TLdifSession) then
      m.Error := MakeError(lecOther, 0, 'save', 'not an LDIF file')
    else
    begin
      s := TLdifSession(AWorker.Session);
      m.Ok := s.SaveTo(Path);
      m.Error := s.LastError;
      if s.Store <> nil then
      begin
        m.EntryCount := s.Store.EntryCount;
        m.ChangeCount := s.Store.ChangeCount;
      end;
    end;
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
end;

procedure TLdifSaveCmd.Fail(AWorker: TDirectoryWorker; const AText: string);
var
  m: TLdifSavedMsg;
begin
  m := TLdifSavedMsg.Create;
  AWorker.Stamp(m, Self);
  m.Path := Path;
  m.Error := MakeError(lecOther, 0, 'save', AText);
  UiInbox.Post(m);
end;

destructor TLdifSchemaCmd.Destroy;
begin
  Schema.Free;
  inherited Destroy;
end;

procedure TLdifSchemaCmd.Execute(AWorker: TDirectoryWorker);
begin
  if AWorker.Session is TLdifSession then
  begin
    TLdifSession(AWorker.Session).UseSchema(Schema);
    Schema := nil;
  end;
end;

constructor TAuthTestThread.Create(AProfile: TConnectionProfile; const ABindDn: string;
  const ASecret: RawByteString; AOwner: Pointer; ATaskId: Int64);
begin
  FProfile := TConnectionProfile.Create;
  FProfile.Assign(AProfile);
  FProfile.AuthMode := amSimple;
  FProfile.BindDn := ABindDn;
  FProfile.AppendBaseDn := False;
  FProfile.BaseDns.Clear;
  FSecret := ASecret;
  UniqueString(FSecret);
  inherited Create(AOwner, ATaskId);
end;

destructor TAuthTestThread.Destroy;
begin
  WipeString(FSecret);
  FProfile.Free;
  inherited Destroy;
end;

procedure TAuthTestThread.Run;
var
  s: TLdapSession;
  m: TAuthTestMsg;
begin
  m := TAuthTestMsg.Create;
  try
    m.Owner := Owner;
    m.TaskId := TaskId;
    if FProfile.Transport = tmPlain then
    begin
      // Les outils de mot de passe exigent un canal chiffre. Verifier un mot de passe en l'envoyant
      // en clair, c'est une idee qu'on n'a qu'une fois.
      m.Accepted := False;
      m.Error := MakeError(lecConfiguration, 0, 'authentication test',
        'testing a password requires an encrypted connection');
    end
    else if Cancel.IsCancelled then
    begin
      m.Accepted := False;
      m.Error := MakeError(lecCancelled, 0, 'authentication test', 'cancelled');
    end
    else
    begin
      s := TLdapSession.Create(FProfile, 'auth-test', 0);
      try
        // Une action utilisateur, une tentative: pas de boucle, pas de rebind. Le verrouillage de
        // compte se debrouille tres bien sans aide.
        m.Accepted := s.Connect(FSecret, Cancel);
        m.Error := s.LastError;
        // Rien du secret dans le texte de l'erreur.
        m.Error.Diagnostic := MaskValueOccurrences(m.Error.Diagnostic, [FSecret]);
        m.Transport := s.Transport;
        s.Close;
      finally
        s.Free;
      end;
    end;
    WipeString(FSecret);
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
end;

end.
