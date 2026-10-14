// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAdPasswordRules;

{$mode objfpc}{$H+}

// Politique de mot de passe du domaine AD, rejouee avant l'envoi, et mots de passe tires au sort.
// Indicatif: une PSO peut durcir ou assouplir pour certains comptes, le serveur a le dernier mot.
// Mais trois cents refus pour "jdupont!", ca s'evite.

interface

uses
  SysUtils, uLdapEntry;

const
  AD_POLICY_ATTRS: array[0..1] of string = ('minPwdLength', 'pwdProperties');
  RANDOM_PWD_DEFAULT = 16;
  RANDOM_PWD_MIN = 8;
  RANDOM_PWD_MAX = 128;

type
  TAdPwdPolicy = record
    Known: Boolean;
    MinLength: Integer;
    Complex: Boolean;
  end;

function AdPolicyFromDomain(ADomain: TLdapEntry): TAdPwdPolicy;
// Vide: conforme, ou politique inconnue. Compte et nom affiche vides s'ils ne sont pas connus.
function AdPasswordProblem(const APassword: string; const APolicy: TAdPwdPolicy;
  const AAccount, ADisplayName: string): string;
// Majuscule, minuscule, chiffre et signe garantis; ni 0/O ni 1/l/I a recopier depuis un papier.
function RandomPassword(ALength: Integer): string;
// Tire jusqu'a passer les regles contextuelles d'AD: un tirage peut contenir le compte ou un
// morceau du nom affiche, et AD le refuserait quelle que soit sa longueur.
function RandomAdPassword(ALength: Integer; const APolicy: TAdPwdPolicy;
  const AAccount, ADisplayName: string): string;

resourcestring
  rsAdPwdTooShort = 'shorter than the %d characters the domain demands';
  rsAdPwdCategories = 'the domain demands 3 kinds of characters among uppercase, lowercase, digits ' +
    'and symbols (%d here)';
  rsAdPwdHasAccount = 'contains the account name';
  rsAdPwdHasName = 'contains "%s" from the display name';

implementation

uses
  LazUTF8, Character, uPwdCore;

const
  // DOMAIN_PASSWORD_COMPLEX
  PWD_COMPLEX_BIT = 1;
  UPPERS = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  LOWERS = 'abcdefghijkmnopqrstuvwxyz';
  DIGITS = '23456789';
  SYMBOLS = '!@#$%*+-=?_';
  // Les seuls signes que compte la regle Microsoft; l'euro, la livre ou un emoji ne comptent pour rien.
  AD_SPECIALS = '~!@#$%^&*_-+=`|\(){}[]:;"''<>,.?/';

function AdPolicyFromDomain(ADomain: TLdapEntry): TAdPwdPolicy;
var
  v: Int64;
begin
  Result := Default(TAdPwdPolicy);
  if ADomain = nil then Exit;
  if TryStrToInt64(Trim(ADomain.FirstValue('minPwdLength', '')), v) and (v >= 0) and (v <= 1024) then
  begin
    Result.MinLength := v;
    Result.Known := True;
  end;
  if TryStrToInt64(Trim(ADomain.FirstValue('pwdProperties', '')), v) then
  begin
    Result.Complex := v and PWD_COMPLEX_BIT <> 0;
    Result.Known := True;
  end;
end;

function AdPasswordProblem(const APassword: string; const APolicy: TAdPwdPolicy;
  const AAccount, ADisplayName: string): string;
var
  p, pend: PChar;
  len, kinds: Integer;
  ch, lowPwd, token: string;
  w: UnicodeString;
  hasUpper, hasLower, hasDigit, hasSymbol, hasOther: Boolean;
  i: Integer;
