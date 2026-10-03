// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdifTab;

{$mode objfpc}{$H+}

// Editeur LDIF et import en deux temps: analyse et plan ordonne, puis execution volontaire vers
// un profil identifie. Un lot n'est pas atomique, chaque operation a son etat (reussie, echouee,
// non tentee, inconnue).

interface

uses
  Classes, SysUtils, Contnrs, Controls, ComCtrls, ExtCtrls, StdCtrls, Forms, Graphics, Dialogs,
  SynEdit, SynEditTypes, SynGutterBase, SynGutter, SynEditMiscClasses, uAppContext, uRtCombo,
  uRtList, uConnections, uUiInbox, uDirectoryWorker, uLdif, uChangeSet, uLdifHighlighter, uRtCheck,
  uLdifTargetCheck, uLdifAdvice, uIcons, uTaskTracker;

resourcestring
  rsLdifTitle = 'LDIF';
  rsLdifOpen = 'Open...';
  rsLdifSave = 'Save as...';
  rsLdifValidate = 'Analyze';
  rsLdifImport = 'Import...';
  rsLdifStop = 'Stop';
  rsLdifTarget = 'Target';
  rsLdifNoTarget = 'None (syntax check only)';
  rsLdifOptions = 'Options:';
  rsLdifContinue = 'Continue after an error';
  rsLdifAllowFiles = 'Allow local file references (:<) under...';
  rsLdifTabProblems = 'Problems (%d)';
  rsLdifTabOperations = 'Operations (%d)';
  rsLdifColSeverity = 'Kind';
  rsLdifColProblem = 'Problem';
  rsLdifPlanOp = 'Operation';
  rsLdifPlanLine = 'Line';
  rsLdifPlanDn = 'DN';
  rsLdifPlanState = 'State';
  rsLdifPlanDetail = 'Details';
  rsLdifReady = 'ready';
  rsLdifCheck = 'to check';
  rsLdifBlocked = 'blocked';
  rsLdifPending = 'queued';
  rsLdifDone = 'done';
  rsLdifFailed = 'failed';
  rsLdifNotAttempted = 'not attempted';
  rsLdifUnknown = 'UNKNOWN RESULT';
  rsLdifHowToTitle = 'Check the file before importing it';
  rsLdifHowTo = 'Analyze reads the file and explains any problem, without writing anything. With a ' +
    'target, it also checks the attributes against the schema of that directory. Import then sends ' +
    'the operations to the target one by one, after a preview.';
  rsLdifVerdictOk = 'Analysis complete: no problem found.';
  rsLdifVerdictSyntaxOk = 'Analysis complete: the LDIF syntax is correct.';
  rsLdifContentNotChecked = 'The file is well formed: %s. Its content (object classes, required ' +
    'attributes, value types) was not checked: choose a target to check it against the schema of ' +
    'that directory.';
  rsLdifVerdictEmpty = 'Analysis complete: the file contains no operation.';
  rsLdifVerdictProblems = 'Analysis complete: %s found.';
  rsLdifReadyTarget = 'Ready to import into %s: %s.';
  rsLdifReadyNoTarget = 'The file is valid: %s.';
  rsLdifNotes = ' %d note(s) in the Problems tab.';
  rsLdifErrorsBlock = 'Errors must be corrected before importing. Select a problem in the list to see ' +
    'why it is a problem and how to fix it.';
  rsLdifWarningsOnly = 'Warnings do not block the import, but the server will probably refuse the ' +
    'operations concerned. Select a problem in the list to see why and how to fix it.';
  rsLdifNoSchema = 'The schema of %s is not loaded: the attributes were not checked.';
  rsLdifStale = 'The text or the target changed since this analysis: analyze again.';
  rsLdifFixAll = 'Remove all attributes written by the server (%d lines)';
  rsLdifFixAllOne = 'Remove the attribute written by the server (1 line)';
  rsLdifShowLine = 'Show in the editor';
  rsLdifWhy = 'Why';
  rsLdifHowToFix = 'How to fix';
  rsLdifExample = 'Correct example';
  rsLdifLineOf = 'Line %d';
  rsLdifWholeFile = 'Whole file';
  rsLdifChooseProblem = 'Select a problem in the list to see the explanation.';
  rsLdifSummary = 'Import finished: %d done, %d failed, %d not attempted, %d unknown.';
  rsLdifImportTitle = 'Import';
  rsLdifProgress = 'Importing: %d of %d...';
  rsLdifNoConnection = 'Choose a connected target directory first.';
  rsLdifBusy = 'An import is running: the plan cannot be analyzed again until it finishes.';
  rsLdifAnalyzeNote = 'Offline analysis does not guarantee success: access controls and server policies apply at import time.';
  rsLdifOpDetailManaged = 'attributes written by the server';
  rsLdifOpDetailUnknown = 'attributes unknown to the target';
  rsLdifOpDetailCritical = 'critical control not supported';
  rsLdifOpDetailSchema = 'refused by the schema of the target';
  rsLdifOpDetailSchemaMaybe = 'may be refused by the schema of the target';

