// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAdSecurityDialogs;

{$mode objfpc}{$H+}

// Active Directory: drapeaux userAccountControl, regle "ne peut pas changer son mot de passe"
// et lecteur de descripteur de securite. AD n'a pas de precondition atomique d'identite: le compte
// est relu apres confirmation, et rien ne part si objectGUID ou userAccountControl ont bouge.
// Il reste une fenetre de quelques millisecondes: on la dit a la confirmation, on ne la cache pas.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs, Graphics, uAppContext, uUiKit,
  uRtCheck, uUiInbox, uLdapEntry, uChangeSet, uAdSecurityDescriptor, uAdAccountPlan, uTaskTracker,
  uTaskDialog;

type
  TAccountFlagsDialog = class(TTaskDialog)
  private
    FDn: string;
    FEntry: TLdapEntry;
    FSd: TSecurityDescriptor;
    FSdRead: Boolean;
    FChecks: array of TRtCheckBox;
    FBits: array of LongWord;
    FValueLabel: TLabel;
    FCcState, FCcNote: TLabel;
    FCcCheck: TRtCheckBox;
    FCcPreview: TMemo;
    FApply, FReload: TButton;
    FGuid: RawByteString;
    FPendingChange: TLdapChange;
    FPendingUac: string;
    FNeedsReread: Boolean;
    FUpdating: Boolean;
    FPendingNote: string;
    procedure BuildUi;
    procedure Populate;
    procedure PopulateSd;
    procedure ReloadClick(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure CcChange(Sender: TObject);
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure HandleWrite(AMsg: TUiMessage);
    procedure VerifyThenWrite(AMsg: TUiMessage);
    procedure DropStale(const ATag: string);
    procedure UpdateButtons;
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);
    destructor Destroy; override;
    procedure Reload;
    procedure SetFlag(ABit: LongWord; AChecked: Boolean);
    function FlagChecked(ABit: LongWord): Boolean;
    function FlagEnabled(ABit: LongWord): Boolean;
    procedure ApplyUac;
    function CanApply: Boolean;
    function ReloadEnabled: Boolean;
    function StatusText: string;
    function CantChangeText: string;
    function PreviewText: string;
    procedure SetCantChange(AChecked: Boolean);
  end;

resourcestring
  rsAfTitle = 'Account flags and permissions';
  rsAfEntry = 'Entry: %s';
  rsAfValue = 'userAccountControl: %s (0x%.8x); unknown bits kept: %s';
  rsAfValueUnknown = 'userAccountControl: not read yet';
  rsAfNone = 'none';
  rsAfReading = 'Reading the entry...';
  rsAfReadFailed = 'The entry could not be read: %s';
  rsAfNoUac = 'userAccountControl was not returned (absent, hidden by access control or not an account): nothing can be changed.';
  rsAfReadOnly = '(read only: %s)';
  rsAfSensitiveTag = '(security)';
  rsAfCatType = 'account type';
  rsAfCatComputed = 'computed by the server, never written';
  rsAfCatNotInUac = 'an access rule, not a stored bit: see below';
  rsAfCatServer = 'set by the system';
  rsAfApply = 'Apply';
  rsAfReload = 'Reload';
  rsAfClose = 'Close';
  rsAfSensitiveNote = 'Security-sensitive changes:';
  rsAfNeedsReread = 'Read the entry again before another change (the last write is applied or unknown).';
  rsAfApplied = 'Applied; the flags show the value read back.';
  rsAfUnknown = 'The result of the write is unknown: nothing is resent. Reload the entry before any other change.';
  rsAfConflict = 'The value changed on the server since it was read: nothing was written. The entry is read again; review the flags.';
  rsAfFailed = 'The change was refused: %s';
  rsAfIdentityUnknown = 'objectGUID was not read as a single complete value: the identity of the account is ' +
    'not established, nothing can be changed.';
  rsAfIdentityChanged = 'Another object now has this DN (its objectGUID differs): nothing was written. ' +
    'The entry is read again; review the flags.';
  rsAfVerifying = 'Reading the account again (identity and value) before writing...';
  rsAfVerifyFailed = 'The account could not be read again before writing: nothing was written. %s';
  rsAfResidualRace = 'Active Directory has no atomic identity precondition: the account is read again just ' +
    'before the write, and the write is sent only if its objectGUID and userAccountControl are unchanged. ' +
    'A race of a few milliseconds remains.';
  rsAfCcTitle = 'User cannot change password (rule on the Change Password right for SELF and Everyone)';
  rsAfCcCheck = 'User cannot change password';
  rsAfCcReading = 'Reading the access list (DACL only)...';
  rsAfCcNotQualified = 'Writing the access list requires a protection against concurrent changes that is not qualified ' +
    'for this server: the change is shown here but not sent. Use the directory tools to apply it.';
  rsAfCcPlanTitle = '# planned rule changes (not sent)';
  rsSdTitle = 'Security descriptor';
  rsSdIncludeSacl = 'Include the audit rules (SACL; requires the right to read them)';
  rsSdReading = 'Reading the security descriptor...';
  rsSdNotReturned = 'nTSecurityDescriptor was not returned: %s';
  rsSdNote = 'Recorded rules only: this view does not compute the effective rights of any user.';

