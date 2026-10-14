// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTemplateDeploy;

{$mode objfpc}{$H+}

// Creation depuis un modele: on choisit, on remplit ce qu'il demande, le reste se calcule sous
// les yeux. L'envoi passe par l'assistant de creation: memes controles, meme confirmation. Le
// numero libre est cherche sans reservation: deux admins presses peuvent tomber sur le meme.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, Dialogs, LCLType,
  uUiKit, uAppContext, uRtButton, uRtChips, uIcons, uEntryTemplate, uEntryCreationPlan, uTaskDialog,
  uTaskTracker, uUiInbox, uNextId, uLdapSchema, uConnectionProfile, uTemplateGroups, uAdPasswordRules,
  uTemplateUnique;

type
  TTemplateForm = class;

  TTfRowKind = (tfkSection, tfkField);

  TTfRow = class(TCustomControl)
  private
    FDlg: TTemplateForm;
    FKind: TTfRowKind;
    FIndex: Integer;
    FTitle: string;
    FEdit: TEdit;
    FChip, FSecretBtn: TRtFlatButton;
    FBuilt: Boolean;
    FTextLeft: Integer;
    procedure EditChange(Sender: TObject);
    procedure EditEnter(Sender: TObject);
    procedure EditExit(Sender: TObject);
    procedure ChipClick(Sender: TObject);
    procedure SecretClick(Sender: TObject);
  protected
    procedure Paint; override;
    procedure Resize; override;
  public
    constructor CreateRow(AOwner: TWinControl; ADlg: TTemplateForm; AKind: TTfRowKind;
      AIndex: Integer; const ATitle: string);
    procedure Restyle;
    procedure LayoutRow;
    procedure StyleChip;
    property Index: Integer read FIndex;
    property Kind: TTfRowKind read FKind;
  end;

  TTfState = record
    Text: string;
    // reprise a la main: ne suit plus les autres champs
    Manual: Boolean;
    Secret: RawByteString;
    // format et texte dont Secret est le hache: une saisie qui bouge le rend perime
    HashedFrom: string;
    // tire au sort pour cet envoi: a montrer une fois la creation faite
    Drawn: Boolean;
    // remis apres une issue inconnue: peut-etre deja pose sur un compte, on n'en change plus en douce
    DrawnHandedOver: Boolean;
    Error: string;
    Missing: Boolean;
    Searching: Boolean;
    Note: string;
  end;

  TTfUniqueState = (tusNone, tusReading, tusDone, tusFailed);

  TTemplateForm = class(TTaskDialog)
  private
    FT: TEntryTemplate;
    FParentDn: string;
    FAnalysis: TClassAnalysis;
    FState: array of TTfState;
    FRows: TFPList;
    FScroll: TRtScrollBox;
    FDnLabel, FStatusLabel: TLabel;
    FStatusIcon: TRtIcon;
    FCreate, FBatchBtn: TButton;
    FGroups: TGroupTargets;
    FGroupRow: TPanel;
    FGroupBar: TRtChipBar;
    FScan: TFreeNumberScan;
    FScanField: Integer;
    FScanBase: string;
    FScanQueue: array of Integer;
    FCreatedDn: string;
    FUpdating: Boolean;
    FCurrent: Integer;
    FSessionId: string;
    FGeneration: Int64;
    FEditH, FRowH, FLabelW, FBtnH: Integer;
    FHashTask: Int64;
    FHashField: Integer;
    // Creation en vol: l'assistant attend ses etapes en laissant passer les clics d'ici.
    FSubmitting: Boolean;
    FHashFrom: string;
    FPolicy: TAdPwdPolicy;
    FAskIndex: Integer;
    FPlannedDn: string;
    // noms deja pris dans l'annuaire: numero d'homonyme et comptes AD
    FUnique, FUniqueReading: TUniqueScan;
    FUniqueState: TTfUniqueState;
    FUniqueNote, FUniqueBase: string;
    FUniqueAt: QWord;
    FUniqueResult: TUniqueResult;
    FCreateAfterRead: Boolean;
    // domaines de la foret: -1 inconnu, 0 sans objet; au-dela d'un, les autres ne sont pas vus
    FForestDomains, FForestSeen: Integer;
    procedure StartUniqueScan;
    procedure EndUniqueScan(const AFailure: string);
    procedure DeferredCreate(AData: PtrInt);
    function IsAdPassword(AIndex: Integer): Boolean;
    function PolicyProblem(AIndex: Integer): string;
    procedure ValidateAdPassword(Sender: TObject; const ASecret: RawByteString; var ARefusal: string);
    procedure BuildUi;
    procedure ComputeMetrics;
    procedure BuildRows;
    function Schema: TSchemaSnapshot;
    function Provider: TProviderKind;
    function RowOfField(AIndex: Integer): TTfRow;
    function IsSecret(AIndex: Integer): Boolean;
    // mot de passe fixe, compose ou tire par le modele: rien a saisir
    function IsComputedSecret(AIndex: Integer): Boolean;
    function HashKey(AIndex: Integer): string;
    function StartHash(AIndex: Integer): Boolean;
    function SecretText(AIndex: Integer): string;
    procedure LocalMessage(AMsg: TUiMessage);
    procedure ShowDrawn(const ADn, AStatus: string);
    function IsDnField(AIndex: Integer): Boolean;
    procedure BrowseDn(AIndex: Integer);
    function IsRdn(AIndex: Integer): Boolean;
    function Required(AIndex: Integer): Boolean;
    procedure RowEdited(ARow: TTfRow);
    procedure ToggleManual(AIndex: Integer);
    procedure SetSecret(AIndex: Integer);
    procedure Revalidate;
    procedure UpdateStatus;
    procedure QueueScan(AIndex: Integer);
    procedure StartNextScan;
    procedure EndScan(const ANote: string; AHasValue: Boolean; AValue: Int64);
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure CreateClick(Sender: TObject);
    procedure BatchClick(Sender: TObject);
    procedure GroupsChanged(Sender: TObject);
    procedure GroupLayout(Sender: TObject);
    procedure GroupClose(Sender: TObject; AIndex: Integer);
    procedure GroupAction(Sender: TObject; AIndex: Integer);
    function FirstProblem: Integer;
    procedure FitRows;
  protected
    procedure ApplyShellColors; override;
    procedure DoShow; override;
    function HasRunningWork: Boolean; override;
  public
    constructor CreateForm(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
      AParentDn: string; const ATemplate: TEntryTemplate);
    destructor Destroy; override;
    procedure SetValue(const AAttr, AText: string);
    procedure Submit;
    function ValueOf(const AAttr: string): string;
    property Groups: TGroupTargets read FGroups;
    function DnText: string;
    function StatusText: string;
    property CreatedDn: string read FCreatedDn;
  end;

function CreateFromTemplate(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  AParentDn: string): string;

resourcestring
  rsTfTitle = 'Create from template';
  rsTfPickHelp = 'Choose the template of the entry to create under %s.';
  rsTfPickUse = 'Use';
  rsTfPickManage = 'Manage templates...';
  rsTfNoTemplates = 'There is no template yet. Open the template manager to create the first one?';
  rsTfNotUsable = 'The template "%s" cannot be used here as it is: %s' + LineEnding + LineEnding +
    'Open it in the template manager (Edit...) to correct it.';
  rsTfColName = 'Template';
  rsTfColKind = 'Creates';
  rsTfColStatus = 'On this server';
  rsTfColDesc = 'Description';
  rsTfUnder = 'Create under %s';
  rsTfDn = 'DN: %s';
  rsTfDnPending = 'DN: (fill in %s)';
  rsTfSectionAsk = 'To fill in';
  rsTfSectionAuto = 'Worked out by the template (can be changed)';
  rsTfSectionFixed = 'Fixed by the template';
  rsTfAuto = 'auto';
  rsTfManual = 'manual';
  rsTfAutoHint = 'Computed from the other values. Type to take over; click to let the template compute it again.';
  rsTfBrowse = 'browse';
  rsTfBrowseHint = 'Choose an entry of the directory';
  rsTfBrowsePrompt = 'Entry to put in %s';
  rsTfSearchAgain = 'search';
  rsTfSearchHint = 'Search the directory again for a free number';
  rsTfSearching = 'searching the directory...';
  rsTfSetPassword = 'Set password...';
  rsTfPasswordSet = 'password set';
  rsTfPasswordUnset = 'no password yet';
  rsTfPwdFixed = 'fixed by the template, stored as %s';
  rsTfPwdComposed = 'computed from the other values, stored as %s';
  rsTfPwdNothing = 'nothing to compose yet';
  rsTfPwdAd = 'sent with the account, in the same request';
  rsTfPwdAdFixed = 'fixed by the template, sent with the account';
  rsTfPwdAdComposed = 'computed from the other values, sent with the account';
  rsTfPwdRandom = 'drawn at random when the entry is created, shown once';
  rsTfAskPwdTitle = 'Password of the new account';
  rsTfAskPwd = 'Password';
  rsTfAskPwdConfirm = 'Confirm';
  rsTfAskPwdReveal = 'Show';
  rsTfHashing = 'Computing %s (%s)...';
  rsTfPwdClear = 'The connection is not encrypted: %s is not sent in clear. Connect with StartTLS or LDAPS.';
  rsTfHashBusy = 'Too many password computations are running. Try again in a moment.';
  rsTfHashFailed = '%s could not be computed: %s';
  rsTfDrawnStale = 'The password drawn for %s and handed over after an unknown outcome no longer passes ' +
    'the domain rules (%s). Check whether the account exists before sending again: the server may ' +
    'already hold that password.';
  rsTfCreate = 'Create...';
  rsTfBatch = 'Several from a CSV file...';
  rsTfGroups = 'Then added to';
  rsTfAddGroup = 'Group';
  rsTfGroupPrompt = 'Group the new entry joins';
  rsTfGroupsReading = 'Reading the groups...';
  rsTfGroupProblem = '%s Remove the group to go on without it.';
  rsTfReady = 'Ready. The entry is shown for a last check before anything is written.';
  rsTfMissing = 'Still to fill in: %s';
  rsTfError = '%s: %s';
  rsTfNumbers = 'Searching the directory for free numbers...';
  rsTfNumberFound = '%s: %d is free (%d value(s) read under %s).';
  rsTfNumberTooMany = '%s: too many values under %s to search safely; type the number.';
  rsTfNumberNone = '%s: no free number in the range; type one.';
  rsTfNumberIncomplete = '%s: the search under %s did not complete (%s); type the number.';
  rsTfNumberFailed = '%s: the search failed (%s); type the number.';
  rsTfNumberNoBase = '%s: no naming context contains %s; type the number.';
  rsTfNumberBusy = '%s: too many background tasks; click "search" to try again.';
  rsTfNumberLost = '%s: the connection changed during the search; click "search" to try again.';
  rsTfRequiredMark = '*';
  rsTfNoConnection = 'The connection is closed.';
  rsTfSessionChanged = 'The connection changed since the form was opened: free numbers and ' +
    'groups are being read again. Check the values, then create.';
  rsTfReadOnly = 'This profile is read-only: nothing can be created.';
  rsTfUniqueReading = 'Reading the names already taken in the directory...';
  rsTfUniqueFailed = 'The names already taken could not be read (%s): nothing guarantees this one is free. ' +
    'Click Create to read them again.';
  rsTfUniqueTooMany = 'too many values under %s';
  rsTfUniqueNoBase = 'no naming context contains %s';
  rsTfUniqueNumber = 'Ready with number %d: %s.';
  rsTfForestUnknown = 'Ready. Names were checked in %s only: the domains of the forest could not be listed, ' +
    'so an address or UPN held in another domain may not be seen.';
  rsTfForestPartial = 'Ready. Names were checked in %s only: the other %d domain(s) of the forest are not ' +
    'read, so an address or UPN held there is not seen.';
  rsTfLookalike = 'Already in the directory under that name: %s. Homonym or duplicate?';
  rsTfLookalikeAsk = 'An entry with the same name already exists:' + LineEnding + '%s' + LineEnding +
    LineEnding + 'If it is the same person, do not create a second account. Create %s anyway?';

