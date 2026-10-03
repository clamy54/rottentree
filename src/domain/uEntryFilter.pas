// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uEntryFilter;

{$mode objfpc}{$H+}

// Evaluation locale d'un filtre RFC 4515 sur un fichier LDIF, sans serveur,
// en logique a trois valeurs (RFC 4511 4.5.1.7). Sans schema, les regles
// viennent d'une table des attributs courants. Repliement de casse simple, pas
// celui de la RFC 4518. Regles AD BIT_AND, BIT_OR et IN_CHAIN comprises.

interface

uses
  SysUtils, Classes, uLdapEntry, uLdapFilter, uLdapDn;

const
  MATCHING_RULE_BIT_AND = '1.2.840.113556.1.4.803';
  MATCHING_RULE_BIT_OR = '1.2.840.113556.1.4.804';
  MATCHING_RULE_IN_CHAIN = '1.2.840.113556.1.4.1941';
  // IN_CHAIN borne: un fichier peut contenir des chaines de liens sans fin, par
  // accident ou par malice.
  IN_CHAIN_MAX_VISITS = 10000;

type
  TFilterResult = (frFalse, frTrue, frUndefined);

  TMatchKind = (mkCaseIgnore, mkCaseExact, mkOctet, mkInteger, mkGeneralizedTime,
    mkDn, mkObjectIdentifier, mkTelephone, mkBoolean, mkNumericString, mkUuid);

  TValueArray = array of RawByteString;

  TComputedValues = function(AEntry: TLdapEntry; const ABase: string;
    out AValues: TValueArray): Boolean of object;
  TEntryByDn = function(const ADn: string): TLdapEntry of object;
  TAttrKindOf = function(const AAttr: string; out AKind: TMatchKind): Boolean of object;

  TFilterContext = record
    Computed: TComputedValues;
    EntryByDn: TEntryByDn;
    KindOf: TAttrKindOf;
  end;

function AttrMatchKind(const AAttr: string; out AKnown: Boolean): TMatchKind;
function NormalizeForMatch(AKind: TMatchKind; const AValue: RawByteString;
  out ANorm: RawByteString): Boolean;
function Utf8LowerSimple(const S: RawByteString): RawByteString;
function RdnMatchKey(const ARdn: TDnRdn): string;
function DnMatchKey(const ADn: TLdapDn): string;
function DnStringMatchKey(const S: string; out AKey: string): Boolean;
function MatchKindFromRuleName(const ARule: string; out AKind: TMatchKind): Boolean;
function EvaluateFilter(AFilter: TFilterNode; AEntry: TLdapEntry;
  const ACtx: TFilterContext): TFilterResult;

implementation

uses
  uRtBytes, uMatchingRules;

var
  GKinds: TStringList = nil;

procedure AddKind(AKind: TMatchKind; const ANames: array of string);
var
  i: Integer;
begin
  for i := 0 to High(ANames) do
    GKinds.AddObject(ANames[i], TObject(PtrInt(Ord(AKind))));
end;