procedure ShowAccountFlags(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);
procedure ShowSecurityDescriptor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);

implementation

uses
  uConnections, uDirectoryWorker, uLdapErrors, uTheme,
  uSearchModel;

const
  UAC_ATTRS: array[0..3] of string = ('userAccountControl', 'msDS-User-Account-Control-Computed',
    'objectClass', 'objectGUID');

procedure ShowAccountFlags(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);
var
  d: TAccountFlagsDialog;
begin
  d := TAccountFlagsDialog.CreateFor(AOwner, ACtx, AProfileUuid, ADn);
  try
    d.ShowModal;
  finally
    d.Free;
  end;
end;

constructor TAccountFlagsDialog.CreateFor(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, ADn: string);
var
  c: TDirectoryConnection;
begin
  inherited CreateDialog(AOwner, rsAfTitle, 820, 700);
  SetIcon('shield-lock');
  FDn := ADn;
  InitTasks(ACtx, AProfileUuid);
  c := FCtx.Connections.Find(AProfileUuid);
  if c <> nil then SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
  Tasks.OnMessage := @TaskMessage;
  BuildUi;
  Reload;
end;

destructor TAccountFlagsDialog.Destroy;
begin
  FPendingChange.Free;
  FEntry.Free;
  inherited Destroy;
end;

procedure TAccountFlagsDialog.BuildUi;
var
  box: TScrollBox;
  content: TPanel;
  i: Integer;
  f: TUacFlag;
  cb: TRtCheckBox;
  cap: string;
  cc: TPanel;
begin
  MakeLabel(Body, Format(rsAfEntry, [FDn]));
  FValueLabel := MakeLabel(Body, rsAfValueUnknown);
  FStatus := MakeLabel(Body, '');
  FStatus.WordWrap := True;
  cc := MakePanel(Body, alBottom, 220);
  MakeLabel(cc, rsAfCcTitle);
  FCcState := MakeLabel(cc, rsAfCcReading);
  FCcState.WordWrap := True;
  FCcCheck := MakeCheck(cc, rsAfCcCheck);
  FCcCheck.Enabled := False;
  FCcCheck.OnChange := @CcChange;
  FCcNote := MakeLabel(cc, rsAfCcNotQualified);
  FCcNote.WordWrap := True;
  FCcPreview := MakeMemo(cc, alClient);
  FCcPreview.ReadOnly := True;
  box := TScrollBox.Create(Body);
  box.Parent := Body;
  box.Align := alClient;
  box.BorderStyle := bsNone;
  box.HorzScrollBar.Visible := False;
  // Un seul enfant a hauteur automatique dans la boite: des cases posees directement
  // dedans faisaient boucler la mise en page sous Cocoa.
  content := TPanel.Create(box);
  content.Parent := box;
  content.Align := alTop;
  content.BevelOuter := bvNone;
  content.Caption := '';
  content.AutoSize := True;
  SetLength(FChecks, UacFlagCount);
  SetLength(FBits, UacFlagCount);
  for i := 0 to UacFlagCount - 1 do
  begin
    f := UacFlag(i);
    cap := f.Name + ' - ' + f.Description;
    case f.Category of
      ucSensitive: cap := cap + ' ' + rsAfSensitiveTag;
      ucAccountType: cap := cap + ' ' + Format(rsAfReadOnly, [rsAfCatType]);
      ucComputed: cap := cap + ' ' + Format(rsAfReadOnly, [rsAfCatComputed]);
      ucNotInUac: cap := cap + ' ' + Format(rsAfReadOnly, [rsAfCatNotInUac]);
      ucServerOnly: cap := cap + ' ' + Format(rsAfReadOnly, [rsAfCatServer]);
    end;
    cb := MakeCheck(content, cap);
    cb.Enabled := False;
    FChecks[i] := cb;
    FBits[i] := f.Bit;
  end;
  AddButton(rsAfClose, mrClose, False, True);
  FApply := AddButton(rsAfApply, mrNone, True);
  FApply.OnClick := @ApplyClick;
  FReload := AddButton(rsAfReload, mrNone);
  FReload.OnClick := @ReloadClick;
  ApplyTheme;
  FCcPreview.Color := clEditorBg;
  FCcPreview.Font.Color := clEditorFg;
  StyleMemo(FCcPreview);
  UpdateButtons;
