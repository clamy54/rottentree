// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTemplateLibrary;

{$mode objfpc}{$H+}

// Modeles du document: communs a tous ses profils, le schema du serveur vise dit lesquels
// s'appliquent. Sans document, rien n'est garde. Un mot de passe fixe vit dans le document
// chiffre; l'export, lui, ne l'emporte que si on le lui demande.

interface

uses
  SysUtils, Classes, uRtDocument, uEntryTemplate;

const
  TEMPLATE_LIBRARY_MAX = 500;
  TEMPLATE_EXPORT_VERSION = 1;
  TEMPLATE_EXPORT_MAX_BYTES = 16 * 1024 * 1024;
  TEMPLATE_EXPORT_KIND = 'rottentree-entry-templates';

function LoadTemplates(ADoc: TRtDocument; out AUnreadable: Integer): TEntryTemplates;
function FindTemplate(ADoc: TRtDocument; const AUuid: string; out T: TEntryTemplate): Boolean;
function TemplateNameTaken(ADoc: TRtDocument; const AName, AExceptUuid: string): Boolean;
function UniqueTemplateName(ADoc: TRtDocument; const AName: string): string;
function StoreTemplate(ADoc: TRtDocument; var T: TEntryTemplate; out AError: string): Boolean;
function DeleteTemplate(ADoc: TRtDocument; const AUuid: string): Boolean;

function ExportTemplatesJson(const AList: array of TEntryTemplate): string;
// Decoupe en autant de fichiers qu'il faut pour que chacun se reimporte: l'import plafonne la
// taille, l'export n'ecrit pas ce qu'il ne saurait relire.
function ExportTemplatesParts(const AList: array of TEntryTemplate): TStringArray;
function ImportTemplatesJson(const AText: string; out AList: TEntryTemplates; out ABad: Integer;
  out AError: string): Boolean;

resourcestring
  rsTlNoDocument = 'no document is open: templates are kept in the document';
  rsTlTooMany = 'the document already holds %d templates';
  rsTlNameTaken = 'another template is already named "%s"';
  rsTlNotExport = 'this file is not a template export';
  rsTlNewer = 'template export version %d is newer than this version supports';
  rsTlTooLarge = 'the file is too large for a template export';
  rsTlInvalid = 'invalid JSON: %s';
  rsTlCopyName = '%s (%d)';
  rsTlReadsDifferently = 'it reads back with different values';

implementation

uses
  fpjson, jsonparser, uJsonGuard;

function LoadTemplates(ADoc: TRtDocument; out AUnreadable: Integer): TEntryTemplates;
var
  items: TDocItems;
  i: Integer;
  t: TEntryTemplate;
  err: string;
begin
  Result := nil;
  AUnreadable := 0;
  if ADoc = nil then Exit;
  items := ADoc.Items(dikTemplate);
  for i := 0 to High(items) do
    if TemplateFromJson(items[i].Body, t, err) then
    begin
      t.Uuid := items[i].Uuid;
      t.Name := items[i].Name;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := t;
    end
    else
      Inc(AUnreadable);
end;

function FindTemplate(ADoc: TRtDocument; const AUuid: string; out T: TEntryTemplate): Boolean;
var
  list: TEntryTemplates;
  bad, i: Integer;
begin
  T := NewTemplate;
  list := LoadTemplates(ADoc, bad);
  for i := 0 to High(list) do
    if list[i].Uuid = AUuid then
    begin
      T := list[i];
      Exit(True);
    end;
  Result := False;
end;

function TemplateNameTaken(ADoc: TRtDocument; const AName, AExceptUuid: string): Boolean;
var
  items: TDocItems;
  i: Integer;
begin
  Result := False;
  if ADoc = nil then Exit;
  items := ADoc.Items(dikTemplate);
  for i := 0 to High(items) do
    if (items[i].Uuid <> AExceptUuid) and SameText(Trim(items[i].Name), Trim(AName)) then
      Exit(True);
end;

function UniqueTemplateName(ADoc: TRtDocument; const AName: string): string;
var
  n: Integer;
begin
  Result := Trim(AName);
  n := 2;
  while TemplateNameTaken(ADoc, Result, '') and (n < 10000) do
  begin
    Result := Format(rsTlCopyName, [Copy(Trim(AName), 1, TEMPLATE_NAME_MAX - 8), n]);
    Inc(n);
  end;
end;

function StoreTemplate(ADoc: TRtDocument; var T: TEntryTemplate; out AError: string): Boolean;
var
  item: TDocItem;
  check: TEntryTemplate;
  err: string;
