// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uMainForm;

{$mode objfpc}{$H+}

// Fenetre principale, construite par code: document .rtt chiffre, profils dans le panneau lateral,
// onglets, journal expurge et barre de statut. Le reseau ne parle a l'interface que par la boite de
// reception, et c'est tres bien comme ca.

interface

uses
  Classes, SysUtils, Forms, Controls, Menus, ComCtrls, ExtCtrls, Graphics,
  Dialogs, LCLType, LMessages, uAppContext, uConnections, uRtDocument, uConnectionProfile,
  uUiInbox, uDirectoryTab, uTabBar, uSearchModel,
  uLdapEntry, uStrings, uProfileCatalog, uProfileSidebar, uRtList
  {$IFNDEF DARWIN}, uMenuBar{$ENDIF}, uDocumentSave;

type
  TMainForm = class(TForm)
  private
    FCtx: TAppContext;
    FMenu: TMainMenu;
    {$IFNDEF DARWIN}
    FMenuBar: TRSMenuBar;
    {$ENDIF}
    FLeft: TPanel;
    FSidebar: TProfileSidebar;
    FTreeMenu: TPopupMenu;
    FSplitLeft, FSplitBottom: TSplitter;
    FRight: TPanel;
    FTabBar: TSessionTabBar;
    FPages: TPageControl;
    FWelcome: TPanel;
    // Journal en liste dessinee: le TListView de Cocoa ignore les couleurs, avec une constance admirable.
    FMessages: TRtListGrid;
    FLogRows: array of array[0..3] of string;
    FStatus: TStatusBar;
    FTimer: TTimer;
    FImages16: TImageList;
    FCatalog: TProfileCatalog;
    FDocLocked: Boolean;
    FLockedPath: string;
    FLockSave: TDocumentSaveThread;
    FLockSaveTask: Int64;
    FPendingSaves: array of Int64;
    FUnlockPending: Boolean;
    FLockPending: Boolean;
    FMiSave, FMiSaveAs, FMiClose, FMiChangePw, FMiRecent: TMenuItem;
    FMiTheme: TMenuItem;
    FMiNewProfile, FMiEditProfile, FMiConnect, FMiDisconnect: TMenuItem;
    FLdifPaths, FLdifUuids: TStringList;
    FMiSaveLdif, FMiSaveLdifAs, FMiLdifSchemaFiles, FMiLdifSchemaFrom: TMenuItem;
    FLdifSaveTask: Int64;
    FLdifSaveDone, FLdifSaveOk: Boolean;
    procedure BuildMenu;
    procedure BuildUi;
    function AddItem(AParent: TMenuItem; const ACaption: string; AShortCut: TShortCut;
      AHandler: TNotifyEvent): TMenuItem;
    procedure ApplyThemeToShell;
    procedure TimerTick(Sender: TObject);
    procedure HandleMessage(AMsg: TUiMessage);
    function AskSecretFor(AProfile: TConnectionProfile; out ASecret: RawByteString): Boolean;
    procedure Log(ALevel: TMessageLevel; const ASource, AText: string);
    procedure StatusChanged(Sender: TObject);
    procedure UpdateStatus;
    procedure UpdateDocumentState;
    procedure ClearProfiles;
    procedure LoadProfilesFromDocument;
    procedure RebuildTree;
    function SelectedRef: TSideRef;
    function ProfileLinkState(const AUuid: string): TProfileLinkState;
    procedure SidebarFilterChanged(Sender: TObject);
    procedure SidebarMoveItems(const AItems: TSideItems; const AFolderUuid: string);
    function ProfileByUuid(const AUuid: string): TConnectionProfile;
    function ActiveDirectoryTab: TDirectoryTab;
    function TabForProfile(const AUuid: string): TDirectoryTab;
    procedure TreePopup(Sender: TObject);
    procedure TabBarInfo(APage: TTabSheet; out AName: string; out AGlyph: TTabGlyphKind);
    procedure TabBarActivate(APage: TTabSheet);
    procedure TabBarClose(APage: TTabSheet);
    procedure PagesChange(Sender: TObject);
    procedure StatusDrawPanel(AStatusBar: TStatusBar; APanel: TStatusPanel; const ARect: TRect);
    function MessageCell(Sender: TObject; AIndex, ACol: Integer): string;
    procedure FormCloseQueryHandler(Sender: TObject; var CanClose: Boolean);
    function EnsureDocumentSaved: Boolean;
    function ConfirmClosePages: Boolean;
    procedure ApplySensitivePrefs;
    procedure OpenDocumentFile(const APath: string);
    function LockDocument: Boolean;
    procedure HandleDocSave(AMsg: TDocSaveMsg);
    procedure ReportSaveWarnings(APreviousStale, ADurabilityUnconfirmed: Boolean);
    procedure TrackSave(ATaskId: Int64);
    procedure ForgetSave(ATaskId: Int64);
    function SavesInFlight: Integer;
    procedure DrainInboxBounded;
    procedure OpenSearchTab(ATab: TDirectoryTab; const ABaseDn, AFilter: string; AScope: Integer;
      ARun: Boolean = False);
    procedure DirectoryOpenSearch(ATab: TDirectoryTab; const ABaseDn, AFilter: string;
      AScope: TSearchScope; ARun: Boolean);
    procedure DirectoryPasswordTools(ATab: TDirectoryTab; AEntry: TLdapEntry);
    procedure SearchOpenEntry(const AProfileUuid, ADn: string);
    procedure EntryPasswordTools(ATab: TObject; AEntry: TLdapEntry);
    procedure RunPasswordTools(c: TDirectoryConnection; AEntry: TLdapEntry);
    procedure RereadEntryViews(const AProfileUuid, ADn: string);
    function PageProfileUuid(APage: TTabSheet): string;
    function PageConfirmDiscard(APage: TTabSheet): Boolean;
    procedure DirectoryExportEntry(ATab: TDirectoryTab; AEntry: TLdapEntry);
    procedure NewDocClick(Sender: TObject);
    procedure OpenDocClick(Sender: TObject);
    procedure SaveDocClick(Sender: TObject);
    procedure SaveAsDocClick(Sender: TObject);
    procedure CloseDocClick(Sender: TObject);
    procedure LockDocClick(Sender: TObject);
    procedure ChangePasswordClick(Sender: TObject);
    procedure RecentMenuClick(Sender: TObject);
    procedure RecentItemClick(Sender: TObject);
    procedure ExitClick(Sender: TObject);
    procedure NewProfileClick(Sender: TObject);
    procedure EditProfileClick(Sender: TObject);
    procedure DuplicateProfileClick(Sender: TObject);
    procedure DeleteProfileClick(Sender: TObject);
    procedure NewFolderClick(Sender: TObject);
    procedure RenameFolderClick(Sender: TObject);
    procedure DeleteFolderClick(Sender: TObject);
    procedure ConnectClick(Sender: TObject);
    procedure DisconnectClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure FocusDnClick(Sender: TObject);
    procedure DeleteEntryClick(Sender: TObject);
    procedure ThemeClick(Sender: TObject);
    procedure ToggleSidebarClick(Sender: TObject);
    procedure ToggleMessagesClick(Sender: TObject);
    procedure ToggleOperationalClick(Sender: TObject);
    procedure LdifEditorClick(Sender: TObject);
    procedure OpenLdifClick(Sender: TObject);
    procedure SaveLdifClick(Sender: TObject);
    procedure SaveLdifAsClick(Sender: TObject);
    procedure LdifSchemaFilesClick(Sender: TObject);
    procedure LdifSchemaFromClick(Sender: TObject);
    procedure LdifModified(Sender: TObject);
    function ActiveLdifConnection: TDirectoryConnection;
    procedure UpdateLdifMenus;
    function SaveLdifTo(AConn: TDirectoryConnection; const APath: string): Boolean;
    function ConfirmLdifClose(AConn: TDirectoryConnection): Boolean;
    function NewDirectoryTab(AConn: TDirectoryConnection): TDirectoryTab;
    procedure SearchTabClick(Sender: TObject);
    procedure CompareNewClick(Sender: TObject);
    procedure PasswordToolClick(Sender: TObject);
    procedure CertificateClick(Sender: TObject);
    procedure SchemaClick(Sender: TObject);
    procedure EscapeToolClick(Sender: TObject);
    procedure ExportProfilesClick(Sender: TObject);
    procedure ImportProfilesClick(Sender: TObject);
    procedure MonitorClick(Sender: TObject);
    procedure AdDomainClick(Sender: TObject);
    procedure RootDseClick(Sender: TObject);
    procedure PreferencesClick(Sender: TObject);
    procedure AboutClick(Sender: TObject);
    procedure LicensesClick(Sender: TObject);
  protected
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function IsShortcut(var Message: TLMKey): Boolean; override;
    procedure OpenLdifFile(const APath: string);
    property Ctx: TAppContext read FCtx;
  end;

var
  MainForm: TMainForm;

implementation

uses
  uTheme, uThemeLoad, uUiKit, uIcons, uPreferences, uDocDialogs, uProfileDialog,
  uDocumentCrypto, uSessionModel, uLdapErrors, uVersion, uCancel,
  uSearchTab, uLdifTab, uPasswordDialog, uCertDialog, uSchemaDialog, uToolsDialogs,
  uAboutDialog, uCompareTab, uRtBytes, uExportActions, uLdifExportDialog, uPasswordWork, uConnectFlow, uEntryTab,
  uDirectoryService, uMonitorTab, uAdToolsDialog, uProfileExchangeDialog, uServerKind,
  uOwnedThread, uRtMessage, uSchemaFiles, uLdapSchema, uPickDialog;

type
  // Application.QueueAsyncCall exige une methode d'objet, d'ou cette classe. Jamais liberee avant la fin
  // du processus: un fil qui a lu le reveil juste avant sa remise a nil ne doit pas viser de la memoire
  // liberee. Quelques octets de fuite contre un crash a la fermeture, marche conclu.
  TInboxWaker = class
    procedure Drain(AData: PtrInt);
  end;

var
  GWaker: TInboxWaker = nil;
  GDrainQueued: LongInt = 0;

procedure TInboxWaker.Drain(AData: PtrInt);
begin
  InterLockedExchange(GDrainQueued, 0);
  UiInbox.Drain(400);
end;

procedure WakeInboxDrain;
begin
  if InterLockedExchange(GDrainQueued, 1) <> 0 then Exit;
  try
    Application.QueueAsyncCall(@GWaker.Drain, 0);
  except
    InterLockedExchange(GDrainQueued, 0);
  end;
end;

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := RT_APP_NAME;
  KeyPreview := True;
  FCtx := TAppContext.Create;
  FCtx.OnLog := @Log;
  FCtx.OnStatusChanged := @StatusChanged;
  FCtx.OnLdifModified := @LdifModified;
  FCatalog := TProfileCatalog.Create;
  FLdifPaths := TStringList.Create;
  FLdifUuids := TStringList.Create;
  Width := PrefWindowWidth;
  Height := PrefWindowHeight;
  if (PrefWindowLeft >= 0) and (PrefWindowTop >= 0) then
  begin
    Position := poDesigned;
    Left := PrefWindowLeft;
    Top := PrefWindowTop;
  end
  else
    Position := poScreenCenter;
  if PrefWindowMaximized then
    WindowState := wsMaximized;
  FImages16 := BuildIconList(Self, IconPixelSize(24, Screen.PixelsPerInch), IsDarkColor(clSideBg));
  BuildMenu;
  BuildUi;
  ApplyThemeToShell;
  ApplySensitivePrefs;
  OnCloseQuery := @FormCloseQueryHandler;
  UiInbox.Subscribe(Self, @HandleMessage);
  // Puits des orphelins: l'issue d'une ecriture partie survit a la vue qui l'a demandee, ou que la vue
  // a ecartee sans la solder (reponse d'une session remplacee).
  UiInbox.OnOrphanMessage := @FCtx.HandleOrphanMessage;
  UiInbox.OnDeliveredMessage := @FCtx.HandleDeliveredMessage;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 50;
  FTimer.OnTimer := @TimerTick;
  if GWaker = nil then GWaker := TInboxWaker.Create;
  UiInbox.OnWake := @WakeInboxDrain;
  UpdateDocumentState;
  Log(mlInfo, RT_APP_NAME, Format('%s %s started', [RT_APP_NAME, RT_VERSION]));
