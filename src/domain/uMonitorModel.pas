// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uMonitorModel;

{$mode objfpc}{$H+}

// Supervision OpenLDAP (cn=Monitor), 389 DS (cn=monitor) et accords de replication 389.
// Un compteur illisible vaut "unavailable", jamais zero: zero erreur et aucune idee
// ne sont pas la meme nouvelle.

interface

uses
  SysUtils, Classes, uLdapEntry;

const
  MONITOR_REFRESH_SECONDS = 10;
  OPENLDAP_MONITOR_DEFAULT = 'cn=Monitor';
  DS389_MONITOR_DN = 'cn=monitor';
  DS389_AGREEMENTS_BASE = 'cn=mapping tree,cn=config';
  DS389_AGREEMENT_FILTER = '(objectClass=nsds5replicationAgreement)';

  DS389_MONITOR_ATTRS: array[0..14] of string = ('version', 'threads', 'currentconnections',
    'totalconnections', 'currentconnectionsatmaxthreads', 'maxthreadsperconnhits',
    'dtablesize', 'readwaiters', 'opsinitiated', 'opscompleted', 'entriessent', 'bytessent',
    'currenttime', 'starttime', 'nbackends');
  DS389_AGREEMENT_ATTRS: array[0..14] of string = ('cn', 'nsds5ReplicaHost', 'nsds5ReplicaPort',
    'nsds5ReplicaRoot', 'nsds5ReplicaEnabled', 'nsds5replicaUpdateInProgress',
    'nsds5replicaLastUpdateStart', 'nsds5replicaLastUpdateEnd', 'nsds5replicaLastUpdateStatus',
    'nsds5replicaLastUpdateStatusJSON', 'nsds5replicaChangesSentSinceStartup',
    'nsds5replicaLastInitStart', 'nsds5replicaLastInitEnd', 'nsds5replicaLastInitStatus',
    'nsds5replicaReapActive');

type
  TMonitorRow = record
    Section: string;
    Name: string;
    Value: string;
    Known: Boolean;
    Counter: Int64;
    IsCounter: Boolean;
  end;
  TMonitorRows = array of TMonitorRow;

  TAgreementHealth = (ahUnknown, ahGreen, ahAmber, ahRed);

  TReplAgreement = record
    Dn: string;
    Name: string;
    Target: string;
    Root: string;
    Enabled: string;
    InProgress: string;
    LastUpdateStart: string;
    LastUpdateEnd: string;
    LastUpdateStatus: string;
    Health: TAgreementHealth;
    ChangesSent: string;
    LastInitStatus: string;
  end;
  TReplAgreements = array of TReplAgreement;

resourcestring
  rsMonUnavailable = 'unavailable';
  rsMonSecServer = 'Server';
  rsMonSecConnections = 'Connections';
  rsMonSecOperations = 'Operations';
  rsMonSecStatistics = 'Statistics';
  rsMonSecWaiters = 'Waiters';
  rsMonSecDatabases = 'Databases';
  rsMonVersion = 'Version';
  rsMonStart = 'Start time';
  rsMonCurrent = 'Current time';
  rsMonUptime = 'Uptime';
  rsMonCurrentConn = 'Current';
  rsMonTotalConn = 'Total';
  rsMonMaxFd = 'Maximum file descriptors';
  rsMonInitiated = '%s initiated';
  rsMonCompleted = '%s completed';
  rsMonAllOps = 'All operations';
  rsMonOverlays = '%s overlays';
  rsMonNoOverlay = 'none';
  rsHealthGreen = 'healthy';
  rsHealthAmber = 'busy or retrying';
  rsHealthRed = 'error';
  rsHealthUnknown = 'unknown';

function OpenLdapMonitorBase(ARootDse: TLdapEntry): string;
function ParseOpenLdapMonitor(const ABase: string; AEntries: TList): TMonitorRows;
function Parse389Monitor(AEntry: TLdapEntry): TMonitorRows;
function ParseAgreement(AEntry: TLdapEntry): TReplAgreement;
function AgreementHealthText(AHealth: TAgreementHealth): string;
function CounterRate(const APrev, ACur: TMonitorRow; AElapsedSec: Double;
  out ARate: Double): Boolean;

implementation

uses
  fpjson, jsonparser, uLdapDn, uJsonGuard;

procedure AddRow(var R: TMonitorRows; const ASection, AName, AValue: string;
  AKnown, AIsCounter: Boolean);
var
  n: Integer;
begin
  n := Length(R);
  SetLength(R, n + 1);
  R[n].Section := ASection;
  R[n].Name := AName;
  R[n].Known := AKnown;
  R[n].IsCounter := AIsCounter;
  if AKnown then
  begin
    R[n].Value := AValue;
    R[n].Known := TryStrToInt64(Trim(AValue), R[n].Counter) or not AIsCounter;
    if not R[n].Known then R[n].Value := rsMonUnavailable;
  end
  else
    R[n].Value := rsMonUnavailable;
