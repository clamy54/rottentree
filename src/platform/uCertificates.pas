// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCertificates;

{$mode objfpc}{$H+}

// Certificats X.509: lecture PEM/DER, description, empreintes SHA-256 et magasin de
// confiance d'une connexion. La confiance ajoutee a un profil ne touche jamais au
// magasin systeme: elle vit dans une copie en memoire, le temps d'une verification.

interface

uses
  SysUtils, Classes, uOpenSslApi;

const
  CERT_MAX_FILE_BYTES = 1024 * 1024;
  CERT_MAX_IN_FILE = 64;

type
  TCertExtension = record
    Oid: string;
    Name: string;
    Critical: Boolean;
    Known: Boolean;
  end;

  TCertInfo = record
    Subject: string;
    Issuer: string;
    SerialHex: string;
    NotBefore: TDateTime;
    NotAfter: TDateTime;
    DatesReadable: Boolean;
    Sha256: string;
    Sha1: string;
    DnsNames: array of string;
    IpAddresses: array of string;
    KeyBits: Integer;
    SignatureAlgorithm: string;
    IsCa: Boolean;
    SelfIssued: Boolean;
    Version: Integer;
    KeyAlgorithm: string;
    KeyUsage: string;
    ExtKeyUsage: string;
    Emails: array of string;
    Uris: array of string;  // SAN URI: texte, jamais suivi
    Extensions: array of TCertExtension;
    ExtensionCount: Integer;
    // Octets restants apres la structure DER (valeur LDAP suivie de donnees parasites):
    // signales, jamais ignores.
    TrailingBytes: Integer;
  end;

  ECertificateError = class(Exception);

function ParseCertificates(const AData: RawByteString; out ADerList: TStringArray;
  out AError: string): Boolean;
function DescribeCertificate(const ADer: RawByteString): TCertInfo;
function FormatFingerprint(const AHex: string): string;
function CertSha256(const ADer: RawByteString): string;

function BuildTrustStore(AIncludeSystemRoots: Boolean;
  const AExtraCasDer: array of RawByteString; out ASystemCount: Integer): PX509_STORE;

function X509FromDer(const ADer: RawByteString): PX509;
function X509ToDer(AX509: PX509): RawByteString;

implementation

uses
  ctypes, DateUtils, uRtBytes
  {$IFDEF WINDOWS}, Windows{$ENDIF};

function X509FromDer(const ADer: RawByteString): PX509;
var
  p: PByte;
begin
  OpenSslEnsureLoaded;
  if ADer = '' then Exit(nil);
  p := @ADer[1];
  Result := d2i_X509(nil, p, Length(ADer));
end;

function X509ToDer(AX509: PX509): RawByteString;
var
  n: cint;
  p: PByte;
begin
  Result := '';
  n := i2d_X509(AX509, nil);
  if n <= 0 then Exit;
  SetLength(Result, n);
  p := @Result[1];
  i2d_X509(AX509, @p);
end;

function ParseCertificates(const AData: RawByteString; out ADerList: TStringArray;
  out AError: string): Boolean;
const
  BeginMark = '-----BEGIN CERTIFICATE-----';
  EndMark = '-----END CERTIFICATE-----';
var
  p, q: Integer;
  body, der: RawByteString;
  x: PX509;
  i: Integer;
