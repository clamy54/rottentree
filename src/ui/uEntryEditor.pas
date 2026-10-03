// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uEntryEditor;

{$mode objfpc}{$H+}

// Vue et edition de l'entree courante: grille des attributs, LDIF (secrets masques), schema.
// Tout se passe dans un tampon local; rien n'est ecrit ici. Apply remonte a l'onglet,
// qui a la lourde tache de toucher a la production.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, ExtCtrls, StdCtrls, Grids, Forms, Graphics, Dialogs,
  LCLType, Menus, uAppContext, uConnections, uLdapEntry, uChangeSet, uDirectoryWorker, uUiInbox,
  uNextId, uUniqueCheck, uConnectionProfile, uAttributeCodec, uValueFile, uIcons, uTaskTracker,
  uLdapErrors;

const
  EDITOR_PRECHECK_TAG = 'editor-precheck';
  VIEW_WRITE_TAG = 'write';

resourcestring
  rsDirAttribute = 'Attribute';
  rsDirValue = 'Value';
  rsDirSyntax = 'Syntax';
  rsDirInfo = 'Information';
  rsDirMaxLen = 'at most %d characters';
  rsDirUnknownSyntax = 'syntax not described by the server';
  rsDirExample = 'Example: %s';
  rsDirTabAttributes = 'Attributes';
  rsDirTabLdif = 'LDIF';
  rsDirTabSchema = 'Schema';
  rsDirAddValue = 'Add value...';
  rsDirEditValue = 'Edit value...';
  rsDirDeleteValue = 'Delete value';
  rsDirDeleteAttr = 'Delete attribute';
  rsDirNextIdMenu = 'Find next available %s';
  rsDirNextIdSearching = 'Searching the highest %s under %s...';
  rsDirNextIdSet = '%s: next available value %d (highest found: %s, %d value(s) read under %s).';
  rsDirNextIdNone = 'none';
  rsDirNextIdIncomplete = 'The search of %s under %s did not complete (%s): no value was set, a partial ' +
    'maximum could give a number already in use.';
  rsDirNextIdGone = '%s was removed from the entry meanwhile: the value found (%d) was not set.';
  rsDirNextIdExhausted = '%s: no identifier is available above the highest value found (%s): nothing was set.';
  rsDirLoadTargetChanged = 'The entry changed while the file was being chosen: %s was not loaded.';
  rsDirUniqueMenu = 'Check uniqueness of this %s';
  rsDirUniqueSearching = 'Searching other entries with this %s under %s...';
  rsDirUniqueTitle = 'Uniqueness of %s';
  rsDirUniqueOk = '%s "%s" is not used by any other entry under %s.';
  rsDirUniqueTaken = '%s "%s" is also used by %d other entr(y/ies) under %s:';
  rsDirUniqueMore = '... and %d more.';
  rsDirUniqueIncomplete = 'The search of %s "%s" under %s did not complete (%s): uniqueness is not established.';
  rsDirUniqueNoEquality = '%s has no equality matching rule in the schema: the server cannot compare its ' +
    'values, uniqueness cannot be checked.';
  rsDirUniqueCase = 'Comparison by the server with the equality rule of %s (%s).';
  rsDirLookupNoBase = 'No naming context of the server contains %s: the directory cannot be searched.';
  rsDirLookupFailed = 'The search of %s failed: %s';
  rsDirAddAttr = 'Add attribute...';
  rsDirApply = 'Apply...';
  rsDirRevert = 'Revert';
  rsDirPending = '%d pending change(s)';
  rsDirNoEntry = 'No entry selected.';
  rsDirBinary = '[%d bytes, binary] %s';
  rsDirTruncated = 'incomplete (range or size limit)';
  rsDirOperational = 'operational';
  rsDirReadOnlyAttr = 'not user-modifiable';
  rsDirMust = 'required';
  rsDirSingle = 'single-valued';
  rsDirSecretMasked = '[masked]';
  rsDirSchemaUnavailable = 'Schema unavailable: free input, validation by the server.';
  rsDirAttrPrompt = 'Attribute name';
  rsDirAddAttrTitle = 'Add attribute';
  rsDirAddAttrHelp = 'Attributes the object classes of this entry allow, and that it does not have yet ' +
    '(required ones first). To add a value to an attribute already present, use Add value. For an ' +
    'attribute of another kind, first add the object class that provides it.';
  rsDirAddClassButton = 'Add object class...';
  rsDirAddClassTitle = 'Add object class';
  rsDirAddClassHelp = 'Auxiliary object classes this entry does not have. The structural class of an ' +
    'entry cannot change; an auxiliary class adds attributes. Give its required attributes a value ' +
    'before Apply.';
  rsDirColAttribute = 'Attribute';
  rsDirColRequirement = 'Requirement';
  rsDirColSyntax = 'Type';
  rsDirColClass = 'Class';
  rsDirColRequires = 'Requires';
  rsDirColDescription = 'Description';
  rsDirChoicesUnavailable = 'The allowed attributes cannot be listed: %s. Type the attribute name; the ' +
    'server will refuse one that the object classes do not allow.';
  rsDirClassAdded = 'Object class %s added to the local changes; nothing is written before Apply.';
  rsDirSecretLater = 'Secret: set with the password tools, never typed in the grid.';
  rsDirValuePrompt = 'Value';
  rsDirReadOnlyProfile = 'Read-only profile: this entry cannot be changed from here';
  rsDirReadOnlyLdif = 'LDIF file opened read-only: this entry cannot be changed from here';
  rsDirDiscardEdits = 'Attribute changes on %s were not applied. Discard them?';
  rsDirReadPending = 'Reading the entry, editing is suspended.';
  rsDirNotInSchema = '(not in schema)';
  rsDirCachedSchema = '# cached schema, may be outdated';
  rsDirUnknownClass = '# unknown class %s';

  rsDirConflict = 'The entry changed on the server since it was read. Nothing was written.';
  rsDirUnknownOutcome = 'The write result is unknown. The entry was not re-sent: read it again before any retry.';
  rsDirWriteSessionLost = 'The connection changed while a write was waiting for the server: its outcome ' +
    'is unknown (recorded in the log). Read the entry again before any retry.';
  rsDirPrecheckSessionLost = 'the connection changed during the check';
  rsDirDeleteProtectedHint = 'If the object is protected from accidental deletion, remove the protection ' +
    'first (Deletion protection... in the tree menu).';
  rsDirNoAssertion = 'The server does not announce the Assertion control: the entry is read again just before writing; a residual race cannot be excluded.';
  rsDirPrecheckFailed = 'The entry could not be read back completely before writing. Nothing was written. %s';
  rsDirPrecheckCancelled = 'The pre-write read was cancelled. Nothing was written. %s';
  rsDirPrecheckViewChanged = 'The view was replaced meanwhile.';
  rsDirPrecheckPending = 'Checking the entry on the server before writing, editing is suspended.';
  rsDirEditedBeforeWrite = 'The attributes changed after the change was confirmed. Nothing was written; apply again to review the new change.';
  rsDirRereadNotShown = 'Write applied to %s; the view shows another entry and was not replaced.';
  rsDirRereadEditsKept = 'Write applied to %s; the attributes were edited meanwhile, so the view was not replaced. Refresh the entry to see the server state.';
  rsDirRereadFailed = '%s';
  rsDirOpenValue = 'Open value...';
  rsDirGoToDn = 'Go to %s';
  rsDirLoadValue = 'Load value from file...';
  rsDirSaveValue = 'Save value to file...';
  rsDirInspectCert = 'Inspect as certificate...';
  rsDirLoadQuestion = 'Add the content of the file as a new value of %s, or replace the selected value?';
  rsDirLoadSingleQuestion = '%s holds a single value: replace it with the content of the file?';
  rsDirLoadAdd = 'Add a new value';
  rsDirLoadReplace = 'Replace the selected value';
  rsDirLoadCancel = 'Cancel';
  rsDirLoading = 'Reading %s...';
  rsDirLoaded = '%s: %d byte(s) read from %s into the local changes; nothing is written before Apply.';
  rsDirLoadFailed = '%s was not loaded: %s';
  rsDirLoadStale = 'The attributes changed while %s was read: its content was not loaded.';
  rsDirLoadEntryLimit = 'The entry would exceed %d bytes: the content of %s was not loaded.';
  rsDirSaved = '%s written.';
  rsDirSaveFailed = 'The value was not saved to %s: %s';
  rsDirTaskBusy = 'Too many background tasks: try again in a moment.';
  rsDirValueChangedMeanwhile = 'The value changed while its dialog was open: the edit was not applied.';
  rsDirInvalidValues = 'These values do not match their syntax; nothing was sent:';
  rsDirConflictRead = '# read';
  rsDirConflictLocal = '# local change';
  rsDirConflictServer = '# the current server state is read again into the attributes view';

type
  TConnectionLookup = function: TDirectoryConnection of object;
  TMenuPopupFn = procedure(AMenu: TPopupMenu; X, Y: Integer);

var
  EntryMenuPopupOverride: TMenuPopupFn = nil;

