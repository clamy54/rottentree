// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAdProtection;

{$mode objfpc}{$H+}

// Protection contre la suppression accidentelle d'un objet Active Directory, comme la case de la console AD.
// Une seule operation pour l'assistant de creation d'OU et le dialogue de l'arbre: DACL relue, remplacee,
// relue encore et comparee au plan; le parent aussi si sa regle manque. Le detail des regles et la raison
// du remplacement vivent dans uAdSecurityDescriptor.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics,
  uUiKit, uAppContext, uRtCheck, uUiInbox, uConnections, uAdSecurityDescriptor, uTaskTracker,
  uTaskDialog, uDirectoryService;

type
  TProtectionOutcome = (poRunning, poOk, poWarning, poFailed);

  TProtectionJobStep = (pjIdle, pjReadObject, pjWriteObject, pjVerifyObject, pjReadParent,
    pjWriteParent, pjVerifyParent, pjDone);

  TDeletionProtectionJob = class
  private
    FCtx: TAppContext;
    FProfileUuid, FDn, FParentDn: string;
    FProtect: Boolean;
    FExpectedGuid, FExpectedSd: RawByteString;
    FCheckVersion: Boolean;
    FStep: TProtectionJobStep;
    FTasks: TDirectoryTasks;
    FPlanned: TAcl;
    FUnknown: Boolean;
    FOutcome: TProtectionOutcome;
    FReport: TStringList;
    FOnDone: TNotifyEvent;
    function GetTask: Int64;
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure WriteSettled(AKind: TOrphanWriteKind; const AText: string);
    procedure ReadSd(const ADn: string; AStep: TProtectionJobStep);
    procedure WriteDacl(const ADn: string; const ABase: TSecurityDescriptor; const ANewDacl: TAcl;
      AStep: TProtectionJobStep);
    procedure ObjectRead(AMsg: TUiMessage);
    procedure ParentRead(AMsg: TUiMessage);
    procedure Written(AMsg: TUiMessage);
    procedure Verified(AMsg: TUiMessage);
    procedure StartParent;
    procedure Note(const AText: string);
    procedure Finish(AOutcome: TProtectionOutcome);
  public
    constructor Create(ACtx: TAppContext; const AProfileUuid, ADn: string; AProtect: Boolean);
    destructor Destroy; override;
    // Identite et version sont deux controles distincts. AExpectedGuid est toujours exige: autre GUID ou GUID
    // illisible, rien n'est ecrit. ACheckVersion exige en plus que la DACL relue soit AExpectedSd, celle qui a
    // ete montree. La creation ne verifie que le GUID; le dialogue autonome, les deux.
    procedure Start(ACheckVersion: Boolean; const AExpectedGuid, AExpectedSd: RawByteString);
    function ReportText: string;
    property Outcome: TProtectionOutcome read FOutcome;
    property Step: TProtectionJobStep read FStep;
    property Task: Int64 read GetTask;
    property ParentDn: string read FParentDn;
    property OnDone: TNotifyEvent read FOnDone write FOnDone;
  end;

  TDeletionProtectionDialog = class(TTaskDialog)
  private
    FDn, FParentDn: string;
    FState: TLabel;
    FCheck: TRtCheckBox;
    FPlan: TMemo;
    FApply, FReload: TButton;
    FGuid, FSdBytes: RawByteString;
    FSd, FParentSd: TSecurityDescriptor;
    FSdRead, FParentRead, FUpdating: Boolean;
    FParentError: string;
    FStateValue: TProtectionState;
    FJob: TDeletionProtectionJob;
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure CheckChange(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure ReloadClick(Sender: TObject);
    procedure JobDone(Sender: TObject);
    procedure ShowPlan;
    procedure UpdateButtons;
  protected
    // La fermeture attend le bilan: un travail detruit a mi-course laisserait une protection a moitie posee.
    function HasRunningWork: Boolean; override;
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);
    destructor Destroy; override;
    procedure Reload;
    procedure SetProtected(AValue: Boolean);
    procedure Apply;
    function StateText: string;
    function PlanText: string;
    function StatusText: string;
    function ApplyEnabled: Boolean;
    function CheckEnabled: Boolean;
    property Job: TDeletionProtectionJob read FJob;
  end;

