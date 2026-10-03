// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAttributeCodec;

{$mode objfpc}{$H+}

// Affichage et edition types des valeurs d'attribut. Le type vient du schema ou d'une
// regle fournisseur nommee, jamais de la forme des octets: 16 octets ne font pas un GUID.
// La presentation ne touche jamais aux octets source, et une valeur n'est reencodee que
// si quelqu'un l'a vraiment modifiee.

interface

uses
  SysUtils, uLdapSchema, uAdSchemaMeta, uConnectionProfile;

const
  SYN_BINARY = '1.3.6.1.4.1.1466.115.121.1.5';
  SYN_BOOLEAN = '1.3.6.1.4.1.1466.115.121.1.7';
  SYN_CERTIFICATE = '1.3.6.1.4.1.1466.115.121.1.8';
  SYN_CERT_LIST = '1.3.6.1.4.1.1466.115.121.1.9';
  SYN_CERT_PAIR = '1.3.6.1.4.1.1466.115.121.1.10';
  SYN_DN = '1.3.6.1.4.1.1466.115.121.1.12';
  SYN_FAX = '1.3.6.1.4.1.1466.115.121.1.23';
  SYN_GENERALIZED_TIME = '1.3.6.1.4.1.1466.115.121.1.24';
  SYN_INTEGER = '1.3.6.1.4.1.1466.115.121.1.27';
  SYN_JPEG = '1.3.6.1.4.1.1466.115.121.1.28';
  SYN_OCTET_STRING = '1.3.6.1.4.1.1466.115.121.1.40';
  SYN_AUDIO = '1.3.6.1.4.1.1466.115.121.1.4';
  SYN_AD_LARGE_INTEGER = '1.2.840.113556.1.4.906';
  SYN_AD_SD = '1.2.840.113556.1.4.907';

  CODEC_GRID_MAX_CHARS = 2048;
  CODEC_GRID_HEX_BYTES = 32;

  AD_FILETIME_NEVER = High(Int64);
  VALUE_TEXT_DETAIL_CHARS = 4096;

type
  TValueKind = (vkText, vkBoolean, vkInteger, vkDn, vkGeneralizedTime, vkAdFileTime,
    vkAdInterval, vkSid, vkGuid, vkBinary, vkSecurityDescriptor, vkCertificate);

  TKindSource = (
    ksLdapSyntax,
    ksAdMetadata,
    ksProviderRule,
    ksBinaryOption,
    ksNoSchema,
    ksUnknownSyntax);

  TValueResolution = record
    Kind: TValueKind;
    Source: TKindSource;
    SyntaxOid: string;
    SyntaxName: string;
    Detail: string;
    ReadOnly: Boolean;
    ReadOnlyReason: string;
    SingleValued: Boolean;
    HasRangeLower, HasRangeUpper: Boolean;
    RangeLower, RangeUpper: Int64;
  end;

  TUtcToLocalFunc = function(AUtc: TDateTime; out ALocal: TDateTime;
    out AOffsetMinutes: Integer): Boolean;

  TAttributeValueView = record
    Bytes: RawByteString;
    Resolution: TValueResolution;
    Valid: Boolean;
    Display: string;
    Details: array of string;
    Diagnostic: string;
    Masked: Boolean;
    TextFaithful: Boolean;
  end;

  TGeneralizedTime = record
    Year, Month, Day, Hour: Integer;
    Minute, Second: Integer;
    Fraction: string;
    FractionOf: Char;
    Utc: Boolean;
    OffsetMinutes: Integer;
    LeapSecond: Boolean;
    Representable: Boolean;
    UtcDate: TDateTime;
  end;

resourcestring
  rsKindText = 'Text';
  rsKindBoolean = 'Boolean';
  rsKindInteger = 'Integer';
  rsKindDn = 'Distinguished name';
  rsKindGenTime = 'Generalized time';
  rsKindAdFileTime = 'AD time (FILETIME)';
  rsKindAdInterval = 'AD time interval';
  rsKindSid = 'Security identifier (SID)';
  rsKindGuid = 'GUID';
  rsKindBinary = 'Binary';
  rsKindSd = 'Security descriptor';
  rsKindCertificate = 'X.509 certificate';

  rsSrcLdapSyntax = 'schema syntax %s';
  rsSrcAdMeta = 'AD schema: %s (attributeSyntax %s, oMSyntax %d)';
  rsSrcProviderRule = 'provider rule: %s';
  rsSrcBinaryOption = 'option ;binary';
  rsSrcNoSchema = 'attribute not in the schema: shown as text when it is valid UTF-8';
  rsSrcNoSchemaAtAll = 'schema unavailable: shown as text when it is valid UTF-8';
  rsSrcUnknownSyntax = 'syntax %s is not interpreted: shown as text';
  rsRuleGuid = 'AD GUID attribute';
  rsRuleSid = 'AD SID attribute (AD schema metadata unavailable)';
  rsRuleFileTime = 'AD time attribute, 100 ns since 1601-01-01 UTC';
  rsRuleInterval = 'AD interval attribute, negative 100 ns';
  rsRuleCertificate = 'certificate attribute';
  rsRoNoUserMod = 'the schema marks it NO-USER-MODIFICATION';
  rsRoSystemOnly = 'the AD schema marks it systemOnly';
  rsRoSd = 'a security descriptor is changed only by targeted actions';

  rsDisplayBinary = '[%d bytes] %s';
  rsDisplayBinaryMore = '[%d bytes] %s...';
  rsDisplayEmpty = '[empty value]';
  rsDisplaySd = '[%d bytes, security descriptor]';
  rsDisplayCert = '[%d bytes, certificate]';
  rsDisplayInvalid = '%s  (invalid %s: %s)';
  rsDisplayTruncated = '%s... (%d characters, open the value to see all of it)';
  rsDisplayInterp = '%s  (%s)';

  rsDiagNotUtf8 = 'not valid UTF-8: shown as bytes';
  rsDiagControl = 'contains control characters, shown as \xNN';
  rsDiagBoolean = 'a Boolean is exactly TRUE or FALSE (RFC 4517)';
  rsDiagIntSyntax = 'an Integer is an optional minus sign and digits without leading zero (RFC 4517)';
  rsDiagIntBeyond = 'beyond 64-bit integers: kept as validated text';
  rsDiagBelowRange = 'below the lower bound %d of the AD schema';
  rsDiagAboveRange = 'above the upper bound %d of the AD schema';
  rsDiagGenTime = 'not a GeneralizedTime (RFC 4517 3.3.13): %s';
  rsDiagNotRepresentable = 'valid, but the date cannot be represented (year %d)';
  rsDiagLeapSecond = 'leap second';
  rsDiagDn = 'not a distinguished name: %s';
  rsDiagFileTimeNegative = 'negative value: not a FILETIME';
  rsDiagFileTimeRange = 'beyond representable dates';
  rsDiagSid = 'not a SID: %s';
  rsDiagGuidLength = 'a GUID has 16 bytes, this value has %d: shown as bytes';
  rsDiagGuidText = 'not a GUID: expected xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx';
  rsDiagHex = 'hexadecimal digits expected (spaces allowed), an even number of them';
  rsDiagTooLarge = 'value larger than %d bytes';
  rsDiagNotEditable = 'this type is not edited as text';

  rsDetType = 'Type: %s';
  rsDetSource = 'Resolved from: %s';
  rsDetBytes = 'Size: %d bytes';
  rsDetUtc = 'UTC: %s';
  rsDetLocal = 'Local: %s (UTC%s)';
  rsDetLocalUnknown = 'Local: time zone offset unknown';
  rsDetOriginal = 'Stored value: %s';
  rsDetFraction = 'Fraction of the %s: .%s';
  rsDetOffset = 'Written with offset %s';
  rsDetSentinel = 'Meaning: %s';
  rsDetRdn = 'RDN %d: %s';
  rsDetSidParts = 'Revision %d, authority %s, %d sub-authorit(y/ies)';
  rsDetRid = 'Relative identifier (RID): %u';
  rsDetInterval = 'Interval: %s';
  rsDetText = 'As text: %s';
  rsDetHour = 'hour';
  rsDetMinute = 'minute';
  rsDetSecond = 'second';

  rsSentNever = 'never';
  rsSentNeverExpires = 'the account never expires';
  rsSentMustChange = 'the password must be changed at next logon';
  rsSentNotLocked = 'not locked out';
  rsSentNoDate = 'no date';

