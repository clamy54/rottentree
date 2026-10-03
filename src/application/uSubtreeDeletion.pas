// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSubtreeDeletion;

{$mode objfpc}{$H+}

// Suppression d'un sous-arbre: enumeration complete, previsualisation, nouvelle enumeration juste
// avant d'executer, puis suppressions une a une des feuilles vers la racine. Pas de controle de
// suppression recursive: on veut savoir ce qui part. Perimetre partiel ou change entre-temps: rien
// n'est supprime.

interface

uses
  SysUtils, Classes, uSearchModel, uChangeSet, uLdapErrors, uLdapEntry, uUiInbox,
  uDirectoryWorker, uDirectoryOps;

const
  SUBTREE_MAX_ENTRIES = 200000;
  SUBTREE_MAX_BYTES = Int64(64) * 1024 * 1024;

type
  TSubtreeState = (sdsIdle, sdsEnumerating, sdsAwaitingConfirm, sdsVerifying,
    sdsAwaitingUnprotected, sdsDeleting, sdsFinished, sdsStopped);

  TSubtreeOutcome = (
    sdoNotMine,
    sdoPending,
    sdoConfirmNeeded,
    sdoUnprotectedConfirm,
    sdoIncomplete,
    sdoScopeChanged,
    sdoDeleting,
    sdoFinished,
    sdoStopped,
    sdoUserStopped
  );

  TSubtreeDeletion = class
  private
    FOps: TDirectoryOps;
    FPageSize: Integer;
    FState: TSubtreeState;
    FBaseDn: string;
    FTask: Int64;
    FFound: TStringList;
    FTargets: TStringList;
    // FQueue n'est jamais retiree en tete: un Delete(0) decale toute la liste, quadratique sur un
    // grand sous-arbre. FQueuePos avance a la place.
    FQueue: TStringList;
    FQueuePos: Integer;
    FAssertPool: TStringList;
    FAssertionControl: Boolean;
    FUnprotected: Integer;
    FDeleted: Integer;
    FNotAttempted: Integer;
    FCurrentDn: string;
    FRefusedDn: string;
    FUnconfirmedDn: string;
    FLastError: TLdapError;
    FStopRequested: Boolean;
    FPendingUnprotected: Integer;
    FBytes: Int64;
    FMaxTargets: Integer;
    FMaxBytes: Int64;
    function StartEnumeration: Boolean;
    function GetFound: Integer;
    function GetRemaining: Integer;
    function SubmitNext: TSubtreeOutcome;
    function Stop(const AError: TLdapError): TSubtreeOutcome;
  public
    constructor Create(AOps: TDirectoryOps; APageSize: Integer);
    destructor Destroy; override;
    function Start(const ABaseDn: string; AAssertionControl: Boolean = False): Boolean;
    function HandleEntries(AMsg: TEntriesMsg): TSubtreeOutcome;
    function HandleWrite(AMsg: TWriteMsg): TSubtreeOutcome;
    function Confirm: TSubtreeOutcome;
    function ConfirmUnprotected: TSubtreeOutcome;
    procedure Cancel;
    function RequestStop: TSubtreeOutcome;
    function OwnsTask(ATaskId: Int64): Boolean;
    function Active: Boolean;
    property State: TSubtreeState read FState;
    property BaseDn: string read FBaseDn;
    property Targets: TStringList read FTargets;
    property Found: Integer read GetFound;
    property Remaining: Integer read GetRemaining;
    property CurrentDn: string read FCurrentDn;
    property Task: Int64 read FTask;
    property StopRequested: Boolean read FStopRequested;
    property Deleted: Integer read FDeleted;
    property NotAttempted: Integer read FNotAttempted;
    property RefusedDn: string read FRefusedDn;
    // Envoyee, issue inconnue: l'entree est a verifier. Sa reponse tardive eventuelle sera soldee
    // par le journal des ecritures.
    property UnconfirmedDn: string read FUnconfirmedDn;
    property LastError: TLdapError read FLastError;
    property AssertionAnnounced: Boolean read FAssertionControl;
    property PendingUnprotected: Integer read FPendingUnprotected;
    property MaxTargets: Integer read FMaxTargets write FMaxTargets;
    property MaxBytes: Int64 read FMaxBytes write FMaxBytes;
    property UnprotectedDeletes: Integer read FUnprotected;
  end;

