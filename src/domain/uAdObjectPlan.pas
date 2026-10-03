// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAdObjectPlan;

{$mode objfpc}{$H+}

// Utilisateurs, ordinateurs, groupes et OU d'Active Directory, chacun en UNE requete
// Add complete (unicodePwd, userAccountControl, pwdLastSet, groupType compris).
// Tout ou rien: un mot de passe refuse par la politique du domaine ne laisse pas
// derriere lui un compte desactive sans mot de passe, que quelqu'un activera un jour.
//
// cn (ou ou) n'est jamais envoye, AD le tire du RDN. L'envoyer quand l'ordinateur
// est cree au titre de ms-DS-MachineAccountQuota vaut 0000207C CONSTRAINT_ATT_TYPE:
// un refus pour un attribut redondant, la bureaucratie dans toute sa splendeur.

interface

uses
  SysUtils, uLdapEntry;

const
  UAC_ACCOUNTDISABLE = $2;
  UAC_PASSWD_NOTREQD = $20;
  UAC_NORMAL_ACCOUNT = $200;
  UAC_WORKSTATION_TRUST_ACCOUNT = $1000;
  UAC_DONT_EXPIRE_PASSWD = $10000;

  GROUP_TYPE_GLOBAL = $2;
  GROUP_TYPE_DOMAIN_LOCAL = $4;
  GROUP_TYPE_UNIVERSAL = $8;
  GROUP_TYPE_SECURITY = LongWord($80000000);

  AD_CN_MAX = 64;
  AD_OU_MAX = 64;
  AD_SAM_USER_MAX = 20;
  AD_SAM_COMPUTER_MAX = 15;
  AD_SAM_GROUP_MAX = 256;
  AD_INITIALS_MAX = 6;
  AD_PREWIN2000_PWD_MAX = 14;

type
  TAdGroupScope = (agsDomainLocal, agsGlobal, agsUniversal);

  TAdUserInput = record
    FirstName, Initials, LastName, FullName: string;
    LogonName, UpnSuffix: string;
    SamName: string;
    Password, Confirm: RawByteString;
    MustChange, NeverExpires, Disabled: Boolean;
  end;

  TAdComputerInput = record
    Name: string;
    SamName: string;
    PreWindows2000: Boolean;
  end;

  TAdGroupInput = record
    Name: string;
    SamName: string;
    Scope: TAdGroupScope;
    Security: Boolean;
  end;

  TAdOuInput = record
    Name: string;
  end;

function AdDomainDnsName(const ADn: string): string;
function AdCanonicalPath(const ADn: string): string;
function AdDefaultFullName(const AFirst, AInitials, ALast: string): string;
function AdSamFromName(const AName: string; AMax: Integer): string;
function AdComputerSamFromName(const AName: string): string;
function AdGroupTypeText(AScope: TAdGroupScope; ASecurity: Boolean): string;
function AdUserAccountControl(const A: TAdUserInput): LongWord;

function AdUserProblem(const A: TAdUserInput): string;
function AdComputerProblem(const A: TAdComputerInput): string;
function AdGroupProblem(const A: TAdGroupInput): string;
function AdOuProblem(const A: TAdOuInput): string;

function BuildAdUserEntry(const AParentDn: string; const A: TAdUserInput; out AError: string): TLdapEntry;
function BuildAdComputerEntry(const AParentDn: string; const A: TAdComputerInput;
  out AError: string): TLdapEntry;
function BuildAdGroupEntry(const AParentDn: string; const A: TAdGroupInput; out AError: string): TLdapEntry;
function BuildAdOuEntry(const AParentDn: string; const A: TAdOuInput; out AError: string): TLdapEntry;

