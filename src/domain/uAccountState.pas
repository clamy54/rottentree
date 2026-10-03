// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAccountState;

{$mode objfpc}{$H+}

// Etat et actions de compte par fournisseur (AD, OpenLDAP ppolicy, 389 DS).
// Une absence d'attribut ne vaut "non" que sur une lecture complete, et une ACL
// peut masquer meme un attribut demande. Les modifications se font valeur par
// valeur et laissent tranquille tout ce qui n'est pas concerne.

interface

uses
  SysUtils, Classes, DateUtils, uLdapEntry, uChangeSet, uConnectionProfile;

const
  UF_ACCOUNTDISABLE = $2;
  UF_LOCKOUT = $10;
  UF_PASSWD_NOTREQD = $20;
  UF_NORMAL_ACCOUNT = $200;
  UF_WORKSTATION_TRUST_ACCOUNT = $1000;
  UF_SERVER_TRUST_ACCOUNT = $2000;
  UF_DONT_EXPIRE_PASSWD = $10000;
  UF_SMARTCARD_REQUIRED = $40000;
  UF_PASSWORD_EXPIRED = $800000;
  // Bits calcules, jamais recopies: un userAccountControl ecrit avec LOCKOUT
  // alors que lockoutTime est non nul deverrouille le compte (MS-SAMR 3.1.1.8.10).
  UF_COMPUTED_BITS = UF_LOCKOUT or UF_PASSWORD_EXPIRED;
  AD_NEVER_EXPIRES = '9223372036854775807';
  PPOLICY_CONTROL_OID = '1.3.6.1.4.1.42.2.27.8.5.1';
  PPOLICY_PERMANENT_LOCK = '000001010000Z';
  DS389_PERMANENT_LOCK = '19700101000000Z';

type
  TTriState = (tsUnknown, tsNo, tsYes);

  TAccountAction = (aaEnable, aaDisable, aaUnlock, aaMustChange, aaClearMustChange,
    aaPasswordNeverExpires, aaPasswordExpires);
  TAccountActions = set of TAccountAction;

  TAccountAdapter = (adNone, adActiveDirectory, adAdLds, adOpenLdapPpolicy, ad389Ds);

  TAccountStatus = record
    Adapter: TAccountAdapter;
    Disabled: TTriState;
    LockedOut: TTriState;
    LockDetail: string;
    AccountExpired: TTriState;
    AccountExpiry: string;
    PasswordExpired: TTriState;
    MustChangePassword: TTriState;
    PasswordNeverExpires: TTriState;
    Available: TAccountActions;
    Notes: array of string;
  end;

resourcestring
  rsAccNoAdapter = 'No qualified account adapter for this server type: account actions are not offered.';
  rsAccNoPpolicy = 'The root DSE does not announce the password policy control: OpenLDAP has no native account lock, so no action is offered.';
  rsAccPpolicyScope = 'The ppolicy control proves that the overlay is loaded, not that it applies to this database; locking also requires pwdLockout: TRUE in the applicable policy.';
  rsAccAttrMissing = '%s was not returned (absent, hidden by access control or not requested).';
  rsAccAttrMissingRequested = '%s was not returned though it was requested: it is absent or hidden by access control.';
  rsAccComputedMissing = 'msDS-User-Account-Control-Computed was not returned: lockout and password expiry are unknown.';
  rsAccIncompleteRead = 'the entry was not fully read: the state of %s is unknown.';
  rsAccLockoutTimeNonZero = 'lockoutTime is not zero; whether the lockout is still in force depends on the lockout duration.';
  rsAccNever = 'never';
  rsAccPermanentLock = 'locked permanently until an administrator unlocks it';
  rsAccLockedSince = 'locked since %s';
  rsAccLockedUntil = 'locked until %s';
  rsAccUnlockPending = 'lock time %s has passed; the server clears it at the next bind';
  rsAccRoleLock = 'nsAccountLock may come from a role (class of service): unlocking the entry does not remove a role lock.';
  rsAccUacUnparsable = 'userAccountControl is not a number: no change is prepared.';
  rsAccCantChangeAce = '"User cannot change password" is an access control entry, not a userAccountControl bit: it is not changed here.';
  rsAccAlreadyDisabled = 'the account is already disabled';
  rsAccAlreadyEnabled = 'the account is not disabled';
  rsAccNotLocked = 'the account is not locked';
  rsAccUnsupported = 'this action is not available for this adapter or state';
  rsAdapterAd = 'Active Directory (userAccountControl)';
  rsAdapterAdLds = 'AD LDS (msDS-UserAccountDisabled)';
  rsAdapterPpolicy = 'OpenLDAP password policy (ppolicy)';
  rsAdapter389 = '389 Directory Server (nsAccountLock, password policy)';
  rsAdapterNone = 'none';
  rsTriYes = 'yes';
  rsTriNo = 'no';
  rsTriUnknown = 'unknown';

