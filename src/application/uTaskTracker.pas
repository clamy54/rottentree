// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTaskTracker;

{$mode objfpc}{$H+}

// Cycle de vie des taches d'annuaire d'une vue. Chaque dialogue tenait ses identifiants a la main
// et oubliait toujours un chemin; ici toute tache est declaree a l'emission et soldee par le
// registre. Une reponse non declaree n'est jamais livree, et une ecriture emise ne s'annule jamais.

interface

uses
  SysUtils, Classes, uUiInbox, uDirectoryWorker, uLdapErrors, uSearchModel, uChangeSet,
  uConnections, uDirectoryOps, uDirectoryService;

type
  TTrackedTask = record
    Id: Int64;
    Kind: TTaskKind;
    Tag: string;
    ProfileUuid: string;
    SessionId: string;
    Generation: Int64;
  end;

  TTaskEnding = (
    tePartial,
    teDone,
    teFailed,
    teStale
  );

  TTaskTracker = class
  private
    FTasks: array of TTrackedTask;
    FCount: Integer;
    FUnknownWrite: Boolean;
    FModelStamped: Boolean;
    FModelRequired: Boolean;
    FModelProfile, FModelSession: string;
    FModelGeneration: Int64;
    function IndexOf(AId: Int64): Integer;
    procedure DeleteAt(AIndex: Integer);
    procedure WriteEnded(AMsg: TUiMessage; AStale: Boolean);
    function GetItem(AIndex: Integer): TTrackedTask;
  public
    procedure Track(AId: Int64; AKind: TTaskKind; const ATag, AProfileUuid, ASessionId: string;
      AGeneration: Int64);
    function Find(AId: Int64; out ATask: TTrackedTask): Boolean;
    function Owns(AId: Int64): Boolean;
    function TaskOf(const ATag: string): Int64;
    procedure Forget(AId: Int64);
    function Settle(AMsg: TUiMessage; AStale: Boolean; out ATask: TTrackedTask;
      out AEnding: TTaskEnding): Boolean;
    class function IsTerminal(AMsg: TUiMessage): Boolean;
    procedure StampModel(const AProfileUuid, ASessionId: string; AGeneration: Int64);
    procedure InvalidateModel;
    function ModelMatches(const AProfileUuid, ASessionId: string; AGeneration: Int64): Boolean;
    procedure AcknowledgeUnknownWrite;
    property Count: Integer read FCount;
    property Items[AIndex: Integer]: TTrackedTask read GetItem; default;
    property ModelStamped: Boolean read FModelStamped;
    // Une vue qui a date un modele en depend pour toujours: une invalidation ne leve jamais cette
    // exigence.
    property ModelRequired: Boolean read FModelRequired;
    property UnknownWrite: Boolean read FUnknownWrite;
  end;

  TTaskMessageEvent = procedure(AMsg: TUiMessage; const ATask: TTrackedTask;
    AEnding: TTaskEnding) of object;

  TWriteSettledEvent = procedure(AKind: TOrphanWriteKind; const AText: string) of object;

  TDirectoryTasks = class
  private
    FManager: TConnectionManager;
    FProfileUuid: string;
    FOwner: Pointer;
    FTracker: TTaskTracker;
    FCurrent: TTrackedTask;
    FUnknownDetail: string;
    FOnMessage: TTaskMessageEvent;
    FOnUntracked: TUiMessageHandler;
    FOnAfterMessage: TNotifyEvent;
    FOnWriteSettled: TWriteSettledEvent;
    procedure HandleInbox(AMsg: TUiMessage);
    procedure SettleWrite(AMsg: TUiMessage);
    procedure OpsIssued(Sender: TConnectionOps; ATaskId: Int64; AKind: TTaskKind);
    function Track(ATaskId: Int64; AKind: TTaskKind; const ATag: string;
      AConn: TDirectoryConnection): Int64;
    function Alive(const ATask: TTrackedTask): Boolean;
  public
    constructor Create(AManager: TConnectionManager; const AProfileUuid: string; AOwner: Pointer);
    destructor Destroy; override;
    function Conn: TDirectoryConnection;
    function ReadEntry(const ATag, ADn: string; const AAttrs: array of string): Int64; overload;
    function ReadEntry(const ATag, ADn: string; const AAttrs: array of string;
      const AControls: TRequestControlArray): Int64; overload;
    function Search(const ATag: string; const AReq: TSearchRequest;
      AAssembleRanges: Boolean = False): Int64;
    function Write(const ATag: string; AChange: TLdapChange; const AAssertion: string;
      out AError: TLdapError): Int64; overload;
    function Write(const ATag: string; AChange: TLdapChange; const AAssertion: string;
      const AControls: TRequestControlArray; const ARereadAttrs: array of string;
      out AError: TLdapError): Int64; overload;
    function FetchSchema(const ATag: string): Int64;
    function PasswordModify(const ATag, AUserDn: string; const AOld, ANew: RawByteString;
      AHasOld, AHasNew: Boolean; out AError: TLdapError): Int64;
    procedure Declare(ATaskId: Int64; AKind: TTaskKind; const ATag: string);
    procedure Attach(AOps: TConnectionOps; const ATag: string);
    function Pending(const ATag: string): Boolean;
    function TaskOf(const ATag: string): Int64;
    function Busy(AKinds: TTaskKinds): Boolean;
    function WritesInFlight: Boolean;
    procedure Cancel(const ATag: string);
    procedure Stop(const ATag: string);
    procedure StampModel(AMsg: TUiMessage);
    function ModelCurrent: Boolean;
    procedure InvalidateModel;
    property Tracker: TTaskTracker read FTracker;
    property Current: TTrackedTask read FCurrent;
    property ProfileUuid: string read FProfileUuid write FProfileUuid;
    property OnMessage: TTaskMessageEvent read FOnMessage write FOnMessage;
    property OnUntracked: TUiMessageHandler read FOnUntracked write FOnUntracked;
    property OnAfterMessage: TNotifyEvent read FOnAfterMessage write FOnAfterMessage;
    property OnWriteSettled: TWriteSettledEvent read FOnWriteSettled write FOnWriteSettled;
    property UnknownDetail: string read FUnknownDetail write FUnknownDetail;
  end;

