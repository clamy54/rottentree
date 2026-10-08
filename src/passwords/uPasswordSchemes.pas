// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPasswordSchemes;

{$mode objfpc}{$H+}

// Registre des formats userPassword: chacun sait se reconnaitre, s'analyser, se
// verifier et parfois se generer. Une empreinte ne se dechiffre pas, et rien ici ne
// convertit un format en un autre. Le premier format qui reconnait une valeur
// l'emporte.

interface

uses
  SysUtils, Classes, Contnrs, uCancel, uPwdCore;

const
  DEFAULT_GENERATOR_ID = 'CRYPT-SHA512';

type
  TPasswordRegistry = class
  private
    FSchemes: TObjectList;
    FGenerators: TObjectList;
    function GetScheme(AIndex: Integer): TPasswordScheme;
  public
    constructor Create;
    destructor Destroy; override;
    function Identify(const AValue: RawByteString): TPasswordScheme;
    function Inspect(const AValue: RawByteString): TPwdInfo;
    function Verify(const AValue, APassword: RawByteString; out ADetail: string): TPwdStatus;
    function SchemeCount: Integer;
    function FindById(const AId: string): TPasswordScheme;
    function GeneratorIds(AServer: TPwdServer): TStringArray;
    property Schemes[AIndex: Integer]: TPasswordScheme read GetScheme;
  end;

  TPwdValueResult = record
    Status: TPwdStatus;
    SchemeId: string;
    Detail: string;
  end;

  TPwdMultiOutcome = (
    pmoMatch,
    pmoNoMatchAllVerified,
    pmoNoMatchIncomplete,
    pmoNothingVerifiable,
    pmoNoValues
  );

  TPwdMultiResult = record
    Outcome: TPwdMultiOutcome;
    Values: array of TPwdValueResult;
  end;

function PasswordRegistry: TPasswordRegistry;
function VerifyPasswordValues(const AValues: array of RawByteString;
  const APassword: RawByteString; ACancel: TCancelToken = nil): TPwdMultiResult;
function PwdMultiOutcomeText(AOutcome: TPwdMultiOutcome): string;

// Active Directory veut unicodePwd entre guillemets et en UTF-16LE. ASecretUtf8 doit
// etre de l'UTF-8 valide; aucune normalisation Unicode.
function EncodeUnicodePwd(const ASecretUtf8: RawByteString): RawByteString;

implementation

uses
  uRtBytes, uPwdDigest, uPwdCrypt, uPwdPbkdf2, uPwdArgon2, uPwdReference;

function PwdMultiOutcomeText(AOutcome: TPwdMultiOutcome): string;
begin
  case AOutcome of
    pmoMatch: Result := 'The password matches at least one value.';
    pmoNoMatchAllVerified: Result := 'No verifiable value matches the password.';
    pmoNoMatchIncomplete:
      Result := 'No match among verifiable values; some values could not be verified.';
    pmoNothingVerifiable: Result := 'None of the values can be verified locally.';
  else
    Result := 'No value to verify.';
  end;
end;

