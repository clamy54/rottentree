// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSearchLibrary;

{$mode objfpc}{$H+}

// Recherches enregistrees et historique d'un profil, dans le document chiffre: un filtre en dit
// souvent long sur ce qu'on cherche. Sans document ouvert, rien n'est garde.

interface

uses
  SysUtils, Classes, uRtDocument, uSavedSearch;

const
  SAVED_SEARCH_MAX_PER_PROFILE = 500;
  SEARCH_HISTORY_ITEM_NAME = 'history';

type
  TSavedSearchItem = record
    Uuid: string;
    Search: TSavedSearch;
  end;
  TSavedSearchItems = array of TSavedSearchItem;

function LoadSavedSearches(ADoc: TRtDocument; const AProfileUuid: string;
  out AUnreadable: Integer): TSavedSearchItems;
function StoreSavedSearch(ADoc: TRtDocument; const AProfileUuid: string; const S: TSavedSearch;
  out AError: string): Boolean;
function DeleteSavedSearch(ADoc: TRtDocument; const AProfileUuid, AName: string): Boolean;
function FindSavedSearch(ADoc: TRtDocument; const AProfileUuid, AName: string;
  out S: TSavedSearch): Boolean;

function LoadSearchHistory(ADoc: TRtDocument; const AProfileUuid: string): TSavedSearches;
procedure RecordSearchHistory(ADoc: TRtDocument; const AProfileUuid: string; const S: TSavedSearch);
procedure ClearSearchHistory(ADoc: TRtDocument; const AProfileUuid: string);

resourcestring
  rsSlNoDocument = 'no document is open: saved searches are kept in the document';
  rsSlTooMany = 'this profile already has %d saved searches';

implementation

function LoadSavedSearches(ADoc: TRtDocument; const AProfileUuid: string;
  out AUnreadable: Integer): TSavedSearchItems;
var
  items: TDocItems;
  i: Integer;
  s: TSavedSearch;
  err: string;
begin
  Result := nil;
  AUnreadable := 0;
  if (ADoc = nil) or (AProfileUuid = '') then Exit;
  items := ADoc.Items(dikSavedSearch, AProfileUuid);
  for i := 0 to High(items) do
    if SavedSearchFromJson(items[i].Body, s, err) then
    begin
      s.Name := items[i].Name;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].Uuid := items[i].Uuid;
      Result[High(Result)].Search := s;
    end
    else
      Inc(AUnreadable);
end;

function FindItemUuid(ADoc: TRtDocument; const AProfileUuid, AName: string; out ACount: Integer): string;
var
  items: TDocItems;
  i: Integer;
begin
  Result := '';
  items := ADoc.Items(dikSavedSearch, AProfileUuid);
  ACount := Length(items);
  for i := 0 to High(items) do
    if SameText(Trim(items[i].Name), Trim(AName)) then Exit(items[i].Uuid);
end;

function StoreSavedSearch(ADoc: TRtDocument; const AProfileUuid: string; const S: TSavedSearch;
  out AError: string): Boolean;
var
  item: TDocItem;
  n: Integer;
  norm: TSavedSearch;
begin
  Result := False;
  if (ADoc = nil) or (AProfileUuid = '') then
  begin
    AError := rsSlNoDocument;
    Exit;
  end;
  norm := S;
  norm.Name := Trim(S.Name);
  AError := SavedSearchProblem(norm);
  if AError <> '' then Exit;
  item := Default(TDocItem);
  item.Uuid := FindItemUuid(ADoc, AProfileUuid, norm.Name, n);
  if (item.Uuid = '') and (n >= SAVED_SEARCH_MAX_PER_PROFILE) then
  begin
    AError := Format(rsSlTooMany, [n]);
    Exit;
  end;
  item.OwnerUuid := AProfileUuid;
  item.Name := norm.Name;
  item.Version := SAVED_SEARCH_VERSION;
  item.Body := SavedSearchToJson(norm);
  // Un corps trop grand serait ecarte a la relecture: refuse des l'ecriture.
  if Length(item.Body) > SAVED_SEARCH_MAX_BYTES then
  begin
    AError := Format(rsSsTooLarge, [SAVED_SEARCH_MAX_BYTES]);
    Exit;
  end;
  ADoc.PutItem(dikSavedSearch, item);
  Result := True;
end;

function DeleteSavedSearch(ADoc: TRtDocument; const AProfileUuid, AName: string): Boolean;
var
  uuid: string;
  n: Integer;
begin
  Result := False;
  if (ADoc = nil) or (AProfileUuid = '') then Exit;
  uuid := FindItemUuid(ADoc, AProfileUuid, AName, n);
  if uuid = '' then Exit;
  ADoc.DeleteItem(dikSavedSearch, uuid);
  Result := True;
end;

function FindSavedSearch(ADoc: TRtDocument; const AProfileUuid, AName: string;
  out S: TSavedSearch): Boolean;
var
  list: TSavedSearchItems;
  bad, i: Integer;
begin
  Result := False;
  S := Default(TSavedSearch);
  list := LoadSavedSearches(ADoc, AProfileUuid, bad);
  for i := 0 to High(list) do
    if SameText(Trim(list[i].Search.Name), Trim(AName)) then
    begin
      S := list[i].Search;
      Exit(True);
    end;
end;

function HistoryItem(ADoc: TRtDocument; const AProfileUuid: string; out AItem: TDocItem): Boolean;
var
  items: TDocItems;
begin
  AItem := Default(TDocItem);
  items := ADoc.Items(dikSearchHistory, AProfileUuid);
  Result := Length(items) > 0;
  if Result then AItem := items[0];
end;

function LoadSearchHistory(ADoc: TRtDocument; const AProfileUuid: string): TSavedSearches;
var
  item: TDocItem;
begin
  Result := nil;
  if (ADoc = nil) or (AProfileUuid = '') then Exit;
  if HistoryItem(ADoc, AProfileUuid, item) then
    Result := SearchHistoryFromJson(item.Body);
end;

procedure RecordSearchHistory(ADoc: TRtDocument; const AProfileUuid: string; const S: TSavedSearch);
var
  item: TDocItem;
  list: TSavedSearches;
  entry: TSavedSearch;
begin
  if (ADoc = nil) or (AProfileUuid = '') then Exit;
  entry := S;
  entry.Name := 'history';
  if SavedSearchProblem(entry) <> '' then Exit;
  entry.Name := '';
  list := nil;
  if HistoryItem(ADoc, AProfileUuid, item) then
    list := SearchHistoryFromJson(item.Body);
  if (Length(list) > 0) and SameQuery(list[0], entry) and (list[0].PageSize = entry.PageSize) and
     (list[0].SizeLimit = entry.SizeLimit) and (list[0].TimeLimitSec = entry.TimeLimitSec) then
    Exit;
  SearchHistoryPush(list, entry);
  // Le corps ecrit doit rester relisible sous la borne de lecture.
  TrimHistoryToBytes(list, SEARCH_HISTORY_MAX_BYTES);
  item.OwnerUuid := AProfileUuid;
  item.Name := SEARCH_HISTORY_ITEM_NAME;
  item.Version := SAVED_SEARCH_VERSION;
  item.Body := SearchHistoryToJson(list);
  ADoc.PutItem(dikSearchHistory, item);
end;

procedure ClearSearchHistory(ADoc: TRtDocument; const AProfileUuid: string);
var
  item: TDocItem;
begin
  if (ADoc = nil) or (AProfileUuid = '') then Exit;
  if HistoryItem(ADoc, AProfileUuid, item) then
    ADoc.DeleteItem(dikSearchHistory, item.Uuid);
end;

end.
