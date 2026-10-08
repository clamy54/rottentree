// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uScanTab;

{$mode objfpc}{$H+}

// Socle des onglets qui parcourent tout un annuaire pour en tirer une liste. L'ecran vient du
// kit; ici le parcours, son suivi et l'export CSV. Un parcours coupe par le serveur ou arrete
// en route n'est jamais presente comme complet: un audit partiel qui se dit complet fait plus
// de degats que pas d'audit du tout.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, ExtCtrls, StdCtrls, Forms, Dialogs,
  uAppContext, uConnections, uUiInbox, uRtList, uRtReport, uTaskTracker, uSearchTab,
  uSearchModel, uDirectoryWorker, uSafeOutput;

const
  // Lignes affichees; l'export porte sur tout. Passe mille, ce n'est plus une liste a
  // traiter, c'est un constat.
  SCAN_SHOWN_MAX = 1000;

type
  TScanState = (scsIdle, scsRunning, scsDone, scsFailed);

  TScanTab = class(TTabSheet)
  private
    FView: TRtReportView;
    FRunBtn, FStopBtn, FExportBtn: TButton;
    FTasks: TDirectoryTasks;
    FFailure: string;
    FOnOpenEntry: TOpenEntryEvent;
    procedure BuildUi;
    procedure RunClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
    procedure ListActivate(Sender: TObject; AIndex: Integer);
    function ListCell(Sender: TObject; AIndex, ACol: Integer): string;
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure Fail(const AText: string);
    function WarningText: string;
  protected
    FCtx: TAppContext;
    FProfileUuid: string;
    FList: TRtListGrid;
    FState: TScanState;
    FCompletion: TSearchCompletion;
    FBases: string;
    // %s recoit le nom du profil.
    function TitleFormat: string; virtual; abstract;
    procedure BuildBarExtras(AView: TRtReportView); virtual;
    procedure SetupColumns; virtual; abstract;
    procedure ResetResults; virtual; abstract;
    function NewCommand(AConn: TDirectoryConnection;
      const ABases: TStringArray): TWorkerCommand; virtual; abstract;
    procedure Absorb(AMsg: TEntriesMsg); virtual; abstract;
    function ShownCount: Integer; virtual; abstract;
    function Cell(AIndex, ACol: Integer): string; virtual; abstract;
    function DnAt(AIndex: Integer): string; virtual; abstract;
    function SummaryText: string; virtual; abstract;
    // Ce que l'outil n'a pas pu lire, quand ca change la portee du resultat. Vide: rien.
    function CoverageWarning: string; virtual;
    function ExportCount: Int64; virtual; abstract;
    // En-tete compris; rend le nombre de lignes.
    function ExportRows(ACsv: TCsvWriter): Int64; virtual; abstract;
    function Finished: Boolean;
    procedure ListChanged;
    procedure UpdateView;
    // Abandonne le parcours en cours et repart avec les reglages du moment.
    procedure Restart;
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext;
      AConn: TDirectoryConnection); virtual;
    destructor Destroy; override;
    procedure ApplyTheme;
    procedure Run;
    property ProfileUuid: string read FProfileUuid;
    property OnOpenEntry: TOpenEntryEvent read FOnOpenEntry write FOnOpenEntry;
  end;

  TScanTabClass = class of TScanTab;

implementation

uses
  uTheme, uDirectoryOps, uDirectoryService, uLdapErrors, uSafeSave;

const
  SCAN_TAG = 'scan';

resourcestring
  rsScanRun = 'Scan again';
  rsScanStop = 'Stop';
  rsScanExport = 'Export CSV...';
  rsScanOpenHint = 'Double-click a line (or press Enter) to open the entry in its own tab.';
  rsScanNoBase = 'No base DN is known for this connection: nothing to scan.';
  rsScanNotConnected = 'Not connected: nothing was scanned.';
  rsScanFailed = 'Scan failed: %s';
  rsScanSessionLost = 'the connection changed during the scan; run it again';
  rsScanCancelled = 'SCAN STOPPED: the figures cover only what was read before the stop.';
  rsScanPartial = 'PARTIAL SCAN (%s): the server did not return every entry, the figures cover ' +
    'only what was read.';
  rsScanExported = '%d lines exported to %s (%s)';
  rsScanCoverComplete = 'complete scan';
  rsScanCoverPartial = 'partial scan';

// Une base placee sous une autre serait parcourue deux fois, et ses entrees comptees deux fois.
function UnderBase(const ADn, ABase: string): Boolean;
var
  d, b: string;