function SelectAccountAdapter(AKind: TProviderKind; AAdLds: Boolean;
  ARootDse: TLdapEntry): TAccountAdapter;
function AccountReadAttributes(AAdapter: TAccountAdapter): TStringArray;
function ReadAccountStatus(AEntry: TLdapEntry; AAdapter: TAccountAdapter;
  ANowUtc: TDateTime): TAccountStatus;
function PlanAccountAction(AEntry: TLdapEntry; AAdapter: TAccountAdapter;
  AAction: TAccountAction; ANowUtc: TDateTime; out AError: string): TLdapChange;
function AccountAdapterName(AAdapter: TAccountAdapter): string;
function TriStateText(AValue: TTriState): string;
function FileTimeToUtc(const AValue: string; out ADate: TDateTime): Boolean;
function ParseGeneralizedTime(const AValue: string; out ADate: TDateTime): Boolean;

implementation

uses
  uCancel;

function AccountAdapterName(AAdapter: TAccountAdapter): string;
begin
  case AAdapter of
    adActiveDirectory: Result := rsAdapterAd;
    adAdLds: Result := rsAdapterAdLds;
    adOpenLdapPpolicy: Result := rsAdapterPpolicy;
    ad389Ds: Result := rsAdapter389;
  else
    Result := rsAdapterNone;
  end;
end;

function TriStateText(AValue: TTriState): string;
begin
  case AValue of
    tsYes: Result := rsTriYes;
    tsNo: Result := rsTriNo;
  else
    Result := rsTriUnknown;
  end;
end;

function HasValueCi(AEntry: TLdapEntry; const AAttr, AValue: string): Boolean;
var
  a: TLdapAttribute;
  i: Integer;
begin
  Result := False;
  if AEntry = nil then Exit;
  a := AEntry.Find(AAttr);
  if a = nil then Exit;
  for i := 0 to a.ValueCount - 1 do
    if SameText(Trim(a.Values[i]), AValue) then Exit(True);
end;

function SelectAccountAdapter(AKind: TProviderKind; AAdLds: Boolean;
  ARootDse: TLdapEntry): TAccountAdapter;
begin
  case AKind of
    pkActiveDirectory:
      if AAdLds then Result := adAdLds else Result := adActiveDirectory;
    pkOpenLdap:
      // Sans module ppolicy, OpenLDAP n'a aucun verrou de compte.
      if HasValueCi(ARootDse, 'supportedControl', PPOLICY_CONTROL_OID) then
        Result := adOpenLdapPpolicy
      else
        Result := adNone;
    pk389Ds: Result := ad389Ds;
  else
    Result := adNone;
  end;
end;

function AccountReadAttributes(AAdapter: TAccountAdapter): TStringArray;
begin
  case AAdapter of
    adActiveDirectory:
      Result := ['objectClass', 'userAccountControl', 'msDS-User-Account-Control-Computed',
        'lockoutTime', 'accountExpires', 'pwdLastSet', 'badPwdCount'];
    adAdLds:
      Result := ['objectClass', 'msDS-UserAccountDisabled', 'msDS-User-Account-Control-Computed',
        'lockoutTime', 'accountExpires', 'pwdLastSet'];
    adOpenLdapPpolicy:
      Result := ['objectClass', 'pwdAccountLockedTime', 'pwdFailureTime', 'pwdReset',
        'pwdChangedTime', 'pwdPolicySubentry', 'pwdStartTime', 'pwdEndTime',
        'pwdAccountTmpLockoutEnd', 'pwdGraceUseTime'];
    ad389Ds:
      Result := ['objectClass', 'nsAccountLock', 'nsRoleDN', 'passwordRetryCount',
        'retryCountResetTime', 'accountUnlockTime', 'passwordExpirationTime', 'pwdReset'];
  else
    Result := ['objectClass'];
  end;
