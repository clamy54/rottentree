// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uProfileDialog;

{$mode objfpc}{$H+}

// Assistant de profil de connexion. Fetch base DNs et Test ouvrent une connexion temporaire
// avec le formulaire tel quel; changer l'hote, la securite ou l'identite invalide leurs resultats.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, ComCtrls, Dialogs, LazUTF8,
  uUiKit, uConnectionProfile, uUiInbox, uDirectoryWorker, uProfileProbe, uRtCheck, uRtCombo, uRtList,
  uRtSecretEdit;

resourcestring
  rsProfileTitle = 'Connection profile';
  rsTabGeneral = 'General';
  rsTabAuth = 'Authentication';
  rsTabTls = 'TLS';
  rsTabBases = 'Base DNs';
  rsTabLimits = 'Limits';
  rsTabTest = 'Test';
  rsName = 'Name';
  rsDescription = 'Description';
  rsBadge = 'Tag';
  rsHost = 'Host';
  rsPort = 'Port';
  rsTransport = 'Transport';
  rsReadOnly = 'Read-only profile (no writes are sent)';
  rsServerKind = 'Server type';
  rsServerKindHint = 'Automatic: deduced from the root DSE at each connection. A manual choice ' +
    'selects the tools offered; vendor-specific writes still check the schema.';
  rsAuthMode = 'Mode';
  rsAuthAnonymous = 'Anonymous';
  rsAuthSimple = 'Simple bind';
  rsAuthExternal = 'SASL EXTERNAL (client certificate)';
  rsBindDn = 'Bind DN or user';
  rsAppendBase = 'Append base DN';
  rsBindAs = 'Bind as: %s';
  rsAppendNoBase = 'No base DN yet (Base DNs tab): nothing can be appended.';
  rsAppendNotDn = 'Not a DN: sent as typed, the base DN is not appended.';
  rsAuthzId = 'Authorization identity';
  rsAuthzHint = 'Optional. Empty: the client certificate''s identity. Otherwise dn:... or u:..., if the server allows it.';
  rsSecret = 'Password';
  rsSecretHint = 'Used for this dialog''s tests. Stored only if you choose to remember it.';
  rsRemember = 'Remember the password in the encrypted document';
  rsAllowPlain = 'Allow sending passwords without encryption for this profile';
  rsPlainWarning = 'This connection is not encrypted: identities, data and passwords can be read on the network.';
  rsVerifyCa = 'Verify the certification chain (CA)';
  rsVerifyDates = 'Verify validity dates';
  rsVerifyName = 'Verify the host name';
  rsCaExplain = 'The connection stays encrypted, but the server identity is no longer fully verified.';
  rsRevocation = 'Revocation';
  rsRevNotChecked = 'Not checked';
  // Pas de CRL ni d'OCSP pour l'instant: les libelles l'avouent et le statut reste
  // "non etabli". Mieux vaut un aveu qu'une case verte qui ment.
  rsRevChecked = 'Report as not established (CRL/OCSP checking not available yet)';
  rsRevRequired = 'Required (always refused until CRL/OCSP checking is available)';
  rsTrustedCas = 'Certificate authorities trusted by this profile';
  rsImportCa = 'Import CA...';
  rsRemove = 'Remove';
  rsPins = 'Pinned SHA-256 fingerprints (added to the verification)';
  rsAddPin = 'Add pin...';
  rsClientCert = 'Client certificate (PEM)';
  rsClientKey = 'Client private key (PEM)';
  rsBrowse = 'Browse...';
  rsBaseDnsIntro = 'Choose the naming contexts to browse. A DN missing from the root DSE is not necessarily invalid.';
  rsFetch = 'Fetch base DNs';
  rsAddManual = 'Add manually...';
  rsManualPrompt = 'Base DN';
  rsFetching = 'Connecting to read the root DSE...';
  rsShowConfig = 'Also show the server configuration (cn=config, cn=monitor...) when this identity can read it';
  rsFetchNone = 'The server returned no naming context (anonymous access may be restricted). Enter a base manually.';
  rsConnectTimeout = 'Connection timeout (s)';
  rsTlsTimeout = 'TLS timeout (s)';
  rsOpTimeout = 'Operation timeout (s)';
  rsPageSize = 'Page size';
  rsSizeLimit = 'Interactive size limit';
  rsAliases = 'Alias dereferencing';
  rsReferrals = 'Referrals';
  rsReferralsOff = 'Disabled (reported, never followed)';
  rsTestIntro = 'Runs each step separately. An open port does not validate credentials.';
  rsRunTest = 'Test connection';
  rsStep = 'Step';
  rsResult = 'Result';
  rsDuration = 'Duration';
  rsDetail = 'Detail';
  rsOk = 'OK';
  rsCancel = 'Cancel';
  rsSave = 'Save';
  rsErrors = 'The profile cannot be saved:';
  rsStale = 'Settings changed since this result: run it again.';
  rsImportPinPrompt = 'SHA-256 fingerprint (64 hexadecimal digits)';
  rsFolder = 'Folder';
  rsNoFolder = '(root)';

