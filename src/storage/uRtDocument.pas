// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uRtDocument;

{$mode objfpc}{$H+}

// Document portable .rtt: profils, dossiers, secrets, favoris, modeles, brouillons et
// journal des ecritures a issue inconnue. SQLite en memoire seulement, enveloppe
// chiffree sur disque, sauvegarde atomique avec copie precedente, verrou de redacteur
// et detection des modifications externes. Paranoiaque, et pas sans raisons.

interface

uses
  SysUtils, Classes, Contnrs, uSecureBytes, uSqliteDb, uConnectionProfile,
  uDocumentCrypto;

const
  RTT_APPLICATION_ID = $52545452;
  RTT_SCHEMA_VERSION = 2;
  RTT_EXTENSION = '.rtt';
  PREVIOUS_SUFFIX = '.previous';

type
  TDocOpenStatus = (dosOk, dosNotFound, dosNotRtt, dosWrongPasswordOrDamaged,
    dosFutureVersion, dosUnsupportedCrypto, dosBadKdfParams, dosLockedByOther,
    dosCorruptDatabase, dosMigrationFailed, dosIoError, dosLockFailed,
    dosHardLinked);

  EDocumentError = class(Exception);
  EDocumentConflict = class(EDocumentError);

  TDocFolder = record
    Uuid: string;
    ParentUuid: string;
    Name: string;
    Sort: Integer;
  end;
  TDocFolders = array of TDocFolder;

  // Stockees par leur rang: tout nouveau genre s'ajoute a la fin, sinon les vieux
  // documents changent de sens.
  TDocItemKind = (dikFavorite, dikComparison, dikTemplate, dikDraft, dikSavedSearch,
    dikSearchHistory);

  TDocItem = record
    Uuid: string;
    OwnerUuid: string;
    Name: string;
    Version: Integer;
    Body: string;
    UpdatedUtc: string;
  end;
  TDocItems = array of TDocItem;

  TRtDocument = class
  private
    FPath: string;
    FUuid: string;
    FDb: TSqliteDb;
    FMaster: TSecureBytes;
    FHeader: TEnvelopeHeader;
    FLock: THandle;
    FModified: Boolean;
    FPreviousStale: Boolean;
    FDurabilityUnconfirmed: Boolean;
    FFileAge: Int64;
    FFileSize: Int64;
    FFileDigest: RawByteString;
    FMigratedFrom: Integer;
    FPreviousRevoked: Boolean;
    procedure CreateSchema;
    procedure Migrate(AFrom: Integer);
    function EnvelopeKey: TSecureBytes;
    function SecretKey: TSecureBytes;
    procedure RememberFileState(const AKnownContent: RawByteString);
    procedure WriteMetaUuid(const AUuid: string);
    procedure Touch;
    procedure RevokePrevious;
    procedure ReleaseAll;
  public
    constructor CreateEmpty;
    destructor Destroy; override;
    class function NewDocument(const APassword: RawByteString; AOps: Int64 = DOC_KDF_OPS_DEFAULT;
      AMem: Int64 = DOC_KDF_MEM_DEFAULT): TRtDocument;
    class function Open(const APath: string; const APassword: RawByteString;
      out AStatus: TDocOpenStatus): TRtDocument;
    procedure Save;
    procedure SaveAs(const APath: string);
    function ExternallyModified: Boolean;
    procedure ChangePassword(const ANewPassword: RawByteString);

    function Folders: TDocFolders;
    function AddFolder(const AName, AParentUuid: string): string;
    procedure RenameFolder(const AUuid, AName: string);
    procedure MoveFolder(const AUuid, AParentUuid: string);
    procedure DeleteFolder(const AUuid: string);
    procedure MoveItems(const AFolderUuids, AProfileUuids: array of string;
      const ATargetFolder: string);

    function LoadProfiles: TObjectList;
    function LoadProfile(const AUuid: string): TConnectionProfile;
    procedure SaveProfile(AProfile: TConnectionProfile; const AFolderUuid: string);
    procedure DeleteProfile(const AUuid: string);
    function ProfileFolder(const AUuid: string): string;

    function StoreSecret(const AProfileUuid, AKind: string; APlain: TSecureBytes): string;
    function LoadSecret(const ARef: string): TSecureBytes;
    procedure DeleteSecret(const ARef: string);
    function SecretExists(const ARef: string): Boolean;

    function Items(AKind: TDocItemKind; const AOwnerUuid: string = ''): TDocItems;
    function PutItem(AKind: TDocItemKind; const AItem: TDocItem): string;
    procedure DeleteItem(AKind: TDocItemKind; const AUuid: string);

    procedure AppendAudit(const AProfileUuid, AKind, ADn, ADetail: string);
    function AuditCount: Integer;

    function GetWorkspace(const AKey: string; const ADefault: string = ''): string;
    procedure SetWorkspace(const AKey, AValue: string);

    property Path: string read FPath;
    property Uuid: string read FUuid;
    property Modified: Boolean read FModified;
    property MigratedFromVersion: Integer read FMigratedFrom;
    property PreviousCopyStale: Boolean read FPreviousStale;
    property DurabilityUnconfirmed: Boolean read FDurabilityUnconfirmed;
  end;

