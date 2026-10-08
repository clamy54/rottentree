// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uHomonymTab;

{$mode objfpc}{$H+}

// Onglet des homonymes: les comptes au meme nom et au meme prenom, groupe par groupe, avec ce
// qui les distingue encore ou ne les distingue plus. Un login ou un mail absent n'est pas un
// conflit, c'est une verification qui n'a pas eu lieu: l'etat le dit au lieu d'afficher un
// "distincts" de complaisance.

interface

uses
  Classes, SysUtils, uConnections, uRtCombo, uRtReport, uDirectoryWorker, uSafeOutput, uScanTab,
  uHomonyms;

type
  THomonymTab = class(TScanTab)
  private
    FFilter: TRtComboBox;
    FRows: THomonymRows;
    FShown: array of Integer;
    FShownCount: Integer;
    FMatching: Int64;
    FTotals: THomonymTotals;
    function Wanted(const ARow: THomonymRow): Boolean;
    procedure RebuildShown;
    procedure FilterChange(Sender: TObject);
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
  uConnectionProfile, uServerKind, uDirectoryScan;

resourcestring
  rsHomTitle = 'Homonyms - %s';
  rsHomShow = 'List';
  rsHomAll = 'All homonyms';
  rsHomConflicts = 'Conflicts only';
  rsHomColName = 'Name';
  rsHomColGiven = 'First name';
  rsHomColShared = 'Accounts';
  rsHomColLogin = 'Login';
  rsHomColMail = 'Email';
  rsHomColStatus = 'Status';
  rsHomColDn = 'DN';
  rsHomSameBoth = 'same login and email';
  rsHomSameLogin = 'same login';
  rsHomSameMail = 'same email';
  rsHomNoBoth = 'not checked: no login, no email';
  rsHomNoLogin = 'not checked: no login';
  rsHomNoMail = 'not checked: no email';
  rsHomDistinct = 'distinct';
  rsHomScanning = 'Scanning %s... %d accounts read.';
  rsHomCounts = '%d accounts read under %s.';
  rsHomUnnamed = '%d of them have no name or no first name and were left out.';
  rsHomGroups = '%d groups of homonyms, %d accounts: %d groups share a login, %d share an email ' +
    'address, %d could not be fully checked (login or email missing).';
  rsHomNone = 'No homonyms among the accounts read.';
  rsHomNoConflict = 'No homonyms share a login or an email address.';
  rsHomShownCap = 'Showing the first %d of %d lines; sorting covers these only. The CSV export ' +
    'holds all %d.';
  rsHomNoAccounts = 'No account entry was returned: wrong base, or this identity cannot see them.';
  rsHomOverflow = 'More than %d accounts: the rest was not compared, homonyms may be missing.';

function StatusText(const R: THomonymRow): string;
begin
  if R.SameLogin and R.SameMail then Result := rsHomSameBoth
  else if R.SameLogin then Result := rsHomSameLogin
  else if R.SameMail then Result := rsHomSameMail
  else if (R.Login = '') and (Length(R.Mails) = 0) then Result := rsHomNoBoth
  else if R.Login = '' then Result := rsHomNoLogin
  else if Length(R.Mails) = 0 then Result := rsHomNoMail
  else Result := rsHomDistinct;
end;

function MailText(const R: THomonymRow): string;
begin
  Result := string.Join(', ', R.Mails);
end;

function THomonymTab.TitleFormat: string;
begin
  Result := rsHomTitle;
end;

procedure THomonymTab.BuildBarExtras(AView: TRtReportView);
begin
  FFilter := AView.AddChoice(rsHomShow, [rsHomAll, rsHomConflicts], @FilterChange, 170);
end;

procedure THomonymTab.SetupColumns;
begin
  FList.ClearColumns;
  FList.AddColumn(rsHomColName, 130);
  FList.AddColumn(rsHomColGiven, 110);
  FList.AddColumn(rsHomColShared, 70);
  FList.AddColumn(rsHomColLogin, 120);
  FList.AddColumn(rsHomColMail, 200);
  FList.AddColumn(rsHomColStatus, 190);
  FList.AddColumn(rsHomColDn, 320);
end;

// Un groupe en conflit se montre en entier: celui qui partage et celui avec qui il partage.
function THomonymTab.Wanted(const ARow: THomonymRow): Boolean;
begin
  Result := (FFilter.ItemIndex = 0) or ARow.GroupConflict;
end;

procedure THomonymTab.RebuildShown;
var
  i: Integer;
begin
  FShownCount := 0;
  FMatching := 0;
  for i := 0 to High(FRows) do
    if Wanted(FRows[i]) then
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

procedure THomonymTab.FilterChange(Sender: TObject);
begin
  RebuildShown;
  ListChanged;
  UpdateView;
end;

