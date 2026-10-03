// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uMonitorTab;

{$mode objfpc}{$H+}

// Supervision d'un serveur: cn=monitor OpenLDAP et 389 DS, accords de replication 389 DS.
// Rafraichi toutes les 10 s, seulement quand l'onglet se voit: inutile de marteler
// un serveur pour un public absent.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, ExtCtrls, StdCtrls, Graphics, Forms, uAppContext,
  uConnections, uUiInbox, uDirectoryWorker, uRtList, uMonitorModel, uConnectionProfile, uTaskTracker;

type
  TMonitorPhase = (mpIdle, mpOpenLdap, mp389Monitor, mp389List, mp389Agreement);

  TMonitorTab = class(TTabSheet)
  private
    FCtx: TAppContext;
    FProfileUuid: string;
    FKind: TProviderKind;
    FTimer: TTimer;
    FTop: TPanel;
    FInfo: TLabel;
    FPause: TButton;
    FList: TRtListGrid;
    FAgreements: TRtListGrid;
    FAgreementsTitle: TLabel;
    FPaused: Boolean;
    FBusy: Boolean;
    FPhase: TMonitorPhase;
    FTasks: TDirectoryTasks;
    FEntries: TList;
    FAgreementDns: TStringList;
    FAgreementDn: string;
    FAgreementRows: array of TReplAgreement;
    FListFailed: Boolean;
    FListPartial: Boolean;
    FListIssue: string;
    FRows, FPrevRows: TMonitorRows;
    FLastTick, FPrevTick: Int64;
    function Conn: TDirectoryConnection;
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure TimerTick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure PauseClick(Sender: TObject);
    procedure StartRefresh;
    procedure NextAgreement;
    procedure ShowRows;
    procedure Finish;
    procedure ClearEntries;
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext; AConn: TDirectoryConnection);
    destructor Destroy; override;
    procedure ApplyTheme;
    property ProfileUuid: string read FProfileUuid;
  end;

implementation

uses
  uTheme, uUiKit, uLdapEntry, uSearchModel, uLdapErrors, uServerKind, uCancel;

resourcestring
  rsMonTitle = 'Monitor - %s';
  rsMonRefresh = 'Refresh now';
  rsMonPause = 'Pause';
  rsMonResume = 'Resume';
  rsMonColSection = 'Section';
  rsMonColName = 'Counter';
  rsMonColValue = 'Value';
  rsMonColRate = 'Per second';
  rsMonInfo = '%s - refreshed %s UTC every %d s while this tab is visible';
  rsMonPausedInfo = '%s - paused';
  rsMonNotConnected = 'Disconnected: refresh stopped.';
  rsMonUnsupported = 'No qualified monitor reader for %s: nothing is read.';
  rsMonAgreements = 'Replication agreements (389 Directory Server)';
  rsMonColAgreement = 'Agreement';
  rsMonColTarget = 'Consumer';
  rsMonColRoot = 'Suffix';
  rsMonColEnabled = 'Enabled';
  rsMonColHealth = 'State';
  rsMonColStatus = 'Last update status';
  rsMonColEnd = 'Last update end';
  rsMonColSent = 'Changes sent';
  rsMonReadFailed = 'Monitor not readable: %s';
  rsMonPartial = 'Partial monitor read: %s';
  rsMonAgreementListFailed = 'list not readable (%s)';
  rsMonAgreementListPartial = 'list truncated (%s): some agreements are missing';
  rsMonCoveragePartial = ' - PARTIAL COVERAGE';