type
  TPlanState = (psReady, psCheck, psBlocked, psPending, psDone, psFailed, psNotAttempted, psUnknown);

  // Barres de defilement natives sombres a chaque creation du handle: le theme de fenetre se perd
  // avec lui, il faut le reposer a chaque fois.
  TLdifSynEdit = class(TSynEdit)
  protected
    procedure CreateWnd; override;
  end;

  // Meme punition pour la zone d'explication defilante.
  TThemedScrollBox = class(TScrollBox)
  protected
    procedure CreateWnd; override;
  end;

  TLdifTab = class(TTabSheet)
  private
    FCtx: TAppContext;
    FEditor: TLdifSynEdit;
    FHighlighter: TSynLdifHighlighter;
    FTarget: TRtComboBox;
    FAnalyzeBtn, FImportBtn, FStopBtn: TButton;
    FContinue: TRtCheckBox;
    FAllowFiles: TRtCheckBox;
    FAllowedRoot: string;
    FVerdictIcon: TRtIcon;
    FVerdict: TLabel;
    FStatus: TLabel;
    FFixAllBtn: TButton;
    FPages: TPageControl;
    FProblemList: TRtListGrid;
    FProbTitle, FProbWhyHead, FProbWhy, FProbFixHead, FProbFix, FProbExampleHead: TLabel;
    FProbScroll: TThemedScrollBox;
    FProbContent: TPanel;
    FProbExampleBox: TPanel;
    FProbExample: TLabel;
    FShowLineBtn, FFixBtn: TButton;
    FPlan: TRtListGrid;
    FDoc: TLdifDocument;
    FStates: array of TPlanState;
    FOpDetails: array of string;
    FProblems: TLdifProblemArray;
    FLineMarks: array of TLdifProblemSeverity;
    FLineMarked: array of Boolean;
    FStale: Boolean;
    FStatusBase: string;
    FStatusColor: TColor;
    FNextIndex: Integer;
    FRunning: Boolean;
    FStopRequested: Boolean;
    FRunProfile: string;
    FRunSessionId: string;
    FRunGeneration: Int64;
    FTasks: TDirectoryTasks;
    FTargetUuids: TStringList;
    procedure BuildUi;
    procedure BuildProblemsPage(AParent: TWinControl);
    procedure SetRunningLook(ARunning: Boolean);
    procedure UpdateActions;
    procedure OpenClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure AnalyzeClick(Sender: TObject);
    procedure ImportClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure FixAllClick(Sender: TObject);
    procedure FixClick(Sender: TObject);
    procedure ShowLineClick(Sender: TObject);
    procedure AllowFilesClick(Sender: TObject);
    procedure TargetDropDown(Sender: TObject);
    procedure TargetChange(Sender: TObject);
    procedure EditorChange(Sender: TObject);
    procedure EditorLineMarkup(Sender: TObject; Line: Integer; var Special: Boolean;
      Markup: TSynSelectedColor);
    procedure ProblemSelected(Sender: TObject; AIndex: Integer);
    procedure ProblemActivated(Sender: TObject; AIndex: Integer);
    procedure RowActivated(Sender: TObject; AIndex: Integer);
    function TargetUuid: string;
    function Analyze: Boolean;
    procedure AddProblem(const AProblem: TLdifProblem);
    function CheckTarget(out ANote: string): Integer;
    procedure SetVerdict(const AIconId: string; AIconColor: TColor; const AVerdict, AText: string;
      AColor: TColor);
    procedure MarkStale;
    procedure ClearResults;
    procedure RefreshPlan;
    procedure RefreshProblems;
    procedure ShowProblem(AIndex: Integer);
    procedure RestackProblem;
    procedure GoToLine(ALine: Integer);
    procedure ApplyFix(const ALines: array of Integer);
    function FixAllLines: TLineArray;
    function OperationsText: string;
    function ProblemCell(Sender: TObject; AIndex, ACol: Integer): string;
    function ProblemCellIcon(Sender: TObject; AIndex, ACol: Integer; out AColor: TColor): string;
    function PlanCell(Sender: TObject; AIndex, ACol: Integer): string;
    function PlanCellIcon(Sender: TObject; AIndex, ACol: Integer; out AColor: TColor): string;
    procedure RunNext;
    procedure Finish;
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext);
    destructor Destroy; override;
    procedure ApplyTheme;
    procedure SetText(const AText: string);
    function AnalyzeNow: Boolean;
    function VerdictText: string;
    function StatusText: string;
    function ProblemCount: Integer;
    function ProblemTitle(AIndex: Integer): string;
    function ProblemSeverity(AIndex: Integer): TLdifProblemSeverity;
    function ProblemPanelText: string;
    function ProblemSectionsInOrder: Boolean;
    procedure SelectProblem(AIndex: Integer);
    function FixSelectedEnabled: Boolean;
    function FixAllEnabled: Boolean;
    procedure FixSelected;
    procedure FixAll;
    function LineMarked(ALine: Integer): Boolean;
    function PlanStateText(AIndex: Integer): string;
    function PlanDetailText(AIndex: Integer): string;
    function PlanRowCount: Integer;
    function IssueCount: Integer;
    function Editor: TSynEdit;
    function SelectTarget(const AUuid: string): Boolean;
    function ImportEnabled: Boolean;
    function StopEnabled: Boolean;
    function ActivePageIndex: Integer;
    procedure ActivateRow(AIndex: Integer);
  end;

implementation

uses
  uTheme, uUiKit, uChangePreview, uLdapErrors, uSafeSave, uRtMessage, uServerKind,
  uConnectionProfile, uTaskDialog;

const
  COL_NUM = 0;
  COL_LINE = 1;
  COL_OP = 2;
  COL_DN = 3;
  COL_STATE = 4;
  COL_DETAIL = 5;
  PCOL_KIND = 0;
  PCOL_LINE = 1;
  PCOL_TITLE = 2;
  PAGE_PROBLEMS = 0;
  PAGE_OPERATIONS = 1;
  VERDICT_ICON = 24;

procedure TLdifSynEdit.CreateWnd;
begin
  inherited CreateWnd;
  ApplyNativeDarkMode(Self);
end;

procedure TThemedScrollBox.CreateWnd;
begin
  inherited CreateWnd;
  ApplyNativeDarkMode(Self);
end;

function SeverityColor(ASeverity: TLdifProblemSeverity): TColor;
begin
  case ASeverity of
    lpsError: Result := ShellStateColor(usError);
    lpsWarning: Result := ShellStateColor(usWarning);
  else
    Result := clAccent;
  end;
end;

function SeverityIcon(ASeverity: TLdifProblemSeverity): string;
begin
  case ASeverity of
    lpsError: Result := 'circle-x';
    lpsWarning: Result := 'alert-triangle';
  else
    Result := 'info-circle';
  end;
end;

constructor TLdifTab.CreateFor(AOwner: TComponent; ACtx: TAppContext);
begin
  inherited Create(AOwner);
  FCtx := ACtx;
  FTargetUuids := TStringList.Create;
  Caption := rsLdifTitle;
  BuildUi;
  TargetDropDown(nil);
  FTarget.ItemIndex := 0;
  FTasks := TDirectoryTasks.Create(FCtx.Connections, '', Self);
  FTasks.OnMessage := @TaskMessage;
  FTasks.UnknownDetail := 'LDIF import: unknown outcome';
  ClearResults;
  ApplyTheme;
end;

destructor TLdifTab.Destroy;
begin
  FreeAndNil(FTasks);
  FDoc.Free;
  FTargetUuids.Free;
  inherited Destroy;
end;

procedure TLdifTab.SetRunningLook(ARunning: Boolean);
begin
  FEditor.ReadOnly := ARunning;
  FTarget.Enabled := not ARunning;
  FAllowFiles.Enabled := not ARunning;
  UpdateActions;
end;

procedure TLdifTab.UpdateActions;
begin
  FAnalyzeBtn.Enabled := not FRunning;
  FImportBtn.Enabled := (not FRunning) and (TargetUuid <> '');
  FStopBtn.Enabled := FRunning;
  FFixAllBtn.Enabled := not FRunning;
  FFixBtn.Enabled := not FRunning;
end;

procedure TLdifTab.BuildUi;
var
  bar, opts, bottom, head, txt, body: TPanel;
  split: TSplitter;
  lbl: TLabel;
