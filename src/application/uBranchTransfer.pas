// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uBranchTransfer;

{$mode objfpc}{$H+}

// Copie d'une entree ou d'une branche, sur le meme serveur ou ailleurs, et deplacement entre
// serveurs. Un deplacement inter-serveurs n'est jamais un ModifyDN: copie, relecture, verification,
// puis seulement suppression de la source. Au premier accroc, la source reste ou elle est. Echanger
// l'original contre une copie fausse, c'est un marche de dupe.

interface

uses
  SysUtils, Classes, uSearchModel, uChangeSet, uLdapErrors, uLdapEntry, uUiInbox,
  uDirectoryWorker, uDirectoryOps, uClonePlan;

type
  TTransferState = (tsIdle, tsReading, tsAwaitingConfirm, tsCopying, tsVerifying, tsProbing,
    tsDeleting, tsFinished, tsStopped);

  TTransferOutcome = (
    toNotMine,
    toPending,
    toConfirmNeeded,
    toIncomplete,
    toPlanFailed,
    toCopying,
    toVerifying,
    toDeleting,
    toFinished,
    toStopped
  );

  TBranchTransfer = class
  private
    FSource: TDirectoryOps;
    FTarget: TDirectoryOps;
    FPageSize: Integer;
    FMove: Boolean;
    FRewrite: Boolean;
    FOptions: TCloneOptions;
    FAssertionControl: Boolean;
    FState: TTransferState;
    FSourceBase: string;
    FTargetBase: string;
    FTask: Int64;
    FPlan: TBranchCopyPlan;
    FStep: Integer;
    FCreated: TStringList;
    FVerified: Integer;
    FMismatch: TStringList;
    FDeleteQueue: TStringList;
    FDeleted: Integer;
    FNotAttempted: Integer;
    FMaxSourceEntries: Integer;
    FMaxSourceBytes: Int64;
    FDestId: array of RawByteString;
    FInFlight: string;
    FUnknownOutcome: string;
    FLastError: TLdapError;
    function Stop(const AError: TLdapError): TTransferOutcome;
    function SessionsKept: Boolean;
    function SessionChanged: TTransferOutcome;
    procedure SettleInFlight;
    function SubmitCopy: TTransferOutcome;
    function SubmitVerify: TTransferOutcome;
    function SubmitProbe: TTransferOutcome;
    function StartDeleting: TTransferOutcome;
    function SubmitDelete: TTransferOutcome;
    function HandleProbe(AMsg: TEntryMsg): TTransferOutcome;
    procedure CompareWritten(APlanned, ARead: TLdapEntry);
  public
    constructor Create(ASource, ATarget: TDirectoryOps; APageSize: Integer);
    destructor Destroy; override;
    function Start(const ASourceBase, ATargetBase: string; AMove, ARewriteInternal: Boolean;
      const AOptions: TCloneOptions; ASingleEntry: Boolean = False;
      ASameDirectory: Boolean = True; ASourceAssertion: Boolean = False): Boolean;
    function HandleEntries(AMsg: TEntriesMsg): TTransferOutcome;
    function HandleEntry(AMsg: TEntryMsg): TTransferOutcome;
    function HandleWrite(AMsg: TWriteMsg): TTransferOutcome;
    function Confirm: TTransferOutcome;
    procedure Cancel;
    // Reponse perdue (session remplacee, fil mort): arret. L'ecriture en vol n'est ni annulee ni
    // comptee creee, son issue est inconnue.
    function TaskLost(const AError: TLdapError): TTransferOutcome;
    function OwnsTask(ATaskId: Int64): Boolean;
    function Active: Boolean;
    function BasesOverlap: Boolean;
    function DeletesWithoutAssertion: Boolean;
    property State: TTransferState read FState;
    property Plan: TBranchCopyPlan read FPlan;
    property Move: Boolean read FMove;
    property Rewrite: Boolean read FRewrite;
    property SourceBase: string read FSourceBase;
    property TargetBase: string read FTargetBase;
    property Created: TStringList read FCreated;
    property Verified: Integer read FVerified;
    property Mismatch: TStringList read FMismatch;
    property Deleted: Integer read FDeleted;
    property NotAttempted: Integer read FNotAttempted;
    property UnknownOutcome: string read FUnknownOutcome;
    property MaxSourceEntries: Integer read FMaxSourceEntries write FMaxSourceEntries;
    property MaxSourceBytes: Int64 read FMaxSourceBytes write FMaxSourceBytes;
    property LastError: TLdapError read FLastError;
  end;

