// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uOpenSslApi;

{$mode objfpc}{$H+}

// Liaison dynamique de libcrypto (OpenSSL 3): condensats, HMAC, PBKDF2, DES crypt
// historique, alea et verification X.509. libssl n'est pas liee ici, libldap la charge
// elle-meme. Pas d'API a moitie: un symbole manquant fait echouer l'initialisation.

interface

uses
  SysUtils, ctypes, dynlibs;

const
  OPENSSL_VERSION_ = 0;
  EVP_MAX_MD_SIZE = 64;

  X509_V_OK = 0;
  X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT = 2;
  X509_V_ERR_UNABLE_TO_DECODE_ISSUER_PUBLIC_KEY = 6;
  X509_V_ERR_CERT_SIGNATURE_FAILURE = 7;
  X509_V_ERR_CERT_NOT_YET_VALID = 9;
  X509_V_ERR_CERT_HAS_EXPIRED = 10;
  X509_V_ERR_ERROR_IN_CERT_NOT_BEFORE_FIELD = 13;
  X509_V_ERR_ERROR_IN_CERT_NOT_AFTER_FIELD = 14;
  X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT = 18;
  X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN = 19;
  X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY = 20;
  X509_V_ERR_UNABLE_TO_VERIFY_LEAF_SIGNATURE = 21;
  X509_V_ERR_CERT_CHAIN_TOO_LONG = 22;
  X509_V_ERR_CERT_REVOKED = 23;
  X509_V_ERR_INVALID_CA = 24;
  X509_V_ERR_INVALID_PURPOSE = 26;
  X509_V_ERR_CERT_UNTRUSTED = 27;
  X509_V_ERR_CERT_REJECTED = 28;
  X509_V_ERR_HOSTNAME_MISMATCH = 62;
  X509_V_ERR_IP_ADDRESS_MISMATCH = 64;
  X509_V_ERR_UNABLE_TO_GET_CRL = 3;
  X509_V_ERR_CA_KEY_TOO_SMALL = 67;
  X509_V_ERR_CA_MD_TOO_WEAK = 68;
  X509_V_ERR_EE_KEY_TOO_SMALL = 66;

  X509_V_FLAG_CRL_CHECK = $4;
  X509_V_FLAG_NO_CHECK_TIME = $200000;
  X509_V_FLAG_PARTIAL_CHAIN = $80000;

  X509_PURPOSE_SSL_SERVER = 2;
  X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS = $4;

type
  EOpenSslError = class(Exception);

  PEVP_MD = Pointer;
  PEVP_MD_CTX = Pointer;
  PX509 = Pointer;
  PX509_STORE = Pointer;
  PX509_STORE_CTX = Pointer;
  PX509_VERIFY_PARAM = Pointer;
  POPENSSL_STACK = Pointer;
  PSSL = Pointer;
  PBIO = Pointer;
  PEVP_PKEY = Pointer;
  PASN1_TIME = Pointer;

  TEVP_md_fn = function: PEVP_MD; cdecl;

