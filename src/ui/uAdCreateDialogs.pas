// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAdCreateDialogs;

{$mode objfpc}{$H+}

// Assistants Active Directory: nouvel utilisateur, ordinateur, groupe, unite d'organisation.
// L'objet part en un seul Add complet: le domaine prend tout ou rien, pas d'objet a moitie cree.
// Issue inconnue: champs geles, rien n'est renvoye tout seul. Un Add rejoue a l'aveugle
// finit tot ou tard en doublon, ou en incident.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, Dialogs, LCLType,
  uUiKit, uAppContext, uRtCombo, uRtCheck, uRtButton, uIcons, uUiInbox, uTaskTracker, uLdapEntry,
  uAdObjectPlan, uAdProtection, uTaskDialog;

type
  TAdCreateKind = (ackUser, ackComputer, ackGroup, ackOrgUnit);

  TAdCreateState = (
    acsEditing,
    acsSending,
    acsChecking,
    acsUnknown,
    acsCreated
  );

  TAdCheckMatch = (amUnknown, amCompatible, amDifferent);

  TAdCreateDialog = class(TTaskDialog)
  private
    FParentDn: string;
    FKind: TAdCreateKind;
    FPage: Integer;
    FPages: array[0..1] of TPanel;
    FBannerIcon: TRtIcon;
    FPathLabel, FDnLabel, FRightsNote: TLabel;
    FStepper: TRtStepper;
    FBack, FNext, FCancel, FEditAgain: TButton;
    FFirst, FInitials, FLast, FFull, FLogon, FSam, FPwd1, FPwd2: TEdit;
    FSuffix: TRtComboBox;
    FNetbiosLabel: TLabel;
    FMustChange, FNeverExpires, FDisabled: TRtCheckBox;
    FName, FObjSam: TEdit;
    FPreW2000: TRtCheckBox;
    FScope, FGroupType: TRtSegmented;
    FScopeNote: TLabel;
    FProtect: TRtCheckBox;
    FProtectJob: TDeletionProtectionJob;
    FFullEdited, FSamEdited, FUpdating: Boolean;
    FState: TAdCreateState;
    FOpNote: Boolean;
    // Une requete LDAP partie ne s'annule pas: une fois l'ecriture emise,
    // le bouton de fermeture cesse de s'appeler Cancel. Il mentirait.
    FSubmitted: Boolean;
    FDomainDns, FNetbios: string;
    FNetbiosRead: Boolean;
    FCreatedDn, FPendingDn: string;
    FNotAllowed: string;
    procedure BuildUi;
    procedure BuildUserPages;
    procedure BuildComputerPage;
    procedure BuildGroupPage;
    procedure BuildOuPage;
    procedure ProtectDone(Sender: TObject);
    function FieldRow(AParent: TWinControl; const ACaption: string): TPanel;
    function NewEdit(ARow: TPanel; APassword: Boolean = False): TEdit;
    procedure FieldChanged(Sender: TObject);
    procedure ScopeChanged(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
    procedure EditAgainClick(Sender: TObject);
    procedure ShowPage(AIndex: Integer);
    procedure StartDomainReads;
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure UpdateState;
    function UserInput: TAdUserInput;
    function ComputerInput: TAdComputerInput;
    function GroupInput: TAdGroupInput;
    function OuInput: TAdOuInput;
    function NeedsEncryption: Boolean;
    procedure Submit;
    procedure StartCheck;
    function MatchesRequest(AEntry: TLdapEntry): TAdCheckMatch;
    procedure WipePasswords;
  protected
    procedure ApplyShellColors; override;
    function HasRunningWork: Boolean; override;
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, AParentDn: string;
      AKind: TAdCreateKind);
    destructor Destroy; override;
    function Problem: string;
    function BuildEntry(out AError: string): TLdapEntry;
    procedure SetField(const AName, AValue: string);
    function FieldText(const AName: string): string;
    procedure SetOption(const AName: string; AValue: Boolean);
    procedure SetScope(AScope: TAdGroupScope; ASecurity: Boolean);
    procedure GoNext;
    procedure AbandonUnknown;
    function StatusText: string;
    function NextEnabled: Boolean;
    function NextCaption: string;
    function SuffixesText: string;
    property State: TAdCreateState read FState;
    property Page: Integer read FPage;
    property ProtectJob: TDeletionProtectionJob read FProtectJob;
    function RightsText: string;
    property CreatedDn: string read FCreatedDn;
    property DomainDns: string read FDomainDns;
    property Netbios: string read FNetbios;
  end;

function ShowAdCreateDialog(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, AParentDn: string;
  AKind: TAdCreateKind): string;

