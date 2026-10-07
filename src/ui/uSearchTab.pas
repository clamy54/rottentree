// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSearchTab;

{$mode objfpc}{$H+}

// Onglet de recherche: base, portee, filtre, attributs, pagination, limites, recherches
// enregistrees et historique. 'Aucun resultat' ne se dit complet qu'apres une fin reussie; une
// erreur apres des entrees reste un resultat partiel. Un vide affirme a tort, c'est un audit
// rate.

interface

uses
  Classes, SysUtils, Contnrs, Controls, ComCtrls, ExtCtrls, StdCtrls, Forms, Graphics, Dialogs,
  LCLType, Menus, uAppContext, uRtCombo, uRtList, uConnections, uUiInbox, uDirectoryWorker, uLdapEntry,
  uSearchModel, uSavedSearch, uTaskTracker;

resourcestring
  rsSearchBase = 'Base DN';
  rsSearchScope = 'Scope';
  rsSearchFilter = 'Filter (expert)';
  rsSearchAttrs = 'Attributes';
  rsSearchPage = 'Page size';
  rsSearchLimit = 'Size limit';
  rsSearchTime = 'Time limit (s)';
  rsSearchRun = 'Run';
  rsSearchStop = 'Stop';
  rsSearchExport = 'Export...';
  rsSearchSaved = 'Saved searches';
  rsSearchHistory = 'History';
  rsSearchSaveAs = 'Save current search...';
  rsSearchSaveName = 'Name of the saved search';
  rsSearchDeleteSaved = 'Delete';
  rsSearchNoSaved = '(no saved search for this profile)';
  rsSearchNoHistory = '(no search yet)';
  rsSearchClearHistory = 'Clear history';
  rsSearchReplaceSaved = 'A saved search named "%s" already exists. Replace it?';
  rsSearchDeleteConfirm = 'Delete the saved search "%s"?';
  rsSearchSavedOk = 'Search saved as "%s" in the document.';
  rsSearchSaveFailed = 'Search not saved: %s';
  rsSearchUnreadableSaved = '%d saved searches of this profile could not be read and are not listed.';
  rsSearchNoDocument = '(open or create a document to keep searches)';
  rsSearchBuilderOpen = 'Builder...';
  rsSearchRunning = 'Searching... %d entries';
  rsSearchComplete = 'Complete: %d entries, %d page(s).';
  rsSearchPartial = 'PARTIAL: %d entries. %s';
  rsSearchFailed = 'Failed: %s';
  rsSearchUnknownAttrs = 'The filter names attributes this server''s schema does not know: %s.';
  rsSearchCancelled = 'Cancelled after %d entries (partial).';
  rsSearchMemoryCap = 'Stopped: the results reached the memory limit (%d entries kept, partial).';
  rsSearchSessionLost = 'the connection changed during the search (partial result); run it again';

const
  // Plafond memoire des resultats gardes par l'onglet, cardinalite comprise. Au-dela on annule:
  // un annuaire trop genereux ne fera pas tomber le poste.
  SEARCH_TAB_MAX_BYTES = Int64(256) * 1024 * 1024;
  rsSearchInvalidFilter = 'Invalid filter: %s';
  rsSearchOpenHint = 'Double-click a result (or press Enter) to open the entry in its own tab.';

