// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdapSession;

{$mode objfpc}{$H+}

// Session LDAP adossee a libldap, propriete d'UN seul fil: jamais deux appels
// concurrents sur le meme handle. Resolution, TCP, TLS verifie avant tout secret,
// authentification, Root DSE. Pas de nouvel essai de bind, pas de repli en clair, pas
// de referral suivi en douce.

interface

uses
  SysUtils, Classes, ctypes, uLdapApi, uConnectionProfile, uTlsPolicy, uTlsVerify,
  uLdapEntry, uSearchModel, uLdapErrors, uChangeSet, uCancel, uSensitive, uSessionModel,
  uDirectorySession;

const
  SESSION_POLL_MS = 100;

type
  TSearchEntryEvent = uDirectorySession.TSearchEntryEvent;

  TSearchArgs = record
    Scope: Integer;
    Base: AnsiString;
    Filter: AnsiString;
    Attrs: array of AnsiString;
    AttrPtrs: array of PAnsiChar;
    StripAttributes: Boolean;
  end;

  TLdapSession = class(TDirectorySession)
  private
    FLd: PLDAP;
    FPendingMsgIds: array of Integer;
    FRangeCancel: TCancelToken;
    function ReadRangeFragment(const ADn, ADescription: string): TLdapEntry;
    procedure ReportStep(AStep: TConnectStep; AOk, ASkipped: Boolean; AStartMs: Int64;
      const ADetail: string);
    function SetIntOption(AOption, AValue: Integer): Boolean;
    function SetTimeoutOption(AOption: Integer; ASeconds: Integer): Boolean;
    function LdErrorCode: Integer;
    function LdDiagnostic: string;
    function WaitResult(AMsgId: Integer; ACancel: TCancelToken; ATimeoutMs: Int64;
      out AMsg: PLDAPMessage; out AErr: TLdapError; const AStep: string): Boolean;
    function ParseFinalResult(AMsg: PLDAPMessage; out ACode: Integer; out AMatched,
      ADiag: string; out ARefs: TStringArray; out ACtrls: PPLDAPControl): Boolean;
    function ParseEntry(AMsg: PLDAPMessage; const ARequested: array of string): TLdapEntry;
    function DoBind(const ASecret: RawByteString; ACancel: TCancelToken): Boolean;
    function DoSecure(ACancel: TCancelToken): Boolean;
    function AttachTlsContext: Boolean;
    procedure ForgetMsgId(AMsgId: Integer);
    function OperationTimeoutMs: Int64;
    function WaitWrite(AMsgId: Integer; ACancel: TCancelToken; const AStep: string): TWriteResult;
    function WriteGuard(const AStep: string; out AResult: TWriteResult): Boolean;
    function SecretsGuard(const AStep: string; const AAttrs: array of string;
      out AResult: TWriteResult): Boolean;
    function AssembleRanges(AEntry: TLdapEntry; ACancel: TCancelToken): Boolean;
    function PrepareSearch(const AReq: TSearchRequest; out AArgs: TSearchArgs;
      var ACompletion: TSearchCompletion): Boolean;
    function SendSearchPage(const AArgs: TSearchArgs; const AReq: TSearchRequest;
      const ACookie: RawByteString; out AMsgId: cint; var ACompletion: TSearchCompletion): Boolean;
    function ReadPageCookie(ACtrls: PPLDAPControl; var ACompletion: TSearchCompletion;
      out AFound: Boolean): RawByteString;
  public
    constructor Create(AProfile: TConnectionProfile; const ASessionId: string;
      AGeneration: Int64);
    destructor Destroy; override;
    // ASecret: mot de passe du bind simple, ignore dans les autres modes (EXTERNAL
    // envoie l'AuthzId du profil). L'appelant efface sa copie apres l'appel.
    function Connect(const ASecret: RawByteString; ACancel: TCancelToken): Boolean; override;
    procedure Close; override;
    function Search(const AReq: TSearchRequest; AOnEntry: TSearchEntryEvent;
      ACancel: TCancelToken; out ACompletion: TSearchCompletion;
      AAssembleRanges: Boolean = False): Boolean; override;
    function ReadEntry(const ADn: string; const AAttrs: array of string;
      ACancel: TCancelToken; AAssembleRanges: Boolean = True): TLdapEntry; overload; override;
    function ReadEntry(const ADn: string; const AAttrs: array of string;
      const AControls: TRequestControlArray; ACancel: TCancelToken): TLdapEntry; overload; override;
    function ReadRootDse(ACancel: TCancelToken): TLdapEntry; override;
    function WhoAmI(ACancel: TCancelToken; out AAuthzId: string): Boolean; override;
    function Modify(const ADn: string; const AMods: TLdapModArray;
      const AAssertionFilter: string; ACancel: TCancelToken): TWriteResult; overload; override;
    function Modify(const ADn: string; const AMods: TLdapModArray;
      const AAssertionFilter: string; const AControls: TRequestControlArray;
      ACancel: TCancelToken): TWriteResult; overload; override;
    function Add(AEntry: TLdapEntry; ACancel: TCancelToken): TWriteResult; override;
    function Delete(const ADn: string; const AAssertionFilter: string;
      ACancel: TCancelToken): TWriteResult; override;
    function Rename(const ADn, ANewRdn, ANewSuperior: string; AHasNewSuperior,
      ADeleteOldRdn: Boolean; ACancel: TCancelToken): TWriteResult; override;
    function PasswordModify(const AUserDn: string; const AOld, ANew: RawByteString;
      AHasOld, AHasNew: Boolean; ACancel: TCancelToken): TWriteResult; override;
    function Compare(const ADn, AAttr: string; const AValue: RawByteString;
      ACancel: TCancelToken; out AMatch: Boolean): Boolean; override;
    function IsConnected: Boolean; override;
  end;

implementation

uses
  uResolve, uOpenSslApi, uBer, uLdapFilter, uRangeAssembly, uRtBytes, uLdapMods;

type
  TControlPtrs = array of PLDAPControl;

procedure FreeRequestControlsPtrs(var ACtrls: TControlPtrs);
var
  i: Integer;
begin
  for i := 0 to High(ACtrls) do
    if ACtrls[i] <> nil then ldap_control_free(ACtrls[i]);
  ACtrls := nil;
end;

procedure FreeRequestControls(var ACtrls: TControlPtrs);
begin
  FreeRequestControlsPtrs(ACtrls);
end;

function CreateRequestControls(const ASpecs: TRequestControlArray; out ACtrls: TControlPtrs): Boolean;
var
  i, rc: Integer;
  bv: TBerval;
  pbv: PBerval;
  oid: AnsiString;
begin
  ACtrls := nil;
  SetLength(ACtrls, Length(ASpecs));
  for i := 0 to High(ASpecs) do
  begin
    ACtrls[i] := nil;
    oid := ASpecs[i].Oid;
    pbv := nil;
    if ASpecs[i].HasValue then
    begin
      bv := StringToBerval(ASpecs[i].Value);
      pbv := @bv;
    end;
    rc := ldap_control_create(PAnsiChar(oid), Ord(ASpecs[i].Critical), pbv, 1, @ACtrls[i]);
    if (rc <> LDAP_SUCCESS) or (ACtrls[i] = nil) then
    begin
      SetLength(ACtrls, i + 1);
      FreeRequestControlsPtrs(ACtrls);
      Exit(False);
    end;
  end;
  Result := True;
end;

constructor TLdapSession.Create(AProfile: TConnectionProfile; const ASessionId: string;
  AGeneration: Int64);
begin
  inherited Create(AProfile, ASessionId, AGeneration);
end;

destructor TLdapSession.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TLdapSession.ReportStep(AStep: TConnectStep; AOk, ASkipped: Boolean;
  AStartMs: Int64; const ADetail: string);
var
  r: TConnectStepResult;
begin
  if not Assigned(FOnStep) then Exit;
  r.Step := AStep;
  r.Ok := AOk;
  r.Skipped := ASkipped;
  r.DurationMs := MonotonicMs - AStartMs;
  r.Detail := ADetail;
  FOnStep(r);
