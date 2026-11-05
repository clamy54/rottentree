// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uGroupMemberTab;

{$mode objfpc}{$H+}

// Onglet des membres de groupes: les valeurs member, uniqueMember et memberUid qui contiennent
// un texte, ou celles qui pointent vers une entree disparue. Une ligne par valeur, le groupe a
// ouvrir d'un double-clic: c'est lui qu'il faut corriger, le compte n'existe plus.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, LCLType, uConnections, uRtCombo, uRtReport,
  uDirectoryWorker, uSafeOutput, uScanTab, uGroupMembers;

type
  TGroupMemberTab = class(TScanTab)
  private
    FModeBox: TRtComboBox;
    FTextEdit: TEdit;
    FRows: TGroupMemberRows;
    FTotals: TGroupMemberTotals;
    FRunMode: TMemberMode;
    FRunText: string;
    function Mode: TMemberMode;
    function ModeVerb(AMode: TMemberMode): string;
    procedure ModeChange(Sender: TObject);
    procedure TextKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  protected
    function TitleFormat: string; override;
    procedure BuildBarExtras(AView: TRtReportView); override;
    procedure SetupColumns; override;
    procedure ResetResults; override;
    function NotReady: string; override;
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
  rsGmTitle = 'Group members - %s';
  rsGmFind = 'Find';
  rsGmModeGone = 'Members whose entry is not found';
  rsGmModeContains = 'Member value contains';
  rsGmModeStarts = 'Member value starts with';
  rsGmModeEnds = 'Member value ends with';
  rsGmModeEquals = 'Member value is the DN';
  rsGmText = 'Text';
  rsGmTextHint = 'uid, name or DN';
  rsGmColGroup = 'Group';
  rsGmColAttr = 'Attribute';
  rsGmColValue = 'Member value';
  rsGmColState = 'Entry';
  rsGmStateExists = 'exists';
  rsGmStateGone = 'NOT FOUND';
  rsGmStateUnchecked = 'not checked';
  rsGmStateNotDn = 'account name, not checked';
  rsGmVerbContains = 'containing';
  rsGmVerbStarts = 'starting with';
  rsGmVerbEnds = 'ending with';
  rsGmVerbEquals = 'equal to';
  rsGmNeedText = 'Type a text, then press Enter or Scan again.';
  rsGmListing = 'Listing the entries under %s... %d read.';
  rsGmReading = 'Reading the groups under %s... %d groups, %d member values.';
  rsGmChecking = 'Checking whether the member entries still exist... %d read.';
  rsGmCounts = '%d groups read under %s, %d member values.';
  rsGmNoGone = 'Every member points to an entry this identity can find.';
  rsGmGone = '%d member values point to entries the server says do not exist, in %d groups. ' +
    'Double-click a line to open the group.';
  rsGmNoMatch = 'No member value %s "%s".';
  rsGmMatches = '%d member values %s "%s", in %d groups; for %d of them the server says the ' +
    'entry does not exist.';
  rsGmUnchecked = '%d could not be checked: outside the bases read, access refused, or more ' +
    'than %d distinct entries to read one by one.';
  rsGmCaveat = 'NOT FOUND means deleted, or hidden from this identity by an access rule: ' +
    'check with an administrative account before removing the membership.';
  rsGmShownCap = 'Showing the first %d of %d lines; sorting covers these only. The CSV export ' +
    'holds all %d.';
  rsGmListingPartial = 'The listing of the entries was incomplete: more members had to be ' +
    'read one by one, and those beyond the reading limit are shown as not checked.';
  rsGmOverflow = 'More than %d values matched: the rest was counted but not listed.';
  rsGmNoGroups = 'No group with members was returned: wrong base, or this identity cannot ' +
    'read the member attributes.';

function TGroupMemberTab.TitleFormat: string;
begin
  Result := rsGmTitle;
end;

procedure TGroupMemberTab.BuildBarExtras(AView: TRtReportView);
begin
  // Le premier pose est le plus a droite: le texte apres le mode, dans l'ordre de lecture.
  FTextEdit := AView.AddEdit(rsGmText, rsGmTextHint, 220);
  FTextEdit.OnKeyDown := @TextKeyDown;
  FTextEdit.Enabled := False;
  FModeBox := AView.AddChoice(rsGmFind, [rsGmModeGone, rsGmModeContains, rsGmModeStarts,
    rsGmModeEnds, rsGmModeEquals], @ModeChange, 230);
end;

function TGroupMemberTab.Mode: TMemberMode;
begin
  case FModeBox.ItemIndex of
    1: Result := mmContains;
    2: Result := mmStarts;
    3: Result := mmEnds;
    4: Result := mmEquals;
  else
    Result := mmGone;
  end;
end;

function TGroupMemberTab.ModeVerb(AMode: TMemberMode): string;
begin
  case AMode of
    mmStarts: Result := rsGmVerbStarts;
    mmEnds: Result := rsGmVerbEnds;
    mmEquals: Result := rsGmVerbEquals;
  else
    Result := rsGmVerbContains;
  end;
end;

procedure TGroupMemberTab.ModeChange(Sender: TObject);
begin
  FTextEdit.Enabled := Mode <> mmGone;
  if FTextEdit.Enabled and FTextEdit.CanFocus then FTextEdit.SetFocus;
  Restart;
end;

procedure TGroupMemberTab.TextKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key <> VK_RETURN then Exit;
  Key := 0;
  Restart;
end;

procedure TGroupMemberTab.SetupColumns;
begin
  FList.ClearColumns;
  FList.AddColumn(rsGmColGroup, 300);
  FList.AddColumn(rsGmColAttr, 100);
  FList.AddColumn(rsGmColValue, 420);
  FList.AddColumn(rsGmColState, 150);