implementation

uses
  Math, LCLIntf, uTheme, uConnections, uStrings, uPickDialog, uRtMessage, uServerKind, uAttributeCodec,
  uTemplateLibrary, uTemplateEditor, uTemplateManager, uCreateWizard, uDirectoryService,
  uDirectoryWorker, uSearchModel, uLdapEntry, uEntryPickDialog, uPasswordDialog, uRtBytes, uSensitive,
  uAdObjectPlan, uTemplateBatchDialog, uPwdCore, uPasswordSchemes, uPasswordWork,
  uRtPassword, uGeneratedPasswords,
  uRtSecretEdit;

const
  NUMBER_TAG = 'tplnumber';
  GROUP_TAG = 'tplgroup';
  POLICY_TAG = 'tplpolicy';
  UNIQUE_TAG = 'tplunique';
  FOREST_TAG = 'tplforest';
  // au-dela, les noms pris sont relus avant d'envoyer: un collegue a pu creer jdupont2 entre temps
  UNIQUE_FRESH_MS = 120000;
  RAIL_X = 6;
  RAIL_W = 3;
  ROW_LEFT = 18;

function MutedColor(ABack: TColor): TColor;
begin
  Result := BlendColor(clAppFg, ABack, 58);
end;

function PickTemplate(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  AParentDn: string; out T: TEntryTemplate): Boolean;
var
  d: TPickDialog;
  list: TEntryTemplates;
  rows: TPickRows;
  problems: TStringArray;
  bad, i, pass, n: Integer;
  r: TModalResult;
  status, info: string;
