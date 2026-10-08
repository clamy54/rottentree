// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uConnections;

{$mode objfpc}{$H+}

// Connexions ouvertes, cote interface. Chaque connexion a son fil et sa generation: apres une
// reconnexion, les messages de l'ancienne generation finissent a la poubelle. Lecture seule
// verifiee ici, puis encore dans la session: une seule serrure, c'est une invitation.

interface

uses
  SysUtils, Classes, Contnrs, uConnectionProfile, uDirectoryWorker, uSessionModel,
  uLdapEntry, uLdapSchema, uLdapErrors, uSearchModel, uChangeSet, uUiInbox, uCancel, uSensitive,
  uWriteJournal;

type
  // Identite d'une session a un instant. Une vue la capture avant une boucle modale et retrouve la
  // connexion par FindSame, plutot que de garder un pointeur qu'une reconnexion aurait libere.
  TSessionStamp = record
    ProfileUuid: string;
    SessionId: string;
    Generation: Int64;
    SchemaKey: string;
  end;

  TDirectoryConnection = class
  private
    FProfile: TConnectionProfile;
    FWorker: TDirectoryWorker;
    FSessionId: string;
    FGeneration: Int64;
    FShutdownWaitMs: Integer;
  public
    State: TConnState;
    Transport: TTransportInfo;
    RootDse: TLdapEntry;
    Schema: TSchemaSnapshot;
    SchemaReason: string;
    LastError: TLdapError;
    ConnectedAtMs: Int64;
    ConnectTaskId: Int64;
    LdifModified: Boolean;
    LdifRewriteNote: string;
    constructor Create(AProfile: TConnectionProfile; AGeneration: Int64);
    destructor Destroy; override;
    function IsReady: Boolean;
    function Accepts(AMsg: TUiMessage): Boolean;
    function DisplayState: string;
    procedure SetSchema(ASchema: TSchemaSnapshot);
    function Stamp: TSessionStamp;
    // Un secret ne s'ecrit que sur un canal chiffre, ou dans un fichier LDIF: rien ne quitte la
    // machine.
    function SecretsSafe: Boolean;
    property Profile: TConnectionProfile read FProfile;
    property Worker: TDirectoryWorker read FWorker;
    property SessionId: string read FSessionId;
    property Generation: Int64 read FGeneration;
  end;

  TConnectionEventKind = (cekNone, cekStepFailed, cekConnected, cekConnectFailed,
    cekConnectionLost, cekSchema, cekSchemaFailed, cekLdifSaved, cekLdifSaveFailed);

  TConnectionEvent = record
    Kind: TConnectionEventKind;
    Connection: TDirectoryConnection;
    Step: TConnectStepResult;
    Error: TLdapError;
    Summary: string;
    Warnings: TStringArray;
  end;

  TCommandSink = procedure(AConn: TDirectoryConnection; ACmd: TWorkerCommand);

  TConnectionManager = class
  private
    FList: TObjectList;
    FNextGeneration: Int64;
    procedure SubmitCommand(AConn: TDirectoryConnection; ACmd: TWorkerCommand);
  public
    function ApplyMessage(AMsg: TUiMessage; AOwner: Pointer; ASensitive: TSensitivePolicy;
      out AEvent: TConnectionEvent): Boolean;
  public
    SensitiveExtra: array of string;
    Journal: TWriteJournal;
    CommandSink: TCommandSink;
    procedure ApplySensitiveExtra(const AList: array of string);
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    function Item(AIndex: Integer): TDirectoryConnection;
    function Find(const AProfileUuid: string): TDirectoryConnection;
    function FindSession(const ASessionId: string): TDirectoryConnection;
    // nil si la connexion a ete fermee, remplacee ou son schema relu: ce qui a ete verifie et
    // confirme ne vaut plus.
    function FindSame(const AStamp: TSessionStamp): TDirectoryConnection;
    function Open(AProfile: TConnectionProfile; const ASecret: RawByteString;
      AOwner: Pointer): TDirectoryConnection;
    procedure Close(const AProfileUuid: string);
    procedure CloseAll(AWaitMs: Integer = 3000);
    function Search(AConn: TDirectoryConnection; const AReq: TSearchRequest; AOwner: Pointer;
      ATag: PtrInt; AAssembleRanges: Boolean = False): Int64;
    function ReadEntry(AConn: TDirectoryConnection; const ADn: string;
      const AAttrs: array of string; AOwner: Pointer; ATag: PtrInt): Int64; overload;
    function ReadEntry(AConn: TDirectoryConnection; const ADn: string;
      const AAttrs: array of string; const AControls: TRequestControlArray; AOwner: Pointer;
      ATag: PtrInt): Int64; overload;
    function Write(AConn: TDirectoryConnection; AChange: TLdapChange; const AAssertion: string;
      AOwner: Pointer; ATag: PtrInt; out AError: TLdapError): Int64; overload;
    function Write(AConn: TDirectoryConnection; AChange: TLdapChange; const AAssertion: string;
      AOwner: Pointer; ATag: PtrInt; const ARereadAttrs: array of string;
      out AError: TLdapError): Int64; overload;
    function Write(AConn: TDirectoryConnection; AChange: TLdapChange; const AAssertion: string;
      const AControls: TRequestControlArray; AOwner: Pointer; ATag: PtrInt;
      const ARereadAttrs: array of string; out AError: TLdapError): Int64; overload;
    function FetchSchema(AConn: TDirectoryConnection; AOwner: Pointer): Int64;
    function PasswordModify(AConn: TDirectoryConnection; const AUserDn: string;
      const AOld, ANew: RawByteString; AHasOld, AHasNew: Boolean; AOwner: Pointer;
      out AError: TLdapError): Int64;
    function SaveLdif(AConn: TDirectoryConnection; const APath: string; AOwner: Pointer): Int64;
    // Deux magasins sur le meme fichier l'ecriraient a tour de role. Le dernier gagne, l'autre
    // disparait.
    function LdifPathInUse(const APath: string; AExcept: TDirectoryConnection): TDirectoryConnection;
    procedure UseLdifSchema(AConn: TDirectoryConnection; ASchema: TSchemaSnapshot);
    function NoteDelivered(AMsg: TUiMessage): Boolean;
    procedure CancelTasks(AConn: TDirectoryConnection; AOwner: Pointer);
    // Une seule tache: abandonner une lecture ne doit pas emporter une ecriture en vol du meme
    // proprietaire.
    procedure CancelTask(AConn: TDirectoryConnection; ATaskId: Int64);
  end;

