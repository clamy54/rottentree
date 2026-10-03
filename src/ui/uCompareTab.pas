// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCompareTab;

{$mode objfpc}{$H+}

// Onglet de comparaison: 2 a 16 annuaires ou exports LDIF, sur des sessions reservees. Verdict, matrice,
// differences jusqu'a la valeur; les valeurs sensibles restent masquees sauf choix explicite. Aucun bouton
// d'ecriture: on constate les ecarts, on ne les repare pas.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, ExtCtrls, StdCtrls, Forms, Graphics, Dialogs, CheckLst,
  uAppContext, uRtCombo, uRtList, uUiInbox, uCompareModel, uCompareRunner, uProfileCatalog,
  uConnectionProfile, uRtCheck;

type
  TCompareTab = class(TTabSheet)
  private
    FCtx: TAppContext;
    FCatalog: TProfileCatalog;
    FProfileUuid: string;
    FSourceUuids: TStringList;
    FBaseByUuid: TStringList;
    FLdifProfiles: TFPList;
    FRun: TComparisonRun;
    FResult: TCompareRunResult;
    FSaved: TRtComboBox;
    FName, FBase, FBusinessKey, FFilter, FInclude, FSample, FDelay, FWindow, FMemory, FQuota: TEdit;
    FSources: TCheckListBox;
    FTopology, FReference, FMode, FStrictness, FIdentity, FScope: TRtComboBox;
    FExclude: TMemo;
    FOperational, FRewriteDn, FSecondPass, FAclAttest, FReveal: TRtCheckBox;
    FRunBtn, FStopBtn, FExportBtn: TButton;
    FHeadline, FAxes, FProgress: TLabel;
    FCaveat: TLabel;
    FResultPages: TPageControl;
    FMatrix, FDiffs: TRtListGrid;
    FDetail, FIndicators, FNotes: TMemo;
    procedure BuildUi;
    procedure FillProfiles;
    procedure FillSaved;
    procedure SourcesClick(Sender: TObject);
    procedure SourcesCheck(Sender: TObject);
    procedure BaseChange(Sender: TObject);
    procedure AddLdifClick(Sender: TObject);
    procedure RefreshReferences;
    function BuildProfile(AProfile: TComparisonProfile; out AErrors: TStringArray): Boolean;
    procedure LoadIntoUi(AProfile: TComparisonProfile);
    procedure RunClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure LoadClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
    function DiffsCell(Sender: TObject; AIndex, ACol: Integer): string;
    procedure DiffsSelect(Sender: TObject; AIndex: Integer);
    procedure RevealClick(Sender: TObject);
    procedure HandleMessage(AMsg: TUiMessage);
    procedure ShowResult;
    procedure ShowDetail(AIndex: Integer);
    procedure StopRun(AWaitMs: Integer);
    function ProfileByUuid(const AUuid: string): TConnectionProfile;
    function AskSecretFor(AProfile: TConnectionProfile; out ASecret: RawByteString): Boolean;
    procedure SetRunning(ARunning: Boolean);
  public
    function AddLdifSource(const APath: string): Integer;
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext; ACatalog: TProfileCatalog);
    destructor Destroy; override;
    procedure ApplyTheme;
  end;

implementation

uses
  fpjson, jsonparser, uTheme, uUiKit, uCompareEngine, uCanonical, uSensitive,
  uCompareReport, uRtDocument, uDocDialogs, uSearchModel, uCsn, uRtBytes, uSafeSave,
  uStrings, uCancel, uConnectFlow, uRtMessage, uDocumentCrypto;

resourcestring
  rsCmpCaption = 'Compare';
  rsCmpSaved = 'Saved comparison';
  rsCmpLoad = 'Load';
  rsCmpSave = 'Save';
  rsCmpDelete = 'Delete';
  rsCmpName = 'Name';
  rsCmpSources = 'Directories (2 to 16)';
  rsCmpBase = 'Base DN of the selected directory';
  rsCmpAllSources = 'all sources';
  rsCmpLdifBaseHint = 'empty: the base of another source, if the file holds it';
  rsCmpServerBaseHint = 'empty: the base of another source within this server, else its naming context';
  rsCmpTopology = 'Topology';
  rsCmpReference = 'Reference';
  rsCmpMode = 'Level';
  rsCmpStrictness = 'Values';
  rsCmpIdentity = 'Entry identity';
  rsCmpBusinessKey = 'Business key attribute';
  rsCmpScope = 'Scope';
  rsCmpFilter = 'Common filter';
  rsCmpInclude = 'Included attributes (empty = all user attributes)';
  rsCmpExclude = 'Excluded attributes (one per line)';
  rsCmpOperational = 'Include operational attributes';
  rsCmpRewriteDn = 'Rewrite DN-syntax values between bases (explicit option)';
  rsCmpSecondPass = 'Read differences again after the delays';
  rsCmpAclAttest = 'I attest that all identities see equivalent data (hypothesis)';
  rsCmpSample = 'Sample size';
  rsCmpDelay = 'Second pass delay (s)';
  rsCmpWindow = 'Stabilization window (s)';
  rsCmpMemory = 'Memory budget (MiB)';
  rsCmpQuota = 'Encrypted temporary quota (MiB)';
  rsCmpRun = 'Run comparison';
  rsCmpStop = 'Stop';
  rsCmpExport = 'Export report...';
  rsCmpReveal = 'Show sensitive values in details';
  rsCmpNoResult = 'No comparison has been run yet.';
  rsCmpInvalid = 'The comparison cannot start:';
  rsCmpRunning = 'Running...';
  rsCmpProgress = '%s: %s %d';
  rsCmpDirectories = 'Directories';
  rsCmpDifferences = 'Differences';
  rsCmpIndicators = 'Replication indicators';
  rsCmpNotes = 'Notes';
  rsCmpRevealConfirm = 'Sensitive attribute values will be displayed on screen. Continue?';
  rsCmpExportSensitive = 'Include sensitive attribute values in the report? The default is No (masked).';
  rsCmpSavedOk = 'Comparison profile saved in the document (not yet written to disk).';
  rsCmpDeleteConfirm = 'Delete the saved comparison "%s"?';
  rsCmpStopFirst = 'Stop the running comparison first.';
  rsCmpProfileMissing = 'Connection profile not found: %s';
  rsCmpNotObserved = 'not observed';
  rsCmpMasked = 'Values of sensitive attributes are masked.';
  rsCmpAddLdif = 'Add LDIF file...';
  rsCmpLdifFilter = 'LDIF files (*.ldif;*.ldf;*.ldi)|*.ldif;*.ldf;*.ldi|All files|*.*';

