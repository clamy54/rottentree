// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCertDialog;

{$mode objfpc}{$H+}

// Inspecteur de certificats: session TLS de la connexion active, ou fichier PEM/DER.
// Empreintes SHA-256 affichees en entier: une empreinte tronquee, c'est une confiance tronquee.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, ComCtrls, Dialogs, uConnections;

procedure ShowCertificateInspector(AOwner: TComponent; AConn: TDirectoryConnection);

implementation

uses
  uTheme, uUiKit, uCertificateInfo, uTlsPolicy, uSessionModel;

resourcestring
  rsCertTitle = 'Certificate inspector';
  rsCertOpen = 'Open certificate file...';
  rsCertNoSession = 'No TLS session for the active connection. Open a certificate file to inspect it.';

type
  TCertInspector = class(TRtDialog)
  public
    Memo: TMemo;
    procedure OpenClick(Sender: TObject);
    procedure Describe(const ADer: RawByteString; AIndex: Integer);
  end;

procedure TCertInspector.Describe(const ADer: RawByteString; AIndex: Integer);
var
  info: TCertInfo;
  i: Integer;
begin
  try
    info := DescribeCertificate(ADer);
  except
    on E: Exception do
    begin
      Memo.Lines.Add(Format('[%d] unreadable certificate: %s', [AIndex, E.Message]));
      Exit;
    end;
  end;
  Memo.Lines.Add(Format('[%d] Subject: %s', [AIndex, info.Subject]));
  Memo.Lines.Add('    Issuer: ' + info.Issuer);
  Memo.Lines.Add('    Serial: ' + info.SerialHex);
  if info.DatesReadable then
    Memo.Lines.Add(Format('    Valid: %s to %s UTC', [FormatDateTime('yyyy-mm-dd hh:nn', info.NotBefore),
      FormatDateTime('yyyy-mm-dd hh:nn', info.NotAfter)]))
  else
    Memo.Lines.Add('    Valid: dates unreadable');
  for i := 0 to High(info.DnsNames) do
    Memo.Lines.Add('    SAN DNS: ' + info.DnsNames[i]);
  for i := 0 to High(info.IpAddresses) do
    Memo.Lines.Add('    SAN IP: ' + info.IpAddresses[i]);
  Memo.Lines.Add(Format('    Key: %d bits, signature %s, CA=%s, self-issued=%s',
    [info.KeyBits, info.SignatureAlgorithm, BoolToStr(info.IsCa, True), BoolToStr(info.SelfIssued, True)]));
  Memo.Lines.Add('    SHA-256: ' + FormatFingerprint(info.Sha256));
  Memo.Lines.Add('    SHA-1: ' + FormatFingerprint(info.Sha1));
end;

procedure TCertInspector.OpenClick(Sender: TObject);
var
  od: TOpenDialog;
  data: RawByteString;
  ders: TStringArray;
  err: string;
  i: Integer;
begin
  od := TOpenDialog.Create(Self);
  try
    od.Filter := 'Certificates (*.pem;*.crt;*.cer;*.der)|*.pem;*.crt;*.cer;*.der|All files|*.*';
    if not od.Execute then Exit;
    Memo.Clear;
    Memo.Lines.Add('# ' + od.FileName);
    if not ReadCertificateFile(od.FileName, data, err) then
    begin
      Memo.Lines.Add(err);
      Exit;
    end;
    if not ParseCertificates(data, ders, err) then
    begin
      Memo.Lines.Add(err);
      Exit;
    end;
    for i := 0 to High(ders) do
      Describe(ders[i], i);
  finally
    od.Free;
  end;
end;

procedure ShowCertificateInspector(AOwner: TComponent; AConn: TDirectoryConnection);
var
  d: TCertInspector;
  bar: TPanel;
  v: TTlsVerification;
  i: Integer;
  c: TTlsCheck;
  waived: string;
begin
  d := TCertInspector.CreateDialog(AOwner, rsCertTitle, 820, 620);
  d.SetIcon('certificate');
  try
    bar := MakePanel(d.Body, alTop, 36);
    MakeButton(bar, rsCertOpen, @d.OpenClick);
    d.Memo := MakeMemo(d.Body);
    d.Memo.ReadOnly := True;
    if (AConn <> nil) and AConn.Transport.Tls.Session.Established then
    begin
      d.SetTarget(AConn.Profile.DisplayEndpoint, AConn.Profile.EnvironmentBadge);
      v := AConn.Transport.Tls;
      d.Memo.Lines.Add(Format('Protocol: %s  Cipher: %s', [v.Session.ProtocolName, v.Session.Cipher]));
      d.Memo.Lines.Add('Status: ' + v.Decision.StatusLabel);
      d.Memo.Lines.Add('Decision: ' + v.Decision.Summary);
      waived := '';
      for c := Low(c) to High(c) do
        if c in v.Decision.Waived then
          waived := waived + TlsCheckName(c) + '; ';
      if waived <> '' then
        d.Memo.Lines.Add('Checks failed but covered by this profile''s exceptions: ' + waived);
      case v.Decision.Revocation of
        rvsNotChecked: d.Memo.Lines.Add('Revocation: not checked');
        rvsNotEstablished: d.Memo.Lines.Add('Revocation: NOT established (no proof from the backend)');
        rvsVerified: d.Memo.Lines.Add('Revocation: verified');
      end;
      for i := 0 to High(v.Issues) do
        d.Memo.Lines.Add(Format('Verification error at depth %d: %s (%s)', [v.Issues[i].Depth,
          v.Issues[i].Text, TlsCheckName(v.Issues[i].Check)]));
      d.Memo.Lines.Add(Format('Trust anchors loaded: %d', [v.TrustAnchorsLoaded]));
      d.Memo.Lines.Add('');
      for i := 0 to High(v.Session.PeerChainDer) do
        d.Describe(v.Session.PeerChainDer[i], i);
    end
    else
      d.Memo.Lines.Add(rsCertNoSession);
    d.AddButton('Close', mrOk, True, True);
    d.ApplyTheme;
    d.ShowModal;
  finally
    d.Free;
  end;
end;

end.