end;

function FileTimeToUtc(const AValue: string; out ADate: TDateTime): Boolean;
var
  ft: Int64;
const
  EPOCH_DELTA_DAYS = 109205.0;
begin
  Result := False;
  ADate := 0;
  if not TryStrToInt64(Trim(AValue), ft) or (ft <= 0) or (ft = High(Int64)) then Exit;
  ADate := ft / 864000000000.0 - EPOCH_DELTA_DAYS;
  Result := (ADate > -657434) and (ADate < 2958466);
end;

function ParseGeneralizedTime(const AValue: string; out ADate: TDateTime): Boolean;
var
  s: string;
  y, mo, d, h, mi, sec: Integer;
begin
  Result := False;
  ADate := 0;
  s := Trim(AValue);
  if (Length(s) < 11) or (s[Length(s)] <> 'Z') then Exit;
  if not (TryStrToInt(Copy(s, 1, 4), y) and TryStrToInt(Copy(s, 5, 2), mo) and
    TryStrToInt(Copy(s, 7, 2), d) and TryStrToInt(Copy(s, 9, 2), h)) then Exit;
  mi := 0;
  sec := 0;
  if (Length(s) >= 13) and (s[11] in ['0'..'9']) then
    if not TryStrToInt(Copy(s, 11, 2), mi) then Exit;
  if (Length(s) >= 15) and (s[13] in ['0'..'9']) then
    if not TryStrToInt(Copy(s, 13, 2), sec) then Exit;
  // 000001010000Z, le verrou permanent de ppolicy, tombe en l'an 0000. TDateTime
  // refuse d'y croire, et il a raison.
  Result := TryEncodeDateTime(y, mo, d, h, mi, sec, 0, ADate);
end;

procedure AddNote(var S: TAccountStatus; const ANote: string);
begin
  SetLength(S.Notes, Length(S.Notes) + 1);
  S.Notes[High(S.Notes)] := ANote;
end;

function UtcText(ADate: TDateTime): string;
begin
  Result := FormatUtcIso(ADate);
end;

function BoolTri(AEntry: TLdapEntry; const AAttr: string): TTriState;
var
  v: string;
begin
  if AEntry.Find(AAttr) = nil then Exit(tsUnknown);
  v := UpperCase(Trim(AEntry.FirstValue(AAttr, '')));
  if v = 'TRUE' then Result := tsYes
  else if v = 'FALSE' then Result := tsNo
  else Result := tsUnknown;
end;

// Le "non" protocolaire n'est admis que sur une lecture complete, et un refus
// d'ACL ressemble a une absence: ce "non" vient donc toujours avec une note.
function AbsentTri(AEntry: TLdapEntry; const AAttr: string;
  var S: TAccountStatus): TTriState;
var
  p: TAttrPresence;
begin
  p := AEntry.Presence(AAttr, False);
  if AEntry.DecodeIncomplete or (p = apTruncated) then
  begin
    AddNote(S, Format(rsAccIncompleteRead, [AAttr]));
    Exit(tsUnknown);
  end;
  Result := tsNo;
  if p = apAbsentRequested then
    AddNote(S, Format(rsAccAttrMissingRequested, [AAttr]))
  else
    AddNote(S, Format(rsAccAttrMissing, [AAttr]));
end;

procedure ReadAd(AEntry: TLdapEntry; ANow: TDateTime; ALds: Boolean; var S: TAccountStatus);
var
  uac, comp: Int64;
  hasUac, hasComp: Boolean;
  d: TDateTime;
  v: string;