const
  TOPOLOGY_ITEMS: array[0..1] of string = ('Symmetric group', 'Designated reference');
  MODE_ITEMS: array[0..2] of string = ('Indicators', 'Sample', 'Full');
  STRICT_ITEMS: array[0..1] of string = ('Strict (byte for byte)', 'Semantic (supported rules only)');
  IDENTITY_ITEMS: array[0..3] of string = ('DN relative to base', 'entryUUID (replicas)',
    'objectGUID (Active Directory replicas)', 'Business key');
  SCOPE_ITEMS: array[0..2] of string = ('base', 'oneLevel', 'subtree');

constructor TCompareTab.CreateFor(AOwner: TComponent; ACtx: TAppContext; ACatalog: TProfileCatalog);
var
  p: TComparisonProfile;
begin
  inherited Create(AOwner);
  FCtx := ACtx;
  FCatalog := ACatalog;
  FSourceUuids := TStringList.Create;
  FBaseByUuid := TStringList.Create;
  FLdifProfiles := TFPList.Create;
  Caption := rsCmpCaption;
  BuildUi;
  FillProfiles;
  FillSaved;
  p := TComparisonProfile.Create;
  try
    LoadIntoUi(p);
  finally
    p.Free;
  end;
  UiInbox.Subscribe(Self, @HandleMessage);
  ApplyTheme;
end;

destructor TCompareTab.Destroy;
var
  i: Integer;
begin
  UiInbox.Unsubscribe(Self);
  // Attente bornee par l'echeance commune: une comparaison coincee en connexion ne retient jamais
  // l'interface en otage.
  StopRun(FCtx.ShutdownWaitMs(3000));
  FResult.Free;
  FSourceUuids.Free;
  FBaseByUuid.Free;
  for i := 0 to FLdifProfiles.Count - 1 do
    TConnectionProfile(FLdifProfiles[i]).Free;
  FLdifProfiles.Free;
  inherited Destroy;
end;

procedure TCompareTab.StopRun(AWaitMs: Integer);
begin
  if FRun = nil then Exit;
  FRun.Cancel;
  if AWaitMs >= 0 then
  begin
    FRun.Release(AWaitMs);
    FRun := nil;
  end;
end;

function Row(AParent: TWinControl; const ACaption: string): TPanel;
begin
  Result := MakeFieldRow(AParent, ACaption, 190);
end;

function RowEdit(AParent: TWinControl; const ACaption: string): TEdit;
var
  r: TPanel;
begin
  r := Row(AParent, ACaption);
  Result := TEdit.Create(r);
  Result.Parent := r;
  Result.Align := alClient;
  Result.BorderSpacing.Around := 2;
end;

function RowCombo(AParent: TWinControl; const ACaption: string; const AItems: array of string): TRtComboBox;
var
  r: TPanel;
  i: Integer;
begin
  r := Row(AParent, ACaption);
  Result := TRtComboBox.Create(r);
  Result.Parent := r;
  Result.Align := alClient;
  Result.Style := csDropDownList;
  Result.BorderSpacing.Around := 2;
  for i := 0 to High(AItems) do
    Result.Items.Add(AItems[i]);
  if Result.Items.Count > 0 then Result.ItemIndex := 0;
end;

procedure TCompareTab.BuildUi;
var
  pLeft, bar, savedRow, pRight, pTop: TPanel;
  scroll: TScrollBox;
  content: TPanel;
  splitter: TSplitter;
  ts: TTabSheet;
  diffBody: TPanel;
  lbl: TLabel;
