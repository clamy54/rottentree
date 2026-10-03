// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uProfileSidebar;

{$mode objfpc}{$H+}

// Panneau lateral: filtre, arbre des dossiers et profils, etat de connexion de chaque profil, panneau
// de verrouillage. Les actions restent a la fenetre principale: ici on montre, on ne decide rien.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, ExtCtrls, StdCtrls, Menus, Graphics, uSearchBox, uTreeScrollBar,
  uProfileCatalog, uRtDocument, uConnectionProfile;

type
  TSideNodeKind = (snkFolder, snkProfile);

  TSideRef = class
  public
    Kind: TSideNodeKind;
    Uuid: string;
    constructor Create(AKind: TSideNodeKind; const AUuid: string);
  end;

  // Designe par identite: les TSideRef appartiennent aux noeuds et meurent a chaque reconstruction.
  TSideItem = record
    Kind: TSideNodeKind;
    Uuid: string;
  end;
  TSideItems = array of TSideItem;
  TSideMoveEvent = procedure(const AItems: TSideItems; const AFolderUuid: string) of object;

  TProfileLinkState = (plsNone, plsBusy, plsReady, plsFailed);
  TProfileStateFunc = function(const AUuid: string): TProfileLinkState of object;

  TProfileSidebar = class(TPanel)
  private
    FSearch: TRottenSearchBox;
    FTree: TScrollTreeView;
    FTreeScroll: TTreeScrollBar;
    FLockPanel: TPanel;
    FCatalog: TProfileCatalog;
    FOnProfileState: TProfileStateFunc;
    FOnActivateProfile: TNotifyEvent;
    FOnFilterChanged: TNotifyEvent;
    FOnLockPanelClick: TNotifyEvent;
    FOnMoveItems: TSideMoveEvent;
    FDragNode: TTreeNode;
    FDragStart: TPoint;
    procedure TreeDblClick(Sender: TObject);
    procedure TreeDeletion(Sender: TObject; Node: TTreeNode);
    procedure TreeMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure TreeMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure TreeDragOver(Sender, Source: TObject; X, Y: Integer; State: TDragState;
      var Accept: Boolean);
    procedure TreeDragDrop(Sender, Source: TObject; X, Y: Integer);
    procedure TreeEndDrag(Sender, Target: TObject; X, Y: Integer);
    function RowNodeAt(Y: Integer): TTreeNode;
    procedure TreeDraw(Sender: TCustomTreeView; Node: TTreeNode; State: TCustomDrawState;
      Stage: TCustomDrawStage; var PaintImages, DefaultDraw: Boolean);
    procedure SearchChanged(Sender: TObject);
    procedure LockPanelClick(Sender: TObject);
    function GetTreeMenu: TPopupMenu;
    procedure SetTreeMenu(AValue: TPopupMenu);
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetImages(AImages: TImageList);
    procedure ApplyTheme;
    procedure Rebuild(ADoc: TRtDocument; ACatalog: TProfileCatalog; ALocked: Boolean);
    procedure SetState(AHasDocument, ALocked: Boolean);
    function SelectedRef: TSideRef;
    function SelectedText: string;
    procedure InvalidateTree;
    function PlanMove(ATarget: TTreeNode; out AItems: TSideItems; out AFolderUuid: string): Boolean;
    procedure SelectItems(const AItems: TSideItems);
    property TreeMenu: TPopupMenu read GetTreeMenu write SetTreeMenu;
    property OnProfileState: TProfileStateFunc read FOnProfileState write FOnProfileState;
    property OnActivateProfile: TNotifyEvent read FOnActivateProfile write FOnActivateProfile;
    property OnFilterChanged: TNotifyEvent read FOnFilterChanged write FOnFilterChanged;
    property OnLockPanelClick: TNotifyEvent read FOnLockPanelClick write FOnLockPanelClick;
    property OnMoveItems: TSideMoveEvent read FOnMoveItems write FOnMoveItems;
  end;

implementation

uses
  uTheme, uIcons, uStrings, uUiKit;

constructor TSideRef.Create(AKind: TSideNodeKind; const AUuid: string);
begin
  inherited Create;
  Kind := AKind;
  Uuid := AUuid;
end;

