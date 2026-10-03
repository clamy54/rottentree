// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSavedSearch;

{$mode objfpc}{$H+}

// Recherches enregistrees et historique. Un DN ou un filtre en dit long sur un
// annuaire: ils ne vivent que dans le document chiffre, jamais dans les
// preferences. Le JSON est relu comme une entree hostile: bornes, filtre
// revalide, element illisible ecarte sans faire tomber la liste.

interface

uses
  SysUtils, Classes, uSearchModel;

const
  SAVED_SEARCH_VERSION = 1;
  SEARCH_HISTORY_MAX = 25;
  SAVED_SEARCH_NAME_MAX = 120;
  SAVED_SEARCH_MAX_BYTES = 512 * 1024;
  SAVED_SEARCH_ATTRS_MAX = 4096;
  SAVED_SEARCH_BASE_MAX = 4096;
  // Un document altere ne nous fera pas analyser des megaoctets de JSON.
  SEARCH_HISTORY_MAX_BYTES = 1024 * 1024;

type
  TSavedSearch = record
    Name: string;
    BaseDn: string;
    Scope: TSearchScope;
    Filter: string;
    Attributes: string;
    PageSize: Integer;
    SizeLimit: Integer;
    TimeLimitSec: Integer;
  end;
  TSavedSearches = array of TSavedSearch;

function SavedSearchProblem(const S: TSavedSearch): string;
function SavedSearchToJson(const S: TSavedSearch): string;
function SavedSearchFromJson(const AText: string; out S: TSavedSearch; out AError: string): Boolean;
function SearchHistoryToJson(const A: TSavedSearches): string;
function SearchHistoryFromJson(const AText: string): TSavedSearches;
function SameQuery(const A, B: TSavedSearch): Boolean;
procedure SearchHistoryPush(var A: TSavedSearches; const S: TSavedSearch;
  AMax: Integer = SEARCH_HISTORY_MAX);
// Ce qui est ecrit doit pouvoir etre relu: on sacrifie les plus anciennes
// plutot que toute la liste.
procedure TrimHistoryToBytes(var A: TSavedSearches; AMaxBytes: Integer);
function SavedSearchCaption(const S: TSavedSearch): string;

resourcestring
  rsSsNoName = 'a name is required';
  rsSsNameTooLong = 'the name is longer than %d characters';
  rsSsBadFilter = 'invalid filter: %s';
  rsSsAttrsTooLong = 'the attribute list is too long';
  rsSsBadBase = 'invalid base DN: %s';
  rsSsBaseTooLong = 'the base DN is longer than %d characters';
  rsSsUnreadable = 'unreadable saved search: %s';
  rsSsFutureVersion = 'saved search from a newer version (%d)';
  rsSsTooLarge = 'saved search larger than %d bytes';

implementation

uses
  fpjson, jsonparser, uJsonGuard, uLdapFilter, uLdapDn;

function FilterProblem(const AFilter: string): string;
var
  node: TFilterNode;
  err: string;
begin
  Result := '';
  node := FilterParse(AFilter, err);
  if node = nil then Exit(Format(rsSsBadFilter, [err]));
  node.Free;
end;

function SavedSearchProblem(const S: TSavedSearch): string;
var
  d: TLdapDn;
begin
  Result := '';
  if Trim(S.Name) = '' then Exit(rsSsNoName);
  if Length(S.Name) > SAVED_SEARCH_NAME_MAX then
    Exit(Format(rsSsNameTooLong, [SAVED_SEARCH_NAME_MAX]));
  if Length(S.Attributes) > SAVED_SEARCH_ATTRS_MAX then Exit(rsSsAttrsTooLong);
  // Base validee et bornee des l'enregistrement: rien n'est stocke qui serait
  // ensuite ecarte comme trop gros ou relance sur un DN faux.
  if Length(S.BaseDn) > SAVED_SEARCH_BASE_MAX then
    Exit(Format(rsSsBaseTooLong, [SAVED_SEARCH_BASE_MAX]));
  if (Trim(S.BaseDn) <> '') and not DnTryParse(S.BaseDn, d) then
    Exit(Format(rsSsBadBase, [S.BaseDn]));
  Result := FilterProblem(S.Filter);