begin
  pLeft := MakePanel(Self, alLeft, 470);
  bar := MakePanel(pLeft, alBottom, 40);
  FRunBtn := MakeButton(bar, rsCmpRun, @RunClick);
  FStopBtn := MakeButton(bar, rsCmpStop, @StopClick);
  FStopBtn.Enabled := False;
  FExportBtn := MakeButton(bar, rsCmpExport, @ExportClick);
  FExportBtn.Enabled := False;
  scroll := TScrollBox.Create(pLeft);
  scroll.Parent := pLeft;
  scroll.Align := alClient;
  scroll.HorzScrollBar.Visible := False;
  scroll.VertScrollBar.Tracking := True;
  scroll.BorderStyle := bsNone;
  // Un seul enfant a hauteur automatique, la boite ne fait que defiler. Des dizaines de lignes posees
  // directement dedans faisaient boucler Cocoa (InvalidatePreferredSize loop detected), qui recalculait
  // la plage de defilement jusqu'a la fin des temps.
  content := TPanel.Create(scroll);
  content.Parent := scroll;
  content.Align := alTop;
  content.BevelOuter := bvNone;
  content.Caption := '';
  content.AutoSize := True;

  savedRow := Row(content, rsCmpSaved);
  FSaved := TRtComboBox.Create(savedRow);
  FSaved.Parent := savedRow;
  FSaved.Align := alClient;
  FSaved.Style := csDropDownList;
  MakeButton(savedRow, rsCmpDelete, @DeleteClick, alRight);
  MakeButton(savedRow, rsCmpLoad, @LoadClick, alRight);
  FName := RowEdit(content, rsCmpName);
  MakeButton(Row(content, ''), rsCmpSave, @SaveClick, alLeft);

  lbl := MakeLabel(content, rsCmpSources);
  StackTop(lbl);
  FSources := TCheckListBox.Create(content);
  FSources.Parent := content;
  FSources.Align := alTop;
  FSources.Height := 150;
  StackTop(FSources);
  FSources.OnClick := @SourcesClick;
  FSources.OnClickCheck := @SourcesCheck;
  MakeButton(Row(content, ''), rsCmpAddLdif, @AddLdifClick, alLeft);
  FBase := RowEdit(content, rsCmpBase);
  FBase.OnChange := @BaseChange;
  FTopology := RowCombo(content, rsCmpTopology, TOPOLOGY_ITEMS);
  FTopology.OnChange := @SourcesCheck;
  FReference := RowCombo(content, rsCmpReference, []);
  FMode := RowCombo(content, rsCmpMode, MODE_ITEMS);
  FStrictness := RowCombo(content, rsCmpStrictness, STRICT_ITEMS);
  FIdentity := RowCombo(content, rsCmpIdentity, IDENTITY_ITEMS);
  FBusinessKey := RowEdit(content, rsCmpBusinessKey);
  FScope := RowCombo(content, rsCmpScope, SCOPE_ITEMS);
  FFilter := RowEdit(content, rsCmpFilter);
  FInclude := RowEdit(content, rsCmpInclude);
  lbl := MakeLabel(content, rsCmpExclude);
  StackTop(lbl);
  FExclude := TMemo.Create(content);
  FExclude.Parent := content;
  FExclude.Align := alTop;
  FExclude.Height := 120;
  FExclude.ScrollBars := ssAutoVertical;
  StackTop(FExclude);
  FOperational := MakeCheck(content, rsCmpOperational);
  StackTop(FOperational);
  FRewriteDn := MakeCheck(content, rsCmpRewriteDn);
  StackTop(FRewriteDn);
  FSecondPass := MakeCheck(content, rsCmpSecondPass);
  StackTop(FSecondPass);
  FAclAttest := MakeCheck(content, rsCmpAclAttest);
  StackTop(FAclAttest);
  FSample := RowEdit(content, rsCmpSample);
  FDelay := RowEdit(content, rsCmpDelay);
  FWindow := RowEdit(content, rsCmpWindow);
  FMemory := RowEdit(content, rsCmpMemory);
  FQuota := RowEdit(content, rsCmpQuota);

  splitter := TSplitter.Create(Self);
  splitter.Parent := Self;
  splitter.Align := alLeft;
  splitter.Left := pLeft.Width + 1;

  pRight := MakePanel(Self, alClient);
  pTop := MakePanel(pRight, alTop, 96);
  FHeadline := MakeLabel(pTop, rsCmpNoResult);
  FHeadline.Tag := TAG_KEEP_FONT;
  FHeadline.Font.Style := [fsBold];
  FAxes := MakeLabel(pTop, '');
  StackTop(FAxes);
  FProgress := MakeLabel(pTop, '');
  StackTop(FProgress);
  FCaveat := MakeLabel(pTop, PERMANENT_CAVEAT);
  FCaveat.WordWrap := True;
  StackTop(FCaveat);
  FReveal := MakeCheck(pRight, rsCmpReveal, alBottom);
  FReveal.OnClick := @RevealClick;

  FResultPages := MakePages(pRight);

  ts := FResultPages.AddTabSheet;
  ts.Caption := rsCmpDirectories;
  FMatrix := TRtListGrid.Create(ts);
  FMatrix.Parent := ts;
  FMatrix.Align := alClient;
  FMatrix.AddColumn('Directory', 140);
  FMatrix.AddColumn('Endpoint', 180);
  FMatrix.AddColumn('Transport', 160);
  FMatrix.AddColumn('Identity', 180);
  FMatrix.AddColumn('Read', 110);
  FMatrix.AddColumn('Entries', 80);
  FMatrix.AddColumn('Not observed here', 140);
  FMatrix.AddColumn('Duplicates', 90);
  FMatrix.AddColumn('Markers moved', 110);
  FMatrix.AddColumn('Errors', 260);

  diffBody := AddPageBody(FResultPages, rsCmpDifferences);
  FDetail := MakeMemo(diffBody, alBottom);
  FDetail.Height := 260;
  FDetail.ReadOnly := True;
  FDetail.ScrollBars := ssAutoBoth;
  FDetail.WordWrap := False;
  with TSplitter.Create(diffBody) do
  begin
    Parent := diffBody;
    Align := alBottom;
  end;
  FDiffs := TRtListGrid.Create(diffBody);
  FDiffs.Parent := diffBody;
  FDiffs.Align := alClient;
  FDiffs.OnGetCell := @DiffsCell;
  FDiffs.OnSelectRow := @DiffsSelect;
  FDiffs.Sortable := True;
  FDiffs.AddColumn('Entry', 360);
  FDiffs.AddColumn('Observed in', 220);
  FDiffs.AddColumn('Observation', 260);
  FDiffs.AddColumn('After second reading', 220);
  FDiffs.AddColumn('Variants', 80);
  FDiffs.AddColumn('objectClass', 140);

  FIndicators := MakeMemo(AddPageBody(FResultPages, rsCmpIndicators));
  FIndicators.ReadOnly := True;

  FNotes := MakeMemo(AddPageBody(FResultPages, rsCmpNotes));
  FNotes.ReadOnly := True;
end;

procedure TCompareTab.ApplyTheme;
begin
  ThemeControlTree(Self);
  ArrangeByCreation(Self);
  FMatrix.Color := clAppBg;
  FMatrix.Font.Color := clAppFg;
  FDiffs.Color := clAppBg;
  FDiffs.Font.Color := clAppFg;
  FMatrix.RefreshMetrics;
  FDiffs.RefreshMetrics;
  FSources.Color := clAppBg;
  FSources.Font.Color := clAppFg;
  FCaveat.Font.Color := clDiffWarning;
  FHeadline.Font.Size := RSUiFontSize + 3;
  if RSUiFontName <> '' then FHeadline.Font.Name := RSUiFontName;
end;

function TCompareTab.ProfileByUuid(const AUuid: string): TConnectionProfile;
var
  i: Integer;
begin
  Result := nil;
  if FCatalog <> nil then Result := FCatalog.Find(AUuid);
  if Result <> nil then Exit;
  for i := 0 to FLdifProfiles.Count - 1 do
    if TConnectionProfile(FLdifProfiles[i]).Uuid = AUuid then
      Exit(TConnectionProfile(FLdifProfiles[i]));
end;

function TCompareTab.AddLdifSource(const APath: string): Integer;
var
  p: TConnectionProfile;
  i: Integer;
  path: string;