begin
  Result := False;
  T := NewTemplate;
  repeat
    list := LoadTemplates(ACtx.Document, bad);
    if Length(list) = 0 then
    begin
      if RtMessageDlg(rsTfTitle, rsTfNoTemplates, mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
      ShowTemplateManager(AOwner, ACtx, AProfileUuid);
      list := LoadTemplates(ACtx.Document, bad);
      if Length(list) = 0 then Exit;
    end;
    problems := nil;
    SetLength(problems, Length(list));
    rows := nil;
    SetLength(rows, Length(list));
    n := 0;
    // Ceux qui tiennent d'abord: on vient creer, pas reparer.
    for pass := 0 to 1 do
      for i := 0 to High(list) do
      begin
        if pass = 0 then problems[i] := TemplateProblemOn(ACtx, AProfileUuid, list[i]);
        if (problems[i] = '') <> (pass = 0) then Continue;
        if problems[i] = '' then
        begin
          status := rsTmUsable;
          info := rsTmReady;
        end
        else
        begin
          status := rsTmNotUsable;
          info := Format(rsTmProblem, [problems[i]]);
        end;
        rows[n].Key := list[i].Uuid;
        rows[n].Cells := [list[i].Name, TemplateKindText(list[i]), status, list[i].Description];
        rows[n].Info := info + #10 + TemplateSummary(list[i], ACtx.Sensitive);
        Inc(n);
      end;
    d := TPickDialog.CreatePick(AOwner, rsTfTitle, Format(rsTfPickHelp, [AParentDn]),
      [rsTfColName, rsTfColKind, rsTfColStatus, rsTfColDesc], [220, 240, 130, 260], rsTfPickManage);
    try
      d.SetIcon('file-plus');
      d.OkCaption := rsTfPickUse;
      d.SetRows(rows);
      r := RunPick(d);
      if r = mrRetry then
      begin
        ShowTemplateManager(AOwner, ACtx, AProfileUuid);
        Continue;
      end;
      if r <> mrOk then Exit;
      for i := 0 to High(list) do
        if list[i].Uuid = d.Chosen then
        begin
          if problems[i] <> '' then
          begin
            RtMessageDlg(rsTfTitle, Format(rsTfNotUsable, [list[i].Name, problems[i]]), mtWarning,
              [mbOK], 0);
            r := mrRetry;
            Break;
          end;
          T := list[i];
          Exit(True);
        end;
      if r <> mrRetry then Exit;
    finally
      d.Free;
    end;
  until False;
end;

function CreateFromTemplate(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  AParentDn: string): string;
var
  c: TDirectoryConnection;
  t: TEntryTemplate;
  f: TTemplateForm;
begin
  Result := '';
  c := ACtx.Connections.Find(AProfileUuid);
  if (c = nil) or not c.IsReady then Exit;
  if ACtx.Document = nil then
  begin
    RtMessageDlg(rsTfTitle, rsTmNoDocument, mtInformation, [mbOK], 0);
    Exit;
  end;
  if c.Schema = nil then
  begin
    RtMessageDlg(rsTfTitle, rsCpNoSchema, mtWarning, [mbOK], 0);
    Exit;
  end;
  if not PickTemplate(AOwner, ACtx, AProfileUuid, AParentDn, t) then Exit;
  f := TTemplateForm.CreateForm(AOwner, ACtx, AProfileUuid, AParentDn, t);
  try
    f.ShowModal;
    Result := f.CreatedDn;
  finally
    f.Free;
  end;
end;

{ TTfRow }

constructor TTfRow.CreateRow(AOwner: TWinControl; ADlg: TTemplateForm; AKind: TTfRowKind;
  AIndex: Integer; const ATitle: string);
var
  f: TTplField;
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FDlg := ADlg;
  FKind := AKind;
  FIndex := AIndex;
  FTitle := ATitle;
  TabStop := False;
  Parent := AOwner;
  Align := alTop;
  Height := ADlg.FRowH;
  if AKind = tfkField then
  begin
    f := ADlg.FT.Fields[AIndex];
    if ADlg.IsSecret(AIndex) then
    begin
      if not ADlg.IsComputedSecret(AIndex) then
      begin
        FSecretBtn := TRtFlatButton.Create(Self);
        FSecretBtn.Parent := Self;
        FSecretBtn.Setup('key', rsTfSetPassword, clAccent);
        FSecretBtn.OnClick := @SecretClick;
      end;
    end
    else if f.Source <> tsFixed then
    begin
      FEdit := TEdit.Create(Self);
      FEdit.Parent := Self;
      FEdit.BorderStyle := bsNone;
      FEdit.AutoSize := False;
      FEdit.Color := clEditorBg;
      FEdit.Font.Color := clEditorFg;
      FEdit.OnChange := @EditChange;
      FEdit.OnEnter := @EditEnter;
      FEdit.OnExit := @EditExit;
      if (f.Source in [tsCompose, tsNumber]) or ADlg.IsDnField(AIndex) then
      begin
        FChip := TRtFlatButton.Create(Self);
        FChip.Parent := Self;
        FChip.TabStop := False;
        FChip.ShowHint := True;
        FChip.OnClick := @ChipClick;
        if f.Source = tsNumber then
        begin
          FChip.Setup('refresh', rsTfSearchAgain, clDefault);
          FChip.Hint := rsTfSearchHint;
        end
        else if f.Source = tsAsk then
        begin
          FChip.Setup('search', rsTfBrowse, clDefault);
          FChip.Hint := rsTfBrowseHint;
        end
        else
          FChip.Hint := rsTfAutoHint;
      end;
    end;
  end;
  FBuilt := True;
  Restyle;
end;

procedure TTfRow.Restyle;
begin
  ThemeControlTree(Self);
  Color := clAppBg;
  StyleChip;
  LayoutRow;
end;

procedure TTfRow.StyleChip;
var
  c: TColor;
  f: TTplField;
begin
  if (FChip = nil) or (FIndex > High(FDlg.FT.Fields)) then Exit;
  f := FDlg.FT.Fields[FIndex];
  if f.Source = tsNumber then
  begin
    FChip.Ink := TemplateSourceColor(tsNumber);
    FChip.Border := BlendColor(FChip.Ink, clAppBg, 45);
    FChip.Enabled := not FDlg.FState[FIndex].Searching;
  end
  else if f.Source = tsAsk then
  begin
    FChip.Ink := TemplateSourceColor(tsAsk);
    FChip.Border := BlendColor(FChip.Ink, clAppBg, 45);
  end
  else if FDlg.FState[FIndex].Manual then
  begin
    FChip.Setup('pencil', rsTfManual, clDefault);
    FChip.Fill := clNone;
    FChip.Border := BlendColor(clAppFg, clAppBg, 25);
    FChip.Ink := BlendColor(clAppFg, clAppBg, 60);
  end
  else
  begin
    c := TemplateSourceColor(tsCompose);
    FChip.Setup('link', rsTfAuto, c);
    FChip.Fill := BlendColor(c, clAppBg, 14);
    FChip.Border := BlendColor(c, clAppBg, 45);
  end;
  FChip.Invalidate;
  LayoutRow;
end;

procedure TTfRow.LayoutRow;
var
  cy, right, x, w, chipW: Integer;
begin
  if not FBuilt then Exit;
  cy := ClientHeight div 2;
  right := ClientWidth - 12 - ScreenIconSize(16) - 8;
  x := ROW_LEFT + FDlg.FLabelW + 10;
  FTextLeft := x;
  {$IFDEF LCLGtk3}
  if FEdit <> nil then FEdit.Constraints.MaxHeight := FDlg.FEditH;
  {$ENDIF}
  if FChip <> nil then
  begin
    chipW := Max(Max(MeasureText(Font, rsTfAuto), MeasureText(Font, rsTfBrowse)),
      Max(MeasureText(Font, rsTfManual), MeasureText(Font, rsTfSearchAgain))) +
      ScreenIconSize(16) + 26;
    FChip.SetBounds(right - chipW, cy - FDlg.FBtnH div 2 + 2, chipW, FDlg.FBtnH - 4);
    Dec(right, chipW + 8);
  end;
  if FEdit <> nil then
    FEdit.SetBounds(x + 7, cy - FDlg.FEditH div 2 + 1, Max(60, right - x - 14), FDlg.FEditH);
  if FSecretBtn <> nil then
  begin
    w := FSecretBtn.PreferredWidth;
    FSecretBtn.SetBounds(x, cy - FDlg.FBtnH div 2, w, FDlg.FBtnH);
    FTextLeft := x + w + 12;
  end;
  Invalidate;
end;

procedure TTfRow.Resize;
begin
  inherited Resize;
  if FDlg <> nil then LayoutRow;
end;

procedure TTfRow.Paint;
var
  f: TTplField;
  st: TTfState;
  y, px, w: Integer;
  r: TRect;
  label1, iconId, shown: string;
  iconColor: TColor;
  bmp: TBitmap;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);
  Canvas.Font.Assign(Font);
  y := (ClientHeight - Canvas.TextHeight('Ag')) div 2;
  if FKind = tfkSection then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Style := [fsBold];
    Canvas.Font.Color := MutedColor(Color);
    Canvas.TextOut(ROW_LEFT - 8, y + 3, FTitle);
    w := ROW_LEFT - 8 + Canvas.TextWidth(FTitle) + 10;
    Canvas.Pen.Color := BlendColor(clAppFg, Color, 18);
    Canvas.Line(w, ClientHeight div 2 + 3, ClientWidth - 12, ClientHeight div 2 + 3);
    Exit;
  end;
  if FIndex > High(FDlg.FT.Fields) then Exit;
  f := FDlg.FT.Fields[FIndex];
  st := FDlg.FState[FIndex];
  Canvas.Brush.Color := TemplateSourceColor(f.Source);
  Canvas.FillRect(Rect(RAIL_X, 5, RAIL_X + RAIL_W, ClientHeight - 5));
  if FEdit <> nil then
  begin
    r := FEdit.BoundsRect;
    InflateRect(r, 7, 5);
    Canvas.Brush.Color := clEditorBg;
    if st.Error <> '' then Canvas.Pen.Color := DialogStateColor(usError)
    else if FEdit.Focused then Canvas.Pen.Color := clAccent
    else Canvas.Pen.Color := BlendColor(clAppFg, Color, 30);
    Canvas.RoundRect(r.Left, r.Top, r.Right, r.Bottom, 8, 8);
  end;
  Canvas.Brush.Style := bsClear;
  label1 := FieldPrompt(f);
  if FDlg.Required(FIndex) and (f.Source = tsAsk) then label1 := label1 + ' ' + rsTfRequiredMark;
  if FDlg.Required(FIndex) then Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := clAppFg;
  r := Rect(ROW_LEFT, 0, ROW_LEFT + FDlg.FLabelW, ClientHeight);
  Canvas.TextRect(r, r.Left, y, label1);
  w := Canvas.TextWidth(label1) + 10;
  Canvas.Font.Style := [];
  if not SameText(label1, f.Attr) and (w < FDlg.FLabelW - 20) then
  begin
    Canvas.Font.Color := MutedColor(Color);
    r := Rect(ROW_LEFT + w, 0, ROW_LEFT + FDlg.FLabelW, ClientHeight);
    Canvas.TextRect(r, r.Left, y, f.Attr);
  end;
  if FDlg.IsComputedSecret(FIndex) then
  begin
    Canvas.Font.Color := MutedColor(Color);
    r := Rect(FTextLeft + 7, 0, ClientWidth - 12 - ScreenIconSize(16) - 8, ClientHeight);
    Canvas.TextRect(r, r.Left, y, FDlg.SecretText(FIndex));
  end
  else if FDlg.IsSecret(FIndex) then
  begin
    Canvas.Font.Color := MutedColor(Color);
    if (st.Secret <> '') or (FDlg.IsAdPassword(FIndex) and (st.Text <> '')) then shown := rsTfPasswordSet
    else shown := rsTfPasswordUnset;
    Canvas.TextOut(FTextLeft, y, shown);
  end
  else if f.Source = tsFixed then
  begin
    Canvas.Font.Color := MutedColor(Color);
    r := Rect(FTextLeft + 7, 0, ClientWidth - 12 - ScreenIconSize(16) - 8, ClientHeight);
    Canvas.TextRect(r, r.Left, y, st.Text);
  end;
  if st.Error <> '' then
  begin
    iconId := 'alert-triangle';
    iconColor := DialogStateColor(usError);
  end
  else if st.Searching then
  begin
    iconId := 'loader-2';
    iconColor := MutedColor(Color);
  end
  else if st.Missing then
  begin
    iconId := 'circle-dashed';
    iconColor := DialogStateColor(usWarning);
  end
  else if (st.Text <> '') or (st.Secret <> '') then
  begin
    iconId := 'circle-check';
    iconColor := DialogStateColor(usOk);
  end
  else
  begin
    iconId := 'circle-minus';
    iconColor := BlendColor(clAppFg, Color, 30);
  end;
  px := ScreenIconSize(16);
  bmp := IconBitmap(iconId, px, iconColor);
  if bmp <> nil then Canvas.Draw(ClientWidth - 12 - px, (ClientHeight - px) div 2, bmp);
end;

procedure TTfRow.EditChange(Sender: TObject);
begin
  if FDlg.FUpdating then Exit;
  FDlg.RowEdited(Self);
end;

procedure TTfRow.EditEnter(Sender: TObject);
begin
  FDlg.FCurrent := FIndex;
  FDlg.UpdateStatus;
  Invalidate;
end;

procedure TTfRow.EditExit(Sender: TObject);
begin
  Invalidate;
end;

procedure TTfRow.ChipClick(Sender: TObject);
begin
  FDlg.ToggleManual(FIndex);
end;

procedure TTfRow.SecretClick(Sender: TObject);
begin
  FDlg.SetSecret(FIndex);
end;

{ TTemplateForm }

constructor TTemplateForm.CreateForm(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  AParentDn: string; const ATemplate: TEntryTemplate);
var
  c: TDirectoryConnection;
  i: Integer;
begin
  inherited CreateDialog(AOwner, rsTfTitle + ': ' + ATemplate.Name, 820, 640);
  SetIcon('file-plus');
  InitTasks(ACtx, AProfileUuid);
  FT := CloneTemplate(ATemplate);
  FParentDn := AParentDn;
  FRows := TFPList.Create;
  FCurrent := -1;
  FScanField := -1;
  c := Conn;
  if c <> nil then
  begin
    SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
    FSessionId := c.SessionId;
    FGeneration := c.Generation;
  end;
  Tasks.OnMessage := @TaskMessage;
  Tasks.OnUntracked := @LocalMessage;
  FHashField := -1;
  FGroups := TGroupTargets.Create(Tasks, GROUP_TAG);
  CheckTemplate(FT, Schema, Provider, FCtx.Sensitive, FAnalysis);
  SetLength(FState, Length(FT.Fields));
  for i := 0 to High(FT.Fields) do
  begin
    FState[i] := Default(TTfState);
    if FT.Fields[i].Source in [tsFixed, tsAsk] then FState[i].Text := FT.Fields[i].Value;
  end;
  BuildUi;
  ComputeMetrics;
  BuildRows;
  ApplyTheme;
  FitRows;
  for i := 0 to High(FT.Fields) do
    if (FT.Fields[i].Source = tsNumber) and (FState[i].Text = '') then QueueScan(i);
  FGroupBar.Color := clAppBg;
  FGroups.OnChange := @GroupsChanged;
  FGroups.SetGroups(FT.Groups);
  if (Provider = pkActiveDirectory) and (c <> nil) and (c.RootDse <> nil) and
     (c.RootDse.FirstValue('defaultNamingContext') <> '') then
    Tasks.ReadEntry(POLICY_TAG, c.RootDse.FirstValue('defaultNamingContext'), AD_POLICY_ATTRS);
  StartUniqueScan;
  Revalidate;
  StartNextScan;