resourcestring
  rsAcUserTitle = 'New object - User';
  rsAcComputerTitle = 'New object - Computer';
  rsAcGroupTitle = 'New object - Group';
  rsAcOuTitle = 'New object - Organizational Unit';
  rsAcOuName = 'Name';
  rsAcProtect = 'Protect container from accidental deletion';
  rsAcProtectNote = 'As in the Active Directory console: Everyone is denied Delete and Delete subtree on ' +
    'the new container, and Delete all child objects on its parent (added only if missing). The parent ' +
    'rule blocks deleting every child of the parent, not only this one, and it stays if the protection ' +
    'is later removed. This is written after the creation; Active Directory has no atomic update of an ' +
    'access list, so each list is read just before being replaced, then read back.';
  rsAcProtecting = 'Created. Protecting the container from accidental deletion...';
  rsAcProtectIncomplete = 'The organizational unit was created, but its protection is not complete:';
  rsAcProtectNoId = 'The organizational unit was created, but its identity (objectGUID) could not be ' +
    'read back: the deletion protection was NOT applied (it could have targeted another object). Use ' +
    'Deletion protection... on it.';
  rsAcExistsUnprotected = 'It was not protected from accidental deletion: use Deletion protection... on it.';
  rsAcCreateIn = 'Create in:';
  rsAcFirst = 'First name';
  rsAcInitials = 'Initials';
  rsAcLast = 'Last name';
  rsAcFull = 'Full name';
  rsAcLogon = 'User logon name';
  rsAcSam = 'Pre-Windows 2000 logon name';
  rsAcPwd = 'Password';
  rsAcPwdConfirm = 'Confirm password';
  rsAcMustChange = 'User must change password at next logon';
  rsAcNeverExpires = 'Password never expires';
  rsAcDisabled = 'Account is disabled';
  rsAcPwdNote = 'The password travels once, encrypted, inside the creation request: the domain accepts ' +
    'the whole account (password policy included) or creates nothing.';
  rsAcComputerName = 'Computer name';
  rsAcComputerSam = 'Computer name (pre-Windows 2000)';
  rsAcPreW2000 = 'Assign this computer account as a pre-Windows 2000 computer';
  rsAcPreW2000Note = 'A pre-Windows 2000 computer gets its name in lower case as initial password. ' +
    'Joining the domain with this account requires the right to reset its password (by default, ' +
    'domain administrators).';
  rsAcGroupName = 'Group name';
  rsAcGroupSam = 'Group name (pre-Windows 2000)';
  rsAcScope = 'Group scope';
  rsAcType = 'Group type';
  rsAcDomainLocal = 'Domain local';
  rsAcGlobal = 'Global';
  rsAcUniversal = 'Universal';
  rsAcSecurity = 'Security';
  rsAcDistribution = 'Distribution';
  rsAcScopeLocal = 'Domain local: members from any domain of the forest; grants access to resources of this domain only.';
  rsAcScopeGlobal = 'Global: members from this domain only; usable in any domain of the forest.';
  rsAcScopeUniversal = 'Universal: members from any domain of the forest; usable in any domain of the forest.';
  rsAcTypeSecurity = 'Security groups can be given permissions; distribution groups only serve e-mail lists.';
  rsAcBack = '< Back';
  rsAcNext = 'Next >';
  rsAcCreate = 'Create';
  rsAcStepNames = 'Names';
  rsAcStepPassword = 'Password';
  rsAcReadOnly = 'This profile is read-only: nothing can be created.';
  rsAcNeedsTls = 'A password is sent only over an encrypted connection (LDAPS or StartTLS).';
  rsAcSending = 'Creating the object...';
  rsAcFailed = 'Not created: %s';
  rsAcUnknown = 'The outcome is unknown (%s): checking whether the object exists...';
  rsAcChecking = 'Checking whether an object exists at %s...';
  rsAcExists = 'An entry now exists at %s, but nothing proves it comes from this request (it may ' +
    'predate it or come from someone else). Check it in the tree; nothing is ever sent again from here.';
  rsAcExistsOther = 'An entry now exists at %s but it does not match this request (class or account ' +
    'name differ): this creation most likely was not applied. Check the tree.';
  rsAcNotThere = 'No entry is visible at this DN on this connection, but the outcome of the previous ' +
    'request is still unknown: it may still be applied, or appear after replication. Use Edit again ' +
    'to prepare a new attempt.';
  rsAcEditAgain = 'Edit again';
  rsAcAbandoned = 'Tracking abandoned: the previous request was NOT proven unapplied, the first ' +
    'object may still appear. Check the tree before creating again.';
  rsAcCheckFailed = 'The object could not be checked (%s): use Check to try the lookup again, or look ' +
    'for it in the tree.';
  rsAcSessionLost = 'The connection changed during the operation: its outcome is unknown. Use Check on ' +
    'the current connection, or look in the tree.';
  rsAcCheck = 'Check';
  rsAcDomainGuess = '(guessed from the DN)';
  rsAcNoRight = 'Your account has no right to create %s objects in this container (no delegation here): ' +
    'Active Directory will most likely refuse the creation.';
  rsAcNotAllowedHere = 'Active Directory does not allow %s objects under this %s object (the schema lists ' +
    'their possible parents). Choose another container.';
  rsAcNoRightComputer = 'Your account has no right to create computer objects in this container (no ' +
    'delegation here). Active Directory may still accept one through the quota "add workstations to the ' +
    'domain" (ms-DS-MachineAccountQuota), which allows only a few attributes.';

implementation

uses
  uTheme, uConnections, uDirectoryWorker, uLdapErrors, uChangeSet, uLdapFilter,
  uSearchModel, uRtBytes, uStrings, uAdAccountPlan, uDirectoryService, Math;

function ShowAdCreateDialog(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, AParentDn: string;
  AKind: TAdCreateKind): string;
var
  d: TAdCreateDialog;
begin
  d := TAdCreateDialog.CreateFor(AOwner, ACtx, AProfileUuid, AParentDn, AKind);
  try
    d.ShowModal;
    Result := d.CreatedDn;
  finally
    d.Free;
  end;
end;

// Le texte rendu par AEdit.Text est ecrase, mais le tampon interne du widgetset reste hors
// d'atteinte: y mettre '' le remplace sans garantie. Nos propres copies, elles, sont ecrasees.
procedure WipeEditText(AEdit: TEdit);
var
  s: string;
begin
  if AEdit = nil then Exit;
  s := AEdit.Text;
  if s <> '' then
  begin
    UniqueString(s);
    FillChar(s[1], Length(s), 0);
  end;
  AEdit.Text := '';
end;

constructor TAdCreateDialog.CreateFor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  AParentDn: string; AKind: TAdCreateKind);
var
  c: TDirectoryConnection;
  title: string;