implementation

uses
  uDocumentCrypto, uSchemaReader, uServerKind;

resourcestring
  rsLdifNoSchema = 'an LDIF file carries no schema';
  rsLdifWritten = '%d entries written to %s';

constructor TDirectoryConnection.Create(AProfile: TConnectionProfile; AGeneration: Int64);
begin
  inherited Create;
  FProfile := TConnectionProfile.Create;
  FProfile.Assign(AProfile);
  FSessionId := NewUuidV4;
  FGeneration := AGeneration;
  FShutdownWaitMs := 3000;
  State := csConnecting;
  LastError := NoError;
  FWorker := TDirectoryWorker.Create(FProfile, FSessionId, FGeneration);
end;

destructor TDirectoryConnection.Destroy;
begin
  if FWorker <> nil then
  begin
    // Un fil encore bloque apres le delai est detache, pas tue: ses messages tardifs seront ignores
    // (session et generation perimees).
    FWorker.Release(FShutdownWaitMs);
    FWorker := nil;
  end;
  RootDse.Free;
  Schema.Free;
  FProfile.Free;
  inherited Destroy;
end;

function TDirectoryConnection.IsReady: Boolean;
begin
  Result := State = csReady;
end;

function TDirectoryConnection.Accepts(AMsg: TUiMessage): Boolean;
begin
  // Reponse tardive d'une session fermee ou remplacee: ignoree.
  Result := (AMsg.SessionId = FSessionId) and (AMsg.Generation = FGeneration);
end;

function TDirectoryConnection.DisplayState: string;
begin
  Result := ConnStateName(State);
end;

procedure TDirectoryConnection.SetSchema(ASchema: TSchemaSnapshot);
begin
  Schema.Free;
  Schema := ASchema;
end;

function TDirectoryConnection.SecretsSafe: Boolean;
begin
  Result := Transport.Encrypted or (FProfile.LdifPath <> '');
end;