type
  TProfileDialog = class(TRtDialog)
  private
    FProfile: TConnectionProfile;
    FPages: TPageControl;
    FName, FDesc, FBadge, FHost, FPort, FBindDn, FAuthz: TEdit;
    FSecret: TRtSecretEdit;
    FTransport, FAuthMode, FRevocation, FAliases, FFolder, FServerKind: TRtComboBox;
    FReadOnly, FAllowPlain, FRemember, FAppendBase, FShowConfig: TRtCheckBox;
    FBindPreview: TLabel;
    FVerifyCa, FVerifyDates, FVerifyName: TRtCheckBox;
    FCaList, FPinList: TListBox;
    FClientCert, FClientKey: TEdit;
    FBaseList: TListBox;
    FBaseStatus: TLabel;
    FConnectTimeout, FTlsTimeout, FOpTimeout, FPageSize, FSizeLimit: TEdit;
    FSteps: TRtListGrid;
    FPlainWarning: TLabel;
    FSecretHint, FAuthzHint: TLabel;
    FProbe: TProfileProbe;
    FDirtySinceRun: Boolean;
    FLoading: Boolean;
    FFolderUuids: TStringList;
    FLastHost: string;
    FLastPort: Integer;
    procedure BuildGeneral(AParent: TWinControl);
    procedure BuildAuth(AParent: TWinControl);
    procedure BuildTls(AParent: TWinControl);
    procedure BuildBases(AParent: TWinControl);
    procedure BuildLimits(AParent: TWinControl);
    procedure BuildTest(AParent: TWinControl);
    function EditRow(AParent: TWinControl; const ACaption: string): TEdit;
    function ComboRow(AParent: TWinControl; const ACaption: string;
      const AItems: array of string): TRtComboBox;
    procedure LoadFromProfile;
    procedure SaveToProfile(AProfile: TConnectionProfile);
    procedure TransportChanged(Sender: TObject);
    procedure AuthModeChanged(Sender: TObject);
    procedure UpdateAuthFields;
    procedure UpdateBindPreview;
    function SimpleBindSelected: Boolean;
    procedure SettingChanged(Sender: TObject);
    procedure VerifyCaClick(Sender: TObject);
    procedure ImportCaClick(Sender: TObject);
    procedure RemoveCaClick(Sender: TObject);
    procedure AddPinClick(Sender: TObject);
    procedure RemovePinClick(Sender: TObject);
    procedure BrowseCertClick(Sender: TObject);
    procedure BrowseKeyClick(Sender: TObject);
    procedure FetchClick(Sender: TObject);
    procedure AddBaseClick(Sender: TObject);
    procedure RemoveBaseClick(Sender: TObject);
    procedure TestClick(Sender: TObject);
    procedure StartWorker(AFetch: Boolean);
    procedure StopWorker;
    procedure HandleMessage(AMsg: TUiMessage);
    procedure CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
  public
    constructor CreateFor(AOwner: TComponent; AProfile: TConnectionProfile;
      const AFolderNames, AFolderUuids: TStrings; const ACurrentFolder: string);
    destructor Destroy; override;
    function SelectedFolderUuid: string;
    function SecretText: RawByteString;
    function RememberSecret: Boolean;
  end;

function EditProfile(AOwner: TComponent; AProfile: TConnectionProfile;
  const AFolderNames, AFolderUuids: TStrings; var AFolderUuid: string;
  out ASecret: RawByteString; out ARemember: Boolean): Boolean;

implementation

uses
  Graphics, uTheme, uLdapDn, uSessionModel, uLdapErrors, uCertificateInfo, uRtBytes, uTlsPolicy, uServerKind, uRtMessage;

function EditProfile(AOwner: TComponent; AProfile: TConnectionProfile;
  const AFolderNames, AFolderUuids: TStrings; var AFolderUuid: string;
  out ASecret: RawByteString; out ARemember: Boolean): Boolean;