begin
  bar := MakePanel(Self, alTop, 36);
  MakeButton(bar, rsLdifOpen, @OpenClick);
  MakeButton(bar, rsLdifSave, @SaveClick);
  MakePanel(bar, alLeft, 18);
  lbl := MakeLabel(bar, rsLdifTarget, alLeft);
  lbl.Layout := tlCenter;
  FTarget := TRtComboBox.Create(bar);
  FTarget.Parent := bar;
  FTarget.Align := alLeft;
  FTarget.Style := csDropDownList;
  FTarget.Width := 300;
  FTarget.BorderSpacing.Around := 4;
  FTarget.OnDropDown := @TargetDropDown;
  FTarget.OnChange := @TargetChange;
  FAnalyzeBtn := MakeButton(bar, rsLdifValidate, @AnalyzeClick);
  FImportBtn := MakeButton(bar, rsLdifImport, @ImportClick);
  FStopBtn := MakeButton(bar, rsLdifStop, @StopClick);
  opts := MakePanel(Self, alTop, 30);
  StackTop(opts);
  lbl := MakeLabel(opts, rsLdifOptions, alLeft);
  lbl.Layout := tlCenter;
  FContinue := MakeCheck(opts, rsLdifContinue, alLeft);
  FAllowFiles := MakeCheck(opts, rsLdifAllowFiles, alLeft);
  FAllowFiles.OnClick := @AllowFilesClick;

  bottom := MakePanel(Self, alBottom, 330);
  head := MakePanel(bottom, alTop, 0);
  head.AutoSize := True;
  head.BorderSpacing.Top := 6;
  head.BorderSpacing.Bottom := 6;
  FVerdictIcon := TRtIcon.Create(head);
  FVerdictIcon.Parent := head;
  FVerdictIcon.Align := alLeft;
  FVerdictIcon.TopAligned := True;
  FVerdictIcon.BorderSpacing.Left := 8;
  FVerdictIcon.BorderSpacing.Right := 10;
  FVerdictIcon.SetIcon('info-circle', VERDICT_ICON, clAccent);
  FFixAllBtn := MakeButton(head, '', @FixAllClick, alRight);
  FFixAllBtn.Visible := False;
  txt := MakePanel(head, alClient, 0);
  txt.AutoSize := True;
  FVerdict := MakeLabel(txt, '', alTop);
  FVerdict.Font.Style := [fsBold];
  FVerdict.WordWrap := True;
  FVerdict.ShowAccelChar := False;
  FStatus := MakeLabel(txt, '', alTop);
  FStatus.WordWrap := True;
  FStatus.ShowAccelChar := False;
  FPages := MakePages(bottom);
  BuildProblemsPage(AddPageBody(FPages, Format(rsLdifTabProblems, [0])));
  body := AddPageBody(FPages, Format(rsLdifTabOperations, [0]));
  FPlan := TRtListGrid.Create(body);
  FPlan.Parent := body;
  FPlan.Align := alClient;
  FPlan.FillWidth := True;
  FPlan.AddColumn('#', 40);
  FPlan.AddColumn(rsLdifPlanLine, 60);
  FPlan.AddColumn(rsLdifPlanOp, 100);
  FPlan.AddColumn(rsLdifPlanDn, 360);
  FPlan.AddColumn(rsLdifPlanState, 140);
  FPlan.AddColumn(rsLdifPlanDetail, 360);
  FPlan.OnGetCell := @PlanCell;
  FPlan.OnGetCellIcon := @PlanCellIcon;
  FPlan.OnActivateRow := @RowActivated;
  split := TSplitter.Create(Self);
  split.Parent := Self;
  split.Align := alBottom;
  split.Top := bottom.Top - 1;

  FEditor := TLdifSynEdit.Create(Self);
  FEditor.Parent := Self;
  FEditor.Align := alClient;
  FHighlighter := TSynLdifHighlighter.Create(Self);
  FEditor.Highlighter := FHighlighter;
  FEditor.Options := FEditor.Options + [eoTabsToSpaces] - [eoSmartTabs];
  FEditor.Gutter.Visible := True;
  // Le cadre natif reste blanc sur fond sombre: pas de cadre du tout.
  FEditor.BorderStyle := bsNone;
  FEditor.OnChange := @EditorChange;
  FEditor.OnSpecialLineMarkup := @EditorLineMarkup;
end;

procedure TLdifTab.BuildProblemsPage(AParent: TWinControl);
var
  right, buttons: TPanel;
  split: TSplitter;
begin
  FProblemList := TRtListGrid.Create(AParent);
  FProblemList.Parent := AParent;
  FProblemList.Align := alLeft;
  FProblemList.Width := 560;
  FProblemList.FillWidth := True;
  FProblemList.AddColumn(rsLdifColSeverity, 100);
  FProblemList.AddColumn(rsLdifPlanLine, 60);
  FProblemList.AddColumn(rsLdifColProblem, 400);
  FProblemList.OnGetCell := @ProblemCell;
  FProblemList.OnGetCellIcon := @ProblemCellIcon;
  FProblemList.OnSelectRow := @ProblemSelected;
  FProblemList.OnActivateRow := @ProblemActivated;
  split := TSplitter.Create(AParent);
  split.Parent := AParent;
  split.Align := alLeft;
  split.Left := FProblemList.Left + FProblemList.Width + 1;
  right := MakePanel(AParent, alClient, 0);
  right.BorderSpacing.Left := 10;
  right.BorderSpacing.Right := 8;
  buttons := MakePanel(right, alBottom, 36);
  FShowLineBtn := MakeButton(buttons, rsLdifShowLine, @ShowLineClick);
  FFixBtn := MakeButton(buttons, '', @FixClick);
  FProbScroll := TThemedScrollBox.Create(right);
  FProbScroll.Parent := right;
  FProbScroll.Align := alClient;
  FProbScroll.BorderStyle := bsNone;
  FProbScroll.HorzScrollBar.Visible := False;
  FProbScroll.VertScrollBar.Tracking := True;
  FProbScroll.AutoScroll := True;
  FProbContent := MakePanel(FProbScroll, alTop, 0);
  FProbContent.AutoSize := True;
  FProbContent.BorderSpacing.Right := 6;
  FProbTitle := MakeLabel(FProbContent, '', alTop);
  FProbTitle.Font.Style := [fsBold];
  FProbTitle.WordWrap := True;
  FProbTitle.ShowAccelChar := False;
  FProbWhyHead := MakeLabel(FProbContent, rsLdifWhy, alTop);
  FProbWhyHead.Font.Style := [fsBold];
  FProbWhyHead.BorderSpacing.Top := 8;
  FProbWhy := MakeLabel(FProbContent, '', alTop);
  FProbWhy.WordWrap := True;
  FProbWhy.ShowAccelChar := False;
  FProbFixHead := MakeLabel(FProbContent, rsLdifHowToFix, alTop);
  FProbFixHead.Font.Style := [fsBold];
  FProbFixHead.BorderSpacing.Top := 8;
  FProbFix := MakeLabel(FProbContent, '', alTop);
  FProbFix.WordWrap := True;
  FProbFix.ShowAccelChar := False;
  FProbExampleHead := MakeLabel(FProbContent, rsLdifExample, alTop);
  FProbExampleHead.Font.Style := [fsBold];
  FProbExampleHead.BorderSpacing.Top := 8;
  FProbExampleBox := MakePanel(FProbContent, alTop, 0);
  FProbExampleBox.AutoSize := True;
  FProbExampleBox.ParentColor := False;
  FProbExampleBox.BorderSpacing.Top := 4;
  FProbExampleBox.BorderSpacing.Bottom := 6;
  FProbExample := MakeLabel(FProbExampleBox, '', alTop);
  FProbExample.WordWrap := True;
  FProbExample.ShowAccelChar := False;
  FProbExample.BorderSpacing.Around := 8;
end;

// Ordre des sections force: un controle alTop re-affiche va sinon se ranger en bas de la pile.
procedure TLdifTab.RestackProblem;
var
  ctrls: array[0..6] of TControl;
  i, y: Integer;
begin
  ctrls[0] := FProbTitle;
  ctrls[1] := FProbWhyHead;
  ctrls[2] := FProbWhy;
  ctrls[3] := FProbFixHead;
  ctrls[4] := FProbFix;
  ctrls[5] := FProbExampleHead;
  ctrls[6] := FProbExampleBox;
  FProbContent.DisableAlign;
  try
    y := 0;
    for i := 0 to High(ctrls) do
    begin
      ctrls[i].Top := y;
      Inc(y, ctrls[i].Height + 20);
    end;
  finally
    FProbContent.EnableAlign;
  end;
  FProbScroll.VertScrollBar.Position := 0;
end;

procedure TLdifTab.ApplyTheme;
var
  i: Integer;
  part: TSynGutterPartBase;
