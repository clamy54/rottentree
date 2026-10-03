// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdapApi;

{$mode objfpc}{$H+}

// Liaison C de libldap/liblber d'OpenLDAP 2.6. Chaque allocation de la bibliotheque
// se libere avec SA fonction (ldap_memfree, ber_bvfree, ldap_msgfree...). ber_len_t est un unsigned long: 32 bits
// sous Win64, 64 sous Unix. Merci, LLP64.

interface

uses
  SysUtils, ctypes, dynlibs;

type
  ber_len_t = culong;
  ber_int_t = cint;
  ber_tag_t = culong;

  PBerval = ^TBerval;
  PPBerval = ^PBerval;
  TBerval = record
    bv_len: ber_len_t;
    bv_val: PAnsiChar;
  end;
  TBervalArray = array[0..MaxInt div SizeOf(TBerval) - 1] of TBerval;
  PBervalArray = ^TBervalArray;

  PLDAPControl = ^TLDAPControl;
  PPLDAPControl = ^PLDAPControl;
  TLDAPControl = record
    ldctl_oid: PAnsiChar;
    ldctl_value: TBerval;
    ldctl_iscritical: AnsiChar;
  end;

  PLdapModC = ^TLdapModC;
  PPLdapModC = ^PLdapModC;
  TLdapModC = record
    mod_op: cint;
    mod_type: PAnsiChar;
    mod_bvalues: PPBerval;
  end;

  PLDAP = Pointer;
  PPLDAP = ^PLDAP;
  PLDAPMessage = Pointer;
  PBerElement = Pointer;

  TLdapTimeval = record
    tv_sec: clong;
    tv_usec: clong;
  end;
  PLdapTimeval = ^TLdapTimeval;

  ELdapApiError = class(Exception);

const
  LDAP_VERSION3 = 3;
  LDAP_SUCCESS = 0;

  LDAP_OPT_DEREF = $0002;
  LDAP_OPT_SIZELIMIT = $0003;
  LDAP_OPT_TIMELIMIT = $0004;
  LDAP_OPT_REFERRALS = $0008;
  LDAP_OPT_RESTART = $0009;
  LDAP_OPT_PROTOCOL_VERSION = $0011;
  LDAP_OPT_RESULT_CODE = $0031;
  LDAP_OPT_DIAGNOSTIC_MESSAGE = $0032;
  LDAP_OPT_TIMEOUT = $5002;
  LDAP_OPT_NETWORK_TIMEOUT = $5005;
  LDAP_OPT_URI = $5006;
  LDAP_OPT_X_TLS_CTX = $6001;
  LDAP_OPT_X_TLS_REQUIRE_CERT = $6006;
  LDAP_OPT_X_TLS_PROTOCOL_MIN = $6007;
  LDAP_OPT_X_TLS_SSL_CTX = $600a;
  LDAP_OPT_X_TLS_NEWCTX = $600f;
  LDAP_OPT_X_TLS_REQUIRE_SAN = $601a;
  LDAP_OPT_X_SASL_SSF = $6104;
  LDAP_OPT_X_TLS_NEVER = 0;
  LDAP_OPT_X_TLS_DEMAND = 2;
  LDAP_OPT_X_TLS_PROTOCOL_TLS1_2 = (3 shl 8) + 3;
  LDAP_OPT_X_KEEPALIVE_IDLE = $6300;

  LDAP_MOD_ADD = $0000;
  LDAP_MOD_DELETE = $0001;
  LDAP_MOD_REPLACE = $0002;
  LDAP_MOD_INCREMENT = $0003;
  LDAP_MOD_BVALUES = $0080;

  LDAP_RES_BIND = $61;
  LDAP_RES_SEARCH_ENTRY = $64;
  LDAP_RES_SEARCH_RESULT = $65;
  LDAP_RES_MODIFY = $67;
  LDAP_RES_ADD = $69;
  LDAP_RES_DELETE = $6b;
  LDAP_RES_MODDN = $6d;
  LDAP_RES_COMPARE = $6f;
  LDAP_RES_SEARCH_REFERENCE = $73;
  LDAP_RES_EXTENDED = $78;
  LDAP_RES_INTERMEDIATE = $79;
  LDAP_RES_ANY = -1;

  LDAP_MSG_ONE = $00;
  LDAP_MSG_ALL = $01;
  LDAP_MSG_RECEIVED = $02;

  LDAP_CONTROL_PAGEDRESULTS = '1.2.840.113556.1.4.319';
  LDAP_CONTROL_ASSERT = '1.3.6.1.1.12';
  LDAP_CONTROL_MANAGEDSAIT = '2.16.840.1.113730.3.4.2';
  LDAP_EXOP_WHO_AM_I = '1.3.6.1.4.1.4203.1.11.3';
  LDAP_EXOP_MODIFY_PASSWD = '1.3.6.1.4.1.4203.1.11.1';
  LDAP_EXOP_START_TLS = '1.3.6.1.4.1.1466.20037';