begin
  d := LowerCase(StringReplace(ADn, ', ', ',', [rfReplaceAll]));
  b := LowerCase(StringReplace(ABase, ', ', ',', [rfReplaceAll]));
  Result := (Length(d) > Length(b)) and (Copy(d, Length(d) - Length(b), MaxInt) = ',' + b);
end;

function ScanBases(AConn: TDirectoryConnection): TStringArray;
var
  all: TStringArray;
  i, j, n: Integer;
  nested: Boolean;
begin
  all := DirectoryBases(AConn);
  Result := nil;
  SetLength(Result, Length(all));
  n := 0;
  for i := 0 to High(all) do
  begin
    nested := Trim(all[i]) = '';
    for j := 0 to High(all) do
      if (j <> i) and (UnderBase(all[i], all[j]) or ((j < i) and SameText(all[i], all[j]))) then
        nested := True;
    if not nested then
    begin
      Result[n] := all[i];
      Inc(n);
    end;
  end;
  SetLength(Result, n);
end;

function PartialReasons(const C: TSearchCompletion): string;
begin
  Result := ResultCodeName(C.ResultCode);
  if C.SizeLimitHit then Result := Result + ', server size limit';
  if C.TimeLimitHit then Result := Result + ', time limit';
  if C.ContinuationsIgnored > 0 then
    Result := Result + Format(', %d referrals not followed', [C.ContinuationsIgnored]);
  if C.ReferralsIgnored > 0 then
    Result := Result + Format(', %d referrals ignored', [C.ReferralsIgnored]);
  if C.PagingAnomaly <> '' then Result := Result + ', ' + C.PagingAnomaly;
  if C.DecodeFailures > 0 then
    Result := Result + Format(', %d entries not decoded', [C.DecodeFailures]);
  if C.TruncatedEntries > 0 then
    Result := Result + Format(', %d entries with omitted values', [C.TruncatedEntries]);
end;

constructor TScanTab.CreateFor(AOwner: TComponent; ACtx: TAppContext;
  AConn: TDirectoryConnection);
begin
  inherited Create(AOwner);
  FCtx := ACtx;
  FProfileUuid := AConn.Profile.Uuid;
  Caption := Format(TitleFormat, [AConn.Profile.Name]);
  BuildUi;
  FTasks := TDirectoryTasks.Create(FCtx.Connections, FProfileUuid, Self);
  FTasks.OnMessage := @TaskMessage;
  ApplyTheme;
  UpdateView;
end;

destructor TScanTab.Destroy;
begin
  if FTasks <> nil then FTasks.Cancel(SCAN_TAG);
  FreeAndNil(FTasks);
  inherited Destroy;
end;

procedure TScanTab.BuildBarExtras(AView: TRtReportView);
begin
end;

function TScanTab.CoverageWarning: string;
begin
  Result := '';
end;

procedure TScanTab.BuildUi;
begin
  FView := TRtReportView.Create(Self);
  FView.Parent := Self;
  FView.Align := alClient;
  FRunBtn := FView.AddButton(rsScanRun, @RunClick);
  FStopBtn := FView.AddButton(rsScanStop, @StopClick);
  FExportBtn := FView.AddButton(rsScanExport, @ExportClick);
  FView.BarHint := rsScanOpenHint;
  BuildBarExtras(FView);
  FList := FView.List;
  FList.OnGetCell := @ListCell;
  FList.OnActivateRow := @ListActivate;
  SetupColumns;
end;

procedure TScanTab.ApplyTheme;
begin
  Color := clAppBg;
  FView.ApplyTheme;
end;

function TScanTab.Finished: Boolean;
begin
  Result := FState in [scsDone, scsFailed];
end;

procedure TScanTab.ListChanged;
begin
  FList.Count := ShownCount;
end;

function TScanTab.ListCell(Sender: TObject; AIndex, ACol: Integer): string;
begin
  if (AIndex < 0) or (AIndex >= ShownCount) then Exit('');
  Result := Cell(AIndex, ACol);
end;

procedure TScanTab.ListActivate(Sender: TObject; AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= ShownCount) then Exit;
  if Assigned(FOnOpenEntry) then
    FOnOpenEntry(FProfileUuid, DnAt(AIndex));
end;

procedure TScanTab.Fail(const AText: string);
begin
  FState := scsFailed;
  FFailure := AText;
  UpdateView;
end;

