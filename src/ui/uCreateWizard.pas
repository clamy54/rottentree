// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCreateWizard;

{$mode objfpc}{$H+}

// Assistant de creation d'entrees: classes, nommage, attributs, apercu, execution. Rien ne part
// avant la confirmation de l'apercu, et seulement dans la session et le schema qui l'ont valide.
// Un compte AD nait desactive: mot de passe puis activation viennent apres, chacun precede
// d'une relecture de l'objectGUID. Une issue inconnue n'est jamais rejouee.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Grids, Dialogs, Graphics, LCLType, Menus,
  uAppContext, uUiKit, uRtList, uRtCombo, uRtCheck, uEntryCreationPlan, uLdapEntry, uUiInbox, uIcons,
  uNextId, uRtButton, uTaskTracker, uTaskDialog;

type
  TWizardPage = (wpStructural, wpAuxiliary, wpNaming, wpAttributes, wpPreview, wpResult);

  TWizRow = record
    Attr: string;
    Text: string;
    Bytes: RawByteString;
    FromFile: Boolean;
    Locked: Boolean;
    Note: string;
  end;

  TReadPurpose = (rpNone, rpExists, rpPassword, rpEnable, rpReconcile);

  TCreateWizard = class(TTaskDialog)
  private
    FPlan: TEntryCreationPlan;
    FAnalysis: TClassAnalysis;
    FPage: TWizardPage;
    FPanels: array[TWizardPage] of TPanel;
    FStepLabel: TLabel;
    FStepper: TRtStepper;
    FNotice: TLabel;
    FBack, FNext: TButton;
    FStructFilter, FAuxFilter: TEdit;
    FStructList, FAuxList: TRtListGrid;
    FStructInfo, FAuxInfo: TMemo;
    FStructChosenLabel, FAuxChosenLabel: TLabel;
    FStructChosen: string;
    FAuxChosen: TStringList;
    FRdnAttr, FRdnAttr2: TRtComboBox;
    FRdnValue, FRdnValue2: TEdit;
    FDnPreview: TLabel;
    FGrid: TStringGrid;
    FOptional: TRtComboBox;
    FRows: array of TWizRow;
    FRowsGen: Int64;
    FEncodeIssues: TPlanIssues;
    FFileTask: Int64;
    FFileRow: Integer;
    FFileGen: Int64;
    FFileAttr: string;
    FFileText: string;
    FRowMenu: TPopupMenu;
    FMenuRow: Integer;
    FAttrNote: TLabel;
    FSecretsNote: TLabel;
    FIdScan: TNextIdScan;
    FIdRow: Integer;
    FIdGen: Int64;
    FIdAttr: string;
    FIdBase: string;
    FPreview: TMemo;
    FExistsLabel: TLabel;
    FEntry: TLdapEntry;
    FPreviewIssues: TPlanIssues;
    FSteps: TRtListGrid;
    FResultNote: TLabel;
    FPwdPanel: TPanel;
    FPwd1, FPwd2: TEdit;
    FMustChange: TRtCheckBox;
    FPwdButton, FEnableButton, FCheckButton, FAcceptButton: TButton;
    FWriteStep: TCreationStepKind;
    FReadPurpose: TReadPurpose;
    FCreatedDn: string;
    FIdentity: RawByteString;
    FReconcileFound: Boolean;
    FReconcileGuid: RawByteString;
    procedure BuildUi;
    procedure ShowPage(APage: TWizardPage);
    procedure NextClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
    procedure StructFilterChange(Sender: TObject);
    procedure AuxFilterChange(Sender: TObject);
    procedure FillStructList;
    procedure FillAuxList;
    function ClassDescription(const AClass, AFilter: string): string;
    procedure UpdateChosenLabels;
    procedure StructSelect(Sender: TObject; AIndex: Integer);
    procedure AuxSelect(Sender: TObject; AIndex: Integer);
    procedure AuxActivate(Sender: TObject; AIndex: Integer);
    procedure AuxKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    function AuxCellIcon(Sender: TObject; AIndex, ACol: Integer; out AColor: TColor): string;
    procedure DescribeClass(AInfo: TMemo; const AName: string);
    function EnterAuxiliary: Boolean;
    function EnterNaming: Boolean;
    procedure FillRdnChoices;
    procedure NamingChange(Sender: TObject);
    function ReadNaming: Boolean;
    procedure EnterAttributes;
    procedure RefreshGrid;
    procedure CommitGrid;
    function RowOfGrid(ARow: Integer): Integer;
    procedure GridSelectEditor(Sender: TObject; aCol, aRow: Integer; var Editor: TWinControl);
    procedure AddOptionalClick(Sender: TObject);
    procedure AddValueClick(Sender: TObject);
    procedure RemoveValueClick(Sender: TObject);
    procedure LoadFileClick(Sender: TObject);
    procedure GridMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure EditorContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure BuildRowMenu(ARow: Integer);
    procedure NextIdMenuClick(Sender: TObject);
    procedure SecretMenuClick(Sender: TObject);
    procedure GridDblClick(Sender: TObject);
    function IsSecretRow(ARow: Integer): Boolean;
    function SecretsAllowed: Boolean;
    procedure SetSecret(ARow: Integer);
    procedure StartNextId(ARow: Integer);
    procedure HandleIdResult(AMsg: TUiMessage);
    procedure DropNextId;
    procedure EnterPreview;
    procedure StartExistsCheck;
    function CheckIdentityOfSession(out AReason: string): Boolean;
    procedure SubmitAdd;
    procedure RefreshSteps;
    function StepCellIcon(Sender: TObject; AIndex, ACol: Integer; out AColor: TColor): string;
    procedure SetStep(AKind: TCreationStepKind; AOutcome: TStepOutcome; const ADetail: string);
    procedure PasswordClick(Sender: TObject);
    procedure EnableClick(Sender: TObject);
    procedure CheckClick(Sender: TObject);
    procedure AcceptClick(Sender: TObject);
    procedure StartRead(APurpose: TReadPurpose; const AAttrs: array of string);
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure LocalMessage(AMsg: TUiMessage);
    procedure HandleWriteResult(AMsg: TUiMessage);
    procedure HandleReadResult(AMsg: TUiMessage);
    procedure ContinuePassword(AEntry: TLdapEntry);
    procedure ContinueEnable(AEntry: TLdapEntry);
    function IdentityMatches(AEntry: TLdapEntry; out AReason: string): Boolean;
    procedure UpdateButtons;
  protected
    // Ecriture en vol: fermer reste possible apres confirmation, l'issue sera soldee au journal.
    // Elle ne s'annule pas pour autant.
    function AllowCloseDuringWrite: Boolean; override;
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
      AParentDn: string);
    destructor Destroy; override;
    function GoNext: Boolean;
    procedure GoBack;
    procedure ChooseStructural(const AName: string);
    procedure ToggleAuxiliary(const AName: string);
    procedure SetStructuralFilter(const AText: string);
    procedure SetAuxiliaryFilter(const AText: string);
    function StructuralChoice: string;
    function AuxiliaryChoice: string;
    function ClassListText(AAuxiliary: Boolean): string;
    procedure SetNaming(const AAttr, AValue: string);
    procedure SetValueText(const AAttr, AText: string);
    function PreviewText: string;
    function StepOutcome(AKind: TCreationStepKind): TStepOutcome;
    property Page: TWizardPage read FPage;
    property Plan: TEntryCreationPlan read FPlan;
    property CreatedDn: string read FCreatedDn;
    property PreviewIssues: TPlanIssues read FPreviewIssues;
    function ExistsText: string;
    procedure StartPasswordStep;
    procedure StartEnableStep;
    procedure StartReconcile;
    procedure AcceptReconciled;
    function ResultText: string;
    function CreateEnabled: Boolean;
    property PasswordEdit: TEdit read FPwd1;
    property PasswordConfirmEdit: TEdit read FPwd2;
    procedure SimulateFileLoad(const AAttr: string; ATaskId: Int64);
    procedure RemoveValueOf(const AAttr: string);
    function RowMenuText(const AAttr: string): string;
    procedure FindNextIdFor(const AAttr: string);
    procedure SetSecretFor(const AAttr: string);
    procedure AddOptional(const AAttr: string);
    function OptionalAttributes: string;
    function ValueTextOf(const AAttr: string): string;
    function AttributeNote: string;
    function FileBytesOf(const AAttr: string): Integer;
    procedure TypeValueText(const AAttr, AText: string);
    property FileTask: Int64 read FFileTask;
  end;

