// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSafeSave;

{$mode objfpc}{$H+}

// Ecriture de fichiers sans fenetre de troncature, sans TOCTOU, sans casser les liens.
// Un fichier a moitie ecrit est pire qu'un fichier absent: il a l'air vivant.

interface

uses
  Classes, SysUtils{$IFDEF UNIX}, BaseUnix, Unix{$ENDIF};

type
  TOwnedHandleStream = class(THandleStream)
  public
    destructor Destroy; override;
  end;

function HasHardLinks(const APath: string): Boolean;
// Couple volume/inode: change a chaque rename, meme a taille et date identiques.
function FileIdentity(const APath: string; out ADev, AIno: Int64): Boolean;
// Echoue AVANT toute ecriture plutot que de rendre un chemin encore lie: l'appelant
// renommerait par-dessus le LIEN, pas par-dessus sa cible.
function ResolveLink(const APath: string): string;
function CreateTempIn(const ADest: string; out ATmpName: string): TOwnedHandleStream;
// Contenu rendu durable AVANT le rename (fsync, FlushFileBuffers). False: le disque n'a
// rien confirme, la sauvegarde non plus.
function FlushToDisk(AHandle: THandle): Boolean;
function ReplaceByRename(const ATmp, ADest: string): Boolean;
// Variantes privees: 0600/0700 quel que soit l'umask. Sans effet sous Windows.
function ReplaceByRenamePrivate(const ATmp, ADest: string): Boolean; overload;
// ADirSynced False: le rename est fait, mais rien ne dit qu'il survivra a une coupure.
// Toujours True sous Windows, faute d'equivalent accessible sans privilege.
function ReplaceByRenamePrivate(const ATmp, ADest: string; out ADirSynced: Boolean): Boolean; overload;
// Chemin physique ou TOUS les composants sont resolus (liens, jonctions, noms courts),
// pas seulement le dernier: deux chemins du meme fichier donnent la meme chaine.
// EStreamError si l'identite reste douteuse; un doute ici finit en ecrasement ailleurs.
function CanonicalFilePath(const APath: string): string;
procedure MakePrivateFile(const APath: string);
procedure MakePrivateDir(const APath: string);
// Temporaire prive cree en exclusif, jamais sur une cible existante, et qui disparait
// seul a la fermeture (DELETE_ON_CLOSE, unlink immediat sous Unix).
function CreatePrivateTempRW(const AName: string): THandle;
function PhysicalPath(const APath: string): string;
function HandleFinalPath(AHandle: THandle): string;
function HandleIsRegularFile(AHandle: THandle): Boolean;
function OpenRegularFileRead(const APath: string; out ANotRegular: Boolean): THandleStream;
function HandleIdentity(AHandle: THandle; out ADev, AIno: Int64): Boolean;
procedure SavePrivateStream(const APath: string; ASrc: TStream);
// Le contenu est produit directement dans le temporaire, sans copie en memoire. Une
// exception dans AFill abandonne tout: temporaire efface, ancien fichier intact.
type
  TStreamFill = procedure(ADest: TStream) of object;
procedure SavePrivateFill(const APath: string; AFill: TStreamFill);
// WriteBuffer prend un Count Longint: au-dela de 2 Gio la taille boucle en silence avec
// {$R-}, et la copie sort tronquee sans que personne ne s'en plaigne.
procedure WriteAllBuf(ASt: TStream; const AData: string);
// Taille lue UNE fois, ce nombre exact d'octets lu, puis un octet de plus tente. Un
// fichier qui grandit en route rend False, un fichier qui raccourcit leve EReadError:
// le tampon ne deborde jamais, quoi que fasse l'autre cote.
function ReadWholeStream(ASt: TStream; AMaxBytes: Int64; out AData: RawByteString): Boolean;

implementation

function ReadWholeStream(ASt: TStream; AMaxBytes: Int64; out AData: RawByteString): Boolean;
var
  n: Int64;
  probe: Byte;