var
  OpenSSL_version: function(t: cint): PAnsiChar; cdecl = nil;
  EVP_md5: TEVP_md_fn = nil;
  EVP_sha1: TEVP_md_fn = nil;
  EVP_sha256: TEVP_md_fn = nil;
  EVP_sha384: TEVP_md_fn = nil;
  EVP_sha512: TEVP_md_fn = nil;
  EVP_MD_CTX_new: function: PEVP_MD_CTX; cdecl = nil;
  EVP_MD_CTX_free: procedure(ctx: PEVP_MD_CTX); cdecl = nil;
  EVP_DigestInit_ex: function(ctx: PEVP_MD_CTX; md: PEVP_MD; impl: Pointer): cint; cdecl = nil;
  EVP_DigestUpdate: function(ctx: PEVP_MD_CTX; d: Pointer; cnt: csize_t): cint; cdecl = nil;
  EVP_DigestFinal_ex: function(ctx: PEVP_MD_CTX; md: PByte; var s: cuint): cint; cdecl = nil;
  EVP_MD_get_size: function(md: PEVP_MD): cint; cdecl = nil;
  PKCS5_PBKDF2_HMAC: function(pass: PAnsiChar; passlen: cint; salt: PByte; saltlen: cint;
    iter: cint; digest: PEVP_MD; keylen: cint; outp: PByte): cint; cdecl = nil;
  HMAC: function(evp_md: PEVP_MD; key: Pointer; key_len: cint; d: PByte; n: csize_t;
    md: PByte; var md_len: cuint): PByte; cdecl = nil;
  RAND_bytes: function(buf: PByte; num: cint): cint; cdecl = nil;
  CRYPTO_memcmp: function(a, b: Pointer; len: csize_t): cint; cdecl = nil;
  OPENSSL_cleanse: procedure(ptr: Pointer; len: csize_t); cdecl = nil;
  DES_fcrypt: function(buf, salt: PAnsiChar; ret: PAnsiChar): PAnsiChar; cdecl = nil;

  d2i_X509: function(px: Pointer; var inp: PByte; len: clong): PX509; cdecl = nil;
  i2d_X509: function(x: PX509; outp: Pointer): cint; cdecl = nil;
  X509_free: procedure(x: PX509); cdecl = nil;
  X509_up_ref: function(x: PX509): cint; cdecl = nil;
  X509_digest: function(x: PX509; md: PEVP_MD; outp: PByte; var len: cuint): cint; cdecl = nil;
  X509_STORE_new: function: PX509_STORE; cdecl = nil;
  X509_STORE_free: procedure(s: PX509_STORE); cdecl = nil;
  X509_STORE_add_cert: function(s: PX509_STORE; x: PX509): cint; cdecl = nil;
  X509_STORE_set_default_paths: function(s: PX509_STORE): cint; cdecl = nil;
  X509_STORE_CTX_new: function: PX509_STORE_CTX; cdecl = nil;
  X509_STORE_CTX_free: procedure(c: PX509_STORE_CTX); cdecl = nil;
  X509_STORE_CTX_init: function(c: PX509_STORE_CTX; s: PX509_STORE; x: PX509;
    chain: POPENSSL_STACK): cint; cdecl = nil;
  X509_STORE_CTX_get0_param: function(c: PX509_STORE_CTX): PX509_VERIFY_PARAM; cdecl = nil;
  X509_STORE_CTX_set_verify_cb: procedure(c: PX509_STORE_CTX; cb: Pointer); cdecl = nil;
  X509_STORE_CTX_get_error: function(c: PX509_STORE_CTX): cint; cdecl = nil;
  X509_STORE_CTX_set_error: procedure(c: PX509_STORE_CTX; e: cint); cdecl = nil;
  X509_STORE_CTX_get_error_depth: function(c: PX509_STORE_CTX): cint; cdecl = nil;
  X509_STORE_CTX_get_ex_data: function(c: PX509_STORE_CTX; idx: cint): Pointer; cdecl = nil;
  X509_STORE_CTX_set_ex_data: function(c: PX509_STORE_CTX; idx: cint; data: Pointer): cint; cdecl = nil;
  X509_STORE_CTX_get1_chain: function(c: PX509_STORE_CTX): POPENSSL_STACK; cdecl = nil;
  X509_verify_cert: function(c: PX509_STORE_CTX): cint; cdecl = nil;
  X509_verify_cert_error_string: function(n: clong): PAnsiChar; cdecl = nil;
  X509_VERIFY_PARAM_set_flags: function(p: PX509_VERIFY_PARAM; flags: culong): cint; cdecl = nil;
  X509_VERIFY_PARAM_set_purpose: function(p: PX509_VERIFY_PARAM; purpose: cint): cint; cdecl = nil;
  X509_VERIFY_PARAM_set1_host: function(p: PX509_VERIFY_PARAM; name: PAnsiChar; len: csize_t): cint; cdecl = nil;
  X509_VERIFY_PARAM_set1_ip_asc: function(p: PX509_VERIFY_PARAM; ipasc: PAnsiChar): cint; cdecl = nil;
  X509_VERIFY_PARAM_set_hostflags: procedure(p: PX509_VERIFY_PARAM; flags: cuint); cdecl = nil;
  X509_check_host: function(x: PX509; chk: PAnsiChar; len: csize_t; flags: cuint;
    peername: Pointer): cint; cdecl = nil;
  X509_check_ip_asc: function(x: PX509; address: PAnsiChar; flags: cuint): cint; cdecl = nil;
  X509_get_subject_name: function(x: PX509): Pointer; cdecl = nil;
  X509_get_issuer_name: function(x: PX509): Pointer; cdecl = nil;
  X509_NAME_oneline: function(name: Pointer; buf: PAnsiChar; size: cint): PAnsiChar; cdecl = nil;
  X509_get0_notBefore: function(x: PX509): PASN1_TIME; cdecl = nil;
  X509_get0_notAfter: function(x: PX509): PASN1_TIME; cdecl = nil;
  X509_get_serialNumber: function(x: PX509): Pointer; cdecl = nil;
  ASN1_TIME_to_tm: function(s: PASN1_TIME; tm: Pointer): cint; cdecl = nil;
  CRYPTO_free: procedure(p: Pointer; f: PAnsiChar; l: cint); cdecl = nil;
  OPENSSL_sk_num: function(sk: POPENSSL_STACK): cint; cdecl = nil;
  OPENSSL_sk_value: function(sk: POPENSSL_STACK; i: cint): Pointer; cdecl = nil;
  OPENSSL_sk_new_null: function: POPENSSL_STACK; cdecl = nil;
  OPENSSL_sk_push: function(sk: POPENSSL_STACK; data: Pointer): cint; cdecl = nil;
  OPENSSL_sk_free: procedure(sk: POPENSSL_STACK); cdecl = nil;
  OPENSSL_sk_pop_free: procedure(sk: POPENSSL_STACK; fn: Pointer); cdecl = nil;
  PEM_read_bio_X509: function(bp: PBIO; x: Pointer; cb: Pointer; u: Pointer): PX509; cdecl = nil;
  BIO_new_mem_buf: function(buf: Pointer; len: cint): PBIO; cdecl = nil;
  BIO_free: function(b: PBIO): cint; cdecl = nil;
  ERR_clear_error: procedure; cdecl = nil;
  X509_get_ext_d2i: function(x: PX509; nid: cint; crit: pcint; idx: pcint): Pointer; cdecl = nil;
  X509_get_pubkey: function(x: PX509): PEVP_PKEY; cdecl = nil;
  EVP_PKEY_get_bits: function(pkey: PEVP_PKEY): cint; cdecl = nil;
  EVP_PKEY_free: procedure(pkey: PEVP_PKEY); cdecl = nil;
  X509_get_signature_nid: function(x: PX509): cint; cdecl = nil;
  OBJ_nid2ln: function(n: cint): PAnsiChar; cdecl = nil;
  X509_NAME_print_ex: function(outp: PBIO; nm: Pointer; indent: cint; flags: culong): cint; cdecl = nil;
  BIO_new: function(typ: Pointer): PBIO; cdecl = nil;
  BIO_s_mem: function: Pointer; cdecl = nil;
  BIO_ctrl: function(b: PBIO; cmd: cint; larg: clong; parg: Pointer): clong; cdecl = nil;
  X509_get_version: function(x: PX509): clong; cdecl = nil;
  GENERAL_NAME_free: procedure(a: Pointer); cdecl = nil;
  X509_STORE_load_locations: function(s: PX509_STORE; f, dir: PAnsiChar): cint; cdecl = nil;
  X509_check_ca: function(x: PX509): cint; cdecl = nil;
  ASN1_INTEGER_get: function(a: Pointer): clong; cdecl = nil;
  i2d_ASN1_INTEGER: function(a: Pointer; pp: Pointer): cint; cdecl = nil;
  X509_get_ext_count: function(x: PX509): cint; cdecl = nil;
  X509_get_ext: function(x: PX509; loc: cint): Pointer; cdecl = nil;
  X509_EXTENSION_get_object: function(ex: Pointer): Pointer; cdecl = nil;
  X509_EXTENSION_get_critical: function(ex: Pointer): cint; cdecl = nil;
  OBJ_obj2nid: function(o: Pointer): cint; cdecl = nil;
  OBJ_obj2txt: function(buf: PAnsiChar; buf_len: cint; a: Pointer; no_name: cint): cint; cdecl = nil;
  X509_get_key_usage: function(x: PX509): cuint32; cdecl = nil;
  X509_get_extended_key_usage: function(x: PX509): cuint32; cdecl = nil;
  EVP_PKEY_get0_type_name: function(key: PEVP_PKEY): PAnsiChar; cdecl = nil;
  // libssl est chargee par libldap; on la lie ici pour inspecter la session TLS
  // negociee.
  SSL_get_peer_cert_chain: function(s: PSSL): POPENSSL_STACK; cdecl = nil;
  SSL_get1_peer_certificate: function(s: PSSL): PX509; cdecl = nil;
  SSL_get_version: function(s: PSSL): PAnsiChar; cdecl = nil;
  SSL_get_current_cipher: function(s: PSSL): Pointer; cdecl = nil;
  SSL_CIPHER_get_name: function(c: Pointer): PAnsiChar; cdecl = nil;
  SSL_get_verify_result: function(s: PSSL): clong; cdecl = nil;
  SSL_version: function(s: PSSL): cint; cdecl = nil;
  TLS_client_method: function: Pointer; cdecl = nil;
  SSL_CTX_new: function(meth: Pointer): Pointer; cdecl = nil;
  SSL_CTX_free: procedure(ctx: Pointer); cdecl = nil;
  SSL_CTX_ctrl: function(ctx: Pointer; cmd: cint; larg: clong; parg: Pointer): clong; cdecl = nil;
  SSL_CTX_set_verify: procedure(ctx: Pointer; mode: cint; cb: Pointer); cdecl = nil;
  SSL_CTX_use_certificate_file: function(ctx: Pointer; f: PAnsiChar; typ: cint): cint; cdecl = nil;
  SSL_CTX_use_PrivateKey_file: function(ctx: Pointer; f: PAnsiChar; typ: cint): cint; cdecl = nil;
  SSL_CTX_check_private_key: function(ctx: Pointer): cint; cdecl = nil;
  SSL_CTX_set_options: function(ctx: Pointer; op: cuint64): cuint64; cdecl = nil;