begin
  path := ExpandFileName(APath);
  for i := 0 to FSourceUuids.Count - 1 do
  begin
    p := ProfileByUuid(FSourceUuids[i]);
    if (p <> nil) and SameFileName(p.LdifPath, path) then
    begin
      FSources.Checked[i] := True;
      RefreshReferences;
      Exit(i);
    end;
  end;
  // Base laissee vide, choisie a l'execution d'apres le contenu du fichier: la source cochee ici n'est pas
  // forcement l'annuaire dont il est l'export.
  p := TConnectionProfile.Create;
  p.Uuid := NewUuidV4;
  p.Name := ExtractFileName(path);
  p.LdifPath := path;
  FLdifProfiles.Add(p);
  Result := FSources.Items.Add(p.Name + '  (' + path + ')');
  FSourceUuids.Add(p.Uuid);
  FBaseByUuid.Add(p.Uuid + '=');
  FSources.Checked[Result] := True;
  RefreshReferences;
end;

procedure TCompareTab.AddLdifClick(Sender: TObject);
var
  od: TOpenDialog;
  i: Integer;
begin
  od := TOpenDialog.Create(Self);
  try
    od.Filter := rsCmpLdifFilter;
    od.Options := od.Options + [ofFileMustExist, ofAllowMultiSelect];
    if not od.Execute then Exit;
    for i := 0 to od.Files.Count - 1 do
      FSources.ItemIndex := AddLdifSource(od.Files[i]);
    SourcesClick(nil);
  finally
    od.Free;
  end;
end;

function TCompareTab.AskSecretFor(AProfile: TConnectionProfile; out ASecret: RawByteString): Boolean;
var
  remember: Boolean;
begin
  Result := AskBindSecret(Self, AProfile.DisplayEndpoint, AProfile.EnvironmentBadge,
    EffectiveBindDn(AProfile), False, ASecret, remember);
end;

procedure TCompareTab.FillProfiles;
var
  i: Integer;
  p: TConnectionProfile;
begin
  FSources.Items.BeginUpdate;
  try
    FSources.Items.Clear;
    FSourceUuids.Clear;
    if FCatalog <> nil then
    for i := 0 to FCatalog.Count - 1 do
    begin
      p := FCatalog[i];
      FSources.Items.Add(p.Name + '  (' + p.DisplayEndpoint + ')');
      FSourceUuids.Add(p.Uuid);
      if (FBaseByUuid.IndexOfName(p.Uuid) < 0) and (p.BaseDns.Count > 0) then
        FBaseByUuid.Values[p.Uuid] := p.BaseDns[0];
    end;
  finally
    FSources.Items.EndUpdate;
  end;
end;

procedure TCompareTab.FillSaved;
var
  items: TDocItems;
  i: Integer;
begin
  FSaved.Items.Clear;
  if FCtx.Document = nil then Exit;
  items := FCtx.Document.Items(dikComparison);
  for i := 0 to High(items) do
    FSaved.Items.AddObject(items[i].Name, TObject(PtrInt(i)));
end;

procedure TCompareTab.SourcesClick(Sender: TObject);
var
  uuid: string;
  p: TConnectionProfile;
begin
  if FSources.ItemIndex < 0 then Exit;
  uuid := FSourceUuids[FSources.ItemIndex];
  FBase.OnChange := nil;
  p := ProfileByUuid(uuid);
  if (p <> nil) and (p.LdifPath <> '') then
    FBase.TextHint := rsCmpLdifBaseHint
  else
    FBase.TextHint := rsCmpServerBaseHint;
  FBase.Text := FBaseByUuid.Values[uuid];
  FBase.OnChange := @BaseChange;
end;

procedure TCompareTab.BaseChange(Sender: TObject);
begin
  if FSources.ItemIndex < 0 then Exit;
  FBaseByUuid.Values[FSourceUuids[FSources.ItemIndex]] := Trim(FBase.Text);
  // Values[...] := '' supprime la ligne du TStringList: on remet une entree explicite.
  if Trim(FBase.Text) = '' then
    FBaseByUuid.Add(FSourceUuids[FSources.ItemIndex] + '=');
end;

procedure TCompareTab.SourcesCheck(Sender: TObject);
begin
  RefreshReferences;
end;

procedure TCompareTab.RefreshReferences;
var
  i, keep: Integer;
  old: string;
begin
  old := FReference.Text;
  FReference.Items.Clear;
  for i := 0 to FSources.Items.Count - 1 do
    if FSources.Checked[i] then
      FReference.Items.Add(FSources.Items[i]);
  keep := FReference.Items.IndexOf(old);
  if keep < 0 then keep := 0;
  if FReference.Items.Count > 0 then FReference.ItemIndex := keep;
  FReference.Enabled := FTopology.ItemIndex = 1;
end;

function TCompareTab.BuildProfile(AProfile: TComparisonProfile; out AErrors: TStringArray): Boolean;
var
  i, n: Integer;
  p: TConnectionProfile;