resourcestring
  rsAoNameMissing = 'Enter a name.';
  rsAoNameTooLong = 'The name is longer than %d characters.';
  rsAoNameChars = 'The name cannot contain %s.';
  rsAoSamMissing = 'Enter the pre-Windows 2000 logon name.';
  rsAoSamTooLong = 'The pre-Windows 2000 name is longer than %d characters.';
  rsAoSamChars = 'The pre-Windows 2000 name cannot contain %s.';
  rsAoSamDots = 'The pre-Windows 2000 name cannot consist only of periods or spaces.';
  rsAoUserNameMissing = 'Enter a first name, a last name or a full name.';
  rsAoInitialsTooLong = 'The initials are longer than %d characters.';
  rsAoLogonMissing = 'Enter the user logon name.';
  rsAoLogonChars = 'The user logon name cannot contain spaces or %s.';
  rsAoSuffixMissing = 'Choose the domain of the user logon name.';
  rsAoPasswordMissing = 'Enter a password: the account is created with it.';
  rsAoPasswordMismatch = 'The password and its confirmation differ.';
  rsAoMustChangeNeverExpires = 'A password that never expires cannot also be changed at the next logon: ' +
    'uncheck one of the two options.';
  rsAoComputerChars = 'A computer name uses letters, digits and hyphens only (DNS host name).';
  rsAoComputerDigits = 'A computer name cannot consist only of digits.';
  rsAoComputerHyphen = 'A computer name cannot start or end with a hyphen.';
  rsAoBadParent = 'The parent DN cannot be read: %s';

implementation

uses
  uLdapDn, uPasswordSchemes;

const
  SAM_EXCLUDED = '"/\[]:;|=,+*?<>@';

function AdDomainDnsName(const ADn: string): string;
var
  d: TLdapDn;
  i: Integer;
begin
  Result := '';
  if not DnTryParse(ADn, d) then Exit;
  for i := 0 to High(d.Rdns) do
    if (Length(d.Rdns[i].Avas) = 1) and SameText(d.Rdns[i].Avas[0].AttrType, 'DC') then
    begin
      if Result <> '' then Result := Result + '.';
      Result := Result + string(d.Rdns[i].Avas[0].Value);
    end;
end;

function AdCanonicalPath(const ADn: string): string;
var
  d: TLdapDn;
  i: Integer;
begin
  if not DnTryParse(ADn, d) then Exit(ADn);
  Result := AdDomainDnsName(ADn);
  for i := High(d.Rdns) downto 0 do
  begin
    if (Length(d.Rdns[i].Avas) = 1) and SameText(d.Rdns[i].Avas[0].AttrType, 'DC') then Continue;
    if Length(d.Rdns[i].Avas) = 0 then Continue;
    if Result <> '' then Result := Result + '/';
    Result := Result + string(d.Rdns[i].Avas[0].Value);
  end;
  if Result = '' then Result := ADn;
end;

function AdDefaultFullName(const AFirst, AInitials, ALast: string): string;
begin
  Result := Trim(AFirst);
  if Trim(AInitials) <> '' then
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + Trim(AInitials) + '.';
  end;
  if Trim(ALast) <> '' then
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + Trim(ALast);
  end;
end;