function DocOpenStatusText(AStatus: TDocOpenStatus): string;

implementation

uses
  uSodiumApi, uSafeSave, uAppPaths, uProfileJson, uCancel;

const
  SCHEMA_V1 =
    'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);' +
    'CREATE TABLE folders(uuid TEXT PRIMARY KEY, parent_uuid TEXT REFERENCES folders(uuid) ' +
    'ON DELETE CASCADE, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0);' +
    'CREATE TABLE profiles(uuid TEXT PRIMARY KEY, folder_uuid TEXT REFERENCES folders(uuid) ' +
    'ON DELETE SET NULL, sort INTEGER NOT NULL DEFAULT 0, format_version INTEGER NOT NULL, ' +
    'body TEXT NOT NULL);' +
    'CREATE TABLE secrets(uuid TEXT PRIMARY KEY, profile_uuid TEXT REFERENCES profiles(uuid) ' +
    'ON DELETE CASCADE, kind TEXT NOT NULL, blob BLOB NOT NULL, created_utc TEXT NOT NULL);' +
    'CREATE TABLE items(uuid TEXT PRIMARY KEY, kind INTEGER NOT NULL, owner_uuid TEXT, ' +
    'name TEXT NOT NULL, version INTEGER NOT NULL, body TEXT NOT NULL, updated_utc TEXT NOT NULL);' +
    'CREATE TABLE workspace(key TEXT PRIMARY KEY, value TEXT NOT NULL);';
  MIGRATE_V1_V2 =
    'CREATE TABLE audit(id INTEGER PRIMARY KEY AUTOINCREMENT, at_utc TEXT NOT NULL, ' +
    'profile_uuid TEXT, kind TEXT NOT NULL, dn TEXT NOT NULL, detail TEXT NOT NULL);';

function DocOpenStatusText(AStatus: TDocOpenStatus): string;
begin
  case AStatus of
    dosOk: Result := 'Document opened.';
    dosNotFound: Result := 'The file does not exist.';
    dosNotRtt: Result := 'This file is not a Rottentree document.';
    dosWrongPasswordOrDamaged: Result := 'Wrong password, or the file is damaged.';
    dosFutureVersion:
      Result := 'This document was written by a newer version of Rottentree. It was not modified.';
    dosUnsupportedCrypto: Result := 'Unsupported document encryption.';
    dosBadKdfParams: Result := 'The document key parameters are out of the accepted bounds.';
    dosLockedByOther: Result := 'The document is already open for writing elsewhere.';
    dosLockFailed: Result := 'The document lock could not be created (permissions or inaccessible application folder); opening is refused.';
    dosCorruptDatabase: Result := 'The document content failed its integrity check.';
    dosMigrationFailed: Result := 'The document could not be upgraded; the file was not modified.';
    dosHardLinked: Result := 'The file has several hard links. Saving would silently detach the other names, so opening is refused.';
  else
    Result := 'The file could not be read.';
  end;
end;

constructor TRtDocument.CreateEmpty;
begin
  inherited Create;
  FLock := THandle(-1);
end;

destructor TRtDocument.Destroy;
begin
  ReleaseAll;
  inherited Destroy;
end;

procedure TRtDocument.ReleaseAll;
begin
  FreeAndNil(FDb);
  // La cle maitresse est effacee par sodium_free.
  FreeAndNil(FMaster);
  if FLock <> THandle(-1) then
  begin
    UnlockDocument(FLock);
    FLock := THandle(-1);
  end;
end;

procedure TRtDocument.CreateSchema;
begin
  FDb.BeginImmediate;
  try
    FDb.ExecScript(SCHEMA_V1);
    FDb.ExecScript(MIGRATE_V1_V2);
    FDb.SetApplicationId(RTT_APPLICATION_ID);
    FDb.SetUserVersion(RTT_SCHEMA_VERSION);
    FUuid := NewUuidV4;
    FDb.ExecScript(Format('INSERT INTO meta(key, value) VALUES(''document_uuid'', ''%s''), ' +
      '(''created_utc'', ''%s'');', [FUuid, FormatUtcIso(UtcNow)]));
    FDb.Commit;
  except
    FDb.Rollback;
    raise;
  end;
end;

procedure TRtDocument.Migrate(AFrom: Integer);
begin
  // Transactionnel: un echec laisse la base memoire et le fichier intacts.
  FDb.BeginImmediate;
  try
    if AFrom < 2 then
      FDb.ExecScript(MIGRATE_V1_V2);
    FDb.SetUserVersion(RTT_SCHEMA_VERSION);
    FDb.Commit;
  except
    FDb.Rollback;
    raise;
  end;
  FMigratedFrom := AFrom;
  FModified := True;
end;

function TRtDocument.EnvelopeKey: TSecureBytes;
begin
  Result := DeriveSubKey(FMaster, KDF_ID_ENVELOPE, KDF_CTX_ENVELOPE);
end;