end;

destructor TMainForm.Destroy;
begin
  if FTimer <> nil then FTimer.Enabled := False;
  UiInbox.OnWake := nil;
  if GWaker <> nil then Application.RemoveAsyncCalls(GWaker);
  UiInbox.Unsubscribe(Self);
  FCtx.ShutdownDeadlineMs := MonotonicMs + 3000;
  PasswordWork.CancelAll;
  // Onglets fermes avant les connexions: plus aucun message ne doit leur arriver.
  while (FPages <> nil) and (FPages.PageCount > 0) do
    FPages.Pages[0].Free;
  FCtx.Connections.CloseAll(FCtx.ShutdownWaitMs(3000));
  PasswordWork.WaitAll(FCtx.ShutdownWaitMs(3000));
  if FLockSave <> nil then
  begin
    // Sauvegarde de verrouillage encore en cours: attente bornee, puis le fil finit seul. Le fichier est
    // ecrit par remplacement atomique, rien ne reste a moitie.
    FLockSave.Release(FCtx.ShutdownWaitMs(3000));
    FLockSave := nil;
  end;
  // Sauvegardes detachees par des verrous successifs: meme attente bornee, puis la finalisation de
  // uOwnedThread leur accorde une derniere echeance.
  JoinDetachedThreads(FCtx.ShutdownWaitMs(3000));
  // Messages deja deposes (issues tardives des fils fermes ci-dessus) passes au puits avant son
  // decrochage, jamais jetes en silence. Les issues inconnues pas encore consignees meurent avec le
  // processus, mais elles sont passees par le journal a l'ecran.
  DrainInboxBounded;
  UiInbox.OnOrphanMessage := nil;
  UiInbox.OnDeliveredMessage := nil;
  FCatalog.Free;
  FLdifPaths.Free;
  FLdifUuids.Free;
  FCtx.Document.Free;
  FCtx.Document := nil;
  FCtx.Journal.SetActiveDocument(nil);
  FCtx.Free;
  inherited Destroy;
end;

function TMainForm.AddItem(AParent: TMenuItem; const ACaption: string; AShortCut: TShortCut;
  AHandler: TNotifyEvent): TMenuItem;
begin
  Result := TMenuItem.Create(FMenu);
  Result.Caption := ACaption;
  Result.ShortCut := AShortCut;
  Result.OnClick := AHandler;
  AParent.Add(Result);
end;

function PShortCut(AKey: Word; AShift: Boolean = False): TShortCut;
begin
  {$IFDEF DARWIN}
  if AShift then Result := ShortCut(AKey, [ssMeta, ssShift]) else Result := ShortCut(AKey, [ssMeta]);
  {$ELSE}
  if AShift then Result := ShortCut(AKey, [ssCtrl, ssShift]) else Result := ShortCut(AKey, [ssCtrl]);
  {$ENDIF}
end;

procedure TMainForm.BuildMenu;
var
  m: TMenuItem;
  i: Integer;
  mi: TMenuItem;

  function Root(const ACaption: string): TMenuItem;
  begin
    Result := TMenuItem.Create(FMenu);
    Result.Caption := ACaption;
    FMenu.Items.Add(Result);
  end;

  procedure Sep(AParent: TMenuItem);
  begin
    AddItem(AParent, '-', 0, nil);
  end;

begin
  FMenu := TMainMenu.Create(Self);
  {$IFDEF DARWIN}
  Menu := FMenu;
  {$ELSE}
  // La LCL attribue d'office un TMainMenu possede par la fenetre: sans cette remise a nil, le menu natif
  // s'affiche en plus de la barre themee. Deux menus, et aucun de trop selon elle.
  Menu := nil;
  {$ENDIF}
  m := Root(rsMenuFile);
  AddItem(m, rsMenuNewDocument, PShortCut(VK_N), @NewDocClick);
  AddItem(m, rsMenuOpenDocument, PShortCut(VK_O), @OpenDocClick);
  FMiRecent := AddItem(m, rsMenuRecent, 0, nil);
  m.OnClick := @RecentMenuClick;
  FMiSave := AddItem(m, rsMenuSave, PShortCut(VK_S), @SaveDocClick);
  FMiSaveAs := AddItem(m, rsMenuSaveAs, PShortCut(VK_S, True), @SaveAsDocClick);
  Sep(m);
  AddItem(m, rsMenuOpenLdif, 0, @OpenLdifClick);
  FMiSaveLdif := AddItem(m, rsMenuSaveLdif, 0, @SaveLdifClick);
  FMiSaveLdifAs := AddItem(m, rsMenuSaveLdifAs, 0, @SaveLdifAsClick);
  AddItem(m, rsMenuImportLdif, 0, @LdifEditorClick);
  Sep(m);
  FMiChangePw := AddItem(m, rsMenuChangePassword, 0, @ChangePasswordClick);
  FMiClose := AddItem(m, rsMenuCloseDocument, 0, @CloseDocClick);
  Sep(m);
  AddItem(m, rsMenuExit, 0, @ExitClick);

  m := Root(rsMenuEdit);
  AddItem(m, rsMenuPreferences, 0, @PreferencesClick);

  m := Root(rsMenuView);
  FMiTheme := AddItem(m, rsMenuTheme, 0, nil);
  for i := 0 to ThemeCount - 1 do
  begin
    mi := AddItem(FMiTheme, ThemeName(i), 0, @ThemeClick);
    mi.Tag := i;
    mi.RadioItem := True;
    mi.GroupIndex := 7;
    mi.Checked := i = CurrentThemeIndex;
  end;
  Sep(m);
  AddItem(m, rsMenuToggleSidebar, 0, @ToggleSidebarClick);
  AddItem(m, rsMenuToggleMessages, 0, @ToggleMessagesClick);
  AddItem(m, rsMenuOperational, 0, @ToggleOperationalClick);
  Sep(m);
  AddItem(m, rsMenuRefresh, ShortCut(VK_F5, []), @RefreshClick);

  m := Root(rsMenuConnection);
  FMiNewProfile := AddItem(m, rsMenuNewProfile, PShortCut(VK_N, True), @NewProfileClick);
  FMiEditProfile := AddItem(m, rsMenuEditProfile, 0, @EditProfileClick);
  AddItem(m, rsMenuDuplicateProfile, 0, @DuplicateProfileClick);
  AddItem(m, rsMenuDeleteProfile, 0, @DeleteProfileClick);
  AddItem(m, rsMenuNewFolder, 0, @NewFolderClick);
  Sep(m);
  AddItem(m, rsMenuExportProfiles, 0, @ExportProfilesClick);
  AddItem(m, rsMenuImportProfiles, 0, @ImportProfilesClick);
  Sep(m);
  FMiConnect := AddItem(m, rsMenuConnect, PShortCut(VK_RETURN), @ConnectClick);
  FMiDisconnect := AddItem(m, rsMenuDisconnect, 0, @DisconnectClick);

  m := Root(rsMenuDirectory);
  AddItem(m, rsMenuFocusDn, PShortCut(VK_L), @FocusDnClick);
  AddItem(m, rsMenuSearch, PShortCut(VK_F), @SearchTabClick);
  AddItem(m, rsMenuDelete, 0, @DeleteEntryClick);
  Sep(m);
  AddItem(m, rsMenuSchema, 0, @SchemaClick);
  FMiLdifSchemaFiles := AddItem(m, rsMenuLdifSchemaFiles, 0, @LdifSchemaFilesClick);
  FMiLdifSchemaFrom := AddItem(m, rsMenuLdifSchemaFrom, 0, @LdifSchemaFromClick);
  AddItem(m, rsMenuPassword, 0, @PasswordToolClick);
  Sep(m);
  AddItem(m, rsMenuMonitor, 0, @MonitorClick);
  AddItem(m, rsMenuAdDomain, 0, @AdDomainClick);

  m := Root(rsMenuCompare);
  AddItem(m, rsMenuCompareNew, 0, @CompareNewClick);

  m := Root(rsMenuTools);
  AddItem(m, rsMenuLdifEditor, 0, @LdifEditorClick);
  AddItem(m, rsMenuEscape, 0, @EscapeToolClick);
  AddItem(m, rsMenuRootDse, 0, @RootDseClick);
  AddItem(m, rsMenuCertificates, 0, @CertificateClick);

  m := Root(rsMenuHelp);
  AddItem(m, rsMenuLicenses, 0, @LicensesClick);
  AddItem(m, Format(rsMenuAbout, [RT_APP_NAME]), 0, @AboutClick);
end;

procedure TMainForm.BuildUi;
var
  mi: TMenuItem;

  procedure PopupItem(const ACaption: string; AHandler: TNotifyEvent; ATag: Integer);
  begin
    mi := TMenuItem.Create(FTreeMenu);
    mi.Caption := ACaption;
    mi.OnClick := AHandler;
    mi.Tag := ATag;
    FTreeMenu.Items.Add(mi);
  end;

begin
  {$IFNDEF DARWIN}
  FMenuBar := TRSMenuBar.Create(Self);
  FMenuBar.Parent := Self;
  FMenuBar.Align := alTop;
  FMenuBar.Height := 26;
  FMenuBar.AdoptMainMenu(FMenu);
  {$ENDIF}

  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := False;
  with FStatus.Panels.Add do Width := 260;
  with FStatus.Panels.Add do Width := 240;
  with FStatus.Panels.Add do Width := 230;
  with FStatus.Panels.Add do Width := 110;
  with FStatus.Panels.Add do Width := 90;
  with FStatus.Panels.Add do Width := 200;
  {$IF DEFINED(WINDOWS) OR DEFINED(DARWIN) OR DEFINED(LCLGtk3)}
  // Panneaux dessines a la main: les couleurs du theme, sous Windows, macOS et GTK3, sont a ce prix.
  FStatus.OnDrawPanel := @StatusDrawPanel;
  FStatus.Panels[0].Style := psOwnerDraw;
  FStatus.Panels[1].Style := psOwnerDraw;
  FStatus.Panels[2].Style := psOwnerDraw;
  FStatus.Panels[3].Style := psOwnerDraw;
  FStatus.Panels[4].Style := psOwnerDraw;
  FStatus.Panels[5].Style := psOwnerDraw;
  {$ENDIF}

  FLeft := TPanel.Create(Self);
  FLeft.Parent := Self;
  FLeft.Align := alLeft;
  FLeft.Width := PrefSidebarWidth;
  FLeft.BevelOuter := bvNone;
  FLeft.Caption := '';

  FSidebar := TProfileSidebar.Create(Self);
  FSidebar.Parent := FLeft;
  FSidebar.Align := alClient;
  FSidebar.SetImages(FImages16);
  FSidebar.OnActivateProfile := @ConnectClick;
  FSidebar.OnFilterChanged := @SidebarFilterChanged;
  FSidebar.OnProfileState := @ProfileLinkState;
  FSidebar.OnLockPanelClick := @LockDocClick;
  FSidebar.OnMoveItems := @SidebarMoveItems;

  FTreeMenu := TPopupMenu.Create(Self);
  FTreeMenu.OnPopup := @TreePopup;
  PopupItem(rsMenuConnect, @ConnectClick, 1);
  PopupItem(rsMenuDisconnect, @DisconnectClick, 1);
  PopupItem('-', nil, 0);
  PopupItem(rsMenuEditProfile, @EditProfileClick, 1);
  PopupItem(rsMenuDuplicateProfile, @DuplicateProfileClick, 1);
  PopupItem(rsMenuDeleteProfile, @DeleteProfileClick, 1);
  PopupItem('-', nil, 0);
  PopupItem(rsMenuNewProfile, @NewProfileClick, 0);
  PopupItem(rsMenuNewFolder, @NewFolderClick, 0);
  PopupItem(rsMenuRenameFolder, @RenameFolderClick, 2);
  PopupItem(rsMenuDeleteFolder, @DeleteFolderClick, 2);
  FSidebar.TreeMenu := FTreeMenu;
  {$IFNDEF DARWIN}
  ThemePopupMenu(FTreeMenu);
  {$ENDIF}

  FSplitLeft := TSplitter.Create(Self);
  FSplitLeft.Parent := Self;
  FSplitLeft.Align := alLeft;
  FSplitLeft.Left := FLeft.Width + 1;

  FMessages := TRtListGrid.Create(Self);
  FMessages.Parent := Self;
  FMessages.Align := alBottom;
  FMessages.Height := PrefMessagesHeight;
  FMessages.Visible := PrefMessagesVisible;
  FMessages.ShowHeader := False;
  FMessages.AddColumn(rsColTime, 80);
  FMessages.AddColumn(rsColLevel, 70);
  FMessages.AddColumn(rsColSource, 160);
  FMessages.AddColumn(rsColMessage, 900);
  FMessages.StretchLastColumn := True;
  FMessages.OnGetCell := @MessageCell;

  FSplitBottom := TSplitter.Create(Self);
  FSplitBottom.Parent := Self;
  FSplitBottom.Align := alBottom;
  FSplitBottom.Top := FMessages.Top - 1;

  FRight := TPanel.Create(Self);
  FRight.Parent := Self;
  FRight.Align := alClient;
  FRight.BevelOuter := bvNone;
  FRight.Caption := '';

  FPages := TPageControl.Create(Self);
  FPages.Parent := FRight;
  FPages.Align := alClient;
  FPages.ShowTabs := False;
  FPages.OnChange := @PagesChange;
  HostWithoutBorder(FPages);

  FTabBar := TSessionTabBar.Create(Self);
  FTabBar.Parent := FRight;
  FTabBar.Align := alTop;
  FTabBar.Height := 34;
  FTabBar.Attach(FPages);
  FTabBar.OnInfo := @TabBarInfo;
  FTabBar.OnActivateTab := @TabBarActivate;
  FTabBar.OnCloseTab := @TabBarClose;

  FWelcome := TPanel.Create(Self);
  FWelcome.Parent := FRight;
  FWelcome.Align := alClient;
  FWelcome.BevelOuter := bvNone;
  FWelcome.Caption := rsWelcome;
  FLeft.Visible := PrefSidebarVisible;
  FSplitLeft.Visible := PrefSidebarVisible;