type
  TOpenEntryEvent = procedure(const AProfileUuid, ADn: string) of object;

  TSearchTab = class(TTabSheet)
  private
    FCtx: TAppContext;
    FProfileUuid: string;
    FBase, FFilter, FAttrs, FPage, FLimit, FTime: TEdit;
    FScope: TRtComboBox;
    FList: TRtListGrid;
    FStatus: TLabel;
    FRunFilter: string;
    FEntries: TObjectList;
    FColumns: array of string;
    FTasks: TDirectoryTasks;
    FRunning: Boolean;
    FBytes: Int64;
    FCapped: Boolean;
    FCoverage: TSearchRunState;
    FCompletion: TSearchCompletion;
    FOnOpenEntry: TOpenEntryEvent;
    FSavedBtn, FHistoryBtn: TButton;
    FSavedMenu, FHistoryMenu: TPopupMenu;
    FSavedName: string;
    procedure BuildUi;
    procedure SavedClick(Sender: TObject);
    procedure HistoryClick(Sender: TObject);
    procedure SavedItemClick(Sender: TObject);
    procedure SaveAsClick(Sender: TObject);
    procedure DeleteSavedClick(Sender: TObject);
    procedure HistoryItemClick(Sender: TObject);
    procedure ClearHistoryClick(Sender: TObject);
    procedure BuildSavedMenu;
    procedure BuildHistoryMenu;
    procedure ApplySearch(const S: TSavedSearch);
    procedure Changed;
    procedure ListActivate(Sender: TObject; AIndex: Integer);
    procedure RunClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
    procedure BuilderOpenClick(Sender: TObject);
    function ListCell(Sender: TObject; AIndex, ACol: Integer): string;
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    function Conn: TDirectoryConnection;
    function CoverageText: string;
    procedure KeyHandler(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ShowFailure(const AText: string);
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext; AConn: TDirectoryConnection;
      const ABase, AFilter: string; AScope: TSearchScope);
    destructor Destroy; override;
    procedure ApplyTheme;
    procedure Run;
    function CurrentSearch: TSavedSearch;
    function SaveSearchAs(const AName: string; out AError: string): Boolean;
    function OpenSavedSearch(const AName: string): Boolean;
    function DeleteSavedSearchNamed(const AName: string): Boolean;
    function OpenHistory(AIndex: Integer): Boolean;
    procedure ClearHistory;
    function SavedSearchNames: string;
    function HistoryText: string;
    procedure SetQuery(const ABase, AFilter, AAttrs: string; AScope: TSearchScope);
    function FilterText: string;
    function BaseText: string;
    function SearchTask: Int64;
    function StatusText: string;
    property OnOpenEntry: TOpenEntryEvent read FOnOpenEntry write FOnOpenEntry;
  end;

implementation

uses
  uTheme, uUiKit, uLdapFilter, uLdapErrors, uRtBytes, uExportActions, uSearchLibrary, uRtMessage,
  uFilterBuilderDialog, uMenuBar, uDirectoryService;

constructor TSearchTab.CreateFor(AOwner: TComponent; ACtx: TAppContext; AConn: TDirectoryConnection;
  const ABase, AFilter: string; AScope: TSearchScope);
begin
  inherited Create(AOwner);
  FCtx := ACtx;
  FProfileUuid := AConn.Profile.Uuid;
  FEntries := TObjectList.Create(True);
  Caption := 'Search - ' + AConn.Profile.Name;
  BuildUi;
  FBase.Text := ABase;
  if AFilter <> '' then FFilter.Text := AFilter;
  FScope.ItemIndex := Ord(AScope);
  FPage.Text := IntToStr(AConn.Profile.PageSize);
  FLimit.Text := IntToStr(AConn.Profile.SizeLimit);
  FTime.Text := IntToStr(AConn.Profile.OperationTimeoutSec);
  FTasks := TDirectoryTasks.Create(FCtx.Connections, FProfileUuid, Self);
  FTasks.OnMessage := @TaskMessage;
  ApplyTheme;
end;

destructor TSearchTab.Destroy;
begin
  if FTasks <> nil then FTasks.Cancel('search');
  FreeAndNil(FTasks);
  FEntries.Free;
  inherited Destroy;
end;

function TSearchTab.Conn: TDirectoryConnection;
begin
  Result := FCtx.Connections.Find(FProfileUuid);
end;

procedure TSearchTab.BuildUi;
var
  form, row, bar: TPanel;

  function Field(AParent: TWinControl; const ACaption: string; AWidth: Integer;
    AAlign: TAlign = alLeft): TEdit;
  var
    lbl: TLabel;
  begin
    lbl := MakeLabel(AParent, ACaption, alLeft);
    lbl.Layout := tlCenter;
    Result := TEdit.Create(AParent);
    Result.Parent := AParent;
    Result.Align := AAlign;
    Result.Width := AWidth;
    Result.BorderSpacing.Around := 3;
    Result.OnKeyDown := @KeyHandler;
  end;

  function RightField(AParent: TWinControl; const ACaption: string; AWidth: Integer): TEdit;
  var
    lbl: TLabel;
  begin
    Result := TEdit.Create(AParent);
    Result.Parent := AParent;
    Result.Align := alRight;
    Result.Width := AWidth;
    Result.BorderSpacing.Around := 3;
    Result.OnKeyDown := @KeyHandler;
    lbl := MakeLabel(AParent, ACaption, alRight);
    lbl.Layout := tlCenter;
  end;

