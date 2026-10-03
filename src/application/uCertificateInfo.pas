// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCertificateInfo;

{$mode objfpc}{$H+}

// Lecture de certificats pour l'interface: inspecteur de valeurs, import d'une CA dans un profil.
// OpenSSL fait le travail, cette unite tient la porte.

interface

uses
  SysUtils, Classes, uCertificates, uSafeSave;

const
  CERT_MAX_FILE_BYTES = uCertificates.CERT_MAX_FILE_BYTES;

type
  TCertInfo = uCertificates.TCertInfo;
  TCertExtension = uCertificates.TCertExtension;

  TCertValueReport = record
    Decoded: Boolean;
    DatesValid: Boolean;
    Lines: array of string;
  end;

function ParseCertificates(const AData: RawByteString; out ADerList: TStringArray;
  out AError: string): Boolean;
function DescribeCertificate(const ADer: RawByteString): TCertInfo;
function FormatFingerprint(const AHex: string): string;
function ReadCertificateFile(const APath: string; out AData: RawByteString;
  out AError: string): Boolean;
// Confiance NON verifiee: aucune chaine construite, aucun acces reseau. AIA, CRL, OCSP et URI sont
// affiches comme du texte, jamais suivis. Un certificat n'a pas a nous faire visiter internet.
function InspectCertificateValue(const AValue: RawByteString; ANowUtc: TDateTime): TCertValueReport;
function DerToPem(const ADer: RawByteString): RawByteString;

implementation

uses
  uRtBytes;

resourcestring
  rsCertFileTooLarge = 'The certificate file is larger than %d bytes.';
  rsCertFileUnreadable = 'The certificate file cannot be read: %s';
  rsCvDecoded = 'Decoded: yes (X.509 version %d)';
  rsCvNotDecoded = 'Decoded: no - %s';
  rsCvValueTooLarge = 'the value is larger than %d bytes';
  rsCvSeveral = 'the value holds %d certificates; each value is inspected on its own';
  rsCvDatesValid = 'Dates: valid now (%s to %s UTC)';
  rsCvNotYetValid = 'Dates: NOT YET VALID (valid from %s UTC)';
  rsCvExpired = 'Dates: EXPIRED on %s UTC';
  rsCvDatesUnreadable = 'Dates: unreadable';
  rsCvTrust = 'Trust: not verified. A directory value is not checked against any authority; ' +
    'inspecting it changes no trust setting of any profile.';
  rsCvSubject = 'Subject: %s';
  rsCvIssuer = 'Issuer: %s';
  rsCvSerial = 'Serial number: %s';
  rsCvKey = 'Public key: %s, %d bits';
  rsCvSignature = 'Signature: %s';
  rsCvCa = 'Certificate authority: %s';
  rsCvKeyUsage = 'Key usage: %s';
  rsCvExtKeyUsage = 'Extended key usage: %s';
  rsCvSanDns = 'SAN DNS: %s';
  rsCvSanIp = 'SAN IP: %s';
  rsCvSanEmail = 'SAN e-mail: %s';
  rsCvSanUri = 'SAN URI (not opened): %s';
  rsCvExt = 'Extension %s%s%s';
  rsCvExtCritical = ' [critical]';
  rsCvExtUnknown = ' [not interpreted]';
  rsCvExtOmitted = 'PARTIAL INSPECTION: %d of %d extensions are not listed (a critical one may be among them).';
  rsCvSha256 = 'SHA-256: %s';
  rsCvSha1 = 'SHA-1: %s';
  rsCvTrailing = 'Warning: %d byte(s) follow the certificate in this value; they are kept but not shown';
  rsCvYes = 'yes';
  rsCvNo = 'no';
  rsCvAbsent = '(extension absent)';

const
  PEM_BEGIN = '-----BEGIN CERTIFICATE-----';
  PEM_END = '-----END CERTIFICATE-----';

procedure AddLine(var R: TCertValueReport; const S: string);
begin
  SetLength(R.Lines, Length(R.Lines) + 1);
  // Chaines du certificat echappees: un CN farci de retours ligne ne forge pas de lignes dans le
  // rapport.
  R.Lines[High(R.Lines)] := EscapeControlChars(S);
end;