begin
  ThemeControlTree(Self);
  ArrangeByCreation(Self);
  FEditor.Color := clEditorBg;
  FEditor.Font.Color := clEditorFg;
  if RSEditorFontName <> '' then
    FEditor.Font.Name := RSEditorFontName;
  FEditor.Font.Size := RSEditorFontSize;
  // SynEdit impose fqNonAntialiased (SynDefaultFontQuality): les Monaspace embarquees sortent
  // crenelees comme en 1998. Lissage ClearType force.
  FEditor.Font.Quality := fqCleartype;
  FEditor.SelectedColor.Background := clSelectionBg;
  FEditor.SelectedColor.Foreground := clSelectionFg;
  FEditor.Gutter.Color := clGutterBg;
  // Chaque morceau de la gouttiere SynEdit a ses couleurs, claires par defaut (numeros sur
  // clBtnFace, separateur blanc): il faut les repeindre un par un.
  for i := 0 to FEditor.Gutter.Parts.Count - 1 do
  begin
    part := FEditor.Gutter.Parts.Part[i];
    part.MarkupInfo.Background := clGutterBg;
    if part is TSynGutterSeparator then
      part.MarkupInfo.Foreground := BlendColor(clEditorFg, clEditorBg, 15)
    else
      part.MarkupInfo.Foreground := clGutterFg;
  end;
  // Marge droite gris argent par defaut, quel que soit le theme: trait blanc sur fond sombre.
  FEditor.RightEdgeColor := BlendColor(clEditorFg, clEditorBg, 15);
  ApplyNativeDarkMode(FEditor);
  FPlan.RefreshMetrics;
  FProblemList.RefreshMetrics;
  FProbScroll.Color := clAppBg;
  ApplyNativeDarkMode(FProbScroll);
  FProbExampleBox.Color := BlendColor(clEditorFg, clEditorBg, 8);
  FProbExample.Font.Color := clEditorFg;
  if RSEditorFontName <> '' then FProbExample.Font.Name := RSEditorFontName;
  FProbExample.Font.Size := RSEditorFontSize;
  FEditor.LineHighlightColor.Background := clCurrentLine;
  FHighlighter.ApplyTheme;
  FEditor.Invalidate;
  FStatus.Font.Color := FStatusColor;
  UpdateActions;
end;

procedure TLdifTab.SetText(const AText: string);
begin
  FEditor.Text := AText;
end;

function TLdifTab.AnalyzeNow: Boolean;
begin
  Result := Analyze;
end;

function TLdifTab.VerdictText: string;
begin
  Result := FVerdict.Caption;
end;

function TLdifTab.StatusText: string;
begin
  Result := FVerdict.Caption + ' ' + FStatus.Caption;
end;

function TLdifTab.ProblemCount: Integer;
begin
  Result := Length(FProblems);
end;

function TLdifTab.ProblemTitle(AIndex: Integer): string;
begin
  Result := FProblems[AIndex].Title;
end;

function TLdifTab.ProblemSeverity(AIndex: Integer): TLdifProblemSeverity;
begin
  Result := FProblems[AIndex].Severity;
end;

function TLdifTab.ProblemPanelText: string;
begin
  Result := FProbTitle.Caption + ' | ' + FProbWhy.Caption + ' | ' + FProbFix.Caption + ' | ' +
    FProbExampleHead.Caption + ' | ' + FProbExample.Caption;
end;

function TLdifTab.ProblemSectionsInOrder: Boolean;
var
  ctrls: array[0..6] of TControl;
  i, last: Integer;
begin
  ctrls[0] := FProbTitle;
  ctrls[1] := FProbWhyHead;
  ctrls[2] := FProbWhy;
  ctrls[3] := FProbFixHead;
  ctrls[4] := FProbFix;
  ctrls[5] := FProbExampleHead;
  ctrls[6] := FProbExampleBox;
  last := -1;
  for i := 0 to High(ctrls) do
  begin
    if not ctrls[i].Visible then Continue;
    if ctrls[i].Top <= last then Exit(False);
    last := ctrls[i].Top;
  end;
  Result := True;
end;

procedure TLdifTab.SelectProblem(AIndex: Integer);
begin
  FProblemList.ItemIndex := AIndex;
  ShowProblem(AIndex);
end;

function TLdifTab.FixSelectedEnabled: Boolean;
begin
  Result := FFixBtn.Visible and FFixBtn.Enabled;
end;

function TLdifTab.FixAllEnabled: Boolean;
begin
  Result := FFixAllBtn.Visible and FFixAllBtn.Enabled;
end;

procedure TLdifTab.FixSelected;
begin
  FixClick(nil);
end;

procedure TLdifTab.FixAll;
begin
  FixAllClick(nil);
end;

function TLdifTab.LineMarked(ALine: Integer): Boolean;
begin
  Result := (ALine >= 1) and (ALine <= Length(FLineMarked)) and FLineMarked[ALine - 1];
end;

function TLdifTab.PlanStateText(AIndex: Integer): string;
begin
  Result := PlanCell(nil, AIndex, COL_STATE);
end;

function TLdifTab.PlanDetailText(AIndex: Integer): string;
begin
  Result := PlanCell(nil, AIndex, COL_DETAIL);
end;

function TLdifTab.PlanRowCount: Integer;
begin
  if FDoc = nil then Result := 0 else Result := FDoc.RecordCount;
end;

function TLdifTab.IssueCount: Integer;
begin
  Result := Length(FProblems);
end;

function TLdifTab.Editor: TSynEdit;
begin
  Result := FEditor;
end;

function TLdifTab.SelectTarget(const AUuid: string): Boolean;
begin
  TargetDropDown(nil);
  FTarget.ItemIndex := FTargetUuids.IndexOf(AUuid);
  Result := FTarget.ItemIndex >= 0;
  TargetChange(nil);
end;

function TLdifTab.ImportEnabled: Boolean;
begin
  Result := FImportBtn.Enabled;
end;

function TLdifTab.StopEnabled: Boolean;
begin
  Result := FStopBtn.Enabled;
end;

function TLdifTab.ActivePageIndex: Integer;
begin
  Result := FPages.ActivePageIndex;
end;

function TLdifTab.TargetUuid: string;
begin
  Result := '';
  if (FTarget.ItemIndex >= 0) and (FTarget.ItemIndex < FTargetUuids.Count) then
    Result := FTargetUuids[FTarget.ItemIndex];
end;

procedure TLdifTab.TargetDropDown(Sender: TObject);
var
  i: Integer;
  c: TDirectoryConnection;
  keep: string;
begin
  keep := FTarget.Text;
  FTarget.Items.Clear;
  FTargetUuids.Clear;
  FTarget.Items.Add(rsLdifNoTarget);
  FTargetUuids.Add('');
  for i := 0 to FCtx.Connections.Count - 1 do
  begin
    c := FCtx.Connections.Item(i);
    if c.IsReady then
    begin
      FTarget.Items.Add(c.Profile.Name + ' - ' + c.Profile.DisplayEndpoint);
      FTargetUuids.Add(c.Profile.Uuid);
    end;
  end;
  FTarget.ItemIndex := FTarget.Items.IndexOf(keep);
  if FTarget.ItemIndex < 0 then FTarget.ItemIndex := 0;
end;

procedure TLdifTab.TargetChange(Sender: TObject);
begin
  UpdateActions;
  MarkStale;
end;

procedure TLdifTab.EditorChange(Sender: TObject);
begin
  MarkStale;
end;

procedure TLdifTab.AllowFilesClick(Sender: TObject);
var
  dd: TSelectDirectoryDialog;