end;

destructor TTemplateForm.Destroy;
var
  i: Integer;
begin
  // Un hachage en route ne revient pas vers un formulaire mort.
  PasswordWork.CancelOwner(Self);
  // Mots de passe effaces avant liberation, en clair compris.
  for i := 0 to High(FState) do
  begin
    if FState[i].Secret <> '' then WipeString(FState[i].Secret);
    if IsComputedSecret(i) then
    begin
      RtWipeSecret(FState[i].Text);
      RtWipeSecret(FState[i].HashedFrom);
    end;
  end;
  RtWipeSecret(FHashFrom);
  Application.RemoveAsyncCalls(Self);
  if Tasks <> nil then
  begin
    Tasks.Cancel(NUMBER_TAG);
    Tasks.Cancel(GROUP_TAG);
    Tasks.Cancel(UNIQUE_TAG);
    Tasks.Cancel(FOREST_TAG);
  end;
  FGroups.Free;
  FreeAndNil(FScan);
  FreeAndNil(FUnique);
  FreeAndNil(FUniqueReading);
  FRows.Free;
  inherited Destroy;
end;

function TTemplateForm.HasRunningWork: Boolean;
begin
  Result := FSubmitting;
end;

function TTemplateForm.Schema: TSchemaSnapshot;
var
  c: TDirectoryConnection;
begin
  Result := nil;
  c := Conn;
  if c <> nil then Result := c.Schema;
end;

function TTemplateForm.Provider: TProviderKind;
var
  c: TDirectoryConnection;
begin
  Result := pkAuto;
  c := Conn;
  if c <> nil then Result := EffectiveServerKind(c.Profile, c.RootDse);
end;

procedure TTemplateForm.BuildUi;
var
  banner, txt, statusRow: TPanel;
  ico: TRtIcon;
  lbl: TLabel;
begin
  banner := MakePanel(Body, alTop, 52);
  ico := TRtIcon.Create(banner);
  ico.Parent := banner;
  ico.Align := alLeft;
  ico.SetIcon('file-plus', 28, clAccent);
  txt := MakePanel(banner, alClient);
  lbl := MakeDataLabel(txt, Format(rsTfUnder, [AdCanonicalPath(FParentDn)]));
  lbl.Font.Color := DialogStateColor(usMuted);
  FDnLabel := MakeDataLabel(txt, '');
  FDnLabel.Font.Style := [fsBold];
  banner.Height := Max(ico.Width, StackedLabelsHeight(txt) + 6);

  FGroupRow := MakeFieldRow(Body, rsTfGroups, 130);
  FGroupRow.Align := alBottom;
  FGroupBar := TRtChipBar.Create(FGroupRow);
  FGroupBar.Parent := FGroupRow;
  FGroupBar.Align := alClient;
  FGroupBar.BorderSpacing.Top := 2;
  FGroupBar.Reorder := False;
  FGroupBar.OnChipClose := @GroupClose;
  FGroupBar.OnActionClick := @GroupAction;
  FGroupBar.OnLayoutChanged := @GroupLayout;

  statusRow := MakePanel(Body, alBottom, 44);
  FStatusIcon := TRtIcon.Create(statusRow);
  FStatusIcon.Parent := statusRow;
  FStatusIcon.Align := alLeft;
  FStatusIcon.Width := 24;
  FStatusIcon.TopAligned := True;
  FStatusIcon.BorderSpacing.Top := 4;
  FStatusLabel := MakeDataLabel(statusRow, '', alClient);
  FStatusLabel.WordWrap := True;

  FScroll := TRtScrollBox.Create(Body);
  FScroll.Parent := Body;
  FScroll.Align := alClient;
  FScroll.BorderSpacing.Top := 6;
  FScroll.HorzScrollBar.Visible := False;
  FScroll.VertScrollBar.Tracking := True;

  FCreate := AddButton(rsTfCreate, mrNone, True);
  FCreate.OnClick := @CreateClick;
  AddButton(rsCancel, mrCancel, False, True);
  FBatchBtn := AddButton(rsTfBatch, mrNone);
  FBatchBtn.OnClick := @BatchClick;
end;

procedure TTemplateForm.ComputeMetrics;
var
  bmp: Graphics.TBitmap;
  i, w: Integer;
begin
  bmp := Graphics.TBitmap.Create;
  try
    bmp.Canvas.Font.Assign(Font);
    if RSUiFontName <> '' then bmp.Canvas.Font.Name := RSUiFontName;
    bmp.Canvas.Font.Size := RSUiFontSize;
    FEditH := bmp.Canvas.TextHeight('Ag') + 4;
    FRowH := FEditH + 20;
    FBtnH := FEditH + 8;
    w := bmp.Canvas.TextWidth('0') * 22;
    bmp.Canvas.Font.Style := [fsBold];
    for i := 0 to High(FT.Fields) do
      w := Max(w, bmp.Canvas.TextWidth(FieldPrompt(FT.Fields[i]) + ' *') + 10 +
        bmp.Canvas.TextWidth(FT.Fields[i].Attr) + 6);
    FLabelW := Min(w, 340);
  finally
    bmp.Free;
  end;
end;

procedure TTemplateForm.BuildRows;
var
  y, i, section: Integer;
  title: string;
  any: Boolean;

  procedure NewRow(AKind: TTfRowKind; AIndex: Integer; const ATitle: string);
  var
    row: TTfRow;
  begin
    row := TTfRow.CreateRow(FScroll, Self, AKind, AIndex, ATitle);
    row.Top := y;
    Inc(y, row.Height);
    FRows.Add(row);
  end;

  function InSection(AIndex, ASection: Integer): Boolean;
  begin
    case FT.Fields[AIndex].Source of
      tsAsk: Result := ASection = 0;
      tsCompose, tsNumber, tsRandom: Result := ASection = 1;
    else
      Result := ASection = 2;
    end;
  end;

begin
  FUpdating := True;
  FScroll.DisableAlign;
  try
    for i := FRows.Count - 1 downto 0 do
      TObject(FRows[i]).Free;
    FRows.Clear;
    y := 0;
    for section := 0 to 2 do
    begin
      any := False;
      for i := 0 to High(FT.Fields) do
        if InSection(i, section) then any := True;
      if not any then Continue;
      case section of
        0: title := rsTfSectionAsk;
        1: title := rsTfSectionAuto;
      else
        title := rsTfSectionFixed;
      end;
      NewRow(tfkSection, -1, title);
      for i := 0 to High(FT.Fields) do
        if InSection(i, section) then NewRow(tfkField, i, '');
    end;
  finally
    FScroll.EnableAlign;
    FUpdating := False;
  end;
end;

procedure TTemplateForm.ApplyShellColors;
var
  i: Integer;
begin
  inherited ApplyShellColors;
  ComputeMetrics;
  for i := 0 to FRows.Count - 1 do
  begin
    TTfRow(FRows[i]).Height := FRowH;
    TTfRow(FRows[i]).Restyle;
  end;
  UpdateStatus;
end;

// Hauteur calee sur un nombre entier de rangees: aucune ne reste coupee en deux.
procedure TTemplateForm.FitRows;
var
  chrome, fit, shown: Integer;
begin
  if (FScroll = nil) or (FRowH <= 0) then Exit;
  chrome := Height - FScroll.Height;
  // Avant le premier affichage rien n'est mis en page: estimation, DoShow corrige.
  if (chrome < 120) or (chrome > 600) then chrome := 290;
  fit := Max(3, (Screen.WorkAreaHeight - 120 - chrome) div FRowH);
  shown := Max(3, Min(FRows.Count, fit));
  Height := chrome + shown * FRowH + 2;
  FScroll.VertScrollBar.Increment := FRowH;
end;

procedure TTemplateForm.DoShow;
begin
  inherited DoShow;
  FitRows;
end;

function TTemplateForm.RowOfField(AIndex: Integer): TTfRow;
var
  i: Integer;
begin
  for i := 0 to FRows.Count - 1 do
    if (TTfRow(FRows[i]).Kind = tfkField) and (TTfRow(FRows[i]).Index = AIndex) then
      Exit(TTfRow(FRows[i]));
  Result := nil;
end;

function TTemplateForm.IsSecret(AIndex: Integer): Boolean;
begin
  Result := FCtx.Sensitive.IsSensitive(FT.Fields[AIndex].Attr);
end;

function TTemplateForm.IsComputedSecret(AIndex: Integer): Boolean;
begin
  Result := IsSecret(AIndex) and (FT.Fields[AIndex].Source in [tsFixed, tsCompose, tsRandom]);
end;

function TTemplateForm.IsAdPassword(AIndex: Integer): Boolean;
begin
  Result := (Provider = pkActiveDirectory) and IsSecret(AIndex) and
    TemplatePasswordAttr(FT.Fields[AIndex].Attr, pkActiveDirectory, Schema);
