// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDirectoryTab;

{$mode objfpc}{$H+}

// Arbre de l'annuaire. Paresseux par principe: un niveau n'est lu que si quelqu'un l'ouvre.
// Naviguer n'ecrit jamais rien; Apply passe par l'apercu du delta, et un conflit d'Assertion
// montre lu, local et serveur cote a cote.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, ExtCtrls, StdCtrls, Menus, Forms, Graphics,
  Dialogs, Clipbrd, LCLType, uAppContext, uRtCombo, uConnections, uUiInbox, uDirectoryWorker, uLdapEntry,
  uSearchModel, uChangeSet, uLdapDn, uLdapErrors, uTreeScrollBar, uSearchBox, uDirectoryOps, uUiKit,
  uSubtreeDeletion, uEntryEditor, uConnectionProfile, uSubtreeProgress, uRtButton, uTaskTracker;

resourcestring
  rsDirLoading = 'Loading...';
  rsDirMore = 'Partial list: %s';
  rsDirRange = '[%d..%d]';
  rsDirPartialClientLimit = 'Partial list: stopped at %d entries (interactive size limit, profile Limits tab)';
  rsDirPartialServerLimit = 'Partial list: the server''s size limit was reached after %d entries';
  rsDirPartialTimeLimit = 'Partial list: the time limit was reached after %d entries';
  rsDirPartialReferrals = 'Partial list: referrals or continuations were not followed';
  rsDirPartialPaging = 'Partial list: paging anomaly (%s)';
  rsDirPartialDecode = 'Partial list: %d entries could not be decoded';
  rsDirDnHint = 'Go to DN…';
  rsDirSearchHint = 'Search: text or LDAP filter…';
  rsDirExpert = 'Expert search';
  rsDirMenuNewUser = 'New user...';
  rsDirMenuNewComputer = 'New computer...';
  rsDirMenuNewGroup = 'New group...';
  rsDirMenuNewOu = 'New organizational unit...';
  rsDirExpertHint = 'Open the expert search (filter builder, attributes, limits, history) with this base, ' +
    'filter and scope';
  rsDirMenuNewChild = 'New child entry...';
  rsDirMenuRename = 'Rename or move...';
  rsDirMenuDelete = 'Delete...';
  rsDirMenuRefresh = 'Refresh';
  rsDirMenuCopyDn = 'Copy DN';
  rsDirMenuSearchHere = 'Search from here...';
  rsDirMenuExportEntry = 'Export LDIF...';
  rsDirMenuPassword = 'Password tools...';
  rsDirMenuProperties = 'Refresh entry';
  rsDirDeleteLeaf = 'Delete this entry?';
  rsDirSessionReplaced = 'The connection was re-established.';
  rsDirChildrenLost = 'The children of %s were not read (%s): expand the node again.';
  rsDirDeleteNoAssertion = 'This server does not announce the Assertion control: '
    + 'the entry is deleted even if it changed since it was displayed.';
  rsDirDeleteNotRead = 'The entry content was not read: the deletion does not '
    + 'depend on its version.';
  rsDirNotConnected = 'Not connected.';
  rsDirSubtreeIncomplete = 'The subtree could not be enumerated completely; nothing was deleted. %s';
  rsDirSubtreeChanged = 'The subtree changed since the preview. Nothing was deleted; preview again.';
  rsDirSubtreePreview = '%d entries under %s, deleted from the leaves to the root. No recursive delete control is used.';
  rsDirSubtreeNoAssertion = 'This server does not announce the Assertion control: '
    + 'an entry modified after this preview would still be deleted.';
  rsDirSubtreeUnprotected = '%d deletion(s) were sent without a version assertion '
    + '(no readable version marker).';
  rsDirSubtreeDeleting = 'deleting %d entries, leaves first';
  rsDirSubtreeDone = '%d entries deleted under %s';
  rsDirSubtreeStopped = 'Subtree deletion stopped: %d deletion(s) confirmed, %d not attempted.';
  rsDirSubtreeRefused = 'Refused by the server (entry kept): %s.';
  rsDirSubtreeUnconfirmed = 'Sent, outcome not confirmed (check this entry): %s.';
  rsDirSubtreeResume = 'To finish, delete %s again once connected: what remains is listed again, ' +
    'nothing already deleted is sent twice.';
  rsDirSubtreeCancelledEarly = 'Subtree deletion cancelled before any entry was deleted. %s';
  rsDirSubtreeUserStopped = 'Subtree deletion stopped at your request: %d deletion(s) confirmed, %d not attempted.';
  rsDirSubtreeStoppedEarly = 'Subtree deletion stopped at your request: nothing was deleted.';
  rsDirSubtreeNotConfirmed = 'Deletion not confirmed: nothing was deleted.';
  rsDirSubtreeUnprotected2 = '%d of %d entries have no readable version marker: their deletion '
    + 'would not fail if another client modified them meanwhile. Delete anyway?';
  rsDirSubtreeUnprotectedRefused = 'Deletion cancelled: %d entries without version protection.';
  rsDirSubtreePreviewTruncated = 'Only the first %d deletions are listed below.';
  rsDirRenameNewRdn = 'New RDN';
  rsDirRenameNewParent = 'New parent DN (unchanged to rename only)';
  rsDirRenameUnderItself = 'An entry cannot be moved under itself.';
  rsDirRenameDeleteOld = 'Remove the old RDN value from the entry (deleteOldRDN)?';
  rsDirRenameRemoveOld = 'Remove old value';
  rsDirRenameKeepOld = 'Keep old value';
  rsDirCancel = 'Cancel';
  rsDirInvalidDn = 'invalid DN: %s';
  rsDirMenuClone = 'Clone entry...';
  rsDirMenuDynamic = 'Dynamic group criteria...';
  rsDirMenuCopySubtree = 'Copy subtree...';
  rsDirMenuMoveServer = 'Move subtree to another server...';
  rsDirMenuMembers = 'Group members...';
  rsDirMenuMemberOf = 'Group memberships...';
  rsDirMenuAccount = 'Account status...';
  rsDirMenuReplMeta = 'Replication metadata...';
  rsDirMenuAccountFlags = 'Account flags and permissions...';
  rsDirMenuSecurity = 'Security descriptor...';
  rsDirMenuProtection = 'Deletion protection...';
  rsDirNotInFile = '(not in file)';
  rsDirServerConfig = '(server configuration)';
  rsDirGlueSelected = 'This level is not in the LDIF file: it only groups the entries below it.';

type
  TTreeChildInfo = record
    Dn: string;
    Caption: string;
    MayHaveChildren: Boolean;
    ImageIndex: Integer;
    Classes: string;
    Container: Boolean;
    Glue: Boolean;
  end;

  TNodeData = class
  public
    Dn: string;
    Classes: string;
    Container: Boolean;
    LdifGlue: Boolean;
    Loaded: Boolean;
    Loading: Boolean;
    TaskId: Int64;
    IsPlaceholder: Boolean;
    ExpandRequested: Boolean;
    IsGroup: Boolean;
    First, Last: Integer;
    Children: array of TTreeChildInfo;
    ChildCount: Integer;
    Rendered: Integer;
    Folded: Boolean;
    ServerPageSize: Integer;
    FoldSize: Integer;
    ConfigRoot: Boolean;
    ConfigIndex: Integer;
  end;

  TDirectoryTab = class;
  TOpenSearchEvent = procedure(ATab: TDirectoryTab; const ABaseDn, AFilter: string;
    AScope: TSearchScope; ARun: Boolean) of object;
  TEntryEvent = procedure(ATab: TDirectoryTab; AEntry: TLdapEntry) of object;
  TOpenEntryDnEvent = procedure(const AProfileUuid, ADn: string) of object;

  TDirectoryTab = class(TTabSheet)
  private
    FCtx: TAppContext;
    FProfileUuid: string;
    FSessionId: string;
    FConfigRoots: TStringArray;
    FGeneration: Int64;
    FTree: TScrollTreeView;
    FTreeScroll: TTreeScrollBar;
    FTreeMenu: TPopupMenu;
    FDnBox, FSearchBox: TRottenSearchBox;
    FExpertBtn: TRtFlatButton;
    FImages: TImageList;
    FTopBar: TPanel;
    FScope: TRtComboBox;
    FEditor: TEntryEditor;
    FTasks: TDirectoryTasks;
    FSubtreeTasks: TDirectoryTasks;
    FPendingReadDn: string;
    FAcceptedNode: TTreeNode;
    FRestoringSelection: Boolean;
    FOps: TConnectionOps;
    FSubtree: TSubtreeDeletion;
    FSubtreeOwner: TObject;
    FSubtreeOps: TConnectionOps;
    FProgress: TSubtreeProgressDialog;
    FOnOpenSearch: TOpenSearchEvent;
    FOnPasswordTools: TEntryEvent;
    FOnExportEntry: TEntryEvent;
    FPendingSelectDn: string;
    FOnOpenEntry: TOpenEntryDnEvent;
    FOnEntryWritten: TOpenEntryDnEvent;
    FDragNode: TTreeNode;
    FDragStart: TPoint;
    procedure SubtreeEntries(AMsg: TEntriesMsg);
    procedure SubtreeWrite(AMsg: TWriteMsg);
    function SubtreeStopSummary(const AReason: string): string;
    procedure InterruptSubtree(const AReason: string; ARefresh: Boolean);
    procedure TreeFollowSubtree;
    function SelectedAccepts(AOrgUnit: Boolean): Boolean;
    function SelectedIsContainer: Boolean;
    function SelectedMayBeGroup(ADynamic: Boolean): Boolean;
    function QuickFilter: string;
    procedure ShowSubtreeProgress;
    procedure UpdateSubtreeProgress;
    procedure FinishSubtreeProgress(const ASummary: string; AState: TUiState);
    procedure SubtreeStopClick(Sender: TObject);
    function Conn: TDirectoryConnection;
    procedure BuildUi;
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure SubtreeTaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure AbandonChildren(ATaskId: Int64; const AReason: string);
    procedure AddConfigRoot(AIndex: Integer);
    procedure TreeExpanding(Sender: TObject; Node: TTreeNode; var AllowExpansion: Boolean);
    procedure TreeSelectionChanged(Sender: TObject);
    procedure TreeDeletion(Sender: TObject; Node: TTreeNode);
    procedure DeferredExpand(AData: PtrInt);
    procedure TreeExpanded(Sender: TObject; Node: TTreeNode);
    procedure TreeDraw(Sender: TCustomTreeView; Node: TTreeNode; State: TCustomDrawState;
      Stage: TCustomDrawStage; var PaintImages, DefaultDraw: Boolean);
    procedure TreeCollapsed(Sender: TObject; Node: TTreeNode);
    procedure TreePopup(Sender: TObject);
    procedure LoadChildren(ANode: TTreeNode);
    procedure AddChildren(AMsg: TEntriesMsg);
    function NodeForTask(ATaskId: Int64): TTreeNode;
    function FoldSizeFor(AData: TNodeData): Integer;
    function AddEntryNode(AParent: TTreeNode; const AInfo: TTreeChildInfo): TTreeNode;
    procedure RenderChildren(ANode: TTreeNode);
    function GroupNode(ANode: TTreeNode; AFirst: Integer): TTreeNode;
    procedure MaterializeGroup(AGroup: TTreeNode);
    procedure ReselectFolded(ANode: TTreeNode; const ADn: string; AAccepted: Boolean);
    function GroupOf(ANode: TTreeNode; AIndex: Integer): TTreeNode;
    function EntryNode(ANode: TTreeNode): TTreeNode;
    function FoldedChildGroup(ANode: TTreeNode; const ATarget: TLdapDn;
      ACmp: TDnComparer): TTreeNode;
    function SelectedDn: string;
    procedure DirectRead(const ADn: string);
    procedure GoClick(Sender: TObject);
    procedure SearchClick(Sender: TObject);
    procedure ExpertClick(Sender: TObject);
    procedure NewChildClick(Sender: TObject);
    procedure NewAdUserClick(Sender: TObject);
    procedure NewAdComputerClick(Sender: TObject);
    procedure NewAdGroupClick(Sender: TObject);
    procedure NewAdOuClick(Sender: TObject);
    procedure NewAdObject(AKind: Integer);
    procedure FollowCreation(const AParentDn, ACreated: string);
    procedure RenameClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure RefreshNodeClick(Sender: TObject);
    procedure CopyDnClick(Sender: TObject);
    procedure SearchHereClick(Sender: TObject);
    procedure PasswordClick(Sender: TObject);
    procedure ExportEntryClick(Sender: TObject);
    procedure RereadClick(Sender: TObject);
    procedure HandleWrite(AMsg: TWriteMsg);
    function FindEntryNode(const ADn: string; ACmp: TDnComparer): TTreeNode;
    procedure ReloadNode(ANode: TTreeNode);
    procedure TreeFollowWrite(AChange: TLdapChange);
    procedure EditorPasswordTools(AEntry: TLdapEntry);
    procedure EditorRereadRequest(Sender: TObject);
    procedure PrepareMove(const ADn, ADefaultParent: string);
    function ServerKind: TProviderKind;
    procedure CloneClick(Sender: TObject);
    procedure CopySubtreeClick(Sender: TObject);
    procedure MoveServerClick(Sender: TObject);
    procedure MembersClick(Sender: TObject);
    procedure DynamicClick(Sender: TObject);
    procedure MemberOfClick(Sender: TObject);
    procedure AccountClick(Sender: TObject);
    procedure ReplMetaClick(Sender: TObject);
    procedure AccountFlagsClick(Sender: TObject);
    procedure SecurityClick(Sender: TObject);
    procedure ProtectionClick(Sender: TObject);
    procedure TransferDone(Sender: TObject);
    procedure OpenEntryFromDialog(const AProfileUuid, ADn: string);
    procedure EntryWrittenFromDialog(const AProfileUuid, ADn: string);
    procedure TreeMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure TreeMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure TreeDragOver(Sender, Source: TObject; X, Y: Integer; State: TDragState;
      var Accept: Boolean);
    procedure TreeDragDrop(Sender, Source: TObject; X, Y: Integer);
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext; AConn: TDirectoryConnection);
    destructor Destroy; override;
    procedure ConnectionReady;
    procedure ApplyTheme;
    procedure FocusDn;
    procedure RefreshSelected;
    function RereadIfShown(const ADn: string): Boolean;
    procedure DeleteSelected;
    function StartSubtreeDeletion(const ADn: string): Boolean;
    property Subtree: TSubtreeDeletion read FSubtree;
    property SubtreeOwner: TObject read FSubtreeOwner;
    property Tasks: TDirectoryTasks read FTasks;
    property SubtreeProgress: TSubtreeProgressDialog read FProgress;
    procedure NavigateTo(const ADn: string);
    function CurrentEntry: TLdapEntry;
    function MaskedEntryLdif(AEntry: TLdapEntry): string;
    function SameDn(const A, B: string): Boolean;
    // Valide la cellule en cours de saisie, une seule fois, avant toute inspection ou
    // remplacement du tampon: une frappe ne se perd pas dans une fermeture ou une reponse tardive.
    procedure CommitInlineEditor;
    function HasPendingEdits: Boolean;
    function ConfirmDiscardEdits: Boolean;
    property ProfileUuid: string read FProfileUuid;
    property OnOpenSearch: TOpenSearchEvent read FOnOpenSearch write FOnOpenSearch;
    procedure ExpertSearch;
    property OnPasswordTools: TEntryEvent read FOnPasswordTools write FOnPasswordTools;
    property OnExportEntry: TEntryEvent read FOnExportEntry write FOnExportEntry;
    property OnOpenEntry: TOpenEntryDnEvent read FOnOpenEntry write FOnOpenEntry;
    property OnEntryWritten: TOpenEntryDnEvent read FOnEntryWritten write FOnEntryWritten;
  end;

