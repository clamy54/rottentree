// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTransferDialog;

{$mode objfpc}{$H+}

// Cloner une entree, copier une branche ou la deplacer vers un autre serveur. Rien n'est ecrit
// avant confirmation. Un deplacement est copie, verification puis suppression: si la copie
// echoue ou differe, la source reste. Perdre une branche en transit, c'est une seule fois.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, Dialogs, uAppContext, uRtCheck, uRtCombo,
  uUiKit, uOpsDialog, uConnections, uDirectoryWorker, uDirectoryOps, uBranchTransfer, uUiInbox;

type
  TTransferMode = (tmClone, tmCopyBranch, tmMoveToServer);

  // Le plan est epingle aux sessions lues par l'apercu: connexion fermee, remplacee ou schema
  // relu, et il faut un nouvel apercu. Un transfert en cours s'arrete net sans rien envoyer de plus.
  TTransferDialog = class(TOpsDialog)
  private
    FMode: TTransferMode;
    FSourceDn: string;
    FTargets: TStringList;
    FTargetCombo: TRtComboBox;
    FParent, FRdn: TEdit;
    FRewrite: TRtCheckBox;
    FPreviewMemo: TMemo;
    FExecute: TButton;
    FSourceOps, FTargetOps: TConnectionOps;
    FTransfer: TBranchTransfer;
    FTargetUuid: string;
    FWrote: Boolean;
    FOnDone: TNotifyEvent;
    procedure BuildUi;
    function TargetConn: TDirectoryConnection;
    function PlanSessionsKept: Boolean;
    procedure PreviewClick(Sender: TObject);
    procedure SettingChanged(Sender: TObject);
    procedure DropPreview(const AStatus: string; AState: TUiState);
    procedure ExecuteClick(Sender: TObject);
    procedure ShowPlan;
    procedure Report(AOutcome: TTransferOutcome);
    procedure CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
  protected
    function AllowCloseDuringWrite: Boolean; override;
    function AcceptsForeign(AMsg: TUiMessage): Boolean; override;
    procedure OnEntry(AMsg: TEntryMsg); override;
    procedure OnEntries(AMsg: TEntriesMsg); override;
    procedure OnWrite(AMsg: TWriteMsg); override;
    procedure OnFailed(AMsg: TTaskFailedMsg); override;
    procedure OnStale(AMsg: TUiMessage); override;
  public
    constructor CreateTransfer(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
      ASourceDn: string; AMode: TTransferMode; AOnDone: TNotifyEvent);
    destructor Destroy; override;
    procedure SetDestination(const AProfileUuid, AParentDn, ARdn: string);
    procedure Preview;
    procedure Execute;
    function ExecuteEnabled: Boolean;
    function StatusText: string;
    function PlanText: string;
    property Transfer: TBranchTransfer read FTransfer;
  end;

procedure ShowTransferDialog(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  ASourceDn: string; AMode: TTransferMode; AOnDone: TNotifyEvent);

implementation

uses
  uLdapEntry, uLdapDn, uChangeSet, uClonePlan, uLdapErrors, uChangePreview, uStrings,
  uDirectoryService, uRtMessage, uTaskDialog;

