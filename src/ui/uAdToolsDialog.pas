// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAdToolsDialog;

{$mode objfpc}{$H+}

// Outils Active Directory: tableau du domaine et metadonnees de replication d'une entree.
// Versions et USN sont propres au controleur interroge: un diagnostic, pas un verdict.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, uAppContext;

procedure ShowAdDomainOverview(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string);
procedure ShowAdReplicationMetadata(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, ADn: string);

implementation

uses
  uUiKit, uOpsDialog, uTaskDialog, uRtList, uConnections, uDirectoryWorker, uLdapEntry, uSearchModel,
  uAdInfo, uStrings, uLdapErrors, uDirectoryService;

resourcestring
  rsAdDomainTitle = 'Active Directory domain';
  rsAdReplTitle = 'Replication metadata';
  rsAdColSection = 'Section';
  rsAdColProperty = 'Property';
  rsAdColValue = 'Value';
  rsAdSecServer = 'Domain controller';
  rsAdSecDomain = 'Default domain policy';
  rsAdSecPso = 'Fine-grained policy %s';
  rsAdNoPso = 'No password settings object is readable in %s.';
  rsAdPsoUnreadable = 'Password settings container not readable: %s';
  rsAdDomainUnreadable = 'Domain head not readable: %s';
  rsAdReading = 'Reading...';
  rsAdNoDomain = 'The root DSE does not announce defaultNamingContext.';
  rsAdReplNote = 'Diagnostic view: versions, USNs and originating DSA are local to the domain ' +
    'controller that answered. They are not comparable counters between controllers and are not ' +
    'a comparison verdict.';
  rsAdReplEmpty = 'msDS-ReplAttributeMetaData was not returned (constructed attribute: not ' +
    'available, or hidden by access control).';
  rsAdColAttribute = 'Attribute';
  rsAdColVersion = 'Version';
  rsAdColChanged = 'Last originating change (UTC)';
  rsAdColDsa = 'Originating DSA';
  rsAdColOrigUsn = 'Originating USN';
  rsAdColLocalUsn = 'Local USN';
  rsAdMinLength = 'Minimum length';
  rsAdHistory = 'History length';
  rsAdMinAge = 'Minimum age';
  rsAdMaxAge = 'Maximum age';
  rsAdComplexity = 'Complexity required';
  rsAdReversible = 'Reversible encryption';
  rsAdThreshold = 'Lockout threshold';
  rsAdDuration = 'Lockout duration';
  rsAdWindow = 'Observation window';
  rsAdPrecedence = 'Precedence';
  rsAdAppliesTo = 'Applies to';

type
  TAdDomainDialog = class(TOpsDialog)
  private
    FList: TRtListGrid;
    FDomain: string;
    FPsos: TList;
    procedure AddPolicy(const ASection: string; const P: TPasswordPolicyView);
  protected
    procedure OnEntry(AMsg: TEntryMsg); override;
    procedure OnEntries(AMsg: TEntriesMsg); override;
  public
    constructor CreateDomain(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string);
    destructor Destroy; override;
  end;

  TAdReplDialog = class(TOpsDialog)
  private
    FList: TRtListGrid;
  protected
    procedure OnEntry(AMsg: TEntryMsg); override;
  public
    constructor CreateRepl(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);
  end;

procedure ShowAdDomainOverview(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string);
var
  d: TAdDomainDialog;
begin
  d := TAdDomainDialog.CreateDomain(AOwner, ACtx, AProfileUuid);
  try
    d.ShowModal;
  finally
    d.Free;
  end;
end;

procedure ShowAdReplicationMetadata(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, ADn: string);
var
  d: TAdReplDialog;
begin
  d := TAdReplDialog.CreateRepl(AOwner, ACtx, AProfileUuid, ADn);
  try
    d.ShowModal;
  finally
    d.Free;
  end;
end;

constructor TAdDomainDialog.CreateDomain(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid: string);
var
  c: TDirectoryConnection;
  dse: TLdapEntry;

  procedure DseRow(const AAttr: string; ALevel: Boolean);
  var
    v: string;
  begin
    if (dse = nil) or (dse.Find(AAttr) = nil) then Exit;
    v := dse.FirstValue(AAttr, '');
    if ALevel then v := AdFunctionalLevelName(v) + ' (' + v + ')';
    FList.AddRow([rsAdSecServer, AAttr, v]);
  end;

begin
  inherited CreateFor(AOwner, ACtx, AProfileUuid, rsAdDomainTitle, 900, 680);
  SetIcon('building');
  FPsos := TList.Create;
  FList := TRtListGrid.Create(Body);
  FList.Parent := Body;
  FList.Align := alClient;
  FList.FillWidth := True;
  FList.AddColumn(rsAdColSection, 220);
  FList.AddColumn(rsAdColProperty, 220);
  FList.AddColumn(rsAdColValue, 400);
  AddButton(rsClose, mrClose, True, True);
  ApplyTheme;
  c := Conn;
  if c = nil then
  begin
    SetStatus(rsTdNotConnected, usError);
    Exit;
  end;
  dse := c.RootDse;
  DseRow('dnsHostName', False);
  DseRow('serverName', False);
  DseRow('domainFunctionality', True);
  DseRow('forestFunctionality', True);
  DseRow('domainControllerFunctionality', True);
  DseRow('isGlobalCatalogReady', False);
  DseRow('isSynchronized', False);
  FDomain := DomainNamingContext(c);
  if FDomain = '' then
  begin
    SetStatus(rsAdNoDomain, usWarning);
    Exit;
  end;
  SetStatus(rsAdReading);
  ReadEntry(FDomain, AD_DOMAIN_POLICY_ATTRS, 'domain');