function TRtDocument.SecretKey: TSecureBytes;
begin
  Result := DeriveSubKey(FMaster, KDF_ID_SECRETS, KDF_CTX_SECRETS);
end;

class function TRtDocument.NewDocument(const APassword: RawByteString; AOps, AMem: Int64): TRtDocument;
begin
  SodiumEnsureLoaded;
  Result := TRtDocument.CreateEmpty;
  try
    Result.FHeader.FormatVersion := RTT_FORMAT_VERSION;
    Result.FHeader.CryptoVersion := RTT_CRYPTO_VERSION;
    Result.FHeader.Salt := SystemRandomBytes(DOC_KDF_SALT_BYTES);
    Result.FHeader.Ops := AOps;
    Result.FHeader.Mem := AMem;
    Result.FMaster := DeriveMasterKey(APassword, Result.FHeader.Salt, AOps, AMem);
    Result.FDb := TSqliteDb.CreateMemory;
    Result.CreateSchema;
    Result.FModified := True;
  except
    Result.Free;
    raise;
  end;
end;

function ReadWholeFile(const APath: string; out AData: RawByteString): Boolean;
var
  fs: THandleStream;
  notRegular: Boolean;
begin
  Result := False;
  AData := '';
  try
    // Fichier ordinaire seulement: un FIFO ou un peripherique bloquerait avant meme le
    // controle de taille.
    fs := OpenRegularFileRead(APath, notRegular);
    if fs = nil then Exit;
    try
      // Taille lue une fois, lecture bornee a cette capacite.
      Result := ReadWholeStream(fs, DOC_MAX_BYTES, AData);
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

class function TRtDocument.Open(const APath: string; const APassword: RawByteString;
  out AStatus: TDocOpenStatus): TRtDocument;
var
  data, image: RawByteString;
  hs: THeaderStatus;
  doc: TRtDocument;
  key: TSecureBytes;
  version: Int64;
  lockOutcome: TLockOutcome;
  realPath: string;
  stmt: TSqliteStmt;
begin
  Result := nil;
  // Identite physique etablie UNE FOIS a l'ouverture: lecture, verrou et sauvegardes
  // visent le meme fichier reel. Sinon sauvegarder via un lien symbolique remplace le
  // lien (rename) pendant que le verrou garde la cible: deux redacteurs, un seul
  // fichier.
  if not FileExists(ExpandFileName(APath)) then
  begin
    AStatus := dosNotFound;
    Exit;
  end;
  // TOUS les composants resolus: un lien sur un dossier intermediaire donnerait un
  // autre nom de verrou, donc un second redacteur.
  try
    realPath := CanonicalFilePath(APath);
  except
    // Chaine de liens insoluble: refus plutot qu'une identite fausse.
    AStatus := dosIoError;
    Exit;
  end;
  if not FileExists(realPath) then
  begin
    AStatus := dosNotFound;
    Exit;
  end;
  // Un fichier a plusieurs liens physiques serait detache en silence des autres noms
  // par le rename atomique: refus explicite.
  if HasHardLinks(realPath) then
  begin
    AStatus := dosHardLinked;
    Exit;
  end;
  doc := TRtDocument.CreateEmpty;
  try
    // Verrou AVANT toute lecture: on interprete le fichier verrouille, pas celui qu'on
    // aurait echange entre la lecture et le verrou. Tout echec libere le verrou via
    // doc.Free.
    doc.FLock := TryLockDocument(realPath, lockOutcome);
    case lockOutcome of
      loHeldByOther:
        begin
          AStatus := dosLockedByOther;
          Exit;
        end;
      loError:
        begin
          // Sans verrou effectif, aucun document modifiable.
          AStatus := dosLockFailed;
          Exit;
        end;
    end;
    if not ReadWholeFile(realPath, data) then
    begin
      AStatus := dosIoError;
      Exit;
    end;
    hs := ParseEnvelopeHeader(data, doc.FHeader);
    case hs of
      hsTooShort, hsNotRtt: AStatus := dosNotRtt;
      hsFutureFormat: AStatus := dosFutureVersion;
      hsUnsupportedCrypto: AStatus := dosUnsupportedCrypto;
      hsBadKdfParams: AStatus := dosBadKdfParams;
    else
      AStatus := dosOk;
    end;
    if AStatus <> dosOk then Exit;
    doc.FMaster := DeriveMasterKey(APassword, doc.FHeader.Salt, doc.FHeader.Ops, doc.FHeader.Mem);
    key := doc.EnvelopeKey;
    try
      if not OpenEnvelope(data, key, image) then
      begin
        AStatus := dosWrongPasswordOrDamaged;
        Exit;
      end;
    finally
      key.Free;
    end;
    doc.FDb := TSqliteDb.CreateMemory;
    try
      try
        doc.FDb.LoadImage(image);
      except
        AStatus := dosCorruptDatabase;
        Exit;
      end;
    finally
      // Image dechiffree effacee sur tous les chemins, exception de LoadImage comprise.
      if image <> '' then FillChar(image[1], Length(image), 0);
    end;
    if (not doc.FDb.IntegrityCheckOk) or (doc.FDb.GetApplicationId <> RTT_APPLICATION_ID) then
    begin
      AStatus := dosCorruptDatabase;
      Exit;
    end;
    version := doc.FDb.GetUserVersion;
    if version > RTT_SCHEMA_VERSION then
    begin
      AStatus := dosFutureVersion;
      Exit;
    end;
    if version < 1 then
    begin
      AStatus := dosCorruptDatabase;
      Exit;
    end;
    if version < RTT_SCHEMA_VERSION then
    begin
      try
        doc.Migrate(version);
      except
        AStatus := dosMigrationFailed;
        Exit;
      end;
    end;
    doc.FUuid := '';
    stmt := doc.FDb.Prepare('SELECT value FROM meta WHERE key = ''document_uuid'';');
    try
      if stmt.Step then
        doc.FUuid := stmt.ColText(0);
    finally
      stmt.Free;
    end;
    if doc.FUuid = '' then
    begin
      doc.FUuid := NewUuidV4;
      doc.FDb.ExecScript(Format(
        'INSERT OR REPLACE INTO meta(key, value) VALUES(''document_uuid'', ''%s'');',
        [doc.FUuid]));
      doc.FModified := True;
    end;
    doc.FPath := realPath;
    doc.RememberFileState(data);
    Result := doc;
    doc := nil;
  finally
    doc.Free;
  end;
