// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPasswordWork;

{$mode objfpc}{$H+}

// Outils de mot de passe hors du fil graphique, sous un superviseur unique: concurrence bornee,
// annulation par jeton, secrets effaces a la mort de chaque fil, aucun fil tue de force. Un calcul
// deja engage retarde la sortie de ce qu'il lui reste, jamais plus.

interface

uses
  SysUtils, Classes, uPwdCore, uPasswordSchemes, uUiInbox, uCancel;

type
  TPwdWorkKind = (pwkVerify, pwkGenerate);

  TPwdWorkMsg = class(TUiMessage)
  public
    Kind: TPwdWorkKind;
    Multi: TPwdMultiResult;
    Generated: RawByteString;
    ErrorText: string;
    Cancelled: Boolean;
    destructor Destroy; override;
  end;

  TPwdWorkThread = class(TThread)
  private
    FOwner: Pointer;
    FTaskId: Int64;
    FCancel: TCancelToken;
  protected
    procedure Run; virtual; abstract;
    procedure Execute; override;
    property Cancel: TCancelToken read FCancel;
  public
    constructor Create(AOwner: Pointer; ATaskId: Int64);
    destructor Destroy; override;
    property Owner: Pointer read FOwner;
    property TaskId: Int64 read FTaskId;
  end;

  TPwdComputeThread = class(TPwdWorkThread)
  private
    FKind: TPwdWorkKind;
    FValues: array of RawByteString;
    FPassword: RawByteString;
    FSchemeId: string;
    procedure WipeSecrets;
  protected
    procedure Run; override;
  public
    constructor CreateVerify(const AValues: array of RawByteString; const APassword: RawByteString;
      AOwner: Pointer; ATaskId: Int64);
    constructor CreateGenerate(const ASchemeId: string; const APassword: RawByteString;
      AOwner: Pointer; ATaskId: Int64);
    destructor Destroy; override;
  end;

  TPwdWorkSupervisor = class
  private
    FLock: TRTLCriticalSection;
    FThreads: TList;
    FMaxConcurrent: Integer;
    procedure Collect;
  public
    constructor Create(AMaxConcurrent: Integer = 4);
    destructor Destroy; override;
    function Launch(AThread: TPwdWorkThread): Boolean;
    function StartVerify(const AValues: array of RawByteString; const APassword: RawByteString;
      AOwner: Pointer; ATaskId: Int64): Boolean;
    function StartGenerate(const ASchemeId: string; const APassword: RawByteString;
      AOwner: Pointer; ATaskId: Int64): Boolean;
    procedure CancelOwner(AOwner: Pointer);
    procedure CancelAll;
    function WaitAll(AWaitMs: Integer): Boolean;
    function ActiveCount: Integer;
  end;

function PasswordWork: TPwdWorkSupervisor;

implementation

uses
  uRtBytes;

var
  GSupervisor: TPwdWorkSupervisor;

function PasswordWork: TPwdWorkSupervisor;
begin
  // Cree a l'initialisation de l'unite: pas de creation paresseuse a se disputer entre fils.
  Result := GSupervisor;
end;

destructor TPwdWorkMsg.Destroy;
begin
  WipeString(Generated);
  inherited Destroy;
end;

constructor TPwdWorkThread.Create(AOwner: Pointer; ATaskId: Int64);
begin
  FOwner := AOwner;
  FTaskId := ATaskId;
  FCancel := TCancelToken.Create;
  FreeOnTerminate := False;
  inherited Create(True);
end;

destructor TPwdWorkThread.Destroy;
begin
  FCancel.Free;
  inherited Destroy;
end;

procedure TPwdWorkThread.Execute;
begin
  try
    Run;
  except
  end;
end;

constructor TPwdComputeThread.CreateVerify(const AValues: array of RawByteString;
  const APassword: RawByteString; AOwner: Pointer; ATaskId: Int64);
var
  i: Integer;
begin
  FKind := pwkVerify;
  SetLength(FValues, Length(AValues));
  for i := 0 to High(AValues) do
  begin
    FValues[i] := AValues[i];
    UniqueString(FValues[i]);
  end;
  FPassword := APassword;
  UniqueString(FPassword);
  inherited Create(AOwner, ATaskId);
end;

constructor TPwdComputeThread.CreateGenerate(const ASchemeId: string; const APassword: RawByteString;
  AOwner: Pointer; ATaskId: Int64);
begin
  FKind := pwkGenerate;
  FSchemeId := ASchemeId;
  FPassword := APassword;
  UniqueString(FPassword);
  inherited Create(AOwner, ATaskId);
end;

destructor TPwdComputeThread.Destroy;
begin
  WipeSecrets;
  inherited Destroy;
end;

procedure TPwdComputeThread.WipeSecrets;
var
  i: Integer;