end;

procedure TMainForm.ApplyThemeToShell;
var
  i: Integer;
begin
  Color := clAppBg;
  Font.Color := clAppFg;
  if RSUiFontName <> '' then Font.Name := RSUiFontName;
  Font.Size := RSUiFontSize;
  ApplyGlobalFonts;
  ApplyNativeAppearance;
  FLeft.Color := clSideBg;
  FSidebar.ApplyTheme;
  FRight.Color := clAppBg;
  FWelcome.Color := clAppBg;
  FWelcome.Font.Color := clStatusText;
  FMessages.Color := clSideBg;
  FMessages.Font.Color := clSideText;
  FMessages.RowColor := clSideBg;
  FMessages.RowTextColor := clSideText;
  FMessages.Font.Size := RSUiFontSize;
  if RSUiFontName <> '' then FMessages.Font.Name := RSUiFontName;
  FMessages.RefreshMetrics;
  FWelcome.Font.Size := RSUiFontSize + 1;
  FStatus.Font.Size := RSUiFontSize;
  FStatus.Height := FontTextHeight(FStatus.Font) + 10;

  ThemeSplitter(FSplitLeft);
  ThemeSplitter(FSplitBottom);
  FStatus.Color := clStatusBg;
  FStatus.Font.Color := clStatusText;
  {$IFNDEF DARWIN}
  FMenuBar.RefreshTheme;
  {$ENDIF}
  FImages16.Free;
  FImages16 := BuildIconList(Self, IconPixelSize(24, Screen.PixelsPerInch), IsDarkColor(clSideBg));
  FSidebar.SetImages(FImages16);
  for i := 0 to FPages.PageCount - 1 do
    if FPages.Pages[i] is TDirectoryTab then
      TDirectoryTab(FPages.Pages[i]).ApplyTheme
    else if FPages.Pages[i] is TSearchTab then
      TSearchTab(FPages.Pages[i]).ApplyTheme
    else if FPages.Pages[i] is TEntryTab then
      TEntryTab(FPages.Pages[i]).ApplyTheme
    else if FPages.Pages[i] is TLdifTab then
      TLdifTab(FPages.Pages[i]).ApplyTheme
    else if FPages.Pages[i] is TCompareTab then
      TCompareTab(FPages.Pages[i]).ApplyTheme
    else if FPages.Pages[i] is TMonitorTab then
      TMonitorTab(FPages.Pages[i]).ApplyTheme;
  FTabBar.Invalidate;
  FSidebar.InvalidateTree;
  Invalidate;
end;

procedure TMainForm.StatusDrawPanel(AStatusBar: TStatusBar; APanel: TStatusPanel;
  const ARect: TRect);
var
  ty: Integer;
begin
  with AStatusBar.Canvas do
  begin
    Brush.Color := clStatusBg;
    Brush.Style := bsSolid;
    FillRect(ARect);
    Font.Assign(AStatusBar.Font);
    Font.Color := clStatusText;
    // Un avertissement de securite reste visible dans la barre, meme quand il derange.
    if (APanel.Index = 2) and ((Pos('unencrypted', APanel.Text) > 0) or
       (Pos('not verified', APanel.Text) > 0)) then
      Font.Color := clTabDead;
    if (APanel.Index = 0) and (Pos('[', APanel.Text) = 1) then
      Font.Color := clAccent;
    ty := ARect.Top + (ARect.Bottom - ARect.Top - TextHeight('Ag')) div 2;
    TextRect(ARect, ARect.Left + 4, ty, APanel.Text);
  end;
end;

procedure TMainForm.TimerTick(Sender: TObject);
begin
  UiInbox.Drain(400);
  // Verrouillage demande pendant un dialogue modal: repris quand les dialogues sont fermes. Pas de
  // verrouillage sur inactivite: quitter ou verrouiller le poste reste le choix de l'utilisateur.
  if FLockPending then
    LockDocument;
end;

procedure TMainForm.Log(ALevel: TMessageLevel; const ASource, AText: string);
var
  n: Integer;
begin
  if FMessages = nil then Exit;
  if Length(FLogRows) >= 1000 then
    Delete(FLogRows, 0, Length(FLogRows) - 999);
  n := Length(FLogRows);
  SetLength(FLogRows, n + 1);
  FLogRows[n][0] := FormatDateTime('hh:nn:ss', Now);
  case ALevel of
    mlInfo: FLogRows[n][1] := 'info';
    mlWarning: FLogRows[n][1] := 'warning';
  else
    FLogRows[n][1] := 'error';
  end;
  FLogRows[n][2] := ASource;
  // Une ligne, un message: personne ne forge de fausse entree de journal a coups de retours a la ligne.
  FLogRows[n][3] := StringReplace(StringReplace(AText, #13, ' ', [rfReplaceAll]), #10, ' ',
    [rfReplaceAll]);
  FMessages.Count := Length(FLogRows);
end;

function TMainForm.MessageCell(Sender: TObject; AIndex, ACol: Integer): string;
begin
  Result := '';
  if (AIndex < 0) or (AIndex >= Length(FLogRows)) or (ACol < 0) or (ACol > 3) then Exit;
  Result := FLogRows[High(FLogRows) - AIndex][ACol];
end;

procedure TMainForm.StatusChanged(Sender: TObject);
begin
  UpdateStatus;
end;

procedure TMainForm.UpdateStatus;
var
  tab: TDirectoryTab;
  c: TDirectoryConnection;
  ident: string;
begin
  tab := ActiveDirectoryTab;
  c := nil;
  if tab <> nil then c := FCtx.Connections.Find(tab.ProfileUuid);
  if c = nil then
  begin
    FStatus.Panels[0].Text := '';
    FStatus.Panels[1].Text := '';
    FStatus.Panels[2].Text := '';
    FStatus.Panels[3].Text := '';
    FStatus.Panels[4].Text := '';
  end
  else
  begin
    ident := c.Transport.AuthzId;
    if ident = '' then ident := c.Transport.BoundIdentity;
    if c.Transport.Anonymous then ident := rsAnonymous;
    if c.Profile.EnvironmentBadge <> '' then
      ident := '[' + c.Profile.EnvironmentBadge + '] ' + ident;
    FStatus.Panels[0].Text := ident;
    FStatus.Panels[1].Text := c.Profile.DisplayEndpoint;
    // Le statut "securise" vient du transport reel, pas de la case cochee dans le profil. Les cases mentent.
    FStatus.Panels[2].Text := c.Transport.StatusLabel;
    FStatus.Panels[3].Text := c.DisplayState;
    if c.IsReady then
      FStatus.Panels[4].Text := IntToStr((MonotonicMs - c.ConnectedAtMs) div 1000) + ' s'
    else
      FStatus.Panels[4].Text := '';
  end;
  if FCtx.Document = nil then
    FStatus.Panels[5].Text := rsNoDocument
  else if FDocLocked then
    FStatus.Panels[5].Text := rsDocumentLockedShort
  else if FCtx.Document.Modified then
    FStatus.Panels[5].Text := ExtractFileName(FCtx.Document.Path) + ' *'
  else
    FStatus.Panels[5].Text := ExtractFileName(FCtx.Document.Path);
  UpdateLdifMenus;
end;

procedure TMainForm.UpdateDocumentState;
var
  hasDoc: Boolean;
begin
  hasDoc := (FCtx.Document <> nil) and not FDocLocked;
  FMiSave.Enabled := hasDoc;
  FMiSaveAs.Enabled := hasDoc;
  FMiClose.Enabled := (FCtx.Document <> nil) or FDocLocked;
  FMiChangePw.Enabled := hasDoc;
  FSidebar.SetState(FCtx.Document <> nil, FDocLocked);
  if FCtx.Document <> nil then
    Caption := ExtractFileName(FCtx.Document.Path) + ' - ' + RT_APP_NAME
  else
    Caption := RT_APP_NAME;
  FWelcome.Visible := FPages.PageCount = 0;
  // Onglet ajoute ou active par code: la barre n'en sait rien sinon.
  FTabBar.RefreshBar;
  if FDocLocked then
    FWelcome.Caption := rsWelcomeLocked
  else if FCtx.Document = nil then
    FWelcome.Caption := rsWelcome
  else if FCatalog.Count = 0 then
    FWelcome.Caption := rsWelcomeNoProfile
  else
    FWelcome.Caption := rsWelcomeConnect;
  UpdateStatus;
end;

procedure TMainForm.ClearProfiles;
begin
  FCatalog.Clear;
end;

procedure TMainForm.LoadProfilesFromDocument;
begin
  FCatalog.LoadFrom(FCtx.Document);
end;

procedure TMainForm.RebuildTree;
begin
  FSidebar.Rebuild(FCtx.Document, FCatalog, FDocLocked);
  UpdateDocumentState;
end;

function TMainForm.ProfileLinkState(const AUuid: string): TProfileLinkState;
var
  c: TDirectoryConnection;
begin
  c := FCtx.Connections.Find(AUuid);
  if c = nil then
    Result := plsNone
  else if c.IsReady then
    Result := plsReady
  else if c.State = csFailed then
    Result := plsFailed
  else
    Result := plsBusy;
end;

procedure TMainForm.SidebarFilterChanged(Sender: TObject);
begin
  RebuildTree;
end;

procedure TMainForm.SidebarMoveItems(const AItems: TSideItems; const AFolderUuid: string);
var
  folders, profiles: array of string;
  i: Integer;
begin
  if (FCtx.Document = nil) or FDocLocked or (Length(AItems) = 0) then Exit;
  folders := nil;
  profiles := nil;
  for i := 0 to High(AItems) do
    if AItems[i].Kind = snkFolder then
    begin
      SetLength(folders, Length(folders) + 1);
      folders[High(folders)] := AItems[i].Uuid;
    end
    else
    begin
      SetLength(profiles, Length(profiles) + 1);
      profiles[High(profiles)] := AItems[i].Uuid;
    end;
  try
    FCtx.Document.MoveItems(folders, profiles, AFolderUuid);
  except
    on E: EDocumentError do
    begin
      RtMessageDlg(RT_APP_NAME, E.Message, mtError, [mbOK], 0);
      Exit;
    end;
  end;
  LoadProfilesFromDocument;
  RebuildTree;
  FSidebar.SelectItems(AItems);
end;

function TMainForm.SelectedRef: TSideRef;
begin
  Result := FSidebar.SelectedRef;
end;

function TMainForm.ProfileByUuid(const AUuid: string): TConnectionProfile;
begin
  Result := FCatalog.Find(AUuid);
end;

procedure TMainForm.TreePopup(Sender: TObject);
var
  ref: TSideRef;
  i: Integer;
begin
  ref := SelectedRef;
  for i := 0 to FTreeMenu.Items.Count - 1 do
    case FTreeMenu.Items[i].Tag of
      1: FTreeMenu.Items[i].Visible := (ref <> nil) and (ref.Kind = snkProfile);
      2: FTreeMenu.Items[i].Visible := (ref <> nil) and (ref.Kind = snkFolder);
      0: FTreeMenu.Items[i].Enabled := (FCtx.Document <> nil) and not FDocLocked;
    end;
end;

function TMainForm.ActiveDirectoryTab: TDirectoryTab;
begin
  Result := nil;
  if (FPages.ActivePage <> nil) and (FPages.ActivePage is TDirectoryTab) then
    Result := TDirectoryTab(FPages.ActivePage);
end;

function TMainForm.TabForProfile(const AUuid: string): TDirectoryTab;
var
  i: Integer;
begin
  for i := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[i] is TDirectoryTab) and (TDirectoryTab(FPages.Pages[i]).ProfileUuid = AUuid) then
      Exit(TDirectoryTab(FPages.Pages[i]));
  Result := nil;
