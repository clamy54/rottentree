// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uEntryPickDialog;

{$mode objfpc}{$H+}

// Choix d'une entree (membre de groupe), facon selecteur d'utilisateurs Windows: un DN complet
// se tape, un bout de nom, d'uid ou de mail se cherche sous la base du profil. Rien n'est ecrit
// ici, l'appelant recoit un DN ou la valeur d'un attribut.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Buttons, Forms, Graphics, LCLType,
  uAppContext, uOpsDialog, uDirectoryWorker, uRtList, uConnectionProfile;

type
  TEntryPickDialog = class(TOpsDialog)
  private
    FBase: string;
    FValueAttr: string;
    FEdit: TEdit;
    FSearchBtn: TBitBtn;
    FList: TRtListGrid;
    FRowDns, FRowValues: TStringList;
    FFound: TList;
    // Active Directory: recherche par debut de valeur d'abord (indexee, rapide), puis n'importe ou
    // dans la valeur (non indexee, lente) pour completer la liste, sans doublon.
    FWideText: string;
    FWide: Boolean;
    FServer: TProviderKind;
    FAttrs: array of string;
    FPicked: string;
    FResult: string;
    procedure SearchClick(Sender: TObject);
    procedure EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ListSelect(Sender: TObject; AIndex: Integer);
    procedure ListActivate(Sender: TObject; AIndex: Integer);
    procedure OkClick(Sender: TObject);
    procedure ClearFound;
    procedure ShowFound(const ANote: string);
    function HasFound(const ADn: string): Boolean;
  protected
    procedure OnEntries(AMsg: TEntriesMsg); override;
  public
    constructor CreatePicker(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
      ACaption, APrompt, ABase, AValueAttr: string);
    destructor Destroy; override;
    procedure SetEntered(const AText: string);
    function Entered: string;
    procedure RunSearch;
    function SearchTask: Int64;
    function ResultDns: string;
    function ChooseDn(const ADn: string): Boolean;
    function StatusText: string;
    function Accept: Boolean;
    property Value: string read FResult;
  end;

  TEntryPickOverride = function(ADialog: TEntryPickDialog): TModalResult;

var
  EntryPickOverride: TEntryPickOverride = nil;

function PickDirectoryEntry(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  ACaption, APrompt, ABase, AValueAttr: string; var AValue: string): Boolean;

implementation

uses
  uUiKit, uIcons, uConnections, uServerKind, uSearchModel, uLdapEntry,
  uEntryLookup, uDirectoryService, uLdapErrors, uGroupModel, uTaskDialog;

resourcestring
  rsEpHelp = 'Type a full DN, or part of a name, uid or mail (or attr=value), then click the ' +
    'magnifier or press Enter to search under %s. Double click a result to choose it.';
  rsEpHelpAd = 'Type a full DN, or part of a name, account or mail (or attr=value), then click the ' +
    'magnifier or press Enter to search under %s: names that begin with it first, then (3 characters ' +
    'or more) anywhere in the value, slower on a large domain. Double click a result to choose it.';
  rsEpWidening = '%d found so far; searching anywhere in the value...';
  rsEpNotDn = '"%s" is not a DN: choose an entry in the list, or type a full DN.';
  rsEpNoBase = 'Type the full DN (no search base is known for this profile).';
  rsEpTimeLimit = 'Time limit reached, partial list: type more to narrow the search.';
  rsEpSearchHint = 'Search the directory';
  rsEpColEntry = 'Entry';
  rsEpColDn = 'DN';
  rsEpSearching = 'Searching...';
  rsEpFound = '%d entries found.';
  rsEpOne = 'One entry found.';
  rsEpNone = 'No entry found.';
  rsEpMore = 'First %d entries only: type more to narrow the search.';
  rsEpPartial = 'Partial result: %s';
  rsEpEmpty = 'Type part of a name, uid or mail, or a full DN.';
  rsEpNoValue = 'This entry has no %s value.';
  rsEpOk = 'OK';
  rsEpCancel = 'Cancel';

function PickDirectoryEntry(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
  ACaption, APrompt, ABase, AValueAttr: string; var AValue: string): Boolean;
var
  d: TEntryPickDialog;
  r: TModalResult;