implementation

uses
  uTheme, uIcons, uSensitive, uLdapFilter, uDirectoryService,
  uServerKind, uTransferDialog, uMembershipDialog, uDynamicGroupDialog, uAccountDialog, uAdToolsDialog, uRtMessage, uCreateWizard, uAdSecurityDialogs,
  uMenuBar, uAdCreateDialogs, uAdProtection, uGroupModel, uTaskDialog;

const
  CONFIG_ROOT_TAG = 'configroot:';
  SUBTREE_PREVIEW_MAX = 2000;
  MENU_TAG_WRITES = 1;
  MENU_TAG_AD = 2;
  MENU_TAG_AD_WRITES = 3;
  MENU_TAG_AD_NEW_OBJECT = 4;
  MENU_TAG_AD_NEW_OU = 5;
  MENU_TAG_NEW_CHILD = 6;
  MENU_TAG_GROUP = 7;
  MENU_TAG_DYNAMIC_GROUP = 8;

function ClassesKey(AEntry: TLdapEntry): string;
var
  a: TLdapAttribute;
  i: Integer;
begin
  Result := '';
  a := AEntry.Find('objectClass');
  if (a = nil) or (a.ValueCount = 0) then Exit;
  Result := ',';
  for i := 0 to a.ValueCount - 1 do
    Result := Result + LowerCase(string(a.Values[i])) + ',';
end;

function IconForEntry(AEntry: TLdapEntry): Integer;
begin
  if IsContainerEntry(AEntry) then
    Result := IconIndex('folder')
  else
    Result := IconIndex('file');
end;

procedure SetNodeIcon(ANode: TTreeNode; const AId: string);
begin
  ANode.ImageIndex := IconIndex(AId);
  ANode.SelectedIndex := ANode.ImageIndex;
end;

constructor TDirectoryTab.CreateFor(AOwner: TComponent; ACtx: TAppContext;
  AConn: TDirectoryConnection);
begin
  inherited Create(AOwner);
  FCtx := ACtx;
  FProfileUuid := AConn.Profile.Uuid;
  FSessionId := AConn.SessionId;
  FGeneration := AConn.Generation;
  Caption := AConn.Profile.Name;
  FOps := TConnectionOps.Create(ACtx.Connections, FProfileUuid, Self);
  FTasks := TDirectoryTasks.Create(FCtx.Connections, FProfileUuid, Self);
  FTasks.OnMessage := @TaskMessage;
  FSubtreeOwner := TObject.Create;
  FSubtreeOps := TConnectionOps.Create(ACtx.Connections, FProfileUuid, FSubtreeOwner);
  FSubtreeTasks := TDirectoryTasks.Create(FCtx.Connections, FProfileUuid, FSubtreeOwner);
  FSubtreeTasks.OnMessage := @SubtreeTaskMessage;
  FSubtreeTasks.Attach(FSubtreeOps, 'subtree');
  FSubtree := TSubtreeDeletion.Create(FSubtreeOps, AConn.Profile.PageSize);
  BuildUi;
end;

destructor TDirectoryTab.Destroy;
begin
  // Plus rien n'est livre a cette vue une fois detruite; une issue d'ecriture
  // en attente part chez les orphelins plutot que dans un objet mort.
  FEditor.ViewTasks := nil;
  FreeAndNil(FTasks);
  FreeAndNil(FSubtreeTasks);
  Application.RemoveAsyncCalls(Self);
  FProgress.Free;
  FSubtree.Free;
  FSubtreeOps.Free;
  FSubtreeOwner.Free;
  FOps.Free;
  inherited Destroy;
end;

function TDirectoryTab.Conn: TDirectoryConnection;
begin
  Result := FCtx.Connections.Find(FProfileUuid);
  if (Result <> nil) and (Result.SessionId <> FSessionId) then
  begin
    FSessionId := Result.SessionId;
    FGeneration := Result.Generation;
  end;
end;

procedure TDirectoryTab.BuildUi;
var
  pTop, pLeft: TPanel;
  split: TSplitter;

  procedure MenuItem(const ACaption: string; AHandler: TNotifyEvent; AShortCut: TShortCut = 0;
    AWrites: Boolean = False; ATag: Integer = 0);
  var
    mi: TMenuItem;
  begin
    mi := TMenuItem.Create(FTreeMenu);
    mi.Caption := ACaption;
    mi.OnClick := AHandler;
    mi.ShortCut := AShortCut;
    if AWrites then mi.Tag := MENU_TAG_WRITES else mi.Tag := ATag;
    FTreeMenu.Items.Add(mi);
  end;