begin
  AProfile.Uuid := FProfileUuid;
  AProfile.Name := Trim(FName.Text);
  n := 0;
  SetLength(AProfile.Sources, 0);
  AProfile.ReferenceIndex := -1;
  for i := 0 to FSources.Items.Count - 1 do
    if FSources.Checked[i] then
    begin
      p := TConnectionProfile(ProfileByUuid(FSourceUuids[i]));
      if p = nil then Continue;
      SetLength(AProfile.Sources, n + 1);
      AProfile.Sources[n].ProfileUuid := p.Uuid;
      AProfile.Sources[n].Name := p.Name;
      AProfile.Sources[n].BaseDn := FBaseByUuid.Values[p.Uuid];
      AProfile.Sources[n].LdifPath := p.LdifPath;
      if (FTopology.ItemIndex = 1) and (FReference.Text = FSources.Items[i]) then
        AProfile.ReferenceIndex := n;
      Inc(n);
    end;
  if FTopology.ItemIndex = 1 then AProfile.Topology := ctReference else AProfile.Topology := ctSymmetric;
  AProfile.Mode := TCompareMode(FMode.ItemIndex);
  AProfile.Strictness := TCompareStrictness(FStrictness.ItemIndex);
  AProfile.Identity := TIdentityMode(FIdentity.ItemIndex);
  AProfile.BusinessKeyAttr := Trim(FBusinessKey.Text);
  AProfile.Scope := TSearchScope(FScope.ItemIndex);
  AProfile.Filter := Trim(FFilter.Text);
  AProfile.IncludeAttrs.Clear;
  AProfile.IncludeAttrs.StrictDelimiter := True;
  AProfile.IncludeAttrs.Delimiter := ',';
  AProfile.IncludeAttrs.DelimitedText := StringReplace(FInclude.Text, ' ', '', [rfReplaceAll]);
  for i := AProfile.IncludeAttrs.Count - 1 downto 0 do
    if Trim(AProfile.IncludeAttrs[i]) = '' then AProfile.IncludeAttrs.Delete(i);
  AProfile.ExcludeAttrs.Clear;
  for i := 0 to FExclude.Lines.Count - 1 do
    if Trim(FExclude.Lines[i]) <> '' then
      AProfile.ExcludeAttrs.Add(Trim(FExclude.Lines[i]));
  AProfile.IncludeOperational := FOperational.Checked;
  AProfile.RewriteDnValues := FRewriteDn.Checked;
  AProfile.SecondPass := FSecondPass.Checked;
  AProfile.AclAttestation := FAclAttest.Checked;
  AProfile.SampleSize := StrToIntDef(FSample.Text, -1);
  AProfile.PassDelaySec := StrToIntDef(FDelay.Text, -1);
  AProfile.StabilizationWindowSec := StrToIntDef(FWindow.Text, -1);
  AProfile.MemoryBudgetMiB := StrToIntDef(FMemory.Text, 0);
  AProfile.TempQuotaMiB := StrToIntDef(FQuota.Text, 0);
  Result := AProfile.Validate(AErrors);
end;

procedure TCompareTab.LoadIntoUi(AProfile: TComparisonProfile);
var
  i, j: Integer;
begin
  FProfileUuid := AProfile.Uuid;
  FName.Text := AProfile.Name;
  for i := 0 to FSources.Items.Count - 1 do
    FSources.Checked[i] := False;
  for j := 0 to High(AProfile.Sources) do
  begin
    if AProfile.Sources[j].LdifPath <> '' then
    begin
      i := AddLdifSource(AProfile.Sources[j].LdifPath);
      AProfile.Sources[j].ProfileUuid := FSourceUuids[i];
    end
    else
      i := FSourceUuids.IndexOf(AProfile.Sources[j].ProfileUuid);
    if i < 0 then
    begin
      FNotes.Lines.Add(Format(rsCmpProfileMissing, [AProfile.Sources[j].Name]));
      Continue;
    end;
    FSources.Checked[i] := True;
    FBaseByUuid.Values[AProfile.Sources[j].ProfileUuid] := AProfile.Sources[j].BaseDn;
    if AProfile.Sources[j].BaseDn = '' then
      FBaseByUuid.Add(AProfile.Sources[j].ProfileUuid + '=');
  end;
  if AProfile.Topology = ctReference then FTopology.ItemIndex := 1 else FTopology.ItemIndex := 0;
  RefreshReferences;
  if (AProfile.Topology = ctReference) and (AProfile.ReferenceIndex >= 0) and
     (AProfile.ReferenceIndex <= High(AProfile.Sources)) then
  begin
    i := FSourceUuids.IndexOf(AProfile.Sources[AProfile.ReferenceIndex].ProfileUuid);
    if i >= 0 then FReference.ItemIndex := FReference.Items.IndexOf(FSources.Items[i]);
  end;
  FMode.ItemIndex := Ord(AProfile.Mode);
  FStrictness.ItemIndex := Ord(AProfile.Strictness);
  FIdentity.ItemIndex := Ord(AProfile.Identity);
  FBusinessKey.Text := AProfile.BusinessKeyAttr;
  FScope.ItemIndex := Ord(AProfile.Scope);
  FFilter.Text := AProfile.Filter;
  FInclude.Text := StringReplace(AProfile.IncludeAttrs.CommaText, ',', ', ', [rfReplaceAll]);
  FExclude.Lines.Assign(AProfile.ExcludeAttrs);
  FOperational.Checked := AProfile.IncludeOperational;
  FRewriteDn.Checked := AProfile.RewriteDnValues;
  FSecondPass.Checked := AProfile.SecondPass;
  FAclAttest.Checked := AProfile.AclAttestation;
  FSample.Text := IntToStr(AProfile.SampleSize);
  FDelay.Text := IntToStr(AProfile.PassDelaySec);
  FWindow.Text := IntToStr(AProfile.StabilizationWindowSec);
  FMemory.Text := IntToStr(AProfile.MemoryBudgetMiB);
  FQuota.Text := IntToStr(AProfile.TempQuotaMiB);
  SourcesClick(nil);
end;

procedure TCompareTab.SetRunning(ARunning: Boolean);
begin
  FRunBtn.Enabled := not ARunning;
  FStopBtn.Enabled := ARunning;
  FExportBtn.Enabled := (not ARunning) and (FResult <> nil) and (FResult.Engine <> nil);
end;

procedure TCompareTab.RunClick(Sender: TObject);
var
  cp: TComparisonProfile;
  errors: TStringArray;
  inputs: array of TCompareSourceInput;
  i: Integer;
  p: TConnectionProfile;
  msg: string;