function ResolveValueKind(ASchema: TSchemaSnapshot; const AAttrDescription: string;
  AProvider: TProviderKind): TValueResolution;
function ValueKindName(AKind: TValueKind): string;
// AMasked: secret non revele, rien n'est interprete ni montre, pas meme la taille. Une
// longueur de mot de passe, c'est deja la moitie d'un indice.
function ViewValue(const ARes: TValueResolution; const AAttrDescription: string;
  const AValue: RawByteString; AMasked: Boolean; AToLocal: TUtcToLocalFunc): TAttributeValueView;
function ValidateValue(const ARes: TValueResolution; const AValue: RawByteString): string;
function EncodeTyped(const ARes: TValueResolution; const AInput: string;
  const AOriginal: RawByteString; out ABytes: RawByteString; out AError: string): Boolean;
function EditableText(const ARes: TValueResolution; const AValue: RawByteString): string;
function KindTextEditable(AKind: TValueKind): Boolean;

function CheckLdapInteger(const S: string; out AFitsInt64: Boolean; out AValue: Int64): Boolean;
function ParseGeneralizedTimeEx(const S: string; out ATime: TGeneralizedTime;
  out AError: string): Boolean;
function SidToText(const ABytes: RawByteString; out AText, AError: string): Boolean;
function SidFromText(const AText: string; out ABytes: RawByteString; out AError: string): Boolean;
function GuidToText(const ABytes: RawByteString; out AText: string): Boolean;
function GuidFromText(const AText: string; out ABytes: RawByteString): Boolean;
function FileTimeToDate(AValue: Int64; out AUtc: TDateTime; out ARemainder100ns: Integer): Boolean;
function AdFileTimeSentinel(const AAttr: string; AValue: Int64): string;
function HexInputDecode(const S: string; AMaxBytes: Int64; out ABytes: RawByteString;
  out AError: string): Boolean;
function HexDump(const ABytes: RawByteString; AMaxBytes: Integer): string;
// Le memo Windows rend toujours CRLF: on revient a LF si la valeur d'origine n'en avait
// pas, sinon chaque edition reecrit toutes les fins de ligne en douce.
function AdaptLineEndings(const AEdited: string; const AOriginal: RawByteString): RawByteString;
function FormatUtcOffset(AMinutes: Integer): string;

implementation

uses
  DateUtils, uLdapEntry, uLdapDn, uRtBytes, uAdInfo, uSyntaxInfo, uSensitive, uAdSecurityDescriptor;

const
  AD_GUID_ATTRS: array[0..5] of string = ('objectGUID', 'schemaIDGUID', 'attributeSecurityGUID',
    'invocationId', 'netbootGUID', 'msDS-OptionalFeatureGUID');
  AD_SID_ATTRS: array[0..6] of string = ('objectSid', 'sIDHistory', 'securityIdentifier',
    'tokenGroups', 'tokenGroupsGlobalAndUniversal', 'tokenGroupsNoGCAcceptable', 'msDS-CreatorSID');
  AD_FILETIME_ATTRS: array[0..10] of string = ('accountExpires', 'badPasswordTime', 'lastLogoff',
    'lastLogon', 'lastLogonTimestamp', 'lockoutTime', 'pwdLastSet', 'creationTime',
    'msDS-UserPasswordExpiryTimeComputed', 'msDS-LastSuccessfulInteractiveLogonTime',
    'msDS-LastFailedInteractiveLogonTime');
  AD_INTERVAL_ATTRS: array[0..8] of string = ('maxPwdAge', 'minPwdAge', 'lockoutDuration',
    'lockOutObservationWindow', 'forceLogoff', 'msDS-MaximumPasswordAge',
    'msDS-MinimumPasswordAge', 'msDS-LockoutDuration', 'msDS-LockoutObservationWindow');
  CERT_ATTRS: array[0..1] of string = ('userCertificate', 'cACertificate');

  FILETIME_EPOCH_DAYS = 109205;
  FILETIME_PER_DAY = Int64(864000000000);
  FILETIME_MAX = Int64(2650467743999999999);

function InList(const AName: string; const AList: array of string): Boolean;
var
  i: Integer;
  l: string;
begin
  l := AsciiLowerCase(AName);
  for i := 0 to High(AList) do
    if AsciiLowerCase(AList[i]) = l then Exit(True);
  Result := False;
end;

