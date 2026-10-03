// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAccountDialog;

{$mode objfpc}{$H+}

// Etat d'un compte et actions possibles, selon le type de serveur. Sous Active Directory, politique de
// mot de passe effective (PSO ou domaine). Tout passe par l'apercu, et l'etat est relu apres chaque ecriture.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, uAppContext;

procedure ShowAccountDialog(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);

implementation

uses
  uUiKit, uOpsDialog, uRtList, uConnections, uDirectoryWorker, uLdapEntry, uChangeSet,
  uAccountState, uAdInfo, uServerKind, uConnectionProfile, uCancel, uStrings, uLdapErrors,
  uDirectoryService;

resourcestring
  rsAccTitle = 'Account';
  rsAccReload = 'Reload';
  rsAccColProperty = 'Property';
  rsAccColValue = 'Value';
  rsAccAdapter = 'Adapter';
  rsAccDisabled = 'Disabled by an administrator';
  rsAccLocked = 'Locked out after failed attempts';
  rsAccLockDetail = 'Lock detail';
  rsAccExpires = 'Account expires';
  rsAccExpired = 'Account expired';
  rsAccPwdExpired = 'Password expired';
  rsAccMustChange = 'Password change required';
  rsAccNeverExpires = 'Password never expires';
  rsAccNotes = 'Notes';
  rsAccEnable = 'Enable';
  rsAccDisable = 'Disable';
  rsAccUnlock = 'Unlock';
  rsAccMustChangeBtn = 'Require change at next logon';
  rsAccClearMustChange = 'Clear change requirement';
  rsAccNeverExpiresBtn = 'Password never expires';
  rsAccExpiresBtn = 'Password expires normally';
  rsAccPolicyTitle = 'Resultant password policy';
  rsAccPolicyFromPso = 'Fine-grained policy (PSO) %s';
  rsAccPolicyFromDomain = 'Domain policy %s (no PSO applies, or msDS-ResultantPSO is not readable)';
  rsAccPolMinLength = 'Minimum length';
  rsAccPolHistory = 'History length';
  rsAccPolMinAge = 'Minimum age';
  rsAccPolMaxAge = 'Maximum age';
  rsAccPolComplexity = 'Complexity required';
  rsAccPolReversible = 'Reversible encryption';
  rsAccPolThreshold = 'Lockout threshold';
  rsAccPolDuration = 'Lockout duration';
  rsAccPolWindow = 'Observation window';
  rsAccPolPrecedence = 'Precedence';
  rsAccReading = 'Reading the account...';
  rsAccUnreadable = 'The entry could not be read: %s';

type
  TAccountDialog = class(TOpsDialog)
  private
    FDn: string;
    FAdapter: TAccountAdapter;
    FEntry: TLdapEntry;
    FList: TRtListGrid;
    FPolicyTitle: TLabel;
    FPolicy: TRtListGrid;
    FActions: array[TAccountAction] of TButton;
    FAvailable: TAccountActions;
    procedure BuildUi;
    procedure Reload;
    procedure ShowStatus;
    procedure ShowPolicy(AEntry: TLdapEntry);
    procedure ActionClick(Sender: TObject);
    procedure ReloadClick(Sender: TObject);
  protected
    procedure OnEntry(AMsg: TEntryMsg); override;
    procedure OnWrite(AMsg: TWriteMsg); override;
    procedure UpdateActions; override;
  public
    constructor CreateAccount(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);
    destructor Destroy; override;
  end;

procedure ShowAccountDialog(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid, ADn: string);
var
  d: TAccountDialog;
begin
  d := TAccountDialog.CreateAccount(AOwner, ACtx, AProfileUuid, ADn);
  try
    d.ShowModal;
  finally
    d.Free;
  end;
end;

function ActionCaption(A: TAccountAction): string;
begin
  case A of
    aaEnable: Result := rsAccEnable;
    aaDisable: Result := rsAccDisable;
    aaUnlock: Result := rsAccUnlock;
    aaMustChange: Result := rsAccMustChangeBtn;
    aaClearMustChange: Result := rsAccClearMustChange;
    aaPasswordNeverExpires: Result := rsAccNeverExpiresBtn;
  else
    Result := rsAccExpiresBtn;
  end;
end;

constructor TAccountDialog.CreateAccount(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, ADn: string);
var
  c: TDirectoryConnection;
