// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uEntryTab;

{$mode objfpc}{$H+}

// Onglet d'une entree ouverte depuis une recherche: lecture par DN, edition par l'editeur commun.
// Les droits, c'est le serveur qui tranche au moment d'ecrire, pas cet onglet.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, ExtCtrls, StdCtrls, Forms, Graphics, Dialogs,
  uAppContext, uConnections, uUiInbox, uDirectoryWorker, uLdapEntry, uEntryEditor, uTaskTracker;

resourcestring
  rsEntryTabReload = 'Reload';
  rsEntryTabLoading = 'Reading %s...';
  rsEntryTabNotFound = 'The entry could not be read: %s';
  rsEntryTabSessionLost = 'the connection changed during the read; use Reload';

type
  TEntryTabEvent = procedure(ATab: TObject; AEntry: TLdapEntry) of object;

  TEntryTab = class(TTabSheet)
  private
    FCtx: TAppContext;
    FProfileUuid: string;
    FSessionId: string;
    FGeneration: Int64;
    FDn: string;
    FTopBar: TPanel;
    FDnLabel: TLabel;
    FEditor: TEntryEditor;
    FTasks: TDirectoryTasks;
    FOnPasswordTools: TEntryTabEvent;
    function Conn: TDirectoryConnection;
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure ReloadClick(Sender: TObject);
    procedure EditorPasswordTools(AEntry: TLdapEntry);
    procedure EditorRereadRequest(Sender: TObject);
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext; AConn: TDirectoryConnection;
      const ADn: string);
    destructor Destroy; override;
    procedure ApplyTheme;
    procedure Reload;
    function RereadIfShown(const ADn: string): Boolean;
    function HasPendingEdits: Boolean;
    function ConfirmDiscardEdits: Boolean;
    function CurrentEntry: TLdapEntry;
    property ProfileUuid: string read FProfileUuid;
    property Dn: string read FDn;
    property Tasks: TDirectoryTasks read FTasks;
    property OnPasswordTools: TEntryTabEvent read FOnPasswordTools write FOnPasswordTools;
  end;

implementation

uses
  uTheme, uUiKit, uLdapErrors, uDirectoryService;

constructor TEntryTab.CreateFor(AOwner: TComponent; ACtx: TAppContext;
  AConn: TDirectoryConnection; const ADn: string);
begin
  inherited Create(AOwner);
  FCtx := ACtx;
  FProfileUuid := AConn.Profile.Uuid;
  FSessionId := AConn.SessionId;
  FGeneration := AConn.Generation;
  FDn := ADn;
  Caption := RdnCaption(ADn);
  FTopBar := MakePanel(Self, alTop, 36);
  MakeButton(FTopBar, rsEntryTabReload, @ReloadClick, alRight);
  FDnLabel := MakeLabel(FTopBar, ADn, alClient);
  FDnLabel.Layout := tlCenter;
  FDnLabel.BorderSpacing.Left := 10;
  FTasks := TDirectoryTasks.Create(FCtx.Connections, FProfileUuid, Self);
  FTasks.OnMessage := @TaskMessage;
  FEditor := TEntryEditor.Create(Self, FCtx, @Conn);
  FEditor.Parent := Self;
  FEditor.Align := alClient;
  FEditor.Title := AConn.Profile.Name + ' - ' + ADn;
  FEditor.ViewTasks := FTasks;
  FEditor.ProfileUuid := FProfileUuid;
  FEditor.OnPasswordTools := @EditorPasswordTools;
  FEditor.OnRereadRequest := @EditorRereadRequest;
  ApplyTheme;
  Reload;
end;

destructor TEntryTab.Destroy;
begin
  // Plus rien n'est livre a cette vue une fois detruite; une issue d'ecriture
  // en attente part chez les orphelins plutot que dans un objet mort.
  FEditor.ViewTasks := nil;
  FreeAndNil(FTasks);
  inherited Destroy;
end;

function TEntryTab.Conn: TDirectoryConnection;
begin
  Result := FCtx.Connections.Find(FProfileUuid);
  if (Result <> nil) and (Result.SessionId <> FSessionId) then
  begin
    FSessionId := Result.SessionId;
    FGeneration := Result.Generation;
  end;