var
  d: TProfileDialog;
begin
  d := TProfileDialog.CreateFor(AOwner, AProfile, AFolderNames, AFolderUuids, AFolderUuid);
  try
    Result := d.ShowModal = mrOk;
    ASecret := '';
    ARemember := False;
    if Result then
    begin
      d.SaveToProfile(AProfile);
      AFolderUuid := d.SelectedFolderUuid;
      ASecret := d.SecretText;
      ARemember := d.RememberSecret;
    end;
  finally
    d.Free;
  end;
end;

constructor TProfileDialog.CreateFor(AOwner: TComponent; AProfile: TConnectionProfile;
  const AFolderNames, AFolderUuids: TStrings; const ACurrentFolder: string);
var
  i: Integer;
begin
  inherited CreateDialog(AOwner, rsProfileTitle, 720, 600);
  SetIcon('server');
  FProfile := AProfile;
  FFolderUuids := TStringList.Create;
  FFolderUuids.Add('');
  FProbe := TProfileProbe.Create;
  if AFolderUuids <> nil then
    FFolderUuids.AddStrings(AFolderUuids);
  FPages := MakePages(Body);
  BuildGeneral(AddPageBody(FPages, rsTabGeneral));
  BuildAuth(AddPageBody(FPages, rsTabAuth));
  BuildTls(AddPageBody(FPages, rsTabTls));
  BuildBases(AddPageBody(FPages, rsTabBases));
  BuildLimits(AddPageBody(FPages, rsTabLimits));
  BuildTest(AddPageBody(FPages, rsTabTest));
  SelectPage(FPages, 0);
  FFolder.Items.Add(rsNoFolder);
  if AFolderNames <> nil then
    FFolder.Items.AddStrings(AFolderNames);
  FFolder.ItemIndex := 0;
  for i := 0 to FFolderUuids.Count - 1 do
    if FFolderUuids[i] = ACurrentFolder then FFolder.ItemIndex := i;
  AddButton(rsSave, mrOk, True);
  AddButton(rsCancel, mrCancel, False, True);
  OnCloseQuery := @CloseQueryHandler;
  LoadFromProfile;
  ApplyTheme;
  UiInbox.Subscribe(Self, @HandleMessage);
end;

destructor TProfileDialog.Destroy;
begin
  UiInbox.Unsubscribe(Self);
  FProbe.Free;
  FFolderUuids.Free;
  inherited Destroy;
end;

function TProfileDialog.EditRow(AParent: TWinControl; const ACaption: string): TEdit;
begin
  Result := MakeEditRow(AParent, ACaption, 190);
  Result.OnChange := @SettingChanged;
end;

function TProfileDialog.ComboRow(AParent: TWinControl; const ACaption: string;
  const AItems: array of string): TRtComboBox;
begin
  Result := MakeComboRow(AParent, ACaption, AItems, 190);
  Result.OnChange := @SettingChanged;
end;

procedure TProfileDialog.BuildGeneral(AParent: TWinControl);
var
  k: TProviderKind;
begin
  FName := EditRow(AParent, rsName);
  FDesc := EditRow(AParent, rsDescription);
  FFolder := ComboRow(AParent, rsFolder, []);
  FBadge := EditRow(AParent, rsBadge);
  FBadge.MaxLength := PROFILE_TAG_MAX_CHARS;
  FBadge.CharCase := ecUppercase;
  FHost := EditRow(AParent, rsHost);
  FTransport := ComboRow(AParent, rsTransport, [TransportLabel(tmStartTls),
    TransportLabel(tmLdaps), TransportLabel(tmPlain)]);
  FTransport.OnChange := @TransportChanged;
  FPort := EditRow(AParent, rsPort);
  FPlainWarning := MakeLabel(AParent, rsPlainWarning);
  FPlainWarning.Font.Color := DialogStateColor(usError);
  FServerKind := ComboRow(AParent, rsServerKind, []);
  for k := Low(TProviderKind) to High(TProviderKind) do
    FServerKind.Items.Add(ServerKindName(k));
  FServerKind.ItemIndex := 0;
  MakeLabel(AParent, rsServerKindHint).Font.Color := DialogStateColor(usMuted);
  FReadOnly := MakeCheck(AParent, rsReadOnly);
  // AutoReconnect n'est plus propose: rien ne le lisait, et une case sans effet
  // ment a celui qui la coche. Le champ JSON reste lu pour les vieux documents.
