// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTemplateBatchDialog;

{$mode objfpc}{$H+}

// Creation en serie depuis un CSV: le fichier, la correspondance colonnes-champs, chaque ligne
// telle qu'elle sera creee. Rien ne part avant la confirmation; ensuite une entree a la fois.
// Une issue inconnue arrete le lot: on n'ecrit pas sur une connexion dont on ne sait plus rien.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, Dialogs, LCLType,
  uUiKit, uAppContext, uRtButton, uRtCombo, uRtList, uRtChips, uIcons, uEntryTemplate,
  uTaskDialog, uTaskTracker, uUiInbox, uNextId, uTemplateBatch, uTemplateGroups, uGroupModel,
  uLdapSchema, uConnectionProfile, uGeneratedPasswords, uTemplateUnique;

type
  TTemplateBatchDialog = class(TTaskDialog)
  private
    FT: TEntryTemplate;
    FParentDn: string;
    FBatch: TTemplateBatch;
    FGroups: TGroupTargets;
    FFileLabel, FNote, FStatusLabel: TLabel;
    FStatusIcon: TRtIcon;
    FMapTitle: TLabel;
    FMapBox: TRtScrollBox;
    FCombos: array of TRtComboBox;
    FComboFields: array of Integer;
    FGroupRow: TPanel;
    FGroupBar: TRtChipBar;
    FList: TRtListGrid;
    FInfo: TMemo;
    FRun, FStop, FClose: TButton;
    FScan: TFreeNumberScan;
    FScanField: Integer;
    FScanQueue: array of Integer;
    FScanBase, FScanProblem: string;
    // noms deja pris: lus une fois par session, independants du fichier
    FUniqueReading: TUniqueScan;
    FUniqueBase, FUniqueProblem: string;
    FUniqueAt: QWord;
    FRunAfterRead: Boolean;
    FForestDomains, FForestSeen: Integer;
    FSessionId, FSchemaKey: string;
    FGeneration: Int64;
    FRunning, FStopRequested, FRan, FUpdating: Boolean;
    FRunRow, FRunJoin: Integer;
    FRunJoins: TGroupJoins;
    FFirstCreated: string;
    FHashTask: Int64;
    FHashed: array of RawByteString;
    // mots de passe tires des lignes creees, remis a la fin du lot puis effaces
    FDrawn: TGeneratedPasswords;
    FSentDrawn: string;
    procedure StartUniqueScan;
    procedure EndUniqueScan(const AProblem: string);
    procedure DeferredRun(AData: PtrInt);
    procedure WipeHashed;
    function StartRowHash: Boolean;
    function WriteRow(ARow: TBatchRow): Boolean;
    procedure LocalMessage(AMsg: TUiMessage);
    procedure BuildUi;
    procedure BuildMapping;
    function Schema: TSchemaSnapshot;
    function Provider: TProviderKind;
    procedure ChooseClick(Sender: TObject);
    procedure MapChange(Sender: TObject);
    procedure GroupsChanged(Sender: TObject);
    procedure GroupClose(Sender: TObject; AIndex: Integer);
    procedure GroupAction(Sender: TObject; AIndex: Integer);
    procedure GroupLayout(Sender: TObject);
    procedure Recompute;
    procedure StartScans;
    procedure StartNextScan;
    procedure EndScan(const AProblem: string);
    procedure RefreshList;
    procedure UpdateStatus;
    function GetCell(Sender: TObject; AIndex, ACol: Integer): string;
    function CellIcon(Sender: TObject; AIndex, ACol: Integer; out AColor: TColor): string;
    procedure ListSelect(Sender: TObject; AIndex: Integer);
    procedure RunClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure SendNext;
    procedure FinishRun(const AProblem: string);
    function SessionUnchanged: Boolean;
    procedure SessionChanged;
    procedure HandleWrite(AMsg: TUiMessage; AStale: Boolean);
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
  protected
    function HasRunningWork: Boolean; override;
  public
    constructor CreateBatch(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
      AParentDn: string; const ATemplate: TEntryTemplate);
    destructor Destroy; override;
    function LoadFile(const APath: string): Boolean;
    function LoadText(const AText: RawByteString; const AName: string): Boolean;
    procedure Run;
    procedure Stop;
    function StatusText: string;
    function RowsText: string;
    property Batch: TTemplateBatch read FBatch;
    property Groups: TGroupTargets read FGroups;
    property Running: Boolean read FRunning;
    property FirstCreated: string read FFirstCreated;
  end;

function CreateBatchFromTemplate(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  AParentDn: string; const ATemplate: TEntryTemplate): string;

resourcestring
  rsTbTitle = 'Create several from a CSV file';
  rsTbHelp = 'One line of the file makes one entry. The first line holds the column titles; ' +
    'columns are matched to the values the template asks for, and the rest is worked out as in the form.';
  rsTbUnder = 'Create under %s  -  %s';
  rsTbBusy = 'too many background tasks';
  rsTbNoBase = 'no naming context contains the container';
  rsTbChoose = 'Choose a CSV file...';
  rsTbNoFile = 'No file chosen yet.';
  rsTbFile = '%s: %d line(s), %d column(s), separated by "%s"';
  rsTbTab = 'tab';
  rsTbFilter = 'CSV files (*.csv;*.txt)|*.csv;*.txt|All files|*.*';
  rsTbReadFailed = 'The file cannot be read.';
  rsTbColumns = 'Columns of the file';
  rsTbFromTemplate = '(worked out by the template)';
  rsTbNotInFile = '(not in the file)';
  rsTbGroups = 'Then added to';
  rsTbAddGroup = 'Group';
  rsTbGroupPrompt = 'Group every created entry joins';
  rsTbInfoLine = '# line %d: %s';
  rsTbColLine = 'Line';
  rsTbColDn = 'Entry';
  rsTbColStatus = 'Status';
  rsTbReady = 'ready';
  rsTbSending = 'sending...';
  rsTbCreated = 'created';
  rsTbCreatedJoins = 'created, added to %d group(s)';
  rsTbCreatedJoinsSkipped = 'created; %d group addition(s) not attempted (run stopped)';
  rsTbStatusJoinsSkipped = '%d group addition(s) not attempted, on %d entr(y/ies).';
  rsTbCreatedJoinsFailed = 'created; %d group(s) refused: %s';
  rsTbRefused = 'refused: %s';
  rsTbNotSent = 'not sent: %s';
  rsTbUnknown = 'UNKNOWN: check the directory (%s)';
  rsTbRun = 'Create %d entries...';
  rsTbRunNone = 'Create';
  rsTbStop = 'Stop';
  rsTbStatusNoFile = 'Choose the CSV file to read.';
  rsTbStatusNumbers = 'Searching the directory for free numbers...';
  rsTbStatusGroups = 'Reading the groups...';
  rsTbStatusReady = '%d entr(y/ies) ready to create, %d line(s) left aside.';
  rsTbStatusRunning = 'Creating: %d of %d done.';
  rsTbStatusDone = 'Finished: %d created, %d refused, %d not sent.';
  rsTbStatusStopped = 'Stopped: %d created, %d refused, %d not sent. %s';
  rsTbStatusJoins = '%d group addition(s) refused, on %d entr(y/ies): see each line.';
  rsTbStatusNothing = 'No line of the file can be created as it is: see the status of each line.';
  rsTbSecrets = 'Passwords are not set in a batch (%s): set them afterwards with the password tools.';
  rsTbBatchNote = '%d entries, one after the other; each one reports its own outcome.';
  rsTbHashNote = '%s: set for each entry just before it is sent, so not shown here.';
  rsTbHashBusy = 'too many password computations are running';
  rsTbPwdClear = 'The connection is not encrypted: %s is not sent in clear. Connect with StartTLS or LDAPS.';
  rsTbHashFailed = '%s could not be computed: %s';
  rsTbSessionChanged = 'The connection changed since the lines were checked: nothing was sent. ' +
    'Free numbers and groups are being read again; review the lines, then create.';
  rsTbSessionLostRun = 'The connection changed during the batch: nothing more was sent.';
  rsTbUnknownStop = 'One outcome is unknown: the batch stops here.';
  rsTbStoppedByUser = 'Stopped on request.';
  rsTbScanTooMany = 'too many values to search safely';
  rsTbScanFailed = 'Free numbers for %s could not be found (%s): those lines are left aside.';
  rsTbUniqueReading = 'Reading the names already taken in the directory...';
  rsTbUniqueFailed = 'The names already taken could not be read (%s): nothing is created. Choose the ' +
    'file again to retry.';
  rsTbUniqueTooMany = 'too many values under %s';
  rsTbReadyLookalike = 'ready - same name as %s: homonym or duplicate?';
  rsTbForestPartial = 'Names were checked in %s only: the other %d domain(s) of the forest are not read.';
  rsTbForestUnknown = 'Names were checked in %s only: the domains of the forest could not be listed.';
  rsTbFileOnly = 'Names were checked against this file only: the target directory is not read.';
  rsTbLookalikeAsk = '%d line(s) carry the name of an entry that already exists, in the directory or ' +
    'higher in the file. First one: line %d, like %s.' + LineEnding + LineEnding +
    'Homonyms get their own number; duplicates make two accounts for one person. Create them anyway?';
  rsTbReadOnly = 'This profile is read-only: nothing can be created.';
  rsTbNoConnection = 'The connection is closed.';