end;

function DataDigest(const AData: RawByteString): RawByteString;
var
  h: array[0..31] of Byte;
begin
  SodiumEnsureLoaded;
  if AData = '' then
    crypto_generichash(@h[0], 32, nil, 0, nil, 0)
  else
    crypto_generichash(@h[0], 32, @AData[1], Length(AData), nil, 0);
  SetLength(Result, 32);
  Move(h[0], Result[1], 32);
end;

function FileDigest(const APath: string): RawByteString;
var
  data: RawByteString;
begin
  Result := '';
  if not ReadWholeFile(APath, data) then Exit;
  Result := DataDigest(data);
end;

procedure TRtDocument.RememberFileState(const AKnownContent: RawByteString);
var
  sr: TSearchRec;
begin
  FFileAge := 0;
  FFileSize := -1;
  // Empreinte des octets lus ou ecrits, jamais d'une relecture: un fichier substitue
  // depuis doit rester visible pour ExternallyModified, pas etre absorbe.
  FFileDigest := DataDigest(AKnownContent);
  if FindFirst(FPath, faAnyFile, sr) = 0 then
  begin
    FFileAge := sr.Time;
    FFileSize := sr.Size;
    FindClose(sr);
  end;
end;

procedure TRtDocument.WriteMetaUuid(const AUuid: string);
var
  stmt: TSqliteStmt;
begin
  stmt := FDb.Prepare('INSERT OR REPLACE INTO meta(key, value) VALUES(''document_uuid'', ?1);');
  try
    stmt.BindText(1, AUuid);
    stmt.Step;
  finally
    stmt.Free;
  end;
end;

function TRtDocument.ExternallyModified: Boolean;
var
  sr: TSearchRec;
begin
  Result := False;
  if FPath = '' then Exit;
  if FindFirst(FPath, faAnyFile, sr) <> 0 then
    Exit(FFileSize >= 0);
  Result := (sr.Time <> FFileAge) or (sr.Size <> FFileSize);
  FindClose(sr);
  if (not Result) and (FFileDigest <> '') then
    Result := FileDigest(FPath) <> FFileDigest;
end;

procedure TRtDocument.Save;
begin
  if FPath = '' then
    raise EDocumentError.Create('the document has no file name yet');
  if ExternallyModified then
    raise EDocumentConflict.Create('the file was modified outside Rottentree');
  SaveAs(FPath);
end;

procedure TRtDocument.SaveAs(const APath: string);
var
  image, sealed, previous: RawByteString;
  key: TSecureBytes;
  dest, tmp, prevTmp: string;
  st: TOwnedHandleStream;
  lockOutcome: TLockOutcome;
  newLock: THandle;
  prevOk, stale, synced, forking: Boolean;
  forkUuid: string;