procedure BuildKinds;
begin
  GKinds := TStringList.Create;
  GKinds.CaseSensitive := False;
  GKinds.Sorted := True;
  GKinds.Duplicates := dupIgnore;
  AddKind(mkInteger, ['uidNumber', 'gidNumber', 'shadowLastChange', 'shadowMin',
    'shadowMax', 'shadowWarning', 'shadowInactive', 'shadowExpire', 'shadowFlag',
    'ipServicePort', 'ipProtocolNumber', 'oncRpcNumber', 'sambaPwdLastSet',
    'sambaPwdCanChange', 'sambaPwdMustChange', 'sambaLogonTime', 'sambaLogoffTime',
    'sambaKickoffTime', 'sambaBadPasswordCount', 'sambaBadPasswordTime',
    'userAccountControl', 'groupType', 'sAMAccountType', 'adminCount', 'primaryGroupID',
    'badPwdCount', 'logonCount', 'pwdLastSet', 'lastLogon', 'lastLogonTimestamp',
    'lastLogoff', 'accountExpires', 'lockoutTime', 'badPasswordTime', 'uSNChanged',
    'uSNCreated', 'instanceType', 'systemFlags', 'msDS-SupportedEncryptionTypes',
    'msDS-User-Account-Control-Computed', 'codePage', 'countryCode', 'maxPwdAge',
    'minPwdAge', 'minPwdLength', 'pwdHistoryLength', 'lockoutDuration',
    'lockoutThreshold', 'lockOutObservationWindow', 'pwdProperties', 'numSubordinates',
    'msDS-Approx-Immed-Subordinates', 'pwdMaxAge', 'pwdMinAge', 'pwdInHistory',
    'pwdMaxFailure', 'pwdLockoutDuration', 'pwdMinLength', 'pwdMaxLength',
    'pwdGraceAuthNLimit', 'pwdExpireWarning', 'pwdFailureCountInterval', 'pwdMaxIdle',
    'pwdMinDelay', 'pwdMaxDelay', 'pwdMaxRecordedFailure', 'pwdCheckQuality']);
  AddKind(mkGeneralizedTime, ['createTimestamp', 'modifyTimestamp', 'whenCreated',
    'whenChanged', 'pwdChangedTime', 'pwdAccountLockedTime', 'pwdFailureTime',
    'pwdGraceUseTime', 'authTimestamp', 'pwdLastSuccess', 'dSCorePropagationData',
    'pwdStartTime', 'pwdEndTime', 'krbPasswordExpiration', 'krbLastPwdChange',
    'krbLastSuccessfulAuth', 'krbLastFailedAuth', 'krbPrincipalExpiration']);
  AddKind(mkOctet, ['userPassword', 'unicodePwd', 'objectGUID', 'objectSid', 'jpegPhoto',
    'photo', 'userCertificate', 'cACertificate', 'certificateRevocationList',
    'authorityRevocationList', 'crossCertificatePair', 'userSMIMECertificate',
    'userPKCS12', 'audio', 'thumbnailPhoto', 'nTSecurityDescriptor', 'sIDHistory',
    'tokenGroups', 'msExchMailboxGuid', 'logonHours', 'supplementalCredentials',
    'dBCSPwd', 'lmPwdHistory', 'ntPwdHistory', 'krbPrincipalKey', 'authPassword',
    'pwdHistory']);
  AddKind(mkDn, ['member', 'uniqueMember', 'owner', 'seeAlso', 'manager', 'secretary',
    'roleOccupant', 'memberOf', 'modifiersName', 'creatorsName', 'distinguishedName',
    'managedBy', 'directReports', 'aliasedObjectName', 'entryDN', 'subschemaSubentry',
    'pwdPolicySubentry', 'namingContexts', 'objectCategory', 'defaultObjectCategory',
    'msDS-AuthenticatedAtDC', 'serverReference', 'homeMDB', 'publicDelegates',
    'altRecipient', 'nisMember', 'hasMember', 'msDS-MembersForAzRole']);
  AddKind(mkObjectIdentifier, ['objectClass', 'structuralObjectClass', 'supportedControl',
    'supportedExtension', 'supportedFeatures', 'supportedCapabilities']);
  AddKind(mkTelephone, ['telephoneNumber', 'facsimileTelephoneNumber', 'mobile',
    'homePhone', 'pager', 'otherTelephone', 'otherMobile', 'otherHomePhone',
    'otherFacsimileTelephoneNumber', 'ipPhone', 'otherIpPhone', 'otherPager',
    'homeTelephoneNumber', 'mobileTelephoneNumber', 'pagerTelephoneNumber']);
  AddKind(mkBoolean, ['hasSubordinates', 'pwdReset', 'pwdLockout', 'pwdMustChange',
    'pwdAllowUserChange', 'pwdSafeModify', 'isDeleted', 'showInAdvancedViewOnly',
    'isCriticalSystemObject', 'isRecycled']);
  AddKind(mkCaseExact, ['homeDirectory', 'loginShell', 'memberUid', 'automountInformation',
    'labeledURI']);
  AddKind(mkUuid, ['entryUUID']);