implementation

uses
  Math, LazUTF8, uTheme, uConnections, uStrings, uRtMessage, uServerKind, uSafeSave, uDirectoryService,
  uDirectoryWorker, uSearchModel, uLdapErrors, uLdapEntry, uChangeSet, uLdif, uSensitive,
  uEntryPickDialog, uTemplateEditor, uAdObjectPlan, uEntryCreationPlan, uRtBytes, uPasswordWork,
  uAdPasswordRules, uPasswordSchemes, uRtSecretEdit;

const
  // La zone fait un nombre entier de rangees: aucune n'est coupee en deux.
  MAP_ROWS_SHOWN = 6;
  MAP_ROW_PITCH = 32;
  FILE_NAME_SHOWN = 48;
  NUMBER_TAG = 'batchnumber';
  UNIQUE_TAG = 'batchunique';
  FOREST_TAG = 'batchforest';
  UNIQUE_FRESH_MS = 120000;
  POLICY_TAG = 'batchpolicy';
  GROUP_TAG = 'batchgroup';
  WRITE_TAG = 'batchwrite';

function CreateBatchFromTemplate(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  AParentDn: string; const ATemplate: TEntryTemplate): string;
var
  d: TTemplateBatchDialog;
begin
  d := TTemplateBatchDialog.CreateBatch(AOwner, ACtx, AProfileUuid, AParentDn, ATemplate);
  try
    d.ShowModal;
    Result := d.FirstCreated;
  finally
    d.Free;
  end;
end;

constructor TTemplateBatchDialog.CreateBatch(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, AParentDn: string; const ATemplate: TEntryTemplate);
var
  c: TDirectoryConnection;
begin
  inherited CreateDialog(AOwner, rsTbTitle + ': ' + ATemplate.Name, 1040, 760);
  SetIcon('file-import');
  InitTasks(ACtx, AProfileUuid);
  FT := CloneTemplate(ATemplate);
  FParentDn := AParentDn;
  FScanField := -1;
  FRunRow := -1;
  c := Conn;
  if c <> nil then
  begin
    SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
    // Empreinte prise avant la premiere lecture de groupe: c'est sur cette session qu'elle part.
    FSessionId := c.SessionId;
    FGeneration := c.Generation;
  end;
  Tasks.OnMessage := @TaskMessage;
  Tasks.OnUntracked := @LocalMessage;
  FBatch := TTemplateBatch.Create(FT, FCtx.Sensitive, FParentDn);
  FBatch.ToFile := (c <> nil) and (c.Profile.LdifPath <> '');
  FGroups := TGroupTargets.Create(Tasks, GROUP_TAG);
  BuildUi;
  ApplyTheme;
  FInfo.Color := clEditorBg;
  FInfo.Font.Color := clEditorFg;
  StyleMemo(FInfo);
  FGroupBar.Color := clAppBg;
  FGroups.OnChange := @GroupsChanged;
  FGroups.SetGroups(FT.Groups);
  c := Conn;
  if (Provider = pkActiveDirectory) and (c <> nil) and (c.RootDse <> nil) and
     (c.RootDse.FirstValue('defaultNamingContext') <> '') then
    Tasks.ReadEntry(POLICY_TAG, c.RootDse.FirstValue('defaultNamingContext'), AD_POLICY_ATTRS);
  UpdateStatus;
end;

destructor TTemplateBatchDialog.Destroy;
begin
  PasswordWork.CancelOwner(Self);
  WipeHashed;
  RtWipeSecret(FSentDrawn);
  WipeGeneratedPasswords(FDrawn);
  Application.RemoveAsyncCalls(Self);
  if Tasks <> nil then
  begin
    Tasks.Cancel(NUMBER_TAG);
    Tasks.Cancel(UNIQUE_TAG);
    Tasks.Cancel(FOREST_TAG);
    Tasks.Cancel(GROUP_TAG);
  end;
  FreeAndNil(FScan);
  FreeAndNil(FUniqueReading);
  FGroups.Free;
  FBatch.Free;
  inherited Destroy;
end;

function TTemplateBatchDialog.Schema: TSchemaSnapshot;
var
  c: TDirectoryConnection;
begin
  Result := nil;
  c := Conn;
  if c <> nil then Result := c.Schema;
end;

function TTemplateBatchDialog.Provider: TProviderKind;
var
  c: TDirectoryConnection;
begin
  Result := pkAuto;
  c := Conn;
  if c <> nil then Result := EffectiveServerKind(c.Profile, c.RootDse);
end;

function TTemplateBatchDialog.HasRunningWork: Boolean;
begin
  // Un lot en route ne se ferme pas sous les ecritures: Stop d'abord, le bilan ensuite.
  Result := FRunning;
end;

procedure TTemplateBatchDialog.BuildUi;
var
  bar, statusRow: TPanel;
  lbl: TLabel;