procedure TScanTab.Run;
var
  c: TDirectoryConnection;
  cmd: TWorkerCommand;
  bases: TStringArray;
  id: Int64;
begin
  if (FState = scsRunning) and FTasks.Pending(SCAN_TAG) then Exit;
  FTasks.Cancel(SCAN_TAG);
  FCompletion := Default(TSearchCompletion);
  FFailure := '';
  ResetResults;
  ListChanged;
  c := FTasks.Conn;
  if c = nil then
  begin
    Fail(rsScanNotConnected);
    Exit;
  end;
  bases := ScanBases(c);
  if Length(bases) = 0 then
  begin
    Fail(rsScanNoBase);
    Exit;
  end;
  FBases := string.Join(' ; ', bases);
  cmd := NewCommand(c, bases);
  id := cmd.TaskId;
  FCtx.Connections.SubmitCommand(c, cmd);
  FTasks.Declare(id, tkSearch, SCAN_TAG);
  FState := scsRunning;
  UpdateView;
end;

procedure TScanTab.Restart;
begin
  FState := scsIdle;
  Run;
end;

procedure TScanTab.RunClick(Sender: TObject);
begin
  Run;
end;

procedure TScanTab.StopClick(Sender: TObject);
begin
  if FState <> scsRunning then Exit;
  // Session fermee sans dernier message: personne ne viendra solder le parcours.
  if FTasks.Pending(SCAN_TAG) then
    FTasks.Stop(SCAN_TAG)
  else
    Fail(rsScanSessionLost);
end;

procedure TScanTab.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask;
  AEnding: TTaskEnding);
var
  m: TEntriesMsg;
begin
  if AEnding = teStale then
  begin
    Fail(rsScanSessionLost);
    Exit;
  end;
  if AMsg is TTaskFailedMsg then
  begin
    Fail(TTaskFailedMsg(AMsg).Text);
    Exit;
  end;
  if not (AMsg is TEntriesMsg) then Exit;
  m := TEntriesMsg(AMsg);
  Absorb(m);
  ListChanged;
  if m.Final then
  begin
    FCompletion := m.Completion;
    if SearchOutcome(m.Completion) = soFailed then
    begin
      Fail(ErrorToText(m.Error));
      Exit;
    end;
    FState := scsDone;
  end;
  UpdateView;
end;

function TScanTab.WarningText: string;
var
  extra: string;

  procedure Add(const S: string);
  begin
    if Result <> '' then Result := Result + LineEnding;
    Result := Result + S;
  end;

begin
  Result := '';
  if FState = scsFailed then
    Add(Format(rsScanFailed, [FFailure]));
  if FState = scsDone then
    case SearchOutcome(FCompletion) of
      soCancelled: Add(rsScanCancelled);
      soPartial: Add(Format(rsScanPartial, [PartialReasons(FCompletion)]));
    end;
  if Finished then
  begin
    extra := CoverageWarning;
    if extra <> '' then Add(extra);
  end;
end;

procedure TScanTab.UpdateView;
begin
  FView.SetTexts(SummaryText, WarningText);
  FRunBtn.Enabled := FState <> scsRunning;
  FStopBtn.Enabled := FState = scsRunning;
  FExportBtn.Enabled := (FState <> scsRunning) and (ExportCount > 0);
end;

procedure TScanTab.ExportClick(Sender: TObject);
var
  sd: TSaveDialog;
  ms: TMemoryStream;
  csv: TCsvWriter;
  n: Int64;
  coverage: string;
begin
  if (FState = scsRunning) or (ExportCount = 0) then Exit;
  sd := TSaveDialog.Create(GetParentForm(Self));
  try
    sd.Filter := 'CSV for spreadsheets (*.csv)|*.csv|All files|*.*';
    sd.DefaultExt := 'csv';
    sd.Options := sd.Options + [ofOverwritePrompt];
    if not sd.Execute then Exit;
    ms := TMemoryStream.Create;
    try
      csv := TCsvWriter.Create(ms, DefaultCsvOptions);
      try
        n := ExportRows(csv);
      finally
        csv.Free;
      end;
      ms.Position := 0;
      SavePrivateStream(sd.FileName, ms);
      if (FState = scsDone) and (SearchOutcome(FCompletion) = soComplete) then
        coverage := rsScanCoverComplete
      else
        coverage := rsScanCoverPartial;
      FCtx.Log(mlInfo, Caption, Format(rsScanExported, [n, sd.FileName, coverage]));
    finally
      ms.Free;
    end;
  finally
    sd.Free;
  end;
end;

end.