end;

function TTemplateForm.PolicyProblem(AIndex: Integer): string;
begin
  Result := '';
  if not IsAdPassword(AIndex) or (FState[AIndex].Text = '') or FState[AIndex].Drawn then Exit;
  Result := AdPasswordProblem(FState[AIndex].Text, FPolicy, ValueOf('sAMAccountName'), ValueOf('displayName'));
end;

procedure TTemplateForm.ValidateAdPassword(Sender: TObject; const ASecret: RawByteString;
  var ARefusal: string);
begin
  if ASecret = '' then ARefusal := rsTfAskPwd
  else ARefusal := AdPasswordProblem(string(ASecret), FPolicy, ValueOf('sAMAccountName'), ValueOf('displayName'));
end;

function TTemplateForm.HashKey(AIndex: Integer): string;
begin
  Result := FT.Fields[AIndex].Scheme + #0 + FState[AIndex].Text;
end;

function TTemplateForm.SecretText(AIndex: Integer): string;
var
  sch: TPasswordScheme;
  v: RawByteString;
begin
  if FT.Fields[AIndex].Source = tsRandom then
  begin
    if Provider = pkActiveDirectory then Exit(rsTfPwdRandom);
    Exit(rsTfPwdRandom + ', ' + FT.Fields[AIndex].Scheme);
  end;
  if FState[AIndex].Text = '' then Exit(rsTfPwdNothing);
  if Provider = pkActiveDirectory then
  begin
    if FT.Fields[AIndex].Source = tsFixed then Exit(rsTfPwdAdFixed);
    Exit(rsTfPwdAdComposed);
  end;
  // Une identite deleguee n'a rien de secret: on montre ce qui sera stocke.
  if TemplateSecretShown(FT.Fields[AIndex]) then
  begin
    sch := PasswordRegistry.FindById(FT.Fields[AIndex].Scheme);
    if sch <> nil then
      try
        v := sch.Generate(FState[AIndex].Text, DefaultGenParams);
        Exit(string(v));
      except
        on E: Exception do Exit(E.Message);
      end;
  end;
  if FT.Fields[AIndex].Source = tsFixed then Result := Format(rsTfPwdFixed, [FT.Fields[AIndex].Scheme])
  else Result := Format(rsTfPwdComposed, [FT.Fields[AIndex].Scheme]);
end;

function TTemplateForm.StartHash(AIndex: Integer): Boolean;
var
  pw: RawByteString;
begin
  Result := False;
  if FHashTask <> 0 then Exit;
  pw := FState[AIndex].Text;
  try
    FHashField := AIndex;
    FHashFrom := HashKey(AIndex);
    FHashTask := NextTaskId;
    if not PasswordWork.StartGenerate(FT.Fields[AIndex].Scheme, pw, Self, FHashTask) then
    begin
      FHashTask := 0;
      FHashField := -1;
      RtWipeSecret(FHashFrom);
      RtMessageDlg(rsTfTitle, rsTfHashBusy, mtWarning, [mbOK], 0);
      Exit;
    end;
  finally
    WipeString(pw);
  end;
  FCreate.Enabled := False;
  UpdateStatus;
  Result := True;
end;

procedure TTemplateForm.LocalMessage(AMsg: TUiMessage);
var
  pw: TPwdWorkMsg;
  i: Integer;
begin
  if not (AMsg is TPwdWorkMsg) or (FHashTask = 0) or (AMsg.TaskId <> FHashTask) then Exit;
  pw := TPwdWorkMsg(AMsg);
  i := FHashField;
  FHashTask := 0;
  FHashField := -1;
  FCreate.Enabled := True;
  UpdateStatus;
  if (pw.ErrorText <> '') or (i < 0) or (i > High(FState)) then
  begin
    RtWipeSecret(FHashFrom);
    if i >= 0 then
      RtMessageDlg(rsTfTitle, Format(rsTfHashFailed, [FT.Fields[i].Attr, pw.ErrorText]), mtError, [mbOK], 0);
    Exit;
  end;
  if FState[i].Secret <> '' then WipeString(FState[i].Secret);
  FState[i].Secret := pw.Generated;
  pw.Generated := '';
  RtWipeSecret(FState[i].HashedFrom);
  FState[i].HashedFrom := FHashFrom;
  FHashFrom := '';
  // L'utilisateur a clique Create: on reprend, et ce qui a bouge entre-temps se recalcule.
  CreateClick(nil);
end;

function TTemplateForm.IsDnField(AIndex: Integer): Boolean;
begin
  Result := (FT.Fields[AIndex].Source = tsAsk) and (Schema <> nil) and not IsSecret(AIndex) and
    (ResolveValueKind(Schema, FT.Fields[AIndex].Attr, Provider).Kind = vkDn);
end;

procedure TTemplateForm.BrowseDn(AIndex: Integer);
var
  c: TDirectoryConnection;
  dn: string;
  row: TTfRow;
begin
  c := Conn;
  if (c = nil) or not c.IsReady or (AIndex < 0) or (AIndex > High(FState)) then Exit;
  dn := FState[AIndex].Text;
  if not PickDirectoryEntry(Self, FCtx, FProfileUuid, FieldPrompt(FT.Fields[AIndex]),
    Format(rsTfBrowsePrompt, [FT.Fields[AIndex].Attr]), NextIdBaseFor(c, FParentDn), '', dn) then Exit;
  row := RowOfField(AIndex);
  if (row <> nil) and (row.FEdit <> nil) then row.FEdit.Text := Trim(dn);
end;

function TTemplateForm.IsRdn(AIndex: Integer): Boolean;
begin
  Result := SameAttr(FT.Fields[AIndex].Attr, FT.RdnAttr) and (FieldIndex(FT, FT.RdnAttr) = AIndex);
end;

function TTemplateForm.Required(AIndex: Integer): Boolean;
begin
  Result := IsRdn(AIndex) or
    ((FieldIndex(FT, FT.Fields[AIndex].Attr) = AIndex) and
      IsRequiredAttr(FAnalysis, Schema, FT.Fields[AIndex].Attr)) or
    ((FT.Fields[AIndex].Source = tsAsk) and not IsSecret(AIndex) and
      (not FT.Fields[AIndex].Optional or (ComposedFrom(FT, AIndex) <> '')));
end;

procedure TTemplateForm.RowEdited(ARow: TTfRow);
var
  i: Integer;
begin
  i := ARow.Index;
  if (i < 0) or (i > High(FState)) or (ARow.FEdit = nil) then Exit;
  FState[i].Text := ARow.FEdit.Text;
  // Une valeur calculee qu'on retouche ne suit plus: sinon la frappe suivante l'efface.
  if (FT.Fields[i].Source in [tsCompose, tsNumber]) and not FState[i].Manual then
  begin
    FState[i].Manual := True;
    ARow.StyleChip;
  end;
  Revalidate;
end;

procedure TTemplateForm.ToggleManual(AIndex: Integer);
var
  row: TTfRow;
begin
  if (AIndex < 0) or (AIndex > High(FState)) then Exit;
  if FT.Fields[AIndex].Source = tsAsk then
  begin
    BrowseDn(AIndex);
    Exit;
  end;
  row := RowOfField(AIndex);
  if FT.Fields[AIndex].Source = tsNumber then
  begin
    if FState[AIndex].Searching then Exit;
    FState[AIndex].Manual := False;
    QueueScan(AIndex);
    Revalidate;
    StartNextScan;
    Exit;
  end;
  FState[AIndex].Manual := not FState[AIndex].Manual;
  if row <> nil then row.StyleChip;
  Revalidate;
end;

procedure TTemplateForm.SetSecret(AIndex: Integer);
var
  c: TDirectoryConnection;
  v: RawByteString;
  d: TRtPasswordDialog;
  plain: string;
begin
  c := Conn;
  if (c = nil) or (AIndex < 0) or (AIndex > High(FState)) or not IsSecret(AIndex) then Exit;
  // AD hache lui-meme: on prend le texte, deux fois.
  if IsAdPassword(AIndex) then
  begin
    d := TRtPasswordDialog.CreateDialog(Self, rsTfAskPwdTitle, 520, 260);
    try
      d.SetIcon('key');
      d.SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
      d.AddField(rsTfAskPwd);
      d.AddConfirm(rsTfAskPwdConfirm);
      d.AddReveal(rsTfAskPwdReveal);
      d.AddStatus;
      FAskIndex := AIndex;
      d.OnValidate := @ValidateAdPassword;
      if not d.Execute(plain) then Exit;
    finally
      d.Free;
    end;
    RtWipeSecret(FState[AIndex].Text);
    FState[AIndex].Text := plain;
    RtWipeSecret(plain);
    Revalidate;
    Exit;
  end;
  // Valeur calculee par les outils de mot de passe: jamais une saisie brute.
  if not ComputePasswordValue(Self, FCtx, c, v) then Exit;
  try
    if FState[AIndex].Secret <> '' then WipeString(FState[AIndex].Secret);
    FState[AIndex].Secret := Copy(v, 1, MaxInt);
  finally
    WipeString(v);
  end;
  Revalidate;
end;

procedure TTemplateForm.Revalidate;
var
  values: TStringArray;
  manual: array of Boolean;
  i: Integer;
  row: TTfRow;
  err, dn: string;
  rdn: TRdnAvas;
  ri: Integer;
  budget: Int64;
