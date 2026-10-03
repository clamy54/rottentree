// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSubtreeProgress;

{$mode objfpc}{$H+}

// Suivi d'une suppression de sous-arbre: enumeration, confirmation, controle, puis les feuilles d'abord.
// Stop pendant l'enumeration: rien n'est touche. Stop pendant les suppressions: celle qui est partie
// rend son issue, les suivantes restent a quai. Le bilan reste affiche, il faudra bien l'expliquer.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, ComCtrls, Forms, Graphics,
  uUiKit, uSubtreeDeletion;

type
  TSubtreeProgressDialog = class(TRtDialog)
  private
    FPhase, FDetail, FCurrent: TLabel;
    FBar: TProgressBar;
    FStop, FClose: TButton;
    FRunning: Boolean;
    FOnStop: TNotifyEvent;
    procedure StopClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
  public
    constructor CreateProgress(AOwner: TComponent; const ABaseDn, AServer, ABadge: string);
    procedure UpdateFrom(ASubtree: TSubtreeDeletion);
    procedure Finish(const ASummary: string; AState: TUiState);
    function PhaseText: string;
    function DetailText: string;
    function StopEnabled: Boolean;
    property Running: Boolean read FRunning;
    property OnStop: TNotifyEvent read FOnStop write FOnStop;
    procedure PressStop;
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
  rsSpStop = 'Stop';
  rsSpClose = 'Close';
  rsSpDone = 'Finished.';
  rsSpStopped = 'Stopped.';

implementation

uses
  uTheme;

constructor TSubtreeProgressDialog.CreateProgress(AOwner: TComponent; const ABaseDn, AServer,
  ABadge: string);
var
  lbl: TLabel;
begin
  inherited CreateDialog(AOwner, rsSpTitle, 640, 250);
  SetIcon('trash');
  SetTarget(AServer, ABadge);
  lbl := MakeLabel(Body, Format(rsSpBase, [ABaseDn]));
  lbl.ShowAccelChar := False;
  FPhase := MakeLabel(Body, rsSpEnumerating);
  FPhase.WordWrap := True;
  FBar := TProgressBar.Create(Body);
  FBar.Parent := Body;
  FBar.Align := alTop;
  FBar.Height := 18;
  FBar.BorderSpacing.Around := 6;
  FBar.Min := 0;
  FBar.Max := 1;
  FDetail := MakeLabel(Body, '');
  FDetail.WordWrap := True;
  FCurrent := MakeLabel(Body, '');
  FCurrent.ShowAccelChar := False;
  FCurrent.WordWrap := True;
  FStop := AddButton(rsSpStop, mrNone);
  FStop.OnClick := @StopClick;
  FClose := AddButton(rsSpClose, mrNone);
  FClose.OnClick := @CloseClick;
  FClose.Enabled := False;
  OnCloseQuery := @CloseQueryHandler;
  FRunning := True;
  ApplyTheme;
end;

procedure TSubtreeProgressDialog.UpdateFrom(ASubtree: TSubtreeDeletion);
var
  total: Integer;
begin
  total := ASubtree.Targets.Count;
  FCurrent.Caption := '';
  case ASubtree.State of
    sdsEnumerating:
      begin
        FPhase.Caption := rsSpEnumerating;
        FDetail.Caption := Format(rsSpFound, [ASubtree.Found]);
        FBar.Style := pbstMarquee;
      end;
    sdsAwaitingConfirm:
      begin
        FPhase.Caption := Format(rsSpAwaiting, [total]);
        FDetail.Caption := '';
        FBar.Style := pbstNormal;
        FBar.Max := 1;
        FBar.Position := 0;
      end;
    sdsAwaitingUnprotected:
      begin
        FPhase.Caption := Format(rsSpAwaitingUnprotected, [ASubtree.PendingUnprotected]);
        FDetail.Caption := '';
        FBar.Style := pbstNormal;
        if total > 0 then FBar.Max := total;
        FBar.Position := 0;
      end;
    sdsVerifying:
      begin
        FPhase.Caption := rsSpVerifying;
        FDetail.Caption := Format(rsSpVerifyFound, [ASubtree.Found, total]);
        FBar.Style := pbstNormal;
        if total > 0 then FBar.Max := total;
        FBar.Position := ASubtree.Found;
      end;
    sdsDeleting:
      begin
        if ASubtree.StopRequested then
          FPhase.Caption := rsSpStopping
        else
          FPhase.Caption := Format(rsSpDeleting, [ASubtree.Deleted, total]);
        FDetail.Caption := Format(rsSpRemaining, [ASubtree.Remaining]);
        FBar.Style := pbstNormal;
        if total > 0 then FBar.Max := total;
        FBar.Position := ASubtree.Deleted;
        if ASubtree.CurrentDn <> '' then
          FCurrent.Caption := Format(rsSpCurrent, [ASubtree.CurrentDn]);
      end;
    sdsFinished, sdsStopped:
      begin
        FBar.Style := pbstNormal;
        if total > 0 then FBar.Max := total;
        FBar.Position := ASubtree.Deleted;
      end;
  end;
  FStop.Enabled := FRunning and not ASubtree.StopRequested;
end;

procedure TSubtreeProgressDialog.Finish(const ASummary: string; AState: TUiState);
begin
  FRunning := False;
  FBar.Style := pbstNormal;
  if AState = usOk then
  begin
    FPhase.Caption := rsSpDone;
    FBar.Position := FBar.Max;
  end
  else
    FPhase.Caption := rsSpStopped;
  FDetail.Caption := ASummary;
  FDetail.Font.Color := DialogStateColor(AState);
  FCurrent.Caption := '';
  FStop.Enabled := False;
  FClose.Enabled := True;
  if Showing and FClose.CanFocus then FClose.SetFocus;
end;

procedure TSubtreeProgressDialog.StopClick(Sender: TObject);
begin
  PressStop;
end;

procedure TSubtreeProgressDialog.PressStop;
begin
  if not FRunning or not FStop.Enabled then Exit;
  FStop.Enabled := False;
  FPhase.Caption := rsSpStopping;
  if Assigned(FOnStop) then FOnStop(Self);
end;

procedure TSubtreeProgressDialog.CloseClick(Sender: TObject);
begin
  Close;
end;

procedure TSubtreeProgressDialog.CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
begin
  // Fermer en pleine suppression vaut Stop. La fenetre reste pour le bilan: on ne cache pas les corps.
  if FRunning then
  begin
    PressStop;
    CanClose := False;
  end
  else
    CanClose := True;
end;

function TSubtreeProgressDialog.PhaseText: string;
begin
  Result := FPhase.Caption;
end;

function TSubtreeProgressDialog.DetailText: string;
begin
  Result := FDetail.Caption;
end;

function TSubtreeProgressDialog.StopEnabled: Boolean;
begin
  Result := FStop.Enabled;
end;

end.