end;

function TLdapSession.SetIntOption(AOption, AValue: Integer): Boolean;
var
  v: cint;
begin
  v := AValue;
  Result := ldap_set_option(FLd, AOption, @v) = LDAP_SUCCESS;
end;

function TLdapSession.SetTimeoutOption(AOption: Integer; ASeconds: Integer): Boolean;
var
  tv: TLdapTimeval;
begin
  tv.tv_sec := ASeconds;
  tv.tv_usec := 0;
  Result := ldap_set_option(FLd, AOption, @tv) = LDAP_SUCCESS;
end;

function TLdapSession.LdErrorCode: Integer;
var
  v: cint;
begin
  v := 0;
  if FLd <> nil then
    ldap_get_option(FLd, LDAP_OPT_RESULT_CODE, @v);
  Result := v;
end;

function TLdapSession.LdDiagnostic: string;
var
  p: PAnsiChar;
begin
  Result := '';
  p := nil;
  if (FLd <> nil) and (ldap_get_option(FLd, LDAP_OPT_DIAGNOSTIC_MESSAGE, @p) = LDAP_SUCCESS) and
     (p <> nil) then
  begin
    Result := SanitizeDiagnostic(p);
    ldap_memfree(p);
  end;
end;

function TLdapSession.OperationTimeoutMs: Int64;
begin
  Result := Int64(FProfile.OperationTimeoutSec) * 1000;
end;

procedure TLdapSession.ForgetMsgId(AMsgId: Integer);
var
  i: Integer;
begin
  for i := 0 to High(FPendingMsgIds) do
    if FPendingMsgIds[i] = AMsgId then
    begin
      FPendingMsgIds[i] := FPendingMsgIds[High(FPendingMsgIds)];
      SetLength(FPendingMsgIds, Length(FPendingMsgIds) - 1);
      Exit;
    end;
end;

function TLdapSession.AttachTlsContext: Boolean;
var
  ctx: Pointer;
  err: string;
  certPath, keyPath: string;
begin
  Result := False;
  certPath := '';
  keyPath := '';
  if FProfile.AuthMode = amSaslExternal then
  begin
    certPath := FProfile.ClientCertPath;
    keyPath := FProfile.ClientKeyPath;
  end;
  ctx := CreateClientSslContext(certPath, keyPath, err);
  if ctx = nil then
  begin
    FLastError := MakeError(lecTls, 0, 'TLS setup', err);
    Exit;
  end;
  try
    // Verification integree de libldap coupee: VerifyTlsSession refait tout, avant le
    // bind.
    SetIntOption(LDAP_OPT_X_TLS_REQUIRE_CERT, LDAP_OPT_X_TLS_NEVER);
    SetIntOption(LDAP_OPT_X_TLS_PROTOCOL_MIN, LDAP_OPT_X_TLS_PROTOCOL_TLS1_2);
    // libldap prend sa propre reference sur le contexte.
    if ldap_set_option(FLd, LDAP_OPT_X_TLS_CTX, ctx) <> LDAP_SUCCESS then
    begin
      FLastError := MakeError(lecTls, 0, 'TLS setup', 'cannot attach the TLS context');
      Exit;
    end;
    Result := True;
  finally
    SSL_CTX_free(ctx);
  end;
end;

function TLdapSession.DoSecure(ACancel: TCancelToken): Boolean;
var
  ssl: Pointer;
  rc: Integer;
  v: TTlsVerification;
  t0: Int64;
begin
  Result := False;
  t0 := MonotonicMs;
  FState := csSecuring;
  if FProfile.Transport = tmStartTls then
  begin
    rc := ldap_start_tls_s(FLd, nil, nil);
    if rc <> LDAP_SUCCESS then
    begin
      // StartTLS rate: connexion fermee. Aucun repli vers le clair, on ne negocie pas
      // avec un attaquant au milieu.
      FLastError := MakeError(lecTls, rc, 'StartTLS', LdDiagnostic);
      if FLastError.Diagnostic = '' then
        FLastError.Diagnostic := string(ldap_err2string(rc));
      ReportStep(stSecurity, False, False, t0, 'StartTLS failed: ' + FLastError.Diagnostic);
      Exit;
    end;
  end;
  ssl := nil;
  if (ldap_get_option(FLd, LDAP_OPT_X_TLS_SSL_CTX, @ssl) <> LDAP_SUCCESS) or (ssl = nil) then
  begin
    FLastError := MakeError(lecTls, 0, 'TLS', 'no TLS session was established');
    ReportStep(stSecurity, False, False, t0, FLastError.Diagnostic);
    Exit;
  end;
  v := VerifyTlsSession(ssl, FProfile, FProfile.Host);
  FTransport.Tls := v;
  if not v.Decision.Accepted then
  begin
    FLastError := MakeError(lecTls, 0, 'certificate verification', v.Decision.Summary);
    ReportStep(stSecurity, False, False, t0, v.Decision.Summary);
    Exit;
  end;
  if (ACancel <> nil) and ACancel.IsCancelled then
  begin
    FLastError := MakeError(lecCancelled, 0, 'security', '');
    Exit;
  end;
  FTransport.Encrypted := True;
  FTransport.StatusLabel := v.Decision.StatusLabel;
  ReportStep(stSecurity, True, False, t0, v.Session.ProtocolName + ', ' + v.Session.Cipher +
    ' - ' + v.Decision.StatusLabel);
  Result := True;
end;

function TLdapSession.DoBind(const ASecret: RawByteString; ACancel: TCancelToken): Boolean;
var
  cred: TBerval;
  msgid: cint;
  rc, code: Integer;
  msg: PLDAPMessage;
  matched, diag: string;
  refs: TStringArray;
  ctrls: PPLDAPControl;
  reason: string;
  t0: Int64;
  dn: AnsiString;
  err: TLdapError;
begin
  Result := False;
  t0 := MonotonicMs;
  FState := csAuthenticating;
  case FProfile.AuthMode of
    amAnonymous:
      begin
        FTransport.Anonymous := True;
        FTransport.BoundIdentity := '';
        ReportStep(stAuthentication, True, True, t0, 'anonymous (no bind sent)');
        Exit(True);
      end;
    amSimple:
      begin
        if not SimpleBindCredentialsAcceptable(EffectiveBindDn(FProfile), Length(ASecret), reason) then
        begin
          FLastError := MakeError(lecConfiguration, 0, 'authentication', reason);
          ReportStep(stAuthentication, False, False, t0, reason);
          Exit;
        end;
        if (not FTransport.Encrypted) and not FProfile.AllowPlainSecrets then
        begin
          FLastError := MakeError(lecConfiguration, 0, 'authentication',
            'sending a password without encryption is not allowed for this profile');
          ReportStep(stAuthentication, False, False, t0, FLastError.Diagnostic);
          Exit;
        end;
        dn := EffectiveBindDn(FProfile);
        cred := StringToBerval(ASecret);
        rc := ldap_sasl_bind(FLd, PAnsiChar(dn), nil, @cred, nil, nil, @msgid);
      end;
    amSaslExternal:
      begin
        if not FTransport.Encrypted then
        begin
          FLastError := MakeError(lecConfiguration, 0, 'authentication',
            'SASL EXTERNAL requires TLS with a client certificate');
          Exit;
        end;
        // RFC 4513: on envoie l'identite d'autorisation du PROFIL ("dn:" ou "u:"),
        // jamais le secret. Vide, bv_val reste nil et libldap omet les credentials:
        // l'identite est alors celle du certificat client.
        cred := StringToBerval(FProfile.AuthzId);
        rc := ldap_sasl_bind(FLd, nil, 'EXTERNAL', @cred, nil, nil, @msgid);
      end;
  else
    rc := -1;
  end;
  if rc <> LDAP_SUCCESS then
  begin
    FLastError := MakeError(CategoryFromResultCode(rc), rc, 'authentication', LdDiagnostic);
    ReportStep(stAuthentication, False, False, t0, ErrorToText(FLastError));
    Exit;
  end;
  if not WaitResult(msgid, ACancel, Int64(FProfile.OperationTimeoutSec) * 1000, msg, err,
      'authentication') then
  begin
    FLastError := err;
    ReportStep(stAuthentication, False, False, t0, ErrorToText(err));
    Exit;
  end;
  try
    ParseFinalResult(msg, code, matched, diag, refs, ctrls);
    if ctrls <> nil then ldap_controls_free(ctrls);
  finally
    ldap_msgfree(msg);
  end;
  if code <> LDAP_RC_SUCCESS then
  begin
    // Une seule tentative: rejouer un bind rate, c'est verrouiller le compte plus vite.
    FLastError := MakeError(CategoryFromResultCode(code), code, 'authentication', diag);
    ReportStep(stAuthentication, False, False, t0, ErrorToText(FLastError));
    Exit;
  end;
  FTransport.Anonymous := False;
  FTransport.BoundIdentity := EffectiveBindDn(FProfile);
  ReportStep(stAuthentication, True, False, t0, 'bound');
  Result := True;