begin
  MarkStale;
  if not FAllowFiles.Checked then
  begin
    FAllowedRoot := '';
    FAllowFiles.Caption := rsLdifAllowFiles;
    Exit;
  end;
  dd := TSelectDirectoryDialog.Create(Self);
  try
    if dd.Execute then
    begin
      FAllowedRoot := dd.FileName;
      FAllowFiles.Caption := rsLdifAllowFiles + ' ' + FAllowedRoot;
    end
    else
      FAllowFiles.Checked := False;
  finally
    dd.Free;
  end;
end;

procedure TLdifTab.OpenClick(Sender: TObject);
var
  od: TOpenDialog;
  fs: THandleStream;
  s: RawByteString;
  notReg: Boolean;
begin
  if FRunning then Exit;
  od := TOpenDialog.Create(Self);
  try
    od.Filter := 'LDIF (*.ldif)|*.ldif|All files|*.*';
    if not od.Execute then Exit;
    // Fichier ordinaire seulement, ouvert sans blocage: un FIFO ou un peripherique ne gelera pas
    // l'interface.
    fs := OpenRegularFileRead(od.FileName, notReg);
    if fs = nil then Exit;
    try
      // Taille lue une fois, lecture bornee a cette taille.
      if not ReadWholeStream(fs, 256 * 1024 * 1024, s) then Exit;
    finally
      fs.Free;
    end;
    FEditor.Text := s;
    Caption := rsLdifTitle + ' - ' + ExtractFileName(od.FileName);
    ClearResults;
  finally
    od.Free;
  end;
end;

procedure TLdifTab.SaveClick(Sender: TObject);
var
  sd: TSaveDialog;
  src: TStringStream;
begin
  sd := TSaveDialog.Create(Self);
  try
    sd.Filter := 'LDIF (*.ldif)|*.ldif|All files|*.*';
    sd.DefaultExt := 'ldif';
    sd.Options := sd.Options + [ofOverwritePrompt];
    if sd.Execute then
    begin
      // Ecriture atomique (temporaire, flush, rename): une erreur en route ne tronque jamais le
      // fichier existant. Le LDIF d'hier vaut mieux qu'un demi-LDIF.
      src := TStringStream.Create(FEditor.Lines.Text);
      try
        try
          SavePrivateStream(sd.FileName, src);
        except
          on E: Exception do
            RtMessageDlg(rsLdifTitle, E.Message, mtError, [mbOK], 0);
        end;
      finally
        src.Free;
      end;
    end;
  finally
    sd.Free;
  end;
end;

procedure TLdifTab.SetVerdict(const AIconId: string; AIconColor: TColor; const AVerdict, AText: string;
  AColor: TColor);
begin
  FVerdictIcon.SetIcon(AIconId, VERDICT_ICON, AIconColor);
  FVerdict.Caption := AVerdict;
  FStatusBase := AText;
  FStatusColor := AColor;
  FStatus.Caption := AText;
  FStatus.Font.Color := AColor;
  FStale := False;
end;

procedure TLdifTab.MarkStale;
begin
  if FRunning or FStale or (FDoc = nil) then Exit;
  FStale := True;
  FStatus.Caption := rsLdifStale + ' ' + FStatusBase;
  FStatus.Font.Color := ShellStateColor(usWarning);
  FVerdictIcon.SetIcon('refresh', VERDICT_ICON, ShellStateColor(usWarning));
  FLineMarked := nil;
  FFixAllBtn.Visible := False;
  FFixBtn.Visible := False;
  FEditor.Invalidate;
end;

procedure TLdifTab.ClearResults;
begin
  FreeAndNil(FDoc);
  FStates := nil;
  FOpDetails := nil;
  FProblems := nil;
  FLineMarked := nil;
  FLineMarks := nil;
  RefreshPlan;
  RefreshProblems;
  ShowProblem(-1);
  SetVerdict('info-circle', clAccent, rsLdifHowToTitle, rsLdifHowTo, clAppFg);
  FFixAllBtn.Visible := False;
  FEditor.Invalidate;
end;

procedure TLdifTab.AddProblem(const AProblem: TLdifProblem);
begin
  SetLength(FProblems, Length(FProblems) + 1);
  FProblems[High(FProblems)] := AProblem;
end;

function TLdifTab.OperationsText: string;
var
  counts: array[TChangeKind] of Integer;
  k: TChangeKind;
  i: Integer;
  parts: string;
begin
  for k := Low(TChangeKind) to High(TChangeKind) do counts[k] := 0;
  for i := 0 to FDoc.RecordCount - 1 do Inc(counts[FDoc[i].Kind]);
  parts := '';
  for k := Low(TChangeKind) to High(TChangeKind) do
    if counts[k] > 0 then
    begin
      if parts <> '' then parts := parts + ', ';
      parts := parts + IntToStr(counts[k]) + ' ' + ChangeKindName(k);
    end;
  Result := Format('%d operation(s) (%s)', [FDoc.RecordCount, parts]);
end;

function CountText(AErrors, AWarnings: Integer): string;
begin
  Result := '';
  if AErrors = 1 then Result := '1 error'
  else if AErrors > 1 then Result := IntToStr(AErrors) + ' errors';
  if AWarnings > 0 then
  begin
    if Result <> '' then Result := Result + ' and ';
    if AWarnings = 1 then Result := Result + '1 warning'
    else Result := Result + IntToStr(AWarnings) + ' warnings';
  end;
end;

function TLdifTab.Analyze: Boolean;
var
  opts: TLdifParseOptions;
  i, j, errors, warnings, notes: Integer;
  c: TLdapChange;
  p: TLdifProblem;
  note, summary, targetName: string;
  fixLines: TLineArray;
