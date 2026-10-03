// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uServerKind;

{$mode objfpc}{$H+}

// Devine le type de serveur a partir du Root DSE: capacites AD, classe OpenLDAP,
// fournisseur, extensions. Une supposition n'autorise jamais seule une ecriture
// propre a un fournisseur: le choix manuel du profil prime et le schema est
// encore verifie. Un Root DSE, ca se maquille.

interface

uses
  SysUtils, uLdapEntry, uConnectionProfile;

const
  OID_AD_CAP = '1.2.840.113556.1.4.800';
  OID_AD_CAP_V51 = '1.2.840.113556.1.4.1670';
  OID_ADLDS_CAP = '1.2.840.113556.1.4.1851';

type
  TServerDetection = record
    Kind: TProviderKind;
    Evidence: array of string;
    Samba: Boolean;
    AdLds: Boolean;
  end;

resourcestring
  rsKindOpenLdap = 'OpenLDAP';
  rsKindAd = 'Active Directory';
  rsKind389 = '389 Directory Server';
  rsKindApache = 'ApacheDS';
  rsKindOther = 'Other LDAP server';
  rsKindAuto = 'Automatic detection';
  rsEvAdCapability = 'supportedCapabilities announces Active Directory (%s)';
  rsEvAdLds = 'supportedCapabilities announces AD LDS (%s)';
  rsEvDomainFunctionality = 'domainFunctionality is present';
  rsEvOpenLdapClass = 'root DSE object class OpenLDAProotDSE';
  rsEvConfigContext = 'configContext is announced (%s)';
  rsEvVendor = 'vendorName: %s';
  rsEvVendorVersion = 'vendorVersion: %s';
  rsEvNone = 'no conclusive indication in the root DSE';

function DetectServerKind(ARootDse: TLdapEntry): TServerDetection;
function EffectiveServerKind(AProfile: TConnectionProfile; ARootDse: TLdapEntry): TProviderKind;
function ServerKindName(AKind: TProviderKind): string;

implementation

function HasValue(AEntry: TLdapEntry; const AAttr, AValue: string): Boolean;
var
  a: TLdapAttribute;
  i: Integer;
begin
  Result := False;
  a := AEntry.Find(AAttr);
  if a = nil then Exit;
  for i := 0 to a.ValueCount - 1 do
    if SameText(a.Values[i], AValue) then Exit(True);
end;

procedure AddEvidence(var D: TServerDetection; const S: string);
begin
  SetLength(D.Evidence, Length(D.Evidence) + 1);
  D.Evidence[High(D.Evidence)] := S;
end;

function DetectServerKind(ARootDse: TLdapEntry): TServerDetection;
var
  vendor, version, lv: string;
begin
  Result := Default(TServerDetection);
  Result.Kind := pkOther;
  if ARootDse = nil then
  begin
    AddEvidence(Result, rsEvNone);
    Exit;
  end;
  vendor := Trim(ARootDse.FirstValue('vendorName', ''));
  version := Trim(ARootDse.FirstValue('vendorVersion', ''));
  lv := LowerCase(vendor + ' ' + version);
  if vendor <> '' then AddEvidence(Result, Format(rsEvVendor, [vendor]));
  if version <> '' then AddEvidence(Result, Format(rsEvVendorVersion, [version]));
  if HasValue(ARootDse, 'supportedCapabilities', OID_AD_CAP) or
     HasValue(ARootDse, 'supportedCapabilities', OID_AD_CAP_V51) then
  begin
    Result.Kind := pkActiveDirectory;
    AddEvidence(Result, Format(rsEvAdCapability, [OID_AD_CAP]));
    if ARootDse.Find('domainFunctionality') <> nil then
      AddEvidence(Result, rsEvDomainFunctionality);
    Result.Samba := Pos('samba', lv) > 0;
    Exit;
  end;
  if HasValue(ARootDse, 'supportedCapabilities', OID_ADLDS_CAP) then
  begin
    Result.Kind := pkActiveDirectory;
    Result.AdLds := True;
    AddEvidence(Result, Format(rsEvAdLds, [OID_ADLDS_CAP]));
    Exit;
  end;
  if HasValue(ARootDse, 'objectClass', 'OpenLDAProotDSE') then
  begin
    Result.Kind := pkOpenLdap;
    AddEvidence(Result, rsEvOpenLdapClass);
    if ARootDse.Find('configContext') <> nil then
      AddEvidence(Result, Format(rsEvConfigContext, [ARootDse.FirstValue('configContext', '')]));
    Exit;
  end;
  if (Pos('389', lv) > 0) or (Pos('fedora', lv) > 0) or (Pos('red hat', lv) > 0) or
     (Pos('netscape', lv) > 0) then
  begin
    Result.Kind := pk389Ds;
    Exit;
  end;
  if Pos('apache', lv) > 0 then
  begin
    Result.Kind := pkApacheDs;
    Exit;
  end;
  if Length(Result.Evidence) = 0 then
    AddEvidence(Result, rsEvNone);
end;

function EffectiveServerKind(AProfile: TConnectionProfile; ARootDse: TLdapEntry): TProviderKind;
begin
  if (AProfile <> nil) and (AProfile.Provider <> pkAuto) then
    Result := AProfile.Provider
  else
    Result := DetectServerKind(ARootDse).Kind;
end;

function ServerKindName(AKind: TProviderKind): string;
begin
  case AKind of
    pkOpenLdap: Result := rsKindOpenLdap;
    pkActiveDirectory: Result := rsKindAd;
    pk389Ds: Result := rsKind389;
    pkApacheDs: Result := rsKindApache;
    pkAuto: Result := rsKindAuto;
  else
    Result := rsKindOther;
  end;
end;

end.