begin
  Result := False;
  AData := '';
  n := ASt.Size;
  if (n < 0) or (n > AMaxBytes) or (n > High(LongInt)) then Exit;
  SetLength(AData, n);
  if n > 0 then ASt.ReadBuffer(AData[1], LongInt(n));
  probe := 0;
  if ASt.Read(probe, 1) <> 0 then
  begin
    AData := '';
    Exit;
  end;
  Result := True;
end;

procedure WriteAllBuf(ASt: TStream; const AData: string);
const
  CHUNK = 64 * 1024 * 1024;
var
  p, n: SizeInt;
begin
  p := 1;
  while p <= Length(AData) do
  begin
    n := Length(AData) - p + 1;
    if n > CHUNK then n := CHUNK;
    ASt.WriteBuffer(AData[p], n);
    Inc(p, n);
  end;
end;

destructor TOwnedHandleStream.Destroy;
begin
  if Handle <> THandle(-1) then
    FileClose(Handle);
  inherited Destroy;
end;

{$IFDEF WINDOWS}
const
  GENERIC_WRITE_W   = $40000000;
  GENERIC_READ_W    = $80000000;
  FILE_FLAG_DELETE_ON_CLOSE_W = $04000000;
  FILE_FLAG_BACKUP_SEMANTICS_W = $02000000;
  FILE_ATTR_DIRECTORY_W = $10;
  FILE_ATTR_DEVICE_W = $40;
  CREATE_NEW_W      = 1;
  OPEN_EXISTING_W   = 3;
  FILE_ATTR_NORMAL  = $80;
  FILE_ATTR_REPARSE = $400;
  SHARE_ALL         = 7;
  REPLACEFILE_IGNORE_MERGE_ERRORS = 2;
  MOVEFILE_REPLACE_EXISTING = 1;
  MOVEFILE_COPY_ALLOWED     = 2;

type
  TByHandleInfo = record
    dwFileAttributes: LongWord;
    ftCreation, ftAccess, ftWrite: array[0..1] of LongWord;
    dwVolumeSerial, nSizeHigh, nSizeLow: LongWord;
    nNumberOfLinks: LongWord;
    nIndexHigh, nIndexLow: LongWord;
  end;

function CreateFileW(lpFileName: PWideChar; dwAccess, dwShare: LongWord;
  lpSec: Pointer; dwDisp, dwFlags: LongWord; hTemplate: THandle): THandle;
  stdcall; external 'kernel32.dll';
function CloseHandle(h: THandle): LongBool; stdcall; external 'kernel32.dll';
function GetFileAttributesW(lpFileName: PWideChar): LongWord;
  stdcall; external 'kernel32.dll';
function GetFileInformationByHandle(h: THandle; out AInfo: TByHandleInfo): LongBool;
  stdcall; external 'kernel32.dll';
function GetFinalPathNameByHandleW(h: THandle; lpszFilePath: PWideChar;
  cchFilePath, dwFlags: LongWord): LongWord; stdcall; external 'kernel32.dll';
function MoveFileExW(lpExisting, lpNew: PWideChar; dwFlags: LongWord): LongBool;
  stdcall; external 'kernel32.dll';
function FlushFileBuffers(h: THandle): LongBool; stdcall; external 'kernel32.dll';
function ReplaceFileW(lpReplaced, lpReplacement, lpBackup: PWideChar;
  dwFlags: LongWord; lpExclude, lpReserved: Pointer): LongBool;
  stdcall; external 'kernel32.dll';

function HasHardLinks(const APath: string): Boolean;
var
  h: THandle;
  info: TByHandleInfo;
begin
  Result := False;
  // Sans FLAG_OPEN_REPARSE_POINT, CreateFileW suit les liens: c'est la cible qu'on teste.
  h := CreateFileW(PWideChar(UTF8Decode(APath)), 0, SHARE_ALL, nil,
    OPEN_EXISTING_W, 0, 0);
  if h = THandle(-1) then Exit;
  if GetFileInformationByHandle(h, info) then
    Result := info.nNumberOfLinks > 1;
  CloseHandle(h);
