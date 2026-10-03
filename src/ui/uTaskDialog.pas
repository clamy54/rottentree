// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTaskDialog;

{$mode objfpc}{$H+}

// Ce que partage toute vue qui ecrit dans l'annuaire, pour qu'aucune ne le reinvente: gardes
// d'ecriture, apercu confirme sur la session de la vue, dialogue qui tient le registre de ses taches.
// La fermeture attend l'issue d'une ecriture partie: une requete envoyee ne se rattrape pas.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, uUiKit, uAppContext, uConnections, uChangeSet,
  uLdapErrors, uSearchModel, uDirectoryService, uTaskTracker;

resourcestring
  rsTdNotConnected = 'Not connected.';
  rsTdReadOnly = 'This profile is read-only: nothing is sent.';
  rsTdModelStale = 'What is shown was read on a connection that has changed since: read it again ' +
    'before changing anything.';
  rsTdWaitingClose = 'Waiting for the server: the outcome will be shown here before this window can close.';
  rsTdSessionLost = 'The connection changed while this operation was in progress: its outcome is ' +
    'unknown. Read the entry again before trying again.';
  rsTdReadSessionLost = 'The connection changed during the reading: read it again.';
  rsTdServerConfigNote = 'This changes the configuration of the server itself: it applies immediately ' +
    'and a wrong value can make the server unusable.';

type
  TTaskDialog = class(TRtDialog)
  private
    FTasks: TDirectoryTasks;
    procedure WriteSettled(AKind: TOrphanWriteKind; const AText: string);
  protected
    FCtx: TAppContext;
    FProfileUuid: string;
    FStatus: TLabel;
    procedure InitTasks(ACtx: TAppContext; const AProfileUuid: string);
    procedure MakeStatusBar;
    function Conn: TDirectoryConnection;
    procedure SetStatus(const AText: string; AState: TUiState = usMuted); virtual;
    // Fermer pendant une ecriture partie est refuse par defaut: son bilan doit etre montre a quelqu'un.
    function AllowCloseDuringWrite: Boolean; virtual;
    function HasRunningWork: Boolean; virtual;
  public
    destructor Destroy; override;
    function CloseQuery: Boolean; override;
    property Tasks: TDirectoryTasks read FTasks;
    property ProfileUuid: string read FProfileUuid;
  end;

function ConfirmWrite(AOwner: TComponent; ACtx: TAppContext; ATasks: TDirectoryTasks;
  const AChanges: array of TLdapChange; out AReason: string; const ANote: string = ''): Boolean;
function SubmitWrite(AOwner: TComponent; ACtx: TAppContext; ATasks: TDirectoryTasks;
  const ATag: string; AChange: TLdapChange; const AAssertion: string; out AReason: string;
  const ANote: string = ''): Int64; overload;
function SubmitWrite(AOwner: TComponent; ACtx: TAppContext; ATasks: TDirectoryTasks;
  const ATag: string; AChange: TLdapChange; const AAssertion: string;
  const AControls: TRequestControlArray; const ARereadAttrs: array of string; out AReason: string;
  const ANote: string = ''): Int64; overload;

implementation

uses
  Graphics, uChangePreview;

function ModelUsable(ATasks: TDirectoryTasks): Boolean;
begin
  // Modele d'une autre session (reconnexion) ou perime par une ecriture: jamais une base d'ecriture.
  Result := not ATasks.Tracker.ModelRequired or ATasks.ModelCurrent;
end;

// Une operation qui touche la configuration du serveur (cn=config, cn=monitor...) est signalee
// dans l'apercu. Reconfigurer un annuaire par megarde, c'est un post-mortem tout trouve.
function WriteNote(AConn: TDirectoryConnection; const AChanges: array of TLdapChange;
  const ANote: string): string;
var
  roots: TStringArray;
  i: Integer;
begin
  Result := ANote;
  roots := KnownServerConfigRoots(AConn);
  if Length(roots) = 0 then Exit;
  for i := 0 to High(AChanges) do
    if DnUnderAny(AChanges[i].Dn, roots) or
       (AChanges[i].HasNewSuperior and DnUnderAny(AChanges[i].NewSuperior, roots)) then
    begin
      if Result = '' then Result := rsTdServerConfigNote
      else Result := rsTdServerConfigNote + LineEnding + Result;
      Exit;
    end;
end;

function ConfirmWrite(AOwner: TComponent; ACtx: TAppContext; ATasks: TDirectoryTasks;
  const AChanges: array of TLdapChange; out AReason: string; const ANote: string): Boolean;
