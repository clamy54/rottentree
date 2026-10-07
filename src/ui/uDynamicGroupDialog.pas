// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDynamicGroupDialog;

{$mode objfpc}{$H+}

// Criteres d'un groupe dynamique (memberURL): edition, apercu borne des membres, puis un seul Modify qui
// retire les valeurs exactes lues et ajoute les nouvelles, sous Assertion (RFC 4528) si le serveur la connait.
// Le calcul des membres depend du serveur (OpenLDAP: dynlist); une URL qui pointe vers un autre serveur
// n'est jamais evaluee ici. Un groupe dynamique est une requete deguisee en liste, on la traite comme telle.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, Dialogs,
  uAppContext, uRtCombo, uOpsDialog, uDirectoryWorker, uLdapEntry, uGroupModel, uConnectionProfile, uUiInbox,
  uMembershipDialog;

type
  TDynamicGroupDialog = class(TOpsDialog)
  private
    FDn: string;
    FServer: TProviderKind;
    FGroup: TLdapEntry;
    FModel: TGroupModel;
    FOriginal: array of string;
    FCriteria: TStringList;
    FPreviewCount: Integer;
    FUpdating: Boolean;
    FEditorValid: Boolean;
    FEditRow: Integer;
    FReadPartial: Boolean;
    FOnWritten: TOpenDnEvent;
    FModelLabel, FProblem, FUrlLabel, FPreviewNote: TLabel;
    FList, FPreviewList: TListBox;
    FBase, FFilter, FAttrs: TEdit;
    FScope: TRtComboBox;
    FEditor: TPanel;
    FAddBtn, FRemoveBtn, FApplyBtn, FPreviewBtn, FReloadBtn: TButton;
    procedure BuildUi;
    procedure Reload;
    procedure FillList(ASelect: Integer);
    procedure LoadEditor;
    procedure EditorChanged(Sender: TObject);
    procedure ListClick(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure BuilderClick(Sender: TObject);
    procedure PreviewClick(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure ReloadClick(Sender: TObject);
    procedure UpdateButtons;
    procedure NoteEdit;
    procedure CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
    function EditorUrl(out AUrl: TLdapUrl; out AError: string): Boolean;
    function Modified: Boolean;
    function DropInvalidDraft: Boolean;
    procedure InvalidatePreview;
    // Annulation par identifiant de tache, jamais par proprietaire: une ecriture en vol emportee au passage
    // deviendrait d'issue inconnue.
    procedure CancelReads;
  protected
    procedure UpdateActions; override;
    procedure OnEntry(AMsg: TEntryMsg); override;
    procedure OnEntries(AMsg: TEntriesMsg); override;
    procedure OnWrite(AMsg: TWriteMsg); override;
    procedure OnFailed(AMsg: TTaskFailedMsg); override;
    procedure OnStale(AMsg: TUiMessage); override;
  public
    constructor CreateDynamic(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);
    destructor Destroy; override;
    function CriteriaText: string;
    function ModelText: string;
    function StatusText: string;
    function ProblemText: string;
    function PreviewText: string;
    function PreviewNote: string;
    procedure SelectCriterion(AIndex: Integer);
    procedure SetCriterion(const ABase: string; AScope: Integer; const AFilter, AAttrs: string);
    procedure AddCriterion;
    procedure RemoveCriterion;
    procedure Preview;
    procedure Apply;
    procedure ReadAgain;
    function ApplyEnabled: Boolean;
    function ReadAgainEnabled: Boolean;
    function HasUnsavedWork: Boolean;
    property OnWritten: TOpenDnEvent read FOnWritten write FOnWritten;
  end;

procedure ShowDynamicGroupDialog(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  ADn: string; AOnWritten: TOpenDnEvent = nil);

resourcestring
  rsDgTitle = 'Dynamic group criteria';
  rsDgGroup = 'Group: %s';
  rsDgModel = 'Model: %s, criteria in %s';
  rsDgNoModel = 'This entry is not a dynamic group: %s.';
  rsDgAdNote = 'Active Directory has no LDAP URL criteria groups; query-based distribution groups ' +
    'are managed with the Exchange tools.';
  rsDgServerNote = 'Members are computed by the server only if its configuration evaluates these ' +
    'criteria (OpenLDAP: dynlist overlay). The preview runs the search with the rights of this connection.';
  rsDgCriteria = 'Criteria (LDAP URLs)';
  rsDgAdd = 'Add criterion';
  rsDgRemove = 'Remove';
  rsDgBase = 'Base DN';
  rsDgScope = 'Scope';
  rsDgFilter = 'Filter';
  rsDgAttrs = 'Attributes (optional)';
  rsDgBuilder = 'Builder...';
  rsDgPreview = 'Preview members';
  rsDgApply = 'Apply';
  rsDgReload = 'Read again';
  rsDgReading = 'Reading the group...';
  rsDgUrl = 'URL: %s';
  rsDgOtherHost = 'This criterion designates another server (%s): it is kept but not previewed.';
  rsDgPreviewing = 'Searching the members of this criterion...';
  rsDgPreviewDone = '%d entries match this criterion (complete).';
  rsDgPreviewLimit = 'First %d entries shown: the preview stops at %d.';
  rsDgPreviewPartial = 'PARTIAL: %d entries (%s).';
  rsDgUnsaved = 'Criteria changed: Apply writes them; closing discards them.';
  rsDgDiscard = 'The criteria were changed and not applied. Close anyway?';
  rsDgDropDraft = 'The criterion being edited is not valid. Discard its changes?';
  rsDgNote = 'Criteria of %s: the values read are removed exactly and the new ones added in the same request.';
  rsDgWritten = 'Criteria written; the group is read again.';
  rsDgReadPartial = 'The group was read incompletely: its criteria may be more than those listed. ' +
    'Nothing can be previewed or written; read it again.';
  rsDgWriteWaitReload = 'A write is in progress: the group is read again when its outcome arrives.';
  rsDgDraftInvalid = 'The criterion being edited is not valid: nothing can be previewed or applied until it is fixed.';
  rsDgNoAssertion = 'No version assertion protects this write (control not announced or no readable ' +
    'version marker): only the removal of the exact values read would fail if the group changed meanwhile.';
  rsDgConcurrent = 'The group changed since it was read: nothing was applied. It is read again; review before retrying.';

const
  DYNAMIC_PREVIEW_LIMIT = 200;

implementation

uses
  uUiKit, uTheme, uStrings, uSearchModel, uLdapErrors, uServerKind, uConnections, uChangeSet,
  uFilterBuilderDialog, uRtMessage, uDirectoryService, uTaskDialog;

procedure ShowDynamicGroupDialog(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  ADn: string; AOnWritten: TOpenDnEvent);
var
  d: TDynamicGroupDialog;
begin
  d := TDynamicGroupDialog.CreateDynamic(AOwner, ACtx, AProfileUuid, ADn);
  try
    d.OnWritten := AOnWritten;
    d.ShowModal;
  finally
    d.Free;
  end;
end;

constructor TDynamicGroupDialog.CreateDynamic(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, ADn: string);
var
  c: TDirectoryConnection;
begin
  inherited CreateFor(AOwner, ACtx, AProfileUuid, rsDgTitle + ' - ' + ADn, 940, 680);
  SetIcon('users');
  FDn := ADn;
  FEditorValid := True;
  FEditRow := -1;
  FCriteria := TStringList.Create;
  c := Conn;
  FServer := pkOther;
  if c <> nil then FServer := EffectiveServerKind(c.Profile, c.RootDse);
  BuildUi;
  ApplyTheme;
  Reload;
end;

destructor TDynamicGroupDialog.Destroy;
begin
  // Lectures et apercus abandonnes cote serveur; une ecriture partie n'est jamais annulee, son issue
  // finit au journal.
  CancelReads;
  FGroup.Free;
  FCriteria.Free;
  inherited Destroy;
end;

procedure TDynamicGroupDialog.CancelReads;
begin
  Tasks.Cancel('read');
  Tasks.Cancel('preview');
end;

procedure TDynamicGroupDialog.UpdateActions;
begin
  UpdateButtons;
end;

procedure TDynamicGroupDialog.BuildUi;
var
  pLeft, pRight, row, bar, bottom: TPanel;
  lbl: TLabel;
begin
  lbl := MakeDataLabel(Body, Format(rsDgGroup, [FDn]));
  FModelLabel := MakeLabel(Body, rsDgReading);
  FModelLabel.WordWrap := True;
  lbl := MakeLabel(Body, rsDgServerNote);
  lbl.WordWrap := True;
  if FServer = pkActiveDirectory then
    MakeLabel(Body, rsDgAdNote).WordWrap := True;

  bottom := MakePanel(Body, alBottom, 200);
  bar := MakePanel(bottom, alTop, 36);
  FPreviewBtn := MakeButton(bar, rsDgPreview, @PreviewClick);
  FPreviewNote := MakeLabel(bar, '', alClient);
  FPreviewNote.Layout := tlCenter;
  FPreviewNote.WordWrap := True;
  FPreviewList := TListBox.Create(bottom);
  FPreviewList.Parent := bottom;
  FPreviewList.Align := alClient;
  FPreviewList.BorderSpacing.Around := 3;

  pLeft := MakePanel(Body, alLeft, 380);
  MakeLabel(pLeft, rsDgCriteria, alTop);
  bar := MakePanel(pLeft, alBottom, 36);
  FAddBtn := MakeButton(bar, rsDgAdd, @AddClick);
  FRemoveBtn := MakeButton(bar, rsDgRemove, @RemoveClick);
  FList := TListBox.Create(pLeft);
  FList.Parent := pLeft;
  FList.Align := alClient;
  FList.BorderSpacing.Around := 3;
  FList.OnClick := @ListClick;

  pRight := MakePanel(Body, alClient);
  FEditor := MakePanel(pRight, alTop);
  FEditor.AutoSize := True;
  FBase := MakeEditRow(FEditor, rsDgBase);
  FBase.OnChange := @EditorChanged;
  FScope := MakeCombo(MakeFieldRow(FEditor, rsDgScope), ['base', 'one', 'sub'], alLeft);
  FScope.Width := 140;
  FScope.ItemIndex := 2;
  FScope.OnChange := @EditorChanged;
  row := MakeFieldRow(FEditor, rsDgFilter, 150);
  MakeButton(row, rsDgBuilder, @BuilderClick, alRight);
  FFilter := MakeEdit(row, alClient);
  FFilter.OnChange := @EditorChanged;
  FAttrs := MakeEditRow(FEditor, rsDgAttrs);
  FAttrs.OnChange := @EditorChanged;
  FUrlLabel := MakeDataLabel(pRight, '', alTop);
  FUrlLabel.WordWrap := True;
  FProblem := MakeLabel(pRight, '', alTop);
  FProblem.WordWrap := True;

  FApplyBtn := AddButton(rsDgApply, mrNone);
  FApplyBtn.OnClick := @ApplyClick;
  FReloadBtn := AddButton(rsDgReload, mrNone);
  FReloadBtn.OnClick := @ReloadClick;
  AddButton(rsClose, mrClose, True, True);
  OnCloseQuery := @CloseQueryHandler;
  UpdateButtons;
end;

procedure TDynamicGroupDialog.Reload;
var
  attrs: array of string;
  i: Integer;
begin
  CancelReads;
  InvalidatePreview;
  FreeAndNil(FGroup);
  FOriginal := nil;
  FCriteria.Clear;
  FModel := Default(TGroupModel);
  FReadPartial := False;
  FEditorValid := True;
  FillList(-1);
  FModelLabel.Caption := rsDgReading;
  attrs := ['objectClass', 'cn', 'memberURL'];
  SetLength(attrs, Length(attrs) + Length(VERSION_MARKERS));
  for i := 0 to High(VERSION_MARKERS) do
    attrs[Length(attrs) - Length(VERSION_MARKERS) + i] := VERSION_MARKERS[i];
  ReadEntry(FDn, attrs, 'read');
  UpdateButtons;
end;

procedure TDynamicGroupDialog.OnEntry(AMsg: TEntryMsg);
var
  a: TLdapAttribute;
  i: Integer;
begin
  if Tasks.Current.Tag <> 'read' then Exit;
  if AMsg.Entry = nil then
  begin
    FModelLabel.Caption := ErrorToText(AMsg.Error);
    SetStatus(ErrorToText(AMsg.Error), usError);
    UpdateButtons;
    Exit;
  end;
  FGroup := AMsg.Entry;
  AMsg.Entry := nil;
  StampModel(AMsg);
  FModel := DetectGroupModel(FGroup, FServer);
  if FModel.DynamicAttr = '' then
  begin
    FModelLabel.Caption := Format(rsDgNoModel, [rsGroupNotDynamic]);
    FModelLabel.Font.Color := DialogStateColor(usWarning);
    UpdateButtons;
    Exit;
  end;
  FModelLabel.Caption := Format(rsDgModel, [GroupKindName(FModel.Kind), FModel.DynamicAttr]);
  a := FGroup.Find(FModel.DynamicAttr);
  if a <> nil then
    for i := 0 to a.ValueCount - 1 do
    begin
      SetLength(FOriginal, Length(FOriginal) + 1);
      FOriginal[High(FOriginal)] := a.Values[i];
      FCriteria.Add(a.Values[i]);
    end;
  // Un groupe lu en partie ne doit pas passer pour une liste complete: ni apercu ni ecriture avant une
  // relecture complete, sinon les valeurs invisibles survivraient en douce.
  FReadPartial := FGroup.DecodeIncomplete or FGroup.AnyTruncated;
  if FReadPartial then
    SetStatus(rsDgReadPartial, usWarning);
  if FCriteria.Count > 0 then FillList(0) else FillList(-1);
end;

procedure TDynamicGroupDialog.FillList(ASelect: Integer);
var
  i: Integer;
begin
  FUpdating := True;
  try
    FList.Items.BeginUpdate;
    try
      FList.Items.Clear;
      for i := 0 to FCriteria.Count - 1 do
        FList.Items.Add(FCriteria[i]);
    finally
      FList.Items.EndUpdate;
    end;
    FList.ItemIndex := ASelect;
  finally
    FUpdating := False;
  end;
  LoadEditor;
end;

procedure TDynamicGroupDialog.LoadEditor;
var
  u: TLdapUrl;
  err: string;
  i: Integer;
  attrs: string;
begin
  i := FList.ItemIndex;
  FEditRow := i;
  FEditorValid := True;
  if FStatus.Caption = rsDgDraftInvalid then NoteEdit;
  InvalidatePreview;
  FUpdating := True;
  try
    if (i < 0) or (i >= FCriteria.Count) then
    begin
      FBase.Text := '';
      FFilter.Text := '';
      FAttrs.Text := '';
      FUrlLabel.Caption := '';
      FProblem.Caption := '';
    end
    else if ParseLdapUrl(FCriteria[i], u, err) then
    begin
      FBase.Text := u.BaseDn;
      FScope.ItemIndex := Ord(u.Scope);
      FFilter.Text := u.Filter;
      attrs := '';
      for i := 0 to High(u.Attributes) do
      begin
        if i > 0 then attrs := attrs + ',';
        attrs := attrs + u.Attributes[i];
      end;
      FAttrs.Text := attrs;
      FUrlLabel.Caption := Format(rsDgUrl, [FList.Items[FList.ItemIndex]]);
      if u.Host <> '' then
      begin
        FProblem.Caption := Format(rsDgOtherHost, [u.Host]);
        FProblem.Font.Color := DialogStateColor(usWarning);
      end
      else
        FProblem.Caption := '';
    end
    else
    begin
      FBase.Text := '';
      FFilter.Text := '';
      FAttrs.Text := '';
      FUrlLabel.Caption := Format(rsDgUrl, [FCriteria[FList.ItemIndex]]);
      FProblem.Caption := err;
      FProblem.Font.Color := DialogStateColor(usError);
    end;
  finally
    FUpdating := False;
  end;
  UpdateButtons;
end;

function TDynamicGroupDialog.EditorUrl(out AUrl: TLdapUrl; out AError: string): Boolean;
var
  old: TLdapUrl;
  parts: TStringArray;
  i: Integer;
begin
  AUrl := Default(TLdapUrl);
  AError := '';
  if (FList.ItemIndex >= 0) and ParseLdapUrl(FCriteria[FList.ItemIndex], old, AError) then
  begin
    AUrl.Scheme := old.Scheme;
    AUrl.Host := old.Host;
    AUrl.Extensions := old.Extensions;
  end;
  AError := '';
  AUrl.BaseDn := Trim(FBase.Text);
  if FScope.ItemIndex >= 0 then AUrl.Scope := TSearchScope(FScope.ItemIndex);
  AUrl.Filter := Trim(FFilter.Text);
  parts := string(FAttrs.Text).Split([',', ' '], TStringSplitOptions.ExcludeEmpty);
  SetLength(AUrl.Attributes, Length(parts));
  for i := 0 to High(parts) do
    AUrl.Attributes[i] := Trim(parts[i]);
  AError := DynamicCriterionProblem(AUrl);
  Result := AError = '';
end;

procedure TDynamicGroupDialog.EditorChanged(Sender: TObject);
var
  u: TLdapUrl;
  err, url: string;
  i: Integer;
begin
  if FUpdating or FReadPartial then Exit;
  i := FList.ItemIndex;
  if (i < 0) or (i >= FCriteria.Count) then Exit;
  if not EditorUrl(u, err) then
  begin
    // Brouillon invalide: le critere enregistre reste, mais rien ne part. L'ecran montrerait un critere,
    // la requete en enverrait un autre.
    FEditorValid := False;
    InvalidatePreview;
    FProblem.Caption := err;
    FProblem.Font.Color := DialogStateColor(usError);
    SetStatus(rsDgDraftInvalid, usWarning);
    UpdateButtons;
    Exit;
  end;
  FEditorValid := True;
  InvalidatePreview;
  url := BuildLdapUrl(u);
  FCriteria[i] := url;
  FUpdating := True;
  try
    FList.Items[i] := url;
    FList.ItemIndex := i;
  finally
    FUpdating := False;
  end;
  FUrlLabel.Caption := Format(rsDgUrl, [url]);
  if u.Host <> '' then
  begin
    FProblem.Caption := Format(rsDgOtherHost, [u.Host]);
    FProblem.Font.Color := DialogStateColor(usWarning);
  end
  else
    FProblem.Caption := '';
  NoteEdit;
end;

function TDynamicGroupDialog.Modified: Boolean;
var
  i: Integer;
begin
  Result := Length(FOriginal) <> FCriteria.Count;
  if Result then Exit;
  for i := 0 to High(FOriginal) do
    if FOriginal[i] <> FCriteria[i] then Exit(True);
end;

procedure TDynamicGroupDialog.UpdateButtons;
var
  c: TDirectoryConnection;
  ready, writable, dynamic, idle: Boolean;
begin
  c := Conn;
  ready := c <> nil;
  writable := ready and not c.Profile.ReadOnly;
  dynamic := (FGroup <> nil) and (FModel.DynamicAttr <> '');
  idle := not Tasks.Pending('read') and not Tasks.WritesInFlight;
  FEditor.Enabled := dynamic and idle and not FReadPartial and (FList.ItemIndex >= 0);
  FAddBtn.Enabled := dynamic and idle and not FReadPartial and
    (FCriteria.Count < DYNAMIC_MAX_CRITERIA);
  FRemoveBtn.Enabled := dynamic and idle and not FReadPartial and (FList.ItemIndex >= 0);
  FPreviewBtn.Enabled := dynamic and ready and FEditorValid and not FReadPartial and
    (FList.ItemIndex >= 0) and not Tasks.Pending('preview');
  FApplyBtn.Enabled := dynamic and writable and idle and FEditorValid and
    not FReadPartial and Modified and Tasks.ModelCurrent;
  FReloadBtn.Enabled := not Tasks.WritesInFlight;
end;

procedure TDynamicGroupDialog.NoteEdit;
begin
  UpdateButtons;
  if Modified then SetStatus(rsDgUnsaved, usWarning) else SetStatus('');
end;

procedure TDynamicGroupDialog.CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
begin
  // Une ecriture partie retient deja la fermeture (TTaskDialog.CloseQuery passe avant). Ici, des criteres
  // non appliques ou un brouillon ne se perdent jamais sans le dire.
  CanClose := not HasUnsavedWork or
    (RtMessageDlg(rsDgTitle, rsDgDiscard, mtConfirmation, [mbYes, mbNo], 0) = mrYes);
end;

// Brouillon invalide abandonne seulement sur confirmation, jamais en silence par une autre selection:
// le critere enregistre reprendrait sa place et Apply pourrait se rallumer.
function TDynamicGroupDialog.DropInvalidDraft: Boolean;
begin
  Result := FEditorValid or
    (RtMessageDlg(rsDgTitle, rsDgDropDraft, mtConfirmation, [mbYes, mbNo], 0) = mrYes);
end;

procedure TDynamicGroupDialog.ListClick(Sender: TObject);
begin
  if FUpdating or (FList.ItemIndex = FEditRow) then Exit;
  if not DropInvalidDraft then
  begin
    FUpdating := True;
    try
      FList.ItemIndex := FEditRow;
    finally
      FUpdating := False;
    end;
    Exit;
  end;
  LoadEditor;
end;

procedure TDynamicGroupDialog.AddCriterion;
var
  u: TLdapUrl;
  c: TDirectoryConnection;
begin
  if (FGroup = nil) or (FModel.DynamicAttr = '') or FReadPartial or
     (FCriteria.Count >= DYNAMIC_MAX_CRITERIA) then Exit;
  if not DropInvalidDraft then Exit;
  u := Default(TLdapUrl);
  c := Conn;
  if (c <> nil) and (c.Profile.BaseDns.Count > 0) then u.BaseDn := c.Profile.BaseDns[0];
  u.Scope := ssSubtree;
  u.Filter := '(objectClass=person)';
  FCriteria.Add(BuildLdapUrl(u));
  FillList(FCriteria.Count - 1);
  NoteEdit;
  if Showing and FFilter.CanFocus then FFilter.SetFocus;
end;

procedure TDynamicGroupDialog.RemoveCriterion;
var
  i: Integer;
begin
  i := FList.ItemIndex;
  if (i < 0) or (i >= FCriteria.Count) or FReadPartial then Exit;
  FCriteria.Delete(i);
  if i >= FCriteria.Count then i := FCriteria.Count - 1;
  FillList(i);
  NoteEdit;
end;

procedure TDynamicGroupDialog.BuilderClick(Sender: TObject);
var
  f: string;
begin
  f := FFilter.Text;
  if EditFilterGraphically(Self, FCtx, FProfileUuid, f) then FFilter.Text := f;
end;

procedure TDynamicGroupDialog.Preview;
var
  u: TLdapUrl;
  err: string;
begin
  if (FList.ItemIndex < 0) or Tasks.Pending('preview') or not FEditorValid or FReadPartial then Exit;
  if not ParseLdapUrl(FCriteria[FList.ItemIndex], u, err) then
  begin
    SetStatus(err, usError);
    Exit;
  end;
  if u.Host <> '' then
  begin
    FPreviewNote.Caption := Format(rsDgOtherHost, [u.Host]);
    Exit;
  end;
  FPreviewList.Items.Clear;
  FPreviewCount := 0;
  FPreviewNote.Caption := rsDgPreviewing;
  Search(DynamicPreviewRequest(u, DYNAMIC_PREVIEW_LIMIT), 'preview');
  UpdateButtons;
end;

procedure TDynamicGroupDialog.InvalidatePreview;
begin
  // Recherche annulee par son identifiant, lots deja postes ignores: la liste ne montre jamais les
  // membres d'un autre critere que celui affiche.
  Tasks.Cancel('preview');
  FPreviewCount := 0;
  FPreviewList.Items.Clear;
  FPreviewNote.Caption := '';
end;

procedure TDynamicGroupDialog.OnEntries(AMsg: TEntriesMsg);
var
  i: Integer;
begin
  if Tasks.Current.Tag <> 'preview' then Exit;
  FPreviewList.Items.BeginUpdate;
  try
    for i := 0 to AMsg.Entries.Count - 1 do
    begin
      FPreviewList.Items.Add(TLdapEntry(AMsg.Entries[i]).Dn);
      Inc(FPreviewCount);
    end;
  finally
    FPreviewList.Items.EndUpdate;
  end;
  if not AMsg.Final then Exit;
  case SearchOutcome(AMsg.Completion) of
    soComplete:
      FPreviewNote.Caption := Format(rsDgPreviewDone, [FPreviewCount]);
    soFailed:
      FPreviewNote.Caption := Format(rsOpsFailed, [ErrorToText(AMsg.Error)]);
  else
    // Borne atteinte: jamais presentee comme la liste complete.
    if (FPreviewCount >= DYNAMIC_PREVIEW_LIMIT) and
       (AMsg.Completion.SizeLimitHit or AMsg.Completion.ClientLimitHit) then
      FPreviewNote.Caption := Format(rsDgPreviewLimit, [FPreviewCount, DYNAMIC_PREVIEW_LIMIT])
    else
      FPreviewNote.Caption := Format(rsDgPreviewPartial, [FPreviewCount,
        CoverageDescription(srsDone, AMsg.Completion)]);
  end;
  UpdateButtons;
end;

procedure TDynamicGroupDialog.Apply;
var
  change: TLdapChange;
  err, note, assertion: string;
  news: array of string;
  i: Integer;
  c: TDirectoryConnection;
begin
  if (FGroup = nil) or Tasks.WritesInFlight or not FEditorValid or FReadPartial then Exit;
  InvalidatePreview;
  SetLength(news, FCriteria.Count);
  for i := 0 to FCriteria.Count - 1 do
    news[i] := FCriteria[i];
  change := PlanDynamicCriteria(FGroup, FModel, FOriginal, news, err);
  if change = nil then
  begin
    SetStatus(err, usWarning);
    Exit;
  end;
  // Precondition de version (RFC 4528) sur le marqueur lu avec le groupe. Sans controle ou sans marqueur,
  // le repli non atomique est annonce avant la confirmation, jamais en douce.
  assertion := '';
  c := Conn;
  if (c <> nil) and ServerSupportsControl(c.RootDse, LDAP_CONTROL_ASSERTION_OID) then
    assertion := VersionAssertion(FGroup);
  note := Format(rsDgNote, [FModel.DynamicAttr]);
  if assertion = '' then
    note := note + LineEnding + rsDgNoAssertion;
  SubmitChange(change, note, assertion);
  UpdateButtons;
end;

procedure TDynamicGroupDialog.OnWrite(AMsg: TWriteMsg);
var
  ok: Boolean;
begin
  if Tasks.Current.Tag <> 'write' then
  begin
    inherited OnWrite(AMsg);
    Exit;
  end;
  ok := ReportWrite(AMsg);
  // Reussie ou inconnue: le groupe et les vues qui le montrent sont relus. En echec (valeur changee
  // entre-temps), relire avant de refaire.
  if Assigned(FOnWritten) and (ok or (AMsg.Result.Error.Category = lecUnknownOutcome)) then
    FOnWritten(FProfileUuid, FDn);
  if ok then
  begin
    Reload;
    SetStatus(rsDgWritten, usOk);
  end
  else if AMsg.Result.Error.Category = lecAssertionFailed then
  begin
    // Modification concurrente prise par l'assertion: relecture, les criteres repartent de l'etat reel,
    // rien n'est rejoue.
    Reload;
    SetStatus(rsDgConcurrent, usError);
  end
  else
    UpdateButtons;
end;

procedure TDynamicGroupDialog.OnFailed(AMsg: TTaskFailedMsg);
begin
  // Une ecriture sans resultat type n'est pas prouvee non partie: issue inconnue. Le groupe lu devient
  // caduc, la relecture est offerte, le brouillon reste.
  if Tasks.Current.Tag = 'preview' then
    FPreviewNote.Caption := Format(rsOpsFailed, [AMsg.Text]);
  inherited OnFailed(AMsg);
  if (Tasks.Current.Tag = 'write') and Assigned(FOnWritten) then FOnWritten(FProfileUuid, FDn);
end;

procedure TDynamicGroupDialog.OnStale(AMsg: TUiMessage);
begin
  inherited OnStale(AMsg);
  if Tasks.Current.Tag = 'preview' then FPreviewNote.Caption := rsTdReadSessionLost;
  if (Tasks.Current.Tag = 'write') and Assigned(FOnWritten) then FOnWritten(FProfileUuid, FDn);
end;

procedure TDynamicGroupDialog.AddClick(Sender: TObject);
begin
  AddCriterion;
end;

procedure TDynamicGroupDialog.RemoveClick(Sender: TObject);
begin
  RemoveCriterion;
end;

procedure TDynamicGroupDialog.PreviewClick(Sender: TObject);
begin
  Preview;
end;

procedure TDynamicGroupDialog.ApplyClick(Sender: TObject);
begin
  Apply;
end;

procedure TDynamicGroupDialog.ReloadClick(Sender: TObject);
begin
  ReadAgain;
end;

procedure TDynamicGroupDialog.ReadAgain;
begin
  // Ecriture en vol: pas de relecture concurrente, celle qui suit l'issue part toute seule.
  if Tasks.WritesInFlight then
  begin
    SetStatus(rsDgWriteWaitReload, usWarning);
    Exit;
  end;
  if HasUnsavedWork and
     (RtMessageDlg(rsDgTitle, rsDgDiscard, mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then
    Exit;
  Reload;
end;

function TDynamicGroupDialog.HasUnsavedWork: Boolean;
begin
  Result := Modified or not FEditorValid;
end;

function TDynamicGroupDialog.ReadAgainEnabled: Boolean;
begin
  Result := FReloadBtn.Enabled;
end;

function TDynamicGroupDialog.CriteriaText: string;
begin
  Result := FCriteria.Text;
end;

function TDynamicGroupDialog.ModelText: string;
begin
  Result := FModelLabel.Caption;
end;

function TDynamicGroupDialog.StatusText: string;
begin
  Result := FStatus.Caption;
end;

function TDynamicGroupDialog.ProblemText: string;
begin
  Result := FProblem.Caption;
end;

function TDynamicGroupDialog.PreviewText: string;
begin
  Result := FPreviewList.Items.Text;
end;

function TDynamicGroupDialog.PreviewNote: string;
begin
  Result := FPreviewNote.Caption;
end;

procedure TDynamicGroupDialog.SelectCriterion(AIndex: Integer);
begin
  FList.ItemIndex := AIndex;
  ListClick(FList);
end;

procedure TDynamicGroupDialog.SetCriterion(const ABase: string; AScope: Integer; const AFilter,
  AAttrs: string);
begin
  FUpdating := True;
  try
    FBase.Text := ABase;
    FScope.ItemIndex := AScope;
    FFilter.Text := AFilter;
    FAttrs.Text := AAttrs;
  finally
    FUpdating := False;
  end;
  EditorChanged(nil);
end;

function TDynamicGroupDialog.ApplyEnabled: Boolean;
begin
  Result := FApplyBtn.Enabled;
end;

end.