begin
  values := nil;
  manual := nil;
  SetLength(values, Length(FState));
  SetLength(manual, Length(FState));
  for i := 0 to High(FState) do
  begin
    values[i] := FState[i].Text;
    manual[i] := FState[i].Manual;
  end;
  FUniqueResult := Default(TUniqueResult);
  FUniqueResult.ProblemField := -1;
  if FUnique <> nil then
  begin
    budget := TEMPLATE_COMPOSE_BUDGET;
    FUniqueResult := FUnique.Resolve(FT, values, manual, budget);
  end
  else
    ComposeValues(FT, values, manual);
  FUpdating := True;
  try
    for i := 0 to High(FState) do
    begin
      row := RowOfField(i);
      if (FT.Fields[i].Source = tsCompose) and not FState[i].Manual then
        FState[i].Text := values[i];
      if (row <> nil) and (row.FEdit <> nil) and (row.FEdit.Text <> FState[i].Text) then
        row.FEdit.Text := FState[i].Text;
      if (row <> nil) and (row.FEdit <> nil) then
      begin
        if FState[i].Searching then row.FEdit.TextHint := rsTfSearching
        else row.FEdit.TextHint := '';
      end;
      FState[i].Error := '';
      FState[i].Missing := False;
      if IsComputedSecret(i) then
      begin
        // Tire au sort a l'envoi: ni manquant ni a juger avant.
        if FT.Fields[i].Source <> tsRandom then
          FState[i].Missing := (FState[i].Text = '') and IsRequiredAttr(FAnalysis, Schema, FT.Fields[i].Attr);
        if Length(FState[i].Text) > TEMPLATE_TEXT_MAX then
          FState[i].Error := Format(rsTplValueTooLong, [TEMPLATE_TEXT_MAX])
        else
          FState[i].Error := PolicyProblem(i);
      end
      else if IsAdPassword(i) then
      begin
        FState[i].Missing := (FState[i].Text = '') and not FT.Fields[i].Optional;
        FState[i].Error := PolicyProblem(i);
      end
      else if IsSecret(i) then
        FState[i].Missing := (FState[i].Secret = '') and
          IsRequiredAttr(FAnalysis, Schema, FT.Fields[i].Attr)
      else if FState[i].Text = '' then
        FState[i].Missing := Required(i) and not FState[i].Searching
      else
        FState[i].Error := TemplateValueProblem(Schema, Provider, FT.Fields[i].Attr, FState[i].Text);
      if (i = FUniqueResult.ProblemField) and (FState[i].Error = '') then
        FState[i].Error := FUniqueResult.Problem;
      if row <> nil then
      begin
        row.StyleChip;
        row.Invalidate;
      end;
    end;
  finally
    FUpdating := False;
  end;
  ri := FieldIndex(FT, FT.RdnAttr);
  if (ri >= 0) and (FState[ri].Text <> '') then
  begin
    rdn := nil;
    SetLength(rdn, 1);
    rdn[0].Attr := FT.RdnAttr;
    rdn[0].Value := FState[ri].Text;
    if BuildCreationDn(FParentDn, rdn, dn, err) then
    begin
      FDnLabel.Caption := Format(rsTfDn, [dn]);
      FPlannedDn := dn;
    end
    else FDnLabel.Caption := err;
  end
  else if ri >= 0 then
    FDnLabel.Caption := Format(rsTfDnPending, [FieldPrompt(FT.Fields[ri])])
  else
    FDnLabel.Caption := '';
  UpdateStatus;
end;

function TTemplateForm.FirstProblem: Integer;
var
  i: Integer;
begin
  for i := 0 to High(FState) do
    if FState[i].Error <> '' then Exit(i);
  for i := 0 to High(FState) do
    if FState[i].Missing then Exit(i);
  Result := -1;
end;

procedure TTemplateForm.UpdateStatus;
var
  i: Integer;
  missing, msg: string;
  state: TUiState;
  searching: Boolean;
  iconId: string;
begin
  if FStatusLabel = nil then Exit;
  msg := '';
  state := usOk;
  searching := False;
  missing := '';
  for i := 0 to High(FState) do
  begin
    if FState[i].Searching then searching := True;
    if FState[i].Missing and ((FT.Fields[i].Source = tsAsk) or FState[i].Manual) then
    begin
      if missing <> '' then missing := missing + ', ';
      missing := missing + FieldPrompt(FT.Fields[i]);
    end;
  end;
  if missing = '' then
    for i := 0 to High(FState) do
      if FState[i].Missing then
      begin
        missing := FieldPrompt(FT.Fields[i]);
        Break;
      end;
  if (FCurrent >= 0) and (FCurrent <= High(FState)) and (FState[FCurrent].Error <> '') then
    msg := Format(rsTfError, [FieldPrompt(FT.Fields[FCurrent]), FState[FCurrent].Error]);
  if msg = '' then
    for i := 0 to High(FState) do
      if FState[i].Error <> '' then
      begin
        msg := Format(rsTfError, [FieldPrompt(FT.Fields[i]), FState[i].Error]);
        Break;
      end;
  if msg <> '' then state := usError
  else if missing <> '' then
  begin
    msg := Format(rsTfMissing, [missing]);
    state := usWarning;
  end
  else if FUniqueState = tusFailed then
  begin
    msg := Format(rsTfUniqueFailed, [FUniqueNote]);
    state := usError;
  end
  else if searching then
  begin
    msg := rsTfNumbers;
    state := usMuted;
  end
  else if FUniqueState = tusReading then
  begin
    msg := rsTfUniqueReading;
    state := usMuted;
  end
  else if FUniqueResult.Lookalike <> '' then
  begin
    msg := Format(rsTfLookalike, [FUniqueResult.Lookalike]);
    state := usWarning;
  end
  else if FForestDomains > 1 then
  begin
    msg := Format(rsTfForestPartial, [FUniqueBase, FForestDomains - 1]);
    state := usWarning;
  end
  else if FForestDomains < 0 then
  begin
    msg := Format(rsTfForestUnknown, [FUniqueBase]);
    state := usWarning;
  end
  else
  begin
    msg := rsTfReady;
    if FUniqueResult.Skipped <> '' then
      msg := Format(rsTfUniqueNumber, [FUniqueResult.Counter, FUniqueResult.Skipped]);
    if (FCurrent >= 0) and (FCurrent <= High(FState)) and (FState[FCurrent].Note <> '') then
      msg := FState[FCurrent].Note;
  end;
  if state <> usError then
    for i := 0 to High(FState) do
      if (FState[i].Note <> '') and (FState[i].Text = '') and not FState[i].Searching then
      begin
        msg := FState[i].Note;
        state := usWarning;
        Break;
      end;
  if state <> usError then
  begin
    if FGroups.FirstProblem <> '' then
    begin
      msg := Format(rsTfGroupProblem, [FGroups.FirstProblem]);
      state := usError;
    end
    else if FGroups.Busy and (state = usOk) then
    begin
      msg := rsTfGroupsReading;
      state := usMuted;
    end;
  end;
  if (FHashTask <> 0) and (FHashField >= 0) and (FHashField <= High(FT.Fields)) then
  begin
    msg := Format(rsTfHashing, [FT.Fields[FHashField].Attr, FT.Fields[FHashField].Scheme]);
    state := usMuted;
  end;
  FStatusLabel.Caption := msg;
  FStatusLabel.Font.Color := DialogStateColor(state);
  case state of
    usOk: iconId := 'circle-check';
    usError: iconId := 'alert-triangle';
  else
    iconId := 'info-circle';
  end;
  FStatusIcon.SetIcon(iconId, 16, DialogStateColor(state));
end;

{ Numeros libres }

procedure TTemplateForm.QueueScan(AIndex: Integer);
var
  i: Integer;
begin
  for i := 0 to High(FScanQueue) do
    if FScanQueue[i] = AIndex then Exit;
  if FScanField = AIndex then Exit;
  SetLength(FScanQueue, Length(FScanQueue) + 1);
  FScanQueue[High(FScanQueue)] := AIndex;
  FState[AIndex].Searching := True;
  FState[AIndex].Note := '';
end;

procedure TTemplateForm.StartNextScan;
var
  c: TDirectoryConnection;
  i, k: Integer;
  f: TTplField;
begin
  while (FScan = nil) and (Length(FScanQueue) > 0) do
  begin
    i := FScanQueue[0];
    for k := 0 to High(FScanQueue) - 1 do
      FScanQueue[k] := FScanQueue[k + 1];
    SetLength(FScanQueue, Length(FScanQueue) - 1);
    f := FT.Fields[i];
    FScanField := i;
    c := Conn;
    if (c = nil) or not c.IsReady then
    begin
      EndScan(Format(rsTfNumberLost, [f.Attr]), False, 0);
      Continue;
    end;
    FScanBase := NextIdBaseFor(c, FParentDn);
    if FScanBase = '' then
    begin
      EndScan(Format(rsTfNumberNoBase, [f.Attr, FParentDn]), False, 0);
      Continue;
    end;
    FScan := TFreeNumberScan.Create(f.Attr, f.NumberMode = tnFirstFree, f.HasMin, f.HasMax, f.Min,
      f.Max, Provider, Schema);
    if Tasks.Search(NUMBER_TAG, NextIdSearchRequest(c.Profile, FScanBase, FScan.Attr)) = 0 then
      EndScan(Format(rsTfNumberBusy, [f.Attr]), False, 0);
  end;
end;

procedure TTemplateForm.EndScan(const ANote: string; AHasValue: Boolean; AValue: Int64);
var
  i: Integer;