resourcestring
  rsCwTitle = 'New entry';
  rsCwStep = 'Step %d of %d: %s';
  rsCwPageStructural = 'structural class';
  rsCwPageAuxiliary = 'auxiliary classes';
  rsCwStructuralHelp = 'Choose what the entry is: one structural class (person, inetOrgPerson, ' +
    'organizationalUnit, groupOfNames...). Auxiliary classes come at the next step.';
  rsCwAuxiliaryHelp = 'Optional: add auxiliary classes that bring more attributes (posixAccount, ' +
    'shadowAccount...). Double click, Enter or Space adds or removes a class.';
  rsCwChosenStructural = 'Chosen: %s';
  rsCwChosenNone = 'Chosen: none yet';
  rsCwChosenAux = 'Structural class: %s. Added: %s';
  rsCwChosenAuxNone = 'none (optional)';
  rsCwPageNaming = 'name';
  rsCwPageAttributes = 'attributes';
  rsCwPagePreview = 'preview';
  rsCwPageResult = 'creation';
  rsCwParent = 'Parent: %s';
  rsCwCreateUnder = 'Create under:';
  rsCwSearchShort = 'Search';
  rsCwSearchHint = 'name, alias, OID or description; or part of an attribute name';
  rsCwStepClass = 'Class';
  rsCwStepAux = 'Auxiliary';
  rsCwStepName = 'Name';
  rsCwStepAttrs = 'Attributes';
  rsCwStepPreview = 'Preview';
  rsCwStepCreate = 'Creation';
  rsCwAttrRequired = '%s required';
  rsCwAttrAllowed = '%s allowed';
  rsCwAttrMore = '%s and %d more';
  rsCwColClass = 'Class';
  rsCwColOid = 'OID';
  rsCwColDesc = 'Description';
  rsCwColUse = 'Use';
  rsCwKindStructural = 'Kind: structural';
  rsCwKindAuxiliary = 'Kind: auxiliary';
  rsCwInherits = 'Inherits: %s';
  rsCwMust = 'Required: %s';
  rsCwMay = 'Allowed: %s';
  rsCwGenerated = 'Set by the server: %s';
  rsCwNamingAttr = 'Naming attribute';
  rsCwNamingValue = 'Value';
  rsCwNamingSecond = 'Second naming attribute (optional)';
  rsCwNone = '(none)';
  rsCwDn = 'DN: %s';
  rsCwColAttr = 'Attribute';
  rsCwColValue = 'Value';
  rsCwColRequirement = 'Requirement';
  rsCwColType = 'Type';
  rsCwReqMust = 'required by %s';
  rsCwReqMay = 'optional (%s)';
  rsCwReqName = 'from the name';
  rsCwReqGenerated = 'set by the server: %s';
  rsCwReqServerOnly = 'required by %s, set by the server only';
  rsCwFromFile = '[%d bytes from a file]';
  rsCwAddOptional = 'Add attribute';
  rsCwAddValue = 'Add value';
  rsCwRemoveValue = 'Remove value';
  rsCwLoadFile = 'Load from file...';
  rsCwNextIdMenu = 'Find next available %s';
  rsCwNextIdSearching = 'Searching the highest %s under %s...';
  rsCwNextIdSet = '%s: next available value %d (highest found: %s, %d value(s) read under %s).';
  rsCwNextIdNone = 'none';
  rsCwNextIdIncomplete = 'The search of %s under %s did not complete (%s): no value was set, a partial ' +
    'result could propose a number already in use.';
  rsCwNextIdExhausted = '%s: no identifier is available above the highest value found (%s): nothing was set.';
  rsCwNextIdStale = '%s: the value found (%d) was not set, the attribute rows changed meanwhile.';
  rsCwNextIdFailed = 'The search of %s failed: %s';
  rsCwNextIdNoBase = 'No naming context or base DN of the profile contains %s: the search was not started.';
  rsCwSecretsLater = 'Secrets (passwords) are set after the creation, with the password tools.';
  rsCwSecretsHere = 'Passwords: add userPassword, then double click its value to set it with the password ' +
    'tools. The value is computed in the chosen format and sent with the entry, never typed in the grid.';
  rsCwSecretEmpty = '(double click to set the password)';
  rsCwSecretSet = '[password set]';
  rsCwSetSecretMenu = 'Set password...';
  rsCwEncode = '%s: %s';
  rsCwNotChecked = 'Checking whether the DN exists...';
  rsCwExists = 'An entry already exists with this DN: the addition will be refused.';
  rsCwNotExists = 'No entry has this DN now; the server decides when the entry is added.';
  rsCwExistsUnknown = 'Whether the DN exists could not be checked: %s';
  rsCwIssues = '# Checks';
  rsCwStepsTitle = '# Steps';
  rsCwFixFirst = 'Fix the errors before creating the entry.';
  rsCwCreate = 'Create';
  rsCwNext = 'Next >';
  rsCwBack = '< Back';
  rsCwClose = 'Close';
  rsCwStepAdd = 'Add the entry';
  rsCwStepPassword = 'Set the password';
  rsCwStepEnable = 'Enable the account';
  rsCwOutPending = 'not done';
  rsCwOutNotSent = 'not sent';
  rsCwOutRefused = 'refused';
  rsCwOutApplied = 'done';
  rsCwOutUnverified = 'done, not read back';
  rsCwOutUnknown = 'UNKNOWN: check the directory before anything else';
  rsCwOutSkipped = 'skipped';
  rsCwColStep = 'Step';
  rsCwColStatus = 'Status';
  rsCwColDetail = 'Detail';
  rsCwPwd = 'New password';
  rsCwPwdConfirm = 'Confirm';
  rsCwMustChange = 'User must change the password at next logon';
  rsCwSetPassword = 'Set password';
  rsCwEnable = 'Enable account';
  rsCwCheck = 'Check the directory';
  rsCwAccept = 'Continue with this entry';
  rsCwPwdMismatch = 'The two passwords differ.';
  rsCwPwdEmpty = 'Type the new password twice.';
  rsCwPwdClear = 'The connection is not encrypted: Active Directory refuses unicodePwd, and the password is not sent.';
  rsCwEnableNeedsPassword = 'Set the password first: the account stays disabled until then.';
  rsCwReading = 'Reading the entry before the next step...';
  rsCwIdentityChanged = 'The entry at %s is not the one created by this assistant (objectGUID differs): nothing was sent.';
  rsCwIdentityUnknown = 'The entry at %s has no usable objectGUID: its identity cannot be confirmed, nothing was sent.';
  rsCwLoadStale = 'The file %s was read, but the attribute rows changed meanwhile: the value for %s was not placed. Load it again.';
  rsCwLoadEdited = 'The file %s was read, but the value of %s was edited meanwhile: the typed value is kept. Load the file again to replace it.';
  rsCwReconcileNoGuid = 'An entry exists at %s but its objectGUID cannot be read: it cannot be adopted as the one created. Close, or check again.';
  rsCwIdentityGone = 'The entry %s cannot be read: %s. Nothing was sent.';
  rsCwReconcileFound = 'An entry exists at %s. It may be the one sent, or another: review it, then continue with it explicitly or close.';
  rsCwReconcileMissing = 'No entry exists at %s: the addition was not applied. Go back to review the plan before submitting again.';
  rsCwSessionChanged = 'The connection was replaced since the plan was checked: review the preview, then create again.';
  rsCwSchemaChanged = 'The schema changed since the plan was checked: the plan was checked again, review it.';
  rsCwNoConnection = 'The connection is closed.';
  rsCwReadOnly = 'This profile is read-only: nothing can be created.';
  rsCwPending = 'A write is in progress. Close anyway? Its result will be recorded in the log.';
  rsCwCreated = '%s created.';
  rsCwAdDone = 'Remaining steps can also be done later with the account and password tools.';
  rsCwOtherDone = 'Set a password later with the password tools if the entry needs one.';
  rsCwNoSchema = 'The schema of the server is not available, so the assistant cannot check a new entry. ' +
    'Write the entry in an LDIF document instead (File > New LDIF).';
  rsCwLoadFailed = '%s was not loaded: %s';
  rsCwTaskBusy = 'Too many background tasks: try again in a moment.';
  rsCwSessionLost = 'The connection changed while the server was being consulted: the outcome is ' +
    'unknown; check the entry before going on.';

function ShowCreateWizard(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  AParentDn: string): string;

implementation

uses
  uAdObjectPlan, uConnections, uConnectionProfile, uDirectoryWorker, uLdapSchema, uLdapErrors, uChangeSet,
  uServerKind, uRtMessage, uTheme, uAttributeCodec, uLdif, uSensitive,
  uAccountState, uPasswordSchemes, uRtBytes, uValueFile, uCancel, uPasswordWork, uMenuBar,
  uSearchModel, uPasswordDialog, uAdAccountPlan, uDirectoryService, Math;

function ShowCreateWizard(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  AParentDn: string): string;
var
  w: TCreateWizard;
  c: TDirectoryConnection;
begin
  Result := '';
  c := ACtx.Connections.Find(AProfileUuid);
  if (c = nil) or not c.IsReady then Exit;
  if c.Schema = nil then
  begin
    RtMessageDlg(rsCwTitle, rsCwNoSchema, mtWarning, [mbOK], 0);
    Exit;
  end;
  w := TCreateWizard.CreateFor(AOwner, ACtx, AProfileUuid, AParentDn);
  try
    w.ShowModal;
    Result := w.CreatedDn;
  finally
    w.Free;
  end;
end;

function OutcomeText(AOutcome: TStepOutcome): string;
begin
  case AOutcome of
    sotNotSent: Result := rsCwOutNotSent;
    sotRefused: Result := rsCwOutRefused;
    sotApplied: Result := rsCwOutApplied;
    sotAppliedUnverified: Result := rsCwOutUnverified;
    sotUnknown: Result := rsCwOutUnknown;
    sotSkipped: Result := rsCwOutSkipped;
  else
    Result := rsCwOutPending;
  end;
end;

function StepText(AKind: TCreationStepKind): string;
begin
  case AKind of
    cskSetPassword: Result := rsCwStepPassword;
    cskEnable: Result := rsCwStepEnable;
  else
    Result := rsCwStepAdd;
  end;
end;

procedure WipeEdit(AEdit: TEdit);
begin
  // Texte ecrase avant d'etre vide: un mot de passe ne traine pas en clair dans le tas.
  AEdit.Text := StringOfChar(' ', Length(AEdit.Text));
  AEdit.Text := '';
end;

type
  // OnContextPopup est protege dans TControl: on passe par la porte de service.
  TPopupAccess = class(TControl);

constructor TCreateWizard.CreateFor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  AParentDn: string);
var
  c: TDirectoryConnection;
begin
  inherited CreateDialog(AOwner, rsCwTitle, 960, 680);
  SetIcon('file-plus');
  InitTasks(ACtx, AProfileUuid);
  FAuxChosen := TStringList.Create;
  FAuxChosen.CaseSensitive := False;
  FPlan := TEntryCreationPlan.Create;
  FPlan.ProfileUuid := AProfileUuid;
  FPlan.ParentDn := AParentDn;
  c := FCtx.Connections.Find(AProfileUuid);
  if c <> nil then
  begin
    FPlan.SessionId := c.SessionId;
    FPlan.Generation := c.Generation;
    FPlan.Provider := EffectiveServerKind(c.Profile, c.RootDse);
    FPlan.SchemaKey := SchemaIdentity(c.Schema);
    SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
  end;
  Tasks.OnMessage := @TaskMessage;
  Tasks.OnUntracked := @LocalMessage;
  BuildUi;
  FillStructList;
  FillAuxList;
  UpdateChosenLabels;
  ShowPage(wpStructural);
end;

destructor TCreateWizard.Destroy;
var
  i: Integer;
begin
  PasswordWork.CancelOwner(Self);
  if FPwd1 <> nil then WipeEdit(FPwd1);
  if FPwd2 <> nil then WipeEdit(FPwd2);
  // Valeurs calculees des mots de passe effacees avant liberation: le gestionnaire memoire
  // n'herite pas de nos secrets.
  for i := 0 to High(FRows) do
    if FRows[i].Bytes <> '' then WipeString(FRows[i].Bytes);
  FEntry.Free;
  FPlan.Free;
  FAuxChosen.Free;
  FIdScan.Free;
  inherited Destroy;
end;

procedure TCreateWizard.BuildUi;
var
  p: TPanel;
  bar, row, txt: TPanel;
  c: TDirectoryConnection;
  lbl: TLabel;
  bannerIcon: TRtIcon;

  function ClassPage(APage: TWizardPage; const AHelp: string; out AFilter: TEdit;
    out AChosen: TLabel; out AInfo: TMemo): TPanel;
  var
    l: TLabel;
    srow: TPanel;
  begin
    Result := MakePanel(Body, alClient);
    FPanels[APage] := Result;
    l := MakeLabel(Result, AHelp);
    l.WordWrap := True;
    AChosen := MakeLabel(Result, '');
    AChosen.Font.Style := [fsBold];
    AChosen.ShowAccelChar := False;
    AChosen.BorderSpacing.Top := 4;
    srow := MakeFieldRow(Result, rsCwSearchShort, 80);
    srow.BorderSpacing.Top := 4;
    AFilter := MakeEdit(srow, alClient);
    AFilter.TextHint := rsCwSearchHint;
    AInfo := MakeMemo(Result, alBottom);
    AInfo.Height := 150;
    AInfo.ReadOnly := True;
    AInfo.WordWrap := True;
    AInfo.ScrollBars := ssAutoVertical;
  end;

