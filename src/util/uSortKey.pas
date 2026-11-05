// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSortKey;

{$mode objfpc}{$H+}

// Tri d'affichage. Une cle par element, calculee une fois, puis un tri fusion sur des indices:
// n log n garanti, quel que soit l'ordre dans lequel le serveur a eu l'idee de repondre. Un
// quicksort naif sur une branche deja triee, c'est cinquante mille entrees et un ecran fige.
// Les minuscules sont faites ici, decodeur borne compris: celles de LazUTF8 lisent au-dela
// d'une sequence tronquee et ratent la pleine chasse.

interface

uses
  SysUtils;

type
  TIndexArray = array of Integer;

// Lettre latine accentuee (U+00C0 a U+017F) ramenee a sa base en minuscules; vide si ce
// n'en est pas une.
function LatinBase(ACode: Cardinal): string;
// Minuscules latines, grecques, cyrilliques et pleine chasse, accents conserves. Un octet
// UTF-8 invalide reste tel quel et seul: il n'avale jamais son voisin.
function FoldCase(const S: string): string;
// Minuscules, accents latins replies, diacritiques combinants retires, tout le reste intact:
// "Elodie", "élodie" et "ELODIE" se suivent. Les nombres se comparent comme des nombres:
// bulk2 avant bulk10, {2}cosine avant {10}misc. Le texte d'origine departage les ex aequo,
// pour que l'ordre ne depende jamais du serveur.
function SortKey(const S: string): string;
// Ordre croissant et stable des indices de AKeys, comparaison octet par octet.
function KeyOrder(const AKeys: TStringArray): TIndexArray;

implementation

function LatinBase(ACode: Cardinal): string;
begin
  case ACode of
    $C0..$C5, $E0..$E5, $100..$105: Result := 'a';
    $C6, $E6: Result := 'ae';
    $C7, $E7, $106..$10D: Result := 'c';
    $D0, $F0, $10E..$111: Result := 'd';
    $C8..$CB, $E8..$EB, $112..$11B: Result := 'e';
    $11C..$123: Result := 'g';
    $124..$127: Result := 'h';
    $CC..$CF, $EC..$EF, $128..$131: Result := 'i';
    $132, $133: Result := 'ij';
    $134, $135: Result := 'j';
    $136..$138: Result := 'k';
    $139..$142: Result := 'l';
    $D1, $F1, $143..$14B: Result := 'n';
    $D2..$D6, $D8, $F2..$F6, $F8, $14C..$151: Result := 'o';
    $152, $153: Result := 'oe';
    $154..$159: Result := 'r';
    $DF: Result := 'ss';
    $15A..$161, $17F: Result := 's';
    $DE, $FE: Result := 'th';
    $162..$167: Result := 't';
    $D9..$DC, $F9..$FC, $168..$173: Result := 'u';
    $174, $175: Result := 'w';
    $DD, $FD, $FF, $176..$178: Result := 'y';
    $179..$17E: Result := 'z';
  else
    Result := '';
  end;
end;

// Toutes ces correspondances gardent la longueur UTF-8: le tampon de l'appelant suffit.
function LowerCode(ACode: Cardinal): Cardinal;
begin
  Result := ACode;
  case ACode of
    Ord('A')..Ord('Z'), $C0..$D6, $D8..$DE: Result := ACode + 32;
    $100..$137, $14A..$177: if not Odd(ACode) then Result := ACode + 1;
    $139..$148, $179..$17E: if Odd(ACode) then Result := ACode + 1;
    $178: Result := $FF;
    $386: Result := $3AC;
    $388..$38A: Result := ACode + 37;
    $38C: Result := $3CC;
    $38E, $38F: Result := ACode + 63;
    $391..$3A1, $3A3..$3AB: Result := ACode + 32;
    $400..$40F: Result := ACode + 80;
    $410..$42F: Result := ACode + 32;
    $FF21..$FF3A: Result := ACode + 32;
  end;
end;

// Faux si la sequence en AIndex n'est pas de l'UTF-8 valide; ASize vaut alors 1.
function DecodeAt(const S: string; AIndex, ALen: Integer; out ACode: Cardinal;
  out ASize: Integer): Boolean;
var
  b, c: Byte;
  k: Integer;
begin
  Result := False;
  ACode := 0;
  ASize := 1;
  b := Ord(S[AIndex]);
  if b < $80 then
  begin
    ACode := b;
    Exit(True);
  end;
  if (b and $E0) = $C0 then
  begin
    ASize := 2;
    ACode := b and $1F;
  end
  else if (b and $F0) = $E0 then
  begin
    ASize := 3;
    ACode := b and $0F;
  end
  else if (b and $F8) = $F0 then
  begin
    ASize := 4;
    ACode := b and $07;
  end
  else
    Exit;
  if AIndex + ASize - 1 > ALen then
  begin
    ASize := 1;
    Exit;
  end;
  for k := 1 to ASize - 1 do
  begin
    c := Ord(S[AIndex + k]);
    if (c and $C0) <> $80 then
    begin
      ASize := 1;
      Exit;
    end;
    ACode := (ACode shl 6) or (c and $3F);
  end;
  // Formes trop longues et demi-codets: pas de l'UTF-8, et pas de deuxieme chance.
  if ((ASize = 2) and (ACode < $80)) or ((ASize = 3) and (ACode < $800)) or
    ((ASize = 4) and ((ACode < $10000) or (ACode > $10FFFF))) or
    ((ACode >= $D800) and (ACode <= $DFFF)) then
  begin
    ASize := 1;
    Exit;
  end;
  Result := True;