end;

procedure TProfileDialog.BuildAuth(AParent: TWinControl);
begin
  FAuthMode := ComboRow(AParent, rsAuthMode, [rsAuthAnonymous, rsAuthSimple, rsAuthExternal]);
  FAuthMode.OnChange := @AuthModeChanged;
  FBindDn := EditRow(AParent, rsBindDn);
  FAppendBase := MakeCheck(AParent, rsAppendBase);
  FAppendBase.OnClick := @SettingChanged;
  FBindPreview := MakeDataLabel(AParent, '');
  FBindPreview.Font.Color := DialogStateColor(usMuted);
  FAuthz := EditRow(AParent, rsAuthzId);
  FAuthzHint := MakeLabel(AParent, rsAuthzHint);
  FSecret := MakeSecretRow(AParent, rsSecret, 190);
  FSecret.OnChange := @SettingChanged;
  FSecretHint := MakeLabel(AParent, rsSecretHint);
  FRemember := MakeCheck(AParent, rsRemember);
  FAllowPlain := MakeCheck(AParent, rsAllowPlain);
  FAllowPlain.OnClick := @SettingChanged;
end;

procedure TProfileDialog.BuildTls(AParent: TWinControl);
var
  row: TPanel;
begin
  FVerifyCa := MakeCheck(AParent, rsVerifyCa);
  FVerifyCa.OnClick := @VerifyCaClick;
  FVerifyDates := MakeCheck(AParent, rsVerifyDates);
  FVerifyDates.OnClick := @VerifyCaClick;
  FVerifyName := MakeCheck(AParent, rsVerifyName);
  FVerifyName.OnClick := @VerifyCaClick;
  FRevocation := ComboRow(AParent, rsRevocation, [rsRevNotChecked, rsRevChecked, rsRevRequired]);
  MakeLabel(AParent, rsTrustedCas);
  row := MakePanel(AParent, alTop, 90);
  FCaList := TListBox.Create(row);
  FCaList.Parent := row;
  FCaList.Align := alClient;
  MakeButton(MakePanel(row, alRight, 130), rsImportCa, @ImportCaClick, alTop);
  MakeButton(TWinControl(row.Controls[row.ControlCount - 1]), rsRemove, @RemoveCaClick, alTop);
  MakeLabel(AParent, rsPins);
  row := MakePanel(AParent, alTop, 70);
  FPinList := TListBox.Create(row);
  FPinList.Parent := row;
  FPinList.Align := alClient;
  MakeButton(MakePanel(row, alRight, 130), rsAddPin, @AddPinClick, alTop);
  MakeButton(TWinControl(row.Controls[row.ControlCount - 1]), rsRemove, @RemovePinClick, alTop);
  FClientCert := MakeEditRow(AParent, rsClientCert, 190);
  MakeButton(FClientCert.Parent, rsBrowse, @BrowseCertClick, alRight);
  FClientKey := MakeEditRow(AParent, rsClientKey, 190);
  MakeButton(FClientKey.Parent, rsBrowse, @BrowseKeyClick, alRight);
end;

procedure TProfileDialog.BuildBases(AParent: TWinControl);
var
  bar: TPanel;
begin
  MakeLabel(AParent, rsBaseDnsIntro);
  bar := MakePanel(AParent, alTop, 36);
  MakeButton(bar, rsFetch, @FetchClick);
  MakeButton(bar, rsAddManual, @AddBaseClick);
  MakeButton(bar, rsRemove, @RemoveBaseClick);
  FBaseStatus := MakeLabel(AParent, '');
  FShowConfig := MakeCheck(AParent, rsShowConfig, alBottom);
  FBaseList := TListBox.Create(AParent);
  FBaseList.Parent := AParent;
  FBaseList.Align := alClient;
  FBaseList.MultiSelect := True;
end;

procedure TProfileDialog.BuildLimits(AParent: TWinControl);
begin
  FConnectTimeout := EditRow(AParent, rsConnectTimeout);
  FTlsTimeout := EditRow(AParent, rsTlsTimeout);
  FOpTimeout := EditRow(AParent, rsOpTimeout);
  FPageSize := EditRow(AParent, rsPageSize);
  FSizeLimit := EditRow(AParent, rsSizeLimit);
  FAliases := ComboRow(AParent, rsAliases, ['never', 'searching', 'finding', 'always']);
  ComboRow(AParent, rsReferrals, [rsReferralsOff]);
end;