resourcestring
  rsTrClone = 'Clone entry';
  rsTrCopy = 'Copy subtree';
  rsTrMove = 'Move subtree to another server';
  rsTrSource = 'Source: %s (%s)';
  rsTrTargetProfile = 'Destination (connected profile)';
  rsTrParent = 'Destination parent DN';
  rsTrRdn = 'New RDN';
  rsTrRewrite = 'Rewrite DN references that point inside the copied subtree';
  rsTrPreview = 'Preview';
  rsTrExecuteCopy = 'Copy...';
  rsTrExecuteMove = 'Move...';
  rsTrMoveNote = 'Moving between servers copies every entry, reads each copy back and compares it, ' +
    'then deletes the source from the leaves to the root. If a copy fails or differs, nothing is deleted.';
  rsTrNoTarget = 'Connect the destination profile first.';
  rsTrBadDn = 'Invalid DN: %s';
  rsTrReading = 'Reading the source...';
  rsTrPlan = '%d entr(ies) to create on %s.';
  rsTrMapping = 'New DNs:';
  rsTrMoreMappings = '... and %d more';
  rsTrExcluded = 'Not copied:';
  rsTrReview = 'Usually unique values to review (copied as is): %s';
  rsTrInternal = 'DN references inside the subtree: %d (%s)';
  rsTrInternalRewritten = 'rewritten to the copy';
  rsTrInternalKept = 'kept pointing to the source';
  rsTrExternal = 'DN references outside the subtree, left unchanged: %d';
  rsTrRunning = 'Copying %d / %d...';
  rsTrVerifying = 'Verifying the copies...';
  rsTrDeleting = 'Deleting the source...';
  rsTrFinishedCopy = '%d entr(ies) created and verified.';
  rsTrFinishedMove = '%d entr(ies) created and verified on the destination; %d deleted from the source.';
  rsTrStopped = 'Stopped: %s. Created: %d, deleted from source: %d, not attempted: %d.';
  rsTrMismatch = 'Differences after copy (source not deleted): %s';
  rsTrCancelRunning = 'The operation is running. Stop after the current write?';
  rsTrMoveConfirmNote = 'Then %d source entr(ies) will be deleted from %s, leaves first, only if every copy is verified.';
  rsTrOutdated = 'Settings changed: preview again before executing.';
  rsTrNestWarning = 'Warning: the destination DN is equal to or inside the copied branch. ' +
    'If both profiles actually point to the same directory, the copy would nest inside the source branch.';
  rsTrPreviewAgain = 'A connection or its schema changed since the preview: preview again.';
  rsTrUnknownOutcome = 'Outcome unknown for %s: the request was sent but its answer was lost. ' +
    'Check this entry before trying again.';
  rsTrNoDeleteAssertion = 'The source server does not announce the Assertion control (or no version marker was read): ' +
    'the source entries will be deleted without a concurrent-change guard.';

procedure ShowTransferDialog(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  ASourceDn: string; AMode: TTransferMode; AOnDone: TNotifyEvent);
var
  d: TTransferDialog;
begin
  d := TTransferDialog.CreateTransfer(AOwner, ACtx, AProfileUuid, ASourceDn, AMode, AOnDone);
  try
    d.ShowModal;
  finally
    d.Free;
  end;
end;

function ModeTitle(AMode: TTransferMode): string;
begin
  case AMode of
    tmClone: Result := rsTrClone;
    tmCopyBranch: Result := rsTrCopy;
  else
    Result := rsTrMove;
  end;
end;

constructor TTransferDialog.CreateTransfer(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, ASourceDn: string; AMode: TTransferMode; AOnDone: TNotifyEvent);
begin
  inherited CreateFor(AOwner, ACtx, AProfileUuid, ModeTitle(AMode) + ' - ' + ASourceDn, 900, 700);
  SetIcon('arrows-move');
  FMode := AMode;
  FSourceDn := ASourceDn;
  FOnDone := AOnDone;
  FTargets := TStringList.Create;
  OnCloseQuery := @CloseQueryHandler;
  BuildUi;
  ApplyTheme;
end;

destructor TTransferDialog.Destroy;
begin
  FTransfer.Free;
  FSourceOps.Free;
  FTargetOps.Free;
  FTargets.Free;
  inherited Destroy;
end;

procedure TTransferDialog.BuildUi;
var
  row: TPanel;
  i: Integer;
  c, src: TDirectoryConnection;
  d: TLdapDn;