begin
  inherited CreateFor(AOwner, ACtx, AProfileUuid, rsAccTitle + ' - ' + ADn, 820, 640);
  SetIcon('user');
  FDn := ADn;
  c := Conn;
  FAdapter := adNone;
  if c <> nil then
    FAdapter := SelectAccountAdapter(EffectiveServerKind(c.Profile, c.RootDse),
      DetectServerKind(c.RootDse).AdLds, c.RootDse);
  BuildUi;
  ApplyTheme;
  Reload;
end;

destructor TAccountDialog.Destroy;
begin
  FEntry.Free;
  inherited Destroy;
end;

procedure TAccountDialog.BuildUi;
var
  bar: TFlowPanel;
  a: TAccountAction;
  b: TButton;
begin
  bar := TFlowPanel.Create(Body);
  bar.Parent := Body;
  bar.Align := alTop;
  bar.AutoSize := True;
  bar.BevelOuter := bvNone;
  for a := Low(TAccountAction) to High(TAccountAction) do
  begin
    b := TButton.Create(bar);
    b.Parent := bar;
    b.Caption := ActionCaption(a);
    b.AutoSize := True;
    b.BorderSpacing.Around := 3;
    b.Tag := Ord(a);
    b.OnClick := @ActionClick;
    b.Enabled := False;
    FActions[a] := b;
  end;
  FPolicy := TRtListGrid.Create(Body);
  FPolicy.Parent := Body;
  FPolicy.Align := alBottom;
  FPolicy.Height := 200;
  FPolicy.FillWidth := True;
  FPolicy.AddColumn(rsAccColProperty, 240);
  FPolicy.AddColumn(rsAccColValue, 400);
  FPolicy.Visible := FAdapter = adActiveDirectory;
  FPolicyTitle := MakeLabel(Body, rsAccPolicyTitle, alBottom);
  FPolicyTitle.Visible := FPolicy.Visible;
  FList := TRtListGrid.Create(Body);
  FList.Parent := Body;
  FList.Align := alClient;
  FList.FillWidth := True;
  FList.AddColumn(rsAccColProperty, 240);
  FList.AddColumn(rsAccColValue, 400);
  AddButton(rsAccReload, mrNone).OnClick := @ReloadClick;
  AddButton(rsClose, mrClose, True, True);
end;

procedure TAccountDialog.Reload;
var
  attrs: TStringArray;
begin
  attrs := AccountReadAttributes(FAdapter);
  if FAdapter = adActiveDirectory then
    attrs := Concat(attrs, ['msDS-ResultantPSO']);
  SetStatus(rsAccReading);
  Tasks.Cancel('read');
  Tasks.Cancel('policy');
  ReadEntry(FDn, attrs, 'read');
  UpdateActions;
end;

procedure TAccountDialog.UpdateActions;
var
  a: TAccountAction;
  usable: Boolean;
begin
  if FActions[Low(TAccountAction)] = nil then Exit;
  // On n'agit que sur un etat lu dans cette session, sans tache en vol. Deverrouiller un compte
  // d'apres une photo perimee, c'est de l'archeologie avec des droits d'admin.
  usable :=(FEntry <> nil) and Tasks.ModelCurrent and not Tasks.Pending('read') and
    not Tasks.WritesInFlight;
  for a := Low(TAccountAction) to High(TAccountAction) do
    FActions[a].Enabled := usable and (a in FAvailable);
end;

procedure TAccountDialog.ReloadClick(Sender: TObject);
begin
  Reload;
end;

procedure TAccountDialog.ShowStatus;
var
  st: TAccountStatus;
  a: TAccountAction;
  i: Integer;