procedure ShowDeletionProtection(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);
function ParentDnOf(const ADn: string): string;

resourcestring
  rsPpTitle = 'Deletion protection';
  rsPpObject = 'Object:';
  rsPpCheck = 'Protect object from accidental deletion';
  rsPpReading = 'Reading the access list...';
  rsPpPlanTitle = 'Planned changes:';
  rsPpNoChange = 'No change.';
  rsPpParentReading = 'the access list of the parent is being read';
  rsPpParentUnread = 'the access list of the parent cannot be read (%s): without its rule, an account ' +
    'allowed to delete children of the parent can still delete this object';
  rsPpParentKept = 'the rule of the parent is kept: other protected children may rely on it';
  rsPpRaceNote = 'Active Directory has no atomic update of an access list: each list is read again just ' +
    'before being replaced, then read back. A change made by someone else in that instant would be ' +
    'overwritten.';
  rsPpApply = 'Apply';
  rsPpReload = 'Reload';
  rsPpClose = 'Close';
  rsPpReadOnly = 'This profile is read-only: the protection cannot be changed here.';
  rsPpWorking = 'Applying...';
  rsPpSessionLost = 'The connection changed during the operation: its outcome is unknown. Reload to see ' +
    'the current state.';
  rsPpReadFailed = 'The access list of the object could not be read: %s';
  rsPpSdHidden = 'absent or hidden by access control';
  rsPpIdentityChanged = 'Another object now has this DN: nothing was written. Reload.';
  rsPpNoGuid = 'The identity of the object (objectGUID, exactly 16 bytes, entry fully read) could not ' +
    'be established: nothing can be safely changed here. Reload.';
  rsPpVerifyIdentity = 'Object: the entry read back after the change does not carry the expected ' +
    'objectGUID; the state shown may belong to another object. Check it.';
  rsPpChanged = 'The access list changed since it was shown: nothing was written. Reload and check it.';
  rsPpAlreadyDone = 'The object already had this state.';
  rsPpWriteFailed = 'The access list of the object was not changed: %s';
  rsPpObjectDone = 'Object: access list replaced and read back as planned.';
  rsPpObjectDiffers = 'Object: access list replaced, but the list read back differs from the plan ' +
    '(another change at the same moment?). Check it.';
  rsPpObjectNotApplied = 'Object: the change is not in the list read back (%s).';
  rsPpNotVerified = '%s: modification confirmed, current state not verified (%s).';
  rsPpParentHas = 'Parent: it already denies Everyone Delete all child objects.';
  rsPpParentDone = 'Parent: access list replaced and read back as planned.';
  rsPpParentDiffers = 'Parent: access list replaced, but the list read back differs from the plan ' +
    '(another change at the same moment?). Check it.';
  rsPpParentFailed = 'Parent: its rule could not be added (%s). An account allowed to delete children of ' +
    '%s can still delete the object.';
  rsPpNoParent = 'Parent: none in this naming context; nothing to add.';
  rsPpObjectWord = 'Object';
  rsPpParentWord = 'Parent';

implementation

uses
  uDirectoryWorker, uLdapEntry, uLdapErrors, uChangeSet, uLdapDn, uAdAccountPlan, uAdObjectPlan;

function ParentDnOf(const ADn: string): string;
var
  d: TLdapDn;
begin
  Result := '';
  if not DnTryParse(ADn, d) or (DnRdnCount(d) < 2) then Exit;
  Result := DnToString(DnParent(d));
end;

function SdOf(AMsg: TUiMessage; out ABytes: RawByteString; out AError: string): Boolean;
var
  e: TEntryMsg;
  a: TLdapAttribute;
begin
  Result := False;
  ABytes := '';
  AError := '';
  if AMsg is TTaskFailedMsg then
  begin
    AError := TTaskFailedMsg(AMsg).Text;
    Exit;
  end;
  if not (AMsg is TEntryMsg) then Exit;
  e := TEntryMsg(AMsg);
  if e.Entry = nil then
  begin
    AError := ErrorToText(e.Error);
    Exit;
  end;
  a := e.Entry.Find('nTSecurityDescriptor');
  if (a = nil) or (a.ValueCount <> 1) or a.Truncated then
  begin
    AError := rsPpSdHidden;
    Exit;
  end;
  ABytes := a.Values[0];
  Result := True;