begin
  FreeAndNil(FDoc);
  FProblems := nil;
  opts := DefaultLdifParseOptions;
  if FAllowFiles.Checked and (FAllowedRoot <> '') then
  begin
    opts.External.AllowLocalFiles := True;
    opts.External.AllowedRoots := [FAllowedRoot];
  end;
  FDoc := LdifParse(FEditor.Text, opts);
  SetLength(FStates, FDoc.RecordCount);
  SetLength(FOpDetails, FDoc.RecordCount);
  for i := 0 to FDoc.RecordCount - 1 do
  begin
    FStates[i] := psReady;
    FOpDetails[i] := '';
  end;
  for i := 0 to FDoc.IssueCount - 1 do
    AddProblem(ExplainParseIssue(FDoc.Issue(i)));
  // Controles jamais envoyes depuis un fichier LDIF: un fichier venu d'ailleurs ne choisit pas
  // a la place de l'operateur.
  for i := 0 to FDoc.RecordCount - 1 do
  begin
    c := FDoc[i];
    for j := 0 to High(c.Controls) do
      if c.Controls[j].Critical then
      begin
        AddProblem(CriticalControlProblem(c.SourceLine, i, c.Controls[j].Oid));
        FStates[i] := psBlocked;
        FOpDetails[i] := rsLdifOpDetailCritical;
      end
      else
        AddProblem(IgnoredControlProblem(c.SourceLine, i, c.Controls[j].Oid));
  end;
  CheckTarget(note);
  SortProblemsByLine(FProblems);
  errors := 0;
  warnings := 0;
  notes := 0;
  SetLength(FLineMarked, FEditor.Lines.Count + 1);
  SetLength(FLineMarks, FEditor.Lines.Count + 1);
  for i := 0 to High(FLineMarked) do FLineMarked[i] := False;
  for i := 0 to High(FProblems) do
  begin
    case FProblems[i].Severity of
      lpsError: Inc(errors);
      lpsWarning: Inc(warnings);
    else
      Inc(notes);
    end;
    if FProblems[i].Severity <> lpsNote then
    begin
      if (FProblems[i].Line >= 1) and (FProblems[i].Line <= Length(FLineMarked)) and
         (Length(FProblems[i].FixLines) = 0) then
      begin
        FLineMarked[FProblems[i].Line - 1] := True;
        FLineMarks[FProblems[i].Line - 1] := FProblems[i].Severity;
      end;
      for j := 0 to High(FProblems[i].FixLines) do
        if (FProblems[i].FixLines[j] >= 1) and (FProblems[i].FixLines[j] <= Length(FLineMarked)) then
        begin
          FLineMarked[FProblems[i].FixLines[j] - 1] := True;
          FLineMarks[FProblems[i].FixLines[j] - 1] := FProblems[i].Severity;
        end;
    end;
  end;
  RefreshPlan;
  RefreshProblems;
  Result := errors = 0;
  targetName := '';
  if TargetUuid <> '' then targetName := FTarget.Text;
  if (errors = 0) and (warnings = 0) then
  begin
    if FDoc.RecordCount = 0 then
      SetVerdict('info-circle', clAccent, rsLdifVerdictEmpty, '', clAppFg)
    else
    begin
      if notes > 0 then note := Trim(note + Format(rsLdifNotes, [notes]));
      if targetName <> '' then
      begin
        summary := Format(rsLdifReadyTarget, [targetName, OperationsText]);
        if note <> '' then summary := summary + ' ' + note;
        SetVerdict('circle-check', ShellStateColor(usOk), rsLdifVerdictOk, summary, clAppFg);
      end
      else
      begin
        summary := Format(rsLdifContentNotChecked, [OperationsText]);
        if note <> '' then summary := summary + ' ' + note;
        SetVerdict('circle-check', ShellStateColor(usOk), rsLdifVerdictSyntaxOk, summary, clAppFg);
      end;
    end;
    SelectPage(FPages, PAGE_OPERATIONS);
  end
  else
  begin
    if errors > 0 then
    begin
      summary := rsLdifErrorsBlock;
      if note <> '' then summary := summary + ' ' + note;
      SetVerdict('circle-x', ShellStateColor(usError),
        Format(rsLdifVerdictProblems, [CountText(errors, warnings)]), summary, clAppFg);
    end
    else
    begin
      summary := rsLdifWarningsOnly;
      if note <> '' then summary := summary + ' ' + note;
      SetVerdict('alert-triangle', ShellStateColor(usWarning),
        Format(rsLdifVerdictProblems, [CountText(errors, warnings)]), summary, clAppFg);
    end;
    SelectPage(FPages, PAGE_PROBLEMS);
  end;
  fixLines := FixAllLines;
  FFixAllBtn.Visible := Length(fixLines) > 0;
  if Length(fixLines) = 1 then
    FFixAllBtn.Caption := rsLdifFixAllOne
  else if FFixAllBtn.Visible then
    FFixAllBtn.Caption := Format(rsLdifFixAll, [Length(fixLines)]);
  if Length(FProblems) > 0 then
    SelectProblem(0)
  else
    ShowProblem(-1);
  FEditor.Invalidate;
end;

function TLdifTab.CheckTarget(out ANote: string): Integer;
var
  c: TDirectoryConnection;
  i, k: Integer;
  f: TTargetFinding;
  issues: TSchemaIssueArray;
  provider: TProviderKind;
  counted: Boolean;
begin
  Result := 0;
  ANote := '';
  c := nil;
  if TargetUuid <> '' then
    c := FCtx.Connections.Find(TargetUuid);
  if c = nil then Exit;
  if c.Schema = nil then
  begin
    ANote := Format(rsLdifNoSchema, [c.Profile.Name]);
    Exit;
  end;
  for i := 0 to FDoc.RecordCount - 1 do
  begin
    f := CheckChangeAgainstSchema(FDoc[i], c.Schema);
    if FindingIsEmpty(f) then Continue;
    if Length(f.ServerManaged) > 0 then
    begin
      AddProblem(ServerManagedProblem(FEditor.Lines, FDoc[i].SourceLine, i, f.ServerManaged));
      FOpDetails[i] := rsLdifOpDetailManaged;
    end;
    if Length(f.Unknown) > 0 then
    begin
      AddProblem(UnknownAttributesProblem(FDoc[i].SourceLine, i, f.Unknown, c.Profile.Name));
      if FOpDetails[i] <> '' then FOpDetails[i] := FOpDetails[i] + '; ';
      FOpDetails[i] := FOpDetails[i] + rsLdifOpDetailUnknown;
    end;
    if FStates[i] = psReady then FStates[i] := psCheck;
    Inc(Result);
  end;
  provider := EffectiveServerKind(c.Profile, c.RootDse);
  for i := 0 to FDoc.RecordCount - 1 do
  begin
    issues := CheckContentAgainstSchema(FDoc[i], c.Schema, provider);
    counted := FStates[i] = psCheck;
    for k := 0 to High(issues) do
    begin
      AddProblem(SchemaIssueProblem(FEditor.Lines, FDoc[i].SourceLine, i, issues[k], c.Profile.Name));
      if issues[k].Certain then
      begin
        FStates[i] := psBlocked;
        if Pos(rsLdifOpDetailSchema, FOpDetails[i]) = 0 then
        begin
          if FOpDetails[i] <> '' then FOpDetails[i] := FOpDetails[i] + '; ';
          FOpDetails[i] := FOpDetails[i] + rsLdifOpDetailSchema;
        end;
      end
      else
      begin
        if FStates[i] = psReady then FStates[i] := psCheck;
        if Pos(rsLdifOpDetailSchemaMaybe, FOpDetails[i]) = 0 then
        begin
          if FOpDetails[i] <> '' then FOpDetails[i] := FOpDetails[i] + '; ';
          FOpDetails[i] := FOpDetails[i] + rsLdifOpDetailSchemaMaybe;
        end;
      end;
    end;
    if (Length(issues) > 0) and not counted then Inc(Result);
  end;
end;

procedure TLdifTab.RefreshPlan;
var
  n: Integer;
begin
  if FDoc = nil then n := 0 else n := FDoc.RecordCount;
  FPlan.Count := n;
  FPages.Pages[PAGE_OPERATIONS].Caption := Format(rsLdifTabOperations, [n]);
  FPlan.Invalidate;
  if FPages.Tag <> 0 then TControl(FPages.Tag).Invalidate;
end;

procedure TLdifTab.RefreshProblems;
begin
  FProblemList.Count := Length(FProblems);
  FPages.Pages[PAGE_PROBLEMS].Caption := Format(rsLdifTabProblems, [Length(FProblems)]);
  FProblemList.Invalidate;
  if FPages.Tag <> 0 then TControl(FPages.Tag).Invalidate;
end;

procedure TLdifTab.ShowProblem(AIndex: Integer);
var
  p: TLdifProblem;
  where: string;