end;

function AttrMatchKind(const AAttr: string; out AKnown: Boolean): TMatchKind;
var
  i: Integer;
begin
  i := GKinds.IndexOf(AttrBaseName(AAttr));
  AKnown := i >= 0;
  if AKnown then
    Result := TMatchKind(PtrInt(GKinds.Objects[i]))
  else
    Result := mkCaseIgnore;
end;

function LowerCodePoint(cp: Cardinal): Cardinal;
begin
  Result := cp;
  case cp of
    $C0..$D6, $D8..$DE: Result := cp + $20;
    $100..$12F, $132..$137, $14A..$177:
      if not Odd(cp) then Result := cp + 1;
    $139..$148, $179..$17E:
      if Odd(cp) then Result := cp + 1;
    $178: Result := $FF;
    $391..$3A1, $3A3..$3A9: Result := cp + $20;
    $400..$40F: Result := cp + $50;
    $410..$42F: Result := cp + $20;
  end;
end;

function Utf8LowerSimple(const S: RawByteString): RawByteString;
var
  i, n: Integer;
  b1, b2: Byte;
  cp: Cardinal;
begin
  Result := S;
  UniqueString(Result);
  n := Length(Result);
  i := 1;
  while i <= n do
  begin
    b1 := Byte(Result[i]);
    if b1 < $80 then
    begin
      if Result[i] in ['A'..'Z'] then
        Result[i] := Chr(b1 + 32);
      Inc(i);
    end
    else if (b1 and $E0 = $C0) and (i < n) and (Byte(Result[i + 1]) and $C0 = $80) then
    begin
      b2 := Byte(Result[i + 1]);
      cp := ((b1 and $1F) shl 6) or (b2 and $3F);
      cp := LowerCodePoint(cp);
      Result[i] := Chr($C0 or (cp shr 6));
      Result[i + 1] := Chr($80 or (cp and $3F));
      Inc(i, 2);
    end
    else
      Inc(i);
  end;
end;

function AsciiLower(const S: RawByteString): RawByteString;
var
  i: Integer;
begin
  Result := S;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then
      Result[i] := Chr(Ord(Result[i]) + 32);
end;

function CollapseSpaces(const S: RawByteString): RawByteString;
var
  i: Integer;
  lastSpace: Boolean;
begin
  Result := '';
  lastSpace := False;
  for i := 1 to Length(S) do
  begin
    if S[i] = ' ' then
    begin
      if not lastSpace then Result := Result + ' ';
      lastSpace := True;
    end
    else
    begin
      Result := Result + S[i];
      lastSpace := False;
    end;
  end;
end;

function StripChars(const S: RawByteString; const AChars: TSysCharSet): RawByteString;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    if not (S[i] in AChars) then
      Result := Result + S[i];
end;

function NormalizeForMatch(AKind: TMatchKind; const AValue: RawByteString;
  out ANorm: RawByteString): Boolean;
var
  n: Int64;
  d: TLdapDn;
  err: string;
  t: RawByteString;