var
  ldap_initialize: function(ldp: PPLDAP; url: PAnsiChar): cint; cdecl = nil;
  ldap_set_option: function(ld: PLDAP; option: cint; invalue: Pointer): cint; cdecl = nil;
  ldap_get_option: function(ld: PLDAP; option: cint; outvalue: Pointer): cint; cdecl = nil;
  ldap_connect: function(ld: PLDAP): cint; cdecl = nil;
  ldap_start_tls_s: function(ld: PLDAP; sctrls, cctrls: PPLDAPControl): cint; cdecl = nil;
  ldap_sasl_bind: function(ld: PLDAP; dn, mechanism: PAnsiChar; cred: PBerval;
    sctrls, cctrls: PPLDAPControl; msgidp: pcint): cint; cdecl = nil;
  ldap_parse_sasl_bind_result: function(ld: PLDAP; res: PLDAPMessage;
    servercredp: PPBerval; freeit: cint): cint; cdecl = nil;
  ldap_unbind_ext: function(ld: PLDAP; sctrls, cctrls: PPLDAPControl): cint; cdecl = nil;
  ldap_search_ext: function(ld: PLDAP; base: PAnsiChar; scope: cint; filter: PAnsiChar;
    attrs: PPAnsiChar; attrsonly: cint; sctrls, cctrls: PPLDAPControl;
    timeout: PLdapTimeval; sizelimit: cint; msgidp: pcint): cint; cdecl = nil;
  ldap_result: function(ld: PLDAP; msgid, all: cint; timeout: PLdapTimeval;
    result: PPointer): cint; cdecl = nil;
  ldap_msgtype: function(lm: PLDAPMessage): cint; cdecl = nil;
  ldap_msgid: function(lm: PLDAPMessage): cint; cdecl = nil;
  ldap_msgfree: function(lm: PLDAPMessage): cint; cdecl = nil;
  ldap_first_message: function(ld: PLDAP; chain: PLDAPMessage): PLDAPMessage; cdecl = nil;
  ldap_next_message: function(ld: PLDAP; msg: PLDAPMessage): PLDAPMessage; cdecl = nil;
  ldap_get_dn_ber: function(ld: PLDAP; e: PLDAPMessage; berout: PPointer;
    dn: PBerval): cint; cdecl = nil;
  ldap_get_attribute_ber: function(ld: PLDAP; e: PLDAPMessage; ber: PBerElement;
    attr: PBerval; vals: PPBerval): cint; cdecl = nil;
  ldap_parse_result: function(ld: PLDAP; res: PLDAPMessage; errcodep: pcint;
    matcheddnp, diagmsgp: PPAnsiChar; referralsp: PPPAnsiChar;
    serverctrlsp: PPointer; freeit: cint): cint; cdecl = nil;
  ldap_parse_reference: function(ld: PLDAP; ref: PLDAPMessage; referralsp: PPPAnsiChar;
    serverctrlsp: PPointer; freeit: cint): cint; cdecl = nil;
  ldap_parse_extended_result: function(ld: PLDAP; res: PLDAPMessage; retoidp: PPAnsiChar;
    retdatap: PPBerval; freeit: cint): cint; cdecl = nil;
  ldap_memfree: procedure(p: Pointer); cdecl = nil;
  ldap_memvfree: procedure(v: PPointer); cdecl = nil;
  ber_memfree: procedure(p: Pointer); cdecl = nil;
  ber_bvfree: procedure(bv: PBerval); cdecl = nil;
  ber_free: procedure(ber: PBerElement; freebuf: cint); cdecl = nil;
  ldap_controls_free: procedure(ctrls: PPLDAPControl); cdecl = nil;
  ldap_control_free: procedure(ctrl: PLDAPControl); cdecl = nil;
  ldap_control_find: function(oid: PAnsiChar; ctrls: PPLDAPControl;
    nextctrlp: Pointer): PLDAPControl; cdecl = nil;
  ldap_create_page_control: function(ld: PLDAP; pagesize: ber_int_t; cookie: PBerval;
    iscritical: cint; ctrlp: PPLDAPControl): cint; cdecl = nil;
  ldap_parse_pageresponse_control: function(ld: PLDAP; ctrl: PLDAPControl;
    count: pcint; cookie: PBerval): cint; cdecl = nil;
  ldap_create_assertion_control: function(ld: PLDAP; assertion: PAnsiChar;
    iscritical: cint; ctrlp: PPLDAPControl): cint; cdecl = nil;
  ldap_control_create: function(requestOID: PAnsiChar; iscritical: cint; value: PBerval;
    dupval: cint; ctrlp: PPLDAPControl): cint; cdecl = nil;
  ldap_abandon_ext: function(ld: PLDAP; msgid: cint; sctrls, cctrls: PPLDAPControl): cint; cdecl = nil;
  ldap_modify_ext: function(ld: PLDAP; dn: PAnsiChar; mods: PPLdapModC;
    sctrls, cctrls: PPLDAPControl; msgidp: pcint): cint; cdecl = nil;
  ldap_add_ext: function(ld: PLDAP; dn: PAnsiChar; attrs: PPLdapModC;
    sctrls, cctrls: PPLDAPControl; msgidp: pcint): cint; cdecl = nil;
  ldap_delete_ext: function(ld: PLDAP; dn: PAnsiChar; sctrls, cctrls: PPLDAPControl;
    msgidp: pcint): cint; cdecl = nil;
  ldap_rename: function(ld: PLDAP; dn, newrdn, newSuperior: PAnsiChar; deleteoldrdn: cint;
    sctrls, cctrls: PPLDAPControl; msgidp: pcint): cint; cdecl = nil;
  ldap_compare_ext: function(ld: PLDAP; dn, attr: PAnsiChar; bvalue: PBerval;
    sctrls, cctrls: PPLDAPControl; msgidp: pcint): cint; cdecl = nil;
  ldap_extended_operation: function(ld: PLDAP; reqoid: PAnsiChar; reqdata: PBerval;
    sctrls, cctrls: PPLDAPControl; msgidp: pcint): cint; cdecl = nil;
  ldap_err2string: function(err: cint): PAnsiChar; cdecl = nil;