end;

procedure TAccountFlagsDialog.Reload;
begin
  if Conn = nil then Exit;
  FStatus.Caption := rsAfReading;
  FCcState.Caption := rsAfCcReading;
  FSdRead := False;
  FreeAndNil(FPendingChange);
  Tasks.Cancel('verify');
  Tasks.Cancel('uac');
  Tasks.Cancel('sd');
  // Relecture: toutes les cases grisees jusqu'a la reponse. Une case decochee n'est pas une valeur lue.
  FreeAndNil(FEntry);
  Tasks.InvalidateModel;
  FGuid := '';
  Populate;
  Tasks.ReadEntry('uac', FDn, UAC_ATTRS);
  // DACL seule. La SACL n'est jamais demandee: pas besoin de privileges qu'on n'a pas a avoir.
  Tasks.ReadEntry('sd', FDn, ['nTSecurityDescriptor'], [SdFlagsControl(SI_DACL, False)]);
  UpdateButtons;
end;

procedure TAccountFlagsDialog.ReloadClick(Sender: TObject);
begin
  Reload;
end;

procedure TAccountFlagsDialog.Populate;
var
  i: Integer;
  a: TLdapAttribute;
  v: Int64;
  unk: LongWord;
  f: TUacFlag;
  ok: Boolean;
begin
  FUpdating := True;
  try
    ok := False;
    v := 0;
    if FEntry <> nil then
    begin
      a := FEntry.Find('userAccountControl');
      ok := (a <> nil) and (a.ValueCount = 1) and not a.Truncated and
        TryStrToInt64(string(a.Values[0]), v) and (v >= 0) and (v <= High(LongWord));
    end;
    for i := 0 to High(FChecks) do
    begin
      f := UacFlag(i);
      FChecks[i].Checked := ok and ((v and FBits[i]) <> 0);
      FChecks[i].Enabled := ok and not FNeedsReread and (f.Category in [ucEditable, ucSensitive]);
    end;
    if ok then
    begin
      unk := UacUnknownBits(v);
      if unk = 0 then
        FValueLabel.Caption := Format(rsAfValue, [IntToStr(v), Int64(v), rsAfNone])
      else
        FValueLabel.Caption := Format(rsAfValue, [IntToStr(v), Int64(v), '0x' + IntToHex(unk, 8)]);
    end
    else
      FValueLabel.Caption := rsAfValueUnknown;
    if (FEntry <> nil) and not ok then FStatus.Caption := rsAfNoUac;
  finally
    FUpdating := False;
  end;
  UpdateButtons;
end;

procedure TAccountFlagsDialog.PopulateSd;
var
  reason: string;
  st: TCantChangeState;
begin
  FUpdating := True;
  try
    st := EvaluateCantChangePassword(FSd, reason);
    FCcState.Caption := reason;
    FCcCheck.Checked := st = ccDenied;
    FCcCheck.Enabled := FSdRead and (st <> ccIndeterminate);
    FCcPreview.Clear;
  finally
    FUpdating := False;
  end;
end;

procedure TAccountFlagsDialog.CcChange(Sender: TObject);
var
  acl: TAcl;
  steps: TStringArray;
  err: string;
  i: Integer;
begin
  if FUpdating or not FSdRead then Exit;
  FCcPreview.Clear;
  if PlanCantChangePassword(FSd, FCcCheck.Checked, acl, steps, err) then
  begin
    FCcPreview.Lines.Add(rsAfCcPlanTitle);
    for i := 0 to High(steps) do
      FCcPreview.Lines.Add(steps[i]);
  end
  else
    FCcPreview.Lines.Add(err);
end;

procedure TAccountFlagsDialog.SetCantChange(AChecked: Boolean);
begin
  FCcCheck.Checked := AChecked;
end;

function TAccountFlagsDialog.CantChangeText: string;
begin
  Result := FCcState.Caption;