implementation

resourcestring
  rsTtNotConnected = 'not connected';

function TTaskTracker.IndexOf(AId: Int64): Integer;
var
  i: Integer;
begin
  if AId <> 0 then
    for i := 0 to FCount - 1 do
      if FTasks[i].Id = AId then Exit(i);
  Result := -1;
end;

procedure TTaskTracker.DeleteAt(AIndex: Integer);
var
  i: Integer;
begin
  for i := AIndex to FCount - 2 do
    FTasks[i] := FTasks[i + 1];
  Dec(FCount);
  FTasks[FCount] := Default(TTrackedTask);
end;

function TTaskTracker.GetItem(AIndex: Integer): TTrackedTask;
begin
  Result := FTasks[AIndex];
end;

procedure TTaskTracker.Track(AId: Int64; AKind: TTaskKind; const ATag, AProfileUuid,
  ASessionId: string; AGeneration: Int64);
begin
  if (AId = 0) or (IndexOf(AId) >= 0) then Exit;
  if FCount = Length(FTasks) then
    SetLength(FTasks, FCount * 2 + 4);
  FTasks[FCount].Id := AId;
  FTasks[FCount].Kind := AKind;
  FTasks[FCount].Tag := ATag;
  FTasks[FCount].ProfileUuid := AProfileUuid;
  FTasks[FCount].SessionId := ASessionId;
  FTasks[FCount].Generation := AGeneration;
  Inc(FCount);
end;

function TTaskTracker.Find(AId: Int64; out ATask: TTrackedTask): Boolean;
var
  i: Integer;
begin
  i := IndexOf(AId);
  Result := i >= 0;
  if Result then ATask := FTasks[i] else ATask := Default(TTrackedTask);
end;

function TTaskTracker.Owns(AId: Int64): Boolean;
begin
  Result := IndexOf(AId) >= 0;
end;

function TTaskTracker.TaskOf(const ATag: string): Int64;
var
  i: Integer;
begin
  for i := 0 to FCount - 1 do
    if FTasks[i].Tag = ATag then Exit(FTasks[i].Id);
  Result := 0;
end;

procedure TTaskTracker.Forget(AId: Int64);
var
  i: Integer;