end;

function TLdapSession.Connect(const ASecret: RawByteString; ACancel: TCancelToken): Boolean;
var
  uri: AnsiString;
  rc: Integer;
  res: TResolveResult;
  t0: Int64;
  issues: TProfileIssues;
  i: Integer;
  root: TLdapEntry;
  authz: string;
  e: TLdapEntry;
begin
  Result := False;
  Close;
  FLastError := NoError;
  FTransport := Default(TTransportInfo);
  FTransport.Mode := FProfile.Transport;
  issues := ValidateProfile(FProfile);
  for i := 0 to High(issues) do
    if issues[i].Level = pilError then
    begin
      FLastError := MakeError(lecConfiguration, 0, 'profile validation', issues[i].Message);
      FState := csFailed;
      Exit;
    end;
  try
    LdapEnsureLoaded;
  except
    on E: Exception do
    begin
      FLastError := MakeError(lecConfiguration, 0, 'library loading', E.Message);
      FState := csFailed;
      Exit;
    end;
  end;
  FState := csResolving;
  t0 := MonotonicMs;
  res := ResolveHost(FProfile.Host);
  if not res.Ok then
  begin
    FLastError := MakeError(lecResolution, 0, 'name resolution', res.Error);
    ReportStep(stResolve, False, False, t0, res.Error);
    FState := csFailed;
    Exit;
  end;
  ReportStep(stResolve, True, False, t0, string.Join(', ', res.Addresses));
  if (ACancel <> nil) and ACancel.IsCancelled then
  begin
    FLastError := MakeError(lecCancelled, 0, 'connection', '');
    FState := csCancelled;
    Exit;
  end;
  FState := csConnecting;
  uri := BuildLdapUri(FProfile);
  rc := ldap_initialize(@FLd, PAnsiChar(uri));
  if rc <> LDAP_SUCCESS then
  begin
    FLastError := MakeError(lecConfiguration, rc, 'initialization', string(ldap_err2string(rc)));
    FState := csFailed;
    Exit;
  end;
  SetIntOption(LDAP_OPT_PROTOCOL_VERSION, LDAP_VERSION3);
  // Referrals jamais suivis par la bibliotheque: pas d'identifiants envoyes chez un
  // inconnu. ReferralPolicy et ReferralDestinations sont gardes dans le profil, mais
  // rien ne les applique: le comportement reel reste le plus strict.
  ldap_set_option(FLd, LDAP_OPT_REFERRALS, nil);
  ldap_set_option(FLd, LDAP_OPT_RESTART, nil);
  SetIntOption(LDAP_OPT_DEREF, FProfile.DerefAliases);
  SetTimeoutOption(LDAP_OPT_NETWORK_TIMEOUT, FProfile.ConnectTimeoutSec);
  SetTimeoutOption(LDAP_OPT_TIMEOUT, FProfile.TlsTimeoutSec);
  if FProfile.Transport <> tmPlain then
    if not AttachTlsContext then
    begin
      FState := csFailed;
      Close;
      Exit;
    end;
  t0 := MonotonicMs;
  rc := ldap_connect(FLd);
  if rc <> LDAP_SUCCESS then
  begin
    if FProfile.Transport = tmLdaps then
      FLastError := MakeError(lecNetwork, rc, 'TCP/TLS connection', LdDiagnostic)
    else
      FLastError := MakeError(lecNetwork, rc, 'TCP connection', LdDiagnostic);
    if FLastError.Diagnostic = '' then
      FLastError.Diagnostic := string(ldap_err2string(rc));
    ReportStep(stTcp, False, False, t0, ErrorToText(FLastError));
    FState := csFailed;
    Close;
    Exit;
  end;
  if FProfile.Transport = tmLdaps then
    ReportStep(stTcp, True, False, t0, 'connected (TCP and TLS handshake)')
  else
    ReportStep(stTcp, True, False, t0, 'connected');
  // Securisation et verification TLS avant le moindre secret.
  if FProfile.Transport <> tmPlain then
  begin
    if not DoSecure(ACancel) then
    begin
      FState := csFailed;
      Close;
      Exit;
    end;
  end
  else
  begin
    FTransport.Encrypted := False;
    FTransport.StatusLabel := 'LDAP - unencrypted';
    ReportStep(stSecurity, True, True, MonotonicMs, 'not encrypted (explicit profile choice)');
  end;
  SetTimeoutOption(LDAP_OPT_TIMEOUT, FProfile.OperationTimeoutSec);
  if not DoBind(ASecret, ACancel) then
  begin
    FState := csFailed;
    Close;
    Exit;
  end;
  FState := csReady;
  if (FProfile.AuthMode <> amAnonymous) and WhoAmI(ACancel, authz) then
    FTransport.AuthzId := authz;
  t0 := MonotonicMs;
  root := ReadRootDse(ACancel);
  if root <> nil then
  begin
    ReportStep(stRootDse, True, False, t0, Format('%d attributes readable', [root.AttrCount]));
    root.Free;
  end
  else
    ReportStep(stRootDse, False, False, t0, ErrorToText(FLastError));
  if FProfile.BaseDns.Count = 0 then
    ReportStep(stBaseAccess, True, True, MonotonicMs, 'no base DN configured')
  else
    for i := 0 to FProfile.BaseDns.Count - 1 do
    begin
      t0 := MonotonicMs;
      e := ReadEntry(FProfile.BaseDns[i], ['1.1'], ACancel);
      if e <> nil then
      begin
        ReportStep(stBaseAccess, True, False, t0, FProfile.BaseDns[i]);
        e.Free;
      end
      else
        ReportStep(stBaseAccess, False, False, t0, FProfile.BaseDns[i] + ': ' + ErrorToText(FLastError));
    end;
  FLastError := NoError;
  Result := True;
end;

procedure TLdapSession.Close;
var
  i: Integer;
begin
  if FLd = nil then
  begin
    if FState in [csReady, csClosing] then FState := csDisconnected;
    Exit;
  end;
  FState := csClosing;
  for i := 0 to High(FPendingMsgIds) do
    ldap_abandon_ext(FLd, FPendingMsgIds[i], nil, nil);
  FPendingMsgIds := nil;
  ldap_unbind_ext(FLd, nil, nil);
  FLd := nil;
  FState := csDisconnected;
end;

function TLdapSession.IsConnected: Boolean;
begin
  Result := (FLd <> nil) and (FState = csReady);
end;

function TLdapSession.WaitResult(AMsgId: Integer; ACancel: TCancelToken; ATimeoutMs: Int64;
  out AMsg: PLDAPMessage; out AErr: TLdapError; const AStep: string): Boolean;
var
  tv: TLdapTimeval;
  rc: Integer;
  deadline: Int64;
