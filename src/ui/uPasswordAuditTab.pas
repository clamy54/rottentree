// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPasswordAuditTab;

{$mode objfpc}{$H+}

// Onglet d'audit du stockage des mots de passe. Le bilan dit combien de mots de passe ont ete
// lus sur combien de comptes: une liste vide rendue par une identite qui n'a pas le droit de
// lire userPassword, c'est un certificat de bonne sante signe par un aveugle.

interface

uses
  Classes, SysUtils, uConnections, uRtCombo, uRtReport, uDirectoryWorker, uSafeOutput,
  uScanTab, uPwdCore, uPasswordAudit;

type
  TPasswordAuditTab = class(TScanTab)
  private
    FThreshold: TRtComboBox;
    FRows: TPwdAuditRows;
    FRowCount: Integer;
    FShown: array of Integer;
    FShownCount: Integer;
    FMatching: Int64;
    FTotals: TPwdAuditTotals;
    FFormats: TPwdAuditFormats;
    function LevelShown: Boolean;
    procedure ThresholdChange(Sender: TObject);
    function Wanted(ALevel: TPwdStorageLevel): Boolean;
    procedure AddShown(AFrom: Integer);
    function BreakdownText: string;
  protected
    function TitleFormat: string; override;
    procedure BuildBarExtras(AView: TRtReportView); override;
    procedure SetupColumns; override;
    procedure ResetResults; override;
    function NewCommand(AConn: TDirectoryConnection;
      const ABases: TStringArray): TWorkerCommand; override;
    procedure Absorb(AMsg: TEntriesMsg); override;
    function ShownCount: Integer; override;
    function Cell(AIndex, ACol: Integer): string; override;
    function DnAt(AIndex: Integer): string; override;
    function SummaryText: string; override;
    function CoverageWarning: string; override;
    function ExportCount: Int64; override;
    function ExportRows(ACsv: TCsvWriter): Int64; override;
  end;

implementation

resourcestring
  rsAuditTitle = 'Password storage - %s';
  rsAuditShow = 'List';
  rsAuditBroken = 'Broken storage only';
  rsAuditWeak = 'Broken and weak storage';
  rsAuditAll = 'Broken, weak and not judged';
  rsAuditColDn = 'DN';
  rsAuditColName = 'Name';
  rsAuditColGiven = 'First name';
  rsAuditColMail = 'Email';
  rsAuditColFormat = 'Password storage';
  rsAuditColLevel = 'Severity';
  rsAuditScanning = 'Scanning %s... %d accounts read, %d with a readable userPassword, %d listed.';
  rsAuditCounts = '%d accounts read under %s, %d with a readable userPassword.';
  rsAuditBreakdown = 'Worst storage per account: %s.';
  rsAuditNothing = 'No account at the selected severity among the passwords read.';
  rsAuditShownCap = 'Showing the first %d of %d listed accounts; sorting covers these only. ' +
    'The CSV export holds all %d.';
  rsAuditListed = '%d accounts listed.';
  rsAuditDropped = '%d more accounts are counted above but not kept: the list stops at %d.';
  rsAuditNoAccounts = 'No account entry was returned: wrong base, or this identity cannot see them.';
  rsAuditNoneReadable = 'NO userPassword COULD BE READ: this identity probably lacks the right to ' +
    'read them. Nothing can be concluded about how passwords are stored.';
  rsAuditSomeUnread = '%d of %d accounts returned no userPassword: unreadable for this identity, ' +
    'or no password at all. The figures cover only the %d others.';

function TPasswordAuditTab.TitleFormat: string;
begin
  Result := rsAuditTitle;
end;

procedure TPasswordAuditTab.BuildBarExtras(AView: TRtReportView);
begin
  FThreshold := AView.AddChoice(rsAuditShow, [rsAuditBroken, rsAuditWeak, rsAuditAll],
    @ThresholdChange, 230);
end;