resourcestring
  rsTransferReadOnlyTarget = 'the destination profile is read-only';
  rsTransferReadOnlySource = 'the source profile is read-only: it cannot be moved';
  rsTransferIncomplete = 'the source could not be read completely';
  rsTransferVerifyFailed = 'the copy does not match the source (%d difference(s)); the source was not deleted';
  rsTransferVerifyMissing = 'the copied entry %s could not be read back; the source was not deleted';
  rsTransferVerifyTruncated = 'the copied entry %s was not read back completely; the source was not deleted';
  rsTransferBudget = 'the source exceeds the collection limit (%d entries, %d MB read): nothing was written';
  rsTransferSameDirectory = 'source and destination are the same directory (%s carries the same identifier on both connections): nothing was deleted, the copy is kept';
  rsTransferIdentityUnknown = 'cannot prove that source and destination are distinct directories: nothing was deleted, the copy is kept';
  rsTransferSessionChanged = 'a connection or its schema changed since the preview: nothing more was sent';
  rsTransferProbeAbsent = 'the probe found nothing at %s through the source connection; an absence does not prove two distinct directories (replication delay or access rules can hide the entry): nothing was deleted, the copy is kept';

implementation

uses
  uSubtreeDeletion, uLdapDn, uLdapSchema, uMatchingRules, uDirectoryService;

const
  // Identifiants poses par le serveur: la meme valeur relue par les deux connexions trahit un seul
  // annuaire derriere deux profils.
  TRANSFER_ID_ATTRS: array[0..4] of string = (
    'entryUUID', 'objectGUID', 'nsUniqueId', 'ipaUniqueID', 'GUID');

constructor TBranchTransfer.Create(ASource, ATarget: TDirectoryOps; APageSize: Integer);
begin
  inherited Create;
  FSource := ASource;
  FTarget := ATarget;
  FPageSize := APageSize;
  FCreated := TStringList.Create;
  FMismatch := TStringList.Create;
  FDeleteQueue := TStringList.Create;
  FMaxSourceEntries := COLLECT_MAX_ENTRIES;
  FMaxSourceBytes := COLLECT_MAX_BYTES;
  FLastError := NoError;
end;

destructor TBranchTransfer.Destroy;
begin
  FPlan.Free;
  FCreated.Free;
  FMismatch.Free;
  FDeleteQueue.Free;
  inherited Destroy;
end;

function TBranchTransfer.Start(const ASourceBase, ATargetBase: string; AMove,
  ARewriteInternal: Boolean; const AOptions: TCloneOptions; ASingleEntry: Boolean;
  ASameDirectory: Boolean; ASourceAssertion: Boolean): Boolean;
var
  req: TSearchRequest;
begin
  Cancel;
  FreeAndNil(FPlan);
  FSourceBase := ASourceBase;
  FTargetBase := ATargetBase;
  FMove := AMove;
  FRewrite := ARewriteInternal;
  FOptions := AOptions;
  FAssertionControl := ASourceAssertion;
  FCreated.Clear;
  FMismatch.Clear;
  FDeleteQueue.Clear;
  FVerified := 0;
  FDeleted := 0;
  FNotAttempted := 0;
  FStep := 0;
  FDestId := nil;
  SetLength(FDestId, Length(TRANSFER_ID_ATTRS));
  FInFlight := '';
  FUnknownOutcome := '';
  FLastError := NoError;
  FState := tsStopped;
  if FTarget.ReadOnly then
  begin
    FLastError := MakeError(lecReadOnly, 0, 'copy', rsTransferReadOnlyTarget);
    Exit(False);
  end;
  if AMove and FSource.ReadOnly then
  begin
    FLastError := MakeError(lecReadOnly, 0, 'move', rsTransferReadOnlySource);
    Exit(False);
  end;
  FPlan := TBranchCopyPlan.Create(ASourceBase, ATargetBase, ASameDirectory);
  // '*' ne renvoie pas les operationnels: les marqueurs de version sont demandes a part, ils
  // protegent la suppression d'un deplacement.
  req := DefaultSearchRequest;
  req.BaseDn := ASourceBase;
  if ASingleEntry then req.Scope := ssBase else req.Scope := ssSubtree;
  req.Filter := '(objectClass=*)';
  req.Attributes := ['*', 'entryCSN', 'modifyTimestamp', 'uSNChanged', 'whenChanged'];
  req.SizeLimit := 0;
  req.TimeLimitSec := 0;
  req.PageSize := FPageSize;
  FTask := FSource.Search(req, FLastError);
  Result := FTask <> 0;
  if Result then FState := tsReading;
