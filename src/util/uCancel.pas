// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCancel;

{$mode objfpc}{$H+}

// Annulation cooperative et horloge monotone. Un jeton est partage entre la vue qui
// demande l'arret et le fil qui travaille; il ne tue rien, il demande poliment.

interface

uses
  SysUtils;

type
  TCancelToken = class
  private
    FCancelled: LongInt;
    FDeadlineMs: Int64;
  public
    procedure Cancel;
    function IsCancelled: Boolean;
    procedure SetTimeoutMs(AMs: Int64);
    function DeadlinePassed: Boolean;
    function RemainingMs: Int64;
  end;

function MonotonicMs: Int64;
function UtcNow: TDateTime;
function FormatUtcIso(ADate: TDateTime): string;

implementation

uses
  DateUtils{$IFDEF UNIX}, Unix, BaseUnix{$ENDIF}{$IFDEF WINDOWS}, Windows{$ENDIF};

{$IFDEF DARWIN}
// FPC 3.2 n'utilise pas clock_gettime sous Darwin: son GetTickCount64 suit
// gettimeofday, donc l'horloge murale, qui recule quand NTP s'en mele. CLOCK_MONOTONIC
// vaut 6 ici (time.h).
function clock_gettime_nsec_np(AClockId: cint): QWord; cdecl; external 'c';
{$ENDIF}

function MonotonicMs: Int64;
begin
  {$IFDEF DARWIN}
  Result := Int64(clock_gettime_nsec_np(6) div 1000000);
  {$ELSE}
  Result := Int64(GetTickCount64);
  {$ENDIF}
end;

function UtcNow: TDateTime;
begin
  Result := LocalTimeToUniversal(Now);
end;

function FormatUtcIso(ADate: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', ADate);
end;

procedure TCancelToken.Cancel;
begin
  InterLockedExchange(FCancelled, 1);
end;

function TCancelToken.IsCancelled: Boolean;
begin
  Result := InterLockedExchangeAdd(FCancelled, 0) <> 0;
end;

procedure TCancelToken.SetTimeoutMs(AMs: Int64);
begin
  if AMs <= 0 then
    FDeadlineMs := 0
  else
    FDeadlineMs := MonotonicMs + AMs;
end;

function TCancelToken.DeadlinePassed: Boolean;
begin
  Result := (FDeadlineMs <> 0) and (MonotonicMs >= FDeadlineMs);
end;

function TCancelToken.RemainingMs: Int64;
begin
  if FDeadlineMs = 0 then
    Result := High(Int64)
  else
  begin
    Result := FDeadlineMs - MonotonicMs;
    if Result < 0 then Result := 0;
  end;
end;

end.