begin
  hasUac := TryStrToInt64(Trim(AEntry.FirstValue('userAccountControl', '')), uac);
  hasComp := TryStrToInt64(Trim(AEntry.FirstValue('msDS-User-Account-Control-Computed', '')), comp);
  if ALds then
  else if hasUac then
  begin
    if uac and UF_ACCOUNTDISABLE <> 0 then S.Disabled := tsYes else S.Disabled := tsNo;
    if uac and UF_DONT_EXPIRE_PASSWD <> 0 then S.PasswordNeverExpires := tsYes
    else S.PasswordNeverExpires := tsNo;
  end
  else
    AddNote(S, Format(rsAccAttrMissing, ['userAccountControl']));
  if hasComp then
  begin
    if comp and UF_LOCKOUT <> 0 then S.LockedOut := tsYes else S.LockedOut := tsNo;
    if comp and UF_PASSWORD_EXPIRED <> 0 then S.PasswordExpired := tsYes
    else S.PasswordExpired := tsNo;
  end
  else
  begin
    AddNote(S, rsAccComputedMissing);
    v := Trim(AEntry.FirstValue('lockoutTime', ''));
    if v = '0' then S.LockedOut := tsNo
    else if v <> '' then AddNote(S, rsAccLockoutTimeNonZero);
  end;
  v := Trim(AEntry.FirstValue('lockoutTime', ''));
  if (S.LockedOut = tsYes) and FileTimeToUtc(v, d) then
    S.LockDetail := Format(rsAccLockedSince, [UtcText(d)]);
  // accountExpires: 0 et 0x7FFFFFFFFFFFFFFF veulent tous deux dire jamais. Deux
  // facons de dire non, c'est AD tout crache.
  v := Trim(AEntry.FirstValue('accountExpires', ''));
  if (v = '0') or (v = AD_NEVER_EXPIRES) then
  begin
    S.AccountExpired := tsNo;
    S.AccountExpiry := rsAccNever;
  end
  else if FileTimeToUtc(v, d) then
  begin
    S.AccountExpiry := UtcText(d);
    if d <= ANow then S.AccountExpired := tsYes else S.AccountExpired := tsNo;
  end;
  v := Trim(AEntry.FirstValue('pwdLastSet', ''));
  if v = '0' then
  begin
    if S.PasswordNeverExpires = tsYes then S.MustChangePassword := tsNo
    else S.MustChangePassword := tsYes;
  end
  else if v <> '' then
    S.MustChangePassword := tsNo;
  if not ALds then AddNote(S, rsAccCantChangeAce);
end;

procedure ReadPpolicy(AEntry: TLdapEntry; ANow: TDateTime; var S: TAccountStatus);
var
  v: string;
  d, e: TDateTime;
begin
  AddNote(S, rsAccPpolicyScope);
  v := Trim(AEntry.FirstValue('pwdAccountLockedTime', ''));
  if v = '' then
  begin
    S.Disabled := AbsentTri(AEntry, 'pwdAccountLockedTime', S);
    S.LockedOut := S.Disabled;
  end
  else if v = PPOLICY_PERMANENT_LOCK then
  begin
    S.Disabled := tsYes;
    S.LockedOut := tsNo;
    S.LockDetail := rsAccPermanentLock;
  end
  else
  begin
    S.Disabled := tsNo;
    if ParseGeneralizedTime(v, d) and (d > ANow) then
      S.LockedOut := tsNo
    else
    begin
      S.LockedOut := tsYes;
      if ParseGeneralizedTime(Trim(AEntry.FirstValue('pwdAccountTmpLockoutEnd', '')), e) then
      begin
        if e > ANow then S.LockDetail := Format(rsAccLockedUntil, [UtcText(e)])
        else
        begin
          S.LockedOut := tsNo;
          S.LockDetail := Format(rsAccUnlockPending, [UtcText(e)]);
        end;
      end
      else
        S.LockDetail := Format(rsAccLockedSince, [v]);
    end;
  end;
  S.MustChangePassword := BoolTri(AEntry, 'pwdReset');
  if ParseGeneralizedTime(Trim(AEntry.FirstValue('pwdEndTime', '')), e) then
  begin
    S.AccountExpiry := UtcText(e);
    if e <= ANow then S.AccountExpired := tsYes else S.AccountExpired := tsNo;
  end;
end;

procedure Read389(AEntry: TLdapEntry; ANow: TDateTime; var S: TAccountStatus);
var
  v: string;
  d: TDateTime;