begin
  src := Conn;
  if src <> nil then
    MakeLabel(Body, Format(rsTrSource, [FSourceDn, src.Profile.Name]));
  row := MakeFieldRow(Body, rsTrTargetProfile, 200);
  FTargetCombo := TRtComboBox.Create(row);
  FTargetCombo.Parent := row;
  FTargetCombo.Align := alClient;
  FTargetCombo.Style := csDropDownList;
  FTargetCombo.BorderSpacing.Around := 3;
  for i := 0 to FCtx.Connections.Count - 1 do
  begin
    c := FCtx.Connections.Item(i);
    if not c.IsReady then Continue;
    // Deplacer sur le meme serveur, c'est un ModifyDN, pas ce dialogue.
    if (FMode = tmMoveToServer) and (c.Profile.Uuid = FProfileUuid) then Continue;
    FTargets.Add(c.Profile.Uuid);
    FTargetCombo.Items.Add(c.Profile.Name + ' - ' + c.Profile.DisplayEndpoint);
    if c.Profile.Uuid = FProfileUuid then FTargetCombo.ItemIndex := FTargetCombo.Items.Count - 1;
  end;
  if (FTargetCombo.ItemIndex < 0) and (FTargetCombo.Items.Count > 0) then
    FTargetCombo.ItemIndex := 0;
  row := MakeFieldRow(Body, rsTrParent, 200);
  FParent := TEdit.Create(row);
  FParent.Parent := row;
  FParent.Align := alClient;
  FParent.BorderSpacing.Around := 3;
  row := MakeFieldRow(Body, rsTrRdn, 200);
  FRdn := TEdit.Create(row);
  FRdn.Parent := row;
  FRdn.Align := alClient;
  FRdn.BorderSpacing.Around := 3;
  if DnTryParse(FSourceDn, d) and (DnRdnCount(d) > 0) then
  begin
    FParent.Text := DnToString(DnParent(d));
    FRdn.Text := RdnToString(DnLeaf(d));
  end;
  FRewrite := MakeCheck(Body, rsTrRewrite);
  FRewrite.Visible := FMode <> tmClone;
  if FMode = tmMoveToServer then
    MakeLabel(Body, rsTrMoveNote).WordWrap := True;
  FPreviewMemo := MakeMemo(Body);
  FPreviewMemo.ReadOnly := True;
  AddButton(rsClose, mrClose, False, True);
  if FMode = tmMoveToServer then
    FExecute := AddButton(rsTrExecuteMove, mrNone)
  else
    FExecute := AddButton(rsTrExecuteCopy, mrNone);
  FExecute.OnClick := @ExecuteClick;
  FExecute.Enabled := False;
  AddButton(rsTrPreview, mrNone, True).OnClick := @PreviewClick;
  FTargetCombo.OnChange := @SettingChanged;
  FParent.OnChange := @SettingChanged;
  FRdn.OnChange := @SettingChanged;
  FRewrite.OnChange := @SettingChanged;
end;

function TTransferDialog.TargetConn: TDirectoryConnection;
begin
  Result := nil;
  if FTargetUuid = '' then Exit;
  Result := FCtx.Connections.Find(FTargetUuid);
  if (Result <> nil) and not Result.IsReady then Result := nil;
end;

function TTransferDialog.AllowCloseDuringWrite: Boolean;
begin
  Result := True;
end;

function TTransferDialog.PlanSessionsKept: Boolean;
begin
  Result := (FSourceOps <> nil) and (FTargetOps <> nil) and FSourceOps.SessionCurrent and
    FTargetOps.SessionCurrent;
end;

function TTransferDialog.AcceptsForeign(AMsg: TUiMessage): Boolean;
var
  t: TDirectoryConnection;
begin
  t := TargetConn;
  Result := (t <> nil) and t.Accepts(AMsg);
end;

procedure TTransferDialog.PreviewClick(Sender: TObject);
var
  src, dst: TDirectoryConnection;
  parentDn, rdn: TLdapDn;
  targetDn: string;
  opts: TCloneOptions;