function TDirectoryConnection.Stamp: TSessionStamp;
begin
  Result.ProfileUuid := FProfile.Uuid;
  Result.SessionId := FSessionId;
  Result.Generation := FGeneration;
  Result.SchemaKey := SchemaSnapshotKey(Schema);
end;

constructor TConnectionManager.Create;
begin
  inherited Create;
  FList := TObjectList.Create(True);
  FNextGeneration := 1;
end;

destructor TConnectionManager.Destroy;
begin
  CloseAll;
  FList.Free;
  inherited Destroy;
end;

function TConnectionManager.Count: Integer;
begin
  Result := FList.Count;
end;

function TConnectionManager.Item(AIndex: Integer): TDirectoryConnection;
begin
  Result := TDirectoryConnection(FList[AIndex]);
end;

function TConnectionManager.Find(const AProfileUuid: string): TDirectoryConnection;
var
  i: Integer;
begin
  for i := 0 to FList.Count - 1 do
    if Item(i).Profile.Uuid = AProfileUuid then Exit(Item(i));
  Result := nil;
end;

function TConnectionManager.FindSession(const ASessionId: string): TDirectoryConnection;
var
  i: Integer;
begin
  for i := 0 to FList.Count - 1 do
    if Item(i).SessionId = ASessionId then Exit(Item(i));
  Result := nil;
end;

function TConnectionManager.FindSame(const AStamp: TSessionStamp): TDirectoryConnection;
begin
  Result := Find(AStamp.ProfileUuid);
  if (Result = nil) or not Result.IsReady or (Result.SessionId <> AStamp.SessionId) or
     (Result.Generation <> AStamp.Generation) or
     (SchemaSnapshotKey(Result.Schema) <> AStamp.SchemaKey) then
    Result := nil;
end;

function TConnectionManager.Open(AProfile: TConnectionProfile; const ASecret: RawByteString;
  AOwner: Pointer): TDirectoryConnection;
var
  cmd: TConnectCmd;
begin
  Close(AProfile.Uuid);
  Result := TDirectoryConnection.Create(AProfile, FNextGeneration);
  Inc(FNextGeneration);
  FList.Add(Result);
  // Politique des attributs sensibles poussee avant la commande de connexion: la session la tient
  // des sa premiere commande.
  Result.Worker.SetSensitiveExtra(SensitiveExtra);
  cmd := TConnectCmd.Create(AOwner);
  cmd.Secret := ASecret;
  Result.ConnectTaskId := cmd.TaskId;
  Result.Worker.Enqueue(cmd);
end;

procedure TConnectionManager.ApplySensitiveExtra(const AList: array of string);
var
  i: Integer;
begin
  SetLength(SensitiveExtra, Length(AList));
  for i := 0 to High(AList) do
    SensitiveExtra[i] := AList[i];
  // Hors de la file annulable: une purge ne doit pas faire disparaitre un changement de politique.
  for i := 0 to FList.Count - 1 do
    Item(i).Worker.SetSensitiveExtra(AList);
end;

procedure TConnectionManager.Close(const AProfileUuid: string);
var
  c: TDirectoryConnection;
begin
  c := Find(AProfileUuid);
  if c <> nil then
    FList.Remove(c);
end;

procedure TConnectionManager.CloseAll(AWaitMs: Integer);
var
  deadline, remaining: Int64;
begin
  // Echeance globale: dix connexions bloquees n'ont pas droit a dix delais.
  deadline := MonotonicMs + AWaitMs;
  while FList.Count > 0 do
  begin
    remaining := deadline - MonotonicMs;
    if remaining < 0 then remaining := 0;
    TDirectoryConnection(FList[FList.Count - 1]).FShutdownWaitMs := remaining;
    FList.Delete(FList.Count - 1);
  end;
end;

procedure TConnectionManager.SubmitCommand(AConn: TDirectoryConnection; ACmd: TWorkerCommand);
begin
  if Assigned(CommandSink) then
    CommandSink(AConn, ACmd)
  else
    AConn.Worker.Enqueue(ACmd);
end;

function TConnectionManager.Search(AConn: TDirectoryConnection; const AReq: TSearchRequest;
  AOwner: Pointer; ATag: PtrInt; AAssembleRanges: Boolean): Int64;
var
  cmd: TSearchCmd;
