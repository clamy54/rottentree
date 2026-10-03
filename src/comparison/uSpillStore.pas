// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSpillStore;

{$mode objfpc}{$H+}

// Magasin des enregistrements canoniques d'une comparaison: en memoire jusqu'au budget,
// puis fichier temporaire chiffre par blocs authentifies, sous une cle ephemere qui ne
// quitte jamais la memoire. Quota disque verifie avant chaque extension. L'effacement
// physique sur SSD, lui, releve de la foi.

interface

uses
  SysUtils, Classes, uSecureBytes, uSafeSave;

type
  ESpillStore = class(Exception);

  TSpillStore = class
  private
    FMemory: TStringList;
    FMemoryBytes: Int64;
    FIndexBytes: Int64;
    FBudgetBytes: Int64;
    FQuotaBytes: Int64;
    FFile: TOwnedHandleStream;
    FFilePath: string;
    FTempDir: string;
    FKey: TSecureBytes;
    FSpilledBytes: Int64;
    FSpilledCount: Int64;
    procedure EnsureFile;
    function IndexBudget: Int64;
    function ContentBudget: Int64;
  public
    constructor Create(ABudgetBytes, AQuotaBytes: Int64; const ATempDir: string);
    destructor Destroy; override;
    function Put(const AData: RawByteString): Int64;
    function Get(AHandle: Int64): RawByteString;
    procedure Account(ABytes: Int64);
    function OverBudget: Boolean;
    function IndexOverBudget: Boolean;
    property MemoryBytes: Int64 read FMemoryBytes;
    property IndexBytes: Int64 read FIndexBytes;
    property SpilledBytes: Int64 read FSpilledBytes;
    property SpilledCount: Int64 read FSpilledCount;
  end;

procedure CleanOrphanSpillFiles(const ATempDir: string);

implementation

uses
  ctypes, uSodiumApi;

function HexOf(const S: RawByteString): string; forward;

const
  SPILL_PREFIX = 'rottentree-spill-';
  NONCE_BYTES = 24;
  TAG_BYTES = 16;
  RECORD_OVERHEAD = 32;
  // Un enregistrement porte formes comparees ET valeurs recues, soit environ deux
  // ENTRY_MAX_BYTES plus les longueurs. Meme borne a l'ecriture et a la relecture.
  SPILL_MAX_RECORD_BYTES = 256 * 1024 * 1024;

constructor TSpillStore.Create(ABudgetBytes, AQuotaBytes: Int64; const ATempDir: string);
begin
  inherited Create;
  FMemory := TStringList.Create;
  FBudgetBytes := ABudgetBytes;
  FQuotaBytes := AQuotaBytes;
  FTempDir := IncludeTrailingPathDelimiter(ATempDir);
  FFilePath := '';
end;

destructor TSpillStore.Destroy;
begin
  FMemory.Free;
  if FFile <> nil then
  begin
    FFile.Free;
    if FFilePath <> '' then DeleteFile(FFilePath);
  end;
  FKey.Free;
  inherited Destroy;
end;

procedure TSpillStore.EnsureFile;
var
  h: THandle;
  i: Integer;
  name: string;
begin
  if FFile <> nil then Exit;
  SodiumEnsureLoaded;
  FKey := TSecureBytes.Create(32);
  randombytes_buf(FKey.Data, 32);
  // Nom aleatoire et creation exclusive: aucun fichier preexistant n'est tronque, et le
  // handle obtenu est le seul qui servira. Pas de seconde ouverture a detourner.
  h := THandle(-1);
  for i := 1 to 20 do
  begin
    name := FTempDir + SPILL_PREFIX + LowerCase(HexOf(SystemRandomBytes(12))) + '.bin';
    h := CreatePrivateTempRW(name);
    if h <> THandle(-1) then Break;
  end;
  if h = THandle(-1) then
    raise ESpillStore.Create('cannot create the temporary comparison store');
  FFilePath := name;
  FFile := TOwnedHandleStream.Create(h);
end;

function HexOf(const S: RawByteString): string;
const
  Digits: array[0..15] of Char = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, Length(S) * 2);
  for i := 1 to Length(S) do
  begin
    Result[i * 2 - 1] := Digits[Ord(S[i]) shr 4];
    Result[i * 2] := Digits[Ord(S[i]) and 15];
  end;
end;

procedure TSpillStore.Account(ABytes: Int64);
begin
  Inc(FIndexBytes, ABytes);
end;