function AdSamFromName(const AName: string; AMax: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(AName) do
    if (Pos(AName[i], SAM_EXCLUDED) = 0) and (AName[i] >= ' ') then
      Result := Result + AName[i];
  Result := Trim(Result);
  // Tronque en caracteres, pas en octets: un caractere UTF-8 coupe en deux, c'est
  // une valeur invalide qui arrive au serveur avec un air innocent.
  if Length(UTF8Decode(Result)) > AMax then
    Result := UTF8Encode(Copy(UTF8Decode(Result), 1, AMax));
end;

function AdComputerSamFromName(const AName: string): string;
begin
  Result := UpperCase(AdSamFromName(AName, AD_SAM_COMPUTER_MAX));
end;

function AdGroupTypeText(AScope: TAdGroupScope; ASecurity: Boolean): string;
var
  v: LongWord;
begin
  case AScope of
    agsDomainLocal: v := GROUP_TYPE_DOMAIN_LOCAL;
    agsGlobal: v := GROUP_TYPE_GLOBAL;
  else
    v := GROUP_TYPE_UNIVERSAL;
  end;
  if ASecurity then v := v or GROUP_TYPE_SECURITY;
  // Entier signe sur 32 bits: un groupe global de securite vaut -2147483646.
  // Oui, negatif: le bit de securite est le bit de signe.
  Result := IntToStr(LongInt(v));
end;

function AdUserAccountControl(const A: TAdUserInput): LongWord;
begin
  Result := UAC_NORMAL_ACCOUNT;
  if A.Disabled then Result := Result or UAC_ACCOUNTDISABLE;
  if A.NeverExpires then Result := Result or UAC_DONT_EXPIRE_PASSWD;
end;

function CharsLength(const S: string): Integer;
begin
  Result := Length(UTF8Decode(S));
end;

function HasAny(const S, AChars: string): Boolean;
var
  i: Integer;
begin
  for i := 1 to Length(S) do
    if Pos(S[i], AChars) > 0 then Exit(True);
  Result := False;
end;

function ShownChars(const AChars: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(AChars) do
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + AChars[i];
  end;
end;

function SamProblem(const ASam: string; AMax: Integer): string;
begin
  Result := '';
  if Trim(ASam) = '' then Exit(rsAoSamMissing);
  if CharsLength(ASam) > AMax then Exit(Format(rsAoSamTooLong, [AMax]));
  if HasAny(ASam, SAM_EXCLUDED) then Exit(Format(rsAoSamChars, [ShownChars(SAM_EXCLUDED)]));
  if Trim(StringReplace(ASam, '.', '', [rfReplaceAll])) = '' then Exit(rsAoSamDots);
end;

function CnProblem(const AName: string; AMax: Integer = AD_CN_MAX): string;
begin
  Result := '';
  if Trim(AName) = '' then Exit(rsAoNameMissing);
  if CharsLength(Trim(AName)) > AMax then Exit(Format(rsAoNameTooLong, [AMax]));
end;

function AdUserProblem(const A: TAdUserInput): string;
begin
  if (Trim(A.FirstName) = '') and (Trim(A.LastName) = '') and (Trim(A.FullName) = '') then
    Exit(rsAoUserNameMissing);
  Result := CnProblem(A.FullName);
  if Result <> '' then Exit;
  if CharsLength(Trim(A.Initials)) > AD_INITIALS_MAX then
    Exit(Format(rsAoInitialsTooLong, [AD_INITIALS_MAX]));
  if Trim(A.LogonName) = '' then Exit(rsAoLogonMissing);
  if HasAny(Trim(A.LogonName), SAM_EXCLUDED + ' ') then
    Exit(Format(rsAoLogonChars, [ShownChars(SAM_EXCLUDED)]));
  if Trim(A.UpnSuffix) = '' then Exit(rsAoSuffixMissing);
  Result := SamProblem(A.SamName, AD_SAM_USER_MAX);
  if Result <> '' then Exit;
  if A.Password = '' then Exit(rsAoPasswordMissing);
  if A.Password <> A.Confirm then Exit(rsAoPasswordMismatch);
  if A.MustChange and A.NeverExpires then Exit(rsAoMustChangeNeverExpires);
end;

function AdComputerProblem(const A: TAdComputerInput): string;
var
  n: string;
  i: Integer;
  digitsOnly: Boolean;
begin
  Result := CnProblem(A.Name);
  if Result <> '' then Exit;
  n := Trim(A.Name);
  digitsOnly := True;
  for i := 1 to Length(n) do
  begin
    if not (n[i] in ['A'..'Z', 'a'..'z', '0'..'9', '-']) then Exit(rsAoComputerChars);
    if not (n[i] in ['0'..'9']) then digitsOnly := False;
  end;
  if digitsOnly then Exit(rsAoComputerDigits);
  if (n[1] = '-') or (n[Length(n)] = '-') then Exit(rsAoComputerHyphen);
  Result := SamProblem(A.SamName, AD_SAM_COMPUTER_MAX);
end;

function AdGroupProblem(const A: TAdGroupInput): string;
begin
  Result := CnProblem(A.Name);
  if Result <> '' then Exit;
  Result := SamProblem(A.SamName, AD_SAM_GROUP_MAX);
end;

function AdOuProblem(const A: TAdOuInput): string;
begin
  Result := CnProblem(A.Name, AD_OU_MAX);
end;

function ChildDn(const AParentDn, ACn: string; out ADn, AError: string;
  const AType: string = 'CN'): Boolean;
var
  parent: TLdapDn;
  err: string;
begin
  Result := False;
  ADn := '';
  AError := '';
  if not DnParse(AParentDn, parent, err) then
  begin
    AError := Format(rsAoBadParent, [err]);
    Exit;
  end;
  ADn := DnToString(DnChild(parent, DnMakeRdn(AType, RawByteString(Trim(ACn)))));
  Result := True;
end;

function BuildAdUserEntry(const AParentDn: string; const A: TAdUserInput; out AError: string): TLdapEntry;
var
  dn: string;
  e: TLdapEntry;
begin
  Result := nil;
  AError := AdUserProblem(A);
  if AError <> '' then Exit;
  if not ChildDn(AParentDn, A.FullName, dn, AError) then Exit;
  e := TLdapEntry.Create(dn);
  e.Ensure('objectClass').SetValues(['top', 'person', 'organizationalPerson', 'user']);
  if Trim(A.FirstName) <> '' then e.Ensure('givenName').AddValue(RawByteString(Trim(A.FirstName)));
  if Trim(A.Initials) <> '' then e.Ensure('initials').AddValue(RawByteString(Trim(A.Initials)));
  if Trim(A.LastName) <> '' then e.Ensure('sn').AddValue(RawByteString(Trim(A.LastName)));
  e.Ensure('displayName').AddValue(RawByteString(Trim(A.FullName)));
  e.Ensure('userPrincipalName').AddValue(RawByteString(Trim(A.LogonName) + '@' + Trim(A.UpnSuffix)));
  e.Ensure('sAMAccountName').AddValue(RawByteString(Trim(A.SamName)));
  // Mot de passe et etat du compte dans la meme requete: tout ou rien. La valeur
  // est ecrasee a la liberation de l'entree, pas laissee au prochain dump memoire.
  with e.Ensure('unicodePwd') do
  begin
    Sensitive := True;
    AddValue(EncodeUnicodePwd(A.Password));
  end;
  e.Ensure('userAccountControl').AddValue(RawByteString(IntToStr(AdUserAccountControl(A))));
  if A.MustChange then e.Ensure('pwdLastSet').AddValue('0');
  Result := e;
end;

function BuildAdComputerEntry(const AParentDn: string; const A: TAdComputerInput;
  out AError: string): TLdapEntry;
var
  dn, sam: string;
  e: TLdapEntry;
begin
  Result := nil;
  AError := AdComputerProblem(A);
  if AError <> '' then Exit;
  if not ChildDn(AParentDn, A.Name, dn, AError) then Exit;
  sam := UpperCase(Trim(A.SamName));
  e := TLdapEntry.Create(dn);
  e.Ensure('objectClass').SetValues(['top', 'person', 'organizationalPerson', 'user', 'computer']);
  e.Ensure('sAMAccountName').AddValue(RawByteString(sam + '$'));
  e.Ensure('userAccountControl').AddValue(
    RawByteString(IntToStr(UAC_WORKSTATION_TRUST_ACCOUNT or UAC_PASSWD_NOTREQD)));
  // Pre-Windows 2000: mot de passe initial = nom en minuscules, celui que le poste
  // presentera a la jonction. Securite de 1999, compatibilite garantie.
  if A.PreWindows2000 then
    with e.Ensure('unicodePwd') do
    begin
      Sensitive := True;
      AddValue(EncodeUnicodePwd(RawByteString(LowerCase(Copy(sam, 1, AD_PREWIN2000_PWD_MAX)))));
    end;
  Result := e;
end;

function BuildAdGroupEntry(const AParentDn: string; const A: TAdGroupInput; out AError: string): TLdapEntry;
var
  dn: string;
  e: TLdapEntry;
begin
  Result := nil;
  AError := AdGroupProblem(A);
  if AError <> '' then Exit;
  if not ChildDn(AParentDn, A.Name, dn, AError) then Exit;
  e := TLdapEntry.Create(dn);
  e.Ensure('objectClass').SetValues(['top', 'group']);
  e.Ensure('sAMAccountName').AddValue(RawByteString(Trim(A.SamName)));
  e.Ensure('groupType').AddValue(RawByteString(AdGroupTypeText(A.Scope, A.Security)));
  Result := e;
end;

function BuildAdOuEntry(const AParentDn: string; const A: TAdOuInput; out AError: string): TLdapEntry;
var
  dn: string;
begin
  Result := nil;
  AError := AdOuProblem(A);
  if AError <> '' then Exit;
  if not ChildDn(AParentDn, A.Name, dn, AError, 'OU') then Exit;
  Result := TLdapEntry.Create(dn);
  Result.Ensure('objectClass').SetValues(['top', 'organizationalUnit']);
end;

end.
