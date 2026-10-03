// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uUiInbox;

{$mode objfpc}{$H+}

// Boite aux lettres entre les fils de travail et l'interface. Les fils ne touchent jamais un
// controle, ils deposent des messages immuables. Une vue disparue voit ses messages partir au puits
// des orphelins, et une reponse d'une session fermee ne change rien.

interface

uses
  SysUtils, Classes, uCancel;

type
  TUiMessage = class
  public
    Owner: Pointer;
    TaskId: Int64;
    SessionId: string;
    Generation: Int64;
    Cost: Int64;
  end;

  TUiMessageHandler = procedure(AMsg: TUiMessage) of object;

  TUiInboxWake = procedure;

  TUiInbox = class
  private
    FLock: TRTLCriticalSection;
    FQueue: TList;
    FHandlers: TList;
    FBusy: TList;
    FClosed: Boolean;
    FOnOrphan: TUiMessageHandler;
    FOnDelivered: TUiMessageHandler;
    FOnWake: TUiInboxWake;
    FRoom: PRTLEvent;
    function TakeNext(out AMsg: TUiMessage): Boolean;
    procedure RouteOrphan(AMsg: TUiMessage);
    procedure AfterDelivery(AMsg: TUiMessage);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Post(AMsg: TUiMessage);
    function QueuedCost(AOwner: Pointer): Int64;
    // Une file vide accepte toujours, meme un message plus gros que la limite, sinon il attendrait
    // pour toujours. Jamais depuis le fil de l'interface: il s'attendrait lui-meme.
    function WaitForRoom(AOwner: Pointer; ANext, ALimit: Int64;
      ACancel: TCancelToken): Boolean;
    procedure Subscribe(AOwner: Pointer; AHandler: TUiMessageHandler);
    procedure Unsubscribe(AOwner: Pointer);
    function Drain(AMax: Integer = 500): Integer;
    function PendingCount: Integer;
    procedure Close;
    // Le puits ne devient pas proprietaire du message et ne relance jamais l'operation qu'il
    // decrit.
    property OnOrphanMessage: TUiMessageHandler read FOnOrphan write FOnOrphan;
    // Filet de securite apres le gestionnaire d'une vue, meme s'il a leve une exception: une issue
    // d'ecriture qu'une vue a ecartee doit encore etre soldee quelque part.
    property OnDeliveredMessage: TUiMessageHandler read FOnDelivered write FOnDelivered;
    // Sans reveil, une operation qui enchaine ses requetes une par une avancait d'une requete par
    // tic de minuterie: 30000 suppressions en 25 minutes. Le temps de relire sa lettre de
    // demission.
    property OnWake: TUiInboxWake read FOnWake write FOnWake;
  end;

function UiInbox: TUiInbox;
// Des fils n'ont pas pu etre rejoints: la boite est fermee mais conservee, un depot tardif est jete
// au lieu d'ecrire dans de la memoire liberee.
procedure UiInboxKeepAliveAtExit;
function NextTaskId: Int64;

implementation

type
  TUiSubscription = class
    Owner: Pointer;
    Handler: TUiMessageHandler;
  end;

var
  GInbox: TUiInbox = nil;
  GKeepAlive: Boolean = False;
  GTaskCounter: Int64 = 0;
  GCounterLock: TRTLCriticalSection;

function UiInbox: TUiInbox;
begin
  // Creee a l'initialisation de l'unite: pas de creation paresseuse a se disputer entre fils.
  Result := GInbox;
end;

procedure UiInboxKeepAliveAtExit;
begin
  GKeepAlive := True;
  if GInbox <> nil then GInbox.Close;
end;

function NextTaskId: Int64;
begin
  EnterCriticalSection(GCounterLock);
  try
    Inc(GTaskCounter);
    Result := GTaskCounter;
  finally
    LeaveCriticalSection(GCounterLock);
  end;
end;

constructor TUiInbox.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FQueue := TList.Create;
  FHandlers := TList.Create;
  FBusy := TList.Create;
  FRoom := RTLEventCreate;
end;

destructor TUiInbox.Destroy;
var
  i: Integer;
begin
  for i := 0 to FQueue.Count - 1 do
    TObject(FQueue[i]).Free;
  FQueue.Free;
  for i := 0 to FHandlers.Count - 1 do
    TObject(FHandlers[i]).Free;
  FHandlers.Free;
  FBusy.Free;
  RTLEventDestroy(FRoom);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TUiInbox.QueuedCost(AOwner: Pointer): Int64;
var
  i: Integer;
begin
  Result := 0;
  EnterCriticalSection(FLock);
  try
    for i := 0 to FQueue.Count - 1 do
      if TUiMessage(FQueue[i]).Owner = AOwner then
        Inc(Result, TUiMessage(FQueue[i]).Cost);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TUiInbox.WaitForRoom(AOwner: Pointer; ANext, ALimit: Int64;
  ACancel: TCancelToken): Boolean;
var
  queued: Int64;
  closed: Boolean;