begin
  row := MakePanel(Body, alTop, 60);
  bannerIcon := TRtIcon.Create(row);
  bannerIcon.Parent := row;
  bannerIcon.Align := alLeft;
  bannerIcon.Width := 44;
  bannerIcon.SetIcon('file-plus', 28, clAccent);
  txt := MakePanel(row, alClient);
  lbl := MakeLabel(txt, rsCwCreateUnder, alTop);
  lbl.Font.Color := DialogStateColor(usMuted);
  lbl := MakeLabel(txt, AdCanonicalPath(FPlan.ParentDn), alTop);
  lbl.Font.Style := [fsBold];
  lbl.ShowAccelChar := False;
  lbl := MakeLabel(txt, FPlan.ParentDn, alTop);
  lbl.ShowAccelChar := False;
  lbl.Font.Color := DialogStateColor(usMuted);
  row.Height := Max(bannerIcon.Width, StackedLabelsHeight(txt) + 6);
  FStepper := TRtStepper.Create(Body);
  FStepper.Parent := Body;
  StackTop(FStepper);
  FStepper.Align := alTop;
  FStepper.BorderSpacing.Top := 6;
  FStepper.SetSteps([rsCwStepClass, rsCwStepAux, rsCwStepName, rsCwStepAttrs, rsCwStepPreview,
    rsCwStepCreate]);
  FStepLabel := MakeLabel(Body, '', alTop);
  FStepLabel.Font.Style := [fsBold];
  FStepLabel.BorderSpacing.Top := 6;
  FNotice := MakeLabel(Body, '');
  FNotice.Visible := False;
  p := ClassPage(wpStructural, rsCwStructuralHelp, FStructFilter, FStructChosenLabel, FStructInfo);
  FStructFilter.OnChange := @StructFilterChange;
  FStructList := TRtListGrid.Create(p);
  FStructList.Parent := p;
  FStructList.Align := alClient;
  FStructList.BorderSpacing.Top := 4;
  FStructList.BorderSpacing.Bottom := 4;
  FStructList.FillWidth := True;
  FStructList.AddColumn(rsCwColClass, 220);
  FStructList.AddColumn(rsCwColDesc, 520);
  FStructList.OnSelectRow := @StructSelect;
  p := ClassPage(wpAuxiliary, rsCwAuxiliaryHelp, FAuxFilter, FAuxChosenLabel, FAuxInfo);
  FAuxChosenLabel.WordWrap := True;
  FAuxFilter.OnChange := @AuxFilterChange;
  FAuxList := TRtListGrid.Create(p);
  FAuxList.Parent := p;
  FAuxList.Align := alClient;
  FAuxList.BorderSpacing.Top := 4;
  FAuxList.BorderSpacing.Bottom := 4;
  FAuxList.FillWidth := True;
  FAuxList.AddColumn(rsCwColUse, 50);
  FAuxList.AddColumn(rsCwColClass, 220);
  FAuxList.AddColumn(rsCwColDesc, 470);
  FAuxList.OnSelectRow := @AuxSelect;
  FAuxList.OnActivateRow := @AuxActivate;
  FAuxList.OnKeyDown := @AuxKeyDown;
  FAuxList.OnGetCellIcon := @AuxCellIcon;
  p := MakePanel(Body, alClient);
  FPanels[wpNaming] := p;
  row := MakeFieldRow(p, rsCwNamingAttr);
  FRdnAttr := TRtComboBox.Create(row);
  FRdnAttr.Parent := row;
  FRdnAttr.Align := alClient;
  FRdnAttr.Style := csDropDownList;
  FRdnAttr.BorderSpacing.Around := 3;
  FRdnAttr.OnChange := @NamingChange;
  row := MakeFieldRow(p, rsCwNamingValue);
  FRdnValue := MakeEdit(row, alClient);
  FRdnValue.OnChange := @NamingChange;
  row := MakeFieldRow(p, rsCwNamingSecond);
  FRdnAttr2 := TRtComboBox.Create(row);
  FRdnAttr2.Parent := row;
  FRdnAttr2.Align := alClient;
  FRdnAttr2.Style := csDropDownList;
  FRdnAttr2.BorderSpacing.Around := 3;
  FRdnAttr2.OnChange := @NamingChange;
  row := MakeFieldRow(p, rsCwNamingValue);
  FRdnValue2 := MakeEdit(row, alClient);
  FRdnValue2.OnChange := @NamingChange;
  FDnPreview := MakeLabel(p, '');
  p := MakePanel(Body, alClient);
  FPanels[wpAttributes] := p;
  bar := MakePanel(p, alTop, 38);
  FOptional := TRtComboBox.Create(bar);
  FOptional.Parent := bar;
  FOptional.Align := alLeft;
  FOptional.Width := 260;
  FOptional.Style := csDropDownList;
  FOptional.BorderSpacing.Around := 4;
  MakeButton(bar, rsCwAddOptional, @AddOptionalClick);
  MakeButton(bar, rsCwAddValue, @AddValueClick);
  MakeButton(bar, rsCwRemoveValue, @RemoveValueClick);
  MakeButton(bar, rsCwLoadFile, @LoadFileClick);
  lbl := MakeLabel(p, rsCwSecretsLater, alBottom);
  lbl.WordWrap := True;
  FSecretsNote := lbl;
  FAttrNote := MakeLabel(p, '', alBottom);
  FAttrNote.WordWrap := True;
  FAttrNote.ShowAccelChar := False;
  FGrid := TStringGrid.Create(p);
  FGrid.Parent := p;
  FGrid.Align := alClient;
  FGrid.ColCount := 4;
  FGrid.FixedCols := 0;
  FGrid.RowCount := 1;
  FGrid.FixedRows := 1;
  FGrid.Options := FGrid.Options + [goEditing, goColSizing, goThumbTracking] - [goRangeSelect];
  FGrid.FastEditing := False;
  FGrid.Cells[0, 0] := rsCwColAttr;
  FGrid.Cells[1, 0] := rsCwColValue;
  FGrid.Cells[2, 0] := rsCwColRequirement;
  FGrid.Cells[3, 0] := rsCwColType;
  FGrid.ColWidths[0] := 190;
  FGrid.ColWidths[1] := 300;
  FGrid.ColWidths[2] := 230;
  FGrid.ColWidths[3] := 190;
  FGrid.OnSelectEditor := @GridSelectEditor;
  FGrid.OnMouseDown := @GridMouseDown;
  FGrid.OnDblClick := @GridDblClick;
  p := MakePanel(Body, alClient);
  FPanels[wpPreview] := p;
  FExistsLabel := MakeLabel(p, '');
  FPreview := MakeMemo(p);
  FPreview.ReadOnly := True;
  FPreview.ScrollBars := ssAutoBoth;
  FPreview.WordWrap := False;
  p := MakePanel(Body, alClient);
  FPanels[wpResult] := p;
  FResultNote := MakeLabel(p, '');
  FResultNote.WordWrap := True;
  FSteps := TRtListGrid.Create(p);
  FSteps.Parent := p;
  StackTop(FSteps);
  FSteps.Align := alTop;
  FSteps.Height := 120;
  FSteps.FillWidth := True;
  FSteps.AddColumn(rsCwColStep, 170);
  FSteps.AddColumn(rsCwColStatus, 200);
  FSteps.AddColumn(rsCwColDetail, 400);
  FSteps.OnGetCellIcon := @StepCellIcon;
  bar := MakePanel(p, alTop, 38);
  FCheckButton := MakeButton(bar, rsCwCheck, @CheckClick);
  FAcceptButton := MakeButton(bar, rsCwAccept, @AcceptClick);
  FPwdPanel := MakePanel(p, alTop);
  FPwdPanel.AutoSize := True;
  row := MakeFieldRow(FPwdPanel, rsCwPwd);
  FPwd1 := MakeEdit(row, alClient);
  FPwd1.PasswordChar := '*';
  row := MakeFieldRow(FPwdPanel, rsCwPwdConfirm);
  FPwd2 := MakeEdit(row, alClient);
  FPwd2.PasswordChar := '*';
  FMustChange := MakeCheck(FPwdPanel, rsCwMustChange);
  bar := MakePanel(FPwdPanel, alTop, 38);
  FPwdButton := MakeButton(bar, rsCwSetPassword, @PasswordClick);
  FEnableButton := MakeButton(bar, rsCwEnable, @EnableClick);
  AddButton(rsCwClose, mrClose, False, True);
  FNext := AddButton(rsCwNext, mrNone, True);
  FNext.OnClick := @NextClick;
  FBack := AddButton(rsCwBack, mrNone);
  FBack.OnClick := @BackClick;
  ApplyTheme;
  FStepper.Height := FStepper.PreferredHeight;
  FStructInfo.Color := clEditorBg;
  FStructInfo.Font.Color := clEditorFg;
  FAuxInfo.Color := clEditorBg;
  FAuxInfo.Font.Color := clEditorFg;
  FPreview.Color := clEditorBg;
  FPreview.Font.Color := clEditorFg;
  StyleMemo(FPreview);
  StyleMemo(FStructInfo);
  StyleMemo(FAuxInfo);
  FGrid.DefaultRowHeight := FontTextHeight(FGrid.Font) + 8;
  FGrid.Color := clAppBg;
  FGrid.Font.Color := clAppFg;
  FGrid.FixedColor := clSideBg;
  FGrid.GridLineColor := clBorder;
  FGrid.FixedGridLineColor := clBorder;
  FGrid.SelectedColor := clSideSel;
  c := FCtx.Connections.Find(FProfileUuid);
  if (c <> nil) and c.Profile.ReadOnly then
  begin
    FNotice.Caption := rsCwReadOnly;
    FNotice.Visible := True;
  end;
end;

procedure TCreateWizard.ShowPage(APage: TWizardPage);
var
  p: TWizardPage;
  title: string;
begin
  FPage := APage;
  for p := Low(TWizardPage) to High(TWizardPage) do
    FPanels[p].Visible := p = APage;
  case APage of
    wpStructural: title := rsCwPageStructural;
    wpAuxiliary: title := rsCwPageAuxiliary;
    wpNaming: title := rsCwPageNaming;
    wpAttributes: title := rsCwPageAttributes;
    wpPreview: title := rsCwPagePreview;
  else
    title := rsCwPageResult;
  end;
  FStepLabel.Caption := UpperCase(Copy(title, 1, 1)) + Copy(title, 2, MaxInt);
  FStepper.Current := Ord(APage);
  if APage = wpPreview then FNext.Caption := rsCwCreate else FNext.Caption := rsCwNext;
  UpdateButtons;
end;

procedure TCreateWizard.UpdateButtons;
var
  c: TDirectoryConnection;
  addOutcome: TStepOutcome;
  pwdDone: Boolean;
  i: Integer;
  busy: Boolean;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  // Un fichier en cours de lecture vise les lignes affichees: pas de changement de page avant son
  // arrivee. La verification d'existence du DN, elle, est indicative et ne bloque rien.
  busy := Tasks.WritesInFlight or (Tasks.Pending('read') and (FReadPurpose <> rpExists)) or
    (FFileTask <> 0) or Tasks.Pending('nextid');
  addOutcome := StepOutcome(cskAdd);
  FBack.Enabled := (FPage <> wpStructural) and not busy and
    not (addOutcome in [sotApplied, sotAppliedUnverified, sotUnknown]);
  FNext.Visible := FPage <> wpResult;
  FNext.Enabled := not busy and (c <> nil) and not c.Profile.ReadOnly;
  if FPage = wpPreview then
    FNext.Enabled := FNext.Enabled and (FEntry <> nil) and not HasErrors(FPreviewIssues);
  if FPage <> wpResult then Exit;
  i := FPlan.StepIndex(cskSetPassword);
  FPwdPanel.Visible := i >= 0;
  pwdDone := (i >= 0) and (FPlan.Steps[i].Outcome in [sotApplied, sotAppliedUnverified]);
  FPwdButton.Enabled := not busy and (addOutcome in [sotApplied, sotAppliedUnverified]) and
    (i >= 0) and not pwdDone and (FPlan.Steps[i].Outcome <> sotUnknown);
  i := FPlan.StepIndex(cskEnable);
  FEnableButton.Enabled := not busy and pwdDone and (i >= 0) and
    not (FPlan.Steps[i].Outcome in [sotApplied, sotAppliedUnverified, sotUnknown]);
  FCheckButton.Visible := addOutcome = sotUnknown;
  FCheckButton.Enabled := not busy;
  FAcceptButton.Visible := (addOutcome = sotUnknown) and FReconcileFound;
end;

function TCreateWizard.ClassDescription(const AClass, AFilter: string): string;
const
  SHOWN = 3;
var
  c: TDirectoryConnection;
  oc: TSchemaObjectClass;
  required, allowed: TStringArray;
  part: string;

  function Names(const AList: TStringArray): string;
  var
    k: Integer;
  begin
    Result := '';
    for k := 0 to High(AList) do
    begin
      if k = SHOWN then Break;
      if Result <> '' then Result := Result + ', ';
      Result := Result + AList[k];
    end;
    if Length(AList) > SHOWN then Result := Format(rsCwAttrMore, [Result, Length(AList) - SHOWN]);
  end;

begin
  Result := '';
  c := FCtx.Connections.Find(FProfileUuid);
  if (c = nil) or (c.Schema = nil) then Exit;
  oc := c.Schema.ObjectClass(AClass);
  if oc = nil then Exit;
  Result := oc.Desc;
  if not ClassMatchingAttributes(c.Schema, AClass, AFilter, required, allowed) then Exit;
  part := '';
  if Length(required) > 0 then part := Format(rsCwAttrRequired, [Names(required)]);
  if Length(allowed) > 0 then
  begin
    if part <> '' then part := part + '; ';
    part := part + Format(rsCwAttrAllowed, [Names(allowed)]);
  end;
  Result := Trim(part + '. ' + oc.Desc);
end;

procedure TCreateWizard.FillStructList;
var
  c: TDirectoryConnection;
  names: TStringArray;
  i: Integer;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  FStructList.Clear;
  if (c = nil) or (c.Schema = nil) then Exit;
  names := FindClasses(c.Schema, FStructFilter.Text, ockStructural, 1000);
  for i := 0 to High(names) do
  begin
    FStructList.AddRow([names[i], ClassDescription(names[i], FStructFilter.Text)]);
    if SameText(names[i], FStructChosen) then FStructList.ItemIndex := i;
  end;
end;

