// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSubtreeProgress;

{$mode objfpc}{$H+}

// Suivi d'une suppression de sous-arbre: enumeration, confirmation, controle, puis les feuilles d'abord.
// Stop pendant l'enumeration: rien n'est touche. Stop pendant les suppressions: celle qui est partie
// rend son issue, les suivantes restent a quai. Le bilan reste affiche, il faudra bien l'expliquer.

interface

uses
  Classes, SysUtils, uUiKit, uRtProgress, uSubtreeDeletion;

type
  TSubtreeProgressDialog = class(TRtProgressDialog)
  public
    constructor CreateProgress(AOwner: TComponent; const ABaseDn, AServer, ABadge: string);
    procedure UpdateFrom(ASubtree: TSubtreeDeletion);
    procedure Finish(const ASummary: string; AState: TUiState);
    function PhaseText: string;
  end;

resourcestring
  rsSpTitle = 'Delete subtree';
  rsSpBase = 'Subtree: %s';
  rsSpEnumerating = 'Listing the entries of the subtree...';
  rsSpFound = '%d entries found so far.';
  rsSpAwaiting = 'Waiting for your confirmation: %d entries.';
  rsSpAwaitingUnprotected = 'Waiting for your confirmation: %d entries have no version marker.';
  rsSpVerifying = 'Checking that the subtree did not change...';
  rsSpVerifyFound = '%d of %d entries listed again.';
  rsSpDeleting = 'Deleting, leaves first: %d of %d.';
  rsSpRemaining = '%d remaining.';
  rsSpStopping = 'Stopping after the deletion in progress...';
  rsSpCurrent = 'Current: %s';
  rsSpDone = 'Finished.';
  rsSpStopped = 'Stopped.';

implementation

constructor TSubtreeProgressDialog.CreateProgress(AOwner: TComponent; const ABaseDn, AServer,
  ABadge: string);
begin
  inherited CreateProgress(AOwner, rsSpTitle, Format(rsSpBase, [ABaseDn]));
  SetIcon('trash');
  SetTarget(AServer, ABadge);
  StatusText := rsSpEnumerating;
  StoppingText := rsSpStopping;
  ApplyTheme;
end;

procedure TSubtreeProgressDialog.UpdateFrom(ASubtree: TSubtreeDeletion);
var
  total: Integer;

  // Cibles encore inconnues: la jauge garde son echelle.
  procedure Bar(APosition: Integer);
  begin
    if total > 0 then SetProgress(APosition, total) else SetProgress(APosition, Gauge.Max);
  end;

begin
  total := ASubtree.Targets.Count;
  CurrentText := '';
  case ASubtree.State of
    sdsEnumerating:
      begin
        StatusText := rsSpEnumerating;
        DetailText := Format(rsSpFound, [ASubtree.Found]);
        SetIndeterminate;
      end;
    sdsAwaitingConfirm:
      begin
        StatusText := Format(rsSpAwaiting, [total]);
        DetailText := '';
        SetProgress(0, 1);
      end;
    sdsAwaitingUnprotected:
      begin
        StatusText := Format(rsSpAwaitingUnprotected, [ASubtree.PendingUnprotected]);
        DetailText := '';
        Bar(0);
      end;
    sdsVerifying:
      begin
        StatusText := rsSpVerifying;
        DetailText := Format(rsSpVerifyFound, [ASubtree.Found, total]);
        Bar(ASubtree.Found);
      end;
    sdsDeleting:
      begin
        if ASubtree.StopRequested then
          StatusText := rsSpStopping
        else
          StatusText := Format(rsSpDeleting, [ASubtree.Deleted, total]);
        DetailText := Format(rsSpRemaining, [ASubtree.Remaining]);
        Bar(ASubtree.Deleted);
        if ASubtree.CurrentDn <> '' then
          CurrentText := Format(rsSpCurrent, [ASubtree.CurrentDn]);
      end;
    sdsFinished, sdsStopped: Bar(ASubtree.Deleted);
  end;
  StopEnabled := not ASubtree.StopRequested;
end;

procedure TSubtreeProgressDialog.Finish(const ASummary: string; AState: TUiState);
begin
  if AState = usOk then
    inherited Finish(rsSpDone, ASummary, AState)
  else
    inherited Finish(rsSpStopped, ASummary, AState);
end;

function TSubtreeProgressDialog.PhaseText: string;
begin
  Result := StatusText;
end;

end.