constructor TMonitorTab.CreateFor(AOwner: TComponent; ACtx: TAppContext; AConn: TDirectoryConnection);
begin
  inherited Create(AOwner);
  FCtx := ACtx;
  FProfileUuid := AConn.Profile.Uuid;
  FKind := EffectiveServerKind(AConn.Profile, AConn.RootDse);
  Caption := Format(rsMonTitle, [AConn.Profile.Name]);
  FEntries := TList.Create;
  FAgreementDns := TStringList.Create;
  FTop := MakePanel(Self, alTop, 36);
  MakeButton(FTop, rsMonRefresh, @RefreshClick, alRight);
  FPause := MakeButton(FTop, rsMonPause, @PauseClick, alRight);
  FInfo := MakeLabel(FTop, '', alClient);
  FInfo.Layout := tlCenter;
  FInfo.BorderSpacing.Left := 10;
  FAgreements := TRtListGrid.Create(Self);
  FAgreements.Parent := Self;
  FAgreements.Align := alBottom;
  FAgreements.Height := 180;
  FAgreements.FillWidth := True;
  FAgreements.AddColumn(rsMonColAgreement, 140);
  FAgreements.AddColumn(rsMonColTarget, 160);
  FAgreements.AddColumn(rsMonColRoot, 160);
  FAgreements.AddColumn(rsMonColEnabled, 60);
  FAgreements.AddColumn(rsMonColHealth, 90);
  FAgreements.AddColumn(rsMonColStatus, 300);
  FAgreements.AddColumn(rsMonColEnd, 130);
  FAgreements.AddColumn(rsMonColSent, 120);
  FAgreements.Visible := FKind = pk389Ds;
  FAgreementsTitle := MakeLabel(Self, rsMonAgreements, alBottom);
  FAgreementsTitle.Visible := FAgreements.Visible;
  FList := TRtListGrid.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.FillWidth := True;
  FList.AddColumn(rsMonColSection, 140);
  FList.AddColumn(rsMonColName, 260);
  FList.AddColumn(rsMonColValue, 300);
  FList.AddColumn(rsMonColRate, 100);
  FTimer := TTimer.Create(Self);
  FTimer.Interval := MONITOR_REFRESH_SECONDS * 1000;
  FTimer.OnTimer := @TimerTick;
  FTimer.Enabled := True;
  FTasks := TDirectoryTasks.Create(FCtx.Connections, FProfileUuid, Self);
  FTasks.OnMessage := @TaskMessage;
  ApplyTheme;
  StartRefresh;
end;

destructor TMonitorTab.Destroy;
begin
  // Onglet ferme, plus de lecture ni de message: personne ne regarde, personne ne demande.
  FTimer.Enabled := False;
  if FTasks <> nil then FTasks.Cancel('monitor');
  FreeAndNil(FTasks);
  ClearEntries;
  FEntries.Free;
  FAgreementDns.Free;
  inherited Destroy;
end;

procedure TMonitorTab.ApplyTheme;
begin
  ThemeControlTree(Self);
  FTop.Color := clSideBg;
  FInfo.Font.Color := clSideText;
  FTop.Height := FontTextHeight(Font) + 20;
  ArrangeByCreation(Self);
end;

procedure TMonitorTab.ClearEntries;
var
  i: Integer;
begin
  for i := 0 to FEntries.Count - 1 do
    TLdapEntry(FEntries[i]).Free;
  FEntries.Clear;
end;

function TMonitorTab.Conn: TDirectoryConnection;
begin
  Result := nil;
  if FTasks <> nil then Result := FTasks.Conn;
end;

procedure TMonitorTab.TimerTick(Sender: TObject);
begin
  if FPaused or FBusy then Exit;
  if (PageControl = nil) or (PageControl.ActivePage <> Self) then Exit;
  StartRefresh;
end;

procedure TMonitorTab.RefreshClick(Sender: TObject);
begin
  if not FBusy then StartRefresh;
end;

procedure TMonitorTab.PauseClick(Sender: TObject);
begin
  FPaused := not FPaused;
  if FPaused then FPause.Caption := rsMonResume else FPause.Caption := rsMonPause;
  if not FPaused then StartRefresh;
end;

procedure TMonitorTab.StartRefresh;
var
  c: TDirectoryConnection;
  req: TSearchRequest;
