// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAdAccountPlan;

{$mode objfpc}{$H+}

// Drapeaux userAccountControl d'Active Directory (MS-ADTS 2.2.16). On part
// toujours de la valeur relue et on ne touche qu'aux bits demandes: reconstruire
// UAC a partir des cases visibles, c'est desactiver des comptes par megarde.

interface

uses
  SysUtils, uLdapEntry, uChangeSet;

type
  TUacCategory = (
    ucEditable,
    ucSensitive,
    ucAccountType,
    ucComputed,
    ucNotInUac,
    ucServerOnly);

  TUacFlag = record
    Bit: LongWord;
    Name: string;
    Description: string;
    Category: TUacCategory;
  end;

  TUacPlan = record
    OldText: string;
    OldValue: Int64;
    NewValue: Int64;
    ChangedMask: LongWord;
    UnknownBits: LongWord;
    SensitiveChanges: array of string;
  end;

resourcestring
  rsUacScript = 'The logon script is run';
  rsUacDisabled = 'The account is disabled';
  rsUacHomedir = 'A home folder is required';
  rsUacLockout = 'Locked out';
  rsUacPwdNotReqd = 'No password is required';
  rsUacCantChange = 'The user cannot change the password';
  rsUacEncryptedText = 'The password can be stored with reversible encryption';
  rsUacTempDuplicate = 'Temporary duplicate account';
  rsUacNormal = 'Normal user account';
  rsUacInterdomain = 'Interdomain trust account';
  rsUacWorkstation = 'Workstation or member server account';
  rsUacServer = 'Domain controller account';
  rsUacDontExpire = 'The password never expires';
  rsUacMnsLogon = 'Majority node set logon account';
  rsUacSmartcard = 'A smart card is required for interactive logon';
  rsUacTrustedDelegation = 'Trusted for Kerberos delegation (unconstrained)';
  rsUacNotDelegated = 'Sensitive account: it cannot be delegated';
  rsUacDesOnly = 'Only DES keys are used for Kerberos';
  rsUacNoPreauth = 'Kerberos pre-authentication is not required';
  rsUacPwdExpired = 'The password has expired';
  rsUacTrustedToAuth = 'Trusted to authenticate for delegation (protocol transition)';
  rsUacNoAuthData = 'No authorization data (PAC) is required';
  rsUacPartialSecrets = 'Read-only domain controller account';
  rsUacUseAes = 'AES keys are used for Kerberos';

  rsUacAbsent = 'userAccountControl was not read: no change is prepared.';
  rsUacTruncated = 'The entry was not read completely: userAccountControl may be missing or stale.';
  rsUacInvalid = 'userAccountControl is not an integer: no change is prepared.';
  rsUacNotEditable = '%s cannot be changed here.';
  rsUacNothing = 'No flag changes.';
  rsUacSetSensitive = 'SET %s: %s';
  rsUacClearSensitive = 'CLEAR %s: %s';

function UacFlagCount: Integer;
function UacFlag(AIndex: Integer): TUacFlag;
function UacFlagByBit(ABit: LongWord; out AFlag: TUacFlag): Boolean;
function UacUnknownBits(AValue: Int64): LongWord;
function PlanUacChange(AEntry: TLdapEntry; ASet, AClear: LongWord; out APlan: TUacPlan;
  out AError: string): TLdapChange;
// objectGUID ne sert d'identite que sur une entree lue en entier: avec un
// decodage incomplet, rien ne prouve que la valeur est unique.
function UsableObjectGuid(AEntry: TLdapEntry): RawByteString;

implementation

uses
  uAttributeCodec;