end;

function TAccountFlagsDialog.PreviewText: string;
begin
  Result := FCcPreview.Text;
end;

procedure TAccountFlagsDialog.UpdateButtons;
begin
  FApply.Enabled := CanApply;
  FReload.Enabled := not Tasks.WritesInFlight and not Tasks.Pending('uac') and
    not Tasks.Pending('verify');
end;

function TAccountFlagsDialog.CanApply: Boolean;
var
  c: TDirectoryConnection;
begin
  c := Conn;
  Result := (c <> nil) and not c.Profile.ReadOnly and (FEntry <> nil) and
    (FGuid <> '') and Tasks.ModelCurrent and
    not Tasks.WritesInFlight and not Tasks.Pending('uac') and not Tasks.Pending('verify') and
    (FPendingChange = nil) and not FNeedsReread;
end;

function TAccountFlagsDialog.ReloadEnabled: Boolean;
begin
  Result := FReload.Enabled;
end;

function TAccountFlagsDialog.StatusText: string;
begin
  Result := FStatus.Caption;
end;

procedure TAccountFlagsDialog.SetFlag(ABit: LongWord; AChecked: Boolean);
var
  i: Integer;
begin
  for i := 0 to High(FBits) do
    if (FBits[i] = ABit) and FChecks[i].Enabled then FChecks[i].Checked := AChecked;
end;

function TAccountFlagsDialog.FlagChecked(ABit: LongWord): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FBits) do
    if FBits[i] = ABit then Exit(FChecks[i].Checked);
  Result := False;
end;

function TAccountFlagsDialog.FlagEnabled(ABit: LongWord): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FBits) do
    if FBits[i] = ABit then Exit(FChecks[i].Enabled);
  Result := False;
end;

procedure TAccountFlagsDialog.ApplyClick(Sender: TObject);
begin
  ApplyUac;
end;

procedure TAccountFlagsDialog.ApplyUac;
var
  i: Integer;
  setMask, clearMask: LongWord;
  v: Int64;
  change: TLdapChange;
  plan: TUacPlan;
  err, note, reason: string;
begin
  if not CanApply then Exit;
  if not TryStrToInt64(string(FEntry.FirstValue('userAccountControl', '')), v) then Exit;
  // Seuls les bits changes par l'utilisateur forment le masque; les autres restent ceux du serveur.
  setMask := 0;
  clearMask := 0;
  for i := 0 to High(FChecks) do
    if FChecks[i].Enabled then
    begin
      if FChecks[i].Checked and ((v and FBits[i]) = 0) then setMask := setMask or FBits[i];
      if not FChecks[i].Checked and ((v and FBits[i]) <> 0) then clearMask := clearMask or FBits[i];
    end;
  change := PlanUacChange(FEntry, setMask, clearMask, plan, err);
  if change = nil then
  begin
    FStatus.Caption := err;
    Exit;
  end;
  note := rsAfResidualRace;
  if Length(plan.SensitiveChanges) > 0 then
    note := rsAfSensitiveNote + LineEnding + string.Join(LineEnding, plan.SensitiveChanges) +
      LineEnding + note;
  if not ConfirmWrite(Self, FCtx, Tasks, [change], reason, note) then
  begin
    change.Free;
    if reason <> '' then FStatus.Caption := reason;
    UpdateButtons;
    Exit;
  end;
  // Relecture d'identite et de valeur: le plan confirme ne part a la reponse que si c'est
  // le meme compte avec la meme valeur.
  FPendingChange := change;
  FPendingUac := string(FEntry.FirstValue('userAccountControl', ''));
  Tasks.ReadEntry('verify', FDn, UAC_ATTRS);
  FStatus.Caption := rsAfVerifying;
  UpdateButtons;
end;

procedure TAccountFlagsDialog.VerifyThenWrite(AMsg: TUiMessage);
var
  e: TLdapEntry;
  change: TLdapChange;
  werr: TLdapError;