begin
  c := Conn;
  if c = nil then
  begin
    FTimer.Enabled := False;
    FInfo.Caption := rsMonNotConnected;
    Exit;
  end;
  FTimer.Enabled := True;
  ClearEntries;
  FListFailed := False;
  FListPartial := False;
  FListIssue := '';
  case FKind of
    pkOpenLdap:
      begin
        FPhase := mpOpenLdap;
        req := DefaultSearchRequest;
        req.BaseDn := OpenLdapMonitorBase(c.RootDse);
        req.Scope := ssSubtree;
        req.Filter := '(objectClass=*)';
        // Les compteurs OpenLDAP sont operationnels: sans '+', cn=monitor joue
        // les annuaires vides avec beaucoup de conviction.
        req.Attributes := ['*', '+'];
        req.SizeLimit := 5000;
        FTasks.Search('monitor', req);
      end;
    pk389Ds:
      begin
        FPhase := mp389Monitor;
        FTasks.ReadEntry('monitor', DS389_MONITOR_DN, DS389_MONITOR_ATTRS);
      end;
  else
    begin
      FInfo.Caption := Format(rsMonUnsupported, [ServerKindName(FKind)]);
      FTimer.Enabled := False;
      Exit;
    end;
  end;
  FBusy := FTasks.Pending('monitor');
end;

procedure TMonitorTab.NextAgreement;
var
  c: TDirectoryConnection;
  dn: string;
begin
  c := Conn;
  if (c = nil) or (FAgreementDns.Count = 0) then
  begin
    Finish;
    Exit;
  end;
  dn := FAgreementDns[0];
  FAgreementDns.Delete(0);
  FAgreementDn := dn;
  if FTasks.ReadEntry('monitor', dn, DS389_AGREEMENT_ATTRS) = 0 then Finish;
end;

procedure TMonitorTab.Finish;
var
  i: Integer;
  g: TReplAgreement;
begin
  FBusy := False;
  FPhase := mpIdle;
  ShowRows;
  if FKind = pk389Ds then
  begin
    FAgreements.Clear;
    for i := 0 to High(FAgreementRows) do
    begin
      g := FAgreementRows[i];
      FAgreements.AddRow([g.Name, g.Target, g.Root, g.Enabled, AgreementHealthText(g.Health),
        g.LastUpdateStatus, g.LastUpdateEnd, g.ChangesSent]);
    end;
    if FListFailed then
      FAgreementsTitle.Caption := rsMonAgreements + ' - ' +
        Format(rsMonAgreementListFailed, [FListIssue])
    else if FListPartial then
      FAgreementsTitle.Caption := rsMonAgreements + ' - ' +
        Format(rsMonAgreementListPartial, [FListIssue])
    else
      FAgreementsTitle.Caption := rsMonAgreements;
  end;
end;

procedure TMonitorTab.ShowRows;
var
  i, j: Integer;
  rate: Double;
  rateText: string;
  c: TDirectoryConnection;
  profName: string;
begin
  FPrevTick := FLastTick;
  FLastTick := MonotonicMs;
  FList.Clear;
  for i := 0 to High(FRows) do
  begin
    rateText := '';
    if FRows[i].IsCounter and (FPrevTick > 0) then
      for j := 0 to High(FPrevRows) do
        if (FPrevRows[j].Section = FRows[i].Section) and (FPrevRows[j].Name = FRows[i].Name) then
        begin
          if CounterRate(FPrevRows[j], FRows[i], (FLastTick - FPrevTick) / 1000, rate) then
            rateText := FormatFloat('0.0', rate);
          Break;
        end;
    FList.AddRow([FRows[i].Section, FRows[i].Name, FRows[i].Value, rateText]);
  end;
  FPrevRows := FRows;
  c := Conn;
  if c <> nil then profName := c.Profile.Name else profName := '';
  if FPaused then
    FInfo.Caption := Format(rsMonPausedInfo, [profName])
  else
    FInfo.Caption := Format(rsMonInfo, [profName, FormatDateTime('hh:nn:ss',
      UtcNow), MONITOR_REFRESH_SECONDS]);
  if FListFailed or FListPartial then
    FInfo.Caption := FInfo.Caption + rsMonCoveragePartial;
end;

