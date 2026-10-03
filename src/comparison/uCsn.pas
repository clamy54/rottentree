// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCsn;

{$mode objfpc}{$H+}

// contextCSN d'OpenLDAP ("YYYYmmddHHMMSS.uuuuuuZ#cccccc#sid#mmmmmm"), compare par SID.
// Un SID absent ou une valeur illisible est inconnu. Des vecteurs identiques sont un
// indice, pas un alibi pour sauter la comparaison du contenu.

interface

uses
  SysUtils;

type
  TCsn = record
    Valid: Boolean;
    Time: string;
    Count: Integer;
    Sid: Integer;
    Modifier: Integer;
    Raw: string;
  end;
  TCsnVector = array of TCsn;

  TSidState = (ssEqual, ssAhead, ssBehind, ssMissing, ssUnreadable);

  TSidComparison = record
    Sid: Integer;
    State: TSidState;
    A: string;
    B: string;
  end;
  TSidComparisons = array of TSidComparison;

function ParseCsn(const S: string): TCsn;
function ParseCsnVector(const AValues: array of string; out AUnreadable: Integer): TCsnVector;
function CompareCsn(const A, B: TCsn): Integer;
function CompareCsnVectors(const A, B: array of string): TSidComparisons;
function SidStateName(AState: TSidState): string;

implementation

function ParseCsn(const S: string): TCsn;
var
  parts: TStringArray;
  i: Integer;
begin
  Result := Default(TCsn);
  Result.Raw := S;
  parts := S.Split(['#']);
  if Length(parts) <> 4 then Exit;
  if (Length(parts[0]) <> 22) or (parts[0][15] <> '.') or (parts[0][22] <> 'Z') then Exit;
  for i := 1 to 21 do
    if (i <> 15) and not (parts[0][i] in ['0'..'9']) then Exit;
  if (Length(parts[1]) <> 6) or (Length(parts[2]) <> 3) or (Length(parts[3]) <> 6) then Exit;
  if not TryStrToInt('$' + parts[1], Result.Count) then Exit;
  if not TryStrToInt('$' + parts[2], Result.Sid) then Exit;
  if not TryStrToInt('$' + parts[3], Result.Modifier) then Exit;
  Result.Time := parts[0];
  Result.Valid := True;
end;

function ParseCsnVector(const AValues: array of string; out AUnreadable: Integer): TCsnVector;
var
  i: Integer;
  c: TCsn;
begin
  Result := nil;
  AUnreadable := 0;
  for i := 0 to High(AValues) do
  begin
    c := ParseCsn(AValues[i]);
    if not c.Valid then
    begin
      Inc(AUnreadable);
      Continue;
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := c;
  end;
end;

function CompareCsn(const A, B: TCsn): Integer;
begin
  if A.Time <> B.Time then
  begin
    if A.Time < B.Time then Exit(-1) else Exit(1);
  end;
  if A.Count <> B.Count then Exit(A.Count - B.Count);
  if A.Sid <> B.Sid then Exit(A.Sid - B.Sid);
  Result := A.Modifier - B.Modifier;
end;

function SidStateName(AState: TSidState): string;
begin
  case AState of
    ssEqual: Result := 'equal';
    ssAhead: Result := 'ahead';
    ssBehind: Result := 'behind';
    ssMissing: Result := 'SID missing (unknown)';
  else
    Result := 'unreadable (unknown)';
  end;
end;

function CompareCsnVectors(const A, B: array of string): TSidComparisons;
var
  va, vb: TCsnVector;
  ua, ub, i, j, c: Integer;
  found: Boolean;

  procedure Add(ASid: Integer; AState: TSidState; const SA, SB: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Sid := ASid;
    Result[High(Result)].State := AState;
    Result[High(Result)].A := SA;
    Result[High(Result)].B := SB;
  end;

begin
  Result := nil;
  va := ParseCsnVector(A, ua);
  vb := ParseCsnVector(B, ub);
  for i := 0 to High(va) do
  begin
    found := False;
    for j := 0 to High(vb) do
      if vb[j].Sid = va[i].Sid then
      begin
        found := True;
        c := CompareCsn(vb[j], va[i]);
        if c = 0 then Add(va[i].Sid, ssEqual, va[i].Raw, vb[j].Raw)
        else if c > 0 then Add(va[i].Sid, ssAhead, va[i].Raw, vb[j].Raw)
        else Add(va[i].Sid, ssBehind, va[i].Raw, vb[j].Raw);
        Break;
      end;
    if not found then
      Add(va[i].Sid, ssMissing, va[i].Raw, '');
  end;
  for j := 0 to High(vb) do
  begin
    found := False;
    for i := 0 to High(va) do
      if va[i].Sid = vb[j].Sid then found := True;
    if not found then
      Add(vb[j].Sid, ssMissing, '', vb[j].Raw);
  end;
  if ua + ub > 0 then
    Add(-1, ssUnreadable, '', '');
end;

end.