begin
  if FRun <> nil then Exit;
  cp := TComparisonProfile.Create;
  inputs := nil;
  try
    if not BuildProfile(cp, errors) then
    begin
      msg := rsCmpInvalid;
      for i := 0 to High(errors) do
        msg := msg + LineEnding + '- ' + errors[i];
      RtMessageDlg(rsCmpCaption, msg, mtWarning, [mbOK], 0);
      Exit;
    end;
    SetLength(inputs, Length(cp.Sources));
    try
      for i := 0 to High(cp.Sources) do
      begin
        p := ProfileByUuid(cp.Sources[i].ProfileUuid);
        if p = nil then
        begin
          RtMessageDlg(rsCmpCaption, Format(rsCmpProfileMissing, [cp.Sources[i].Name]), mtError, [mbOK], 0);
          Exit;
        end;
        inputs[i].Profile := p;
        if p.LdifPath <> '' then Continue;
        if NeedsPlainSecretConfirmation(p) then
          if RtMessageDlg(p.Name, rsPlainWarningConnect, mtWarning, [mbYes, mbNo], 0) <> mrYes then
            Exit;
        if not ResolveBindSecret(FCtx.Document, p, @AskSecretFor, inputs[i].Secret) then
          Exit;
      end;
      FResult.Free;
      FResult := nil;
      FDiffs.Count := 0;
      FMatrix.Clear;
      FDetail.Clear;
      FIndicators.Clear;
      FNotes.Clear;
      FHeadline.Caption := rsCmpRunning;
      FAxes.Caption := '';
      FRun := TComparisonRun.Create(Self, cp, inputs, GetTempDir(False));
      SetRunning(True);
      FCtx.Log(mlInfo, rsCmpCaption, Format('Comparison "%s" started on %d directories (%s).',
        [cp.Name, Length(cp.Sources), ModeName(cp.Mode)]));
    finally
      for i := 0 to High(inputs) do
        WipeString(inputs[i].Secret);
    end;
  finally
    cp.Free;
  end;
end;

procedure TCompareTab.StopClick(Sender: TObject);
begin
  if FRun <> nil then
  begin
    FRun.Cancel;
    FStopBtn.Enabled := False;
  end;
end;

procedure TCompareTab.HandleMessage(AMsg: TUiMessage);
var
  pm: TCompareProgressMsg;
  who: string;
  i: Integer;
begin
  if (FRun = nil) or (AMsg.TaskId <> FRun.TaskId) then Exit;
  if AMsg is TCompareProgressMsg then
  begin
    pm := TCompareProgressMsg(AMsg);
    if (pm.Source >= 0) and (pm.Source < FSources.Items.Count) then
      who := Format('#%d', [pm.Source + 1])
    else
      who := 'run';
    FProgress.Caption := Format(rsCmpProgress, [who, pm.Phase, pm.Count]);
  end
  else if AMsg is TCompareDoneMsg then
  begin
    FResult.Free;
    FResult := TCompareDoneMsg(AMsg).TakeRun;
    if FResult <> nil then
      for i := 0 to High(FResult.Schemas) do
        FCtx.Sensitive.LearnSchema(FResult.Schemas[i]);
    FRun.Release(3000);
    FRun := nil;
    FProgress.Caption := '';
    SetRunning(False);
    ShowResult;
    if FResult <> nil then
      FCtx.Log(mlInfo, rsCmpCaption, 'Comparison finished: ' + FResult.Verdict.Headline);
  end;
end;

procedure TCompareTab.ShowResult;
var
  e: TComparisonEngine;
  i, j: Integer;
  obs: TSourceObservation;
  markers, ident: string;
  moved: Boolean;
  errs: string;
  mc: TMarkerComparison;
begin
  if FResult = nil then Exit;
  FHeadline.Caption := FResult.Verdict.Headline;
  FAxes.Caption := Format('Execution: %s  |  Coverage: %s  |  Stability: %s  |  Result: %s',
    [ExecutionName(FResult.Verdict.Execution), CoverageName(FResult.Verdict.Coverage),
     StabilityName(FResult.Verdict.Stability), ResultStateName(FResult.Verdict.Result)]);
  for i := 0 to High(FResult.Notes) do
    FNotes.Lines.Add(FResult.Notes[i]);
  for i := 0 to High(FResult.Verdict.CoverageReasons) do
    FNotes.Lines.Add('Coverage: ' + FResult.Verdict.CoverageReasons[i]);
  for i := 0 to High(FResult.Verdict.StabilityReasons) do
    FNotes.Lines.Add('Stability: ' + FResult.Verdict.StabilityReasons[i]);
  FNotes.Lines.Add(Format('Started %s UTC, finished %s UTC, %d pass(es), %d ms.',
    [FormatUtcIso(FResult.StartedUtc), FormatUtcIso(FResult.FinishedUtc), FResult.Passes,
     FResult.DurationMs]));
  e := FResult.Engine;
  if e = nil then Exit;
  FNotes.Lines.Add(Format('%d keys: %d equal, %d differing (%d not observed everywhere, %d values differ, ' +
    '%d renamed, %d ambiguous); %d transient, %d persistent.',
    [e.Counters.Keys, e.Counters.EqualKeys, e.Counters.DifferingKeys, e.Counters.MissingKeys,
     e.Counters.ContentKeys, e.Counters.RenamedKeys, e.Counters.AmbiguousKeys,
     e.Counters.TransientKeys, e.Counters.PersistentKeys]));
  FNotes.Lines.Add('Excluded attributes: ' + e.Profile.ExcludeAttrs.CommaText);
  for i := 0 to High(e.Profile.Sources) do
  begin
    obs := e.Observation(i);
    moved := Length(obs.MarkersBefore) <> Length(obs.MarkersAfter);
    if not moved then
      for j := 0 to High(obs.MarkersBefore) do
        if obs.MarkersBefore[j] <> obs.MarkersAfter[j] then moved := True;
    if Length(obs.MarkersBefore) + Length(obs.MarkersAfter) = 0 then
      markers := 'unavailable'
    else if moved then
      markers := 'yes'
    else
      markers := 'no';
    if obs.AuthzId <> '' then ident := obs.AuthzId else ident := obs.BoundIdentity;
    errs := '';
    for j := 0 to High(obs.Errors) do
      errs := errs + obs.Errors[j] + '; ';
    FMatrix.AddRow([obs.Name, obs.Endpoint, obs.TransportLabel, ident,
      ResultCodeName(obs.Completion.ResultCode), IntToStr(obs.EntryCount),
      IntToStr(e.Counters.PerSourceAbsent[i]), IntToStr(obs.DuplicateKeys), markers, errs]);
  end;
  FIndicators.Lines.Add('Replication markers are hints only: identical vectors do not replace a content comparison.');
  for i := 0 to High(e.Profile.Sources) do
  begin
    obs := e.Observation(i);
    FIndicators.Lines.Add('');
    FIndicators.Lines.Add(obs.Name + ':');
    if Length(obs.MarkersAfter) = 0 then
      FIndicators.Lines.Add('  no readable contextCSN (unavailable)');
    for j := 0 to High(obs.MarkersBefore) do
      FIndicators.Lines.Add('  before ' + obs.MarkersBefore[j]);
    for j := 0 to High(obs.MarkersAfter) do
      FIndicators.Lines.Add('  after  ' + obs.MarkersAfter[j]);
  end;
  for i := 0 to High(FResult.MarkerComparisons) do
  begin
    mc := FResult.MarkerComparisons[i];
    FIndicators.Lines.Add('');
    FIndicators.Lines.Add(Format('%s -> %s:', [e.Profile.Sources[mc.SourceA].Name,
      e.Profile.Sources[mc.SourceB].Name]));
    for j := 0 to High(mc.Sids) do
      FIndicators.Lines.Add(Format('  SID %d: %s (%s / %s)', [mc.Sids[j].Sid,
        SidStateName(mc.Sids[j].State), mc.Sids[j].A, mc.Sids[j].B]));
  end;
  FDiffs.Count := e.DiffCount;
  if e.DiffCount > 0 then SelectPage(FResultPages, 1);
  SetRunning(False);