begin
  if AEntry.Find('nsAccountLock') = nil then
    S.Disabled := AbsentTri(AEntry, 'nsAccountLock', S)
  else if SameText(Trim(AEntry.FirstValue('nsAccountLock', '')), 'true') then
  begin
    S.Disabled := tsYes;
    if AEntry.Find('nsRoleDN') <> nil then AddNote(S, rsAccRoleLock);
  end
  else
    S.Disabled := tsNo;
  v := Trim(AEntry.FirstValue('accountUnlockTime', ''));
  if v = '' then
    S.LockedOut := AbsentTri(AEntry, 'accountUnlockTime', S)
  else if v = DS389_PERMANENT_LOCK then
  begin
    S.LockedOut := tsYes;
    S.LockDetail := rsAccPermanentLock;
  end
  else if ParseGeneralizedTime(v, d) then
  begin
    if d > ANow then
    begin
      S.LockedOut := tsYes;
      S.LockDetail := Format(rsAccLockedUntil, [UtcText(d)]);
    end
    else
      S.LockedOut := tsNo;
  end;
  v := Trim(AEntry.FirstValue('passwordExpirationTime', ''));
  if (BoolTri(AEntry, 'pwdReset') = tsYes) or (v = DS389_PERMANENT_LOCK) then
    S.MustChangePassword := tsYes
  else
    S.MustChangePassword := BoolTri(AEntry, 'pwdReset');
  if (v <> '') and (v <> DS389_PERMANENT_LOCK) and ParseGeneralizedTime(v, d) then
    if d <= ANow then S.PasswordExpired := tsYes else S.PasswordExpired := tsNo;
end;

procedure ComputeAvailable(AEntry: TLdapEntry; var S: TAccountStatus);
begin
  S.Available := [];
  if S.Adapter = adNone then Exit;
  // Etat inconnu, aucune action fondee sur une certitude: seuls tsYes/tsNo ouvrent
  // enable, disable et unlock. Imposer un changement de mot de passe reste offert.
  if S.Disabled = tsYes then Include(S.Available, aaEnable);
  if S.Disabled = tsNo then Include(S.Available, aaDisable);
  if S.LockedOut = tsYes then Include(S.Available, aaUnlock);
  case S.Adapter of
    adActiveDirectory, adAdLds, adOpenLdapPpolicy:
      if S.MustChangePassword = tsYes then Include(S.Available, aaClearMustChange)
      else Include(S.Available, aaMustChange);
  end;
  if S.Adapter = adActiveDirectory then
    if S.PasswordNeverExpires = tsYes then Include(S.Available, aaPasswordExpires)
    else if S.PasswordNeverExpires = tsNo then Include(S.Available, aaPasswordNeverExpires);
  if (S.Adapter in [adActiveDirectory, adAdLds]) and (S.LockedOut = tsUnknown) and
     (Trim(AEntry.FirstValue('lockoutTime', '')) <> '') and
     (Trim(AEntry.FirstValue('lockoutTime', '')) <> '0') then
    Include(S.Available, aaUnlock);
  if (S.Adapter = ad389Ds) and (S.LockedOut = tsNo) and
     (AEntry.Find('accountUnlockTime') <> nil) then
    Include(S.Available, aaUnlock);
end;

function ReadAccountStatus(AEntry: TLdapEntry; AAdapter: TAccountAdapter;
  ANowUtc: TDateTime): TAccountStatus;
begin
  Result := Default(TAccountStatus);
  Result.Adapter := AAdapter;
  if AEntry = nil then Exit;
  case AAdapter of
    adActiveDirectory: ReadAd(AEntry, ANowUtc, False, Result);
    adAdLds:
      begin
        Result.Disabled := BoolTri(AEntry, 'msDS-UserAccountDisabled');
        if AEntry.Find('msDS-UserAccountDisabled') = nil then
          AddNote(Result, Format(rsAccAttrMissing, ['msDS-UserAccountDisabled']));
        ReadAd(AEntry, ANowUtc, True, Result);
      end;
    adOpenLdapPpolicy: ReadPpolicy(AEntry, ANowUtc, Result);
    ad389Ds: Read389(AEntry, ANowUtc, Result);
  else
    AddNote(Result, rsAccNoAdapter);
  end;
  ComputeAvailable(AEntry, Result);
end;

function Refuse(const AMsg: string; out AError: string): TLdapChange;
begin
  AError := AMsg;
  Result := nil;
end;

// Suppression de la valeur lue et ajout de la nouvelle dans le meme Modify: une
// valeur changee entre-temps fait echouer l'operation au lieu d'ecraser d'autres bits.
function PlanUac(AEntry: TLdapEntry; ASet, AClear: Int64; out AError: string): TLdapChange;
var
  old, nv: Int64;
  raw: string;
begin
  raw := Trim(AEntry.FirstValue('userAccountControl', ''));
  if not TryStrToInt64(raw, old) then Exit(Refuse(rsAccUacUnparsable, AError));
  nv := ((old or ASet) and not AClear) and not UF_COMPUTED_BITS;
  Result := NewChange(ckModify, AEntry.Dn);
  Result.AddMod(moDelete, 'userAccountControl', [AEntry.FirstValue('userAccountControl', '')]);
  Result.AddMod(moAdd, 'userAccountControl', [IntToStr(nv)]);