begin
  Result := True;
  ANorm := '';
  case AKind of
    mkCaseIgnore:
      ANorm := Utf8LowerSimple(PrepareSpacesAscii(AValue));
    mkCaseExact:
      ANorm := PrepareSpacesAscii(AValue);
    mkOctet:
      ANorm := AValue;
    mkInteger:
      begin
        Result := TryStrToInt64(Trim(AValue), n);
        if Result then ANorm := IntToStr(n);
      end;
    mkGeneralizedTime:
      begin
        Result := ParseGeneralizedTime(Trim(AValue), t);
        if Result then ANorm := t;
      end;
    mkDn:
      begin
        Result := DnParse(AValue, d, err);
        if Result then ANorm := DnMatchKey(d);
      end;
    mkObjectIdentifier:
      ANorm := AsciiLower(Trim(AValue));
    mkTelephone:
      ANorm := Utf8LowerSimple(StripChars(AValue, [' ', '-']));
    mkBoolean:
      begin
        t := UpperCase(Trim(AValue));
        Result := (t = 'TRUE') or (t = 'FALSE');
        if Result then ANorm := t;
      end;
    mkNumericString:
      ANorm := StripChars(AValue, [' ']);
    mkUuid:
      ANorm := AsciiLower(Trim(AValue));
  end;
end;

function SubstringForm(AKind: TMatchKind; const S: RawByteString; AWhole: Boolean): RawByteString;
begin
  case AKind of
    mkCaseExact:
      if AWhole then Result := PrepareSpacesAscii(S) else Result := CollapseSpaces(S);
    mkOctet:
      Result := S;
    mkTelephone:
      Result := Utf8LowerSimple(StripChars(S, [' ', '-']));
    mkNumericString:
      Result := StripChars(S, [' ']);
  else
    // Sans casse, y compris DN et nombres: chercher un morceau de texte sert plus ici
    // que le refus d'un serveur sans regle SUBSTR.
    if AWhole then
      Result := Utf8LowerSimple(PrepareSpacesAscii(S))
    else
      Result := Utf8LowerSimple(CollapseSpaces(S));
  end;
end;

function AvaMatchKey(const AAva: TDnAva): string;
var
  known: Boolean;
  norm: RawByteString;
  t: string;
begin
  t := AsciiLower(AAva.AttrType);
  if AAva.HexForm then
    Exit(t + '=#' + HexEncode(AAva.Value));
  if not NormalizeForMatch(AttrMatchKind(t, known), AAva.Value, norm) then
    norm := AAva.Value;
  // Longueur en prefixe: une valeur contenant ',', '+' ou '=' ne peut pas se faire
  // passer pour deux AVA.
  Result := t + '=' + IntToStr(Length(norm)) + ':' + norm;
end;

function RdnMatchKey(const ARdn: TDnRdn): string;
var
  parts: array of string;
  i, k: Integer;
  tmp: string;
begin
  parts := nil;
  SetLength(parts, Length(ARdn.Avas));
  for i := 0 to High(ARdn.Avas) do
    parts[i] := AvaMatchKey(ARdn.Avas[i]);
  for i := 1 to High(parts) do
  begin
    tmp := parts[i];
    k := i - 1;
    while (k >= 0) and (parts[k] > tmp) do
    begin
      parts[k + 1] := parts[k];
      Dec(k);
    end;
    parts[k + 1] := tmp;
  end;
  Result := '';
  for i := 0 to High(parts) do
  begin
    if i > 0 then Result := Result + '+';
    Result := Result + parts[i];
  end;
end;

function DnMatchKey(const ADn: TLdapDn): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(ADn.Rdns) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + RdnMatchKey(ADn.Rdns[i]);
  end;
end;

function DnStringMatchKey(const S: string; out AKey: string): Boolean;
var
  d: TLdapDn;
  err: string;
begin
  AKey := '';
  Result := DnParse(S, d, err);
  if Result then AKey := DnMatchKey(d);
end;

function KindFor(const ACtx: TFilterContext; const AAttr: string; out AKnown: Boolean): TMatchKind;
begin
  if Assigned(ACtx.KindOf) and ACtx.KindOf(AttrBaseName(AAttr), Result) then
  begin
    AKnown := True;
    Exit;
  end;
  Result := AttrMatchKind(AAttr, AKnown);
end;

function Combine(AIsAnd: Boolean; const AItems: array of TFilterResult): TFilterResult;
var
  i: Integer;
  undef: Boolean;