procedure LdapEnsureLoaded;
function LdapVendorVersion: string;

function BervalToString(const B: TBerval): RawByteString;
// Pointe sur les octets de S: S doit survivre a l'appel C, sinon libldap lit un
// fantome.
function StringToBerval(const S: RawByteString): TBerval;

implementation

uses
  uNativeLib, uOpenSslApi;

var
  GLdap: TLibHandle = NilHandle;
  GLber: TLibHandle = NilHandle;
  GReady: Boolean = False;
  GLock: TRTLCriticalSection;

function LdapNames: TStringArray;
begin
  {$IFDEF WINDOWS}
  Result := ['libldap.dll'];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := ['libldap.so.2', 'libldap-2.6.so.0', 'libldap-2.5.so.0'];
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := ['libldap.2.dylib'];
  {$ENDIF}
end;

function LberNames: TStringArray;
begin
  {$IFDEF WINDOWS}
  Result := ['liblber.dll'];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := ['liblber.so.2', 'liblber-2.6.so.0', 'liblber-2.5.so.0'];
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := ['liblber.2.dylib'];
  {$ENDIF}
end;

procedure LdapEnsureLoaded;
var
  path: string;

  function S(const AName: string): Pointer;
  begin
    Result := NativeSymbol(GLdap, 'libldap', AName);
  end;

  function B(const AName: string): Pointer;
  begin
    Result := NativeSymbol(GLber, 'liblber', AName);
  end;