begin
  pTop := MakePanel(Self, alTop, 44);
  pTop.ParentColor := False;
  pTop.Color := clSideBg;
  FTopBar := pTop;
  FDnBox := TRottenSearchBox.Create(pTop);
  FDnBox.Parent := pTop;
  FDnBox.Align := alLeft;
  FDnBox.Width := 460;
  FDnBox.Glyph := sbgGoTo;
  FDnBox.HintText := rsDirDnHint;
  FDnBox.OnSubmit := @GoClick;
  FDnBox.SetEnabledLook(True);
  FSearchBox := TRottenSearchBox.Create(pTop);
  FSearchBox.Parent := pTop;
  FSearchBox.Align := alLeft;
  FSearchBox.Width := 420;
  FSearchBox.HintText := rsDirSearchHint;
  FSearchBox.OnSubmit := @SearchClick;
  FSearchBox.SetEnabledLook(True);
  FScope := TRtComboBox.Create(pTop);
  FScope.Parent := pTop;
  FScope.Align := alLeft;
  FScope.Items.Add('base');
  FScope.Items.Add('oneLevel');
  FScope.Items.Add('subtree');
  FScope.ItemIndex := 2;
  FScope.Width := 110;
  FScope.BorderSpacing.Left := 6;
  FExpertBtn := TRtFlatButton.Create(pTop);
  FExpertBtn.Parent := pTop;
  FExpertBtn.Align := alLeft;
  FExpertBtn.Left := FScope.Left + FScope.Width + 1;
  FExpertBtn.BorderSpacing.Left := 8;
  FExpertBtn.Setup('filter', rsDirExpert);
  FExpertBtn.Hint := rsDirExpertHint;
  FExpertBtn.ShowHint := True;
  FExpertBtn.OnClick := @ExpertClick;

  pLeft := MakePanel(Self, alLeft, 330);
  FTreeScroll := TTreeScrollBar.Create(pLeft);
  FTreeScroll.Parent := pLeft;
  FTreeScroll.Align := alRight;
  FTreeScroll.Width := 12;
  FTree := TScrollTreeView.Create(pLeft);
  FTree.Parent := pLeft;
  FTree.Align := alClient;
  FTree.BorderStyle := bsNone;
  FTree.ScrollBars := ssNone;
  FTree.ReadOnly := True;
  FTree.RightClickSelect := True;
  FTree.HideSelection := False;
  // Le dessin theme de la LCL ignore nos couleurs: on dessine nous-memes.
  FTree.Options := FTree.Options - [tvoThemedDraw];
  FTree.OnExpanding := @TreeExpanding;
  FTree.OnAdvancedCustomDrawItem := @TreeDraw;
  FTree.OnExpanded := @TreeExpanded;
  FTree.OnCollapsed := @TreeCollapsed;
  FTree.OnSelectionChanged := @TreeSelectionChanged;
  FTree.OnDeletion := @TreeDeletion;
  FTree.DragMode := dmManual;
  FTree.OnMouseDown := @TreeMouseDown;
  FTree.OnMouseMove := @TreeMouseMove;
  FTree.OnDragOver := @TreeDragOver;
  FTree.OnDragDrop := @TreeDragDrop;
  FTreeMenu := TPopupMenu.Create(Self);
  FTreeMenu.OnPopup := @TreePopup;
  MenuItem(rsDirMenuRefresh, @RefreshNodeClick, VK_F5);
  MenuItem(rsDirMenuProperties, @RereadClick);
  MenuItem('-', nil);
  MenuItem(rsDirMenuNewChild, @NewChildClick, 0, False, MENU_TAG_NEW_CHILD);
  MenuItem(rsDirMenuNewUser, @NewAdUserClick, 0, False, MENU_TAG_AD_NEW_OBJECT);
  MenuItem(rsDirMenuNewComputer, @NewAdComputerClick, 0, False, MENU_TAG_AD_NEW_OBJECT);
  MenuItem(rsDirMenuNewGroup, @NewAdGroupClick, 0, False, MENU_TAG_AD_NEW_OBJECT);
  MenuItem(rsDirMenuNewOu, @NewAdOuClick, 0, False, MENU_TAG_AD_NEW_OU);
  MenuItem('-', nil);
  MenuItem(rsDirMenuRename, @RenameClick, 0, True);
  MenuItem(rsDirMenuDelete, @DeleteClick, VK_DELETE, True);
  MenuItem(rsDirMenuClone, @CloneClick, 0, True);
  MenuItem(rsDirMenuCopySubtree, @CopySubtreeClick);
  MenuItem(rsDirMenuMoveServer, @MoveServerClick, 0, True);
  MenuItem('-', nil);
  MenuItem(rsDirMenuMembers, @MembersClick, 0, False, MENU_TAG_GROUP);
  MenuItem(rsDirMenuMemberOf, @MemberOfClick);
  MenuItem(rsDirMenuDynamic, @DynamicClick, 0, False, MENU_TAG_DYNAMIC_GROUP);
  MenuItem(rsDirMenuAccount, @AccountClick);
  MenuItem(rsDirMenuReplMeta, @ReplMetaClick, 0, False, MENU_TAG_AD);
  MenuItem(rsDirMenuAccountFlags, @AccountFlagsClick, 0, False, MENU_TAG_AD);
  MenuItem(rsDirMenuSecurity, @SecurityClick, 0, False, MENU_TAG_AD);
  MenuItem(rsDirMenuProtection, @ProtectionClick, 0, False, MENU_TAG_AD);
  MenuItem('-', nil);
  MenuItem(rsDirMenuCopyDn, @CopyDnClick);
  MenuItem(rsDirMenuSearchHere, @SearchHereClick);
  MenuItem(rsDirMenuExportEntry, @ExportEntryClick);
  MenuItem(rsDirMenuPassword, @PasswordClick);
  FTree.PopupMenu := FTreeMenu;
  ThemePopupMenu(FTreeMenu);
  FTreeScroll.Bind(FTree);

  split := TSplitter.Create(Self);
  split.Parent := Self;
  split.Align := alLeft;
  split.Left := pLeft.Left + pLeft.Width + 1;

  FEditor := TEntryEditor.Create(Self, FCtx, @Conn);
  FEditor.Parent := Self;
  FEditor.Align := alClient;
  FEditor.Title := Caption;
  FEditor.ViewTasks := FTasks;
  FEditor.ProfileUuid := FProfileUuid;
  FEditor.OnPasswordTools := @EditorPasswordTools;
  FEditor.OnRereadRequest := @EditorRereadRequest;
  FEditor.OnNavigate := @NavigateTo;
  ApplyTheme;
end;

procedure TDirectoryTab.ApplyTheme;
begin
  ThemeControlTree(Self);
  FTree.Color := clSideBg;
  FTree.Font.Color := clSideText;
  FTree.BackgroundColor := clSideBg;
  FTree.Font.Size := RSTreeFontSize;
  FTree.ExpandSignType := tvestPlusMinus;
  FTree.ExpandSignColor := BlendColor(clSideText, clSideBg, 60);
  FTree.TreeLineColor := BlendColor(clSideText, clSideBg, 35);
  FitTreeIndent(FTree);
  FImages.Free;
  FImages := BuildIconList(Self, IconPixelSize(24, Screen.PixelsPerInch), IsDarkColor(clSideBg));
  FTree.Images := FImages;
  FTopBar.Height := FontTextHeight(Font) + 24;
  FDnBox.ApplyTheme(clSideBg, clSideHover, BlendColor(clSideText, clSideBg, 30), clAccent,
    clSideText, BlendColor(clSideText, clSideBg, 55), BlendColor(clSideText, clSideBg, 45));
  FSearchBox.ApplyTheme(clSideBg, clSideHover, BlendColor(clSideText, clSideBg, 30), clAccent,
    clSideText, BlendColor(clSideText, clSideBg, 55), BlendColor(clSideText, clSideBg, 45));
  FExpertBtn.Ink := clSideText;
  FExpertBtn.Fill := clSideHover;
  FExpertBtn.Border := BlendColor(clSideText, clSideBg, 30);
  FExpertBtn.InsetY := 5;
  FExpertBtn.Font.Color := clSideText;
  FExpertBtn.FitWidth;
  FTreeScroll.ApplyTheme(clSideBg, BlendColor(clSideText, clSideBg, 22),
    BlendColor(clSideText, clSideBg, 42));
  FEditor.ApplyTheme;
  ArrangeByCreation(Self);
end;

procedure TDirectoryTab.ConnectionReady;
var
  c: TDirectoryConnection;
  bases, known: TStringArray;
  i: Integer;
  node: TTreeNode;
  data: TNodeData;
begin
  c := Conn;
  if (c = nil) or not c.IsReady then Exit;
  // Nouvelle session: la relecture de pre-ecriture lancee sur l'ancienne serait refusee.
  // On abandonne le delta en attente plutot que de laisser l'edition pendue.
  FEditor.CancelPrecheck(rsDirSessionReplaced);
  // Meme punition pour une suppression de sous-arbre en cours: les resultats de l'ancienne
  // session n'arriveront plus. Les suppressions restantes ne partent pas, celle en vol est a verifier.
  if FSubtree.Active then
    InterruptSubtree(rsDirSessionReplaced, False);
  FTree.Items.BeginUpdate;
  try
    FTree.Items.Clear;
    bases := DirectoryBases(c);
    // Une base qui est elle-meme la configuration du serveur (ApacheDS sans base choisie,
    // profil pointe sur cn=config) est marquee comme telle.
    known := KnownServerConfigRoots(c);
    for i := 0 to High(bases) do
    begin
      data := TNodeData.Create;
      data.Dn := bases[i];
      data.LdifGlue := IsLdifPlaceholderContext(c, bases[i]);
      if data.LdifGlue then
      begin
        node := FTree.Items.AddObject(nil, bases[i] + ' ' + rsDirNotInFile, data);
        SetNodeIcon(node, 'circle-dashed');
      end
      else if DnUnderAny(bases[i], known) then
      begin
        data.ConfigRoot := True;
        data.ConfigIndex := -1;
        node := FTree.Items.AddObject(nil, bases[i] + '  ' + rsDirServerConfig, data);
        SetNodeIcon(node, 'settings');
      end
      else
      begin
        node := FTree.Items.AddObject(nil, bases[i], data);
        SetNodeIcon(node, 'database');
      end;
      node.HasChildren := True;
    end;
  finally
    FTree.Items.EndUpdate;
  end;
  if FTree.Items.Count > 0 then
    FTree.Items[0].Selected := True;
  // Chaque racine de configuration est lue avec l'identite de la session, sans autre bind,
  // et n'apparait que si elle repond. OpenLDAP repond noSuchObject quand on n'a pas le droit:
  // un refus ou une absence ne disent donc rien.
  FConfigRoots := nil;
  if c.Profile.ShowServerConfig then
  begin
    FConfigRoots := ServerConfigRoots(c);
    for i := 0 to High(FConfigRoots) do
      FTasks.ReadEntry(CONFIG_ROOT_TAG + IntToStr(i), FConfigRoots[i], ['1.1']);
  end;
end;

procedure TDirectoryTab.AddConfigRoot(AIndex: Integer);
var
  i: Integer;
  node, before: TTreeNode;
  data, d: TNodeData;
begin
  if (AIndex < 0) or (AIndex > High(FConfigRoots)) then Exit;
  before := nil;
  for i := 0 to FTree.Items.TopLvlCount - 1 do
  begin
    d := TNodeData(FTree.Items.TopLvlItems[i].Data);
    if (d = nil) or not d.ConfigRoot then Continue;
    if d.ConfigIndex = AIndex then Exit;
    if (before = nil) and (d.ConfigIndex > AIndex) then before := FTree.Items.TopLvlItems[i];
  end;
  data := TNodeData.Create;
  data.Dn := FConfigRoots[AIndex];
  data.ConfigRoot := True;
  data.ConfigIndex := AIndex;
  if before <> nil then
    node := FTree.Items.InsertObject(before, FConfigRoots[AIndex] + '  ' + rsDirServerConfig, data)
  else
    node := FTree.Items.AddObject(nil, FConfigRoots[AIndex] + '  ' + rsDirServerConfig, data);
  SetNodeIcon(node, 'settings');
  node.HasChildren := True;
end;

procedure TDirectoryTab.TreeDeletion(Sender: TObject; Node: TTreeNode);
begin
  // Aucune reference ne survit au noeud: repliage, relecture ou reconnexion detruisent des noeuds
  // que la selection ou un glisser en cours designent peut-etre. Un pointeur pendant, c'est un crash differe.
  if Node = FAcceptedNode then FAcceptedNode := nil;
  if Node = FDragNode then FDragNode := nil;
  TObject(Node.Data).Free;
  Node.Data := nil;
end;

procedure TDirectoryTab.TreeExpanding(Sender: TObject; Node: TTreeNode; var AllowExpansion: Boolean);
var
  data: TNodeData;
begin
  AllowExpansion := True;
  data := TNodeData(Node.Data);
  if (data <> nil) and data.IsGroup then
  begin
    if data.Loaded then Exit;
    MaterializeGroup(Node);
    AllowExpansion := False;
    data.ExpandRequested := True;
    data.TaskId := NextTaskId;
    Application.QueueAsyncCall(@DeferredExpand, PtrInt(data.TaskId));
    Exit;
  end;
  if (data = nil) or data.Loaded or data.Loading or data.IsPlaceholder then Exit;
  // Win32 annule l'expansion si les enfants changent pendant cet evenement: on refuse
  // ce depliage, on lance la lecture, et on deplie plus tard, hors evenement.
  AllowExpansion := False;
  data.ExpandRequested := True;
  LoadChildren(Node);
  Application.QueueAsyncCall(@DeferredExpand, PtrInt(data.TaskId));
end;

procedure TDirectoryTab.TreeExpanded(Sender: TObject; Node: TTreeNode);
begin
  if Node.ImageIndex = IconIndex('folder') then
    SetNodeIcon(Node, 'folder-open');
end;

procedure TDirectoryTab.TreeDraw(Sender: TCustomTreeView; Node: TTreeNode;
  State: TCustomDrawState; Stage: TCustomDrawStage; var PaintImages, DefaultDraw: Boolean);
var
  tr: TRect;
  ty: Integer;
  saved: TFont;