procedure TProfileDialog.BuildTest(AParent: TWinControl);
var
  bar: TPanel;
begin
  MakeLabel(AParent, rsTestIntro);
  bar := MakePanel(AParent, alTop, 36);
  MakeButton(bar, rsRunTest, @TestClick);
  // Liste maison: l'en-tete du TListView natif se moque du theme.
  FSteps := TRtListGrid.Create(AParent);
  FSteps.Parent := AParent;
  FSteps.Align := alClient;
  FSteps.FillWidth := True;
  FSteps.AddColumn(rsStep, 150);
  FSteps.AddColumn(rsResult, 70);
  FSteps.AddColumn(rsDuration, 80);
  FSteps.AddColumn(rsDetail, 360);
end;

procedure TProfileDialog.LoadFromProfile;
var
  i: Integer;
begin
  FLoading := True;
  try
    FName.Text := FProfile.Name;
    FDesc.Text := FProfile.Description;
    FBadge.Text := FProfile.EnvironmentBadge;
    FHost.Text := FProfile.Host;
    FPort.Text := IntToStr(FProfile.Port);
    FTransport.ItemIndex := Ord(FProfile.Transport);
    FReadOnly.Checked := FProfile.ReadOnly;
    FServerKind.ItemIndex := Ord(FProfile.Provider);
    FAuthMode.ItemIndex := Ord(FProfile.AuthMode);
    FBindDn.Text := FProfile.BindDn;
    FAppendBase.Checked := FProfile.AppendBaseDn;
    FAuthz.Text := FProfile.AuthzId;
    FAllowPlain.Checked := FProfile.AllowPlainSecrets;
    FRemember.Checked := FProfile.SecretRef <> '';
    FVerifyCa.Checked := FProfile.Tls.VerifyCAChain;
    FVerifyDates.Checked := FProfile.Tls.VerifyValidityDates;
    FVerifyName.Checked := FProfile.Tls.VerifyHostname;
    FRevocation.ItemIndex := Ord(FProfile.Revocation);
    FCaList.Items.Clear;
    for i := 0 to FProfile.TrustedCaDer.Count - 1 do
      FCaList.Items.Add(FProfile.TrustedCaDer[i]);
    FPinList.Items.Assign(FProfile.PinnedSha256);
    FClientCert.Text := FProfile.ClientCertPath;
    FClientKey.Text := FProfile.ClientKeyPath;
    FBaseList.Items.Assign(FProfile.BaseDns);
    FShowConfig.Checked := FProfile.ShowServerConfig;
    FConnectTimeout.Text := IntToStr(FProfile.ConnectTimeoutSec);
    FTlsTimeout.Text := IntToStr(FProfile.TlsTimeoutSec);
    FOpTimeout.Text := IntToStr(FProfile.OperationTimeoutSec);
    FPageSize.Text := IntToStr(FProfile.PageSize);
    FSizeLimit.Text := IntToStr(FProfile.SizeLimit);
    FAliases.ItemIndex := FProfile.DerefAliases;
    FLastHost := FProfile.Host;
    FLastPort := FProfile.Port;
    FPlainWarning.Visible := FProfile.Transport = tmPlain;
  finally
    FLoading := False;
  end;
  UpdateAuthFields;
end;