begin
  d := TEntryPickDialog.CreatePicker(AOwner, ACtx, AProfileUuid, ACaption, APrompt, ABase, AValueAttr);
  try
    d.SetEntered(AValue);
    if Assigned(EntryPickOverride) then r := EntryPickOverride(d)
    else r := d.ShowModal;
    Result := (r = mrOk) and (d.Value <> '');
    if Result then AValue := d.Value;
  finally
    d.Free;
  end;
end;

constructor TEntryPickDialog.CreatePicker(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, ACaption, APrompt, ABase, AValueAttr: string);
var
  lbl: TLabel;
  row: TPanel;
  glyph: TBitmap;
  ok: TButton;
  c: TDirectoryConnection;
  help: string;
begin
  inherited CreateFor(AOwner, ACtx, AProfileUuid, ACaption, 820, 560);
  SetIcon('search');
  FBase := ABase;
  FValueAttr := AValueAttr;
  FRowDns := TStringList.Create;
  FRowValues := TStringList.Create;
  FFound := TList.Create;
  MakeLabel(Body, APrompt);
  row := MakePanel(Body, alTop, 30);
  row.BorderSpacing.Top := 4;
  FSearchBtn := TBitBtn.Create(row);
  FSearchBtn.Parent := row;
  FSearchBtn.Align := alRight;
  FSearchBtn.Width := 36;
  FSearchBtn.BorderSpacing.Left := 4;
  FSearchBtn.Hint := rsEpSearchHint;
  FSearchBtn.ShowHint := True;
  FSearchBtn.OnClick := @SearchClick;
  glyph := LoadIconTinted('search', IconPixelSize(16, Screen.PixelsPerInch), ICON_ON_LIGHT);
  if glyph <> nil then
  try
    FSearchBtn.Glyph.Assign(glyph);
  finally
    glyph.Free;
  end
  else
    FSearchBtn.Caption := '...';
  FEdit := MakeEdit(row, alClient);
  FEdit.OnKeyDown := @EditKeyDown;
  help := rsEpHelp;
  c := Conn;
  if (c <> nil) and (EffectiveServerKind(c.Profile, c.RootDse) = pkActiveDirectory) then help := rsEpHelpAd;
  if FBase <> '' then lbl := MakeLabel(Body, Format(help, [FBase]))
  else lbl := MakeLabel(Body, rsEpNoBase);
  lbl.WordWrap := True;
  lbl.ShowAccelChar := False;
  lbl.BorderSpacing.Top := 4;
  FList := TRtListGrid.Create(Body);
  FList.Parent := Body;
  FList.Align := alClient;
  FList.BorderSpacing.Top := 6;
  FList.FillWidth := True;
  FList.AddColumn(rsEpColEntry, 220);
  FList.AddColumn(rsEpColDn, 480);
  if FValueAttr <> '' then FList.AddColumn(FValueAttr, 140);
  FList.OnSelectRow := @ListSelect;
  FList.OnActivateRow := @ListActivate;
  AddButton(rsEpCancel, mrCancel, False, True);
  ok := AddButton(rsEpOk, mrNone, True);
  ok.OnClick := @OkClick;
  FSearchBtn.Enabled := FBase <> '';
  ApplyTheme;
  ActiveControl := FEdit;
end;

destructor TEntryPickDialog.Destroy;
begin
  ClearFound;
  FFound.Free;
  FRowDns.Free;
  FRowValues.Free;
  inherited Destroy;
end;

procedure TEntryPickDialog.ClearFound;
var
  i: Integer;
begin
  for i := 0 to FFound.Count - 1 do TLdapEntry(FFound[i]).Free;
  FFound.Clear;
end;

procedure TEntryPickDialog.RunSearch;
var
  c: TDirectoryConnection;
  req: TSearchRequest;
  server: TProviderKind;
  attrs: array of string;
