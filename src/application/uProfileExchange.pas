// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uProfileExchange;

{$mode objfpc}{$H+}

// Echange de profils entre documents ou postes, en JSON versionne. Aucun secret ni reference de
// secret: ils ne voyagent que dans un document chiffre. A l'import, chaque profil repart d'un etat
// sur: TLS strict, lecture seule, nouvel UUID en cas de conflit.

interface

uses
  SysUtils, Classes, Contnrs, fpjson, uConnectionProfile, uProfileJson;

const
  PORTABLE_EXPORT_MAX_BYTES = 8 * 1024 * 1024;
  PORTABLE_EXPORT_MAX_PROFILES = 5000;

type
  TImportConflict = (icNone, icSameUuid, icSameName);

  TProfileImport = class
  private
    FItems: TObjectList;
    FConflicts: array of TImportConflict;
    FSelected: array of Boolean;
    FSkipped: TStringList;
    function GetItem(AIndex: Integer): TConnectionProfile;
    function GetConflict(AIndex: Integer): TImportConflict;
    function GetSelected(AIndex: Integer): Boolean;
    procedure SetSelected(AIndex: Integer; AValue: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    function Parse(const AText: string; const AExisting: array of TConnectionProfile;
      out AError: string): Boolean;
    function TakeSelected: TObjectList;
    function Count: Integer;
    property Items[AIndex: Integer]: TConnectionProfile read GetItem; default;
    property Conflicts[AIndex: Integer]: TImportConflict read GetConflict;
    property Selected[AIndex: Integer]: Boolean read GetSelected write SetSelected;
    property Skipped: TStringList read FSkipped;
  end;

resourcestring
  rsExchNotExport = 'this file is not a Rottentree profile export';
  rsExchNewer = 'profile export version %d is newer than this version supports';
  rsExchTooLarge = 'the file is too large for a profile export';
  rsExchTooMany = 'too many profiles in the file (maximum %d)';
  rsExchInvalid = 'invalid JSON: %s';
  rsExchConflictUuid = 'already present (a copy will be created)';
  rsExchConflictName = 'a profile with this name exists';
  rsExchNoConflict = 'new';

function ExportProfilesJson(const AProfiles: array of TConnectionProfile): string;
function ImportConflictText(AConflict: TImportConflict): string;

implementation

uses
  jsonparser, uJsonGuard, uDocumentCrypto, uCancel, uVersion;

function ExportProfilesJson(const AProfiles: array of TConnectionProfile): string;
var
  root: TJSONObject;
  list: TJSONArray;
  i: Integer;
begin
  root := TJSONObject.Create;
  try
    root.Add('format', PORTABLE_EXPORT_FORMAT);
    root.Add('version', PORTABLE_EXPORT_VERSION);
    root.Add('generator', RT_APP_NAME + ' ' + RT_VERSION);
    root.Add('exported', FormatUtcIso(UtcNow));
    list := TJSONArray.Create;
    root.Add('profiles', list);
    for i := 0 to High(AProfiles) do
      list.Add(ProfileToJson(AProfiles[i], False));
    Result := root.FormatJSON;
  finally
    root.Free;
  end;
end;

function ImportConflictText(AConflict: TImportConflict): string;
begin
  case AConflict of
    icSameUuid: Result := rsExchConflictUuid;
    icSameName: Result := rsExchConflictName;
  else
    Result := rsExchNoConflict;
  end;
end;

constructor TProfileImport.Create;
begin
  inherited Create;
  FItems := TObjectList.Create(True);
  FSkipped := TStringList.Create;
end;

destructor TProfileImport.Destroy;
begin
  FItems.Free;
  FSkipped.Free;
  inherited Destroy;
end;

function TProfileImport.Count: Integer;
begin
  Result := FItems.Count;
end;

function TProfileImport.GetItem(AIndex: Integer): TConnectionProfile;
begin
  Result := TConnectionProfile(FItems[AIndex]);
end;

function TProfileImport.GetConflict(AIndex: Integer): TImportConflict;
begin
  Result := FConflicts[AIndex];
end;

function TProfileImport.GetSelected(AIndex: Integer): Boolean;
begin
  Result := FSelected[AIndex];
end;

procedure TProfileImport.SetSelected(AIndex: Integer; AValue: Boolean);
begin
  FSelected[AIndex] := AValue;
end;

function TProfileImport.Parse(const AText: string;
  const AExisting: array of TConnectionProfile; out AError: string): Boolean;
var
  data: TJSONData;
  root: TJSONObject;
  list: TJSONArray;
  i, j, n: Integer;
  p: TConnectionProfile;
  conflict: TImportConflict;
begin
  Result := False;
  AError := '';
  FItems.Clear;
  FConflicts := nil;
  FSelected := nil;
  FSkipped.Clear;
  if Length(AText) > PORTABLE_EXPORT_MAX_BYTES then
  begin
    AError := rsExchTooLarge;
    Exit;
  end;
  if JsonNestingTooDeep(AText) then
  begin
    AError := rsExchNotExport;
    Exit;
  end;
  try
    data := GetJSON(AText);
  except
    on E: Exception do
    begin
      AError := Format(rsExchInvalid, [E.Message]);
      Exit;
    end;
  end;
  try
    if not (data is TJSONObject) then
    begin
      AError := rsExchNotExport;
      Exit;
    end;
    root := TJSONObject(data);
    if (root.IndexOfName('format') < 0) or (root.Types['format'] <> jtString) or
       (root.Strings['format'] <> PORTABLE_EXPORT_FORMAT) or
       (root.IndexOfName('profiles') < 0) or (root.Types['profiles'] <> jtArray) then
    begin
      AError := rsExchNotExport;
      Exit;
    end;
    if (root.IndexOfName('version') >= 0) and (root.Types['version'] = jtNumber) and
       (root.Integers['version'] > PORTABLE_EXPORT_VERSION) then
    begin
      AError := Format(rsExchNewer, [root.Integers['version']]);
      Exit;
    end;
    list := root.Arrays['profiles'];
    if list.Count > PORTABLE_EXPORT_MAX_PROFILES then
    begin
      AError := Format(rsExchTooMany, [PORTABLE_EXPORT_MAX_PROFILES]);
      Exit;
    end;
    for i := 0 to list.Count - 1 do
    begin
      if not (list.Items[i] is TJSONObject) then
      begin
        FSkipped.Add(IntToStr(i + 1) + ': ' + rsExchNotExport);
        Continue;
      end;
      try
        p := ProfileFromJson(TJSONObject(list.Items[i]));
      except
        on E: Exception do
        begin
          FSkipped.Add(IntToStr(i + 1) + ': ' + E.Message);
          Continue;
        end;
      end;
      conflict := icNone;
      for j := 0 to High(AExisting) do
        if (p.Uuid <> '') and SameText(AExisting[j].Uuid, p.Uuid) then
        begin
          conflict := icSameUuid;
          Break;
        end
        else if (conflict = icNone) and SameText(AExisting[j].Name, p.Name) then
          conflict := icSameName;
      for j := 0 to FItems.Count - 1 do
        if (p.Uuid <> '') and SameText(TConnectionProfile(FItems[j]).Uuid, p.Uuid) then
          conflict := icSameUuid;
      FItems.Add(p);
      n := FItems.Count;
      SetLength(FConflicts, n);
      SetLength(FSelected, n);
      FConflicts[n - 1] := conflict;
      FSelected[n - 1] := True;
    end;
    Result := True;
  finally
    data.Free;
  end;
end;

function TProfileImport.TakeSelected: TObjectList;
var
  i: Integer;
  p, q: TConnectionProfile;
begin
  Result := TObjectList.Create(True);
  for i := 0 to FItems.Count - 1 do
  begin
    if not FSelected[i] then Continue;
    p := TConnectionProfile(FItems[i]);
    // Duplicate retire secret et exceptions TLS; le nom d'origine reste.
    q := p.Duplicate(False, False);
    q.Name := p.Name;
    if (p.Uuid = '') or (FConflicts[i] = icSameUuid) then
      q.Uuid := NewUuidV4
    else
      q.Uuid := p.Uuid;
    q.FolderUuid := '';
    q.ReadOnly := True;
    Result.Add(q);
  end;
end;

end.