procedure SortLeavesFirst(AList: TStringList);

implementation

uses
  uLdapDn, uDirectoryService;

resourcestring
  rsSubtreeIncomplete = 'the subtree could not be enumerated completely';
  rsSubtreeReadOnly = 'this profile is read-only';
  rsSubtreeStoppedByUser = 'stopped at your request';
  rsSubtreeBudget = 'the subtree exceeds the collection limit (%d entries): nothing was deleted';

function DnDepthCompare(List: TStringList; Index1, Index2: Integer): Integer;
var
  a, b: TLdapDn;
  da, db: Integer;
begin
  if DnTryParse(List[Index1], a) then da := DnRdnCount(a) else da := 0;
  if DnTryParse(List[Index2], b) then db := DnRdnCount(b) else db := 0;
  Result := db - da;
  if Result = 0 then
    Result := CompareStr(List[Index1], List[Index2]);
end;

procedure SortLeavesFirst(AList: TStringList);
begin
  AList.Sorted := False;
  AList.CustomSort(@DnDepthCompare);
end;

constructor TSubtreeDeletion.Create(AOps: TDirectoryOps; APageSize: Integer);
begin
  inherited Create;
  FOps := AOps;
  FPageSize := APageSize;
  FFound := TStringList.Create;
  FTargets := TStringList.Create;
  FQueue := TStringList.Create;
  FAssertPool := TStringList.Create;
  FLastError := NoError;
  FMaxTargets := SUBTREE_MAX_ENTRIES;
  FMaxBytes := SUBTREE_MAX_BYTES;
end;

destructor TSubtreeDeletion.Destroy;
begin
  FFound.Free;
  FTargets.Free;
  FQueue.Free;
  FAssertPool.Free;
  inherited Destroy;
end;

function TSubtreeDeletion.StartEnumeration: Boolean;
var
  req: TSearchRequest;
begin
  FFound.Clear;
  // Sans limite: une enumeration tronquee ne passe jamais pour complete.
  req := DefaultSearchRequest;
  req.BaseDn := FBaseDn;
  req.Scope := ssSubtree;
  req.Filter := '(objectClass=*)';
  if (FState = sdsVerifying) and FAssertionControl then
    req.Attributes := ['entryCSN', 'modifyTimestamp', 'uSNChanged', 'whenChanged']
  else
    req.Attributes := ['1.1'];
  req.SizeLimit := 0;
  req.TimeLimitSec := 0;
  req.PageSize := FPageSize;
  FTask := FOps.Search(req, FLastError);
  Result := FTask <> 0;
end;

function TSubtreeDeletion.Start(const ABaseDn: string; AAssertionControl: Boolean): Boolean;
begin
  Cancel;
  FBaseDn := ABaseDn;
  FAssertionControl := AAssertionControl;
  FUnprotected := 0;
  FDeleted := 0;
  FNotAttempted := 0;
  FCurrentDn := '';
  FRefusedDn := '';
  FUnconfirmedDn := '';
  FStopRequested := False;
  FPendingUnprotected := 0;
  FBytes := 0;
  FTargets.Clear;
  FQueue.Clear;
  FQueuePos := 0;
  FAssertPool.Clear;
  FLastError := NoError;
  if FOps.ReadOnly then
  begin
    FLastError := MakeError(lecReadOnly, 0, 'delete', rsSubtreeReadOnly);
    FState := sdsStopped;
    Exit(False);
  end;
  FState := sdsEnumerating;
  Result := StartEnumeration;
  if not Result then FState := sdsStopped;
end;

function TSubtreeDeletion.OwnsTask(ATaskId: Int64): Boolean;
begin
  Result := (FTask <> 0) and (ATaskId = FTask) and
    (FState in [sdsEnumerating, sdsVerifying, sdsDeleting]);
end;