begin
  if FDb = nil then
    raise EDocumentError.Create('the document is locked');
  // Meme identite physique qu'a l'ouverture: le rename atomique remplacerait un lien
  // symbolique au lieu de sa cible, et un dossier lie donnerait un autre verrou.
  try
    dest := CanonicalFilePath(APath);
  except
    raise EDocumentError.Create('the target path cannot be resolved (broken link or missing folder)');
  end;
  if FileExists(dest) and HasHardLinks(dest) then
    raise EDocumentError.Create('the target file has several hard links: replacing it ' +
      'would silently detach the other names, so the save is refused');
  // "Enregistrer sous" vers un autre fichier: la copie recoit une identite neuve. Sinon
  // deux fichiers portent le meme document_uuid, et le journal des ecritures ne sait
  // plus lequel croire.
  forking := (FPath <> '') and not SameFileName(dest, FPath);
  forkUuid := '';
  newLock := THandle(-1);
  if not SameFileName(dest, ExpandFileName(FPath)) then
  begin
    newLock := TryLockDocument(dest, lockOutcome);
    if lockOutcome = loHeldByOther then
      raise EDocumentError.Create('the target document is open elsewhere');
    if lockOutcome <> loAcquired then
      raise EDocumentError.Create('the document lock could not be created for the target file');
  end;
  stale := False;
  synced := False;
  // A partir d'ici, toute erreur rend le verrou de destination et, pour une copie,
  // l'identite d'origine.
  try
    if forking then
    begin
      forkUuid := NewUuidV4;
      WriteMetaUuid(forkUuid);
    end;
    image := FDb.SaveImage;
    key := EnvelopeKey;
    try
      sealed := SealEnvelope(image, key, FHeader);
    finally
      key.Free;
      if image <> '' then FillChar(image[1], Length(image), 0);
    end;
    // L'ouverture refuse au-dela de DOC_MAX_BYTES: ne rien ecrire qu'on ne saurait
    // relire.
    if Length(sealed) > DOC_MAX_BYTES then
      raise EDocumentError.Create('the document exceeds the maximum document size');
    // Copie precedente: la derniere version valide reste recuperable. Apres retrait
    // d'un secret ou changement de mot de passe, la copie recoit le nouveau contenu:
    // l'ancien fichier garderait le secret ou s'ouvrirait avec l'ancien mot de passe.
    previous := '';
    if FPreviousRevoked then
      previous := sealed
    else if FileExists(dest) and not ReadWholeFile(dest, previous) then
    begin
      // Fichier remplace illisible (taille, type, acces refuse): il ne devient pas la
      // copie .previous. La sauvegarde continue, le filet perime est signale.
      previous := '';
      stale := True;
    end;
    if previous <> '' then
    begin
      prevTmp := '';
      prevOk := False;
      st := CreateTempIn(dest + PREVIOUS_SUFFIX, prevTmp);
      try
        st.WriteBuffer(previous[1], Length(previous));
        // Un flush refuse laisse un .previous peut-etre illisible apres coupure: il
        // compte comme un echec.
        prevOk := FlushToDisk(st.Handle);
      finally
        st.Free;
      end;
      if prevOk then
        prevOk := ReplaceByRenamePrivate(prevTmp, dest + PREVIOUS_SUFFIX);
      if not prevOk then
      begin
        DeleteFile(prevTmp);
        // Jamais d'ancienne copie revoquee laissee en place.
        if FPreviousRevoked and FileExists(dest + PREVIOUS_SUFFIX) and
          not DeleteFile(dest + PREVIOUS_SUFFIX) then
          raise EDocumentError.Create('the previous copy of the document could not be replaced');
        // La sauvegarde continue mais le filet est perime: signale via
        // PreviousCopyStale, jamais en silence.
        stale := True;
      end;
    end;
    tmp := '';
    st := CreateTempIn(dest, tmp);
    try
      try
        st.WriteBuffer(sealed[1], Length(sealed));
        if not FlushToDisk(st.Handle) then
          raise EDocumentError.Create('the disk did not confirm the write');
      finally
        st.Free;
      end;
      // .previous et le document partagent le dossier: la synchronisation qui suit ce
      // rename couvre les deux entrees.
      if not ReplaceByRenamePrivate(tmp, dest, synced) then
        raise EDocumentError.Create('cannot replace the document file');
    except
      DeleteFile(tmp);
      raise;
    end;
  except
    if forkUuid <> '' then
      try
        WriteMetaUuid(FUuid);
      except
      end;
    if newLock <> THandle(-1) then UnlockDocument(newLock);
    raise;
  end;
  if forkUuid <> '' then
    FUuid := forkUuid;
  FPreviousStale := stale;
  FDurabilityUnconfirmed := not synced;
  if newLock <> THandle(-1) then
  begin
    if FLock <> THandle(-1) then UnlockDocument(FLock);
    FLock := newLock;
  end
  else if FLock = THandle(-1) then
  begin
    FLock := TryLockDocument(dest, lockOutcome);
    if lockOutcome <> loAcquired then
      raise EDocumentError.Create('the document was written but its lock could not be created');
  end;
  FPath := dest;
  FModified := False;
  FPreviousRevoked := False;
  RememberFileState(sealed);
end;

procedure TRtDocument.ChangePassword(const ANewPassword: RawByteString);
var
  newMaster, oldSecretKey, newSecretKey: TSecureBytes;
  st, upd: TSqliteStmt;
  plain: TSecureBytes;
  refs: TStringList;
  blobs: TStringList;
  i: Integer;
  newHeader: TEnvelopeHeader;