constructor TProfileSidebar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption := '';

  FSearch := TRottenSearchBox.Create(Self);
  FSearch.Parent := Self;
  FSearch.Align := alTop;
  FSearch.Height := 34;
  FSearch.OnSearchChange := @SearchChanged;

  FTreeScroll := TTreeScrollBar.Create(Self);
  FTreeScroll.Parent := Self;
  FTreeScroll.Align := alRight;
  FTreeScroll.Width := 12;

  FTree := TScrollTreeView.Create(Self);
  FTree.Parent := Self;
  FTree.Align := alClient;
  FTree.BorderStyle := bsNone;
  FTree.ScrollBars := ssNone;
  FTree.ReadOnly := True;
  FTree.RightClickSelect := True;
  FTree.HideSelection := False;
  // Dessin LCL non theme: sinon le theme Windows peint le texte des profils en noir sur le fond
  // sombre. Parfait pour qui lit dans le noir, c'est-a-dire personne.
  FTree.Options := FTree.Options - [tvoThemedDraw];
  FTree.OnDblClick := @TreeDblClick;
  FTree.OnDeletion := @TreeDeletion;
  FTree.OnAdvancedCustomDrawItem := @TreeDraw;
  FTree.DragMode := dmManual;
  FTree.OnMouseDown := @TreeMouseDown;
  FTree.OnMouseMove := @TreeMouseMove;
  FTree.OnDragOver := @TreeDragOver;
  FTree.OnDragDrop := @TreeDragDrop;
  FTree.OnEndDrag := @TreeEndDrag;
  FTreeScroll.Bind(FTree);

  FLockPanel := TPanel.Create(Self);
  FLockPanel.Parent := Self;
  FLockPanel.Align := alClient;
  FLockPanel.BevelOuter := bvNone;
  FLockPanel.Caption := rsDocumentLocked;
  FLockPanel.Visible := False;
  FLockPanel.OnClick := @LockPanelClick;
  FLockPanel.Cursor := crHandPoint;
end;

function TProfileSidebar.GetTreeMenu: TPopupMenu;
begin
  Result := FTree.PopupMenu;
end;

procedure TProfileSidebar.SetTreeMenu(AValue: TPopupMenu);
begin
  FTree.PopupMenu := AValue;
end;

procedure TProfileSidebar.SetImages(AImages: TImageList);
begin
  FTree.Images := AImages;
end;

procedure TProfileSidebar.ApplyTheme;
begin
  Color := clSideBg;
  FTree.Color := clSideBg;
  FTree.Font.Color := clSideText;
  FTree.Font.Size := RSTreeFontSize;
  if RSUiFontName <> '' then FTree.Font.Name := RSUiFontName;
  FTree.SelectionColor := clSideSel;
  FTree.SelectionFontColor := clSideTextHi;
  FTree.SelectionFontColorUsed := True;
  FTree.TreeLineColor := clSideBg;
  FTree.ExpandSignType := tvestPlusMinus;
  FTree.ExpandSignColor := BlendColor(clSideText, clSideBg, 60);
  FitTreeIndent(FTree);
  FTree.BackgroundColor := clSideBg;
  FTreeScroll.ApplyTheme(clSideBg, BlendColor(clSideText, clSideBg, 22),
    BlendColor(clSideText, clSideBg, 42));
  FSearch.ApplyTheme(clSideBg, clSideHover, BlendColor(clSideText, clSideBg, 30), clAccent,
    clSideText, BlendColor(clSideText, clSideBg, 55), BlendColor(clSideText, clSideBg, 45));
  FLockPanel.Color := clSideBg;
  FLockPanel.Font.Color := clSideText;
  FTree.Invalidate;
end;

procedure TProfileSidebar.SetState(AHasDocument, ALocked: Boolean);
begin
  FTree.Visible := not ALocked;
  FTreeScroll.Visible := not ALocked;
  FLockPanel.Visible := ALocked;
  FSearch.SetEnabledLook(AHasDocument and not ALocked);
end;

procedure TProfileSidebar.Rebuild(ADoc: TRtDocument; ACatalog: TProfileCatalog; ALocked: Boolean);
var
  folders: TDocFolders;
  i: Integer;
  node, parentNode: TTreeNode;
  p: TConnectionProfile;

  function FindFolderNode(const AUuid: string): TTreeNode;
  var
    k: Integer;
  begin
    for k := 0 to FTree.Items.Count - 1 do
      if (FTree.Items[k].Data <> nil) and (TSideRef(FTree.Items[k].Data).Kind = snkFolder) and
         (TSideRef(FTree.Items[k].Data).Uuid = AUuid) then
        Exit(FTree.Items[k]);
    Result := nil;
  end;