end;

procedure PutChar(var ABuf: string; var P: Integer; C: Char); inline;
begin
  Inc(P);
  ABuf[P] := C;
end;

procedure PutCode(var ABuf: string; var P: Integer; ACode: Cardinal);
begin
  if ACode < $80 then
    PutChar(ABuf, P, Chr(ACode))
  else if ACode < $800 then
  begin
    PutChar(ABuf, P, Chr($C0 or (ACode shr 6)));
    PutChar(ABuf, P, Chr($80 or (ACode and $3F)));
  end
  else if ACode < $10000 then
  begin
    PutChar(ABuf, P, Chr($E0 or (ACode shr 12)));
    PutChar(ABuf, P, Chr($80 or ((ACode shr 6) and $3F)));
    PutChar(ABuf, P, Chr($80 or (ACode and $3F)));
  end
  else
  begin
    PutChar(ABuf, P, Chr($F0 or (ACode shr 18)));
    PutChar(ABuf, P, Chr($80 or ((ACode shr 12) and $3F)));
    PutChar(ABuf, P, Chr($80 or ((ACode shr 6) and $3F)));
    PutChar(ABuf, P, Chr($80 or (ACode and $3F)));
  end;
end;

function FoldCase(const S: string): string;
var
  i, len, n, p: Integer;
  code: Cardinal;
begin
  len := Length(S);
  Result := '';
  SetLength(Result, len);
  p := 0;
  i := 1;
  while i <= len do
  begin
    if DecodeAt(S, i, len, code, n) then
      PutCode(Result, p, LowerCode(code))
    else
      PutChar(Result, p, S[i]);
    Inc(i, n);
  end;
  SetLength(Result, p);
end;

function SortKey(const S: string): string;
var
  key, base: string;
  i, j, k, len, n, p, m, q: Integer;
  code: Cardinal;
begin
  len := Length(S);
  // Jamais plus de deux octets produits par octet lu. Cinquante mille concatenations par
  // noeud, c'est le tri qui attendrait les cles.
  key := '';
  SetLength(key, 2 * len + 1 + len);
  p := 0;
  i := 1;
  while i <= len do
  begin
    if S[i] in ['0'..'9'] then
    begin
      // Zeros de tete retires, longueur en prefixe: a longueur egale l'ordre des octets est
      // celui des nombres. Les zeros enleves, le texte d'origine en fin de cle les rattrape.
      while (i <= len) and (S[i] = '0') do Inc(i);
      j := i;
      while (j <= len) and (S[j] in ['0'..'9']) do Inc(j);
      n := j - i;
      if n < 30 then
        PutChar(key, p, Chr(1 + n))
      else
      begin
        // Au-dela de 29 chiffres: #31, le nombre d'octets de la longueur, puis la longueur
        // en base 250 decalee de 1. Plus d'octets, plus long; a egalite, poids forts d'abord.
        k := 0;
        m := n;
        while m > 0 do
        begin
          Inc(k);
          m := m div 250;
        end;
        PutChar(key, p, #31);
        PutChar(key, p, Chr(1 + k));
        m := n;
        for q := k downto 1 do
        begin
          key[p + q] := Chr(1 + m mod 250);
          m := m div 250;
        end;
        Inc(p, k);
      end;
      for k := i to j - 1 do
        PutChar(key, p, S[k]);
      i := j;
      Continue;
    end;
    if not DecodeAt(S, i, len, code, n) then
    begin
      PutChar(key, p, S[i]);
      Inc(i);
      Continue;
    end;
    Inc(i, n);
    if (code >= $300) and (code <= $36F) then Continue;
    code := LowerCode(code);
    base := '';
    if (code >= $C0) and (code <= $17F) then base := LatinBase(code);
    if base <> '' then
      for k := 1 to Length(base) do
        PutChar(key, p, base[k])
    else
      PutCode(key, p, code);
  end;
  PutChar(key, p, #0);
  for k := 1 to len do
    PutChar(key, p, S[k]);
  SetLength(key, p);
  Result := key;
end;

function KeyOrder(const AKeys: TStringArray): TIndexArray;
var
  n, width, lo, mid, hi, i, j, k: Integer;
  src, dst, t: TIndexArray;
begin
  n := Length(AKeys);
  src := nil;
  SetLength(src, n);
  for i := 0 to n - 1 do
    src[i] := i;
  dst := nil;
  SetLength(dst, n);
  width := 1;
  while width < n do
  begin
    lo := 0;
    while lo < n do
    begin
      mid := lo + width;
      if mid > n then mid := n;
      hi := mid + width;
      if hi > n then hi := n;
      i := lo;
      j := mid;
      k := lo;
      while (i < mid) and (j < hi) do
      begin
        // Strictement inferieur: a egalite le premier arrive reste devant.
        if CompareStr(AKeys[src[j]], AKeys[src[i]]) < 0 then
        begin
          dst[k] := src[j];
          Inc(j);
        end
        else
        begin
          dst[k] := src[i];
          Inc(i);
        end;
        Inc(k);
      end;
      while i < mid do
      begin
        dst[k] := src[i];
        Inc(i);
        Inc(k);
      end;
      while j < hi do
      begin
        dst[k] := src[j];
        Inc(j);
        Inc(k);
      end;
      lo := hi;
    end;
    t := src;
    src := dst;
    dst := t;
    width := width * 2;
  end;
  Result := src;
end;

end.