end;

function TBranchTransfer.OwnsTask(ATaskId: Int64): Boolean;
begin
  Result := (FTask <> 0) and (ATaskId = FTask) and
    (FState in [tsReading, tsCopying, tsVerifying, tsProbing, tsDeleting]);
end;

function TBranchTransfer.Active: Boolean;
begin
  Result := FState in [tsReading, tsAwaitingConfirm, tsCopying, tsVerifying, tsProbing,
    tsDeleting];
end;

function TBranchTransfer.SessionsKept: Boolean;
begin
  Result := FSource.SessionCurrent and FTarget.SessionCurrent;
end;

function TBranchTransfer.SessionChanged: TTransferOutcome;
begin
  Result := Stop(MakeError(lecOther, 0, 'transfer', rsTransferSessionChanged));
end;

procedure TBranchTransfer.SettleInFlight;
begin
  if FInFlight = '' then Exit;
  FUnknownOutcome := FInFlight;
  FInFlight := '';
  if FState = tsCopying then Inc(FStep);
end;

function TBranchTransfer.TaskLost(const AError: TLdapError): TTransferOutcome;
begin
  if not (FState in [tsReading, tsCopying, tsVerifying, tsProbing, tsDeleting]) then
    Exit(toNotMine);
  SettleInFlight;
  Result := Stop(AError);
end;

function TBranchTransfer.Stop(const AError: TLdapError): TTransferOutcome;
begin
  FLastError := AError;
  case FState of
    tsReading: FSource.Cancel;
    tsCopying: FNotAttempted := FPlan.Count - FStep;
    tsProbing: FNotAttempted := FPlan.Count;
    tsDeleting: FNotAttempted := FDeleteQueue.Count;
  end;
  FDeleteQueue.Clear;
  FTask := 0;
  FState := tsStopped;
  Result := toStopped;
end;

function TBranchTransfer.HandleEntries(AMsg: TEntriesMsg): TTransferOutcome;
var
  i: Integer;
  err: string;
begin
  if not OwnsTask(AMsg.TaskId) or (FState <> tsReading) then Exit(toNotMine);
  for i := 0 to AMsg.Entries.Count - 1 do
  begin
    FPlan.AddSource(TLdapEntry(AMsg.Entries[i]));
    // Plafond de collecte atteint: arret avant toute ecriture, et annulation cote source, sinon le
    // producteur continue de remplir une file que plus personne ne lit.
    if (FPlan.SourceCount > FMaxSourceEntries) or (FPlan.SourceBytes > FMaxSourceBytes) then
    begin
      FLastError := MakeError(lecOther, 0, 'copy', Format(rsTransferBudget,
        [FPlan.SourceCount, FPlan.SourceBytes div (1024 * 1024)]));
      FSource.Cancel;
      FTask := 0;
      FState := tsStopped;
      Exit(toIncomplete);
    end;
  end;
  if not AMsg.Final then Exit(toPending);
  FTask := 0;
  if SearchOutcome(AMsg.Completion) <> soComplete then
  begin
    FLastError := AMsg.Error;
    if FLastError.Category = lecNone then
      FLastError := MakeError(lecOther, AMsg.Completion.ResultCode, 'copy',
        rsTransferIncomplete);
    FState := tsStopped;
    Exit(toIncomplete);
  end;
  // Le plan consulte le schema de la destination: s'il a ete remplace entre-temps, l'ancien est
  // deja libere.
  if not SessionsKept then
  begin
    FLastError := MakeError(lecOther, 0, 'copy', rsTransferSessionChanged);
    FState := tsStopped;
    Exit(toPlanFailed);
  end;
  if not FPlan.Build(FOptions, FRewrite, err) then
  begin
    FLastError := MakeError(lecOther, 0, 'copy', err);
    FState := tsStopped;
    Exit(toPlanFailed);
  end;
  FState := tsAwaitingConfirm;
  Result := toConfirmNeeded;
end;

function TBranchTransfer.Confirm: TTransferOutcome;
begin
  if FState <> tsAwaitingConfirm then Exit(toNotMine);
  FState := tsCopying;
  FStep := 0;
  Result := SubmitCopy;