begin
  undef := False;
  for i := 0 to High(AItems) do
  begin
    if AIsAnd and (AItems[i] = frFalse) then Exit(frFalse);
    if (not AIsAnd) and (AItems[i] = frTrue) then Exit(frTrue);
    if AItems[i] = frUndefined then undef := True;
  end;
  if undef then Exit(frUndefined);
  if AIsAnd then Result := frTrue else Result := frFalse;
end;

function ValuesFor(AEntry: TLdapEntry; const ADescription: string;
  const ACtx: TFilterContext; out AValues: TValueArray): Boolean;
var
  want: TAttrDescription;
  i, j, k, n: Integer;
  a: TLdapAttribute;
  ok: Boolean;
  lb: string;
begin
  AValues := nil;
  want := ParseAttrDescription(ADescription);
  // Valeurs calculees (hasSubordinates...) avant celles du fichier, qui datent de
  // l'export: le filtre voit ce que la lecture rend, pas un fossile.
  if (Length(want.Options) = 0) and Assigned(ACtx.Computed) and
     ACtx.Computed(AEntry, want.Base, AValues) then
    Exit(True);
  lb := AsciiLowerCase(want.Base);
  Result := False;
  n := 0;
  for i := 0 to AEntry.AttrCount - 1 do
  begin
    a := AEntry.Attrs[i];
    if AsciiLowerCase(a.BaseName) <> lb then Continue;
    ok := True;
    for j := 0 to High(want.Options) do
      if not a.HasOption(want.Options[j]) then
      begin
        ok := False;
        Break;
      end;
    if not ok then Continue;
    Result := True;
    SetLength(AValues, n + a.ValueCount);
    for k := 0 to a.ValueCount - 1 do
    begin
      AValues[n] := a.Values[k];
      Inc(n);
    end;
  end;
end;

function EvalEquality(AEntry: TLdapEntry; AFilter: TFilterNode;
  const ACtx: TFilterContext): TFilterResult;
var
  kind: TMatchKind;
  known, undef: Boolean;
  values: TValueArray;
  wanted, norm: RawByteString;
  i: Integer;
begin
  kind := KindFor(ACtx, AFilter.Attr, known);
  if not NormalizeForMatch(kind, AFilter.Value, wanted) then Exit(frUndefined);
  if not ValuesFor(AEntry, AFilter.Attr, ACtx, values) then Exit(frFalse);
  undef := False;
  for i := 0 to High(values) do
    if NormalizeForMatch(kind, values[i], norm) then
    begin
      if norm = wanted then Exit(frTrue);
    end
    else
      undef := True;
  if undef then Result := frUndefined else Result := frFalse;
end;

function CompareTimes(const A, B: RawByteString): Integer;
var
  ia, ib, fa, fb: RawByteString;
  p: Integer;
begin
  ia := Copy(A, 1, 14);
  ib := Copy(B, 1, 14);
  Result := CompareStr(ia, ib);
  if Result <> 0 then Exit;
  fa := '';
  fb := '';
  p := Pos('.', A);
  if p > 0 then fa := Copy(A, p + 1, Length(A) - p - 1);
  p := Pos('.', B);
  if p > 0 then fb := Copy(B, p + 1, Length(B) - p - 1);
  while Length(fa) < Length(fb) do fa := fa + '0';
  while Length(fb) < Length(fa) do fb := fb + '0';
  Result := CompareStr(fa, fb);
end;

function EvalOrdering(AEntry: TLdapEntry; AFilter: TFilterNode;
  const ACtx: TFilterContext; AGreater: Boolean): TFilterResult;
var
  kind: TMatchKind;
  known, undef, numeric: Boolean;
  values: TValueArray;
  wanted, norm: RawByteString;
  wantedInt, v: Int64;
  i, c: Integer;