begin
  Result := False;
  AMsg := nil;
  AErr := NoError;
  deadline := MonotonicMs + ATimeoutMs;
  while True do
  begin
    if (ACancel <> nil) and ACancel.IsCancelled then
    begin
      ldap_abandon_ext(FLd, AMsgId, nil, nil);
      AErr := MakeError(lecCancelled, LDAP_RC_USER_CANCELLED, AStep, '');
      Exit;
    end;
    if (ATimeoutMs > 0) and (MonotonicMs >= deadline) then
    begin
      ldap_abandon_ext(FLd, AMsgId, nil, nil);
      AErr := MakeError(lecTimeout, LDAP_RC_TIMEOUT, AStep, 'no response before the time limit');
      Exit;
    end;
    tv.tv_sec := 0;
    tv.tv_usec := SESSION_POLL_MS * 1000;
    rc := ldap_result(FLd, AMsgId, LDAP_MSG_ONE, @tv, @AMsg);
    if rc = 0 then Continue;
    if rc = -1 then
    begin
      AErr := MakeError(CategoryFromResultCode(LdErrorCode), LdErrorCode, AStep, LdDiagnostic);
      if AErr.Category in [lecNone, lecOther] then
        AErr.Category := lecNetwork;
      Exit;
    end;
    Exit(True);
  end;
end;

function TLdapSession.ParseFinalResult(AMsg: PLDAPMessage; out ACode: Integer;
  out AMatched, ADiag: string; out ARefs: TStringArray; out ACtrls: PPLDAPControl): Boolean;
var
  code: cint;
  matched, diag: PAnsiChar;
  refs: PPAnsiChar;
  p: PPAnsiChar;
  rc: Integer;
begin
  ACode := LDAP_RC_OTHER;
  AMatched := '';
  ADiag := '';
  ARefs := nil;
  ACtrls := nil;
  code := 0;
  matched := nil;
  diag := nil;
  refs := nil;
  rc := ldap_parse_result(FLd, AMsg, @code, @matched, @diag, @refs, @ACtrls, 0);
  Result := rc = LDAP_SUCCESS;
  if not Result then
  begin
    ACode := rc;
    Exit;
  end;
  ACode := code;
  if matched <> nil then
  begin
    AMatched := string(matched);
    ldap_memfree(matched);
  end;
  if diag <> nil then
  begin
    ADiag := SanitizeDiagnostic(diag);
    ldap_memfree(diag);
  end;
  if refs <> nil then
  begin
    p := refs;
    while p^ <> nil do
    begin
      SetLength(ARefs, Length(ARefs) + 1);
      ARefs[High(ARefs)] := SanitizeDiagnostic(p^);
      Inc(p);
    end;
    ldap_memvfree(PPointer(refs));
  end;
end;

// Cout plancher par attribut recu, compte dans le budget: un serveur qui envoie un
// million d'attributs sans valeur n'echappe pas a la borne pour autant.
function TLdapSession.ParseEntry(AMsg: PLDAPMessage; const ARequested: array of string): TLdapEntry;
var
  ber: PBerElement;
  dn, attr: TBerval;
  vals: PBerval;
  rc, i: Integer;
  a: TLdapAttribute;
  arr: PBervalArray;
  total: Int64;
  desc: string;
begin
  Result := nil;
  ber := nil;
  FillChar(dn, SizeOf(dn), 0);
  if ldap_get_dn_ber(FLd, AMsg, @ber, @dn) <> LDAP_SUCCESS then
    Exit;
  try
    Result := TLdapEntry.Create(BervalToString(dn));
    Result.SetRequested(ARequested);
    total := dn.bv_len;
    while True do
    begin
      FillChar(attr, SizeOf(attr), 0);
      vals := nil;
      rc := ldap_get_attribute_ber(FLd, AMsg, ber, @attr, @vals);
      if rc <> LDAP_SUCCESS then
      begin
        Result.DecodeIncomplete := True;
        Break;
      end;
      if attr.bv_val = nil then Break;
      // Budget verifie avant toute copie: une description hors limite ou un reliquat
      // insuffisant arrete le decodage, signale par DecodeIncomplete, jamais en
      // silence.
      if (attr.bv_len > VALUE_MAX_BYTES) or
         (total + Int64(attr.bv_len) + ATTR_OVERHEAD_BYTES > ENTRY_MAX_BYTES) then
      begin
        Result.DecodeIncomplete := True;
        if vals <> nil then
          ber_memfree(vals);
        Break;
      end;
      desc := BervalToString(attr);
      // Compte meme pour un attribut duplique: il a ete decode et copie, le budget suit
      // ce qui a ete paye.
      Inc(total, Length(desc) + ATTR_OVERHEAD_BYTES);
      a := Result.Find(desc);
      if a = nil then
      begin
        a := Result.Add(TLdapAttribute.Create(desc));
        // Politique de secrets de la session (liste integree, alias du schema, ajouts
        // de l'utilisateur): un secret lu est mis a zero a la liberation, clones
        // compris.
        a.Sensitive := FSensitive.IsSensitive(desc);
      end;
      if vals <> nil then
      begin
        try
          arr := PBervalArray(vals);
          i := 0;
          while arr^[i].bv_val <> nil do
          begin
            // Bornes avant copie: une valeur hors limite n'est pas tronquee en silence,
            // et meme une valeur vide coute VALUE_OVERHEAD_BYTES pour que la
            // cardinalite reste bornee.
            if (arr^[i].bv_len > VALUE_MAX_BYTES) or
               (total + Int64(arr^[i].bv_len) + VALUE_OVERHEAD_BYTES > ENTRY_MAX_BYTES) then
              a.Truncated := True
            else
            begin
              a.AddValue(BervalToString(arr^[i]));
              Inc(total, Int64(arr^[i].bv_len) + VALUE_OVERHEAD_BYTES);
            end;
            Inc(i);
          end;
        finally
          ber_memfree(vals);
        end;
      end;
    end;
  except
    FreeAndNil(Result);
    if ber <> nil then
      ber_free(ber, 0);
    ber := nil;
    raise;
  end;
  if ber <> nil then
    ber_free(ber, 0);
end;

function TLdapSession.ReadRangeFragment(const ADn, ADescription: string): TLdapEntry;
begin
  Result := ReadEntry(ADn, [ADescription], FRangeCancel, False);
end;

function TLdapSession.AssembleRanges(AEntry: TLdapEntry; ACancel: TCancelToken): Boolean;
begin
  FRangeCancel := ACancel;
  try
    Result := AssembleEntryRanges(AEntry, @ReadRangeFragment);
  finally
    FRangeCancel := nil;
  end;
end;

function TLdapSession.PrepareSearch(const AReq: TSearchRequest; out AArgs: TSearchArgs;
  var ACompletion: TSearchCompletion): Boolean;
var
  flt: TFilterNode;
  ferr: string;
  i: Integer;
  wire: TStringArray;
begin
  AArgs := Default(TSearchArgs);
  flt := FilterParse(AReq.Filter, ferr);
  if flt = nil then
  begin
    FLastError := MakeError(lecConfiguration, LDAP_RC_FILTER_ERROR, 'search', 'invalid filter: ' + ferr);
    ACompletion.ResultCode := LDAP_RC_FILTER_ERROR;
    Exit(False);
  end;
  try
    AArgs.Filter := FilterToString(flt);
  finally
    flt.Free;
  end;
  case AReq.Scope of
    ssBase: AArgs.Scope := 0;
    ssOneLevel: AArgs.Scope := 1;
  else
    AArgs.Scope := 2;
  end;
  AArgs.Base := AReq.BaseDn;
  // '1.1' part en 'objectClass' et les attributs recus sont jetes: ApacheDS gere mal
  // '1.1' (pagination qui oublie son controle de reponse, code 80 a la limite de
  // taille).
  wire := WireAttributes(AReq.Attributes, AArgs.StripAttributes);
  SetLength(AArgs.Attrs, Length(wire));
  SetLength(AArgs.AttrPtrs, Length(wire) + 1);
  for i := 0 to High(wire) do
  begin
    AArgs.Attrs[i] := wire[i];
    AArgs.AttrPtrs[i] := PAnsiChar(AArgs.Attrs[i]);
  end;
  AArgs.AttrPtrs[High(AArgs.AttrPtrs)] := nil;
  Result := True;
end;