end;

function OpenLdapMonitorBase(ARootDse: TLdapEntry): string;
begin
  Result := '';
  if ARootDse <> nil then Result := Trim(ARootDse.FirstValue('monitorContext', ''));
  if Result = '' then Result := OPENLDAP_MONITOR_DEFAULT;
end;

function FindRelative(AEntries: TList; const ABase, ARelative: string): TLdapEntry;
var
  i: Integer;
  want: string;
  cmp: TDnComparer;
  a, b: TLdapDn;
begin
  Result := nil;
  if ARelative = '' then want := ABase else want := ARelative + ',' + ABase;
  if not DnTryParse(LowerCase(want), b) then Exit;
  cmp := TDnComparer.Create;
  try
    for i := 0 to AEntries.Count - 1 do
      if DnTryParse(LowerCase(TLdapEntry(AEntries[i]).Dn), a) and
         (DnStrictKey(cmp, a) = DnStrictKey(cmp, b)) then
        Exit(TLdapEntry(AEntries[i]));
  finally
    cmp.Free;
  end;
end;

procedure AddAttrRow(var R: TMonitorRows; AEntries: TList; const ABase, ARelative, AAttr,
  ASection, AName: string; AIsCounter: Boolean);
var
  e: TLdapEntry;
begin
  e := FindRelative(AEntries, ABase, ARelative);
  if (e <> nil) and (e.Find(AAttr) <> nil) then
    AddRow(R, ASection, AName, Trim(e.FirstValue(AAttr, '')), True, AIsCounter)
  else
    AddRow(R, ASection, AName, '', False, AIsCounter);
end;

function ParseOpenLdapMonitor(const ABase: string; AEntries: TList): TMonitorRows;
const
  OPS: array[0..9] of string = ('Bind', 'Unbind', 'Search', 'Compare', 'Modify', 'Modrdn',
    'Add', 'Delete', 'Abandon', 'Extended');
  STATS: array[0..3] of string = ('Bytes', 'PDU', 'Entries', 'Referrals');
var
  i, k: Integer;
  e: TLdapEntry;
  a: TLdapAttribute;
  d: TLdapDn;
  overlays, name: string;
begin
  Result := nil;
  AddAttrRow(Result, AEntries, ABase, '', 'monitoredInfo', rsMonSecServer, rsMonVersion, False);
  AddAttrRow(Result, AEntries, ABase, 'cn=Start,cn=Time', 'monitorTimestamp', rsMonSecServer,
    rsMonStart, False);
  AddAttrRow(Result, AEntries, ABase, 'cn=Current,cn=Time', 'monitorTimestamp', rsMonSecServer,
    rsMonCurrent, False);
  AddAttrRow(Result, AEntries, ABase, 'cn=Uptime,cn=Time', 'monitoredInfo', rsMonSecServer,
    rsMonUptime, False);
  AddAttrRow(Result, AEntries, ABase, 'cn=Current,cn=Connections', 'monitorCounter',
    rsMonSecConnections, rsMonCurrentConn, False);
  AddAttrRow(Result, AEntries, ABase, 'cn=Total,cn=Connections', 'monitorCounter',
    rsMonSecConnections, rsMonTotalConn, True);
  AddAttrRow(Result, AEntries, ABase, 'cn=Max File Descriptors,cn=Connections', 'monitorCounter',
    rsMonSecConnections, rsMonMaxFd, False);
  AddAttrRow(Result, AEntries, ABase, 'cn=Operations', 'monitorOpInitiated', rsMonSecOperations,
    Format(rsMonInitiated, [rsMonAllOps]), True);
  AddAttrRow(Result, AEntries, ABase, 'cn=Operations', 'monitorOpCompleted', rsMonSecOperations,
    Format(rsMonCompleted, [rsMonAllOps]), True);
  for i := 0 to High(OPS) do
    AddAttrRow(Result, AEntries, ABase, 'cn=' + OPS[i] + ',cn=Operations', 'monitorOpCompleted',
      rsMonSecOperations, Format(rsMonCompleted, [OPS[i]]), True);
  for i := 0 to High(STATS) do
    AddAttrRow(Result, AEntries, ABase, 'cn=' + STATS[i] + ',cn=Statistics', 'monitorCounter',
      rsMonSecStatistics, STATS[i], True);
  AddAttrRow(Result, AEntries, ABase, 'cn=Read,cn=Waiters', 'monitorCounter', rsMonSecWaiters,
    'Read', False);
  AddAttrRow(Result, AEntries, ABase, 'cn=Write,cn=Waiters', 'monitorCounter', rsMonSecWaiters,
    'Write', False);
  for i := 0 to AEntries.Count - 1 do
  begin
    e := TLdapEntry(AEntries[i]);
    if not DnTryParse(e.Dn, d) or (DnRdnCount(d) = 0) then Continue;
    name := RdnToString(DnLeaf(d));
    if (Pos('cn=database ', LowerCase(name)) <> 1) or
       (Pos(',cn=databases,', LowerCase(e.Dn)) = 0) then Continue;
    a := e.Find('monitorOverlay');
    overlays := '';
    if a <> nil then
      for k := 0 to a.ValueCount - 1 do
      begin
        if overlays <> '' then overlays := overlays + ', ';
        overlays := overlays + a.Values[k];
      end;
    if overlays = '' then overlays := rsMonNoOverlay;
    if e.Find('namingContexts') <> nil then
      name := name + ' (' + e.FirstValue('namingContexts', '') + ')';
    AddRow(Result, rsMonSecDatabases, Format(rsMonOverlays, [name]), overlays, True, False);
  end;