begin
  if (FTransfer <> nil) and FTransfer.Active and (FTransfer.State <> tsAwaitingConfirm) then Exit;
  FExecute.Enabled := False;
  src := Conn;
  if (src = nil) or (FTargetCombo.ItemIndex < 0) then
  begin
    SetStatus(rsTrNoTarget, usError);
    Exit;
  end;
  FTargetUuid := FTargets[FTargetCombo.ItemIndex];
  dst := TargetConn;
  if dst = nil then
  begin
    SetStatus(rsTrNoTarget, usError);
    Exit;
  end;
  if not DnTryParse(Trim(FParent.Text), parentDn) then
  begin
    SetStatus(Format(rsTrBadDn, [FParent.Text]), usError);
    Exit;
  end;
  if not DnTryParse(Trim(FRdn.Text), rdn) or (DnRdnCount(rdn) <> 1) then
  begin
    SetStatus(Format(rsTrBadDn, [FRdn.Text]), usError);
    Exit;
  end;
  targetDn := DnToString(DnConcat(rdn, parentDn));
  FreeAndNil(FTransfer);
  FreeAndNil(FSourceOps);
  FreeAndNil(FTargetOps);
  FSourceOps := TConnectionOps.Create(FCtx.Connections, FProfileUuid, Self);
  FTargetOps := TConnectionOps.Create(FCtx.Connections, FTargetUuid, Self);
  AttachOps(FSourceOps, 'transfer');
  AttachOps(FTargetOps, 'transfer');
  // Le plan sera execute dans ces sessions-ci et pas d'autres: une reconnexion
  // n'est jamais suivie en silence au milieu d'un transfert.
  if not (FSourceOps.Pin and FTargetOps.Pin) then
  begin
    SetStatus(rsTrNoTarget, usError);
    Exit;
  end;
  FTransfer := TBranchTransfer.Create(FSourceOps, FTargetOps, src.Profile.PageSize);
  opts := DefaultCloneOptions;
  opts.Schema := dst.Schema;
  opts.Sensitive := FCtx.Sensitive;
  FPreviewMemo.Clear;
  // Deux profils distincts peuvent viser le meme serveur (alias DNS, repartiteur). Le
  // transfert prouve l'identite des deux bouts avant toute suppression: s'effacer soi-meme, non.
  if FTransfer.Start(FSourceDn, targetDn, FMode = tmMoveToServer, FRewrite.Checked, opts,
      FMode = tmClone, FTargetUuid = FProfileUuid,
      ServerSupportsControl(src.RootDse, LDAP_CONTROL_ASSERTION_OID)) then
    SetStatus(rsTrReading)
  else
    SetStatus(ErrorToText(FTransfer.LastError), usError);
end;

procedure TTransferDialog.SettingChanged(Sender: TObject);
begin
  // Les champs ne collent plus au plan previsualise: execution bloquee jusqu'au
  // prochain apercu, et l'apercu en cours part a la poubelle, il visait autre chose.
  if FExecute <> nil then FExecute.Enabled := False;
  if (FTransfer <> nil) and (FTransfer.State in [tsReading, tsAwaitingConfirm]) then
    DropPreview(rsTrOutdated, usMuted);
end;

procedure TTransferDialog.DropPreview(const AStatus: string; AState: TUiState);
begin
  FTransfer.Cancel;
  FExecute.Enabled := False;
  FPreviewMemo.Clear;
  SetStatus(AStatus, AState);
end;

procedure TTransferDialog.ShowPlan;
const
  MAX_LINES = 200;
var
  p: TBranchCopyPlan;
  i, internal, external: Integer;
  lines: TStringList;
  dst: TDirectoryConnection;
  how: string;
begin
  p := FTransfer.Plan;
  dst := TargetConn;
  lines := TStringList.Create;
  try
    if dst <> nil then
      lines.Add(Format(rsTrPlan, [p.Count, dst.Profile.DisplayEndpoint]));
    lines.Add('');
    lines.Add(rsTrMapping);
    for i := 0 to p.Count - 1 do
    begin
      if i >= MAX_LINES then
      begin
        lines.Add(Format(rsTrMoreMappings, [p.Count - MAX_LINES]));
        Break;
      end;
      lines.Add('  ' + p.SourceDns[i] + '  ->  ' + p.Targets[i].Dn);
    end;
    if Length(p.Excluded) > 0 then
    begin
      lines.Add('');
      lines.Add(rsTrExcluded);
      for i := 0 to High(p.Excluded) do
        lines.Add('  ' + p.Excluded[i].Attr + ': ' + CloneReasonText(p.Excluded[i].Reason));
    end;
    if p.Review.Count > 0 then
    begin
      lines.Add('');
      lines.Add(Format(rsTrReview, [p.Review.CommaText]));
    end;
    internal := 0;
    external := 0;
    for i := 0 to High(p.Refs) do
      if p.Refs[i].Kind = brkInternal then Inc(internal) else Inc(external);
    // Etat du plan fige au Start, pas la case actuelle, qui a pu bouger depuis l'apercu.
    if FTransfer.Rewrite then how := rsTrInternalRewritten else how := rsTrInternalKept;
    lines.Add('');
    lines.Add(Format(rsTrInternal, [internal, how]));
    lines.Add(Format(rsTrExternal, [external]));
    if (not FTransfer.Move) and FTransfer.BasesOverlap then
    begin
      lines.Add('');
      lines.Add(rsTrNestWarning);
    end;
    FPreviewMemo.Lines.Assign(lines);
  finally
    lines.Free;
  end;
  FExecute.Enabled := p.Count > 0;
  SetStatus('');