begin
  i := IndexOf(AId);
  if i >= 0 then DeleteAt(i);
end;

class function TTaskTracker.IsTerminal(AMsg: TUiMessage): Boolean;
begin
  Result := not (AMsg is TEntriesMsg) or TEntriesMsg(AMsg).Final;
end;

procedure TTaskTracker.WriteEnded(AMsg: TUiMessage; AStale: Boolean);
var
  ok: Boolean;
  cat: TLdapErrorCategory;
begin
  // Session perdue ou commande sans resultat type: l'ecriture a pu partir.
  if AStale or (AMsg is TTaskFailedMsg) then
  begin
    FUnknownWrite := True;
    InvalidateModel;
    Exit;
  end;
  if AMsg is TWriteMsg then
  begin
    ok := TWriteMsg(AMsg).Result.Ok;
    cat := TWriteMsg(AMsg).Result.Error.Category;
  end
  else if AMsg is TPasswordMsg then
  begin
    ok := TPasswordMsg(AMsg).Result.Ok;
    cat := TPasswordMsg(AMsg).Result.Error.Category;
  end
  else
    Exit;
  // Ecriture appliquee: ce qui avait ete lu ne decrit plus le serveur. Un refus franc laisse le
  // modele valable.
  if ok then
    InvalidateModel
  else if cat = lecUnknownOutcome then
  begin
    FUnknownWrite := True;
    InvalidateModel;
  end;
end;

function TTaskTracker.Settle(AMsg: TUiMessage; AStale: Boolean; out ATask: TTrackedTask;
  out AEnding: TTaskEnding): Boolean;
var
  i: Integer;
begin
  AEnding := teDone;
  i := IndexOf(AMsg.TaskId);
  Result := i >= 0;
  if not Result then
  begin
    ATask := Default(TTrackedTask);
    Exit;
  end;
  ATask := FTasks[i];
  if AStale then AEnding := teStale
  else if AMsg is TTaskFailedMsg then AEnding := teFailed
  else if not IsTerminal(AMsg) then
  begin
    AEnding := tePartial;
    Exit;
  end;
  DeleteAt(i);
  if ATask.Kind = tkWrite then WriteEnded(AMsg, AStale);
end;

procedure TTaskTracker.StampModel(const AProfileUuid, ASessionId: string; AGeneration: Int64);
begin
  FModelStamped := True;
  FModelRequired := True;
  FModelProfile := AProfileUuid;
  FModelSession := ASessionId;
  FModelGeneration := AGeneration;
end;

procedure TTaskTracker.InvalidateModel;
begin
  FModelStamped := False;
  FModelProfile := '';
  FModelSession := '';
  FModelGeneration := 0;
end;

function TTaskTracker.ModelMatches(const AProfileUuid, ASessionId: string;
  AGeneration: Int64): Boolean;
begin
  Result := FModelStamped and (FModelProfile = AProfileUuid) and (FModelSession = ASessionId) and
    (FModelGeneration = AGeneration);
end;

procedure TTaskTracker.AcknowledgeUnknownWrite;
begin
  FUnknownWrite := False;
end;

constructor TDirectoryTasks.Create(AManager: TConnectionManager; const AProfileUuid: string;
  AOwner: Pointer);
begin
  inherited Create;
  FManager := AManager;
  FProfileUuid := AProfileUuid;
  FOwner := AOwner;
  FTracker := TTaskTracker.Create;
  UiInbox.Subscribe(FOwner, @HandleInbox);
end;

destructor TDirectoryTasks.Destroy;
begin
  // Reponses tardives: jamais livrees a une vue fermee, elles finissent au puits des orphelins.
  UiInbox.Unsubscribe(FOwner);
  FTracker.Free;
  inherited Destroy;
end;

function TDirectoryTasks.Conn: TDirectoryConnection;
begin
  Result := FManager.Find(FProfileUuid);
  if (Result <> nil) and not Result.IsReady then Result := nil;
end;

function TDirectoryTasks.Track(ATaskId: Int64; AKind: TTaskKind; const ATag: string;
  AConn: TDirectoryConnection): Int64;
begin
  Result := ATaskId;
  if (ATaskId = 0) or (AConn = nil) then Exit;
  FTracker.Track(ATaskId, AKind, ATag, AConn.Profile.Uuid, AConn.SessionId, AConn.Generation);