procedure TCreateWizard.FillAuxList;
var
  c: TDirectoryConnection;
  names: TStringArray;
  i, firstRow: Integer;
  current: string;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  current := '';
  if FAuxList.ItemIndex >= 0 then current := FAuxList.CellText(FAuxList.ItemIndex, 1);
  firstRow := FAuxList.TopRow;
  FAuxList.Clear;
  if (c = nil) or (c.Schema = nil) then Exit;
  names := FindClasses(c.Schema, FAuxFilter.Text, ockAuxiliary, 1000);
  for i := 0 to High(names) do
  begin
    if FAuxChosen.IndexOf(names[i]) >= 0 then
      FAuxList.AddRow(['yes', names[i], ClassDescription(names[i], FAuxFilter.Text)])
    else
      FAuxList.AddRow(['', names[i], ClassDescription(names[i], FAuxFilter.Text)]);
  end;
  for i := 0 to FAuxList.Count - 1 do
    if SameText(FAuxList.CellText(i, 1), current) then
    begin
      FAuxList.ItemIndex := i;
      Break;
    end;
  if (firstRow >= FAuxList.FixedRows) and (firstRow < FAuxList.RowCount) then FAuxList.TopRow := firstRow;
end;

procedure TCreateWizard.UpdateChosenLabels;
var
  i: Integer;
  aux: string;
begin
  if FStructChosen <> '' then
    FStructChosenLabel.Caption := Format(rsCwChosenStructural, [FStructChosen])
  else
    FStructChosenLabel.Caption := rsCwChosenNone;
  aux := '';
  for i := 0 to FAuxChosen.Count - 1 do
  begin
    if aux <> '' then aux := aux + ', ';
    aux := aux + FAuxChosen[i];
  end;
  if aux = '' then aux := rsCwChosenAuxNone;
  FAuxChosenLabel.Caption := Format(rsCwChosenAux, [FStructChosen, aux]);
end;

procedure TCreateWizard.StructFilterChange(Sender: TObject);
begin
  FillStructList;
end;

procedure TCreateWizard.AuxFilterChange(Sender: TObject);
begin
  FillAuxList;
end;

procedure TCreateWizard.DescribeClass(AInfo: TMemo; const AName: string);
var
  c: TDirectoryConnection;
  oc: TSchemaObjectClass;
  chain: TStringArray;
  issue, must, may, gen: string;
  a: TClassAnalysis;
  i: Integer;
begin
  AInfo.Clear;
  c := FCtx.Connections.Find(FProfileUuid);
  if (c = nil) or (c.Schema = nil) then Exit;
  oc := c.Schema.ObjectClass(AName);
  if oc = nil then Exit;
  AInfo.Lines.Add(oc.PrimaryName + '  (' + oc.Oid + ')');
  if oc.Desc <> '' then AInfo.Lines.Add(oc.Desc);
  if oc.Kind = ockAuxiliary then AInfo.Lines.Add(rsCwKindAuxiliary)
  else AInfo.Lines.Add(rsCwKindStructural);
  if InheritanceChain(c.Schema, AName, chain, issue) then
    AInfo.Lines.Add(Format(rsCwInherits, [string.Join(' < ', chain)]))
  else
    AInfo.Lines.Add(issue);
  if oc.Kind = ockAuxiliary then
    a := AnalyzeClasses(c.Schema, ['top'], [], FPlan.Provider)
  else
    a := AnalyzeClasses(c.Schema, [AName], [], FPlan.Provider);
  must := '';
  may := '';
  gen := '';
  for i := 0 to High(a.Requirements) do
    case a.Requirements[i].Supply of
      rsUser:
        if a.Requirements[i].Kind = rqMust then
          must := must + a.Requirements[i].Name + ' (' + a.Requirements[i].Origin + ')  '
        else
          may := may + a.Requirements[i].Name + '  ';
      rsServerGenerated, rsServerOnly:
        gen := gen + a.Requirements[i].Name + '  ';
    end;
  if oc.Kind = ockAuxiliary then
  begin
    must := string.Join('  ', oc.Must);
    may := string.Join('  ', oc.May);
  end;
  AInfo.Lines.Add(Format(rsCwMust, [must]));
  AInfo.Lines.Add(Format(rsCwMay, [may]));
  if gen <> '' then AInfo.Lines.Add(Format(rsCwGenerated, [gen]));
  if oc.Kind <> ockAuxiliary then
    for i := 0 to High(a.Issues) do
      AInfo.Lines.Add(a.Issues[i].Text);
end;

procedure TCreateWizard.StructSelect(Sender: TObject; AIndex: Integer);
begin
  if AIndex < 0 then Exit;
  FStructChosen := FStructList.CellText(AIndex, 0);
  UpdateChosenLabels;
  DescribeClass(FStructInfo, FStructChosen);
end;

procedure TCreateWizard.AuxSelect(Sender: TObject; AIndex: Integer);
begin
  if AIndex >= 0 then DescribeClass(FAuxInfo, FAuxList.CellText(AIndex, 1));
end;

procedure TCreateWizard.AuxActivate(Sender: TObject; AIndex: Integer);
begin
  if AIndex >= 0 then ToggleAuxiliary(FAuxList.CellText(AIndex, 1));
end;

procedure TCreateWizard.AuxKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_SPACE) and (Shift = []) and (FAuxList.ItemIndex >= 0) then
  begin
    ToggleAuxiliary(FAuxList.CellText(FAuxList.ItemIndex, 1));
    Key := 0;
  end;
end;

function TCreateWizard.AuxCellIcon(Sender: TObject; AIndex, ACol: Integer; out AColor: TColor): string;
begin
  Result := '';
  AColor := clNone;
  if ACol <> 0 then Exit;
  if FAuxList.CellText(AIndex, 0) <> '' then
  begin
    Result := 'circle-check';
    AColor := ShellStateColor(usOk);
  end
  else
  begin
    Result := 'circle-dashed';
    AColor := ShellStateColor(usMuted);
  end;
end;

procedure TCreateWizard.ToggleAuxiliary(const AName: string);
var
  i: Integer;
begin
  i := FAuxChosen.IndexOf(AName);
  if i >= 0 then FAuxChosen.Delete(i) else FAuxChosen.Add(AName);
  FillAuxList;
  UpdateChosenLabels;
end;

procedure TCreateWizard.ChooseStructural(const AName: string);
var
  c: TDirectoryConnection;
  oc: TSchemaObjectClass;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  if (c = nil) or (c.Schema = nil) then Exit;
  oc := c.Schema.ObjectClass(AName);
  if (oc = nil) or (oc.Kind <> ockStructural) then Exit;
  FStructChosen := AName;
  FillStructList;
  UpdateChosenLabels;
  DescribeClass(FStructInfo, AName);
end;

procedure TCreateWizard.SetStructuralFilter(const AText: string);
begin
  FStructFilter.Text := AText;
  FillStructList;
end;

procedure TCreateWizard.SetAuxiliaryFilter(const AText: string);
begin
  FAuxFilter.Text := AText;
  FillAuxList;
end;

function TCreateWizard.StructuralChoice: string;
begin
  Result := FStructChosen;
end;

function TCreateWizard.ClassListText(AAuxiliary: Boolean): string;
var
  i: Integer;
begin
  Result := '';
  if AAuxiliary then
    for i := 0 to FAuxList.Count - 1 do
      Result := Result + FAuxList.CellText(i, 1) + ': ' + FAuxList.CellText(i, 2) + LineEnding
  else
    for i := 0 to FStructList.Count - 1 do
      Result := Result + FStructList.CellText(i, 0) + ': ' + FStructList.CellText(i, 1) + LineEnding;
end;

function TCreateWizard.AuxiliaryChoice: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to FAuxChosen.Count - 1 do
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + FAuxChosen[i];
  end;
end;

function TCreateWizard.EnterAuxiliary: Boolean;
var
  c: TDirectoryConnection;
  a: TClassAnalysis;
  i: Integer;
  msg: string;
begin
  Result := False;
  c := FCtx.Connections.Find(FProfileUuid);
  if (FStructChosen = '') and (FStructList.ItemIndex >= 0) then
    StructSelect(FStructList, FStructList.ItemIndex);
  if (c = nil) or (FStructChosen = '') then
  begin
    RtMessageDlg(rsCwTitle, rsCpNoStructural, mtWarning, [mbOK], 0);
    Exit;
  end;
  a := AnalyzeClasses(c.Schema, [FStructChosen], [], FPlan.Provider);
  if not a.Ok then
  begin
    msg := '';
    for i := 0 to High(a.Issues) do
      if a.Issues[i].Severity = isError then msg := msg + a.Issues[i].Text + LineEnding;
    RtMessageDlg(rsCwTitle, msg, mtError, [mbOK], 0);
    Exit;
  end;
  UpdateChosenLabels;
  FillAuxList;
  if FAuxList.ItemIndex >= 0 then DescribeClass(FAuxInfo, FAuxList.CellText(FAuxList.ItemIndex, 1));
  Result := True;
end;

function TCreateWizard.EnterNaming: Boolean;
var
  c: TDirectoryConnection;
  i: Integer;
  msg: string;
begin
  Result := False;
  c := FCtx.Connections.Find(FProfileUuid);
  if (c = nil) or (FStructChosen = '') then
  begin
    RtMessageDlg(rsCwTitle, rsCpNoStructural, mtWarning, [mbOK], 0);
    Exit;
  end;
  SetLength(FPlan.Structural, 1);
  FPlan.Structural[0] := FStructChosen;
  SetLength(FPlan.Auxiliaries, FAuxChosen.Count);
  for i := 0 to FAuxChosen.Count - 1 do
    FPlan.Auxiliaries[i] := FAuxChosen[i];
  FAnalysis := AnalyzeClasses(c.Schema, FPlan.Structural, FPlan.Auxiliaries, FPlan.Provider);
  if not FAnalysis.Ok then
  begin
    msg := '';
    for i := 0 to High(FAnalysis.Issues) do
      if FAnalysis.Issues[i].Severity = isError then
        msg := msg + FAnalysis.Issues[i].Text + LineEnding;
    RtMessageDlg(rsCwTitle, msg, mtError, [mbOK], 0);
    Exit;
  end;
  PrepareSteps(FPlan, FAnalysis);
  FillRdnChoices;
  Result := True;
end;

procedure AddSortedNames(ATarget: TStrings; ANames: TStringList);
begin
  ANames.CaseSensitive := False;
  ANames.Sort;
  ATarget.AddStrings(ANames);
end;

procedure TCreateWizard.FillRdnChoices;
var
  i, keep, keep2: Integer;
  prev, prev2, def: string;
  names: TStringList;
begin
  prev := FRdnAttr.Text;
  prev2 := FRdnAttr2.Text;
  FRdnAttr.Items.Clear;
  FRdnAttr2.Items.Clear;
  FRdnAttr2.Items.Add(rsCwNone);
  // Jamais un secret ni une valeur du serveur comme attribut de nommage: un mot de passe dans
  // un DN, c'est un mot de passe dans tous les journaux.
  names := TStringList.Create;
  try
    for i := 0 to High(FAnalysis.Requirements) do
      if (FAnalysis.Requirements[i].Supply = rsUser) and
         (FAnalysis.Requirements[i].Kind in [rqMust, rqMay]) and
         not FCtx.Sensitive.IsSensitive(FAnalysis.Requirements[i].Name) then
        names.Add(FAnalysis.Requirements[i].Name);
    AddSortedNames(FRdnAttr.Items, names);
    AddSortedNames(FRdnAttr2.Items, names);
  finally
    names.Free;
  end;
  keep := FRdnAttr.Items.IndexOf(prev);
  if keep < 0 then
  begin
    def := DefaultRdnAttribute(FAnalysis);
    keep := FRdnAttr.Items.IndexOf(def);
  end;
  if (keep < 0) and (FRdnAttr.Items.Count > 0) then keep := 0;
  FRdnAttr.ItemIndex := keep;
  keep2 := FRdnAttr2.Items.IndexOf(prev2);
  if keep2 < 0 then keep2 := 0;
  FRdnAttr2.ItemIndex := keep2;
  NamingChange(nil);
end;