end;

function FileIdentity(const APath: string; out ADev, AIno: Int64): Boolean;
var
  h: THandle;
  info: TByHandleInfo;
begin
  ADev := 0;
  AIno := 0;
  Result := False;
  h := CreateFileW(PWideChar(UTF8Decode(APath)), 0, SHARE_ALL, nil,
    OPEN_EXISTING_W, 0, 0);
  if h = THandle(-1) then Exit;
  if GetFileInformationByHandle(h, info) then
  begin
    ADev := Int64(info.dwVolumeSerial);
    AIno := (Int64(info.nIndexHigh) shl 32) or Int64(info.nIndexLow);
    Result := True;
  end;
  CloseHandle(h);
end;

function ResolveLink(const APath: string): string;
var
  attrs, n: LongWord;
  h: THandle;
  buf: array[0..4095] of WideChar;
  s: UnicodeString;
begin
  Result := APath;
  // UTF8Decode explicite: ne pas dependre de DefaultSystemCodePage.
  attrs := GetFileAttributesW(PWideChar(UTF8Decode(APath)));
  if (attrs = $FFFFFFFF) or ((attrs and FILE_ATTR_REPARSE) = 0) then
    Exit;
  h := CreateFileW(PWideChar(UTF8Decode(APath)), 0, SHARE_ALL, nil,
    OPEN_EXISTING_W, 0, 0);
  if h = THandle(-1) then
    raise EStreamError.CreateFmt('Cannot resolve link %s', [APath]);
  n := GetFinalPathNameByHandleW(h, @buf[0], Length(buf), 0);
  CloseHandle(h);
  if (n = 0) or (n >= LongWord(Length(buf))) then
    raise EStreamError.CreateFmt('Cannot resolve link %s', [APath]);
  SetString(s, PWideChar(@buf[0]), n);
  // GetFinalPathNameByHandle prefixe en \\?\ (ou \\?\UNC\ pour le reseau).
  if Copy(s, 1, 8) = '\\?\UNC\' then
    s := '\\' + Copy(s, 9, MaxInt)
  else if Copy(s, 1, 4) = '\\?\' then
    s := Copy(s, 5, MaxInt);
  Result := UTF8Encode(s);
end;

function ExclusiveCreate(const AName: string): THandle;
begin
  Result := CreateFileW(PWideChar(UTF8Decode(AName)), GENERIC_WRITE_W, 0,
    nil, CREATE_NEW_W, FILE_ATTR_NORMAL, 0);
end;

function CreatePrivateTempRW(const AName: string): THandle;
begin
  Result := CreateFileW(PWideChar(UTF8Decode(AName)), GENERIC_READ_W or GENERIC_WRITE_W, 0,
    nil, CREATE_NEW_W, FILE_ATTR_NORMAL or FILE_FLAG_DELETE_ON_CLOSE_W, 0);
end;

function HandleFinalPath(AHandle: THandle): string;
var
  buf: array[0..4095] of WideChar;
  n: LongWord;
  s: UnicodeString;
begin
  Result := '';
  if AHandle = THandle(-1) then Exit;
  n := GetFinalPathNameByHandleW(AHandle, @buf[0], Length(buf), 0);
  if (n = 0) or (n >= LongWord(Length(buf))) then Exit;
  SetString(s, PWideChar(@buf[0]), n);
  if Copy(s, 1, 8) = '\\?\UNC\' then
    s := '\\' + Copy(s, 9, MaxInt)
  else if Copy(s, 1, 4) = '\\?\' then
    s := Copy(s, 5, MaxInt);
  Result := UTF8Encode(s);
end;

function PhysicalPath(const APath: string): string;
var
  h: THandle;