begin
  i := FScanField;
  FScanField := -1;
  FreeAndNil(FScan);
  if (i < 0) or (i > High(FState)) then Exit;
  FState[i].Searching := False;
  FState[i].Note := ANote;
  // Saisie faite pendant la recherche: elle prime.
  if AHasValue and not FState[i].Manual then FState[i].Text := IntToStr(AValue);
  if ANote <> '' then
  begin
    if AHasValue then FCtx.Log(mlInfo, rsTfTitle, ANote) else FCtx.Log(mlWarning, rsTfTitle, ANote);
  end;
  Revalidate;
end;

procedure TTemplateForm.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
var
  m: TEntriesMsg;
  i: Integer;
  n: Int64;
  attr, reason: string;
begin
  if FGroups.HandleMessage(AMsg, ATask, AEnding) then Exit;
  if ATask.Tag = POLICY_TAG then
  begin
    // Politique illisible: le serveur jugera seul, comme avant.
    if (AEnding <> teStale) and (AMsg is TEntryMsg) and (TEntryMsg(AMsg).Entry <> nil) then
    begin
      FPolicy := AdPolicyFromDomain(TEntryMsg(AMsg).Entry);
      Revalidate;
    end;
    Exit;
  end;
  if ATask.Tag = FOREST_TAG then
  begin
    // Echec ou liste tronquee: on reste a "inconnu".
    if (AEnding <> teStale) and (AMsg is TEntriesMsg) then
    begin
      m := TEntriesMsg(AMsg);
      if m.Entries <> nil then Inc(FForestSeen, m.Entries.Count);
      if m.Final then
      begin
        if (SearchOutcome(m.Completion) = soComplete) and (FForestSeen > 0) then FForestDomains := FForestSeen;
        UpdateStatus;
      end;
    end;
    Exit;
  end;
  if ATask.Tag = UNIQUE_TAG then
  begin
    if FUniqueReading = nil then Exit;
    if AEnding = teStale then EndUniqueScan(rsTfNoConnection)
    else if AMsg is TTaskFailedMsg then EndUniqueScan(TTaskFailedMsg(AMsg).Text)
    else if AMsg is TEntriesMsg then
    begin
      m := TEntriesMsg(AMsg);
      if m.Entries <> nil then
        for i := 0 to m.Entries.Count - 1 do FUniqueReading.Feed(TLdapEntry(m.Entries[i]));
      if not m.Final then Exit;
      if SearchOutcome(m.Completion) <> soComplete then
      begin
        reason := ResultCodeName(m.Completion.ResultCode);
        if m.Completion.SizeLimitHit then reason := 'size limit'
        else if m.Completion.TimeLimitHit then reason := 'time limit'
        else if m.Completion.Cancelled then reason := 'cancelled';
        EndUniqueScan(reason);
      end
      else if FUniqueReading.Overflow then
        EndUniqueScan(Format(rsTfUniqueTooMany, [FUniqueBase]))
      else
        EndUniqueScan('');
    end;
    Exit;
  end;
  if (ATask.Tag <> NUMBER_TAG) or (FScan = nil) or (FScanField < 0) then Exit;
  attr := FT.Fields[FScanField].Attr;
  if AEnding = teStale then
  begin
    EndScan(Format(rsTfNumberLost, [attr]), False, 0);
    StartNextScan;
    Exit;
  end;
  if AMsg is TTaskFailedMsg then
  begin
    EndScan(Format(rsTfNumberFailed, [attr, TTaskFailedMsg(AMsg).Text]), False, 0);
    StartNextScan;
    Exit;
  end;
  if not (AMsg is TEntriesMsg) then Exit;
  m := TEntriesMsg(AMsg);
  if m.Entries <> nil then
    for i := 0 to m.Entries.Count - 1 do FScan.Feed(TLdapEntry(m.Entries[i]));
  if not m.Final then Exit;
  // Enumeration incomplete: aucun numero n'est sur, rien n'est propose.
  if SearchOutcome(m.Completion) <> soComplete then
  begin
    reason := ResultCodeName(m.Completion.ResultCode);
    if m.Completion.SizeLimitHit then reason := 'size limit'
    else if m.Completion.TimeLimitHit then reason := 'time limit'
    else if m.Completion.Cancelled then reason := 'cancelled';
    EndScan(Format(rsTfNumberIncomplete, [attr, FScanBase, reason]), False, 0);
  end
  else if FScan.Overflow then
    EndScan(Format(rsTfNumberTooMany, [attr, FScanBase]), False, 0)
  else if FScan.Pick(n) then
    EndScan(Format(rsTfNumberFound, [attr, n, FScan.Found, FScanBase]), True, n)
  else
    EndScan(Format(rsTfNumberNone, [attr]), False, 0);
  StartNextScan;
end;

{ Noms deja pris }

procedure TTemplateForm.StartUniqueScan;
var
  c: TDirectoryConnection;
begin
  Tasks.Cancel(UNIQUE_TAG);
  FreeAndNil(FUniqueReading);
  FUniqueState := tusNone;
  FUniqueNote := '';
  c := Conn;
  if c = nil then Exit;
  FForestDomains := 0;
  Tasks.Cancel(FOREST_TAG);
  FUniqueReading := TUniqueScan.Create(FT, Provider, Schema);
  if not FUniqueReading.Needed then
  begin
    FreeAndNil(FUniqueReading);
    FreeAndNil(FUnique);
    Exit;
  end;
  FUniqueState := tusReading;
  if Provider = pkActiveDirectory then
  begin
    // Inconnu tant que pas prouve: un refus de lire les partitions ne fait pas une foret d'un arbre.
    FForestDomains := -1;
    FForestSeen := 0;
    if (c.RootDse <> nil) and (c.RootDse.FirstValue('configurationNamingContext', '') <> '') then
      Tasks.Search(FOREST_TAG, ForestDomainsRequest(c.Profile, c.RootDse.FirstValue('configurationNamingContext', '')));
  end;
  FUniqueBase := NextIdBaseFor(c, FParentDn);
  if FUniqueBase = '' then
    EndUniqueScan(Format(rsTfUniqueNoBase, [FParentDn]))
  else if Tasks.Search(UNIQUE_TAG, UniqueSearchRequest(c.Profile, FUniqueBase, FUniqueReading)) = 0 then
    EndUniqueScan(rsTfHashBusy);
end;

procedure TTemplateForm.EndUniqueScan(const AFailure: string);
begin
  if AFailure <> '' then
  begin
    FreeAndNil(FUniqueReading);
    FUniqueState := tusFailed;
    FUniqueNote := AFailure;
    FCreateAfterRead := False;
    FCtx.Log(mlWarning, rsTfTitle, Format(rsTfUniqueFailed, [AFailure]));
  end
  else
  begin
    FreeAndNil(FUnique);
    FUnique := FUniqueReading;
    FUniqueReading := nil;
    FUniqueState := tusDone;
    FUniqueAt := GetTickCount64;
  end;
  Revalidate;
  if FCreateAfterRead and (FUniqueState = tusDone) then
  begin
    FCreateAfterRead := False;
    // pas depuis le traitement du message: l'assistant modal attendrait sous nos pieds
    Application.QueueAsyncCall(@DeferredCreate, 0);
  end;
end;

procedure TTemplateForm.DeferredCreate(AData: PtrInt);
begin
  if not FSubmitting then CreateClick(nil);
end;

{ Creation }

procedure TTemplateForm.CreateClick(Sender: TObject);
var
  c: TDirectoryConnection;
  p: TCreatePrefill;
  i, bad, ri, n: Integer;
  row: TTfRow;
  created: string;
  outcome: TStepOutcome;
  strict: TAdPwdPolicy;
  problem: string;