const
  SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
  SSL_VERIFY_NONE = 0;
  SSL_FILETYPE_PEM = 1;
  SSL_OP_NO_RENEGOTIATION = cuint64($40000000);
  SSL_OP_NO_COMPRESSION = cuint64($00020000);

procedure OpenSslEnsureLoaded;
function OpenSslVersionText: string;

function DigestOf(const AAlgo: string; const AData: RawByteString): RawByteString;
function DigestByName(const AAlgo: string): PEVP_MD;

type
  TDigestCtx = record
    Ctx: PEVP_MD_CTX;
    Md: PEVP_MD;
  end;

procedure DigestInit(out C: TDigestCtx; const AAlgo: string);
procedure DigestUpdate(var C: TDigestCtx; const AData: RawByteString);
function DigestFinal(var C: TDigestCtx): RawByteString;
procedure DigestFree(var C: TDigestCtx);

function Pbkdf2Hmac(const AAlgo: string; const APassword, ASalt: RawByteString;
  AIterations, AKeyLen: Integer): RawByteString;
function DesCrypt(const APassword, ASalt2: RawByteString): RawByteString;

implementation

uses
  uNativeLib;

var
  GCrypto: TLibHandle = NilHandle;
  GSsl: TLibHandle = NilHandle;
  GReady: Boolean = False;
  GLock: TRTLCriticalSection;

