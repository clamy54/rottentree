// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTlsVerify;

{$mode objfpc}{$H+}

// Verification de la session TLS negociee par libldap, AVANT toute authentification.
// libldap negocie avec notre contexte OpenSSL sans rien verifier; on refait tout via
// X509_verify_cert (chaine, dates, usage serveur, nom ou IP), puis le profil tranche.

interface

uses
  SysUtils, uOpenSslApi, uConnectionProfile, uTlsPolicy, uSessionModel;

// TLS 1.2 minimum, ni renegociation ni compression. Verification integree coupee:
// VerifyTlsSession la refait, en entier.
function CreateClientSslContext(const AClientCertPath, AClientKeyPath: string;
  out AError: string): Pointer;

function InspectSslSession(ASsl: PSSL): TTlsSessionInfo;

function VerifyTlsSession(ASsl: PSSL; AProfile: TConnectionProfile;
  const AHostName: string): TTlsVerification;

function VerifyChain(const AChainDer: array of RawByteString; AProfile: TConnectionProfile;
  const AHostName: string; AProtocolVersion: Integer): TTlsVerification;

implementation

uses
  ctypes, uCertificates, uRtBytes;

threadvar
  GCollected: TTlsIssues;
  GCallbackFailed: Boolean;

function VerifyCallback(ok: cint; ctx: PX509_STORE_CTX): cint; cdecl;
var
  err: cint;
  issue: TTlsIssue;
  i: Integer;
begin
  // Continuer: toutes les erreurs sont relevees, la politique tranche ensuite.
  Result := 1;
  try
    if ok = 0 then
    begin
      err := X509_STORE_CTX_get_error(ctx);
      issue.Code := err;
      issue.Depth := X509_STORE_CTX_get_error_depth(ctx);
      issue.Check := ClassifyX509Error(err);
      issue.Text := string(X509_verify_cert_error_string(err));
      for i := 0 to High(GCollected) do
        if (GCollected[i].Code = issue.Code) and (GCollected[i].Depth = issue.Depth) then
          Exit;
      SetLength(GCollected, Length(GCollected) + 1);
      GCollected[High(GCollected)] := issue;
    end;
  except
    // Une exception Pascal ne traverse jamais un cadre C d'OpenSSL. L'erreur est notee
    // et ressort apres coup: echec ferme.
    GCallbackFailed := True;
    Result := 0;
  end;
end;

function CreateClientSslContext(const AClientCertPath, AClientKeyPath: string;
  out AError: string): Pointer;
begin
  OpenSslEnsureLoaded;
  AError := '';
  Result := SSL_CTX_new(TLS_client_method());
  if Result = nil then
  begin
    AError := 'cannot create a TLS context';
    Exit;
  end;
  SSL_CTX_ctrl(Result, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil);
  SSL_CTX_set_options(Result, SSL_OP_NO_RENEGOTIATION or SSL_OP_NO_COMPRESSION);
  SSL_CTX_set_verify(Result, SSL_VERIFY_NONE, nil);
  if (AClientCertPath <> '') or (AClientKeyPath <> '') then
  begin
    if (SSL_CTX_use_certificate_file(Result, PAnsiChar(AnsiString(AClientCertPath)), SSL_FILETYPE_PEM) <> 1) or
       (SSL_CTX_use_PrivateKey_file(Result, PAnsiChar(AnsiString(AClientKeyPath)), SSL_FILETYPE_PEM) <> 1) or
       (SSL_CTX_check_private_key(Result) <> 1) then
    begin
      AError := 'cannot load the client certificate or its private key';
      SSL_CTX_free(Result);
      Result := nil;
    end;
  end;
  ERR_clear_error;
end;

function InspectSslSession(ASsl: PSSL): TTlsSessionInfo;
var
  sk: POPENSSL_STACK;
  i: Integer;
  cipher: Pointer;
begin
  Result := Default(TTlsSessionInfo);
  if ASsl = nil then Exit;
  Result.Established := True;
  Result.ProtocolVersion := SSL_version(ASsl);
  Result.ProtocolName := ProtocolVersionName(Result.ProtocolVersion);
  cipher := SSL_get_current_cipher(ASsl);
  if cipher <> nil then
    Result.Cipher := string(SSL_CIPHER_get_name(cipher));
  // Cote client, la chaine rendue par OpenSSL commence par le certificat du serveur.
  sk := SSL_get_peer_cert_chain(ASsl);
  if sk <> nil then
    for i := 0 to OPENSSL_sk_num(sk) - 1 do
    begin
      SetLength(Result.PeerChainDer, Length(Result.PeerChainDer) + 1);
      Result.PeerChainDer[High(Result.PeerChainDer)] := X509ToDer(OPENSSL_sk_value(sk, i));
    end;
  if Length(Result.PeerChainDer) > 0 then
    Result.LeafSha256 := CertSha256(Result.PeerChainDer[0]);
end;

function StripBrackets(const AHost: string): string;
begin
  Result := AHost;
  if (Length(Result) > 2) and (Result[1] = '[') and (Result[Length(Result)] = ']') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function VerifyChain(const AChainDer: array of RawByteString; AProfile: TConnectionProfile;
  const AHostName: string; AProtocolVersion: Integer): TTlsVerification;