begin
  repeat
    EnterCriticalSection(FLock);
    try
      closed := FClosed;
    finally
      LeaveCriticalSection(FLock);
    end;
    if closed then Exit(False);
    if (ACancel <> nil) and ACancel.IsCancelled then Exit(False);
    queued := QueuedCost(AOwner);
    if (queued = 0) or (queued + ANext <= ALimit) then Exit(True);
    // Attente bornee: un signal peut etre consomme par un autre producteur, et l'annulation ne
    // signale pas.
    RTLEventWaitFor(FRoom, 50);
  until False;
end;

procedure TUiInbox.Post(AMsg: TUiMessage);
var
  rejected: Boolean;
  wake: TUiInboxWake;
begin
  EnterCriticalSection(FLock);
  try
    rejected := FClosed;
    if not rejected then
      FQueue.Add(AMsg);
    wake := FOnWake;
  finally
    LeaveCriticalSection(FLock);
  end;
  if rejected then
    AMsg.Free
  else if Assigned(wake) then
    wake();
end;

procedure TUiInbox.Close;
var
  i: Integer;
begin
  EnterCriticalSection(FLock);
  try
    FClosed := True;
    for i := 0 to FQueue.Count - 1 do
      TObject(FQueue[i]).Free;
    FQueue.Clear;
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FRoom);
end;

function TUiInbox.TakeNext(out AMsg: TUiMessage): Boolean;
var
  i: Integer;
begin
  AMsg := nil;
  EnterCriticalSection(FLock);
  try
    // Premier message dont la vue n'est pas deja dans un gestionnaire: pas de reentrance, et
    // l'ordre de depot tient pour chaque vue.
    for i := 0 to FQueue.Count - 1 do
      if FBusy.IndexOf(TUiMessage(FQueue[i]).Owner) < 0 then
      begin
        AMsg := TUiMessage(FQueue[i]);
        FQueue.Delete(i);
        Break;
      end;
  finally
    LeaveCriticalSection(FLock);
  end;
  Result := AMsg <> nil;
  if Result then
    RTLEventSetEvent(FRoom);
end;

procedure TUiInbox.Subscribe(AOwner: Pointer; AHandler: TUiMessageHandler);
var
  s: TUiSubscription;
begin
  Unsubscribe(AOwner);
  s := TUiSubscription.Create;
  s.Owner := AOwner;
  s.Handler := AHandler;
  FHandlers.Add(s);
end;

procedure TUiInbox.RouteOrphan(AMsg: TUiMessage);
begin
  // Le puits peut echouer; ca n'empeche ni la liberation du message ni la destruction de la vue.
  if Assigned(FOnOrphan) then
    try
      FOnOrphan(AMsg);
    except
    end;
  AMsg.Free;
end;

procedure TUiInbox.AfterDelivery(AMsg: TUiMessage);
begin
  // Le filet ne masque jamais l'exception d'un gestionnaire et n'empeche pas la liberation du
  // message.
  if Assigned(FOnDelivered) then
    try
      FOnDelivered(AMsg);
    except
    end;
end;

procedure TUiInbox.Unsubscribe(AOwner: Pointer);
var
  i: Integer;
  orphans: TList;
begin
  for i := FHandlers.Count - 1 downto 0 do
    if TUiSubscription(FHandlers[i]).Owner = AOwner then
    begin
      TObject(FHandlers[i]).Free;
      FHandlers.Delete(i);
    end;
  orphans := TList.Create;
  try
    EnterCriticalSection(FLock);
    try
      for i := FQueue.Count - 1 downto 0 do
        if TUiMessage(FQueue[i]).Owner = AOwner then
        begin
          orphans.Insert(0, FQueue[i]);
          FQueue.Delete(i);
        end;
    finally
      LeaveCriticalSection(FLock);
    end;
    if orphans.Count > 0 then
      RTLEventSetEvent(FRoom);
    for i := 0 to orphans.Count - 1 do
      RouteOrphan(TUiMessage(orphans[i]));
  finally
    orphans.Free;
  end;
end;

function TUiInbox.Drain(AMax: Integer): Integer;
var
  j: Integer;
  msg: TUiMessage;
  owner: Pointer;
  handler: TUiMessageHandler;
  pending: TObject;
begin
  Result := 0;
  pending := nil;
  // Un message a la fois: un dialogue modal qui relance le vidage reprend la file la ou elle en
  // est.
  while (Result < AMax) and TakeNext(msg) do
  begin
    owner := msg.Owner;
    try
      handler := nil;
      for j := 0 to FHandlers.Count - 1 do
        if TUiSubscription(FHandlers[j]).Owner = owner then
        begin
          handler := TUiSubscription(FHandlers[j]).Handler;
          Break;
        end;
      if Assigned(handler) then
      begin
        FBusy.Add(owner);
        try
          handler(msg);
        finally
          FBusy.Remove(owner);
          AfterDelivery(msg);
        end;
      end
      else if Assigned(FOnOrphan) then
        FOnOrphan(msg);
    except
      if pending = nil then
        pending := TObject(AcquireExceptionObject);
    end;
    msg.Free;
    Inc(Result);
  end;
  if pending <> nil then
    raise pending;
end;

function TUiInbox.PendingCount: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FQueue.Count;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

initialization
  InitCriticalSection(GCounterLock);
  GInbox := TUiInbox.Create;

finalization
  if GKeepAlive then
    GInbox.Close
  else
    FreeAndNil(GInbox);
  DoneCriticalSection(GCounterLock);

end.
