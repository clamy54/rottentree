// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uProfileProbe;

{$mode objfpc}{$H+}

// Connexion temporaire du dialogue de profil: recherche des bases et test de connexion en etapes,
// avec les parametres du formulaire. Session dediee; toucher a un parametre arrete la sonde et rend
// ses resultats caducs.

interface

uses
  SysUtils, Classes, uConnectionProfile, uLdapEntry, uUiInbox, uDirectoryWorker;

type
  TProbeKind = (pkFetchBases, pkTest);

  TBaseDnCandidate = record
    Dn: string;
    Origin: string;
  end;
  TBaseDnCandidates = array of TBaseDnCandidate;

  TProfileProbe = class
  private
    FWorker: TDirectoryWorker;
    FTaskId: Int64;
    FKind: TProbeKind;
  public
    destructor Destroy; override;
    // Le secret part avec la commande de connexion, qui l'efface apres usage; l'appelant efface sa
    // copie.
    procedure Start(AProfile: TConnectionProfile; const ASecret: RawByteString;
      AKind: TProbeKind; AOwner: Pointer);
    procedure Stop(AWaitMs: Integer = 1500);
    function Accepts(AMsg: TUiMessage): Boolean;
    function Running: Boolean;
    property Kind: TProbeKind read FKind;
  end;

// Aucune base n'est deduite du nom DNS du serveur: deviner, c'est se tromper avec assurance.
function BaseDnCandidates(ARootDse: TLdapEntry): TBaseDnCandidates;

implementation

uses
  uDocumentCrypto;

const
  BASE_SOURCES: array[0..4] of string = ('namingContexts', 'defaultNamingContext',
    'rootDomainNamingContext', 'configurationNamingContext', 'schemaNamingContext');

function BaseDnCandidates(ARootDse: TLdapEntry): TBaseDnCandidates;
var
  s, i, k: Integer;
  a: TLdapAttribute;
  v: string;
  dup: Boolean;
begin
  Result := nil;
  if ARootDse = nil then Exit;
  for s := 0 to High(BASE_SOURCES) do
  begin
    a := ARootDse.Find(BASE_SOURCES[s]);
    if a = nil then Continue;
    for i := 0 to a.ValueCount - 1 do
    begin
      v := Trim(a.Values[i]);
      if v = '' then Continue;
      dup := False;
      for k := 0 to High(Result) do
        if SameText(Result[k].Dn, v) then
        begin
          dup := True;
          Break;
        end;
      if dup then Continue;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].Dn := v;
      Result[High(Result)].Origin := BASE_SOURCES[s];
    end;
  end;
end;

destructor TProfileProbe.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TProfileProbe.Start(AProfile: TConnectionProfile; const ASecret: RawByteString;
  AKind: TProbeKind; AOwner: Pointer);
var
  tmp: TConnectionProfile;
  cmd: TConnectCmd;
begin
  Stop;
  tmp := TConnectionProfile.Create;
  try
    tmp.Assign(AProfile);
    tmp.Uuid := 'profile-probe';
    // Identite completee AVANT de vider les bases: le bind reste celui du profil.
    tmp.BindDn := EffectiveBindDn(tmp);
    tmp.AppendBaseDn := False;
    if AKind = pkFetchBases then tmp.BaseDns.Clear;
    // Session propre a cette sonde: aucun message d'une sonde precedente ne peut passer pour le
    // sien.
    FWorker := TDirectoryWorker.Create(tmp, 'probe-' + NewUuidV4, 1);
    cmd := TConnectCmd.Create(AOwner);
    cmd.Secret := ASecret;
    FTaskId := cmd.TaskId;
    FKind := AKind;
    FWorker.Enqueue(cmd);
  finally
    tmp.Free;
  end;
end;

procedure TProfileProbe.Stop(AWaitMs: Integer);
begin
  FTaskId := 0;
  if FWorker <> nil then
  begin
    FWorker.Release(AWaitMs);
    FWorker := nil;
  end;
end;

function TProfileProbe.Accepts(AMsg: TUiMessage): Boolean;
begin
  Result := (FWorker <> nil) and (FTaskId <> 0) and (AMsg.TaskId = FTaskId) and
    (AMsg.SessionId = FWorker.SessionId);
end;

function TProfileProbe.Running: Boolean;
begin
  Result := FWorker <> nil;
end;

end.