begin
  kind := KindFor(ACtx, AFilter.Attr, known);
  if kind in [mkDn, mkOctet, mkBoolean, mkUuid] then Exit(frUndefined);
  numeric := (kind = mkInteger) or
    ((not known) and TryStrToInt64(Trim(AFilter.Value), wantedInt));
  if numeric then
  begin
    if not TryStrToInt64(Trim(AFilter.Value), wantedInt) then Exit(frUndefined);
  end
  else if not NormalizeForMatch(kind, AFilter.Value, wanted) then
    Exit(frUndefined);
  if not ValuesFor(AEntry, AFilter.Attr, ACtx, values) then Exit(frFalse);
  undef := False;
  for i := 0 to High(values) do
  begin
    if numeric then
    begin
      if not TryStrToInt64(Trim(values[i]), v) then
      begin
        undef := True;
        Continue;
      end;
      if v < wantedInt then c := -1 else if v > wantedInt then c := 1 else c := 0;
    end
    else
    begin
      if not NormalizeForMatch(kind, values[i], norm) then
      begin
        undef := True;
        Continue;
      end;
      if kind = mkGeneralizedTime then
        c := CompareTimes(norm, wanted)
      else
        c := CompareStr(norm, wanted);
    end;
    if AGreater and (c >= 0) then Exit(frTrue);
    if (not AGreater) and (c <= 0) then Exit(frTrue);
  end;
  if undef then Result := frUndefined else Result := frFalse;
end;

function SubstringMatches(const AValue: RawByteString; AFilter: TFilterNode;
  AKind: TMatchKind): Boolean;
var
  v, part: RawByteString;
  p, i, q: Integer;
begin
  v := SubstringForm(AKind, AValue, True);
  p := 1;
  if AFilter.HasInitial then
  begin
    part := SubstringForm(AKind, AFilter.SubInitial, False);
    if Copy(v, 1, Length(part)) <> part then Exit(False);
    p := Length(part) + 1;
  end;
  for i := 0 to High(AFilter.SubAny) do
  begin
    part := SubstringForm(AKind, AFilter.SubAny[i], False);
    if part = '' then Continue;
    q := Pos(part, Copy(v, p, MaxInt));
    if q = 0 then Exit(False);
    p := p + q - 1 + Length(part);
  end;
  if AFilter.HasFinal then
  begin
    part := SubstringForm(AKind, AFilter.SubFinal, False);
    if Length(v) - Length(part) + 1 < p then Exit(False);
    if Copy(v, Length(v) - Length(part) + 1, Length(part)) <> part then Exit(False);
  end;
  Result := True;
end;

function EvalSubstrings(AEntry: TLdapEntry; AFilter: TFilterNode;
  const ACtx: TFilterContext): TFilterResult;
var
  kind: TMatchKind;
  known: Boolean;
  values: TValueArray;
  i: Integer;
begin
  kind := KindFor(ACtx, AFilter.Attr, known);
  if not ValuesFor(AEntry, AFilter.Attr, ACtx, values) then Exit(frFalse);
  for i := 0 to High(values) do
    if SubstringMatches(values[i], AFilter, kind) then Exit(frTrue);
  Result := frFalse;
end;

function EvalPresent(AEntry: TLdapEntry; AFilter: TFilterNode;
  const ACtx: TFilterContext): TFilterResult;
var
  values: TValueArray;
begin
  // Toute entree a une classe (RFC 4512 2.4.1), meme si le fichier l'a oubliee.
  if AsciiLowerCase(AFilter.Attr) = 'objectclass' then Exit(frTrue);
  if ValuesFor(AEntry, AFilter.Attr, ACtx, values) and (Length(values) > 0) then
    Result := frTrue
  else
    Result := frFalse;
end;

