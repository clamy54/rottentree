// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSyntaxInfo;

{$mode objfpc}{$H+}

// Nom et explication des syntaxes LDAP pour l'editeur: RFC 4517, extensions courantes et
// syntaxes AD. Une syntaxe absente de la table garde la description du serveur, quand il
// daigne en publier une.

interface

uses
  SysUtils;

function SyntaxDescription(const AOid: string; out AName, AExplanation: string): Boolean;
function SyntaxExample(const AOid: string): string;
function SplitSyntaxLength(const ASyntax: string; out AMaxLen: Integer): string;

implementation

type
  TSyntaxDoc = record
    Oid: string;
    Name: string;
    Explanation: string;
    Example: string;
  end;

const
  RFC = '1.3.6.1.4.1.1466.115.121.1.';
  AD = '1.2.840.113556.1.4.';

  SYNTAXES: array[0..51] of TSyntaxDoc = (
    (Oid: RFC + '3'; Name: 'Attribute Type Description';
      Explanation: 'schema definition of an attribute type'; Example: '( 2.5.4.3 NAME ''cn'' SUP name )'),
    (Oid: RFC + '5'; Name: 'Binary'; Explanation: 'raw bytes (obsolete syntax)'; Example: '(binary data)'),
    (Oid: RFC + '6'; Name: 'Bit String'; Explanation: 'bits in quotes followed by B, e.g. ''0101''B'; Example: '''0101111101''B'),
    (Oid: RFC + '7'; Name: 'Boolean'; Explanation: 'TRUE or FALSE, in capitals'; Example: 'TRUE'),
    (Oid: RFC + '8'; Name: 'Certificate'; Explanation: 'X.509 certificate, binary (DER)'; Example: '(DER file, loaded from disk)'),
    (Oid: RFC + '9'; Name: 'Certificate List'; Explanation: 'certificate revocation list, binary (DER)'; Example: '(DER file, loaded from disk)'),
    (Oid: RFC + '10'; Name: 'Certificate Pair'; Explanation: 'pair of cross certificates, binary (DER)'; Example: '(DER file, loaded from disk)'),
    (Oid: RFC + '11'; Name: 'Country String'; Explanation: 'two-letter ISO 3166 country code, e.g. FR'; Example: 'FR'),
    (Oid: RFC + '12'; Name: 'DN'; Explanation: 'distinguished name of an entry, e.g. uid=jdoe,ou=people,dc=example,dc=org'; Example: 'uid=jdoe,ou=people,dc=example,dc=org'),
    (Oid: RFC + '14'; Name: 'Delivery Method';
      Explanation: 'delivery methods separated by $, e.g. telephone $ physical'; Example: 'telephone $ physical'),
    (Oid: RFC + '15'; Name: 'Directory String'; Explanation: 'text in UTF-8 (accents allowed), never empty'; Example: 'John Doe'),
    (Oid: RFC + '16'; Name: 'DIT Content Rule Description'; Explanation: 'schema definition of a content rule'; Example: '( 2.5.6.4 DESC ''content rule'' AUX ( pkiUser ) )'),
    (Oid: RFC + '17'; Name: 'DIT Structure Rule Description';
      Explanation: 'schema definition of a structure rule'; Example: '( 2 DESC ''structure rule'' FORM personNameForm )'),
    (Oid: RFC + '21'; Name: 'Enhanced Guide'; Explanation: 'search guide: object class and criteria'; Example: 'person#(sn$EQ)'),
    (Oid: RFC + '22'; Name: 'Facsimile Telephone Number';
      Explanation: 'fax number, optionally followed by $ and fax parameters'; Example: '+33 3 83 00 00 01'),
    (Oid: RFC + '23'; Name: 'Fax'; Explanation: 'G3 fax image, binary'; Example: '(binary data)'),
    (Oid: RFC + '24'; Name: 'Generalized Time';
      Explanation: 'date and time YYYYMMDDHHMMSS with zone, e.g. 20260929143000Z (UTC)'; Example: '20260929143000Z'),
    (Oid: RFC + '25'; Name: 'Guide'; Explanation: 'search guide (obsolete, see Enhanced Guide)'; Example: 'person#sn$EQ'),
    (Oid: RFC + '26'; Name: 'IA5 String';
      Explanation: 'ASCII text: letters, digits and punctuation, no accents (mail, paths, shells)'; Example: 'jdoe@example.org'),
    (Oid: RFC + '27'; Name: 'INTEGER'; Explanation: 'whole number, optionally negative, e.g. 10008'; Example: '10008'),
    (Oid: RFC + '28'; Name: 'JPEG'; Explanation: 'JPEG image, binary'; Example: '(JPEG file, loaded from disk)'),
    (Oid: RFC + '30'; Name: 'Matching Rule Description'; Explanation: 'schema definition of a matching rule'; Example: '( 2.5.13.2 NAME ''caseIgnoreMatch'' SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 )'),
    (Oid: RFC + '31'; Name: 'Matching Rule Use Description';
      Explanation: 'attributes a matching rule applies to'; Example: '( 2.5.13.2 APPLIES ( cn $ sn ) )'),
    (Oid: RFC + '34'; Name: 'Name and Optional UID';
      Explanation: 'DN, optionally followed by #''bits''B, e.g. cn=admins,dc=example,dc=org'; Example: 'uid=jdoe,ou=people,dc=example,dc=org#''0101''B'),
    (Oid: RFC + '35'; Name: 'Name Form Description'; Explanation: 'schema definition of a name form'; Example: '( 2.5.15.3 NAME ''personNameForm'' OC person MUST cn )'),
    (Oid: RFC + '36'; Name: 'Numeric String'; Explanation: 'digits and spaces only'; Example: '15 079 672 281'),
    (Oid: RFC + '37'; Name: 'Object Class Description'; Explanation: 'schema definition of an object class'; Example: '( 2.5.6.6 NAME ''person'' SUP top STRUCTURAL MUST ( sn $ cn ) )'),
    (Oid: RFC + '38'; Name: 'OID';
      Explanation: 'object identifier: a name such as person, or dotted numbers such as 2.5.6.6'; Example: 'inetOrgPerson'),
    (Oid: RFC + '39'; Name: 'Other Mailbox'; Explanation: 'mailbox type, $ and address'; Example: 'internet $ jdoe@example.org'),
    (Oid: RFC + '40'; Name: 'Octet String';
      Explanation: 'arbitrary bytes, compared exactly (hashed passwords, keys)'; Example: '{SSHA}5k2zwVhmbumGkLdvPem3SNHxxTLdeuU1naFvVA=='),
    (Oid: RFC + '41'; Name: 'Postal Address';
      Explanation: 'address lines separated by $, e.g. 1 rue Exemple $ 54000 Nancy'; Example: '1 rue Exemple $ 54000 Nancy $ France'),
    (Oid: RFC + '44'; Name: 'Printable String';
      Explanation: 'letters, digits, space and '' ( ) + , - . / : = ? only, no accents'; Example: 'Example Corp.'),
    (Oid: RFC + '50'; Name: 'Telephone Number'; Explanation: 'telephone number, e.g. +33 3 83 00 00 00'; Example: '+33 3 83 00 00 00'),
    (Oid: RFC + '51'; Name: 'Teletex Terminal Identifier'; Explanation: 'teletex terminal and parameters'; Example: 'teletex $ graphic:1'),
    (Oid: RFC + '52'; Name: 'Telex Number'; Explanation: 'telex number $ country code $ answerback'; Example: '817379 $ ca $ ruwchi'),
    (Oid: RFC + '53'; Name: 'UTC Time';
      Explanation: 'date and time YYMMDDHHMM[SS]Z with a two-digit year (obsolete)'; Example: '2609291430Z'),
    (Oid: RFC + '54'; Name: 'LDAP Syntax Description'; Explanation: 'schema definition of a syntax'; Example: '( 1.3.6.1.4.1.1466.115.121.1.27 DESC ''INTEGER'' )'),
    (Oid: RFC + '58'; Name: 'Substring Assertion'; Explanation: 'substring pattern with * wildcards'; Example: 'jdoe*@example.org'),
    (Oid: '1.3.6.1.1.16.1'; Name: 'UUID';
      Explanation: 'universally unique identifier, e.g. 597ae2f6-16a6-1027-98f4-d28b5365dc14'; Example: '597ae2f6-16a6-1027-98f4-d28b5365dc14'),
    (Oid: '1.3.6.1.1.1.0.0'; Name: 'NIS Netgroup Triple'; Explanation: '(host,user,domain), fields may be empty'; Example: '(host1,jdoe,example.org)'),
    (Oid: '1.3.6.1.1.1.0.1'; Name: 'Boot Parameter'; Explanation: 'key=server:path'; Example: 'root=nfs1:/export/root/host1'),
    (Oid: '1.3.6.1.4.1.4203.666.11.2.1'; Name: 'CSN';
      Explanation: 'change sequence number, set by the server for replication'; Example: '20260929143000.123456Z#000000#001#000000'),
    (Oid: '1.3.6.1.4.1.4203.1.1.1'; Name: 'OpenLDAP ACI'; Explanation: 'OpenLDAP access control item'; Example: '(OpenLDAP access control item)'),
    (Oid: '1.2.36.79672281.1.5.0'; Name: 'RDN'; Explanation: 'relative distinguished name, e.g. uid=jdoe'; Example: 'uid=jdoe'),
    (Oid: '1.3.6.1.4.1.1466.115.121.1.4'; Name: 'Audio'; Explanation: 'audio data, binary'; Example: '(binary data)'),
    (Oid: AD + '903'; Name: 'DN-Binary (Active Directory)';
      Explanation: 'B:<hex length>:<hex bytes>:<DN>'; Example: 'B:8:0102ABCD:CN=John Doe,OU=Users,DC=example,DC=org'),
    (Oid: AD + '904'; Name: 'DN-String (Active Directory)'; Explanation: 'S:<length>:<text>:<DN>'; Example: 'S:5:hello:CN=John Doe,OU=Users,DC=example,DC=org'),
    (Oid: AD + '905'; Name: 'Case-insensitive String (Active Directory)'; Explanation: 'text, case ignored'; Example: 'Example Corp'),
    (Oid: AD + '906'; Name: 'Large Integer (Active Directory)';
      Explanation: '64-bit integer; dates are 100 ns intervals since 1601 (0 or 9223372036854775807: never)'; Example: '133722342000000000'),
    (Oid: AD + '907'; Name: 'Security Descriptor (Active Directory)';
      Explanation: 'Windows security descriptor, binary'; Example: '(binary data)'),
    (Oid: AD + '1221'; Name: 'OR-Name (Active Directory)'; Explanation: 'X.400 address'; Example: 'c=FR;a= ;p=Example;o=Paris;s=Doe;g=John;'),
    (Oid: AD + '1362'; Name: 'Case-sensitive String (Active Directory)'; Explanation: 'text, case significant'; Example: 'CaseSensitiveValue')
  );

function SplitSyntaxLength(const ASyntax: string; out AMaxLen: Integer): string;
var
  p, q: Integer;
begin
  AMaxLen := 0;
  Result := Trim(ASyntax);
  p := Pos('{', Result);
  if p = 0 then Exit;
  q := Pos('}', Result);
  if q > p then AMaxLen := StrToIntDef(Copy(Result, p + 1, q - p - 1), 0);
  Result := Trim(Copy(Result, 1, p - 1));
end;

function SyntaxExample(const AOid: string): string;
var
  i, len: Integer;
  oid: string;
begin
  oid := SplitSyntaxLength(AOid, len);
  for i := Low(SYNTAXES) to High(SYNTAXES) do
    if SYNTAXES[i].Oid = oid then Exit(SYNTAXES[i].Example);
  Result := '';
end;

function SyntaxDescription(const AOid: string; out AName, AExplanation: string): Boolean;
var
  i, len: Integer;
  oid: string;
begin
  AName := '';
  AExplanation := '';
  oid := SplitSyntaxLength(AOid, len);
  for i := Low(SYNTAXES) to High(SYNTAXES) do
    if SYNTAXES[i].Oid = oid then
    begin
      AName := SYNTAXES[i].Name;
      AExplanation := SYNTAXES[i].Explanation;
      Exit(True);
    end;
  Result := False;
end;

end.