begin
  cmd := TSearchCmd.Create(AOwner);
  cmd.Request := AReq;
  cmd.Tag := ATag;
  cmd.BatchSize := 200;
  cmd.AssembleRanges := AAssembleRanges;
  Result := cmd.TaskId;
  SubmitCommand(AConn, cmd);
end;

function TConnectionManager.ReadEntry(AConn: TDirectoryConnection; const ADn: string;
  const AAttrs: array of string; AOwner: Pointer; ATag: PtrInt): Int64;
begin
  Result := ReadEntry(AConn, ADn, AAttrs, nil, AOwner, ATag);
end;

function TConnectionManager.ReadEntry(AConn: TDirectoryConnection; const ADn: string;
  const AAttrs: array of string; const AControls: TRequestControlArray; AOwner: Pointer;
  ATag: PtrInt): Int64;
var
  cmd: TReadEntryCmd;
  i: Integer;
begin
  cmd := TReadEntryCmd.Create(AOwner);
  cmd.Dn := ADn;
  cmd.Tag := ATag;
  SetLength(cmd.Attributes, Length(AAttrs));
  for i := 0 to High(AAttrs) do
    cmd.Attributes[i] := AAttrs[i];
  cmd.Controls := Copy(AControls, 0, Length(AControls));
  Result := cmd.TaskId;
  SubmitCommand(AConn, cmd);
end;

function TConnectionManager.Write(AConn: TDirectoryConnection; AChange: TLdapChange;
  const AAssertion: string; AOwner: Pointer; ATag: PtrInt; out AError: TLdapError): Int64;
begin
  Result := Write(AConn, AChange, AAssertion, AOwner, ATag, [], AError);
end;

function TConnectionManager.Write(AConn: TDirectoryConnection; AChange: TLdapChange;
  const AAssertion: string; AOwner: Pointer; ATag: PtrInt; const ARereadAttrs: array of string;
  out AError: TLdapError): Int64;
begin
  Result := Write(AConn, AChange, AAssertion, nil, AOwner, ATag, ARereadAttrs, AError);
end;

function TConnectionManager.Write(AConn: TDirectoryConnection; AChange: TLdapChange;
  const AAssertion: string; const AControls: TRequestControlArray; AOwner: Pointer; ATag: PtrInt;
  const ARereadAttrs: array of string; out AError: TLdapError): Int64;
var
  cmd: TWriteCmd;
  i: Integer;
begin
  Result := 0;
  AError := NoError;
  if AConn.Profile.ReadOnly then
  begin
    AError := MakeError(lecReadOnly, 0, ChangeKindName(AChange.Kind), 'this profile is read-only');
    AChange.Free;
    Exit;
  end;
  if not AConn.IsReady then
  begin
    AChange.Free;
    AError := MakeError(lecNetwork, 0, 'write', 'not connected');
    Exit;
  end;
  cmd := TWriteCmd.Create(AOwner);
  cmd.Change := AChange;
  cmd.AssertionFilter := AAssertion;
  SetLength(cmd.RereadAttributes, Length(ARereadAttrs));
  for i := 0 to High(ARereadAttrs) do
    cmd.RereadAttributes[i] := ARereadAttrs[i];
  cmd.Tag := ATag;
  cmd.RequestControls := Copy(AControls, 0, Length(AControls));
  Result := cmd.TaskId;
  // Journal ecrit a la soumission, avant tout resultat: si la reponse ne vient jamais, on sait au
  // moins ce qui est parti, et depuis quel document.
  if Journal <> nil then
    Journal.RegisterWrite(cmd.TaskId, AConn.Profile.Uuid);
  SubmitCommand(AConn, cmd);
end;

function TConnectionManager.FetchSchema(AConn: TDirectoryConnection; AOwner: Pointer): Int64;
var
  cmd: TSchemaCmd;
begin
  cmd := TSchemaCmd.Create(AOwner);
  cmd.SubschemaDn := SubschemaDnFromRootDse(AConn.RootDse);
  if (AConn.RootDse <> nil) and
     ((EffectiveServerKind(AConn.Profile, AConn.RootDse) = pkActiveDirectory) or
      DetectServerKind(AConn.RootDse).AdLds) then
    cmd.AdSchemaDn := string(AConn.RootDse.FirstValue('schemaNamingContext', ''));
  Result := cmd.TaskId;
  SubmitCommand(AConn, cmd);