end;

procedure TGroupMemberTab.ResetResults;
begin
  FRows := nil;
  FTotals := Default(TGroupMemberTotals);
end;

function TGroupMemberTab.NotReady: string;
begin
  Result := '';
  if (Mode <> mmGone) and (Trim(FTextEdit.Text) = '') then Result := rsGmNeedText;
end;

function TGroupMemberTab.NewCommand(AConn: TDirectoryConnection;
  const ABases: TStringArray): TWorkerCommand;
var
  cmd: TGroupMemberCmd;
begin
  cmd := TGroupMemberCmd.Create(Self);
  cmd.Bases := ABases;
  cmd.PageSize := AConn.Profile.PageSize;
  cmd.Mode := Mode;
  cmd.Text := Trim(FTextEdit.Text);
  cmd.Attributes := GroupMemberAttrs(AConn.Schema,
    EffectiveServerKind(AConn.Profile, AConn.RootDse) = pkActiveDirectory);
  cmd.Filter := GroupMemberFilter(cmd.Attributes);
  // Le bilan decrit ce qui a ete cherche, pas ce que le champ contient depuis.
  FRunMode := cmd.Mode;
  FRunText := cmd.Text;
  Result := cmd;
end;

procedure TGroupMemberTab.Absorb(AMsg: TEntriesMsg);
var
  m: TGroupMemberMsg;
begin
  if not (AMsg is TGroupMemberMsg) then Exit;
  m := TGroupMemberMsg(AMsg);
  FTotals := m.Totals;
  if m.Final then FRows := m.Rows;
end;

function TGroupMemberTab.ShownCount: Integer;
begin
  Result := Length(FRows);
  if Result > SCAN_SHOWN_MAX then Result := SCAN_SHOWN_MAX;
end;

function StateText(AState: TMemberState): string;
begin
  case AState of
    msExists: Result := rsGmStateExists;
    msNotFound: Result := rsGmStateGone;
    msNotDn: Result := rsGmStateNotDn;
  else
    Result := rsGmStateUnchecked;
  end;
end;

function TGroupMemberTab.Cell(AIndex, ACol: Integer): string;
begin
  case ACol of
    0: Result := FRows[AIndex].GroupDn;
    1: Result := FRows[AIndex].Attr;
    2: Result := FRows[AIndex].Value;
    3: Result := StateText(FRows[AIndex].State);
  else
    Result := '';
  end;
end;

function TGroupMemberTab.DnAt(AIndex: Integer): string;
begin
  Result := FRows[AIndex].GroupDn;
end;

function TGroupMemberTab.SummaryText: string;

  procedure Add(const S: string);
  begin
    if Result <> '' then Result := Result + LineEnding;
    Result := Result + S;
  end;

begin
  Result := '';
  if FState = scsIdle then
    Exit(NotReady);
  if FState = scsRunning then
    case FTotals.Phase of
      mpListing: Exit(Format(rsGmListing, [FBases, FTotals.Listed]));
      mpChecking: Exit(Format(rsGmChecking, [FTotals.Checked]));
    else
      Exit(Format(rsGmReading, [FBases, FTotals.Groups, FTotals.Values]));
    end;
  if not Finished or (FTotals.Groups = 0) then Exit;
  Add(Format(rsGmCounts, [FTotals.Groups, FBases, FTotals.Values]));
  if FRunMode = mmGone then
  begin
    if Length(FRows) = 0 then
      Add(rsGmNoGone)
    else
      Add(Format(rsGmGone, [FTotals.Gone, FTotals.MatchGroups]));
  end
  else if FTotals.Matches = 0 then
    Add(Format(rsGmNoMatch, [ModeVerb(FRunMode), FRunText]))
  else
    Add(Format(rsGmMatches, [FTotals.Matches, ModeVerb(FRunMode), FRunText,
      FTotals.MatchGroups, FTotals.Gone]));
  if FTotals.Unchecked > 0 then
    Add(Format(rsGmUnchecked, [FTotals.Unchecked, GROUP_MEMBER_READ_MAX]));
  if FTotals.Gone > 0 then
    Add(rsGmCaveat);
  if Length(FRows) > ShownCount then
    Add(Format(rsGmShownCap, [ShownCount, Length(FRows), Length(FRows)]));
end;

function TGroupMemberTab.CoverageWarning: string;
begin
  Result := '';
  if FTotals.ListingPartial then
    Result := rsGmListingPartial;
  if FTotals.Overflow then
  begin
    if Result <> '' then Result := Result + LineEnding;
    Result := Result + Format(rsGmOverflow, [GROUP_MEMBER_KEEP_MAX]);
  end;
  // Un echec avant la premiere entree a deja son message.
  if (Result = '') and (FTotals.Groups = 0) and (FState = scsDone) then
    Result := rsGmNoGroups;
end;

function TGroupMemberTab.ExportCount: Int64;
begin
  Result := Length(FRows);
end;

function TGroupMemberTab.ExportRows(ACsv: TCsvWriter): Int64;
var
  i: Integer;
begin
  ACsv.AddCell('group');
  ACsv.AddCell('attribute');
  ACsv.AddCell('value');
  ACsv.AddCell('entry');
  ACsv.EndRow;
  Result := 0;
  for i := 0 to High(FRows) do
  begin
    ACsv.AddCell(FRows[i].GroupDn);
    ACsv.AddCell(FRows[i].Attr);
    ACsv.AddCell(FRows[i].Value);
    ACsv.AddCell(StateText(FRows[i].State));
    ACsv.EndRow;
    Inc(Result);
  end;
end;

end.
