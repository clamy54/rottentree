// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uProfileCatalog;

{$mode objfpc}{$H+}

// Profils et dossiers du document ouvert, tels que les montrent le panneau lateral et l'onglet de
// comparaison. Copie de travail: le document reste la reference.

interface

uses
  SysUtils, Classes, Contnrs, uConnectionProfile, uRtDocument;

type
  TProfileCatalog = class
  private
    FProfiles: TObjectList;
    FFolderOf: TStringList;
    function GetItem(AIndex: Integer): TConnectionProfile;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure LoadFrom(ADoc: TRtDocument);
    function Count: Integer;
    function Find(const AUuid: string): TConnectionProfile;
    function FolderOf(const AUuid: string): string;
    property Items[AIndex: Integer]: TConnectionProfile read GetItem; default;
  end;

function ProfileMatches(AProfile: TConnectionProfile; const AFilter: string): Boolean;
// Un dossier orphelin ou pris dans un cycle n'est pas rendu. Le document refuse deja les cycles,
// mais on ne parie pas une boucle infinie sur un fichier.
function FoldersParentFirst(const AFolders: TDocFolders): TDocFolders;

procedure StoreProfile(ADoc: TRtDocument; AProfile: TConnectionProfile;
  const AFolderUuid: string; const ASecret: RawByteString; ARemember: Boolean);
// Avec AKeepSecret, le secret est copie dans sa propre ligne: supprimer l'original ne l'emporte
// pas.
function DuplicateProfile(ADoc: TRtDocument; const ASourceUuid: string;
  AKeepSecret: Boolean): string;

implementation

uses
  uSecureBytes, uDocumentCrypto;

const
  BIND_SECRET_KIND = 'bind-password';

procedure StoreProfile(ADoc: TRtDocument; AProfile: TConnectionProfile;
  const AFolderUuid: string; const ASecret: RawByteString; ARemember: Boolean);
var
  sec: TSecureBytes;
begin
  // La ligne du profil existe avant son secret: cle etrangere.
  ADoc.SaveProfile(AProfile, AFolderUuid);
  if ARemember and (ASecret <> '') then
  begin
    if AProfile.SecretRef <> '' then
      ADoc.DeleteSecret(AProfile.SecretRef);
    sec := TSecureBytes.CreateFrom(ASecret[1], Length(ASecret));
    try
      AProfile.SecretRef := ADoc.StoreSecret(AProfile.Uuid, BIND_SECRET_KIND, sec);
    finally
      sec.Free;
    end;
  end
  else if (not ARemember) and (AProfile.SecretRef <> '') then
  begin
    ADoc.DeleteSecret(AProfile.SecretRef);
    AProfile.SecretRef := '';
  end;
  ADoc.SaveProfile(AProfile, AFolderUuid);
end;

function DuplicateProfile(ADoc: TRtDocument; const ASourceUuid: string;
  AKeepSecret: Boolean): string;
var
  src, dup: TConnectionProfile;
  sec: TSecureBytes;
  folder: string;
begin
  Result := '';
  src := ADoc.LoadProfile(ASourceUuid);
  if src = nil then Exit;
  try
    // Exceptions TLS et epinglage remis au strict: une copie n'herite pas des derogations.
    dup := src.Duplicate(False, False);
    try
      dup.Uuid := NewUuidV4;
      dup.SecretRef := '';
      folder := ADoc.ProfileFolder(src.Uuid);
      ADoc.SaveProfile(dup, folder);
      if AKeepSecret and (src.SecretRef <> '') then
      begin
        sec := ADoc.LoadSecret(src.SecretRef);
        if sec <> nil then
        try
          dup.SecretRef := ADoc.StoreSecret(dup.Uuid, BIND_SECRET_KIND, sec);
          ADoc.SaveProfile(dup, folder);
        finally
          sec.Free;
        end;
      end;
      Result := dup.Uuid;
    finally
      dup.Free;
    end;
  finally
    src.Free;
  end;
end;

constructor TProfileCatalog.Create;
begin
  inherited Create;
  FProfiles := TObjectList.Create(True);
  FFolderOf := TStringList.Create;
end;

destructor TProfileCatalog.Destroy;
begin
  FProfiles.Free;
  FFolderOf.Free;
  inherited Destroy;
end;

procedure TProfileCatalog.Clear;
begin
  FProfiles.Clear;
  FFolderOf.Clear;
end;

procedure TProfileCatalog.LoadFrom(ADoc: TRtDocument);
var
  list: TObjectList;
  i: Integer;
  p: TConnectionProfile;
begin
  Clear;
  if ADoc = nil then Exit;
  list := ADoc.LoadProfiles;
  try
    list.OwnsObjects := False;
    for i := 0 to list.Count - 1 do
    begin
      p := TConnectionProfile(list[i]);
      FProfiles.Add(p);
      FFolderOf.Values[p.Uuid] := ADoc.ProfileFolder(p.Uuid);
    end;
  finally
    list.Free;
  end;
end;

function TProfileCatalog.Count: Integer;
begin
  Result := FProfiles.Count;
end;

function TProfileCatalog.GetItem(AIndex: Integer): TConnectionProfile;
begin
  Result := TConnectionProfile(FProfiles[AIndex]);
end;

function TProfileCatalog.Find(const AUuid: string): TConnectionProfile;
var
  i: Integer;
begin
  for i := 0 to FProfiles.Count - 1 do
    if GetItem(i).Uuid = AUuid then
      Exit(GetItem(i));
  Result := nil;
end;

function TProfileCatalog.FolderOf(const AUuid: string): string;
begin
  Result := FFolderOf.Values[AUuid];
end;

function ProfileMatches(AProfile: TConnectionProfile; const AFilter: string): Boolean;
var
  f: string;
begin
  f := LowerCase(Trim(AFilter));
  Result := (f = '') or
    (Pos(f, LowerCase(AProfile.Name + ' ' + AProfile.Host + ' ' + AProfile.Description)) > 0);
end;

function FoldersParentFirst(const AFolders: TDocFolders): TDocFolders;
var
  placed: TStringList;
  added: Boolean;
  i: Integer;
begin
  Result := nil;
  placed := TStringList.Create;
  try
    placed.Sorted := True;
    repeat
      added := False;
      for i := 0 to High(AFolders) do
      begin
        if placed.IndexOf(AFolders[i].Uuid) >= 0 then Continue;
        if (AFolders[i].ParentUuid <> '') and (placed.IndexOf(AFolders[i].ParentUuid) < 0) then
          Continue;
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := AFolders[i];
        placed.Add(AFolders[i].Uuid);
        added := True;
      end;
    until not added;
  finally
    placed.Free;
  end;
end;

end.
