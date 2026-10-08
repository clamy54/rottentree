// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDuplicateIdTab;

{$mode objfpc}{$H+}

// Onglet des identifiants partages (uidNumber, login, mail), ranges par valeur. "Aucun doublon"
// ne vaut que pour ce qui a ete lu: un parcours partiel le dit, il n'est pas la pour rassurer.

interface

uses
  Classes, SysUtils, uConnections, uRtCombo, uRtReport, uDirectoryWorker, uSafeOutput, uScanTab,
  uDuplicateIds;

type
  TDupIdKind = (dkUidNumber, dkLogin, dkMail);
  TDupIdColumn = (dcValue, dcShared, dcDn, dcLogin, dcName, dcGiven, dcMail);

  TDuplicateIdTab = class(TScanTab)
  private
    FKindBox: TRtComboBox;
    FCols: array of TDupIdColumn;
    FLoginAttr: string;
    FRows: TDupIdRows;
    FTotals: TDupIdTotals;
    function Kind: TDupIdKind;
    function KindLabel: string;
    function ScannedAttribute: string;
    function ColumnText(const ARow: TDupIdRow; ACol: TDupIdColumn): string;
    procedure KindChange(Sender: TObject);
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

uses
  uConnectionProfile, uServerKind;

resourcestring
  rsDupTitle = 'Duplicate identifiers - %s';
  rsDupKind = 'Identifier';
  rsDupKindUidNumber = 'uidNumber';
  rsDupKindLogin = 'Login';
  rsDupKindMail = 'Email address';
  rsDupColShared = 'Entries';
  rsDupColDn = 'DN';
  rsDupColLogin = 'Login';
  rsDupColName = 'Name';
  rsDupColGiven = 'First name';
  rsDupColMail = 'Email';
  rsDupScanning = 'Scanning %s... %d entries with a value read (%s).';
  rsDupCounts = '%s: %d entries with a value read under %s, %d distinct values.';
  rsDupShared = '%d values are shared by %d entries, grouped below by value.';
  rsDupNone = 'No value is shared among the entries read.';
  rsDupShownCap = 'Showing the first %d of %d lines; sorting covers these only. The CSV export ' +
    'holds all %d.';
  rsDupNoEntries = 'No entry with this identifier was returned: wrong base, attribute not used ' +
    'here, or this identity cannot read it.';
  rsDupOverflow = 'More than %d entries: the rest was not compared, shared values may be missing.';

function TDuplicateIdTab.TitleFormat: string;
begin
  Result := rsDupTitle;
end;

procedure TDuplicateIdTab.BuildBarExtras(AView: TRtReportView);
begin
  FKindBox := AView.AddChoice(rsDupKind, [rsDupKindUidNumber, rsDupKindLogin, rsDupKindMail],
    @KindChange, 170);
end;

function TDuplicateIdTab.Kind: TDupIdKind;
begin
  case FKindBox.ItemIndex of
    1: Result := dkLogin;
    2: Result := dkMail;
  else
    Result := dkUidNumber;
  end;
end;

function TDuplicateIdTab.KindLabel: string;
begin
  case Kind of
    dkLogin: Result := rsDupKindLogin;
    dkMail: Result := rsDupKindMail;
  else
    Result := rsDupKindUidNumber;
  end;
end;

function TDuplicateIdTab.ScannedAttribute: string;
begin
  case Kind of
    dkLogin: Result := FLoginAttr;
    dkMail: Result := 'mail';
  else
    Result := 'uidNumber';
  end;
end;

procedure TDuplicateIdTab.KindChange(Sender: TObject);
begin
  SetupColumns;
  Restart;
end;

// La colonne de l'identifiant compare passe en tete; elle ne revient pas plus loin.
procedure TDuplicateIdTab.SetupColumns;

  procedure Add(ACol: TDupIdColumn; const ACaption: string; AWidth: Integer);
  begin
    SetLength(FCols, Length(FCols) + 1);
    FCols[High(FCols)] := ACol;
    FList.AddColumn(ACaption, AWidth);
  end;

begin
  FCols := nil;
  FList.ClearColumns;
  Add(dcValue, KindLabel, 170);
  Add(dcShared, rsDupColShared, 70);
  Add(dcDn, rsDupColDn, 340);
  if Kind <> dkLogin then Add(dcLogin, rsDupColLogin, 110);
  Add(dcName, rsDupColName, 130);
  Add(dcGiven, rsDupColGiven, 110);
  if Kind <> dkMail then Add(dcMail, rsDupColMail, 190);
  FList.SortBy(-1, False);