begin
  Result := '';
  // BACKUP_SEMANTICS, sinon CreateFileW refuse d'ouvrir un dossier. Les liens sont suivis.
  h := CreateFileW(PWideChar(UTF8Decode(APath)), 0, SHARE_ALL, nil,
    OPEN_EXISTING_W, FILE_FLAG_BACKUP_SEMANTICS_W, 0);
  if h = THandle(-1) then Exit;
  Result := HandleFinalPath(h);
  CloseHandle(h);
end;

function CanonicalFilePath(const APath: string): string;
var
  p, dir: string;
begin
  p := ExpandFileName(APath);
  // Fichier existant: GetFinalPathNameByHandle rend le chemin du fichier reellement ouvert,
  // jonctions, liens, lecteurs substitues et noms courts 8.3 compris.
  Result := PhysicalPath(p);
  if Result <> '' then Exit;
  // Un nom qui existe sans pouvoir s'ouvrir (lien casse): identite inconnue, on refuse.
  if GetFileAttributesW(PWideChar(UTF8Decode(p))) <> $FFFFFFFF then
    raise EStreamError.CreateFmt('Cannot resolve %s', [APath]);
  dir := PhysicalPath(ExtractFileDir(p));
  if dir = '' then
    raise EStreamError.CreateFmt('Cannot resolve the folder of %s', [APath]);
  Result := IncludeTrailingPathDelimiter(dir) + ExtractFileName(p);
end;

function HandleIsRegularFile(AHandle: THandle): Boolean;
var
  info: TByHandleInfo;
begin
  Result := False;
  if not GetFileInformationByHandle(AHandle, info) then Exit;
  Result := (info.dwFileAttributes and (FILE_ATTR_DIRECTORY_W or FILE_ATTR_DEVICE_W or
    FILE_ATTR_REPARSE)) = 0;
end;

function HandleIdentity(AHandle: THandle; out ADev, AIno: Int64): Boolean;
var
  info: TByHandleInfo;
begin
  ADev := 0;
  AIno := 0;
  Result := GetFileInformationByHandle(AHandle, info);
  if Result then
  begin
    ADev := Int64(info.dwVolumeSerial);
    AIno := (Int64(info.nIndexHigh) shl 32) or Int64(info.nIndexLow);
  end;
end;

function FlushToDisk(AHandle: THandle): Boolean;
begin
  Result := FlushFileBuffers(AHandle);
end;

function ReplaceByRename(const ATmp, ADest: string): Boolean;
begin
  // ReplaceFileW preserve attributs et ACL de la cible, mais exige qu'elle existe.
  if FileExists(ADest) then
    if ReplaceFileW(PWideChar(UTF8Decode(ADest)), PWideChar(UTF8Decode(ATmp)),
        nil, REPLACEFILE_IGNORE_MERGE_ERRORS, nil, nil) then
      Exit(True);
  // Jamais MOVEFILE_COPY_ALLOWED: une copie n'est pas atomique. Le temporaire nait a cote
  // de la cible, donc sur le meme volume.
  Result := MoveFileExW(PWideChar(UTF8Decode(ATmp)),
    PWideChar(UTF8Decode(ADest)),
    MOVEFILE_REPLACE_EXISTING);
end;

{$ELSE}

function HasHardLinks(const APath: string): Boolean;
var
  st: Stat;
begin
  // fpStat suit les liens: c'est la cible reelle qu'on teste.
  Result := (fpStat(PChar(APath), st) = 0) and (st.st_nlink > 1);
end;

function FileIdentity(const APath: string; out ADev, AIno: Int64): Boolean;
var
  st: Stat;
begin
  ADev := 0;
  AIno := 0;
  Result := fpStat(PChar(APath), st) = 0;
  if Result then
  begin
    ADev := Int64(st.st_dev);
    AIno := Int64(st.st_ino);
  end;
end;

function ResolveLink(const APath: string): string;
var
  st: Stat;
  lnk: string;
  i: Integer;