function CryptoNames: TStringArray;
begin
  {$IFDEF WINDOWS}
  Result := ['libcrypto-3-x64.dll'];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := ['libcrypto.so.3'];
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := ['libcrypto.3.dylib'];
  {$ENDIF}
end;

function SslNames: TStringArray;
begin
  {$IFDEF WINDOWS}
  Result := ['libssl-3-x64.dll'];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := ['libssl.so.3'];
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := ['libssl.3.dylib'];
  {$ENDIF}
end;

procedure OpenSslEnsureLoaded;
var
  path: string;

  function S(const AName: string): Pointer;
  begin
    Result := NativeSymbol(GCrypto, 'libcrypto', AName);
  end;

  function SS(const AName: string): Pointer;
  begin
    Result := NativeSymbol(GSsl, 'libssl', AName);
  end;

begin
  // Lecture hors verrou: la barriere publie les pointeurs de fonction avant GReady,
  // indispensable sur les processeurs a ordre faible (ARM64).
  if GReady then
  begin
    ReadBarrier;
    Exit;
  end;
  EnterCriticalSection(GLock);
  try
    if GReady then Exit;
    GCrypto := LoadNativeLibrary('OpenSSL libcrypto', CryptoNames, path);
    if GCrypto = NilHandle then
      raise EOpenSslError.Create('libcrypto (OpenSSL 3) not found in the expected locations');
    GSsl := LoadNativeLibrary('OpenSSL libssl', SslNames, path);
    if GSsl = NilHandle then
      raise EOpenSslError.Create('libssl (OpenSSL 3) not found in the expected locations');
    Pointer(OpenSSL_version) := S('OpenSSL_version');
    Pointer(EVP_md5) := S('EVP_md5');
    Pointer(EVP_sha1) := S('EVP_sha1');
    Pointer(EVP_sha256) := S('EVP_sha256');
    Pointer(EVP_sha384) := S('EVP_sha384');
    Pointer(EVP_sha512) := S('EVP_sha512');
    Pointer(EVP_MD_CTX_new) := S('EVP_MD_CTX_new');
    Pointer(EVP_MD_CTX_free) := S('EVP_MD_CTX_free');
    Pointer(EVP_DigestInit_ex) := S('EVP_DigestInit_ex');
    Pointer(EVP_DigestUpdate) := S('EVP_DigestUpdate');
    Pointer(EVP_DigestFinal_ex) := S('EVP_DigestFinal_ex');
    Pointer(EVP_MD_get_size) := S('EVP_MD_get_size');
    Pointer(PKCS5_PBKDF2_HMAC) := S('PKCS5_PBKDF2_HMAC');
    Pointer(HMAC) := S('HMAC');
    Pointer(RAND_bytes) := S('RAND_bytes');
    Pointer(CRYPTO_memcmp) := S('CRYPTO_memcmp');
    Pointer(OPENSSL_cleanse) := S('OPENSSL_cleanse');
    Pointer(DES_fcrypt) := S('DES_fcrypt');
    Pointer(d2i_X509) := S('d2i_X509');
    Pointer(i2d_X509) := S('i2d_X509');
    Pointer(X509_free) := S('X509_free');
    Pointer(X509_up_ref) := S('X509_up_ref');
    Pointer(X509_digest) := S('X509_digest');
    Pointer(X509_STORE_new) := S('X509_STORE_new');
    Pointer(X509_STORE_free) := S('X509_STORE_free');
    Pointer(X509_STORE_add_cert) := S('X509_STORE_add_cert');
    Pointer(X509_STORE_set_default_paths) := S('X509_STORE_set_default_paths');
    Pointer(X509_STORE_CTX_new) := S('X509_STORE_CTX_new');
    Pointer(X509_STORE_CTX_free) := S('X509_STORE_CTX_free');
    Pointer(X509_STORE_CTX_init) := S('X509_STORE_CTX_init');
    Pointer(X509_STORE_CTX_get0_param) := S('X509_STORE_CTX_get0_param');
    Pointer(X509_STORE_CTX_set_verify_cb) := S('X509_STORE_CTX_set_verify_cb');
    Pointer(X509_STORE_CTX_get_error) := S('X509_STORE_CTX_get_error');
    Pointer(X509_STORE_CTX_set_error) := S('X509_STORE_CTX_set_error');
    Pointer(X509_STORE_CTX_get_error_depth) := S('X509_STORE_CTX_get_error_depth');
    Pointer(X509_STORE_CTX_get_ex_data) := S('X509_STORE_CTX_get_ex_data');
    Pointer(X509_STORE_CTX_set_ex_data) := S('X509_STORE_CTX_set_ex_data');
    Pointer(X509_STORE_CTX_get1_chain) := S('X509_STORE_CTX_get1_chain');
    Pointer(X509_verify_cert) := S('X509_verify_cert');
    Pointer(X509_verify_cert_error_string) := S('X509_verify_cert_error_string');
    Pointer(X509_VERIFY_PARAM_set_flags) := S('X509_VERIFY_PARAM_set_flags');
    Pointer(X509_VERIFY_PARAM_set_purpose) := S('X509_VERIFY_PARAM_set_purpose');
    Pointer(X509_VERIFY_PARAM_set1_host) := S('X509_VERIFY_PARAM_set1_host');
    Pointer(X509_VERIFY_PARAM_set1_ip_asc) := S('X509_VERIFY_PARAM_set1_ip_asc');
    Pointer(X509_VERIFY_PARAM_set_hostflags) := S('X509_VERIFY_PARAM_set_hostflags');
    Pointer(X509_check_host) := S('X509_check_host');
    Pointer(X509_check_ip_asc) := S('X509_check_ip_asc');
    Pointer(X509_get_subject_name) := S('X509_get_subject_name');
    Pointer(X509_get_issuer_name) := S('X509_get_issuer_name');
    Pointer(X509_NAME_oneline) := S('X509_NAME_oneline');
    Pointer(X509_get0_notBefore) := S('X509_get0_notBefore');
    Pointer(X509_get0_notAfter) := S('X509_get0_notAfter');
    Pointer(X509_get_serialNumber) := S('X509_get_serialNumber');
    Pointer(ASN1_TIME_to_tm) := S('ASN1_TIME_to_tm');
    Pointer(CRYPTO_free) := S('CRYPTO_free');
    Pointer(OPENSSL_sk_num) := S('OPENSSL_sk_num');
    Pointer(OPENSSL_sk_value) := S('OPENSSL_sk_value');
    Pointer(OPENSSL_sk_new_null) := S('OPENSSL_sk_new_null');
    Pointer(OPENSSL_sk_push) := S('OPENSSL_sk_push');
    Pointer(OPENSSL_sk_free) := S('OPENSSL_sk_free');
    Pointer(OPENSSL_sk_pop_free) := S('OPENSSL_sk_pop_free');
    Pointer(PEM_read_bio_X509) := S('PEM_read_bio_X509');
    Pointer(BIO_new_mem_buf) := S('BIO_new_mem_buf');
    Pointer(BIO_free) := S('BIO_free');
    Pointer(ERR_clear_error) := S('ERR_clear_error');
    Pointer(X509_get_ext_d2i) := S('X509_get_ext_d2i');
    Pointer(X509_get_pubkey) := S('X509_get_pubkey');
    Pointer(EVP_PKEY_get_bits) := S('EVP_PKEY_get_bits');
    Pointer(EVP_PKEY_free) := S('EVP_PKEY_free');
    Pointer(X509_get_signature_nid) := S('X509_get_signature_nid');
    Pointer(OBJ_nid2ln) := S('OBJ_nid2ln');
    Pointer(X509_NAME_print_ex) := S('X509_NAME_print_ex');
    Pointer(BIO_new) := S('BIO_new');
    Pointer(BIO_s_mem) := S('BIO_s_mem');
    Pointer(BIO_ctrl) := S('BIO_ctrl');
    Pointer(X509_get_version) := S('X509_get_version');
    Pointer(GENERAL_NAME_free) := S('GENERAL_NAME_free');
    Pointer(X509_STORE_load_locations) := S('X509_STORE_load_locations');
    Pointer(X509_check_ca) := S('X509_check_ca');
    Pointer(ASN1_INTEGER_get) := S('ASN1_INTEGER_get');
    Pointer(i2d_ASN1_INTEGER) := S('i2d_ASN1_INTEGER');
    Pointer(X509_get_ext_count) := S('X509_get_ext_count');
    Pointer(X509_get_ext) := S('X509_get_ext');
    Pointer(X509_EXTENSION_get_object) := S('X509_EXTENSION_get_object');
    Pointer(X509_EXTENSION_get_critical) := S('X509_EXTENSION_get_critical');
    Pointer(OBJ_obj2nid) := S('OBJ_obj2nid');
    Pointer(OBJ_obj2txt) := S('OBJ_obj2txt');
    Pointer(X509_get_key_usage) := S('X509_get_key_usage');
    Pointer(X509_get_extended_key_usage) := S('X509_get_extended_key_usage');
    Pointer(EVP_PKEY_get0_type_name) := S('EVP_PKEY_get0_type_name');
    Pointer(SSL_get_peer_cert_chain) := SS('SSL_get_peer_cert_chain');
    Pointer(SSL_get1_peer_certificate) := SS('SSL_get1_peer_certificate');
    Pointer(SSL_get_version) := SS('SSL_get_version');
    Pointer(SSL_get_current_cipher) := SS('SSL_get_current_cipher');
    Pointer(SSL_CIPHER_get_name) := SS('SSL_CIPHER_get_name');
    Pointer(SSL_get_verify_result) := SS('SSL_get_verify_result');
    Pointer(SSL_version) := SS('SSL_version');
    Pointer(TLS_client_method) := SS('TLS_client_method');
    Pointer(SSL_CTX_new) := SS('SSL_CTX_new');
    Pointer(SSL_CTX_free) := SS('SSL_CTX_free');
    Pointer(SSL_CTX_ctrl) := SS('SSL_CTX_ctrl');
    Pointer(SSL_CTX_set_verify) := SS('SSL_CTX_set_verify');
    Pointer(SSL_CTX_use_certificate_file) := SS('SSL_CTX_use_certificate_file');
    Pointer(SSL_CTX_use_PrivateKey_file) := SS('SSL_CTX_use_PrivateKey_file');
    Pointer(SSL_CTX_check_private_key) := SS('SSL_CTX_check_private_key');
    Pointer(SSL_CTX_set_options) := SS('SSL_CTX_set_options');
    SetLoadedLibVersion('OpenSSL libcrypto', string(OpenSSL_version(OPENSSL_VERSION_)));
    // Symboles publies avant le drapeau lu hors verrou.
    WriteBarrier;
    GReady := True;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function OpenSslVersionText: string;