begin
  form := MakePanel(Self, alTop, 110);
  form.ParentColor := False;
  form.AutoSize := True;
  row := MakePanel(form, alTop, 34);
  FAttrs := RightField(row, rsSearchAttrs, 280);
  FAttrs.Text := 'cn,objectClass';
  FScope := MakeCombo(row, ['base', 'oneLevel', 'subtree'], alRight);
  FScope.Width := 110;
  MakeLabel(row, rsSearchScope, alRight).Layout := tlCenter;
  FBase := Field(row, rsSearchBase, 360, alClient);
  row := MakePanel(form, alTop, 34);
  FTime := RightField(row, rsSearchTime, 60);
  FLimit := RightField(row, rsSearchLimit, 80);
  FPage := RightField(row, rsSearchPage, 70);
  MakeButton(row, rsSearchBuilderOpen, @BuilderOpenClick, alRight);
  FFilter := Field(row, rsSearchFilter, 480, alClient);
  FFilter.Text := '(objectClass=*)';
  bar := MakePanel(Self, alTop, 36);
  MakeButton(bar, rsSearchRun, @RunClick);
  MakeButton(bar, rsSearchStop, @StopClick);
  MakeButton(bar, rsSearchExport, @ExportClick);
  FSavedBtn := MakeButton(bar, rsSearchSaved + ' ' + #$E2#$96#$BE, @SavedClick);
  FHistoryBtn := MakeButton(bar, rsSearchHistory + ' ' + #$E2#$96#$BE, @HistoryClick);
  FSavedMenu := TPopupMenu.Create(Self);
  FHistoryMenu := TPopupMenu.Create(Self);
  FStatus := MakeLabel(bar, rsSearchOpenHint, alClient);
  FStatus.Layout := tlCenter;
  FList := TRtListGrid.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.OnGetCell := @ListCell;
  FList.FillWidth := True;
  FList.OnActivateRow := @ListActivate;
  FList.AddColumn('DN', 420);
end;

procedure TSearchTab.ListActivate(Sender: TObject; AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FEntries.Count) then Exit;
  if Assigned(FOnOpenEntry) then
    FOnOpenEntry(FProfileUuid, TLdapEntry(FEntries[AIndex]).Dn);
end;

procedure TSearchTab.ApplyTheme;
begin
  ThemeControlTree(Self);
  ArrangeByCreation(Self);
  FList.Color := clAppBg;
  FList.Font.Color := clAppFg;
  FList.RefreshMetrics;
end;

procedure TSearchTab.KeyHandler(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_RETURN) and ((ssCtrl in Shift) or (ssMeta in Shift)) then
  begin
    RunClick(Sender);
    Key := 0;
  end
  else if Key = VK_ESCAPE then
  begin
    StopClick(Sender);
    Key := 0;
  end;
end;

procedure TSearchTab.BuilderOpenClick(Sender: TObject);
var
  f: string;
begin
  f := FFilter.Text;
  if EditFilterGraphically(GetParentForm(Self), FCtx, FProfileUuid, f) then
    FFilter.Text := f;
end;

procedure TSearchTab.RunClick(Sender: TObject);
var
  c: TDirectoryConnection;
  req: TSearchRequest;
  err: string;
  f: TFilterNode;
  parts: TStringArray;
  i: Integer;
begin
  c := Conn;
  if (c = nil) or not c.IsReady then Exit;
  f := FilterParse(FFilter.Text, err);
  if f = nil then
  begin
    FStatus.Caption := Format(rsSearchInvalidFilter, [err]);
    FStatus.Font.Color := clCodeInvalid;
    Exit;
  end;
  f.Free;
  FTasks.Cancel('search');
  FEntries.Clear;
  FList.Count := 0;
  req := DefaultSearchRequest;
  req.BaseDn := Trim(FBase.Text);
  req.Scope := TSearchScope(FScope.ItemIndex);
  req.Filter := FFilter.Text;
  parts := string(FAttrs.Text).Split([',', ' '], TStringSplitOptions.ExcludeEmpty);
  SetLength(req.Attributes, Length(parts));
  for i := 0 to High(parts) do
    req.Attributes[i] := Trim(parts[i]);
  req.PageSize := StrToIntDef(FPage.Text, 500);
  if req.PageSize < 1 then req.PageSize := 500;
  FPage.Text := IntToStr(req.PageSize);
  req.SizeLimit := StrToIntDef(FLimit.Text, 10000);
  if req.SizeLimit < 0 then req.SizeLimit := 10000;
  FLimit.Text := IntToStr(req.SizeLimit);
  req.TimeLimitSec := StrToIntDef(FTime.Text, 30);
  if req.TimeLimitSec < 0 then req.TimeLimitSec := 30;
  FTime.Text := IntToStr(req.TimeLimitSec);
  FBytes := 0;
  FCapped := False;
  FList.ClearColumns;
  FList.AddColumn('DN', 420);
  SetLength(FColumns, Length(req.Attributes));
  for i := 0 to High(req.Attributes) do
  begin
    FColumns[i] := req.Attributes[i];
    FList.AddColumn(req.Attributes[i], 180);
  end;
  FRunning := True;
  FCoverage := srsRunning;
  FCompletion := Default(TSearchCompletion);
  FStatus.Font.Color := clAppFg;
  FStatus.Caption := Format(rsSearchRunning, [0]);
  FStatus.Hint := '';
  FRunFilter := req.Filter;
  if (FTasks.Search('search', req, True) <> 0) and (FCtx.Document <> nil) then
  begin
    RecordSearchHistory(FCtx.Document, FProfileUuid, CurrentSearch);
    Changed;
  end;
end;

procedure TSearchTab.Run;
begin
  RunClick(nil);
  if FList.CanFocus then
    FList.SetFocus;
end;

procedure TSearchTab.StopClick(Sender: TObject);
begin
  if not FRunning then Exit;
  FTasks.Stop('search');
end;

function TSearchTab.SearchTask: Int64;
begin
  Result := FTasks.TaskOf('search');
end;

function TSearchTab.FilterText: string;
begin
  Result := FFilter.Text;
end;

function TSearchTab.BaseText: string;
begin
  Result := FBase.Text;
end;

procedure TSearchTab.SetQuery(const ABase, AFilter, AAttrs: string; AScope: TSearchScope);
begin
  FBase.Text := ABase;
  FFilter.Text := AFilter;
  FAttrs.Text := AAttrs;
  FScope.ItemIndex := Ord(AScope);
end;

procedure TSearchTab.Changed;
begin
  FCtx.StatusChanged;
end;

function TSearchTab.CurrentSearch: TSavedSearch;
begin
  Result := Default(TSavedSearch);
  Result.Name := FSavedName;
  Result.BaseDn := Trim(FBase.Text);
  if FScope.ItemIndex in [0..2] then Result.Scope := TSearchScope(FScope.ItemIndex)
  else Result.Scope := ssSubtree;
  Result.Filter := FFilter.Text;
  Result.Attributes := Trim(FAttrs.Text);
  Result.PageSize := StrToIntDef(FPage.Text, 500);
  Result.SizeLimit := StrToIntDef(FLimit.Text, 10000);
  Result.TimeLimitSec := StrToIntDef(FTime.Text, 30);
end;

procedure TSearchTab.ApplySearch(const S: TSavedSearch);
begin
  FBase.Text := S.BaseDn;
  FScope.ItemIndex := Ord(S.Scope);
  FFilter.Text := S.Filter;
  FAttrs.Text := S.Attributes;
  FPage.Text := IntToStr(S.PageSize);
  FLimit.Text := IntToStr(S.SizeLimit);
  FTime.Text := IntToStr(S.TimeLimitSec);
end;

function TSearchTab.SaveSearchAs(const AName: string; out AError: string): Boolean;
var
  s: TSavedSearch;
begin
  s := CurrentSearch;
  s.Name := Trim(AName);
  Result := StoreSavedSearch(FCtx.Document, FProfileUuid, s, AError);
  if not Result then Exit;
  FSavedName := s.Name;
  Changed;
  FCtx.Log(mlInfo, Caption, Format(rsSearchSavedOk, [s.Name]));
end;

function TSearchTab.OpenSavedSearch(const AName: string): Boolean;
var
  s: TSavedSearch;
begin
  Result := FindSavedSearch(FCtx.Document, FProfileUuid, AName, s);
  if not Result then Exit;
  FSavedName := s.Name;
  ApplySearch(s);
  Run;
end;

function TSearchTab.DeleteSavedSearchNamed(const AName: string): Boolean;
begin
  Result := DeleteSavedSearch(FCtx.Document, FProfileUuid, AName);
  if not Result then Exit;
  if SameText(FSavedName, AName) then FSavedName := '';
  Changed;
end;

function TSearchTab.OpenHistory(AIndex: Integer): Boolean;
var
  list: TSavedSearches;
begin
  list := LoadSearchHistory(FCtx.Document, FProfileUuid);
  Result := (AIndex >= 0) and (AIndex <= High(list));
  if not Result then Exit;
  ApplySearch(list[AIndex]);
  Run;
end;

procedure TSearchTab.ClearHistory;
begin
  if FCtx.Document = nil then Exit;
  ClearSearchHistory(FCtx.Document, FProfileUuid);
  Changed;
end;

function TSearchTab.SavedSearchNames: string;
var
  list: TSavedSearchItems;
  bad, i: Integer;
begin
  Result := '';
  list := LoadSavedSearches(FCtx.Document, FProfileUuid, bad);
  for i := 0 to High(list) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + list[i].Search.Name;
  end;
end;

function TSearchTab.HistoryText: string;
var
  list: TSavedSearches;
  i: Integer;
begin
  Result := '';
  list := LoadSearchHistory(FCtx.Document, FProfileUuid);
  for i := 0 to High(list) do
    Result := Result + list[i].Filter + LineEnding;
end;

procedure PopupUnder(AMenu: TPopupMenu; AButton: TControl);
var
  pt: TPoint;
begin
  pt := AButton.ClientToScreen(Point(0, AButton.Height));
  ThemePopupMenu(AMenu);
  AMenu.PopUp(pt.X, pt.Y);
end;

function AddItem(AParent: TMenuItem; const ACaption: string; AOnClick: TNotifyEvent;
  ATag: PtrInt = 0): TMenuItem;
begin
  Result := TMenuItem.Create(AParent);
  Result.Caption := ACaption;
  Result.OnClick := AOnClick;
  Result.Tag := ATag;
  AParent.Add(Result);
end;

procedure TSearchTab.BuildSavedMenu;
var
  list: TSavedSearchItems;
  bad, i: Integer;
  del, it: TMenuItem;
begin
  FSavedMenu.Items.Clear;
  if FCtx.Document = nil then
  begin
    AddItem(FSavedMenu.Items, rsSearchNoDocument, nil).Enabled := False;
    Exit;
  end;
  list := LoadSavedSearches(FCtx.Document, FProfileUuid, bad);
  if bad > 0 then
    FCtx.Log(mlWarning, Caption, Format(rsSearchUnreadableSaved, [bad]));
  if Length(list) = 0 then
    AddItem(FSavedMenu.Items, rsSearchNoSaved, nil).Enabled := False;
  for i := 0 to High(list) do
  begin
    it := AddItem(FSavedMenu.Items, StringReplace(list[i].Search.Name, '&', '&&', [rfReplaceAll]),
      @SavedItemClick, i);
    it.Hint := list[i].Search.Filter;
  end;
  AddItem(FSavedMenu.Items, '-', nil);
  AddItem(FSavedMenu.Items, rsSearchSaveAs, @SaveAsClick);
  if Length(list) > 0 then
  begin
    del := AddItem(FSavedMenu.Items, rsSearchDeleteSaved, nil);
    for i := 0 to High(list) do
      AddItem(del, StringReplace(list[i].Search.Name, '&', '&&', [rfReplaceAll]), @DeleteSavedClick, i);
  end;
end;

procedure TSearchTab.BuildHistoryMenu;
var
  list: TSavedSearches;
  i: Integer;
begin
  FHistoryMenu.Items.Clear;
  if FCtx.Document = nil then
  begin
    AddItem(FHistoryMenu.Items, rsSearchNoDocument, nil).Enabled := False;
    Exit;
  end;
  list := LoadSearchHistory(FCtx.Document, FProfileUuid);
  if Length(list) = 0 then
    AddItem(FHistoryMenu.Items, rsSearchNoHistory, nil).Enabled := False;
  for i := 0 to High(list) do
    AddItem(FHistoryMenu.Items, SavedSearchCaption(list[i]), @HistoryItemClick, i);
  if Length(list) > 0 then
  begin
    AddItem(FHistoryMenu.Items, '-', nil);
    AddItem(FHistoryMenu.Items, rsSearchClearHistory, @ClearHistoryClick);
  end;
end;

procedure TSearchTab.SavedClick(Sender: TObject);
begin
  BuildSavedMenu;
  PopupUnder(FSavedMenu, FSavedBtn);
end;

procedure TSearchTab.HistoryClick(Sender: TObject);
begin
  BuildHistoryMenu;
  PopupUnder(FHistoryMenu, FHistoryBtn);
end;

function SavedNameAt(ACtx: TAppContext; const AProfileUuid: string; AIndex: Integer): string;
var
  list: TSavedSearchItems;
  bad: Integer;
begin
  Result := '';
  list := LoadSavedSearches(ACtx.Document, AProfileUuid, bad);
  if (AIndex >= 0) and (AIndex <= High(list)) then Result := list[AIndex].Search.Name;
end;

procedure TSearchTab.SavedItemClick(Sender: TObject);
var
  nm: string;
begin
  nm := SavedNameAt(FCtx, FProfileUuid, TMenuItem(Sender).Tag);
  if nm <> '' then OpenSavedSearch(nm);
end;

procedure TSearchTab.SaveAsClick(Sender: TObject);
var
  nm, err: string;
  existing: TSavedSearch;
begin
  nm := FSavedName;
  if not RtInputQuery(rsSearchSaved, rsSearchSaveName, nm) or (Trim(nm) = '') then Exit;
  if FindSavedSearch(FCtx.Document, FProfileUuid, nm, existing) and
     (RtMessageDlg(rsSearchSaved, Format(rsSearchReplaceSaved, [existing.Name]), mtConfirmation,
       [mbYes, mbNo], 0) <> mrYes) then
    Exit;
  if not SaveSearchAs(nm, err) then
    RtMessageDlg(rsSearchSaved, Format(rsSearchSaveFailed, [err]), mtError, [mbOK], 0);
end;

procedure TSearchTab.DeleteSavedClick(Sender: TObject);
var
  nm: string;
begin
  nm := SavedNameAt(FCtx, FProfileUuid, TMenuItem(Sender).Tag);
  if nm = '' then Exit;
  if RtMessageDlg(rsSearchSaved, Format(rsSearchDeleteConfirm, [nm]), mtConfirmation,
      [mbYes, mbNo], 0) <> mrYes then
    Exit;
  DeleteSavedSearchNamed(nm);
end;

procedure TSearchTab.HistoryItemClick(Sender: TObject);
begin
  OpenHistory(TMenuItem(Sender).Tag);
end;

procedure TSearchTab.ClearHistoryClick(Sender: TObject);
begin
  ClearHistory;
end;

function TSearchTab.ListCell(Sender: TObject; AIndex, ACol: Integer): string;
var
  e: TLdapEntry;
  k: Integer;
  a: TLdapAttribute;
begin
  Result := '';
  if (AIndex < 0) or (AIndex >= FEntries.Count) then Exit;
  e := TLdapEntry(FEntries[AIndex]);
  if ACol = 0 then Exit(e.Dn);
  if ACol - 1 > High(FColumns) then Exit;
  a := e.Find(FColumns[ACol - 1]);
  if a = nil then Exit;
  if FCtx.Sensitive.IsSensitive(a.Description) then Exit('[masked]');
  for k := 0 to a.ValueCount - 1 do
  begin
    if k > 0 then Result := Result + ' | ';
    if IsValidUtf8(a.Values[k]) then
      Result := Result + EscapeControlChars(a.Values[k])
    else
      Result := Result + '[' + IntToStr(Length(a.Values[k])) + ' bytes]';
    if Length(Result) > 512 then Break;
  end;
end;

function TSearchTab.CoverageText: string;
begin
  Result := CoverageDescription(FCoverage, FCompletion);
end;

procedure TSearchTab.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
var
  m: TEntriesMsg;
  e: TLdapEntry;
  reasons: string;
begin
  if AEnding = teStale then
  begin
    FRunning := False;
    FCoverage := srsFailed;
    ShowFailure(rsSearchSessionLost);
    Exit;
  end;
  if AMsg is TTaskFailedMsg then
  begin
    FRunning := False;
    FCoverage := srsFailed;
    ShowFailure(TTaskFailedMsg(AMsg).Text);
    Exit;
  end;
  if not (AMsg is TEntriesMsg) then Exit;
  m := TEntriesMsg(AMsg);
  if not FCapped then
  begin
    m.Entries.OwnsObjects := False;
    while m.Entries.Count > 0 do
    begin
      e := TLdapEntry(m.Entries[0]);
      Inc(FBytes, e.MemoryCost);
      FEntries.Add(e);
      m.Entries.Delete(0);
    end;
    // Plafond atteint: annulation cote serveur, sinon le producteur continuerait de lire et de
    // publier dans le vide. Les lots deja en file sont jetes a l'arrivee.
    if FBytes > SEARCH_TAB_MAX_BYTES then
    begin
      FCapped := True;
      FTasks.Stop('search');
      FStatus.Caption := Format(rsSearchMemoryCap, [FEntries.Count]);
      FStatus.Font.Color := clDiffWarning;
    end;
  end;
  FList.Count := FEntries.Count;
  if not m.Final then
  begin
    if not FCapped then
      FStatus.Caption := Format(rsSearchRunning, [FEntries.Count]);
    Exit;
  end;
  FRunning := False;
  FCompletion := m.Completion;
  FCoverage := srsDone;
  if FCapped then
  begin
    FStatus.Caption := Format(rsSearchMemoryCap, [FEntries.Count]);
    FStatus.Font.Color := clDiffWarning;
    Exit;
  end;
  case SearchOutcome(m.Completion) of
    soComplete:
      begin
        FStatus.Caption := Format(rsSearchComplete, [FEntries.Count, m.Completion.PageCount]);
        FStatus.Font.Color := clDiffEqual;
      end;
    soCancelled:
      begin
        FStatus.Caption := Format(rsSearchCancelled, [FEntries.Count]);
        FStatus.Font.Color := clDiffWarning;
      end;
    soFailed:
      begin
        ShowFailure(ErrorToText(m.Error));
      end;
  else
    begin
      reasons := ResultCodeName(m.Completion.ResultCode);
      if m.Completion.SizeLimitHit then reasons := reasons + ', server size limit';
      if m.Completion.ClientLimitHit then reasons := reasons + ', client size limit';
      if m.Completion.TimeLimitHit then reasons := reasons + ', time limit';
      if m.Completion.ContinuationsIgnored > 0 then
        reasons := reasons + Format(', %d referrals not followed', [m.Completion.ContinuationsIgnored]);
      if m.Completion.PagingAnomaly <> '' then reasons := reasons + ', ' + m.Completion.PagingAnomaly;
      if m.Completion.RangeIncomplete then reasons := reasons + ', incomplete attribute ranges';
      if m.Completion.DecodeFailures > 0 then
        reasons := reasons + Format(', %d entries not decoded', [m.Completion.DecodeFailures]);
      if m.Completion.TruncatedEntries > 0 then
        reasons := reasons + Format(', %d entries with omitted values', [m.Completion.TruncatedEntries]);
      FStatus.Caption := Format(rsSearchPartial, [FEntries.Count, reasons]);
      FStatus.Font.Color := clDiffWarning;
    end;
  end;
end;

// Le diagnostic d'ApacheDS tient sur plusieurs lignes, trace Java comprise: une ligne dans la
// barre, le reste en info-bulle et au journal. Les attributs du filtre inconnus du schema passent
// en tete: ApacheDS refuse un tel filtre par une erreur 36 sans dire lequel.
procedure TSearchTab.ShowFailure(const AText: string);
var
  c: TDirectoryConnection;
  unknown: TStringArray;
  msg: string;
begin
  msg := Format(rsSearchFailed, [AText]);
  unknown := nil;
  c := Conn;
  if c <> nil then unknown := FilterUnknownAttributes(FRunFilter, c.Schema);
  if Length(unknown) > 0 then
    msg := Format(rsSearchUnknownAttrs, [string.Join(', ', unknown)]) + ' ' + msg;
  FStatus.Caption := OneLineText(msg);
  FStatus.Hint := msg;
  FStatus.ShowHint := True;
  FStatus.Font.Color := clCodeInvalid;
  FCtx.Log(mlError, Caption, msg);
end;

function TSearchTab.StatusText: string;
begin
  Result := FStatus.Caption;
end;

procedure TSearchTab.ExportClick(Sender: TObject);
var
  coverage: string;
begin
  coverage := CoverageText;
  ExportEntryList(GetParentForm(Self), FCtx, FEntries, FColumns, coverage);
end;

end.