end;

procedure TMainForm.TabBarInfo(APage: TTabSheet; out AName: string; out AGlyph: TTabGlyphKind);
var
  c: TDirectoryConnection;
begin
  AName := APage.Caption;
  AGlyph := tgkNone;
  if APage is TDirectoryTab then
  begin
    c := FCtx.Connections.Find(TDirectoryTab(APage).ProfileUuid);
    if (c <> nil) and (c.Profile.LdifPath <> '') and c.LdifModified then
      AName := AName + ' *';
  end;
  if PageProfileUuid(APage) <> '' then
  begin
    c := FCtx.Connections.Find(PageProfileUuid(APage));
    if c = nil then
      AGlyph := tgkDead
    else
      case c.State of
        csReady: AGlyph := tgkConnected;
        csFailed: AGlyph := tgkFailed;
        csDisconnected, csCancelled: AGlyph := tgkDead;
      else
        AGlyph := tgkBusy;
      end;
  end;
end;

procedure TMainForm.TabBarActivate(APage: TTabSheet);
begin
  FPages.ActivePage := APage;
  UpdateStatus;
end;

procedure TMainForm.TabBarClose(APage: TTabSheet);
var
  uuid: string;
begin
  uuid := '';
  if not PageConfirmDiscard(APage) then Exit;
  if APage is TDirectoryTab then
    uuid := TDirectoryTab(APage).ProfileUuid;
  APage.Free;
  if (uuid <> '') and (TabForProfile(uuid) = nil) then
    FCtx.Connections.Close(uuid);
  FTabBar.Invalidate;
  FSidebar.InvalidateTree;
  UpdateDocumentState;
end;

procedure TMainForm.PagesChange(Sender: TObject);
begin
  UpdateStatus;
  FTabBar.Invalidate;
end;

function TMainForm.ActiveLdifConnection: TDirectoryConnection;
begin
  Result := nil;
  if FPages.ActivePage = nil then Exit;
  Result := FCtx.Connections.Find(PageProfileUuid(FPages.ActivePage));
  if (Result <> nil) and (Result.Profile.LdifPath = '') then Result := nil;
end;

procedure TMainForm.UpdateLdifMenus;
var
  c: TDirectoryConnection;
  ready: Boolean;
begin
  if FMiSaveLdif = nil then Exit;
  c := ActiveLdifConnection;
  ready := (c <> nil) and c.IsReady;
  FMiSaveLdif.Enabled := ready;
  FMiSaveLdifAs.Enabled := ready;
  FMiLdifSchemaFiles.Enabled := ready;
  FMiLdifSchemaFrom.Enabled := ready;
end;

procedure TMainForm.LdifModified(Sender: TObject);
begin
  FTabBar.Invalidate;
  UpdateLdifMenus;
end;

procedure TMainForm.HandleMessage(AMsg: TUiMessage);
var
  ev: TConnectionEvent;
  c: TDirectoryConnection;
  tab: TDirectoryTab;
  i: Integer;
begin
  if AMsg is TDocSaveMsg then
  begin
    HandleDocSave(TDocSaveMsg(AMsg));
    Exit;
  end;
  if not FCtx.Connections.ApplyMessage(AMsg, Self, FCtx.Sensitive, ev) then Exit;
  c := ev.Connection;
  case ev.Kind of
    cekStepFailed:
      Log(mlWarning, c.Profile.Name, ConnectStepName(ev.Step.Step) + ': ' + ev.Step.Detail);
    cekConnected:
      begin
        if c.Profile.LdifPath <> '' then
        begin
          Log(mlInfo, c.Profile.Name, ev.Summary);
          for i := 0 to High(ev.Warnings) do
            Log(mlWarning, c.Profile.Name, ev.Warnings[i]);
        end
        else
        begin
          Log(mlInfo, c.Profile.Name, Format(rsConnectedTo, [c.Profile.DisplayEndpoint,
            c.Transport.StatusLabel]));
          if not c.Transport.Encrypted then
            Log(mlWarning, c.Profile.Name, rsPlainWarningStatus);
        end;
        tab := TabForProfile(c.Profile.Uuid);
        if tab <> nil then tab.ConnectionReady;
      end;
    cekConnectFailed:
      if c.Profile.LdifPath <> '' then
      begin
        Log(mlError, c.Profile.Name, Format(rsLdifOpenFailed, [c.Profile.LdifPath,
          ev.Error.Diagnostic]));
        RtMessageDlg(RT_APP_NAME, Format(rsLdifOpenFailed, [c.Profile.LdifPath,
          ev.Error.Diagnostic]), mtError, [mbOK], 0);
      end
      else
        Log(mlError, c.Profile.Name, ErrorToText(ev.Error) + ' ' + ev.Error.Action);
    cekLdifSaved:
      begin
        Log(mlInfo, c.Profile.Name, ev.Summary);
        for i := 0 to FLdifUuids.Count - 1 do
          if FLdifUuids[i] = c.Profile.Uuid then
            FLdifPaths[i] := c.Profile.LdifPath;
        for i := 0 to FPages.PageCount - 1 do
          if (FPages.Pages[i] is TDirectoryTab) and
             (TDirectoryTab(FPages.Pages[i]).ProfileUuid = c.Profile.Uuid) then
            FPages.Pages[i].Caption := c.Profile.Name;
        if AMsg.TaskId = FLdifSaveTask then
        begin
          FLdifSaveDone := True;
          FLdifSaveOk := True;
        end;
      end;
    cekLdifSaveFailed:
      begin
        Log(mlError, c.Profile.Name, Format(rsLdifSaveFailed, [c.Profile.Name,
          ErrorToText(ev.Error)]));
        if AMsg.TaskId = FLdifSaveTask then
        begin
          FLdifSaveDone := True;
          FLdifSaveOk := False;
        end
        else
          RtMessageDlg(RT_APP_NAME, Format(rsLdifSaveFailed, [c.Profile.Name,
            ErrorToText(ev.Error)]), mtError, [mbOK], 0);
      end;
    cekSchema:
      Log(mlInfo, c.Profile.Name, Format(rsSchemaLoaded, [c.Schema.AttributeTypeCount,
        c.Schema.ObjectClassCount]));
    cekSchemaFailed:
      if c.Schema = nil then
        Log(mlWarning, c.Profile.Name, c.SchemaReason)
      else
        Log(mlWarning, c.Profile.Name, Format(rsSchemaKeptStale, [c.SchemaReason]));
  end;
  if ev.Kind in [cekConnected, cekConnectFailed, cekLdifSaved, cekLdifSaveFailed] then
  begin
    FTabBar.Invalidate;
    FSidebar.InvalidateTree;
    UpdateStatus;
  end;
end;

function TMainForm.AskSecretFor(AProfile: TConnectionProfile; out ASecret: RawByteString): Boolean;
var
  remember: Boolean;
begin
  Result := AskBindSecret(Self, AProfile.DisplayEndpoint, AProfile.EnvironmentBadge,
    EffectiveBindDn(AProfile), False, ASecret, remember);
end;

function TMainForm.IsShortcut(var Message: TLMKey): Boolean;
begin
  {$IFNDEF DARWIN}
  // La LCL n'interroge pas les popups adoptes par la barre: leurs raccourcis passent par ici.
  if (FMenuBar <> nil) and FMenuBar.DispatchShortcut(Message) then
    Exit(True);
  {$ENDIF}
  Result := inherited IsShortcut(Message);
end;

function TMainForm.ConfirmClosePages: Boolean;
var
  i: Integer;
begin
  // Les modifications d'attributs non appliquees ne marquent pas le document: chaque onglet d'annuaire
  // est consulte avant toute fermeture.
  for i := 0 to FPages.PageCount - 1 do
    if not PageConfirmDiscard(FPages.Pages[i]) then Exit(False);
  Result := True;
end;

function TMainForm.PageProfileUuid(APage: TTabSheet): string;
begin
  if APage is TDirectoryTab then
    Result := TDirectoryTab(APage).ProfileUuid
  else if APage is TEntryTab then
    Result := TEntryTab(APage).ProfileUuid
  else if APage is TMonitorTab then
    Result := TMonitorTab(APage).ProfileUuid
  else
    Result := '';
end;

function TMainForm.PageConfirmDiscard(APage: TTabSheet): Boolean;
var
  c: TDirectoryConnection;
  i: Integer;
  others: Boolean;
begin
  if APage is TDirectoryTab then
  begin
    Result := TDirectoryTab(APage).ConfirmDiscardEdits;
    if not Result then Exit;
    c := FCtx.Connections.Find(TDirectoryTab(APage).ProfileUuid);
    if (c = nil) or (c.Profile.LdifPath = '') or not c.LdifModified then Exit;
    others := False;
    for i := 0 to FPages.PageCount - 1 do
      if (FPages.Pages[i] <> APage) and (FPages.Pages[i] is TDirectoryTab) and
         (TDirectoryTab(FPages.Pages[i]).ProfileUuid = c.Profile.Uuid) then
        others := True;
    if not others then
      Result := ConfirmLdifClose(c);
  end
  else if APage is TEntryTab then
    Result := TEntryTab(APage).ConfirmDiscardEdits
  else
    Result := True;
end;

procedure TMainForm.ApplySensitivePrefs;
var
  parts: TStringArray;
  i: Integer;
  extra: array of string;
begin
  extra := nil;
  parts := PrefExtraSensitiveAttrs.Split([',', ';', ' ']);
  for i := 0 to High(parts) do
    if Trim(parts[i]) <> '' then
    begin
      SetLength(extra, Length(extra) + 1);
      extra[High(extra)] := Trim(parts[i]);
    end;
  FCtx.Sensitive.SetExtra(extra);
  FCtx.Connections.ApplySensitiveExtra(extra);
end;

function TMainForm.EnsureDocumentSaved: Boolean;
var
  r: Integer;
begin
  Result := True;
  if not ConfirmClosePages then Exit(False);
  if (FCtx.Document = nil) or FDocLocked or not FCtx.Document.Modified then Exit;
  r := RtQuestionDlg(RT_APP_NAME, rsSaveChangesQuestion, mtConfirmation,
    [mrYes, rsSave, mrNo, rsDiscard, mrCancel, rsCancel], 0);
  case r of
    mrYes:
      begin
        SaveDocClick(nil);
        Result := not FCtx.Document.Modified;
      end;
    mrNo: Result := True;
  else
    Result := False;
  end;
