// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAdInfo;

{$mode objfpc}{$H+}

// Lectures Active Directory sans reseau: metadonnees de replication et politique de mot
// de passe (domaine, PSO). Versions et USN sont propres a chaque DC: de quoi enqueter,
// pas de quoi trancher.

interface

uses
  SysUtils, Classes, uLdapEntry;

const
  AD_REPL_METADATA_ATTR = 'msDS-ReplAttributeMetaData';
  AD_INTERVAL_NEVER = Low(Int64); // 0x8000000000000000: jamais
  DOMAIN_PASSWORD_COMPLEX = $1;
  DOMAIN_PASSWORD_NO_ANON_CHANGE = $2;
  DOMAIN_PASSWORD_NO_CLEAR_CHANGE = $4;
  DOMAIN_LOCKOUT_ADMINS = $8;
  DOMAIN_PASSWORD_STORE_CLEARTEXT = $10;
  DOMAIN_REFUSE_PASSWORD_CHANGE = $20;

  AD_DOMAIN_POLICY_ATTRS: array[0..9] of string = ('minPwdLength', 'minPwdAge', 'maxPwdAge',
    'pwdHistoryLength', 'pwdProperties', 'lockoutThreshold', 'lockoutDuration',
    'lockOutObservationWindow', 'msDS-Behavior-Version', 'objectSid');
  AD_PSO_ATTRS: array[0..11] of string = ('cn', 'msDS-PasswordSettingsPrecedence',
    'msDS-PasswordReversibleEncryptionEnabled', 'msDS-PasswordHistoryLength',
    'msDS-PasswordComplexityEnabled', 'msDS-MinimumPasswordLength', 'msDS-MinimumPasswordAge',
    'msDS-MaximumPasswordAge', 'msDS-LockoutThreshold', 'msDS-LockoutObservationWindow',
    'msDS-LockoutDuration', 'msDS-PSOAppliesTo');

type
  TReplAttrMeta = record
    Attribute: string;
    Version: string;
    LastOriginatingChange: string;
    OriginatingDsaInvocationId: string;
    OriginatingUsn: string;
    LocalUsn: string;
    OriginatingDsaDn: string;
  end;
  TReplAttrMetaArray = array of TReplAttrMeta;

  TPasswordPolicyView = record
    Source: string;
    IsPso: Boolean;
    Precedence: string;
    MinLength: string;
    HistoryLength: string;
    MinAge: string;
    MaxAge: string;
    Complexity: string;
    ReversibleEncryption: string;
    LockoutThreshold: string;
    LockoutDuration: string;
    ObservationWindow: string;
    AppliesTo: array of string;
  end;

resourcestring
  rsAdUnparsedMeta = 'value not in the documented XML form (%d bytes): shown as is';
  rsAdNever = 'never';
  rsAdNone = 'none';
  rsAdUntilUnlocked = 'until an administrator unlocks it';
  rsAdLockoutOff = '0 (no lockout)';
  rsAdYes = 'yes';
  rsAdNo = 'no';
  rsAdDays = '%d day(s)';
  rsAdHours = '%d h';
  rsAdMinutes = '%d min';
  rsAdSeconds = '%d s';

function ParseReplMetadata(AAttr: TLdapAttribute): TReplAttrMetaArray;
function AdIntervalText(const AValue: string): string;
function ReadDomainPolicy(ADomain: TLdapEntry): TPasswordPolicyView;
function ReadPso(APso: TLdapEntry): TPasswordPolicyView;
function AdFunctionalLevelName(const AValue: string): string;

implementation