begin
  DefaultDraw := True;
  if Stage <> cdPostPaint then Exit;
  // Selection lisible avec ou sans focus: le rendu systeme inactif est illisible.
  if not ((cdsSelected in State) or (cdsMarked in State)) then Exit;
  tr := Node.DisplayRect(True);
  saved := TFont.Create;
  try
    // Canevas partage avec le dessin des noeuds suivants: on remet tout en place en partant.
    saved.Assign(Sender.Canvas.Font);
    Sender.Canvas.Brush.Style := bsSolid;
    Sender.Canvas.Brush.Color := clSideSel;
    Sender.Canvas.FillRect(tr);
    Sender.Canvas.Brush.Style := bsClear;
    Sender.Canvas.Font.Color := clSideTextHi;
    ty := tr.Top + (tr.Bottom - tr.Top - Sender.Canvas.TextHeight('Ag')) div 2;
    Sender.Canvas.TextOut(tr.Left + 2, ty, Node.Text);
    Sender.Canvas.Brush.Style := bsSolid;
    Sender.Canvas.Font.Assign(saved);
  finally
    saved.Free;
  end;
end;

procedure TDirectoryTab.TreeCollapsed(Sender: TObject; Node: TTreeNode);
begin
  if Node.ImageIndex = IconIndex('folder-open') then
    SetNodeIcon(Node, 'folder');
end;

procedure TDirectoryTab.DeferredExpand(AData: PtrInt);
var
  i: Integer;
  d: TNodeData;
begin
  for i := 0 to FTree.Items.Count - 1 do
  begin
    d := TNodeData(FTree.Items[i].Data);
    if (d <> nil) and (d.TaskId = Int64(AData)) and d.ExpandRequested then
    begin
      if FTree.Items[i].Count > 0 then
      begin
        FTree.Items[i].Expand(False);
        if d.IsGroup then d.ExpandRequested := False;
      end;
      Exit;
    end;
  end;
end;

procedure TDirectoryTab.LoadChildren(ANode: TTreeNode);
var
  data, ph: TNodeData;
  c: TDirectoryConnection;
begin
  c := Conn;
  if (c = nil) or not c.IsReady then Exit;
  data := TNodeData(ANode.Data);
  ANode.DeleteChildren;
  data.Children := nil;
  data.ChildCount := 0;
  data.Rendered := 0;
  data.Folded := False;
  data.ServerPageSize := 0;
  data.FoldSize := 0;
  ph := TNodeData.Create;
  ph.IsPlaceholder := True;
  FTree.Items.AddChildObject(ANode, rsDirLoading, ph);
  data.Loading := True;
  data.TaskId := FTasks.Search('children', TreeChildrenRequest(c.Profile, data.Dn));
end;

function TDirectoryTab.NodeForTask(ATaskId: Int64): TTreeNode;
var
  i: Integer;
begin
  for i := 0 to FTree.Items.Count - 1 do
    if (FTree.Items[i].Data <> nil) and (TNodeData(FTree.Items[i].Data).TaskId = ATaskId) and
       TNodeData(FTree.Items[i].Data).Loading then
      Exit(FTree.Items[i]);
  Result := nil;
end;

function RdnLabel(const ADn: string): string;
var
  d: TLdapDn;
begin
  if DnTryParse(ADn, d) and (DnRdnCount(d) > 0) then
    Result := RdnToString(DnLeaf(d))
  else
    Result := ADn;
end;

// Dire en clair pourquoi la liste s'arrete (limite du profil, du serveur, du temps):
// un "success" sur une liste tronquee n'a jamais rassure personne.
function PartialListText(const AMsg: TEntriesMsg; ACount: Integer): string;
var
  c: TSearchCompletion;
begin
  c := AMsg.Completion;
  if c.ClientLimitHit then
    Result := Format(rsDirPartialClientLimit, [ACount])
  else if c.SizeLimitHit or (c.ResultCode = LDAP_RC_ADMINLIMIT_EXCEEDED) then
    Result := Format(rsDirPartialServerLimit, [ACount])
  else if c.TimeLimitHit then
    Result := Format(rsDirPartialTimeLimit, [ACount])
  else if c.PagingAnomaly <> '' then
    Result := Format(rsDirPartialPaging, [c.PagingAnomaly])
  else if (c.ReferralsIgnored > 0) or (c.ContinuationsIgnored > 0) then
    Result := rsDirPartialReferrals
  else if c.DecodeFailures > 0 then
    Result := Format(rsDirPartialDecode, [c.DecodeFailures])
  else
    Result := Format(rsDirMore,
      [Trim(ErrorToText(AMsg.Error) + ' ' + ResultCodeName(c.ResultCode))]);
end;

function TDirectoryTab.FoldSizeFor(AData: TNodeData): Integer;
var
  c: TDirectoryConnection;
begin
  // Une plage = une page telle que le serveur la rend, et il peut rendre moins que demande
  // (RFC 2696). Taille demandee en attendant la fin de la premiere page.
  if AData.FoldSize > 0 then Exit(AData.FoldSize);
  if AData.ServerPageSize > 0 then Exit(AData.ServerPageSize);
  c := Conn;
  if (c <> nil) and (c.Profile.PageSize > 0) then
    Result := c.Profile.PageSize
  else
    Result := 1000;
end;

function TDirectoryTab.AddEntryNode(AParent: TTreeNode; const AInfo: TTreeChildInfo): TTreeNode;
var
  cd: TNodeData;
begin
  cd := TNodeData.Create;
  cd.Dn := AInfo.Dn;
  cd.Classes := AInfo.Classes;
  cd.Container := AInfo.Container;
  cd.LdifGlue := AInfo.Glue;
  Result := FTree.Items.AddChildObject(AParent, AInfo.Caption, cd);
  Result.HasChildren := AInfo.MayHaveChildren;
  Result.ImageIndex := AInfo.ImageIndex;
  Result.SelectedIndex := AInfo.ImageIndex;
end;

function TDirectoryTab.GroupNode(ANode: TTreeNode; AFirst: Integer): TTreeNode;
var
  i: Integer;
  gd: TNodeData;
begin
  for i := ANode.Count - 1 downto 0 do
  begin
    gd := TNodeData(ANode.Items[i].Data);
    if (gd <> nil) and gd.IsGroup and (gd.First = AFirst) then Exit(ANode.Items[i]);
  end;
  gd := TNodeData.Create;
  gd.IsGroup := True;
  gd.First := AFirst;
  gd.Last := AFirst - 1;
  Result := FTree.Items.AddChildObject(ANode, '', gd);
  Result.HasChildren := True;
  Result.ImageIndex := IconIndex('folder');
  Result.SelectedIndex := Result.ImageIndex;
end;

function TDirectoryTab.GroupOf(ANode: TTreeNode; AIndex: Integer): TTreeNode;
var
  i: Integer;
  gd: TNodeData;
begin
  Result := nil;
  for i := 0 to ANode.Count - 1 do
  begin
    gd := TNodeData(ANode.Items[i].Data);
    if (gd <> nil) and gd.IsGroup and (AIndex >= gd.First) and (AIndex <= gd.Last) then
      Exit(ANode.Items[i]);
  end;
end;

function TDirectoryTab.EntryNode(ANode: TTreeNode): TTreeNode;
begin
  Result := ANode;
  if (Result <> nil) and (Result.Data <> nil) and TNodeData(Result.Data).IsGroup then
    Result := Result.Parent;
end;

procedure TDirectoryTab.MaterializeGroup(AGroup: TTreeNode);
var
  gd, pd: TNodeData;
  j: Integer;
begin
  gd := TNodeData(AGroup.Data);
  if gd.Loaded then Exit;
  pd := TNodeData(AGroup.Parent.Data);
  FTree.Items.BeginUpdate;
  try
    for j := gd.First to gd.Last do
      AddEntryNode(AGroup, pd.Children[j]);
  finally
    FTree.Items.EndUpdate;
  end;
  gd.Loaded := True;
end;

procedure TDirectoryTab.RenderChildren(ANode: TTreeNode);
var
  data, gd: TNodeData;
  fold, k, last, j, i: Integer;
  grp, sel: TTreeNode;
  selDn: string;
  wasAccepted: Boolean;
begin
  data := TNodeData(ANode.Data);
  fold := FoldSizeFor(data);
  if (not data.Folded) and (data.ChildCount <= fold) then
  begin
    for k := data.Rendered to data.ChildCount - 1 do
      AddEntryNode(ANode, data.Children[k]);
    data.Rendered := data.ChildCount;
    Exit;
  end;
  selDn := '';
  wasAccepted := False;
  if not data.Folded then
  begin
    sel := FTree.Selected;
    if (sel <> nil) and (sel.Parent = ANode) and (sel.Data <> nil) and
       not TNodeData(sel.Data).IsPlaceholder then
    begin
      selDn := TNodeData(sel.Data).Dn;
      wasAccepted := sel = FAcceptedNode;
    end;
    for i := ANode.Count - 1 downto 0 do
      if not TNodeData(ANode.Items[i].Data).IsPlaceholder then
        ANode.Items[i].Delete;
    data.Folded := True;
    data.Rendered := 0;
    data.FoldSize := fold;
  end;
  k := data.Rendered;
  while k < data.ChildCount do
  begin
    grp := GroupNode(ANode, (k div fold) * fold);
    gd := TNodeData(grp.Data);
    last := gd.First + fold - 1;
    if last > data.ChildCount - 1 then last := data.ChildCount - 1;
    if gd.Loaded then
      for j := gd.Last + 1 to last do
        AddEntryNode(grp, data.Children[j]);
    gd.Last := last;
    grp.Text := Format(rsDirRange, [gd.First + 1, gd.Last + 1]);
    k := last + 1;
  end;
  data.Rendered := data.ChildCount;
  if selDn <> '' then
    ReselectFolded(ANode, selDn, wasAccepted);
end;

procedure TDirectoryTab.ReselectFolded(ANode: TTreeNode; const ADn: string; AAccepted: Boolean);
var
  data: TNodeData;
  k: Integer;
  grp, node: TTreeNode;
begin
  data := TNodeData(ANode.Data);
  for k := 0 to data.ChildCount - 1 do
    if data.Children[k].Dn = ADn then
    begin
      grp := GroupOf(ANode, k);
      if grp = nil then Exit;
      MaterializeGroup(grp);
      node := grp.Items[k - TNodeData(grp.Data).First];
      FRestoringSelection := True;
      try
        node.Selected := True;
      finally
        FRestoringSelection := False;
      end;
      if AAccepted then FAcceptedNode := node;
      Exit;
    end;
end;

procedure TDirectoryTab.AddChildren(AMsg: TEntriesMsg);
var
  node, child, ph: TTreeNode;
  data, cd: TNodeData;
  i: Integer;
  e: TLdapEntry;
  c: TDirectoryConnection;