end;

function PlanAccountAction(AEntry: TLdapEntry; AAdapter: TAccountAdapter;
  AAction: TAccountAction; ANowUtc: TDateTime; out AError: string): TLdapChange;
var
  st: TAccountStatus;
begin
  Result := nil;
  AError := '';
  st := ReadAccountStatus(AEntry, AAdapter, ANowUtc);
  if not (AAction in st.Available) then
  begin
    case AAction of
      aaEnable: AError := rsAccAlreadyEnabled;
      aaDisable: AError := rsAccAlreadyDisabled;
      aaUnlock: AError := rsAccNotLocked;
    else
      AError := rsAccUnsupported;
    end;
    Exit;
  end;
  case AAdapter of
    adActiveDirectory:
      case AAction of
        aaEnable: Result := PlanUac(AEntry, 0, UF_ACCOUNTDISABLE, AError);
        aaDisable: Result := PlanUac(AEntry, UF_ACCOUNTDISABLE, 0, AError);
        aaPasswordNeverExpires: Result := PlanUac(AEntry, UF_DONT_EXPIRE_PASSWD, 0, AError);
        aaPasswordExpires: Result := PlanUac(AEntry, 0, UF_DONT_EXPIRE_PASSWD, AError);
        aaUnlock:
          begin
            // lockoutTime a 0: la seule valeur de deverrouillage documentee.
            Result := NewChange(ckModify, AEntry.Dn);
            Result.AddMod(moReplace, 'lockoutTime', ['0']);
          end;
        aaMustChange:
          begin
            Result := NewChange(ckModify, AEntry.Dn);
            Result.AddMod(moReplace, 'pwdLastSet', ['0']);
          end;
        aaClearMustChange:
          begin
            Result := NewChange(ckModify, AEntry.Dn);
            Result.AddMod(moReplace, 'pwdLastSet', ['-1']);
          end;
      end;
    adAdLds:
      begin
        Result := NewChange(ckModify, AEntry.Dn);
        case AAction of
          aaEnable: Result.AddMod(moReplace, 'msDS-UserAccountDisabled', ['FALSE']);
          aaDisable: Result.AddMod(moReplace, 'msDS-UserAccountDisabled', ['TRUE']);
          aaUnlock: Result.AddMod(moReplace, 'lockoutTime', ['0']);
          aaMustChange: Result.AddMod(moReplace, 'pwdLastSet', ['0']);
          aaClearMustChange: Result.AddMod(moReplace, 'pwdLastSet', ['-1']);
        else
          FreeAndNil(Result);
          AError := rsAccUnsupported;
        end;
      end;
    adOpenLdapPpolicy:
      begin
        Result := NewChange(ckModify, AEntry.Dn);
        case AAction of
          aaDisable: Result.AddMod(moReplace, 'pwdAccountLockedTime', [PPOLICY_PERMANENT_LOCK]);
          aaEnable, aaUnlock: Result.AddMod(moDelete, 'pwdAccountLockedTime', []);
          aaMustChange: Result.AddMod(moReplace, 'pwdReset', ['TRUE']);
          aaClearMustChange: Result.AddMod(moDelete, 'pwdReset', []);
        else
          FreeAndNil(Result);
          AError := rsAccUnsupported;
        end;
      end;
    ad389Ds:
      begin
        Result := NewChange(ckModify, AEntry.Dn);
        case AAction of
          aaDisable: Result.AddMod(moReplace, 'nsAccountLock', ['true']);
          aaEnable: Result.AddMod(moDelete, 'nsAccountLock', []);
          aaUnlock:
            begin
              // Seuls les attributs presents: supprimer un absent ferait echouer tout le Modify.
              if AEntry.Find('passwordRetryCount') <> nil then
                Result.AddMod(moDelete, 'passwordRetryCount', []);
              if AEntry.Find('accountUnlockTime') <> nil then
                Result.AddMod(moDelete, 'accountUnlockTime', []);
            end;
        else
          FreeAndNil(Result);
          AError := rsAccUnsupported;
        end;
      end;
  else
    AError := rsAccNoAdapter;
  end;
end;

end.
