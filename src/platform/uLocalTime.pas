// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLocalTime;

{$mode objfpc}{$H+}

// Heure locale d'une date UTC, avec le decalage en vigueur A CETTE DATE (heure d'ete
// comprise). Windows: SystemTimeToTzSpecificLocalTime. Ailleurs, sans base de fuseaux,
// le decalage est dit inconnu plutot que devine.

interface

uses
  SysUtils;

function UtcToLocalAt(AUtc: TDateTime; out ALocal: TDateTime; out AOffsetMinutes: Integer): Boolean;

implementation

{$IFDEF WINDOWS}
uses
  Windows;

function UtcToLocalAt(AUtc: TDateTime; out ALocal: TDateTime; out AOffsetMinutes: Integer): Boolean;
var
  st, lt: TSystemTime;
begin
  ALocal := 0;
  AOffsetMinutes := 0;
  Result := False;
  // SYSTEMTIME ne va que de 1601 a 30827.
  if (AUtc < EncodeDate(1601, 1, 1)) or (AUtc >= EncodeDate(9999, 12, 31)) then Exit;
  DateTimeToSystemTime(AUtc, st);
  if not SystemTimeToTzSpecificLocalTime(nil, @st, @lt) then Exit;
  ALocal := SystemTimeToDateTime(lt);
  AOffsetMinutes := Round((ALocal - AUtc) * 1440);
  Result := True;
end;
{$ELSE}
function UtcToLocalAt(AUtc: TDateTime; out ALocal: TDateTime; out AOffsetMinutes: Integer): Boolean;
begin
  ALocal := 0;
  AOffsetMinutes := 0;
  Result := False;
end;
{$ENDIF}

end.
