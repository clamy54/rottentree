// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uBer;

{$mode objfpc}{$H+}

// Encodage BER minimal pour les operations etendues (RFC 3062). Le flux LDAP
// reste l'affaire de libldap: ici on ne decode que du court et du borne.

interface

uses
  SysUtils;

const
  BER_MAX_DECODE_BYTES = 64 * 1024;

type
  TBerItem = record
    Tag: Byte;
    Value: RawByteString;
  end;
  TBerItems = array of TBerItem;

function BerEncodeLength(ALen: Integer): RawByteString;
function BerTlv(ATag: Byte; const AValue: RawByteString): RawByteString;
function BerDecodeSequence(const AData: RawByteString; out ATag: Byte;
  out AItems: TBerItems): Boolean;

function EncodePasswdModifyRequest(const AUser, AOld, ANew: RawByteString;
  AHasUser, AHasOld, AHasNew: Boolean): RawByteString;
function DecodePasswdModifyResponse(const AData: RawByteString; out AGenerated: RawByteString;
  out AHasGenerated: Boolean): Boolean;

implementation

function BerEncodeLength(ALen: Integer): RawByteString;
var
  tmp: RawByteString;
  n: Integer;
begin
  if ALen < $80 then
    Exit(Char(ALen));
  tmp := '';
  n := ALen;
  while n > 0 do
  begin
    tmp := Char(n and $FF) + tmp;
    n := n shr 8;
  end;
  Result := Char($80 or Length(tmp)) + tmp;
end;

function BerTlv(ATag: Byte; const AValue: RawByteString): RawByteString;
begin
  Result := Char(ATag) + BerEncodeLength(Length(AValue)) + AValue;
end;

function ReadTlv(const AData: RawByteString; var APos: Integer; out ATag: Byte;
  out AValue: RawByteString): Boolean;
var
  first, n, i: Integer;
  len: Int64;
begin
  Result := False;
  AValue := '';
  if APos > Length(AData) then Exit;
  ATag := Byte(AData[APos]);
  if (ATag and $1F) = $1F then Exit;
  Inc(APos);
  if APos > Length(AData) then Exit;
  first := Byte(AData[APos]);
  Inc(APos);
  if first < $80 then
    len := first
  else
  begin
    n := first and $7F;
    // Forme indefinie et longueurs sur plus de 4 octets refusees. Un serveur qui
    // annonce 4 Go pour un mot de passe genere n'a pas besoin qu'on le croie.
    if (n = 0) or (n > 4) then Exit;
    len := 0;
    for i := 1 to n do
    begin
      if APos > Length(AData) then Exit;
      len := (len shl 8) or Byte(AData[APos]);
      Inc(APos);
    end;
  end;
  if (len < 0) or (len > BER_MAX_DECODE_BYTES) or (APos + len - 1 > Length(AData)) then Exit;
  AValue := Copy(AData, APos, len);
  Inc(APos, len);
  Result := True;
end;

function BerDecodeSequence(const AData: RawByteString; out ATag: Byte;
  out AItems: TBerItems): Boolean;
var
  p, q: Integer;
  body: RawByteString;
  item: TBerItem;
begin
  Result := False;
  AItems := nil;
  if Length(AData) > BER_MAX_DECODE_BYTES then Exit;
  p := 1;
  if not ReadTlv(AData, p, ATag, body) then Exit;
  if p <> Length(AData) + 1 then Exit;
  q := 1;
  while q <= Length(body) do
  begin
    if not ReadTlv(body, q, item.Tag, item.Value) then Exit;
    SetLength(AItems, Length(AItems) + 1);
    AItems[High(AItems)] := item;
  end;
  Result := True;
end;

function EncodePasswdModifyRequest(const AUser, AOld, ANew: RawByteString;
  AHasUser, AHasOld, AHasNew: Boolean): RawByteString;
var
  buf: RawByteString;
  bodyLen, p: Integer;

  function ItemLen(AHas: Boolean; const AValue: RawByteString): Integer;
  begin
    if AHas then
      Result := 1 + Length(BerEncodeLength(Length(AValue))) + Length(AValue)
    else
      Result := 0;
  end;

  procedure Put(const S: RawByteString);
  begin
    if S <> '' then Move(S[1], buf[p], Length(S));
    Inc(p, Length(S));
  end;

  procedure PutItem(AHas: Boolean; ATag: Byte; const AValue: RawByteString);
  begin
    if not AHas then Exit;
    buf[p] := Char(ATag);
    Inc(p);
    Put(BerEncodeLength(Length(AValue)));
    Put(AValue);
  end;

begin
  // Un seul tampon, pas de concatenation: chaque copie intermediaire serait un
  // secret de plus qui traine dans le tas. L'appelant l'efface apres emission.
  bodyLen := ItemLen(AHasUser, AUser) + ItemLen(AHasOld, AOld) + ItemLen(AHasNew, ANew);
  buf := '';
  SetLength(buf, 1 + Length(BerEncodeLength(bodyLen)) + bodyLen);
  p := 1;
  buf[p] := #$30;
  Inc(p);
  Put(BerEncodeLength(bodyLen));
  PutItem(AHasUser, $80, AUser);
  PutItem(AHasOld, $81, AOld);
  PutItem(AHasNew, $82, ANew);
  Result := buf;
end;

function DecodePasswdModifyResponse(const AData: RawByteString; out AGenerated: RawByteString;
  out AHasGenerated: Boolean): Boolean;
var
  tag: Byte;
  items: TBerItems;
  i: Integer;
begin
  AGenerated := '';
  AHasGenerated := False;
  if AData = '' then Exit(True);
  Result := BerDecodeSequence(AData, tag, items) and (tag = $30);
  if not Result then Exit;
  for i := 0 to High(items) do
  begin
    if items[i].Tag = $80 then
    begin
      AGenerated := items[i].Value;
      UniqueString(AGenerated);
      AHasGenerated := True;
    end;
    // Les copies du mot de passe genere sont effacees: le tas n'est pas un coffre.
    if items[i].Value <> '' then
    begin
      UniqueString(items[i].Value);
      FillChar(items[i].Value[1], Length(items[i].Value), 0);
    end;
  end;
end;

end.