end;

constructor TDeletionProtectionJob.Create(ACtx: TAppContext; const AProfileUuid, ADn: string;
  AProtect: Boolean);
begin
  inherited Create;
  FCtx := ACtx;
  FProfileUuid := AProfileUuid;
  FDn := ADn;
  FParentDn := ParentDnOf(ADn);
  FProtect := AProtect;
  FReport := TStringList.Create;
  FOutcome := poRunning;
  FTasks := TDirectoryTasks.Create(FCtx.Connections, FProfileUuid, Self);
  FTasks.OnMessage := @TaskMessage;
  FTasks.OnWriteSettled := @WriteSettled;
end;

destructor TDeletionProtectionJob.Destroy;
begin
  FreeAndNil(FTasks);
  FReport.Free;
  inherited Destroy;
end;

procedure TDeletionProtectionJob.WriteSettled(AKind: TOrphanWriteKind; const AText: string);
begin
  FCtx.LogWriteOutcome(AKind, rsPpTitle, AText);
end;

function TDeletionProtectionJob.GetTask: Int64;
begin
  Result := FTasks.TaskOf('step');
end;

procedure TDeletionProtectionJob.Start(ACheckVersion: Boolean; const AExpectedGuid,
  AExpectedSd: RawByteString);
begin
  FCheckVersion := ACheckVersion;
  FExpectedGuid := AExpectedGuid;
  FExpectedSd := AExpectedSd;
  FReport.Clear;
  FOutcome := poRunning;
  ReadSd(FDn, pjReadObject);
end;

function TDeletionProtectionJob.ReportText: string;
begin
  Result := Trim(FReport.Text);
end;

procedure TDeletionProtectionJob.Note(const AText: string);
begin
  FReport.Add(AText);
end;

procedure TDeletionProtectionJob.Finish(AOutcome: TProtectionOutcome);
begin
  FStep := pjDone;
  FOutcome := AOutcome;
  if Assigned(FOnDone) then FOnDone(Self);
end;

procedure TDeletionProtectionJob.ReadSd(const ADn: string; AStep: TProtectionJobStep);
begin
  if FTasks.Conn = nil then
  begin
    Note(rsTdNotConnected);
    if AStep in [pjReadObject, pjVerifyObject] then Finish(poFailed) else Finish(poWarning);
    Exit;
  end;
  FStep := AStep;
  if FTasks.ReadEntry('step', ADn, ['objectGUID', 'nTSecurityDescriptor'],
       [SdFlagsControl(SI_DACL, False)]) = 0 then
  begin
    Note(rsTdNotConnected);
    if AStep in [pjReadObject, pjVerifyObject] then Finish(poFailed) else Finish(poWarning);
  end;
end;

procedure TDeletionProtectionJob.WriteDacl(const ADn: string; const ABase: TSecurityDescriptor;
  const ANewDacl: TAcl; AStep: TProtectionJobStep);
var
  bytes: RawByteString;
  change: TLdapChange;
  werr: TLdapError;
begin
  bytes := SerializeDaclOnly(ABase, ANewDacl);
  if bytes = '' then
  begin
    Note(rsCcPartial);
    if AStep = pjWriteObject then Finish(poFailed) else Finish(poWarning);
    Exit;
  end;
  if FTasks.Conn = nil then
  begin
    Note(rsTdNotConnected);
    if AStep = pjWriteObject then Finish(poFailed) else Finish(poWarning);
    Exit;
  end;
  FPlanned := ANewDacl;
  FUnknown := False;
  FStep := AStep;
  // DACL seule, SD Flags critique: proprietaire, groupe et SACL restent intacts.
  change := NewChange(ckModify, ADn);
  change.AddMod(moReplace, 'nTSecurityDescriptor', [bytes]);
  if FTasks.Write('step', change, '', [SdFlagsControl(SI_DACL, True)], ['objectGUID'], werr) = 0 then
  begin
    if AStep = pjWriteObject then
    begin
      Note(Format(rsPpWriteFailed, [ErrorToText(werr)]));
      Finish(poFailed);
    end
    else
    begin
      Note(Format(rsPpParentFailed, [ErrorToText(werr), FParentDn]));
      Finish(poWarning);
    end;
  end;