begin
  node := NodeForTask(AMsg.TaskId);
  if node = nil then Exit;
  data := TNodeData(node.Data);
  if data.LdifGlue and AMsg.Final and (AMsg.Entries.Count = 0) and
     (AMsg.Completion.ResultCode = LDAP_RC_NO_SUCH_OBJECT) then
  begin
    node.Delete;
    Exit;
  end;
  c := Conn;
  FTree.Items.BeginUpdate;
  try
    // Retirer l'indicateur de chargement apres l'ajout du lot: supprimer d'abord le seul
    // enfant replierait le noeud sous les yeux de l'utilisateur.
    ph := nil;
    if (node.Count > 0) and TNodeData(node.Items[0].Data).IsPlaceholder then
      ph := node.Items[0];
    if (AMsg.ServerPageSize > 0) and (data.ServerPageSize = 0) then
      data.ServerPageSize := AMsg.ServerPageSize;
    if data.ChildCount + AMsg.Entries.Count > Length(data.Children) then
      SetLength(data.Children, 2 * (data.ChildCount + AMsg.Entries.Count));
    for i := 0 to AMsg.Entries.Count - 1 do
    begin
      e := TLdapEntry(AMsg.Entries[i]);
      with data.Children[data.ChildCount] do
      begin
        Dn := e.Dn;
        Caption := RdnLabel(e.Dn);
        MayHaveChildren := EntryMayHaveChildren(e);
        ImageIndex := IconForEntry(e);
        Classes := ClassesKey(e);
        Container := IsContainerEntry(e);
        Glue := IsLdifPlaceholder(c, Classes);
        if Glue then
        begin
          Caption := Caption + ' ' + rsDirNotInFile;
          ImageIndex := IconIndex('circle-dashed');
        end;
      end;
      Inc(data.ChildCount);
    end;
    RenderChildren(node);
    if (ph <> nil) and ((node.Count > 1) or AMsg.Final) then
      ph.Delete;
    if AMsg.Final then
    begin
      data.Loading := False;
      data.Loaded := True;
      if SearchOutcome(AMsg.Completion) <> soComplete then
      begin
        // Une page manquante n'est pas un annuaire vide; on dit pourquoi.
        cd := TNodeData.Create;
        cd.IsPlaceholder := True;
        child := FTree.Items.AddChildObject(node, PartialListText(AMsg, data.ChildCount), cd);
        child.ImageIndex := IconIndex('alert-triangle');
        child.SelectedIndex := child.ImageIndex;
      end;
      node.HasChildren := node.Count > 0;
      if (node.Count > 0) and (node.ImageIndex = IconIndex('file')) then
        SetNodeIcon(node, 'folder');
      if data.ExpandRequested and (node.Count > 0) and not node.Expanded then
        node.Expand(False);
      data.ExpandRequested := False;
      if FPendingSelectDn <> '' then
        NavigateTo(FPendingSelectDn);
    end;
  finally
    FTree.Items.EndUpdate;
  end;
end;

function TDirectoryTab.SelectedDn: string;
begin
  Result := '';
  if (FTree.Selected <> nil) and (FTree.Selected.Data <> nil) and
     not TNodeData(FTree.Selected.Data).IsPlaceholder and
     not TNodeData(FTree.Selected.Data).IsGroup then
    Result := TNodeData(FTree.Selected.Data).Dn;
end;

procedure TDirectoryTab.TreeSelectionChanged(Sender: TObject);
var
  dn: string;
  c: TDirectoryConnection;
begin
  if FRestoringSelection then Exit;
  dn := SelectedDn;
  if dn = '' then Exit;
  if (Sender <> Self) and HasPendingEdits and not ConfirmDiscardEdits then
  begin
    if (FAcceptedNode <> nil) and (FTree.Selected <> FAcceptedNode) then
    begin
      FRestoringSelection := True;
      try
        FTree.Selected := FAcceptedNode;
      finally
        FRestoringSelection := False;
      end;
    end;
    Exit;
  end;
  FAcceptedNode := FTree.Selected;
  FDnBox.SetText(dn);
  if TNodeData(FTree.Selected.Data).LdifGlue then
  begin
    FTasks.Cancel('read');
    FPendingReadDn := '';
    FEditor.ReadPending := False;
    FEditor.ShowPlaceholder(rsDirGlueSelected);
    Exit;
  end;
  c := Conn;
  if (c = nil) or not c.IsReady then Exit;
  FPendingReadDn := dn;
  FTasks.Cancel('read');
  if FTasks.ReadEntry('read', dn, EntryReadAttributes(c.Profile)) <> 0 then
    FEditor.ReadPending := True;
end;

procedure TDirectoryTab.AbandonChildren(ATaskId: Int64; const AReason: string);
var
  node: TTreeNode;
  data: TNodeData;
begin
  node := NodeForTask(ATaskId);
  if node = nil then Exit;
  data := TNodeData(node.Data);
  node.DeleteChildren;
  data.Loading := False;
  data.Loaded := False;
  data.ExpandRequested := False;
  node.HasChildren := True;
  FCtx.Log(mlWarning, Caption, Format(rsDirChildrenLost, [data.Dn, AReason]));
end;

procedure TDirectoryTab.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
begin
  // Une reponse d'une session remplacee n'est jamais appliquee: la tache est liberee, et
  // une issue d'ecriture ainsi ecartee reste au journal jusqu'a ce que la boite la solde.
  if ATask.Tag = EDITOR_PRECHECK_TAG then
  begin
    FEditor.PrecheckDelivered(AMsg, AEnding);
    Exit;
  end;
  if Copy(ATask.Tag, 1, Length(CONFIG_ROOT_TAG)) = CONFIG_ROOT_TAG then
  begin
    if (AEnding = teDone) and (AMsg is TEntryMsg) and (TEntryMsg(AMsg).Entry <> nil) then
      AddConfigRoot(StrToIntDef(Copy(ATask.Tag, Length(CONFIG_ROOT_TAG) + 1, MaxInt), -1));
    Exit;
  end;
  if ATask.Tag = 'children' then
  begin
    if AEnding = teStale then AbandonChildren(AMsg.TaskId, rsDirSessionReplaced)
    else if AMsg is TEntriesMsg then AddChildren(TEntriesMsg(AMsg))
    else if AMsg is TTaskFailedMsg then AbandonChildren(AMsg.TaskId, TTaskFailedMsg(AMsg).Text);
    Exit;
  end;
  if ATask.Tag = 'read' then
  begin
    FPendingReadDn := '';
    FEditor.ReadPending := False;
    if AEnding = teStale then Exit;
    if AMsg is TTaskFailedMsg then
    begin
      FCtx.Log(mlError, Caption, TTaskFailedMsg(AMsg).Text);
      Exit;
    end;
    if not (AMsg is TEntryMsg) then Exit;
    if TEntryMsg(AMsg).Entry = nil then
    begin
      FCtx.Log(mlWarning, Caption, ErrorToText(TEntryMsg(AMsg).Error));
      Exit;
    end;
    FEditor.ShowEntry(TEntryMsg(AMsg).Entry);
    TEntryMsg(AMsg).Entry := nil;
    Exit;
  end;
  if ATask.Tag = VIEW_WRITE_TAG then
  begin
    if AEnding = teStale then
      FCtx.Log(mlError, Caption, rsDirWriteSessionLost)
    else if AMsg is TWriteMsg then
      HandleWrite(TWriteMsg(AMsg))
    else if AMsg is TTaskFailedMsg then
      FCtx.Log(mlError, Caption, TTaskFailedMsg(AMsg).Text);
  end;
end;

procedure TDirectoryTab.SubtreeTaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask;
  AEnding: TTaskEnding);
begin
  if not FSubtree.OwnsTask(AMsg.TaskId) then Exit;
  if AEnding = teStale then
  begin
    // Les resultats de l'ancienne session ne viendront plus: les suppressions restantes
    // ne partent pas, celle en vol est a verifier.
    InterruptSubtree(rsDirSessionReplaced, False);
    Exit;
  end;
  if AMsg is TEntriesMsg then
    SubtreeEntries(TEntriesMsg(AMsg))
  else if AMsg is TWriteMsg then
    SubtreeWrite(TWriteMsg(AMsg))
  else if AMsg is TTaskFailedMsg then
  begin
    FCtx.Log(mlError, Caption, TTaskFailedMsg(AMsg).Text);
    // Tache de suppression en echec: la suppression envoyee a une issue inconnue, le bilan le dit.
    InterruptSubtree(TTaskFailedMsg(AMsg).Text, True);
  end;
end;

function TDirectoryTab.SameDn(const A, B: string): Boolean;
begin
  Result := SameDnStrict(A, B);
end;

procedure TDirectoryTab.CommitInlineEditor;
begin
  FEditor.CommitInlineEditor;
end;

function TDirectoryTab.HasPendingEdits: Boolean;
begin
  Result := FEditor.HasPendingEdits;
end;

function TDirectoryTab.ConfirmDiscardEdits: Boolean;
begin
  Result := FEditor.ConfirmDiscardEdits;
end;

function TDirectoryTab.MaskedEntryLdif(AEntry: TLdapEntry): string;
begin
  Result := FEditor.MaskedEntryLdif(AEntry);
end;

procedure TDirectoryTab.EditorPasswordTools(AEntry: TLdapEntry);
begin
  if Assigned(FOnPasswordTools) then FOnPasswordTools(Self, AEntry);
end;

function TDirectoryTab.CurrentEntry: TLdapEntry;
begin
  Result := FEditor.Original;
end;

procedure TDirectoryTab.HandleWrite(AMsg: TWriteMsg);
begin
  if FEditor.HandleWrite(AMsg) and (AMsg.Change.Kind in [ckDelete, ckModDn, ckAdd]) then
    TreeFollowWrite(AMsg.Change);
end;

function TDirectoryTab.FindEntryNode(const ADn: string; ACmp: TDnComparer): TTreeNode;
var
  i: Integer;
  target, nd: TLdapDn;
  d: TNodeData;
begin
  Result := nil;
  if not DnTryParse(ADn, target) or (DnRdnCount(target) = 0) then Exit;
  for i := 0 to FTree.Items.Count - 1 do
  begin
    d := TNodeData(FTree.Items[i].Data);
    if (d = nil) or d.IsPlaceholder or d.IsGroup or not DnTryParse(d.Dn, nd) then Continue;
    if ACmp.CompareDn(nd, target) = dmEqual then Exit(FTree.Items[i]);
  end;
end;

procedure TDirectoryTab.ReloadNode(ANode: TTreeNode);
begin
  TNodeData(ANode.Data).Loaded := False;
  LoadChildren(ANode);
  ANode.Expand(False);
end;

// D'apres les DN de l'operation, jamais d'apres la selection: elle a pu changer depuis l'envoi.
// Le parent est relu; un renommage relit l'ancien et le nouveau parent.
procedure TDirectoryTab.TreeFollowWrite(AChange: TLdapChange);
var
  cmp: TDnComparer;
  src: TLdapDn;
  oldNode, newNode: TTreeNode;
  newParentDn, newDn: string;
  follow: Boolean;
begin
  if not DnTryParse(AChange.Dn, src) or (DnRdnCount(src) = 0) then Exit;
  cmp := TDnComparer.Create;
  try
    oldNode := FindEntryNode(DnToString(DnParent(src)), cmp);
    if AChange.Kind <> ckModDn then
    begin
      if oldNode <> nil then ReloadNode(oldNode);
      Exit;
    end;
    follow := SameDnStrict(SelectedDn, AChange.Dn) or
      ((FEditor.Original <> nil) and SameDnStrict(FEditor.Original.Dn, AChange.Dn));
    if AChange.HasNewSuperior then
      newParentDn := AChange.NewSuperior
    else
      newParentDn := DnToString(DnParent(src));
    if newParentDn <> '' then
      newDn := AChange.NewRdn + ',' + newParentDn
    else
      newDn := AChange.NewRdn;
    newNode := FindEntryNode(newParentDn, cmp);
    if (oldNode <> nil) and (newNode <> nil) then
    begin
      if newNode.HasAsParent(oldNode) then
        newNode := nil
      else if oldNode.HasAsParent(newNode) then
        oldNode := nil;
    end;
    if oldNode <> nil then ReloadNode(oldNode);
    if (newNode <> nil) and (newNode <> oldNode) then ReloadNode(newNode);
  finally
    cmp.Free;
  end;
  if follow then NavigateTo(newDn);
end;

procedure TDirectoryTab.EditorRereadRequest(Sender: TObject);
begin
  TreeSelectionChanged(Self);
end;

procedure TDirectoryTab.TreePopup(Sender: TObject);
var
  i: Integer;
  c: TDirectoryConnection;
  writable, hasDn: Boolean;
  kind: TProviderKind;