constructor TPasswordRegistry.Create;

  procedure Add(S: TPasswordScheme);
  begin
    FSchemes.Add(S);
  end;

  procedure AddReferences(const APrefixes: array of string; const AName, ANote: string;
    AStorage: TPwdStorageLevel);
  var
    i: Integer;
  begin
    for i := 0 to High(APrefixes) do
      Add(TReferenceScheme.Create(UpperCase(Copy(APrefixes[i], 2, Length(APrefixes[i]) - 2)),
        APrefixes[i], AName + ' ' + APrefixes[i], ANote, prUnsupported, AStorage));
  end;

  procedure AddDelegations(AList: TObjectList);
  begin
    AList.Add(TDelegationScheme.Create('SASL', '{SASL}', '{SASL} pass-through authentication',
      'not a hash: the server delegates authentication to SASL', 'SASL identity',
      'Stores {SASL}identity: the server hands the bind to its SASL stack (saslauthd, ' +
      'Kerberos...). The identity is usually user@REALM; nothing is hashed.'));
    AList.Add(TDelegationScheme.Create('KERBEROS', '{KERBEROS}',
      '{KERBEROS} pass-through authentication',
      'not a hash: the server checks the password against this Kerberos principal',
      'Kerberos principal',
      'Stores {KERBEROS}principal: the server checks the password against the KDC. Needs the ' +
      'contrib kerberos module of OpenLDAP, long deprecated in favour of {SASL}.'));
    AList.Add(TDelegationScheme.Create('UNIX', '{UNIX}', '{UNIX} pass-through authentication',
      'not a hash: the server checks the password against its own system account of that name',
      'System account',
      'Stores {UNIX}account: the server checks the password against the system account of ' +
      'that name on its own host. Needs an OpenLDAP built with crypt support.'));
    AList.Add(TDelegationScheme.Create('RADIUS', '{RADIUS}', '{RADIUS} pass-through authentication',
      'not a hash: the server delegates authentication to RADIUS', 'RADIUS user name',
      'Stores {RADIUS}user: the server asks a RADIUS server to check the password. Needs the ' +
      'contrib radius module of OpenLDAP.'));
    AList.Add(TDelegationScheme.Create('K5KEY', '{K5KEY}', '{K5KEY} Kerberos keys of the entry',
      'not a hash: the server checks the password against the krb5Key values of the entry', '',
      'Stores {K5KEY} alone, nothing to type: the server checks the password against the ' +
      'Kerberos keys (krb5Key) the entry already holds. Needs the smbk5pwd overlay.'));
  end;

  procedure AddTaggedCleartext(AList: TObjectList);
  const
    READERS = 'No LDAP server binds against this prefix: it is for software that reads ' +
      'userPassword itself (Dovecot, FreeRADIUS). Anyone who can read the entry reads the password.';
  begin
    AList.Add(TTaggedCleartextScheme.Create('CLEAR', '{CLEAR}', [pws389Ds, pwsOther],
      'Understood by 389 DS, Sun/Oracle DSEE and OpenDJ. Stored as typed behind the prefix: ' +
      'anyone who can read the entry reads the password.'));
    AList.Add(TTaggedCleartextScheme.Create('BASE64', '{BASE64}', [pwsOther],
      'Understood by OpenDJ. Base64 is an encoding, not a hash: anyone who can read the entry ' +
      'reads the password.', True));
    AList.Add(TTaggedCleartextScheme.Create('PLAIN', '{PLAIN}', [pwsOther], READERS));
    AList.Add(TTaggedCleartextScheme.Create('CLEARTEXT-PREFIXED', '{CLEARTEXT}', [pwsOther],
      READERS));
  end;