begin
  lbl := MakeLabel(Body, rsTbHelp);
  lbl.WordWrap := True;
  lbl := MakeDataLabel(Body, Format(rsTbUnder, [AdCanonicalPath(FParentDn), FParentDn]));
  lbl.Font.Color := DialogStateColor(usMuted);
  bar := MakePanel(Body, alTop, 38);
  bar.BorderSpacing.Top := 4;
  MakeButton(bar, rsTbChoose, @ChooseClick);
  FFileLabel := MakeDataLabel(bar, rsTbNoFile, alClient);
  FFileLabel.Layout := tlCenter;
  FFileLabel.BorderSpacing.Left := 10;

  FMapTitle := MakeLabel(Body, rsTbColumns);
  FMapTitle.Font.Style := [fsBold];
  FMapTitle.BorderSpacing.Top := 6;
  FMapTitle.Visible := False;
  FMapBox := TRtScrollBox.Create(Body);
  FMapBox.Parent := Body;
  StackTop(FMapBox);
  FMapBox.Align := alTop;
  FMapBox.Height := MAP_ROWS_SHOWN * MAP_ROW_PITCH;
  FMapBox.Visible := False;

  FGroupRow := MakeFieldRow(Body, rsTbGroups);
  FGroupBar := TRtChipBar.Create(FGroupRow);
  FGroupBar.Parent := FGroupRow;
  FGroupBar.Align := alClient;
  FGroupBar.BorderSpacing.Top := 2;
  FGroupBar.Reorder := False;
  FGroupBar.OnChipClose := @GroupClose;
  FGroupBar.OnActionClick := @GroupAction;
  FGroupBar.OnLayoutChanged := @GroupLayout;

  FNote := MakeDataLabel(Body, '');
  FNote.WordWrap := True;
  FNote.Visible := False;

  statusRow := MakePanel(Body, alBottom, 40);
  FStatusIcon := TRtIcon.Create(statusRow);
  FStatusIcon.Parent := statusRow;
  FStatusIcon.Align := alLeft;
  FStatusIcon.Width := 24;
  FStatusIcon.TopAligned := True;
  FStatusIcon.BorderSpacing.Top := 4;
  FStatusLabel := MakeDataLabel(statusRow, '', alClient);
  FStatusLabel.WordWrap := True;

  FInfo := MakeMemo(Body, alBottom);
  FInfo.Height := 130;
  FInfo.ReadOnly := True;
  FInfo.WordWrap := True;
  FInfo.ScrollBars := ssAutoVertical;

  FList := TRtListGrid.Create(Body);
  FList.Parent := Body;
  FList.Align := alClient;
  FList.BorderSpacing.Top := 6;
  FList.BorderSpacing.Bottom := 4;
  FList.FillWidth := True;
  FList.AddColumn(rsTbColLine, 60);
  FList.AddColumn(rsTbColDn, 470);
  FList.AddColumn(rsTbColStatus, 430);
  FList.OnGetCell := @GetCell;
  FList.OnGetCellIcon := @CellIcon;
  FList.OnSelectRow := @ListSelect;

  FClose := AddButton(rsClose, mrClose, False, True);
  FRun := AddButton(rsTbRunNone, mrNone, True);
  FRun.OnClick := @RunClick;
  FStop := AddButton(rsTbStop, mrNone);
  FStop.OnClick := @StopClick;
  FStop.Enabled := False;
end;

procedure TTemplateBatchDialog.BuildMapping;
var
  i, k, n, col: Integer;
  row: TPanel;
  combo: TRtComboBox;
  f: TTplField;
  title: string;
begin
  FUpdating := True;
  FMapBox.Content.DisableAlign;
  try
    for i := FMapBox.Content.ControlCount - 1 downto 0 do
      FMapBox.Content.Controls[i].Free;
    FCombos := nil;
    FComboFields := nil;
    n := 0;
    for i := 0 to High(FT.Fields) do
    begin
      f := FT.Fields[i];
      // Ni secret ni valeur fixe: le fichier ne remplit que ce que le modele laisse ouvert.
      if not FBatch.Mappable(i) then Continue;
      title := FieldPrompt(f);
      if not SameText(title, f.Attr) then title := title + '  (' + f.Attr + ')';
      row := MakeFieldRow(FMapBox.Content, title, 320);
      row.BorderSpacing.Top := 0;
      row.Height := MAP_ROW_PITCH;
      row.Top := n * MAP_ROW_PITCH;
      combo := MakeCombo(row, []);
      if f.Source = tsAsk then combo.Items.Add(rsTbNotInFile)
      else combo.Items.Add(rsTbFromTemplate);
      for k := 0 to High(FBatch.Table.Headers) do
        combo.Items.Add(FBatch.Table.Headers[k]);
      col := FBatch.Mapping[i];
      combo.ItemIndex := col + 1;
      combo.Tag := n;
      combo.OnChange := @MapChange;
      SetLength(FCombos, n + 1);
      SetLength(FComboFields, n + 1);
      FCombos[n] := combo;
      FComboFields[n] := i;
      Inc(n);
    end;
  finally
    FMapBox.Content.EnableAlign;
    FUpdating := False;
  end;
  ThemeControlTree(FMapBox);
  FMapBox.VertScrollBar.Increment := MAP_ROW_PITCH;
  FMapBox.VertScrollBar.Position := 0;
  FMapBox.Height := Max(1, Min(n, MAP_ROWS_SHOWN)) * MAP_ROW_PITCH;
  FMapTitle.Visible := n > 0;
  FMapBox.Visible := n > 0;
  // Les rangees alTop se reclassent quand la zone reapparait: ordre de creation remis.
  StackByCreation(Body);
end;

procedure TTemplateBatchDialog.MapChange(Sender: TObject);
var
  n: Integer;
begin
  if FUpdating or FRunning then Exit;
  n := TRtComboBox(Sender).Tag;
  if (n < 0) or (n > High(FComboFields)) then Exit;
  FBatch.Mapping[FComboFields[n]] := TRtComboBox(Sender).ItemIndex - 1;
  FBatch.ForgetNumbers;
  Recompute;
  StartScans;
end;

procedure TTemplateBatchDialog.ChooseClick(Sender: TObject);
var
  od: TOpenDialog;
begin
  if FRunning then Exit;
  od := TOpenDialog.Create(Self);
  try
    od.Filter := rsTbFilter;
    if od.Execute then LoadFile(od.FileName);
  finally
    od.Free;
  end;
end;

function TTemplateBatchDialog.LoadFile(const APath: string): Boolean;
var
  fs: THandleStream;
  notReg: Boolean;
  raw: RawByteString;
begin
  Result := False;
  fs := OpenRegularFileRead(APath, notReg);
  if fs = nil then
  begin
    RtMessageDlg(rsTbTitle, rsTbReadFailed, mtWarning, [mbOK], 0);
    Exit;
  end;
  try
    if not ReadWholeStream(fs, BATCH_MAX_BYTES, raw) then
    begin
      RtMessageDlg(rsTbTitle, Format(rsTbTooLarge, [BATCH_MAX_BYTES div (1024 * 1024)]), mtWarning,
        [mbOK], 0);
      Exit;
    end;
  finally
    fs.Free;
  end;
  Result := LoadText(raw, ExtractFileName(APath));
end;