begin
  c := Conn;
  writable := (c <> nil) and c.IsReady and not c.Profile.ReadOnly;
  hasDn := SelectedDn <> '';
  kind := ServerKind;
  for i := 0 to FTreeMenu.Items.Count - 1 do
    with FTreeMenu.Items[i] do
      case Tag of
        // Bloque aussi dans l'interface en lecture seule, en plus du service. Ceinture et bretelles.
        MENU_TAG_WRITES: Enabled := writable and hasDn;
        MENU_TAG_AD:
          begin
            Visible := kind = pkActiveDirectory;
            Enabled := hasDn;
          end;
        MENU_TAG_AD_WRITES:
          begin
            Visible := kind = pkActiveDirectory;
            Enabled := writable and hasDn;
          end;
        MENU_TAG_NEW_CHILD: Enabled := writable and hasDn and SelectedIsContainer;
        MENU_TAG_GROUP: Enabled := hasDn and SelectedMayBeGroup(False);
        MENU_TAG_DYNAMIC_GROUP: Enabled := hasDn and SelectedMayBeGroup(True);
        MENU_TAG_AD_NEW_OBJECT, MENU_TAG_AD_NEW_OU:
          begin
            Visible := kind = pkActiveDirectory;
            Enabled := writable and hasDn and SelectedAccepts(Tag = MENU_TAG_AD_NEW_OU);
          end;
      else
        if Caption <> '-' then Enabled := hasDn;
      end;
  if hasDn and (FTree.Selected <> nil) and TNodeData(FTree.Selected.Data).LdifGlue then
    for i := 0 to FTreeMenu.Items.Count - 1 do
      with FTreeMenu.Items[i] do
        if (Caption <> '-') and (Caption <> rsDirMenuRefresh) and (Caption <> rsDirMenuCopyDn) and
           (Caption <> rsDirMenuSearchHere) then
          Enabled := False;
end;

function TDirectoryTab.SelectedAccepts(AOrgUnit: Boolean): Boolean;

  function Has(const AClasses, AName: string): Boolean;
  begin
    Result := Pos(',' + AName + ',', AClasses) > 0;
  end;

var
  node: TTreeNode;
  cls: string;
begin
  Result := False;
  node := FTree.Selected;
  if (node = nil) or (node.Data = nil) or TNodeData(node.Data).IsPlaceholder or
     TNodeData(node.Data).IsGroup then Exit;
  if node.Parent = nil then Exit(True);
  cls := TNodeData(node.Data).Classes;
  if cls = '' then Exit(True);
  Result := Has(cls, 'organizationalunit') or Has(cls, 'domaindns') or Has(cls, 'domain') or
    Has(cls, 'organization');
  if not AOrgUnit then
    Result := Result or Has(cls, 'container');
end;

function TDirectoryTab.SelectedIsContainer: Boolean;
var
  node: TTreeNode;
  d: TNodeData;
begin
  Result := False;
  node := FTree.Selected;
  if (node = nil) or (node.Data = nil) then Exit;
  d := TNodeData(node.Data);
  if d.IsPlaceholder or d.IsGroup then Exit;
  Result := (node.Parent = nil) or (d.Classes = '') or d.Container or (node.Count > 0);
end;

function TDirectoryTab.SelectedMayBeGroup(ADynamic: Boolean): Boolean;
var
  node: TTreeNode;
  d: TNodeData;
  e: TLdapEntry;
  c: string;
  model: TGroupModel;
begin
  Result := False;
  node := FTree.Selected;
  if (node = nil) or (node.Data = nil) then Exit;
  d := TNodeData(node.Data);
  if d.IsPlaceholder or d.IsGroup then Exit;
  if d.Classes = '' then Exit(True);
  e := TLdapEntry.Create(d.Dn);
  try
    for c in d.Classes.Split([',']) do
      if c <> '' then e.Ensure('objectClass').AddValue(RawByteString(c));
    model := DetectGroupModel(e, ServerKind);
  finally
    e.Free;
  end;
  if ADynamic then Result := model.Kind = gkDynamicUrl
  else Result := model.Kind <> gkNotGroup;
end;

function TDirectoryTab.QuickFilter: string;
var
  c: TDirectoryConnection;
begin
  c := Conn;
  if c <> nil then Result := QuickSearchFilter(FSearchBox.SearchText, c.Schema)
  else Result := QuickSearchFilter(FSearchBox.SearchText);
end;

function TDirectoryTab.ServerKind: TProviderKind;
var
  c: TDirectoryConnection;
begin
  c := Conn;
  if c = nil then Exit(pkOther);
  Result := EffectiveServerKind(c.Profile, c.RootDse);
end;

procedure TDirectoryTab.TransferDone(Sender: TObject);
begin
  RefreshNodeClick(nil);
end;

procedure TDirectoryTab.OpenEntryFromDialog(const AProfileUuid, ADn: string);
begin
  if Assigned(FOnOpenEntry) then FOnOpenEntry(AProfileUuid, ADn);
end;

procedure TDirectoryTab.EntryWrittenFromDialog(const AProfileUuid, ADn: string);
begin
  if Assigned(FOnEntryWritten) then FOnEntryWritten(AProfileUuid, ADn)
  else RereadIfShown(ADn);
end;

procedure TDirectoryTab.CloneClick(Sender: TObject);
begin
  if SelectedDn = '' then Exit;
  ShowTransferDialog(GetParentForm(Self), FCtx, FProfileUuid, SelectedDn, tmClone, @TransferDone);
end;

procedure TDirectoryTab.CopySubtreeClick(Sender: TObject);
begin
  if SelectedDn = '' then Exit;
  ShowTransferDialog(GetParentForm(Self), FCtx, FProfileUuid, SelectedDn, tmCopyBranch,
    @TransferDone);
end;

procedure TDirectoryTab.MoveServerClick(Sender: TObject);
begin
  if SelectedDn = '' then Exit;
  ShowTransferDialog(GetParentForm(Self), FCtx, FProfileUuid, SelectedDn, tmMoveToServer,
    @TransferDone);
end;

procedure TDirectoryTab.MembersClick(Sender: TObject);
begin
  if SelectedDn = '' then Exit;
  ShowMembershipDialog(GetParentForm(Self), FCtx, FProfileUuid, SelectedDn, False,
    @OpenEntryFromDialog, @EntryWrittenFromDialog);
end;

procedure TDirectoryTab.MemberOfClick(Sender: TObject);
begin
  if SelectedDn = '' then Exit;
  ShowMembershipDialog(GetParentForm(Self), FCtx, FProfileUuid, SelectedDn, True,
    @OpenEntryFromDialog, @EntryWrittenFromDialog);
end;

procedure TDirectoryTab.DynamicClick(Sender: TObject);
begin
  if SelectedDn = '' then Exit;
  ShowDynamicGroupDialog(GetParentForm(Self), FCtx, FProfileUuid, SelectedDn, @EntryWrittenFromDialog);
end;

procedure TDirectoryTab.AccountClick(Sender: TObject);
begin
  if SelectedDn = '' then Exit;
  ShowAccountDialog(GetParentForm(Self), FCtx, FProfileUuid, SelectedDn);
  RefreshSelected;
end;

procedure TDirectoryTab.ReplMetaClick(Sender: TObject);
begin
  if SelectedDn = '' then Exit;
  ShowAdReplicationMetadata(GetParentForm(Self), FCtx, FProfileUuid, SelectedDn);
end;

procedure TDirectoryTab.AccountFlagsClick(Sender: TObject);
begin
  if SelectedDn = '' then Exit;
  ShowAccountFlags(GetParentForm(Self), FCtx, FProfileUuid, SelectedDn);
  RefreshSelected;
end;

procedure TDirectoryTab.SecurityClick(Sender: TObject);
begin
  if SelectedDn = '' then Exit;
  ShowSecurityDescriptor(GetParentForm(Self), FCtx, FProfileUuid, SelectedDn);
end;

procedure TDirectoryTab.ProtectionClick(Sender: TObject);
begin
  if SelectedDn = '' then Exit;
  ShowDeletionProtection(GetParentForm(Self), FCtx, FProfileUuid, SelectedDn);
end;

procedure TDirectoryTab.TreeMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  FDragNode := nil;
  if Button <> mbLeft then Exit;
  FDragNode := FTree.GetNodeAt(X, Y);
  FDragStart := Point(X, Y);
end;

procedure TDirectoryTab.TreeMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if (FDragNode = nil) or not (ssLeft in Shift) or FTree.Dragging then Exit;
  if (Abs(X - FDragStart.X) < 8) and (Abs(Y - FDragStart.Y) < 8) then Exit;
  if (FDragNode.Data = nil) or TNodeData(FDragNode.Data).IsPlaceholder or
     TNodeData(FDragNode.Data).IsGroup then Exit;
  FTree.BeginDrag(True);
end;

procedure TDirectoryTab.TreeDragOver(Sender, Source: TObject; X, Y: Integer; State: TDragState;
  var Accept: Boolean);
var
  target: TTreeNode;
  c: TDirectoryConnection;
begin
  Accept := False;
  c := Conn;
  if (Source <> FTree) or (FDragNode = nil) or (c = nil) or c.Profile.ReadOnly then Exit;
  target := FTree.GetNodeAt(X, Y);
  if (target = nil) or (target.Data = nil) or TNodeData(target.Data).IsPlaceholder or
     TNodeData(target.Data).IsGroup then Exit;
  if (target = FDragNode) or target.HasAsParent(FDragNode) or
     (target = EntryNode(FDragNode.Parent)) then Exit;
  Accept := True;
end;

procedure TDirectoryTab.TreeDragDrop(Sender, Source: TObject; X, Y: Integer);
var
  target: TTreeNode;
  dn: string;
begin
  target := FTree.GetNodeAt(X, Y);
  if (Source <> FTree) or (FDragNode = nil) or (target = nil) or (target.Data = nil) then Exit;
  dn := TNodeData(FDragNode.Data).Dn;
  FDragNode := nil;
  PrepareMove(dn, TNodeData(target.Data).Dn);
end;

procedure TDirectoryTab.RefreshNodeClick(Sender: TObject);
var
  node: TTreeNode;
begin
  node := FTree.Selected;
  if node = nil then Exit;
  if (node.Data <> nil) and (TNodeData(node.Data).IsPlaceholder or TNodeData(node.Data).IsGroup) then
    node := node.Parent;
  if node = nil then Exit;
  if (node.Parent <> nil) and (Sender = nil) then
    node := node.Parent;
  node := EntryNode(node);
  if node = nil then Exit;
  ReloadNode(node);
end;

procedure TDirectoryTab.RereadClick(Sender: TObject);
begin
  TreeSelectionChanged(nil);
end;

function TDirectoryTab.RereadIfShown(const ADn: string): Boolean;
begin
  Result := False;
  if (CurrentEntry = nil) or not SameDnStrict(CurrentEntry.Dn, ADn) then Exit;
  if HasPendingEdits then Exit(True);
  FEditor.KeepRevealOnNextRead(CurrentEntry.Dn);
  DirectRead(CurrentEntry.Dn);
  if not FEditor.ReadPending then FEditor.KeepRevealOnNextRead('');
end;

procedure TDirectoryTab.RefreshSelected;
begin
  RefreshNodeClick(Self);
  RereadClick(nil);
end;

procedure TDirectoryTab.CopyDnClick(Sender: TObject);
begin
  if SelectedDn <> '' then
    Clipboard.AsText := SelectedDn;
end;

procedure TDirectoryTab.SearchHereClick(Sender: TObject);
begin
  if Assigned(FOnOpenSearch) and (SelectedDn <> '') then
    FOnOpenSearch(Self, SelectedDn, QuickFilter,
      TSearchScope(FScope.ItemIndex), False);
end;

procedure TDirectoryTab.SearchClick(Sender: TObject);
var
  base: string;