procedure TCreateWizard.SetNaming(const AAttr, AValue: string);
begin
  FRdnAttr.ItemIndex := FRdnAttr.Items.IndexOf(AAttr);
  FRdnValue.Text := AValue;
  NamingChange(nil);
end;

procedure TCreateWizard.NamingChange(Sender: TObject);
var
  dn, err: string;
begin
  if not ReadNaming then Exit;
  if BuildCreationDn(FPlan.ParentDn, FPlan.Rdn, dn, err) then
    FDnPreview.Caption := Format(rsCwDn, [dn])
  else
    FDnPreview.Caption := err;
end;

function TCreateWizard.ReadNaming: Boolean;
begin
  Result := (FRdnAttr.ItemIndex >= 0);
  FPlan.Rdn := nil;
  if not Result then Exit;
  FPlan.SetRdn(FRdnAttr.Text, FRdnValue.Text);
  if (FRdnAttr2.ItemIndex > 0) then
    FPlan.AddRdnAva(FRdnAttr2.Text, FRdnValue2.Text);
end;

function TCreateWizard.RowOfGrid(ARow: Integer): Integer;
begin
  Result := -1;
  if (ARow < 1) or (ARow >= FGrid.RowCount) or (FGrid.Objects[0, ARow] = nil) then Exit;
  Result := PtrInt(FGrid.Objects[0, ARow]) - 1;
end;

procedure TCreateWizard.EnterAttributes;
var
  i, j, k: Integer;
  r: TWizRow;
  a: TLdapAttribute;
  req: TAttrRequirement;
  isRdn: Boolean;
  names: TStringList;

  procedure Push(const ARow: TWizRow);
  begin
    SetLength(FRows, Length(FRows) + 1);
    FRows[High(FRows)] := ARow;
  end;

  function Listed(const AAttr: string): Boolean;
  var
    n: Integer;
  begin
    for n := 0 to High(FRows) do
      if SameText(FRows[n].Attr, AAttr) then Exit(True);
    Result := False;
  end;

begin
  FRows := nil;
  Inc(FRowsGen);
  for i := 0 to High(FPlan.Rdn) do
  begin
    r := Default(TWizRow);
    r.Attr := FPlan.Rdn[i].Attr;
    r.Text := string(FPlan.Rdn[i].Value);
    r.Locked := True;
    r.Note := rsCwReqName;
    Push(r);
  end;
  for i := 0 to High(FAnalysis.Requirements) do
  begin
    req := FAnalysis.Requirements[i];
    if req.Supply = rsPlan then Continue;
    isRdn := False;
    for k := 0 to High(FPlan.Rdn) do
      if SameText(FPlan.Rdn[k].Attr, req.Name) then isRdn := True;
    if req.Supply in [rsServerGenerated, rsServerOnly] then
    begin
      if req.Kind <> rqMust then Continue;
      if not (SameText(req.Name, 'sAMAccountName') and (req.Supply = rsServerGenerated)) then
      begin
        r := Default(TWizRow);
        r.Attr := req.Name;
        r.Locked := True;
        if req.Supply = rsServerGenerated then r.Note := Format(rsCwReqGenerated, [req.Rule])
        else r.Note := Format(rsCwReqServerOnly, [req.Origin]);
        Push(r);
        Continue;
      end;
    end;
    if (req.Kind <> rqMust) and not SameText(req.Name, 'sAMAccountName') then Continue;
    if isRdn or FCtx.Sensitive.IsSensitive(req.Name) then Continue;
    a := FPlan.Values.Find(req.Name);
    if (a <> nil) and (a.ValueCount > 0) then
      for j := 0 to a.ValueCount - 1 do
      begin
        r := Default(TWizRow);
        r.Attr := req.Name;
        r.Text := EditableText(ResolveValueKind(FCtx.Connections.Find(FProfileUuid).Schema, req.Name,
          FPlan.Provider), a.Values[j]);
        Push(r);
      end
    else
    begin
      r := Default(TWizRow);
      r.Attr := req.Name;
      Push(r);
    end;
  end;
  for i := 0 to FPlan.Values.AttrCount - 1 do
  begin
    a := FPlan.Values.Attrs[i];
    if Listed(a.Description) then Continue;
    for j := 0 to a.ValueCount - 1 do
    begin
      r := Default(TWizRow);
      r.Attr := a.Description;
      if FCtx.Sensitive.IsSensitive(a.Description) then
        r.Bytes := a.Values[j]
      else
        r.Text := EditableText(ResolveValueKind(FCtx.Connections.Find(FProfileUuid).Schema,
          a.Description, FPlan.Provider), a.Values[j]);
      Push(r);
    end;
  end;
  FOptional.Items.Clear;
  names := TStringList.Create;
  try
    for i := 0 to High(FAnalysis.Requirements) do
      if (FAnalysis.Requirements[i].Supply = rsUser) and
         (SecretsAllowed or not FCtx.Sensitive.IsSensitive(FAnalysis.Requirements[i].Name)) then
        names.Add(FAnalysis.Requirements[i].Name);
    AddSortedNames(FOptional.Items, names);
  finally
    names.Free;
  end;
  if FOptional.Items.Count > 0 then FOptional.ItemIndex := 0;
  if SecretsAllowed then FSecretsNote.Caption := rsCwSecretsHere
  else FSecretsNote.Caption := rsCwSecretsLater;
  RefreshGrid;
end;

// Hors Active Directory, userPassword se pose a la creation (valeur calculee par les outils).
// AD veut unicodePwd, en etape distincte une fois l'entree creee.
function TCreateWizard.SecretsAllowed: Boolean;
begin
  Result := FPlan.Provider <> pkActiveDirectory;
end;

function TCreateWizard.IsSecretRow(ARow: Integer): Boolean;
begin
  Result := (ARow >= 0) and (ARow <= High(FRows)) and FCtx.Sensitive.IsSensitive(FRows[ARow].Attr);
end;

procedure TCreateWizard.GridDblClick(Sender: TObject);
var
  i: Integer;
begin
  i := RowOfGrid(FGrid.Row);
  if IsSecretRow(i) then SetSecret(i);
end;

procedure TCreateWizard.SecretMenuClick(Sender: TObject);
begin
  SetSecret(FMenuRow);
end;

// Valeur calculee par les outils de mot de passe dans le format choisi: jamais le mot de passe
// lui-meme, jamais une saisie de la grille.
procedure TCreateWizard.SetSecret(ARow: Integer);
var
  c: TDirectoryConnection;
  v: RawByteString;
  gen: Int64;
  attr: string;
begin
  if not SecretsAllowed or not IsSecretRow(ARow) or FRows[ARow].Locked then Exit;
  if (FFileTask <> 0) or Tasks.Pending('nextid') then Exit;
  c := FCtx.Connections.Find(FProfileUuid);
  if c = nil then Exit;
  CommitGrid;
  gen := FRowsGen;
  attr := FRows[ARow].Attr;
  if not ComputePasswordValue(Self, FCtx, c, v) then Exit;
  try
    if (gen <> FRowsGen) or (ARow > High(FRows)) or not SameText(FRows[ARow].Attr, attr) then Exit;
    FRows[ARow].Bytes := Copy(v, 1, MaxInt);
    RefreshGrid;
    CommitGrid;
  finally
    WipeString(v);
  end;
end;

procedure TCreateWizard.SetSecretFor(const AAttr: string);
var
  i: Integer;
begin
  for i := 0 to High(FRows) do
    if SameText(FRows[i].Attr, AAttr) then
    begin
      SetSecret(i);
      Exit;
    end;
end;

procedure TCreateWizard.AddOptional(const AAttr: string);
begin
  FOptional.ItemIndex := FOptional.Items.IndexOf(AAttr);
  if FOptional.ItemIndex >= 0 then AddOptionalClick(nil);
end;

function TCreateWizard.OptionalAttributes: string;
var
  i: Integer;
begin
  Result := '|';
  for i := 0 to FOptional.Items.Count - 1 do Result := Result + FOptional.Items[i] + '|';
end;

procedure TCreateWizard.RefreshGrid;
var
  i, n: Integer;
  req: string;
  c: TDirectoryConnection;
  res: TValueResolution;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  FGrid.RowCount := Length(FRows) + 1;
  for i := 0 to High(FRows) do
  begin
    FGrid.Cells[0, i + 1] := FRows[i].Attr;
    if IsSecretRow(i) then
    begin
      if FRows[i].Bytes <> '' then FGrid.Cells[1, i + 1] := rsCwSecretSet
      else FGrid.Cells[1, i + 1] := rsCwSecretEmpty;
    end
    else if FRows[i].FromFile then
      FGrid.Cells[1, i + 1] := Format(rsCwFromFile, [Length(FRows[i].Bytes)])
    else
      FGrid.Cells[1, i + 1] := FRows[i].Text;
    req := FRows[i].Note;
    if req = '' then
      for n := 0 to High(FAnalysis.Requirements) do
        if SameText(FAnalysis.Requirements[n].Name, AttrBaseName(FRows[i].Attr)) then
        begin
          if FAnalysis.Requirements[n].Kind = rqMust then
            req := Format(rsCwReqMust, [FAnalysis.Requirements[n].Origin])
          else
            req := Format(rsCwReqMay, [FAnalysis.Requirements[n].Origin]);
          Break;
        end;
    FGrid.Cells[2, i + 1] := req;
    if c <> nil then
    begin
      res := ResolveValueKind(c.Schema, FRows[i].Attr, FPlan.Provider);
      FGrid.Cells[3, i + 1] := ValueKindName(res.Kind);
    end;
    FGrid.Objects[0, i + 1] := TObject(PtrInt(i + 1));
  end;
end;

procedure TCreateWizard.GridSelectEditor(Sender: TObject; aCol, aRow: Integer; var Editor: TWinControl);
var
  i: Integer;
  c: TDirectoryConnection;
  res: TValueResolution;
begin
  i := RowOfGrid(aRow);
  c := FCtx.Connections.Find(FProfileUuid);
  if (aCol <> 1) or (i < 0) or FRows[i].Locked or FRows[i].FromFile or IsSecretRow(i) or (c = nil) or
     ((FFileTask <> 0) and (i = FFileRow)) then
  begin
    Editor := nil;
    Exit;
  end;
  res := ResolveValueKind(c.Schema, FRows[i].Attr, FPlan.Provider);
  if not KindTextEditable(res.Kind) then
  begin
    Editor := nil;
    Exit;
  end;
  if Editor <> nil then
  begin
    Editor.Color := clEditorBg;
    Editor.Font := FGrid.Font;
    Editor.Font.Color := clEditorFg;
    TPopupAccess(Editor).OnContextPopup := @EditorContextPopup;
  end;
end;

procedure TCreateWizard.CommitGrid;
var
  i: Integer;
  c: TDirectoryConnection;
  res: TValueResolution;
  b: RawByteString;
  err: string;
begin
  if FGrid.EditorMode then FGrid.EditorMode := False;
  for i := 0 to High(FRows) do
    if not FRows[i].Locked and not FRows[i].FromFile and not IsSecretRow(i) then
      FRows[i].Text := FGrid.Cells[1, i + 1];
  c := FCtx.Connections.Find(FProfileUuid);
  FEncodeIssues := nil;
  while FPlan.Values.AttrCount > 0 do
    FPlan.Values.Remove(FPlan.Values.Attrs[0].Description);
  FPlan.ComputedSecrets := nil;
  for i := 0 to High(FRows) do
  begin
    if FRows[i].Locked then Continue;
    if IsSecretRow(i) then
    begin
      if SecretsAllowed and (FRows[i].Bytes <> '') then
      begin
        FPlan.Values.Ensure(FRows[i].Attr).AddValue(FRows[i].Bytes);
        SetLength(FPlan.ComputedSecrets, Length(FPlan.ComputedSecrets) + 1);
        FPlan.ComputedSecrets[High(FPlan.ComputedSecrets)] := AttrBaseName(FRows[i].Attr);
      end;
      Continue;
    end;
    if FRows[i].FromFile then
    begin
      FPlan.Values.Ensure(FRows[i].Attr).AddValue(FRows[i].Bytes);
      Continue;
    end;
    if FRows[i].Text = '' then Continue;
    if c = nil then Continue;
    res := ResolveValueKind(c.Schema, FRows[i].Attr, FPlan.Provider);
    if EncodeTyped(res, FRows[i].Text, '', b, err) then
      FPlan.Values.Ensure(FRows[i].Attr).AddValue(b)
    else
    begin
      SetLength(FEncodeIssues, Length(FEncodeIssues) + 1);
      FEncodeIssues[High(FEncodeIssues)].Severity := isError;
      FEncodeIssues[High(FEncodeIssues)].Attr := FRows[i].Attr;
      FEncodeIssues[High(FEncodeIssues)].Text := Format(rsCwEncode, [FRows[i].Attr, err]);
    end;
  end;
