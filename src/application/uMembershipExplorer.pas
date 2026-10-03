// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uMembershipExplorer;

{$mode objfpc}{$H+}

// Exploration des appartenances, noeud par noeud: vers le bas les membres d'un groupe, vers le haut
// les groupes qui citent l'entree. Le groupe principal AD est resolu par SID et RID, jamais
// confondu avec member. Une lecture refusee laisse l'information inconnue, pas vide.

interface

uses
  SysUtils, Classes, uSearchModel, uLdapErrors, uLdapEntry, uUiInbox, uDirectoryWorker,
  uDirectoryOps, uConnectionProfile, uGroupModel;

type
  TExploreDirection = (edMembers, edMemberOf);

  TExploreOutcome = (eoNotMine, eoProgress, eoFinished, eoFailed);

  TMembershipExplorer = class
  private
    FOps: TDirectoryOps;
    FServer: TProviderKind;
    FSearchBase: string;
    FPageSize: Integer;
    FDirection: TExploreDirection;
    FGraph: TMembershipGraph;
    FTask: Int64;
    FNode: Integer;
    FFound: TMemberRefArray;
    FRootUid: string;
    FRootSid: RawByteString;
    FRootPrimaryRid: Int64;
    FPrimaryPending: Boolean;
    FRunning: Boolean;
    FLastError: TLdapError;
    function Advance: TExploreOutcome;
    function StartSearch(const AFilter: string): Boolean;
    procedure AddRef(const AValue: string; AKind: TMembershipKind; ALeaf: Boolean);
    procedure CollectMembers(AEntry: TLdapEntry; out AIsGroup: Boolean);
  public
    constructor Create(AOps: TDirectoryOps; AServer: TProviderKind; const ASearchBase: string;
      APageSize: Integer);
    destructor Destroy; override;
    function Start(const ARootDn: string; ADirection: TExploreDirection): Boolean;
    function HandleEntry(AMsg: TEntryMsg): TExploreOutcome;
    function HandleEntries(AMsg: TEntriesMsg): TExploreOutcome;
    procedure Cancel;
    function OwnsTask(ATaskId: Int64): Boolean;
    property Task: Int64 read FTask;
    property Graph: TMembershipGraph read FGraph;
    property Direction: TExploreDirection read FDirection;
    property Running: Boolean read FRunning;
    property LastError: TLdapError read FLastError;
  end;

implementation

uses
  uLdapFilter;

constructor TMembershipExplorer.Create(AOps: TDirectoryOps; AServer: TProviderKind;
  const ASearchBase: string; APageSize: Integer);
begin
  inherited Create;
  FOps := AOps;
  FServer := AServer;
  FSearchBase := ASearchBase;
  FPageSize := APageSize;
  FLastError := NoError;
end;

destructor TMembershipExplorer.Destroy;
begin
  FGraph.Free;
  inherited Destroy;
end;

function TMembershipExplorer.OwnsTask(ATaskId: Int64): Boolean;
begin
  Result := FRunning and (FTask <> 0) and (ATaskId = FTask);
end;

procedure TMembershipExplorer.Cancel;
begin
  FRunning := False;
  FTask := 0;
end;

function TMembershipExplorer.Start(const ARootDn: string; ADirection: TExploreDirection): Boolean;
var
  node, i: Integer;
  dn: string;
  attrs: TStringArray;
begin
  Cancel;
  FreeAndNil(FGraph);
  FDirection := ADirection;
  FGraph := TMembershipGraph.Create(ARootDn);
  FRootUid := '';
  FRootSid := '';
  FRootPrimaryRid := -1;
  FPrimaryPending := False;
  FLastError := NoError;
  FRunning := True;
  FGraph.NextToRead(node, dn);
  FNode := node;
  SetLength(attrs, Length(GROUP_READ_ATTRS));
  for i := 0 to High(GROUP_READ_ATTRS) do
    attrs[i] := GROUP_READ_ATTRS[i];
  attrs := Concat(attrs, ['uid', 'objectSid', 'primaryGroupID']);
  FTask := FOps.ReadEntry(dn, attrs, FLastError);
  Result := FTask <> 0;
  if not Result then FRunning := False;
end;

procedure TMembershipExplorer.AddRef(const AValue: string; AKind: TMembershipKind;
  ALeaf: Boolean);
begin
  SetLength(FFound, Length(FFound) + 1);
  FFound[High(FFound)].Value := AValue;
  FFound[High(FFound)].Kind := AKind;
  FFound[High(FFound)].Leaf := ALeaf;
end;

procedure TMembershipExplorer.CollectMembers(AEntry: TLdapEntry; out AIsGroup: Boolean);
var
  model: TGroupModel;
  a: TLdapAttribute;
  i, p: Integer;
  v: string;