end;

procedure TDeletionProtectionJob.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask;
  AEnding: TTaskEnding);
begin
  // Session fermee ou remplacee: la tache est deja soldee et l'issue n'est pas connue ici.
  if AEnding = teStale then
  begin
    Note(rsPpSessionLost);
    if FStep in [pjReadObject, pjReadParent] then
    begin
      if FStep = pjReadObject then Finish(poFailed) else Finish(poWarning);
    end
    else
      Finish(poWarning);
    Exit;
  end;
  case FStep of
    pjReadObject: ObjectRead(AMsg);
    pjReadParent: ParentRead(AMsg);
    pjWriteObject, pjWriteParent: Written(AMsg);
    pjVerifyObject, pjVerifyParent: Verified(AMsg);
  end;
end;

procedure TDeletionProtectionJob.ObjectRead(AMsg: TUiMessage);
var
  raw, guid: RawByteString;
  err: string;
  sd: TSecurityDescriptor;
  acl: TAcl;
  steps: TStringArray;
begin
  if not SdOf(AMsg, raw, err) then
  begin
    Note(Format(rsPpReadFailed, [err]));
    Finish(poFailed);
    Exit;
  end;
  // Jamais de remplacement de DACL sans identite: sans objectGUID utilisable, l'ecriture pourrait viser un
  // objet recree au meme DN. Comparer les seuls octets de la DACL accepterait un sosie a la liste identique.
  guid := UsableObjectGuid(TEntryMsg(AMsg).Entry);
  if (guid = '') or (FCheckVersion and (FExpectedGuid = '')) then
  begin
    Note(rsPpNoGuid);
    Finish(poFailed);
    Exit;
  end;
  if (FExpectedGuid <> '') and (guid <> FExpectedGuid) then
  begin
    Note(rsPpIdentityChanged);
    Finish(poFailed);
    Exit;
  end;
  // DACL differente de celle montree: conflit, rien n'est ecrit.
  if FCheckVersion and (raw <> FExpectedSd) then
  begin
    Note(rsPpChanged);
    Finish(poFailed);
    Exit;
  end;
  sd := ParseSecurityDescriptor(raw, SI_DACL);
  if not PlanDeletionProtection(sd, FProtect, acl, steps, err) then
  begin
    if err = rsPdAlready then
    begin
      Note(rsPpAlreadyDone);
      if FProtect then StartParent else Finish(poOk);
      Exit;
    end;
    Note(err);
    Finish(poFailed);
    Exit;
  end;
  WriteDacl(FDn, sd, acl, pjWriteObject);
end;

procedure TDeletionProtectionJob.StartParent;
begin
  if FParentDn = '' then
  begin
    Note(rsPpNoParent);
    Finish(poOk);
    Exit;
  end;
  ReadSd(FParentDn, pjReadParent);
end;

procedure TDeletionProtectionJob.ParentRead(AMsg: TUiMessage);
var
  raw: RawByteString;
  err: string;
  sd: TSecurityDescriptor;
  acl: TAcl;
  needed: Boolean;
begin
  if not SdOf(AMsg, raw, err) then
  begin
    Note(Format(rsPpParentFailed, [err, FParentDn]));
    Finish(poWarning);
    Exit;
  end;
  sd := ParseSecurityDescriptor(raw, SI_DACL);
  if not PlanParentDeleteChildDeny(sd, acl, needed, err) then
  begin
    Note(Format(rsPpParentFailed, [err, FParentDn]));
    Finish(poWarning);
    Exit;
  end;
  if not needed then
  begin
    Note(rsPpParentHas);
    Finish(poOk);
    Exit;
  end;
  WriteDacl(FParentDn, sd, acl, pjWriteParent);
end;

procedure TDeletionProtectionJob.Written(AMsg: TUiMessage);
var
  w: TWriteMsg;
  isObject: Boolean;