end;

procedure TCreateWizard.SetValueText(const AAttr, AText: string);
var
  i: Integer;
  r: TWizRow;
begin
  CommitGrid;
  for i := 0 to High(FRows) do
    if SameText(FRows[i].Attr, AAttr) and not FRows[i].Locked and (FRows[i].Text = '') and
       not FRows[i].FromFile then
    begin
      FRows[i].Text := AText;
      RefreshGrid;
      CommitGrid;
      Exit;
    end;
  r := Default(TWizRow);
  r.Attr := AAttr;
  r.Text := AText;
  SetLength(FRows, Length(FRows) + 1);
  FRows[High(FRows)] := r;
  RefreshGrid;
  CommitGrid;
end;

procedure TCreateWizard.AddOptionalClick(Sender: TObject);
var
  r: TWizRow;
begin
  if FOptional.ItemIndex < 0 then Exit;
  CommitGrid;
  r := Default(TWizRow);
  r.Attr := FOptional.Text;
  SetLength(FRows, Length(FRows) + 1);
  FRows[High(FRows)] := r;
  RefreshGrid;
  FGrid.Row := Length(FRows);
  FGrid.Col := 1;
end;

procedure TCreateWizard.AddValueClick(Sender: TObject);
var
  i: Integer;
  r: TWizRow;
begin
  i := RowOfGrid(FGrid.Row);
  if (i < 0) or FRows[i].Locked then Exit;
  CommitGrid;
  r := Default(TWizRow);
  r.Attr := FRows[i].Attr;
  Inc(FRowsGen);
  SetLength(FRows, Length(FRows) + 1);
  Move(FRows[i + 1], FRows[i + 2], (Length(FRows) - i - 2) * SizeOf(TWizRow));
  FillChar(FRows[i + 1], SizeOf(TWizRow), 0);
  FRows[i + 1] := r;
  RefreshGrid;
  FGrid.Row := i + 2;
end;

procedure TCreateWizard.RemoveValueClick(Sender: TObject);
var
  i, j, n: Integer;
begin
  i := RowOfGrid(FGrid.Row);
  if (i < 0) or FRows[i].Locked then Exit;
  CommitGrid;
  n := 0;
  for j := 0 to High(FRows) do
    if SameText(FRows[j].Attr, FRows[i].Attr) then Inc(n);
  Inc(FRowsGen);
  FRows[i].Text := '';
  FRows[i].Bytes := '';
  FRows[i].FromFile := False;
  if n > 1 then
  begin
    for j := i to High(FRows) - 1 do
      FRows[j] := FRows[j + 1];
    SetLength(FRows, Length(FRows) - 1);
  end;
  RefreshGrid;
  CommitGrid;
end;

procedure TCreateWizard.LoadFileClick(Sender: TObject);
var
  i: Integer;
  od: TOpenDialog;
begin
  i := RowOfGrid(FGrid.Row);
  if (i < 0) or FRows[i].Locked or IsSecretRow(i) or (FFileTask <> 0) then Exit;
  od := TOpenDialog.Create(Self);
  try
    od.Filter := 'All files|*.*';
    if not od.Execute then Exit;
    if (i > High(FRows)) or FRows[i].Locked then Exit;
    CommitGrid;
    FFileRow := i;
    FFileGen := FRowsGen;
    FFileAttr := FRows[i].Attr;
    FFileText := FRows[i].Text;
    FFileTask := StartValueLoad(od.FileName, VALUE_MAX_BYTES, Self);
    if FFileTask = 0 then RtMessageDlg(rsCwTitle, rsCwTaskBusy, mtWarning, [mbOK], 0);
    UpdateButtons;
  finally
    od.Free;
  end;
end;

procedure TCreateWizard.SimulateFileLoad(const AAttr: string; ATaskId: Int64);
var
  i: Integer;
begin
  CommitGrid;
  for i := 0 to High(FRows) do
    if SameText(FRows[i].Attr, AAttr) and not FRows[i].Locked then
    begin
      FFileRow := i;
      FFileGen := FRowsGen;
      FFileAttr := FRows[i].Attr;
      FFileText := FRows[i].Text;
      FFileTask := ATaskId;
      UpdateButtons;
      Exit;
    end;
end;

procedure TCreateWizard.TypeValueText(const AAttr, AText: string);
var
  i: Integer;
begin
  for i := 0 to High(FRows) do
    if SameText(FRows[i].Attr, AAttr) and not FRows[i].Locked and not FRows[i].FromFile then
    begin
      FGrid.Cells[1, i + 1] := AText;
      Exit;
    end;
end;

procedure TCreateWizard.RemoveValueOf(const AAttr: string);
var
  i: Integer;
begin
  for i := 0 to High(FRows) do
    if SameText(FRows[i].Attr, AAttr) and not FRows[i].Locked then
    begin
      FGrid.Row := i + 1;
      RemoveValueClick(nil);
      Exit;
    end;
end;

function TCreateWizard.FileBytesOf(const AAttr: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FRows) do
    if SameText(FRows[i].Attr, AAttr) and FRows[i].FromFile then Exit(Length(FRows[i].Bytes));
  Result := -1;
end;

procedure TCreateWizard.GridMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  col, row: Integer;
begin
  if Button <> mbRight then Exit;
  FGrid.MouseToCell(X, Y, col, row);
  if RowOfGrid(row) < 0 then Exit;
  FGrid.Row := row;
  BuildRowMenu(RowOfGrid(row));
  if FRowMenu.Items.Count = 0 then Exit;
  {$IFNDEF DARWIN}
  ThemePopupMenu(FRowMenu);
  {$ENDIF}
  FRowMenu.PopUp(Mouse.CursorPos.X, Mouse.CursorPos.Y);
end;

procedure TCreateWizard.EditorContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
var
  pt: TPoint;
begin
  BuildRowMenu(RowOfGrid(FGrid.Row));
  if FRowMenu.Items.Count = 0 then Exit;
  if Sender is TCustomEdit then AddEditCommands(FRowMenu, TCustomEdit(Sender));
  Handled := True;
  if (MousePos.X < 0) and (MousePos.Y < 0) and (Sender is TControl) then
    pt := TControl(Sender).ClientToScreen(Point(0, TControl(Sender).Height))
  else
    pt := Mouse.CursorPos;
  {$IFNDEF DARWIN}
  ThemePopupMenu(FRowMenu);
  {$ENDIF}
  FRowMenu.PopUp(pt.X, pt.Y);
end;

procedure TCreateWizard.BuildRowMenu(ARow: Integer);
var
  item: TMenuItem;
begin
  if FRowMenu = nil then FRowMenu := TPopupMenu.Create(Self);
  FRowMenu.Items.Clear;
  FMenuRow := ARow;
  if (ARow < 0) or (ARow > High(FRows)) then Exit;
  if IsSecretRow(ARow) and SecretsAllowed and not FRows[ARow].Locked then
  begin
    item := TMenuItem.Create(FRowMenu);
    item.Caption := rsCwSetSecretMenu;
    item.OnClick := @SecretMenuClick;
    item.Enabled := not Tasks.Pending('nextid') and (FFileTask = 0) and not Tasks.WritesInFlight;
    FRowMenu.Items.Add(item);
  end;
  if IsNextIdAttribute(FRows[ARow].Attr, FPlan.Provider) and not FRows[ARow].Locked then
  begin
    item := TMenuItem.Create(FRowMenu);
    item.Caption := Format(rsCwNextIdMenu, [AttrBaseName(FRows[ARow].Attr)]);
    item.OnClick := @NextIdMenuClick;
    item.Enabled := not Tasks.Pending('nextid') and (FFileTask = 0) and not Tasks.WritesInFlight;
    FRowMenu.Items.Add(item);
  end;
end;

procedure TCreateWizard.NextIdMenuClick(Sender: TObject);
begin
  StartNextId(FMenuRow);
end;

procedure TCreateWizard.StartNextId(ARow: Integer);
var
  c: TDirectoryConnection;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  if (c = nil) or not c.IsReady or Tasks.Pending('nextid') or (FFileTask <> 0) then Exit;
  if (ARow < 0) or (ARow > High(FRows)) or FRows[ARow].Locked or
     not IsNextIdAttribute(FRows[ARow].Attr, FPlan.Provider) then Exit;
  CommitGrid;
  FIdBase := NextIdBaseFor(FCtx.Connections.Find(FProfileUuid), FPlan.ParentDn);
  if FIdBase = '' then
  begin
    FAttrNote.Caption := Format(rsCwNextIdNoBase, [FPlan.ParentDn]);
    Exit;
  end;
  FIdAttr := AttrBaseName(FRows[ARow].Attr);
  FIdRow := ARow;
  FIdGen := FRowsGen;
  FIdScan := TNextIdScan.Create(FIdAttr);
  if Tasks.Search('nextid', NextIdSearchRequest(c.Profile, FIdBase, FIdAttr)) = 0 then
  begin
    FreeAndNil(FIdScan);
    FAttrNote.Caption := rsCwTaskBusy;
    Exit;
  end;
  FAttrNote.Caption := Format(rsCwNextIdSearching, [FIdAttr, FIdBase]);
  UpdateButtons;
end;

procedure TCreateWizard.DropNextId;
begin
  Tasks.Cancel('nextid');
  FreeAndNil(FIdScan);
end;

procedure TCreateWizard.HandleIdResult(AMsg: TUiMessage);
var
  m: TEntriesMsg;
  i: Integer;
  candidate: Int64;
  highest, reason: string;
begin
  if AMsg is TTaskFailedMsg then
  begin
    FAttrNote.Caption := Format(rsCwNextIdFailed, [FIdAttr, TTaskFailedMsg(AMsg).Text]);
    FCtx.Log(mlWarning, rsCwTitle, FAttrNote.Caption);
    DropNextId;
    UpdateButtons;
    Exit;
  end;
  if not (AMsg is TEntriesMsg) then Exit;
  m := TEntriesMsg(AMsg);
  if m.Entries <> nil then
    for i := 0 to m.Entries.Count - 1 do FIdScan.Feed(TLdapEntry(m.Entries[i]));
  if not m.Final then Exit;
  try
    candidate := FIdScan.NextId;
    if FIdScan.Found > 0 then highest := FIdScan.HighestText else highest := rsCwNextIdNone;
    // Enumeration incomplete: aucun maximum n'est sur, rien n'est pose. Un uidNumber en double,
    // ca se paie plus tard, et cher.
    if SearchOutcome(m.Completion) <> soComplete then
    begin
      reason := ResultCodeName(m.Completion.ResultCode);
      if m.Completion.SizeLimitHit then reason := 'size limit'
      else if m.Completion.TimeLimitHit then reason := 'time limit'
      else if m.Completion.Cancelled then reason := 'cancelled';
      FAttrNote.Caption := Format(rsCwNextIdIncomplete, [FIdAttr, FIdBase, reason]);
      FCtx.Log(mlWarning, rsCwTitle, FAttrNote.Caption);
      Exit;
    end;
    if candidate = 0 then
    begin
      FAttrNote.Caption := Format(rsCwNextIdExhausted, [FIdAttr, highest]);
      FCtx.Log(mlWarning, rsCwTitle, FAttrNote.Caption);
      Exit;
    end;
    if (FPage <> wpAttributes) or (FIdGen <> FRowsGen) or (FIdRow > High(FRows)) or
       FRows[FIdRow].Locked or FRows[FIdRow].FromFile or
       not SameText(AttrBaseName(FRows[FIdRow].Attr), FIdAttr) then
    begin
      FAttrNote.Caption := Format(rsCwNextIdStale, [FIdAttr, candidate]);
      FCtx.Log(mlWarning, rsCwTitle, FAttrNote.Caption);
      Exit;
    end;
    CommitGrid;
    FRows[FIdRow].Text := IntToStr(candidate);
    RefreshGrid;
    CommitGrid;
    FAttrNote.Caption := Format(rsCwNextIdSet, [FIdAttr, candidate, highest, FIdScan.Found, FIdBase]);
    FCtx.Log(mlInfo, rsCwTitle, FAttrNote.Caption);
  finally
    DropNextId;
    UpdateButtons;
  end;