begin
  case AKind of
    ackUser: title := rsAcUserTitle;
    ackComputer: title := rsAcComputerTitle;
    ackOrgUnit: title := rsAcOuTitle;
  else
    title := rsAcGroupTitle;
  end;
  inherited CreateDialog(AOwner, title, 700, 560);
  case AKind of
    ackUser: SetIcon('user');
    ackComputer: SetIcon('device-desktop');
    ackOrgUnit: SetIcon('folder');
  else
    SetIcon('users');
  end;
  InitTasks(ACtx, AProfileUuid);
  FParentDn := AParentDn;
  FKind := AKind;
  c := FCtx.Connections.Find(FProfileUuid);
  if c <> nil then SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
  FDomainDns := AdDomainDnsName(AParentDn);
  if DomainNamingContext(c) <> '' then
    FDomainDns := AdDomainDnsName(DomainNamingContext(c));
  FNetbios := UpperCase(Copy(FDomainDns, 1, Pos('.', FDomainDns + '.') - 1));
  Tasks.OnMessage := @TaskMessage;
  BuildUi;
  ApplyTheme;
  ShowPage(0);
  StartDomainReads;
end;

destructor TAdCreateDialog.Destroy;
begin
  FreeAndNil(FProtectJob);
  WipePasswords;
  inherited Destroy;
end;

function TAdCreateDialog.HasRunningWork: Boolean;
begin
  // Une requete emise ne s'annule pas: la fenetre attend le resultat terminal
  // (verification, protection) avant de se laisser fermer.
  Result := Tasks.Pending('check') or ((FProtectJob <> nil) and (FProtectJob.Outcome = poRunning));
end;

procedure TAdCreateDialog.WipePasswords;
begin
  WipeEditText(FPwd1);
  WipeEditText(FPwd2);
end;

function TAdCreateDialog.FieldRow(AParent: TWinControl; const ACaption: string): TPanel;
begin
  Result := MakeFieldRow(AParent, ACaption, 230);
end;

function TAdCreateDialog.NewEdit(ARow: TPanel; APassword: Boolean): TEdit;
begin
  Result := MakeEdit(ARow, alClient);
  if APassword then Result.PasswordChar := '*';
  Result.OnChange := @FieldChanged;
end;

procedure TAdCreateDialog.BuildUi;
var
  banner, txt: TPanel;
  lbl: TLabel;
begin
  banner := MakePanel(Body, alTop, 64);
  FBannerIcon := TRtIcon.Create(banner);
  FBannerIcon.Parent := banner;
  FBannerIcon.Align := alLeft;
  FBannerIcon.Width := 48;
  txt := MakePanel(banner, alClient);
  lbl := MakeLabel(txt, rsAcCreateIn, alTop);
  lbl.Font.Color := DialogStateColor(usMuted);
  FPathLabel := MakeLabel(txt, AdCanonicalPath(FParentDn), alTop);
  FPathLabel.Font.Style := [fsBold];
  FPathLabel.ShowAccelChar := False;
  FDnLabel := MakeLabel(txt, FParentDn, alTop);
  FDnLabel.ShowAccelChar := False;
  FDnLabel.Font.Color := DialogStateColor(usMuted);
  banner.Height := Max(FBannerIcon.Width, StackedLabelsHeight(txt) + 6);
  FRightsNote := MakeLabel(Body, '', alTop);
  FRightsNote.WordWrap := True;
  FRightsNote.Visible := False;
  FRightsNote.BorderSpacing.Top := 6;
  FStepper := TRtStepper.Create(Body);
  FStepper.Parent := Body;
  StackTop(FStepper);
  FStepper.Align := alTop;
  FStepper.BorderSpacing.Top := 8;
  FStepper.SetSteps([rsAcStepNames, rsAcStepPassword]);
  FStepper.Visible := FKind = ackUser;
  FStatus := MakeLabel(Body, '', alBottom);
  FStatus.WordWrap := True;
  FStatus.ShowAccelChar := False;
  FPages[0] := MakePanel(Body, alClient);
  FPages[0].BorderSpacing.Top := 6;
  FPages[1] := MakePanel(Body, alClient);
  FPages[1].BorderSpacing.Top := 6;
  case FKind of
    ackUser: BuildUserPages;
    ackComputer: BuildComputerPage;
    ackOrgUnit: BuildOuPage;
  else
    BuildGroupPage;
  end;
  FCancel := AddButton(rsCancel, mrCancel, False, True);
  FNext := AddButton(rsAcCreate, mrNone, True);
  FNext.OnClick := @NextClick;
  FBack := AddButton(rsAcBack, mrNone);
  FBack.OnClick := @BackClick;
  FEditAgain := AddButton(rsAcEditAgain, mrNone);
  FEditAgain.OnClick := @EditAgainClick;
  FEditAgain.Visible := False;
end;

procedure TAdCreateDialog.BuildUserPages;
var
  row: TPanel;
  lbl: TLabel;