var
  c: TDirectoryConnection;
  readOnly: Boolean;
begin
  Result := False;
  AReason := '';
  c := nil;
  if ATasks <> nil then c := ATasks.Conn;
  if c = nil then
  begin
    AReason := rsTdNotConnected;
    Exit;
  end;
  if not ModelUsable(ATasks) then
  begin
    AReason := rsTdModelStale;
    Exit;
  end;
  // Apercu affiche meme en lecture seule, Apply grise. L'etat est lu avant la boucle modale: apres
  // une annulation, la connexion a pu fermer entre-temps.
  readOnly := c.Profile.ReadOnly;
  if not ConfirmChangesOn(AOwner, ACtx.Connections, c, AChanges, ACtx.Sensitive, AReason,
      WriteNote(c, AChanges, ANote)) then
  begin
    if (AReason = '') and readOnly then AReason := rsTdReadOnly;
    Exit;
  end;
  // La boucle modale a pu livrer une ecriture qui a perime le modele: on reverifie.
  if not ModelUsable(ATasks) then
  begin
    AReason := rsTdModelStale;
    Exit;
  end;
  Result := True;
end;

function SubmitWrite(AOwner: TComponent; ACtx: TAppContext; ATasks: TDirectoryTasks;
  const ATag: string; AChange: TLdapChange; const AAssertion: string; out AReason: string;
  const ANote: string): Int64;
begin
  Result := SubmitWrite(AOwner, ACtx, ATasks, ATag, AChange, AAssertion, nil, [], AReason, ANote);
end;

function SubmitWrite(AOwner: TComponent; ACtx: TAppContext; ATasks: TDirectoryTasks;
  const ATag: string; AChange: TLdapChange; const AAssertion: string;
  const AControls: TRequestControlArray; const ARereadAttrs: array of string; out AReason: string;
  const ANote: string): Int64;
var
  err: TLdapError;
begin
  Result := 0;
  if not ConfirmWrite(AOwner, ACtx, ATasks, [AChange], AReason, ANote) then
  begin
    AChange.Free;
    Exit;
  end;
  // Write prend possession du changement, meme quand il refuse.
  Result := ATasks.Write(ATag, AChange, AAssertion, AControls, ARereadAttrs, err);
  if Result = 0 then AReason := ErrorToText(err);
end;

procedure TTaskDialog.InitTasks(ACtx: TAppContext; const AProfileUuid: string);
begin
  FCtx := ACtx;
  FProfileUuid := AProfileUuid;
  FTasks := TDirectoryTasks.Create(FCtx.Connections, FProfileUuid, Self);
  FTasks.OnWriteSettled := @WriteSettled;
end;

destructor TTaskDialog.Destroy;
begin
  // Reponses tardives jamais livrees a un dialogue ferme; une issue d'ecriture finit quand meme au
  // journal par le puits des orphelins.
  FreeAndNil(FTasks);
  inherited Destroy;
end;

procedure TTaskDialog.MakeStatusBar;
begin
  FStatus := MakeLabel(ButtonBar, '', alClient);
  FStatus.Layout := tlCenter;
  FStatus.WordWrap := True;
  FStatus.BorderSpacing.Left := 8;
end;

function TTaskDialog.Conn: TDirectoryConnection;
begin
  Result := nil;
  if FTasks <> nil then Result := FTasks.Conn;
end;

procedure TTaskDialog.SetStatus(const AText: string; AState: TUiState);
begin
  if FStatus = nil then Exit;
  FStatus.Caption := AText;
  FStatus.Font.Color := DialogStateColor(AState);
end;

procedure TTaskDialog.WriteSettled(AKind: TOrphanWriteKind; const AText: string);
begin
  FCtx.LogWriteOutcome(AKind, Caption, AText);
end;

function TTaskDialog.AllowCloseDuringWrite: Boolean;
begin
  Result := False;
end;

function TTaskDialog.HasRunningWork: Boolean;
begin
  Result := False;
end;

function TTaskDialog.CloseQuery: Boolean;
begin
  // Avant OnCloseQuery: une ecriture en vol passe avant toute autre question.
  if ((FTasks <> nil) and FTasks.WritesInFlight and not AllowCloseDuringWrite) or HasRunningWork then
  begin
    SetStatus(rsTdWaitingClose, usWarning);
    Exit(False);
  end;
  Result := inherited CloseQuery;
end;

end.