begin
  FCatalog := ACatalog;
  FTree.Items.BeginUpdate;
  try
    FTree.Items.Clear;
    if (ADoc = nil) or ALocked then Exit;
    folders := FoldersParentFirst(ADoc.Folders);
    for i := 0 to High(folders) do
    begin
      parentNode := nil;
      if folders[i].ParentUuid <> '' then
        parentNode := FindFolderNode(folders[i].ParentUuid);
      node := FTree.Items.AddChildObject(parentNode, folders[i].Name,
        TSideRef.Create(snkFolder, folders[i].Uuid));
      node.ImageIndex := IconIndex('folder');
      node.SelectedIndex := IconIndex('folder-open');
    end;
    for i := 0 to ACatalog.Count - 1 do
    begin
      p := ACatalog[i];
      if not ProfileMatches(p, FSearch.SearchText) then Continue;
      parentNode := FindFolderNode(ACatalog.FolderOf(p.Uuid));
      node := FTree.Items.AddChildObject(parentNode, p.Name, TSideRef.Create(snkProfile, p.Uuid));
      if p.IconId <> '' then
        node.ImageIndex := IconIndex(p.IconId)
      else
        node.ImageIndex := IconIndex('server');
      if node.ImageIndex < 0 then node.ImageIndex := IconIndex('server');
      node.SelectedIndex := node.ImageIndex;
    end;
    FTree.FullExpand;
  finally
    FTree.Items.EndUpdate;
  end;
end;

procedure TProfileSidebar.TreeDeletion(Sender: TObject; Node: TTreeNode);
begin
  if Node = FDragNode then FDragNode := nil;
  TObject(Node.Data).Free;
  Node.Data := nil;
end;

procedure TProfileSidebar.TreeMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  // Appele avant que la LCL ne change la selection: on retient le noeud, et son etat selectionne
  // n'est lu qu'au debut du glisser.
  FDragNode := nil;
  if (Button <> mbLeft) or (ssDouble in Shift) then Exit;
  FDragNode := FTree.GetNodeAt(X, Y);
  FDragStart := Point(X, Y);
end;

procedure TProfileSidebar.TreeMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if (FDragNode = nil) or not (ssLeft in Shift) or FTree.Dragging then Exit;
  if (Abs(X - FDragStart.X) < 8) and (Abs(Y - FDragStart.Y) < 8) then Exit;
  if not FDragNode.Selected then
  begin
    FDragNode := nil;
    Exit;
  end;
  FTree.BeginDrag(True);
end;

procedure TProfileSidebar.TreeDragOver(Sender, Source: TObject; X, Y: Integer; State: TDragState;
  var Accept: Boolean);
var
  items: TSideItems;
  folder: string;
begin
  Accept := (Source = FTree) and (FDragNode <> nil) and PlanMove(RowNodeAt(Y), items, folder);
end;

function TProfileSidebar.RowNodeAt(Y: Integer): TTreeNode;
var
  r: TRect;
begin
  // GetNodeAt ne vise que le libelle; ici toute la ligne compte. Sous le dernier noeud: nil, la racine.
  Result := FTree.Items.GetFirstVisibleNode;
  while Result <> nil do
  begin
    r := Result.DisplayRect(False);
    if (Y >= r.Top) and (Y < r.Bottom) then Exit;
    Result := Result.GetNextVisible;
  end;
end;

procedure TProfileSidebar.TreeDragDrop(Sender, Source: TObject; X, Y: Integer);
var
  items: TSideItems;
  folder: string;
begin
  if (Source <> FTree) or (FDragNode = nil) then Exit;
  FDragNode := nil;
  if PlanMove(RowNodeAt(Y), items, folder) and Assigned(FOnMoveItems) then
    FOnMoveItems(items, folder);
end;

procedure TProfileSidebar.TreeEndDrag(Sender, Target: TObject; X, Y: Integer);
begin
  // Glisser abandonne (Echap, lacher hors de l'arbre): pas de nouveau depart tant que le bouton reste
  // enfonce.
  FDragNode := nil;
end;

function TProfileSidebar.PlanMove(ATarget: TTreeNode; out AItems: TSideItems;
  out AFolderUuid: string): Boolean;
var
  node, dest: TTreeNode;