end;

procedure TMainForm.NewDocClick(Sender: TObject);
var
  pw: RawByteString;
  sd: TSaveDialog;
  doc: TRtDocument;
begin
  if not EnsureDocumentSaved then Exit;
  sd := TSaveDialog.Create(Self);
  try
    sd.Filter := rsDocFilter;
    sd.DefaultExt := 'rtt';
    sd.Options := sd.Options + [ofOverwritePrompt];
    if not sd.Execute then Exit;
    if not AskNewDocumentPassword(Self, sd.FileName, False, pw) then Exit;
    try
      Screen.Cursor := crHourGlass;
      try
        doc := TRtDocument.NewDocument(pw);
      finally
        Screen.Cursor := crDefault;
      end;
      try
        doc.SaveAs(sd.FileName);
      except
        doc.Free;
        raise;
      end;
      ReportSaveWarnings(doc.PreviousCopyStale, doc.DurabilityUnconfirmed);
    finally
      WipeString(pw);
    end;
    FCtx.Connections.CloseAll;
    while FPages.PageCount > 0 do FPages.Pages[0].Free;
    FCtx.Document.Free;
    FCtx.Document := doc;
    FCtx.Journal.SetActiveDocument(doc);
    FDocLocked := False;
    // Nouveau document: aucun deverrouillage differe ne doit lui survivre.
    FUnlockPending := False;
    AddRecentDocument(sd.FileName);
    LoadProfilesFromDocument;
    RebuildTree;
    UpdateDocumentState;
    Log(mlInfo, RT_APP_NAME, Format(rsDocumentCreated, [sd.FileName]));
  finally
    sd.Free;
  end;
end;

procedure TMainForm.OpenDocumentFile(const APath: string);
var
  pw: RawByteString;
  st: TDocOpenStatus;
  doc: TRtDocument;
begin
  if not AskDocumentPassword(Self, APath, FDocLocked, pw) then Exit;
  try
    Screen.Cursor := crHourGlass;
    try
      doc := TRtDocument.Open(APath, pw, st);
    finally
      Screen.Cursor := crDefault;
    end;
  finally
    WipeString(pw);
  end;
  if doc = nil then
  begin
    RtMessageDlg(RT_APP_NAME, DocOpenStatusText(st), mtError, [mbOK], 0);
    Exit;
  end;
  FCtx.Document.Free;
  FCtx.Document := doc;
  // Journal aligne sur le document ouvert: les issues inconnues retenues pour ce chemin y sont
  // consignees maintenant.
  FCtx.Journal.SetActiveDocument(doc);
  FDocLocked := False;
  FLockedPath := '';
  FUnlockPending := False;
  AddRecentDocument(APath);
  if doc.MigratedFromVersion > 0 then
    Log(mlInfo, RT_APP_NAME, Format(rsDocumentMigrated, [doc.MigratedFromVersion]));
  LoadProfilesFromDocument;
  RebuildTree;
  UpdateDocumentState;
end;

procedure TMainForm.OpenDocClick(Sender: TObject);
var
  od: TOpenDialog;
begin
  if not EnsureDocumentSaved then Exit;
  od := TOpenDialog.Create(Self);
  try
    od.Filter := rsDocFilter;
    if not od.Execute then Exit;
    FCtx.Connections.CloseAll;
    while FPages.PageCount > 0 do FPages.Pages[0].Free;
    OpenDocumentFile(od.FileName);
  finally
    od.Free;
  end;
end;

procedure TMainForm.RecentMenuClick(Sender: TObject);
var
  i: Integer;
  mi: TMenuItem;
begin
  FMiRecent.Clear;
  if PrefRecentDocuments = nil then Exit;
  for i := 0 to PrefRecentDocuments.Count - 1 do
  begin
    mi := TMenuItem.Create(FMiRecent);
    mi.Caption := PrefRecentDocuments[i];
    mi.Tag := i;
    mi.OnClick := @RecentItemClick;
    FMiRecent.Add(mi);
  end;
  {$IFNDEF DARWIN}
  ThemeMenuItems(FMiRecent);
  {$ENDIF}
end;

procedure TMainForm.RecentItemClick(Sender: TObject);
var
  path: string;
begin
  path := PrefRecentDocuments[TMenuItem(Sender).Tag];
  if not EnsureDocumentSaved then Exit;
  FCtx.Connections.CloseAll;
  while FPages.PageCount > 0 do FPages.Pages[0].Free;
  OpenDocumentFile(path);
end;

procedure TMainForm.SaveDocClick(Sender: TObject);
begin
  if (FCtx.Document = nil) or FDocLocked then Exit;
  try
    FCtx.Document.Save;
    Log(mlInfo, RT_APP_NAME, rsDocumentSaved);
    ReportSaveWarnings(FCtx.Document.PreviousCopyStale, FCtx.Document.DurabilityUnconfirmed);
  except
    on E: EDocumentConflict do
      if RtMessageDlg(RT_APP_NAME, rsExternalChange, mtWarning, [mbYes, mbNo], 0) = mrYes then
      begin
        FCtx.Document.SaveAs(FCtx.Document.Path);
        Log(mlInfo, RT_APP_NAME, rsDocumentSaved);
        ReportSaveWarnings(FCtx.Document.PreviousCopyStale, FCtx.Document.DurabilityUnconfirmed);
      end;
    on E: Exception do
      RtMessageDlg(RT_APP_NAME, E.Message, mtError, [mbOK], 0);
  end;
  UpdateStatus;
end;

procedure TMainForm.ReportSaveWarnings(APreviousStale, ADurabilityUnconfirmed: Boolean);
begin
  // Filet .previous perime: on le dit. Un secours perime qu'on croit frais, c'est pire que pas de secours.
  if APreviousStale then
    Log(mlWarning, RT_APP_NAME, rsPreviousStale);
  if ADurabilityUnconfirmed then
    Log(mlWarning, RT_APP_NAME, rsSaveNotDurable);
end;

procedure TMainForm.SaveAsDocClick(Sender: TObject);
var
  sd: TSaveDialog;
  oldUuid: string;
begin
  if (FCtx.Document = nil) or FDocLocked then Exit;
  sd := TSaveDialog.Create(Self);
  try
    sd.Filter := rsDocFilter;
    sd.DefaultExt := 'rtt';
    sd.Options := sd.Options + [ofOverwritePrompt];
    if not sd.Execute then Exit;
    try
      oldUuid := FCtx.Document.Uuid;
      FCtx.Document.SaveAs(sd.FileName);
      // Copie vers un autre fichier: identite neuve. Les ecritures en vol et les issues retenues suivent la
      // session, l'ancien fichier garde la sienne. Jamais deux fichiers avec le meme document_uuid.
      FCtx.Journal.DocumentForked(oldUuid, FCtx.Document.Uuid);
      AddRecentDocument(sd.FileName);
      if FCtx.Document.Uuid <> oldUuid then
        Log(mlInfo, RT_APP_NAME, Format(rsDocumentSavedAs, [FCtx.Document.Path]))
      else
        Log(mlInfo, RT_APP_NAME, rsDocumentSaved);
      ReportSaveWarnings(FCtx.Document.PreviousCopyStale, FCtx.Document.DurabilityUnconfirmed);
    except
      on E: Exception do
        RtMessageDlg(RT_APP_NAME, E.Message, mtError, [mbOK], 0);
    end;
  finally
    sd.Free;
  end;
  UpdateDocumentState;
end;

procedure TMainForm.CloseDocClick(Sender: TObject);
begin
  if not EnsureDocumentSaved then Exit;
  FCtx.Connections.CloseAll;
  while FPages.PageCount > 0 do FPages.Pages[0].Free;
  // Le journal lache ce document avant sa liberation: une issue inconnue tardive sera retenue, jamais
  // consignee ailleurs.
  FCtx.Journal.SetActiveDocument(nil);
  FreeAndNil(FCtx.Document);
  FDocLocked := False;
  FLockedPath := '';
  FUnlockPending := False;
  ClearProfiles;
  RebuildTree;
  UpdateDocumentState;
end;

// Verrouillage: ecran purge d'abord, puis document sauve (ou copie de secours), puis cles liberees.
// Un echec de sauvegarde ne laisse jamais la session consultable.
function TMainForm.LockDocument: Boolean;
var
  i: Integer;
  anyModal: Boolean;
  doc: TRtDocument;
begin
  Result := False;
  if (FCtx.Document = nil) or FDocLocked then Exit;
  // Dialogues modaux fermes d'abord; le verrouillage reprend au tic suivant, une fois leurs boucles
  // sorties.
  anyModal := False;
  for i := Screen.FormCount - 1 downto 0 do
    if (Screen.Forms[i] <> Self) and (fsModal in Screen.Forms[i].FormState) then
    begin
      Screen.Forms[i].ModalResult := mrCancel;
      anyModal := True;
    end;
  if anyModal then
  begin
    FLockPending := True;
    Exit;
  end;
  FLockPending := False;
  // Fichiers LDIF modifies: enregistres ou abandonnes avant que le verrouillage ferme leurs onglets,
  // jamais en silence.
  for i := 0 to FCtx.Connections.Count - 1 do
    if (FCtx.Connections.Item(i).Profile.LdifPath <> '') and
       FCtx.Connections.Item(i).LdifModified and
       not ConfirmLdifClose(FCtx.Connections.Item(i)) then
      Exit;
  FCtx.ShutdownDeadlineMs := MonotonicMs + 3000;
  PasswordWork.CancelAll;
  // Brouillons d'attributs perdus au verrouillage: on le dit.
  for i := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[i] is TDirectoryTab) and TDirectoryTab(FPages.Pages[i]).HasPendingEdits then
      Log(mlWarning, FPages.Pages[i].Caption,
        Format(rsLockEditsLost, [TDirectoryTab(FPages.Pages[i]).CurrentEntry.Dn]))
    else if (FPages.Pages[i] is TEntryTab) and TEntryTab(FPages.Pages[i]).HasPendingEdits then
      Log(mlWarning, FPages.Pages[i].Caption,
        Format(rsLockEditsLost, [TEntryTab(FPages.Pages[i]).Dn]));
  while FPages.PageCount > 0 do FPages.Pages[0].Free;
  // 1. Etat verrouille etabli sans aucune E/S: document retire du contexte, profils et vues effaces,
  // ecran de verrouillage affiche.
  doc := FCtx.Document;
  FCtx.Document := nil;
  // Journal detache avant que le document passe au fil de sauvegarde: il n'ecrira jamais dans un
  // document possede par un autre fil. Les issues inconnues recues entre-temps attendent la reouverture
  // du meme chemin.
  FCtx.Journal.SetActiveDocument(nil);
  FLockedPath := doc.Path;
  ClearProfiles;
  FDocLocked := True;
  FUnlockPending := False;
  RebuildTree;
  UpdateDocumentState;
  // 2. Sauvegarde hors du fil graphique: le document appartient au fil jusqu'a son issue, un disque
  // bloque ne fige pas l'ecran. Une sauvegarde precedente encore en cours finit seule.
  if FLockSave <> nil then
  begin
    // Detachee mais suivie jusqu'a son message terminal.
    FLockSave.Release(0);
    FLockSave := nil;
  end;
  FLockSave := TDocumentSaveThread.Create(doc, Self);
  FLockSaveTask := FLockSave.TaskId;
  TrackSave(FLockSaveTask);
  // 3. Sessions fermees, sans bloquer au-dela de l'echeance commune.
  FCtx.Connections.CloseAll(FCtx.ShutdownWaitMs(1500));
  PasswordWork.WaitAll(FCtx.ShutdownWaitMs(1500));
  FCtx.ShutdownDeadlineMs := 0;
  Result := True;
end;

procedure TMainForm.TrackSave(ATaskId: Int64);
begin
  SetLength(FPendingSaves, Length(FPendingSaves) + 1);
  FPendingSaves[High(FPendingSaves)] := ATaskId;
end;

procedure TMainForm.ForgetSave(ATaskId: Int64);
var
  i, j: Integer;