end;

procedure TBranchTransfer.Cancel;
begin
  // Une ecriture emise ne s'annule pas: elle reste d'issue inconnue, seules les suivantes restent
  // au sol.
  SettleInFlight;
  case FState of
    tsReading: FSource.Cancel;
    tsCopying: FNotAttempted := FPlan.Count - FStep;
    tsProbing: FNotAttempted := FPlan.Count;
    tsDeleting: FNotAttempted := FDeleteQueue.Count;
  end;
  FDeleteQueue.Clear;
  FTask := 0;
  if FState <> tsIdle then FState := tsStopped;
end;

function TBranchTransfer.SubmitCopy: TTransferOutcome;
var
  change: TLdapChange;
  err: TLdapError;
begin
  if FStep >= FPlan.Count then
  begin
    FState := tsVerifying;
    FStep := 0;
    Exit(SubmitVerify);
  end;
  if not SessionsKept then Exit(SessionChanged);
  change := TLdapChange.Create;
  change.Kind := ckAdd;
  change.Dn := FPlan.Targets[FStep].Dn;
  change.Entry := FPlan.Targets[FStep].Clone;
  FTask := FTarget.Write(change, '', err);
  if FTask = 0 then Exit(Stop(err));
  FInFlight := FPlan.Targets[FStep].Dn;
  Result := toCopying;
end;

function TBranchTransfer.SubmitVerify: TTransferOutcome;
var
  err: TLdapError;
begin
  if FStep >= FPlan.Count then
  begin
    FTask := 0;
    if FMismatch.Count > 0 then
      Exit(Stop(MakeError(lecOther, 0, 'verify',
        Format(rsTransferVerifyFailed, [FMismatch.Count]))));
    if not FMove then
    begin
      FState := tsFinished;
      Exit(toFinished);
    end;
    // Destination dans la base source: avant de supprimer, preuve qu'il y a bien deux annuaires.
    // Sinon on efface l'original de la copie qu'on vient de faire.
    if BasesOverlap then Exit(SubmitProbe);
    Exit(StartDeleting);
  end;
  if not SessionsKept then Exit(SessionChanged);
  FTask := FTarget.ReadEntry(FPlan.Targets[FStep].Dn,
    ['*', 'entryUUID', 'objectGUID', 'nsUniqueId', 'ipaUniqueID', 'GUID'], err);
  if FTask = 0 then Exit(Stop(err));
  Result := toVerifying;
end;

function TBranchTransfer.BasesOverlap: Boolean;
var
  s, t: TLdapDn;
  cmp: TDnComparer;
begin
  Result := False;
  if not (DnTryParse(FSourceBase, s) and DnTryParse(FTargetBase, t)) then Exit;
  cmp := TDnComparer.Create;
  try
    Result := cmp.IsUnder(t, s, True) <> dmDifferent;
  finally
    cmp.Free;
  end;
end;

function TBranchTransfer.SubmitProbe: TTransferOutcome;
var
  err: TLdapError;
  i: Integer;
  known: Boolean;
begin
  known := False;
  for i := 0 to High(FDestId) do
    if FDestId[i] <> '' then known := True;
  FState := tsProbing;
  if not known then
    Exit(Stop(MakeError(lecOther, 0, 'move', rsTransferIdentityUnknown)));
  if not SessionsKept then Exit(SessionChanged);
  // Relecture par la connexion SOURCE d'une entree creee sur la destination. Une absence ne prouve
  // rien: replication en retard et ACL rendent le meme noSuchObject sur un seul et meme annuaire.
  FTask := FSource.ReadEntry(FPlan.Targets[0].Dn, TRANSFER_ID_ATTRS, err);
  if FTask = 0 then Exit(Stop(err));
  Result := toVerifying;
end;

function TBranchTransfer.HandleProbe(AMsg: TEntryMsg): TTransferOutcome;
var
  i: Integer;
  v: RawByteString;
  compared: Boolean;