end;

function TCreateWizard.RowMenuText(const AAttr: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FRows) do
    if SameText(FRows[i].Attr, AAttr) then
    begin
      BuildRowMenu(i);
      Break;
    end;
  if FRowMenu = nil then Exit;
  for i := 0 to FRowMenu.Items.Count - 1 do
  begin
    if not FRowMenu.Items[i].Enabled then Result := Result + '-';
    Result := Result + FRowMenu.Items[i].Caption + '|';
  end;
end;

procedure TCreateWizard.FindNextIdFor(const AAttr: string);
var
  i: Integer;
begin
  for i := 0 to High(FRows) do
    if SameText(FRows[i].Attr, AAttr) and not FRows[i].Locked then
    begin
      StartNextId(i);
      Exit;
    end;
end;

function TCreateWizard.ValueTextOf(const AAttr: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FRows) do
    if SameText(FRows[i].Attr, AAttr) then Exit(FRows[i].Text);
end;

function TCreateWizard.AttributeNote: string;
begin
  Result := FAttrNote.Caption;
end;

procedure TCreateWizard.EnterPreview;
var
  c: TDirectoryConnection;
  i: Integer;
  issues: TPlanIssues;
  masked: TLdapEntry;
  sev: string;
begin
  FreeAndNil(FEntry);
  FPreview.Clear;
  c := FCtx.Connections.Find(FProfileUuid);
  if c = nil then
  begin
    FPreviewIssues := nil;
    FPreview.Lines.Add(rsCwNoConnection);
    Exit;
  end;
  FEntry := BuildCreationEntry(c.Schema, FPlan, FAnalysis, FCtx.Sensitive, issues);
  FPreviewIssues := Copy(FEncodeIssues, 0, Length(FEncodeIssues));
  for i := 0 to High(issues) do
  begin
    SetLength(FPreviewIssues, Length(FPreviewIssues) + 1);
    FPreviewIssues[High(FPreviewIssues)] := issues[i];
  end;
  if HasErrors(FEncodeIssues) then FreeAndNil(FEntry);
  if Length(FPreviewIssues) > 0 then
  begin
    FPreview.Lines.Add(rsCwIssues);
    for i := 0 to High(FPreviewIssues) do
    begin
      if FPreviewIssues[i].Severity = isError then sev := '# ERROR: ' else sev := '# warning: ';
      FPreview.Lines.Add(sev + FPreviewIssues[i].Text);
    end;
    FPreview.Lines.Add('');
  end;
  if FEntry <> nil then
  begin
    masked := FEntry.Clone;
    try
      for i := 0 to masked.AttrCount - 1 do
        if FCtx.Sensitive.IsSensitive(masked.Attrs[i].Description) then
          masked.Attrs[i].SetValues([MASK_TEXT]);
      FPreview.Lines.Add(string(LdifEntryToString(masked)));
    finally
      masked.Free;
    end;
    FPreview.Lines.Add(rsCwStepsTitle);
    for i := 0 to High(FPlan.Steps) do
      FPreview.Lines.Add(Format('# %d. %s', [i + 1, StepText(FPlan.Steps[i].Kind)]));
    StartExistsCheck;
  end
  else
  begin
    FExistsLabel.Caption := rsCwFixFirst;
  end;
end;

procedure TCreateWizard.StartExistsCheck;
begin
  if FEntry = nil then Exit;
  FExistsLabel.Caption := rsCwNotChecked;
  StartRead(rpExists, ['1.1']);
end;

procedure TCreateWizard.StartPasswordStep;
begin
  PasswordClick(nil);
end;

procedure TCreateWizard.StartEnableStep;
begin
  EnableClick(nil);
end;

procedure TCreateWizard.StartReconcile;
begin
  CheckClick(nil);
end;

procedure TCreateWizard.AcceptReconciled;
begin
  AcceptClick(nil);
end;

function TCreateWizard.ResultText: string;
begin
  Result := FResultNote.Caption;
end;

function TCreateWizard.ExistsText: string;
begin
  Result := FExistsLabel.Caption;
end;

function TCreateWizard.CreateEnabled: Boolean;
begin
  Result := (FPage = wpPreview) and FNext.Enabled;
end;

function TCreateWizard.PreviewText: string;
begin
  Result := FPreview.Text;
end;

function TCreateWizard.GoNext: Boolean;
var
  dn, err: string;
begin
  Result := False;
  UpdateButtons;
  if not FNext.Enabled then Exit;
  case FPage of
    wpStructural:
      if EnterAuxiliary then
      begin
        ShowPage(wpAuxiliary);
        Result := True;
      end;
    wpAuxiliary:
      if EnterNaming then
      begin
        ShowPage(wpNaming);
        Result := True;
      end;
    wpNaming:
      begin
        ReadNaming;
        if not BuildCreationDn(FPlan.ParentDn, FPlan.Rdn, dn, err) then
        begin
          RtMessageDlg(rsCwTitle, err, mtWarning, [mbOK], 0);
          Exit;
        end;
        EnterAttributes;
        ShowPage(wpAttributes);
        Result := True;
      end;
    wpAttributes:
      begin
        CommitGrid;
        EnterPreview;
        ShowPage(wpPreview);
        Result := True;
      end;
    wpPreview:
      begin
        SubmitAdd;
        Result := FPage = wpResult;
      end;
  end;
end;

procedure TCreateWizard.GoBack;
begin
  case FPage of
    wpAuxiliary: ShowPage(wpStructural);
    wpNaming: ShowPage(wpAuxiliary);
    wpAttributes:
      begin
        CommitGrid;
        ShowPage(wpNaming);
      end;
    wpPreview:
      begin
        EnterAttributes;
        ShowPage(wpAttributes);
      end;
    wpResult:
      begin
        EnterPreview;
        ShowPage(wpPreview);
      end;
  end;
end;

procedure TCreateWizard.NextClick(Sender: TObject);
begin
  GoNext;
end;

procedure TCreateWizard.BackClick(Sender: TObject);
begin
  GoBack;
end;

function TCreateWizard.CheckIdentityOfSession(out AReason: string): Boolean;
var
  c: TDirectoryConnection;
begin
  Result := False;
  AReason := '';
  c := FCtx.Connections.Find(FProfileUuid);
  if (c = nil) or not c.IsReady then
  begin
    AReason := rsCwNoConnection;
    Exit;
  end;
  if c.Profile.ReadOnly then
  begin
    AReason := rsCwReadOnly;
    Exit;
  end;
  if (c.SessionId <> FPlan.SessionId) or (c.Generation <> FPlan.Generation) then
  begin
    FPlan.SessionId := c.SessionId;
    FPlan.Generation := c.Generation;
    AReason := rsCwSessionChanged;
    Exit;
  end;
  if SchemaIdentity(c.Schema) <> FPlan.SchemaKey then
  begin
    FPlan.SchemaKey := SchemaIdentity(c.Schema);
    FAnalysis := AnalyzeClasses(c.Schema, FPlan.Structural, FPlan.Auxiliaries, FPlan.Provider);
    AReason := rsCwSchemaChanged;
    Exit;
  end;
  Result := True;
end;

procedure TCreateWizard.SubmitAdd;
var
  change: TLdapChange;
  werr: TLdapError;
  reason: string;
begin
  if (FEntry = nil) or HasErrors(FPreviewIssues) or Tasks.WritesInFlight then Exit;
  if not CheckIdentityOfSession(reason) then
  begin
    RtMessageDlg(rsCwTitle, reason, mtWarning, [mbOK], 0);
    EnterPreview;
    UpdateButtons;
    Exit;
  end;
  change := NewChange(ckAdd, FEntry.Dn);
  change.Entry.Free;
  change.Entry := FEntry.Clone;
  // Session et schema verifies avant la confirmation, retrouves inchanges apres: le plan revu
  // est celui qui part, dans cette session.
  if not ConfirmWrite(Self, FCtx, Tasks, [change], reason) then
  begin
    change.Free;
    if reason <> '' then
    begin
      RtMessageDlg(rsCwTitle, reason, mtWarning, [mbOK], 0);
      CheckIdentityOfSession(reason);
      EnterPreview;
      UpdateButtons;
    end;
    Exit;
  end;
  if FReadPurpose = rpExists then
  begin
    Tasks.Cancel('read');
    FReadPurpose := rpNone;
  end;
  FWriteStep := cskAdd;
  if Tasks.Write('write', change, '', werr) = 0 then
    SetStep(cskAdd, sotNotSent, ErrorToText(werr))
  else
    SetStep(cskAdd, sotPending, '');
  ShowPage(wpResult);
  RefreshSteps;
end;

procedure TCreateWizard.SetStep(AKind: TCreationStepKind; AOutcome: TStepOutcome; const ADetail: string);
var
  i: Integer;
begin
  i := FPlan.StepIndex(AKind);
  if i < 0 then Exit;
  FPlan.Steps[i].Outcome := AOutcome;
  FPlan.Steps[i].Detail := ADetail;
  RefreshSteps;
end;

function TCreateWizard.StepOutcome(AKind: TCreationStepKind): TStepOutcome;
var
  i: Integer;
begin
  i := FPlan.StepIndex(AKind);
  if i < 0 then Exit(sotPending);
  Result := FPlan.Steps[i].Outcome;
end;

function TCreateWizard.StepCellIcon(Sender: TObject; AIndex, ACol: Integer; out AColor: TColor): string;
begin
  Result := '';
  AColor := clAppFg;
  if (ACol <> 1) or (AIndex < 0) or (AIndex > High(FPlan.Steps)) then Exit;
  case FPlan.Steps[AIndex].Outcome of
    sotNotSent:
      begin
        Result := 'circle-minus';
        AColor := ShellStateColor(usWarning);
      end;
    sotRefused:
      begin
        Result := 'circle-x';
        AColor := ShellStateColor(usError);
      end;
    sotApplied:
      begin
        Result := 'circle-check';
        AColor := ShellStateColor(usOk);
      end;
    sotAppliedUnverified:
      begin
        Result := 'circle-check';
        AColor := ShellStateColor(usWarning);
      end;
    sotUnknown:
      begin
        Result := 'help-circle';
        AColor := clDiffUnknown;
      end;
    sotSkipped:
      begin
        Result := 'circle-minus';
        AColor := ShellStateColor(usMuted);
      end;
  else
    Result := 'circle-dashed';
    AColor := ShellStateColor(usMuted);
  end;
end;

procedure TCreateWizard.RefreshSteps;
var
  i: Integer;
begin
  FSteps.Clear;
  for i := 0 to High(FPlan.Steps) do
    FSteps.AddRow([StepText(FPlan.Steps[i].Kind), OutcomeText(FPlan.Steps[i].Outcome),
      FPlan.Steps[i].Detail]);
  UpdateButtons;
end;

procedure TCreateWizard.StartRead(APurpose: TReadPurpose; const AAttrs: array of string);
var
  c: TDirectoryConnection;
  dn: string;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  if (c = nil) or not c.IsReady then Exit;
  if FCreatedDn <> '' then dn := FCreatedDn
  else if FEntry <> nil then dn := FEntry.Dn
  else Exit;
  FReadPurpose := APurpose;
  Tasks.Cancel('read');
  Tasks.ReadEntry('read', dn, AAttrs);
  UpdateButtons;
end;