end;

procedure TEntryTab.ApplyTheme;
begin
  ThemeControlTree(Self);
  FTopBar.Color := clSideBg;
  FDnLabel.Font.Color := clSideText;
  FTopBar.Height := FontTextHeight(Font) + 20;
  FEditor.ApplyTheme;
  ArrangeByCreation(Self);
end;

procedure TEntryTab.Reload;
var
  c: TDirectoryConnection;
begin
  c := Conn;
  if (c = nil) or not c.IsReady then Exit;
  FDnLabel.Caption := Format(rsEntryTabLoading, [FDn]);
  // Une lecture encore en vol est annulee: deux reponses pour une grille, c'est une de trop.
  FTasks.Cancel('read');
  if FTasks.ReadEntry('read', FDn, EntryReadAttributes(c.Profile)) <> 0 then
    FEditor.ReadPending := True;
end;

function TEntryTab.RereadIfShown(const ADn: string): Boolean;
begin
  Result := False;
  if not SameDnStrict(FDn, ADn) then Exit;
  if HasPendingEdits then Exit(True);
  FEditor.KeepRevealOnNextRead(FDn);
  Reload;
  if not FEditor.ReadPending then FEditor.KeepRevealOnNextRead('');
end;

procedure TEntryTab.ReloadClick(Sender: TObject);
begin
  if HasPendingEdits and not ConfirmDiscardEdits then Exit;
  Reload;
end;

procedure TEntryTab.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
begin
  if ATask.Tag = EDITOR_PRECHECK_TAG then
  begin
    FEditor.PrecheckDelivered(AMsg, AEnding);
    Exit;
  end;
  if ATask.Tag = 'read' then
  begin
    FEditor.ReadPending := False;
    if AEnding = teStale then
    begin
      FDnLabel.Caption := Format(rsEntryTabNotFound, [rsEntryTabSessionLost]);
      Exit;
    end;
    if AMsg is TTaskFailedMsg then
    begin
      FCtx.Log(mlError, Caption, TTaskFailedMsg(AMsg).Text);
      Exit;
    end;
    if not (AMsg is TEntryMsg) then Exit;
    if TEntryMsg(AMsg).Entry = nil then
    begin
      FDnLabel.Caption := Format(rsEntryTabNotFound, [ErrorToText(TEntryMsg(AMsg).Error)]);
      FCtx.Log(mlWarning, Caption, ErrorToText(TEntryMsg(AMsg).Error));
      Exit;
    end;
    FDnLabel.Caption := FDn;
    FEditor.ShowEntry(TEntryMsg(AMsg).Entry);
    TEntryMsg(AMsg).Entry := nil;
    Exit;
  end;
  if ATask.Tag = VIEW_WRITE_TAG then
  begin
    // Ecriture d'une session remplacee: issue inconnue, deja consignee au journal.
    // On le dit, mais on ne la fait surtout pas passer pour un resultat.
    if AEnding = teStale then
      FCtx.Log(mlError, Caption, rsDirWriteSessionLost)
    else if AMsg is TWriteMsg then
      FEditor.HandleWrite(TWriteMsg(AMsg))
    else if AMsg is TTaskFailedMsg then
      FCtx.Log(mlError, Caption, TTaskFailedMsg(AMsg).Text);
  end;
end;

procedure TEntryTab.EditorPasswordTools(AEntry: TLdapEntry);
begin
  if Assigned(FOnPasswordTools) then FOnPasswordTools(Self, AEntry);
end;

procedure TEntryTab.EditorRereadRequest(Sender: TObject);
begin
  Reload;
end;

function TEntryTab.HasPendingEdits: Boolean;
begin
  Result := FEditor.HasPendingEdits;
end;

function TEntryTab.ConfirmDiscardEdits: Boolean;
begin
  Result := FEditor.ConfirmDiscardEdits;
end;

function TEntryTab.CurrentEntry: TLdapEntry;
begin
  Result := FEditor.Original;
end;

end.