end;

function ScopeText(AScope: TSearchScope): string;
begin
  case AScope of
    ssBase: Result := 'base';
    ssOneLevel: Result := 'one';
  else
    Result := 'sub';
  end;
end;

function TextScope(const S: string; out AScope: TSearchScope): Boolean;
begin
  Result := True;
  if S = 'base' then AScope := ssBase
  else if S = 'one' then AScope := ssOneLevel
  else if S = 'sub' then AScope := ssSubtree
  else Result := False;
end;

function ToObject(const S: TSavedSearch): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('version', SAVED_SEARCH_VERSION);
  Result.Add('name', S.Name);
  Result.Add('base', S.BaseDn);
  Result.Add('scope', ScopeText(S.Scope));
  Result.Add('filter', S.Filter);
  Result.Add('attributes', S.Attributes);
  Result.Add('pageSize', S.PageSize);
  Result.Add('sizeLimit', S.SizeLimit);
  Result.Add('timeLimit', S.TimeLimitSec);
end;

function Bounded(AObj: TJSONObject; const AKey: string; ADefault, AMax: Integer): Integer;
var
  d: TJSONData;
begin
  Result := ADefault;
  d := AObj.Find(AKey);
  if (d = nil) or not (d is TJSONIntegerNumber) then Exit;
  if (d.AsInt64 < 0) or (d.AsInt64 > AMax) then Exit;
  Result := d.AsInteger;
end;

function Str(AObj: TJSONObject; const AKey: string): string;
var
  d: TJSONData;
begin
  Result := '';
  d := AObj.Find(AKey);
  if (d <> nil) and (d is TJSONString) then Result := d.AsString;
end;

function FromObject(AObj: TJSONObject; out S: TSavedSearch; out AError: string): Boolean;
var
  d: TJSONData;
  v: Int64;
begin
  Result := False;
  S := Default(TSavedSearch);
  AError := '';
  d := AObj.Find('version');
  if (d = nil) or not (d is TJSONIntegerNumber) then
  begin
    AError := Format(rsSsUnreadable, ['version']);
    Exit;
  end;
  v := d.AsInt64;
  if v > SAVED_SEARCH_VERSION then
  begin
    AError := Format(rsSsFutureVersion, [v]);
    Exit;
  end;
  S.Name := Copy(Str(AObj, 'name'), 1, SAVED_SEARCH_NAME_MAX);
  S.BaseDn := Copy(Str(AObj, 'base'), 1, SAVED_SEARCH_BASE_MAX);
  if not TextScope(Str(AObj, 'scope'), S.Scope) then S.Scope := ssSubtree;
  S.Filter := Str(AObj, 'filter');
  S.Attributes := Copy(Str(AObj, 'attributes'), 1, SAVED_SEARCH_ATTRS_MAX);
  S.PageSize := Bounded(AObj, 'pageSize', 500, 100000);
  S.SizeLimit := Bounded(AObj, 'sizeLimit', 10000, MaxInt);
  S.TimeLimitSec := Bounded(AObj, 'timeLimit', 30, 86400);
  // Filtre relu comme une saisie: un fichier modifie a la main ne part pas au
  // serveur sans analyse.
  AError := FilterProblem(S.Filter);
  Result := AError = '';
end;

function SavedSearchToJson(const S: TSavedSearch): string;
var
  o: TJSONObject;
begin
  o := ToObject(S);
  try
    Result := o.AsJSON;
  finally
    o.Free;
  end;
end;

function ParseBounded(const AText: string; AMaxBytes: Integer; out AError: string): TJSONData;
begin
  Result := nil;
  AError := '';
  if Length(AText) > AMaxBytes then
  begin
    AError := Format(rsSsTooLarge, [AMaxBytes]);
    Exit;
  end;
  if JsonNestingTooDeep(AText, 8) then
  begin
    AError := Format(rsSsUnreadable, ['nesting']);
    Exit;
  end;
  try
    Result := GetJSON(AText);
  except
    on E: Exception do
    begin
      Result := nil;
      AError := Format(rsSsUnreadable, [E.Message]);
    end;
  end;