end;

function ObservedIn(AEngine: TComparisonEngine; ADiff: TEntryDiff): string;
var
  s, k: Integer;
  absent: Boolean;
begin
  if Length(ADiff.Absent) = 0 then Exit(rsCmpAllSources);
  Result := '';
  for s := 0 to High(ADiff.Dns) do
  begin
    absent := False;
    for k := 0 to High(ADiff.Absent) do
      if ADiff.Absent[k] = s then absent := True;
    if absent then Continue;
    if Result <> '' then Result := Result + ', ';
    Result := Result + AEngine.Observation(s).Name;
  end;
  if Result = '' then Result := '-';
end;

function TCompareTab.DiffsCell(Sender: TObject; AIndex, ACol: Integer): string;
var
  d: TEntryDiff;
begin
  Result := '';
  if (FResult = nil) or (FResult.Engine = nil) or (AIndex >= FResult.Engine.DiffCount) then Exit;
  d := FResult.Engine.Diff(AIndex);
  case ACol of
    0: Result := d.DisplayKey;
    1: Result := ObservedIn(FResult.Engine, d);
    2: Result := DiffKindsText(d.Kinds);
    3: case d.Persistence of
         psTransient: Result := 'transient divergence observed';
         psPersistent: Result := 'persistent divergence observed';
       else
         Result := 'not read again';
       end;
    4: Result := IntToStr(Length(d.Variants));
    5: Result := d.ObjectClass;
  end;
end;

procedure TCompareTab.DiffsSelect(Sender: TObject; AIndex: Integer);
begin
  ShowDetail(AIndex);
end;

procedure TCompareTab.RevealClick(Sender: TObject);
begin
  if FReveal.Checked then
    if RtMessageDlg(rsCmpCaption, rsCmpRevealConfirm, mtWarning, [mbYes, mbNo], 0) <> mrYes then
    begin
      FReveal.OnClick := nil;
      FReveal.Checked := False;
      FReveal.OnClick := @RevealClick;
    end;
  if FDiffs.ItemIndex >= 0 then
    ShowDetail(FDiffs.ItemIndex);
end;

procedure TCompareTab.ShowDetail(AIndex: Integer);
var
  e: TComparisonEngine;
  d: TEntryDiff;
  i, j, k: Integer;
  names: string;
  attrs: TCanonAttrs;
  masked: Boolean;

  function Show(const V: RawByteString): string;
  begin
    if IsValidUtf8(V) then
      Result := EscapeControlChars(V)
    else
      Result := 'base64:' + Base64EncodeStr(V);
  end;

begin
  FDetail.Lines.BeginUpdate;
  try
    FDetail.Clear;
    if (FResult = nil) or (FResult.Engine = nil) then Exit;
    e := FResult.Engine;
    if (AIndex < 0) or (AIndex >= e.DiffCount) then Exit;
    d := e.Diff(AIndex);
    FDetail.Lines.Add(d.DisplayKey + '   [' + DiffKindsText(d.Kinds) + ']');
    for i := 0 to High(d.Dns) do
      if d.Dns[i] <> '' then
        FDetail.Lines.Add(Format('  %-20s %s', [e.Profile.Sources[i].Name, d.Dns[i]]))
      else
        FDetail.Lines.Add(Format('  %-20s (%s)', [e.Profile.Sources[i].Name, rsCmpNotObserved]));
    for i := 0 to High(d.Duplicated) do
      FDetail.Lines.Add('  duplicated identity on ' + e.Profile.Sources[d.Duplicated[i]].Name);
    if not FReveal.Checked then
      FDetail.Lines.Add(rsCmpMasked);
    for i := 0 to High(d.Variants) do
    begin
      names := '';
      for j := 0 to High(d.Variants[i].Members) do
      begin
        if names <> '' then names := names + ', ';
        names := names + e.Profile.Sources[d.Variants[i].Members[j]].Name;
      end;
      FDetail.Lines.Add('');
      FDetail.Lines.Add(Format('Variant %d shared by: %s', [i + 1, names]));
      try
        attrs := e.VariantAttributes(d, i);
      except
        on Ex: Exception do
        begin
          FDetail.Lines.Add('  (record unreadable: ' + Ex.Message + ')');
          Continue;
        end;
      end;
      for j := 0 to High(attrs) do
      begin
        masked := (not FReveal.Checked) and FCtx.Sensitive.IsSensitive(attrs[j].Name);
        if masked then
          FDetail.Lines.Add('  ' + attrs[j].Name + ': ' + MaskedValuesText(Length(attrs[j].RawValues)))
        else
          for k := 0 to High(attrs[j].RawValues) do
            FDetail.Lines.Add('  ' + attrs[j].Name + ': ' + Show(attrs[j].RawValues[k]));
      end;
    end;
    if Length(d.AttrDiffs) > 0 then
    begin
      FDetail.Lines.Add('');
      FDetail.Lines.Add('Attribute differences:');
      for i := 0 to High(d.AttrDiffs) do
      begin
        masked := (not FReveal.Checked) and FCtx.Sensitive.IsSensitive(d.AttrDiffs[i].Attr);
        if d.AttrDiffs[i].SemanticUndetermined then
          FDetail.Lines.Add('  ' + d.AttrDiffs[i].Attr + ' (semantic equivalence undetermined)')
        else
          FDetail.Lines.Add('  ' + d.AttrDiffs[i].Attr);
        if masked then
          FDetail.Lines.Add('    ' + MaskedValuesText(Length(d.AttrDiffs[i].OnlyInBase) +
            Length(d.AttrDiffs[i].OnlyInOther)))
        else
        begin
          for k := 0 to High(d.AttrDiffs[i].OnlyInBase) do
            FDetail.Lines.Add(Format('    - variant %d: %s', [d.AttrDiffs[i].BaseVariant + 1,
              Show(d.AttrDiffs[i].OnlyInBase[k])]));
          for k := 0 to High(d.AttrDiffs[i].OnlyInOther) do
            FDetail.Lines.Add(Format('    + variant %d: %s', [d.AttrDiffs[i].OtherVariant + 1,
              Show(d.AttrDiffs[i].OnlyInOther[k])]));
        end;
      end;
    end;
  finally
    FDetail.Lines.EndUpdate;
  end;