// Une seule gravite listee: la colonne ne dirait rien.
function TPasswordAuditTab.LevelShown: Boolean;
begin
  Result := FThreshold.ItemIndex > 0;
end;

procedure TPasswordAuditTab.SetupColumns;
begin
  FList.ClearColumns;
  FList.AddColumn(rsAuditColDn, 340);
  FList.AddColumn(rsAuditColName, 130);
  FList.AddColumn(rsAuditColGiven, 110);
  FList.AddColumn(rsAuditColMail, 190);
  FList.AddColumn(rsAuditColFormat, 240);
  if LevelShown then FList.AddColumn(rsAuditColLevel, 80);
  FList.SortBy(FList.SortedColumn, FList.SortedDescending);
end;

function TPasswordAuditTab.Wanted(ALevel: TPwdStorageLevel): Boolean;
begin
  case FThreshold.ItemIndex of
    1: Result := ALevel in [pslBroken, pslWeak];
    2: Result := ALevel in [pslBroken, pslWeak, pslUnknown];
  else
    Result := ALevel = pslBroken;
  end;
end;

procedure TPasswordAuditTab.AddShown(AFrom: Integer);
var
  i: Integer;
begin
  for i := AFrom to FRowCount - 1 do
    if Wanted(FRows[i].Level) then
    begin
      Inc(FMatching);
      if FShownCount < SCAN_SHOWN_MAX then
      begin
        if FShownCount = Length(FShown) then SetLength(FShown, FShownCount + 256);
        FShown[FShownCount] := i;
        Inc(FShownCount);
      end;
    end;
end;

procedure TPasswordAuditTab.ThresholdChange(Sender: TObject);
begin
  SetupColumns;
  FShownCount := 0;
  FMatching := 0;
  AddShown(0);
  ListChanged;
  UpdateView;
end;

procedure TPasswordAuditTab.ResetResults;
begin
  FRows := nil;
  FRowCount := 0;
  FShownCount := 0;
  FMatching := 0;
  FTotals := Default(TPwdAuditTotals);
  FFormats := nil;
end;

function TPasswordAuditTab.NewCommand(AConn: TDirectoryConnection;
  const ABases: TStringArray): TWorkerCommand;
var
  cmd: TPasswordAuditCmd;
begin
  cmd := TPasswordAuditCmd.Create(Self);
  cmd.Bases := ABases;
  cmd.Filter := PwdAuditFilter(AConn.Schema);
  cmd.PageSize := AConn.Profile.PageSize;
  Result := cmd;
end;

procedure TPasswordAuditTab.Absorb(AMsg: TEntriesMsg);
var
  m: TPwdAuditMsg;
  i, first: Integer;
begin
  if not (AMsg is TPwdAuditMsg) then Exit;
  m := TPwdAuditMsg(AMsg);
  first := FRowCount;
  if FRowCount + Length(m.Rows) > Length(FRows) then
    SetLength(FRows, (FRowCount + Length(m.Rows)) * 2);
  for i := 0 to High(m.Rows) do
    FRows[FRowCount + i] := m.Rows[i];
  Inc(FRowCount, Length(m.Rows));
  FTotals := m.Totals;
  FFormats := m.Formats;
  AddShown(first);
end;

function TPasswordAuditTab.ShownCount: Integer;
begin
  Result := FShownCount;
end;

function TPasswordAuditTab.Cell(AIndex, ACol: Integer): string;
begin
  Result := '';
  with FRows[FShown[AIndex]] do
    case ACol of
      0: Result := Dn;
      1: Result := Name;
      2: Result := GivenName;
      3: Result := Mail;
      4: Result := Format;
      5: Result := PwdStorageText(Level);
    end;
end;

function TPasswordAuditTab.DnAt(AIndex: Integer): string;
begin
  Result := FRows[FShown[AIndex]].Dn;
end;

function TPasswordAuditTab.BreakdownText: string;
var
  order: array of Integer;
  i, j, t: Integer;