begin
  OpenSslEnsureLoaded;
  Result := string(OpenSSL_version(OPENSSL_VERSION_));
end;

function DigestByName(const AAlgo: string): PEVP_MD;
var
  a: string;
begin
  OpenSslEnsureLoaded;
  a := UpperCase(AAlgo);
  if a = 'MD5' then Result := EVP_md5()
  else if (a = 'SHA1') or (a = 'SHA') then Result := EVP_sha1()
  else if a = 'SHA256' then Result := EVP_sha256()
  else if a = 'SHA384' then Result := EVP_sha384()
  else if a = 'SHA512' then Result := EVP_sha512()
  else
    raise EOpenSslError.Create('unsupported digest ' + AAlgo);
end;

procedure DigestInit(out C: TDigestCtx; const AAlgo: string);
begin
  C.Md := DigestByName(AAlgo);
  C.Ctx := EVP_MD_CTX_new();
  if C.Ctx = nil then
    raise EOpenSslError.Create('EVP_MD_CTX_new failed');
  if EVP_DigestInit_ex(C.Ctx, C.Md, nil) <> 1 then
  begin
    EVP_MD_CTX_free(C.Ctx);
    C.Ctx := nil;
    raise EOpenSslError.Create('EVP_DigestInit_ex failed');
  end;
