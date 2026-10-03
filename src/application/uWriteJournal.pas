// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uWriteJournal;

{$mode objfpc}{$H+}

// Journal des ecritures LDAP soumises, fil de l'interface uniquement. Document et profil sont
// captures a la soumission et rattaches par l'UUID du document: une adresse memoire se recycle, un
// chemin peut cacher un autre fichier. Une issue inconnue n'atterrit que dans son document
// d'origine, quitte a attendre qu'il revienne.

interface

uses
  SysUtils, Classes, uRtDocument, uChangeSet, uLdapErrors;

type
  // DocUuid vide: jamais rattachable. Conservee mais jamais flushee, pour ne pas polluer le journal
  // d'un autre document.
  THeldOutcome = record
    ProfileUuid: string;
    Kind: string;
    Dn: string;
    Detail: string;
    DocUuid: string;
  end;

  TPendingWrite = record
    TaskId: Int64;
    ProfileUuid: string;
    DocUuid: string;
  end;

  TWriteJournal = class
  private
    FActive: TRtDocument;
    FPending: array of TPendingWrite;
    FHeld: array of THeldOutcome;
    function FindPending(ATaskId: Int64): Integer;
    procedure RemovePending(AIndex: Integer);
    procedure Hold(const AProfileUuid, AKind, ADn, ADetail, ADocUuid: string);
    procedure FlushInto(ADoc: TRtDocument);
  public
    // A appeler juste apres chaque affectation du document du contexte, et AVANT de transferer un
    // document a son fil de sauvegarde.
    procedure SetActiveDocument(ADoc: TRtDocument);
    procedure RegisterWrite(ATaskId: Int64; const AProfileUuid: string);
    procedure Resolve(ATaskId: Int64);
    procedure RecordUnknownOutcome(ATaskId: Int64; const AFallbackProfileUuid: string;
      AChange: TLdapChange; const AError: TLdapError; const ADetail: string = '');
    procedure RecordUnknownOutcomeRaw(ATaskId: Int64; const AFallbackProfileUuid: string;
      const AKind, ADn: string; const AError: TLdapError; const ADetail: string = '');
    procedure DocumentForked(const AOldUuid, ANewUuid: string);
    function IsPending(ATaskId: Int64): Boolean;
    function PendingWriteCount: Integer;
    function HeldCount: Integer;
    function HeldItem(AIndex: Integer): THeldOutcome;
    property ActiveDocument: TRtDocument read FActive;
  end;

implementation

function TWriteJournal.FindPending(ATaskId: Int64): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FPending) do
    if FPending[i].TaskId = ATaskId then Exit(i);
  Result := -1;
end;

procedure TWriteJournal.RemovePending(AIndex: Integer);
var
  i: Integer;
begin
  for i := AIndex to High(FPending) - 1 do
    FPending[i] := FPending[i + 1];
  SetLength(FPending, Length(FPending) - 1);
end;

procedure TWriteJournal.Hold(const AProfileUuid, AKind, ADn, ADetail, ADocUuid: string);
begin
  SetLength(FHeld, Length(FHeld) + 1);
  with FHeld[High(FHeld)] do
  begin
    ProfileUuid := AProfileUuid;
    Kind := AKind;
    Dn := ADn;
    Detail := ADetail;
    DocUuid := ADocUuid;
  end;
end;

procedure TWriteJournal.FlushInto(ADoc: TRtDocument);
var
  i, j: Integer;
begin
  if ADoc.Uuid = '' then Exit;
  i := 0;
  while i <= High(FHeld) do
    if (FHeld[i].DocUuid <> '') and (FHeld[i].DocUuid = ADoc.Uuid) then
    begin
      ADoc.AppendAudit(FHeld[i].ProfileUuid, FHeld[i].Kind, FHeld[i].Dn, FHeld[i].Detail);
      for j := i to High(FHeld) - 1 do
        FHeld[j] := FHeld[j + 1];
      SetLength(FHeld, Length(FHeld) - 1);
    end
    else
      Inc(i);
end;

procedure TWriteJournal.SetActiveDocument(ADoc: TRtDocument);
begin
  FActive := ADoc;
  if FActive <> nil then
    FlushInto(FActive);
end;

procedure TWriteJournal.RegisterWrite(ATaskId: Int64; const AProfileUuid: string);
begin
  SetLength(FPending, Length(FPending) + 1);
  with FPending[High(FPending)] do
  begin
    TaskId := ATaskId;
    ProfileUuid := AProfileUuid;
    if FActive <> nil then DocUuid := FActive.Uuid else DocUuid := '';
  end;
end;

procedure TWriteJournal.DocumentForked(const AOldUuid, ANewUuid: string);
var
  i: Integer;
begin
  if (AOldUuid = '') or (ANewUuid = '') or (AOldUuid = ANewUuid) then Exit;
  for i := 0 to High(FPending) do
    if FPending[i].DocUuid = AOldUuid then
      FPending[i].DocUuid := ANewUuid;
  for i := 0 to High(FHeld) do
    if FHeld[i].DocUuid = AOldUuid then
      FHeld[i].DocUuid := ANewUuid;
  if FActive <> nil then
    FlushInto(FActive);
end;

procedure TWriteJournal.Resolve(ATaskId: Int64);
var
  i: Integer;
begin
  i := FindPending(ATaskId);
  if i >= 0 then RemovePending(i);
end;

procedure TWriteJournal.RecordUnknownOutcomeRaw(ATaskId: Int64;
  const AFallbackProfileUuid: string; const AKind, ADn: string;
  const AError: TLdapError; const ADetail: string);
var
  i: Integer;
  rec: TPendingWrite;
  detail: string;
begin
  detail := ADetail;
  if detail = '' then
    detail := 'unknown outcome: ' + ErrorToText(AError);
  i := FindPending(ATaskId);
  if i >= 0 then
  begin
    rec := FPending[i];
    RemovePending(i);
    // Consignation immediate seulement si le document ACTIF porte l'UUID de la soumission. Ferme,
    // verrouille ou remplace, il ne recoit rien maintenant: il appartient peut-etre deja a son fil
    // de sauvegarde.
    if (rec.DocUuid <> '') and (FActive <> nil) and (rec.DocUuid = FActive.Uuid) then
      FActive.AppendAudit(rec.ProfileUuid, AKind, ADn, detail)
    else
      Hold(rec.ProfileUuid, AKind, ADn, detail, rec.DocUuid);
  end
  else
    // Tache non enregistree: UUID vide, donc jamais consignee dans un document qui n'est pas le
    // sien.
    Hold(AFallbackProfileUuid, AKind, ADn, detail, '');
end;

procedure TWriteJournal.RecordUnknownOutcome(ATaskId: Int64; const AFallbackProfileUuid: string;
  AChange: TLdapChange; const AError: TLdapError; const ADetail: string);
begin
  if AChange = nil then Exit;
  RecordUnknownOutcomeRaw(ATaskId, AFallbackProfileUuid, ChangeKindName(AChange.Kind),
    AChange.Dn, AError, ADetail);
end;

function TWriteJournal.IsPending(ATaskId: Int64): Boolean;
begin
  Result := FindPending(ATaskId) >= 0;
end;

function TWriteJournal.PendingWriteCount: Integer;
begin
  Result := Length(FPending);
end;

function TWriteJournal.HeldCount: Integer;
begin
  Result := Length(FHeld);
end;

function TWriteJournal.HeldItem(AIndex: Integer): THeldOutcome;
begin
  Result := FHeld[AIndex];
end;

end.
