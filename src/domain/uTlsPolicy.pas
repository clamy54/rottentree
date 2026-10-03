// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTlsPolicy;

{$mode objfpc}{$H+}

// Verdict TLS a partir des erreurs X.509 remontees par OpenSSL. Chaque exception
// de profil couvre une liste fermee d'erreurs, tout le reste bloque. Pas
// d'exception globale: on ne lit que le profil passe, pas l'humeur du jour.

interface

uses
  SysUtils, uConnectionProfile;

const
  X509E_UNABLE_TO_GET_ISSUER_CERT = 2;
  X509E_UNABLE_TO_GET_CRL = 3;
  X509E_CERT_SIGNATURE_FAILURE = 7;
  X509E_CERT_NOT_YET_VALID = 9;
  X509E_CERT_HAS_EXPIRED = 10;
  X509E_ERROR_IN_CERT_NOT_BEFORE_FIELD = 13;
  X509E_ERROR_IN_CERT_NOT_AFTER_FIELD = 14;
  X509E_DEPTH_ZERO_SELF_SIGNED_CERT = 18;
  X509E_SELF_SIGNED_CERT_IN_CHAIN = 19;
  X509E_UNABLE_TO_GET_ISSUER_CERT_LOCALLY = 20;
  X509E_UNABLE_TO_VERIFY_LEAF_SIGNATURE = 21;
  X509E_CERT_CHAIN_TOO_LONG = 22;
  X509E_CERT_REVOKED = 23;
  X509E_INVALID_CA = 24;
  X509E_INVALID_PURPOSE = 26;
  X509E_CERT_UNTRUSTED = 27;
  X509E_CERT_REJECTED = 28;
  X509E_HOSTNAME_MISMATCH = 62;
  X509E_EMAIL_MISMATCH = 63;
  X509E_IP_ADDRESS_MISMATCH = 64;
  X509E_EE_KEY_TOO_SMALL = 66;
  X509E_CA_KEY_TOO_SMALL = 67;
  X509E_CA_MD_TOO_WEAK = 68;

type
  TTlsCheck = (tcChain, tcDates, tcHostname, tcPurpose, tcSignature, tcFormat,
    tcAlgorithm, tcPin, tcRevocation, tcProtocol, tcOther);
  TTlsChecks = set of TTlsCheck;

  TTlsIssue = record
    Code: Integer;
    Depth: Integer;
    Check: TTlsCheck;
    Text: string;
  end;
  TTlsIssues = array of TTlsIssue;

  TRevocationState = (rvsNotChecked, rvsNotEstablished, rvsVerified);

  TTlsDecision = record
    Accepted: Boolean;
    Waived: TTlsChecks;
    Blocking: TTlsIssues;
    Revocation: TRevocationState;
    StatusLabel: string;
    Summary: string;
  end;

function ClassifyX509Error(ACode: Integer): TTlsCheck;
function CheckCoveredBy(const AExceptions: TTlsExceptions; ACheck: TTlsCheck): Boolean;
function DecideTls(const AExceptions: TTlsExceptions; ARevocation: TRevocationPolicy;
  const AIssues: TTlsIssues; APinsConfigured, APinMatched: Boolean;
  AProtocolVersion: Integer): TTlsDecision;
// Une exception active interdit le libelle strict: pas de cadenas peint a la main.
function TlsStatusLabel(const AExceptions: TTlsExceptions): string;
function TlsCheckName(ACheck: TTlsCheck): string;
function ProtocolVersionName(AVersion: Integer): string;
function NormalizeFingerprint(const S: string): string;

const
  TLS1_2_VERSION = $0303;
  TLS1_3_VERSION = $0304;

implementation

function ClassifyX509Error(ACode: Integer): TTlsCheck;
begin
  case ACode of
    X509E_UNABLE_TO_GET_ISSUER_CERT, X509E_DEPTH_ZERO_SELF_SIGNED_CERT,
    X509E_SELF_SIGNED_CERT_IN_CHAIN, X509E_UNABLE_TO_GET_ISSUER_CERT_LOCALLY,
    X509E_UNABLE_TO_VERIFY_LEAF_SIGNATURE, X509E_CERT_UNTRUSTED:
      Result := tcChain;
    X509E_CERT_NOT_YET_VALID, X509E_CERT_HAS_EXPIRED:
      Result := tcDates;
    X509E_HOSTNAME_MISMATCH, X509E_IP_ADDRESS_MISMATCH, X509E_EMAIL_MISMATCH:
      Result := tcHostname;
    X509E_INVALID_PURPOSE, X509E_CERT_REJECTED:
      Result := tcPurpose;
    X509E_CERT_SIGNATURE_FAILURE:
      Result := tcSignature;
    X509E_ERROR_IN_CERT_NOT_BEFORE_FIELD, X509E_ERROR_IN_CERT_NOT_AFTER_FIELD:
      Result := tcFormat;
    X509E_EE_KEY_TOO_SMALL, X509E_CA_KEY_TOO_SMALL, X509E_CA_MD_TOO_WEAK:
      Result := tcAlgorithm;
    X509E_CERT_REVOKED, X509E_UNABLE_TO_GET_CRL:
      Result := tcRevocation;
  else
    Result := tcOther;
  end;
end;