procedure TCreateWizard.PasswordClick(Sender: TObject);
var
  c: TDirectoryConnection;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  UpdateButtons;
  if (c = nil) or not FPwdButton.Enabled then Exit;
  if (FPwd1.Text = '') or (FPwd2.Text = '') then
  begin
    FResultNote.Caption := rsCwPwdEmpty;
    Exit;
  end;
  if FPwd1.Text <> FPwd2.Text then
  begin
    FResultNote.Caption := rsCwPwdMismatch;
    Exit;
  end;
  if not c.SecretsSafe then
  begin
    FResultNote.Caption := rsCwPwdClear;
    Exit;
  end;
  // objectGUID relu avant tout envoi du secret. AD n'a pas de controle d'assertion pour lier
  // cette identite a l'ecriture: la fenetre entre relecture et ecriture existe, on ne pretend
  // pas le contraire.
  FResultNote.Caption := rsCwReading;
  StartRead(rpPassword, ['objectGUID', 'objectClass']);
end;

procedure TCreateWizard.EnableClick(Sender: TObject);
var
  i: Integer;
  attrs: TStringArray;
begin
  i := FPlan.StepIndex(cskSetPassword);
  if (i >= 0) and not (FPlan.Steps[i].Outcome in [sotApplied, sotAppliedUnverified]) then
  begin
    FResultNote.Caption := rsCwEnableNeedsPassword;
    Exit;
  end;
  UpdateButtons;
  if not FEnableButton.Enabled then Exit;
  FResultNote.Caption := rsCwReading;
  attrs := AccountReadAttributes(adActiveDirectory);
  SetLength(attrs, Length(attrs) + 1);
  attrs[High(attrs)] := 'objectGUID';
  StartRead(rpEnable, attrs);
end;

procedure TCreateWizard.CheckClick(Sender: TObject);
begin
  FReconcileFound := False;
  FReconcileGuid := '';
  StartRead(rpReconcile, ['objectGUID', 'objectClass']);
end;

procedure TCreateWizard.AcceptClick(Sender: TObject);
begin
  // Decision explicite: l'entree trouvee est celle du plan, son objectGUID devient l'identite
  // exigee par la suite. Une autre entree au meme DN sera refusee.
  if not FReconcileFound or (FReconcileGuid = '') then Exit;
  FIdentity := FReconcileGuid;
  SetStep(cskAdd, sotAppliedUnverified, Format(rsCwReconcileFound, [FEntry.Dn]));
  FCreatedDn := FEntry.Dn;
  FReconcileFound := False;
  FReconcileGuid := '';
  UpdateButtons;
end;

function TCreateWizard.IdentityMatches(AEntry: TLdapEntry; out AReason: string): Boolean;
var
  guid: RawByteString;
begin
  AReason := '';
  Result := False;
  // Identite absente ou mal formee: rien n'est conclu, rien n'est envoye. Une absence n'est
  // jamais prise pour une premiere identite.
  guid := UsableObjectGuid(AEntry);
  if guid = '' then
  begin
    AReason := Format(rsCwIdentityUnknown, [AEntry.Dn]);
    Exit;
  end;
  if FIdentity = '' then
  begin
    FIdentity := guid;
    Exit(True);
  end;
  Result := guid = FIdentity;
  if not Result then AReason := Format(rsCwIdentityChanged, [AEntry.Dn]);
end;

procedure TCreateWizard.ContinuePassword(AEntry: TLdapEntry);
var
  c: TDirectoryConnection;
  change: TLdapChange;
  pw: RawByteString;
  werr: TLdapError;
  reason: string;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  if c = nil then Exit;
  if not IdentityMatches(AEntry, reason) then
  begin
    FResultNote.Caption := reason;
    Exit;
  end;
  pw := FPwd1.Text;
  WipeEdit(FPwd1);
  WipeEdit(FPwd2);
  change := NewChange(ckModify, AEntry.Dn);
  try
    change.AddMod(moReplace, 'unicodePwd', [EncodeUnicodePwd(pw)]);
  finally
    WipeString(pw);
  end;
  if FMustChange.Checked then
    change.AddMod(moReplace, 'pwdLastSet', ['0']);
  if not ConfirmWrite(Self, FCtx, Tasks, [change], reason) then
  begin
    change.Free;
    FResultNote.Caption := reason;
    Exit;
  end;
  FWriteStep := cskSetPassword;
  if Tasks.Write('write', change, '', werr) = 0 then SetStep(cskSetPassword, sotNotSent, ErrorToText(werr));
  FResultNote.Caption := '';
  UpdateButtons;
end;

procedure TCreateWizard.ContinueEnable(AEntry: TLdapEntry);
var
  c: TDirectoryConnection;
  change: TLdapChange;
  werr: TLdapError;
  err, reason: string;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  if c = nil then Exit;
  if not IdentityMatches(AEntry, reason) then
  begin
    FResultNote.Caption := reason;
    Exit;
  end;
  // Valeur relue a l'instant, autres bits conserves, ancienne valeur supprimee et nouvelle
  // ajoutee dans la meme requete: si quelqu'un l'a changee entre-temps, le serveur refuse au
  // lieu d'ecraser.
  change := PlanAccountAction(AEntry, adActiveDirectory, aaEnable, UtcNow, err);
  if change = nil then
  begin
    FResultNote.Caption := err;
    Exit;
  end;
  if not ConfirmWrite(Self, FCtx, Tasks, [change], reason) then
  begin
    change.Free;
    FResultNote.Caption := reason;
    Exit;
  end;
  FWriteStep := cskEnable;
  if Tasks.Write('write', change, '', werr) = 0 then SetStep(cskEnable, sotNotSent, ErrorToText(werr));
  FResultNote.Caption := '';
  UpdateButtons;
end;

procedure TCreateWizard.LocalMessage(AMsg: TUiMessage);
var
  f: TValueFileMsg;
begin
  if AMsg is TValueFileMsg then
  begin
    f := TValueFileMsg(AMsg);
    if (FFileTask = 0) or (f.TaskId <> FFileTask) then Exit;
    FFileTask := 0;
    UpdateButtons;
    if not f.Ok then
    begin
      if not f.Cancelled then
        RtMessageDlg(rsCwTitle, Format(rsCwLoadFailed, [f.Path, f.ErrorText]), mtError, [mbOK], 0);
      Exit;
    end;
    // Le resultat ne va qu'a la ligne visee au lancement (meme generation, page, attribut),
    // sinon il est ecarte: mieux vaut recharger qu'ecraser la mauvaise valeur.
    if (FPage <> wpAttributes) or (FFileGen <> FRowsGen) or (FFileRow < 0) or
       (FFileRow > High(FRows)) or FRows[FFileRow].Locked or
       not SameText(FRows[FFileRow].Attr, FFileAttr) then
    begin
      FCtx.Log(mlWarning, rsCwTitle, Format(rsCwLoadStale, [f.Path, FFileAttr]));
      Exit;
    end;
    // Une valeur retouchee depuis le lancement n'est pas ecrasee par le fichier: la saisie prime,
    // le fichier est a recharger.
    CommitGrid;
    if FRows[FFileRow].Text <> FFileText then
    begin
      FCtx.Log(mlWarning, rsCwTitle, Format(rsCwLoadEdited, [f.Path, FFileAttr]));
      FAttrNote.Caption := Format(rsCwLoadEdited, [f.Path, FFileAttr]);
      Exit;
    end;
    FRows[FFileRow].Bytes := Copy(f.Data, 1, MaxInt);
    FRows[FFileRow].FromFile := True;
    RefreshGrid;
    CommitGrid;
  end;
end;

procedure TCreateWizard.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
begin
  if AEnding = teStale then
  begin
    if ATask.Tag = 'nextid' then DropNextId
    else if ATask.Tag = 'write' then
      // Ecriture partie dans l'ancienne session: rien n'est affirme.
      // Ni succes ni echec, un doute documente.
      SetStep(FWriteStep, sotUnknown, rsCwSessionLost)
    else if ATask.Tag = 'read' then
    begin
      FReadPurpose := rpNone;
      FResultNote.Caption := rsCwSessionLost;
    end;
    UpdateButtons;
    Exit;
  end;
  if ATask.Tag = 'nextid' then
    HandleIdResult(AMsg)
  else if ATask.Tag = 'write' then
    HandleWriteResult(AMsg)
  else if ATask.Tag = 'read' then
    HandleReadResult(AMsg);
end;

procedure TCreateWizard.HandleWriteResult(AMsg: TUiMessage);
var
  m: TWriteMsg;
  step: TCreationStepKind;
  outcome: TStepOutcome;
  detail: string;
begin
  step := FWriteStep;
  if AMsg is TTaskFailedMsg then
  begin
    SetStep(step, sotUnknown, TTaskFailedMsg(AMsg).Text);
    Exit;
  end;
  if not (AMsg is TWriteMsg) then Exit;
  m := TWriteMsg(AMsg);
  detail := '';
  if m.Result.Ok then
  begin
    if m.Reread <> nil then outcome := sotApplied else outcome := sotAppliedUnverified;
    detail := m.Note;
    if step = cskAdd then
    begin
      FCreatedDn := m.Change.Dn;
      if m.Reread <> nil then FIdentity := UsableObjectGuid(m.Reread);
      if FPlan.StepIndex(cskSetPassword) >= 0 then
        FResultNote.Caption := Format(rsCwCreated, [FCreatedDn]) + ' ' + rsCwAdDone
      else
        FResultNote.Caption := Format(rsCwCreated, [FCreatedDn]) + ' ' + rsCwOtherDone;
    end;
  end
  else if m.Result.Error.Category = lecUnknownOutcome then
  begin
    outcome := sotUnknown;
    detail := ErrorToText(m.Result.Error);
  end
  else
  begin
    if m.Result.Sent then outcome := sotRefused else outcome := sotNotSent;
    detail := ErrorToText(m.Result.Error);
  end;
  SetStep(step, outcome, detail);
end;

procedure TCreateWizard.HandleReadResult(AMsg: TUiMessage);
var
  e: TEntryMsg;
  purpose: TReadPurpose;
  dn: string;
begin
  purpose := FReadPurpose;
  FReadPurpose := rpNone;
  if FEntry <> nil then dn := FEntry.Dn else dn := FCreatedDn;
  if AMsg is TTaskFailedMsg then
  begin
    if purpose = rpExists then
      FExistsLabel.Caption := Format(rsCwExistsUnknown, [TTaskFailedMsg(AMsg).Text])
    else
      FResultNote.Caption := Format(rsCwIdentityGone, [dn, TTaskFailedMsg(AMsg).Text]);
    UpdateButtons;
    Exit;
  end;
  if not (AMsg is TEntryMsg) then Exit;
  e := TEntryMsg(AMsg);
  case purpose of
    rpExists:
      // Indication seulement: entre deux clients, c'est l'ajout qui tranche la course.
      if e.Entry <> nil then FExistsLabel.Caption := rsCwExists
      else if e.Error.Category = lecNoSuchObject then FExistsLabel.Caption := rsCwNotExists
      else FExistsLabel.Caption := Format(rsCwExistsUnknown, [ErrorToText(e.Error)]);
    rpReconcile:
      if e.Entry <> nil then
      begin
        FReconcileGuid := UsableObjectGuid(e.Entry);
        FReconcileFound := FReconcileGuid <> '';
        if FReconcileFound then
          FResultNote.Caption := Format(rsCwReconcileFound, [dn])
        else
          FResultNote.Caption := Format(rsCwReconcileNoGuid, [dn]);
      end
      else if e.Error.Category = lecNoSuchObject then
      begin
        SetStep(cskAdd, sotNotSent, Format(rsCwReconcileMissing, [dn]));
        FResultNote.Caption := Format(rsCwReconcileMissing, [dn]);
      end
      else
        FResultNote.Caption := Format(rsCwIdentityGone, [dn, ErrorToText(e.Error)]);
    rpPassword, rpEnable:
      if e.Entry = nil then
        FResultNote.Caption := Format(rsCwIdentityGone, [dn, ErrorToText(e.Error)])
      else if purpose = rpPassword then
        ContinuePassword(e.Entry)
      else
        ContinueEnable(e.Entry);
  end;
  UpdateButtons;
end;

function TCreateWizard.AllowCloseDuringWrite: Boolean;
begin
  Result := RtMessageDlg(rsCwTitle, rsCwPending, mtWarning, [mbYes, mbNo], 0) = mrYes;
end;

end.