procedure TProfileDialog.SaveToProfile(AProfile: TConnectionProfile);
begin
  AProfile.Name := Trim(FName.Text);
  AProfile.Description := FDesc.Text;
  AProfile.EnvironmentBadge := UTF8Copy(UTF8UpperCase(Trim(FBadge.Text)), 1,
    PROFILE_TAG_MAX_CHARS);
  // Changer d'hote ou de port remet les exceptions TLS au strict, sauf reglage explicite
  // ici: une exception accordee a un serveur ne se transmet pas a son voisin.
  AProfile.SetEndpoint(Trim(FHost.Text), StrToIntDef(FPort.Text, 0), True);
  AProfile.Transport := TTransportMode(FTransport.ItemIndex);
  AProfile.ReadOnly := FReadOnly.Checked;
  if FServerKind.ItemIndex >= 0 then
    AProfile.Provider := TProviderKind(FServerKind.ItemIndex);
  AProfile.AuthMode := TAuthMode(FAuthMode.ItemIndex);
  AProfile.BindDn := Trim(FBindDn.Text);
  AProfile.AppendBaseDn := FAppendBase.Checked;
  AProfile.AuthzId := Trim(FAuthz.Text);
  AProfile.AllowPlainSecrets := FAllowPlain.Checked;
  AProfile.Tls.VerifyCAChain := FVerifyCa.Checked;
  AProfile.Tls.VerifyValidityDates := FVerifyDates.Checked;
  AProfile.Tls.VerifyHostname := FVerifyName.Checked;
  AProfile.Revocation := TRevocationPolicy(FRevocation.ItemIndex);
  AProfile.TrustedCaDer.Assign(FCaList.Items);
  AProfile.PinnedSha256.Assign(FPinList.Items);
  AProfile.ClientCertPath := Trim(FClientCert.Text);
  AProfile.ClientKeyPath := Trim(FClientKey.Text);
  AProfile.BaseDns.Assign(FBaseList.Items);
  AProfile.ShowServerConfig := FShowConfig.Checked;
  AProfile.ConnectTimeoutSec := StrToIntDef(FConnectTimeout.Text, 10);
  AProfile.TlsTimeoutSec := StrToIntDef(FTlsTimeout.Text, 10);
  AProfile.OperationTimeoutSec := StrToIntDef(FOpTimeout.Text, 30);
  AProfile.PageSize := StrToIntDef(FPageSize.Text, 500);
  AProfile.SizeLimit := StrToIntDef(FSizeLimit.Text, 10000);
  AProfile.DerefAliases := FAliases.ItemIndex;
end;

procedure TProfileDialog.TransportChanged(Sender: TObject);
var
  p: Integer;
begin
  if FLoading then Exit;
  p := StrToIntDef(FPort.Text, 0);
  if (p = DEFAULT_LDAP_PORT) or (p = DEFAULT_LDAPS_PORT) or (p = 0) then
    FPort.Text := IntToStr(DefaultPortFor(TTransportMode(FTransport.ItemIndex)));
  FPlainWarning.Visible := FTransport.ItemIndex = Ord(tmPlain);
  SettingChanged(Sender);
end;

procedure TProfileDialog.AuthModeChanged(Sender: TObject);
begin
  UpdateAuthFields;
  SettingChanged(Sender);
end;

function TProfileDialog.SimpleBindSelected: Boolean;
begin
  Result := FAuthMode.ItemIndex = Ord(amSimple);
end;

procedure TProfileDialog.UpdateAuthFields;
var
  simple, external: Boolean;
begin
  simple := SimpleBindSelected;
  external := FAuthMode.ItemIndex = Ord(amSaslExternal);
  FBindDn.Parent.Enabled := simple;
  FAppendBase.Enabled := simple;
  FSecret.Parent.Enabled := simple;
  FSecretHint.Enabled := simple;
  FRemember.Enabled := simple;
  FAllowPlain.Enabled := simple;
  FAuthz.Parent.Enabled := external;
  FAuthzHint.Enabled := external;
  FClientCert.Parent.Enabled := external;
  FClientKey.Parent.Enabled := external;
  UpdateBindPreview;
end;

procedure TProfileDialog.UpdateBindPreview;
var
  tmp: TConnectionProfile;
  d: TLdapDn;
  err: string;
begin
  if (FBindPreview = nil) or (FBaseList = nil) then Exit;
  if not SimpleBindSelected or not FAppendBase.Checked or (Trim(FBindDn.Text) = '') then
    FBindPreview.Caption := ''
  else if FBaseList.Items.Count = 0 then
    FBindPreview.Caption := rsAppendNoBase
  else if not DnParse(Trim(FBindDn.Text), d, err) then
    FBindPreview.Caption := rsAppendNotDn
  else
  begin
    tmp := TConnectionProfile.Create;
    try
      tmp.AuthMode := amSimple;
      tmp.BindDn := FBindDn.Text;
      tmp.AppendBaseDn := True;
      tmp.BaseDns.Assign(FBaseList.Items);
      FBindPreview.Caption := Format(rsBindAs, [EffectiveBindDn(tmp)]);
    finally
      tmp.Free;
    end;
  end;
end;

procedure TProfileDialog.SettingChanged(Sender: TObject);
begin
  if FLoading then Exit;
  UpdateBindPreview;
  FDirtySinceRun := True;
  // Hote ou port change: retour au TLS strict.
  if ((Sender = FHost) or (Sender = FPort)) and
     ((Trim(FHost.Text) <> FLastHost) or (StrToIntDef(FPort.Text, 0) <> FLastPort)) then
  begin
    FLoading := True;
    try
      FVerifyCa.Checked := True;
      FVerifyDates.Checked := True;
      FVerifyName.Checked := True;
      FPinList.Items.Clear;
    finally
      FLoading := False;
    end;
    FLastHost := Trim(FHost.Text);
    FLastPort := StrToIntDef(FPort.Text, 0);
  end;
  if (FSteps <> nil) and (FSteps.Count > 0) then
    FBaseStatus.Caption := rsStale;
  StopWorker;