function CheckCoveredBy(const AExceptions: TTlsExceptions; ACheck: TTlsCheck): Boolean;
begin
  case ACheck of
    tcChain: Result := not AExceptions.VerifyCAChain;
    tcDates: Result := not AExceptions.VerifyValidityDates;
    tcHostname: Result := not AExceptions.VerifyHostname;
  else
    Result := False;
  end;
end;

function TlsCheckName(ACheck: TTlsCheck): string;
begin
  case ACheck of
    tcChain: Result := 'certificate chain';
    tcDates: Result := 'validity dates';
    tcHostname: Result := 'host name';
    tcPurpose: Result := 'certificate purpose';
    tcSignature: Result := 'certificate signature';
    tcFormat: Result := 'certificate format';
    tcAlgorithm: Result := 'key or algorithm strength';
    tcPin: Result := 'pinned fingerprint';
    tcRevocation: Result := 'revocation';
    tcProtocol: Result := 'protocol version';
  else
    Result := 'certificate verification';
  end;
end;

function ProtocolVersionName(AVersion: Integer): string;
begin
  case AVersion of
    $0300: Result := 'SSLv3';
    $0301: Result := 'TLS 1.0';
    $0302: Result := 'TLS 1.1';
    TLS1_2_VERSION: Result := 'TLS 1.2';
    TLS1_3_VERSION: Result := 'TLS 1.3';
  else
    Result := Format('unknown (0x%.4x)', [AVersion]);
  end;
end;

function TlsStatusLabel(const AExceptions: TTlsExceptions): string;
var
  parts: string;
begin
  if TlsExceptionsAreStrict(AExceptions) then
    Exit('TLS - verified');
  parts := '';
  if not AExceptions.VerifyCAChain then parts := 'CA not verified';
  if not AExceptions.VerifyValidityDates then
  begin
    if parts <> '' then parts := parts + ', ';
    parts := parts + 'dates not verified';
  end;
  if not AExceptions.VerifyHostname then
  begin
    if parts <> '' then parts := parts + ', ';
    parts := parts + 'name not verified';
  end;
  Result := 'TLS - ' + parts;
end;

procedure AddBlocking(var D: TTlsDecision; const AIssue: TTlsIssue);
begin
  SetLength(D.Blocking, Length(D.Blocking) + 1);
  D.Blocking[High(D.Blocking)] := AIssue;
end;

function MakeIssue(ACheck: TTlsCheck; const AText: string): TTlsIssue;
begin
  Result.Code := 0;
  Result.Depth := 0;
  Result.Check := ACheck;
  Result.Text := AText;
end;

function DecideTls(const AExceptions: TTlsExceptions; ARevocation: TRevocationPolicy;
  const AIssues: TTlsIssues; APinsConfigured, APinMatched: Boolean;
  AProtocolVersion: Integer): TTlsDecision;
var
  i: Integer;
  c: TTlsCheck;
begin
  Result.Accepted := False;
  Result.Waived := [];
  Result.Blocking := nil;
  Result.Revocation := rvsNotChecked;
  Result.StatusLabel := TlsStatusLabel(AExceptions);
  Result.Summary := '';
  if (ARevocation = rpRequired) and not AExceptions.VerifyCAChain then
    AddBlocking(Result, MakeIssue(tcRevocation,
      'inconsistent profile: revocation required with CA verification disabled'));
  if AProtocolVersion < TLS1_2_VERSION then
    AddBlocking(Result, MakeIssue(tcProtocol,
      'negotiated protocol ' + ProtocolVersionName(AProtocolVersion) + ' is not allowed'));
  for i := 0 to High(AIssues) do
  begin
    c := AIssues[i].Check;
    if CheckCoveredBy(AExceptions, c) then
      Include(Result.Waived, c)
    else
      AddBlocking(Result, AIssues[i]);
  end;
  if APinsConfigured and not APinMatched then
    AddBlocking(Result, MakeIssue(tcPin,
      'the server certificate does not match the pinned fingerprint'));
  case ARevocation of
    rpNotChecked: Result.Revocation := rvsNotChecked;
    rpChecked: Result.Revocation := rvsNotEstablished;
    rpRequired:
      begin
        // Le backend ne fournit aucune preuve de revocation. On ne pretend donc jamais
        // l'avoir verifiee, et l'exiger bloque.
        Result.Revocation := rvsNotEstablished;
        AddBlocking(Result, MakeIssue(tcRevocation,
          'revocation is required but its status could not be established'));
      end;
  end;
  Result.Accepted := Length(Result.Blocking) = 0;
  if Result.Accepted then
  begin
    if Result.Waived = [] then
      Result.Summary := 'Certificate verified.'
    else
    begin
      Result.Summary := 'Accepted under profile exceptions:';
      for c := Low(c) to High(c) do
        if c in Result.Waived then
          Result.Summary := Result.Summary + ' ' + TlsCheckName(c) + ';';
    end;
  end
  else
    Result.Summary := 'Refused: ' + TlsCheckName(Result.Blocking[0].Check) + ' - ' +
      Result.Blocking[0].Text;
end;

function NormalizeFingerprint(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    if S[i] in ['0'..'9', 'a'..'f'] then
      Result := Result + S[i]
    else if S[i] in ['A'..'F'] then
      Result := Result + Chr(Ord(S[i]) + 32);
end;

end.