type
  TEntryNotify = procedure(AEntry: TLdapEntry) of object;
  TDnNotify = procedure(const ADn: string) of object;

  TEntryEditor = class(TPanel)
  private
    FCtx: TAppContext;
    FGetConn: TConnectionLookup;
    FTitle: string;
    FDetailPages: TPageControl;
    FGrid: TStringGrid;
    FLdif: TMemo;
    FSchemaInfo: TMemo;
    FEditBar: TPanel;
    FEditRow, FEditRow2: TPanel;
    FBarButtons: array of TButton;
    FApplyButton, FRevertButton: TButton;
    FBarQueued: Boolean;
    FPendingLabel: TLabel;
    FReadOnlyIcon: TRtIcon;
    FOriginal: TLdapEntry;
    FEdited: TLdapEntry;
    FEditSerial: Int64;
    FInlineArmed: Boolean;
    FInlineDn: string;
    FRefreshQueued: Boolean;
    FReadPending: Boolean;
    FOnPasswordTools: TEntryNotify;
    FOnRereadRequest: TNotifyEvent;
    FViewTasks: TDirectoryTasks;
    FLookups: TDirectoryTasks;
    FProfileUuid: string;
    FWriteTask: Int64;
    FWriteSerial: Int64;
    FPrecheckTask: Int64;
    FPendingChange: TLdapChange;
    FRevealed: TStringList;
    FKeepRevealDn: string;
    FPlaceholderText: string;
    FEnterDown: Boolean;
    FSyntaxColSized: Boolean;
    FDeleteButton: TButton;
    FIdMenu: TPopupMenu;
    FMenuEdit: TCustomEdit;
    FIdMenuAttr: string;
    FIdMenuValue: RawByteString;
    FLookupTask: Int64;
    FLookupDn: string;
    FLookupBase: string;
    FLookupProfile: string;
    FNextIdScan: TNextIdScan;
    FUnique: TUniqueCheck;
    FUniqueReport: string;
    FUniqueReportType: TMsgDlgType;
    FFileTask: Int64;
    FFileDn: string;
    FFileAttr: string;
    FFileValueIndex: Integer;
    FFileOriginal: RawByteString;
    FFileSerial: Int64;
    FFilePath: string;
    FMenuRow: Integer;
    FMenuDn: string;
    FOnNavigate: TDnNotify;
    function ResolutionFor(const AAttr: string): TValueResolution;
    function ViewOf(const ARes: TValueResolution; const AAttr: string;
      const AValue: RawByteString): TAttributeValueView;
    procedure EditRow(ARow: Integer);
    procedure OpenValueDialog(ARow: Integer);
    procedure LoadValueFromFile(ARow: Integer; AAddOnly: Boolean = False);
    procedure AddTypedValue(AAttrIndex: Integer);
    procedure SaveValueToFile(ARow: Integer);
    procedure InspectCertificate(ARow: Integer);
    procedure HandleFileMsg(AMsg: TValueFileMsg);
    procedure CancelFileTask;
    procedure MenuOpenClick(Sender: TObject);
    procedure MenuLoadClick(Sender: TObject);
    procedure MenuSaveClick(Sender: TObject);
    procedure MenuCertClick(Sender: TObject);
    procedure MenuGoToClick(Sender: TObject);
    procedure UpdateDeleteCaption;
    function BarButton(AButton: TButton): TButton;
    procedure EditBarResize(Sender: TObject);
    procedure AsyncArrangeEditBar(AData: PtrInt);
    procedure GridGetCellHint(Sender: TObject; ACol, ARow: Integer; var HintText: string);
    procedure FitSyntaxColumn;
    procedure GridSelection(Sender: TObject; aCol, aRow: Integer);
    procedure NextIdClick(Sender: TObject);
    procedure UniqueClick(Sender: TObject);
    function LookupBase(c: TDirectoryConnection): string;
    function ServerKind: TProviderKind;
    procedure FinishNextId(AMsg: TEntriesMsg);
    procedure FinishUnique(AMsg: TEntriesMsg);
    procedure ShowUniqueReport(AData: PtrInt);
    procedure CancelLookup;
    procedure LookupMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure LocalMessage(AMsg: TUiMessage);
    function ViewWrite(AChange: TLdapChange; const AAssertion: string;
      const ARereadAttrs: array of string; out AError: TLdapError): Int64;
    procedure ShowConflict(AChange: TLdapChange);
    procedure BuildUi;
    procedure SetReadPending(AValue: Boolean);
    procedure ApplyButtonClick(Sender: TObject);
    function ValueDisplay(const AAttr: string; const AValue: RawByteString): string;
    function AttributeSyntax(const AAttr: string): string;
    function AttributeInfo(const AAttr: string; AAttribute: TLdapAttribute): string;
    function EqualityKnown(const AAttr: string): Boolean;
    procedure AddValueClick(Sender: TObject);
    procedure EditValueClick(Sender: TObject);
    procedure DeleteValueClick(Sender: TObject);
    procedure AddAttrClick(Sender: TObject);
    function PickAttribute(out AName: string): Boolean;
    function PickAuxiliaryClass: Boolean;
    procedure RevertClick(Sender: TObject);
    procedure GridKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure GridKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure GridMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure InlineContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure Touch;
    procedure SetRowRef(ARow, AAttr, AValue: Integer);
    procedure GetRowRef(ARow: Integer; out AAttr, AValue: Integer);
    function RowEditableInline(ARow: Integer): Boolean;
    procedure BeginInlineEdit(ARow: Integer);
    procedure GridSelectEditor(Sender: TObject; aCol, aRow: Integer; var Editor: TWinControl);
    procedure GridEditingDone(Sender: TObject);
    procedure GridDblClick(Sender: TObject);
    function IsRevealed(const AAttr: string): Boolean;
    procedure GridResize(Sender: TObject);
    procedure GridHeaderSized(Sender: TObject; IsColumn: Boolean; Index: Integer);
    procedure QueueRefresh;
    procedure DeferredRefresh(AData: PtrInt);
    procedure CancelInlineEditor;
  public
    constructor Create(AOwner: TComponent; ACtx: TAppContext; AGetConn: TConnectionLookup); reintroduce;
    destructor Destroy; override;
    procedure ApplyTheme;
    procedure ShowEntry(AEntry: TLdapEntry);
    procedure ShowPlaceholder(const AText: string);
    procedure RefreshGrid;
    procedure UpdateEditState;
    procedure ArrangeEditBar;
    function EditBarRows: Integer;
    function EditingAllowed: Boolean;
    // Valide la cellule en cours de saisie, une seule fois, avant toute inspection ou
    // remplacement du tampon: une frappe ne se perd pas dans une fermeture ou une reponse tardive.
    procedure CommitInlineEditor;
    function HasPendingEdits: Boolean;
    function ConfirmDiscardEdits: Boolean;
    function MaskedEntryLdif(AEntry: TLdapEntry): string;
    procedure ToggleReveal(const AAttr: string);
    procedure StartNextId(const AAttr: string);
    procedure StartUniqueCheck(const AAttr: string; const AValue: RawByteString);
    property LookupTask: Int64 read FLookupTask;
    procedure LoadFileInto(const AAttr: string; AValueIndex: Integer; const APath: string);
    property FileTask: Int64 read FFileTask;
    function InvalidEdits: string;
    procedure KeepRevealOnNextRead(const ADn: string);
    property Original: TLdapEntry read FOriginal;
    property Edited: TLdapEntry read FEdited;
    property EditSerial: Int64 read FEditSerial;
    function ReadOnlyNotice: string;
    property ReadPending: Boolean read FReadPending write SetReadPending;
    property Title: string read FTitle write FTitle;
    procedure SubmitChanges;
    function HandleWrite(AMsg: TWriteMsg): Boolean;
    procedure HandlePrecheck(AMsg: TEntryMsg);
    procedure CancelPrecheck(const AReason: string);
    procedure PrecheckDelivered(AMsg: TUiMessage; AEnding: TTaskEnding);
    property PrecheckTask: Int64 read FPrecheckTask;
    property ViewTasks: TDirectoryTasks read FViewTasks write FViewTasks;
    property ProfileUuid: string read FProfileUuid write FProfileUuid;
    property OnPasswordTools: TEntryNotify read FOnPasswordTools write FOnPasswordTools;
    property OnNavigate: TDnNotify read FOnNavigate write FOnNavigate;
    property OnRereadRequest: TNotifyEvent read FOnRereadRequest write FOnRereadRequest;
  end;

implementation

uses
  uTheme, uUiKit, uLdapSchema, uLdif, uRtBytes, uLdapFilter, uSensitive,
  uChangePreview, uDirectoryService, uRtMessage, uSearchModel, uMenuBar, uSyntaxInfo, uServerKind, uRtButton,
  uValueDialog, uLocalTime, uPasswordWork, uAttributeChoice, uPickDialog, uTaskDialog;

type
  // Classe d'acces: EditorShowInCell est protege dans la LCL.
  TGridAccess = class(TStringGrid);
  // Idem pour OnContextPopup, protege dans TControl.
  TPopupAccess = class(TControl);

constructor TEntryEditor.Create(AOwner: TComponent; ACtx: TAppContext; AGetConn: TConnectionLookup);
begin
  inherited Create(AOwner);
  FCtx := ACtx;
  FGetConn := AGetConn;
  BevelOuter := bvNone;
  Caption := '';
  FRevealed := TStringList.Create;
  FRevealed.CaseSensitive := False;
  FRevealed.Sorted := True;
  FRevealed.Duplicates := dupIgnore;
  FLookups := TDirectoryTasks.Create(FCtx.Connections, '', Self);
  FLookups.OnMessage := @LookupMessage;
  FLookups.OnUntracked := @LocalMessage;
  BuildUi;
end;

destructor TEntryEditor.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  CancelLookup;
  FreeAndNil(FLookups);
  PasswordWork.CancelOwner(Self);
  FRevealed.Free;
  FOriginal.Free;
  FEdited.Free;
  FPendingChange.Free;
  inherited Destroy;
end;

procedure TEntryEditor.BuildUi;
var
  page: TTabSheet;
begin
  FEditBar := MakePanel(Self, alBottom, 38);
  FEditBar.OnResize := @EditBarResize;
  FEditRow := MakePanel(FEditBar, alTop, 38);
  FEditRow2 := MakePanel(FEditBar, alTop, 38);
  FEditRow2.Top := 38;
  FEditRow2.Visible := False;
  BarButton(MakeButton(FEditRow, rsDirAddValue, @AddValueClick));
  BarButton(MakeButton(FEditRow, rsDirEditValue, @EditValueClick));
  FDeleteButton := BarButton(MakeButton(FEditRow, rsDirDeleteValue, @DeleteValueClick));
  BarButton(MakeButton(FEditRow, rsDirAddAttr, @AddAttrClick));
  FReadOnlyIcon := TRtIcon.Create(FEditRow);
  FReadOnlyIcon.Parent := FEditRow;
  FReadOnlyIcon.Align := alLeft;
  FReadOnlyIcon.BorderSpacing.Left := 8;
  FReadOnlyIcon.BorderSpacing.Right := 6;
  FReadOnlyIcon.SetIcon('lock', 20, ShellStateColor(usError));
  FReadOnlyIcon.Visible := False;
  // Espace restant entre les boutons: une etiquette a taille automatique faisait osciller
  // la mise en page quand les boutons ne tiennent pas (ELayoutException). La LCL tourne en rond, pas nous.
  FPendingLabel := MakeLabel(FEditRow, '', alClient);
  FPendingLabel.WordWrap := False;
  FPendingLabel.AutoSize := False;
  FPendingLabel.Layout := tlCenter;
  FRevertButton := BarButton(MakeButton(FEditRow, rsDirRevert, @RevertClick, alRight));
  FApplyButton := BarButton(MakeButton(FEditRow, rsDirApply, @ApplyButtonClick, alRight));

  FDetailPages := MakePages(Self);
  page := FDetailPages.AddTabSheet;
  page.Caption := rsDirTabAttributes;
  FGrid := TStringGrid.Create(page);
  FGrid.Parent := page;
  FGrid.Align := alClient;
  FGrid.ColCount := 4;
  FGrid.FixedCols := 0;
  FGrid.RowCount := 1;
  FGrid.FixedRows := 1;
  FGrid.Options := FGrid.Options + [goRowSelect, goColSizing, goThumbTracking, goEditing] -
    [goRangeSelect, goAlwaysShowEditor];
  // Pendant l'edition, gauche/droite bougent le curseur. Avec FastEditing (defaut LCL), une fleche
  // au bord du texte, ou sur un texte tout selectionne, change de cellule (grids.pas, TStringCellEditor.KeyDown).
  FGrid.FastEditing := False;
  FGrid.Cells[0, 0] := rsDirAttribute;
  FGrid.Cells[1, 0] := rsDirValue;
  FGrid.Cells[2, 0] := rsDirSyntax;
  FGrid.Cells[3, 0] := rsDirInfo;
  FGrid.ColWidths[0] := 180;
  FGrid.ColWidths[1] := 420;
  FGrid.ColWidths[2] := 240;
  FGrid.ColWidths[3] := 320;
  FGrid.OnResize := @GridResize;
  FGrid.OnHeaderSized := @GridHeaderSized;
  FGrid.OnKeyDown := @GridKeyDown;
  FGrid.OnKeyUp := @GridKeyUp;
  FGrid.OnDblClick := @GridDblClick;
  FGrid.OnMouseDown := @GridMouseDown;
  FGrid.OnSelectEditor := @GridSelectEditor;
  FGrid.OnEditingDone := @GridEditingDone;
  FGrid.OnSelection := @GridSelection;
  FGrid.Options := FGrid.Options + [goCellHints];
  FGrid.ShowHint := True;
  FGrid.OnGetCellHint := @GridGetCellHint;
  FLdif := MakeMemo(AddPageBody(FDetailPages, rsDirTabLdif));
  FLdif.ReadOnly := True;
  FSchemaInfo := MakeMemo(AddPageBody(FDetailPages, rsDirTabSchema));
  FSchemaInfo.ReadOnly := True;
  UpdateEditState;
end;

procedure TEntryEditor.ApplyTheme;
begin
  FGrid.DefaultRowHeight := FontTextHeight(FGrid.Font) + 8;
  FGrid.GridLineColor := clBorder;
  FGrid.FixedGridLineColor := clBorder;
  FGrid.BorderStyle := bsNone;
  FGrid.Font.Color := clAppFg;
  FGrid.Color := clAppBg;
  FGrid.AlternateColor := BlendColor(clAppBg, clSideBg, 60);
  FGrid.FixedColor := clSideBg;
  FGrid.SelectedColor := clSideSel;
  FLdif.Color := clEditorBg;
  FLdif.Font.Color := clEditorFg;
  FSchemaInfo.Color := clEditorBg;
  FSchemaInfo.Font.Color := clEditorFg;
  UpdateEditState;
  StyleMemo(FLdif);
  StyleMemo(FSchemaInfo);
end;

procedure TEntryEditor.SetReadPending(AValue: Boolean);
begin
  if AValue then
    // Grille visible mais figee jusqu'a la reponse: ce qu'on taperait pendant l'attente
    // serait ecrase par l'entree lue, sans un mot.
    CommitInlineEditor;
  FReadPending := AValue;
  UpdateEditState;
end;

procedure TEntryEditor.ApplyButtonClick(Sender: TObject);
begin
  SubmitChanges;
end;

procedure TEntryEditor.SubmitChanges;
var
  c: TDirectoryConnection;
  plan: TModifyPlan;
  note, reason: string;
  werr: TLdapError;
  serial: Int64;