function TLdapSession.SendSearchPage(const AArgs: TSearchArgs; const AReq: TSearchRequest;
  const ACookie: RawByteString; out AMsgId: cint; var ACompletion: TSearchCompletion): Boolean;
var
  pageCtrl: PLDAPControl;
  sctrls: TControlPtrs;
  extra: TControlPtrs;
  pctrls: PPLDAPControl;
  cookieBv: TBerval;
  pattrs: PPAnsiChar;
  rc, i, n: Integer;
begin
  Result := False;
  AMsgId := -1;
  pageCtrl := nil;
  pctrls := nil;
  extra := nil;
  sctrls := nil;
  if AReq.PageSize > 0 then
  begin
    cookieBv := StringToBerval(ACookie);
    rc := ldap_create_page_control(FLd, AReq.PageSize, @cookieBv, 0, @pageCtrl);
    if rc <> LDAP_SUCCESS then
    begin
      FLastError := MakeError(lecProtocol, rc, 'search', 'cannot create the paging control');
      ACompletion.ResultCode := rc;
      Exit;
    end;
  end;
  if not CreateRequestControls(AReq.Controls, extra) then
  begin
    if pageCtrl <> nil then ldap_control_free(pageCtrl);
    FLastError := MakeError(lecProtocol, 0, 'search', 'cannot create a request control');
    ACompletion.ResultCode := LDAP_RC_OTHER;
    Exit;
  end;
  n := Length(extra);
  if pageCtrl <> nil then Inc(n);
  if n > 0 then
  begin
    SetLength(sctrls, n + 1);
    i := 0;
    if pageCtrl <> nil then
    begin
      sctrls[0] := pageCtrl;
      i := 1;
    end;
    for n := 0 to High(extra) do
    begin
      sctrls[i] := extra[n];
      Inc(i);
    end;
    sctrls[i] := nil;
    pctrls := @sctrls[0];
  end;
  if Length(AArgs.Attrs) = 0 then
    pattrs := nil
  else
    pattrs := @AArgs.AttrPtrs[0];
  try
    rc := ldap_search_ext(FLd, PAnsiChar(AArgs.Base), AArgs.Scope, PAnsiChar(AArgs.Filter), pattrs,
      Ord(AReq.TypesOnly), pctrls, nil, nil, AReq.ServerSizeLimit, @AMsgId);
  finally
    if pageCtrl <> nil then ldap_control_free(pageCtrl);
    FreeRequestControls(extra);
  end;
  if rc <> LDAP_SUCCESS then
  begin
    FLastError := MakeError(CategoryFromResultCode(rc), rc, 'search', LdDiagnostic);
    ACompletion.ResultCode := rc;
    Exit;
  end;
  SetLength(FPendingMsgIds, Length(FPendingMsgIds) + 1);
  FPendingMsgIds[High(FPendingMsgIds)] := AMsgId;
  Result := True;
end;

function TLdapSession.ReadPageCookie(ACtrls: PPLDAPControl;
  var ACompletion: TSearchCompletion; out AFound: Boolean): RawByteString;
var
  resp: PLDAPControl;
  cookieBv: TBerval;
  count: cint;
begin
  Result := '';
  AFound := False;
  if ACtrls = nil then Exit;
  resp := ldap_control_find(LDAP_CONTROL_PAGEDRESULTS, ACtrls, nil);
  if resp = nil then Exit;
  AFound := True;
  FillChar(cookieBv, SizeOf(cookieBv), 0);
  count := 0;
  if ldap_parse_pageresponse_control(FLd, resp, @count, @cookieBv) = LDAP_SUCCESS then
  begin
    Result := BervalToString(cookieBv);
    if cookieBv.bv_val <> nil then ber_memfree(cookieBv.bv_val);
  end
  else
    ACompletion.PagingAnomaly := 'unreadable paging response';
end;

function TLdapSession.Search(const AReq: TSearchRequest; AOnEntry: TSearchEntryEvent;
  ACancel: TCancelToken; out ACompletion: TSearchCompletion; AAssembleRanges: Boolean): Boolean;
var
  args: TSearchArgs;
  tracker: TPagingTracker;
  cookie: RawByteString;
  msgid: cint;
  code, pageEntries: Integer;
  msg: PLDAPMessage;
  err: TLdapError;
  matched, diag: string;
  refs: TStringArray;
  ctrls: PPLDAPControl;
  entry: TLdapEntry;
  stop, done, hasPageCtrl: Boolean;
  deadline: Int64;
  refsP: PPAnsiChar;
begin
  Result := False;
  ACompletion := Default(TSearchCompletion);
  ACompletion.HasResult := True;
  if not IsConnected then
  begin
    FLastError := MakeError(lecNetwork, LDAP_RC_SERVER_DOWN, 'search', 'not connected');
    ACompletion.ResultCode := LDAP_RC_SERVER_DOWN;
    Exit;
  end;
  if not PrepareSearch(AReq, args, ACompletion) then Exit;
  SetIntOption(LDAP_OPT_DEREF, Ord(AReq.Deref));
  tracker := TPagingTracker.Create(FSessionId, FGeneration);
  cookie := '';
  if AReq.TimeLimitSec > 0 then
    deadline := MonotonicMs + Int64(AReq.TimeLimitSec) * 1000
  else
    deadline := 0;
  try
    done := False;
    while not done do
    begin
      if not SendSearchPage(args, AReq, cookie, msgid, ACompletion) then Exit;
      pageEntries := 0;
      while True do
      begin
        if (deadline <> 0) and (MonotonicMs >= deadline) then
        begin
          ldap_abandon_ext(FLd, msgid, nil, nil);
          ForgetMsgId(msgid);
          ACompletion.TimeLimitHit := True;
          ACompletion.ResultCode := LDAP_RC_TIMELIMIT_EXCEEDED;
          Exit(True);
        end;
        if not WaitResult(msgid, ACancel, OperationTimeoutMs, msg, err, 'search') then
        begin
          ForgetMsgId(msgid);
          FLastError := err;
          if err.Category = lecCancelled then
          begin
            ACompletion.Cancelled := True;
            ACompletion.ResultCode := LDAP_RC_USER_CANCELLED;
            Exit(True);
          end;
          if err.Category = lecTimeout then
          begin
            ACompletion.TimeLimitHit := True;
            ACompletion.ResultCode := LDAP_RC_TIMELIMIT_EXCEEDED;
            Exit(True);
          end;
          ACompletion.ResultCode := err.ResultCode;
          ACompletion.DiagnosticMessage := err.Diagnostic;
          Exit;
        end;
        case ldap_msgtype(msg) of
          LDAP_RES_SEARCH_ENTRY:
            begin
              entry := ParseEntry(msg, AReq.Attributes);
              ldap_msgfree(msg);
              if entry = nil then
              begin
                Inc(ACompletion.DecodeFailures);
                Continue;
              end;
              if args.StripAttributes then
                while entry.AttrCount > 0 do
                  entry.Remove(entry.Attrs[0].Description);
              if entry.DecodeIncomplete then
                Inc(ACompletion.DecodeFailures);
              if AAssembleRanges then
                if not AssembleRanges(entry, ACancel) then
                  ACompletion.RangeIncomplete := True;
              if entry.AnyTruncated then
                Inc(ACompletion.TruncatedEntries);
              Inc(ACompletion.EntryCount);
              Inc(pageEntries);
              stop := False;
              if Assigned(AOnEntry) then
                AOnEntry(entry, stop)
              else
                entry.Free;
              if (AReq.SizeLimit > 0) and (ACompletion.EntryCount >= AReq.SizeLimit) and not stop then
              begin
                ACompletion.ClientLimitHit := True;
                stop := True;
              end;
              if stop then
              begin
                ldap_abandon_ext(FLd, msgid, nil, nil);
                ForgetMsgId(msgid);
                if not ACompletion.ClientLimitHit then
                  ACompletion.Cancelled := True;
                ACompletion.ResultCode := LDAP_RC_SUCCESS;
                Exit(True);
              end;
            end;
          LDAP_RES_SEARCH_REFERENCE:
            begin
              refsP := nil;
              if ldap_parse_reference(FLd, msg, @refsP, nil, 0) = LDAP_SUCCESS then
                if refsP <> nil then ldap_memvfree(PPointer(refsP));
              Inc(ACompletion.ContinuationsIgnored);
              ldap_msgfree(msg);
            end;
          LDAP_RES_SEARCH_RESULT:
            begin
              ForgetMsgId(msgid);
              Inc(ACompletion.PageCount);
              ParseFinalResult(msg, code, matched, diag, refs, ctrls);
              ldap_msgfree(msg);
              ACompletion.ResultCode := code;
              ACompletion.MatchedDn := matched;
              ACompletion.DiagnosticMessage := diag;
              if Length(refs) > 0 then
                Inc(ACompletion.ReferralsIgnored, Length(refs));
              if code = LDAP_RC_SIZELIMIT_EXCEEDED then
                ACompletion.SizeLimitHit := True;
              if code = LDAP_RC_TIMELIMIT_EXCEEDED then
                ACompletion.TimeLimitHit := True;
              cookie := '';
              if AReq.PageSize > 0 then
              begin
                cookie := ReadPageCookie(ctrls, ACompletion, hasPageCtrl);
                // Pas de controle de reponse alors que RFC 2696 l'exige. Fin sure
                // seulement si la page est plus courte que demandee, ou plus longue
                // (pagination ignoree). Une page pleine sans controle peut cacher une
                // troncature: couverture partielle.
                if (not hasPageCtrl) and (code = LDAP_RC_SUCCESS) and
                  (pageEntries = AReq.PageSize) and (ACompletion.PagingAnomaly = '') then
                  ACompletion.PagingAnomaly := 'paging response control missing after a full page';
              end;
              if ctrls <> nil then ldap_controls_free(ctrls);
              if (code <> LDAP_RC_SUCCESS) or (AReq.PageSize = 0) then
              begin
                done := True;
                Break;
              end;
              // Cookie repete ou page incoherente: arret. Un serveur qui tourne en rond
              // le fera sans nous.
              case tracker.OnPage(cookie, pageEntries) of
                pvDone: done := True;
                pvAnomaly:
                  begin
                    ACompletion.PagingAnomaly := tracker.Anomaly;
                    done := True;
                  end;
              end;
              if (not done) and (ACompletion.FirstPageSize = 0) and (pageEntries > 0) then
                ACompletion.FirstPageSize := pageEntries;
              Break;
            end;
        else
          ldap_msgfree(msg);
        end;
      end;
    end;
    if ACompletion.ResultCode <> LDAP_RC_SUCCESS then
      FLastError := MakeError(CategoryFromResultCode(ACompletion.ResultCode),
        ACompletion.ResultCode, 'search', ACompletion.DiagnosticMessage)
    else
      FLastError := NoError;
    Result := True;
  finally
    tracker.Free;
  end;