begin
  model := DetectGroupModel(AEntry, FServer);
  AIsGroup := model.Kind <> gkNotGroup;
  if not AIsGroup then Exit;
  if model.MemberAttr <> '' then
  begin
    a := AEntry.Find(model.MemberAttr);
    if a <> nil then
      for i := 0 to a.ValueCount - 1 do
      begin
        v := a.Values[i];
        // uniqueMember: un DN, parfois suivi de #'bits'B. Parce que pourquoi pas.
        p := Pos('#''', v);
        if model.ValuesAreDns and (p > 0) and (Copy(v, Length(v) - 1, 2) = '''B') then
          v := Copy(v, 1, p - 1);
        AddRef(v, mkDirect, not model.ValuesAreDns);
      end;
    // Plage AD incomplete: des membres manquent, l'information est partielle.
    if (a <> nil) and a.Truncated then
      AddRef(model.MemberAttr + ' (partial)', mkUnknown, True);
  end;
  if model.DynamicAttr <> '' then
  begin
    a := AEntry.Find(model.DynamicAttr);
    if a <> nil then
    begin
      for i := 0 to a.ValueCount - 1 do
        AddRef(a.Values[i], mkDynamic, True);
      if a.Truncated then
        AddRef(model.DynamicAttr + ' (partial)', mkUnknown, True);
    end;
  end;
  if AEntry.DecodeIncomplete then
    AddRef('(partial)', mkUnknown, True);
end;

function TMembershipExplorer.StartSearch(const AFilter: string): Boolean;
var
  req: TSearchRequest;
begin
  req := DefaultSearchRequest;
  req.BaseDn := FSearchBase;
  req.Scope := ssSubtree;
  req.Filter := AFilter;
  req.Attributes := ['1.1'];
  req.PageSize := FPageSize;
  req.SizeLimit := GROUP_MAX_NODES;
  FTask := FOps.Search(req, FLastError);
  Result := FTask <> 0;
end;

function TMembershipExplorer.HandleEntry(AMsg: TEntryMsg): TExploreOutcome;
var
  isGroup: Boolean;
  sid: RawByteString;
begin
  if not OwnsTask(AMsg.TaskId) then Exit(eoNotMine);
  FTask := 0;
  FFound := nil;
  if AMsg.Entry = nil then
  begin
    FGraph.Feed(FNode, False, nil, True, ErrorToText(AMsg.Error));
    Exit(Advance);
  end;
  if FDirection = edMembers then
  begin
    CollectMembers(AMsg.Entry, isGroup);
    // Groupe principal AD: ses membres ne figurent pas dans member, il faut aller les chercher
    // ailleurs.
    if isGroup and (FNode = 0) and (FServer = pkActiveDirectory) and
       (AMsg.Entry.FirstValue('primaryGroupToken', '') <> '') then
    begin
      FGraph.Feed(FNode, True, FFound, False);
      FFound := nil;
      FPrimaryPending := True;
      if not StartSearch(AdPrimaryMembersFilter(AMsg.Entry.FirstValue('primaryGroupToken', ''))) then
      begin
        FRunning := False;
        Exit(eoFailed);
      end;
      Exit(eoProgress);
    end;
    // Non-groupe au decodage incomplet: contenu inconnu, jamais presente comme "aucun membre".
    FGraph.Feed(FNode, isGroup, FFound, (not isGroup) and AMsg.Entry.DecodeIncomplete);
    Exit(Advance);
  end;
  if FNode = 0 then
  begin
    FRootUid := AMsg.Entry.FirstValue('uid', '');
    FRootSid := AMsg.Entry.FirstValue('objectSid', '');
    FRootPrimaryRid := StrToInt64Def(Trim(AMsg.Entry.FirstValue('primaryGroupID', '')), -1);
    if (FServer = pkActiveDirectory) and (FRootPrimaryRid >= 0) and
       AdPrimaryGroupSid(FRootSid, Cardinal(FRootPrimaryRid), sid) then
    begin
      FPrimaryPending := True;
      if not StartSearch('(objectSid=' + FilterEscapeValue(sid) + ')') then
      begin
        FRunning := False;
        Exit(eoFailed);
      end;
      Exit(eoProgress);
    end;
  end;
  if not StartSearch(DirectGroupsFilter(FGraph[FNode].Dn, FRootUid)) then
  begin
    FRunning := False;
    Exit(eoFailed);
  end;
  Result := eoProgress;
end;

function TMembershipExplorer.HandleEntries(AMsg: TEntriesMsg): TExploreOutcome;
var
  i: Integer;
  partial: Boolean;
  kind: TMembershipKind;
begin
  if not OwnsTask(AMsg.TaskId) then Exit(eoNotMine);
  if FPrimaryPending then kind := mkPrimary else kind := mkDirect;
  for i := 0 to AMsg.Entries.Count - 1 do
    AddRef(TLdapEntry(AMsg.Entries[i]).Dn, kind, (FDirection = edMembers) and FPrimaryPending);
  if not AMsg.Final then Exit(eoProgress);
  FTask := 0;
  partial := SearchOutcome(AMsg.Completion) <> soComplete;
  if partial then
    AddRef(ErrorToText(AMsg.Error), mkUnknown, True);
  if FPrimaryPending then
  begin
    FPrimaryPending := False;
    if FDirection = edMembers then
    begin
      FGraph.Feed(0, True, FFound, False);
      FFound := nil;
      Exit(Advance);
    end;
    if not StartSearch(DirectGroupsFilter(FGraph[FNode].Dn, FRootUid)) then
    begin
      FRunning := False;
      Exit(eoFailed);
    end;
    Exit(eoProgress);
  end;
  FGraph.Feed(FNode, True, FFound, False);
  FFound := nil;
  Result := Advance;
end;

function TMembershipExplorer.Advance: TExploreOutcome;
var
  node: Integer;
  dn: string;
begin
  FFound := nil;
  if not FGraph.NextToRead(node, dn) then
  begin
    FRunning := False;
    Exit(eoFinished);
  end;
  FNode := node;
  if FDirection = edMembers then
    FTask := FOps.ReadEntry(dn, GROUP_READ_ATTRS, FLastError)
  else
    StartSearch(DirectGroupsFilter(dn, ''));
  if FTask = 0 then
  begin
    FRunning := False;
    Exit(eoFailed);
  end;
  Result := eoProgress;
end;

end.