const
  FLAGS: array[0..22] of record
    Bit: LongWord;
    Name: string;
    Category: TUacCategory;
  end = (
    (Bit: $00000001; Name: 'SCRIPT'; Category: ucEditable),
    (Bit: $00000002; Name: 'ACCOUNTDISABLE'; Category: ucEditable),
    (Bit: $00000008; Name: 'HOMEDIR_REQUIRED'; Category: ucEditable),
    (Bit: $00000010; Name: 'LOCKOUT'; Category: ucComputed),
    (Bit: $00000020; Name: 'PASSWD_NOTREQD'; Category: ucSensitive),
    (Bit: $00000040; Name: 'PASSWD_CANT_CHANGE'; Category: ucNotInUac),
    (Bit: $00000080; Name: 'ENCRYPTED_TEXT_PWD_ALLOWED'; Category: ucSensitive),
    (Bit: $00000100; Name: 'TEMP_DUPLICATE_ACCOUNT'; Category: ucAccountType),
    (Bit: $00000200; Name: 'NORMAL_ACCOUNT'; Category: ucAccountType),
    (Bit: $00000800; Name: 'INTERDOMAIN_TRUST_ACCOUNT'; Category: ucAccountType),
    (Bit: $00001000; Name: 'WORKSTATION_TRUST_ACCOUNT'; Category: ucAccountType),
    (Bit: $00002000; Name: 'SERVER_TRUST_ACCOUNT'; Category: ucAccountType),
    (Bit: $00010000; Name: 'DONT_EXPIRE_PASSWORD'; Category: ucEditable),
    (Bit: $00020000; Name: 'MNS_LOGON_ACCOUNT'; Category: ucEditable),
    (Bit: $00040000; Name: 'SMARTCARD_REQUIRED'; Category: ucSensitive),
    (Bit: $00080000; Name: 'TRUSTED_FOR_DELEGATION'; Category: ucSensitive),
    (Bit: $00100000; Name: 'NOT_DELEGATED'; Category: ucSensitive),
    (Bit: $00200000; Name: 'USE_DES_KEY_ONLY'; Category: ucSensitive),
    (Bit: $00400000; Name: 'DONT_REQ_PREAUTH'; Category: ucSensitive),
    (Bit: $00800000; Name: 'PASSWORD_EXPIRED'; Category: ucComputed),
    (Bit: $01000000; Name: 'TRUSTED_TO_AUTH_FOR_DELEGATION'; Category: ucSensitive),
    (Bit: $02000000; Name: 'NO_AUTH_DATA_REQUIRED'; Category: ucSensitive),
    (Bit: $04000000; Name: 'PARTIAL_SECRETS_ACCOUNT'; Category: ucServerOnly));
  USE_AES_KEYS = $08000000;

function Describe(ABit: LongWord): string;
begin
  case ABit of
    $00000001: Result := rsUacScript;
    $00000002: Result := rsUacDisabled;
    $00000008: Result := rsUacHomedir;
    $00000010: Result := rsUacLockout;
    $00000020: Result := rsUacPwdNotReqd;
    $00000040: Result := rsUacCantChange;
    $00000080: Result := rsUacEncryptedText;
    $00000100: Result := rsUacTempDuplicate;
    $00000200: Result := rsUacNormal;
    $00000800: Result := rsUacInterdomain;
    $00001000: Result := rsUacWorkstation;
    $00002000: Result := rsUacServer;
    $00010000: Result := rsUacDontExpire;
    $00020000: Result := rsUacMnsLogon;
    $00040000: Result := rsUacSmartcard;
    $00080000: Result := rsUacTrustedDelegation;
    $00100000: Result := rsUacNotDelegated;
    $00200000: Result := rsUacDesOnly;
    $00400000: Result := rsUacNoPreauth;
    $00800000: Result := rsUacPwdExpired;
    $01000000: Result := rsUacTrustedToAuth;
    $02000000: Result := rsUacNoAuthData;
    $04000000: Result := rsUacPartialSecrets;
    USE_AES_KEYS: Result := rsUacUseAes;
  else
    Result := '';
  end;
end;

function UacFlagCount: Integer;
begin
  Result := Length(FLAGS) + 1;
end;

function UacFlag(AIndex: Integer): TUacFlag;
begin
  Result := Default(TUacFlag);
  if AIndex = Length(FLAGS) then
  begin
    Result.Bit := USE_AES_KEYS;
    Result.Name := 'USE_AES_KEYS';
    Result.Category := ucEditable;
  end
  else
  begin
    Result.Bit := FLAGS[AIndex].Bit;
    Result.Name := FLAGS[AIndex].Name;
    Result.Category := FLAGS[AIndex].Category;
  end;
  Result.Description := Describe(Result.Bit);
end;

function UacFlagByBit(ABit: LongWord; out AFlag: TUacFlag): Boolean;
var
  i: Integer;
begin
  for i := 0 to UacFlagCount - 1 do
  begin
    AFlag := UacFlag(i);
    if AFlag.Bit = ABit then Exit(True);
  end;
  AFlag := Default(TUacFlag);
  Result := False;
end;