function DateText(ADate: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd hh":"nn":"ss', ADate);
end;

function InspectCertificateValue(const AValue: RawByteString; ANowUtc: TDateTime): TCertValueReport;
var
  der: RawByteString;
  ders: TStringArray;
  info: TCertInfo;
  err, s, crit, unk: string;
  i: Integer;
begin
  Result := Default(TCertValueReport);
  if Length(AValue) > CERT_MAX_FILE_BYTES then
  begin
    AddLine(Result, Format(rsCvNotDecoded, [Format(rsCvValueTooLarge, [CERT_MAX_FILE_BYTES])]));
    AddLine(Result, rsCvTrust);
    Exit;
  end;
  der := AValue;
  if Pos(PEM_BEGIN, AValue) > 0 then
  begin
    if not uCertificates.ParseCertificates(AValue, ders, err) then
    begin
      AddLine(Result, Format(rsCvNotDecoded, [err]));
      AddLine(Result, rsCvTrust);
      Exit;
    end;
    if Length(ders) <> 1 then
    begin
      AddLine(Result, Format(rsCvNotDecoded, [Format(rsCvSeveral, [Length(ders)])]));
      AddLine(Result, rsCvTrust);
      Exit;
    end;
    der := ders[0];
  end;
  try
    info := uCertificates.DescribeCertificate(der);
  except
    on E: Exception do
    begin
      AddLine(Result, Format(rsCvNotDecoded, [E.Message]));
      AddLine(Result, rsCvTrust);
      Exit;
    end;
  end;
  Result.Decoded := True;
  AddLine(Result, Format(rsCvDecoded, [info.Version]));
  if not info.DatesReadable then
    AddLine(Result, rsCvDatesUnreadable)
  else if ANowUtc < info.NotBefore then
    AddLine(Result, Format(rsCvNotYetValid, [DateText(info.NotBefore)]))
  else if ANowUtc > info.NotAfter then
    AddLine(Result, Format(rsCvExpired, [DateText(info.NotAfter)]))
  else
  begin
    Result.DatesValid := True;
    AddLine(Result, Format(rsCvDatesValid, [DateText(info.NotBefore), DateText(info.NotAfter)]));
  end;
  AddLine(Result, rsCvTrust);
  if info.TrailingBytes > 0 then
    AddLine(Result, Format(rsCvTrailing, [info.TrailingBytes]));
  AddLine(Result, '');
  AddLine(Result, Format(rsCvSubject, [info.Subject]));
  AddLine(Result, Format(rsCvIssuer, [info.Issuer]));
  AddLine(Result, Format(rsCvSerial, [info.SerialHex]));
  AddLine(Result, Format(rsCvKey, [info.KeyAlgorithm, info.KeyBits]));
  AddLine(Result, Format(rsCvSignature, [info.SignatureAlgorithm]));
  if info.IsCa then s := rsCvYes else s := rsCvNo;
  AddLine(Result, Format(rsCvCa, [s]));
  if info.KeyUsage <> '' then s := info.KeyUsage else s := rsCvAbsent;
  AddLine(Result, Format(rsCvKeyUsage, [s]));
  if info.ExtKeyUsage <> '' then s := info.ExtKeyUsage else s := rsCvAbsent;
  AddLine(Result, Format(rsCvExtKeyUsage, [s]));
  for i := 0 to High(info.DnsNames) do AddLine(Result, Format(rsCvSanDns, [info.DnsNames[i]]));
  for i := 0 to High(info.IpAddresses) do AddLine(Result, Format(rsCvSanIp, [info.IpAddresses[i]]));
  for i := 0 to High(info.Emails) do AddLine(Result, Format(rsCvSanEmail, [info.Emails[i]]));
  for i := 0 to High(info.Uris) do AddLine(Result, Format(rsCvSanUri, [info.Uris[i]]));
  for i := 0 to High(info.Extensions) do
  begin
    s := info.Extensions[i].Oid;
    if info.Extensions[i].Name <> '' then s := info.Extensions[i].Name + ' (' + s + ')';
    if info.Extensions[i].Critical then crit := rsCvExtCritical else crit := '';
    if info.Extensions[i].Known then unk := '' else unk := rsCvExtUnknown;
    AddLine(Result, Format(rsCvExt, [s, crit, unk]));
  end;
  // Liste d'extensions bornee: l'inspection est partielle et le dit.
  if info.ExtensionCount > Length(info.Extensions) then
    AddLine(Result, Format(rsCvExtOmitted, [info.ExtensionCount - Length(info.Extensions),
      info.ExtensionCount]));
  AddLine(Result, Format(rsCvSha256, [FormatFingerprint(info.Sha256)]));
  AddLine(Result, Format(rsCvSha1, [FormatFingerprint(info.Sha1)]));
end;

function DerToPem(const ADer: RawByteString): RawByteString;
var
  b64: string;
  i: Integer;
begin
  b64 := Base64EncodeStr(ADer);
  Result := PEM_BEGIN + #10;
  i := 1;
  while i <= Length(b64) do
  begin
    Result := Result + Copy(b64, i, 64) + #10;
    Inc(i, 64);
  end;
  Result := Result + PEM_END + #10;
end;

function ParseCertificates(const AData: RawByteString; out ADerList: TStringArray;
  out AError: string): Boolean;
begin
  Result := uCertificates.ParseCertificates(AData, ADerList, AError);
end;

function DescribeCertificate(const ADer: RawByteString): TCertInfo;
begin
  Result := uCertificates.DescribeCertificate(ADer);
end;

function FormatFingerprint(const AHex: string): string;
begin
  Result := uCertificates.FormatFingerprint(AHex);
end;

function ReadCertificateFile(const APath: string; out AData: RawByteString;
  out AError: string): Boolean;
var
  fs: THandleStream;
  notRegular: Boolean;
begin
  Result := False;
  AData := '';
  AError := '';
  try
    // Fichier ordinaire seulement: un FIFO ou un peripherique bloquerait l'interface avant meme le
    // controle de taille.
    fs := OpenRegularFileRead(APath, notRegular);
    if fs = nil then
    begin
      AError := Format(rsCertFileUnreadable, [APath]);
      Exit;
    end;
    try
      if fs.Size > CERT_MAX_FILE_BYTES then
      begin
        AError := Format(rsCertFileTooLarge, [CERT_MAX_FILE_BYTES]);
        Exit;
      end;
      // Taille lue une fois, lecture bornee: un fichier qui grossit pendant qu'on le lit n'obtient
      // pas la memoire en prime.
      if not ReadWholeStream(fs, CERT_MAX_FILE_BYTES, AData) then
      begin
        AError := Format(rsCertFileUnreadable, [APath]);
        Exit;
      end;
      Result := True;
    finally
      fs.Free;
    end;
  except
    on E: Exception do
      AError := Format(rsCertFileUnreadable, [E.Message]);
  end;
end;

end.