end;

type
  TSingleCollector = class
    Entry: TLdapEntry;
    procedure OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
    destructor Destroy; override;
  end;

procedure TSingleCollector.OnEntry(AEntry: TLdapEntry; var AStop: Boolean);
begin
  if Entry = nil then
    Entry := AEntry
  else
    AEntry.Free;
end;

destructor TSingleCollector.Destroy;
begin
  Entry.Free;
  inherited Destroy;
end;

function TLdapSession.ReadEntry(const ADn: string; const AAttrs: array of string;
  ACancel: TCancelToken; AAssembleRanges: Boolean): TLdapEntry;
var
  req: TSearchRequest;
  comp: TSearchCompletion;
  col: TSingleCollector;
  i: Integer;
begin
  Result := nil;
  req := DefaultSearchRequest;
  req.BaseDn := ADn;
  req.Scope := ssBase;
  req.Filter := '(objectClass=*)';
  req.PageSize := 0;
  req.SizeLimit := 0;
  req.TimeLimitSec := 0;
  SetLength(req.Attributes, Length(AAttrs));
  for i := 0 to High(AAttrs) do
    req.Attributes[i] := AAttrs[i];
  col := TSingleCollector.Create;
  try
    if not Search(req, @col.OnEntry, ACancel, comp, AAssembleRanges) then Exit;
    if comp.ResultCode <> LDAP_RC_SUCCESS then
    begin
      FLastError := MakeError(CategoryFromResultCode(comp.ResultCode), comp.ResultCode,
        'read', comp.DiagnosticMessage);
      Exit;
    end;
    if col.Entry = nil then
    begin
      FLastError := MakeError(lecNoSuchObject, LDAP_RC_NO_SUCH_OBJECT, 'read', 'entry not returned');
      Exit;
    end;
    Result := col.Entry;
    col.Entry := nil;
  finally
    col.Free;
  end;
end;

function TLdapSession.ReadEntry(const ADn: string; const AAttrs: array of string;
  const AControls: TRequestControlArray; ACancel: TCancelToken): TLdapEntry;
var
  req: TSearchRequest;
  comp: TSearchCompletion;
  col: TSingleCollector;
  i: Integer;
begin
  Result := nil;
  req := DefaultSearchRequest;
  req.BaseDn := ADn;
  req.Scope := ssBase;
  req.Filter := '(objectClass=*)';
  req.PageSize := 0;
  req.SizeLimit := 0;
  req.TimeLimitSec := 0;
  req.Controls := Copy(AControls, 0, Length(AControls));
  SetLength(req.Attributes, Length(AAttrs));
  for i := 0 to High(AAttrs) do
    req.Attributes[i] := AAttrs[i];
  col := TSingleCollector.Create;
  try
    if not Search(req, @col.OnEntry, ACancel, comp, False) then Exit;
    if comp.ResultCode <> LDAP_RC_SUCCESS then
    begin
      FLastError := MakeError(CategoryFromResultCode(comp.ResultCode), comp.ResultCode,
        'read', comp.DiagnosticMessage);
      Exit;
    end;
    if col.Entry = nil then
    begin
      FLastError := MakeError(lecNoSuchObject, LDAP_RC_NO_SUCH_OBJECT, 'read', 'entry not returned');
      Exit;
    end;
    Result := col.Entry;
    col.Entry := nil;
  finally
    col.Free;
  end;
end;

function TLdapSession.ReadRootDse(ACancel: TCancelToken): TLdapEntry;
begin
  Result := ReadEntry('', ['*', '+', 'namingContexts', 'defaultNamingContext',
    'rootDomainNamingContext', 'configurationNamingContext', 'schemaNamingContext',
    'subschemaSubentry', 'supportedLDAPVersion', 'supportedControl', 'supportedExtension',
    'supportedFeatures', 'supportedSASLMechanisms', 'supportedCapabilities', 'vendorName',
    'vendorVersion', 'dnsHostName', 'serverName', 'dsServiceName', 'isGlobalCatalogReady',
    'forestFunctionality', 'domainFunctionality', 'domainControllerFunctionality',
    'highestCommittedUSN', 'currentTime', 'contextCSN', 'objectClass', 'entryDN',
    'altServer', 'ldapServiceName', 'isSynchronized', 'nsds50ruv'], ACancel);
end;

function TLdapSession.WhoAmI(ACancel: TCancelToken; out AAuthzId: string): Boolean;
var
  msgid: cint;
  msg: PLDAPMessage;
  err: TLdapError;
  code: Integer;
  matched, diag: string;
  refs: TStringArray;
  ctrls: PPLDAPControl;
  data: PBerval;
  oid: PAnsiChar;
begin
  Result := False;
  AAuthzId := '';
  if FLd = nil then Exit;
  if ldap_extended_operation(FLd, LDAP_EXOP_WHO_AM_I, nil, nil, nil, @msgid) <> LDAP_SUCCESS then
    Exit;
  if not WaitResult(msgid, ACancel, OperationTimeoutMs, msg, err, 'who am i') then Exit;
  try
    ParseFinalResult(msg, code, matched, diag, refs, ctrls);
    if ctrls <> nil then ldap_controls_free(ctrls);
    if code <> LDAP_RC_SUCCESS then Exit;
    data := nil;
    oid := nil;
    if ldap_parse_extended_result(FLd, msg, @oid, @data, 0) = LDAP_SUCCESS then
    begin
      if data <> nil then
      begin
        AAuthzId := BervalToString(data^);
        ber_bvfree(data);
      end;
      if oid <> nil then ldap_memfree(oid);
      Result := True;
    end;
  finally
    ldap_msgfree(msg);
  end;