function XmlUnescape(const S: string): string;
begin
  Result := StringReplace(S, '&lt;', '<', [rfReplaceAll]);
  Result := StringReplace(Result, '&gt;', '>', [rfReplaceAll]);
  Result := StringReplace(Result, '&quot;', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '&apos;', '''', [rfReplaceAll]);
  Result := StringReplace(Result, '&amp;', '&', [rfReplaceAll]);
end;

function Element(const AXml, ATag: string): string;
var
  p, q: Integer;
begin
  Result := '';
  p := Pos('<' + ATag + '>', AXml);
  if p = 0 then Exit;
  Inc(p, Length(ATag) + 2);
  q := Pos('</' + ATag + '>', Copy(AXml, p, MaxInt));
  if q = 0 then Exit;
  Result := XmlUnescape(Trim(Copy(AXml, p, q - 1)));
end;

function ParseReplMetadata(AAttr: TLdapAttribute): TReplAttrMetaArray;
var
  i, n: Integer;
  v: string;
  m: TReplAttrMeta;
begin
  Result := nil;
  if AAttr = nil then Exit;
  n := 0;
  SetLength(Result, AAttr.ValueCount);
  for i := 0 to AAttr.ValueCount - 1 do
  begin
    // AD glisse des NUL parasites dans ces valeurs XML, Microsoft le reconnait lui-meme.
    // On les retire.
    v := StringReplace(AAttr.Values[i], #0, '', [rfReplaceAll]);
    m := Default(TReplAttrMeta);
    if (Pos('<DS_REPL_ATTR_META_DATA', v) > 0) and (Pos('<pszAttributeName>', v) > 0) then
    begin
      m.Attribute := Element(v, 'pszAttributeName');
      m.Version := Element(v, 'dwVersion');
      m.LastOriginatingChange := Element(v, 'ftimeLastOriginatingChange');
      m.OriginatingDsaInvocationId := Element(v, 'uuidLastOriginatingDsaInvocationID');
      m.OriginatingUsn := Element(v, 'usnOriginatingChange');
      m.LocalUsn := Element(v, 'usnLocalChange');
      m.OriginatingDsaDn := Element(v, 'pszLastOriginatingDsaDN');
    end
    else
      m.Attribute := Format(rsAdUnparsedMeta, [Length(AAttr.Values[i])]);
    Result[n] := m;
    Inc(n);
  end;
  SetLength(Result, n);
end;

function AdIntervalText(const AValue: string): string;
var
  v: Int64;
  secs: Int64;
begin
  Result := '';
  if Trim(AValue) = '' then Exit;
  if not TryStrToInt64(Trim(AValue), v) then Exit(AValue);
  if v = AD_INTERVAL_NEVER then Exit(rsAdNever);
  if v = 0 then Exit(rsAdNone);
  // AD stocke ages et durees en negatif, par tranches de 100 ns. Heritage NT, inutile de
  // discuter.
  if v < 0 then v := -v;
  secs := v div 10000000;
  if (secs mod 86400 = 0) and (secs >= 86400) then
    Result := Format(rsAdDays, [secs div 86400])
  else if (secs mod 3600 = 0) and (secs >= 3600) then
    Result := Format(rsAdHours, [secs div 3600])
  else if (secs mod 60 = 0) and (secs >= 60) then
    Result := Format(rsAdMinutes, [secs div 60])
  else
    Result := Format(rsAdSeconds, [secs]);
end;

function YesNo(ACondition: Boolean): string;
begin
  if ACondition then Result := rsAdYes else Result := rsAdNo;
end;

function BoolText(const AValue: string): string;
begin
  if SameText(Trim(AValue), 'TRUE') then Result := rsAdYes
  else if SameText(Trim(AValue), 'FALSE') then Result := rsAdNo
  else Result := AValue;
end;

// Duree de verrouillage nulle: verrouille jusqu'au deblocage par un admin.
// Chez AD, zero c'est pour toujours.
function LockoutDurationText(const AValue: string): string;
var
  v: Int64;
begin
  if TryStrToInt64(Trim(AValue), v) and (v = 0) then
    Result := rsAdUntilUnlocked
  else
    Result := AdIntervalText(AValue);
end;

function ThresholdText(const AValue: string): string;
begin
  if Trim(AValue) = '0' then Result := rsAdLockoutOff else Result := Trim(AValue);
end;

function ReadDomainPolicy(ADomain: TLdapEntry): TPasswordPolicyView;
var
  props: Int64;
  raw: string;
begin
  Result := Default(TPasswordPolicyView);
  if ADomain = nil then Exit;
  Result.Source := ADomain.Dn;
  Result.MinLength := Trim(ADomain.FirstValue('minPwdLength', ''));
  Result.HistoryLength := Trim(ADomain.FirstValue('pwdHistoryLength', ''));
  Result.MinAge := AdIntervalText(ADomain.FirstValue('minPwdAge', ''));
  Result.MaxAge := AdIntervalText(ADomain.FirstValue('maxPwdAge', ''));
  raw := Trim(ADomain.FirstValue('pwdProperties', ''));
  if TryStrToInt64(raw, props) then
  begin
    Result.Complexity := YesNo(props and DOMAIN_PASSWORD_COMPLEX <> 0);
    Result.ReversibleEncryption := YesNo(props and DOMAIN_PASSWORD_STORE_CLEARTEXT <> 0);
  end;
  if ADomain.Find('lockoutThreshold') <> nil then
    Result.LockoutThreshold := ThresholdText(ADomain.FirstValue('lockoutThreshold', ''));
  if ADomain.Find('lockoutDuration') <> nil then
    Result.LockoutDuration := LockoutDurationText(ADomain.FirstValue('lockoutDuration', ''));
  Result.ObservationWindow := AdIntervalText(ADomain.FirstValue('lockOutObservationWindow', ''));
end;

function ReadPso(APso: TLdapEntry): TPasswordPolicyView;
var
  a: TLdapAttribute;
  i: Integer;
begin
  Result := Default(TPasswordPolicyView);
  if APso = nil then Exit;
  Result.Source := APso.Dn;
  Result.IsPso := True;
  Result.Precedence := Trim(APso.FirstValue('msDS-PasswordSettingsPrecedence', ''));
  Result.MinLength := Trim(APso.FirstValue('msDS-MinimumPasswordLength', ''));
  Result.HistoryLength := Trim(APso.FirstValue('msDS-PasswordHistoryLength', ''));
  Result.MinAge := AdIntervalText(APso.FirstValue('msDS-MinimumPasswordAge', ''));
  Result.MaxAge := AdIntervalText(APso.FirstValue('msDS-MaximumPasswordAge', ''));
  Result.Complexity := BoolText(APso.FirstValue('msDS-PasswordComplexityEnabled', ''));
  Result.ReversibleEncryption := BoolText(APso.FirstValue('msDS-PasswordReversibleEncryptionEnabled', ''));
  if APso.Find('msDS-LockoutThreshold') <> nil then
    Result.LockoutThreshold := ThresholdText(APso.FirstValue('msDS-LockoutThreshold', ''));
  if APso.Find('msDS-LockoutDuration') <> nil then
    Result.LockoutDuration := LockoutDurationText(APso.FirstValue('msDS-LockoutDuration', ''));
  Result.ObservationWindow := AdIntervalText(APso.FirstValue('msDS-LockoutObservationWindow', ''));
  a := APso.Find('msDS-PSOAppliesTo');
  if a <> nil then
  begin
    SetLength(Result.AppliesTo, a.ValueCount);
    for i := 0 to a.ValueCount - 1 do
      Result.AppliesTo[i] := a.Values[i];
  end;
end;

function AdFunctionalLevelName(const AValue: string): string;
begin
  case StrToIntDef(Trim(AValue), -1) of
    0: Result := 'Windows 2000';
    1: Result := 'Windows Server 2003 (mixed domains)';
    2: Result := 'Windows Server 2003';
    3: Result := 'Windows Server 2008';
    4: Result := 'Windows Server 2008 R2';
    5: Result := 'Windows Server 2012';
    6: Result := 'Windows Server 2012 R2';
    7: Result := 'Windows Server 2016';
    10: Result := 'Windows Server 2025';
  else
    Result := AValue;
  end;
end;

end.
