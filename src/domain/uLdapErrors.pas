// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdapErrors;

{$mode objfpc}{$H+}

// Erreurs structurees: categorie, code, etape, diagnostic expurge et action possible. Une
// annulation n'est pas un mauvais mot de passe, et une ecriture sans reponse n'est ni
// reussie ni ratee.

interface

uses
  SysUtils;

type
  TLdapErrorCategory = (
    lecNone,
    lecConfiguration,
    lecResolution,
    lecNetwork,
    lecTls,
    lecAuthentication,
    lecAccessDenied,
    lecNoSuchObject,
    lecUnavailable,
    lecRefused,
    lecTimeout,
    lecProtocol,
    lecConstraint,
    lecAssertionFailed,
    lecCancelled,
    lecUnknownOutcome,
    lecReadOnly,
    lecOther
  );

  TLdapError = record
    Category: TLdapErrorCategory;
    ResultCode: Integer;
    Step: string;
    Diagnostic: string; // deja expurge
    MatchedDn: string;
    Target: string;
    Action: string;
  end;

function NoError: TLdapError;
function MakeError(ACategory: TLdapErrorCategory; ACode: Integer; const AStep,
  ADiagnostic: string): TLdapError;
function CategoryFromResultCode(ACode: Integer): TLdapErrorCategory;
function CategoryName(ACategory: TLdapErrorCategory): string;
function SuggestedAction(ACategory: TLdapErrorCategory): string;
function ErrorToText(const E: TLdapError): string;
// Diagnostic serveur assaini: caracteres de controle retires, longueur bornee.
// Un serveur hostile n'ecrit pas ce qu'il veut dans nos journaux.
function SanitizeDiagnostic(const S: RawByteString): string;
// Certains serveurs recrachent la valeur soumise dans leur diagnostic: elle est masquee
// avant affichage ou journal. Forme exacte seulement. Sous 2 octets on laisse: masquer
// chaque 'a' du texte ne protegerait personne.
function MaskValueOccurrences(const AText: string;
  const AValues: array of RawByteString): string;

implementation

uses
  uSearchModel;

function NoError: TLdapError;
begin
  Result := Default(TLdapError);
  Result.Category := lecNone;
end;

function MakeError(ACategory: TLdapErrorCategory; ACode: Integer; const AStep,
  ADiagnostic: string): TLdapError;
begin
  Result := Default(TLdapError);
  Result.Category := ACategory;
  Result.ResultCode := ACode;
  Result.Step := AStep;
  Result.Diagnostic := SanitizeDiagnostic(ADiagnostic);
  Result.Action := SuggestedAction(ACategory);
end;

function CategoryFromResultCode(ACode: Integer): TLdapErrorCategory;
begin
  case ACode of
    LDAP_RC_SUCCESS, LDAP_RC_COMPARE_FALSE, LDAP_RC_COMPARE_TRUE: Result := lecNone;
    LDAP_RC_INVALID_CREDENTIALS, LDAP_RC_INAPPROPRIATE_AUTH,
    LDAP_RC_AUTH_METHOD_NOT_SUPPORTED, LDAP_RC_STRONGER_AUTH_REQUIRED,
    LDAP_RC_CONFIDENTIALITY_REQUIRED, LDAP_RC_AUTH_UNKNOWN:
      Result := lecAuthentication;
    LDAP_RC_INSUFFICIENT_ACCESS: Result := lecAccessDenied;
    LDAP_RC_NO_SUCH_OBJECT: Result := lecNoSuchObject;
    LDAP_RC_BUSY, LDAP_RC_UNAVAILABLE, LDAP_RC_ADMINLIMIT_EXCEEDED:
      Result := lecUnavailable;
    // Regle du serveur, pas une panne: reessayer ne change rien (AD refuse par exemple un
    // renommage qui garde l'ancien RDN). L'acharnement n'a jamais convaincu un controleur
    // de domaine.
    LDAP_RC_UNWILLING_TO_PERFORM: Result := lecRefused;
    LDAP_RC_TIMELIMIT_EXCEEDED, LDAP_RC_TIMEOUT: Result := lecTimeout;
    LDAP_RC_PROTOCOL_ERROR, LDAP_RC_DECODING_ERROR, LDAP_RC_ENCODING_ERROR,
    LDAP_RC_UNAVAILABLE_CRITICAL_EXTENSION, LDAP_RC_NOT_SUPPORTED:
      Result := lecProtocol;
    LDAP_RC_NO_SUCH_ATTRIBUTE, LDAP_RC_UNDEFINED_TYPE, LDAP_RC_INAPPROPRIATE_MATCHING,
    LDAP_RC_CONSTRAINT_VIOLATION, LDAP_RC_TYPE_OR_VALUE_EXISTS, LDAP_RC_INVALID_SYNTAX,
    LDAP_RC_INVALID_DN_SYNTAX, LDAP_RC_NAMING_VIOLATION, LDAP_RC_OBJECT_CLASS_VIOLATION,
    LDAP_RC_NOT_ALLOWED_ON_NONLEAF, LDAP_RC_NOT_ALLOWED_ON_RDN, LDAP_RC_ALREADY_EXISTS,
    LDAP_RC_NO_OBJECT_CLASS_MODS, LDAP_RC_AFFECTS_MULTIPLE_DSAS, LDAP_RC_ALIAS_PROBLEM:
      Result := lecConstraint;
    LDAP_RC_ASSERTION_FAILED: Result := lecAssertionFailed;
    LDAP_RC_SERVER_DOWN, LDAP_RC_CONNECT_ERROR: Result := lecNetwork;
    LDAP_RC_USER_CANCELLED, LDAP_RC_CANCELED: Result := lecCancelled;
  else
    Result := lecOther;
  end;
