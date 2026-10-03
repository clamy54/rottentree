// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uOwnedThread;

{$mode objfpc}{$H+}

// Fil a proprietaire unique. Release est la seule autorite de destruction: arret demande, attente
// bornee, liberation, ou detachement si le fil traine. Les detaches sont rejoints avant la fin de
// la boite de l'interface: un fil en retard ne poste pas dans une boite morte.

interface

uses
  SysUtils, Classes;

type
  TOwnedThread = class(TThread)
  private
    FLifeLock: TRTLCriticalSection;
    FStopRequested: Boolean;
    FExecuteDone: Boolean;
    FDetached: Boolean;
  protected
    procedure Run; virtual; abstract;
    // Annulation cooperative, jamais Terminate: si Terminated est vrai au demarrage, le runtime
    // saute Execute, et "jamais demarre" devient indiscernable de "pas encore signale".
    procedure RequestStop; virtual;
    function StopRequested: Boolean;
    procedure Execute; override;
  public
    // Le fil demarre ici: les descendants posent tous leurs champs AVANT d'appeler ce constructeur.
    constructor Create;
    destructor Destroy; override;
    // Apres cet appel, l'objet n'existe plus pour l'appelant. Un Free ici serait le dernier geste.
    function Release(AWaitMs: Integer): Boolean;
    function IsExecuteDone: Boolean;
  end;

function DetachedThreadCount: Integer;
function JoinDetachedThreads(ATimeoutMs: Integer): Boolean;

implementation

uses
  uUiInbox;

var
  GRegistry: TList = nil;
  GRegistryLock: TRTLCriticalSection;

procedure RegisterDetached(AThread: TOwnedThread);
begin
  EnterCriticalSection(GRegistryLock);
  try
    GRegistry.Add(AThread);
  finally
    LeaveCriticalSection(GRegistryLock);
  end;
end;

procedure UnregisterDetached(AThread: TOwnedThread);
begin
  EnterCriticalSection(GRegistryLock);
  try
    GRegistry.Remove(AThread);
  finally
    LeaveCriticalSection(GRegistryLock);
  end;
end;

function DetachedThreadCount: Integer;
begin
  EnterCriticalSection(GRegistryLock);
  try
    Result := GRegistry.Count;
  finally
    LeaveCriticalSection(GRegistryLock);
  end;
end;

function JoinDetachedThreads(ATimeoutMs: Integer): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  while (DetachedThreadCount > 0) and (waited < ATimeoutMs) do
  begin
    Sleep(10);
    Inc(waited, 10);
  end;
  Result := DetachedThreadCount = 0;
end;

constructor TOwnedThread.Create;
begin
  InitCriticalSection(FLifeLock);
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TOwnedThread.Destroy;
begin
  DoneCriticalSection(FLifeLock);
  inherited Destroy;
end;

procedure TOwnedThread.RequestStop;
begin
end;

function TOwnedThread.StopRequested: Boolean;
begin
  EnterCriticalSection(FLifeLock);
  try
    Result := FStopRequested;
  finally
    LeaveCriticalSection(FLifeLock);
  end;
end;

function TOwnedThread.IsExecuteDone: Boolean;
begin
  EnterCriticalSection(FLifeLock);
  try
    Result := FExecuteDone;
  finally
    LeaveCriticalSection(FLifeLock);
  end;
end;

procedure TOwnedThread.Execute;
begin
  try
    Run;
  finally
    // Fin de vie decidee sous verrou: soit Release libere, soit le fil se libere seul. Jamais les
    // deux.
    EnterCriticalSection(FLifeLock);
    try
      FExecuteDone := True;
      if FDetached then
      begin
        UnregisterDetached(Self);
        FreeOnTerminate := True;
      end;
    finally
      LeaveCriticalSection(FLifeLock);
    end;
  end;
end;

function TOwnedThread.Release(AWaitMs: Integer): Boolean;
var
  waited: Integer;
begin
  EnterCriticalSection(FLifeLock);
  FStopRequested := True;
  LeaveCriticalSection(FLifeLock);
  RequestStop;
  waited := 0;
  while (not IsExecuteDone) and (waited < AWaitMs) do
  begin
    Sleep(10);
    Inc(waited, 10);
  end;
  EnterCriticalSection(FLifeLock);
  try
    Result := FExecuteDone;
    if not Result then
    begin
      FDetached := True;
      RegisterDetached(Self);
    end;
  finally
    LeaveCriticalSection(FLifeLock);
  end;
  if Result then
    Free;
end;

initialization
  InitCriticalSection(GRegistryLock);
  GRegistry := TList.Create;

finalization
  // Unite finalisee avant uUiInbox: derniere echeance pour les detaches, puis la boite est fermee
  // mais conservee, pour qu'un message tardif soit jete au lieu d'ecrire dans de la memoire
  // liberee.
  if not JoinDetachedThreads(5000) then
    UiInboxKeepAliveAtExit
  else
  begin
    GRegistry.Free;
    DoneCriticalSection(GRegistryLock);
  end;

end.