begin
  Result := APath;
  for i := 1 to 8 do // boucle de liens bornee
  begin
    if fpLStat(PChar(Result), st) <> 0 then
      Exit;
    if not fpS_ISLNK(st.st_mode) then
      Exit;
    lnk := fpReadLink(Result);
    if lnk = '' then
      raise EStreamError.CreateFmt('Cannot resolve link %s', [Result]);
    if lnk[1] <> '/' then
      lnk := ExpandFileName(ExtractFilePath(Result) + lnk);
    Result := lnk;
  end;
  if (fpLStat(PChar(Result), st) = 0) and fpS_ISLNK(st.st_mode) then
    raise EStreamError.CreateFmt('Too many symlink levels resolving %s', [APath]);
end;

function FlushToDisk(AHandle: THandle): Boolean;
begin
  Result := fpfsync(cint(AHandle)) = 0;
end;

function ExclusiveCreate(const AName: string): THandle;
begin
  Result := THandle(FpOpen(PChar(AName), O_WRONLY or O_CREAT or O_EXCL, &600));
end;

function CreatePrivateTempRW(const AName: string): THandle;
var
  fd: cint;
begin
  fd := FpOpen(PChar(AName), O_RDWR or O_CREAT or O_EXCL, &600);
  if fd < 0 then Exit(THandle(-1));
  // Retire du nommage aussitot: aucune autre instance ne peut l'ouvrir ni le supprimer,
  // et un crash ne laisse pas d'orphelin a ramasser.
  FpUnlink(PChar(AName));
  Result := THandle(fd);
end;

function HandleFinalPath(AHandle: THandle): string;
begin
  Result := '';
end;

const
  // PATH_MAX vaut 4096 sous Linux et 1024 sous macOS: realpath ecrit sans connaitre la
  // taille du tampon, il couvre donc large.
  REALPATH_BUF = 8192;
  CANON_MAX_LINKS = 40;

function c_realpath(APath: PChar; AResolved: PChar): PChar; cdecl;
  external 'c' name 'realpath';

function RealPathOf(const APath: string): string;
var
  buf: array[0..REALPATH_BUF - 1] of Char;
begin
  Result := '';
  if c_realpath(PChar(APath), @buf[0]) <> nil then
    Result := StrPas(PChar(@buf[0]));
end;

function CanonicalFilePath(const APath: string): string;
var
  p, dir, lnk: string;
  st: Stat;
  i: Integer;
begin
  p := ExpandFileName(APath);
  for i := 1 to CANON_MAX_LINKS do
  begin
    Result := RealPathOf(p);
    if Result <> '' then Exit;
    dir := RealPathOf(ExtractFileDir(p));
    if dir = '' then
      raise EStreamError.CreateFmt('Cannot resolve the folder of %s', [APath]);
    Result := IncludeTrailingPathDelimiter(dir) + ExtractFileName(p);
    if fpLStat(PChar(Result), st) <> 0 then
      Exit;
    if not fpS_ISLNK(st.st_mode) then
      raise EStreamError.CreateFmt('Cannot resolve %s', [APath]);
    // Lien casse: sa cible, relative au dossier PHYSIQUE du lien. Aucune reduction lexicale
    // de '..', realpath s'en charge au tour suivant.
    lnk := fpReadLink(Result);
    if lnk = '' then
      raise EStreamError.CreateFmt('Cannot resolve link %s', [Result]);
    if lnk[1] <> '/' then
      lnk := IncludeTrailingPathDelimiter(dir) + lnk;
    p := lnk;
  end;
  raise EStreamError.CreateFmt('Too many symlink levels resolving %s', [APath]);
end;

function PhysicalPath(const APath: string): string;
var
  parts: TStringArray;
  i: Integer;
  cur: string;