end;

procedure TCompareTab.SaveClick(Sender: TObject);
var
  cp: TComparisonProfile;
  errors: TStringArray;
  item: TDocItem;
  json: TJSONObject;
begin
  if FCtx.Document = nil then Exit;
  cp := TComparisonProfile.Create;
  try
    BuildProfile(cp, errors);
    if cp.Name = '' then
    begin
      RtMessageDlg(rsCmpCaption, rsCmpName + '?', mtWarning, [mbOK], 0);
      Exit;
    end;
    item := Default(TDocItem);
    item.Uuid := FProfileUuid;
    item.Name := cp.Name;
    item.Version := COMPARE_PROFILE_VERSION;
    json := cp.ToJson;
    try
      item.Body := json.AsJSON;
    finally
      json.Free;
    end;
    FProfileUuid := FCtx.Document.PutItem(dikComparison, item);
    FillSaved;
    FSaved.ItemIndex := FSaved.Items.IndexOf(cp.Name);
    FCtx.StatusChanged;
    FCtx.Log(mlInfo, rsCmpCaption, rsCmpSavedOk);
  finally
    cp.Free;
  end;
end;

procedure TCompareTab.LoadClick(Sender: TObject);
var
  items: TDocItems;
  idx: Integer;
  data: TJSONData;
  cp: TComparisonProfile;
begin
  if (FCtx.Document = nil) or (FSaved.ItemIndex < 0) then Exit;
  if FRun <> nil then
  begin
    RtMessageDlg(rsCmpCaption, rsCmpStopFirst, mtInformation, [mbOK], 0);
    Exit;
  end;
  items := FCtx.Document.Items(dikComparison);
  idx := PtrInt(FSaved.Items.Objects[FSaved.ItemIndex]);
  if (idx < 0) or (idx > High(items)) then Exit;
  cp := TComparisonProfile.Create;
  try
    try
      data := GetJSON(items[idx].Body);
      try
        if not (data is TJSONObject) then
          raise Exception.Create('not a JSON object');
        cp.LoadJson(TJSONObject(data));
      finally
        data.Free;
      end;
    except
      on E: Exception do
      begin
        RtMessageDlg(rsCmpCaption, 'Unreadable comparison profile: ' + E.Message, mtError, [mbOK], 0);
        Exit;
      end;
    end;
    cp.Uuid := items[idx].Uuid;
    FillProfiles;
    LoadIntoUi(cp);
  finally
    cp.Free;
  end;
end;

procedure TCompareTab.DeleteClick(Sender: TObject);
var
  items: TDocItems;
  idx: Integer;
begin
  if (FCtx.Document = nil) or (FSaved.ItemIndex < 0) then Exit;
  items := FCtx.Document.Items(dikComparison);
  idx := PtrInt(FSaved.Items.Objects[FSaved.ItemIndex]);
  if (idx < 0) or (idx > High(items)) then Exit;
  if RtMessageDlg(rsCmpCaption, Format(rsCmpDeleteConfirm, [items[idx].Name]), mtConfirmation,
      [mbYes, mbNo], 0) <> mrYes then
    Exit;
  FCtx.Document.DeleteItem(dikComparison, items[idx].Uuid);
  if FProfileUuid = items[idx].Uuid then FProfileUuid := '';
  FillSaved;
  FCtx.StatusChanged;
end;

procedure TCompareTab.ExportClick(Sender: TObject);
var
  sd: TSaveDialog;
  fmt: TReportFormat;
  includeSensitive: Boolean;
  ms: TMemoryStream;
begin
  if (FResult = nil) or (FResult.Engine = nil) then Exit;
  sd := TSaveDialog.Create(Self);
  try
    sd.Filter := 'JSON report (*.json)|*.json|HTML report (*.html)|*.html|CSV table (*.csv)|*.csv';
    sd.Options := sd.Options + [ofOverwritePrompt];
    sd.FileName := 'comparison-report.json';
    if not sd.Execute then Exit;
    case sd.FilterIndex of
      2: fmt := rfHtml;
      3: fmt := rfCsv;
    else
      fmt := rfJson;
    end;
    if ExtractFileExt(sd.FileName) = '' then
      sd.FileName := sd.FileName + ReportFormatExtension(fmt);
    includeSensitive := RtMessageDlg(rsCmpCaption, rsCmpExportSensitive, mtConfirmation,
      [mbYes, mbNo], 0) = mrYes;
    ms := TMemoryStream.Create;
    try
      WriteCompareReport(fmt, ms, FResult, FCtx.Sensitive, includeSensitive);
      ms.Position := 0;
      SavePrivateStream(sd.FileName, ms);
    finally
      ms.Free;
    end;
    FCtx.Log(mlInfo, rsCmpCaption, 'Report written: ' + sd.FileName);
  finally
    sd.Free;
  end;
end;

end.