function TSpillStore.IndexBudget: Int64;
begin
  Result := (FBudgetBytes div 4) * 3;
end;

function TSpillStore.ContentBudget: Int64;
begin
  Result := FBudgetBytes - IndexBudget;
end;

function TSpillStore.OverBudget: Boolean;
begin
  Result := FMemoryBytes + FIndexBytes > FBudgetBytes;
end;

function TSpillStore.IndexOverBudget: Boolean;
begin
  Result := FIndexBytes > IndexBudget;
end;

function TSpillStore.Put(const AData: RawByteString): Int64;
var
  nonce, cipher: RawByteString;
  clen: cuint64;
  lenBuf: array[0..3] of Byte;
  n: Integer;
begin
  if FMemoryBytes + Length(AData) + RECORD_OVERHEAD <= ContentBudget then
  begin
    Result := FMemory.Add(AData);
    Inc(FMemoryBytes, Length(AData) + RECORD_OVERHEAD);
    Exit;
  end;
  if AData = '' then
    raise ESpillStore.Create('memory budget reached by the temporary store: the comparison stops explicitly');
  if Length(AData) > SPILL_MAX_RECORD_BYTES then
    raise ESpillStore.Create('an entry is too large for the temporary store: the comparison stops explicitly');
  EnsureFile;
  if FSpilledBytes + Length(AData) + NONCE_BYTES + TAG_BYTES + 4 > FQuotaBytes then
    raise ESpillStore.Create('temporary disk quota reached: the comparison stops explicitly');
  nonce := SystemRandomBytes(NONCE_BYTES);
  SetLength(cipher, Length(AData) + TAG_BYTES);
  clen := 0;
  if crypto_aead_xchacha20poly1305_ietf_encrypt(@cipher[1], @clen, @AData[1], Length(AData),
      nil, 0, nil, @nonce[1], FKey.Data) <> 0 then
    raise ESpillStore.Create('temporary store encryption failed');
  Result := -(FFile.Size + 1);
  FFile.Seek(0, soEnd);
  n := clen;
  lenBuf[0] := n and $FF;
  lenBuf[1] := (n shr 8) and $FF;
  lenBuf[2] := (n shr 16) and $FF;
  lenBuf[3] := (n shr 24) and $FF;
  FFile.WriteBuffer(lenBuf, 4);
  FFile.WriteBuffer(nonce[1], NONCE_BYTES);
  FFile.WriteBuffer(cipher[1], clen);
  Inc(FSpilledBytes, 4 + NONCE_BYTES + clen);
  Inc(FSpilledCount);
end;

function TSpillStore.Get(AHandle: Int64): RawByteString;
var
  lenBuf: array[0..3] of Byte;
  n: Integer;
  nonce, cipher: RawByteString;
  mlen: cuint64;
begin
  if AHandle >= 0 then
    Exit(FMemory[AHandle]);
  if FFile = nil then
    raise ESpillStore.Create('invalid temporary store handle');
  FFile.Seek(-AHandle - 1, soBeginning);
  FFile.ReadBuffer(lenBuf, 4);
  n := lenBuf[0] or (lenBuf[1] shl 8) or (lenBuf[2] shl 16) or (lenBuf[3] shl 24);
  if (n < TAG_BYTES) or (n > SPILL_MAX_RECORD_BYTES + TAG_BYTES) then
    raise ESpillStore.Create('corrupted temporary store');
  SetLength(nonce, NONCE_BYTES);
  FFile.ReadBuffer(nonce[1], NONCE_BYTES);
  SetLength(cipher, n);
  FFile.ReadBuffer(cipher[1], n);
  SetLength(Result, n - TAG_BYTES);
  mlen := 0;
  if crypto_aead_xchacha20poly1305_ietf_decrypt(@Result[1], @mlen, nil, @cipher[1], n,
      nil, 0, @nonce[1], FKey.Data) <> 0 then
    raise ESpillStore.Create('temporary store authentication failed');
  SetLength(Result, mlen);
end;

procedure CleanOrphanSpillFiles(const ATempDir: string);
var
  sr: TSearchRec;
  dir: string;
begin
  dir := IncludeTrailingPathDelimiter(ATempDir);
  if FindFirst(dir + SPILL_PREFIX + '*.bin', faAnyFile, sr) = 0 then
  begin
    repeat
      // Un fichier encore ouvert par une execution vivante resiste a la suppression: on
      // ne ramasse que les cadavres.
      DeleteFile(dir + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

end.