end;

function Parse389Monitor(AEntry: TLdapEntry): TMonitorRows;
const
  COUNTERS: array[0..7] of string = ('totalconnections', 'currentconnectionsatmaxthreads',
    'maxthreadsperconnhits', 'opsinitiated', 'opscompleted', 'entriessent', 'bytessent',
    'readwaiters');
var
  i, k: Integer;
  isCounter: Boolean;
  attr: string;
begin
  Result := nil;
  for i := 0 to High(DS389_MONITOR_ATTRS) do
  begin
    attr := DS389_MONITOR_ATTRS[i];
    isCounter := False;
    for k := 0 to High(COUNTERS) do
      if COUNTERS[k] = attr then isCounter := True;
    if (AEntry <> nil) and (AEntry.Find(attr) <> nil) then
      AddRow(Result, rsMonSecServer, attr, Trim(AEntry.FirstValue(attr, '')), True, isCounter)
    else
      AddRow(Result, rsMonSecServer, attr, '', False, isCounter);
  end;
end;

function HealthFromJson(const AText: string): TAgreementHealth;
var
  data: TJSONData;
  s: string;
begin
  Result := ahUnknown;
  if (AText = '') or (Length(AText) > 64 * 1024) or JsonNestingTooDeep(AText) then Exit;
  try
    data := GetJSON(AText);
  except
    Exit;
  end;
  try
    if (data is TJSONObject) and (TJSONObject(data).IndexOfName('state') >= 0) and
       (TJSONObject(data).Types['state'] = jtString) then
    begin
      s := LowerCase(TJSONObject(data).Strings['state']);
      if s = 'green' then Result := ahGreen
      else if s = 'amber' then Result := ahAmber
      else if s = 'red' then Result := ahRed;
    end;
  finally
    data.Free;
  end;
end;

function ParseAgreement(AEntry: TLdapEntry): TReplAgreement;
var
  port: string;
begin
  Result := Default(TReplAgreement);
  if AEntry = nil then Exit;
  Result.Dn := AEntry.Dn;
  Result.Name := AEntry.FirstValue('cn', '');
  Result.Target := AEntry.FirstValue('nsds5ReplicaHost', '');
  port := AEntry.FirstValue('nsds5ReplicaPort', '');
  if port <> '' then Result.Target := Result.Target + ':' + port;
  Result.Root := AEntry.FirstValue('nsds5ReplicaRoot', '');
  Result.Enabled := AEntry.FirstValue('nsds5ReplicaEnabled', '');
  Result.InProgress := AEntry.FirstValue('nsds5replicaUpdateInProgress', '');
  Result.LastUpdateStart := AEntry.FirstValue('nsds5replicaLastUpdateStart', '');
  Result.LastUpdateEnd := AEntry.FirstValue('nsds5replicaLastUpdateEnd', '');
  Result.LastUpdateStatus := AEntry.FirstValue('nsds5replicaLastUpdateStatus', '');
  Result.ChangesSent := AEntry.FirstValue('nsds5replicaChangesSentSinceStartup', '');
  Result.LastInitStatus := AEntry.FirstValue('nsds5replicaLastInitStatus', '');
  Result.Health := HealthFromJson(AEntry.FirstValue('nsds5replicaLastUpdateStatusJSON', ''));
end;

function AgreementHealthText(AHealth: TAgreementHealth): string;
begin
  case AHealth of
    ahGreen: Result := rsHealthGreen;
    ahAmber: Result := rsHealthAmber;
    ahRed: Result := rsHealthRed;
  else
    Result := rsHealthUnknown;
  end;
end;

function CounterRate(const APrev, ACur: TMonitorRow; AElapsedSec: Double;
  out ARate: Double): Boolean;
begin
  ARate := 0;
  // Compteur qui recule = serveur redemarre. Un debit negatif, c'est joli sur un
  // graphique et faux partout ailleurs.
  Result := APrev.Known and ACur.Known and ACur.IsCounter and (AElapsedSec > 0) and
    (ACur.Counter >= APrev.Counter);
  if Result then ARate := (ACur.Counter - APrev.Counter) / AElapsedSec;
end;

end.