end;

function TConnectionManager.PasswordModify(AConn: TDirectoryConnection; const AUserDn: string;
  const AOld, ANew: RawByteString; AHasOld, AHasNew: Boolean; AOwner: Pointer;
  out AError: TLdapError): Int64;
var
  cmd: TPasswordModifyCmd;
begin
  Result := 0;
  AError := NoError;
  if AConn.Profile.ReadOnly then
  begin
    AError := MakeError(lecReadOnly, 0, 'password modify', 'this profile is read-only');
    Exit;
  end;
  cmd := TPasswordModifyCmd.Create(AOwner);
  cmd.UserDn := AUserDn;
  cmd.OldSecret := AOld;
  cmd.NewSecret := ANew;
  cmd.HasOld := AHasOld;
  cmd.HasNew := AHasNew;
  Result := cmd.TaskId;
  // Password Modify journalise comme le reste: son issue inconnue passe par
  // RecordUnknownOutcomeRaw, faute de TLdapChange.
  if Journal <> nil then
    Journal.RegisterWrite(cmd.TaskId, AConn.Profile.Uuid);
  SubmitCommand(AConn, cmd);
end;

function TConnectionManager.ApplyMessage(AMsg: TUiMessage; AOwner: Pointer;
  ASensitive: TSensitivePolicy; out AEvent: TConnectionEvent): Boolean;
var
  c: TDirectoryConnection;
  cm: TConnectedMsg;
begin
  AEvent := Default(TConnectionEvent);
  Result := False;
  c := FindSession(AMsg.SessionId);
  if (c = nil) or not c.Accepts(AMsg) then Exit;
  AEvent.Connection := c;
  if AMsg is TStepMsg then
  begin
    if not TStepMsg(AMsg).Step.Ok then
    begin
      AEvent.Kind := cekStepFailed;
      AEvent.Step := TStepMsg(AMsg).Step;
    end;
    Exit(True);
  end;
  if AMsg is TConnectedMsg then
  begin
    cm := TConnectedMsg(AMsg);
    c.Transport := cm.Transport;
    c.LastError := cm.Error;
    if cm.Ok then
    begin
      c.State := csReady;
      c.ConnectedAtMs := MonotonicMs;
      c.RootDse.Free;
      c.RootDse := cm.RootDse;
      cm.RootDse := nil;
      AEvent.Summary := cm.Summary;
      AEvent.Warnings := cm.Warnings;
      c.LdifModified := False;
      c.LdifRewriteNote := cm.RewriteNote;
      if (c.Profile.LdifPath <> '') and (SubschemaDnFromRootDse(c.RootDse) = '') then
        c.SchemaReason := rsLdifNoSchema
      else
        FetchSchema(c, AOwner);
      AEvent.Kind := cekConnected;
    end
    else
    begin
      c.State := csFailed;
      AEvent.Kind := cekConnectFailed;
      AEvent.Error := cm.Error;
    end;
    Exit(True);
  end;
  // Session fermee par le serveur ou le reseau, constatee par le maintien de session: l'etat
  // change tout de suite au lieu d'attendre l'echec de la prochaine commande.
  if AMsg is TDisconnectedMsg then
  begin
    if c.State = csReady then
    begin
      c.State := csDisconnected;
      c.LastError := TDisconnectedMsg(AMsg).Error;
      AEvent.Kind := cekConnectionLost;
      AEvent.Error := TDisconnectedMsg(AMsg).Error;
    end;
    Exit(True);
  end;
  if AMsg is TLdifSavedMsg then
  begin
    if TLdifSavedMsg(AMsg).Ok then
    begin
      c.LdifModified := False;
      c.LdifRewriteNote := '';
      c.Profile.LdifPath := TLdifSavedMsg(AMsg).Path;
      c.Profile.Name := ExtractFileName(TLdifSavedMsg(AMsg).Path);
      AEvent.Kind := cekLdifSaved;
      AEvent.Summary := Format(rsLdifWritten, [TLdifSavedMsg(AMsg).EntryCount,
        TLdifSavedMsg(AMsg).Path]);
    end
    else
    begin
      AEvent.Kind := cekLdifSaveFailed;
      AEvent.Error := TLdifSavedMsg(AMsg).Error;
    end;
    Exit(True);
  end;
  if AMsg is TSchemaMsg then
  begin
    // Lecture du schema en echec: le dernier schema utilisable est garde, declare perime, avec la
    // raison. Un vieux schema vaut mieux que pas de schema du tout.
    if TSchemaMsg(AMsg).Schema = nil then
    begin
      c.SchemaReason := TSchemaMsg(AMsg).Reason;
      if c.Schema <> nil then c.Schema.Stale := True;
      AEvent.Kind := cekSchemaFailed;
      Exit(True);
    end;
    // Une reponse ancienne ne remplace jamais un schema plus recent: les fils ne repondent pas dans
    // l'ordre.
    if (c.Schema <> nil) and (TSchemaMsg(AMsg).Schema <> nil) and
       (TSchemaMsg(AMsg).Schema.FetchedUtc < c.Schema.FetchedUtc) then
    begin
      AEvent.Kind := cekNone;
      Exit(True);
    end;
    c.SetSchema(TSchemaMsg(AMsg).Schema);
    TSchemaMsg(AMsg).Schema := nil;
    c.SchemaReason := TSchemaMsg(AMsg).Reason;
    if (ASensitive <> nil) and (c.Schema <> nil) then
      ASensitive.LearnSchema(c.Schema);
    AEvent.Kind := cekSchema;
    Exit(True);
  end;