function TTemplateBatchDialog.LoadText(const AText: RawByteString; const AName: string): Boolean;
var
  table: TCsvTable;
  err, sep, shown: string;
begin
  Result := False;
  if FRunning then Exit;
  if not ParseCsv(AText, table, err) then
  begin
    RtMessageDlg(rsTbTitle, err, mtWarning, [mbOK], 0);
    Exit;
  end;
  FRan := False;
  FFirstCreated := '';
  FBatch.SetTable(table);
  if table.Delimiter = #9 then sep := rsTbTab else sep := table.Delimiter;
  shown := AName;
  if UTF8Length(shown) > FILE_NAME_SHOWN then
    shown := UTF8Copy(shown, 1, FILE_NAME_SHOWN div 2) + '...' +
      UTF8Copy(shown, UTF8Length(shown) - FILE_NAME_SHOWN div 2 + 1, FILE_NAME_SHOWN div 2);
  FFileLabel.Caption := Format(rsTbFile, [shown, Length(table.Rows), Length(table.Headers), sep]);
  FFileLabel.Hint := AName;
  FFileLabel.ShowHint := True;
  BuildMapping;
  Recompute;
  StartScans;
  Result := True;
end;

procedure TTemplateBatchDialog.Recompute;
var
  c: TDirectoryConnection;
  moved: Boolean;
begin
  c := Conn;
  // Autre session: lectures jetees AVANT la nouvelle empreinte, sinon un recalcul les blanchirait.
  moved := (c <> nil) and ((c.SessionId <> FSessionId) or (c.Generation <> FGeneration));
  if moved then
  begin
    FBatch.ForgetNumbers;
    Tasks.Cancel(UNIQUE_TAG);
    FreeAndNil(FUniqueReading);
    FBatch.ForgetUnique;
    FSessionId := c.SessionId;
    FGeneration := c.Generation;
    FGroups.SetGroups(FGroups.Dns);
  end;
  // Schema lu a l'instant: celui d'avant a pu etre libere par une relecture.
  FBatch.Compute(Schema, Provider);
  if c <> nil then FSchemaKey := SchemaIdentity(c.Schema);
  RefreshList;
  if moved then StartScans;
end;

procedure TTemplateBatchDialog.RefreshList;
var
  keep: Integer;
begin
  keep := FList.ItemIndex;
  FList.Count := FBatch.Count;
  if (keep >= 0) and (keep < FBatch.Count) then FList.ItemIndex := keep
  else if FBatch.Count > 0 then FList.ItemIndex := 0;
  FList.Invalidate;
  ListSelect(FList, FList.ItemIndex);
  UpdateStatus;
end;

function TTemplateBatchDialog.GetCell(Sender: TObject; AIndex, ACol: Integer): string;
var
  row: TBatchRow;
begin
  Result := '';
  if (AIndex < 0) or (AIndex >= FBatch.Count) then Exit;
  row := FBatch[AIndex];
  case ACol of
    0: Result := IntToStr(row.Line);
    1: Result := row.Dn;
    2:
      case row.State of
        brsReady:
          if row.Lookalike <> '' then Result := Format(rsTbReadyLookalike, [row.Lookalike])
          else Result := rsTbReady;
        brsProblem: Result := row.Problem;
        brsSending: Result := rsTbSending;
        brsCreated:
          if row.JoinsFailed > 0 then
            Result := Format(rsTbCreatedJoinsFailed, [row.JoinsFailed, row.Detail])
          else if row.JoinsSkipped > 0 then
            Result := Format(rsTbCreatedJoinsSkipped, [row.JoinsSkipped])
          else if row.JoinsDone > 0 then
            Result := Format(rsTbCreatedJoins, [row.JoinsDone])
          else
            Result := rsTbCreated;
        brsRefused: Result := Format(rsTbRefused, [row.Detail]);
        brsNotSent: Result := Format(rsTbNotSent, [row.Detail]);
        brsUnknown: Result := Format(rsTbUnknown, [row.Detail]);
      end;
  end;
end;

function TTemplateBatchDialog.CellIcon(Sender: TObject; AIndex, ACol: Integer;
  out AColor: TColor): string;
begin
  Result := '';
  AColor := clNone;
  if (ACol <> 2) or (AIndex < 0) or (AIndex >= FBatch.Count) then Exit;
  case FBatch[AIndex].State of
    brsReady:
      begin
        Result := 'circle-dashed';
        if FBatch[AIndex].Lookalike <> '' then AColor := ShellStateColor(usWarning)
        else AColor := ShellStateColor(usMuted);
      end;
    brsSending:
      begin
        Result := 'loader-2';
        AColor := ShellStateColor(usMuted);
      end;
    brsCreated:
      begin
        Result := 'circle-check';
        if (FBatch[AIndex].JoinsFailed > 0) or (FBatch[AIndex].JoinsSkipped > 0) then
          AColor := ShellStateColor(usWarning)
        else AColor := ShellStateColor(usOk);
      end;
    brsUnknown:
      begin
        Result := 'help-circle';
        AColor := clDiffUnknown;
      end;
    brsProblem:
      begin
        Result := 'circle-minus';
        AColor := ShellStateColor(usWarning);
      end;
  else
    Result := 'circle-x';
    AColor := ShellStateColor(usError);
  end;
end;

procedure TTemplateBatchDialog.ListSelect(Sender: TObject; AIndex: Integer);
var
  row: TBatchRow;
  masked: TLdapEntry;
  i: Integer;
  head: string;
begin
  FInfo.Clear;
  if (AIndex < 0) or (AIndex >= FBatch.Count) then Exit;
  row := FBatch[AIndex];
  head := Format(rsTbInfoLine, [row.Line, GetCell(FList, AIndex, 2)]);
  if row.Skipped <> '' then head := head + LineEnding + '# ' + row.Skipped;
  if row.Entry = nil then
  begin
    FInfo.Text := head;
    Exit;
  end;
  masked := row.Entry.Clone;
  try
    for i := 0 to masked.AttrCount - 1 do
      if FCtx.Sensitive.IsSensitive(masked.Attrs[i].Description) then
        masked.Attrs[i].SetValues([MASK_TEXT]);
    FInfo.Text := head + LineEnding + LineEnding + string(LdifEntryToString(masked));
  finally
    masked.Free;
  end;
end;

procedure TTemplateBatchDialog.UpdateStatus;
var
  text_, secrets, problem: string;
  state: TUiState;
  ready, aside: Integer;
  iconId: string;