procedure THomonymTab.ResetResults;
begin
  FRows := nil;
  FShownCount := 0;
  FMatching := 0;
  FTotals := Default(THomonymTotals);
end;

function THomonymTab.NewCommand(AConn: TDirectoryConnection;
  const ABases: TStringArray): TWorkerCommand;
var
  cmd: THomonymCmd;
  terms: string;
begin
  cmd := THomonymCmd.Create(Self);
  cmd.Bases := ABases;
  cmd.PageSize := AConn.Profile.PageSize;
  if EffectiveServerKind(AConn.Profile, AConn.RootDse) = pkActiveDirectory then
  begin
    // objectClass=user seul ramenerait aussi les comptes d'ordinateur, qui n'ont pas de prenom
    // mais beaucoup de cousins.
    cmd.Filter := '(&(objectCategory=person)(objectClass=user))';
    cmd.LoginAttr := 'sAMAccountName';
  end
  else
  begin
    terms := AccountClassTerms(AConn.Schema);
    if terms = '' then
      cmd.Filter := '(&(sn=*)(givenName=*))'
    else
      cmd.Filter := '(|' + terms + ')';
    cmd.LoginAttr := 'uid';
  end;
  Result := cmd;
end;

procedure THomonymTab.Absorb(AMsg: TEntriesMsg);
var
  m: THomonymMsg;
begin
  if not (AMsg is THomonymMsg) then Exit;
  m := THomonymMsg(AMsg);
  FTotals := m.Totals;
  // Avant le dernier lot il n'y a qu'un compteur: les groupes n'existent qu'une fois tout lu.
  if m.Final then
  begin
    FRows := m.Rows;
    RebuildShown;
  end;
end;

function THomonymTab.ShownCount: Integer;
begin
  Result := FShownCount;
end;

function THomonymTab.Cell(AIndex, ACol: Integer): string;
begin
  Result := '';
  with FRows[FShown[AIndex]] do
    case ACol of
      0: Result := Name;
      1: Result := GivenName;
      2: Result := IntToStr(Shared);
      3: Result := Login;
      4: Result := MailText(FRows[FShown[AIndex]]);
      5: Result := StatusText(FRows[FShown[AIndex]]);
      6: Result := Dn;
    end;
end;

function THomonymTab.DnAt(AIndex: Integer): string;
begin
  Result := FRows[FShown[AIndex]].Dn;
end;

function THomonymTab.SummaryText: string;
begin
  Result := '';
  if FState = scsRunning then
    Exit(Format(rsHomScanning, [FBases, FTotals.Accounts]));
  if not Finished or (FTotals.Accounts = 0) then Exit;
  Result := Format(rsHomCounts, [FTotals.Accounts, FBases]);
  if FTotals.Unnamed > 0 then
    Result := Result + ' ' + Format(rsHomUnnamed, [FTotals.Unnamed]);
  if FTotals.Groups = 0 then
    Exit(Result + LineEnding + rsHomNone);
  Result := Result + LineEnding + Format(rsHomGroups, [FTotals.Groups, FTotals.GroupAccounts,
    FTotals.LoginGroups, FTotals.MailGroups, FTotals.UncheckedGroups]);
  if FMatching = 0 then
    Result := Result + LineEnding + rsHomNoConflict
  else if FMatching > FShownCount then
    Result := Result + LineEnding + Format(rsHomShownCap, [FShownCount, FMatching, FMatching]);
end;

function THomonymTab.CoverageWarning: string;
begin
  Result := '';
  if FTotals.Overflow then
    Result := Format(rsHomOverflow, [HOMONYM_SCAN_MAX])
  // Un echec avant la premiere entree a deja son message.
  else if (FTotals.Accounts = 0) and (FState = scsDone) then
    Result := rsHomNoAccounts;
end;

function THomonymTab.ExportCount: Int64;
begin
  Result := FMatching;
end;

function THomonymTab.ExportRows(ACsv: TCsvWriter): Int64;
var
  i: Integer;
begin
  ACsv.AddCell('name');
  ACsv.AddCell('givenName');
  ACsv.AddCell('accounts');
  ACsv.AddCell('login');
  ACsv.AddCell('mail');
  ACsv.AddCell('status');
  ACsv.AddCell('dn');
  ACsv.EndRow;
  Result := 0;
  for i := 0 to High(FRows) do
    if Wanted(FRows[i]) then
    begin
      ACsv.AddCell(FRows[i].Name);
      ACsv.AddCell(FRows[i].GivenName);
      ACsv.AddCell(IntToStr(FRows[i].Shared));
      ACsv.AddCell(FRows[i].Login);
      ACsv.AddCell(MailText(FRows[i]));
      ACsv.AddCell(StatusText(FRows[i]));
      ACsv.AddCell(FRows[i].Dn);
      ACsv.EndRow;
      Inc(Result);
    end;
end;

end.