begin
  // Chaque prefixe est resolu a son tour: un lien intermediaire compte aussi. La variable
  // intermediaire existe parce que FPC 3.2.4 sous Darwin refuse le helper sur le resultat
  // direct d'ExpandFileName.
  cur := ExpandFileName(APath);
  parts := cur.Split(['/']);
  cur := '';
  for i := 0 to High(parts) do
  begin
    if parts[i] = '' then Continue;
    cur := cur + '/' + parts[i];
    try
      cur := ResolveLink(cur);
    except
      Exit('');
    end;
  end;
  if cur = '' then cur := '/';
  Result := cur;
end;

function HandleIsRegularFile(AHandle: THandle): Boolean;
var
  st: Stat;
begin
  Result := (fpFStat(cint(AHandle), st) = 0) and fpS_ISREG(st.st_mode);
end;

function HandleIdentity(AHandle: THandle; out ADev, AIno: Int64): Boolean;
var
  st: Stat;
begin
  ADev := 0;
  AIno := 0;
  Result := fpFStat(cint(AHandle), st) = 0;
  if Result then
  begin
    ADev := Int64(st.st_dev);
    AIno := Int64(st.st_ino);
  end;
end;

// Un rename n'est durable qu'une fois le repertoire parent synchronise: sans ca, un arret
// brutal peut ressusciter l'ancien nom. False: persistance non confirmee, l'appelant
// doit le dire.
function SyncParentDir(const APath: string): Boolean;
var
  fd: cint;
begin
  fd := FpOpen(PChar(ExtractFileDir(ExpandFileName(APath))), O_RDONLY);
  if fd < 0 then Exit(False);
  Result := fpfsync(fd) = 0;
  FpClose(fd);
end;

function ReplaceByRename(const ATmp, ADest: string): Boolean;
var
  st: Stat;
  hasMeta: Boolean;
  um: TMode;
begin
  hasMeta := fpStat(PChar(ADest), st) = 0;
  Result := RenameFile(ATmp, ADest);
  if not Result then Exit;
  // Chemin non prive (polices embarquees): au mieux, sans verdict.
  SyncParentDir(ADest);
  if hasMeta then
  begin
    // chown PUIS chmod: un chown efface setuid/setgid sur la plupart des systemes.
    fpChown(PChar(ADest), st.st_uid, st.st_gid);
    fpChmod(PChar(ADest), st.st_mode and $0FFF);
  end
  else
  begin
    // Fichier neuf: le temporaire est ne en 0600, on rend les droits d'une creation normale.
    // Lire l'umask oblige a l'ecraser, d'ou le second appel qui le remet.
    um := fpUmask(0);
    fpUmask(um);
    fpChmod(PChar(ADest), TMode(&666) and not um);
  end;
end;

{$ENDIF}

function OpenRegularFileRead(const APath: string; out ANotRegular: Boolean): THandleStream;
{$IFDEF UNIX}
var
  fd: cint;
  st: Stat;
  flags: cint;
begin
  ANotRegular := False;
  // O_NONBLOCK: un FIFO sans ecrivain rend la main au lieu de bloquer AVANT tout controle.
  // Le type est ensuite verifie sur le descripteur reellement ouvert, pas sur le nom.
  fd := FpOpen(PChar(APath), O_RDONLY or O_NONBLOCK);
  if fd < 0 then
    raise EFOpenError.CreateFmt('Unable to open file "%s"', [APath]);
  if (fpFStat(fd, st) <> 0) or not fpS_ISREG(st.st_mode) then
  begin
    FpClose(fd);
    ANotRegular := True;
    Exit(nil);
  end;
  flags := FpFcntl(fd, F_GETFL);
  if flags >= 0 then
    FpFcntl(fd, F_SETFL, flags and not O_NONBLOCK);
  Result := TOwnedHandleStream.Create(THandle(fd));
end;
{$ELSE}
begin
  // Windows: CON, NUL ou \\.\pipe\... s'ouvrent tres bien par TFileStream. Le type est
  // verifie sur le handle ouvert avant toute lecture susceptible de bloquer.
  ANotRegular := False;
  Result := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  if not HandleIsRegularFile(Result.Handle) then
  begin
    FreeAndNil(Result);
    ANotRegular := True;
  end;