begin
  for i := 0 to High(FPendingSaves) do
    if FPendingSaves[i] = ATaskId then
    begin
      for j := i to High(FPendingSaves) - 1 do
        FPendingSaves[j] := FPendingSaves[j + 1];
      SetLength(FPendingSaves, Length(FPendingSaves) - 1);
      Exit;
    end;
end;

function TMainForm.SavesInFlight: Integer;
begin
  Result := Length(FPendingSaves);
end;

procedure TMainForm.DrainInboxBounded;
var
  guard: Integer;
begin
  // Drain supporte l'imbrication: un gestionnaire occupe ne recoit rien et Drain rend 0, donc la boucle
  // s'arrete aussi quand plus rien n'est livrable. Le plafond d'iterations couvre les jours ou la theorie
  // se trompe.
  guard := 0;
  while (guard < 10) and (UiInbox.PendingCount > 0) do
  begin
    if UiInbox.Drain = 0 then Break;
    Inc(guard);
  end;
end;

procedure TMainForm.HandleDocSave(AMsg: TDocSaveMsg);
begin
  ForgetSave(AMsg.TaskId);
  // Copie de recuperation = nouvelle identite: les issues retenues pendant le verrouillage suivent la
  // session vers la copie.
  FCtx.Journal.DocumentForked(AMsg.OldUuid, AMsg.NewUuid);
  if AMsg.Outcome in [dsoSaved, dsoRecovery] then
    ReportSaveWarnings(AMsg.PreviousStale, AMsg.DurabilityUnconfirmed);
  case AMsg.Outcome of
    dsoSaved: Log(mlInfo, RT_APP_NAME, rsLockSaved);
    dsoRecovery:
      begin
        Log(mlWarning, RT_APP_NAME, Format(rsLockRecoverySaved, [AMsg.ErrorText, AMsg.Path]));
        // Echec montre a l'utilisateur, pas seulement au journal que personne ne lit.
        RtMessageDlg(RT_APP_NAME, Format(rsLockRecoverySaved, [AMsg.ErrorText, AMsg.Path]),
          mtWarning, [mbOK], 0);
      end;
    dsoLost:
      begin
        Log(mlError, RT_APP_NAME, Format(rsLockUnsavedLost, [AMsg.ErrorText, AMsg.RecoveryError]));
        RtMessageDlg(RT_APP_NAME, Format(rsLockUnsavedLost, [AMsg.ErrorText, AMsg.RecoveryError]),
          mtError, [mbOK], 0);
      end;
  end;
  // Issue d'une sauvegarde remplacee par un verrou plus recent: presentee ci-dessus, mais jamais
  // correlee a l'operation courante.
  if AMsg.TaskId <> FLockSaveTask then Exit;
  FLockedPath := AMsg.Path;
  if FLockSave <> nil then
  begin
    FLockSave.Release(3000);
    FLockSave := nil;
  end;
  if FUnlockPending and FDocLocked then
  begin
    FUnlockPending := False;
    OpenDocumentFile(FLockedPath);
  end;
end;

procedure TMainForm.LockDocClick(Sender: TObject);
begin
  if FDocLocked then
  begin
    if FLockSave <> nil then
    begin
      // Le fichier est encore tenu par la sauvegarde de verrouillage: la reouverture attend son issue.
      FUnlockPending := True;
      Log(mlInfo, RT_APP_NAME, rsLockSaveInProgress);
      Exit;
    end;
    OpenDocumentFile(FLockedPath);
    Exit;
  end;
  LockDocument;
end;

procedure TMainForm.ChangePasswordClick(Sender: TObject);
var
  pw: RawByteString;
begin
  if (FCtx.Document = nil) or FDocLocked then Exit;
  if not AskNewDocumentPassword(Self, FCtx.Document.Path, True, pw) then Exit;
  try
    Screen.Cursor := crHourGlass;
    try
      FCtx.Document.ChangePassword(pw);
      FCtx.Document.Save;
    finally
      Screen.Cursor := crDefault;
    end;
    Log(mlInfo, RT_APP_NAME, rsPasswordChanged);
    ReportSaveWarnings(FCtx.Document.PreviousCopyStale, FCtx.Document.DurabilityUnconfirmed);
  finally
    WipeString(pw);
  end;
end;

procedure TMainForm.ExitClick(Sender: TObject);
begin
  Close;
end;

procedure TMainForm.FormCloseQueryHandler(Sender: TObject; var CanClose: Boolean);
var
  savesBusy: Boolean;
begin
  // Issues deja publiees mais pas drainees: livrees et presentees d'abord, ce qui purge FPendingSaves.
  // Le drainage sert aussi les autres vues, c'est la pompe normale.
  DrainInboxBounded;
  // Aucune sauvegarde de verrouillage ne meurt avec le processus a l'insu de l'utilisateur: fil pas fini,
  // ou resultat pas encore recu. Un fil termine n'est pas une issue presentee: il a pu finir en dsoLost
  // (rien d'ecrit) ou en dsoRecovery.
  savesBusy := SaveCloseBusy(FLockSave <> nil,
    (FLockSave <> nil) and FLockSave.IsExecuteDone, SavesInFlight);
  if savesBusy and
    (RtMessageDlg(RT_APP_NAME, rsCloseWhileSaving, mtWarning, [mbYes, mbNo], 0) <> mrYes) then
  begin
    CanClose := False;
    Exit;
  end;
  // Issues inconnues retenues sans document ou les consigner: elles ne survivent pas au processus, la
  // fermeture doit le savoir.
  if (FCtx.Journal.HeldCount > 0) and
    (RtMessageDlg(RT_APP_NAME, Format(rsHeldOutcomesOnClose, [FCtx.Journal.HeldCount]),
      mtWarning, [mbYes, mbNo], 0) <> mrYes) then
  begin
    CanClose := False;
    Exit;
  end;
  CanClose := EnsureDocumentSaved;
  if not CanClose then Exit;
  PrefWindowMaximized := WindowState = wsMaximized;
  if WindowState = wsNormal then
  begin
    PrefWindowLeft := Left;
    PrefWindowTop := Top;
    PrefWindowWidth := Width;
    PrefWindowHeight := Height;
  end;
  PrefSidebarWidth := FLeft.Width;
  PrefMessagesHeight := FMessages.Height;
  PrefThemeName := CurrentThemeName;
  SavePreferences;
end;

function FolderLists(ADoc: TRtDocument; ANames, AUuids: TStrings): Boolean;
var
  f: TDocFolders;
  i: Integer;
begin
  Result := ADoc <> nil;
  if not Result then Exit;
  f := ADoc.Folders;
  for i := 0 to High(f) do
  begin
    ANames.Add(f[i].Name);
    AUuids.Add(f[i].Uuid);
  end;
end;

procedure TMainForm.NewProfileClick(Sender: TObject);
var
  p: TConnectionProfile;
  names, uuids: TStringList;
  folder: string;
  secret: RawByteString;
  remember: Boolean;
  ref: TSideRef;
begin
  if (FCtx.Document = nil) or FDocLocked then
  begin
    RtMessageDlg(RT_APP_NAME, rsNeedDocument, mtInformation, [mbOK], 0);
    Exit;
  end;
  p := TConnectionProfile.Create;
  names := TStringList.Create;
  uuids := TStringList.Create;
  try
    FolderLists(FCtx.Document, names, uuids);
    folder := '';
    ref := SelectedRef;
    if (ref <> nil) and (ref.Kind = snkFolder) then folder := ref.Uuid;
    if not EditProfile(Self, p, names, uuids, folder, secret, remember) then Exit;
    try
      p.Uuid := NewUuidV4;
      StoreProfile(FCtx.Document, p, folder, secret, remember);
    finally
      WipeString(secret);
    end;
    LoadProfilesFromDocument;
    RebuildTree;
    UpdateStatus;
  finally
    p.Free;
    names.Free;
    uuids.Free;
  end;
end;

procedure TMainForm.EditProfileClick(Sender: TObject);
var
  ref: TSideRef;
  p: TConnectionProfile;
  names, uuids: TStringList;
  folder: string;
  secret: RawByteString;
  remember: Boolean;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Kind <> snkProfile) or (FCtx.Document = nil) then Exit;
  p := FCtx.Document.LoadProfile(ref.Uuid);
  if p = nil then Exit;
  names := TStringList.Create;
  uuids := TStringList.Create;
  try
    FolderLists(FCtx.Document, names, uuids);
    folder := FCtx.Document.ProfileFolder(p.Uuid);
    if not EditProfile(Self, p, names, uuids, folder, secret, remember) then Exit;
    try
      StoreProfile(FCtx.Document, p, folder, secret, remember);
    finally
      WipeString(secret);
    end;
    // Parametres changes: la session ouverte de ce profil ne vaut plus rien.
    if FCtx.Connections.Find(p.Uuid) <> nil then
    begin
      FCtx.Connections.Close(p.Uuid);
      Log(mlInfo, p.Name, rsProfileChangedDisconnected);
    end;
    LoadProfilesFromDocument;
    RebuildTree;
    FTabBar.Invalidate;
  finally
    p.Free;
    names.Free;
    uuids.Free;
  end;
end;

procedure TMainForm.DuplicateProfileClick(Sender: TObject);
var
  ref: TSideRef;
  p: TConnectionProfile;
  keepSecret: Boolean;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Kind <> snkProfile) or (FCtx.Document = nil) then Exit;
  p := ProfileByUuid(ref.Uuid);
  if p = nil then Exit;
  keepSecret := False;
  // Le secret n'est duplique qu'apres un choix explicite.
  if p.SecretRef <> '' then
    keepSecret := RtMessageDlg(RT_APP_NAME, rsDuplicateSecretQuestion, mtConfirmation,
      [mbYes, mbNo], 0) = mrYes;
  DuplicateProfile(FCtx.Document, p.Uuid, keepSecret);
  LoadProfilesFromDocument;
  RebuildTree;
end;

procedure TMainForm.DeleteProfileClick(Sender: TObject);
var
  ref: TSideRef;
  p: TConnectionProfile;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Kind <> snkProfile) or (FCtx.Document = nil) then Exit;
  p := ProfileByUuid(ref.Uuid);
  if p = nil then Exit;
  if RtMessageDlg(RT_APP_NAME, Format(rsDeleteProfileQuestion, [p.Name]), mtConfirmation,
      [mbYes, mbNo], 0) <> mrYes then Exit;
  FCtx.Connections.Close(p.Uuid);
  while TabForProfile(p.Uuid) <> nil do
    TabForProfile(p.Uuid).Free;
  FCtx.Document.DeleteProfile(p.Uuid);
  LoadProfilesFromDocument;
  RebuildTree;
  UpdateDocumentState;
end;

procedure TMainForm.NewFolderClick(Sender: TObject);
var
  folderName, parentUuid: string;
  ref: TSideRef;
begin
  if (FCtx.Document = nil) or FDocLocked then Exit;
  folderName := '';
  if not RtInputQuery(rsMenuNewFolder, rsFolderName, folderName) or (Trim(folderName) = '') then Exit;
  parentUuid := '';
  ref := SelectedRef;
  if (ref <> nil) and (ref.Kind = snkFolder) then parentUuid := ref.Uuid;
  FCtx.Document.AddFolder(Trim(folderName), parentUuid);
  RebuildTree;
  UpdateStatus;
end;

procedure TMainForm.RenameFolderClick(Sender: TObject);
var
  ref: TSideRef;
  folderName: string;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Kind <> snkFolder) then Exit;
  folderName := FSidebar.SelectedText;
  if not RtInputQuery(rsMenuRenameFolder, rsFolderName, folderName) or (Trim(folderName) = '') then Exit;
  FCtx.Document.RenameFolder(ref.Uuid, Trim(folderName));
  RebuildTree;
end;