begin
  row := FieldRow(FPages[0], rsAcFirst);
  FInitials := MakeEdit(row, alRight);
  FInitials.Width := 70;
  FInitials.OnChange := @FieldChanged;
  lbl := MakeLabel(row, rsAcInitials, alRight);
  lbl.BorderSpacing.Left := 10;
  FFirst := NewEdit(row);
  row := FieldRow(FPages[0], rsAcLast);
  FLast := NewEdit(row);
  row := FieldRow(FPages[0], rsAcFull);
  FFull := NewEdit(row);
  row := FieldRow(FPages[0], rsAcLogon);
  row.BorderSpacing.Top := 12;
  FSuffix := TRtComboBox.Create(row);
  FSuffix.Parent := row;
  FSuffix.Align := alRight;
  FSuffix.Width := 220;
  FSuffix.BorderSpacing.Left := 6;
  FSuffix.Items.Add('@' + FDomainDns);
  FSuffix.ItemIndex := 0;
  FSuffix.OnChange := @FieldChanged;
  FLogon := NewEdit(row);
  row := FieldRow(FPages[0], rsAcSam);
  FNetbiosLabel := MakeLabel(row, FNetbios + '\', alLeft);
  FNetbiosLabel.ShowAccelChar := False;
  FSam := NewEdit(row);
  row := FieldRow(FPages[1], rsAcPwd);
  FPwd1 := NewEdit(row, True);
  row := FieldRow(FPages[1], rsAcPwdConfirm);
  FPwd2 := NewEdit(row, True);
  FMustChange := MakeCheck(FPages[1], rsAcMustChange);
  FMustChange.BorderSpacing.Top := 10;
  FMustChange.Checked := True;
  FMustChange.OnChange := @FieldChanged;
  FNeverExpires := MakeCheck(FPages[1], rsAcNeverExpires);
  FNeverExpires.OnChange := @FieldChanged;
  FDisabled := MakeCheck(FPages[1], rsAcDisabled);
  FDisabled.OnChange := @FieldChanged;
  lbl := MakeLabel(FPages[1], rsAcPwdNote, alTop);
  lbl.WordWrap := True;
  lbl.BorderSpacing.Top := 12;
  lbl.Font.Color := DialogStateColor(usMuted);
end;

procedure TAdCreateDialog.BuildComputerPage;
var
  row: TPanel;
  lbl: TLabel;
begin
  row := FieldRow(FPages[0], rsAcComputerName);
  FName := NewEdit(row);
  row := FieldRow(FPages[0], rsAcComputerSam);
  FObjSam := NewEdit(row);
  FPreW2000 := MakeCheck(FPages[0], rsAcPreW2000);
  FPreW2000.BorderSpacing.Top := 10;
  FPreW2000.OnChange := @FieldChanged;
  lbl := MakeLabel(FPages[0], rsAcPreW2000Note, alTop);
  lbl.WordWrap := True;
  lbl.BorderSpacing.Top := 10;
  lbl.Font.Color := DialogStateColor(usMuted);
end;

procedure TAdCreateDialog.BuildGroupPage;
var
  row: TPanel;
  lbl: TLabel;
begin
  row := FieldRow(FPages[0], rsAcGroupName);
  FName := NewEdit(row);
  row := FieldRow(FPages[0], rsAcGroupSam);
  FObjSam := NewEdit(row);
  row := FieldRow(FPages[0], rsAcScope);
  row.BorderSpacing.Top := 12;
  FScope := TRtSegmented.Create(row);
  FScope.Parent := row;
  FScope.Align := alLeft;
  FScope.SetChoices([rsAcDomainLocal, rsAcGlobal, rsAcUniversal], Ord(agsGlobal));
  FScope.OnChange := @ScopeChanged;
  row := FieldRow(FPages[0], rsAcType);
  FGroupType := TRtSegmented.Create(row);
  FGroupType.Parent := row;
  FGroupType.Align := alLeft;
  FGroupType.SetChoices([rsAcSecurity, rsAcDistribution], 0);
  FGroupType.OnChange := @ScopeChanged;
  FScopeNote := MakeLabel(FPages[0], '', alTop);
  FScopeNote.WordWrap := True;
  FScopeNote.BorderSpacing.Top := 10;
  lbl := MakeLabel(FPages[0], rsAcTypeSecurity, alTop);
  lbl.WordWrap := True;
  lbl.Font.Color := DialogStateColor(usMuted);
end;

procedure TAdCreateDialog.BuildOuPage;
var
  row: TPanel;
  lbl: TLabel;
begin
  row := FieldRow(FPages[0], rsAcOuName);
  FName := NewEdit(row);
  FProtect := MakeCheck(FPages[0], rsAcProtect);
  FProtect.BorderSpacing.Top := 10;
  FProtect.Checked := True;
  FProtect.OnChange := @FieldChanged;
  lbl := MakeLabel(FPages[0], rsAcProtectNote, alTop);
  lbl.WordWrap := True;
  lbl.BorderSpacing.Top := 10;
  lbl.Font.Color := DialogStateColor(usMuted);
end;

procedure TAdCreateDialog.ApplyShellColors;
var
  sz: Integer;
begin
  inherited ApplyShellColors;
  case FKind of
    ackUser: FBannerIcon.SetIcon('user', 32, clAccent);
    ackComputer: FBannerIcon.SetIcon('device-desktop', 32, clAccent);
    ackOrgUnit: FBannerIcon.SetIcon('folder', 32, clAccent);
  else
    FBannerIcon.SetIcon('users', 32, clAccent);
  end;
  if FScopeNote <> nil then FScopeNote.Font.Color := DialogStateColor(usMuted);
  FStepper.Height := FStepper.PreferredHeight;
  sz := FontTextHeight(Font) + 12;
  if FScope <> nil then
  begin
    FScope.Width := FScope.PreferredWidth;
    FScope.BorderSpacing.Top := (FScope.Parent.ClientHeight - sz) div 2;
    FScope.BorderSpacing.Bottom := FScope.Parent.ClientHeight - sz - FScope.BorderSpacing.Top;
  end;
  if FGroupType <> nil then
  begin
    FGroupType.Width := FGroupType.PreferredWidth;
    FGroupType.BorderSpacing.Top := (FGroupType.Parent.ClientHeight - sz) div 2;
    FGroupType.BorderSpacing.Bottom := FGroupType.Parent.ClientHeight - sz - FGroupType.BorderSpacing.Top;
  end;
  UpdateState;
end;

procedure TAdCreateDialog.ShowPage(AIndex: Integer);
var
  pages: Integer;
begin
  FPage := AIndex;
  FPages[0].Visible := AIndex = 0;
  FPages[1].Visible := AIndex = 1;
  if FKind = ackUser then pages := 2 else pages := 1;
  FBack.Visible := pages > 1;
  FStepper.Current := AIndex;
  UpdateState;
  if not Showing then Exit;
  case FKind of
    ackUser: if AIndex = 0 then FFirst.SetFocus else FPwd1.SetFocus;
  else
    FName.SetFocus;
  end;
end;

procedure TAdCreateDialog.FieldChanged(Sender: TObject);
var
  sam: string;
begin
  if FUpdating then Exit;
  FOpNote := False;
  FUpdating := True;
  try
    if Sender = FFull then FFullEdited := True;
    if (Sender = FSam) or (Sender = FObjSam) then FSamEdited := True;
    if (FKind = ackUser) and not FFullEdited and
       ((Sender = FFirst) or (Sender = FInitials) or (Sender = FLast)) then
      FFull.Text := AdDefaultFullName(FFirst.Text, FInitials.Text, FLast.Text);
    if not FSamEdited then
      case FKind of
        ackUser:
          if Sender = FLogon then FSam.Text := AdSamFromName(FLogon.Text, AD_SAM_USER_MAX);
        ackComputer:
          if Sender = FName then FObjSam.Text := AdComputerSamFromName(FName.Text);
        ackGroup:
          if Sender = FName then FObjSam.Text := AdSamFromName(FName.Text, AD_SAM_GROUP_MAX);
      end;
    // Nom NetBIOS d'un ordinateur en majuscules, comme le poste se presentera de toute facon.
    if (FKind = ackComputer) and (Sender = FObjSam) then
    begin
      sam := UpperCase(FObjSam.Text);
      if sam <> FObjSam.Text then
      begin
        FObjSam.Text := sam;
        FObjSam.SelStart := Length(sam);
      end;
    end;
  finally
    FUpdating := False;
  end;
  UpdateState;
end;

procedure TAdCreateDialog.ScopeChanged(Sender: TObject);
begin
  UpdateState;
end;

function TAdCreateDialog.UserInput: TAdUserInput;
begin
  Result := Default(TAdUserInput);
  if FKind <> ackUser then Exit;
  Result.FirstName := FFirst.Text;
  Result.Initials := FInitials.Text;
  Result.LastName := FLast.Text;
  Result.FullName := FFull.Text;
  Result.LogonName := FLogon.Text;
  Result.UpnSuffix := Copy(FSuffix.Text, 2, MaxInt);
  Result.SamName := FSam.Text;
  Result.Password := RawByteString(FPwd1.Text);
  Result.Confirm := RawByteString(FPwd2.Text);
  Result.MustChange := FMustChange.Checked;
  Result.NeverExpires := FNeverExpires.Checked;
  Result.Disabled := FDisabled.Checked;
end;

function TAdCreateDialog.ComputerInput: TAdComputerInput;
begin
  Result := Default(TAdComputerInput);
  if FKind <> ackComputer then Exit;
  Result.Name := FName.Text;
  Result.SamName := FObjSam.Text;
  Result.PreWindows2000 := FPreW2000.Checked;
end;

function TAdCreateDialog.GroupInput: TAdGroupInput;
begin
  Result := Default(TAdGroupInput);
  if FKind <> ackGroup then Exit;
  Result.Name := FName.Text;
  Result.SamName := FObjSam.Text;
  Result.Scope := TAdGroupScope(Max(0, FScope.ItemIndex));
  Result.Security := FGroupType.ItemIndex = 0;
end;

function TAdCreateDialog.OuInput: TAdOuInput;
begin
  Result := Default(TAdOuInput);
  if FKind <> ackOrgUnit then Exit;
  Result.Name := FName.Text;
end;

function TAdCreateDialog.NeedsEncryption: Boolean;
begin
  Result := (FKind = ackUser) or ((FKind = ackComputer) and FPreW2000.Checked);
end;

function TAdCreateDialog.Problem: string;
var
  u: TAdUserInput;
begin
  case FKind of
    ackUser:
      begin
        u := UserInput;
        try
          if FPage = 0 then
          begin
            u.Password := 'x';
            u.Confirm := 'x';
            u.MustChange := False;
          end;
          Result := AdUserProblem(u);
        finally
          if u.Password <> '' then FillChar(u.Password[1], Length(u.Password), 0);
          if u.Confirm <> '' then FillChar(u.Confirm[1], Length(u.Confirm), 0);
        end;
      end;
    ackComputer: Result := AdComputerProblem(ComputerInput);
    ackOrgUnit: Result := AdOuProblem(OuInput);
  else
    Result := AdGroupProblem(GroupInput);
  end;
end;

function TAdCreateDialog.BuildEntry(out AError: string): TLdapEntry;
var
  u: TAdUserInput;
begin
  case FKind of
    ackUser:
      begin
        u := UserInput;
        try
          Result := BuildAdUserEntry(FParentDn, u, AError);
        finally
          if u.Password <> '' then FillChar(u.Password[1], Length(u.Password), 0);
          if u.Confirm <> '' then FillChar(u.Confirm[1], Length(u.Confirm), 0);
        end;
      end;
    ackComputer: Result := BuildAdComputerEntry(FParentDn, ComputerInput, AError);
    ackOrgUnit: Result := BuildAdOuEntry(FParentDn, OuInput, AError);
  else
    Result := BuildAdGroupEntry(FParentDn, GroupInput, AError);
  end;
end;

procedure TAdCreateDialog.UpdateState;
var
  c: TDirectoryConnection;
  p: string;
  busy: Boolean;
begin
  if FNext = nil then Exit;
  c := Conn;
  busy := (FState in [acsSending, acsChecking]) or
    ((FProtectJob <> nil) and (FProtectJob.Outcome = poRunning));
  if FScopeNote <> nil then
    case TAdGroupScope(Max(0, FScope.ItemIndex)) of
      agsDomainLocal: FScopeNote.Caption := rsAcScopeLocal;
      agsGlobal: FScopeNote.Caption := rsAcScopeGlobal;
    else
      FScopeNote.Caption := rsAcScopeUniversal;
    end;
  if FNetbiosLabel <> nil then FNetbiosLabel.Caption := FNetbios + '\';
  // Champs geles des qu'une ecriture est partie. Une saisie valide ne dit rien de l'issue
  // d'une operation, et ne reactive jamais l'envoi.
  FPages[0].Enabled := FState = acsEditing;
  FPages[1].Enabled := FState = acsEditing;
  FBack.Enabled := (FPage > 0) and (FState = acsEditing);
  if FSubmitted then FCancel.Caption := rsClose;
  FEditAgain.Visible := FState = acsUnknown;
  if FState = acsUnknown then FNext.Caption := rsAcCheck
  else if (FKind = ackUser) and (FPage = 0) then FNext.Caption := rsAcNext
  else FNext.Caption := rsAcCreate;
  if busy or (FState = acsCreated) then
  begin
    FNext.Enabled := False;
    Exit;
  end;
  if FState = acsUnknown then
  begin
    FNext.Enabled := c <> nil;
    Exit;
  end;
  if c = nil then
  begin
    SetStatus(rsTdNotConnected, usError);
    FNext.Enabled := False;
    Exit;
  end;
  if c.Profile.ReadOnly then
  begin
    SetStatus(rsAcReadOnly, usWarning);
    FNext.Enabled := False;
    Exit;
  end;
  if FNotAllowed <> '' then
  begin
    FNext.Enabled := False;
    SetStatus('', usMuted);
    Exit;
  end;
  p := Problem;
  if (p = '') and NeedsEncryption and ((FKind <> ackUser) or (FPage = 1)) and
     not c.SecretsSafe then
    p := rsAcNeedsTls;
  FNext.Enabled := p = '';
  if FOpNote then Exit;
  if (FStatus.Font.Color <> DialogStateColor(usError)) or (p <> '') then
    SetStatus(p, usMuted);
end;

procedure TAdCreateDialog.NextClick(Sender: TObject);
begin
  GoNext;
end;

procedure TAdCreateDialog.BackClick(Sender: TObject);
begin
  if FPage > 0 then ShowPage(FPage - 1);
end;

procedure TAdCreateDialog.EditAgainClick(Sender: TObject);
begin
  AbandonUnknown;
end;

procedure TAdCreateDialog.AbandonUnknown;
begin
  if FState <> acsUnknown then Exit;
  // Retour a l'edition sur decision explicite seulement. L'issue du premier envoi
  // reste inconnue, l'avertissement le dit et ne s'en va pas.
  FState := acsEditing;
  FOpNote := True;
  SetStatus(rsAcAbandoned, usWarning);
  UpdateState;
end;

procedure TAdCreateDialog.GoNext;
begin
  UpdateState;
  if not FNext.Enabled then Exit;
  // Issue inconnue: le meme bouton verifie le DN, jamais un nouvel Add.
  if FState = acsUnknown then
  begin
    SetStatus(Format(rsAcChecking, [FPendingDn]), usMuted);
    StartCheck;
    Exit;
  end;
  if (FKind = ackUser) and (FPage = 0) then
    ShowPage(1)
  else
    Submit;
end;

function HasValue(A: TLdapAttribute; const AValue: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to A.ValueCount - 1 do
    if SameText(string(A.Values[i]), AValue) then Exit(True);
  Result := False;
end;

procedure TAdCreateDialog.Submit;
var
  e: TLdapEntry;
  change: TLdapChange;
  err, reason, note: string;
  i: Integer;
begin
  if Conn = nil then Exit;
  e := BuildEntry(err);
  if e = nil then
  begin
    SetStatus(err, usError);
    Exit;
  end;
  // Attributs sensibles selon la politique courante: ecrases a la liberation de l'entree
  // (unicodePwd est deja marque par le plan).
  for i := 0 to e.AttrCount - 1 do
    if FCtx.Sensitive.IsSensitive(e.Attrs[i].Description) then
      e.Attrs[i].Sensitive := True;
  change := NewChange(ckAdd, e.Dn);
  change.Entry.Free;
  change.Entry := e;
  // Apercu habituel, secrets masques; la session doit etre la meme en sortie qu'en entree.
  note := '';
  if (FKind = ackOrgUnit) and FProtect.Checked then note := rsAcProtectNote;
  FPendingDn := change.Dn;
  if SubmitWrite(Self, FCtx, Tasks, 'write', change, '', reason, note) = 0 then
  begin
    if reason <> '' then
    begin
      SetStatus(reason, usWarning);
      FOpNote := True;
    end;
  end
  else
  begin
    FState := acsSending;
    FSubmitted := True;
    SetStatus(rsAcSending, usMuted);
  end;
  UpdateState;
end;

procedure TAdCreateDialog.StartCheck;
begin
  if Conn = nil then
  begin
    FState := acsUnknown;
    UpdateState;
    Exit;
  end;
  if Tasks.ReadEntry('check', FPendingDn, ['objectClass', 'objectGUID', 'sAMAccountName']) = 0 then
    FState := acsUnknown
  else
    FState := acsChecking;
  UpdateState;
end;

// Une entree presente au DN ne prouve pas que l'Add ambigu a reussi: elle pouvait
// preexister ou venir d'un collegue zele. Seule une incompatibilite se demontre.
function TAdCreateDialog.MatchesRequest(AEntry: TLdapEntry): TAdCheckMatch;
var
  a: TLdapAttribute;
  cls, sam: string;
begin
  Result := amUnknown;
  case FKind of
    ackUser: cls := 'user';
    ackComputer: cls := 'computer';
    ackOrgUnit: cls := 'organizationalUnit';
  else
    cls := 'group';
  end;
  a := AEntry.Find('objectClass');
  if (a <> nil) and (a.ValueCount > 0) and not a.Truncated then
  begin
    if not HasValue(a, cls) then Exit(amDifferent);
    Result := amCompatible;
  end;
  sam := '';
  case FKind of
    ackUser: sam := Trim(FSam.Text);
    ackComputer: sam := UpperCase(Trim(FObjSam.Text)) + '$';
    ackGroup: sam := Trim(FObjSam.Text);
  end;
  a := AEntry.Find('sAMAccountName');
  if (sam <> '') and (a <> nil) and (a.ValueCount > 0) and
     not SameText(string(a.Values[0]), sam) then
    Result := amDifferent;
end;

procedure TAdCreateDialog.StartDomainReads;
var
  c: TDirectoryConnection;
  config, defaultNc: string;
  req: TSearchRequest;
  f: TFilterNode;
begin
  c := Conn;
  if c = nil then Exit;
  Tasks.ReadEntry('rights', FParentDn,
    ['objectClass', 'allowedChildClasses', 'allowedChildClassesEffective']);
  if c.RootDse = nil then Exit;
  config := string(c.RootDse.FirstValue('configurationNamingContext', ''));
  defaultNc := DomainNamingContext(c);
  if config = '' then Exit;
  if FKind = ackUser then
    Tasks.ReadEntry('upn', 'CN=Partitions,' + config, ['uPNSuffixes']);
  if (FKind = ackUser) and (defaultNc <> '') then
  begin
    req := DefaultSearchRequest;
    req.BaseDn := 'CN=Partitions,' + config;
    req.Scope := ssOneLevel;
    f := FltAnd([FltEq('objectClass', 'crossRef'), FltEq('nCName', RawByteString(defaultNc))]);
    try
      req.Filter := FilterToString(f);
    finally
      f.Free;
    end;
    SetLength(req.Attributes, 1);
    req.Attributes[0] := 'nETBIOSName';
    req.SizeLimit := 10;
    Tasks.Search('netbios', req);
  end;
end;

procedure TAdCreateDialog.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask;
  AEnding: TTaskEnding);
var
  a: TLdapAttribute;
  i: Integer;
  m: TEntriesMsg;
  w: TWriteMsg;
  e: TEntryMsg;
  nb: string;
  guid: RawByteString;
begin
  if AEnding = teStale then
  begin
    // Session fermee ou remplacee pendant l'Add ou sa verification: issue inconnue
    // durable, champs geles, rien de rejouable.
    if (ATask.Tag = 'write') or (ATask.Tag = 'check') then
    begin
      FState := acsUnknown;
      SetStatus(rsAcSessionLost, usWarning);
    end;
    UpdateState;
    Exit;
  end;
  if ATask.Tag = 'rights' then
  begin
    if (AMsg is TEntryMsg) and (TEntryMsg(AMsg).Entry <> nil) then
    begin
      e := TEntryMsg(AMsg);
      case FKind of
        ackUser: nb := 'user';
        ackComputer: nb := 'computer';
        ackOrgUnit: nb := 'organizationalUnit';
      else
        nb := 'group';
      end;
      // Liste partielle (budget atteint, decodage interrompu): une absence n'y prouve rien.
      // On ne conclut pas, on ne bloque pas, le serveur tranchera.
      a := e.Entry.Find('allowedChildClasses');
      if (a <> nil) and not a.Truncated and not e.Entry.DecodeIncomplete and
         not HasValue(a, nb) then
      begin
        a := e.Entry.Find('objectClass');
        if (a <> nil) and (a.ValueCount > 0) then
          FNotAllowed := Format(rsAcNotAllowedHere, [nb, string(a.Values[a.ValueCount - 1])])
        else
          FNotAllowed := Format(rsAcNotAllowedHere, [nb, '?']);
        FRightsNote.Caption := FNotAllowed;
        FRightsNote.Font.Color := DialogStateColor(usError);
        FRightsNote.Visible := True;
        UpdateState;
        Exit;
      end;
      a := e.Entry.Find('allowedChildClassesEffective');
      if (a <> nil) and not a.Truncated and not e.Entry.DecodeIncomplete then
      begin
        FRightsNote.Visible := not HasValue(a, nb);
        if FKind = ackComputer then FRightsNote.Caption := rsAcNoRightComputer
        else FRightsNote.Caption := Format(rsAcNoRight, [nb]);
        FRightsNote.Font.Color := DialogStateColor(usWarning);
      end;
    end;
    Exit;
  end;
  if ATask.Tag = 'upn' then
  begin
    if (AMsg is TEntryMsg) and (TEntryMsg(AMsg).Entry <> nil) then
    begin
      a := TEntryMsg(AMsg).Entry.Find('uPNSuffixes');
      if a <> nil then
        for i := 0 to a.ValueCount - 1 do
          if FSuffix.Items.IndexOf('@' + string(a.Values[i])) < 0 then
            FSuffix.Items.Add('@' + string(a.Values[i]));
    end;
    Exit;
  end;
  if ATask.Tag = 'netbios' then
  begin
    if AMsg is TEntriesMsg then
    begin
      m := TEntriesMsg(AMsg);
      for i := 0 to m.Entries.Count - 1 do
      begin
        nb := string(TLdapEntry(m.Entries[i]).FirstValue('nETBIOSName', ''));
        if nb <> '' then
        begin
          FNetbios := nb;
          FNetbiosRead := True;
        end;
      end;
    end;
    UpdateState;
    Exit;
  end;
  if ATask.Tag = 'write' then
  begin
    if AMsg is TTaskFailedMsg then
    begin
      SetStatus(Format(rsAcUnknown, [TTaskFailedMsg(AMsg).Text]), usWarning);
      StartCheck;
      Exit;
    end
    else if AMsg is TWriteMsg then
    begin
      w := TWriteMsg(AMsg);
      if w.Result.Ok then
      begin
        FState := acsCreated;
        FCreatedDn := FPendingDn;
        WipePasswords;
        if (FKind = ackOrgUnit) and FProtect.Checked then
        begin
          // Identite relue avec l'Add: la protection exige ce GUID avant de remplacer la DACL,
          // l'objet au DN n'est peut-etre deja plus le notre. Sans identite, rien n'est ecrit.
          guid := '';
          if w.Reread <> nil then guid := UsableObjectGuid(w.Reread);
          if guid = '' then
          begin
            SetStatus(rsAcProtectNoId, usWarning);
            UpdateState;
            Exit;
          end;
          FProtectJob := TDeletionProtectionJob.Create(FCtx, FProfileUuid, FCreatedDn, True);
          FProtectJob.OnDone := @ProtectDone;
          SetStatus(rsAcProtecting, usMuted);
          FProtectJob.Start(False, guid, '');
          UpdateState;
          Exit;
        end;
        UpdateState;
        ModalResult := mrOk;
        Exit;
      end;
      if w.Result.Error.Category = lecUnknownOutcome then
      begin
        // Jamais rejoue: une lecture dit ce qui existe au DN.
        SetStatus(Format(rsAcUnknown, [ErrorToText(w.Result.Error)]), usWarning);
        StartCheck;
        Exit;
      end;
      FState := acsEditing;
      FOpNote := True;
      SetStatus(Format(rsAcFailed, [ErrorToText(w.Result.Error)]), usError);
    end;
    UpdateState;
    Exit;
  end;
  if ATask.Tag = 'check' then
  begin
    if (AMsg is TEntryMsg) then
    begin
      e := TEntryMsg(AMsg);
      if e.Entry <> nil then
      begin
        // Une entree est la, mais rien ne la rattache a cette requete: etat inconnu, jamais
        // Created, et pas de nouvel envoi sur un DN occupe.
        FState := acsUnknown;
        if MatchesRequest(e.Entry) = amDifferent then
          SetStatus(Format(rsAcExistsOther, [FPendingDn]), usWarning)
        else if (FKind = ackOrgUnit) and FProtect.Checked then
          SetStatus(Format(rsAcExists, [FPendingDn]) + ' ' + rsAcExistsUnprotected, usWarning)
        else
          SetStatus(Format(rsAcExists, [FPendingDn]), usWarning);
      end
      else if e.Error.Category = lecNoSuchObject then
      begin
        // Une absence observee (autre controleur, replication en retard) ne prouve pas que
        // le premier Add ne tombera jamais. Etat inconnu; seul Edit again rouvre la saisie.
        FState := acsUnknown;
        SetStatus(rsAcNotThere, usWarning);
      end
      else
      begin
        FState := acsUnknown;
        SetStatus(Format(rsAcCheckFailed, [ErrorToText(e.Error)]), usError);
      end;
    end
    else if AMsg is TTaskFailedMsg then
    begin
      FState := acsUnknown;
      SetStatus(Format(rsAcCheckFailed, [TTaskFailedMsg(AMsg).Text]), usError);
    end;
    UpdateState;
  end;
end;

procedure TAdCreateDialog.ProtectDone(Sender: TObject);
begin
  if FProtectJob.Outcome = poOk then
  begin
    UpdateState;
    ModalResult := mrOk;
    Exit;
  end;
  SetStatus(rsAcProtectIncomplete + LineEnding + FProtectJob.ReportText, usWarning);
  UpdateState;
end;

procedure TAdCreateDialog.SetField(const AName, AValue: string);
var
  e: TEdit;
begin
  e := nil;
  if AName = 'first' then e := FFirst
  else if AName = 'initials' then e := FInitials
  else if AName = 'last' then e := FLast
  else if AName = 'full' then e := FFull
  else if AName = 'logon' then e := FLogon
  else if AName = 'sam' then
  begin
    if FKind = ackUser then e := FSam else e := FObjSam;
  end
  else if AName = 'password' then e := FPwd1
  else if AName = 'confirm' then e := FPwd2
  else if AName = 'name' then e := FName;
  if e = nil then Exit;
  e.Text := AValue;
  // Sans fenetre affichee, la LCL ne garantit pas OnChange: on l'appelle a la main.
  FieldChanged(e);
end;

function TAdCreateDialog.FieldText(const AName: string): string;
begin
  Result := '';
  if AName = 'full' then Result := FFull.Text
  else if AName = 'sam' then
  begin
    if FKind = ackUser then Result := FSam.Text else Result := FObjSam.Text;
  end
  else if AName = 'netbios' then Result := FNetbios
  else if AName = 'suffix' then Result := FSuffix.Text;
end;

procedure TAdCreateDialog.SetOption(const AName: string; AValue: Boolean);
begin
  if AName = 'mustchange' then FMustChange.Checked := AValue
  else if AName = 'neverexpires' then FNeverExpires.Checked := AValue
  else if AName = 'disabled' then FDisabled.Checked := AValue
  else if AName = 'prewin2000' then FPreW2000.Checked := AValue
  else if AName = 'protect' then FProtect.Checked := AValue;
  UpdateState;
end;

procedure TAdCreateDialog.SetScope(AScope: TAdGroupScope; ASecurity: Boolean);
begin
  FScope.ItemIndex := Ord(AScope);
  if ASecurity then FGroupType.ItemIndex := 0 else FGroupType.ItemIndex := 1;
  UpdateState;
end;

function TAdCreateDialog.RightsText: string;
begin
  if FRightsNote.Visible then Result := FRightsNote.Caption else Result := '';
end;

function TAdCreateDialog.StatusText: string;
begin
  Result := FStatus.Caption;
end;

function TAdCreateDialog.NextEnabled: Boolean;
begin
  Result := FNext.Enabled;
end;

function TAdCreateDialog.NextCaption: string;
begin
  Result := FNext.Caption;
end;

function TAdCreateDialog.SuffixesText: string;
begin
  Result := FSuffix.Items.CommaText;
end;

end.