begin
  if FStatusLabel = nil then Exit;
  ready := FBatch.ReadyCount;
  aside := FBatch.CountIn(brsProblem);
  state := usMuted;
  problem := FGroups.FirstProblem;
  if FRunning then
    text_ := Format(rsTbStatusRunning, [FBatch.CountIn(brsCreated) + FBatch.CountIn(brsRefused) +
      FBatch.CountIn(brsNotSent) + FBatch.CountIn(brsUnknown), FBatch.Count - aside])
  else if FRan then
    text_ := FStatusLabel.Caption
  else if Length(FBatch.Table.Headers) = 0 then
    text_ := rsTbStatusNoFile
  else if (FScan <> nil) or (Length(FScanQueue) > 0) then
    text_ := rsTbStatusNumbers
  else if FUniqueReading <> nil then
    text_ := rsTbUniqueReading
  else if FGroups.Busy then
    text_ := rsTbStatusGroups
  else if problem <> '' then
  begin
    text_ := problem;
    state := usError;
  end
  else if FUniqueProblem <> '' then
  begin
    text_ := FUniqueProblem;
    state := usError;
  end
  else if FScanProblem <> '' then
  begin
    text_ := FScanProblem;
    state := usWarning;
  end
  else if ready = 0 then
  begin
    text_ := rsTbStatusNothing;
    state := usWarning;
  end
  else
  begin
    text_ := Format(rsTbStatusReady, [ready, aside]);
    if aside = 0 then state := usOk else state := usWarning;
    if FForestDomains > 1 then
    begin
      text_ := text_ + ' ' + Format(rsTbForestPartial, [FUniqueBase, FForestDomains - 1]);
      state := usWarning;
    end
    else if FForestDomains < 0 then
    begin
      text_ := text_ + ' ' + Format(rsTbForestUnknown, [FUniqueBase]);
      state := usWarning;
    end
    else if FBatch.ToFile and FBatch.UniqueNeeded(Provider, Schema) then
    begin
      text_ := text_ + ' ' + rsTbFileOnly;
      state := usWarning;
    end;
  end;
  if FRan then state := usMuted;
  FStatusLabel.Caption := text_;
  FStatusLabel.Font.Color := DialogStateColor(state);
  case state of
    usOk: iconId := 'circle-check';
    usError: iconId := 'alert-triangle';
  else
    iconId := 'info-circle';
  end;
  FStatusIcon.SetIcon(iconId, 16, DialogStateColor(state));
  secrets := FBatch.SecretNames;
  FNote.Visible := secrets <> '';
  if secrets <> '' then
  begin
    FNote.Caption := Format(rsTbSecrets, [secrets]);
    FNote.Font.Color := DialogStateColor(usWarning);
  end;
  FRun.Enabled := not FRunning and not FRan and (ready > 0) and (FScan = nil) and
    (Length(FScanQueue) = 0) and (FUniqueReading = nil) and not FGroups.Busy and (problem = '');
  if ready > 0 then FRun.Caption := Format(rsTbRun, [ready]) else FRun.Caption := rsTbRunNone;
  FStop.Enabled := FRunning and not FStopRequested;
  FClose.Enabled := not FRunning;
end;

{ Groupes }

procedure TTemplateBatchDialog.GroupsChanged(Sender: TObject);
begin
  if FGroupBar = nil then Exit;
  FGroupBar.OnLayoutChanged := nil;
  try
    FillGroupChips(FGroupBar, FGroups, not FRunning and not FRan, rsTbAddGroup);
  finally
    FGroupBar.OnLayoutChanged := @GroupLayout;
  end;
  GroupLayout(nil);
  UpdateStatus;
end;

procedure TTemplateBatchDialog.GroupLayout(Sender: TObject);
var
  h: Integer;
begin
  if (FGroupBar = nil) or (FGroupRow = nil) then Exit;
  h := Max(30, FGroupBar.PreferredHeight(Max(100, FGroupBar.ClientWidth)) + 6);
  if FGroupRow.Height <> h then FGroupRow.Height := h;
end;

procedure TTemplateBatchDialog.GroupClose(Sender: TObject; AIndex: Integer);
begin
  if FRunning or FRan then Exit;
  FGroups.Remove(AIndex);
end;

procedure TTemplateBatchDialog.GroupAction(Sender: TObject; AIndex: Integer);
var
  c: TDirectoryConnection;
  dn: string;
begin
  c := Conn;
  if FRunning or FRan or (c = nil) or not c.IsReady then Exit;
  dn := '';
  if not PickDirectoryEntry(Self, FCtx, FProfileUuid, rsTbTitle, rsTbGroupPrompt,
    NextIdBaseFor(c, FParentDn), '', dn) then Exit;
  if FGroups.Add(dn) then FGroups.Pump;
end;

{ Numeros libres }

procedure TTemplateBatchDialog.StartScans;
var
  fields: TTplIndexes;
  i: Integer;
begin
  Tasks.Cancel(NUMBER_TAG);
  FreeAndNil(FScan);
  FScanField := -1;
  FScanProblem := '';
  FScanQueue := nil;
  if FBatch.Count = 0 then Exit;
  fields := FBatch.NumberFields;
  SetLength(FScanQueue, Length(fields));
  for i := 0 to High(fields) do FScanQueue[i] := fields[i];
  if (FUniqueReading = nil) and (FBatch.UniquePending or (FUniqueProblem <> '')) then StartUniqueScan;
  StartNextScan;
  UpdateStatus;
end;

procedure TTemplateBatchDialog.StartUniqueScan;
var
  c: TDirectoryConnection;
begin
  Tasks.Cancel(UNIQUE_TAG);
  FreeAndNil(FUniqueReading);
  FUniqueProblem := '';
  FForestDomains := 0;
  Tasks.Cancel(FOREST_TAG);
  if not FBatch.UniqueNeeded(Provider, Schema) then Exit;
  FBatch.ForgetUnique;
  c := Conn;
  if (c = nil) or not c.IsReady then
  begin
    EndUniqueScan(rsTbNoConnection);
    Exit;
  end;
  if (Provider = pkActiveDirectory) and (c.Profile.LdifPath = '') then
  begin
    // Inconnu tant que pas prouve: un refus de lire les partitions ne fait pas une foret d'un arbre.
    FForestDomains := -1;
    FForestSeen := 0;
    if (c.RootDse <> nil) and (c.RootDse.FirstValue('configurationNamingContext', '') <> '') then
      Tasks.Search(FOREST_TAG, ForestDomainsRequest(c.Profile, c.RootDse.FirstValue('configurationNamingContext', '')));
  end;
  FUniqueBase := NextIdBaseFor(c, FParentDn);
  if FUniqueBase = '' then
  begin
    EndUniqueScan(rsTbNoBase);
    Exit;
  end;
  FUniqueReading := TUniqueScan.Create(FT, Provider, Schema);
  if Tasks.Search(UNIQUE_TAG, UniqueSearchRequest(c.Profile, FUniqueBase, FUniqueReading)) = 0 then
    EndUniqueScan(rsTbBusy);
end;

procedure TTemplateBatchDialog.EndUniqueScan(const AProblem: string);
var
  scan: TUniqueScan;
  reason: string;
begin
  scan := FUniqueReading;
  FUniqueReading := nil;
  if (AProblem = '') and (scan <> nil) and not scan.Overflow then
  begin
    FBatch.SetUnique(scan);
    FUniqueAt := GetTickCount64;
  end
  else
  begin
    scan.Free;
    reason := AProblem;
    if reason = '' then reason := Format(rsTbUniqueTooMany, [FUniqueBase]);
    FUniqueProblem := Format(rsTbUniqueFailed, [reason]);
    FBatch.FailUnique(reason);
    FRunAfterRead := False;
    FCtx.Log(mlWarning, rsTbTitle, FUniqueProblem);
  end;
  if not FRunning and not FRan then Recompute;
  if FRunAfterRead then
  begin
    FRunAfterRead := False;
    Application.QueueAsyncCall(@DeferredRun, 0);
  end;