function ValueKindName(AKind: TValueKind): string;
begin
  case AKind of
    vkText: Result := rsKindText;
    vkBoolean: Result := rsKindBoolean;
    vkInteger: Result := rsKindInteger;
    vkDn: Result := rsKindDn;
    vkGeneralizedTime: Result := rsKindGenTime;
    vkAdFileTime: Result := rsKindAdFileTime;
    vkAdInterval: Result := rsKindAdInterval;
    vkSid: Result := rsKindSid;
    vkGuid: Result := rsKindGuid;
    vkBinary: Result := rsKindBinary;
    vkSecurityDescriptor: Result := rsKindSd;
    vkCertificate: Result := rsKindCertificate;
  else
    Result := rsKindText;
  end;
end;

function KindTextEditable(AKind: TValueKind): Boolean;
begin
  Result := AKind in [vkText, vkBoolean, vkInteger, vkDn, vkGeneralizedTime, vkAdFileTime,
    vkAdInterval, vkSid, vkGuid, vkBinary];
end;

function KindOfLdapSyntax(const AOid: string; out AKind: TValueKind): Boolean;
begin
  Result := True;
  if AOid = SYN_BOOLEAN then AKind := vkBoolean
  else if (AOid = SYN_INTEGER) or (AOid = SYN_AD_LARGE_INTEGER) then AKind := vkInteger
  else if AOid = SYN_DN then AKind := vkDn
  else if AOid = SYN_GENERALIZED_TIME then AKind := vkGeneralizedTime
  else if AOid = SYN_CERTIFICATE then AKind := vkCertificate
  else if AOid = SYN_AD_SD then AKind := vkSecurityDescriptor
  else if (AOid = SYN_BINARY) or (AOid = SYN_OCTET_STRING) or (AOid = SYN_JPEG) or
    (AOid = SYN_FAX) or (AOid = SYN_AUDIO) or (AOid = SYN_CERT_LIST) or (AOid = SYN_CERT_PAIR) then
    AKind := vkBinary
  else
  begin
    AKind := vkText;
    Result := False;
  end;
end;

function KindOfAdSyntax(AMeta: TAdAttributeMeta; out AKind: TValueKind): Boolean;
var
  s: string;
begin
  Result := True;
  s := AMeta.AttributeSyntax;
  if s = AD_SYNTAX_DN then AKind := vkDn
  else if s = AD_SYNTAX_BOOLEAN then AKind := vkBoolean
  else if (s = AD_SYNTAX_INTEGER) or (s = AD_SYNTAX_LARGE_INTEGER) then AKind := vkInteger
  else if s = AD_SYNTAX_OCTET then AKind := vkBinary
  else if s = AD_SYNTAX_SD then AKind := vkSecurityDescriptor
  else if s = AD_SYNTAX_SID then AKind := vkSid
  else if s = AD_SYNTAX_TIME then
  begin
    if AMeta.OmSyntax = AD_OM_GENERALIZED_TIME then AKind := vkGeneralizedTime
    else AKind := vkText;
  end
  else if (s = AD_SYNTAX_OID) or (s = AD_SYNTAX_CASE_STRING) or (s = AD_SYNTAX_TELETEX) or
    (s = AD_SYNTAX_PRINTABLE) or (s = AD_SYNTAX_NUMERIC) or (s = AD_SYNTAX_UNICODE) or
    (s = AD_SYNTAX_DN_BINARY) or (s = AD_SYNTAX_DN_STRING) or (s = AD_SYNTAX_PRESENTATION) then
    AKind := vkText
  else
  begin
    AKind := vkText;
    Result := False;
  end;
end;

function ResolveValueKind(ASchema: TSchemaSnapshot; const AAttrDescription: string;
  AProvider: TProviderKind): TValueResolution;
var
  base, oid: string;
  at: TSchemaAttributeType;
  meta: TAdAttributeMeta;
  adMeta: TAdSchemaMeta;
  k: TValueKind;
  len: Integer;
  isAd, known: Boolean;
begin
  Result := Default(TValueResolution);
  Result.Kind := vkText;
  base := AttrBaseName(AAttrDescription);
  adMeta := nil;
  if ASchema <> nil then adMeta := ASchema.AdMeta;
  isAd := (AProvider = pkActiveDirectory) or (adMeta <> nil);
  meta := nil;
  if adMeta <> nil then meta := adMeta.Attribute(base);
  at := nil;
  if ASchema <> nil then at := ASchema.AttributeType(base);

  if meta <> nil then
  begin
    known := KindOfAdSyntax(meta, k);
    Result.Kind := k;
    Result.Source := ksAdMetadata;
    Result.SyntaxOid := meta.AttributeSyntax;
    Result.SyntaxName := AdSyntaxName(meta.AttributeSyntax, meta.OmSyntax, meta.OmObjectClassHex);
    Result.Detail := Format(rsSrcAdMeta, [Result.SyntaxName, meta.AttributeSyntax, meta.OmSyntax]);
    if not known then Result.Source := ksUnknownSyntax;
    Result.SingleValued := meta.SingleValued;
    Result.HasRangeLower := meta.HasRangeLower;
    Result.RangeLower := meta.RangeLower;
    Result.HasRangeUpper := meta.HasRangeUpper;
    Result.RangeUpper := meta.RangeUpper;
    if meta.SystemOnly then
    begin
      Result.ReadOnly := True;
      Result.ReadOnlyReason := rsRoSystemOnly;
    end;
  end
  else if at <> nil then
  begin
    oid := SplitSyntaxLength(ASchema.EffectiveSyntax(base), len);
    Result.SyntaxOid := oid;
    Result.SingleValued := at.SingleValue;
    if KindOfLdapSyntax(oid, k) then
    begin
      Result.Kind := k;
      Result.Source := ksLdapSyntax;
      Result.Detail := Format(rsSrcLdapSyntax, [oid]);
    end
    else
    begin
      Result.Kind := vkText;
      Result.Source := ksUnknownSyntax;
      Result.Detail := Format(rsSrcUnknownSyntax, [oid]);
    end;
  end
  else
  begin
    Result.Source := ksNoSchema;
    if ASchema = nil then Result.Detail := rsSrcNoSchemaAtAll else Result.Detail := rsSrcNoSchema;
  end;
  if (at <> nil) and at.NoUserModification and not Result.ReadOnly then
  begin
    Result.ReadOnly := True;
    Result.ReadOnlyReason := rsRoNoUserMod;
  end;

  // Regles fournisseur AD (MS-ADA1..3, MS-ADTS): GUID publies en Octet String et pris
  // comme tels seulement a 16 octets pile, SID sans metadonnees AD, FILETIME et
  // intervalles des tables AD_FILETIME_ATTRS et AD_INTERVAL_ATTRS. Jamais au-dela du type
  // de base precise.
  if isAd and (Result.Kind = vkBinary) and InList(base, AD_GUID_ATTRS) then
  begin
    Result.Kind := vkGuid;
    Result.Source := ksProviderRule;
    Result.Detail := Format(rsSrcProviderRule, [rsRuleGuid]);
  end
  else if isAd and (meta = nil) and (Result.Kind in [vkBinary, vkText]) and
    (Result.Source <> ksNoSchema) and InList(base, AD_SID_ATTRS) then
  begin
    Result.Kind := vkSid;
    Result.Source := ksProviderRule;
    Result.Detail := Format(rsSrcProviderRule, [rsRuleSid]);
  end
  else if isAd and (Result.Kind = vkInteger) and InList(base, AD_FILETIME_ATTRS) then
  begin
    Result.Kind := vkAdFileTime;
    Result.Source := ksProviderRule;
    Result.Detail := Format(rsSrcProviderRule, [rsRuleFileTime]);
  end
  else if isAd and (Result.Kind = vkInteger) and InList(base, AD_INTERVAL_ATTRS) then
  begin
    Result.Kind := vkAdInterval;
    Result.Source := ksProviderRule;
    Result.Detail := Format(rsSrcProviderRule, [rsRuleInterval]);
  end
  else if (Result.Kind = vkBinary) and InList(base, CERT_ATTRS) then
  begin
    Result.Kind := vkCertificate;
    Result.Source := ksProviderRule;
    Result.Detail := Format(rsSrcProviderRule, [rsRuleCertificate]);
  end;

  if (Result.Kind in [vkText]) and (Pos(';binary', AsciiLowerCase(AAttrDescription)) > 0) then
  begin
    Result.Kind := vkBinary;
    Result.Source := ksBinaryOption;
    Result.Detail := rsSrcBinaryOption;
  end;
  if Result.Kind = vkSecurityDescriptor then
  begin
    Result.ReadOnly := True;
    if Result.ReadOnlyReason = '' then Result.ReadOnlyReason := rsRoSd;
  end;