end;

procedure TProfileDialog.VerifyCaClick(Sender: TObject);
begin
  if FLoading then Exit;
  if not TRtCheckBox(Sender).Checked then
    RtMessageDlg(rsTabTls, rsCaExplain, mtWarning, [mbOK], 0);
  if (Sender = FVerifyCa) and not FVerifyCa.Checked and (FRevocation.ItemIndex = Ord(rpRequired)) then
    FRevocation.ItemIndex := Ord(rpChecked);
  SettingChanged(Sender);
end;

procedure TProfileDialog.ImportCaClick(Sender: TObject);
var
  od: TOpenDialog;
  data: RawByteString;
  ders: TStringArray;
  err: string;
  i: Integer;
  info: TCertInfo;
begin
  od := TOpenDialog.Create(Self);
  try
    od.Filter := 'Certificates (*.pem;*.crt;*.cer;*.der)|*.pem;*.crt;*.cer;*.der|All files|*.*';
    if not od.Execute then Exit;
    if not (ReadCertificateFile(od.FileName, data, err) and ParseCertificates(data, ders, err)) then
    begin
      RtMessageDlg(rsImportCa, err, mtError, [mbOK], 0);
      Exit;
    end;
    for i := 0 to High(ders) do
    begin
      info := DescribeCertificate(ders[i]);
      // L'empreinte est montree avant d'accorder la confiance. Lire avant de signer.
      if RtMessageDlg(rsImportCa, Format('%s' + LineEnding + 'Issuer: %s' + LineEnding +
          'SHA-256: %s' + LineEnding + LineEnding + 'Trust this authority for this profile only?',
          [info.Subject, info.Issuer, FormatFingerprint(info.Sha256)]), mtConfirmation,
          [mbYes, mbNo], 0) = mrYes then
        FCaList.Items.Add(HexEncode(ders[i]));
    end;
    SettingChanged(Sender);
  finally
    od.Free;
  end;
end;

procedure TProfileDialog.RemoveCaClick(Sender: TObject);
begin
  if FCaList.ItemIndex >= 0 then
  begin
    FCaList.Items.Delete(FCaList.ItemIndex);
    SettingChanged(Sender);
  end;
end;

procedure TProfileDialog.AddPinClick(Sender: TObject);
var
  s: string;
begin
  s := '';
  if not RtInputQuery(rsAddPin, rsImportPinPrompt, s) then Exit;
  s := NormalizeFingerprint(s);
  if Length(s) <> 64 then Exit;
  FPinList.Items.Add(s);
  SettingChanged(Sender);
end;

procedure TProfileDialog.RemovePinClick(Sender: TObject);
begin
  if FPinList.ItemIndex >= 0 then
  begin
    FPinList.Items.Delete(FPinList.ItemIndex);
    SettingChanged(Sender);
  end;
end;

procedure TProfileDialog.BrowseCertClick(Sender: TObject);
var
  od: TOpenDialog;
begin
  od := TOpenDialog.Create(Self);
  try
    if od.Execute then FClientCert.Text := od.FileName;
  finally
    od.Free;
  end;
end;

procedure TProfileDialog.BrowseKeyClick(Sender: TObject);
var
  od: TOpenDialog;
begin
  od := TOpenDialog.Create(Self);
  try
    if od.Execute then FClientKey.Text := od.FileName;
  finally
    od.Free;
  end;
end;

procedure TProfileDialog.StartWorker(AFetch: Boolean);
var
  tmp: TConnectionProfile;
  secret: RawByteString;
begin
  tmp := TConnectionProfile.Create;
  try
    tmp.Assign(FProfile);
    SaveToProfile(tmp);
    FDirtySinceRun := False;
    // Le mot de passe ne part qu'en bind simple. En EXTERNAL, l'identite vient du champ
    // dedie du profil, jamais de celui-ci.
    if not SimpleBindSelected then secret := ''
    else FSecret.GetSecret(secret);
    try
      if AFetch then
        FProbe.Start(tmp, secret, pkFetchBases, Self)
      else
        FProbe.Start(tmp, secret, pkTest, Self);
    finally
      WipeString(secret);
    end;
  finally
    tmp.Free;
  end;