end;

procedure TTemplateBatchDialog.DeferredRun(AData: PtrInt);
begin
  if not FRunning and not FRan then RunClick(nil);
end;

procedure TTemplateBatchDialog.StartNextScan;
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
      EndScan(rsTbNoConnection);
      Continue;
    end;
    FScanBase := NextIdBaseFor(c, FParentDn);
    if FScanBase = '' then
    begin
      EndScan(rsTbNoBase);
      Continue;
    end;
    FScan := TFreeNumberScan.Create(f.Attr, f.NumberMode = tnFirstFree, f.HasMin, f.HasMax, f.Min,
      f.Max, Provider, Schema);
    if Tasks.Search(NUMBER_TAG, NextIdSearchRequest(c.Profile, FScanBase, FScan.Attr)) = 0 then
      EndScan(rsTbBusy);
  end;
end;

procedure TTemplateBatchDialog.EndScan(const AProblem: string);
var
  i: Integer;
  used: TInt64Array;
begin
  i := FScanField;
  FScanField := -1;
  if (i >= 0) and (i <= High(FT.Fields)) then
  begin
    if (AProblem = '') and (FScan <> nil) and not FScan.Overflow then
    begin
      // L'annuaire tel qu'il est juge les numeros imposes; ceux-ci sont ensuite reserves.
      used := FScan.UsedValues;
      FScan.Reserve(FBatch.FileNumbers(i));
      FBatch.SetNumbers(i, FScan.PickMany(FBatch.Count), used);
    end
    else
    begin
      // Sans enumeration complete, aucun numero n'est sur: ces lignes restent de cote.
      FBatch.FailNumbers(i);
      if AProblem = '' then FScanProblem := Format(rsTbScanFailed, [FT.Fields[i].Attr, rsTbScanTooMany])
      else FScanProblem := Format(rsTbScanFailed, [FT.Fields[i].Attr, AProblem]);
      FCtx.Log(mlWarning, rsTbTitle, FScanProblem);
    end;
  end;
  FreeAndNil(FScan);
  if Length(FScanQueue) = 0 then Recompute;
end;

{ Envoi }

// Autre session: tout ce qui avait ete lu est jete. Numeros et groupes relus, envoi ferme d'ici la.
procedure TTemplateBatchDialog.SessionChanged;
begin
  Recompute;
end;

function TTemplateBatchDialog.SessionUnchanged: Boolean;
var
  c: TDirectoryConnection;
begin
  c := Conn;
  Result := (c <> nil) and c.IsReady and (c.SessionId = FSessionId) and
    (c.Generation = FGeneration) and (SchemaIdentity(c.Schema) = FSchemaKey);
end;

procedure TTemplateBatchDialog.Run;
begin
  RunClick(nil);
end;

procedure TTemplateBatchDialog.Stop;
begin
  StopClick(nil);
end;

procedure TTemplateBatchDialog.RunClick(Sender: TObject);
var
  c: TDirectoryConnection;
  all: array of TLdapChange;
  joins: TGroupJoins;
  i, j, n: Integer;
  change: TLdapChange;
  reason, err, note: string;
  ok: Boolean;