function UacUnknownBits(AValue: Int64): LongWord;
var
  known: LongWord;
  i: Integer;
begin
  known := 0;
  for i := 0 to UacFlagCount - 1 do
    known := known or UacFlag(i).Bit;
  Result := LongWord(AValue and $FFFFFFFF) and not known;
end;

function UsableObjectGuid(AEntry: TLdapEntry): RawByteString;
var
  a: TLdapAttribute;
begin
  Result := '';
  if (AEntry = nil) or AEntry.DecodeIncomplete or AEntry.AnyTruncated then Exit;
  a := AEntry.Find('objectGUID');
  if (a = nil) or (a.ValueCount <> 1) or (Length(a.Values[0]) <> 16) then Exit;
  Result := a.Values[0];
end;

function PlanUacChange(AEntry: TLdapEntry; ASet, AClear: LongWord; out APlan: TUacPlan;
  out AError: string): TLdapChange;
const
  COMPUTED_BITS = $00000010 or $00800000;
var
  a: TLdapAttribute;
  fits: Boolean;
  v: Int64;
  bit: LongWord;
  i: Integer;
  f: TUacFlag;
  requested: LongWord;
begin
  Result := nil;
  AError := '';
  APlan := Default(TUacPlan);
  if AEntry = nil then
  begin
    AError := rsUacAbsent;
    Exit;
  end;
  if AEntry.DecodeIncomplete then
  begin
    AError := rsUacTruncated;
    Exit;
  end;
  a := AEntry.Find('userAccountControl');
  if (a = nil) or (a.ValueCount <> 1) then
  begin
    AError := rsUacAbsent;
    Exit;
  end;
  if a.Truncated then
  begin
    AError := rsUacTruncated;
    Exit;
  end;
  APlan.OldText := string(a.Values[0]);
  if not CheckLdapInteger(APlan.OldText, fits, v) or not fits or (v < 0) or (v > High(LongWord)) then
  begin
    AError := rsUacInvalid;
    Exit;
  end;
  APlan.OldValue := v;
  APlan.UnknownBits := UacUnknownBits(v);
  requested := ASet or AClear;
  for i := 0 to 31 do
  begin
    bit := LongWord(1) shl i;
    if (requested and bit) = 0 then Continue;
    if not UacFlagByBit(bit, f) or not (f.Category in [ucEditable, ucSensitive]) then
    begin
      if f.Name = '' then f.Name := Format('0x%.8x', [Int64(bit)]);
      AError := Format(rsUacNotEditable, [f.Name]);
      Exit;
    end;
  end;
  // Bits inconnus conserves. LOCKOUT et PASSWORD_EXPIRED sont calcules par le
  // serveur (msDS-User-Account-Control-Computed): les recopier serait mentir.
  APlan.NewValue := ((v and not Int64(AClear)) or Int64(ASet)) and not Int64(COMPUTED_BITS);
  APlan.ChangedMask := LongWord(APlan.NewValue xor (v and not Int64(COMPUTED_BITS)));
  if APlan.NewValue = (v and not Int64(COMPUTED_BITS)) then
  begin
    AError := rsUacNothing;
    Exit;
  end;
  for i := 0 to 31 do
  begin
    bit := LongWord(1) shl i;
    if (APlan.ChangedMask and bit) = 0 then Continue;
    if UacFlagByBit(bit, f) and (f.Category = ucSensitive) then
    begin
      SetLength(APlan.SensitiveChanges, Length(APlan.SensitiveChanges) + 1);
      if (APlan.NewValue and bit) <> 0 then
        APlan.SensitiveChanges[High(APlan.SensitiveChanges)] := Format(rsUacSetSensitive, [f.Name, f.Description])
      else
        APlan.SensitiveChanges[High(APlan.SensitiveChanges)] := Format(rsUacClearSensitive, [f.Name, f.Description]);
    end;
  end;
  // Ancienne valeur exacte supprimee, nouvelle ajoutee, dans la meme requete: si
  // quelqu'un a touche au compte entre-temps, le serveur refuse et rien n'est rejoue.
  Result := NewChange(ckModify, AEntry.Dn);
  Result.AddMod(moDelete, 'userAccountControl', [RawByteString(APlan.OldText)]);
  Result.AddMod(moAdd, 'userAccountControl', [RawByteString(IntToStr(APlan.NewValue))]);
end;

end.