end;

function TConnectionManager.SaveLdif(AConn: TDirectoryConnection; const APath: string;
  AOwner: Pointer): Int64;
var
  cmd: TLdifSaveCmd;
begin
  cmd := TLdifSaveCmd.Create(AOwner);
  cmd.Path := APath;
  Result := cmd.TaskId;
  SubmitCommand(AConn, cmd);
end;

function TConnectionManager.LdifPathInUse(const APath: string;
  AExcept: TDirectoryConnection): TDirectoryConnection;
var
  i: Integer;
  c: TDirectoryConnection;
begin
  Result := nil;
  for i := 0 to Count - 1 do
  begin
    c := Item(i);
    if (c = AExcept) or (c.Profile.LdifPath = '') then Continue;
    if c.State in [csDisconnected, csFailed, csCancelled] then Continue;
    if SameFileName(ExpandFileName(c.Profile.LdifPath), ExpandFileName(APath)) then
      Exit(c);
  end;
end;

procedure TConnectionManager.UseLdifSchema(AConn: TDirectoryConnection; ASchema: TSchemaSnapshot);
var
  cmd: TLdifSchemaCmd;
begin
  cmd := TLdifSchemaCmd.Create(nil);
  try
    cmd.Schema := ASchema.Clone;
  except
    cmd.Free;
    ASchema.Free;
    raise;
  end;
  AConn.SetSchema(ASchema);
  AConn.SchemaReason := '';
  SubmitCommand(AConn, cmd);
end;

function TConnectionManager.NoteDelivered(AMsg: TUiMessage): Boolean;
var
  c: TDirectoryConnection;
  ok: Boolean;
begin
  Result := False;
  if AMsg is TWriteMsg then ok := TWriteMsg(AMsg).Result.Ok
  else if AMsg is TPasswordMsg then ok := TPasswordMsg(AMsg).Result.Ok
  else Exit;
  if not ok then Exit;
  c := FindSession(AMsg.SessionId);
  if (c = nil) or (c.Profile.LdifPath = '') or c.LdifModified then Exit;
  c.LdifModified := True;
  Result := True;
end;

procedure TConnectionManager.CancelTasks(AConn: TDirectoryConnection; AOwner: Pointer);
begin
  // Les vues partagent le fil du profil: seule l'annulation ciblee sort d'ici. Un CancelAll, et la
  // vue d'a cote perd ses taches sans comprendre pourquoi.
  if (AConn <> nil) and (AConn.Worker <> nil) then
    AConn.Worker.CancelOwned(AOwner);
end;

procedure TConnectionManager.CancelTask(AConn: TDirectoryConnection; ATaskId: Int64);
begin
  if (AConn <> nil) and (AConn.Worker <> nil) then
    AConn.Worker.CancelTask(ATaskId);
end;

end.