end;

procedure DigestUpdate(var C: TDigestCtx; const AData: RawByteString);
begin
  if AData = '' then Exit;
  if EVP_DigestUpdate(C.Ctx, @AData[1], Length(AData)) <> 1 then
    raise EOpenSslError.Create('EVP_DigestUpdate failed');
end;

function DigestFinal(var C: TDigestCtx): RawByteString;
var
  buf: array[0..EVP_MAX_MD_SIZE - 1] of Byte;
  n: cuint;
begin
  n := 0;
  if EVP_DigestFinal_ex(C.Ctx, @buf[0], n) <> 1 then
    raise EOpenSslError.Create('EVP_DigestFinal_ex failed');
  SetLength(Result, n);
  Move(buf[0], Result[1], n);
  OPENSSL_cleanse(@buf[0], SizeOf(buf));
  EVP_DigestInit_ex(C.Ctx, C.Md, nil);
end;

procedure DigestFree(var C: TDigestCtx);
begin
  if C.Ctx <> nil then
    EVP_MD_CTX_free(C.Ctx);
  C.Ctx := nil;
end;

function DigestOf(const AAlgo: string; const AData: RawByteString): RawByteString;
var
  c: TDigestCtx;
begin
  DigestInit(c, AAlgo);
  try
    DigestUpdate(c, AData);
    Result := DigestFinal(c);
  finally
    DigestFree(c);
  end;