begin
  CommitInlineEditor;
  c := FGetConn();
  if (c = nil) or (FOriginal = nil) or not EditingAllowed then Exit;
  // La confirmation montre CE delta, et c'est lui seul qui a le droit de partir.
  serial := FEditSerial;
  note := InvalidEdits;
  if note <> '' then
  begin
    RtMessageDlg(FTitle, rsDirInvalidValues + note, mtError, [mbOK], 0);
    Exit;
  end;
  if not PlanModify(FOriginal, FEdited, c.Schema, c.RootDse, plan) then
  begin
    RtMessageDlg(FTitle, plan.Error, mtError, [mbOK], 0);
    Exit;
  end;
  if plan.Change = nil then Exit;
  note := '';
  if plan.AssertionUnavailable and (c.Profile.LdifPath = '') then
    note := rsDirNoAssertion;
  // Delta calcule contre le schema et la session presents: les memes apres la confirmation,
  // sinon rien ne part.
  if not ConfirmWrite(GetParentForm(Self), FCtx, FViewTasks, [plan.Change], reason, note) then
  begin
    plan.Change.Free;
    if reason <> '' then RtMessageDlg(FTitle, reason, mtWarning, [mbOK], 0);
    Exit;
  end;
  // La boite est videe pendant le dialogue modal: une relecture a pu remplacer le tampon.
  // Le delta confirme n'est alors plus celui de l'ecran.
  if FEditSerial <> serial then
  begin
    plan.Change.Free;
    FCtx.Log(mlError, FTitle, rsDirEditedBeforeWrite);
    Exit;
  end;
  if plan.AssertionUnavailable then
  begin
    // Pas de precondition possible cote serveur: relecture juste avant l'ecriture. Le delta ne part
    // que si les attributs touches n'ont pas bouge et si le tampon n'a pas ete edite entre-temps.
    // La course residuelle a ete avouee a la confirmation.
    FPendingChange.Free;
    FPendingChange := plan.Change;
    FPrecheckTask := 0;
    if FViewTasks <> nil then
      FPrecheckTask := FViewTasks.ReadEntry(EDITOR_PRECHECK_TAG, FOriginal.Dn,
        EntryReadAttributes(c.Profile));
    FWriteSerial := FEditSerial;
    if FPrecheckTask = 0 then
      CancelPrecheck('')
    else
      UpdateEditState;
    Exit;
  end;
  FWriteTask := ViewWrite(plan.Change, plan.Assertion, EntryReadAttributes(c.Profile), werr);
  if FWriteTask = 0 then
    FCtx.Log(mlError, FTitle, ErrorToText(werr))
  else
    FWriteSerial := FEditSerial;
end;

function TEntryEditor.HandleWrite(AMsg: TWriteMsg): Boolean;
begin
  CommitInlineEditor;
  Result := AMsg.Result.Ok;
  if Result then
  begin
    FCtx.Log(mlInfo, FTitle, AMsg.Change.Describe);
    if AMsg.Note <> '' then
      FCtx.Log(mlWarning, FTitle, Format(rsDirRereadFailed, [AMsg.Note]));
    // La relecture ne remplace la vue que si c'est la meme entree, sans autre lecture
    // en attente, et sans edition depuis la soumission.
    if (AMsg.Reread <> nil) and not FReadPending and (FOriginal <> nil) and
       (AMsg.TaskId = FWriteTask) and (FEditSerial = FWriteSerial) and
       SameDnStrict(AMsg.Reread.Dn, FOriginal.Dn) then
    begin
      ShowEntry(AMsg.Reread);
      AMsg.Reread := nil;
    end
    else if (AMsg.Reread <> nil) and (FOriginal <> nil) and
      SameDnStrict(AMsg.Reread.Dn, FOriginal.Dn) then
      FCtx.Log(mlWarning, FTitle, Format(rsDirRereadEditsKept, [AMsg.Reread.Dn]))
    else if AMsg.Reread <> nil then
      FCtx.Log(mlInfo, FTitle, Format(rsDirRereadNotShown, [AMsg.Reread.Dn]));
    Exit;
  end;
  case AMsg.Result.Error.Category of
    lecAssertionFailed: ShowConflict(AMsg.Change);
    lecUnknownOutcome:
      begin
        FCtx.Log(mlError, FTitle, rsDirUnknownOutcome + ' ' + AMsg.Change.Describe);
        RtMessageDlg(FTitle, rsDirUnknownOutcome, mtWarning, [mbOK], 0);
      end;
  else
    FCtx.Log(mlError, FTitle, ErrorToText(AMsg.Result.Error) + ' - ' + AMsg.Change.Describe);
    // Suppression refusee sur AD: neuf fois sur dix, c'est la protection contre la
    // suppression accidentelle de la console (refus a Everyone). Elle fait son travail.
    if (AMsg.Change.Kind = ckDelete) and (AMsg.Result.Error.Category = lecAccessDenied) and
       (ServerKind = pkActiveDirectory) then
      RtMessageDlg(FTitle, ErrorToText(AMsg.Result.Error) + LineEnding + AMsg.Result.Error.Action +
        LineEnding + rsDirDeleteProtectedHint, mtError, [mbOK], 0)
    else
      RtMessageDlg(FTitle, ErrorToText(AMsg.Result.Error) + LineEnding + AMsg.Result.Error.Action,
        mtError, [mbOK], 0);
  end;
end;

procedure TEntryEditor.HandlePrecheck(AMsg: TEntryMsg);
var
  c: TDirectoryConnection;
  werr: TLdapError;
  change: TLdapChange;
begin
  FPrecheckTask := 0;
  if FPendingChange = nil then Exit;
  change := FPendingChange;
  FPendingChange := nil;
  try
    c := FGetConn();
    // Relecture illisible ou incomplete: elle ne prouve rien, donc rien n'est ecrit.
    if (c = nil) or (AMsg.Entry = nil) or AMsg.Entry.DecodeIncomplete or
      AMsg.Entry.AnyTruncated then
    begin
      FCtx.Log(mlError, FTitle,
        Format(rsDirPrecheckFailed, [ErrorToText(AMsg.Error)]));
      FreeAndNil(change);
      Exit;
    end;
    // Tampon change depuis la confirmation (ceinture et bretelles: l'edition est suspendue
    // pendant la relecture). Le delta confirme n'est plus celui de l'ecran, rien n'est ecrit.
    if FEditSerial <> FWriteSerial then
    begin
      FCtx.Log(mlError, FTitle, rsDirEditedBeforeWrite);
      FreeAndNil(change);
      Exit;
    end;
    if not TouchedAttributesUnchanged(FOriginal, AMsg.Entry, change) then
    begin
      FCtx.Log(mlError, FTitle, rsDirConflict);
      try
        ShowConflict(change);
      finally
        FreeAndNil(change);
      end;
      Exit;
    end;
    // Etat inchange sur les attributs touches: l'ecriture part. La course entre cette lecture
    // et l'ecriture existe toujours, elle a ete annoncee.
    FWriteTask := ViewWrite(change, '', EntryReadAttributes(c.Profile), werr);
    change := nil;   // propriete transferee, meme sur refus
    if FWriteTask = 0 then
      FCtx.Log(mlError, FTitle, ErrorToText(werr));
  finally
    change.Free;
    UpdateEditState;
  end;
end;

function TEntryEditor.ViewWrite(AChange: TLdapChange; const AAssertion: string;
  const ARereadAttrs: array of string; out AError: TLdapError): Int64;
begin
  if FViewTasks = nil then
  begin
    AChange.Free;
    AError := MakeError(lecOther, 0, 'write', 'no view to receive the result');
    Exit(0);
  end;
  Result := FViewTasks.Write(VIEW_WRITE_TAG, AChange, AAssertion, nil, ARereadAttrs, AError);
end;

procedure TEntryEditor.PrecheckDelivered(AMsg: TUiMessage; AEnding: TTaskEnding);
begin
  if AEnding = teStale then
    CancelPrecheck(rsDirPrecheckSessionLost)
  else if AMsg is TTaskFailedMsg then
    CancelPrecheck(TTaskFailedMsg(AMsg).Text)
  else if AMsg is TEntryMsg then
    HandlePrecheck(TEntryMsg(AMsg));
end;

procedure TEntryEditor.CancelPrecheck(const AReason: string);
begin
  if (FPrecheckTask = 0) and (FPendingChange = nil) then Exit;
  FPrecheckTask := 0;
  if FPendingChange <> nil then
    FCtx.Log(mlError, FTitle, Format(rsDirPrecheckCancelled, [AReason]));
  FreeAndNil(FPendingChange);
  UpdateEditState;
end;

procedure TEntryEditor.ShowConflict(AChange: TLdapChange);
var
  d: TRtDialog;
  cols: TPanel;
  m1, m2: TMemo;
  c: TDirectoryConnection;
begin
  c := FGetConn();
  d := TRtDialog.CreateDialog(GetParentForm(Self), rsDirConflict, 900, 560);
  d.SetIcon('alert-triangle');
  try
    if c <> nil then
      d.SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
    MakeLabel(d.Body, rsDirConflict);
    cols := MakePanel(d.Body, alClient);
    m1 := MakeMemo(cols, alLeft);
    m1.Width := 430;
    m1.ReadOnly := True;
    if FOriginal <> nil then
      m1.Text := rsDirConflictRead + LineEnding + MaskedEntryLdif(FOriginal);
    m2 := MakeMemo(cols, alClient);
    m2.ReadOnly := True;
    m2.Text := rsDirConflictLocal + LineEnding + MaskedChangeLdif(AChange, FCtx.Sensitive) +
      LineEnding + rsDirConflictServer;
    d.AddButton('OK', mrOk, True, True);
    d.ApplyTheme;
    d.ShowModal;
  finally
    d.Free;
  end;
  if Assigned(FOnRereadRequest) then FOnRereadRequest(Self);
end;

function TEntryEditor.HasPendingEdits: Boolean;
var
  mods: TLdapModArray;
  err: string;
  opts: TDeltaOptions;
begin
  Result := False;
  CommitInlineEditor;
  if (FOriginal = nil) or (FEdited = nil) then Exit;
  opts.EqualityKnown := @EqualityKnown;
  if ComputeModifications(FOriginal, FEdited, opts, mods, err) then
    Result := Length(mods) > 0
  else
    Result := True;
end;

function TEntryEditor.ConfirmDiscardEdits: Boolean;
begin
  Result := True;
  if not HasPendingEdits then Exit;
  Result := RtMessageDlg(FTitle, Format(rsDirDiscardEdits, [FOriginal.Dn]), mtConfirmation,
    [mbYes, mbNo], 0) = mrYes;
end;

procedure TEntryEditor.ShowEntry(AEntry: TLdapEntry);
begin
  CommitInlineEditor;
  if (FLookupTask <> 0) and not SameDnStrict(AEntry.Dn, FLookupDn) then CancelLookup;
  if FFileTask <> 0 then
  begin
    FCtx.Log(mlWarning, FTitle, Format(rsDirLoadStale, [FFilePath]));
    CancelFileTask;
  end;
  // Le tampon de reference change: un delta qui attendait sa relecture de pre-ecriture
  // n'a plus rien a quoi se comparer, il est abandonne.
  if FPendingChange <> nil then
    CancelPrecheck(rsDirPrecheckViewChanged);
  FOriginal.Free;
  AEntry.SortForDisplay;
  FOriginal := AEntry;
  FEdited.Free;
  FEdited := AEntry.Clone;
  Touch;
  // Secrets de nouveau masques, meme a la relecture de la meme entree, sauf relecture
  // demandee apres les outils de mot de passe.
  if (FKeepRevealDn = '') or not SameDnStrict(AEntry.Dn, FKeepRevealDn) then
    FRevealed.Clear;
  FKeepRevealDn := '';
  FPlaceholderText := '';
  RefreshGrid;
end;

procedure TEntryEditor.ShowPlaceholder(const AText: string);
begin
  CommitInlineEditor;
  if FLookupTask <> 0 then CancelLookup;
  if FFileTask <> 0 then
  begin
    FCtx.Log(mlWarning, FTitle, Format(rsDirLoadStale, [FFilePath]));
    CancelFileTask;
  end;
  if FPendingChange <> nil then
    CancelPrecheck(rsDirPrecheckViewChanged);
  FreeAndNil(FOriginal);
  FreeAndNil(FEdited);
  Touch;
  FRevealed.Clear;
  FKeepRevealDn := '';
  FPlaceholderText := AText;
  RefreshGrid;
  UpdateEditState;