begin
  if not FCreate.Enabled then Exit;
  c := Conn;
  if (c = nil) or not c.IsReady then
  begin
    RtMessageDlg(rsTfTitle, rsTfNoConnection, mtWarning, [mbOK], 0);
    Exit;
  end;
  if c.Profile.ReadOnly then
  begin
    RtMessageDlg(rsTfTitle, rsTfReadOnly, mtWarning, [mbOK], 0);
    Exit;
  end;
  if (c.SessionId <> FSessionId) or (c.Generation <> FGeneration) then
  begin
    // Lus sur la session d'avant: un numero libre hier ne l'est plus forcement. On relit.
    FSessionId := c.SessionId;
    FGeneration := c.Generation;
    for i := 0 to High(FT.Fields) do
      if (FT.Fields[i].Source = tsNumber) and not FState[i].Manual then
      begin
        FState[i].Text := '';
        QueueScan(i);
      end;
    FGroups.SetGroups(FGroups.Dns);
    StartUniqueScan;
    Revalidate;
    StartNextScan;
    RtMessageDlg(rsTfTitle, rsTfSessionChanged, mtWarning, [mbOK], 0);
    Exit;
  end;
  if FUniqueState = tusReading then Exit;
  // Echec ou lecture trop vieille: on relit, et on cree dans la foulee si rien n'a bouge.
  if (FUniqueState = tusFailed) or ((FUniqueState = tusDone) and
     (GetTickCount64 - FUniqueAt > UNIQUE_FRESH_MS)) then
  begin
    FCreateAfterRead := FUniqueState = tusDone;
    StartUniqueScan;
    Revalidate;
    Exit;
  end;
  Revalidate;
  // On n'inscrit personne dans un groupe qu'on n'a pas lu.
  if FGroups.Busy or (FGroups.FirstProblem <> '') then Exit;
  bad := FirstProblem;
  if bad >= 0 then
  begin
    // Plutot qu'un bouton grise sans explication: droit au premier champ qui bloque.
    FCurrent := bad;
    UpdateStatus;
    row := RowOfField(bad);
    if row <> nil then
    begin
      FScroll.ScrollInView(row);
      if (row.FEdit <> nil) and row.FEdit.CanFocus then row.FEdit.SetFocus
      else if (row.FSecretBtn <> nil) and row.FSecretBtn.CanFocus then row.FSecretBtn.SetFocus;
    end;
    Exit;
  end;
  // Connexion en clair: le serveur refuserait, autant ne rien calculer.
  for i := 0 to High(FState) do
    if (IsComputedSecret(i) or IsAdPassword(i)) and
       ((FState[i].Text <> '') or (FT.Fields[i].Source = tsRandom)) and not c.SecretsSafe then
    begin
      RtMessageDlg(rsTfTitle, Format(rsTfPwdClear, [FT.Fields[i].Attr]), mtWarning, [mbOK], 0);
      Exit;
    end;
  // Un tirage garde d'un envoi precedent se rejuge: compte, nom affiche ou politique ont pu changer.
  for i := 0 to High(FState) do
    if FState[i].Drawn and (FState[i].Text <> '') and IsAdPassword(i) then
    begin
      strict := FPolicy;
      strict.Known := True;
      strict.Complex := True;
      problem := AdPasswordProblem(FState[i].Text, strict, ValueOf('sAMAccountName'), ValueOf('displayName'));
      if problem = '' then Continue;
      if FState[i].DrawnHandedOver then
      begin
        RtMessageDlg(rsTfTitle, Format(rsTfDrawnStale, [FT.Fields[i].Attr, problem]), mtWarning, [mbOK], 0);
        Exit;
      end;
      // Jamais montre a personne: on en tire un autre.
      RtWipeSecret(FState[i].Text);
      FState[i].Drawn := False;
    end;
  // Tire une fois par formulaire: un envoi refuse puis repris garde le meme.
  for i := 0 to High(FState) do
    if IsComputedSecret(i) and (FT.Fields[i].Source = tsRandom) and (FState[i].Text = '') then
    begin
      if IsAdPassword(i) then
        FState[i].Text := RandomAdPassword(FT.Fields[i].RandomLength, FPolicy, ValueOf('sAMAccountName'),
          ValueOf('displayName'))
      else
        FState[i].Text := RandomPassword(Max(FT.Fields[i].RandomLength, FPolicy.MinLength));
      FState[i].Drawn := True;
    end;
  if Provider <> pkActiveDirectory then
    for i := 0 to High(FState) do
      if IsComputedSecret(i) and (FState[i].Text <> '') and
         ((FState[i].Secret = '') or (FState[i].HashedFrom <> HashKey(i))) then
      begin
        StartHash(i);
        Exit;
      end;
  // Homonyme ou doublon: la machine ne sait pas, l'operateur si.
  if (FUniqueResult.Lookalike <> '') and (RtMessageDlg(rsTfTitle, Format(rsTfLookalikeAsk,
     [FUniqueResult.Lookalike, FPlannedDn]), mtWarning, [mbYes, mbNo], 0) <> mrYes) then Exit;
  p := Default(TCreatePrefill);
  p.Structural := FT.Structural;
  p.Auxiliaries := Copy(FT.Auxiliaries, 0, Length(FT.Auxiliaries));
  ri := FieldIndex(FT, FT.RdnAttr);
  if ri < 0 then Exit;
  p.RdnAttr := FT.RdnAttr;
  p.RdnText := FState[ri].Text;
  p.Joins := FGroups.Joins;
  if TemplateIsAdUser(FAnalysis, Provider) and TemplateDesignedForAd(FT) then
  begin
    p.AdMustChange := FT.Account.MustChange;
    p.AdNeverExpires := FT.Account.NeverExpires;
    p.AdDisabled := FT.Account.Disabled;
    p.AdAccountOptions := True;
  end;
  for i := 0 to High(FState) do
  begin
    if i = ri then Continue;
    if IsAdPassword(i) then
    begin
      if FState[i].Text <> '' then p.AdPassword := FState[i].Text;
      Continue;
    end;
    if IsComputedSecret(i) and (FState[i].Text = '') then Continue;
    if IsSecret(i) then
    begin
      if FState[i].Secret = '' then Continue;
      n := Length(p.SecretAttrs);
      SetLength(p.SecretAttrs, n + 1);
      SetLength(p.Secrets, n + 1);
      p.SecretAttrs[n] := FT.Fields[i].Attr;
      p.Secrets[n] := Copy(FState[i].Secret, 1, MaxInt);
      Continue;
    end;
    if FState[i].Text = '' then Continue;
    n := Length(p.Attrs);
    SetLength(p.Attrs, n + 1);
    SetLength(p.Texts, n + 1);
    p.Attrs[n] := FT.Fields[i].Attr;
    p.Texts[n] := FState[i].Text;
  end;
  // Tout s'eteint pendant l'envoi: un double clic ferait des jumeaux, un lot glisse la un orphelin.
  FCreate.Enabled := False;
  FBatchBtn.Enabled := False;
  FGroupBar.Enabled := False;
  FSubmitting := True;
  try
    created := ShowCreateWizardPrefilled(Self, FCtx, FProfileUuid, FParentDn, p, True, outcome);
  finally
    FSubmitting := False;
    FGroupBar.Enabled := True;
    FBatchBtn.Enabled := True;
    FCreate.Enabled := True;
    for i := 0 to High(p.Secrets) do
      WipeString(p.Secrets[i]);
    WipeString(p.AdPassword);
  end;
  // Issue inconnue: le compte existe peut-etre, avec ce mot de passe. Le taire serait pire.
  if (created = '') and (outcome = sotUnknown) then ShowDrawn(FPlannedDn, rsGpToVerify);
  if created = '' then Exit;
  FCreatedDn := created;
  ShowDrawn(created, '');
  ModalResult := mrOk;
end;

// Le mot de passe tire n'existe plus nulle part apres ce dialogue: ni ici, ni dans le modele.
procedure TTemplateForm.ShowDrawn(const ADn, AStatus: string);
var
  list: TGeneratedPasswords;
  i: Integer;
  account: string;
begin
  list := nil;
  account := ValueOf('sAMAccountName');
  if account = '' then account := ValueOf('uid');
  if account = '' then account := ValueOf(FT.RdnAttr);
  for i := 0 to High(FState) do
    if FState[i].Drawn and (FState[i].Text <> '') then
    begin
      SetLength(list, Length(list) + 1);
      list[High(list)].Dn := ADn;
      list[High(list)].Account := account;
      list[High(list)].Password := FState[i].Text;
      list[High(list)].Status := AStatus;
      // Issue inconnue: on garde le tirage, un nouvel essai repart avec le meme.
      if AStatus = '' then
      begin
        RtWipeSecret(FState[i].Text);
        FState[i].Drawn := False;
        FState[i].DrawnHandedOver := False;
      end
      else
        FState[i].DrawnHandedOver := True;
    end;
  ShowGeneratedPasswords(Self, list);
end;

procedure TTemplateForm.BatchClick(Sender: TObject);
var
  t: TEntryTemplate;
  created: string;
begin
  if FSubmitting then Exit;
  t := CloneTemplate(FT);
  t.Groups := FGroups.Dns;
  created := CreateBatchFromTemplate(Self, FCtx, FProfileUuid, FParentDn, t);
  if created = '' then Exit;
  FCreatedDn := created;
  ModalResult := mrOk;
end;

procedure TTemplateForm.GroupsChanged(Sender: TObject);
begin
  if FGroupBar = nil then Exit;
  FGroupBar.OnLayoutChanged := nil;
  try
    FillGroupChips(FGroupBar, FGroups, True, rsTfAddGroup);
  finally
    FGroupBar.OnLayoutChanged := @GroupLayout;
  end;
  GroupLayout(nil);
  UpdateStatus;
end;

procedure TTemplateForm.GroupLayout(Sender: TObject);
var
  h: Integer;
begin
  if (FGroupBar = nil) or (FGroupRow = nil) then Exit;
  h := Max(30, FGroupBar.PreferredHeight(Max(100, FGroupBar.ClientWidth)) + 6);
  if FGroupRow.Height <> h then FGroupRow.Height := h;
end;

procedure TTemplateForm.GroupClose(Sender: TObject; AIndex: Integer);
begin
  if FSubmitting then Exit;
  FGroups.Remove(AIndex);
end;

procedure TTemplateForm.GroupAction(Sender: TObject; AIndex: Integer);
var
  c: TDirectoryConnection;
  dn: string;
begin
  if FSubmitting then Exit;
  c := Conn;
  if (c = nil) or not c.IsReady then Exit;
  dn := '';
  if not PickDirectoryEntry(Self, FCtx, FProfileUuid, rsTfTitle, rsTfGroupPrompt,
    NextIdBaseFor(c, FParentDn), '', dn) then Exit;
  if FGroups.Add(dn) then FGroups.Pump;
end;

procedure TTemplateForm.SetValue(const AAttr, AText: string);
var
  i: Integer;
  row: TTfRow;
begin
  i := FieldIndex(FT, AAttr);
  if i < 0 then Exit;
  row := RowOfField(i);
  if (row <> nil) and (row.FEdit <> nil) then row.FEdit.Text := AText;
end;

procedure TTemplateForm.Submit;
begin
  CreateClick(nil);
end;

function TTemplateForm.ValueOf(const AAttr: string): string;
var
  i: Integer;
begin
  Result := '';
  i := FieldIndex(FT, AAttr);
  if i >= 0 then Result := FState[i].Text;
end;

function TTemplateForm.DnText: string;
begin
  Result := FDnLabel.Caption;
end;

function TTemplateForm.StatusText: string;
begin
  Result := FStatusLabel.Caption;
end;

end.