procedure TMainForm.DeleteFolderClick(Sender: TObject);
var
  ref: TSideRef;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Kind <> snkFolder) then Exit;
  if RtMessageDlg(RT_APP_NAME, rsDeleteFolderQuestion, mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  FCtx.Document.DeleteFolder(ref.Uuid);
  LoadProfilesFromDocument;
  RebuildTree;
end;

procedure TMainForm.ConnectClick(Sender: TObject);
var
  ref: TSideRef;
  p: TConnectionProfile;
  secret: RawByteString;
  tab: TDirectoryTab;
  c: TDirectoryConnection;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Kind <> snkProfile) then Exit;
  p := ProfileByUuid(ref.Uuid);
  if p = nil then Exit;
  // Secret memorise, sinon demande une fois. Pas de nouvel essai automatique: c'est comme ca qu'on
  // verrouille un compte de service un vendredi soir.
  if not ResolveBindSecret(FCtx.Document, p, @AskSecretFor, secret) then Exit;
  try
    // Avertissement du mot de passe en clair a la premiere connexion de la session.
    if NeedsPlainSecretConfirmation(p) then
      if RtMessageDlg(p.Name, rsPlainWarningConnect, mtWarning, [mbYes, mbNo], 0) <> mrYes then
        Exit;
    tab := TabForProfile(p.Uuid);
    c := FCtx.Connections.Open(p, secret, Self);
    if tab = nil then
      tab := NewDirectoryTab(c);
    FPages.ActivePage := tab;
    Log(mlInfo, p.Name, Format(rsConnecting, [p.DisplayEndpoint, TransportLabel(p.Transport)]));
  finally
    WipeString(secret);
  end;
  UpdateDocumentState;
  FTabBar.Invalidate;
end;

function TMainForm.NewDirectoryTab(AConn: TDirectoryConnection): TDirectoryTab;
begin
  Result := TDirectoryTab.CreateFor(FPages, FCtx, AConn);
  Result.PageControl := FPages;
  Result.OnOpenSearch := @DirectoryOpenSearch;
  Result.OnPasswordTools := @DirectoryPasswordTools;
  Result.OnExportEntry := @DirectoryExportEntry;
  Result.OnOpenEntry := @SearchOpenEntry;
  Result.OnEntryWritten := @RereadEntryViews;
end;

procedure TMainForm.OpenLdifClick(Sender: TObject);
var
  od: TOpenDialog;
begin
  od := TOpenDialog.Create(Self);
  try
    od.Filter := rsLdifFileFilter;
    od.Options := od.Options + [ofFileMustExist];
    if not od.Execute then Exit;
    OpenLdifFile(od.FileName);
  finally
    od.Free;
  end;
end;

procedure TMainForm.OpenLdifFile(const APath: string);
var
  path, uuid: string;
  i: Integer;
  c: TDirectoryConnection;
  p: TConnectionProfile;
  tab: TDirectoryTab;
begin
  path := ExpandFileName(APath);
  uuid := '';
  for i := 0 to FLdifPaths.Count - 1 do
    if SameFileName(FLdifPaths[i], path) then
      uuid := FLdifUuids[i];
  tab := nil;
  if uuid <> '' then
  begin
    tab := TabForProfile(uuid);
    c := FCtx.Connections.Find(uuid);
    if (tab <> nil) and (c <> nil) and (c.State <> csFailed) then
    begin
      FPages.ActivePage := tab;
      UpdateDocumentState;
      Exit;
    end;
  end
  else
  begin
    uuid := NewUuidV4;
    FLdifPaths.Add(path);
    FLdifUuids.Add(uuid);
  end;
  // Profil ephemere: jamais dans le document ni dans le panneau.
  p := TConnectionProfile.Create;
  try
    p.Uuid := uuid;
    p.Name := ExtractFileName(path);
    p.LdifPath := path;
    p.ReadOnly := False;
    c := FCtx.Connections.Open(p, '', Self);
    if tab = nil then
      tab := NewDirectoryTab(c);
    FPages.ActivePage := tab;
    Log(mlInfo, p.Name, Format(rsOpeningLdif, [path]));
  finally
    p.Free;
  end;
  UpdateDocumentState;
  FTabBar.Invalidate;
end;

function TMainForm.SaveLdifTo(AConn: TDirectoryConnection; const APath: string): Boolean;
var
  deadline: Int64;
  uuid: string;
  other: TDirectoryConnection;
begin
  Result := False;
  if (AConn = nil) or not AConn.IsReady then Exit;
  // Fichier deja ouvert dans un autre onglet: les deux s'ecraseraient a tour de role. L'autre ferme
  // d'abord.
  other := FCtx.Connections.LdifPathInUse(APath, AConn);
  if other <> nil then
  begin
    RtMessageDlg(RT_APP_NAME, Format(rsLdifPathOpenElsewhere, [ExtractFileName(APath),
      other.Profile.Name]), mtWarning, [mbOK], 0);
    Exit;
  end;
  // Ecraser le fichier ouvert: ce qu'il contenait sans etre charge est perdu, d'ou la question.
  if SameFileName(ExpandFileName(APath), AConn.Profile.LdifPath) and
     (AConn.LdifRewriteNote <> '') and
     (RtMessageDlg(RT_APP_NAME, Format(rsLdifRewriteConfirm, [AConn.Profile.Name,
       AConn.LdifRewriteNote]), mtWarning, [mbYes, mbNo], 0) <> mrYes) then
    Exit;
  uuid := AConn.Profile.Uuid;
  FLdifSaveDone := False;
  FLdifSaveOk := False;
  FLdifSaveTask := FCtx.Connections.SaveLdif(AConn, ExpandFileName(APath), Self);
  Screen.Cursor := crHourGlass;
  try
    deadline := MonotonicMs + 120000;
    while (not FLdifSaveDone) and (MonotonicMs < deadline) do
    begin
      UiInbox.Drain(50);
      if not FLdifSaveDone then Sleep(10);
    end;
  finally
    Screen.Cursor := crDefault;
  end;
  if not FLdifSaveDone then
  begin
    FLdifSaveTask := 0;
    Log(mlWarning, RT_APP_NAME, Format(rsLdifStillSaving, [ExtractFileName(APath)]));
    Exit;
  end;
  FLdifSaveTask := 0;
  Result := FLdifSaveOk;
  if not Result then
  begin
    AConn := FCtx.Connections.Find(uuid);
    if AConn <> nil then
      RtMessageDlg(RT_APP_NAME, Format(rsLdifSaveFailed, [ExtractFileName(APath),
        ErrorToText(AConn.LastError)]), mtError, [mbOK], 0);
  end;
  FTabBar.Invalidate;
  UpdateLdifMenus;
end;

function TMainForm.ConfirmLdifClose(AConn: TDirectoryConnection): Boolean;
begin
  case RtQuestionDlg(RT_APP_NAME, Format(rsLdifUnsaved, [AConn.Profile.Name]), mtConfirmation,
    [mrYes, rsSave, mrNo, rsDiscard, mrCancel, rsCancel], 0) of
    mrYes: Result := SaveLdifTo(AConn, AConn.Profile.LdifPath);
    mrNo: Result := True;
  else
    Result := False;
  end;
end;

procedure TMainForm.SaveLdifClick(Sender: TObject);
var
  c: TDirectoryConnection;
begin
  c := ActiveLdifConnection;
  if c = nil then
  begin
    RtMessageDlg(RT_APP_NAME, rsLdifNoActive, mtInformation, [mbOK], 0);
    Exit;
  end;
  SaveLdifTo(c, c.Profile.LdifPath);
end;

procedure TMainForm.SaveLdifAsClick(Sender: TObject);
var
  c: TDirectoryConnection;
  sd: TSaveDialog;
begin
  c := ActiveLdifConnection;
  if c = nil then
  begin
    RtMessageDlg(RT_APP_NAME, rsLdifNoActive, mtInformation, [mbOK], 0);
    Exit;
  end;
  sd := TSaveDialog.Create(Self);
  try
    sd.Filter := rsLdifFileFilter;
    sd.DefaultExt := 'ldif';
    sd.FileName := c.Profile.LdifPath;
    sd.Options := sd.Options + [ofOverwritePrompt];
    if not sd.Execute then Exit;
    SaveLdifTo(c, sd.FileName);
  finally
    sd.Free;
  end;
end;

procedure TMainForm.LdifSchemaFilesClick(Sender: TObject);
var
  c: TDirectoryConnection;
  od: TOpenDialog;
  paths: array of string;
  i: Integer;
  schema: TSchemaSnapshot;
  report: string;
begin
  c := ActiveLdifConnection;
  if c = nil then
  begin
    RtMessageDlg(RT_APP_NAME, rsLdifNoActive, mtInformation, [mbOK], 0);
    Exit;
  end;
  od := TOpenDialog.Create(Self);
  try
    od.Filter := rsLdifSchemaFilter;
    od.Options := od.Options + [ofFileMustExist, ofAllowMultiSelect];
    if not od.Execute then Exit;
    paths := nil;
    SetLength(paths, od.Files.Count);
    for i := 0 to od.Files.Count - 1 do
      paths[i] := od.Files[i];
  finally
    od.Free;
  end;
  schema := SchemaFromFiles(paths, report);
  if schema = nil then
  begin
    RtMessageDlg(RT_APP_NAME, Format(rsLdifSchemaNothing, [report]), mtWarning, [mbOK], 0);
    Exit;
  end;
  FCtx.Connections.UseLdifSchema(c, schema);
  FCtx.Sensitive.LearnSchema(schema);
  Log(mlInfo, c.Profile.Name, Format(rsLdifSchemaLoaded, [c.Profile.Name, report]));
end;

procedure TMainForm.LdifSchemaFromClick(Sender: TObject);
var
  c, src: TDirectoryConnection;
  d: TPickDialog;
  rows: TPickRows;
  i, n: Integer;
  key: string;
begin
  c := ActiveLdifConnection;
  if c = nil then
  begin
    RtMessageDlg(RT_APP_NAME, rsLdifNoActive, mtInformation, [mbOK], 0);
    Exit;
  end;
  rows := nil;
  n := 0;
  for i := 0 to FCtx.Connections.Count - 1 do
  begin
    src := FCtx.Connections.Item(i);
    if (src = c) or not src.IsReady or (src.Schema = nil) then Continue;
    SetLength(rows, n + 1);
    rows[n].Key := src.Profile.Uuid;
    rows[n].Cells := [src.Profile.Name, src.Profile.DisplayEndpoint,
      IntToStr(src.Schema.AttributeTypeCount)];
    rows[n].Info := src.Profile.DisplayEndpoint;
    Inc(n);
  end;
  if n = 0 then
  begin
    RtMessageDlg(RT_APP_NAME, rsLdifSchemaNoSource, mtInformation, [mbOK], 0);
    Exit;
  end;
  d := TPickDialog.CreatePick(Self, rsLdifSchemaFromTitle, rsLdifSchemaFromHelp,
    ['Directory', 'Endpoint', 'Attribute types'], [180, 260, 110]);
  try
    d.SetRows(rows);
    if RunPick(d) <> mrOk then Exit;
    key := d.Chosen;
  finally
    d.Free;
  end;
  // Les connexions ont pu changer pendant le dialogue modal.
  c := ActiveLdifConnection;
  src := FCtx.Connections.Find(key);
  if (c = nil) or (src = nil) or (src.Schema = nil) then Exit;
  FCtx.Connections.UseLdifSchema(c, src.Schema.Clone);
  Log(mlInfo, c.Profile.Name, Format(rsLdifSchemaBorrowed, [src.Profile.Name, c.Profile.Name,
    c.Schema.AttributeTypeCount, c.Schema.ObjectClassCount]));
end;

procedure TMainForm.DisconnectClick(Sender: TObject);
var
  ref: TSideRef;
  uuid: string;
begin
  uuid := '';
  ref := SelectedRef;
  if (ref <> nil) and (ref.Kind = snkProfile) then
    uuid := ref.Uuid
  else if ActiveDirectoryTab <> nil then
    uuid := ActiveDirectoryTab.ProfileUuid;
  if uuid = '' then Exit;
  FCtx.Connections.Close(uuid);
  FTabBar.Invalidate;
  FSidebar.InvalidateTree;
  UpdateStatus;
end;

procedure TMainForm.RefreshClick(Sender: TObject);
begin
  if ActiveDirectoryTab <> nil then
    ActiveDirectoryTab.RefreshSelected;
end;

procedure TMainForm.FocusDnClick(Sender: TObject);
begin
  if ActiveDirectoryTab <> nil then
    ActiveDirectoryTab.FocusDn;