procedure TMonitorTab.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
var
  c: TDirectoryConnection;
  m: TEntriesMsg;
  e: TLdapEntry;
  req: TSearchRequest;
  n: Integer;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  // Reponse d'une session fermee ou remplacee: on clot le cycle, sinon FBusy
  // reste leve et plus rien ne se rafraichit jamais. Le suivant repart sur la session courante.
  if AEnding = teStale then
  begin
    Finish;
    Exit;
  end;
  if AMsg is TTaskFailedMsg then
  begin
    FBusy := False;
    FPhase := mpIdle;
    FInfo.Caption := Format(rsMonReadFailed, [TTaskFailedMsg(AMsg).Text]);
    Exit;
  end;
  case FPhase of
    mpOpenLdap:
      if AMsg is TEntriesMsg then
      begin
        m := TEntriesMsg(AMsg);
        while m.Entries.Count > 0 do
          FEntries.Add(m.Entries.Extract(m.Entries[0]));
        if not m.Final then Exit;
        if SearchOutcome(m.Completion) <> soComplete then
          FCtx.Log(mlWarning, Caption, Format(rsMonPartial, [ResultCodeName(m.Completion.ResultCode)]));
        FRows := ParseOpenLdapMonitor(OpenLdapMonitorBase(c.RootDse), FEntries);
        Finish;
      end;
    mp389Monitor:
      if AMsg is TEntryMsg then
      begin
        FRows := Parse389Monitor(TEntryMsg(AMsg).Entry);
        FAgreementRows := nil;
        FAgreementDns.Clear;
        req := DefaultSearchRequest;
        req.BaseDn := DS389_AGREEMENTS_BASE;
        req.Scope := ssSubtree;
        req.Filter := DS389_AGREEMENT_FILTER;
        req.Attributes := ['1.1'];
        req.SizeLimit := 500;
        FPhase := mp389List;
        if FTasks.Search('monitor', req) = 0 then Finish;
      end;
    mp389List:
      if AMsg is TEntriesMsg then
      begin
        m := TEntriesMsg(AMsg);
        for n := 0 to m.Entries.Count - 1 do
          FAgreementDns.Add(TLdapEntry(m.Entries[n]).Dn);
        if not m.Final then Exit;
        // Un echec de recherche arrive ici (Final, code non succes) et pas en TTaskFailedMsg.
        // Ne surtout pas le prendre pour une liste vide: zero accord et accords illisibles, ce n'est pas pareil.
        case SearchOutcome(m.Completion) of
          soComplete: ;
          soPartial:
            begin
              FListPartial := True;
              // Limite atteinte cote client: le serveur, lui, repond toujours "success" sans rougir.
              if m.Completion.ClientLimitHit then
                FListIssue := ResultCodeName(LDAP_RC_SIZELIMIT_EXCEEDED)
              else
                FListIssue := ResultCodeName(m.Completion.ResultCode);
              FCtx.Log(mlWarning, Caption, Format(rsMonPartial, [FListIssue]));
            end;
        else
          begin
            FListFailed := True;
            FListIssue := ResultCodeName(m.Completion.ResultCode);
            FCtx.Log(mlWarning, Caption, Format(rsMonPartial, [FListIssue]));
          end;
        end;
        FPhase := mp389Agreement;
        NextAgreement;
      end;
    mp389Agreement:
      if AMsg is TEntryMsg then
      begin
        e := TEntryMsg(AMsg).Entry;
        n := Length(FAgreementRows);
        SetLength(FAgreementRows, n + 1);
        if e <> nil then
          FAgreementRows[n] := ParseAgreement(e)
        else
        begin
          FAgreementRows[n] := Default(TReplAgreement);
          FAgreementRows[n].Dn := FAgreementDn;
          FAgreementRows[n].Name := FAgreementDn;
          FAgreementRows[n].Target := rsMonUnavailable;
          FAgreementRows[n].Root := rsMonUnavailable;
          FAgreementRows[n].Enabled := rsMonUnavailable;
          FAgreementRows[n].LastUpdateStatus := rsMonUnavailable;
          FAgreementRows[n].LastUpdateEnd := rsMonUnavailable;
          FAgreementRows[n].ChangesSent := rsMonUnavailable;
        end;
        NextAgreement;
      end;
  end;
end;

end.