end;

procedure TDuplicateIdTab.ResetResults;
begin
  FRows := nil;
  FTotals := Default(TDupIdTotals);
end;

function TDuplicateIdTab.NewCommand(AConn: TDirectoryConnection;
  const ABases: TStringArray): TWorkerCommand;
var
  cmd: TDuplicateIdCmd;
begin
  if EffectiveServerKind(AConn.Profile, AConn.RootDse) = pkActiveDirectory then
    FLoginAttr := 'sAMAccountName'
  else
    FLoginAttr := 'uid';
  cmd := TDuplicateIdCmd.Create(Self);
  cmd.Bases := ABases;
  cmd.Attribute := ScannedAttribute;
  cmd.LoginAttr := FLoginAttr;
  cmd.Numeric := Kind = dkUidNumber;
  cmd.PageSize := AConn.Profile.PageSize;
  Result := cmd;
end;

procedure TDuplicateIdTab.Absorb(AMsg: TEntriesMsg);
var
  m: TDupIdMsg;
begin
  if not (AMsg is TDupIdMsg) then Exit;
  m := TDupIdMsg(AMsg);
  FTotals := m.Totals;
  // Avant le dernier lot il n'y a qu'un compteur: les groupes n'existent qu'une fois tout lu.
  if m.Final then FRows := m.Rows;
end;

function TDuplicateIdTab.ShownCount: Integer;
begin
  Result := Length(FRows);
  if Result > SCAN_SHOWN_MAX then Result := SCAN_SHOWN_MAX;
end;

function TDuplicateIdTab.ColumnText(const ARow: TDupIdRow; ACol: TDupIdColumn): string;
begin
  case ACol of
    dcValue: Result := ARow.Id;
    dcShared: Result := IntToStr(ARow.Shared);
    dcDn: Result := ARow.Dn;
    dcLogin: Result := ARow.Login;
    dcName: Result := ARow.Name;
    dcGiven: Result := ARow.GivenName;
  else
    Result := ARow.Mail;
  end;
end;

function TDuplicateIdTab.Cell(AIndex, ACol: Integer): string;
begin
  if (ACol < 0) or (ACol > High(FCols)) then Exit('');
  Result := ColumnText(FRows[AIndex], FCols[ACol]);
end;

function TDuplicateIdTab.DnAt(AIndex: Integer): string;
begin
  Result := FRows[AIndex].Dn;
end;

function TDuplicateIdTab.SummaryText: string;
begin
  Result := '';
  if FState = scsRunning then
    Exit(Format(rsDupScanning, [FBases, FTotals.Entries, KindLabel]));
  if not Finished or (FTotals.Entries = 0) then Exit;
  Result := Format(rsDupCounts, [KindLabel, FTotals.Entries, FBases, FTotals.Distinct]);
  if FTotals.SharedIds = 0 then
    Result := Result + LineEnding + rsDupNone
  else
    Result := Result + LineEnding + Format(rsDupShared, [FTotals.SharedIds,
      FTotals.SharedEntries]);
  if Length(FRows) > ShownCount then
    Result := Result + LineEnding + Format(rsDupShownCap, [ShownCount, Length(FRows),
      Length(FRows)]);
end;

function TDuplicateIdTab.CoverageWarning: string;
begin
  Result := '';
  if FTotals.Overflow then
    Result := Format(rsDupOverflow, [DUP_ID_SCAN_MAX])
  // Un echec avant la premiere entree a deja son message.
  else if (FTotals.Entries = 0) and (FState = scsDone) then
    Result := rsDupNoEntries;
end;

function TDuplicateIdTab.ExportCount: Int64;
begin
  Result := Length(FRows);
end;

function TDuplicateIdTab.ExportRows(ACsv: TCsvWriter): Int64;
const
  HEADERS: array[TDupIdColumn] of string = ('', 'entries', 'dn', 'login', 'name', 'givenName',
    'mail');
var
  i, c: Integer;
begin
  for c := 0 to High(FCols) do
    if FCols[c] = dcValue then
      ACsv.AddCell(ScannedAttribute)
    else
      ACsv.AddCell(HEADERS[FCols[c]]);
  ACsv.EndRow;
  for i := 0 to High(FRows) do
  begin
    for c := 0 to High(FCols) do
      ACsv.AddCell(ColumnText(FRows[i], FCols[c]));
    ACsv.EndRow;
  end;
  Result := Length(FRows);
end;

end.