begin
  // Lecture hors verrou: la barriere garantit que les pointeurs de fonction publies
  // avant GReady sont visibles. Sur ARM64, l'ordre des ecritures n'est qu'une
  // suggestion.
  if GReady then
  begin
    ReadBarrier;
    Exit;
  end;
  EnterCriticalSection(GLock);
  try
    if GReady then Exit;
    // OpenSSL d'abord: libldap en depend, et on inspecte ses sessions TLS.
    OpenSslEnsureLoaded;
    GLber := LoadNativeLibrary('OpenLDAP liblber', LberNames, path);
    if GLber = NilHandle then
      raise ELdapApiError.Create('liblber not found in the expected locations');
    GLdap := LoadNativeLibrary('OpenLDAP libldap', LdapNames, path);
    if GLdap = NilHandle then
      raise ELdapApiError.Create('libldap not found in the expected locations');
    Pointer(ldap_initialize) := S('ldap_initialize');
    Pointer(ldap_set_option) := S('ldap_set_option');
    Pointer(ldap_get_option) := S('ldap_get_option');
    Pointer(ldap_connect) := S('ldap_connect');
    Pointer(ldap_start_tls_s) := S('ldap_start_tls_s');
    Pointer(ldap_sasl_bind) := S('ldap_sasl_bind');
    Pointer(ldap_parse_sasl_bind_result) := S('ldap_parse_sasl_bind_result');
    Pointer(ldap_unbind_ext) := S('ldap_unbind_ext');
    Pointer(ldap_search_ext) := S('ldap_search_ext');
    Pointer(ldap_result) := S('ldap_result');
    Pointer(ldap_msgtype) := S('ldap_msgtype');
    Pointer(ldap_msgid) := S('ldap_msgid');
    Pointer(ldap_msgfree) := S('ldap_msgfree');
    Pointer(ldap_first_message) := S('ldap_first_message');
    Pointer(ldap_next_message) := S('ldap_next_message');
    Pointer(ldap_get_dn_ber) := S('ldap_get_dn_ber');
    Pointer(ldap_get_attribute_ber) := S('ldap_get_attribute_ber');
    Pointer(ldap_parse_result) := S('ldap_parse_result');
    Pointer(ldap_parse_reference) := S('ldap_parse_reference');
    Pointer(ldap_parse_extended_result) := S('ldap_parse_extended_result');
    Pointer(ldap_memfree) := S('ldap_memfree');
    Pointer(ldap_memvfree) := S('ldap_memvfree');
    Pointer(ldap_controls_free) := S('ldap_controls_free');
    Pointer(ldap_control_free) := S('ldap_control_free');
    Pointer(ldap_control_find) := S('ldap_control_find');
    Pointer(ldap_create_page_control) := S('ldap_create_page_control');
    Pointer(ldap_parse_pageresponse_control) := S('ldap_parse_pageresponse_control');
    Pointer(ldap_create_assertion_control) := S('ldap_create_assertion_control');
    Pointer(ldap_control_create) := S('ldap_control_create');
    Pointer(ldap_abandon_ext) := S('ldap_abandon_ext');
    Pointer(ldap_modify_ext) := S('ldap_modify_ext');
    Pointer(ldap_add_ext) := S('ldap_add_ext');
    Pointer(ldap_delete_ext) := S('ldap_delete_ext');
    Pointer(ldap_rename) := S('ldap_rename');
    Pointer(ldap_compare_ext) := S('ldap_compare_ext');
    Pointer(ldap_extended_operation) := S('ldap_extended_operation');
    Pointer(ldap_err2string) := S('ldap_err2string');
    Pointer(ber_memfree) := B('ber_memfree');
    Pointer(ber_bvfree) := B('ber_bvfree');
    Pointer(ber_free) := B('ber_free');
    SetLoadedLibVersion('OpenLDAP libldap', LdapVendorVersion);
    // Symboles publies avant le drapeau, que d'autres fils lisent sans verrou.
    WriteBarrier;
    GReady := True;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

type
  TLdapApiInfo = record
    ldapai_info_version: cint;
    ldapai_api_version: cint;
    ldapai_protocol_version: cint;
    ldapai_extensions: PPAnsiChar;
    ldapai_vendor_name: PAnsiChar;
    ldapai_vendor_version: cint;
  end;

function LdapVendorVersion: string;
const
  LDAP_OPT_API_INFO = $0000;
  LDAP_API_INFO_VERSION = 1;
var
  info: TLdapApiInfo;
  v: Integer;
begin
  Result := '';
  if not Assigned(ldap_get_option) then Exit;
  FillChar(info, SizeOf(info), 0);
  info.ldapai_info_version := LDAP_API_INFO_VERSION;
  if ldap_get_option(nil, LDAP_OPT_API_INFO, @info) <> LDAP_SUCCESS then Exit;
  v := info.ldapai_vendor_version;
  Result := Format('%s %d.%d.%d', [string(info.ldapai_vendor_name), v div 10000,
    (v div 100) mod 100, v mod 100]);
  if info.ldapai_extensions <> nil then
    ldap_memvfree(PPointer(info.ldapai_extensions));
  if info.ldapai_vendor_name <> nil then
    ldap_memfree(info.ldapai_vendor_name);
end;

function BervalToString(const B: TBerval): RawByteString;
begin
  Result := '';
  if (B.bv_val = nil) or (B.bv_len = 0) then Exit;
  SetLength(Result, B.bv_len);
  Move(B.bv_val^, Result[1], B.bv_len);
end;

function StringToBerval(const S: RawByteString): TBerval;
begin
  Result.bv_len := Length(S);
  if S = '' then
    Result.bv_val := nil
  else
    Result.bv_val := @S[1];
end;

initialization
  InitCriticalSection(GLock);

finalization
  DoneCriticalSection(GLock);

end.
