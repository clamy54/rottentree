// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTemplateGroups;

{$mode objfpc}{$H+}

// Groupes ou inscrire une entree creee depuis un modele. Chacun est lu sur l'annuaire ouvert
// avant toute creation: on n'inscrit personne dans un groupe qu'on n'a pas vu.

interface

uses
  SysUtils, Classes, uGroupModel, uTaskTracker, uUiInbox, uConnectionProfile;

type
  TGroupTargetState = (gtsReading, gtsReady, gtsProblem);

  TGroupTarget = record
    Dn: string;
    State: TGroupTargetState;
    Join: TGroupJoin;
    Problem: string;
  end;

  TGroupTargets = class
  private
    FTasks: TDirectoryTasks;
    FTag: string;
    FItems: array of TGroupTarget;
    FReading: Integer;
    FOnChange: TNotifyEvent;
    function GetItem(AIndex: Integer): TGroupTarget;
    procedure Changed;
    function Provider: TProviderKind;
    procedure Settle(AIndex: Integer; const AProblem: string);
  public
    constructor Create(ATasks: TDirectoryTasks; const ATag: string);
    procedure SetGroups(const ADns: array of string);
    function Add(const ADn: string): Boolean;
    procedure Remove(AIndex: Integer);
    function Count: Integer;
    procedure Pump;
    function Busy: Boolean;
    function FirstProblem: string;
    function Joins: TGroupJoins;
    function NeedUid: Boolean;
    function Dns: TStringArray;
    function HandleMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding): Boolean;
    property Items[AIndex: Integer]: TGroupTarget read GetItem; default;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

resourcestring
  rsTgNotConnected = 'not connected';
  rsTgBusy = 'too many background tasks: remove the group and add it again';
  rsTgLost = 'the connection changed while the group was being read';
  rsTgUnreadable = 'cannot be read here: %s';
  rsTgProblem = '%s: %s';

implementation

uses
  uConnections, uDirectoryWorker, uLdapErrors, uServerKind, uLdapEntry, uLdapDn, uDirectoryService;

constructor TGroupTargets.Create(ATasks: TDirectoryTasks; const ATag: string);
begin
  inherited Create;
  FTasks := ATasks;
  FTag := ATag;
  FReading := -1;
end;

function TGroupTargets.GetItem(AIndex: Integer): TGroupTarget;
begin
  Result := FItems[AIndex];
end;

function TGroupTargets.Count: Integer;
begin
  Result := Length(FItems);
end;

procedure TGroupTargets.Changed;
begin
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TGroupTargets.Provider: TProviderKind;
var
  c: TDirectoryConnection;
begin
  Result := pkAuto;
  c := FTasks.Conn;
  if c <> nil then Result := EffectiveServerKind(c.Profile, c.RootDse);
end;

procedure TGroupTargets.SetGroups(const ADns: array of string);
var
  i: Integer;
begin
  FTasks.Cancel(FTag);
  FReading := -1;
  FItems := nil;
  for i := 0 to High(ADns) do
    Add(ADns[i]);
  Pump;
end;

function TGroupTargets.Add(const ADn: string): Boolean;
var
  i: Integer;
  key: string;
  rules: TDnCaseRules;
begin
  Result := False;
  if Trim(ADn) = '' then Exit;
  rules := TDnCaseRules.Create(FTasks.Conn);
  try
    key := DnFoldKey(Trim(ADn), @rules.Folds, @rules.Canon);
    for i := 0 to High(FItems) do
      if DnFoldKey(FItems[i].Dn, @rules.Folds, @rules.Canon) = key then Exit;
  finally
    rules.Free;
  end;
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)] := Default(TGroupTarget);
  FItems[High(FItems)].Dn := Trim(ADn);
  FItems[High(FItems)].State := gtsReading;
  Result := True;
  Changed;
end;

procedure TGroupTargets.Remove(AIndex: Integer);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  // La lecture en cours visait peut-etre ce groupe: abandonnee.
  if FReading = AIndex then
  begin
    FTasks.Cancel(FTag);
    FReading := -1;
  end
  else if FReading > AIndex then
    Dec(FReading);
  for i := AIndex to High(FItems) - 1 do
    FItems[i] := FItems[i + 1];
  SetLength(FItems, Length(FItems) - 1);
  Changed;
  Pump;
end;

procedure TGroupTargets.Settle(AIndex: Integer; const AProblem: string);
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  if AProblem = '' then FItems[AIndex].State := gtsReady
  else FItems[AIndex].State := gtsProblem;
  FItems[AIndex].Problem := AProblem;
end;

procedure TGroupTargets.Pump;
var
  i: Integer;
  c: TDirectoryConnection;
begin
  if FReading >= 0 then Exit;
  c := FTasks.Conn;
  for i := 0 to High(FItems) do
  begin
    if FItems[i].State <> gtsReading then Continue;
    if (c = nil) or not c.IsReady then
    begin
      Settle(i, rsTgNotConnected);
      Continue;
    end;
    if FTasks.ReadEntry(FTag, FItems[i].Dn, GROUP_READ_ATTRS) = 0 then
    begin
      Settle(i, rsTgBusy);
      Continue;
    end;
    FReading := i;
    Break;
  end;
  Changed;
end;

function TGroupTargets.Busy: Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    if FItems[i].State = gtsReading then Exit(True);
  Result := False;
end;

function TGroupTargets.FirstProblem: string;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    if FItems[i].State = gtsProblem then
      Exit(Format(rsTgProblem, [FItems[i].Dn, FItems[i].Problem]));
  Result := '';
end;

function TGroupTargets.Joins: TGroupJoins;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to High(FItems) do
    if FItems[i].State = gtsReady then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := FItems[i].Join;
    end;
end;

function TGroupTargets.NeedUid: Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    if (FItems[i].State = gtsReady) and not FItems[i].Join.ByDn then Exit(True);
  Result := False;
end;

function TGroupTargets.Dns: TStringArray;
var
  i: Integer;
begin
  Result := nil;
  SetLength(Result, Length(FItems));
  for i := 0 to High(FItems) do
    Result[i] := FItems[i].Dn;
end;

function TGroupTargets.HandleMessage(AMsg: TUiMessage; const ATask: TTrackedTask;
  AEnding: TTaskEnding): Boolean;
var
  e: TEntryMsg;
  i: Integer;
  join: TGroupJoin;
  err: string;
begin
  Result := ATask.Tag = FTag;
  if not Result then Exit;
  i := FReading;
  FReading := -1;
  if (i >= 0) and (i <= High(FItems)) then
  begin
    if AEnding = teStale then
      Settle(i, rsTgLost)
    else if AMsg is TTaskFailedMsg then
      Settle(i, Format(rsTgUnreadable, [TTaskFailedMsg(AMsg).Text]))
    else if AMsg is TEntryMsg then
    begin
      e := TEntryMsg(AMsg);
      if e.Entry = nil then
        Settle(i, Format(rsTgUnreadable, [ErrorToText(e.Error)]))
      else if PlanGroupJoin(e.Entry, Provider, join, err) then
      begin
        FItems[i].Join := join;
        Settle(i, '');
      end
      else
        Settle(i, err);
    end
    else
    begin
      FReading := i;
      Exit;
    end;
  end;
  Pump;
end;

end.