begin
  base := SelectedDn;
  if base = '' then
    base := Trim(FDnBox.SearchText);
  if Assigned(FOnOpenSearch) then
    FOnOpenSearch(Self, base, QuickFilter,
      TSearchScope(FScope.ItemIndex), True);
end;

procedure TDirectoryTab.ExpertClick(Sender: TObject);
begin
  ExpertSearch;
end;

procedure TDirectoryTab.ExpertSearch;
var
  base: string;
begin
  base := SelectedDn;
  if base = '' then
    base := Trim(FDnBox.SearchText);
  if Assigned(FOnOpenSearch) then
    FOnOpenSearch(Self, base, QuickFilter,
      TSearchScope(FScope.ItemIndex), False);
end;

procedure TDirectoryTab.PasswordClick(Sender: TObject);
begin
  if Assigned(FOnPasswordTools) and (FEditor.Original <> nil) then
    FOnPasswordTools(Self, FEditor.Original);
end;

procedure TDirectoryTab.ExportEntryClick(Sender: TObject);
begin
  if Assigned(FOnExportEntry) and (FEditor.Original <> nil) then
    FOnExportEntry(Self, FEditor.Original);
end;

procedure TDirectoryTab.GoClick(Sender: TObject);
var
  d: TLdapDn;
  err: string;
begin
  if not DnParse(Trim(FDnBox.SearchText), d, err) then
  begin
    FCtx.Log(mlWarning, Caption, Format(rsDirInvalidDn, [err]));
    Exit;
  end;
  NavigateTo(DnToString(d));
end;

procedure TDirectoryTab.DirectRead(const ADn: string);
var
  c: TDirectoryConnection;
begin
  if HasPendingEdits and not ConfirmDiscardEdits then Exit;
  FDnBox.SetText(ADn);
  c := Conn;
  if (c = nil) or not c.IsReady then Exit;
  FPendingReadDn := ADn;
  FTasks.Cancel('read');
  if FTasks.ReadEntry('read', ADn, EntryReadAttributes(c.Profile)) <> 0 then
    FEditor.ReadPending := True;
end;

function TDirectoryTab.FoldedChildGroup(ANode: TTreeNode; const ATarget: TLdapDn;
  ACmp: TDnComparer): TTreeNode;
var
  data: TNodeData;
  k: Integer;
  cd: TLdapDn;
begin
  Result := nil;
  data := TNodeData(ANode.Data);
  for k := 0 to data.ChildCount - 1 do
  begin
    if not DnTryParse(data.Children[k].Dn, cd) then Continue;
    if ACmp.IsUnder(ATarget, cd, True) = dmEqual then
    begin
      Result := GroupOf(ANode, k);
      if (Result <> nil) and TNodeData(Result.Data).Loaded then Result := nil;
      Exit;
    end;
  end;
end;

procedure TDirectoryTab.NavigateTo(const ADn: string);
var
  i, bestDepth: Integer;
  node, grp: TTreeNode;
  cmp: TDnComparer;
  target, nd: TLdapDn;
  best: TTreeNode;
begin
  if not DnTryParse(ADn, target) then Exit;
  cmp := TDnComparer.Create;
  try
    best := nil;
    bestDepth := -1;
    for i := 0 to FTree.Items.Count - 1 do
    begin
      node := FTree.Items[i];
      if (node.Data = nil) or TNodeData(node.Data).IsPlaceholder or
         TNodeData(node.Data).IsGroup then Continue;
      if not DnTryParse(TNodeData(node.Data).Dn, nd) then Continue;
      if cmp.CompareDn(nd, target) = dmEqual then
      begin
        FPendingSelectDn := '';
        node.Selected := True;
        node.MakeVisible;
        Exit;
      end;
      if (cmp.IsUnder(target, nd, False) = dmEqual) and (DnRdnCount(nd) > bestDepth) then
      begin
        best := node;
        bestDepth := DnRdnCount(nd);
      end;
    end;
    FPendingSelectDn := ADn;
    if (best <> nil) and TNodeData(best.Data).Loaded and TNodeData(best.Data).Folded then
    begin
      grp := FoldedChildGroup(best, target, cmp);
      if grp <> nil then
      begin
        MaterializeGroup(grp);
        grp.Expand(False);
        NavigateTo(ADn);
        Exit;
      end;
    end;
    if best <> nil then
    begin
      if TNodeData(best.Data).Loaded then
      begin
        FPendingSelectDn := '';
        DirectRead(ADn);
      end
      else
      begin
        // La cible est sous ce noeud: il a donc des enfants, meme si sa lecture l'avait cru
        // terminal. La LCL refuse de deplier un noeud sans enfants.
        best.HasChildren := True;
        best.Expand(False);
      end;
    end
    else
    begin
      FPendingSelectDn := '';
      DirectRead(ADn);
    end;
  finally
    cmp.Free;
  end;
end;

procedure TDirectoryTab.FocusDn;
begin
  if FDnBox.CanFocusEdit then
  begin
    FDnBox.FocusEdit;
    FDnBox.SelectAll;
  end;
end;

procedure TDirectoryTab.NewChildClick(Sender: TObject);
var
  parentDn, created: string;
  c: TDirectoryConnection;
begin
  c := Conn;
  parentDn := SelectedDn;
  if (c = nil) or (parentDn = '') then Exit;
  created := ShowCreateWizard(GetParentForm(Self), FCtx, c.Profile.Uuid, parentDn);
  if created = '' then Exit;
  FollowCreation(parentDn, created);
end;

procedure TDirectoryTab.FollowCreation(const AParentDn, ACreated: string);
var
  cmp: TDnComparer;
  node: TTreeNode;
begin
  cmp := TDnComparer.Create;
  try
    node := FindEntryNode(AParentDn, cmp);
    if node <> nil then ReloadNode(node);
  finally
    cmp.Free;
  end;
  NavigateTo(ACreated);
end;

procedure TDirectoryTab.NewAdObject(AKind: Integer);
var
  parentDn, created: string;
  c: TDirectoryConnection;
begin
  c := Conn;
  parentDn := SelectedDn;
  if (c = nil) or (parentDn = '') then Exit;
  created := ShowAdCreateDialog(GetParentForm(Self), FCtx, c.Profile.Uuid, parentDn,
    TAdCreateKind(AKind));
  if created <> '' then FollowCreation(parentDn, created);
end;

procedure TDirectoryTab.NewAdUserClick(Sender: TObject);
begin
  NewAdObject(Ord(ackUser));
end;

procedure TDirectoryTab.NewAdComputerClick(Sender: TObject);
begin
  NewAdObject(Ord(ackComputer));
end;

procedure TDirectoryTab.NewAdGroupClick(Sender: TObject);
begin
  NewAdObject(Ord(ackGroup));
end;

procedure TDirectoryTab.NewAdOuClick(Sender: TObject);
begin
  NewAdObject(Ord(ackOrgUnit));
end;

procedure TDirectoryTab.RenameClick(Sender: TObject);
var
  dn: string;
  d: TLdapDn;
begin
  dn := SelectedDn;
  if (dn = '') or not DnTryParse(dn, d) then Exit;
  PrepareMove(dn, DnToString(DnParent(d)));
end;

procedure TDirectoryTab.PrepareMove(const ADn, ADefaultParent: string);
var
  c: TDirectoryConnection;
  dn, newRdn, newParent: string;
  src, np, rd: TLdapDn;
  err, reason: string;
  change: TLdapChange;
  cmp: TDnComparer;
  delOld: Integer;
begin
  c := Conn;
  dn := ADn;
  if (c = nil) or (dn = '') or not DnParse(dn, src, err) then Exit;
  newRdn := RdnToString(DnLeaf(src));
  if not RtInputQuery(rsDirMenuRename, rsDirRenameNewRdn, newRdn) then Exit;
  newParent := ADefaultParent;
  if not RtInputQuery(rsDirMenuRename, rsDirRenameNewParent, newParent) then Exit;
  if not DnParse(newRdn, rd, err) or (DnRdnCount(rd) <> 1) then Exit;
  if not DnParse(newParent, np, err) then Exit;
  cmp := TDnComparer.Create;
  try
    if cmp.IsUnder(np, src, True) = dmEqual then
    begin
      RtMessageDlg(rsDirMenuRename, rsDirRenameUnderItself, mtError, [mbOK], 0);
      Exit;
    end;
    change := NewChange(ckModDn, dn);
    change.NewRdn := newRdn;
    change.HasNewSuperior := cmp.CompareDn(np, DnParent(src)) <> dmEqual;
    if change.HasNewSuperior then change.NewSuperior := newParent;
  finally
    cmp.Free;
  end;
  // deleteOldRDN se choisit explicitement. Active Directory refuse de garder l'ancienne
  // valeur (unwillingToPerform "Old RDN must be deleted"): inutile de poser une question
  // dont une des reponses echoue a tous les coups.
  if ServerKind = pkActiveDirectory then
    delOld := mrYes
  else
    delOld := RtQuestionDlg(rsDirMenuRename, rsDirRenameDeleteOld,
      mtConfirmation, [mrYes, rsDirRenameRemoveOld, mrNo, rsDirRenameKeepOld, mrCancel, rsDirCancel], 0);
  if delOld = mrCancel then
  begin
    change.Free;
    Exit;
  end;
  change.DeleteOldRdn := delOld = mrYes;
  if (SubmitWrite(GetParentForm(Self), FCtx, FTasks, VIEW_WRITE_TAG, change, '', reason) = 0) and
     (reason <> '') then
    RtMessageDlg(Caption, reason, mtWarning, [mbOK], 0);
end;

procedure TDirectoryTab.DeleteClick(Sender: TObject);
begin
  DeleteSelected;
end;

procedure TDirectoryTab.DeleteSelected;
var
  c: TDirectoryConnection;
  dn, assertion, note, reason: string;
  node: TTreeNode;
  change: TLdapChange;
  announced: Boolean;
begin
  c := Conn;
  dn := SelectedDn;
  if (c = nil) or (dn = '') then Exit;
  node := FTree.Selected;
  if node.HasChildren and not (TNodeData(node.Data).Loaded and (node.Count = 0)) then
  begin
    // Perimetre enumere en entier avant l'apercu, puis reverifie juste avant l'execution. Si le
    // serveur annonce Assertion (RFC 4528), chaque suppression porte la version relue.
    StartSubtreeDeletion(dn);
    Exit;
  end;
  change := NewChange(ckDelete, dn);
  // Suppression conditionnee a la version affichee (RFC 4528): une entree modifiee entre-temps
  // n'est pas effacee, le serveur repond assertionFailed. Sans controle ou sans version lue,
  // elle part sans condition, et la confirmation l'avoue.
  assertion := '';
  note := '';
  announced := ServerSupportsControl(c.RootDse, LDAP_CONTROL_ASSERTION_OID);
  if announced and (FEditor.Original <> nil) and not FEditor.ReadPending and
    SameDnStrict(FEditor.Original.Dn, dn) then
    assertion := VersionAssertion(FEditor.Original);
  if c.Profile.LdifPath <> '' then
    note := ''
  else if not announced then
    note := rsDirDeleteNoAssertion
  else if assertion = '' then
    note := rsDirDeleteNotRead;
  if (SubmitWrite(GetParentForm(Self), FCtx, FTasks, VIEW_WRITE_TAG, change, assertion, reason,
      note) = 0) and (reason <> '') then
    RtMessageDlg(Caption, reason, mtWarning, [mbOK], 0);
end;

function TDirectoryTab.StartSubtreeDeletion(const ADn: string): Boolean;
var
  c: TDirectoryConnection;