begin
  change := FPendingChange;
  FPendingChange := nil;
  try
    e := nil;
    if AMsg is TEntryMsg then e := TEntryMsg(AMsg).Entry;
    if e = nil then
    begin
      if AMsg is TTaskFailedMsg then
        FStatus.Caption := Format(rsAfVerifyFailed, [TTaskFailedMsg(AMsg).Text])
      else if AMsg is TEntryMsg then
        FStatus.Caption := Format(rsAfVerifyFailed, [ErrorToText(TEntryMsg(AMsg).Error)]);
      Exit;
    end;
    // Un autre objet porte ce DN (supprime puis recree): rien n'est ecrit, on relit et on
    // montre. Modifier l'homonyme d'un compte, c'est une facon originale de se faire des ennemis.
    if UsableObjectGuid(e) <> FGuid then
    begin
      FPendingNote := rsAfIdentityChanged;
      Reload;
      FStatus.Caption := rsAfIdentityChanged;
      Exit;
    end;
    // Valeur changee depuis la lecture: conflit, relecture, et aucune tentative.
    if string(e.FirstValue('userAccountControl', '')) <> FPendingUac then
    begin
      FPendingNote := rsAfConflict;
      Reload;
      FStatus.Caption := rsAfConflict;
      Exit;
    end;
    if not Tasks.ModelCurrent then
    begin
      FStatus.Caption := rsTdModelStale;
      Exit;
    end;
    // Write prend possession du changement, meme quand il refuse: pas de Free ici.
    if Tasks.Write('write', change, '', nil, UAC_ATTRS, werr) = 0 then
      FStatus.Caption := ErrorToText(werr)
    else
      FStatus.Caption := '';
    change := nil;
  finally
    change.Free;
    UpdateButtons;
  end;
end;

procedure TAccountFlagsDialog.DropStale(const ATag: string);
begin
  // Ecriture partie dans l'ancienne session: issue inconnue, on relit avant tout nouveau plan.
  if ATag = 'write' then FNeedsReread := True;
  if ATag = 'verify' then FreeAndNil(FPendingChange);
  FPendingNote := '';
  if ATag = 'write' then FStatus.Caption := rsTdSessionLost
  else FStatus.Caption := rsTdReadSessionLost;
  Populate;
end;

procedure TAccountFlagsDialog.HandleWrite(AMsg: TUiMessage);
var
  m: TWriteMsg;
begin
  if AMsg is TTaskFailedMsg then
  begin
    FNeedsReread := True;
    FStatus.Caption := rsAfUnknown;
    Populate;
    Exit;
  end;
  if not (AMsg is TWriteMsg) then Exit;
  m := TWriteMsg(AMsg);
  if m.Result.Ok then
  begin
    if (m.Reread <> nil) and (m.Reread.Find('userAccountControl') <> nil) and
       (UsableObjectGuid(m.Reread) = FGuid) then
    begin
      FEntry.Free;
      FEntry := m.Reread;
      m.Reread := nil;
      Tasks.StampModel(m);
      FNeedsReread := False;
      FStatus.Caption := rsAfApplied;
    end
    else
    begin
      FNeedsReread := True;
      FStatus.Caption := rsAfNeedsReread;
    end;
  end
  else if m.Result.Error.Category = lecUnknownOutcome then
  begin
    FNeedsReread := True;
    FStatus.Caption := rsAfUnknown;
  end
  else if m.Result.Error.Category in [lecConstraint, lecAssertionFailed] then
  begin
    FCtx.Log(mlWarning, rsAfTitle, rsAfConflict);
    FPendingNote := rsAfConflict;
    Reload;
    FStatus.Caption := rsAfConflict;
    Exit;
  end
  else
    FStatus.Caption := Format(rsAfFailed, [ErrorToText(m.Result.Error)]);
  Populate;
end;

procedure TAccountFlagsDialog.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask;
  AEnding: TTaskEnding);
var
  e: TEntryMsg;
  a: TLdapAttribute;
  raw: RawByteString;
begin
  if AEnding = teStale then
  begin
    DropStale(ATask.Tag);
    Exit;
  end;
  if ATask.Tag = 'write' then
  begin
    HandleWrite(AMsg);
    Exit;
  end;
  if ATask.Tag = 'verify' then
  begin
    VerifyThenWrite(AMsg);
    Exit;
  end;
  if ATask.Tag = 'uac' then
  begin
    if AMsg is TTaskFailedMsg then
      FStatus.Caption := Format(rsAfReadFailed, [TTaskFailedMsg(AMsg).Text])
    else if AMsg is TEntryMsg then
    begin
      e := TEntryMsg(AMsg);
      if e.Entry = nil then
        FStatus.Caption := Format(rsAfReadFailed, [ErrorToText(e.Error)])
      else
      begin
        FEntry.Free;
        FEntry := e.Entry;
        e.Entry := nil;
        FNeedsReread := False;
        Tasks.StampModel(AMsg);
        FGuid := UsableObjectGuid(FEntry);
        FStatus.Caption := FPendingNote;
        FPendingNote := '';
        if FGuid = '' then FStatus.Caption := rsAfIdentityUnknown;
      end;
    end;
    Populate;
    Exit;
  end;
  if ATask.Tag = 'sd' then
  begin
    FSd := Default(TSecurityDescriptor);
    FSdRead := False;
    if (AMsg is TEntryMsg) and (TEntryMsg(AMsg).Entry <> nil) then
    begin
      a := TEntryMsg(AMsg).Entry.Find('nTSecurityDescriptor');
      if (a <> nil) and (a.ValueCount = 1) and not a.Truncated then
      begin
        raw := a.Values[0];
        FSd := ParseSecurityDescriptor(raw, SI_DACL);
        FSdRead := True;
      end;
    end;
    PopulateSd;
    Exit;
  end;