end;

function Pbkdf2Hmac(const AAlgo: string; const APassword, ASalt: RawByteString;
  AIterations, AKeyLen: Integer): RawByteString;
var
  md: PEVP_MD;
  pw: PAnsiChar;
  salt: PByte;
begin
  md := DigestByName(AAlgo);
  if (AIterations < 1) or (AKeyLen < 1) then
    raise EOpenSslError.Create('invalid PBKDF2 parameters');
  SetLength(Result, AKeyLen);
  if APassword = '' then pw := PAnsiChar('') else pw := @APassword[1];
  if ASalt = '' then salt := nil else salt := @ASalt[1];
  if PKCS5_PBKDF2_HMAC(pw, Length(APassword), salt, Length(ASalt), AIterations, md,
      AKeyLen, @Result[1]) <> 1 then
    raise EOpenSslError.Create('PKCS5_PBKDF2_HMAC failed');
end;

function DesCrypt(const APassword, ASalt2: RawByteString): RawByteString;
var
  buf: array[0..13] of AnsiChar;
  pw: RawByteString;
begin
  OpenSslEnsureLoaded;
  // crypt(3) DES ne lit que 8 octets: l'appelant a deja refuse la troncature.
  pw := APassword + #0;
  FillChar(buf, SizeOf(buf), 0);
  if DES_fcrypt(@pw[1], PAnsiChar(ASalt2), @buf[0]) = nil then
    raise EOpenSslError.Create('DES_fcrypt failed');
  Result := StrPas(@buf[0]);
  OPENSSL_cleanse(@pw[1], Length(pw));
end;

initialization
  InitCriticalSection(GLock);

finalization
  DoneCriticalSection(GLock);

end.