end;

// Les secrets (userPassword, unicodePwd...) ne partent jamais en clair, quel que soit
// le chemin d'ecriture. La derogation du profil ne couvre que le mot de passe de bind,
// pas les envies d'ecrire un mot de passe sur le reseau en clair.
function TLdapSession.SecretsGuard(const AStep: string; const AAttrs: array of string;
  out AResult: TWriteResult): Boolean;
var
  i: Integer;
begin
  Result := True;
  if FTransport.Encrypted then Exit;
  for i := 0 to High(AAttrs) do
    if FSensitive.IsSensitive(AAttrs[i]) then
    begin
      AResult := Default(TWriteResult);
      AResult.Error := MakeError(lecConfiguration, 0, AStep,
        'writing ' + AttrBaseName(AAttrs[i]) + ' requires an encrypted connection (StartTLS or LDAPS)');
      FLastError := AResult.Error;
      Exit(False);
    end;
end;

function TLdapSession.WriteGuard(const AStep: string; out AResult: TWriteResult): Boolean;
begin
  AResult := Default(TWriteResult);
  // Lecture seule verifiee ici aussi: l'interface n'est pas une barriere de securite.
  if FProfile.ReadOnly then
  begin
    AResult.Error := MakeError(lecReadOnly, 0, AStep, 'this profile is read-only');
    FLastError := AResult.Error;
    Exit(False);
  end;
  if not IsConnected then
  begin
    AResult.Error := MakeError(lecNetwork, LDAP_RC_SERVER_DOWN, AStep, 'not connected');
    FLastError := AResult.Error;
    Exit(False);
  end;
  Result := True;
end;

function TLdapSession.WaitWrite(AMsgId: Integer; ACancel: TCancelToken;
  const AStep: string): TWriteResult;
var
  msg: PLDAPMessage;
  err: TLdapError;
  code: Integer;
  matched, diag: string;
  refs: TStringArray;
  ctrls: PPLDAPControl;
begin
  Result := Default(TWriteResult);
  // Apres emission, annulation, coupure ou delai ne disent pas si le serveur a ecrit:
  // l'issue reste inconnue, pas "echouee".
  if not WaitResult(AMsgId, ACancel, OperationTimeoutMs, msg, err, AStep) then
  begin
    Result.Error := err;
    Result.Error.Category := lecUnknownOutcome;
    Result.Error.Action := SuggestedAction(lecUnknownOutcome);
    FLastError := Result.Error;
    Exit;
  end;
  try
    ParseFinalResult(msg, code, matched, diag, refs, ctrls);
    if ctrls <> nil then ldap_controls_free(ctrls);
  finally
    ldap_msgfree(msg);
  end;
  if code = LDAP_RC_SUCCESS then
  begin
    Result.Ok := True;
    FLastError := NoError;
  end
  else
  begin
    Result.Error := MakeError(CategoryFromResultCode(code), code, AStep, diag);
    Result.Error.MatchedDn := matched;
    FLastError := Result.Error;
  end;
end;

function TLdapSession.Modify(const ADn: string; const AMods: TLdapModArray;
  const AAssertionFilter: string; ACancel: TCancelToken): TWriteResult;
begin
  Result := Modify(ADn, AMods, AAssertionFilter, nil, ACancel);
end;

function TLdapSession.Modify(const ADn: string; const AMods: TLdapModArray;
  const AAssertionFilter: string; const AControls: TRequestControlArray;
  ACancel: TCancelToken): TWriteResult;
var
  buf: TModBuffer;
  dn, flt: AnsiString;
  msgid: cint;
  rc, i, n: Integer;
  ctrl: PLDAPControl;
  sctrls: TControlPtrs;
  extra: TControlPtrs;
  attrNames: array of string;
begin
  if not WriteGuard('modify', Result) then Exit;
  if Length(AMods) = 0 then
  begin
    Result.Ok := True;
    Exit;
  end;
  SetLength(attrNames, Length(AMods));
  for i := 0 to High(AMods) do attrNames[i] := AMods[i].Attr;
  if not SecretsGuard('modify', attrNames, Result) then Exit;
  if (ACancel <> nil) and ACancel.IsCancelled then
  begin
    Result.Error := MakeError(lecCancelled, LDAP_RC_USER_CANCELLED, 'modify', '');
    FLastError := Result.Error;
    Exit;
  end;
  buf := TModBuffer.Create;
  ctrl := nil;
  extra := nil;
  try
    buf.Build(AMods);
    dn := ADn;
    if AAssertionFilter <> '' then
    begin
      flt := AAssertionFilter;
      rc := ldap_create_assertion_control(FLd, PAnsiChar(flt), 1, @ctrl);
      if rc <> LDAP_SUCCESS then
      begin
        Result.Error := MakeError(lecProtocol, rc, 'modify', 'cannot create the assertion control');
        FLastError := Result.Error;
        Exit;
      end;
    end;
    if not CreateRequestControls(AControls, extra) then
    begin
      Result.Error := MakeError(lecProtocol, 0, 'modify', 'cannot create a request control');
      FLastError := Result.Error;
      Exit;
    end;
    SetLength(sctrls, Length(extra) + 2);
    n := 0;
    if ctrl <> nil then
    begin
      sctrls[0] := ctrl;
      n := 1;
    end;
    for i := 0 to High(extra) do
    begin
      sctrls[n] := extra[i];
      Inc(n);
    end;
    sctrls[n] := nil;
    rc := ldap_modify_ext(FLd, PAnsiChar(dn), @buf.ModPtrs[0], @sctrls[0], nil, @msgid);
    if rc <> LDAP_SUCCESS then
    begin
      Result.Error := MakeError(CategoryFromResultCode(rc), rc, 'modify', LdDiagnostic);
      FLastError := Result.Error;
      Exit;
    end;
    Result := WaitWrite(msgid, ACancel, 'modify');
    // Requete emise: un echec vient desormais du serveur, ou reste inconnu.
    Result.Sent := True;
  finally
    if ctrl <> nil then ldap_control_free(ctrl);
    FreeRequestControls(extra);
    buf.Free;
  end;
end;

function TLdapSession.Add(AEntry: TLdapEntry; ACancel: TCancelToken): TWriteResult;
var
  buf: TModBuffer;
  dn: AnsiString;
  msgid: cint;
  rc, i: Integer;
  attrNames: array of string;
begin
  if not WriteGuard('add', Result) then Exit;
  SetLength(attrNames, AEntry.AttrCount);
  for i := 0 to AEntry.AttrCount - 1 do attrNames[i] := AEntry.Attrs[i].Description;
  if not SecretsGuard('add', attrNames, Result) then Exit;
  if (ACancel <> nil) and ACancel.IsCancelled then
  begin
    Result.Error := MakeError(lecCancelled, LDAP_RC_USER_CANCELLED, 'add', '');
    FLastError := Result.Error;
    Exit;
  end;
  buf := TModBuffer.Create;
  try
    buf.BuildFromEntry(AEntry);
    dn := AEntry.Dn;
    rc := ldap_add_ext(FLd, PAnsiChar(dn), @buf.ModPtrs[0], nil, nil, @msgid);
    if rc <> LDAP_SUCCESS then
    begin
      Result.Error := MakeError(CategoryFromResultCode(rc), rc, 'add', LdDiagnostic);
      FLastError := Result.Error;
      Exit;
    end;
    Result := WaitWrite(msgid, ACancel, 'add');
    Result.Sent := True;
  finally
    buf.Free;
  end;
end;