begin
  inherited Create;
  FSchemes := TObjectList.Create(True);
  FGenerators := TObjectList.Create(True);
  // L'ordre compte: {SSHA256} avant {SSHA}, {SHA256} avant {SHA}, sinon le prefixe
  // court gagne a tort.
  Add(TArgon2Scheme.Create);
  Add(TCryptScheme.Create(sfNone));
  Add(TPbkdf2Scheme.Create('PBKDF2-SHA512', '{PBKDF2-SHA512}', 'SHA512', 64));
  Add(TPbkdf2Scheme.Create('PBKDF2-SHA256', '{PBKDF2-SHA256}', 'SHA256', 32));
  Add(TPbkdf2Scheme.Create('PBKDF2-SHA1', '{PBKDF2-SHA1}', 'SHA1', 20));
  Add(TPbkdf2Scheme.Create('PBKDF2-SHA1', '{PBKDF2}', 'SHA1', 20));
  Add(TDigestScheme.Create('SSHA512', '{SSHA512}', 'SHA512', 64, True, prAcceptable));
  Add(TDigestScheme.Create('SSHA384', '{SSHA384}', 'SHA384', 48, True, prAcceptable));
  Add(TDigestScheme.Create('SSHA256', '{SSHA256}', 'SHA256', 32, True, prAcceptable));
  Add(TDigestScheme.Create('SHA512', '{SHA512}', 'SHA512', 64, False, prLegacy));
  Add(TDigestScheme.Create('SHA384', '{SHA384}', 'SHA384', 48, False, prLegacy));
  Add(TDigestScheme.Create('SHA256', '{SHA256}', 'SHA256', 32, False, prLegacy));
  Add(TDigestScheme.Create('SSHA', '{SSHA}', 'SHA1', 20, True, prLegacy));
  Add(TDigestScheme.Create('SHA', '{SHA}', 'SHA1', 20, False, prLegacy));
  Add(TDigestScheme.Create('SMD5', '{SMD5}', 'MD5', 16, True, prLegacy));
  Add(TDigestScheme.Create('MD5', '{MD5}', 'MD5', 16, False, prLegacy));
  AddDelegations(FSchemes);
  AddTaggedCleartext(FSchemes);
  AddReferences(['{AES}', '{AES128}', '{AES192}', '{AES256}', '{3DES}', '{DES}', '{RC4}',
    '{BLOWFISH}', '{IMASK}'], 'Reversible encryption',
    'not a hash: encrypted with a key the server holds, so the server can recover the password',
    pslBroken);
  AddReferences(['{TOTP1}', '{TOTP256}', '{TOTP512}', '{TOTP1ANDPW}', '{TOTP256ANDPW}',
    '{TOTP512ANDPW}'], 'TOTP shared key',
    'not a hash: holds the TOTP key, as sensitive as a cleartext password', pslUnknown);
  AddReferences(['{LANMAN}'], 'LAN Manager hash',
    'uppercased, cut in two halves of 7 characters, unsalted', pslBroken);
  AddReferences(['{NT}', '{X-NTHASH}'], 'NT hash', 'one round of unsalted MD4', pslBroken);
  AddReferences(['{NS-MTA-MD5}'], 'Netscape MTA MD5', 'one round of salted MD5', pslWeak);
  AddReferences(['{APR1}', '{BSDMD5}'], 'MD5-crypt',
    '1000 rounds of MD5, declared obsolete by its author', pslWeak);
  Add(TReferenceScheme.Create('PBKDF2_SHA256-389', '{PBKDF2_SHA256}',
    '389 Directory Server PBKDF2_SHA256',
    'binary 389 DS dialect is recognised; local verification is not qualified', prUnsupported,
    pslStrong));
  Add(TReferenceScheme.Create('PBKDF2-389', '{PBKDF2-SHA512-389}', '389 Directory Server PBKDF2',
    'recognised; local verification is not qualified', prUnsupported, pslStrong));
  Add(TReferenceScheme.Create('UNKNOWN', '', 'Unknown or proprietary scheme',
    'unknown prefix: value preserved unchanged, no validation', prUnsupported, pslUnknown));
  Add(TCleartextScheme.Create);
  FGenerators.Add(TArgon2Scheme.Create);
  FGenerators.Add(TCryptScheme.Create(sfBcrypt));
  FGenerators.Add(TCryptScheme.Create(sfSha512));
  FGenerators.Add(TCryptScheme.Create(sfSha256));
  FGenerators.Add(TPbkdf2Scheme.Create('PBKDF2-SHA512', '{PBKDF2-SHA512}', 'SHA512', 64));
  FGenerators.Add(TPbkdf2Scheme.Create('PBKDF2-SHA256', '{PBKDF2-SHA256}', 'SHA256', 32));
  FGenerators.Add(TDigestScheme.Create('SSHA512', '{SSHA512}', 'SHA512', 64, True, prAcceptable));
  FGenerators.Add(TDigestScheme.Create('SSHA256', '{SSHA256}', 'SHA256', 32, True, prAcceptable));
  FGenerators.Add(TDigestScheme.Create('SSHA', '{SSHA}', 'SHA1', 20, True, prLegacy));
  FGenerators.Add(TDigestScheme.Create('SMD5', '{SMD5}', 'MD5', 16, True, prLegacy));
  FGenerators.Add(TCryptScheme.Create(sfMd5));
  FGenerators.Add(TCryptScheme.Create(sfDes));
  FGenerators.Add(TDigestScheme.Create('SHA', '{SHA}', 'SHA1', 20, False, prLegacy));
  FGenerators.Add(TDigestScheme.Create('MD5', '{MD5}', 'MD5', 16, False, prLegacy));
  AddDelegations(FGenerators);
  AddTaggedCleartext(FGenerators);
  FGenerators.Add(TCleartextScheme.Create);
end;

destructor TPasswordRegistry.Destroy;
begin
  FSchemes.Free;
  FGenerators.Free;
  inherited Destroy;
end;

function TPasswordRegistry.GetScheme(AIndex: Integer): TPasswordScheme;
begin
  Result := TPasswordScheme(FSchemes[AIndex]);
end;

function TPasswordRegistry.SchemeCount: Integer;
begin
  Result := FSchemes.Count;
end;

function TPasswordRegistry.Identify(const AValue: RawByteString): TPasswordScheme;
var
  i: Integer;