begin
  if FBase = '' then
  begin
    SetStatus(rsEpNoBase, usWarning);
    Exit;
  end;
  if Trim(FEdit.Text) = '' then
  begin
    SetStatus(rsEpEmpty, usWarning);
    Exit;
  end;
  c := Conn;
  if c = nil then
  begin
    SetStatus(rsTdNotConnected, usError);
    Exit;
  end;
  server := EffectiveServerKind(c.Profile, c.RootDse);
  attrs := ['1.1'];
  if FValueAttr <> '' then attrs := [FValueAttr];
  FServer := server;
  FAttrs := attrs;
  FWide := False;
  FWideText := '';
  if EntryLookupWidens(FEdit.Text, server) then FWideText := FEdit.Text;
  req := EntryLookupRequest(FBase, FEdit.Text, server, attrs, LOOKUP_LIMIT);
  Tasks.Cancel('search');
  Tasks.Cancel('wide');
  ClearFound;
  FList.Clear;
  FRowDns.Clear;
  FRowValues.Clear;
  FPicked := '';
  if Search(req, 'search') <> 0 then SetStatus(rsEpSearching);
end;

procedure TEntryPickDialog.SearchClick(Sender: TObject);
begin
  RunSearch;
end;

procedure TEntryPickDialog.EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Shift <> [] then Exit;
  case Key of
    VK_RETURN:
      if (FPicked = '') or (Trim(FEdit.Text) <> FPicked) then
      begin
        Key := 0;
        RunSearch;
      end;
    VK_DOWN:
      if FList.Count > 0 then
      begin
        Key := 0;
        if FList.ItemIndex < 0 then FList.ItemIndex := 0;
        ListSelect(FList, FList.ItemIndex);
        FList.SetFocus;
      end;
  end;
end;