end;

procedure TMainForm.DeleteEntryClick(Sender: TObject);
begin
  if ActiveDirectoryTab <> nil then
    ActiveDirectoryTab.DeleteSelected;
end;

procedure TMainForm.ThemeClick(Sender: TObject);
begin
  if ApplyThemeIndex(TMenuItem(Sender).Tag) then
  begin
    TMenuItem(Sender).Checked := True;
    PrefThemeName := CurrentThemeName;
    ApplyThemeToShell;
  end;
end;

procedure TMainForm.ToggleSidebarClick(Sender: TObject);
begin
  FLeft.Visible := not FLeft.Visible;
  FSplitLeft.Visible := FLeft.Visible;
  PrefSidebarVisible := FLeft.Visible;
end;

procedure TMainForm.ToggleMessagesClick(Sender: TObject);
begin
  FMessages.Visible := not FMessages.Visible;
  FSplitBottom.Visible := FMessages.Visible;
  PrefMessagesVisible := FMessages.Visible;
end;

procedure TMainForm.ToggleOperationalClick(Sender: TObject);
var
  tab: TDirectoryTab;
  c: TDirectoryConnection;
begin
  tab := ActiveDirectoryTab;
  if tab = nil then Exit;
  c := FCtx.Connections.Find(tab.ProfileUuid);
  if c = nil then Exit;
  c.Profile.ShowOperationalAttrs := not c.Profile.ShowOperationalAttrs;
  tab.RefreshSelected;
end;

procedure TMainForm.OpenSearchTab(ATab: TDirectoryTab; const ABaseDn, AFilter: string; AScope: Integer;
  ARun: Boolean);
var
  st: TSearchTab;
  c: TDirectoryConnection;
begin
  if ATab = nil then Exit;
  c := FCtx.Connections.Find(ATab.ProfileUuid);
  if (c = nil) or not c.IsReady then
  begin
    Log(mlWarning, RT_APP_NAME, rsNotConnected);
    Exit;
  end;
  st := TSearchTab.CreateFor(FPages, FCtx, c, ABaseDn, AFilter, TSearchScope(AScope));
  st.PageControl := FPages;
  st.OnOpenEntry := @SearchOpenEntry;
  FPages.ActivePage := st;
  UpdateDocumentState;
  if ARun then
    st.Run;
end;

procedure TMainForm.DirectoryOpenSearch(ATab: TDirectoryTab; const ABaseDn, AFilter: string;
  AScope: TSearchScope; ARun: Boolean);
begin
  OpenSearchTab(ATab, ABaseDn, AFilter, Ord(AScope), ARun);
end;

procedure TMainForm.SearchTabClick(Sender: TObject);
begin
  if ActiveDirectoryTab <> nil then
    OpenSearchTab(ActiveDirectoryTab, '', '(objectClass=*)', Ord(ssSubtree));
end;

procedure TMainForm.DirectoryPasswordTools(ATab: TDirectoryTab; AEntry: TLdapEntry);
var
  c: TDirectoryConnection;
begin
  c := FCtx.Connections.Find(ATab.ProfileUuid);
  if c = nil then Exit;
  RunPasswordTools(c, AEntry);
end;

procedure TMainForm.RunPasswordTools(c: TDirectoryConnection; AEntry: TLdapEntry);
var
  uuid, dn: string;
begin
  // Identite capturee avant le dialogue modal: un verrouillage pendant son ouverture detruit onglets
  // et entree.
  uuid := c.Profile.Uuid;
  dn := '';
  if AEntry <> nil then dn := AEntry.Dn;
  if ShowPasswordTools(Self, FCtx, c, AEntry) and (dn <> '') and not FDocLocked then
    RereadEntryViews(uuid, dn);
end;

procedure TMainForm.RereadEntryViews(const AProfileUuid, ADn: string);
var
  i: Integer;
  kept: Boolean;
begin
  for i := 0 to FPages.PageCount - 1 do
  begin
    kept := False;
    if (FPages.Pages[i] is TDirectoryTab) and
       (TDirectoryTab(FPages.Pages[i]).ProfileUuid = AProfileUuid) then
      kept := TDirectoryTab(FPages.Pages[i]).RereadIfShown(ADn)
    else if (FPages.Pages[i] is TEntryTab) and
       (TEntryTab(FPages.Pages[i]).ProfileUuid = AProfileUuid) then
      kept := TEntryTab(FPages.Pages[i]).RereadIfShown(ADn);
    if kept then
      Log(mlWarning, FPages.Pages[i].Caption, Format(rsPwdViewEditsKept, [ADn]));
  end;
end;

procedure TMainForm.SearchOpenEntry(const AProfileUuid, ADn: string);
var
  i: Integer;
  c: TDirectoryConnection;
  et: TEntryTab;
begin
  for i := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[i] is TEntryTab) and (TEntryTab(FPages.Pages[i]).ProfileUuid = AProfileUuid) and
       SameDnStrict(TEntryTab(FPages.Pages[i]).Dn, ADn) then
    begin
      FPages.ActivePage := FPages.Pages[i];
      UpdateDocumentState;
      Exit;
    end;
  c := FCtx.Connections.Find(AProfileUuid);
  if (c = nil) or not c.IsReady then
  begin
    Log(mlWarning, RT_APP_NAME, rsNotConnected);
    Exit;
  end;
  et := TEntryTab.CreateFor(FPages, FCtx, c, ADn);
  et.PageControl := FPages;
  et.OnPasswordTools := @EntryPasswordTools;
  FPages.ActivePage := et;
  UpdateDocumentState;
end;

procedure TMainForm.EntryPasswordTools(ATab: TObject; AEntry: TLdapEntry);
var
  c: TDirectoryConnection;
begin
  c := FCtx.Connections.Find(TEntryTab(ATab).ProfileUuid);
  if c = nil then Exit;
  RunPasswordTools(c, AEntry);
end;

procedure TMainForm.DirectoryExportEntry(ATab: TDirectoryTab; AEntry: TLdapEntry);
begin
  ShowLdifExport(Self, FCtx, ATab.ProfileUuid, AEntry);
end;

procedure TMainForm.PasswordToolClick(Sender: TObject);
var
  tab: TDirectoryTab;
  c: TDirectoryConnection;
begin
  tab := ActiveDirectoryTab;
  if tab = nil then
  begin
    ShowPasswordTools(Self, FCtx, nil, nil);
    Exit;
  end;
  c := FCtx.Connections.Find(tab.ProfileUuid);
  if c = nil then
    ShowPasswordTools(Self, FCtx, nil, tab.CurrentEntry)
  else
    RunPasswordTools(c, tab.CurrentEntry);
end;

procedure TMainForm.CertificateClick(Sender: TObject);
var
  tab: TDirectoryTab;
  c: TDirectoryConnection;
begin
  c := nil;
  tab := ActiveDirectoryTab;
  if tab <> nil then c := FCtx.Connections.Find(tab.ProfileUuid);
  ShowCertificateInspector(Self, c);
end;

procedure TMainForm.SchemaClick(Sender: TObject);
var
  tab: TDirectoryTab;
  c: TDirectoryConnection;
begin
  tab := ActiveDirectoryTab;
  if tab = nil then Exit;
  c := FCtx.Connections.Find(tab.ProfileUuid);
  if c <> nil then ShowSchemaBrowser(Self, FCtx, c.Profile.Uuid);
end;

procedure TMainForm.EscapeToolClick(Sender: TObject);
begin
  ShowEscapeTool(Self);
end;

procedure TMainForm.ExportProfilesClick(Sender: TObject);
begin
  if (FCtx.Document = nil) or FDocLocked then
  begin
    RtMessageDlg(RT_APP_NAME, rsNeedDocument, mtInformation, [mbOK], 0);
    Exit;
  end;
  ExportProfilesDialog(Self, FCtx, FCatalog);
end;

procedure TMainForm.ImportProfilesClick(Sender: TObject);
begin
  if (FCtx.Document = nil) or FDocLocked then
  begin
    RtMessageDlg(RT_APP_NAME, rsNeedDocument, mtInformation, [mbOK], 0);
    Exit;
  end;
  if ImportProfilesDialog(Self, FCtx, FCatalog) > 0 then
  begin
    LoadProfilesFromDocument;
    RebuildTree;
    UpdateStatus;
  end;
end;

procedure TMainForm.MonitorClick(Sender: TObject);
var
  tab: TDirectoryTab;
  c: TDirectoryConnection;
  i: Integer;
  mt: TMonitorTab;
begin
  tab := ActiveDirectoryTab;
  if tab = nil then Exit;
  c := FCtx.Connections.Find(tab.ProfileUuid);
  if (c = nil) or not c.IsReady then
  begin
    Log(mlWarning, RT_APP_NAME, rsNotConnected);
    Exit;
  end;
  if c.Profile.LdifPath <> '' then
  begin
    RtMessageDlg(RT_APP_NAME, rsLdifNoMonitor, mtInformation, [mbOK], 0);
    Exit;
  end;
  for i := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[i] is TMonitorTab) and (TMonitorTab(FPages.Pages[i]).ProfileUuid = c.Profile.Uuid) then
    begin
      FPages.ActivePage := FPages.Pages[i];
      UpdateDocumentState;
      Exit;
    end;
  mt := TMonitorTab.CreateFor(FPages, FCtx, c);
  mt.PageControl := FPages;
  FPages.ActivePage := mt;
  UpdateDocumentState;
end;

procedure TMainForm.AdDomainClick(Sender: TObject);
var
  tab: TDirectoryTab;
  c: TDirectoryConnection;
  kind: TProviderKind;
begin
  tab := ActiveDirectoryTab;
  if tab = nil then Exit;
  c := FCtx.Connections.Find(tab.ProfileUuid);
  if (c = nil) or not c.IsReady then
  begin
    Log(mlWarning, RT_APP_NAME, rsNotConnected);
    Exit;
  end;
  kind := EffectiveServerKind(c.Profile, c.RootDse);
  if kind <> pkActiveDirectory then
  begin
    RtMessageDlg(RT_APP_NAME, Format(rsNotActiveDirectory, [ServerKindName(kind)]), mtInformation,
      [mbOK], 0);
    Exit;
  end;
  ShowAdDomainOverview(Self, FCtx, c.Profile.Uuid);
end;

procedure TMainForm.RootDseClick(Sender: TObject);
var
  tab: TDirectoryTab;
  c: TDirectoryConnection;
begin
  tab := ActiveDirectoryTab;
  if tab = nil then Exit;
  c := FCtx.Connections.Find(tab.ProfileUuid);
  if c <> nil then ShowRootDse(Self, c);
end;

procedure TMainForm.LdifEditorClick(Sender: TObject);
var
  t: TLdifTab;
begin
  t := TLdifTab.CreateFor(FPages, FCtx);
  t.PageControl := FPages;
  FPages.ActivePage := t;
  UpdateDocumentState;
end;

procedure TMainForm.CompareNewClick(Sender: TObject);
var
  t: TCompareTab;
  c: TDirectoryConnection;
begin
  if FDocLocked then
  begin
    RtMessageDlg(RT_APP_NAME, rsNeedDocument, mtInformation, [mbOK], 0);
    Exit;
  end;
  c := ActiveLdifConnection;
  t := TCompareTab.CreateFor(FPages, FCtx, FCatalog);
  if c <> nil then
  begin
    t.AddLdifSource(c.Profile.LdifPath);
    if c.LdifModified then
      Log(mlWarning, c.Profile.Name, Format(rsLdifCompareOnDisk, [c.Profile.Name]));
  end;
  t.PageControl := FPages;
  FPages.ActivePage := t;
  UpdateDocumentState;
end;

procedure TMainForm.PreferencesClick(Sender: TObject);
begin
  if ShowPreferences(Self) then
  begin
    ApplyThemeToShell;
    ApplySensitivePrefs;
  end;
end;

procedure TMainForm.AboutClick(Sender: TObject);
begin
  ShowAbout(Self);
end;

procedure TMainForm.LicensesClick(Sender: TObject);
begin
  ShowLicenses(Self);
end;

finalization
  FreeAndNil(GWaker);

end.