end;

type
  TSdViewer = class(TTaskDialog)
  private
    FDn: string;
    FMemo: TMemo;
    FSacl: TRtCheckBox;
    FFlags: Byte;
    procedure ReloadClick(Sender: TObject);
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
  public
    procedure Start;
  end;

procedure TSdViewer.Start;
begin
  if Conn = nil then Exit;
  FFlags := SI_OWNER or SI_GROUP or SI_DACL;
  if FSacl.Checked then FFlags := FFlags or SI_SACL;
  FMemo.Lines.Text := rsSdReading;
  Tasks.Cancel('sd');
  Tasks.ReadEntry('sd', FDn, ['nTSecurityDescriptor'], [SdFlagsControl(FFlags, False)]);
end;

procedure TSdViewer.ReloadClick(Sender: TObject);
begin
  Start;
end;

procedure TSdViewer.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
var
  e: TEntryMsg;
  a: TLdapAttribute;
  lines: TStringArray;
  i: Integer;
begin
  FMemo.Clear;
  if AEnding = teStale then
  begin
    FMemo.Lines.Add(rsTdReadSessionLost);
    Exit;
  end;
  if AMsg is TTaskFailedMsg then
  begin
    FMemo.Lines.Add(Format(rsSdNotReturned, [TTaskFailedMsg(AMsg).Text]));
    Exit;
  end;
  if not (AMsg is TEntryMsg) then Exit;
  e := TEntryMsg(AMsg);
  a := nil;
  if e.Entry <> nil then a := e.Entry.Find('nTSecurityDescriptor');
  if (a = nil) or (a.ValueCount = 0) then
  begin
    if e.Entry = nil then FMemo.Lines.Add(Format(rsSdNotReturned, [ErrorToText(e.Error)]))
    else FMemo.Lines.Add(Format(rsSdNotReturned, ['absent or hidden by access control']));
    Exit;
  end;
  lines := DescribeSecurityDescriptor(ParseSecurityDescriptor(a.Values[0], FFlags));
  FMemo.Lines.BeginUpdate;
  try
    FMemo.Lines.Add(rsSdNote);
    FMemo.Lines.Add('');
    for i := 0 to High(lines) do
      FMemo.Lines.Add(lines[i]);
  finally
    FMemo.Lines.EndUpdate;
  end;
end;

procedure ShowSecurityDescriptor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);
var
  d: TSdViewer;
  c: TDirectoryConnection;
  b: TButton;
begin
  d := TSdViewer.CreateDialog(AOwner, rsSdTitle, 900, 640);
  d.SetIcon('shield-lock');
  try
    d.InitTasks(ACtx, AProfileUuid);
    d.Tasks.OnMessage := @d.TaskMessage;
    d.FDn := ADn;
    c := ACtx.Connections.Find(AProfileUuid);
    if c <> nil then d.SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
    MakeLabel(d.Body, Format(rsAfEntry, [ADn]));
    d.FSacl := MakeCheck(d.Body, rsSdIncludeSacl);
    d.FMemo := MakeMemo(d.Body);
    d.FMemo.ReadOnly := True;
    d.FMemo.ScrollBars := ssAutoBoth;
    d.FMemo.WordWrap := False;
    d.AddButton(rsAfClose, mrClose, True, True);
    b := d.AddButton(rsAfReload, mrNone);
    b.OnClick := @d.ReloadClick;
    d.ApplyTheme;
    d.FMemo.Color := clEditorBg;
    d.FMemo.Font.Color := clEditorFg;
    StyleMemo(d.FMemo);
    d.Start;
    d.ShowModal;
  finally
    d.Free;
  end;
end;

end.