var
  store: PX509_STORE;
  ctx: PX509_STORE_CTX;
  leaf, x: PX509;
  untrusted: POPENSSL_STACK;
  param: PX509_VERIFY_PARAM;
  extra: array of RawByteString;
  i: Integer;
  host: string;
  pinMatched: Boolean;
  flags: culong;
  issue: TTlsIssue;
  setupOk: Boolean;
begin
  Result := Default(TTlsVerification);
  OpenSslEnsureLoaded;
  if Length(AChainDer) = 0 then
  begin
    issue.Code := -1;
    issue.Depth := 0;
    issue.Check := tcFormat;
    issue.Text := 'the server presented no certificate';
    Result.Issues := [issue];
    Result.Decision := DecideTls(AProfile.Tls, AProfile.Revocation, Result.Issues,
      AProfile.PinnedSha256.Count > 0, False, AProtocolVersion);
    Exit;
  end;
  SetLength(extra, AProfile.TrustedCaDer.Count);
  for i := 0 to AProfile.TrustedCaDer.Count - 1 do
    HexDecode(AProfile.TrustedCaDer[i], extra[i]);
  store := BuildTrustStore(True, extra, Result.TrustAnchorsLoaded);
  ctx := nil;
  leaf := nil;
  untrusted := nil;
  try
    leaf := X509FromDer(AChainDer[0]);
    if leaf = nil then
    begin
      issue.Code := -1;
      issue.Depth := 0;
      issue.Check := tcFormat;
      issue.Text := 'the server certificate cannot be parsed';
      Result.Issues := [issue];
    end
    else
    begin
      // Chaque allocation et chaque parametre verifies: une penurie memoire refuse le
      // TLS proprement, au lieu d'une violation d'acces ou d'une verification de nom
      // muette.
      setupOk := True;
      untrusted := OPENSSL_sk_new_null();
      if untrusted = nil then
        setupOk := False
      else
        for i := 1 to High(AChainDer) do
        begin
          x := X509FromDer(AChainDer[i]);
          if x <> nil then
            OPENSSL_sk_push(untrusted, x);
        end;
      ctx := nil;
      if setupOk then
      begin
        ctx := X509_STORE_CTX_new();
        setupOk := (ctx <> nil) and (X509_STORE_CTX_init(ctx, store, leaf, untrusted) = 1);
      end;
      param := nil;
      if setupOk then
      begin
        param := X509_STORE_CTX_get0_param(ctx);
        setupOk := param <> nil;
      end;
      if setupOk then
        setupOk := X509_VERIFY_PARAM_set_purpose(param, X509_PURPOSE_SSL_SERVER) = 1;
      if setupOk then
      begin
        host := StripBrackets(AHostName);
        // Un echec de set1_ip_asc/set1_host laisserait le nom NON verifie: refus plutot
        // que de continuer a l'aveugle.
        if IsIpLiteral(host) then
          setupOk := X509_VERIFY_PARAM_set1_ip_asc(param, PAnsiChar(AnsiString(host))) = 1
        else
        begin
          X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
          setupOk := X509_VERIFY_PARAM_set1_host(param, PAnsiChar(AnsiString(host)),
            Length(host)) = 1;
        end;
      end;
      if not setupOk then
      begin
        issue.Code := -1;
        issue.Depth := 0;
        issue.Check := tcOther;
        issue.Text := 'internal certificate verification error (setup failed)';
        Result.Issues := [issue];
      end
      else
      begin
        flags := 0;
        X509_VERIFY_PARAM_set_flags(param, flags);
        GCollected := nil;
        GCallbackFailed := False;
        X509_STORE_CTX_set_verify_cb(ctx, @VerifyCallback);
        if (X509_verify_cert(ctx) < 0) or GCallbackFailed then
        begin
          issue.Code := -1;
          issue.Depth := 0;
          issue.Check := tcOther;
          issue.Text := 'internal certificate verification error';
          SetLength(GCollected, Length(GCollected) + 1);
          GCollected[High(GCollected)] := issue;
        end;
        Result.Issues := GCollected;
        GCollected := nil;
      end;
    end;
  finally
    if ctx <> nil then X509_STORE_CTX_free(ctx);
    if untrusted <> nil then OPENSSL_sk_pop_free(untrusted, Pointer(X509_free));
    if leaf <> nil then X509_free(leaf);
    X509_STORE_free(store);
    ERR_clear_error;
  end;
  pinMatched := False;
  for i := 0 to AProfile.PinnedSha256.Count - 1 do
    if NormalizeFingerprint(AProfile.PinnedSha256[i]) = CertSha256(AChainDer[0]) then
      pinMatched := True;
  Result.Decision := DecideTls(AProfile.Tls, AProfile.Revocation, Result.Issues,
    AProfile.PinnedSha256.Count > 0, pinMatched, AProtocolVersion);
end;

function VerifyTlsSession(ASsl: PSSL; AProfile: TConnectionProfile;
  const AHostName: string): TTlsVerification;
var
  info: TTlsSessionInfo;
begin
  info := InspectSslSession(ASsl);
  Result := VerifyChain(info.PeerChainDer, AProfile, AHostName, info.ProtocolVersion);
  Result.Session := info;
end;

end.