end;

procedure TEntryEditor.Touch;
begin
  Inc(FEditSerial);
end;

procedure TEntryEditor.CommitInlineEditor;
begin
  if not FInlineArmed then
  begin
    if FGrid.EditorMode then FGrid.EditorMode := False;
    Exit;
  end;
  // Si la LCL n'a pas emis OnEditingDone en fermant l'editeur, on valide ici.
  // FInlineArmed garantit que ca n'arrive qu'une fois.
  if FGrid.EditorMode then FGrid.EditorMode := False;
  if FInlineArmed then GridEditingDone(FGrid);
end;

procedure TEntryEditor.CancelInlineEditor;
begin
  FInlineArmed := False;
  if FGrid.EditorMode then FGrid.EditorMode := False;
end;

function TEntryEditor.EditingAllowed: Boolean;
var
  c: TDirectoryConnection;
begin
  c := FGetConn();
  Result := (FEdited <> nil) and (FOriginal <> nil) and not FReadPending and
    (FPendingChange = nil) and (c <> nil) and c.IsReady and not c.Profile.ReadOnly;
end;

procedure TEntryEditor.SetRowRef(ARow, AAttr, AValue: Integer);
begin
  FGrid.Objects[0, ARow] := TObject(PtrInt(AAttr + 1));
  FGrid.Objects[1, ARow] := TObject(PtrInt(AValue + 3));
end;

procedure TEntryEditor.GetRowRef(ARow: Integer; out AAttr, AValue: Integer);
begin
  AAttr := -1;
  AValue := -1;
  if (ARow < 1) or (ARow >= FGrid.RowCount) or (FGrid.Objects[0, ARow] = nil) then Exit;
  AAttr := PtrInt(FGrid.Objects[0, ARow]) - 1;
  AValue := PtrInt(FGrid.Objects[1, ARow]) - 3;
end;

function TEntryEditor.RowEditableInline(ARow: Integer): Boolean;
var
  ai, vi: Integer;
  a: TLdapAttribute;
  res: TValueResolution;
  view: TAttributeValueView;