end;

destructor TAdDomainDialog.Destroy;
var
  i: Integer;
begin
  for i := 0 to FPsos.Count - 1 do
    TLdapEntry(FPsos[i]).Free;
  FPsos.Free;
  inherited Destroy;
end;

procedure TAdDomainDialog.AddPolicy(const ASection: string; const P: TPasswordPolicyView);

  procedure Row(const AName, AValue: string);
  begin
    if AValue <> '' then FList.AddRow([ASection, AName, AValue]);
  end;

var
  i: Integer;
begin
  Row(rsAdPrecedence, P.Precedence);
  Row(rsAdMinLength, P.MinLength);
  Row(rsAdHistory, P.HistoryLength);
  Row(rsAdMinAge, P.MinAge);
  Row(rsAdMaxAge, P.MaxAge);
  Row(rsAdComplexity, P.Complexity);
  Row(rsAdReversible, P.ReversibleEncryption);
  Row(rsAdThreshold, P.LockoutThreshold);
  Row(rsAdDuration, P.LockoutDuration);
  Row(rsAdWindow, P.ObservationWindow);
  for i := 0 to High(P.AppliesTo) do
    Row(rsAdAppliesTo, P.AppliesTo[i]);
end;

procedure TAdDomainDialog.OnEntry(AMsg: TEntryMsg);
var
  req: TSearchRequest;
  i: Integer;
begin
  if Tasks.Current.Tag <> 'domain' then Exit;
  if AMsg.Entry = nil then
    FList.AddRow([rsAdSecDomain, '', Format(rsAdDomainUnreadable, [ErrorToText(AMsg.Error)])])
  else
    AddPolicy(rsAdSecDomain, ReadDomainPolicy(AMsg.Entry));
  req := DefaultSearchRequest;
  req.BaseDn := 'CN=Password Settings Container,CN=System,' + FDomain;
  req.Scope := ssOneLevel;
  req.Filter := '(objectClass=msDS-PasswordSettings)';
  SetLength(req.Attributes, Length(AD_PSO_ATTRS));
  for i := 0 to High(AD_PSO_ATTRS) do
    req.Attributes[i] := AD_PSO_ATTRS[i];
  req.SizeLimit := 500;
  Search(req, 'pso');
end;

procedure TAdDomainDialog.OnEntries(AMsg: TEntriesMsg);
var
  i: Integer;
  e: TLdapEntry;
begin
  if Tasks.Current.Tag <> 'pso' then Exit;
  while AMsg.Entries.Count > 0 do
  begin
    e := TLdapEntry(AMsg.Entries.Extract(AMsg.Entries[0]));
    FPsos.Add(e);
  end;
  if not AMsg.Final then Exit;
  if SearchOutcome(AMsg.Completion) <> soComplete then
    FList.AddRow([rsAdSecPso, '', Format(rsAdPsoUnreadable, [ResultCodeName(AMsg.Completion.ResultCode)])]);
  if FPsos.Count = 0 then
    FList.AddRow([Format(rsAdSecPso, ['']), '', Format(rsAdNoPso,
      ['CN=Password Settings Container,CN=System,' + FDomain])]);
  for i := 0 to FPsos.Count - 1 do
  begin
    e := TLdapEntry(FPsos[i]);
    AddPolicy(Format(rsAdSecPso, [e.FirstValue('cn', e.Dn)]), ReadPso(e));
  end;
  SetStatus('');
end;

constructor TAdReplDialog.CreateRepl(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, ADn: string);
begin
  inherited CreateFor(AOwner, ACtx, AProfileUuid, rsAdReplTitle + ' - ' + ADn, 1000, 620);
  SetIcon('hierarchy-2');
  MakeLabel(Body, rsAdReplNote).WordWrap := True;
  FList := TRtListGrid.Create(Body);
  FList.Parent := Body;
  FList.Align := alClient;
  FList.FillWidth := True;
  FList.AddColumn(rsAdColAttribute, 200);
  FList.AddColumn(rsAdColVersion, 70);
  FList.AddColumn(rsAdColChanged, 180);
  FList.AddColumn(rsAdColDsa, 330);
  FList.AddColumn(rsAdColOrigUsn, 100);
  FList.AddColumn(rsAdColLocalUsn, 100);
  AddButton(rsClose, mrClose, True, True);
  ApplyTheme;
  SetStatus(rsAdReading);
  // Attribut construit: Active Directory ne le rend que demande nommement,
  // et en lecture de base. Sinon, silence radio.
  ReadEntry(ADn, [AD_REPL_METADATA_ATTR], 'repl');
end;

procedure TAdReplDialog.OnEntry(AMsg: TEntryMsg);
var
  m: TReplAttrMetaArray;
  i: Integer;
begin
  if Tasks.Current.Tag <> 'repl' then Exit;
  if AMsg.Entry = nil then
  begin
    SetStatus(ErrorToText(AMsg.Error), usError);
    Exit;
  end;
  m := ParseReplMetadata(AMsg.Entry.Find(AD_REPL_METADATA_ATTR));
  if Length(m) = 0 then
  begin
    SetStatus(rsAdReplEmpty, usWarning);
    Exit;
  end;
  for i := 0 to High(m) do
    FList.AddRow([m[i].Attribute, m[i].Version, m[i].LastOriginatingChange,
      m[i].OriginatingDsaDn, m[i].OriginatingUsn, m[i].LocalUsn]);
  SetStatus('');
end;

end.