begin
  newHeader := FHeader;
  newHeader.Salt := SystemRandomBytes(DOC_KDF_SALT_BYTES);
  newMaster := DeriveMasterKey(ANewPassword, newHeader.Salt, newHeader.Ops, newHeader.Mem);
  oldSecretKey := SecretKey;
  refs := TStringList.Create;
  blobs := TStringList.Create;
  try
    try
      // Les secrets sont rechiffres avec la sous-cle derivee du nouveau maitre.
      st := FDb.Prepare('SELECT uuid, blob FROM secrets;');
      try
        while st.Step do
        begin
          refs.Add(st.ColText(0));
          blobs.Add(st.ColBlob(1));
        end;
      finally
        st.Free;
      end;
      newSecretKey := DeriveSubKey(newMaster, KDF_ID_SECRETS, KDF_CTX_SECRETS);
      try
        FDb.BeginImmediate;
        try
          upd := FDb.Prepare('UPDATE secrets SET blob = ?1 WHERE uuid = ?2;');
          try
            for i := 0 to refs.Count - 1 do
            begin
              if not OpenSecret(oldSecretKey, refs[i], blobs[i], plain) then
                raise EDocumentError.Create('a stored secret could not be decrypted');
              try
                upd.Reset;
                upd.BindBlob(1, SealSecret(newSecretKey, refs[i], plain));
                upd.BindText(2, refs[i]);
                upd.Step;
              finally
                plain.Free;
              end;
            end;
          finally
            upd.Free;
          end;
          FDb.Commit;
        except
          FDb.Rollback;
          raise;
        end;
      finally
        newSecretKey.Free;
      end;
    except
      newMaster.Free;
      raise;
    end;
    FMaster.Free;
    FMaster := newMaster;
    FHeader := newHeader;
    // L'ancien fichier s'ouvre avec l'ancien mot de passe, peut-etre compromis: il ne
    // survivra pas comme copie precedente.
    RevokePrevious;
  finally
    oldSecretKey.Free;
    refs.Free;
    blobs.Free;
  end;
end;

procedure TRtDocument.Touch;
begin
  FModified := True;
end;

procedure TRtDocument.RevokePrevious;
begin
  FPreviousRevoked := True;
  Touch;
end;

function TRtDocument.Folders: TDocFolders;
var
  st: TSqliteStmt;
begin
  Result := nil;
  st := FDb.Prepare('SELECT uuid, parent_uuid, name, sort FROM folders ORDER BY sort, name;');
  try
    while st.Step do
    begin
      SetLength(Result, Length(Result) + 1);
      with Result[High(Result)] do
      begin
        Uuid := st.ColText(0);
        if st.ColIsNull(1) then ParentUuid := '' else ParentUuid := st.ColText(1);
        Name := st.ColText(2);
        Sort := st.ColInt64(3);
      end;
    end;
  finally
    st.Free;
  end;
end;

function TRtDocument.AddFolder(const AName, AParentUuid: string): string;
var
  st: TSqliteStmt;
begin
  Result := NewUuidV4;
  st := FDb.Prepare('INSERT INTO folders(uuid, parent_uuid, name) VALUES(?1, ?2, ?3);');
  try
    st.BindText(1, Result);
    if AParentUuid = '' then st.BindNull(2) else st.BindText(2, AParentUuid);
    st.BindText(3, AName);
    st.Step;
  finally
    st.Free;
  end;
  Touch;
end;

procedure TRtDocument.RenameFolder(const AUuid, AName: string);
var
  st: TSqliteStmt;
begin
  st := FDb.Prepare('UPDATE folders SET name = ?1 WHERE uuid = ?2;');
  try
    st.BindText(1, AName);
    st.BindText(2, AUuid);
    st.Step;
  finally
    st.Free;
  end;
  Touch;
end;

procedure TRtDocument.MoveFolder(const AUuid, AParentUuid: string);
var
  st: TSqliteStmt;
  cur: string;
  depth: Integer;
begin
  cur := AParentUuid;
  depth := 0;
  while cur <> '' do
  begin
    if cur = AUuid then
      raise EDocumentError.Create('a folder cannot be moved into itself');
    st := FDb.Prepare('SELECT parent_uuid FROM folders WHERE uuid = ?1;');
    try
      st.BindText(1, cur);
      if st.Step and not st.ColIsNull(0) then cur := st.ColText(0) else cur := '';
    finally
      st.Free;
    end;
    Inc(depth);
    if depth > 64 then
      raise EDocumentError.Create('folder tree too deep');
  end;
  st := FDb.Prepare('UPDATE folders SET parent_uuid = ?1 WHERE uuid = ?2;');
  try
    if AParentUuid = '' then st.BindNull(1) else st.BindText(1, AParentUuid);
    st.BindText(2, AUuid);
    st.Step;
  finally
    st.Free;
  end;
  Touch;
end;

procedure TRtDocument.MoveItems(const AFolderUuids, AProfileUuids: array of string;
  const ATargetFolder: string);
var
  st: TSqliteStmt;
  i: Integer;
  wasModified: Boolean;