function TSubtreeDeletion.Active: Boolean;
begin
  Result := FState in [sdsEnumerating, sdsAwaitingConfirm, sdsVerifying,
    sdsAwaitingUnprotected, sdsDeleting];
end;

function TSubtreeDeletion.Stop(const AError: TLdapError): TSubtreeOutcome;
begin
  FLastError := AError;
  FNotAttempted := GetRemaining;
  FQueue.Clear;
  FQueuePos := 0;
  FTask := 0;
  FState := sdsStopped;
  Result := sdoStopped;
end;

function TSubtreeDeletion.HandleEntries(AMsg: TEntriesMsg): TSubtreeOutcome;
var
  i: Integer;
  same: Boolean;
  e: TLdapEntry;
  a: string;
  idx: PtrInt;
begin
  if not OwnsTask(AMsg.TaskId) or not (FState in [sdsEnumerating, sdsVerifying]) then
    Exit(sdoNotMine);
  for i := 0 to AMsg.Entries.Count - 1 do
  begin
    e := TLdapEntry(AMsg.Entries[i]);
    idx := 0;
    if (FState = sdsVerifying) and FAssertionControl then
    begin
      a := VersionAssertion(e);
      if a <> '' then idx := FAssertPool.Add(a) + 1;
      Inc(FBytes, Length(a));
    end;
    FFound.AddObject(e.Dn, TObject(idx));
    Inc(FBytes, Length(e.Dn));
    // Plafond de collecte: recherche annulee cote serveur, rien n'est supprime, la previsualisation
    // ne s'ouvre pas.
    if (FFound.Count > FMaxTargets) or (FBytes > FMaxBytes) then
    begin
      FOps.Cancel;
      FLastError := MakeError(lecOther, 0, 'delete', Format(rsSubtreeBudget, [FFound.Count]));
      FFound.Clear;
      FQueue.Clear;
      FQueuePos := 0;
      FTask := 0;
      FState := sdsStopped;
      Exit(sdoIncomplete);
    end;
  end;
  if not AMsg.Final then Exit(sdoPending);
  FTask := 0;
  if SearchOutcome(AMsg.Completion) <> soComplete then
  begin
    // Une page manquante n'est pas un sous-arbre vide.
    FLastError := AMsg.Error;
    if FLastError.Category = lecNone then
      FLastError := MakeError(lecOther, AMsg.Completion.ResultCode, 'delete', rsSubtreeIncomplete);
    FFound.Clear;
    FQueue.Clear;
    FQueuePos := 0;
    FState := sdsStopped;
    Exit(sdoIncomplete);
  end;
  SortLeavesFirst(FFound);
  if FState = sdsEnumerating then
  begin
    FTargets.Assign(FFound);
    FFound.Clear;
    FState := sdsAwaitingConfirm;
    Exit(sdoConfirmNeeded);
  end;
  same := FFound.Text = FTargets.Text;
  if not same then
  begin
    FFound.Clear;
    FState := sdsStopped;
    Exit(sdoScopeChanged);
  end;
  // La file vient de l'enumeration de controle: ses marqueurs de version sont ceux tout juste
  // relus, pas ceux de la previsualisation.
  FQueue.Assign(FFound);
  FQueuePos := 0;
  FFound.Clear;
  // Assertion annoncee mais cibles sans marqueur lisible: elles partiraient sans protection. Accord
  // explicite AVANT le premier envoi, pas un journal apres coup.
  if FAssertionControl then
  begin
    FPendingUnprotected := 0;
    for i := 0 to FQueue.Count - 1 do
      if PtrInt(FQueue.Objects[i]) = 0 then Inc(FPendingUnprotected);
    if FPendingUnprotected > 0 then
    begin
      FState := sdsAwaitingUnprotected;
      Exit(sdoUnprotectedConfirm);
    end;
  end;
  FState := sdsDeleting;
  Result := SubmitNext;
end;

function TSubtreeDeletion.ConfirmUnprotected: TSubtreeOutcome;
begin
  if FState <> sdsAwaitingUnprotected then Exit(sdoNotMine);
  FState := sdsDeleting;
  Result := SubmitNext;