begin
  FTask := 0;
  if AMsg.Entry = nil then
  begin
    if AMsg.Error.Category = lecNoSuchObject then
      Exit(Stop(MakeError(lecOther, 0, 'move',
        Format(rsTransferProbeAbsent, [FPlan.Targets[0].Dn]))));
    Exit(Stop(MakeError(lecOther, 0, 'move', rsTransferIdentityUnknown)));
  end;
  if AMsg.Entry.DecodeIncomplete or AMsg.Entry.AnyTruncated then
    Exit(Stop(MakeError(lecOther, 0, 'move', rsTransferIdentityUnknown)));
  compared := False;
  for i := 0 to High(TRANSFER_ID_ATTRS) do
  begin
    v := AMsg.Entry.FirstValue(TRANSFER_ID_ATTRS[i]);
    if (v = '') or (FDestId[i] = '') then Continue;
    compared := True;
    // Le moindre identifiant commun suffit a refuser la suppression. Paranoia assumee, elle coute
    // moins cher qu'une restauration.
    if (v = FDestId[i]) or SameText(v, FDestId[i]) then
      Exit(Stop(MakeError(lecOther, 0, 'move',
        Format(rsTransferSameDirectory, [FPlan.Targets[0].Dn]))));
  end;
  if not compared then
    Exit(Stop(MakeError(lecOther, 0, 'move', rsTransferIdentityUnknown)));
  Result := StartDeleting;
end;

function TBranchTransfer.StartDeleting: TTransferOutcome;
var
  i: Integer;
begin
  FState := tsDeleting;
  FDeleteQueue.Clear;
  for i := 0 to FPlan.Count - 1 do
    FDeleteQueue.AddObject(FPlan.SourceDns[i], TObject(PtrInt(i)));
  SortLeavesFirst(FDeleteQueue);
  Result := SubmitDelete;
end;

function TBranchTransfer.DeletesWithoutAssertion: Boolean;
var
  i: Integer;
begin
  Result := False;
  if not FMove or (FPlan = nil) then Exit;
  if not FAssertionControl then Exit(True);
  for i := 0 to FPlan.Count - 1 do
    if VersionAssertion(FPlan.Sources[i]) = '' then Exit(True);
end;

function TBranchTransfer.SubmitDelete: TTransferOutcome;
var
  dn, assertion: string;
  idx: PtrInt;
  err: TLdapError;
begin
  if FDeleteQueue.Count = 0 then
  begin
    FTask := 0;
    FState := tsFinished;
    Exit(toFinished);
  end;
  if not SessionsKept then Exit(SessionChanged);
  dn := FDeleteQueue[0];
  idx := PtrInt(FDeleteQueue.Objects[0]);
  FDeleteQueue.Delete(0);
  // Suppression conditionnee a la version lue (Assertion, RFC 4528): une entree modifiee
  // entre-temps n'est pas supprimee. Sans controle annonce, elle part sans, et la confirmation l'a
  // dit.
  assertion := '';
  if FAssertionControl then
    assertion := VersionAssertion(FPlan.Sources[idx]);
  FTask := FSource.Write(NewChange(ckDelete, dn), assertion, err);
  if FTask = 0 then
  begin
    FDeleteQueue.InsertObject(0, dn, TObject(idx));
    Exit(Stop(err));
  end;
  FInFlight := dn;
  Result := toDeleting;
end;

function SameDnValue(const A, B: string): Boolean;
var
  da, db: TLdapDn;
  cmp: TDnComparer;
begin
  if not (DnTryParse(A, da) and DnTryParse(B, db)) then Exit(False);
  cmp := TDnComparer.Create;
  try
    Result := DnStrictKey(cmp, da) = DnStrictKey(cmp, db);
  finally
    cmp.Free;
  end;
end;

// Le serveur rend ;binary ou l'omet a sa guise; les autres options (;lang-xx) doivent concorder
// exactement.
function DifferOnlyByBinary(const A, B: string): Boolean;
var
  da, db: TAttrDescription;
  used: array of Boolean;
  i, j: Integer;
  found: Boolean;

  function Kept(const AOpt: string): Boolean;
  begin
    Result := not SameText(AOpt, 'binary');
  end;

begin
  Result := False;
  da := ParseAttrDescription(A);
  db := ParseAttrDescription(B);
  if not SameText(da.Base, db.Base) then Exit;
  used := nil;
  SetLength(used, Length(db.Options));
  for i := 0 to High(da.Options) do
  begin
    if not Kept(da.Options[i]) then Continue;
    found := False;
    for j := 0 to High(db.Options) do
      if not used[j] and Kept(db.Options[j]) and SameText(da.Options[i], db.Options[j]) then
      begin
        used[j] := True;
        found := True;
        Break;
      end;
    if not found then Exit;
  end;
  for j := 0 to High(db.Options) do
    if Kept(db.Options[j]) and not used[j] then Exit;
  Result := True;
