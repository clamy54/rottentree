// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uMembershipDialog;

{$mode objfpc}{$H+}

// Appartenances: membres d'un groupe ou groupes d'une entree, imbriques, avec le chemin, les
// cycles et ce qu'on ignore. Ajout et retrait dans l'attribut du groupe, jamais dans memberOf:
// il est calcule par le serveur, l'ecrire c'est parler a un mur.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, ComCtrls, Forms, Graphics, Dialogs,
  uAppContext, uRtCombo, uOpsDialog, uUiInbox, uDirectoryWorker, uDirectoryOps, uLdapEntry,
  uMembershipExplorer, uConnectionProfile;

type
  TOpenDnEvent = procedure(const AProfileUuid, ADn: string) of object;

  TGroupAction = (gaNone, gaAddTo, gaRemoveFrom);

  TMembershipDialog = class(TOpsDialog)
  private
    FDn: string;
    FServer: TProviderKind;
    FOps: TConnectionOps;
    FExplorer: TMembershipExplorer;
    FDirection: TRtComboBox;
    FTree: TTreeView;
    FInfo: TLabel;
    FModelLabel: TLabel;
    FRoot: TLdapEntry;
    FGroupAction: TGroupAction;
    FWriteGroup: string;
    FAddBtn, FRemoveBtn, FCriteriaBtn, FExploreBtn: TButton;
    FPreview: TStringList;
    FOnOpen: TOpenDnEvent;
    FOnWritten: TOpenDnEvent;
    FWriteMember: string;
    procedure BuildUi;
    procedure Explore;
    procedure FillTree;
    function SelectedNode: Integer;
    procedure ExploreClick(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure PreviewClick(Sender: TObject);
    procedure CriteriaClick(Sender: TObject);
    procedure TreeChange(Sender: TObject; Node: TTreeNode);
    function SearchBase: string;
    procedure ShowPreview(const ANote: string);
    procedure UpdateButtons;
    function ViewsGroupsOfEntry: Boolean;
    procedure GroupRead(AMsg: TEntryMsg);
    function RootUsable: Boolean;
    function Working: Boolean;
  protected
    procedure OnEntry(AMsg: TEntryMsg); override;
    procedure OnEntries(AMsg: TEntriesMsg); override;
    procedure OnWrite(AMsg: TWriteMsg); override;
    procedure OnFailed(AMsg: TTaskFailedMsg); override;
    procedure OnStale(AMsg: TUiMessage); override;
    procedure UpdateActions; override;
  public
    constructor CreateMembership(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
      ADn: string; AMemberOf: Boolean; AOnOpen: TOpenDnEvent);
    destructor Destroy; override;
    procedure AddMember;
    procedure RemoveMember;
    procedure Reexplore;
    function ExploreEnabled: Boolean;
    function StatusText: string;
    function AddButtonText: string;
    function AddEnabled: Boolean;
    property OnWritten: TOpenDnEvent read FOnWritten write FOnWritten;
  end;

procedure ShowMembershipDialog(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  ADn: string; AMemberOf: Boolean; AOnOpen: TOpenDnEvent; AOnWritten: TOpenDnEvent = nil);

implementation

uses
  uUiKit, uRtList, uConnections,
  uChangeSet, uSearchModel, uGroupModel, uServerKind,
  uStrings, uLdapErrors, uDirectoryService, uEntryPickDialog, uDynamicGroupDialog, uTaskDialog;

resourcestring
  rsMemTitle = 'Group membership';
  rsMemDirMembers = 'Members of this group (nested)';
  rsMemDirMemberOf = 'Groups this entry belongs to (nested)';
  rsMemExplore = 'Explore';
  rsMemAdd = 'Add member...';
  rsMemRemove = 'Remove member';
  rsMemOpen = 'Open entry';
  rsMemPreview = 'Preview dynamic members';
  rsMemCriteria = 'Edit criteria...';
  rsMemAddPrompt = 'DN of the new direct member';
  rsMemAddUidPrompt = 'uid of the new member (memberUid holds identifiers, not DNs)';
  rsMemExploring = 'Exploring: %d node(s)...';
  rsMemDone = '%d node(s), %d cycle(s)%s';
  rsMemLimit = ', exploration bound reached (partial)';
  rsMemCycleNote = 'cycle';
  rsMemUnreadable = 'unreadable';
  rsMemSameAs = 'already shown above';
  rsMemAdNote = 'Active Directory: primary group membership is not stored in member or memberOf; ' +
    'it is shown as "primary group". Unreadable groups stay unknown.';
  rsMemModel = 'Group model: %s';
  rsMemNotDirect = 'Select a direct member of the explored group.';
  rsMemPreviewTitle = 'Dynamic members (first %d)';
  rsMemPreviewPartial = 'Partial result: %s';
  rsMemFailed = 'Exploration failed: %s';
  rsMemAddTo = 'Add to group...';
  rsMemRemoveFrom = 'Remove from group';
  rsMemAddToPrompt = 'DN of the group to add this entry to';
  rsMemNotDirectGroup = 'Select a group this entry is a direct member of (a primary group is changed ' +
    'on the account itself).';
  rsMemNotAGroup = '%s is not a group.';
  rsMemReadingGroup = 'Reading the group...';
  rsMemGroupUnread = 'The group could not be read: %s';

const
  PREVIEW_LIMIT = 200;

procedure ShowMembershipDialog(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  ADn: string; AMemberOf: Boolean; AOnOpen: TOpenDnEvent; AOnWritten: TOpenDnEvent);
var
  d: TMembershipDialog;
begin
  d := TMembershipDialog.CreateMembership(AOwner, ACtx, AProfileUuid, ADn, AMemberOf, AOnOpen);
  try
    d.FOnWritten := AOnWritten;
    d.ShowModal;
  finally
    d.Free;
  end;
end;

constructor TMembershipDialog.CreateMembership(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, ADn: string; AMemberOf: Boolean; AOnOpen: TOpenDnEvent);
var
  c: TDirectoryConnection;
begin
  inherited CreateFor(AOwner, ACtx, AProfileUuid, rsMemTitle + ' - ' + ADn, 860, 660);
  SetIcon('users');
  FDn := ADn;
  FOnOpen := AOnOpen;
  FPreview := TStringList.Create;
  c := Conn;
  FServer := pkOther;
  if c <> nil then FServer := EffectiveServerKind(c.Profile, c.RootDse);
  FOps := TConnectionOps.Create(ACtx.Connections, AProfileUuid, Self);
  AttachOps(FOps, 'explore');
  BuildUi;
  if AMemberOf then FDirection.ItemIndex := 1 else FDirection.ItemIndex := 0;
  ApplyTheme;
  Explore;
end;

destructor TMembershipDialog.Destroy;
begin
  FExplorer.Free;
  FOps.Free;
  FRoot.Free;
  FPreview.Free;
  inherited Destroy;
end;

procedure TMembershipDialog.BuildUi;
var
  row, bar: TPanel;
begin
  row := MakePanel(Body, alTop, 34);
  FExploreBtn := MakeButton(row, rsMemExplore, @ExploreClick, alRight);
  FDirection := TRtComboBox.Create(row);
  FDirection.Parent := row;
  FDirection.Align := alClient;
  FDirection.Style := csDropDownList;
  FDirection.BorderSpacing.Around := 3;
  FDirection.Items.Add(rsMemDirMembers);
  FDirection.Items.Add(rsMemDirMemberOf);
  FModelLabel := MakeLabel(Body, '');
  bar := MakePanel(Body, alBottom, 36);
  FAddBtn := MakeButton(bar, rsMemAdd, @AddClick);
  FRemoveBtn := MakeButton(bar, rsMemRemove, @RemoveClick);
  MakeButton(bar, rsMemPreview, @PreviewClick);
  FCriteriaBtn := MakeButton(bar, rsMemCriteria, @CriteriaClick);
  MakeButton(bar, rsMemOpen, @OpenClick);
  FInfo := MakeLabel(Body, '', alBottom);
  FInfo.WordWrap := True;
  FTree := TTreeView.Create(Body);
  FTree.Parent := Body;
  FTree.Align := alClient;
  FTree.ReadOnly := True;
  FTree.HideSelection := False;
  FTree.OnChange := @TreeChange;
  if FServer = pkActiveDirectory then
    MakeLabel(Body, rsMemAdNote, alBottom).WordWrap := True;
  AddButton(rsClose, mrClose, True, True);
end;

function TMembershipDialog.SearchBase: string;
begin
  Result := DefaultSearchBase(Conn);
end;

procedure TMembershipDialog.Explore;
var
  c: TDirectoryConnection;
  dir: TExploreDirection;
begin
  if Tasks.Pending('group') or Tasks.WritesInFlight then Exit;
  c := Conn;
  if c = nil then
  begin
    SetStatus(rsTdNotConnected, usError);
    Exit;
  end;
  // Annulation ciblee des explorations remplacees, jamais d'une ecriture partie ni d'un apercu.
  // Sans elle, les anciennes tournaient cote serveur jusqu'au bout, pour personne.
  Tasks.Cancel('explore');
  Tasks.Cancel('root');
  FreeAndNil(FExplorer);
  // Une lecture precedente ne sert plus jamais de base d'ecriture: on n'ecrit pas sur la foi de
  // souvenirs.
  FreeAndNil(FRoot);
  Tasks.InvalidateModel;
  FTree.Items.Clear;
  if FDirection.ItemIndex = 1 then dir := edMemberOf else dir := edMembers;
  FExplorer := TMembershipExplorer.Create(FOps, FServer, SearchBase, c.Profile.PageSize);
  ReadEntry(FDn, ['objectClass', 'member', 'uniqueMember', 'memberUid', 'memberURL',
    'primaryGroupToken', 'groupType', 'uid'], 'root');
  UpdateButtons;
  if not FExplorer.Start(FDn, dir) then
    SetStatus(Format(rsMemFailed, [ErrorToText(FExplorer.LastError)]), usError)
  else
    SetStatus(Format(rsMemExploring, [1]));
end;

procedure TMembershipDialog.ExploreClick(Sender: TObject);
begin
  Explore;
end;

procedure TMembershipDialog.FillTree;
var
  nodes: array of TTreeNode;
  i: Integer;
  n: TMemberNode;
  lineText, extra: string;
  up: TTreeNode;
  limit: string;
begin
  FTree.Items.BeginUpdate;
  try
    FTree.Items.Clear;
    SetLength(nodes, FExplorer.Graph.Count);
    for i := 0 to FExplorer.Graph.Count - 1 do
    begin
      n := FExplorer.Graph[i];
      lineText := RdnCaption(n.Dn);
      if i > 0 then
      begin
        extra := MembershipKindName(n.Kind);
        if n.Cycle then extra := extra + ', ' + rsMemCycleNote;
        if n.Unreadable then extra := extra + ', ' + rsMemUnreadable;
        if (n.SameAs >= 0) and not n.Cycle then extra := extra + ', ' + rsMemSameAs;
        if (n.Note <> '') and not n.Cycle then extra := extra + ', ' + n.Note;
        lineText := lineText + '  (' + extra + ')';
      end;
      if n.Parent < 0 then up := nil else up := nodes[n.Parent];
      nodes[i] := FTree.Items.AddChildObject(up, lineText, Pointer(PtrInt(i)));
    end;
    if Length(nodes) > 0 then nodes[0].Expand(False);
  finally
    FTree.Items.EndUpdate;
  end;
  if FExplorer.Graph.LimitHit then limit := rsMemLimit else limit := '';
  SetStatus(Format(rsMemDone, [FExplorer.Graph.Count, FExplorer.Graph.CycleCount, limit]),
    usOk);
end;

function TMembershipDialog.SelectedNode: Integer;
begin
  Result := -1;
  if (FTree.Selected <> nil) and (FExplorer <> nil) then
    Result := PtrInt(FTree.Selected.Data);
end;

procedure TMembershipDialog.TreeChange(Sender: TObject; Node: TTreeNode);
var
  i: Integer;
begin
  i := SelectedNode;
  if i < 0 then Exit;
  FInfo.Caption := FExplorer.Graph.PathText(i) + LineEnding + FExplorer.Graph[i].Dn;
end;

procedure TMembershipDialog.OnEntry(AMsg: TEntryMsg);
var
  model: TGroupModel;
begin
  if Tasks.Current.Tag = 'root' then
  begin
    FreeAndNil(FRoot);
    FRoot := AMsg.Entry;
    AMsg.Entry := nil;
    if FRoot <> nil then StampModel(AMsg);
    model := DetectGroupModel(FRoot, FServer);
    FModelLabel.Caption := Format(rsMemModel, [GroupKindName(model.Kind)]);
    Exit;
  end;
  if Tasks.Current.Tag = 'group' then
  begin
    GroupRead(AMsg);
    Exit;
  end;
  if (FExplorer = nil) or not FExplorer.OwnsTask(AMsg.TaskId) then Exit;
  case FExplorer.HandleEntry(AMsg) of
    eoProgress: SetStatus(Format(rsMemExploring, [FExplorer.Graph.Count]));
    eoFinished: FillTree;
    eoFailed: SetStatus(Format(rsMemFailed, [ErrorToText(FExplorer.LastError)]), usError);
  end;
end;

procedure TMembershipDialog.OnEntries(AMsg: TEntriesMsg);
var
  i: Integer;
begin
  if Tasks.Current.Tag = 'preview' then
  begin
    for i := 0 to AMsg.Entries.Count - 1 do
      FPreview.Add(TLdapEntry(AMsg.Entries[i]).Dn);
    if AMsg.Final then
    begin
      if SearchOutcome(AMsg.Completion) <> soComplete then
        ShowPreview(Format(rsMemPreviewPartial, [ResultCodeName(AMsg.Completion.ResultCode)]))
      else
        ShowPreview('');
    end;
    Exit;
  end;
  if (FExplorer = nil) or not FExplorer.OwnsTask(AMsg.TaskId) then Exit;
  case FExplorer.HandleEntries(AMsg) of
    eoProgress: SetStatus(Format(rsMemExploring, [FExplorer.Graph.Count]));
    eoFinished: FillTree;
    eoFailed: SetStatus(Format(rsMemFailed, [ErrorToText(FExplorer.LastError)]), usError);
  end;
end;

procedure TMembershipDialog.OnFailed(AMsg: TTaskFailedMsg);
begin
  inherited OnFailed(AMsg);
  if (FExplorer <> nil) and FExplorer.OwnsTask(AMsg.TaskId) then FExplorer.Cancel;
end;

procedure TMembershipDialog.OnStale(AMsg: TUiMessage);
begin
  inherited OnStale(AMsg);
  FreeAndNil(FRoot);
  Tasks.InvalidateModel;
  if FExplorer <> nil then FExplorer.Cancel;
  FTree.Items.Clear;
  FModelLabel.Caption := '';
end;

procedure TMembershipDialog.UpdateActions;
begin
  UpdateButtons;
end;

function TMembershipDialog.RootUsable: Boolean;
begin
  Result := (FRoot <> nil) and Tasks.ModelCurrent;
end;

function TMembershipDialog.Working: Boolean;
begin
  Result := Tasks.Pending('root') or Tasks.Pending('group') or Tasks.WritesInFlight;
end;

procedure TMembershipDialog.OnWrite(AMsg: TWriteMsg);
var
  ok: Boolean;
begin
  if Tasks.Current.Tag <> 'write' then Exit;
  ok := ReportWrite(AMsg);
  // Issue inconnue comprise: l'etat serveur a pu changer, les vues ouvertes du groupe et du
  // membre relisent.
  if Assigned(FOnWritten) and (ok or (AMsg.Result.Error.Category = lecUnknownOutcome)) then
  begin
    if FWriteGroup <> '' then FOnWritten(FProfileUuid, FWriteGroup) else FOnWritten(FProfileUuid, FDn);
    if FWriteMember <> '' then FOnWritten(FProfileUuid, FWriteMember);
  end;
  if ok then Explore;
end;

procedure TMembershipDialog.AddClick(Sender: TObject);
var
  model: TGroupModel;
  dn, uid, err: string;
  change: TLdapChange;
begin
  if not RootUsable or Working then Exit;
  if ViewsGroupsOfEntry then
  begin
    dn := '';
    if not PickDirectoryEntry(Self, FCtx, FProfileUuid, rsMemAddTo, rsMemAddToPrompt, SearchBase, '', dn) then
      Exit;
    FGroupAction := gaAddTo;
    if ReadEntry(Trim(dn), GROUP_READ_ATTRS, 'group') <> 0 then SetStatus(rsMemReadingGroup);
    UpdateButtons;
    Exit;
  end;
  model := DetectGroupModel(FRoot, FServer);
  dn := '';
  uid := '';
  if model.ValuesAreDns or (model.MemberAttr = '') then
  begin
    if not PickDirectoryEntry(Self, FCtx, FProfileUuid, rsMemAdd, rsMemAddPrompt, SearchBase, '', dn) then
      Exit;
    dn := Trim(dn);
  end
  else
  begin
    if not PickDirectoryEntry(Self, FCtx, FProfileUuid, rsMemAdd, rsMemAddUidPrompt, SearchBase, 'uid', uid) then
      Exit;
    uid := Trim(uid);
  end;
  change := PlanAddMember(FRoot, model, dn, uid, err);
  if change = nil then
  begin
    SetStatus(err, usWarning);
    Exit;
  end;
  FWriteGroup := '';
  FWriteMember := dn;
  SubmitChange(change, Format(rsMemModel, [GroupKindName(model.Kind)]));
  UpdateButtons;
end;

procedure TMembershipDialog.RemoveClick(Sender: TObject);
var
  i: Integer;
  model: TGroupModel;
  change: TLdapChange;
  err, v: string;
begin
  i := SelectedNode;
  if not RootUsable or Working then Exit;
  if ViewsGroupsOfEntry then
  begin
    if (i <= 0) or (FExplorer.Graph[i].Parent <> 0) or (FExplorer.Graph[i].Kind <> mkDirect) then
    begin
      SetStatus(rsMemNotDirectGroup, usWarning);
      Exit;
    end;
    FGroupAction := gaRemoveFrom;
    if ReadEntry(FExplorer.Graph[i].Dn, GROUP_READ_ATTRS, 'group') <> 0 then SetStatus(rsMemReadingGroup);
    UpdateButtons;
    Exit;
  end;
  if (i <= 0) or (FExplorer.Direction <> edMembers) or (FExplorer.Graph[i].Parent <> 0) or
     (FExplorer.Graph[i].Kind <> mkDirect) then
  begin
    SetStatus(rsMemNotDirect, usWarning);
    Exit;
  end;
  model := DetectGroupModel(FRoot, FServer);
  v := FExplorer.Graph[i].Dn;
  if model.ValuesAreDns then
    change := PlanRemoveMember(FRoot, model, v, '', err)
  else
    change := PlanRemoveMember(FRoot, model, '', v, err);
  if change = nil then
  begin
    SetStatus(err, usWarning);
    Exit;
  end;
  FWriteGroup := '';
  if model.ValuesAreDns then FWriteMember := v else FWriteMember := '';
  SubmitChange(change, Format(rsMemModel, [GroupKindName(model.Kind)]));
  UpdateButtons;
end;

function TMembershipDialog.ViewsGroupsOfEntry: Boolean;
begin
  Result := (FExplorer <> nil) and (FExplorer.Direction = edMemberOf);
end;

procedure TMembershipDialog.UpdateButtons;
var
  model: TGroupModel;
  usable: Boolean;
begin
  if FAddBtn = nil then Exit;
  model := DetectGroupModel(FRoot, FServer);
  usable := RootUsable and not Working;
  if ViewsGroupsOfEntry then
  begin
    FAddBtn.Caption := rsMemAddTo;
    FRemoveBtn.Caption := rsMemRemoveFrom;
    FAddBtn.Enabled := usable;
    FRemoveBtn.Enabled := FAddBtn.Enabled;
  end
  else
  begin
    FAddBtn.Caption := rsMemAdd;
    FRemoveBtn.Caption := rsMemRemove;
    FAddBtn.Enabled := usable and (model.Kind <> gkNotGroup) and (model.MemberAttr <> '');
    FRemoveBtn.Enabled := FAddBtn.Enabled;
  end;
  FCriteriaBtn.Enabled := usable and (model.Kind = gkDynamicUrl);
  // Pas d'exploration pendant une lecture de groupe ou une ecriture: elle remplacerait sous ses
  // pieds la racine dont l'ecriture depend.
  FExploreBtn.Enabled := not Tasks.Pending('group') and not Tasks.WritesInFlight;
  FModelLabel.Visible := not ViewsGroupsOfEntry or (model.Kind <> gkNotGroup);
end;

procedure TMembershipDialog.GroupRead(AMsg: TEntryMsg);
var
  model: TGroupModel;
  change: TLdapChange;
  err, uid: string;
begin
  if AMsg.Entry = nil then
  begin
    SetStatus(Format(rsMemGroupUnread, [ErrorToText(AMsg.Error)]), usError);
    Exit;
  end;
  model := DetectGroupModel(AMsg.Entry, FServer);
  if model.Kind = gkNotGroup then
  begin
    SetStatus(Format(rsMemNotAGroup, [AMsg.Entry.Dn]), usWarning);
    Exit;
  end;
  uid := '';
  if FRoot <> nil then uid := string(FRoot.FirstValue('uid', ''));
  if FGroupAction = gaAddTo then
    change := PlanAddMember(AMsg.Entry, model, FDn, uid, err)
  else
    change := PlanRemoveMember(AMsg.Entry, model, FDn, uid, err);
  if change = nil then
  begin
    SetStatus(err, usWarning);
    Exit;
  end;
  FWriteGroup := AMsg.Entry.Dn;
  FWriteMember := FDn;
  SubmitChange(change, Format(rsMemModel, [GroupKindName(model.Kind)]));
end;

function TMembershipDialog.AddButtonText: string;
begin
  Result := FAddBtn.Caption;
end;

function TMembershipDialog.AddEnabled: Boolean;
begin
  Result := FAddBtn.Enabled;
end;

procedure TMembershipDialog.AddMember;
begin
  AddClick(nil);
end;

procedure TMembershipDialog.Reexplore;
begin
  ExploreClick(nil);
end;

function TMembershipDialog.ExploreEnabled: Boolean;
begin
  Result := FExploreBtn.Enabled;
end;

procedure TMembershipDialog.RemoveMember;
begin
  RemoveClick(nil);
end;

function TMembershipDialog.StatusText: string;
begin
  Result := FStatus.Caption;
end;

procedure TMembershipDialog.OpenClick(Sender: TObject);
var
  i: Integer;
begin
  i := SelectedNode;
  if (i < 0) or not Assigned(FOnOpen) then Exit;
  if FExplorer.Graph[i].Leaf and (FExplorer.Graph[i].Kind <> mkPrimary) then Exit;
  FOnOpen(FProfileUuid, FExplorer.Graph[i].Dn);
end;

procedure TMembershipDialog.PreviewClick(Sender: TObject);
var
  i: Integer;
  url: TLdapUrl;
  err: string;
  req: TSearchRequest;
begin
  i := SelectedNode;
  if (i < 0) or (FExplorer.Graph[i].Kind <> mkDynamic) then Exit;
  if not ParseLdapUrl(FExplorer.Graph[i].Dn, url, err) then
  begin
    SetStatus(err, usError);
    Exit;
  end;
  if url.Host <> '' then
  begin
    SetStatus(Format(rsGroupUrlHost, [url.Host]), usWarning);
    Exit;
  end;
  req := DynamicPreviewRequest(url, PREVIEW_LIMIT);
  FPreview.Clear;
  Tasks.Cancel('preview');
  Search(req, 'preview');
end;

procedure TMembershipDialog.CriteriaClick(Sender: TObject);
begin
  ShowDynamicGroupDialog(Self, FCtx, FProfileUuid, FDn, FOnWritten);
  Explore;
end;

procedure TMembershipDialog.ShowPreview(const ANote: string);
var
  d: TRtDialog;
  m: TMemo;
begin
  d := TRtDialog.CreateDialog(Self, Format(rsMemPreviewTitle, [PREVIEW_LIMIT]), 700, 500);
  d.SetIcon('users');
  try
    if ANote <> '' then MakeLabel(d.Body, ANote).Font.Color := DialogStateColor(usWarning);
    m := MakeMemo(d.Body);
    m.ReadOnly := True;
    m.Lines.Assign(FPreview);
    d.AddButton(rsClose, mrOk, True, True);
    d.ApplyTheme;
    d.ShowModal;
  finally
    d.Free;
  end;
end;

end.