end;

procedure TTransferDialog.ExecuteClick(Sender: TObject);
var
  changes: array of TLdapChange;
  i, n: Integer;
  p: TBranchCopyPlan;
  dst, src: TDirectoryConnection;
  note, reason: string;
  ok: Boolean;
begin
  if (FTransfer = nil) or (FTransfer.State <> tsAwaitingConfirm) then Exit;
  p := FTransfer.Plan;
  dst := TargetConn;
  src := Conn;
  if (dst = nil) or (src = nil) then
  begin
    SetStatus(rsTrNoTarget, usError);
    Exit;
  end;
  if not PlanSessionsKept then
  begin
    DropPreview(rsTrPreviewAgain, usError);
    Exit;
  end;
  changes := nil;
  SetLength(changes, p.Count);
  n := 0;
  try
    for i := 0 to p.Count - 1 do
    begin
      changes[n] := TLdapChange.Create;
      changes[n].Kind := ckAdd;
      changes[n].Dn := p.Targets[i].Dn;
      changes[n].Entry := p.Targets[i].Clone;
      Inc(n);
    end;
    note := '';
    if FMode = tmMoveToServer then
    begin
      note := Format(rsTrMoveConfirmNote, [p.Count, src.Profile.DisplayEndpoint]);
      // Pas de controle Assertion pour la suppression: on le dit avant de confirmer, pas apres.
      if FTransfer.DeletesWithoutAssertion then
        note := note + LineEnding + rsTrNoDeleteAssertion;
    end;
    // Destination et source doivent etre retrouvees inchangees apres la confirmation,
    // sinon rien ne part.
    ok := ConfirmChangesOn(Self, FCtx.Connections, dst, changes, FCtx.Sensitive, reason, note);
    if ok and not PlanSessionsKept then
    begin
      ok := False;
      reason := rsPreviewSessionChanged;
    end;
  finally
    for i := 0 to n - 1 do
      changes[i].Free;
  end;
  if not ok then
  begin
    if reason <> '' then SetStatus(reason, usError);
    Exit;
  end;
  FExecute.Enabled := False;
  Report(FTransfer.Confirm);
end;