begin
  if FRunning or FRan or not FRun.Enabled then Exit;
  c := Conn;
  if (c = nil) or not c.IsReady then
  begin
    RtMessageDlg(rsTbTitle, rsTbNoConnection, mtWarning, [mbOK], 0);
    Exit;
  end;
  if c.Profile.ReadOnly then
  begin
    RtMessageDlg(rsTbTitle, rsTbReadOnly, mtWarning, [mbOK], 0);
    Exit;
  end;
  if not SessionUnchanged then
  begin
    SessionChanged;
    RtMessageDlg(rsTbTitle, rsTbSessionChanged, mtWarning, [mbOK], 0);
    Exit;
  end;
  // Noms lus il y a trop longtemps: relus, numeros recalcules, puis on revient ici.
  if FBatch.UniqueNeeded(Provider, Schema) and (GetTickCount64 - FUniqueAt > UNIQUE_FRESH_MS) then
  begin
    FRunAfterRead := True;
    StartUniqueScan;
    UpdateStatus;
    Exit;
  end;
  if FBatch.LookalikeCount > 0 then
  begin
    for i := 0 to FBatch.Count - 1 do
      if (FBatch[i].State = brsReady) and (FBatch[i].Lookalike <> '') then Break;
    if RtMessageDlg(rsTbTitle, Format(rsTbLookalikeAsk, [FBatch.LookalikeCount, FBatch[i].Line,
       FBatch[i].Lookalike]), mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  end;
  // Refuse avant de hacher cinq mille lignes que le serveur refuserait une par une.
  if (FBatch.HashedNames <> '') and not c.SecretsSafe then
  begin
    RtMessageDlg(rsTbTitle, Format(rsTbPwdClear, [FBatch.HashedNames]), mtWarning, [mbOK], 0);
    Exit;
  end;
  joins := FGroups.Joins;
  all := nil;
  n := 0;
  ok := True;
  try
    for i := 0 to FBatch.Count - 1 do
    begin
      if FBatch[i].State <> brsReady then Continue;
      SetLength(all, n + 1 + Length(joins));
      change := NewChange(ckAdd, FBatch[i].Entry.Dn);
      change.Entry.Free;
      change.Entry := FBatch[i].Entry.Clone;
      all[n] := change;
      Inc(n);
      for j := 0 to High(joins) do
      begin
        change := GroupJoinChange(joins[j], FBatch[i].Entry, err);
        if change = nil then
        begin
          // Groupe par uid, entree sans uid: mieux vaut le savoir avant d'avoir cree la moitie du lot.
          RtMessageDlg(rsTbTitle, Format('%s - %s: %s', [FBatch[i].Dn, joins[j].GroupDn, err]),
            mtWarning, [mbOK], 0);
          ok := False;
          Break;
        end;
        all[n] := change;
        Inc(n);
      end;
      if not ok then Break;
    end;
    SetLength(all, n);
    if not ok or (n = 0) then Exit;
    note := Format(rsTbBatchNote, [FBatch.ReadyCount]);
    if FBatch.HashedNames <> '' then note := note + ' ' + Format(rsTbHashNote, [FBatch.HashedNames]);
    if not ConfirmWrite(Self, FCtx, Tasks, all, reason, note) then
    begin
      if reason <> '' then RtMessageDlg(rsTbTitle, reason, mtWarning, [mbOK], 0);
      Exit;
    end;
  finally
    for i := 0 to n - 1 do
      all[i].Free;
  end;
  if not SessionUnchanged then
  begin
    SessionChanged;
    RtMessageDlg(rsTbTitle, rsTbSessionChanged, mtWarning, [mbOK], 0);
    Exit;
  end;
  FRunJoins := joins;
  FRunning := True;
  FStopRequested := False;
  FRunRow := -1;
  FRunJoin := -1;
  GroupsChanged(nil);
  UpdateStatus;
  SendNext;
end;

procedure TTemplateBatchDialog.StopClick(Sender: TObject);
begin
  if not FRunning then Exit;
  // L'ecriture partie rend son issue; les suivantes restent a quai.
  FStopRequested := True;
  UpdateStatus;
end;

procedure TTemplateBatchDialog.SendNext;
var
  row: TBatchRow;
  change: TLdapChange;
  werr: TLdapError;
  err: string;
  i, k: Integer;
begin
  while True do
  begin
    if (FRunRow >= 0) and (FRunRow < FBatch.Count) and (FBatch[FRunRow].State = brsCreated) and
       (FRunJoin < High(FRunJoins)) and not FStopRequested then
    begin
      Inc(FRunJoin);
      row := FBatch[FRunRow];
      if not SessionUnchanged then
      begin
        FinishRun(rsTbSessionLostRun);
        Exit;
      end;
      change := GroupJoinChange(FRunJoins[FRunJoin], row.Entry, err);
      if change = nil then
      begin
        Inc(row.JoinsFailed);
        row.Detail := err;
        Continue;
      end;
      if Tasks.Write(WRITE_TAG, change, '', werr) = 0 then
      begin
        Inc(row.JoinsFailed);
        row.Detail := ErrorToText(werr);
        Continue;
      end;
      Exit;
    end;
    if FStopRequested then
    begin
      FinishRun(rsTbStoppedByUser);
      Exit;
    end;
    i := FRunRow + 1;
    while (i < FBatch.Count) and (FBatch[i].State <> brsReady) do Inc(i);
    if i >= FBatch.Count then
    begin
      FinishRun('');
      Exit;
    end;
    if not SessionUnchanged then
    begin
      FinishRun(rsTbSessionLostRun);
      Exit;
    end;
    FRunRow := i;
    FRunJoin := -1;
    row := FBatch[i];
    if (Length(row.PwdPlain) > 0) and SameText(row.PwdSchemes[0], TEMPLATE_SCHEME_AD) then
    begin
      // AD hache lui-meme: encode sur place, part avec le compte dans la meme requete.
      WipeHashed;
      SetLength(FHashed, Length(row.PwdPlain));
      for k := 0 to High(row.PwdPlain) do
        FHashed[k] := EncodeUnicodePwd(row.PwdPlain[k]);
      if WriteRow(row) then Exit;
      Continue;
    end;
    if Length(row.PwdPlain) > 0 then
    begin
      // Le hachage passe d'abord, hors de l'interface; l'ecriture suit dans LocalMessage.
      WipeHashed;
      row.State := brsSending;
      if StartRowHash then
      begin
        FList.Invalidate;
        UpdateStatus;
        Exit;
      end;
      row.State := brsNotSent;
      row.Detail := rsTbHashBusy;
      Continue;
    end;
    if WriteRow(row) then Exit;
  end;
end;

procedure TTemplateBatchDialog.WipeHashed;
var
  i: Integer;
begin
  for i := 0 to High(FHashed) do
    WipeString(FHashed[i]);
  FHashed := nil;
end;

function TTemplateBatchDialog.StartRowHash: Boolean;
var
  row: TBatchRow;
  k: Integer;
begin
  row := FBatch[FRunRow];
  k := Length(FHashed);
  FHashTask := NextTaskId;
  Result := PasswordWork.StartGenerate(row.PwdSchemes[k], row.PwdPlain[k], Self, FHashTask);
  if not Result then FHashTask := 0;
end;

function TTemplateBatchDialog.WriteRow(ARow: TBatchRow): Boolean;
var
  change: TLdapChange;
  werr: TLdapError;
  k: Integer;
begin
  change := NewChange(ckAdd, ARow.Entry.Dn);
  change.Entry.Free;
  change.Entry := ARow.Entry.Clone;
  for k := 0 to High(FHashed) do
    if k <= High(ARow.PwdAttrs) then change.Entry.Ensure(ARow.PwdAttrs[k]).AddValue(FHashed[k]);
  WipeHashed;
  // Le tire ne se remet que si la ligne est creee: garde jusqu'a la reponse, efface sinon.
  RtWipeSecret(FSentDrawn);
  for k := 0 to High(ARow.PwdDrawn) do
    if ARow.PwdDrawn[k] then FSentDrawn := string(ARow.PwdPlain[k]);
  // Le clair n'a plus d'usage: parti ou pas, il ne reste pas en memoire jusqu'a la fermeture.
  ARow.WipePasswords;
  // Write prend possession du changement, meme quand il refuse.
  Result := Tasks.Write(WRITE_TAG, change, '', werr) <> 0;
  if not Result then
  begin
    ARow.State := brsNotSent;
    ARow.Detail := ErrorToText(werr);
    Exit;
  end;
  ARow.State := brsSending;
  FList.Invalidate;
  UpdateStatus;
end;

procedure TTemplateBatchDialog.LocalMessage(AMsg: TUiMessage);
var
  pw: TPwdWorkMsg;
  row: TBatchRow;
  k: Integer;
begin
  if not (AMsg is TPwdWorkMsg) or (FHashTask = 0) or (AMsg.TaskId <> FHashTask) then Exit;
  pw := TPwdWorkMsg(AMsg);
  FHashTask := 0;
  if not FRunning or (FRunRow < 0) or (FRunRow >= FBatch.Count) then Exit;
  row := FBatch[FRunRow];
  k := Length(FHashed);
  if pw.ErrorText <> '' then
  begin
    WipeHashed;
    row.WipePasswords;
    row.State := brsNotSent;
    if k <= High(row.PwdAttrs) then row.Detail := Format(rsTbHashFailed, [row.PwdAttrs[k], pw.ErrorText])
    else row.Detail := pw.ErrorText;
    FList.Invalidate;
    SendNext;
    Exit;
  end;
  SetLength(FHashed, k + 1);
  FHashed[k] := pw.Generated;
  pw.Generated := '';
  // Stop ou session changee pendant le calcul: la ligne n'est pas partie, elle le dit.
  if FStopRequested or not SessionUnchanged then
  begin
    WipeHashed;
    row.State := brsReady;
    if FStopRequested then FinishRun(rsTbStoppedByUser) else FinishRun(rsTbSessionLostRun);
    Exit;
  end;
  if Length(FHashed) < Length(row.PwdPlain) then
  begin
    if StartRowHash then Exit;
    WipeHashed;
    row.State := brsNotSent;
    row.Detail := rsTbHashBusy;
    SendNext;
    Exit;
  end;
  if not WriteRow(row) then SendNext;
end;

procedure TTemplateBatchDialog.HandleWrite(AMsg: TUiMessage; AStale: Boolean);
var
  row: TBatchRow;
  m: TWriteMsg;
  detail: string;
  unknown, ok: Boolean;
begin
  if not FRunning or (FRunRow < 0) or (FRunRow >= FBatch.Count) then Exit;
  row := FBatch[FRunRow];
  unknown := False;
  ok := False;
  detail := '';
  if AStale then
  begin
    unknown := True;
    detail := rsTdSessionLost;
  end
  else if AMsg is TTaskFailedMsg then
  begin
    unknown := True;
    detail := TTaskFailedMsg(AMsg).Text;
  end
  else if AMsg is TWriteMsg then
  begin
    m := TWriteMsg(AMsg);
    ok := m.Result.Ok;
    if not ok then
    begin
      unknown := m.Result.Error.Category = lecUnknownOutcome;
      detail := ErrorToText(m.Result.Error);
    end;
  end
  else
    Exit;
  if FRunJoin < 0 then
  begin
    // Issue inconnue: le compte a pu naitre avec ce mot de passe. Remis, avec la reserve.
    if (ok or unknown) and (FSentDrawn <> '') then
    begin
      SetLength(FDrawn, Length(FDrawn) + 1);
      FDrawn[High(FDrawn)].Dn := row.Dn;
      FDrawn[High(FDrawn)].Account := row.Login;
      FDrawn[High(FDrawn)].Password := FSentDrawn;
      if not ok then FDrawn[High(FDrawn)].Status := rsGpToVerify;
    end;
    RtWipeSecret(FSentDrawn);
    if ok then
    begin
      row.State := brsCreated;
      if FFirstCreated = '' then FFirstCreated := row.Dn;
    end
    else if unknown then row.State := brsUnknown
    else if (AMsg is TWriteMsg) and not TWriteMsg(AMsg).Result.Sent then row.State := brsNotSent
    else row.State := brsRefused;
    row.Detail := detail;
  end
  else
  begin
    if ok then Inc(row.JoinsDone)
    else
    begin
      Inc(row.JoinsFailed);
      row.Detail := detail;
    end;
  end;
  FList.Invalidate;
  if FRunRow = FList.ItemIndex then ListSelect(FList, FRunRow);
  if unknown then
  begin
    FinishRun(rsTbUnknownStop);
    Exit;
  end;
  UpdateStatus;
  SendNext;
end;

procedure TTemplateBatchDialog.FinishRun(const AProblem: string);
var
  i, created, refused, notSent, joinRows, joinsFailed, skipRows, joinsSkipped: Integer;
  state: TUiState;
begin
  FRunning := False;
  FRan := True;
  // Ce qui n'est pas parti est dit comme tel: une ligne "prete" apres un arret mentirait.
  if AProblem <> '' then
    for i := 0 to FBatch.Count - 1 do
      if FBatch[i].State = brsReady then
      begin
        FBatch[i].State := brsNotSent;
        FBatch[i].Detail := AProblem;
      end;
  created := FBatch.CountIn(brsCreated);
  refused := FBatch.CountIn(brsRefused) + FBatch.CountIn(brsUnknown);
  notSent := FBatch.CountIn(brsNotSent);
  // Creee mais absente de ses groupes: ce n'est pas un succes, le bilan le compte. Arretee entre la
  // creation et ses inscriptions non plus.
  joinRows := 0;
  joinsFailed := 0;
  skipRows := 0;
  joinsSkipped := 0;
  for i := 0 to FBatch.Count - 1 do
  begin
    if FBatch[i].State = brsCreated then
      FBatch[i].JoinsSkipped := Max(0, Length(FRunJoins) - FBatch[i].JoinsDone - FBatch[i].JoinsFailed);
    if FBatch[i].JoinsFailed > 0 then
    begin
      Inc(joinRows);
      Inc(joinsFailed, FBatch[i].JoinsFailed);
    end;
    if FBatch[i].JoinsSkipped > 0 then
    begin
      Inc(skipRows);
      Inc(joinsSkipped, FBatch[i].JoinsSkipped);
    end;
  end;
  if AProblem = '' then
    FStatusLabel.Caption := Format(rsTbStatusDone, [created, refused, notSent])
  else
    FStatusLabel.Caption := Format(rsTbStatusStopped, [created, refused, notSent, AProblem]);
  if joinsFailed > 0 then
    FStatusLabel.Caption := FStatusLabel.Caption + ' ' + Format(rsTbStatusJoins, [joinsFailed, joinRows]);
  if joinsSkipped > 0 then
    FStatusLabel.Caption := FStatusLabel.Caption + ' ' + Format(rsTbStatusJoinsSkipped, [joinsSkipped, skipRows]);
  if (AProblem = '') and (refused = 0) and (notSent = 0) and (joinsFailed = 0) and (joinsSkipped = 0) then
  begin
    state := usOk;
    FCtx.Log(mlInfo, rsTbTitle, FStatusLabel.Caption);
  end
  else
  begin
    state := usWarning;
    FCtx.Log(mlWarning, rsTbTitle, FStatusLabel.Caption);
  end;
  FList.Invalidate;
  GroupsChanged(nil);
  UpdateStatus;
  FStatusLabel.Font.Color := DialogStateColor(state);
  if state = usOk then FStatusIcon.SetIcon('circle-check', 16, DialogStateColor(state))
  else FStatusIcon.SetIcon('alert-triangle', 16, DialogStateColor(state));
  ShowGeneratedPasswords(Self, FDrawn);
end;

procedure TTemplateBatchDialog.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask;
  AEnding: TTaskEnding);