function TEntryPickDialog.HasFound(const ADn: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to FFound.Count - 1 do
    if SameText(TLdapEntry(FFound[i]).Dn, ADn) then Exit(True);
  Result := False;
end;

procedure TEntryPickDialog.OnEntries(AMsg: TEntriesMsg);
var
  i: Integer;
  cmp: TSearchCompletion;
  e: TLdapEntry;
  req: TSearchRequest;
begin
  FWide := Tasks.Current.Tag = 'wide';
  for i := 0 to AMsg.Entries.Count - 1 do
  begin
    e := TLdapEntry(AMsg.Entries[i]);
    if FWide and HasFound(e.Dn) then e.Free else FFound.Add(e);
  end;
  AMsg.Entries.OwnsObjects := False;
  AMsg.Entries.Clear;
  if not AMsg.Final then Exit;
  cmp := AMsg.Completion;
  // Renvois d'AD vers DomainDnsZones, ForestDnsZones ou Configuration quand on cherche depuis la
  // racine du domaine: personne ne veut d'une zone DNS comme membre de groupe.
  cmp.ReferralsIgnored := 0;
  cmp.ContinuationsIgnored := 0;
  if not FWide and (FWideText <> '') and not (cmp.SizeLimitHit or cmp.ClientLimitHit or cmp.TimeLimitHit) and
     (SearchOutcome(cmp) = soComplete) then
  begin
    ShowFound('');
    req := EntryLookupRequest(FBase, FWideText, FServer, FAttrs, LOOKUP_LIMIT, True);
    // Phase non indexee: limite de temps courte. Si le controleur traine ou expire, les resultats
    // par prefixe restent affiches.
    req.TimeLimitSec := LOOKUP_ANYWHERE_TIME_SEC;
    if Search(req, 'wide') <> 0 then SetStatus(Format(rsEpWidening, [FFound.Count]));
    Exit;
  end;
  if cmp.SizeLimitHit or cmp.ClientLimitHit then
    ShowFound(Format(rsEpMore, [LOOKUP_LIMIT]))
  else if cmp.TimeLimitHit then
    ShowFound(rsEpTimeLimit)
  else if SearchOutcome(cmp) <> soComplete then
    ShowFound(Format(rsEpPartial, [ResultCodeName(cmp.ResultCode)]))
  else
    ShowFound('');
end;

function CompareCaption(List: TStringList; Index1, Index2: Integer): Integer;
begin
  Result := CompareText(List[Index1], List[Index2]);
  if Result = 0 then
    Result := CompareText(TLdapEntry(List.Objects[Index1]).Dn, TLdapEntry(List.Objects[Index2]).Dn);
end;

procedure TEntryPickDialog.ShowFound(const ANote: string);
var
  sorted: TStringList;
  i: Integer;
  e: TLdapEntry;
  v, keep: string;
begin
  keep := '';
  if (FList.ItemIndex >= 0) and (FList.ItemIndex < FRowDns.Count) then keep := FRowDns[FList.ItemIndex];
  sorted := TStringList.Create;
  try
    for i := 0 to FFound.Count - 1 do
      sorted.AddObject(RdnCaption(TLdapEntry(FFound[i]).Dn), TObject(FFound[i]));
    sorted.CustomSort(@CompareCaption);
    FList.Clear;
    FRowDns.Clear;
    FRowValues.Clear;
    for i := 0 to sorted.Count - 1 do
    begin
      e := TLdapEntry(sorted.Objects[i]);
      if FValueAttr <> '' then
      begin
        v := string(e.FirstValue(FValueAttr));
        FList.AddRow([sorted[i], e.Dn, v]);
      end
      else
      begin
        v := e.Dn;
        FList.AddRow([sorted[i], e.Dn]);
      end;
      FRowDns.Add(e.Dn);
      FRowValues.Add(v);
    end;
  finally
    sorted.Free;
  end;
  if ANote <> '' then SetStatus(ANote, usWarning)
  else if FRowDns.Count = 0 then SetStatus(rsEpNone, usWarning)
  else if FRowDns.Count = 1 then SetStatus(rsEpOne, usOk)
  else SetStatus(Format(rsEpFound, [FRowDns.Count]), usOk);
  if FRowDns.Count = 1 then
  begin
    FList.ItemIndex := 0;
    ListSelect(FList, 0);
  end
  else if (keep <> '') and (FRowDns.IndexOf(keep) >= 0) then
    FList.ItemIndex := FRowDns.IndexOf(keep);
end;

procedure TEntryPickDialog.ListSelect(Sender: TObject; AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FRowValues.Count) then Exit;
  if FRowValues[AIndex] = '' then
  begin
    SetStatus(Format(rsEpNoValue, [FValueAttr]), usWarning);
    Exit;
  end;
  FPicked := FRowValues[AIndex];
  FEdit.Text := FPicked;
end;

procedure TEntryPickDialog.ListActivate(Sender: TObject; AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FRowValues.Count) then Exit;
  ListSelect(Sender, AIndex);
  if FRowValues[AIndex] <> '' then Accept;
end;

procedure TEntryPickDialog.OkClick(Sender: TObject);
begin
  Accept;
end;

function TEntryPickDialog.Accept: Boolean;
begin
  FResult := Trim(FEdit.Text);
  Result := FResult <> '';
  if not Result then
  begin
    SetStatus(rsEpEmpty, usWarning);
    Exit;
  end;
  // Un bout de nom n'est pas un DN: 'test1' est deja parti tel quel dans member, et AD l'a refuse.
  // On le cherche a la place.
  if (FValueAttr = '') and not LooksLikeDn(FResult) then
  begin
    Result := False;
    FResult := '';
    if FRowDns.Count = 0 then RunSearch;
    if SearchTask = 0 then SetStatus(Format(rsEpNotDn, [Trim(FEdit.Text)]), usWarning);
    Exit;
  end;
  ModalResult := mrOk;
end;

procedure TEntryPickDialog.SetEntered(const AText: string);
begin
  FEdit.Text := AText;
end;

function TEntryPickDialog.Entered: string;
begin
  Result := FEdit.Text;
end;

function TEntryPickDialog.SearchTask: Int64;
begin
  Result := Tasks.TaskOf('search');
  if Result = 0 then Result := Tasks.TaskOf('wide');
end;

function TEntryPickDialog.ResultDns: string;
var
  i: Integer;
begin
  Result := '|';
  for i := 0 to FRowDns.Count - 1 do Result := Result + FRowDns[i] + '|';
end;

function TEntryPickDialog.ChooseDn(const ADn: string): Boolean;
var
  i: Integer;
begin
  i := FRowDns.IndexOf(ADn);
  Result := i >= 0;
  if not Result then Exit;
  FList.ItemIndex := i;
  ListSelect(FList, i);
end;

function TEntryPickDialog.StatusText: string;
begin
  Result := FStatus.Caption;
end;

end.