begin
  Result := False;
  AError := '';
  if ADoc = nil then
  begin
    AError := rsTlNoDocument;
    Exit;
  end;
  T.Name := Trim(T.Name);
  if T.Name = '' then
  begin
    AError := rsTplNoName;
    Exit;
  end;
  if Length(T.Name) > TEMPLATE_NAME_MAX then
  begin
    AError := Format(rsTplNameTooLong, [TEMPLATE_NAME_MAX]);
    Exit;
  end;
  if TemplateNameTaken(ADoc, T.Name, T.Uuid) then
  begin
    AError := Format(rsTlNameTaken, [T.Name]);
    Exit;
  end;
  if (T.Uuid = '') and (Length(ADoc.Items(dikTemplate)) >= TEMPLATE_LIBRARY_MAX) then
  begin
    AError := Format(rsTlTooMany, [TEMPLATE_LIBRARY_MAX]);
    Exit;
  end;
  item := Default(TDocItem);
  item.Uuid := T.Uuid;
  item.Name := T.Name;
  item.Version := TEMPLATE_VERSION;
  item.Body := TemplateToJson(T);
  // Un corps trop grand serait ecarte a la relecture: refuse des l'ecriture.
  if Length(item.Body) > TEMPLATE_MAX_BYTES then
  begin
    AError := Format(rsTplTooLarge, [TEMPLATE_MAX_BYTES]);
    Exit;
  end;
  // Relu avant d'etre ecrit, et a l'identique: un modele que le lecteur refuse ou rabote
  // disparaitrait de la liste a la prochaine ouverture. Ecrase, en plus, s'il existait deja.
  if not TemplateFromJson(item.Body, check, err) then
  begin
    AError := Format(rsTplNotReadable, [err]);
    Exit;
  end;
  if TemplateToJson(check) <> item.Body then
  begin
    AError := Format(rsTplNotReadable, [rsTlReadsDifferently]);
    Exit;
  end;
  T.Uuid := ADoc.PutItem(dikTemplate, item);
  Result := True;
end;

function DeleteTemplate(ADoc: TRtDocument; const AUuid: string): Boolean;
begin
  Result := (ADoc <> nil) and (AUuid <> '');
  if Result then ADoc.DeleteItem(dikTemplate, AUuid);
end;

function ExportTemplatesJson(const AList: array of TEntryTemplate): string;
var
  root: TJSONObject;
  arr: TJSONArray;
  i: Integer;
begin
  root := TJSONObject.Create;
  try
    root.Add('kind', TEMPLATE_EXPORT_KIND);
    root.Add('version', TEMPLATE_EXPORT_VERSION);
    arr := TJSONArray.Create;
    for i := 0 to High(AList) do
      arr.Add(GetJSON(TemplateToJson(AList[i])));
    root.Add('templates', arr);
    Result := root.FormatJSON;
  finally
    root.Free;
  end;
end;

function ExportTemplatesParts(const AList: array of TEntryTemplate): TStringArray;

  procedure Pack(AFrom, ATo: Integer);
  var
    part: string;
    mid, k: Integer;
    slice: TEntryTemplates;
  begin
    if AFrom > ATo then Exit;
    slice := nil;
    SetLength(slice, ATo - AFrom + 1);
    for k := AFrom to ATo do slice[k - AFrom] := AList[k];
    part := ExportTemplatesJson(slice);
    if (Length(part) <= TEMPLATE_EXPORT_MAX_BYTES) or (AFrom = ATo) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := part;
      Exit;
    end;
    mid := (AFrom + ATo) div 2;
    Pack(AFrom, mid);
    Pack(mid + 1, ATo);
  end;

begin
  Result := nil;
  Pack(0, High(AList));
end;

function ImportTemplatesJson(const AText: string; out AList: TEntryTemplates; out ABad: Integer;
  out AError: string): Boolean;
var
  data, d: TJSONData;
  root: TJSONObject;
  arr: TJSONArray;
  i: Integer;
  t: TEntryTemplate;
  err: string;
begin
  Result := False;
  AList := nil;
  ABad := 0;
  AError := '';
  if Length(AText) > TEMPLATE_EXPORT_MAX_BYTES then
  begin
    AError := rsTlTooLarge;
    Exit;
  end;
  data := nil;
  try
    try
      data := SafeGetJSON(AText, 10);
    except
      on E: Exception do
      begin
        AError := Format(rsTlInvalid, [E.Message]);
        Exit;
      end;
    end;
    if not (data is TJSONObject) then
    begin
      AError := rsTlNotExport;
      Exit;
    end;
    root := TJSONObject(data);
    d := root.Find('kind');
    if (d = nil) or not (d is TJSONString) or (d.AsString <> TEMPLATE_EXPORT_KIND) then
    begin
      AError := rsTlNotExport;
      Exit;
    end;
    d := root.Find('version');
    if (d = nil) or not (d is TJSONIntegerNumber) then
    begin
      AError := rsTlNotExport;
      Exit;
    end;
    if d.AsInt64 > TEMPLATE_EXPORT_VERSION then
    begin
      AError := Format(rsTlNewer, [d.AsInt64]);
      Exit;
    end;
    d := root.Find('templates');
    if (d = nil) or not (d is TJSONArray) then
    begin
      AError := rsTlNotExport;
      Exit;
    end;
    arr := TJSONArray(d);
    for i := 0 to arr.Count - 1 do
    begin
      // Au-dela de ce que le document peut tenir: comptes, pas oublies en silence.
      if Length(AList) >= TEMPLATE_LIBRARY_MAX then
      begin
        Inc(ABad, arr.Count - i);
        Break;
      end;
      if (arr[i] is TJSONObject) and TemplateFromJson(arr[i].AsJSON, t, err) and
         (Trim(t.Name) <> '') then
      begin
        SetLength(AList, Length(AList) + 1);
        AList[High(AList)] := t;
      end
      else
        Inc(ABad);
    end;
    Result := True;
  finally
    data.Free;
  end;
end;

end.