end;
{$ENDIF}

function ReplaceByRenamePrivate(const ATmp, ADest: string; out ADirSynced: Boolean): Boolean;
begin
  ADirSynced := False;
  {$IFDEF UNIX}
  // Aucune preservation de mode: un 0644 herite ne survit pas a la reecriture.
  Result := RenameFile(ATmp, ADest);
  if Result then
  begin
    fpChmod(PChar(ADest), &600);
    ADirSynced := SyncParentDir(ADest);
  end;
  {$ELSE}
  Result := ReplaceByRename(ATmp, ADest);
  ADirSynced := Result;
  {$ENDIF}
end;

function ReplaceByRenamePrivate(const ATmp, ADest: string): Boolean;
var
  synced: Boolean;
begin
  Result := ReplaceByRenamePrivate(ATmp, ADest, synced);
end;

procedure MakePrivateFile(const APath: string);
begin
  if APath = '' then Exit;
  {$IFDEF UNIX}
  fpChmod(PChar(APath), &600);
  {$ENDIF}
end;

procedure MakePrivateDir(const APath: string);
begin
  if APath = '' then Exit;
  {$IFDEF UNIX}
  fpChmod(PChar(ExcludeTrailingPathDelimiter(APath)), &700);
  {$ENDIF}
end;

type
  TStreamCopier = class
    Src: TStream;
    procedure Fill(ADest: TStream);
  end;

procedure TStreamCopier.Fill(ADest: TStream);
begin
  // CopyFrom avec un compte a 0: FPC repart du debut de la source et copie tout.
  if Src.Size > 0 then
    ADest.CopyFrom(Src, 0);
end;

procedure SavePrivateStream(const APath: string; ASrc: TStream);
var
  c: TStreamCopier;
begin
  c := TStreamCopier.Create;
  try
    c.Src := ASrc;
    SavePrivateFill(APath, @c.Fill);
  finally
    c.Free;
  end;
end;

procedure SavePrivateFill(const APath: string; AFill: TStreamFill);
var
  net: TOwnedHandleStream;
  tmp: string;
  synced: Boolean;
begin
  net := CreateTempIn(APath, tmp);
  try
    try
      AFill(net);
      // Durable AVANT le rename, sinon une coupure peut laisser un fichier vide a la place.
      if not FlushToDisk(net.Handle) then
        raise EStreamError.CreateFmt('The disk did not confirm the write of %s', [APath]);
    finally
      net.Free;
    end;
    if not ReplaceByRenamePrivate(tmp, APath, synced) then
      raise EStreamError.CreateFmt('Cannot replace %s', [APath]);
    // Jamais de succes annonce sans confirmation du disque.
    if not synced then
      raise EStreamError.CreateFmt('%s was written, but the disk did not confirm ' +
        'the folder update: the file may be lost after a power failure', [APath]);
  except
    DeleteFile(tmp);
    raise;
  end;
end;

function CreateTempIn(const ADest: string; out ATmpName: string): TOwnedHandleStream;
var
  i: Integer;
  h: THandle;
begin
  for i := 1 to 20 do
  begin
    // Les 32 bits de poids faible passent en Int64: un LongWord devient un vtInteger dans
    // l'array of const et -Cr refuse toute valeur >= 2^31. GetTickCount64 compte depuis
    // l'epoque Unix sous Darwin, et ailleurs 24,8 jours d'uptime suffisent.
    ATmpName := Format('%s.rtt%.8x%.4x.tmp',
      [ADest, Int64(GetTickCount64 and $FFFFFFFF), Random($10000)]);
    h := ExclusiveCreate(ATmpName);
    if h <> THandle(-1) then
      Exit(TOwnedHandleStream.Create(h));
  end;
  ATmpName := '';
  raise EStreamError.CreateFmt('Cannot create temp file near %s', [ADest]);
end;

initialization
  Randomize;

end.