function KindFromRule(AKind: TRuleKind; out AMatch: TMatchKind): Boolean;
begin
  Result := True;
  case AKind of
    rkOctet: AMatch := mkOctet;
    rkCaseIgnore, rkCaseIgnoreIA5: AMatch := mkCaseIgnore;
    rkCaseExact, rkCaseExactIA5: AMatch := mkCaseExact;
    rkNumericString: AMatch := mkNumericString;
    rkInteger: AMatch := mkInteger;
    rkBoolean: AMatch := mkBoolean;
    rkGeneralizedTime: AMatch := mkGeneralizedTime;
    rkTelephone: AMatch := mkTelephone;
    rkDn: AMatch := mkDn;
    rkObjectIdentifier: AMatch := mkObjectIdentifier;
    rkUuid: AMatch := mkUuid;
  else
    Result := False;
  end;
end;

function MatchKindFromRuleName(const ARule: string; out AKind: TMatchKind): Boolean;
begin
  AKind := mkCaseIgnore;
  Result := KindFromRule(RuleKindFromName(ARule), AKind);
end;

type
  TExtRule = (erKind, erBitAnd, erBitOr, erInChain);

function InChain(AEntry: TLdapEntry; const AAttr: string; const AWantedKey: string;
  const ACtx: TFilterContext): TFilterResult;
var
  queue: TStringList;
  seen: TStringList;
  head, i: Integer;
  values: TValueArray;
  key: string;
  e: TLdapEntry;
begin
  if not Assigned(ACtx.EntryByDn) then Exit(frUndefined);
  queue := TStringList.Create;
  seen := TStringList.Create;
  try
    seen.Sorted := True;
    if ValuesFor(AEntry, AAttr, ACtx, values) then
      for i := 0 to High(values) do queue.Add(values[i]);
    head := 0;
    while head < queue.Count do
    begin
      if not DnStringMatchKey(queue[head], key) then
      begin
        Inc(head);
        Continue;
      end;
      if key = AWantedKey then Exit(frTrue);
      if seen.IndexOf(key) < 0 then
      begin
        if seen.Count >= IN_CHAIN_MAX_VISITS then Exit(frUndefined);
        seen.Add(key);
        e := ACtx.EntryByDn(queue[head]);
        if (e <> nil) and ValuesFor(e, AAttr, ACtx, values) then
          for i := 0 to High(values) do queue.Add(values[i]);
      end;
      Inc(head);
    end;
    Result := frFalse;
  finally
    seen.Free;
    queue.Free;
  end;
end;

function ValueMatchesRule(ARule: TExtRule; AKind: TMatchKind; const AValue,
  AWanted: RawByteString; AWantedInt: Int64; out AUndefined: Boolean): Boolean;
var
  v: Int64;
  norm: RawByteString;
begin
  Result := False;
  AUndefined := False;
  case ARule of
    erBitAnd, erBitOr:
      begin
        if not TryStrToInt64(Trim(AValue), v) then
        begin
          AUndefined := True;
          Exit;
        end;
        if ARule = erBitAnd then
          Result := (v and AWantedInt) = AWantedInt
        else
          Result := (v and AWantedInt) <> 0;
      end;
  else
    if NormalizeForMatch(AKind, AValue, norm) then
      Result := norm = AWanted
    else
      AUndefined := True;
  end;
end;

function EvalExtensible(AEntry: TLdapEntry; AFilter: TFilterNode;
  const ACtx: TFilterContext): TFilterResult;
var
  rule: TExtRule;
  kind: TMatchKind;
  known, undef, u: Boolean;
  lr: string;
  wanted: RawByteString;
  wantedInt: Int64;
  values: TValueArray;
  i, j, k: Integer;
  d: TLdapDn;
  err, chainKey: string;
  a: TLdapAttribute;
