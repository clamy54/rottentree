// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uValueFile;

{$mode objfpc}{$H+}

// Chargement et enregistrement d'une valeur d'attribut dans un fichier, a l'octet pres: ni BOM, ni
// encodage, ni fin de ligne retouchee. Lecture bornee, fichiers ordinaires seulement, ecriture par
// remplacement sur, le tout hors du fil graphique.

interface

uses
  SysUtils, Classes, uUiInbox, uCancel, uPasswordWork;

type
  TValueFileOp = (vfoLoad, vfoSave);

  TValueFileMsg = class(TUiMessage)
  public
    Op: TValueFileOp;
    Path: string;
    Data: RawByteString;
    Ok: Boolean;
    Cancelled: Boolean;
    ErrorText: string;
    destructor Destroy; override;
  end;

  TValueFileThread = class(TPwdWorkThread)
  private
    FOp: TValueFileOp;
    FPath: string;
    FData: RawByteString;
    FMaxBytes: Int64;
  protected
    procedure Run; override;
  public
    constructor CreateLoad(const APath: string; AMaxBytes: Int64; AOwner: Pointer; ATaskId: Int64);
    constructor CreateSave(const APath: string; const AData: RawByteString; AOwner: Pointer;
      ATaskId: Int64);
    destructor Destroy; override;
  end;

resourcestring
  rsVfDevicePath = 'this path names a device or a named pipe, not a file';
  rsVfEmptyPath = 'no file name';
  rsVfNotRegular = 'not a regular file (directory, device, pipe or link)';
  rsVfTooLarge = 'the file is larger than %d bytes';
  rsVfGrew = 'the file grew beyond %d bytes while it was read';
  rsVfChanged = 'the file changed while it was read (%d bytes announced, %d read)';
  rsVfReadError = 'the system reported a read error after %d bytes';
  rsVfCancelled = 'cancelled';
  rsVfReadFailed = 'cannot read the file: %s';
  rsVfWriteFailed = 'cannot write the file: %s';

function ValueFilePathProblem(const APath: string): string;
function ReadValueFile(const APath: string; AMaxBytes: Int64; ACancel: TCancelToken;
  out AData: RawByteString; out AError: string): Boolean;
// La taille annoncee n'est qu'un precontrole: erreur systeme, fichier qui grandit au-dela de la
// limite ou taille finale differente rendent False, jamais un prefixe presente comme complet.
function ReadBoundedStream(ASt: TStream; AMaxBytes: Int64; ACancel: TCancelToken;
  out AData: RawByteString; out AError: string): Boolean;
function WriteValueFile(const APath: string; const AData: RawByteString;
  ACancel: TCancelToken; out AError: string): Boolean;
function StartValueLoad(const APath: string; AMaxBytes: Int64; AOwner: Pointer): Int64;
function StartValueSave(const APath: string; const AData: RawByteString; AOwner: Pointer): Int64;

implementation

uses
  uSafeSave, uRtBytes;

const
  READ_CHUNK = 256 * 1024;

  DOS_DEVICES: array[0..7] of string = ('CON', 'PRN', 'AUX', 'NUL', 'CONIN$', 'CONOUT$',
    'CLOCK$', 'CONFIG$');

function IsReservedDeviceName(const AName: string): Boolean;
var
  base: string;
  p, i: Integer;