end;

procedure TProfileDialog.StopWorker;
begin
  FProbe.Stop;
end;

procedure TProfileDialog.FetchClick(Sender: TObject);
begin
  FBaseStatus.Caption := rsFetching;
  StartWorker(True);
end;

procedure TProfileDialog.AddBaseClick(Sender: TObject);
var
  s: string;
begin
  s := '';
  if RtInputQuery(rsAddManual, rsManualPrompt, s) and (Trim(s) <> '') then
  begin
    FBaseList.Items.Add(Trim(s));
    UpdateBindPreview;
  end;
end;

procedure TProfileDialog.RemoveBaseClick(Sender: TObject);
var
  i: Integer;
begin
  for i := FBaseList.Items.Count - 1 downto 0 do
    if FBaseList.Selected[i] then FBaseList.Items.Delete(i);
  UpdateBindPreview;
end;

procedure TProfileDialog.TestClick(Sender: TObject);
begin
  FSteps.Clear;
  StartWorker(False);
end;

procedure TProfileDialog.HandleMessage(AMsg: TUiMessage);
var
  verdict: string;
  step: TStepMsg;
  conn: TConnectedMsg;
  bases: TBaseDnCandidates;
  names: string;
  i, k: Integer;
  known: Boolean;
begin
  if not FProbe.Accepts(AMsg) then Exit;
  if AMsg is TStepMsg then
  begin
    if FProbe.Kind = pkFetchBases then Exit;
    step := TStepMsg(AMsg);
    if step.Step.Skipped then
      verdict := '-'
    else if step.Step.Ok then
      verdict := 'OK'
    else
      verdict := 'FAILED';
    FSteps.AddRow([ConnectStepName(step.Step.Step), verdict,
      IntToStr(step.Step.DurationMs) + ' ms', step.Step.Detail]);
  end
  else if AMsg is TConnectedMsg then
  begin
    conn := TConnectedMsg(AMsg);
    if FProbe.Kind = pkFetchBases then
    begin
      if not conn.Ok then
      begin
        FBaseStatus.Caption := ErrorToText(conn.Error);
        Exit;
      end;
      bases := BaseDnCandidates(conn.RootDse);
      names := '';
      for i := 0 to High(bases) do
      begin
        known := False;
        for k := 0 to FBaseList.Items.Count - 1 do
          if SameText(FBaseList.Items[k], bases[i].Dn) then known := True;
        if not known then FBaseList.Items.Add(bases[i].Dn);
        if names <> '' then names := names + ', ';
        names := names + bases[i].Dn + '  (' + bases[i].Origin + ')';
      end;
      UpdateBindPreview;
      if names = '' then
        FBaseStatus.Caption := rsFetchNone
      else
        FBaseStatus.Caption := names;
    end
    else if not conn.Ok then
    begin
      FSteps.AddRow([CategoryName(conn.Error.Category), 'FAILED', '',
        ErrorToText(conn.Error) + ' ' + conn.Error.Action]);
    end;
  end;
end;

procedure TProfileDialog.CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
var
  tmp: TConnectionProfile;
  issues: TProfileIssues;
  i: Integer;
  msg: string;
begin
  if ModalResult <> mrOk then Exit;
  tmp := TConnectionProfile.Create;
  try
    tmp.Assign(FProfile);
    SaveToProfile(tmp);
    issues := ValidateProfile(tmp);
    msg := '';
    for i := 0 to High(issues) do
      if issues[i].Level = pilError then
        msg := msg + LineEnding + '- ' + issues[i].Message;
    if msg <> '' then
    begin
      RtMessageDlg(rsProfileTitle, rsErrors + msg, mtError, [mbOK], 0);
      CanClose := False;
    end;
  finally
    tmp.Free;
  end;
end;

function TProfileDialog.SelectedFolderUuid: string;
begin
  if (FFolder.ItemIndex >= 0) and (FFolder.ItemIndex < FFolderUuids.Count) then
    Result := FFolderUuids[FFolder.ItemIndex]
  else
    Result := '';
end;

function TProfileDialog.SecretText: RawByteString;
begin
  if SimpleBindSelected then
    FSecret.GetSecret(Result)
  else
    Result := '';
end;

function TProfileDialog.RememberSecret: Boolean;
begin
  Result := FRemember.Checked and SimpleBindSelected;
end;

end.