begin
  if (AIndex < 0) or (AIndex > High(FProblems)) then
  begin
    FProbTitle.Caption := rsLdifChooseProblem;
    FProbTitle.Font.Color := clAppFg;
    FProbWhyHead.Visible := False;
    FProbWhy.Caption := '';
    FProbFixHead.Visible := False;
    FProbFix.Caption := '';
    FProbExampleHead.Visible := False;
    FProbExampleBox.Visible := False;
    FShowLineBtn.Visible := False;
    FFixBtn.Visible := False;
    RestackProblem;
    Exit;
  end;
  p := FProblems[AIndex];
  if p.Line > 0 then where := Format(rsLdifLineOf, [p.Line]) else where := rsLdifWholeFile;
  FProbTitle.Caption := where + ' - ' + p.Title;
  FProbTitle.Font.Color := SeverityColor(p.Severity);
  FProbWhyHead.Visible := True;
  FProbWhy.Caption := p.Explanation;
  FProbFixHead.Visible := True;
  FProbFix.Caption := p.HowToFix;
  FProbExampleHead.Visible := p.Example <> '';
  if p.ExampleTitle <> '' then FProbExampleHead.Caption := p.ExampleTitle
  else FProbExampleHead.Caption := rsLdifExample;
  FProbExampleBox.Visible := p.Example <> '';
  FProbExample.Caption := StringReplace(p.Example, #10, LineEnding, [rfReplaceAll]);
  RestackProblem;
  FShowLineBtn.Visible := p.Line > 0;
  FFixBtn.Visible := (p.FixLabel <> '') and not FStale;
  FFixBtn.Caption := p.FixLabel;
  UpdateActions;
end;

procedure TLdifTab.ProblemSelected(Sender: TObject; AIndex: Integer);
begin
  ShowProblem(AIndex);
end;

procedure TLdifTab.ProblemActivated(Sender: TObject; AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex <= High(FProblems)) then GoToLine(FProblems[AIndex].Line);
end;

procedure TLdifTab.ShowLineClick(Sender: TObject);
begin
  ProblemActivated(nil, FProblemList.ItemIndex);
end;

procedure TLdifTab.GoToLine(ALine: Integer);
begin
  if ALine < 1 then Exit;
  FEditor.CaretXY := Point(1, ALine);
  if ALine > 3 then FEditor.TopLine := ALine - 3 else FEditor.TopLine := 1;
  if FEditor.CanFocus then FEditor.SetFocus;
end;

procedure TLdifTab.RowActivated(Sender: TObject; AIndex: Integer);
begin
  ActivateRow(AIndex);
end;

procedure TLdifTab.ActivateRow(AIndex: Integer);
begin
  if (FDoc = nil) or (AIndex < 0) or (AIndex >= FDoc.RecordCount) then Exit;
  GoToLine(FDoc[AIndex].SourceLine);
end;

procedure TLdifTab.ApplyFix(const ALines: array of Integer);
begin
  if FRunning or (Length(ALines) = 0) then Exit;
  FEditor.BeginUndoBlock;
  try
    FEditor.SelectAll;
    FEditor.SelText := RemoveLines(FEditor.Text, ALines);
  finally
    FEditor.EndUndoBlock;
  end;
  Analyze;
end;

function TLdifTab.FixAllLines: TLineArray;
var
  i, j, k: Integer;
  seen: Boolean;
begin
  Result := nil;
  for i := 0 to High(FProblems) do
    for j := 0 to High(FProblems[i].FixLines) do
    begin
      seen := False;
      for k := 0 to High(Result) do
        if Result[k] = FProblems[i].FixLines[j] then
        begin
          seen := True;
          Break;
        end;
      if not seen then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := FProblems[i].FixLines[j];
      end;
    end;
end;

procedure TLdifTab.FixClick(Sender: TObject);
var
  i: Integer;
begin
  i := FProblemList.ItemIndex;
  if (i < 0) or (i > High(FProblems)) or FStale then Exit;
  ApplyFix(FProblems[i].FixLines);
end;

procedure TLdifTab.FixAllClick(Sender: TObject);
begin
  if FStale then Exit;
  ApplyFix(FixAllLines);
end;

procedure TLdifTab.EditorLineMarkup(Sender: TObject; Line: Integer; var Special: Boolean;
  Markup: TSynSelectedColor);
begin
  if (Line < 1) or (Line > Length(FLineMarked)) or not FLineMarked[Line - 1] then Exit;
  Special := True;
  Markup.Background := BlendColor(SeverityColor(FLineMarks[Line - 1]), clEditorBg, 22);
  Markup.Foreground := clNone;
end;

function TLdifTab.ProblemCell(Sender: TObject; AIndex, ACol: Integer): string;
begin
  Result := '';
  if (AIndex < 0) or (AIndex > High(FProblems)) then Exit;
  case ACol of
    PCOL_KIND: Result := SeverityName(FProblems[AIndex].Severity);
    PCOL_LINE: if FProblems[AIndex].Line > 0 then Result := IntToStr(FProblems[AIndex].Line);
    PCOL_TITLE: Result := FProblems[AIndex].Title;
  end;
end;

function TLdifTab.ProblemCellIcon(Sender: TObject; AIndex, ACol: Integer; out AColor: TColor): string;
begin
  Result := '';
  AColor := clAppFg;
  if (ACol <> PCOL_KIND) or (AIndex < 0) or (AIndex > High(FProblems)) then Exit;
  AColor := SeverityColor(FProblems[AIndex].Severity);
  Result := SeverityIcon(FProblems[AIndex].Severity);
end;

function TLdifTab.PlanCell(Sender: TObject; AIndex, ACol: Integer): string;
begin
  Result := '';
  if (FDoc = nil) or (AIndex < 0) or (AIndex >= FDoc.RecordCount) or (AIndex > High(FStates)) then Exit;
  case ACol of
    COL_NUM: Result := IntToStr(AIndex + 1);
    COL_LINE: Result := IntToStr(FDoc[AIndex].SourceLine);
    COL_OP: Result := ChangeKindName(FDoc[AIndex].Kind);
    COL_DN: Result := FDoc[AIndex].Dn;
    COL_DETAIL: Result := FOpDetails[AIndex];
    COL_STATE:
      case FStates[AIndex] of
        psReady: Result := rsLdifReady;
        psCheck: Result := rsLdifCheck;
        psBlocked: Result := rsLdifBlocked;
        psPending: Result := rsLdifPending;
        psDone: Result := rsLdifDone;
        psFailed: Result := rsLdifFailed;
        psNotAttempted: Result := rsLdifNotAttempted;
      else
        Result := rsLdifUnknown;
      end;
  end;
end;

function TLdifTab.PlanCellIcon(Sender: TObject; AIndex, ACol: Integer; out AColor: TColor): string;
begin
  Result := '';
  AColor := clAppFg;
  if (FDoc = nil) or (AIndex < 0) or (AIndex >= FDoc.RecordCount) or (AIndex > High(FStates)) then Exit;
  if ACol = COL_OP then
    Exit(ChangeKindIcon(FDoc[AIndex].Kind, AColor));
  if ACol <> COL_STATE then Exit;
  case FStates[AIndex] of
    psReady:
      begin
        Result := 'circle-dot';
        AColor := clAccent;
      end;
    psCheck:
      begin
        Result := 'alert-triangle';
        AColor := ShellStateColor(usWarning);
      end;
    psBlocked, psFailed:
      begin
        Result := 'circle-x';
        AColor := ShellStateColor(usError);
      end;
    psPending:
      begin
        Result := 'circle-dashed';
        AColor := ShellStateColor(usMuted);
      end;
    psDone:
      begin
        Result := 'circle-check';
        AColor := ShellStateColor(usOk);
      end;
    psNotAttempted:
      begin
        Result := 'circle-minus';
        AColor := ShellStateColor(usMuted);
      end;
  else
    Result := 'help-circle';
    AColor := clDiffUnknown;
  end;
end;

procedure TLdifTab.AnalyzeClick(Sender: TObject);
begin
  if FRunning then
  begin
    FStatus.Caption := rsLdifBusy;
    Exit;
  end;
  Analyze;
end;

procedure TLdifTab.ImportClick(Sender: TObject);
var
  c: TDirectoryConnection;
  changes: array of TLdapChange;
  i: Integer;
  reason: string;
begin
  if FRunning then Exit;
  if TargetUuid = '' then
  begin
    RtMessageDlg(rsLdifTitle, rsLdifNoConnection, mtInformation, [mbOK], 0);
    Exit;
  end;
  c := FCtx.Connections.Find(TargetUuid);
  if (c = nil) or not c.IsReady or
     (c.Profile.Name + ' - ' + c.Profile.DisplayEndpoint <> FTarget.Text) then
  begin
    FTarget.ItemIndex := 0;
    UpdateActions;
    RtMessageDlg(rsLdifTitle, rsLdifNoConnection, mtInformation, [mbOK], 0);
    Exit;
  end;
  if not Analyze then Exit;
  if FDoc.RecordCount = 0 then Exit;
  SetLength(changes, FDoc.RecordCount);
  for i := 0 to FDoc.RecordCount - 1 do
    changes[i] := FDoc[i];
  // La session approuvee est celle d'avant la confirmation, retrouvee inchangee apres; sinon
  // le lot ne demarre pas.
  FTasks.ProfileUuid := c.Profile.Uuid;
  if not ConfirmWrite(GetParentForm(Self), FCtx, FTasks, changes, reason, rsLdifAnalyzeNote) then
  begin
    if reason <> '' then RtMessageDlg(rsLdifTitle, reason, mtWarning, [mbOK], 0);
    Exit;
  end;
  // Import lie a la session approuvee, pas seulement au profil: une reconnexion (autre serveur,
  // autre identite) arrete le lot.
  for i := 0 to High(FStates) do
    FStates[i] := psPending;
  FRunProfile := c.Profile.Uuid;
  FRunSessionId := c.SessionId;
  FRunGeneration := c.Generation;
  FNextIndex := 0;
  FStopRequested := False;
  FRunning := True;
  SetRunningLook(True);
  SetVerdict('loader-2', clAccent, rsLdifImportTitle, Format(rsLdifProgress, [0, FDoc.RecordCount]),
    clAppFg);
  SelectPage(FPages, PAGE_OPERATIONS);
  RefreshPlan;
  RunNext;
end;

procedure TLdifTab.StopClick(Sender: TObject);
begin
  // Stop agit entre deux operations: celle en vol va au bout ou devient inconnue. On ne
  // debranche pas une ecriture partie.
  FStopRequested := True;
end;

procedure TLdifTab.RunNext;
var
  c: TDirectoryConnection;
  change: TLdapChange;
  err: TLdapError;
  i: Integer;
begin
  c := FCtx.Connections.Find(FRunProfile);
  if (c <> nil) and ((c.SessionId <> FRunSessionId) or (c.Generation <> FRunGeneration)) then
  begin
    FCtx.Log(mlError, rsLdifTitle, 'target session replaced since the preview; import stopped');
    c := nil;
  end;
  if FStopRequested or (c = nil) or not c.IsReady or (FNextIndex >= FDoc.RecordCount) then
  begin
    for i := FNextIndex to FDoc.RecordCount - 1 do
      FStates[i] := psNotAttempted;
    Finish;
    Exit;
  end;
  change := FDoc[FNextIndex].Clone;
  change.Controls := nil;
  FTasks.ProfileUuid := FRunProfile;
  if FTasks.Write('import:' + IntToStr(FNextIndex), change, '', err) = 0 then
  begin
    FStates[FNextIndex] := psFailed;
    FOpDetails[FNextIndex] := ErrorToText(err);
    FCtx.Log(mlError, rsLdifTitle, ErrorToText(err));
    for i := FNextIndex + 1 to FDoc.RecordCount - 1 do
      FStates[i] := psNotAttempted;
    Finish;
  end;
end;

procedure TLdifTab.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
var
  m: TWriteMsg;
  i, idx: Integer;
  detail: string;
begin
  if not FRunning then Exit;
  // Session remplacee pendant l'ecriture, ou fin sans reponse: issue inconnue, le lot s'arrete.
  // Continuer, ce serait empiler des operations sur un etat qu'on ne connait plus.
  if (AEnding = teStale) or (AMsg is TTaskFailedMsg) then
  begin
    if AEnding = teStale then
      detail := 'target session replaced during the import; outcome unknown'
    else
      detail := TTaskFailedMsg(AMsg).Text;
    if (FNextIndex >= 0) and (FNextIndex < Length(FStates)) then
    begin
      FStates[FNextIndex] := psUnknown;
      FOpDetails[FNextIndex] := detail;
    end;
    FCtx.Log(mlError, rsLdifTitle, detail);
    for i := FNextIndex + 1 to High(FStates) do
      FStates[i] := psNotAttempted;
    Finish;
    Exit;
  end;
  if not (AMsg is TWriteMsg) then Exit;
  m := TWriteMsg(AMsg);
  idx := StrToIntDef(Copy(ATask.Tag, Length('import:') + 1, MaxInt), -1);
  if (idx <> FNextIndex) or (idx < 0) or (idx >= Length(FStates)) then
  begin
    FCtx.Log(mlError, rsLdifTitle, 'unexpected import response; import stopped');
    Finish;
    Exit;
  end;
  if m.Result.Ok then
    FStates[idx] := psDone
  else if m.Result.Error.Category = lecUnknownOutcome then
  begin
    FStates[idx] := psUnknown;
    FOpDetails[idx] := ErrorToText(m.Result.Error);
    // Jamais de reprise automatique apres un resultat ambigu: rejouer un ajout incertain, c'est
    // jouer la prod a pile ou face.
    for i := idx + 1 to FDoc.RecordCount - 1 do
      FStates[i] := psNotAttempted;
    Finish;
    Exit;
  end
  else
  begin
    FStates[idx] := psFailed;
    FOpDetails[idx] := ErrorToText(m.Result.Error);
    FCtx.Log(mlError, rsLdifTitle, Format('line %d: %s', [FDoc[idx].SourceLine, ErrorToText(m.Result.Error)]));
    if not FContinue.Checked then
    begin
      for i := idx + 1 to FDoc.RecordCount - 1 do
        FStates[i] := psNotAttempted;
      Finish;
      Exit;
    end;
  end;
  FNextIndex := idx + 1;
  FStatus.Caption := Format(rsLdifProgress, [FNextIndex, FDoc.RecordCount]);
  RefreshPlan;
  RunNext;
end;

procedure TLdifTab.Finish;
var
  i, done, failed, skipped, unknown: Integer;
begin
  FRunning := False;
  SetRunningLook(False);
  done := 0;
  failed := 0;
  skipped := 0;
  unknown := 0;
  for i := 0 to High(FStates) do
    case FStates[i] of
      psDone: Inc(done);
      psFailed: Inc(failed);
      psReady, psCheck, psBlocked, psNotAttempted, psPending: Inc(skipped);
      psUnknown: Inc(unknown);
    end;
  RefreshPlan;
  if (failed > 0) or (unknown > 0) then
    SetVerdict('alert-triangle', ShellStateColor(usWarning), rsLdifImportTitle,
      Format(rsLdifSummary, [done, failed, skipped, unknown]), clAppFg)
  else
    SetVerdict('circle-check', ShellStateColor(usOk), rsLdifImportTitle,
      Format(rsLdifSummary, [done, failed, skipped, unknown]), clAppFg);
  FCtx.Log(mlInfo, rsLdifTitle, FStatus.Caption);
end;

end.