begin
  // CON, NUL.txt, COM1, LPT9.log: peripheriques quel que soit le dossier, et Windows ignore espaces
  // et points finaux. L'heritage de MS-DOS ne se refuse pas.
  base := UpperCase(AName);
  p := Pos('.', base);
  if p > 0 then base := Copy(base, 1, p - 1);
  base := TrimRight(base);
  for i := 0 to High(DOS_DEVICES) do
    if base = DOS_DEVICES[i] then Exit(True);
  if (Length(base) = 4) and ((Copy(base, 1, 3) = 'COM') or (Copy(base, 1, 3) = 'LPT')) and
     (base[4] in ['0'..'9']) then
    Exit(True);
  // COM1 a COM3 en exposant (U+00B9, U+00B2, U+00B3), encodes en UTF-8, sont aussi des
  // peripheriques.
  if (Length(base) = 5) and ((Copy(base, 1, 3) = 'COM') or (Copy(base, 1, 3) = 'LPT')) and
     (base[4] = #$C2) and (base[5] in [#$B9, #$B2, #$B3]) then
    Exit(True);
  Result := False;
end;

function ValueFilePathProblem(const APath: string): string;
var
  p, rest: string;
  parts: TStringArray;
  i: Integer;
begin
  Result := '';
  if APath = '' then Exit(rsVfEmptyPath);
  if Pos(#0, APath) > 0 then Exit(rsVfDevicePath);
  {$IFDEF WINDOWS}
  p := StringReplace(APath, '/', '\', [rfReplaceAll]);
  // Espace de noms des peripheriques: \\.\X, \\?\GLOBALROOT, \??\
  if (Copy(p, 1, 4) = '\\.\') or (Copy(p, 1, 4) = '\??\') then Exit(rsVfDevicePath);
  if Copy(p, 1, 4) = '\\?\' then
  begin
    rest := Copy(p, 5, MaxInt);
    // Seuls \\?\C:\... et \\?\UNC\serveur\partage\... designent des fichiers.
    if not (((Length(rest) >= 3) and (rest[2] = ':') and (rest[3] = '\')) or
            SameText(Copy(rest, 1, 4), 'UNC\')) then
      Exit(rsVfDevicePath);
    if SameText(Copy(rest, 1, 4), 'UNC\') then p := '\\' + Copy(rest, 5, MaxInt)
    else p := rest;
  end;
  // Canal nomme local ou distant (\\serveur\pipe\nom, mailslot): s'y connecter livre deja
  // l'identite du client au serveur du canal, avant meme d'avoir lu un octet.
  if Copy(p, 1, 2) = '\\' then
  begin
    parts := Copy(p, 3, MaxInt).Split(['\']);
    if (Length(parts) >= 2) and (SameText(parts[1], 'pipe') or SameText(parts[1], 'mailslot')) then
      Exit(rsVfDevicePath);
  end;
  // Flux de donnees alternatifs NTFS: fichier:flux, hors lettre de lecteur.
  rest := p;
  if (Length(rest) >= 2) and (rest[2] = ':') then rest := Copy(rest, 3, MaxInt);
  if Pos(':', rest) > 0 then Exit(rsVfDevicePath);
  parts := p.Split(['\']);
  for i := 0 to High(parts) do
    if IsReservedDeviceName(parts[i]) then Exit(rsVfDevicePath);
  {$ELSE}
  // Unix: type verifie sur le descripteur ouvert (FIFO, socket, peripherique), pas sur le chemin.
  p := APath;
  rest := p;
  parts := nil;
  i := 0;
  {$ENDIF}
end;

function ReadValueFile(const APath: string; AMaxBytes: Int64; ACancel: TCancelToken;
  out AData: RawByteString; out AError: string): Boolean;
var
  st: THandleStream;
  notRegular: Boolean;
begin
  Result := False;
  AData := '';
  AError := ValueFilePathProblem(APath);
  if AError <> '' then Exit;
  try
    st := OpenRegularFileRead(APath, notRegular);
  except
    on E: Exception do
    begin
      AError := Format(rsVfReadFailed, [E.Message]);
      Exit;
    end;
  end;
  if st = nil then
  begin
    AError := rsVfNotRegular;
    Exit;
  end;
  try
    Result := ReadBoundedStream(st, AMaxBytes, ACancel, AData, AError);
  finally
    st.Free;
  end;
end;

function ReadBoundedStream(ASt: TStream; AMaxBytes: Int64; ACancel: TCancelToken;
  out AData: RawByteString; out AError: string): Boolean;
var
  size, total, cap: Int64;
  n: LongInt;
  buf: RawByteString;
begin
  Result := False;
  AData := '';
  AError := '';
  try
    size := ASt.Size;
    if size > AMaxBytes then
    begin
      AError := Format(rsVfTooLarge, [AMaxBytes]);
      Exit;
    end;
    SetLength(buf, READ_CHUNK);
    total := 0;
    if size > 0 then SetLength(AData, size);
    while True do
    begin
      if (ACancel <> nil) and ACancel.IsCancelled then
      begin
        AError := rsVfCancelled;
        AData := '';
        Exit;
      end;
      n := ASt.Read(buf[1], READ_CHUNK);
      // Read rend -1 sur erreur systeme (contrat THandleStream), sans exception: un prefixe lu
      // n'est pas le fichier.
      if n < 0 then
      begin
        AError := Format(rsVfReadError, [total]);
        AData := '';
        Exit;
      end;
      if n = 0 then Break;
      if total + n > AMaxBytes then
      begin
        AError := Format(rsVfGrew, [AMaxBytes]);
        AData := '';
        Exit;
      end;
      if total + n > Length(AData) then
      begin
        cap := Int64(Length(AData)) * 2;
        if cap < total + n then cap := total + n;
        if cap > AMaxBytes then cap := AMaxBytes;
        SetLength(AData, cap);
      end;
      Move(buf[1], AData[total + 1], n);
      Inc(total, n);
    end;
    // Raccourci ou allonge pendant la lecture: l'instantane n'est pas le fichier, rien n'est
    // accepte en silence.
    if (size >= 0) and (total <> size) then
    begin
      AError := Format(rsVfChanged, [size, total]);
      AData := '';
      Exit;
    end;
    SetLength(AData, total);
    Result := True;
  except
    on E: Exception do
    begin
      AData := '';
      AError := Format(rsVfReadFailed, [E.Message]);
    end;
  end;
end;

type
  TValueWriter = class
    Data: RawByteString;
    procedure Fill(ADest: TStream);
  end;

procedure TValueWriter.Fill(ADest: TStream);
begin
  WriteAllBuf(ADest, Data);
end;

function WriteValueFile(const APath: string; const AData: RawByteString;
  ACancel: TCancelToken; out AError: string): Boolean;
var
  w: TValueWriter;
begin
  Result := False;
  AError := ValueFilePathProblem(APath);
  if AError <> '' then Exit;
  if (ACancel <> nil) and ACancel.IsCancelled then
  begin
    AError := rsVfCancelled;
    Exit;
  end;
  w := TValueWriter.Create;
  try
    w.Data := AData;
    try
      // Temporaire, confirmation du disque, renommage: si une etape echoue, l'ancien fichier reste.
      // Jamais de succes non confirme.
      SavePrivateFill(APath, @w.Fill);
      Result := True;
    except
      on E: Exception do
        AError := Format(rsVfWriteFailed, [E.Message]);
    end;
  finally
    w.Free;
  end;
end;

destructor TValueFileMsg.Destroy;
begin
  // Une valeur lue peut etre un secret (cle, certificat prive).
  WipeString(Data);
  inherited Destroy;
end;

constructor TValueFileThread.CreateLoad(const APath: string; AMaxBytes: Int64;
  AOwner: Pointer; ATaskId: Int64);
begin
  FOp := vfoLoad;
  FPath := APath;
  FMaxBytes := AMaxBytes;
  inherited Create(AOwner, ATaskId);
end;

constructor TValueFileThread.CreateSave(const APath: string; const AData: RawByteString;
  AOwner: Pointer; ATaskId: Int64);
begin
  FOp := vfoSave;
  FPath := APath;
  FData := AData;
  UniqueString(FData);
  inherited Create(AOwner, ATaskId);
end;

destructor TValueFileThread.Destroy;
begin
  WipeString(FData);
  inherited Destroy;
end;

procedure TValueFileThread.Run;
var
  m: TValueFileMsg;
  data: RawByteString;
  err: string;
begin
  m := TValueFileMsg.Create;
  try
    m.Owner := Owner;
    m.TaskId := TaskId;
    m.Op := FOp;
    m.Path := FPath;
    if FOp = vfoLoad then
    begin
      m.Ok := ReadValueFile(FPath, FMaxBytes, Cancel, data, err);
      if m.Ok then m.Data := data;
    end
    else
      m.Ok := WriteValueFile(FPath, FData, Cancel, err);
    m.ErrorText := err;
    m.Cancelled := (not m.Ok) and Cancel.IsCancelled;
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
end;

function StartValueLoad(const APath: string; AMaxBytes: Int64; AOwner: Pointer): Int64;
begin
  Result := NextTaskId;
  if not PasswordWork.Launch(TValueFileThread.CreateLoad(APath, AMaxBytes, AOwner, Result)) then
    Result := 0;
end;

function StartValueSave(const APath: string; const AData: RawByteString; AOwner: Pointer): Int64;
begin
  Result := NextTaskId;
  if not PasswordWork.Launch(TValueFileThread.CreateSave(APath, AData, AOwner, Result)) then
    Result := 0;
end;

end.
