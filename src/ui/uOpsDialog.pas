// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uOpsDialog;

{$mode objfpc}{$H+}

// Base des dialogues d'administration: lectures sur la connexion du profil, ecriture seulement apres
// apercu confirme. Seules les reponses aux taches declarees sont livrees, une ecriture en vol retient
// la fermeture, et un modele d'une autre session bloque l'envoi.

interface

uses
  Classes, SysUtils, Controls, ExtCtrls, Graphics, uUiKit, uAppContext, uConnections,
  uUiInbox, uDirectoryWorker, uChangeSet, uSearchModel, uLdapErrors, uDirectoryOps, uTaskTracker,
  uTaskDialog;

type
  TOpsDialog = class(TTaskDialog)
  private
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure UntrackedMessage(AMsg: TUiMessage);
    procedure AfterTaskMessage(Sender: TObject);
  protected
    procedure OnEntry(AMsg: TEntryMsg); virtual;
    procedure OnEntries(AMsg: TEntriesMsg); virtual;
    procedure OnWrite(AMsg: TWriteMsg); virtual;
    procedure OnFailed(AMsg: TTaskFailedMsg); virtual;
    procedure OnOther(AMsg: TUiMessage); virtual;
    function AcceptsForeign(AMsg: TUiMessage): Boolean; virtual;
    procedure OnStale(AMsg: TUiMessage); virtual;
    procedure UpdateActions; virtual;
    function ReadEntry(const ADn: string; const AAttrs: array of string;
      const ATag: string = ''): Int64;
    function Search(const AReq: TSearchRequest; const ATag: string = ''): Int64;
    function SubmitChange(AChange: TLdapChange; const ANote: string = '';
      const AAssertion: string = ''; const ATag: string = 'write'): Int64;
    procedure AttachOps(AOps: TConnectionOps; const ATag: string);
    procedure StampModel(AMsg: TUiMessage);
    function ReportWrite(AMsg: TWriteMsg): Boolean;
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
      ACaption: string; AWidth, AHeight: Integer);
  end;

resourcestring
  rsOpsSent = 'Sent, waiting for the server...';
  rsOpsDone = 'Done: %s';
  rsOpsFailed = 'Failed: %s';
  rsOpsUnknownOutcome = 'Outcome unknown: check the entry before trying again. %s';

implementation

constructor TOpsDialog.CreateFor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  ACaption: string; AWidth, AHeight: Integer);
var
  c: TDirectoryConnection;
begin
  inherited CreateDialog(AOwner, ACaption, AWidth, AHeight);
  InitTasks(ACtx, AProfileUuid);
  c := Conn;
  if c <> nil then SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
  MakeStatusBar;
  Tasks.OnMessage := @TaskMessage;
  Tasks.OnUntracked := @UntrackedMessage;
  Tasks.OnAfterMessage := @AfterTaskMessage;
end;

function TOpsDialog.AcceptsForeign(AMsg: TUiMessage): Boolean;
begin
  Result := False;
end;

procedure TOpsDialog.OnStale(AMsg: TUiMessage);
begin
  SetStatus(rsTdSessionLost, usWarning);
end;

procedure TOpsDialog.UpdateActions;
begin
end;

procedure TOpsDialog.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
begin
  if AEnding = teStale then
  begin
    OnStale(AMsg);
    Exit;
  end;
  if AMsg is TEntryMsg then OnEntry(TEntryMsg(AMsg))
  else if AMsg is TEntriesMsg then OnEntries(TEntriesMsg(AMsg))
  else if AMsg is TWriteMsg then OnWrite(TWriteMsg(AMsg))
  else if AMsg is TTaskFailedMsg then OnFailed(TTaskFailedMsg(AMsg))
  else OnOther(AMsg);
end;

procedure TOpsDialog.UntrackedMessage(AMsg: TUiMessage);
var
  c: TDirectoryConnection;
begin
  // Resultat d'une tache non declaree (annulee, oubliee, pas a nous): jamais livre. Une issue
  // d'ecriture reste soldee par le journal central.
  if (AMsg is TEntryMsg) or (AMsg is TEntriesMsg) or (AMsg is TWriteMsg) or
     (AMsg is TTaskFailedMsg) or (AMsg is TSchemaMsg) or (AMsg is TPasswordMsg) then Exit;
  c := FCtx.Connections.Find(FProfileUuid);
  if ((c <> nil) and c.Accepts(AMsg)) or AcceptsForeign(AMsg) then OnOther(AMsg);
end;

procedure TOpsDialog.AfterTaskMessage(Sender: TObject);
begin
  UpdateActions;
end;

procedure TOpsDialog.AttachOps(AOps: TConnectionOps; const ATag: string);
begin
  Tasks.Attach(AOps, ATag);
end;

procedure TOpsDialog.StampModel(AMsg: TUiMessage);
begin
  Tasks.StampModel(AMsg);
end;

procedure TOpsDialog.OnOther(AMsg: TUiMessage);
begin
end;

procedure TOpsDialog.OnEntry(AMsg: TEntryMsg);
begin
end;

procedure TOpsDialog.OnEntries(AMsg: TEntriesMsg);
begin
end;

procedure TOpsDialog.OnWrite(AMsg: TWriteMsg);
begin
  ReportWrite(AMsg);
end;

procedure TOpsDialog.OnFailed(AMsg: TTaskFailedMsg);
begin
  SetStatus(AMsg.Text, usError);
  FCtx.Log(mlError, Caption, AMsg.Text);
end;

function TOpsDialog.ReadEntry(const ADn: string; const AAttrs: array of string;
  const ATag: string): Int64;
begin
  Result := 0;
  if Conn = nil then
  begin
    SetStatus(rsTdNotConnected, usError);
    Exit;
  end;
  Result := Tasks.ReadEntry(ATag, ADn, AAttrs);
end;

function TOpsDialog.Search(const AReq: TSearchRequest; const ATag: string): Int64;
begin
  Result := 0;
  if Conn = nil then
  begin
    SetStatus(rsTdNotConnected, usError);
    Exit;
  end;
  Result := Tasks.Search(ATag, AReq);
end;

function TOpsDialog.SubmitChange(AChange: TLdapChange; const ANote: string;
  const AAssertion: string; const ATag: string): Int64;
var
  reason: string;
begin
  Result := SubmitWrite(Self, FCtx, Tasks, ATag, AChange, AAssertion, reason, ANote);
  if Result <> 0 then
    SetStatus(rsOpsSent)
  else if reason <> '' then
    SetStatus(reason, usError);
end;

function TOpsDialog.ReportWrite(AMsg: TWriteMsg): Boolean;
begin
  Result := AMsg.Result.Ok;
  if Result then
    SetStatus(Format(rsOpsDone, [AMsg.Change.Describe]), usOk)
  else if AMsg.Result.Error.Category = lecUnknownOutcome then
    // Issue inconnue: aucun renvoi automatique. Rejouer une ecriture a l'aveugle, c'est parier sur
    // l'etat du serveur avec l'argent de quelqu'un d'autre.
    SetStatus(Format(rsOpsUnknownOutcome, [AMsg.Change.Describe]), usError)
  else
    SetStatus(Format(rsOpsFailed, [ErrorToText(AMsg.Result.Error) + ' ' +
      AMsg.Result.Error.Action]), usError);
end;

end.