begin
  isObject := FStep = pjWriteObject;
  if AMsg is TTaskFailedMsg then
  begin
    // Incident apres l'envoi: seule la relecture dit ce qui est en place.
    FUnknown := True;
    if isObject then ReadSd(FDn, pjVerifyObject) else ReadSd(FParentDn, pjVerifyParent);
    Exit;
  end;
  if not (AMsg is TWriteMsg) then Exit;
  w := TWriteMsg(AMsg);
  // Appliquee ou inconnue: la relecture tranche.
  if not w.Result.Ok and (w.Result.Error.Category = lecUnknownOutcome) then
    FUnknown := True
  else if not w.Result.Ok then
  begin
    if isObject then
    begin
      Note(Format(rsPpWriteFailed, [ErrorToText(w.Result.Error)]));
      Finish(poFailed);
    end
    else
    begin
      Note(Format(rsPpParentFailed, [ErrorToText(w.Result.Error), FParentDn]));
      Finish(poWarning);
    end;
    Exit;
  end;
  if isObject then ReadSd(FDn, pjVerifyObject) else ReadSd(FParentDn, pjVerifyParent);
end;

procedure TDeletionProtectionJob.Verified(AMsg: TUiMessage);
var
  raw: RawByteString;
  err, reason, who: string;
  sd: TSecurityDescriptor;
  isObject, applied: Boolean;
begin
  isObject := FStep = pjVerifyObject;
  if isObject then who := rsPpObjectWord else who := rsPpParentWord;
  if not SdOf(AMsg, raw, err) then
  begin
    // Confirmee mais non verifiee, ou issue inconnue: rien n'est conclu.
    Note(Format(rsPpNotVerified, [who, err]));
    if isObject and FProtect and not FUnknown then StartParent else Finish(poWarning);
    Exit;
  end;
  // Relecture finale toujours sur le GUID du plan: sinon l'etat lu appartient peut-etre a un autre objet,
  // et conclure dessus serait de la divination.
  if isObject and (FExpectedGuid <> '') and
     (UsableObjectGuid(TEntryMsg(AMsg).Entry) <> FExpectedGuid) then
  begin
    Note(rsPpVerifyIdentity);
    Finish(poWarning);
    Exit;
  end;
  sd := ParseSecurityDescriptor(raw, SI_DACL);
  if DaclMatchesPlan(sd, FPlanned) then
  begin
    if isObject then Note(rsPpObjectDone) else Note(rsPpParentDone);
    if isObject and FProtect then StartParent else Finish(poOk);
    Exit;
  end;
  if isObject then
  begin
    applied := (EvaluateDeletionProtection(sd, reason) = prProtected) = FProtect;
    if applied then
    begin
      Note(rsPpObjectDiffers);
      if FProtect then StartParent else Finish(poWarning);
    end
    else
    begin
      Note(Format(rsPpObjectNotApplied, [reason]));
      Finish(poFailed);
    end;
  end
  else
  begin
    Note(rsPpParentDiffers);
    Finish(poWarning);
  end;
end;

procedure ShowDeletionProtection(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);
var
  d: TDeletionProtectionDialog;
begin
  d := TDeletionProtectionDialog.CreateFor(AOwner, ACtx, AProfileUuid, ADn);
  try
    d.ShowModal;
  finally
    d.Free;
  end;
end;

constructor TDeletionProtectionDialog.CreateFor(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, ADn: string);
var
  c: TDirectoryConnection;
  lbl: TLabel;
begin
  inherited CreateDialog(AOwner, rsPpTitle, 680, 460);
  SetIcon('shield-lock');
  InitTasks(ACtx, AProfileUuid);
  FDn := ADn;
  FParentDn := ParentDnOf(ADn);
  c := FCtx.Connections.Find(FProfileUuid);
  if c <> nil then SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
  lbl := MakeLabel(Body, rsPpObject);
  lbl.Font.Color := DialogStateColor(usMuted);
  lbl := MakeLabel(Body, AdCanonicalPath(ADn));
  lbl.Font.Style := [fsBold];
  lbl.ShowAccelChar := False;
  lbl := MakeLabel(Body, ADn);
  lbl.ShowAccelChar := False;
  lbl.Font.Color := DialogStateColor(usMuted);
  FState := MakeLabel(Body, rsPpReading);
  FState.WordWrap := True;
  FState.ShowAccelChar := False;
  FState.BorderSpacing.Top := 12;
  FCheck := MakeCheck(Body, rsPpCheck);
  FCheck.BorderSpacing.Top := 8;
  FCheck.OnChange := @CheckChange;
  lbl := MakeLabel(Body, rsPpRaceNote, alBottom);
  lbl.WordWrap := True;
  lbl.Font.Color := DialogStateColor(usMuted);
  FStatus := MakeLabel(Body, '', alBottom);
  FStatus.WordWrap := True;
  FStatus.ShowAccelChar := False;
  FPlan := MakeMemo(Body);
  FPlan.ReadOnly := True;
  FPlan.WordWrap := True;
  FPlan.ScrollBars := ssAutoVertical;
  FPlan.BorderSpacing.Top := 8;
  AddButton(rsPpClose, mrClose, False, True);
  FApply := AddButton(rsPpApply, mrNone, True);
  FApply.OnClick := @ApplyClick;
  FReload := AddButton(rsPpReload, mrNone);
  FReload.OnClick := @ReloadClick;
  Tasks.OnMessage := @TaskMessage;
  ApplyTheme;
  Reload;