begin
  for i := 0 to FSchemes.Count - 1 do
    if TPasswordScheme(FSchemes[i]).Matches(AValue) then
      Exit(TPasswordScheme(FSchemes[i]));
  Result := nil;
end;

function TPasswordRegistry.Inspect(const AValue: RawByteString): TPwdInfo;
var
  s: TPasswordScheme;
begin
  s := Identify(AValue);
  Result := s.Inspect(AValue);
end;

function TPasswordRegistry.Verify(const AValue, APassword: RawByteString;
  out ADetail: string): TPwdStatus;
begin
  Result := Identify(AValue).Verify(AValue, APassword, ADetail);
end;

function TPasswordRegistry.FindById(const AId: string): TPasswordScheme;
var
  i: Integer;
begin
  for i := 0 to FGenerators.Count - 1 do
    if SameText(TPasswordScheme(FGenerators[i]).Id, AId) then
      Exit(TPasswordScheme(FGenerators[i]));
  Result := nil;
end;

function TPasswordRegistry.GeneratorIds(AServer: TPwdServer): TStringArray;
var
  i, n: Integer;
begin
  Result := nil;
  SetLength(Result, FGenerators.Count);
  n := 0;
  for i := 0 to FGenerators.Count - 1 do
    if AServer in TPasswordScheme(FGenerators[i]).Servers then
    begin
      Result[n] := TPasswordScheme(FGenerators[i]).Id;
      Inc(n);
    end;
  SetLength(Result, n);
end;

var
  GRegistry: TPasswordRegistry = nil;

function PasswordRegistry: TPasswordRegistry;
begin
  // Cree a l'initialisation de l'unite: les fils de calcul y accedent aussi, pas de
  // creation paresseuse en course.
  Result := GRegistry;
end;

function VerifyPasswordValues(const AValues: array of RawByteString;
  const APassword: RawByteString; ACancel: TCancelToken): TPwdMultiResult;
var
  i: Integer;
  anyMatch, anyUnverified, anyVerified: Boolean;
  sch: TPasswordScheme;
begin
  Result.Values := nil;
  SetLength(Result.Values, Length(AValues));
  anyMatch := False;
  anyUnverified := False;
  anyVerified := False;
  for i := 0 to High(AValues) do
  begin
    sch := PasswordRegistry.Identify(AValues[i]);
    Result.Values[i].SchemeId := sch.Inspect(AValues[i]).SchemeId;
    if (ACancel <> nil) and ACancel.IsCancelled then
    begin
      Result.Values[i].Status := psUnverifiable;
      Result.Values[i].Detail := 'cancelled';
      anyUnverified := True;
      Continue;
    end;
    try
      Result.Values[i].Status := sch.Verify(AValues[i], APassword, Result.Values[i].Detail);
    except
      on E: Exception do
      begin
        // Bibliotheque absente ou erreur interne: inverifiable, jamais "ne correspond
        // pas".
        Result.Values[i].Status := psUnverifiable;
        Result.Values[i].Detail := E.Message;
      end;
    end;
    case Result.Values[i].Status of
      psMatch:
        begin
          anyMatch := True;
          anyVerified := True;
        end;
      psNoMatch: anyVerified := True;
    else
      anyUnverified := True;
    end;
  end;
  if Length(AValues) = 0 then
    Result.Outcome := pmoNoValues
  else if anyMatch then
    Result.Outcome := pmoMatch
  else if not anyVerified then
    Result.Outcome := pmoNothingVerifiable
  else if anyUnverified then
    Result.Outcome := pmoNoMatchIncomplete
  else
    Result.Outcome := pmoNoMatchAllVerified;
end;

function EncodeUnicodePwd(const ASecretUtf8: RawByteString): RawByteString;
var
  w: UnicodeString;
begin
  if not IsValidUtf8(ASecretUtf8) then
    raise Exception.Create('the password is not valid UTF-8');
  w := '"' + UTF8Decode(ASecretUtf8) + '"';
  SetLength(Result, Length(w) * SizeOf(WideChar));
  if Length(w) > 0 then
    Move(w[1], Result[1], Length(Result));
  // La copie UTF-16 intermediaire est effacee.
  FillChar(w[1], Length(w) * SizeOf(WideChar), 0);
  {$IFDEF ENDIAN_BIG}
  raise Exception.Create('big-endian hosts are not supported');
  {$ENDIF}
end;

initialization
  GRegistry := TPasswordRegistry.Create;

finalization
  GRegistry.Free;

end.