begin
  Result := '';
  order := nil;
  SetLength(order, Length(FFormats));
  for i := 0 to High(order) do
    order[i] := i;
  // Du plus inquietant au moins inquietant, puis du plus frequent au plus rare.
  for i := 1 to High(order) do
  begin
    t := order[i];
    j := i - 1;
    while (j >= 0) and
      ((PwdAuditRank(FFormats[order[j]].Level) > PwdAuditRank(FFormats[t].Level)) or
       ((PwdAuditRank(FFormats[order[j]].Level) = PwdAuditRank(FFormats[t].Level)) and
        (FFormats[order[j]].Count < FFormats[t].Count))) do
    begin
      order[j + 1] := order[j];
      Dec(j);
    end;
    order[j + 1] := t;
  end;
  for i := 0 to High(order) do
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + SysUtils.Format('%d x %s [%s]', [FFormats[order[i]].Count,
      FFormats[order[i]].Name, PwdStorageText(FFormats[order[i]].Level)]);
  end;
end;

function TPasswordAuditTab.SummaryText: string;
begin
  Result := '';
  if FState = scsRunning then
    Exit(SysUtils.Format(rsAuditScanning, [FBases, FTotals.Accounts, FTotals.Readable,
      FMatching]));
  if not Finished or (FTotals.Accounts = 0) then Exit;
  Result := SysUtils.Format(rsAuditCounts, [FTotals.Accounts, FBases, FTotals.Readable]);
  if Length(FFormats) > 0 then
    Result := Result + LineEnding + SysUtils.Format(rsAuditBreakdown, [BreakdownText]);
  if FTotals.Readable > 0 then
    if FMatching = 0 then
      Result := Result + LineEnding + rsAuditNothing
    else if FMatching > FShownCount then
      Result := Result + LineEnding + SysUtils.Format(rsAuditShownCap, [FShownCount, FMatching,
        FMatching])
    else
      Result := Result + LineEnding + SysUtils.Format(rsAuditListed, [FMatching]);
  if FTotals.Dropped > 0 then
    Result := Result + LineEnding + SysUtils.Format(rsAuditDropped, [FTotals.Dropped,
      PWD_AUDIT_KEEP_MAX]);
end;

function TPasswordAuditTab.CoverageWarning: string;
begin
  Result := '';
  if FTotals.Accounts = 0 then
  begin
    // Un echec avant la premiere entree a deja son message.
    if FState = scsDone then Result := rsAuditNoAccounts;
  end
  else if FTotals.Readable = 0 then
    Result := rsAuditNoneReadable
  else if FTotals.Readable < FTotals.Accounts then
    Result := SysUtils.Format(rsAuditSomeUnread, [FTotals.Accounts - FTotals.Readable,
      FTotals.Accounts, FTotals.Readable]);
end;

function TPasswordAuditTab.ExportCount: Int64;
begin
  Result := FMatching;
end;

function TPasswordAuditTab.ExportRows(ACsv: TCsvWriter): Int64;
var
  i: Integer;
begin
  ACsv.AddCell('dn');
  ACsv.AddCell('name');
  ACsv.AddCell('givenName');
  ACsv.AddCell('mail');
  ACsv.AddCell('passwordStorage');
  if LevelShown then ACsv.AddCell('severity');
  ACsv.EndRow;
  Result := 0;
  for i := 0 to FRowCount - 1 do
    if Wanted(FRows[i].Level) then
    begin
      ACsv.AddCell(FRows[i].Dn);
      ACsv.AddCell(FRows[i].Name);
      ACsv.AddCell(FRows[i].GivenName);
      ACsv.AddCell(FRows[i].Mail);
      ACsv.AddCell(FRows[i].Format);
      if LevelShown then ACsv.AddCell(PwdStorageText(FRows[i].Level));
      ACsv.EndRow;
      Inc(Result);
    end;
end;

end.