begin
  wasModified := FModified;
  FDb.BeginImmediate;
  try
    if ATargetFolder <> '' then
    begin
      st := FDb.Prepare('SELECT 1 FROM folders WHERE uuid = ?1;');
      try
        st.BindText(1, ATargetFolder);
        if not st.Step then
          raise EDocumentError.Create('destination folder not found');
      finally
        st.Free;
      end;
    end;
    for i := 0 to High(AFolderUuids) do
      MoveFolder(AFolderUuids[i], ATargetFolder);
    for i := 0 to High(AProfileUuids) do
    begin
      st := FDb.Prepare('UPDATE profiles SET folder_uuid = ?1 WHERE uuid = ?2;');
      try
        if ATargetFolder = '' then st.BindNull(1) else st.BindText(1, ATargetFolder);
        st.BindText(2, AProfileUuids[i]);
        st.Step;
      finally
        st.Free;
      end;
    end;
    FDb.Commit;
  except
    FDb.Rollback;
    FModified := wasModified;
    raise;
  end;
  Touch;
end;

procedure TRtDocument.DeleteFolder(const AUuid: string);
var
  st: TSqliteStmt;
begin
  st := FDb.Prepare('DELETE FROM folders WHERE uuid = ?1;');
  try
    st.BindText(1, AUuid);
    st.Step;
  finally
    st.Free;
  end;
  Touch;
end;

function TRtDocument.LoadProfiles: TObjectList;
var
  st: TSqliteStmt;
begin
  Result := TObjectList.Create(True);
  try
    st := FDb.Prepare('SELECT body FROM profiles ORDER BY sort, uuid;');
    try
      while st.Step do
        Result.Add(ProfileFromJsonText(st.ColText(0)));
    finally
      st.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TRtDocument.LoadProfile(const AUuid: string): TConnectionProfile;
var
  st: TSqliteStmt;
begin
  Result := nil;
  st := FDb.Prepare('SELECT body FROM profiles WHERE uuid = ?1;');
  try
    st.BindText(1, AUuid);
    if st.Step then
      Result := ProfileFromJsonText(st.ColText(0));
  finally
    st.Free;
  end;
end;

procedure TRtDocument.SaveProfile(AProfile: TConnectionProfile; const AFolderUuid: string);
var
  st: TSqliteStmt;
begin
  if AProfile.Uuid = '' then
    AProfile.Uuid := NewUuidV4;
  st := FDb.Prepare('INSERT INTO profiles(uuid, folder_uuid, format_version, body) ' +
    'VALUES(?1, ?2, ?3, ?4) ON CONFLICT(uuid) DO UPDATE SET folder_uuid = excluded.folder_uuid, ' +
    'format_version = excluded.format_version, body = excluded.body;');
  try
    st.BindText(1, AProfile.Uuid);
    if AFolderUuid = '' then st.BindNull(2) else st.BindText(2, AFolderUuid);
    st.BindInt64(3, PROFILE_JSON_VERSION);
    st.BindText(4, ProfileToJsonText(AProfile, True));
    st.Step;
  finally
    st.Free;
  end;
  Touch;
end;

procedure TRtDocument.DeleteProfile(const AUuid: string);
var
  st: TSqliteStmt;
begin
  st := FDb.Prepare('DELETE FROM profiles WHERE uuid = ?1;');
  try
    st.BindText(1, AUuid);
    st.Step;
  finally
    st.Free;
  end;
  st := FDb.Prepare('DELETE FROM items WHERE owner_uuid = ?1;');
  try
    st.BindText(1, AUuid);
    st.Step;
  finally
    st.Free;
  end;
  // Les secrets du profil partent en cascade; la copie precedente, elle, les garderait.
  RevokePrevious;
end;

function TRtDocument.ProfileFolder(const AUuid: string): string;
var
  st: TSqliteStmt;
begin
  Result := '';
  st := FDb.Prepare('SELECT folder_uuid FROM profiles WHERE uuid = ?1;');
  try
    st.BindText(1, AUuid);
    if st.Step and not st.ColIsNull(0) then
      Result := st.ColText(0);
  finally
    st.Free;
  end;
end;

function TRtDocument.StoreSecret(const AProfileUuid, AKind: string; APlain: TSecureBytes): string;
var
  st: TSqliteStmt;
  key: TSecureBytes;
begin
  Result := NewUuidV4;
  key := SecretKey;
  try
    st := FDb.Prepare('INSERT INTO secrets(uuid, profile_uuid, kind, blob, created_utc) ' +
      'VALUES(?1, ?2, ?3, ?4, ?5);');
    try
      st.BindText(1, Result);
      if AProfileUuid = '' then st.BindNull(2) else st.BindText(2, AProfileUuid);
      st.BindText(3, AKind);
      st.BindBlob(4, SealSecret(key, Result, APlain));
      st.BindText(5, FormatUtcIso(UtcNow));
      st.Step;
    finally
      st.Free;
    end;
  finally
    key.Free;
  end;
  Touch;
end;

function TRtDocument.LoadSecret(const ARef: string): TSecureBytes;
var
  st: TSqliteStmt;
  key: TSecureBytes;
  blob: RawByteString;
begin
  Result := nil;
  st := FDb.Prepare('SELECT blob FROM secrets WHERE uuid = ?1;');
  try
    st.BindText(1, ARef);
    if not st.Step then Exit;
    blob := st.ColBlob(0);
  finally
    st.Free;
  end;
  key := SecretKey;
  try
    if not OpenSecret(key, ARef, blob, Result) then
      Result := nil;
  finally
    key.Free;
  end;