end;

function FindBinaryVariant(ARead: TLdapEntry; const ADescription: string): TLdapAttribute;
var
  i: Integer;
begin
  for i := 0 to ARead.AttrCount - 1 do
    if DifferOnlyByBinary(ADescription, ARead.Attrs[i].Description) then
      Exit(ARead.Attrs[i]);
  Result := nil;
end;

// Le serveur peut ajouter des valeurs (classes heritees, defauts), pas en perdre. Egalite binaire,
// sauf tolerance justifiee par le schema de la destination.
procedure TBranchTransfer.CompareWritten(APlanned, ARead: TLdapEntry);
var
  i, k, j: Integer;
  want, got: TLdapAttribute;
  found, allowText, allowDn: Boolean;
  eq: TRuleKind;
begin
  for i := 0 to APlanned.AttrCount - 1 do
  begin
    want := APlanned.Attrs[i];
    got := ARead.Find(want.Description);
    if got = nil then
      got := FindBinaryVariant(ARead, want.Description);
    if got = nil then
    begin
      FMismatch.Add(APlanned.Dn + ': ' + want.Description);
      Continue;
    end;
    allowText := False;
    allowDn := False;
    if FOptions.Schema <> nil then
    begin
      eq := RuleKindFromName(FOptions.Schema.EffectiveEquality(AttrBaseName(want.Description)));
      allowText := eq in [rkCaseIgnore, rkCaseIgnoreIA5];
      allowDn := (eq = rkDn) or IsDnValuedAttr(want.Description, FOptions.Schema);
    end;
    for k := 0 to want.ValueCount - 1 do
    begin
      found := got.IndexOfValue(want.Values[k]) >= 0;
      j := 0;
      while not found and (j < got.ValueCount) do
      begin
        if allowText then
          found := SameText(got.Values[j], want.Values[k]);
        if not found and allowDn then
          found := SameDnValue(got.Values[j], want.Values[k]);
        Inc(j);
      end;
      if not found then
      begin
        FMismatch.Add(APlanned.Dn + ': ' + want.Description);
        Break;
      end;
    end;
  end;
end;

function TBranchTransfer.HandleEntry(AMsg: TEntryMsg): TTransferOutcome;
var
  i: Integer;
begin
  if not OwnsTask(AMsg.TaskId) or not (FState in [tsVerifying, tsProbing]) then
    Exit(toNotMine);
  if FState = tsProbing then Exit(HandleProbe(AMsg));
  if AMsg.Entry = nil then
    Exit(Stop(MakeError(lecOther, 0, 'verify',
      Format(rsTransferVerifyMissing, [FPlan.Targets[FStep].Dn]))));
  // Relecture incomplete: elle ne confirme rien, la verification echoue.
  if AMsg.Entry.DecodeIncomplete or AMsg.Entry.AnyTruncated then
    Exit(Stop(MakeError(lecOther, 0, 'verify',
      Format(rsTransferVerifyTruncated, [FPlan.Targets[FStep].Dn]))));
  if not SessionsKept then Exit(SessionChanged);
  if FStep = 0 then
    for i := 0 to High(TRANSFER_ID_ATTRS) do
      FDestId[i] := AMsg.Entry.FirstValue(TRANSFER_ID_ATTRS[i]);
  CompareWritten(FPlan.Targets[FStep], AMsg.Entry);
  Inc(FVerified);
  Inc(FStep);
  Result := SubmitVerify;
end;

function TBranchTransfer.HandleWrite(AMsg: TWriteMsg): TTransferOutcome;
begin
  if not OwnsTask(AMsg.TaskId) or not (FState in [tsCopying, tsDeleting]) then
    Exit(toNotMine);
  if (not AMsg.Result.Ok) and (AMsg.Result.Error.Category = lecUnknownOutcome) then
    FUnknownOutcome := FInFlight;
  FInFlight := '';
  if not AMsg.Result.Ok then
  begin
    if FState = tsCopying then Inc(FStep);
    Exit(Stop(AMsg.Result.Error));
  end;
  if FState = tsCopying then
  begin
    FCreated.Add(FPlan.Targets[FStep].Dn);
    Inc(FStep);
    Exit(SubmitCopy);
  end;
  Inc(FDeleted);
  Result := SubmitDelete;
end;

end.