begin
  WipeString(FPassword);
  for i := 0 to High(FValues) do WipeString(FValues[i]);
end;

procedure TPwdComputeThread.Run;
var
  m: TPwdWorkMsg;
  sch: TPasswordScheme;
begin
  m := TPwdWorkMsg.Create;
  m.Owner := FOwner;
  m.TaskId := FTaskId;
  m.Kind := FKind;
  try
    case FKind of
      pwkVerify:
        // Aucune normalisation Unicode, aucun trim: on compare les octets saisis, pas ce que
        // l'utilisateur voulait sans doute dire.
        m.Multi := VerifyPasswordValues(FValues, FPassword, FCancel);
      pwkGenerate:
        begin
          sch := PasswordRegistry.FindById(FSchemeId);
          if sch = nil then
            m.ErrorText := 'unknown format'
          else if not FCancel.IsCancelled then
            m.Generated := sch.Generate(FPassword, DefaultGenParams);
        end;
    end;
  except
    on E: Exception do
      m.ErrorText := E.Message;
  end;
  WipeSecrets;
  if FCancel.IsCancelled then
  begin
    // Calcul annule: aucun secret derive ne quitte le fil.
    WipeString(m.Generated);
    m.Cancelled := True;
    m.ErrorText := 'cancelled';
  end;
  UiInbox.Post(m);
end;

constructor TPwdWorkSupervisor.Create(AMaxConcurrent: Integer);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FThreads := TList.Create;
  FMaxConcurrent := AMaxConcurrent;
  if FMaxConcurrent < 1 then FMaxConcurrent := 1;
end;

destructor TPwdWorkSupervisor.Destroy;
var
  i: Integer;
  t: TPwdWorkThread;
begin
  // Fin de processus: annulation puis jointure de chaque fil. Le registre des formats et la boite
  // de l'interface sont finalises apres cette unite, donc jamais detruits sous un fil actif.
  CancelAll;
  EnterCriticalSection(FLock);
  try
    for i := FThreads.Count - 1 downto 0 do
    begin
      t := TPwdWorkThread(FThreads[i]);
      t.WaitFor;
      t.Free;
      FThreads.Delete(i);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  FThreads.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TPwdWorkSupervisor.Collect;
var
  i: Integer;
  t: TPwdWorkThread;
begin
  for i := FThreads.Count - 1 downto 0 do
  begin
    t := TPwdWorkThread(FThreads[i]);
    if t.Finished then
    begin
      t.WaitFor;
      t.Free;
      FThreads.Delete(i);
    end;
  end;
end;

function TPwdWorkSupervisor.Launch(AThread: TPwdWorkThread): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Collect;
    Result := FThreads.Count < FMaxConcurrent;
    if Result then
    begin
      FThreads.Add(AThread);
      AThread.Start;
    end
    else
      // Limite atteinte: le fil suspendu est detruit avec ses secrets, il ne fera pas la queue.
      AThread.Free;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPwdWorkSupervisor.StartVerify(const AValues: array of RawByteString;
  const APassword: RawByteString; AOwner: Pointer; ATaskId: Int64): Boolean;
begin
  Result := Launch(TPwdComputeThread.CreateVerify(AValues, APassword, AOwner, ATaskId));
end;

function TPwdWorkSupervisor.StartGenerate(const ASchemeId: string; const APassword: RawByteString;
  AOwner: Pointer; ATaskId: Int64): Boolean;
begin
  Result := Launch(TPwdComputeThread.CreateGenerate(ASchemeId, APassword, AOwner, ATaskId));
end;

procedure TPwdWorkSupervisor.CancelOwner(AOwner: Pointer);
var
  i: Integer;
begin
  EnterCriticalSection(FLock);
  try
    for i := 0 to FThreads.Count - 1 do
      if TPwdWorkThread(FThreads[i]).Owner = AOwner then
        TPwdWorkThread(FThreads[i]).FCancel.Cancel;
    Collect;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TPwdWorkSupervisor.CancelAll;
var
  i: Integer;
begin
  EnterCriticalSection(FLock);
  try
    for i := 0 to FThreads.Count - 1 do
      TPwdWorkThread(FThreads[i]).FCancel.Cancel;
    Collect;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TPwdWorkSupervisor.WaitAll(AWaitMs: Integer): Boolean;
var
  waited: Integer;
begin
  CancelAll;
  waited := 0;
  while (ActiveCount > 0) and (waited < AWaitMs) do
  begin
    Sleep(10);
    Inc(waited, 10);
  end;
  Result := ActiveCount = 0;
end;

function TPwdWorkSupervisor.ActiveCount: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Collect;
    Result := FThreads.Count;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

initialization
  GSupervisor := TPwdWorkSupervisor.Create;

finalization
  FreeAndNil(GSupervisor);

end.