begin
  st := ReadAccountStatus(FEntry, FAdapter, UtcNow);
  FList.Clear;
  FList.AddRow([rsAccAdapter, AccountAdapterName(FAdapter)]);
  if FAdapter <> adNone then
  begin
    FList.AddRow([rsAccDisabled, TriStateText(st.Disabled)]);
    FList.AddRow([rsAccLocked, TriStateText(st.LockedOut)]);
    if st.LockDetail <> '' then FList.AddRow([rsAccLockDetail, st.LockDetail]);
    if st.AccountExpiry <> '' then FList.AddRow([rsAccExpires, st.AccountExpiry]);
    FList.AddRow([rsAccExpired, TriStateText(st.AccountExpired)]);
    FList.AddRow([rsAccPwdExpired, TriStateText(st.PasswordExpired)]);
    FList.AddRow([rsAccMustChange, TriStateText(st.MustChangePassword)]);
    if FAdapter = adActiveDirectory then
      FList.AddRow([rsAccNeverExpires, TriStateText(st.PasswordNeverExpires)]);
  end;
  for i := 0 to High(st.Notes) do
    FList.AddRow([rsAccNotes, st.Notes[i]]);
  FAvailable := st.Available;
  for a := Low(TAccountAction) to High(TAccountAction) do
    FActions[a].Visible := (FAdapter <> adNone) and ((a in st.Available) or
      (a in [aaEnable, aaDisable, aaUnlock]));
  UpdateActions;
end;

procedure TAccountDialog.ShowPolicy(AEntry: TLdapEntry);
var
  p: TPasswordPolicyView;
  i: Integer;

  procedure Row(const AName, AValue: string);
  begin
    if AValue <> '' then FPolicy.AddRow([AName, AValue]);
  end;

begin
  FPolicy.Clear;
  if AEntry = nil then Exit;
  if FEntry.FirstValue('msDS-ResultantPSO', '') <> '' then
  begin
    p := ReadPso(AEntry);
    FPolicyTitle.Caption := rsAccPolicyTitle + ': ' + Format(rsAccPolicyFromPso, [p.Source]);
  end
  else
  begin
    p := ReadDomainPolicy(AEntry);
    FPolicyTitle.Caption := rsAccPolicyTitle + ': ' + Format(rsAccPolicyFromDomain, [p.Source]);
  end;
  Row(rsAccPolPrecedence, p.Precedence);
  Row(rsAccPolMinLength, p.MinLength);
  Row(rsAccPolHistory, p.HistoryLength);
  Row(rsAccPolMinAge, p.MinAge);
  Row(rsAccPolMaxAge, p.MaxAge);
  Row(rsAccPolComplexity, p.Complexity);
  Row(rsAccPolReversible, p.ReversibleEncryption);
  Row(rsAccPolThreshold, p.LockoutThreshold);
  Row(rsAccPolDuration, p.LockoutDuration);
  Row(rsAccPolWindow, p.ObservationWindow);
  for i := 0 to High(p.AppliesTo) do
    FPolicy.AddRow(['msDS-PSOAppliesTo', p.AppliesTo[i]]);
end;

procedure TAccountDialog.OnEntry(AMsg: TEntryMsg);
var
  pso, domain: string;
begin
  if Tasks.Current.Tag = 'read' then
  begin
    if AMsg.Entry = nil then
    begin
      SetStatus(Format(rsAccUnreadable, [ErrorToText(AMsg.Error)]), usError);
      Exit;
    end;
    FreeAndNil(FEntry);
    FEntry := AMsg.Entry;
    AMsg.Entry := nil;
    StampModel(AMsg);
    SetStatus('');
    ShowStatus;
    if FAdapter = adActiveDirectory then
    begin
      pso := FEntry.FirstValue('msDS-ResultantPSO', '');
      if pso <> '' then
        ReadEntry(pso, AD_PSO_ATTRS, 'policy')
      else
      begin
        domain := DomainNamingContext(Conn);
        if domain <> '' then ReadEntry(domain, AD_DOMAIN_POLICY_ATTRS, 'policy');
      end;
    end;
  end
  else if Tasks.Current.Tag = 'policy' then
    ShowPolicy(AMsg.Entry);
end;

procedure TAccountDialog.OnWrite(AMsg: TWriteMsg);
begin
  if Tasks.Current.Tag <> 'write' then Exit;
  if ReportWrite(AMsg) then Reload;
end;

procedure TAccountDialog.ActionClick(Sender: TObject);
var
  change: TLdapChange;
  err: string;
begin
  UpdateActions;
  if not TButton(Sender).Enabled then Exit;
  change := PlanAccountAction(FEntry, FAdapter, TAccountAction(TButton(Sender).Tag), UtcNow, err);
  if change = nil then
  begin
    SetStatus(err, usWarning);
    Exit;
  end;
  SubmitChange(change, AccountAdapterName(FAdapter));
  UpdateActions;
end;

end.