begin
  Result := '';
  if not APolicy.Known then Exit;
  if UTF8Length(APassword) < APolicy.MinLength then
    Exit(Format(rsAdPwdTooShort, [APolicy.MinLength]));
  if not APolicy.Complex then Exit;
  lowPwd := UTF8LowerCase(APassword);
  // Regles de Windows: le compte s'il fait 3 caracteres ou plus, chaque morceau de 3 caracteres ou
  // plus du nom affiche, decoupe aux separateurs habituels.
  if (UTF8Length(AAccount) >= 3) and (Pos(UTF8LowerCase(AAccount), lowPwd) > 0) then
    Exit(rsAdPwdHasAccount);
  token := '';
  for i := 1 to Length(ADisplayName) + 1 do
    if (i > Length(ADisplayName)) or (ADisplayName[i] in [',', '.', '-', '_', ' ', '#', #9]) then
    begin
      if (UTF8Length(token) >= 3) and (Pos(UTF8LowerCase(token), lowPwd) > 0) then
        Exit(Format(rsAdPwdHasName, [token]));
      token := '';
    end
    else
      token := token + ADisplayName[i];
  hasUpper := False;
  hasLower := False;
  hasDigit := False;
  hasSymbol := False;
  hasOther := False;
  p := PChar(APassword);
  pend := p + Length(APassword);
  while p < pend do
  begin
    len := UTF8CodepointSize(p);
    if len < 1 then len := 1;
    SetString(ch, p, len);
    Inc(p, len);
    if len = 1 then
    begin
      case ch[1] of
        'A'..'Z': hasUpper := True;
        'a'..'z': hasLower := True;
        '0'..'9': hasDigit := True;
      else
        if Pos(ch[1], AD_SPECIALS) > 0 then hasSymbol := True;
      end;
      Continue;
    end;
    // Hors ASCII: lettre majuscule, minuscule, ou lettre sans casse (cinquieme famille). Un symbole
    // ou un chiffre exotique ne compte nulle part.
    w := UTF8Decode(ch);
    if w = '' then Continue;
    case TCharacter.GetUnicodeCategory(w, 1) of
      TUnicodeCategory.ucUppercaseLetter: hasUpper := True;
      TUnicodeCategory.ucLowercaseLetter: hasLower := True;
      TUnicodeCategory.ucTitlecaseLetter, TUnicodeCategory.ucModifierLetter,
      TUnicodeCategory.ucOtherLetter: hasOther := True;
    end;
  end;
  kinds := Ord(hasUpper) + Ord(hasLower) + Ord(hasDigit) + Ord(hasSymbol) + Ord(hasOther);
  if kinds < 3 then Result := Format(rsAdPwdCategories, [kinds]);
end;

function RandomAdPassword(ALength: Integer; const APolicy: TAdPwdPolicy;
  const AAccount, ADisplayName: string): string;
var
  strict: TAdPwdPolicy;
  i: Integer;
begin
  // Politique inconnue: on juge comme un domaine par defaut, complexite comprise.
  strict := APolicy;
  strict.Known := True;
  strict.Complex := True;
  if ALength < APolicy.MinLength then ALength := APolicy.MinLength;
  for i := 1 to 1000 do
  begin
    Result := RandomPassword(ALength);
    if AdPasswordProblem(Result, strict, AAccount, ADisplayName) = '' then Exit;
  end;
end;

function RandomIndex(AModulo: Integer): Integer;
var
  b: RawByteString;
  v, limit: LongWord;
begin
  // Rejet plutot que modulo nu: pas de caractere favori.
  limit := (High(LongWord) div LongWord(AModulo)) * LongWord(AModulo);
  repeat
    b := RandomSalt(4);
    v := LongWord(Ord(b[1])) or (LongWord(Ord(b[2])) shl 8) or (LongWord(Ord(b[3])) shl 16) or
      (LongWord(Ord(b[4])) shl 24);
  until v < limit;
  Result := v mod LongWord(AModulo);
end;

function RandomPassword(ALength: Integer): string;
var
  all: string;
  i, j: Integer;
  c: Char;
begin
  if ALength < RANDOM_PWD_MIN then ALength := RANDOM_PWD_MIN;
  if ALength > RANDOM_PWD_MAX then ALength := RANDOM_PWD_MAX;
  all := UPPERS + LOWERS + DIGITS + SYMBOLS;
  SetLength(Result, ALength);
  Result[1] := UPPERS[RandomIndex(Length(UPPERS)) + 1];
  Result[2] := LOWERS[RandomIndex(Length(LOWERS)) + 1];
  Result[3] := DIGITS[RandomIndex(Length(DIGITS)) + 1];
  Result[4] := SYMBOLS[RandomIndex(Length(SYMBOLS)) + 1];
  for i := 5 to ALength do
    Result[i] := all[RandomIndex(Length(all)) + 1];
  // Melange, sinon les quatre premiers trahissent leur famille.
  for i := ALength downto 2 do
  begin
    j := RandomIndex(i) + 1;
    c := Result[i];
    Result[i] := Result[j];
    Result[j] := c;
  end;
  // Jamais un signe en tete: "=" ou "+" au debut d'une cellule, un tableur y voit une formule.
  if Pos(Result[1], SYMBOLS) > 0 then
    for i := 2 to ALength do
      if Pos(Result[i], SYMBOLS) = 0 then
      begin
        c := Result[1];
        Result[1] := Result[i];
        Result[i] := c;
        Break;
      end;
end;

end.