begin
  AItems := nil;
  AFolderUuid := '';
  Result := False;
  node := FTree.Selected;
  if (node = nil) or (node.Data = nil) then Exit;
  dest := ATarget;
  if (dest <> nil) and (dest.Data <> nil) and (TSideRef(dest.Data).Kind = snkProfile) then
    dest := dest.Parent;
  // Un dossier sous lui-meme ou sous un descendant, c'est un cycle: refuse. Un element deja a sa place
  // ne bouge pas.
  if (dest <> nil) and ((dest = node) or dest.HasAsParent(node)) then Exit;
  if node.Parent = dest then Exit;
  if (dest <> nil) and (dest.Data <> nil) then AFolderUuid := TSideRef(dest.Data).Uuid;
  SetLength(AItems, 1);
  AItems[0].Kind := TSideRef(node.Data).Kind;
  AItems[0].Uuid := TSideRef(node.Data).Uuid;
  Result := True;
end;

procedure TProfileSidebar.SelectItems(const AItems: TSideItems);
var
  i, k: Integer;
  ref: TSideRef;
begin
  for i := 0 to FTree.Items.Count - 1 do
  begin
    ref := TSideRef(FTree.Items[i].Data);
    if ref = nil then Continue;
    for k := 0 to High(AItems) do
      if (AItems[k].Kind = ref.Kind) and (AItems[k].Uuid = ref.Uuid) then
      begin
        FTree.Selected := FTree.Items[i];
        Exit;
      end;
  end;
end;

procedure TProfileSidebar.TreeDraw(Sender: TCustomTreeView; Node: TTreeNode;
  State: TCustomDrawState; Stage: TCustomDrawStage; var PaintImages, DefaultDraw: Boolean);
var
  ref: TSideRef;
  tr: TRect;
  link: TProfileLinkState;
  selected: Boolean;
  fg: TColor;
  ty: Integer;
  p: TConnectionProfile;
begin
  DefaultDraw := True;
  if Stage <> cdPostPaint then Exit;
  ref := TSideRef(Node.Data);
  if (ref = nil) or (ref.Kind <> snkProfile) then Exit;
  link := plsNone;
  if Assigned(FOnProfileState) then link := FOnProfileState(ref.Uuid);
  p := nil;
  if FCatalog <> nil then p := FCatalog.Find(ref.Uuid);
  if (link = plsNone) and ((p = nil) or (p.EnvironmentBadge = '')) then Exit;
  selected := (cdsSelected in State) or (cdsMarked in State);
  if link = plsReady then
    fg := clSideActive
  else if link = plsFailed then
    fg := clTabDead
  else if selected then
    fg := clSideTextHi
  else
    fg := clSideText;
  tr := Node.DisplayRect(True);
  if selected then Sender.Canvas.Brush.Color := clSideSel else Sender.Canvas.Brush.Color := clSideBg;
  Sender.Canvas.FillRect(tr);
  Sender.Canvas.Brush.Style := bsClear;
  Sender.Canvas.Font.Color := fg;
  ty := tr.Top + (tr.Bottom - tr.Top - Sender.Canvas.TextHeight('Ag')) div 2;
  if (p <> nil) and (p.EnvironmentBadge <> '') then
    Sender.Canvas.TextOut(tr.Left + 2, ty, Node.Text + '  [' + p.EnvironmentBadge + ']')
  else
    Sender.Canvas.TextOut(tr.Left + 2, ty, Node.Text);
  Sender.Canvas.Brush.Style := bsSolid;
end;

procedure TProfileSidebar.TreeDblClick(Sender: TObject);
var
  ref: TSideRef;
begin
  ref := SelectedRef;
  if (ref <> nil) and (ref.Kind = snkProfile) and Assigned(FOnActivateProfile) then
    FOnActivateProfile(Self);
end;

procedure TProfileSidebar.SearchChanged(Sender: TObject);
begin
  if Assigned(FOnFilterChanged) then FOnFilterChanged(Self);
end;

procedure TProfileSidebar.LockPanelClick(Sender: TObject);
begin
  if Assigned(FOnLockPanelClick) then FOnLockPanelClick(Self);
end;

function TProfileSidebar.SelectedRef: TSideRef;
begin
  Result := nil;
  if (FTree.Selected <> nil) and (FTree.Selected.Data <> nil) then
    Result := TSideRef(FTree.Selected.Data);
end;

function TProfileSidebar.SelectedText: string;
begin
  if FTree.Selected <> nil then Result := FTree.Selected.Text else Result := '';
end;

procedure TProfileSidebar.InvalidateTree;
begin
  FTree.Invalidate;
end;

end.