end;

destructor TDeletionProtectionDialog.Destroy;
begin
  FreeAndNil(FJob);
  inherited Destroy;
end;

function TDeletionProtectionDialog.HasRunningWork: Boolean;
begin
  // Lecture, ecriture, verification, puis le parent: detruire le travail en route abandonne les etapes
  // restantes et le bilan avec.
  Result := (FJob <> nil) and (FJob.Outcome = poRunning);
end;

procedure TDeletionProtectionDialog.Reload;
begin
  FSdRead := False;
  FParentRead := False;
  FParentError := '';
  FStateValue := prIndeterminate;
  FState.Caption := rsPpReading;
  FPlan.Clear;
  if Conn = nil then
  begin
    FState.Caption := rsTdNotConnected;
    UpdateButtons;
    Exit;
  end;
  // Lectures precedentes annulees, leurs reponses ne sont plus livrees: deux Reload ne laissent pas
  // d'orpheline.
  Tasks.Cancel('object');
  Tasks.Cancel('parent');
  Tasks.ReadEntry('object', FDn, ['objectGUID', 'nTSecurityDescriptor'], [SdFlagsControl(SI_DACL, False)]);
  if FParentDn <> '' then
    Tasks.ReadEntry('parent', FParentDn, ['nTSecurityDescriptor'], [SdFlagsControl(SI_DACL, False)]);
  UpdateButtons;
end;

procedure TDeletionProtectionDialog.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask;
  AEnding: TTaskEnding);
var
  raw: RawByteString;
  err, reason: string;
begin
  if ATask.Tag = 'object' then
  begin
    if AEnding = teStale then
      FState.Caption := rsPpSessionLost
    else if not SdOf(AMsg, raw, err) then
      FState.Caption := Format(rsPpReadFailed, [err])
    else
    begin
      FGuid := UsableObjectGuid(TEntryMsg(AMsg).Entry);
      // Sans identite sure (objectGUID absent, multiple, tronque, entree incomplete), rien n'est modifiable
      // d'ici: l'ecriture viserait un objet qu'on ne sait pas reidentifier.
      if FGuid = '' then
        FState.Caption := rsPpNoGuid
      else
      begin
        FSdBytes := raw;
        FSd := ParseSecurityDescriptor(raw, SI_DACL);
        FSdRead := True;
        FStateValue := EvaluateDeletionProtection(FSd, reason);
        FState.Caption := reason;
        FUpdating := True;
        try
          FCheck.Checked := FStateValue = prProtected;
        finally
          FUpdating := False;
        end;
      end;
    end;
    ShowPlan;
    UpdateButtons;
    Exit;
  end;
  if ATask.Tag = 'parent' then
  begin
    if AEnding = teStale then
      FParentError := rsPpSessionLost
    else if not SdOf(AMsg, raw, err) then
      FParentError := err
    else
    begin
      FParentSd := ParseSecurityDescriptor(raw, SI_DACL);
      FParentRead := True;
    end;
    ShowPlan;
    UpdateButtons;
  end;
end;

procedure TDeletionProtectionDialog.ShowPlan;
var
  acl: TAcl;
  steps: TStringArray;
  err: string;
  needed: Boolean;
  i: Integer;