begin
  Result := False;
  c := Conn;
  if c = nil then Exit;
  if FSubtree.Active then
  begin
    if (FProgress <> nil) and (GetParentForm(Self) <> nil) and GetParentForm(Self).Visible then
      FProgress.Show;
    Exit;
  end;
  if not FSubtree.Start(ADn, ServerSupportsControl(c.RootDse, LDAP_CONTROL_ASSERTION_OID)) then
  begin
    FCtx.Log(mlError, Caption, ErrorToText(FSubtree.LastError));
    Exit;
  end;
  ShowSubtreeProgress;
  Result := True;
end;

procedure TDirectoryTab.SubtreeEntries(AMsg: TEntriesMsg);
var
  i: Integer;
  c: TDirectoryConnection;
  changes: array of TLdapChange;
  ok: Boolean;
  note, reason: string;
begin
  case FSubtree.HandleEntries(AMsg) of
    sdoPending:
      UpdateSubtreeProgress;
    sdoIncomplete:
      begin
        FinishSubtreeProgress(Format(rsDirSubtreeIncomplete, [ErrorToText(FSubtree.LastError)]), usError);
        RtMessageDlg(rsDirMenuDelete, Format(rsDirSubtreeIncomplete, [ErrorToText(FSubtree.LastError)]),
          mtError, [mbOK], 0);
      end;
    sdoScopeChanged:
      begin
        FinishSubtreeProgress(rsDirSubtreeChanged, usWarning);
        RtMessageDlg(rsDirMenuDelete, rsDirSubtreeChanged, mtWarning, [mbOK], 0);
      end;
    sdoDeleting:
      begin
        FCtx.Log(mlInfo, Caption, Format(rsDirSubtreeDeleting, [FSubtree.Targets.Count]));
        UpdateSubtreeProgress;
      end;
    sdoStopped:
      SubtreeWrite(nil);
    sdoUnprotectedConfirm:
      begin
        // Certaines cibles n'ont aucun marqueur de version: rien ne part sans accord explicite.
        UpdateSubtreeProgress;
        if RtMessageDlg(rsDirMenuDelete, Format(rsDirSubtreeUnprotected2,
            [FSubtree.PendingUnprotected, FSubtree.Targets.Count]), mtWarning,
            [mbYes, mbNo], 0) = mrYes then
        begin
          if FSubtree.ConfirmUnprotected = sdoDeleting then
          begin
            FCtx.Log(mlInfo, Caption, Format(rsDirSubtreeDeleting, [FSubtree.Targets.Count]));
            UpdateSubtreeProgress;
          end
          else
            SubtreeWrite(nil);
        end
        else
        begin
          FSubtree.Cancel;
          FCtx.Log(mlWarning, Caption, Format(rsDirSubtreeUnprotectedRefused,
            [FSubtree.PendingUnprotected]));
          FinishSubtreeProgress(Format(rsDirSubtreeUnprotectedRefused,
            [FSubtree.PendingUnprotected]), usWarning);
        end;
      end;
    sdoConfirmNeeded:
      begin
        UpdateSubtreeProgress;
        c := Conn;
        if c = nil then
        begin
          FSubtree.Cancel;
          FinishSubtreeProgress(rsDirNotConnected, usError);
          Exit;
        end;
        changes := nil;
        SetLength(changes, FSubtree.Targets.Count);
        if Length(changes) > SUBTREE_PREVIEW_MAX then SetLength(changes, SUBTREE_PREVIEW_MAX);
        for i := 0 to High(changes) do
          changes[i] := NewChange(ckDelete, FSubtree.Targets[i]);
        note := Format(rsDirSubtreePreview, [FSubtree.Targets.Count, FSubtree.BaseDn]);
        if FSubtree.Targets.Count > SUBTREE_PREVIEW_MAX then
          note := note + LineEnding + Format(rsDirSubtreePreviewTruncated, [SUBTREE_PREVIEW_MAX]);
        // Pas de controle Assertion pour la suppression: on le dit avant de confirmer.
        if (not FSubtree.AssertionAnnounced) and (c.Profile.LdifPath = '') then
          note := note + LineEnding + rsDirSubtreeNoAssertion;
        try
          // Perimetre enumere dans cette session: la meme apres confirmation, ou rien ne part.
          ok := ConfirmWrite(GetParentForm(Self), FCtx, FSubtreeTasks, changes, reason, note);
        finally
          for i := 0 to High(changes) do
            changes[i].Free;
        end;
        if not ok and (reason <> '') then
        begin
          FSubtree.Cancel;
          FinishSubtreeProgress(reason, usError);
        end
        else if not ok then
        begin
          FSubtree.Cancel;
          FinishSubtreeProgress(rsDirSubtreeNotConfirmed, usMuted);
          if FProgress <> nil then FProgress.Hide;
        end
        else if FSubtree.Confirm = sdoStopped then
          SubtreeWrite(nil)
        else
          UpdateSubtreeProgress;
      end;
  end;
end;

procedure TDirectoryTab.SubtreeWrite(AMsg: TWriteMsg);
var
  outcome: TSubtreeOutcome;
begin
  if AMsg <> nil then
  begin
    outcome := FSubtree.HandleWrite(AMsg);
    if outcome = sdoNotMine then Exit;
    // Issue deja consignee au journal. Une ecriture ambigue n'est jamais renvoyee
    // automatiquement: on ne retente pas un rm au hasard.
    if AMsg.Result.Ok then
      FCtx.Log(mlInfo, Caption, AMsg.Change.Describe)
    else if AMsg.Result.Error.Category = lecUnknownOutcome then
      FCtx.Log(mlError, Caption, rsDirUnknownOutcome + ' ' + AMsg.Change.Describe);
  end
  else
    outcome := sdoStopped;
  case outcome of
    sdoDeleting:
      UpdateSubtreeProgress;
    sdoUserStopped:
      begin
        FCtx.Log(mlWarning, Caption, Format(rsDirSubtreeUserStopped,
          [FSubtree.Deleted, FSubtree.NotAttempted]));
        FinishSubtreeProgress(Format(rsDirSubtreeUserStopped, [FSubtree.Deleted, FSubtree.NotAttempted]),
          usWarning);
        if FSubtree.Deleted > 0 then TreeFollowSubtree;
      end;
    sdoFinished:
      begin
        FinishSubtreeProgress(Format(rsDirSubtreeDone, [FSubtree.Deleted, FSubtree.BaseDn]), usOk);
        FCtx.Log(mlInfo, Caption, Format(rsDirSubtreeDone, [FSubtree.Deleted, FSubtree.BaseDn]));
        // Repli sans Assertion jamais silencieux: le compte va au journal.
        if FSubtree.AssertionAnnounced and (FSubtree.UnprotectedDeletes > 0) then
          FCtx.Log(mlWarning, Caption,
            Format(rsDirSubtreeUnprotected, [FSubtree.UnprotectedDeletes]));
        TreeFollowSubtree;
      end;
    sdoStopped:
      begin
        FinishSubtreeProgress(SubtreeStopSummary(ErrorToText(FSubtree.LastError)), usError);
        FCtx.Log(mlError, Caption, SubtreeStopSummary(ErrorToText(FSubtree.LastError)));
        RtMessageDlg(rsDirMenuDelete, SubtreeStopSummary(ErrorToText(FSubtree.LastError) +
          LineEnding + FSubtree.LastError.Action), mtError, [mbOK], 0);
        if (FSubtree.Deleted > 0) or (FSubtree.UnconfirmedDn <> '') then
          TreeFollowSubtree;
      end;
  end;
end;

procedure TDirectoryTab.ShowSubtreeProgress;
var
  c: TDirectoryConnection;
begin
  FreeAndNil(FProgress);
  c := Conn;
  if c = nil then Exit;
  FProgress := TSubtreeProgressDialog.CreateProgress(nil, FSubtree.BaseDn,
    c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
  // Possedee par la fenetre principale, donc toujours au-dessus: sinon un clic dans l'arbre
  // la cachait derriere, sans bouton dans la barre des taches pour la retrouver.
  if GetParentForm(Self) <> nil then
  begin
    FProgress.PopupMode := pmExplicit;
    FProgress.PopupParent := GetParentForm(Self);
  end;
  FProgress.OnStop := @SubtreeStopClick;
  FProgress.UpdateFrom(FSubtree);
  if (GetParentForm(Self) <> nil) and GetParentForm(Self).Visible then
    FProgress.Show;
end;

procedure TDirectoryTab.UpdateSubtreeProgress;
begin
  if FProgress <> nil then FProgress.UpdateFrom(FSubtree);
end;

procedure TDirectoryTab.FinishSubtreeProgress(const ASummary: string; AState: TUiState);
begin
  if FProgress = nil then Exit;
  FProgress.UpdateFrom(FSubtree);
  FProgress.Finish(ASummary, AState);
end;

procedure TDirectoryTab.SubtreeStopClick(Sender: TObject);
begin
  case FSubtree.RequestStop of
    sdoUserStopped:
      begin
        FCtx.Log(mlWarning, Caption, rsDirSubtreeStoppedEarly);
        FinishSubtreeProgress(rsDirSubtreeStoppedEarly, usWarning);
      end;
    sdoDeleting:
      UpdateSubtreeProgress;
  end;
end;

function TDirectoryTab.SubtreeStopSummary(const AReason: string): string;
begin
  Result := Format(rsDirSubtreeStopped, [FSubtree.Deleted, FSubtree.NotAttempted]);
  if FSubtree.RefusedDn <> '' then
    Result := Result + ' ' + Format(rsDirSubtreeRefused, [FSubtree.RefusedDn]);
  if FSubtree.UnconfirmedDn <> '' then
    Result := Result + ' ' + Format(rsDirSubtreeUnconfirmed, [FSubtree.UnconfirmedDn]);
  if AReason <> '' then
    Result := Result + ' ' + AReason;
  if (FSubtree.NotAttempted > 0) or (FSubtree.UnconfirmedDn <> '') then
    Result := Result + ' ' + Format(rsDirSubtreeResume, [FSubtree.BaseDn]);
end;

// D'apres la base de la suppression, jamais la selection: la fenetre de progression n'est pas
// modale et la selection a pu bouger. Sinon une OU de 30000 entrees reste affichee, morte.
procedure TDirectoryTab.TreeFollowSubtree;
var
  cmp: TDnComparer;
  base: TLdapDn;
  node: TTreeNode;
begin
  if not DnTryParse(FSubtree.BaseDn, base) or (DnRdnCount(base) = 0) then Exit;
  cmp := TDnComparer.Create;
  try
    node := FindEntryNode(DnToString(DnParent(base)), cmp);
    if node = nil then node := FindEntryNode(FSubtree.BaseDn, cmp);
    if node <> nil then ReloadNode(node);
  finally
    cmp.Free;
  end;
end;

procedure TDirectoryTab.InterruptSubtree(const AReason: string; ARefresh: Boolean);
var
  wasDeleting: Boolean;
begin
  wasDeleting := FSubtree.State = sdsDeleting;
  FSubtree.Cancel;
  if not wasDeleting then
  begin
    FCtx.Log(mlWarning, Caption, Format(rsDirSubtreeCancelledEarly, [AReason]));
    FinishSubtreeProgress(Format(rsDirSubtreeCancelledEarly, [AReason]), usWarning);
    Exit;
  end;
  FinishSubtreeProgress(SubtreeStopSummary(AReason), usError);
  FCtx.Log(mlError, Caption, SubtreeStopSummary(AReason));
  RtMessageDlg(rsDirMenuDelete, SubtreeStopSummary(AReason), mtError, [mbOK], 0);
  if ARefresh and ((FSubtree.Deleted > 0) or (FSubtree.UnconfirmedDn <> '')) then
    TreeFollowSubtree;
end;

end.