end;

function TSubtreeDeletion.Confirm: TSubtreeOutcome;
begin
  if FState <> sdsAwaitingConfirm then Exit(sdoNotMine);
  FState := sdsVerifying;
  if not StartEnumeration then
    Exit(Stop(FLastError));
  Result := sdoPending;
end;

procedure TSubtreeDeletion.Cancel;
begin
  // Une suppression emise ne s'annule pas: seules les suivantes restent au sol. Celle dont on
  // attend la reponse n'est ni confirmee ni non tentee: elle est a verifier.
  if (FState = sdsDeleting) and (FTask <> 0) and (FCurrentDn <> '') then
    FUnconfirmedDn := FCurrentDn;
  FCurrentDn := '';
  FNotAttempted := GetRemaining;
  FQueue.Clear;
  FQueuePos := 0;
  FFound.Clear;
  FTask := 0;
  if FState <> sdsIdle then FState := sdsStopped;
end;

function TSubtreeDeletion.GetFound: Integer;
begin
  Result := FFound.Count;
end;

function TSubtreeDeletion.GetRemaining: Integer;
begin
  Result := FQueue.Count - FQueuePos;
  if Result < 0 then Result := 0;
end;

function TSubtreeDeletion.RequestStop: TSubtreeOutcome;
begin
  if not Active then Exit(sdoNotMine);
  FStopRequested := True;
  FLastError := MakeError(lecCancelled, 0, 'delete', rsSubtreeStoppedByUser);
  if (FState = sdsDeleting) and (FCurrentDn <> '') then Exit(sdoDeleting);
  if FState in [sdsEnumerating, sdsVerifying] then FOps.Cancel;
  FNotAttempted := GetRemaining;
  FQueue.Clear;
  FQueuePos := 0;
  FFound.Clear;
  FTask := 0;
  FState := sdsStopped;
  Result := sdoUserStopped;
end;

function TSubtreeDeletion.SubmitNext: TSubtreeOutcome;
var
  dn, assertion: string;
  idx: PtrInt;
  err: TLdapError;
begin
  if FQueuePos >= FQueue.Count then
  begin
    FTask := 0;
    FState := sdsFinished;
    Exit(sdoFinished);
  end;
  dn := FQueue[FQueuePos];
  idx := PtrInt(FQueue.Objects[FQueuePos]);
  // Suppression conditionnee au marqueur relu (Assertion, RFC 4528). Sans controle ou sans
  // marqueur, elle part sans, et la confirmation l'a annonce.
  assertion := '';
  if (idx > 0) and (idx <= FAssertPool.Count) then
    assertion := FAssertPool[idx - 1];
  FTask := FOps.Write(NewChange(ckDelete, dn), assertion, err);
  if FTask = 0 then
    Exit(Stop(err));
  if assertion = '' then Inc(FUnprotected);
  Inc(FQueuePos);
  FCurrentDn := dn;
  Result := sdoDeleting;
end;

function TSubtreeDeletion.HandleWrite(AMsg: TWriteMsg): TSubtreeOutcome;
begin
  if not OwnsTask(AMsg.TaskId) or (FState <> sdsDeleting) then Exit(sdoNotMine);
  if not AMsg.Result.Ok then
  begin
    // Issue inconnue: envoyee, peut-etre appliquee, a verifier. Refus apres emission: l'entree est
    // toujours la. Echec avant emission: jamais partie, comptee non tentee.
    if AMsg.Result.Error.Category = lecUnknownOutcome then
      FUnconfirmedDn := FCurrentDn
    else if AMsg.Result.Sent then
      FRefusedDn := FCurrentDn
    else
      Dec(FQueuePos);
    FCurrentDn := '';
    Exit(Stop(AMsg.Result.Error));
  end;
  FCurrentDn := '';
  Inc(FDeleted);
  if FStopRequested then
  begin
    FNotAttempted := GetRemaining;
    FQueue.Clear;
    FQueuePos := 0;
    FTask := 0;
    FState := sdsStopped;
    Exit(sdoUserStopped);
  end;
  Result := SubmitNext;
end;

end.
