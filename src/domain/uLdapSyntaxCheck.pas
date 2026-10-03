// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdapSyntaxCheck;

{$mode objfpc}{$H+}

// Valeur contre la syntaxe LDAP de son attribut (RFC 4517, RFC 2307, OpenLDAP, AD):
// dire avant l'import ce que le serveur refusera, ligne 48 213 d'un LDIF de 50 000.
// Une syntaxe sans grammaire connue n'est jamais jugee, le serveur tranche.

interface

uses
  SysUtils, uLdapSchema;

function CheckSyntaxValue(const ASyntaxOid: string; AMaxLen: Integer;
  const AValue: RawByteString): string;
function EffectiveSyntaxAndLen(ASchema: TSchemaSnapshot; const AAttr: string;
  out AMaxLen: Integer): string;
function IsSyntaxChecked(const ASyntaxOid: string): Boolean;
function Utf8Length(const S: RawByteString): Integer;

implementation

uses
  uLdapDn, uAttributeCodec;

const
  RFC = '1.3.6.1.4.1.1466.115.121.1.';
  AD = '1.2.840.113556.1.4.';
  PRINTABLE = ['A'..'Z', 'a'..'z', '0'..'9', '''', '(', ')', '+', ',', '-', '.', '/', ':', '?', ' ', '='];

function EffectiveSyntaxAndLen(ASchema: TSchemaSnapshot; const AAttr: string;
  out AMaxLen: Integer): string;
var
  a: TSchemaAttributeType;
  depth: Integer;
begin
  Result := '';
  AMaxLen := 0;
  if ASchema = nil then Exit;
  a := ASchema.AttributeType(AAttr);
  depth := 0;
  while (a <> nil) and (depth < SCHEMA_MAX_SUP_DEPTH) do
  begin
    if a.Syntax <> '' then
    begin
      AMaxLen := a.SyntaxLen;
      Exit(Trim(a.Syntax));
    end;
    if a.Sup = '' then Exit;
    a := ASchema.AttributeType(a.Sup);
    Inc(depth);
  end;
end;

function Utf8Length(const S: RawByteString): Integer;
var
  i, n, k: Integer;
  c: Byte;
begin
  Result := 0;
  i := 1;
  while i <= Length(S) do
  begin
    c := Byte(S[i]);
    if c < $80 then n := 0
    else if (c and $E0) = $C0 then n := 1
    else if (c and $F0) = $E0 then n := 2
    else if (c and $F8) = $F0 then n := 3
    else Exit(-1);
    if (n = 1) and (c < $C2) then Exit(-1);
    if i + n > Length(S) then Exit(-1);
    for k := 1 to n do
      if (Byte(S[i + k]) and $C0) <> $80 then Exit(-1);
    Inc(i, n + 1);
    Inc(Result);
  end;
end;

function AllIn(const S: RawByteString; const ASet: TSysCharSet): Boolean;
var
  i: Integer;
begin
  for i := 1 to Length(S) do
    if not (S[i] in ASet) then Exit(False);
  Result := True;
end;

function FirstNotIn(const S: RawByteString; const ASet: TSysCharSet): string;
var
  i: Integer;
begin
  for i := 1 to Length(S) do
    if not (S[i] in ASet) then
    begin
      if Byte(S[i]) >= $80 then Exit('non-ASCII character (accent or symbol)');
      if Byte(S[i]) < $20 then Exit('control character');
      Exit('character "' + S[i] + '"');
    end;
  Result := '';
end;

function IsInteger(const S: string): Boolean;
var
  i, start: Integer;
begin
  Result := False;
  if S = '' then Exit;
  start := 1;
  if S[1] = '-' then start := 2;
  if start > Length(S) then Exit;
  for i := start to Length(S) do
    if not (S[i] in ['0'..'9']) then Exit;
  if (S[start] = '0') and ((Length(S) > start) or (start = 2)) then Exit;
  Result := True;
end;

function IsNumericOid(const S: string): Boolean;
var
  parts: TStringArray;
  i, j: Integer;
begin
  Result := False;
  parts := S.Split(['.']);
  if Length(parts) < 2 then Exit;
  for i := 0 to High(parts) do
  begin
    if parts[i] = '' then Exit;
    for j := 1 to Length(parts[i]) do
      if not (parts[i][j] in ['0'..'9']) then Exit;
    if (Length(parts[i]) > 1) and (parts[i][1] = '0') then Exit;
  end;
  Result := True;
end;

function IsDescr(const S: string): Boolean;
var
  i: Integer;
begin
  Result := (S <> '') and (S[1] in ['A'..'Z', 'a'..'z']);
  if not Result then Exit;
  for i := 2 to Length(S) do
    if not (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '-']) then Exit(False);
end;

function IsBitString(const S: string): Boolean;
begin
  Result := (Length(S) >= 3) and (S[1] = '''') and (Copy(S, Length(S) - 1, 2) = '''B') and
    AllIn(Copy(S, 2, Length(S) - 3), ['0', '1']);
end;

function IsUtcTime(const S: string): Boolean;
var
  i, n: Integer;
begin
  Result := False;
  n := 0;
  while (n < Length(S)) and (S[n + 1] in ['0'..'9']) do Inc(n);
  if (n <> 10) and (n <> 12) then Exit;
  if (StrToInt(Copy(S, 3, 2)) < 1) or (StrToInt(Copy(S, 3, 2)) > 12) then Exit;
  if (StrToInt(Copy(S, 5, 2)) < 1) or (StrToInt(Copy(S, 5, 2)) > 31) then Exit;
  if StrToInt(Copy(S, 7, 2)) > 23 then Exit;
  if StrToInt(Copy(S, 9, 2)) > 59 then Exit;
  if (n = 12) and (StrToInt(Copy(S, 11, 2)) > 59) then Exit;
  if Copy(S, n + 1, MaxInt) = 'Z' then Exit(True);
  if (Length(S) = n + 5) and (S[n + 1] in ['+', '-']) then
  begin
    for i := n + 2 to n + 5 do
      if not (S[i] in ['0'..'9']) then Exit;
    Result := True;
  end;
end;

function IsUuid(const S: string): Boolean;
var
  i: Integer;
begin
  Result := Length(S) = 36;
  if not Result then Exit;
  for i := 1 to 36 do
    if i in [9, 14, 19, 24] then
    begin
      if S[i] <> '-' then Exit(False);
    end
    else if not (S[i] in ['0'..'9', 'a'..'f', 'A'..'F']) then Exit(False);
end;

function DnDiag(const S: string): string;
var
  dn: TLdapDn;
  err: string;
begin
  Result := '';
  if not DnParse(S, dn, err) then Result := 'not a valid DN: ' + err;
end;

function IsSyntaxChecked(const ASyntaxOid: string): Boolean;
begin
  Result := (ASyntaxOid = RFC + '6') or (ASyntaxOid = RFC + '7') or (ASyntaxOid = RFC + '8') or
    (ASyntaxOid = RFC + '9') or (ASyntaxOid = RFC + '10') or (ASyntaxOid = RFC + '11') or
    (ASyntaxOid = RFC + '12') or (ASyntaxOid = RFC + '14') or (ASyntaxOid = RFC + '15') or
    (ASyntaxOid = RFC + '22') or (ASyntaxOid = RFC + '24') or (ASyntaxOid = RFC + '26') or
    (ASyntaxOid = RFC + '27') or (ASyntaxOid = RFC + '28') or (ASyntaxOid = RFC + '34') or
    (ASyntaxOid = RFC + '36') or (ASyntaxOid = RFC + '38') or (ASyntaxOid = RFC + '39') or
    (ASyntaxOid = RFC + '41') or (ASyntaxOid = RFC + '44') or (ASyntaxOid = RFC + '50') or
    (ASyntaxOid = RFC + '52') or (ASyntaxOid = RFC + '53') or (ASyntaxOid = '1.3.6.1.1.16.1') or
    (ASyntaxOid = '1.3.6.1.1.1.0.0') or (ASyntaxOid = AD + '903') or (ASyntaxOid = AD + '904') or
    (ASyntaxOid = AD + '905') or (ASyntaxOid = AD + '906') or (ASyntaxOid = AD + '1362');
end;

function CheckSyntaxValue(const ASyntaxOid: string; AMaxLen: Integer;
  const AValue: RawByteString): string;
var
  s, oid, rest, part: string;
  len, i, p, q: Integer;
  parts: TStringArray;
  gt: TGeneralizedTime;
  err: string;
begin
  Result := '';
  oid := Trim(ASyntaxOid);
  if (oid <> '') and (oid[1] = '''') then oid := Copy(oid, 2, Length(oid) - 2);
  s := string(AValue);
  // Binaire: seul l'entete trahit le PDF depose dans jpegPhoto par un formulaire RH.
  if oid = RFC + '28' then
  begin
    if (Length(AValue) < 3) or (Byte(AValue[1]) <> $FF) or (Byte(AValue[2]) <> $D8) then
      Result := 'not a JPEG image (a JPEG file starts with the bytes FF D8)';
    Exit;
  end;
  if (oid = RFC + '8') or (oid = RFC + '9') or (oid = RFC + '10') then
  begin
    if (AValue = '') or (Byte(AValue[1]) <> $30) then
      Result := 'not a DER-encoded certificate (load the .cer/.der file, or write the value in base64)';
    Exit;
  end;
  if not IsSyntaxChecked(oid) then Exit;
  len := Utf8Length(AValue);
  if len < 0 then Exit('not valid UTF-8 text');
  if (AMaxLen > 0) and (len > AMaxLen) then
    Exit(Format('%d characters, the maximum is %d', [len, AMaxLen]));
  if oid = RFC + '7' then
  begin
    if (s <> 'TRUE') and (s <> 'FALSE') then Result := 'must be TRUE or FALSE, in capitals';
  end
  else if (oid = RFC + '27') or (oid = AD + '906') then
  begin
    if not IsInteger(s) then Result := 'not a whole number (digits only, optional minus sign, no leading zero)';
  end
  else if oid = RFC + '36' then
  begin
    if (s = '') or not AllIn(AValue, ['0'..'9', ' ']) then Result := 'only digits and spaces are allowed';
  end
  else if oid = RFC + '26' then
  begin
    if not AllIn(AValue, [#0..#127]) then
      Result := FirstNotIn(AValue, [#0..#127]) + ': only ASCII characters are allowed (no accents)';
  end
  else if (oid = RFC + '44') or (oid = RFC + '50') then
  begin
    if s = '' then Result := 'must not be empty'
    else if not AllIn(AValue, PRINTABLE) then
      Result := FirstNotIn(AValue, PRINTABLE) + ' not allowed: only letters, digits, spaces and '' ( ) + , - . / : = ?';
  end
  else if oid = RFC + '11' then
  begin
    if (Length(s) <> 2) or not AllIn(AValue, ['A'..'Z', 'a'..'z']) then
      Result := 'must be a two-letter country code, such as FR or DE';
  end
  else if oid = RFC + '22' then
  begin
    p := Pos('$', s);
    if p > 0 then part := Copy(s, 1, p - 1) else part := s;
    if (Trim(part) = '') or not AllIn(RawByteString(part), PRINTABLE) then
      Result := 'the fax number must use letters, digits, spaces and '' ( ) + , - . / : = ? only';
  end
  else if oid = RFC + '15' then
  begin
    if s = '' then Result := 'must not be empty';
  end
  else if (oid = AD + '905') or (oid = AD + '1362') then
    // rien de plus a verifier: l'UTF-8 l'a ete au-dessus
  else if oid = RFC + '41' then
  begin
    if s = '' then Exit('must not be empty');
    parts := s.Split(['$']);
    for i := 0 to High(parts) do
      if Trim(parts[i]) = '' then Exit('empty line between "$" separators');
  end
  else if oid = RFC + '12' then
    Result := DnDiag(s)
  else if oid = RFC + '34' then
  begin
    p := LastDelimiter('#', s);
    if (p > 0) and IsBitString(Copy(s, p + 1, MaxInt)) then s := Copy(s, 1, p - 1);
    Result := DnDiag(s);
  end
  else if oid = RFC + '6' then
  begin
    if not IsBitString(s) then Result := 'must be bits in quotes followed by B, such as ''0101''B';
  end
  else if oid = RFC + '24' then
  begin
    if not ParseGeneralizedTimeEx(s, gt, err) then
      Result := 'not a date and time YYYYMMDDHHMMSSZ (' + err + ')';
  end
  else if oid = RFC + '53' then
  begin
    if not IsUtcTime(s) then Result := 'not a date and time YYMMDDHHMM[SS]Z';
  end
  else if oid = RFC + '38' then
  begin
    if not (IsDescr(s) or IsNumericOid(s)) then
      Result := 'must be a name (letters, digits, hyphens) or dotted numbers such as 2.5.6.6';
  end
  else if oid = '1.3.6.1.1.16.1' then
  begin
    if not IsUuid(s) then Result := 'must be a UUID such as 597ae2f6-16a6-1027-98f4-d28b5365dc14';
  end
  else if oid = RFC + '39' then
  begin
    if Pos('$', s) < 2 then Result := 'must be "mailbox type $ address"';
  end
  else if oid = RFC + '52' then
  begin
    if Length(s.Split(['$'])) <> 3 then Result := 'must be "number $ country code $ answerback"';
  end
  else if oid = RFC + '14' then
  begin
    parts := s.Split(['$']);
    for i := 0 to High(parts) do
    begin
      part := LowerCase(Trim(parts[i]));
      if (part <> 'any') and (part <> 'mhs') and (part <> 'physical') and (part <> 'telex') and
         (part <> 'teletex') and (part <> 'g3fax') and (part <> 'g4fax') and (part <> 'ia5') and
         (part <> 'videotex') and (part <> 'telephone') then
        Exit('"' + Trim(parts[i]) + '" is not a delivery method');
    end;
  end
  else if oid = '1.3.6.1.1.1.0.0' then
  begin
    if (Length(s) < 4) or (s[1] <> '(') or (s[Length(s)] <> ')') or
       (Length(Copy(s, 2, Length(s) - 2).Split([','])) <> 3) then
      Result := 'must be (host,user,domain)';
  end
  else if (oid = AD + '903') or (oid = AD + '904') then
  begin
    if (Length(s) < 2) or not (s[1] in ['B', 'b', 'S', 's']) or (s[2] <> ':') then
      Exit('must start with B: or S:');
    rest := Copy(s, 3, MaxInt);
    p := Pos(':', rest);
    if p = 0 then Exit('the length is missing');
    q := StrToIntDef(Copy(rest, 1, p - 1), -1);
    rest := Copy(rest, p + 1, MaxInt);
    if (q < 0) or (Length(rest) < q + 1) or (rest[q + 1] <> ':') then
      Exit('the length does not match the data');
    Result := DnDiag(Copy(rest, q + 2, MaxInt));
  end;
end;

end.