var
  m: TEntriesMsg;
  i: Integer;
  reason: string;
begin
  if FGroups.HandleMessage(AMsg, ATask, AEnding) then Exit;
  if ATask.Tag = POLICY_TAG then
  begin
    if (AEnding <> teStale) and (AMsg is TEntryMsg) and (TEntryMsg(AMsg).Entry <> nil) then
    begin
      FBatch.Policy := AdPolicyFromDomain(TEntryMsg(AMsg).Entry);
      if not FRunning and not FRan then Recompute;
    end;
    Exit;
  end;
  if ATask.Tag = WRITE_TAG then
  begin
    HandleWrite(AMsg, AEnding = teStale);
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
    if AEnding = teStale then EndUniqueScan(rsTdReadSessionLost)
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
      else
        EndUniqueScan('');
    end;
    UpdateStatus;
    Exit;
  end;
  if (ATask.Tag <> NUMBER_TAG) or (FScan = nil) then Exit;
  if AEnding = teStale then
  begin
    EndScan(rsTdReadSessionLost);
    StartNextScan;
    UpdateStatus;
    Exit;
  end;
  if AMsg is TTaskFailedMsg then
  begin
    EndScan(TTaskFailedMsg(AMsg).Text);
    StartNextScan;
    UpdateStatus;
    Exit;
  end;
  if not (AMsg is TEntriesMsg) then Exit;
  m := TEntriesMsg(AMsg);
  if m.Entries <> nil then
    for i := 0 to m.Entries.Count - 1 do FScan.Feed(TLdapEntry(m.Entries[i]));
  if not m.Final then Exit;
  if SearchOutcome(m.Completion) <> soComplete then
  begin
    reason := ResultCodeName(m.Completion.ResultCode);
    if m.Completion.SizeLimitHit then reason := 'size limit'
    else if m.Completion.TimeLimitHit then reason := 'time limit'
    else if m.Completion.Cancelled then reason := 'cancelled';
    EndScan(reason);
  end
  else
    EndScan('');
  StartNextScan;
  UpdateStatus;
end;

function TTemplateBatchDialog.StatusText: string;
begin
  Result := FStatusLabel.Caption;
end;

function TTemplateBatchDialog.RowsText: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to FBatch.Count - 1 do
    Result := Result + GetCell(FList, i, 0) + ' | ' + GetCell(FList, i, 1) + ' | ' +
      GetCell(FList, i, 2) + LineEnding;
end;

end.