begin
  Result := False;
  ADerList := nil;
  AError := '';
  OpenSslEnsureLoaded;
  if Length(AData) > CERT_MAX_FILE_BYTES then
  begin
    AError := 'certificate file too large';
    Exit;
  end;
  p := Pos(BeginMark, AData);
  if p = 0 then
  begin
    x := X509FromDer(AData);
    if x = nil then
    begin
      AError := 'not a PEM or DER certificate';
      Exit;
    end;
    X509_free(x);
    ADerList := [AData];
    Exit(True);
  end;
  while p > 0 do
  begin
    q := Pos(EndMark, Copy(AData, p, MaxInt));
    if q = 0 then
    begin
      AError := 'unterminated PEM block';
      Exit;
    end;
    body := Copy(AData, p + Length(BeginMark), q - 1 - Length(BeginMark));
    der := '';
    for i := 1 to Length(body) do
      if not (body[i] in [#9, #10, #13, ' ']) then
        der := der + body[i];
    if not Base64DecodeStrict(der, body) then
    begin
      AError := 'invalid base64 in PEM block';
      Exit;
    end;
    x := X509FromDer(body);
    if x = nil then
    begin
      AError := 'unreadable certificate in PEM block';
      Exit;
    end;
    X509_free(x);
    if Length(ADerList) >= CERT_MAX_IN_FILE then
    begin
      AError := 'too many certificates in one file';
      Exit;
    end;
    SetLength(ADerList, Length(ADerList) + 1);
    ADerList[High(ADerList)] := body;
    Inc(p, q + Length(EndMark) - 1);
    q := Pos(BeginMark, Copy(AData, p, MaxInt));
    if q = 0 then Break;
    p := p + q - 1;
  end;
  Result := Length(ADerList) > 0;
  if not Result then AError := 'no certificate found';
end;

function CertSha256(const ADer: RawByteString): string;
begin
  Result := HexEncode(DigestOf('SHA256', ADer));
end;

function FormatFingerprint(const AHex: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(AHex) do
  begin
    if (i > 1) and Odd(i) then Result := Result + ':';
    Result := Result + UpCase(AHex[i]);
  end;
end;

function NameToString(AName: Pointer): string;
const
  // XN_FLAG_RFC2253 sans ASN1_STRFLGS_ESC_MSB, sinon OpenSSL echappe l'UTF-8 octet par
  // octet et le nom devient illisible.
  XN_FLAG_RFC2253 = $01110313;
  BIO_CTRL_INFO = 3;
var
  bio: PBIO;
  data: PAnsiChar;
  n: clong;
begin
  Result := '';
  bio := BIO_new(BIO_s_mem());
  if bio = nil then Exit;
  try
    if X509_NAME_print_ex(bio, AName, 0, XN_FLAG_RFC2253) < 0 then Exit;
    data := nil;
    n := BIO_ctrl(bio, BIO_CTRL_INFO, 0, @data);
    if (n > 0) and (data <> nil) then
      SetString(Result, data, n);
  finally
    BIO_free(bio);
  end;
end;

type
  // struct tm: seuls les 9 premiers champs sont communs a toutes les libc cibles.
  TTmBuf = record
    tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst: cint;
    pad: array[0..7] of cint;
  end;

function AsnTimeToDateTime(T: PASN1_TIME; out ADate: TDateTime): Boolean;
var
  tm: TTmBuf;
begin
  Result := False;
  ADate := 0;
  if T = nil then Exit;
  FillChar(tm, SizeOf(tm), 0);
  if ASN1_TIME_to_tm(T, @tm) <> 1 then Exit;
  Result := TryEncodeDateTime(tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour,
    tm.tm_min, tm.tm_sec, 0, ADate);
end;

type
  PAsn1String = ^TAsn1String;
  TAsn1String = record
    length: cint;
    typ: cint;
    data: PByte;
    flags: clong;
  end;

  PGeneralName = ^TGeneralName;
  TGeneralName = record
    typ: cint;
    d: Pointer;
  end;

const
  NID_subject_alt_name = 85;
  GEN_EMAIL = 1;
  GEN_DNS = 2;
  GEN_URI = 6;
  GEN_IPADD = 7;
  NO_USAGE = $FFFFFFFF;

function KeyUsageText(AFlags: LongWord): string;
const
  Bits: array[0..8] of LongWord = ($80, $40, $20, $10, $08, $04, $02, $01, $8000);
  Names: array[0..8] of string = ('digitalSignature', 'nonRepudiation', 'keyEncipherment',
    'dataEncipherment', 'keyAgreement', 'keyCertSign', 'cRLSign', 'encipherOnly', 'decipherOnly');
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Bits) do
    if (AFlags and Bits[i]) <> 0 then
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + Names[i];
    end;
  if Result = '' then Result := '(none)';
end;

function ExtKeyUsageText(AFlags: LongWord): string;
const
  Bits: array[0..8] of LongWord = ($1, $2, $4, $8, $10, $20, $40, $80, $100);
  Names: array[0..8] of string = ('serverAuth', 'clientAuth', 'emailProtection', 'codeSigning',
    'serverGatedCrypto', 'OCSPSigning', 'timeStamping', 'DVCS', 'anyExtendedKeyUsage');
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Bits) do
    if (AFlags and Bits[i]) <> 0 then
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + Names[i];
    end;
  if Result = '' then Result := '(other purposes only)';
end;

function ObjectOid(AObj: Pointer): string;
var
  buf: array[0..127] of AnsiChar;
  n: cint;
begin
  Result := '';
  if AObj = nil then Exit;
  n := OBJ_obj2txt(@buf[0], SizeOf(buf), AObj, 1);
  if (n > 0) and (n < SizeOf(buf)) then
    SetString(Result, PAnsiChar(@buf[0]), n);
end;

function IpBytesToString(P: PByte; ALen: Integer): string;
var
  i: Integer;
begin
  Result := '';
  if ALen = 4 then
    Result := Format('%d.%d.%d.%d', [P[0], P[1], P[2], P[3]])
  else if ALen = 16 then
  begin
    for i := 0 to 7 do
    begin
      if i > 0 then Result := Result + ':';
      Result := Result + LowerCase(IntToHex((Integer(P[i * 2]) shl 8) or P[i * 2 + 1], 1));
    end;
  end;
end;

function DescribeCertificate(const ADer: RawByteString): TCertInfo;
var
  x: PX509;
  sk: Pointer;
  i, n: Integer;
  gn: PGeneralName;
  s: PAsn1String;
  pkey: PEVP_PKEY;
  txt: string;
  serial: Pointer;
  buf: RawByteString;
  bp: PByte;
  pin: PByte;
  ext: Pointer;
  nid: cint;
  u: LongWord;
begin
  Result := Default(TCertInfo);
  OpenSslEnsureLoaded;
  if ADer = '' then
    raise ECertificateError.Create('unreadable certificate');
  pin := @ADer[1];
  x := d2i_X509(nil, pin, Length(ADer));
  if x = nil then
    raise ECertificateError.Create('unreadable certificate');
  Result.TrailingBytes := Length(ADer) - (PtrUInt(pin) - PtrUInt(@ADer[1]));
  try
    Result.Version := X509_get_version(x) + 1;
    Result.Subject := NameToString(X509_get_subject_name(x));
    Result.Issuer := NameToString(X509_get_issuer_name(x));
    Result.SelfIssued := Result.Subject = Result.Issuer;
    Result.DatesReadable := AsnTimeToDateTime(X509_get0_notBefore(x), Result.NotBefore) and
      AsnTimeToDateTime(X509_get0_notAfter(x), Result.NotAfter);
    Result.Sha256 := CertSha256(ADer);
    Result.Sha1 := HexEncode(DigestOf('SHA1', ADer));
    Result.IsCa := X509_check_ca(x) > 0;
    serial := X509_get_serialNumber(x);
    if serial <> nil then
    begin
      n := i2d_ASN1_INTEGER(serial, nil);
      if (n > 2) and (n < 128) then
      begin
        SetLength(buf, n);
        bp := @buf[1];
        i2d_ASN1_INTEGER(serial, @bp);
        if (buf[1] = #2) and (Byte(buf[2]) = n - 2) then
          Result.SerialHex := HexEncode(Copy(buf, 3, MaxInt));
      end;
    end;
    pkey := X509_get_pubkey(x);
    if pkey <> nil then
    begin
      Result.KeyBits := EVP_PKEY_get_bits(pkey);
      if EVP_PKEY_get0_type_name(pkey) <> nil then
        Result.KeyAlgorithm := string(EVP_PKEY_get0_type_name(pkey));
      EVP_PKEY_free(pkey);
    end;
    txt := '';
    if OBJ_nid2ln(X509_get_signature_nid(x)) <> nil then
      txt := string(OBJ_nid2ln(X509_get_signature_nid(x)));
    Result.SignatureAlgorithm := txt;
    sk := X509_get_ext_d2i(x, NID_subject_alt_name, nil, nil);
    if sk <> nil then
    begin
      try
        for i := 0 to OPENSSL_sk_num(sk) - 1 do
        begin
          gn := PGeneralName(OPENSSL_sk_value(sk, i));
          if gn = nil then Continue;
          s := PAsn1String(gn^.d);
          if (s = nil) or (s^.data = nil) or (s^.length <= 0) or (s^.length > 1024) then Continue;
          if gn^.typ = GEN_DNS then
          begin
            SetString(txt, PAnsiChar(s^.data), s^.length);
            SetLength(Result.DnsNames, Length(Result.DnsNames) + 1);
            Result.DnsNames[High(Result.DnsNames)] := txt;
          end
          else if gn^.typ = GEN_IPADD then
          begin
            SetLength(Result.IpAddresses, Length(Result.IpAddresses) + 1);
            Result.IpAddresses[High(Result.IpAddresses)] := IpBytesToString(s^.data, s^.length);
          end
          else if gn^.typ = GEN_EMAIL then
          begin
            SetString(txt, PAnsiChar(s^.data), s^.length);
            SetLength(Result.Emails, Length(Result.Emails) + 1);
            Result.Emails[High(Result.Emails)] := txt;
          end
          else if gn^.typ = GEN_URI then
          begin
            SetString(txt, PAnsiChar(s^.data), s^.length);
            SetLength(Result.Uris, Length(Result.Uris) + 1);
            Result.Uris[High(Result.Uris)] := txt;
          end;
        end;
      finally
        OPENSSL_sk_pop_free(sk, Pointer(GENERAL_NAME_free));
      end;
    end;
    u := X509_get_key_usage(x);
    if u <> NO_USAGE then Result.KeyUsage := KeyUsageText(u);
    u := X509_get_extended_key_usage(x);
    if u <> NO_USAGE then Result.ExtKeyUsage := ExtKeyUsageText(u);
    n := X509_get_ext_count(x);
    Result.ExtensionCount := n;
    if n > 64 then n := 64;
    SetLength(Result.Extensions, 0);
    for i := 0 to n - 1 do
    begin
      ext := X509_get_ext(x, i);
      if ext = nil then Continue;
      SetLength(Result.Extensions, Length(Result.Extensions) + 1);
      with Result.Extensions[High(Result.Extensions)] do
      begin
        Oid := ObjectOid(X509_EXTENSION_get_object(ext));
        Critical := X509_EXTENSION_get_critical(ext) > 0;
        nid := OBJ_obj2nid(X509_EXTENSION_get_object(ext));
        Known := nid <> 0;
        if Known and (OBJ_nid2ln(nid) <> nil) then Name := string(OBJ_nid2ln(nid)) else Name := '';
      end;
    end;
  finally
    X509_free(x);
  end;
end;

{$IFDEF WINDOWS}
type
  PCertContext = ^TCertContext;
  TCertContext = record
    dwCertEncodingType: DWORD;
    pbCertEncoded: PByte;
    cbCertEncoded: DWORD;
    pCertInfo: Pointer;
    hCertStore: Pointer;
  end;

function CertOpenSystemStoreW(hProv: Pointer; szSubsystemProtocol: PWideChar): Pointer;
  stdcall; external 'crypt32.dll';
function CertEnumCertificatesInStore(hCertStore: Pointer; pPrevCertContext: PCertContext): PCertContext;
  stdcall; external 'crypt32.dll';
function CertCloseStore(hCertStore: Pointer; dwFlags: DWORD): BOOL;
  stdcall; external 'crypt32.dll';

function AddWindowsRoots(AStore: PX509_STORE): Integer;
var
  hStore: Pointer;
  ctx: PCertContext;
  der: RawByteString;
  x: PX509;
begin
  Result := 0;
  hStore := CertOpenSystemStoreW(nil, 'ROOT');
  if hStore = nil then Exit;
  try
    ctx := CertEnumCertificatesInStore(hStore, nil);
    while ctx <> nil do
    begin
      if (ctx^.cbCertEncoded > 0) and (ctx^.cbCertEncoded < 64 * 1024) then
      begin
        SetString(der, PAnsiChar(ctx^.pbCertEncoded), ctx^.cbCertEncoded);
        x := X509FromDer(der);
        if x <> nil then
        begin
          if X509_STORE_add_cert(AStore, x) = 1 then Inc(Result);
          X509_free(x);
        end;
      end;
      ctx := CertEnumCertificatesInStore(hStore, ctx);
    end;
  finally
    CertCloseStore(hStore, 0);
  end;
  ERR_clear_error;
end;
{$ENDIF}

function BuildTrustStore(AIncludeSystemRoots: Boolean;
  const AExtraCasDer: array of RawByteString; out ASystemCount: Integer): PX509_STORE;
var
  i: Integer;
  x: PX509;
begin
  OpenSslEnsureLoaded;
  ASystemCount := 0;
  Result := X509_STORE_new();
  if Result = nil then
    raise ECertificateError.Create('X509_STORE_new failed');
  if AIncludeSystemRoots then
  begin
    {$IFDEF WINDOWS}
    ASystemCount := AddWindowsRoots(Result);
    {$ELSE}
    {$IFDEF DARWIN}
    // macOS: magasin groupe expose par le systeme; les ancres du trousseau passent par
    // Security.framework.
    if X509_STORE_load_locations(Result, '/etc/ssl/cert.pem', nil) = 1 then
      ASystemCount := 1;
    {$ELSE}
    if X509_STORE_set_default_paths(Result) = 1 then
      ASystemCount := 1;
    {$ENDIF}
    {$ENDIF}
  end;
  for i := 0 to High(AExtraCasDer) do
  begin
    x := X509FromDer(AExtraCasDer[i]);
    if x = nil then Continue;
    X509_STORE_add_cert(Result, x);
    X509_free(x);
  end;
  ERR_clear_error;
end;

end.