begin
  Result := False;
  if not EditingAllowed then Exit;
  GetRowRef(ARow, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  a := FEdited.Attrs[ai];
  // Secrets: jamais en texte libre (outils de mot de passe). Binaire: jamais en ligne.
  if FCtx.Sensitive.IsSensitive(a.Description) then Exit;
  res := ResolutionFor(a.Description);
  if res.ReadOnly then Exit;
  if vi >= 0 then
  begin
    if vi >= a.ValueCount then Exit;
    view := ViewOf(res, a.Description, a.Values[vi]);
    if not view.TextFaithful or (view.Display <> string(a.Values[vi])) then Exit;
  end
  else if not (res.Kind in [vkText, vkBoolean, vkInteger, vkDn, vkGeneralizedTime, vkAdFileTime,
    vkAdInterval]) then
    Exit;
  Result := True;
end;

procedure TEntryEditor.BeginInlineEdit(ARow: Integer);
begin
  if not RowEditableInline(ARow) then Exit;
  FGrid.Row := ARow;
  FGrid.Col := 1;
  if FGrid.CanFocus then FGrid.SetFocus;
  FInlineArmed := True;
  FInlineDn := FEdited.Dn;
  TGridAccess(FGrid).EditorShowInCell(1, ARow);
end;

procedure TEntryEditor.GridSelectEditor(Sender: TObject; aCol, aRow: Integer;
  var Editor: TWinControl);
begin
  if not FInlineArmed or (aCol <> 1) or not RowEditableInline(aRow) then
    Editor := nil
  else if Editor <> nil then
  begin
    Editor.Color := clEditorBg;
    Editor.Font := FGrid.Font;
    Editor.Font.Color := clEditorFg;
    TPopupAccess(Editor).OnContextPopup := @InlineContextPopup;
  end;
end;

procedure TEntryEditor.InlineContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
var
  r: TRect;
begin
  if not (Sender is TCustomEdit) then Exit;
  r := FGrid.CellRect(1, FGrid.Row);
  FMenuEdit := TCustomEdit(Sender);
  try
    GridMouseDown(FGrid, mbRight, [], (r.Left + r.Right) div 2, (r.Top + r.Bottom) div 2);
  finally
    FMenuEdit := nil;
  end;
  Handled := True;
end;

procedure TEntryEditor.GridEditingDone(Sender: TObject);
var
  row, ai, vi, j: Integer;
  a: TLdapAttribute;
  cell: string;
  values: array of RawByteString;
begin
  if not FInlineArmed then Exit;
  FInlineArmed := False;
  row := FGrid.Row;
  if (FEdited = nil) or (row < 1) or (row >= FGrid.RowCount) then Exit;
  // Le tampon a change de DN depuis l'ouverture de l'editeur: la saisie ne vise plus la bonne entree.
  if not SameDnStrict(FEdited.Dn, FInlineDn) then Exit;
  GetRowRef(row, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  a := FEdited.Attrs[ai];
  values := nil;
  cell := FGrid.Cells[1, row];
  if vi < 0 then
  begin
    if cell <> '' then
    begin
      a.AddValue(cell);
      Touch;
    end
    else if (a.ValueCount = 0) and (FOriginal.Find(a.Description) = nil) then
      FEdited.Remove(a.Description);
    QueueRefresh;
    Exit;
  end;
  if vi >= a.ValueCount then Exit;
  if cell = string(a.Values[vi]) then
  begin
    QueueRefresh;
    Exit;
  end;
  SetLength(values, a.ValueCount);
  for j := 0 to a.ValueCount - 1 do
    values[j] := a.Values[j];
  values[vi] := cell;
  a.SetValues(values);
  Touch;
  QueueRefresh;
end;

procedure TEntryEditor.GridDblClick(Sender: TObject);
var
  pt: TPoint;
  col, row, ai, vi: Integer;
begin
  pt := FGrid.ScreenToClient(Mouse.CursorPos);
  FGrid.MouseToCell(pt.X, pt.Y, col, row);
  if (row < 1) or (FEdited = nil) then Exit;
  GetRowRef(row, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  if FCtx.Sensitive.IsSensitive(FEdited.Attrs[ai].Description) then
  begin
    if EditingAllowed and Assigned(FOnPasswordTools) then
      FOnPasswordTools(FOriginal);
    Exit;
  end;
  EditRow(row);
end;

procedure TEntryEditor.GridMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  col, row, ai, vi: Integer;
  kind: TProviderKind;
  attr: string;
  canUnique, canNext, hasValue: Boolean;
  res: TValueResolution;

  procedure AddItem(const ACaption: string; AOnClick: TNotifyEvent; AEnabled: Boolean);
  var
    item: TMenuItem;
  begin
    item := TMenuItem.Create(FIdMenu);
    item.Caption := ACaption;
    item.OnClick := AOnClick;
    item.Enabled := AEnabled;
    FIdMenu.Items.Add(item);
  end;

begin
  if (Button <> mbRight) or (FEdited = nil) then Exit;
  FGrid.MouseToCell(X, Y, col, row);
  if row < 1 then Exit;
  GetRowRef(row, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  // Clic droit sur un secret: affiche ou masque, a l'ecran seulement. Ni LDIF, ni journal,
  // ni fichier: un secret revele n'a pas a faire de tourisme.
  if FCtx.Sensitive.IsSensitive(FEdited.Attrs[ai].Description) then
  begin
    if FEdited.Attrs[ai].ValueCount > 0 then
    begin
      FGrid.Row := row;
      ToggleReveal(FEdited.Attrs[ai].Description);
    end;
    Exit;
  end;
  kind := ServerKind;
  attr := FEdited.Attrs[ai].Description;
  res := ResolutionFor(attr);
  hasValue := (vi >= 0) and (vi < FEdited.Attrs[ai].ValueCount);
  canUnique := hasValue and (FEdited.Attrs[ai].Values[vi] <> '') and
    IsUniqueCheckAttribute(attr, kind, EntryIsGroup(FEdited, kind)) and (FGetConn() <> nil) and
    FGetConn().IsReady;
  canNext := IsNextIdAttribute(attr, kind) and EditingAllowed;
  FGrid.Row := row;
  FMenuRow := row;
  FIdMenuAttr := attr;
  if canUnique then FIdMenuValue := FEdited.Attrs[ai].Values[vi] else FIdMenuValue := '';
  if FIdMenu = nil then FIdMenu := TPopupMenu.Create(Self);
  FIdMenu.Items.Clear;
  if hasValue then
    AddItem(rsDirOpenValue, @MenuOpenClick, True);
  // DN analyse, jamais decoupe a la virgule: les virgules echappees existent, et elles mordent.
  FMenuDn := '';
  if hasValue and (res.Kind = vkDn) and Assigned(FOnNavigate) and
     ViewOf(res, attr, FEdited.Attrs[ai].Values[vi]).Valid then
  begin
    FMenuDn := string(FEdited.Attrs[ai].Values[vi]);
    AddItem(Format(rsDirGoToDn, [FMenuDn]), @MenuGoToClick, True);
  end;
  AddItem(rsDirLoadValue, @MenuLoadClick, EditingAllowed and not res.ReadOnly and (FFileTask = 0));
  if hasValue then
  begin
    AddItem(rsDirSaveValue, @MenuSaveClick, True);
    if res.Kind in [vkCertificate, vkBinary] then
      AddItem(rsDirInspectCert, @MenuCertClick, True);
  end;
  if canUnique then
    AddItem(Format(rsDirUniqueMenu, [attr]), @UniqueClick, FLookupTask = 0);
  if canNext then
    AddItem(Format(rsDirNextIdMenu, [attr]), @NextIdClick, FLookupTask = 0);
  if FMenuEdit <> nil then AddEditCommands(FIdMenu, FMenuEdit);
  if Assigned(EntryMenuPopupOverride) then
  begin
    EntryMenuPopupOverride(FIdMenu, Mouse.CursorPos.X, Mouse.CursorPos.Y);
    Exit;
  end;
  {$IFNDEF DARWIN}
  ThemePopupMenu(FIdMenu);
  {$ENDIF}
  FIdMenu.PopUp(Mouse.CursorPos.X, Mouse.CursorPos.Y);
end;

procedure TEntryEditor.MenuOpenClick(Sender: TObject);
begin
  OpenValueDialog(FMenuRow);
end;

procedure TEntryEditor.MenuLoadClick(Sender: TObject);
begin
  LoadValueFromFile(FMenuRow);
end;

procedure TEntryEditor.MenuSaveClick(Sender: TObject);
begin
  SaveValueToFile(FMenuRow);
end;

procedure TEntryEditor.MenuCertClick(Sender: TObject);
begin
  InspectCertificate(FMenuRow);
end;

procedure TEntryEditor.MenuGoToClick(Sender: TObject);
begin
  if (FMenuDn <> '') and Assigned(FOnNavigate) then FOnNavigate(FMenuDn);
end;

procedure TEntryEditor.EditRow(ARow: Integer);
var
  ai, vi: Integer;
  res: TValueResolution;
begin
  if FEdited = nil then Exit;
  GetRowRef(ARow, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  if RowEditableInline(ARow) then
  begin
    BeginInlineEdit(ARow);
    Exit;
  end;
  if (vi >= 0) and (vi < FEdited.Attrs[ai].ValueCount) then
    OpenValueDialog(ARow)
  else if EditingAllowed then
  begin
    res := ResolutionFor(FEdited.Attrs[ai].Description);
    if (res.Kind in [vkBinary, vkCertificate]) and not res.ReadOnly then
      LoadValueFromFile(ARow);
  end;
end;

procedure TEntryEditor.OpenValueDialog(ARow: Integer);
var
  ai, vi: Integer;
  a: TLdapAttribute;
  attr: string;
  before, newValue: RawByteString;
  serial: Int64;
  res: TValueResolution;
  view: TAttributeValueView;
  c: TDirectoryConnection;
  editable: Boolean;
  endpoint, badge: string;
  values: array of RawByteString;
  j: Integer;
begin
  if FEdited = nil then Exit;
  CommitInlineEditor;
  GetRowRef(ARow, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  a := FEdited.Attrs[ai];
  if (vi < 0) or (vi >= a.ValueCount) then Exit;
  if FCtx.Sensitive.IsSensitive(a.Description) then Exit;
  attr := a.Description;
  before := a.Values[vi];
  res := ResolutionFor(attr);
  view := ViewOf(res, attr, before);
  editable := EditingAllowed and not res.ReadOnly;
  c := FGetConn();
  endpoint := '';
  badge := '';
  if c <> nil then
  begin
    endpoint := c.Profile.DisplayEndpoint;
    badge := c.Profile.EnvironmentBadge;
  end;
  serial := FEditSerial;
  if not ShowValueDialog(GetParentForm(Self), endpoint, badge, attr, view, editable,
    res.ReadOnlyReason, newValue) then Exit;
  // La boite est videe pendant le dialogue: une relecture ou une autre edition a pu remplacer
  // le tampon, et la saisie ne vise alors plus rien.
  a := FEdited.Find(attr);
  if (FEditSerial <> serial) or (a = nil) or (vi >= a.ValueCount) or (a.Values[vi] <> before) or
     not EditingAllowed then
  begin
    FCtx.Log(mlWarning, FTitle, rsDirValueChangedMeanwhile);
    Exit;
  end;
  SetLength(values, a.ValueCount);
  for j := 0 to a.ValueCount - 1 do
    values[j] := a.Values[j];
  values[vi] := newValue;
  a.SetValues(values);
  Touch;
  RefreshGrid;
end;

procedure TEntryEditor.LoadValueFromFile(ARow: Integer; AAddOnly: Boolean);
var
  ai, vi: Integer;
  a: TLdapAttribute;
  res: TValueResolution;
  od: TOpenDialog;
  answer: TModalResult;
  replaceIndex: Integer;
  attrName, dn: string;
  serial: Int64;
begin
  if not EditingAllowed or (FFileTask <> 0) then Exit;
  CommitInlineEditor;
  GetRowRef(ARow, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  a := FEdited.Attrs[ai];
  if FCtx.Sensitive.IsSensitive(a.Description) then Exit;
  res := ResolutionFor(a.Description);
  if res.ReadOnly then Exit;
  // Cible capturee avant les dialogues (DN, generation, attribut) et tout revalide apres:
  // l'attribut lui-meme n'est plus consulte, il a peut-etre ete libere entre-temps.
  attrName := a.Description;
  dn := FEdited.Dn;
  serial := FEditSerial;
  replaceIndex := -1;
  if AAddOnly then
  begin
    if res.SingleValued and (a.ValueCount > 0) then Exit;
  end
  else if (vi >= 0) and (vi < a.ValueCount) then
  begin
    if res.SingleValued then
    begin
      if RtQuestionDlg(FTitle, Format(rsDirLoadSingleQuestion, [a.Description]), mtConfirmation,
        [mrYes, rsDirLoadReplace, mrCancel, rsDirLoadCancel], 0) <> mrYes then Exit;
      replaceIndex := vi;
    end
    else
    begin
      answer := RtQuestionDlg(FTitle, Format(rsDirLoadQuestion, [a.Description]), mtConfirmation,
        [mrYes, rsDirLoadAdd, mrNo, rsDirLoadReplace, mrCancel, rsDirLoadCancel], 0);
      if answer = mrNo then replaceIndex := vi
      else if answer <> mrYes then Exit;
    end;
  end
  else if res.SingleValued and (a.ValueCount > 0) then
    Exit;
  a := nil;
  od := TOpenDialog.Create(Self);
  try
    od.Filter := 'All files|*.*';
    if not od.Execute then Exit;
    if (FEdited = nil) or (FEditSerial <> serial) or not SameDnStrict(FEdited.Dn, dn) then
    begin
      FCtx.Log(mlWarning, FTitle, Format(rsDirLoadTargetChanged, [attrName]));
      Exit;
    end;
    LoadFileInto(attrName, replaceIndex, od.FileName);
  finally
    od.Free;
  end;
end;

procedure TEntryEditor.LoadFileInto(const AAttr: string; AValueIndex: Integer; const APath: string);
var
  a: TLdapAttribute;
begin
  if not EditingAllowed or (FFileTask <> 0) then Exit;
  CommitInlineEditor;
  a := FEdited.Find(AAttr);
  if (a = nil) or FCtx.Sensitive.IsSensitive(AAttr) then Exit;
  if AValueIndex >= a.ValueCount then Exit;
  FFilePath := APath;
  FFileDn := FEdited.Dn;
  FFileAttr := a.Description;
  FFileValueIndex := AValueIndex;
  if AValueIndex >= 0 then FFileOriginal := a.Values[AValueIndex] else FFileOriginal := '';
  FFileSerial := FEditSerial;
  // Lecture bornee hors du fil graphique. Le tampon reste editable, mais toute edition
  // entre-temps fait jeter le contenu lu.
  FFileTask := StartValueLoad(FFilePath, VALUE_MAX_BYTES, Self);
  if FFileTask = 0 then
    FCtx.Log(mlWarning, FTitle, rsDirTaskBusy);
  UpdateEditState;
end;

procedure TEntryEditor.AddTypedValue(AAttrIndex: Integer);
var
  a: TLdapAttribute;
  attr, endpoint, badge: string;
  res: TValueResolution;
  newValue: RawByteString;
  serial: Int64;
  c: TDirectoryConnection;
begin
  if not EditingAllowed or (AAttrIndex < 0) or (AAttrIndex >= FEdited.AttrCount) then Exit;
  CommitInlineEditor;
  a := FEdited.Attrs[AAttrIndex];
  attr := a.Description;
  res := ResolutionFor(attr);
  if res.SingleValued and (a.ValueCount > 0) then Exit;
  c := FGetConn();
  endpoint := '';
  badge := '';
  if c <> nil then
  begin
    endpoint := c.Profile.DisplayEndpoint;
    badge := c.Profile.EnvironmentBadge;
  end;
  serial := FEditSerial;
  if not ShowValueDialog(GetParentForm(Self), endpoint, badge, attr, ViewOf(res, attr, ''), True, '',
    newValue) then Exit;
  a := FEdited.Find(attr);
  if (FEditSerial <> serial) or (a = nil) or not EditingAllowed then
  begin
    FCtx.Log(mlWarning, FTitle, rsDirValueChangedMeanwhile);
    Exit;
  end;
  a.AddValue(newValue);
  Touch;
  RefreshGrid;
end;

procedure TEntryEditor.CancelFileTask;
begin
  if FFileTask = 0 then Exit;
  FFileTask := 0;
  PasswordWork.CancelOwner(Self);
  FFileOriginal := '';
  UpdateEditState;
end;

procedure TEntryEditor.HandleFileMsg(AMsg: TValueFileMsg);
var
  a: TLdapAttribute;
  values: array of RawByteString;
  j: Integer;
  cost: Int64;
begin
  if AMsg.Op = vfoSave then
  begin
    if AMsg.Ok then
      FCtx.Log(mlInfo, FTitle, Format(rsDirSaved, [AMsg.Path]))
    else
    begin
      FCtx.Log(mlError, FTitle, Format(rsDirSaveFailed, [AMsg.Path, AMsg.ErrorText]));
      RtMessageDlg(FTitle, Format(rsDirSaveFailed, [AMsg.Path, AMsg.ErrorText]), mtError, [mbOK], 0);
    end;
    Exit;
  end;
  if (FFileTask = 0) or (AMsg.TaskId <> FFileTask) then Exit;
  FFileTask := 0;
  try
    if not AMsg.Ok then
    begin
      FCtx.Log(mlWarning, FTitle, Format(rsDirLoadFailed, [AMsg.Path, AMsg.ErrorText]));
      if not AMsg.Cancelled then
        RtMessageDlg(FTitle, Format(rsDirLoadFailed, [AMsg.Path, AMsg.ErrorText]), mtError, [mbOK], 0);
      Exit;
    end;
    CommitInlineEditor;
    a := nil;
    if FEdited <> nil then a := FEdited.Find(FFileAttr);
    if (FEdited = nil) or (FEditSerial <> FFileSerial) or not SameDnStrict(FEdited.Dn, FFileDn) or
       (a = nil) or not EditingAllowed or
       ((FFileValueIndex >= 0) and ((FFileValueIndex >= a.ValueCount) or
         (a.Values[FFileValueIndex] <> FFileOriginal))) then
    begin
      FCtx.Log(mlWarning, FTitle, Format(rsDirLoadStale, [AMsg.Path]));
      Exit;
    end;
    cost := FEdited.MemoryCost + Length(AMsg.Data) + VALUE_OVERHEAD_BYTES;
    if FFileValueIndex >= 0 then Dec(cost, Length(FFileOriginal));
    if cost > ENTRY_MAX_BYTES then
    begin
      RtMessageDlg(FTitle, Format(rsDirLoadEntryLimit, [ENTRY_MAX_BYTES, AMsg.Path]), mtError, [mbOK], 0);
      Exit;
    end;
    if FFileValueIndex >= 0 then
    begin
      SetLength(values, a.ValueCount);
      for j := 0 to a.ValueCount - 1 do
        values[j] := a.Values[j];
      values[FFileValueIndex] := AMsg.Data;
      UniqueString(values[FFileValueIndex]);
      a.SetValues(values);
    end
    else
      // Fichier vide: une valeur de longueur zero, pas une suppression.
      a.AddValue(Copy(AMsg.Data, 1, MaxInt));
    Touch;
    RefreshGrid;
    FCtx.Log(mlInfo, FTitle, Format(rsDirLoaded, [FFileAttr, Length(AMsg.Data), AMsg.Path]));
  finally
    FFileOriginal := '';
    UpdateEditState;
  end;
end;

procedure TEntryEditor.SaveValueToFile(ARow: Integer);
var
  ai, vi: Integer;
  a: TLdapAttribute;
  sd: TSaveDialog;
  res: TValueResolution;
  attrName: string;
  data: RawByteString;
begin
  if FEdited = nil then Exit;
  CommitInlineEditor;
  GetRowRef(ARow, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  a := FEdited.Attrs[ai];
  if (vi < 0) or (vi >= a.ValueCount) then Exit;
  if FCtx.Sensitive.IsSensitive(a.Description) then Exit;
  res := ResolutionFor(a.Description);
  // Octets et nom copies AVANT la boucle modale: une relecture livree pendant le dialogue
  // remplace le tampon et libere l'attribut. Lire de la memoire liberee, c'est pour les autres.
  attrName := a.Description;
  data := a.Values[vi];
  a := nil;
  sd := TSaveDialog.Create(Self);
  try
    sd.Options := sd.Options + [ofOverwritePrompt];
    case res.Kind of
      vkCertificate:
        begin
          sd.Filter := 'Certificate (*.cer)|*.cer|All files|*.*';
          sd.DefaultExt := 'cer';
        end;
      vkText, vkDn, vkInteger, vkBoolean, vkGeneralizedTime:
        begin
          sd.Filter := 'Text (*.txt)|*.txt|All files|*.*';
          sd.DefaultExt := 'txt';
        end;
    else
      sd.Filter := 'Binary (*.bin)|*.bin|All files|*.*';
      sd.DefaultExt := 'bin';
    end;
    sd.FileName := AttrBaseName(attrName) + '.' + sd.DefaultExt;
    if not sd.Execute then Exit;
    if StartValueSave(sd.FileName, data, Self) = 0 then
      FCtx.Log(mlWarning, FTitle, rsDirTaskBusy);
  finally
    sd.Free;
  end;
end;

procedure TEntryEditor.InspectCertificate(ARow: Integer);
var
  ai, vi: Integer;
  a: TLdapAttribute;
  c: TDirectoryConnection;
  endpoint, badge: string;
begin
  if FEdited = nil then Exit;
  GetRowRef(ARow, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  a := FEdited.Attrs[ai];
  if (vi < 0) or (vi >= a.ValueCount) or FCtx.Sensitive.IsSensitive(a.Description) then Exit;
  c := FGetConn();
  endpoint := '';
  badge := '';
  if c <> nil then
  begin
    endpoint := c.Profile.DisplayEndpoint;
    badge := c.Profile.EnvironmentBadge;
  end;
  // Chaque certificat seul: jamais de chaine de confiance, jamais de reseau.
  ShowCertificateValue(GetParentForm(Self), endpoint, badge, a.Description, a.Values[vi], Self);
end;

function TEntryEditor.InvalidEdits: string;
var
  i, j, n: Integer;
  a, o: TLdapAttribute;
  res: TValueResolution;
  err: string;
begin
  Result := '';
  if (FEdited = nil) or (FOriginal = nil) then Exit;
  n := 0;
  for i := 0 to FEdited.AttrCount - 1 do
  begin
    a := FEdited.Attrs[i];
    if FCtx.Sensitive.IsSensitive(a.Description) then Continue;
    o := FOriginal.Find(a.Description);
    res := ResolutionFor(a.Description);
    for j := 0 to a.ValueCount - 1 do
    begin
      if (o <> nil) and (o.IndexOfValue(a.Values[j]) >= 0) then Continue;
      err := ValidateValue(res, a.Values[j]);
      if err = '' then Continue;
      Inc(n);
      if n <= 10 then
        Result := Result + LineEnding + '  ' + a.Description + ': ' + err;
    end;
  end;
  if n > 10 then Result := Result + LineEnding + Format('  ... (%d)', [n - 10]);
end;

procedure TEntryEditor.ToggleReveal(const AAttr: string);
var
  i: Integer;
begin
  i := FRevealed.IndexOf(AAttr);
  if i >= 0 then
    FRevealed.Delete(i)
  else
    FRevealed.Add(AAttr);
  RefreshGrid;
end;

procedure TEntryEditor.KeepRevealOnNextRead(const ADn: string);
begin
  FKeepRevealDn := ADn;
end;

function TEntryEditor.IsRevealed(const AAttr: string): Boolean;
begin
  Result := FRevealed.IndexOf(AAttr) >= 0;
end;

procedure TEntryEditor.GridResize(Sender: TObject);
var
  w: Integer;
begin
  w := FGrid.ClientWidth - FGrid.ColWidths[0] - FGrid.ColWidths[1] - FGrid.ColWidths[2] -
    FGrid.GridLineWidth * 4;
  if w < 120 then w := 120;
  if FGrid.ColWidths[3] <> w then FGrid.ColWidths[3] := w;
end;

procedure TEntryEditor.GridHeaderSized(Sender: TObject; IsColumn: Boolean; Index: Integer);
begin
  if IsColumn and (Index = 2) then FSyntaxColSized := True;
  if IsColumn then GridResize(Sender);
end;

procedure TEntryEditor.FitSyntaxColumn;
var
  r, w, best: Integer;
  bmp: Graphics.TBitmap;
begin
  if FSyntaxColSized then Exit;
  // Mesure hors ecran: le canevas de la grille exige son handle, qui n'existe pas toujours.
  bmp := Graphics.TBitmap.Create;
  try
    bmp.Canvas.Font.Assign(FGrid.Font);
    best := bmp.Canvas.TextWidth(FGrid.Cells[2, 0]);
    for r := 1 to FGrid.RowCount - 1 do
    begin
      w := bmp.Canvas.TextWidth(FGrid.Cells[2, r]);
      if w > best then best := w;
    end;
    best := best + 3 * bmp.Canvas.TextWidth('M');
  finally
    bmp.Free;
  end;
  if best < 120 then best := 120;
  if FGrid.ColWidths[2] <> best then
  begin
    FGrid.ColWidths[2] := best;
    GridResize(FGrid);
  end;
end;

procedure TEntryEditor.QueueRefresh;
begin
  // La grille ne se reconstruit pas pendant que son editeur se ferme: on differe.
  if FRefreshQueued then Exit;
  FRefreshQueued := True;
  Application.QueueAsyncCall(@DeferredRefresh, 0);
end;

procedure TEntryEditor.DeferredRefresh(AData: PtrInt);
begin
  FRefreshQueued := False;
  if FEdited <> nil then RefreshGrid;
end;

function TEntryEditor.MaskedEntryLdif(AEntry: TLdapEntry): string;
var
  masked: TLdapEntry;
  a: TLdapAttribute;
  i, j: Integer;
  c: TDirectoryConnection;
begin
  masked := AEntry.Clone;
  try
    c := FGetConn();
    if c <> nil then
      for i := masked.AttrCount - 1 downto 0 do
        if IsHiddenVersionMarker(c.Profile, c.Schema, masked.Attrs[i].BaseName) then
          masked.Remove(masked.Attrs[i].Description);
    for i := 0 to masked.AttrCount - 1 do
      if FCtx.Sensitive.IsSensitive(masked.Attrs[i].Description) then
      begin
        a := masked.Attrs[i];
        for j := a.ValueCount - 1 downto 0 do
          a.DeleteValue(j);
        a.AddValue(MASK_TEXT);
      end;
    Result := LdifEntryToString(masked);
  finally
    masked.Free;
  end;
end;

function TEntryEditor.ValueDisplay(const AAttr: string; const AValue: RawByteString): string;
begin
  Result := ViewOf(ResolutionFor(AAttr), AAttr, AValue).Display;
end;

function TEntryEditor.ResolutionFor(const AAttr: string): TValueResolution;
var
  c: TDirectoryConnection;
begin
  c := FGetConn();
  if c = nil then
    Result := ResolveValueKind(nil, AAttr, pkOther)
  else
    Result := ResolveValueKind(c.Schema, AAttr, ServerKind);
end;

function TEntryEditor.ViewOf(const ARes: TValueResolution; const AAttr: string;
  const AValue: RawByteString): TAttributeValueView;
var
  masked: Boolean;
begin
  // Secret non revele: rien n'est interprete ni montre, pas meme sa taille.
  masked := FCtx.Sensitive.IsSensitive(AAttr) and not IsRevealed(AAttr);
  Result := ViewValue(ARes, AAttr, AValue, masked, @UtcToLocalAt);
  if masked then Result.Display := rsDirSecretMasked;
end;

function TEntryEditor.AttributeSyntax(const AAttr: string): string;
var
  c: TDirectoryConnection;
begin
  Result := '';
  c := FGetConn();
  // Syntaxe heritee (SUP) comprise: cn, sn et compagnie n'en declarent pas eux-memes.
  if (c <> nil) and (c.Schema <> nil) then
    Result := c.Schema.EffectiveSyntax(AAttr);
end;

function TEntryEditor.AttributeInfo(const AAttr: string; AAttribute: TLdapAttribute): string;
var
  c: TDirectoryConnection;
  s: TSchemaSnapshot;
  parts: TStringList;
  at: TSchemaAttributeType;
  syn: TSchemaSyntax;
  oid, synName, expl: string;
  maxLen, i: Integer;
  res: TValueResolution;
begin
  parts := TStringList.Create;
  try
    c := FGetConn();
    if (c <> nil) and (c.Schema <> nil) then
    begin
      s := c.Schema;
      at := s.AttributeType(AAttr);
      if at <> nil then
      begin
        oid := SplitSyntaxLength(s.EffectiveSyntax(AAttr), maxLen);
        res := ResolutionFor(AAttr);
        // AD: le type reel (metadonnees attributeSchema ou regle fournisseur) prime sur le
        // sous-schema agrege, ou un SID n'est qu'un Octet String parmi d'autres.
        if res.Source in [ksAdMetadata, ksProviderRule] then
        begin
          parts.Add(ValueKindName(res.Kind) + ': ' + res.Detail);
          if maxLen > 0 then parts.Add(Format(rsDirMaxLen, [maxLen]));
        end
        else if oid <> '' then
        begin
          if SyntaxDescription(oid, synName, expl) then
            parts.Add(synName + ': ' + expl)
          else
          begin
            syn := s.Syntax(oid);
            if (syn <> nil) and (syn.Desc <> '') then parts.Add(syn.Desc)
            else parts.Add(rsDirUnknownSyntax);
          end;
          if maxLen > 0 then parts.Add(Format(rsDirMaxLen, [maxLen]));
        end;
        if at.SingleValue then parts.Add(rsDirSingle);
        if at.Usage <> auUserApplications then parts.Add(rsDirOperational);
        if at.NoUserModification then parts.Add(rsDirReadOnlyAttr);
      end
      else
        parts.Add(rsDirNotInSchema);
    end;
    if (AAttribute <> nil) and AAttribute.Truncated then parts.Add(rsDirTruncated);
    Result := '';
    for i := 0 to parts.Count - 1 do
      if i = 0 then Result := parts[i] else Result := Result + '; ' + parts[i];
  finally
    parts.Free;
  end;
end;

procedure TEntryEditor.RefreshGrid;
var
  i, j, row, keepRow: Integer;
  a: TLdapAttribute;
  s: TSchemaSnapshot;
  c: TDirectoryConnection;
  must, may: TStringList;
  classes: array of string;
  oc: TLdapAttribute;
begin
  CommitInlineEditor;
  keepRow := FGrid.Row;
  FGrid.BeginUpdate;
  try
    if FEdited = nil then
    begin
      FGrid.RowCount := 2;
      if FPlaceholderText <> '' then
        FGrid.Cells[0, 1] := FPlaceholderText
      else
        FGrid.Cells[0, 1] := rsDirNoEntry;
      FGrid.Cells[1, 1] := '';
      FGrid.Cells[2, 1] := '';
      FGrid.Cells[3, 1] := '';
      FGrid.Objects[0, 1] := nil;
      FGrid.Objects[1, 1] := nil;
      Exit;
    end;
    row := 1;
    FGrid.RowCount := 1;
    c := FGetConn();
    for i := 0 to FEdited.AttrCount - 1 do
    begin
      a := FEdited.Attrs[i];
      if (c <> nil) and IsHiddenVersionMarker(c.Profile, c.Schema, a.BaseName) then
        Continue;
      if a.ValueCount = 0 then
      begin
        FGrid.RowCount := row + 1;
        FGrid.Cells[0, row] := a.Description;
        FGrid.Cells[1, row] := '';
        FGrid.Cells[2, row] := AttributeSyntax(a.BaseName);
        FGrid.Cells[3, row] := AttributeInfo(a.BaseName, a);
        SetRowRef(row, i, -1);
        Inc(row);
        Continue;
      end;
      for j := 0 to a.ValueCount - 1 do
      begin
        FGrid.RowCount := row + 1;
        if j = 0 then FGrid.Cells[0, row] := a.Description else FGrid.Cells[0, row] := '';
        FGrid.Cells[1, row] := ValueDisplay(a.Description, a.Values[j]);
        if j = 0 then
        begin
          FGrid.Cells[2, row] := AttributeSyntax(a.BaseName);
          FGrid.Cells[3, row] := AttributeInfo(a.BaseName, a);
        end
        else
        begin
          FGrid.Cells[2, row] := '';
          FGrid.Cells[3, row] := '';
        end;
        SetRowRef(row, i, j);
        Inc(row);
      end;
    end;
    if (keepRow >= 1) and (keepRow < FGrid.RowCount) then FGrid.Row := keepRow;
  finally
    FGrid.EndUpdate;
  end;
  FLdif.Text := MaskedEntryLdif(FEdited);
  c := FGetConn();
  FSchemaInfo.Lines.BeginUpdate;
  try
    FSchemaInfo.Clear;
    if (c = nil) or (c.Schema = nil) then
      FSchemaInfo.Lines.Add(rsDirSchemaUnavailable)
    else
    begin
      s := c.Schema;
      oc := FEdited.Find('objectClass');
      classes := nil;
      if oc <> nil then
      begin
        SetLength(classes, oc.ValueCount);
        for i := 0 to oc.ValueCount - 1 do
          classes[i] := oc.Values[i];
      end;
      must := TStringList.Create;
      may := TStringList.Create;
      try
        s.CollectAllowed(classes, must, may);
        FSchemaInfo.Lines.Add('# ' + s.SubschemaDn);
        if s.Stale then
          FSchemaInfo.Lines.Add(rsDirCachedSchema);
        FSchemaInfo.Lines.Add('MUST: ' + must.CommaText);
        FSchemaInfo.Lines.Add('MAY: ' + may.CommaText);
        for i := 0 to High(classes) do
          if s.ObjectClass(classes[i]) <> nil then
            FSchemaInfo.Lines.Add(s.ObjectClass(classes[i]).Raw)
          else
            FSchemaInfo.Lines.Add(Format(rsDirUnknownClass, [classes[i]]));
      finally
        must.Free;
        may.Free;
      end;
    end;
  finally
    FSchemaInfo.Lines.EndUpdate;
  end;
  FitSyntaxColumn;
  UpdateEditState;
end;

function TEntryEditor.EqualityKnown(const AAttr: string): Boolean;
var
  c: TDirectoryConnection;
begin
  c := FGetConn();
  if c = nil then Exit(True);
  Result := SchemaEqualityKnown(c.Schema, AAttr);
end;

procedure TEntryEditor.UpdateEditState;
var
  mods: TLdapModArray;
  err: string;
  opts: TDeltaOptions;
  c: TDirectoryConnection;
  n, i: Integer;
  ro: Boolean;
begin
  n := 0;
  if (FOriginal <> nil) and (FEdited <> nil) then
  begin
    opts.EqualityKnown := @EqualityKnown;
    if ComputeModifications(FOriginal, FEdited, opts, mods, err) then
      n := Length(mods);
  end;
  c := FGetConn();
  ro := (c <> nil) and c.Profile.ReadOnly;
  for i := 0 to High(FBarButtons) do
  begin
    FBarButtons[i].Visible := not ro;
    FBarButtons[i].Enabled := EditingAllowed;
  end;
  FReadOnlyIcon.Visible := ro;
  if ro then
  begin
    FReadOnlyIcon.IconColor := ShellStateColor(usError);
    FPendingLabel.Font.Color := ShellStateColor(usError);
    FPendingLabel.Font.Style := [fsBold];
  end
  else
  begin
    FPendingLabel.Font.Color := clAppFg;
    FPendingLabel.Font.Style := [];
  end;
  if ro and (c.Profile.LdifPath <> '') then
    FPendingLabel.Caption := rsDirReadOnlyLdif
  else if ro then
    FPendingLabel.Caption := rsDirReadOnlyProfile
  else if FReadPending then
    FPendingLabel.Caption := rsDirReadPending
  else if FPendingChange <> nil then
    FPendingLabel.Caption := rsDirPrecheckPending
  else if FFileTask <> 0 then
    FPendingLabel.Caption := Format(rsDirLoading, [ExtractFileName(FFilePath)])
  else if (FLookupTask <> 0) and (FNextIdScan <> nil) then
    FPendingLabel.Caption := Format(rsDirNextIdSearching, [FNextIdScan.Attr, FLookupBase])
  else if (FLookupTask <> 0) and (FUnique <> nil) then
    FPendingLabel.Caption := Format(rsDirUniqueSearching, [FUnique.Attr, FLookupBase])
  else
    FPendingLabel.Caption := Format(rsDirPending, [n]);
  UpdateDeleteCaption;
  EditBarResize(nil);
end;

function TEntryEditor.BarButton(AButton: TButton): TButton;
begin
  SetLength(FBarButtons, Length(FBarButtons) + 1);
  FBarButtons[High(FBarButtons)] := AButton;
  Result := AButton;
end;

// Differe: deplacer des controles pendant le redimensionnement de leur parent
// relancerait la mise en page, et c'est reparti pour un tour d'oscillation.
procedure TEntryEditor.EditBarResize(Sender: TObject);
begin
  if FBarQueued or (csDestroying in ComponentState) then Exit;
  FBarQueued := True;
  Application.QueueAsyncCall(@AsyncArrangeEditBar, 0);
end;

procedure TEntryEditor.AsyncArrangeEditBar(AData: PtrInt);
begin
  FBarQueued := False;
  ArrangeEditBar;
end;

function TEntryEditor.EditBarRows: Integer;
begin
  if FEditRow2.Visible then Result := 2 else Result := 1;
end;

procedure TEntryEditor.ArrangeEditBar;
var
  need, i: Integer;
  two: Boolean;
  row: TPanel;

  function Outer(AControl: TControl): Integer;
  begin
    if not AControl.Visible then Exit(0);
    Result := AControl.Width + AControl.BorderSpacing.Left + AControl.BorderSpacing.Right +
      2 * AControl.BorderSpacing.Around;
  end;

begin
  if (FEditBar = nil) or (FEditBar.ClientWidth <= 0) then Exit;
  need := Outer(FReadOnlyIcon) + MeasureText(FPendingLabel.Font,
    FPendingLabel.Caption + '  ', FPendingLabel.Font.Style) + 16;
  for i := 0 to High(FBarButtons) do
    Inc(need, Outer(FBarButtons[i]));
  two := need > FEditBar.ClientWidth;
  if two = FEditRow2.Visible then Exit;
  if two then row := FEditRow2 else row := FEditRow;
  FEditBar.DisableAlign;
  try
    FReadOnlyIcon.Parent := row;
    FPendingLabel.Parent := row;
    FRevertButton.Parent := row;
    FApplyButton.Parent := row;
    FEditRow2.Visible := two;
    if two then FEditBar.Height := 2 * FEditRow.Height else FEditBar.Height := FEditRow.Height;
    FEditRow2.Top := FEditRow.Top + FEditRow.Height;
  finally
    FEditBar.EnableAlign;
  end;
  ArrangeByCreation(FEditRow);
  ArrangeByCreation(FEditRow2);
end;

function TEntryEditor.ReadOnlyNotice: string;
begin
  if FReadOnlyIcon.Visible and (fsBold in FPendingLabel.Font.Style) then
    Result := FPendingLabel.Caption
  else
    Result := '';
end;

procedure TEntryEditor.UpdateDeleteCaption;
var
  ai, vi: Integer;
  cap: string;
begin
  if FDeleteButton = nil then Exit;
  cap := rsDirDeleteValue;
  if FEdited <> nil then
  begin
    GetRowRef(FGrid.Row, ai, vi);
    if (ai >= 0) and (ai < FEdited.AttrCount) and (FEdited.Attrs[ai].ValueCount <= 1) then
      cap := rsDirDeleteAttr;
  end;
  if FDeleteButton.Caption <> cap then FDeleteButton.Caption := cap;
end;

procedure TEntryEditor.GridGetCellHint(Sender: TObject; ACol, ARow: Integer; var HintText: string);
var
  ai, vi, len: Integer;
  ex: string;
begin
  HintText := '';
  if (ACol <> 3) or (ARow < 1) or (FEdited = nil) then Exit;
  GetRowRef(ARow, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  ex := SyntaxExample(SplitSyntaxLength(AttributeSyntax(FEdited.Attrs[ai].BaseName), len));
  if ex = '' then Exit;
  // '|' separe l'aide courte de l'aide longue dans GetShortHint: on le neutralise.
  HintText := StringReplace(Format(rsDirExample, [ex]), '|', '/', [rfReplaceAll]);
end;

procedure TEntryEditor.GridSelection(Sender: TObject; aCol, aRow: Integer);
begin
  UpdateDeleteCaption;
end;

procedure TEntryEditor.NextIdClick(Sender: TObject);
begin
  StartNextId(FIdMenuAttr);
end;

procedure TEntryEditor.UniqueClick(Sender: TObject);
begin
  StartUniqueCheck(FIdMenuAttr, FIdMenuValue);
end;

function TEntryEditor.ServerKind: TProviderKind;
var
  c: TDirectoryConnection;
begin
  c := FGetConn();
  if c = nil then Exit(pkOther);
  Result := EffectiveServerKind(c.Profile, c.RootDse);
end;

function TEntryEditor.LookupBase(c: TDirectoryConnection): string;
begin
  Result := NextIdBaseFor(c, FOriginal.Dn);
end;

procedure TEntryEditor.StartNextId(const AAttr: string);
var
  c: TDirectoryConnection;
begin
  if not EditingAllowed then Exit;
  c := FGetConn();
  CancelLookup;
  FLookupBase := LookupBase(c);
  if FLookupBase = '' then
  begin
    FCtx.Log(mlWarning, FTitle, Format(rsDirLookupNoBase, [FOriginal.Dn]));
    Exit;
  end;
  FNextIdScan := TNextIdScan.Create(AAttr);
  FLookupDn := FOriginal.Dn;
  FLookupProfile := c.Profile.Uuid;
  FLookups.ProfileUuid := FLookupProfile;
  FLookupTask := FLookups.Search('lookup', NextIdSearchRequest(c.Profile, FLookupBase, AAttr));
  if FLookupTask = 0 then FreeAndNil(FNextIdScan);
  UpdateEditState;
end;

procedure TEntryEditor.StartUniqueCheck(const AAttr: string; const AValue: RawByteString);
var
  c: TDirectoryConnection;
  kind: TProviderKind;
begin
  c := FGetConn();
  if (c = nil) or not c.IsReady or (FOriginal = nil) or (AValue = '') then Exit;
  CancelLookup;
  // Sans regle d'egalite, le filtre ne vaut jamais vrai (RFC 4511, Undefined):
  // l'absence de doublon ne prouverait rien, sinon notre optimisme.
  if (c.Schema <> nil) and (c.Schema.AttributeType(AAttr) <> nil) and
     (c.Schema.EffectiveEquality(AAttr) = '') then
  begin
    FUniqueReport := Format(rsDirUniqueNoEquality, [AAttr]);
    FUniqueReportType := mtWarning;
    Application.QueueAsyncCall(@ShowUniqueReport, 0);
    Exit;
  end;
  FLookupBase := LookupBase(c);
  if FLookupBase = '' then
  begin
    FCtx.Log(mlWarning, FTitle, Format(rsDirLookupNoBase, [FOriginal.Dn]));
    Exit;
  end;
  kind := ServerKind;
  FUnique := TUniqueCheck.Create(AAttr, AValue, FOriginal.Dn);
  FLookupDn := FOriginal.Dn;
  FLookupProfile := c.Profile.Uuid;
  FLookups.ProfileUuid := FLookupProfile;
  FLookupTask := FLookups.Search('lookup', UniqueCheckRequest(c.Profile, FLookupBase,
    UniqueCheckFilter(AAttr, AValue, kind, EntryIsGroup(FEdited, kind))));
  if FLookupTask = 0 then FreeAndNil(FUnique);
  UpdateEditState;
end;

procedure TEntryEditor.CancelLookup;
begin
  if FLookups <> nil then FLookups.Cancel('lookup');
  FLookupTask := 0;
  FreeAndNil(FNextIdScan);
  FreeAndNil(FUnique);
end;

procedure TEntryEditor.LocalMessage(AMsg: TUiMessage);
begin
  if AMsg is TValueFileMsg then HandleFileMsg(TValueFileMsg(AMsg));
end;

procedure TEntryEditor.LookupMessage(AMsg: TUiMessage; const ATask: TTrackedTask;
  AEnding: TTaskEnding);
var
  m: TEntriesMsg;
  i: Integer;
  what: string;
begin
  if AMsg.TaskId <> FLookupTask then Exit;
  if AEnding = teStale then
  begin
    CancelLookup;
    UpdateEditState;
    Exit;
  end;
  if AMsg is TTaskFailedMsg then
  begin
    if FNextIdScan <> nil then what := FNextIdScan.Attr else what := FUnique.Attr;
    FCtx.Log(mlWarning, FTitle, Format(rsDirLookupFailed, [what, TTaskFailedMsg(AMsg).Text]));
    CancelLookup;
    UpdateEditState;
  end
  else if AMsg is TEntriesMsg then
  begin
    m := TEntriesMsg(AMsg);
    for i := 0 to m.Entries.Count - 1 do
      if FNextIdScan <> nil then FNextIdScan.Feed(TLdapEntry(m.Entries[i]))
      else FUnique.Feed(TLdapEntry(m.Entries[i]));
    if m.Final then
      if FNextIdScan <> nil then FinishNextId(m) else FinishUnique(m);
  end;
end;

function IncompleteReason(const C: TSearchCompletion): string;
begin
  Result := ResultCodeName(C.ResultCode);
  if C.SizeLimitHit then Result := 'size limit'
  else if C.TimeLimitHit then Result := 'time limit'
  else if C.Cancelled then Result := 'cancelled';
end;

procedure TEntryEditor.FinishNextId(AMsg: TEntriesMsg);
var
  a: TLdapAttribute;
  next: Int64;
  highest, attr: string;
begin
  attr := FNextIdScan.Attr;
  next := FNextIdScan.NextId;
  if FNextIdScan.Found > 0 then highest := FNextIdScan.HighestText else highest := rsDirNextIdNone;
  try
    // Enumeration incomplete: aucun maximum n'est sur, donc rien n'est pose.
    if SearchOutcome(AMsg.Completion) <> soComplete then
    begin
      FCtx.Log(mlWarning, FTitle, Format(rsDirNextIdIncomplete, [attr, FLookupBase,
        IncompleteReason(AMsg.Completion)]));
      Exit;
    end;
    if next = 0 then
    begin
      FCtx.Log(mlWarning, FTitle, Format(rsDirNextIdExhausted, [attr, highest]));
      Exit;
    end;
    if (FEdited = nil) or not SameDnStrict(FEdited.Dn, FLookupDn) or not EditingAllowed then Exit;
    CommitInlineEditor;
    a := FEdited.Find(attr);
    if a = nil then
    begin
      FCtx.Log(mlWarning, FTitle, Format(rsDirNextIdGone, [attr, next]));
      Exit;
    end;
    a.SetValues([RawByteString(IntToStr(next))]);
    Touch;
    RefreshGrid;
    FCtx.Log(mlInfo, FTitle, Format(rsDirNextIdSet, [attr, next, highest,
      FNextIdScan.Found, FLookupBase]));
  finally
    FLookupTask := 0;
    FreeAndNil(FNextIdScan);
    UpdateEditState;
  end;
end;

procedure TEntryEditor.FinishUnique(AMsg: TEntriesMsg);
var
  c: TDirectoryConnection;
  i: Integer;
  report, rule: string;
begin
  try
    if FUnique.OtherCount > 0 then
    begin
      report := Format(rsDirUniqueTaken, [FUnique.Attr, string(FUnique.Value), FUnique.OtherCount,
        FLookupBase]);
      for i := 0 to FUnique.Others.Count - 1 do
        report := report + LineEnding + '  ' + FUnique.Others[i];
      if FUnique.OtherCount > FUnique.Others.Count then
        report := report + LineEnding + Format(rsDirUniqueMore, [FUnique.OtherCount - FUnique.Others.Count]);
      FUniqueReportType := mtWarning;
    end
    // Aucun doublon sur une enumeration incomplete: rien n'est etabli.
    else if SearchOutcome(AMsg.Completion) <> soComplete then
    begin
      report := Format(rsDirUniqueIncomplete, [FUnique.Attr, string(FUnique.Value), FLookupBase,
        IncompleteReason(AMsg.Completion)]);
      FUniqueReportType := mtWarning;
    end
    else
    begin
      report := Format(rsDirUniqueOk, [FUnique.Attr, string(FUnique.Value), FLookupBase]);
      FUniqueReportType := mtInformation;
    end;
    c := FCtx.Connections.Find(FLookupProfile);
    if (c <> nil) and (c.Schema <> nil) then
    begin
      rule := c.Schema.EffectiveEquality(FUnique.Attr);
      if rule <> '' then
        report := report + LineEnding + LineEnding + Format(rsDirUniqueCase, [FUnique.Attr, rule]);
    end;
    if FUniqueReportType = mtInformation then FCtx.Log(mlInfo, FTitle, report)
    else FCtx.Log(mlWarning, FTitle, report);
    // Dialogue apres le traitement du message: jamais de boucle modale pendant qu'on vide la boite.
    FUniqueReport := report;
    Application.QueueAsyncCall(@ShowUniqueReport, 0);
  finally
    FLookupTask := 0;
    FreeAndNil(FUnique);
    UpdateEditState;
  end;
end;

procedure TEntryEditor.ShowUniqueReport(AData: PtrInt);
var
  report: string;
begin
  report := FUniqueReport;
  FUniqueReport := '';
  if report = '' then Exit;
  RtMessageDlg(Format(rsDirUniqueTitle, [FTitle]), report, FUniqueReportType, [mbOK], 0);
end;

procedure TEntryEditor.AddValueClick(Sender: TObject);
var
  ai, vi, row, last, r, a2, v2: Integer;
  res: TValueResolution;
begin
  if not EditingAllowed then Exit;
  GetRowRef(FGrid.Row, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  if FCtx.Sensitive.IsSensitive(FEdited.Attrs[ai].Description) then
  begin
    if Assigned(FOnPasswordTools) then FOnPasswordTools(FOriginal);
    Exit;
  end;
  res := ResolutionFor(FEdited.Attrs[ai].Description);
  if res.ReadOnly or (res.Kind = vkSecurityDescriptor) then Exit;
  if res.Kind in [vkBinary, vkCertificate] then
  begin
    LoadValueFromFile(FGrid.Row, True);
    Exit;
  end;
  if res.Kind in [vkSid, vkGuid] then
  begin
    AddTypedValue(ai);
    Exit;
  end;
  CommitInlineEditor;
  last := FGrid.Row;
  for r := 1 to FGrid.RowCount - 1 do
  begin
    GetRowRef(r, a2, v2);
    if a2 = ai then last := r;
  end;
  row := last + 1;
  FGrid.InsertColRow(False, row);
  FGrid.Cells[0, row] := '';
  FGrid.Cells[1, row] := '';
  FGrid.Cells[2, row] := '';
  FGrid.Cells[3, row] := '';
  SetRowRef(row, ai, -2);
  BeginInlineEdit(row);
end;

procedure TEntryEditor.EditValueClick(Sender: TObject);
var
  ai, vi: Integer;
begin
  if not EditingAllowed then Exit;
  GetRowRef(FGrid.Row, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) then Exit;
  if FCtx.Sensitive.IsSensitive(FEdited.Attrs[ai].Description) then
  begin
    if Assigned(FOnPasswordTools) then FOnPasswordTools(FOriginal);
    Exit;
  end;
  EditRow(FGrid.Row);
end;

procedure TEntryEditor.DeleteValueClick(Sender: TObject);
var
  ai, vi: Integer;
begin
  if not EditingAllowed then Exit;
  CommitInlineEditor;
  GetRowRef(FGrid.Row, ai, vi);
  if (ai < 0) or (ai >= FEdited.AttrCount) or (vi < 0) then Exit;
  if vi >= FEdited.Attrs[ai].ValueCount then Exit;
  FEdited.Attrs[ai].DeleteValue(vi);
  if FEdited.Attrs[ai].ValueCount = 0 then
    FEdited.Remove(FEdited.Attrs[ai].Description);
  Touch;
  RefreshGrid;
end;

function TEntryEditor.PickAttribute(out AName: string): Boolean;
var
  c: TDirectoryConnection;
  choices: TAttrChoiceArray;
  reason, synName, synExpl, info: string;
  rows: TPickRows;
  i: Integer;
  d: TPickDialog;
  r: TModalResult;
begin
  Result := False;
  AName := '';
  c := FGetConn();
  while True do
  begin
    if (c = nil) or (c.Schema = nil) or
       not AttributeChoicesFor(c.Schema, FEdited, ServerKind, choices, reason) then
    begin
      if (c = nil) or (c.Schema = nil) then reason := 'the schema of the server is not available';
      RtMessageDlg(FTitle, Format(rsDirChoicesUnavailable, [reason]), mtWarning, [mbOK], 0);
      if not RtInputQuery(FTitle, rsDirAttrPrompt, AName) then Exit;
      AName := Trim(AName);
      Exit(AName <> '');
    end;
    SetLength(rows, Length(choices));
    for i := 0 to High(choices) do
    begin
      if not SyntaxDescription(choices[i].SyntaxOid, synName, synExpl) then
      begin
        synName := choices[i].SyntaxOid;
        synExpl := '';
      end;
      rows[i] := Default(TPickRow);
      rows[i].Key := choices[i].Name;
      rows[i].Cells := [choices[i].Name, AttrChoiceKindText(choices[i]), synName];
      info := choices[i].Name;
      if choices[i].Oid <> '' then info := info + '  (' + choices[i].Oid + ')';
      if choices[i].Desc <> '' then info := info + #10 + choices[i].Desc;
      info := info + #10 + AttrChoiceKindText(choices[i]);
      if synName <> '' then
      begin
        info := info + #10 + 'Type: ' + synName;
        if synExpl <> '' then info := info + ' (' + synExpl + ')';
      end;
      if choices[i].SingleValued then info := info + #10 + 'Single value'
      else info := info + #10 + 'Several values allowed';
      if FCtx.Sensitive.IsSensitive(choices[i].Name) then info := info + #10 + rsDirSecretLater;
      rows[i].Info := info;
    end;
    d := TPickDialog.CreatePick(Self, rsDirAddAttrTitle, rsDirAddAttrHelp,
      [rsDirColAttribute, rsDirColRequirement, rsDirColSyntax], [220, 360, 200], rsDirAddClassButton);
    try
      d.SetIcon('plus');
      d.SetRows(rows);
      r := RunPick(d);
      AName := d.Chosen;
    finally
      d.Free;
    end;
    if r = mrOk then Exit(AName <> '');
    if r <> mrRetry then Exit;
    PickAuxiliaryClass;
  end;
end;

function TEntryEditor.PickAuxiliaryClass: Boolean;
var
  c: TDirectoryConnection;
  classes: TClassChoiceArray;
  rows: TPickRows;
  i: Integer;
  d: TPickDialog;
  picked, info: string;
begin
  Result := False;
  c := FGetConn();
  if (c = nil) or (c.Schema = nil) or not EditingAllowed then Exit;
  classes := AuxiliaryClassChoicesFor(c.Schema, FEdited);
  SetLength(rows, Length(classes));
  for i := 0 to High(classes) do
  begin
    rows[i] := Default(TPickRow);
    rows[i].Key := classes[i].Name;
    rows[i].Cells := [classes[i].Name, string.Join(', ', classes[i].Must), classes[i].Desc];
    info := classes[i].Name + '  (' + classes[i].Oid + ')';
    if classes[i].Desc <> '' then info := info + #10 + classes[i].Desc;
    info := info + #10 + 'Kind: auxiliary' + #10 + 'Required: ' + string.Join('  ', classes[i].Must) +
      #10 + 'Allowed: ' + string.Join('  ', classes[i].May);
    rows[i].Info := info;
  end;
  d := TPickDialog.CreatePick(Self, rsDirAddClassTitle, rsDirAddClassHelp,
    [rsDirColClass, rsDirColRequires, rsDirColDescription], [220, 300, 340]);
  try
    d.SetIcon('plus');
    d.SetRows(rows);
    if RunPick(d) <> mrOk then Exit;
    picked := d.Chosen;
  finally
    d.Free;
  end;
  if (picked = '') or not EditingAllowed then Exit;
  CommitInlineEditor;
  FEdited.Ensure('objectClass').AddValue(RawByteString(picked));
  Touch;
  RefreshGrid;
  FCtx.Log(mlInfo, FTitle, Format(rsDirClassAdded, [picked]));
  Result := True;
end;

procedure TEntryEditor.AddAttrClick(Sender: TObject);
var
  attrName: string;
  a: TLdapAttribute;
  r, ai, vi: Integer;
begin
  if not EditingAllowed then Exit;
  if not PickAttribute(attrName) then Exit;
  if not EditingAllowed then Exit;
  attrName := Trim(attrName);
  if not IsValidAttributeDescription(attrName) then Exit;
  if FCtx.Sensitive.IsSensitive(attrName) then
  begin
    if Assigned(FOnPasswordTools) then FOnPasswordTools(FOriginal);
    Exit;
  end;
  a := FEdited.Ensure(attrName);
  RefreshGrid;
  for r := 1 to FGrid.RowCount - 1 do
  begin
    GetRowRef(r, ai, vi);
    if (ai >= 0) and (ai < FEdited.AttrCount) and (FEdited.Attrs[ai] = a) then
    begin
      if vi = -1 then
        BeginInlineEdit(r)
      else
      begin
        FGrid.Row := r;
        AddValueClick(nil);
      end;
      Exit;
    end;
  end;
end;

procedure TEntryEditor.RevertClick(Sender: TObject);
begin
  if FOriginal = nil then Exit;
  CancelInlineEditor;
  FEdited.Free;
  FEdited := FOriginal.Clone;
  Touch;
  RefreshGrid;
end;

procedure TEntryEditor.GridKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if FGrid.EditorMode then Exit;
  if Key = VK_DELETE then
  begin
    DeleteValueClick(Sender);
    Key := 0;
  end
  else if Key = VK_F2 then
  begin
    EditValueClick(Sender);
    Key := 0;
  end
  else if Key = VK_RETURN then
  begin
    // Entree ouvre l'editeur au RELACHEMENT. Ouvert a l'appui, il recevait le relachement, et
    // TCustomEdit valide sur Entree relachee (customedit.inc, KeyUpAfterInterface -> EditingDone):
    // la saisie se refermait aussitot ouverte.
    FEnterDown := True;
    Key := 0;
  end;
end;

procedure TEntryEditor.GridKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key <> VK_RETURN) or not FEnterDown then Exit;
  FEnterDown := False;
  Key := 0;
  if not FGrid.EditorMode then
    EditValueClick(Sender);
end;

end.