end;

function SavedSearchFromJson(const AText: string; out S: TSavedSearch; out AError: string): Boolean;
var
  d: TJSONData;
begin
  Result := False;
  S := Default(TSavedSearch);
  if Length(AText) > SAVED_SEARCH_MAX_BYTES then
  begin
    AError := Format(rsSsTooLarge, [SAVED_SEARCH_MAX_BYTES]);
    Exit;
  end;
  d := ParseBounded(AText, SAVED_SEARCH_MAX_BYTES, AError);
  if d = nil then Exit;
  try
    if not (d is TJSONObject) then
    begin
      AError := Format(rsSsUnreadable, ['not an object']);
      Exit;
    end;
    Result := FromObject(TJSONObject(d), S, AError);
  finally
    d.Free;
  end;
end;

function SearchHistoryToJson(const A: TSavedSearches): string;
var
  arr: TJSONArray;
  i: Integer;
begin
  arr := TJSONArray.Create;
  try
    for i := 0 to High(A) do
      arr.Add(ToObject(A[i]));
    Result := arr.AsJSON;
  finally
    arr.Free;
  end;
end;

function SearchHistoryFromJson(const AText: string): TSavedSearches;
var
  d: TJSONData;
  i: Integer;
  s: TSavedSearch;
  err: string;
begin
  Result := nil;
  if AText = '' then Exit;
  d := ParseBounded(AText, SEARCH_HISTORY_MAX_BYTES, err);
  if d = nil then Exit;
  try
    if not (d is TJSONArray) then Exit;
    for i := 0 to TJSONArray(d).Count - 1 do
    begin
      if Length(Result) >= SEARCH_HISTORY_MAX then Break;
      if not (TJSONArray(d).Items[i] is TJSONObject) then Continue;
      if FromObject(TJSONObject(TJSONArray(d).Items[i]), s, err) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := s;
      end;
    end;
  finally
    d.Free;
  end;
end;

function SameQuery(const A, B: TSavedSearch): Boolean;
begin
  Result := (A.BaseDn = B.BaseDn) and (A.Scope = B.Scope) and (A.Filter = B.Filter) and
    (A.Attributes = B.Attributes);
end;

procedure SearchHistoryPush(var A: TSavedSearches; const S: TSavedSearch; AMax: Integer);
var
  r: TSavedSearches;
  i: Integer;
begin
  r := nil;
  SetLength(r, 1);
  r[0] := S;
  for i := 0 to High(A) do
  begin
    if Length(r) >= AMax then Break;
    if SameQuery(A[i], S) then Continue;
    SetLength(r, Length(r) + 1);
    r[High(r)] := A[i];
  end;
  A := r;
end;

procedure TrimHistoryToBytes(var A: TSavedSearches; AMaxBytes: Integer);
begin
  while (Length(A) > 1) and (Length(SearchHistoryToJson(A)) > AMaxBytes) do
    SetLength(A, Length(A) - 1);
  if (Length(A) = 1) and (Length(SearchHistoryToJson(A)) > AMaxBytes) then
    A := nil;
end;

function Shorten(const S: string; AMax: Integer): string;
begin
  if Length(S) <= AMax then Exit(S);
  Result := Copy(S, 1, AMax - 3) + '...';
end;

function SavedSearchCaption(const S: TSavedSearch): string;
var
  base: string;
begin
  base := S.BaseDn;
  if base = '' then base := '(root)';
  Result := Shorten(S.Filter, 70) + '   [' + ScopeText(S.Scope) + ', ' + Shorten(base, 50) + ']';
  // La LCL prend une esperluette de menu pour un raccourci clavier. Un filtre
  // (&(...)) en contient toujours une.
  Result := StringReplace(Result, '&', '&&', [rfReplaceAll]);
end;

end.