procedure TTransferDialog.Report(AOutcome: TTransferOutcome);
begin
  case AOutcome of
    toCopying:
      SetStatus(Format(rsTrRunning, [FTransfer.Created.Count + 1, FTransfer.Plan.Count]));
    toVerifying: SetStatus(rsTrVerifying);
    toDeleting: SetStatus(rsTrDeleting);
    toConfirmNeeded: ShowPlan;
    toIncomplete, toPlanFailed:
      SetStatus(ErrorToText(FTransfer.LastError), usError);
    toFinished:
      begin
        FWrote := True;
        if FTransfer.Move then
          SetStatus(Format(rsTrFinishedMove, [FTransfer.Created.Count, FTransfer.Deleted]), usOk)
        else
          SetStatus(Format(rsTrFinishedCopy, [FTransfer.Created.Count]), usOk);
        FCtx.Log(mlInfo, Caption, FStatus.Caption);
        if Assigned(FOnDone) then FOnDone(Self);
      end;
    toStopped:
      begin
        // Une ecriture d'issue inconnue a peut-etre abouti: les vues relisent, au cas ou.
        if (FTransfer.Created.Count > 0) or (FTransfer.Deleted > 0) or
           (FTransfer.UnknownOutcome <> '') then
          FWrote := True;
        SetStatus(Format(rsTrStopped, [ErrorToText(FTransfer.LastError),
          FTransfer.Created.Count, FTransfer.Deleted, FTransfer.NotAttempted]), usError);
        if FTransfer.Mismatch.Count > 0 then
          FPreviewMemo.Lines.Add(Format(rsTrMismatch, [FTransfer.Mismatch.CommaText]));
        if FTransfer.UnknownOutcome <> '' then
          FPreviewMemo.Lines.Add(Format(rsTrUnknownOutcome, [FTransfer.UnknownOutcome]));
        FCtx.Log(mlError, Caption, FStatus.Caption);
        if FWrote and Assigned(FOnDone) then FOnDone(Self);
      end;
  end;
end;

procedure TTransferDialog.OnEntries(AMsg: TEntriesMsg);
begin
  if (FTransfer = nil) or not FTransfer.OwnsTask(AMsg.TaskId) then Exit;
  Report(FTransfer.HandleEntries(AMsg));
end;

procedure TTransferDialog.OnEntry(AMsg: TEntryMsg);
begin
  if (FTransfer = nil) or not FTransfer.OwnsTask(AMsg.TaskId) then Exit;
  Report(FTransfer.HandleEntry(AMsg));
end;

procedure TTransferDialog.OnWrite(AMsg: TWriteMsg);
begin
  if (FTransfer = nil) or not FTransfer.OwnsTask(AMsg.TaskId) then Exit;
  Report(FTransfer.HandleWrite(AMsg));
end;

procedure TTransferDialog.OnFailed(AMsg: TTaskFailedMsg);
begin
  inherited OnFailed(AMsg);
  // La mort du fil ne dit rien de l'ecriture en vol: issue inconnue, et on l'avoue.
  if (FTransfer <> nil) and FTransfer.OwnsTask(AMsg.TaskId) then
    Report(FTransfer.TaskLost(MakeError(lecOther, 0, 'transfer', AMsg.Text)));
end;

procedure TTransferDialog.OnStale(AMsg: TUiMessage);
begin
  // Reponse d'une session fermee ou remplacee: une ecriture y est d'issue inconnue.
  // Le moteur s'arrete, pas d'etape suivante, et le dialogue redevient utilisable.
  inherited OnStale(AMsg);
  if (FTransfer <> nil) and FTransfer.OwnsTask(AMsg.TaskId) then
    Report(FTransfer.TaskLost(MakeError(lecOther, 0, 'transfer', rsTdSessionLost)));
end;

procedure TTransferDialog.SetDestination(const AProfileUuid, AParentDn, ARdn: string);
begin
  FTargetCombo.ItemIndex := FTargets.IndexOf(AProfileUuid);
  FParent.Text := AParentDn;
  FRdn.Text := ARdn;
end;

procedure TTransferDialog.Preview;
begin
  PreviewClick(nil);
end;

procedure TTransferDialog.Execute;
begin
  ExecuteClick(nil);
end;

function TTransferDialog.ExecuteEnabled: Boolean;
begin
  Result := FExecute.Enabled;
end;

function TTransferDialog.StatusText: string;
begin
  Result := FStatus.Caption;
end;

function TTransferDialog.PlanText: string;
begin
  Result := FPreviewMemo.Lines.Text;
end;

procedure TTransferDialog.CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
begin
  if (FTransfer = nil) or not (FTransfer.State in [tsCopying, tsVerifying, tsDeleting]) then Exit;
  CanClose := RtMessageDlg(Caption, rsTrCancelRunning, mtConfirmation, [mbYes, mbNo], 0) = mrYes;
  // Ce qui est deja parti n'est pas annulable; seules les ecritures suivantes sont evitees.
  if CanClose then FTransfer.Cancel;
end;

end.