end;

function CheckLdapInteger(const S: string; out AFitsInt64: Boolean; out AValue: Int64): Boolean;
var
  i, start: Integer;
  digits, limit: string;
  neg: Boolean;
begin
  AFitsInt64 := False;
  AValue := 0;
  Result := False;
  if S = '' then Exit;
  neg := S[1] = '-';
  if neg then start := 2 else start := 1;
  if start > Length(S) then Exit;
  for i := start to Length(S) do
    if not (S[i] in ['0'..'9']) then Exit;
  digits := Copy(S, start, MaxInt);
  if (Length(digits) > 1) and (digits[1] = '0') then Exit;
  if neg and (digits = '0') then Exit;
  Result := True;
  // Comparaison textuelle aux bornes: aucune conversion qui deborde sur un entier de cent
  // chiffres envoye par un plaisantin.
  if neg then limit := '9223372036854775808' else limit := '9223372036854775807';
  if (Length(digits) < Length(limit)) or ((Length(digits) = Length(limit)) and (digits <= limit)) then
  begin
    AFitsInt64 := TryStrToInt64(S, AValue);
    if not AFitsInt64 then AValue := 0;
  end;
end;

function TakeDigits(const S: string; var P: Integer; ACount: Integer; out AValue: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  AValue := 0;
  if P + ACount - 1 > Length(S) then Exit;
  for i := P to P + ACount - 1 do
  begin
    if not (S[i] in ['0'..'9']) then Exit;
    AValue := AValue * 10 + Ord(S[i]) - Ord('0');
  end;
  Inc(P, ACount);
  Result := True;
end;

function IsDigitAt(const S: string; P: Integer): Boolean;
begin
  Result := (P <= Length(S)) and (S[P] in ['0'..'9']);
end;

function ParseGeneralizedTimeEx(const S: string; out ATime: TGeneralizedTime;
  out AError: string): Boolean;
var
  p, v, oh, om, maxDay: Integer;
  sign: Integer;
  d, frac: Double;
  i: Integer;
begin
  Result := False;
  AError := '';
  ATime := Default(TGeneralizedTime);
  ATime.Minute := -1;
  ATime.Second := -1;
  p := 1;
  if not TakeDigits(S, p, 4, ATime.Year) or not TakeDigits(S, p, 2, ATime.Month) or
     not TakeDigits(S, p, 2, ATime.Day) or not TakeDigits(S, p, 2, ATime.Hour) then
  begin
    AError := 'YYYYMMDDHH expected';
    Exit;
  end;
  ATime.FractionOf := 'h';
  if IsDigitAt(S, p) then
  begin
    if not TakeDigits(S, p, 2, v) then begin AError := 'minute'; Exit; end;
    ATime.Minute := v;
    ATime.FractionOf := 'm';
    if IsDigitAt(S, p) then
    begin
      if not TakeDigits(S, p, 2, v) then begin AError := 'second'; Exit; end;
      ATime.Second := v;
      ATime.FractionOf := 's';
    end;
  end;
  if (p <= Length(S)) and (S[p] in ['.', ',']) then
  begin
    Inc(p);
    if not IsDigitAt(S, p) then begin AError := 'fraction digits expected'; Exit; end;
    while IsDigitAt(S, p) do
    begin
      ATime.Fraction := ATime.Fraction + S[p];
      Inc(p);
    end;
  end;
  if p > Length(S) then begin AError := 'time zone expected (Z or +hhmm)'; Exit; end;
  if S[p] = 'Z' then
  begin
    ATime.Utc := True;
    Inc(p);
  end
  else if S[p] in ['+', '-'] then
  begin
    if S[p] = '-' then sign := -1 else sign := 1;
    Inc(p);
    if not TakeDigits(S, p, 2, oh) then begin AError := 'offset hour'; Exit; end;
    om := 0;
    if IsDigitAt(S, p) and not TakeDigits(S, p, 2, om) then begin AError := 'offset minute'; Exit; end;
    if (oh > 23) or (om > 59) then begin AError := 'offset out of range'; Exit; end;
    ATime.OffsetMinutes := sign * (oh * 60 + om);
  end
  else
  begin
    AError := 'time zone expected (Z or +hhmm)';
    Exit;
  end;
  if p <= Length(S) then begin AError := 'unexpected characters after the time zone'; Exit; end;
  if (ATime.Month < 1) or (ATime.Month > 12) then begin AError := 'month out of range'; Exit; end;
  if (ATime.Day < 1) or (ATime.Day > 31) then begin AError := 'day out of range'; Exit; end;
  if ATime.Hour > 23 then begin AError := 'hour out of range'; Exit; end;
  if ATime.Minute > 59 then begin AError := 'minute out of range'; Exit; end;
  if ATime.Second > 60 then begin AError := 'second out of range'; Exit; end;
  ATime.LeapSecond := ATime.Second = 60;
  if ATime.Year >= 1 then
  begin
    maxDay := DaysInAMonth(ATime.Year, ATime.Month);
    if ATime.Day > maxDay then begin AError := 'day does not exist in this month'; Exit; end;
  end;
  Result := True;
  // An 0000 non representable, et pourtant ppolicy d'OpenLDAP s'en sert pour un verrou
  // definitif (000001010000Z).
  if (ATime.Year < 1) or not TryEncodeDate(ATime.Year, ATime.Month, ATime.Day, d) then
  begin
    ATime.Representable := False;
    Exit;
  end;
  d := d + ATime.Hour / 24;
  if ATime.Minute >= 0 then d := d + ATime.Minute / 1440;
  if ATime.Second >= 0 then d := d + ATime.Second / 86400;
  if ATime.Fraction <> '' then
  begin
    frac := 0;
    for i := Length(ATime.Fraction) downto 1 do
      frac := (frac + Ord(ATime.Fraction[i]) - Ord('0')) / 10;
    case ATime.FractionOf of
      'h': d := d + frac / 24;
      'm': d := d + frac / 1440;
    else
      d := d + frac / 86400;
    end;
  end;
  d := d - ATime.OffsetMinutes / 1440;
  ATime.UtcDate := d;
  ATime.Representable := (d >= MinDateTime) and (d < EncodeDate(9999, 12, 31) + 1);
end;

function SidToText(const ABytes: RawByteString; out AText, AError: string): Boolean;
var
  rev, count, i: Integer;
  auth: QWord;
begin
  Result := False;
  AText := '';
  AError := '';
  if Length(ABytes) < 8 then
  begin
    AError := Format('%d bytes, at least 8 expected', [Length(ABytes)]);
    Exit;
  end;
  rev := Byte(ABytes[1]);
  count := Byte(ABytes[2]);
  if rev <> 1 then
  begin
    AError := Format('revision %d, 1 expected', [rev]);
    Exit;
  end;
  if count > 15 then
  begin
    AError := Format('%d sub-authorities, at most 15', [count]);
    Exit;
  end;
  if Length(ABytes) <> 8 + 4 * count then
  begin
    AError := Format('%d bytes for %d sub-authorities, %d expected', [Length(ABytes), count, 8 + 4 * count]);
    Exit;
  end;
  auth := 0;
  for i := 3 to 8 do
    auth := (auth shl 8) or Byte(ABytes[i]);
  if auth < QWord($100000000) then
    AText := 'S-1-' + IntToStr(auth)
  else
    AText := 'S-1-0x' + IntToHex(auth, 12);
  for i := 0 to count - 1 do
    AText := AText + '-' + IntToStr(ReadUInt32LE(ABytes, 9 + 4 * i));
  Result := True;
end;

function SidFromText(const AText: string; out ABytes: RawByteString; out AError: string): Boolean;
var
  parts: TStringArray;
  auth: QWord;
  sub: QWord;
  i, j: Integer;
  s: string;
begin
  Result := False;
  ABytes := '';
  AError := '';
  parts := AText.Split(['-']);
  if (Length(parts) < 3) or not SameText(parts[0], 'S') or (parts[1] <> '1') then
  begin
    AError := 'S-1-<authority>-<sub-authorities> expected';
    Exit;
  end;
  if Length(parts) - 3 > 15 then
  begin
    AError := 'at most 15 sub-authorities';
    Exit;
  end;
  s := parts[2];
  if (Length(s) > 2) and SameText(Copy(s, 1, 2), '0x') then
  begin
    if (Length(s) > 14) or not TryStrToQWord('$' + Copy(s, 3, MaxInt), auth) then
    begin
      AError := 'invalid authority';
      Exit;
    end;
  end
  else
  begin
    for j := 1 to Length(s) do
      if not (s[j] in ['0'..'9']) then begin AError := 'invalid authority'; Exit; end;
    if (s = '') or (Length(s) > 15) or not TryStrToQWord(s, auth) then
    begin
      AError := 'invalid authority';
      Exit;
    end;
  end;
  if auth > QWord($FFFFFFFFFFFF) then
  begin
    AError := 'authority beyond 48 bits';
    Exit;
  end;
  SetLength(ABytes, 8 + 4 * (Length(parts) - 3));
  ABytes[1] := #1;
  ABytes[2] := Char(Length(parts) - 3);
  for i := 0 to 5 do
    ABytes[3 + i] := Char((auth shr (8 * (5 - i))) and $FF);
  for i := 3 to High(parts) do
  begin
    s := parts[i];
    if (s = '') or (Length(s) > 10) then begin AError := 'invalid sub-authority'; ABytes := ''; Exit; end;
    for j := 1 to Length(s) do
      if not (s[j] in ['0'..'9']) then begin AError := 'invalid sub-authority'; ABytes := ''; Exit; end;
    if not TryStrToQWord(s, sub) or (sub > $FFFFFFFF) then
    begin
      AError := 'sub-authority beyond 32 bits';
      ABytes := '';
      Exit;
    end;
    for j := 0 to 3 do
      ABytes[9 + 4 * (i - 3) + j] := Char((sub shr (8 * j)) and $FF);
  end;
  Result := True;
end;

function SidAuthorityText(const ASid: string): string;
var
  rest: string;
  p: Integer;
begin
  rest := Copy(ASid, 5, MaxInt);
  p := Pos('-', rest);
  if p > 0 then Result := Copy(rest, 1, p - 1) else Result := rest;
end;

const
  GUID_ORDER: array[0..15] of Integer = (4, 3, 2, 1, 6, 5, 8, 7, 9, 10, 11, 12, 13, 14, 15, 16);

function GuidToText(const ABytes: RawByteString; out AText: string): Boolean;
var
  i: Integer;
begin
  AText := '';
  Result := Length(ABytes) = 16;
  if not Result then Exit;
  for i := 0 to 15 do
  begin
    if i in [4, 6, 8, 10] then AText := AText + '-';
    AText := AText + LowerCase(IntToHex(Byte(ABytes[GUID_ORDER[i]]), 2));
  end;
end;

function GuidFromText(const AText: string; out ABytes: RawByteString): Boolean;
var
  s, hex: string;
  raw: RawByteString;
  i: Integer;
begin
  Result := False;
  ABytes := '';
  s := Trim(AText);
  if (Length(s) = 38) and (s[1] = '{') and (s[38] = '}') then s := Copy(s, 2, 36);
  if (Length(s) <> 36) or (s[9] <> '-') or (s[14] <> '-') or (s[19] <> '-') or (s[24] <> '-') then
    Exit;
  hex := StringReplace(s, '-', '', [rfReplaceAll]);
  if (Length(hex) <> 32) or not HexDecode(hex, raw) then Exit;
  SetLength(ABytes, 16);
  for i := 0 to 15 do
    ABytes[GUID_ORDER[i]] := raw[i + 1];
  Result := True;
end;

function FileTimeToDate(AValue: Int64; out AUtc: TDateTime; out ARemainder100ns: Integer): Boolean;
var
  secs, days, daySecs: Int64;
begin
  AUtc := 0;
  ARemainder100ns := 0;
  Result := (AValue >= 0) and (AValue <= FILETIME_MAX);
  if not Result then Exit;
  secs := AValue div 10000000;
  ARemainder100ns := AValue mod 10000000;
  days := secs div 86400;
  daySecs := secs mod 86400;
  AUtc := (days - FILETIME_EPOCH_DAYS) + daySecs / 86400;
end;

function AdFileTimeSentinel(const AAttr: string; AValue: Int64): string;
var
  a: string;
begin
  Result := '';
  a := AsciiLowerCase(AttrBaseName(AAttr));
  if a = 'accountexpires' then
  begin
    if (AValue = 0) or (AValue = AD_FILETIME_NEVER) then Result := rsSentNeverExpires;
  end
  else if a = 'pwdlastset' then
  begin
    if AValue = 0 then Result := rsSentMustChange;
  end
  else if a = 'lockouttime' then
  begin
    if AValue = 0 then Result := rsSentNotLocked;
  end
  else if a = 'msds-userpasswordexpirytimecomputed' then
  begin
    if AValue = AD_FILETIME_NEVER then Result := rsSentNever
    else if AValue = 0 then Result := rsSentNoDate;
  end
  else if (a = 'lastlogon') or (a = 'lastlogontimestamp') or (a = 'lastlogoff') or
    (a = 'badpasswordtime') or (a = 'msds-lastsuccessfulinteractivelogontime') or
    (a = 'msds-lastfailedinteractivelogontime') then
  begin
    if AValue = 0 then Result := rsSentNever;
  end;
end;

function FormatUtcOffset(AMinutes: Integer): string;
var
  m: Integer;
  sign: Char;
begin
  if AMinutes < 0 then sign := '-' else sign := '+';
  m := Abs(AMinutes);
  Result := Format('%s%.2d:%.2d', [sign, m div 60, m mod 60]);
end;

function DateText(ADate: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd hh":"nn":"ss', ADate);
end;

function LocalLine(AUtc: TDateTime; AToLocal: TUtcToLocalFunc): string;
var
  loc: TDateTime;
  off: Integer;
begin
  if Assigned(AToLocal) and AToLocal(AUtc, loc, off) then
    Result := Format(rsDetLocal, [DateText(loc), FormatUtcOffset(off)])
  else
    Result := rsDetLocalUnknown;
end;

procedure AddDetail(var V: TAttributeValueView; const ALine: string);
begin
  SetLength(V.Details, Length(V.Details) + 1);
  V.Details[High(V.Details)] := ALine;
end;

function GridText(const S: string): string;
begin
  if Length(S) > CODEC_GRID_MAX_CHARS then
    Result := Format(rsDisplayTruncated, [Copy(S, 1, CODEC_GRID_MAX_CHARS), Length(S)])
  else
    Result := S;
end;

function BinaryDisplay(const AValue: RawByteString): string;
begin
  if AValue = '' then Exit(rsDisplayEmpty);
  if Length(AValue) <= CODEC_GRID_HEX_BYTES then
    Result := Format(rsDisplayBinary, [Length(AValue), HexEncode(AValue)])
  else
    Result := Format(rsDisplayBinaryMore, [Length(AValue), HexEncode(Copy(AValue, 1, CODEC_GRID_HEX_BYTES))]);
end;

// Texte echappe borne a AMax octets: une valeur de 16 Mio n'a rien a faire dans une
// cellule.
function SafeText(const AValue: RawByteString; AMax: Integer): string;
begin
  if Length(AValue) > AMax then
    Result := EscapeControlChars(Copy(AValue, 1, AMax))
  else
    Result := EscapeControlChars(AValue);
end;

function HasControl(const AValue: RawByteString): Boolean;
var
  i: Integer;
begin
  for i := 1 to Length(AValue) do
    if (Byte(AValue[i]) < 32) or (Byte(AValue[i]) = 127) then Exit(True);
  Result := False;
end;

function RangeDiagnostic(const ARes: TValueResolution; AValue: Int64): string;
begin
  Result := '';
  if ARes.HasRangeLower and (AValue < ARes.RangeLower) then
    Result := Format(rsDiagBelowRange, [ARes.RangeLower])
  else if ARes.HasRangeUpper and (AValue > ARes.RangeUpper) then
    Result := Format(rsDiagAboveRange, [ARes.RangeUpper]);
end;

procedure MarkInvalid(var V: TAttributeValueView; const AShown, AReason: string);
begin
  V.Valid := False;
  V.Diagnostic := AReason;
  V.Display := GridText(Format(rsDisplayInvalid, [AShown, ValueKindName(V.Resolution.Kind), AReason]));
  V.TextFaithful := False;
end;

function ViewValue(const ARes: TValueResolution; const AAttrDescription: string;
  const AValue: RawByteString; AMasked: Boolean; AToLocal: TUtcToLocalFunc): TAttributeValueView;
var
  s, t, err, sent: string;
  fits: Boolean;
  iv: Int64;
  gt: TGeneralizedTime;
  utc: TDateTime;
  rem: Integer;
  dn: TLdapDn;
  i: Integer;
  sd: TSecurityDescriptor;
  sdLines: TStringArray;
begin
  Result := Default(TAttributeValueView);
  Result.Bytes := AValue;
  Result.Resolution := ARes;
  Result.Valid := True;
  if AMasked then
  begin
    Result.Masked := True;
    Result.Display := MASK_TEXT;
    Exit;
  end;
  AddDetail(Result, Format(rsDetType, [ValueKindName(ARes.Kind)]));
  AddDetail(Result, Format(rsDetSource, [ARes.Detail]));
  AddDetail(Result, Format(rsDetBytes, [Length(AValue)]));
  if (ARes.Kind in [vkText, vkBoolean, vkInteger, vkDn, vkGeneralizedTime, vkAdFileTime,
     vkAdInterval]) and not IsValidUtf8(AValue) then
  begin
    Result.Valid := ARes.Kind = vkText;
    Result.Diagnostic := rsDiagNotUtf8;
    Result.Display := BinaryDisplay(AValue);
    Result.TextFaithful := False;
    Exit;
  end;
  s := string(AValue);
  case ARes.Kind of
    vkText:
      begin
        t := SafeText(AValue, CODEC_GRID_MAX_CHARS + 1);
        Result.Display := GridText(t);
        Result.TextFaithful := (Length(AValue) <= CODEC_GRID_MAX_CHARS) and not HasControl(AValue);
        if AValue = '' then Result.Display := '';
        if HasControl(AValue) then Result.Diagnostic := rsDiagControl;
      end;
    vkBoolean:
      begin
        Result.Display := s;
        Result.TextFaithful := True;
        if (s <> 'TRUE') and (s <> 'FALSE') then MarkInvalid(Result, SafeText(AValue, 64), rsDiagBoolean);
      end;
    vkInteger:
      begin
        Result.Display := GridText(s);
        Result.TextFaithful := Length(s) <= CODEC_GRID_MAX_CHARS;
        if not CheckLdapInteger(s, fits, iv) then
          MarkInvalid(Result, SafeText(AValue, 64), rsDiagIntSyntax)
        else if not fits then
          Result.Diagnostic := rsDiagIntBeyond
        else
        begin
          err := RangeDiagnostic(ARes, iv);
          if err <> '' then Result.Diagnostic := err;
        end;
      end;
    vkDn:
      begin
        Result.Display := GridText(SafeText(AValue, CODEC_GRID_MAX_CHARS + 1));
        Result.TextFaithful := (Length(AValue) <= CODEC_GRID_MAX_CHARS) and not HasControl(AValue);
        if not DnParse(s, dn, err, dpmStrict) then
          MarkInvalid(Result, SafeText(AValue, 256), err)
        else
          for i := 0 to DnRdnCount(dn) - 1 do
            AddDetail(Result, Format(rsDetRdn, [i + 1, RdnToString(dn.Rdns[i])]));
      end;
    vkGeneralizedTime:
      begin
        if not ParseGeneralizedTimeEx(s, gt, err) then
          MarkInvalid(Result, SafeText(AValue, 64), Format(rsDiagGenTime, [err]))
        else if not gt.Representable then
        begin
          Result.Display := s;
          Result.TextFaithful := True;
          Result.Diagnostic := Format(rsDiagNotRepresentable, [gt.Year]);
        end
        else
        begin
          Result.Display := Format(rsDisplayInterp, [s, DateText(gt.UtcDate) + ' UTC']);
          AddDetail(Result, Format(rsDetOriginal, [s]));
          AddDetail(Result, Format(rsDetUtc, [DateText(gt.UtcDate)]));
          AddDetail(Result, LocalLine(gt.UtcDate, AToLocal));
          if gt.Fraction <> '' then
          begin
            case gt.FractionOf of
              'h': t := rsDetHour;
              'm': t := rsDetMinute;
            else
              t := rsDetSecond;
            end;
            AddDetail(Result, Format(rsDetFraction, [t, gt.Fraction]));
          end;
          if not gt.Utc then AddDetail(Result, Format(rsDetOffset, [FormatUtcOffset(gt.OffsetMinutes)]));
          if gt.LeapSecond then Result.Diagnostic := rsDiagLeapSecond;
        end;
      end;
    vkAdFileTime:
      begin
        if not CheckLdapInteger(s, fits, iv) or not fits then
          MarkInvalid(Result, SafeText(AValue, 64), rsDiagIntSyntax)
        else
        begin
          AddDetail(Result, Format(rsDetOriginal, [s]));
          sent := AdFileTimeSentinel(AAttrDescription, iv);
          if sent <> '' then
          begin
            Result.Display := Format(rsDisplayInterp, [s, sent]);
            AddDetail(Result, Format(rsDetSentinel, [sent]));
          end
          else if iv < 0 then
            MarkInvalid(Result, s, rsDiagFileTimeNegative)
          else if not FileTimeToDate(iv, utc, rem) then
          begin
            Result.Display := s;
            Result.Diagnostic := rsDiagFileTimeRange;
          end
          else
          begin
            t := DateText(utc);
            if rem <> 0 then t := t + '.' + Format('%.7d', [rem]);
            Result.Display := Format(rsDisplayInterp, [s, t + ' UTC']);
            AddDetail(Result, Format(rsDetUtc, [t]));
            AddDetail(Result, LocalLine(utc, AToLocal));
          end;
        end;
      end;
    vkAdInterval:
      begin
        if not CheckLdapInteger(s, fits, iv) or not fits then
          MarkInvalid(Result, SafeText(AValue, 64), rsDiagIntSyntax)
        else
        begin
          t := AdIntervalText(s);
          Result.Display := Format(rsDisplayInterp, [s, t]);
          AddDetail(Result, Format(rsDetOriginal, [s]));
          AddDetail(Result, Format(rsDetInterval, [t]));
        end;
      end;
    vkSid:
      begin
        if SidToText(AValue, t, err) then
        begin
          Result.Display := t;
          AddDetail(Result, t);
          AddDetail(Result, Format(rsDetSidParts, [Byte(AValue[1]), SidAuthorityText(t),
            Byte(AValue[2])]));
          if Byte(AValue[2]) > 0 then
            AddDetail(Result, Format(rsDetRid, [ReadUInt32LE(AValue, Length(AValue) - 3)]));
        end
        else
          MarkInvalid(Result, BinaryDisplay(AValue), Format(rsDiagSid, [err]));
      end;
    vkGuid:
      begin
        if GuidToText(AValue, t) then
        begin
          Result.Display := t;
          AddDetail(Result, t);
        end
        else
        begin
          Result.Valid := False;
          Result.Display := BinaryDisplay(AValue);
          Result.Diagnostic := Format(rsDiagGuidLength, [Length(AValue)]);
        end;
      end;
    vkBinary:
      begin
        // Octet String souvent textuel (hash {SSHA}, identifiants): l'imprimable est
        // montre tel quel, le reste en hexadecimal. Affichage seulement, jamais d'edition
        // en place: un octet mal relu, et le hash ne correspond plus a rien.
        if (AValue <> '') and IsValidUtf8(AValue) and not HasControl(AValue) then
        begin
          Result.Display := GridText(SafeText(AValue, CODEC_GRID_MAX_CHARS + 1));
          AddDetail(Result, Format(rsDetText, [SafeText(AValue, VALUE_TEXT_DETAIL_CHARS)]));
        end
        else
          Result.Display := BinaryDisplay(AValue);
      end;
    vkSecurityDescriptor:
      begin
        Result.Display := Format(rsDisplaySd, [Length(AValue)]);
        sd := ParseSecurityDescriptor(AValue, SI_OWNER or SI_GROUP or SI_DACL or SI_SACL);
        sdLines := DescribeSecurityDescriptor(sd);
        for i := 0 to High(sdLines) do
          AddDetail(Result, sdLines[i]);
        if not sd.Valid or sd.Partial then
        begin
          Result.Valid := sd.Valid;
          Result.Diagnostic := sd.Error;
        end;
      end;
    vkCertificate:
      Result.Display := Format(rsDisplayCert, [Length(AValue)]);
  end;
end;

function ValidateValue(const ARes: TValueResolution; const AValue: RawByteString): string;
var
  v: TAttributeValueView;
  fits: Boolean;
  iv: Int64;
begin
  Result := '';
  if not (ARes.Kind in [vkBoolean, vkInteger, vkDn, vkGeneralizedTime, vkAdFileTime,
    vkAdInterval, vkSid, vkGuid]) then Exit;
  v := ViewValue(ARes, '', AValue, False, nil);
  if not v.Valid then Exit(v.Diagnostic);
  if (ARes.Kind = vkInteger) and CheckLdapInteger(string(AValue), fits, iv) and fits then
    Result := RangeDiagnostic(ARes, iv);
end;

function EditableText(const ARes: TValueResolution; const AValue: RawByteString): string;
var
  err: string;
begin
  case ARes.Kind of
    vkSid:
      if not SidToText(AValue, Result, err) then Result := '';
    vkGuid:
      if not GuidToText(AValue, Result) then Result := '';
    vkBinary, vkCertificate, vkSecurityDescriptor:
      Result := HexEncode(AValue);
  else
    Result := string(AValue);
  end;
end;

function AdaptLineEndings(const AEdited: string; const AOriginal: RawByteString): RawByteString;
begin
  if Pos(#13#10, AOriginal) > 0 then
    Result := StringReplace(StringReplace(AEdited, #13#10, #10, [rfReplaceAll]), #10, #13#10, [rfReplaceAll])
  else
    Result := StringReplace(AEdited, #13#10, #10, [rfReplaceAll]);
end;

function EncodeTyped(const ARes: TValueResolution; const AInput: string;
  const AOriginal: RawByteString; out ABytes: RawByteString; out AError: string): Boolean;
var
  err: string;
begin
  ABytes := '';
  AError := '';
  Result := False;
  case ARes.Kind of
    vkText:
      // Aucun trim: espaces et retours saisis sont des octets voulus, pas des fautes de
      // frappe a corriger dans le dos de l'admin.
      ABytes := AdaptLineEndings(AInput, AOriginal);
    vkSid:
      if not SidFromText(Trim(AInput), ABytes, err) then
      begin
        AError := Format(rsDiagSid, [err]);
        Exit;
      end;
    vkGuid:
      if not GuidFromText(AInput, ABytes) then
      begin
        AError := rsDiagGuidText;
        Exit;
      end;
    vkBinary:
      if not HexInputDecode(AInput, VALUE_MAX_BYTES, ABytes, AError) then Exit;
    vkBoolean, vkInteger, vkDn, vkGeneralizedTime, vkAdFileTime, vkAdInterval:
      ABytes := AInput;
  else
    AError := rsDiagNotEditable;
    Exit;
  end;
  if Length(ABytes) > VALUE_MAX_BYTES then
  begin
    AError := Format(rsDiagTooLarge, [VALUE_MAX_BYTES]);
    ABytes := '';
    Exit;
  end;
  AError := ValidateValue(ARes, ABytes);
  Result := AError = '';
  if not Result then ABytes := '';
end;

function HexInputDecode(const S: string; AMaxBytes: Int64; out ABytes: RawByteString;
  out AError: string): Boolean;
var
  i, n: Integer;
  compact: string;
begin
  Result := False;
  ABytes := '';
  AError := '';
  n := 0;
  for i := 1 to Length(S) do
    if S[i] in ['0'..'9', 'a'..'f', 'A'..'F'] then Inc(n)
    else if not (S[i] in [' ', #9, #10, #13]) then
    begin
      AError := rsDiagHex;
      Exit;
    end;
  if Odd(n) then
  begin
    AError := rsDiagHex;
    Exit;
  end;
  // Taille decodee verifiee avant toute allocation: un collage de 2 Go n'a pas a devenir
  // un probleme de RAM.
  if n div 2 > AMaxBytes then
  begin
    AError := Format(rsDiagTooLarge, [AMaxBytes]);
    Exit;
  end;
  SetLength(compact, n);
  n := 0;
  for i := 1 to Length(S) do
    if S[i] in ['0'..'9', 'a'..'f', 'A'..'F'] then
    begin
      Inc(n);
      compact[n] := S[i];
    end;
  Result := HexDecode(compact, ABytes);
  if not Result then AError := rsDiagHex;
end;

function HexDump(const ABytes: RawByteString; AMaxBytes: Integer): string;
var
  n, off, i: Integer;
  line, ascii: string;
  b: Byte;
  sb: TAnsiStringBuilder;
begin
  n := Length(ABytes);
  if (AMaxBytes >= 0) and (n > AMaxBytes) then n := AMaxBytes;
  sb := TAnsiStringBuilder.Create;
  try
    off := 0;
    while off < n do
    begin
      line := IntToHex(off, 8) + '  ';
      ascii := '';
      for i := 0 to 15 do
      begin
        if off + i < n then
        begin
          b := Byte(ABytes[off + i + 1]);
          line := line + LowerCase(IntToHex(b, 2)) + ' ';
          if (b >= 32) and (b < 127) then ascii := ascii + Char(b) else ascii := ascii + '.';
        end
        else
          line := line + '   ';
        if i = 7 then line := line + ' ';
      end;
      sb.Append(line + ' |' + ascii + '|' + LineEnding);
      Inc(off, 16);
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

end.