end;

function CategoryName(ACategory: TLdapErrorCategory): string;
begin
  case ACategory of
    lecNone: Result := 'no error';
    lecConfiguration: Result := 'configuration';
    lecResolution: Result := 'name resolution';
    lecNetwork: Result := 'network';
    lecTls: Result := 'TLS';
    lecAuthentication: Result := 'authentication';
    lecAccessDenied: Result := 'access denied';
    lecNoSuchObject: Result := 'no such object';
    lecUnavailable: Result := 'server unavailable';
    lecRefused: Result := 'refused by the server';
    lecTimeout: Result := 'timeout';
    lecProtocol: Result := 'protocol';
    lecConstraint: Result := 'constraint';
    lecAssertionFailed: Result := 'concurrent modification';
    lecCancelled: Result := 'cancelled';
    lecUnknownOutcome: Result := 'unknown outcome';
    lecReadOnly: Result := 'read-only profile';
  else
    Result := 'error';
  end;
end;

function SuggestedAction(ACategory: TLdapErrorCategory): string;
begin
  case ACategory of
    lecConfiguration: Result := 'Fix the connection profile.';
    lecResolution: Result := 'Check the host name and DNS.';
    lecNetwork: Result := 'Check the host, port, firewall and transport mode.';
    lecTls: Result := 'Inspect the certificate and the TLS settings of this profile.';
    lecAuthentication: Result := 'Check the identity and secret. No automatic retry was made.';
    lecAccessDenied: Result := 'The server refused this operation for the bound identity.';
    lecNoSuchObject: Result := 'Check the DN; the entry may have moved or be hidden.';
    lecUnavailable: Result := 'Retry later or contact the directory administrator.';
    lecRefused: Result := 'The server declined this operation; its message gives the reason. Retrying will not help.';
    lecTimeout: Result := 'Narrow the request or raise the time limit.';
    lecAssertionFailed: Result := 'The entry changed on the server. Compare before retrying.';
    lecUnknownOutcome: Result := 'Read the entry again before any retry: the write may have been applied.';
    lecReadOnly: Result := 'Disable read-only mode for this profile to write.';
  else
    Result := '';
  end;
end;

function ErrorToText(const E: TLdapError): string;
begin
  if E.Category = lecNone then Exit('');
  Result := CategoryName(E.Category);
  if E.Step <> '' then Result := Result + ' during ' + E.Step;
  if E.ResultCode <> 0 then
    Result := Result + ' (' + ResultCodeName(E.ResultCode) + ')';
  if E.Diagnostic <> '' then
    Result := Result + ': ' + E.Diagnostic;
end;

function SanitizeDiagnostic(const S: RawByteString): string;
const
  MaxChars = 1024;
var
  i: Integer;
begin
  Result := Copy(S, 1, MaxChars);
  for i := 1 to Length(Result) do
    if (Byte(Result[i]) < 32) or (Byte(Result[i]) = 127) then
      Result[i] := ' ';
  if Length(S) > MaxChars then
    Result := Result + ' [truncated]';
end;

function MaskValueOccurrences(const AText: string;
  const AValues: array of RawByteString): string;
var
  i: Integer;
begin
  Result := AText;
  if Result = '' then Exit;
  for i := 0 to High(AValues) do
    if Length(AValues[i]) >= 2 then
      Result := StringReplace(Result, string(AValues[i]), '[masked]', [rfReplaceAll]);
end;

end.