end;

function TDirectoryTasks.ReadEntry(const ATag, ADn: string; const AAttrs: array of string): Int64;
var
  c: TDirectoryConnection;
begin
  c := Conn;
  if c = nil then Exit(0);
  Result := Track(FManager.ReadEntry(c, ADn, AAttrs, FOwner, 0), tkRead, ATag, c);
end;

function TDirectoryTasks.ReadEntry(const ATag, ADn: string; const AAttrs: array of string;
  const AControls: TRequestControlArray): Int64;
var
  c: TDirectoryConnection;
begin
  c := Conn;
  if c = nil then Exit(0);
  Result := Track(FManager.ReadEntry(c, ADn, AAttrs, AControls, FOwner, 0), tkRead, ATag, c);
end;

function TDirectoryTasks.Search(const ATag: string; const AReq: TSearchRequest;
  AAssembleRanges: Boolean): Int64;
var
  c: TDirectoryConnection;
begin
  c := Conn;
  if c = nil then Exit(0);
  Result := Track(FManager.Search(c, AReq, FOwner, 0, AAssembleRanges), tkSearch, ATag, c);
end;

function TDirectoryTasks.Write(const ATag: string; AChange: TLdapChange; const AAssertion: string;
  out AError: TLdapError): Int64;
var
  c: TDirectoryConnection;
begin
  AError := NoError;
  c := Conn;
  if c = nil then
  begin
    AChange.Free;
    AError := MakeError(lecNetwork, 0, 'directory', rsTtNotConnected);
    Exit(0);
  end;
  Result := Track(FManager.Write(c, AChange, AAssertion, FOwner, 0, AError), tkWrite, ATag, c);
end;

function TDirectoryTasks.Write(const ATag: string; AChange: TLdapChange; const AAssertion: string;
  const AControls: TRequestControlArray; const ARereadAttrs: array of string;
  out AError: TLdapError): Int64;
var
  c: TDirectoryConnection;
begin
  AError := NoError;
  c := Conn;
  if c = nil then
  begin
    AChange.Free;
    AError := MakeError(lecNetwork, 0, 'directory', rsTtNotConnected);
    Exit(0);
  end;
  Result := Track(FManager.Write(c, AChange, AAssertion, AControls, FOwner, 0, ARereadAttrs, AError),
    tkWrite, ATag, c);
end;

function TDirectoryTasks.FetchSchema(const ATag: string): Int64;
var
  c: TDirectoryConnection;
begin
  c := Conn;
  if c = nil then Exit(0);
  Result := Track(FManager.FetchSchema(c, FOwner), tkRead, ATag, c);
end;

function TDirectoryTasks.PasswordModify(const ATag, AUserDn: string; const AOld, ANew: RawByteString;
  AHasOld, AHasNew: Boolean; out AError: TLdapError): Int64;
var
  c: TDirectoryConnection;
begin
  AError := NoError;
  c := Conn;
  if c = nil then
  begin
    AError := MakeError(lecNetwork, 0, 'directory', rsTtNotConnected);
    Exit(0);
  end;
  Result := Track(FManager.PasswordModify(c, AUserDn, AOld, ANew, AHasOld, AHasNew, FOwner, AError),
    tkWrite, ATag, c);
end;

procedure TDirectoryTasks.Declare(ATaskId: Int64; AKind: TTaskKind; const ATag: string);
begin
  Track(ATaskId, AKind, ATag, FManager.Find(FProfileUuid));
end;

procedure TDirectoryTasks.Attach(AOps: TConnectionOps; const ATag: string);
begin
  if AOps = nil then Exit;
  AOps.TaskTag := ATag;
  AOps.OnIssued := @OpsIssued;
end;

procedure TDirectoryTasks.OpsIssued(Sender: TConnectionOps; ATaskId: Int64; AKind: TTaskKind);
begin
  // Appel synchrone juste apres l'emission: la connexion trouvee est forcement celle qui a recu la
  // commande.
  Track(ATaskId, AKind, Sender.TaskTag, FManager.Find(Sender.ProfileUuid));
end;

function TDirectoryTasks.Alive(const ATask: TTrackedTask): Boolean;
var
  c: TDirectoryConnection;