function TLdapSession.Delete(const ADn: string; const AAssertionFilter: string;
  ACancel: TCancelToken): TWriteResult;
var
  dn, flt: AnsiString;
  msgid: cint;
  rc: Integer;
  ctrl: PLDAPControl;
  sctrls: array[0..1] of PLDAPControl;
begin
  if not WriteGuard('delete', Result) then Exit;
  if (ACancel <> nil) and ACancel.IsCancelled then
  begin
    Result.Error := MakeError(lecCancelled, LDAP_RC_USER_CANCELLED, 'delete', '');
    FLastError := Result.Error;
    Exit;
  end;
  dn := ADn;
  ctrl := nil;
  sctrls[0] := nil;
  sctrls[1] := nil;
  try
    if AAssertionFilter <> '' then
    begin
      // Precondition demandee mais impossible a construire: pas de suppression sans
      // elle.
      flt := AAssertionFilter;
      rc := ldap_create_assertion_control(FLd, PAnsiChar(flt), 1, @ctrl);
      if rc <> LDAP_SUCCESS then
      begin
        Result.Error := MakeError(lecProtocol, rc, 'delete', 'cannot create the assertion control');
        FLastError := Result.Error;
        Exit;
      end;
      sctrls[0] := ctrl;
    end;
    rc := ldap_delete_ext(FLd, PAnsiChar(dn), @sctrls[0], nil, @msgid);
    if rc <> LDAP_SUCCESS then
    begin
      Result.Error := MakeError(CategoryFromResultCode(rc), rc, 'delete', LdDiagnostic);
      FLastError := Result.Error;
      Exit;
    end;
    Result := WaitWrite(msgid, ACancel, 'delete');
    Result.Sent := True;
  finally
    if ctrl <> nil then ldap_control_free(ctrl);
  end;
end;

function TLdapSession.Rename(const ADn, ANewRdn, ANewSuperior: string; AHasNewSuperior,
  ADeleteOldRdn: Boolean; ACancel: TCancelToken): TWriteResult;
var
  dn, rdn, sup: AnsiString;
  psup: PAnsiChar;
  msgid: cint;
  rc: Integer;
begin
  if not WriteGuard('rename', Result) then Exit;
  if (ACancel <> nil) and ACancel.IsCancelled then
  begin
    Result.Error := MakeError(lecCancelled, LDAP_RC_USER_CANCELLED, 'rename', '');
    FLastError := Result.Error;
    Exit;
  end;
  dn := ADn;
  rdn := ANewRdn;
  sup := ANewSuperior;
  if AHasNewSuperior then psup := PAnsiChar(sup) else psup := nil;
  rc := ldap_rename(FLd, PAnsiChar(dn), PAnsiChar(rdn), psup, Ord(ADeleteOldRdn), nil, nil, @msgid);
  if rc <> LDAP_SUCCESS then
  begin
    Result.Error := MakeError(CategoryFromResultCode(rc), rc, 'rename', LdDiagnostic);
    FLastError := Result.Error;
    Exit;
  end;
  Result := WaitWrite(msgid, ACancel, 'rename');
  Result.Sent := True;
end;

function TLdapSession.PasswordModify(const AUserDn: string; const AOld, ANew: RawByteString;
  AHasOld, AHasNew: Boolean; ACancel: TCancelToken): TWriteResult;
var
  value: RawByteString;
  bv: TBerval;
  msgid: cint;
  rc, code: Integer;
  msg: PLDAPMessage;
  err: TLdapError;
  matched, diag: string;
  refs: TStringArray;
  ctrls: PPLDAPControl;
  data: PBerval;
  oid: PAnsiChar;
  gen, raw: RawByteString;
  hasGen: Boolean;
begin
  if not WriteGuard('password modify', Result) then Exit;
  if not FTransport.Encrypted then
  begin
    // Outils de mot de passe: canal chiffre exige, sans exception.
    Result.Error := MakeError(lecConfiguration, 0, 'password modify',
      'password operations require an encrypted connection');
    FLastError := Result.Error;
    Exit;
  end;
  if (ACancel <> nil) and ACancel.IsCancelled then
  begin
    Result.Error := MakeError(lecCancelled, LDAP_RC_USER_CANCELLED, 'password modify', '');
    FLastError := Result.Error;
    Exit;
  end;
  value := EncodePasswdModifyRequest(AUserDn, AOld, ANew, AUserDn <> '', AHasOld, AHasNew);
  bv := StringToBerval(value);
  rc := ldap_extended_operation(FLd, LDAP_EXOP_MODIFY_PASSWD, @bv, nil, nil, @msgid);
  FillChar(value[1], Length(value), 0);
  if rc <> LDAP_SUCCESS then
  begin
    Result.Error := MakeError(CategoryFromResultCode(rc), rc, 'password modify', LdDiagnostic);
    FLastError := Result.Error;
    Exit;
  end;
  Result.Sent := True;
  if not WaitResult(msgid, ACancel, OperationTimeoutMs, msg, err, 'password modify') then
  begin
    Result.Error := err;
    Result.Error.Category := lecUnknownOutcome;
    Result.Error.Action := SuggestedAction(lecUnknownOutcome);
    FLastError := Result.Error;
    Exit;
  end;
  try
    ParseFinalResult(msg, code, matched, diag, refs, ctrls);
    if ctrls <> nil then ldap_controls_free(ctrls);
    if code <> LDAP_RC_SUCCESS then
    begin
      Result.Error := MakeError(CategoryFromResultCode(code), code, 'password modify', diag);
      FLastError := Result.Error;
      Exit;
    end;
    data := nil;
    oid := nil;
    if ldap_parse_extended_result(FLd, msg, @oid, @data, 0) = LDAP_SUCCESS then
    begin
      if data <> nil then
      begin
        raw := BervalToString(data^);
        if DecodePasswdModifyResponse(raw, gen, hasGen) and hasGen then
          Result.Generated := gen;
        // Mot de passe genere: copies intermediaires et tampon natif effaces.
        WipeString(raw);
        WipeString(gen);
        if (data^.bv_val <> nil) and (data^.bv_len > 0) then
          FillChar(data^.bv_val^, data^.bv_len, 0);
        ber_bvfree(data);
      end;
      if oid <> nil then ldap_memfree(oid);
    end;
    Result.Ok := True;
    FLastError := NoError;
  finally
    ldap_msgfree(msg);
  end;
end;

function TLdapSession.Compare(const ADn, AAttr: string; const AValue: RawByteString;
  ACancel: TCancelToken; out AMatch: Boolean): Boolean;
var
  dn, attr: AnsiString;
  bv: TBerval;
  msgid: cint;
  rc, code: Integer;
  msg: PLDAPMessage;
  err: TLdapError;
  matched, diag: string;
  refs: TStringArray;
  ctrls: PPLDAPControl;
  wr: TWriteResult;
begin
  Result := False;
  AMatch := False;
  if not IsConnected then Exit;
  // Comparer userPassword, c'est envoyer le secret: meme garde que l'ecriture.
  if not SecretsGuard('compare', [AAttr], wr) then Exit;
  dn := ADn;
  attr := AAttr;
  bv := StringToBerval(AValue);
  if bv.bv_val = nil then bv.bv_val := PAnsiChar('');
  rc := ldap_compare_ext(FLd, PAnsiChar(dn), PAnsiChar(attr), @bv, nil, nil, @msgid);
  if rc <> LDAP_SUCCESS then Exit;
  if not WaitResult(msgid, ACancel, OperationTimeoutMs, msg, err, 'compare') then
  begin
    FLastError := err;
    Exit;
  end;
  try
    ParseFinalResult(msg, code, matched, diag, refs, ctrls);
    if ctrls <> nil then ldap_controls_free(ctrls);
  finally
    ldap_msgfree(msg);
  end;
  if code = LDAP_RC_COMPARE_TRUE then
  begin
    AMatch := True;
    Result := True;
  end
  else if code = LDAP_RC_COMPARE_FALSE then
    Result := True
  else
    FLastError := MakeError(CategoryFromResultCode(code), code, 'compare', diag);
end;

end.