begin
  rule := erKind;
  kind := mkCaseIgnore;
  lr := AsciiLowerCase(Trim(AFilter.MatchingRule));
  if lr = MATCHING_RULE_BIT_AND then rule := erBitAnd
  else if lr = MATCHING_RULE_BIT_OR then rule := erBitOr
  else if lr = MATCHING_RULE_IN_CHAIN then rule := erInChain
  else if lr <> '' then
  begin
    if not KindFromRule(RuleKindFromName(lr), kind) then Exit(frUndefined);
  end
  else if AFilter.Attr <> '' then
    kind := KindFor(ACtx, AFilter.Attr, known)
  else
    Exit(frUndefined);
  wantedInt := 0;
  case rule of
    erBitAnd, erBitOr:
      if not TryStrToInt64(Trim(AFilter.Value), wantedInt) then Exit(frUndefined);
    erInChain:
      begin
        if (AFilter.Attr = '') or not DnStringMatchKey(AFilter.Value, chainKey) then
          Exit(frUndefined);
        Exit(InChain(AEntry, AFilter.Attr, chainKey, ACtx));
      end;
  else
    if not NormalizeForMatch(kind, AFilter.Value, wanted) then Exit(frUndefined);
  end;
  undef := False;
  if AFilter.Attr <> '' then
  begin
    if ValuesFor(AEntry, AFilter.Attr, ACtx, values) then
      for i := 0 to High(values) do
      begin
        if ValueMatchesRule(rule, kind, values[i], wanted, wantedInt, u) then Exit(frTrue);
        if u then undef := True;
      end;
  end
  else
    for i := 0 to AEntry.AttrCount - 1 do
    begin
      a := AEntry.Attrs[i];
      for j := 0 to a.ValueCount - 1 do
        if ValueMatchesRule(rule, kind, a.Values[j], wanted, wantedInt, u) then
          Exit(frTrue);
    end;
  if AFilter.DnAttributes and DnParse(AEntry.Dn, d, err) then
    for i := 0 to High(d.Rdns) do
      for k := 0 to High(d.Rdns[i].Avas) do
        if (AFilter.Attr = '') or
           (AsciiLowerCase(d.Rdns[i].Avas[k].AttrType) = AsciiLowerCase(AttrBaseName(AFilter.Attr))) then
          if ValueMatchesRule(rule, kind, d.Rdns[i].Avas[k].Value, wanted, wantedInt, u) then
            Exit(frTrue);
  if undef then Result := frUndefined else Result := frFalse;
end;

function EvaluateFilter(AFilter: TFilterNode; AEntry: TLdapEntry;
  const ACtx: TFilterContext): TFilterResult;
var
  items: array of TFilterResult;
  i: Integer;
begin
  case AFilter.Kind of
    fkAnd, fkOr:
      begin
        items := nil;
        SetLength(items, AFilter.ChildCount);
        for i := 0 to AFilter.ChildCount - 1 do
        begin
          items[i] := EvaluateFilter(AFilter.Children[i], AEntry, ACtx);
          if (AFilter.Kind = fkAnd) and (items[i] = frFalse) then Exit(frFalse);
          if (AFilter.Kind = fkOr) and (items[i] = frTrue) then Exit(frTrue);
        end;
        Result := Combine(AFilter.Kind = fkAnd, items);
      end;
    fkNot:
      case EvaluateFilter(AFilter.Children[0], AEntry, ACtx) of
        frTrue: Result := frFalse;
        frFalse: Result := frTrue;
      else
        Result := frUndefined;
      end;
    fkEquality, fkApprox:
      // ~= sans phonetique: egalite sans casse ni blancs superflus, ce que fait deja
      // la regle de la plupart des attributs.
      Result := EvalEquality(AEntry, AFilter, ACtx);
    fkSubstrings:
      Result := EvalSubstrings(AEntry, AFilter, ACtx);
    fkGreaterOrEqual:
      Result := EvalOrdering(AEntry, AFilter, ACtx, True);
    fkLessOrEqual:
      Result := EvalOrdering(AEntry, AFilter, ACtx, False);
    fkPresent:
      Result := EvalPresent(AEntry, AFilter, ACtx);
    fkExtensible:
      Result := EvalExtensible(AEntry, AFilter, ACtx);
  else
    Result := frUndefined;
  end;
end;

initialization
  BuildKinds;

finalization
  FreeAndNil(GKinds);

end.