end;

procedure TRtDocument.DeleteSecret(const ARef: string);
var
  st: TSqliteStmt;
begin
  st := FDb.Prepare('DELETE FROM secrets WHERE uuid = ?1;');
  try
    st.BindText(1, ARef);
    st.Step;
  finally
    st.Free;
  end;
  RevokePrevious;
end;

function TRtDocument.SecretExists(const ARef: string): Boolean;
var
  st: TSqliteStmt;
begin
  st := FDb.Prepare('SELECT 1 FROM secrets WHERE uuid = ?1;');
  try
    st.BindText(1, ARef);
    Result := st.Step;
  finally
    st.Free;
  end;
end;

function TRtDocument.Items(AKind: TDocItemKind; const AOwnerUuid: string): TDocItems;
var
  st: TSqliteStmt;
begin
  Result := nil;
  if AOwnerUuid = '' then
    st := FDb.Prepare('SELECT uuid, owner_uuid, name, version, body, updated_utc FROM items ' +
      'WHERE kind = ?1 ORDER BY name;')
  else
    st := FDb.Prepare('SELECT uuid, owner_uuid, name, version, body, updated_utc FROM items ' +
      'WHERE kind = ?1 AND owner_uuid = ?2 ORDER BY name;');
  try
    st.BindInt64(1, Ord(AKind));
    if AOwnerUuid <> '' then st.BindText(2, AOwnerUuid);
    while st.Step do
    begin
      SetLength(Result, Length(Result) + 1);
      with Result[High(Result)] do
      begin
        Uuid := st.ColText(0);
        if st.ColIsNull(1) then OwnerUuid := '' else OwnerUuid := st.ColText(1);
        Name := st.ColText(2);
        Version := st.ColInt64(3);
        Body := st.ColText(4);
        UpdatedUtc := st.ColText(5);
      end;
    end;
  finally
    st.Free;
  end;
end;

function TRtDocument.PutItem(AKind: TDocItemKind; const AItem: TDocItem): string;
var
  st: TSqliteStmt;
begin
  Result := AItem.Uuid;
  if Result = '' then Result := NewUuidV4;
  st := FDb.Prepare('INSERT INTO items(uuid, kind, owner_uuid, name, version, body, updated_utc) ' +
    'VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(uuid) DO UPDATE SET owner_uuid = excluded.owner_uuid, ' +
    'name = excluded.name, version = excluded.version, body = excluded.body, ' +
    'updated_utc = excluded.updated_utc;');
  try
    st.BindText(1, Result);
    st.BindInt64(2, Ord(AKind));
    if AItem.OwnerUuid = '' then st.BindNull(3) else st.BindText(3, AItem.OwnerUuid);
    st.BindText(4, AItem.Name);
    st.BindInt64(5, AItem.Version);
    st.BindText(6, AItem.Body);
    st.BindText(7, FormatUtcIso(UtcNow));
    st.Step;
  finally
    st.Free;
  end;
  Touch;
end;

procedure TRtDocument.DeleteItem(AKind: TDocItemKind; const AUuid: string);
var
  st: TSqliteStmt;
begin
  st := FDb.Prepare('DELETE FROM items WHERE uuid = ?1 AND kind = ?2;');
  try
    st.BindText(1, AUuid);
    st.BindInt64(2, Ord(AKind));
    st.Step;
  finally
    st.Free;
  end;
  Touch;
end;

procedure TRtDocument.AppendAudit(const AProfileUuid, AKind, ADn, ADetail: string);
var
  st: TSqliteStmt;
begin
  st := FDb.Prepare('INSERT INTO audit(at_utc, profile_uuid, kind, dn, detail) VALUES(?1, ?2, ?3, ?4, ?5);');
  try
    st.BindText(1, FormatUtcIso(UtcNow));
    if AProfileUuid = '' then st.BindNull(2) else st.BindText(2, AProfileUuid);
    st.BindText(3, AKind);
    st.BindText(4, ADn);
    st.BindText(5, ADetail);
    st.Step;
  finally
    st.Free;
  end;
  Touch;
end;

function TRtDocument.AuditCount: Integer;
begin
  Result := FDb.ExecScalarInt('SELECT COUNT(*) FROM audit;');
end;

function TRtDocument.GetWorkspace(const AKey: string; const ADefault: string): string;
var
  st: TSqliteStmt;
begin
  Result := ADefault;
  st := FDb.Prepare('SELECT value FROM workspace WHERE key = ?1;');
  try
    st.BindText(1, AKey);
    if st.Step then Result := st.ColText(0);
  finally
    st.Free;
  end;
end;

procedure TRtDocument.SetWorkspace(const AKey, AValue: string);
var
  st: TSqliteStmt;
begin
  st := FDb.Prepare('INSERT INTO workspace(key, value) VALUES(?1, ?2) ' +
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value;');
  try
    st.BindText(1, AKey);
    st.BindText(2, AValue);
    st.Step;
  finally
    st.Free;
  end;
  Touch;
end;

end.