begin
  c := FManager.Find(ATask.ProfileUuid);
  Result := (c <> nil) and (c.SessionId = ATask.SessionId) and (c.Generation = ATask.Generation);
end;

function TDirectoryTasks.Pending(const ATag: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to FTracker.Count - 1 do
    if (FTracker[i].Tag = ATag) and Alive(FTracker[i]) then Exit(True);
  Result := False;
end;

function TDirectoryTasks.TaskOf(const ATag: string): Int64;
begin
  Result := FTracker.TaskOf(ATag);
end;

function TDirectoryTasks.Busy(AKinds: TTaskKinds): Boolean;
var
  i: Integer;
begin
  for i := 0 to FTracker.Count - 1 do
    if (FTracker[i].Kind in AKinds) and Alive(FTracker[i]) then Exit(True);
  Result := False;
end;

function TDirectoryTasks.WritesInFlight: Boolean;
begin
  Result := Busy([tkWrite]);
end;

procedure TDirectoryTasks.Cancel(const ATag: string);
var
  i: Integer;
  t: TTrackedTask;
  c: TDirectoryConnection;
begin
  for i := FTracker.Count - 1 downto 0 do
  begin
    t := FTracker[i];
    if (t.Tag <> ATag) or (t.Kind = tkWrite) then Continue;
    c := FManager.Find(t.ProfileUuid);
    if c <> nil then FManager.CancelTask(c, t.Id);
    FTracker.Forget(t.Id);
  end;
end;

procedure TDirectoryTasks.Stop(const ATag: string);
var
  i: Integer;
  t: TTrackedTask;
  c: TDirectoryConnection;
begin
  for i := 0 to FTracker.Count - 1 do
  begin
    t := FTracker[i];
    if (t.Tag <> ATag) or (t.Kind = tkWrite) then Continue;
    c := FManager.Find(t.ProfileUuid);
    if c <> nil then FManager.CancelTask(c, t.Id);
  end;
end;

procedure TDirectoryTasks.StampModel(AMsg: TUiMessage);
var
  profile: string;
begin
  if (FCurrent.Id <> 0) and (FCurrent.Id = AMsg.TaskId) then profile := FCurrent.ProfileUuid
  else profile := FProfileUuid;
  FTracker.StampModel(profile, AMsg.SessionId, AMsg.Generation);
end;

function TDirectoryTasks.ModelCurrent: Boolean;
var
  c: TDirectoryConnection;
begin
  Result := False;
  if not FTracker.ModelStamped then Exit;
  c := FManager.Find(FProfileUuid);
  if (c = nil) or not c.IsReady then Exit;
  Result := FTracker.ModelMatches(c.Profile.Uuid, c.SessionId, c.Generation);
end;

procedure TDirectoryTasks.InvalidateModel;
begin
  FTracker.InvalidateModel;
end;

procedure TDirectoryTasks.SettleWrite(AMsg: TUiMessage);
var
  kind: TOrphanWriteKind;
  text: string;
begin
  // Document d'origine de la soumission, jamais le document courant.
  kind := SettleWriteOutcome(AMsg, FManager, FManager.Journal, text, FUnknownDetail);
  if (kind <> owkNone) and Assigned(FOnWriteSettled) then FOnWriteSettled(kind, text);
end;

procedure TDirectoryTasks.HandleInbox(AMsg: TUiMessage);
var
  t, prev: TTrackedTask;
  c: TDirectoryConnection;
  ending: TTaskEnding;
  stale: Boolean;
begin
  if not FTracker.Find(AMsg.TaskId, t) then
  begin
    if Assigned(FOnUntracked) then FOnUntracked(AMsg);
    Exit;
  end;
  c := FManager.Find(t.ProfileUuid);
  stale := (c = nil) or not c.Accepts(AMsg);
  FTracker.Settle(AMsg, stale, t, ending);
  if (t.Kind = tkWrite) and (ending = teDone) then SettleWrite(AMsg);
  prev := FCurrent;
  FCurrent := t;
  try
    if Assigned(FOnMessage) then FOnMessage(AMsg, t, ending);
  finally
    FCurrent := prev;
  end;
  if Assigned(FOnAfterMessage) then FOnAfterMessage(Self);
end;

end.