begin
  FPlan.Clear;
  if not FSdRead or (FCheck.Checked = (FStateValue = prProtected)) then
  begin
    if FSdRead then FPlan.Lines.Add(rsPpNoChange);
    Exit;
  end;
  if not PlanDeletionProtection(FSd, FCheck.Checked, acl, steps, err) then
  begin
    FPlan.Lines.Add(err);
    Exit;
  end;
  FPlan.Lines.Add(rsPpPlanTitle);
  for i := 0 to High(steps) do
    FPlan.Lines.Add('  ' + steps[i]);
  if not FCheck.Checked then
  begin
    FPlan.Lines.Add('  ' + rsPpParentKept);
    Exit;
  end;
  if FParentDn = '' then
    FPlan.Lines.Add('  ' + rsPpNoParent)
  else if FParentRead and PlanParentDeleteChildDeny(FParentSd, acl, needed, err) then
  begin
    if needed then FPlan.Lines.Add('  ' + rsPdAddParent) else FPlan.Lines.Add('  ' + rsPdParentHas);
  end
  else if FParentRead then
    FPlan.Lines.Add('  ' + Format(rsPpParentUnread, [err]))
  else if FParentError <> '' then
    FPlan.Lines.Add('  ' + Format(rsPpParentUnread, [FParentError]))
  else
    FPlan.Lines.Add('  ' + rsPpParentReading);
end;

procedure TDeletionProtectionDialog.UpdateButtons;
var
  c: TDirectoryConnection;
  busy, writable: Boolean;
  acl: TAcl;
  steps: TStringArray;
  err: string;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  // La lecture du parent compte comme occupee: sinon Reload et Apply s'offraient avant que le plan soit
  // complet, et un Reload laissait la premiere lecture du parent orpheline.
  busy := Tasks.Pending('object') or Tasks.Pending('parent') or HasRunningWork;
  writable := (c <> nil) and c.IsReady and not c.Profile.ReadOnly;
  // Etat non concluant: pas de case qui pretendrait savoir.
  FCheck.Enabled := FSdRead and (FStateValue <> prIndeterminate) and writable and not busy;
  FApply.Enabled := FCheck.Enabled and (FCheck.Checked <> (FStateValue = prProtected)) and
    PlanDeletionProtection(FSd, FCheck.Checked, acl, steps, err);
  FReload.Enabled := not busy;
  if (c <> nil) and c.Profile.ReadOnly and (FStatus.Caption = '') then SetStatus(rsPpReadOnly, usWarning);
end;

procedure TDeletionProtectionDialog.CheckChange(Sender: TObject);
begin
  if FUpdating then Exit;
  ShowPlan;
  UpdateButtons;
end;

procedure TDeletionProtectionDialog.ApplyClick(Sender: TObject);
begin
  Apply;
end;

procedure TDeletionProtectionDialog.Apply;
begin
  UpdateButtons;
  if not FApply.Enabled then Exit;
  FreeAndNil(FJob);
  FJob := TDeletionProtectionJob.Create(FCtx, FProfileUuid, FDn, FCheck.Checked);
  FJob.OnDone := @JobDone;
  SetStatus(rsPpWorking, usMuted);
  FJob.Start(True, FGuid, FSdBytes);
  UpdateButtons;
end;

procedure TDeletionProtectionDialog.JobDone(Sender: TObject);
begin
  case FJob.Outcome of
    poOk: SetStatus(FJob.ReportText, usOk);
    poWarning: SetStatus(FJob.ReportText, usWarning);
  else
    SetStatus(FJob.ReportText, usError);
  end;
  Reload;
end;

procedure TDeletionProtectionDialog.ReloadClick(Sender: TObject);
begin
  SetStatus('', usMuted);
  Reload;
end;

procedure TDeletionProtectionDialog.SetProtected(AValue: Boolean);
begin
  FCheck.Checked := AValue;
  CheckChange(FCheck);
end;

function TDeletionProtectionDialog.StateText: string;
begin
  Result := FState.Caption;
end;

function TDeletionProtectionDialog.PlanText: string;
begin
  Result := Trim(FPlan.Lines.Text);
end;

function TDeletionProtectionDialog.StatusText: string;
begin
  Result := FStatus.Caption;
end;

function TDeletionProtectionDialog.ApplyEnabled: Boolean;
begin
  Result := FApply.Enabled;
end;

function TDeletionProtectionDialog.CheckEnabled: Boolean;
begin
  Result := FCheck.Enabled;
end;

end.
