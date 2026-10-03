// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdapEntry;

{$mode objfpc}{$H+}

// Entrees et attributs tels que recus: octets et ordre des valeurs conserves,
// options d'attribut comprises. Un attribut absent de la reponse n'est pas un
// attribut vide, et pas forcement un attribut inexistant.

interface

uses
  SysUtils, Classes;

const
  // Bornes contre un serveur trop genereux: une valeur hors borne est omise et
  // l'attribut marque tronque, jamais coupee en silence.
  VALUE_MAX_BYTES = 16 * 1024 * 1024;
  ENTRY_MAX_BYTES = 64 * 1024 * 1024;
  VALUE_OVERHEAD_BYTES = 32;
  // Cout plancher par attribut, meme sans valeur: cent mille attributs vides ne
  // pesent zero octet que sur le papier.
  ATTR_OVERHEAD_BYTES = 64;
  ENTRY_OVERHEAD_BYTES = 256;

type
  TAttrPresence = (
    apPresent,
    apAbsentRequested,
    apNotRequested,
    apTruncated,
    apVisibilityUnknown
  );

  TAttrDescription = record
    Base: string;
    Options: array of string;
  end;

  TLdapAttribute = class
  private
    FDescription: string;
    FValues: array of RawByteString;
    FValueCount: Integer;
    FTruncated: Boolean;
    FSensitive: Boolean;
    function GetValue(AIndex: Integer): RawByteString;
    procedure WipeOwnValues;
  public
    constructor Create(const ADescription: string);
    destructor Destroy; override;
    function Clone: TLdapAttribute;
    procedure AddValue(const AValue: RawByteString);
    procedure SetValues(const AValues: array of RawByteString);
    procedure ClearValues;
    procedure DeleteValue(AIndex: Integer);
    function IndexOfValue(const AValue: RawByteString): Integer;
    function ValueCount: Integer;
    function TotalBytes: Int64;
    function BaseName: string;
    function HasOption(const AOption: string): Boolean;
    property Description: string read FDescription;
    property Values[AIndex: Integer]: RawByteString read GetValue; default;
    property Truncated: Boolean read FTruncated write FTruncated;
    // Valeurs porteuses de secrets: ecrasees avant d'etre remplacees ou liberees, au
    // lieu d'attendre dans le tas que quelqu'un vienne les lire.
    property Sensitive: Boolean read FSensitive write FSensitive;
  end;

  TLdapEntry = class
  private
    FDn: string;
    FAttrs: TList;
    FRequested: TStringList;
    FDecodeIncomplete: Boolean;
    function GetAttr(AIndex: Integer): TLdapAttribute;
  public
    constructor Create(const ADn: string);
    destructor Destroy; override;
    function Clone: TLdapEntry;
    function Find(const ADescription: string): TLdapAttribute;
    function FindAllByBase(const ABase: string): TList;
    function Ensure(const ADescription: string): TLdapAttribute;
    function Add(AAttr: TLdapAttribute): TLdapAttribute;
    procedure Remove(const ADescription: string);
    function AttrCount: Integer;
    function FirstValue(const ADescription: string; const ADefault: RawByteString = ''): RawByteString;
    function TotalBytes: Int64;
    function TotalValueCount: Integer;
    function MemoryCost: Int64;
    procedure SetRequested(const AAttrs: array of string);
    function AnyTruncated: Boolean;
    function Presence(const ADescription: string; AIsOperational: Boolean): TAttrPresence;
    procedure SortForDisplay;
    property Dn: string read FDn write FDn;
    property Attrs[AIndex: Integer]: TLdapAttribute read GetAttr;
    // Decodage interrompu (erreur BER, budget epuise, plage invalide): des attributs
    // manquent peut-etre, et aucune absence n'est observee.
    property DecodeIncomplete: Boolean read FDecodeIncomplete write FDecodeIncomplete;
  end;

function ParseAttrDescription(const S: string): TAttrDescription;
function SameAttrDescription(const A, B: string): Boolean;
function AttrBaseName(const ADescription: string): string;
function AsciiLowerCase(const S: string): string;

implementation

uses
  uRtBytes;

function AsciiLowerCase(const S: string): string;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then
      Result[i] := Chr(Ord(Result[i]) + 32);
end;

function ParseAttrDescription(const S: string): TAttrDescription;
var
  parts: TStringArray;
  i: Integer;
begin
  parts := S.Split([';']);
  Result.Options := nil;
  if Length(parts) = 0 then
  begin
    Result.Base := '';
    Exit;
  end;
  Result.Base := parts[0];
  SetLength(Result.Options, Length(parts) - 1);
  for i := 1 to High(parts) do
    Result.Options[i - 1] := parts[i];
end;

function AttrBaseName(const ADescription: string): string;
var
  p: Integer;
begin
  p := Pos(';', ADescription);
  if p > 0 then
    Result := Copy(ADescription, 1, p - 1)
  else
    Result := ADescription;
end;

// Les options forment un ensemble (RFC 4512 2.5): l'ordre ne compte pas.
function SameAttrDescription(const A, B: string): Boolean;
var
  da, db: TAttrDescription;
  i, j: Integer;
  found: Boolean;
begin
  if AsciiLowerCase(A) = AsciiLowerCase(B) then Exit(True);
  da := ParseAttrDescription(A);
  db := ParseAttrDescription(B);
  if (AsciiLowerCase(da.Base) <> AsciiLowerCase(db.Base)) or
     (Length(da.Options) <> Length(db.Options)) then
    Exit(False);
  for i := 0 to High(da.Options) do
  begin
    found := False;
    for j := 0 to High(db.Options) do
      if AsciiLowerCase(da.Options[i]) = AsciiLowerCase(db.Options[j]) then
      begin
        found := True;
        Break;
      end;
    if not found then Exit(False);
  end;
  Result := True;
end;

constructor TLdapAttribute.Create(const ADescription: string);
begin
  inherited Create;
  FDescription := ADescription;
end;

// WipeString rend chaque chaine unique d'abord: seul un tampon dont l'attribut
// est l'unique proprietaire est mis a zero, pas celui d'un voisin.
procedure TLdapAttribute.WipeOwnValues;
var
  i: Integer;
begin
  if not FSensitive then Exit;
  for i := 0 to High(FValues) do
    WipeString(FValues[i]);
end;

destructor TLdapAttribute.Destroy;
begin
  WipeOwnValues;
  inherited Destroy;
end;

function TLdapAttribute.Clone: TLdapAttribute;
begin
  Result := TLdapAttribute.Create(FDescription);
  Result.FValues := Copy(FValues, 0, FValueCount);
  Result.FValueCount := FValueCount;
  Result.FTruncated := FTruncated;
  Result.FSensitive := FSensitive;
end;

function TLdapAttribute.GetValue(AIndex: Integer): RawByteString;
begin
  Result := FValues[AIndex];
end;

procedure TLdapAttribute.AddValue(const AValue: RawByteString);
begin
  // Capacite doublee: un gros groupe ajoutait ses membres en cout quadratique.
  if FValueCount = Length(FValues) then
  begin
    if FValueCount = 0 then
      SetLength(FValues, 4)
    else
      SetLength(FValues, FValueCount * 2);
  end;
  FValues[FValueCount] := AValue;
  Inc(FValueCount);
end;

procedure TLdapAttribute.SetValues(const AValues: array of RawByteString);
var
  i: Integer;
begin
  WipeOwnValues;
  SetLength(FValues, Length(AValues));
  for i := 0 to High(AValues) do
    FValues[i] := AValues[i];
  FValueCount := Length(AValues);
end;

procedure TLdapAttribute.ClearValues;
begin
  WipeOwnValues;
  FValues := nil;
  FValueCount := 0;
end;

procedure TLdapAttribute.DeleteValue(AIndex: Integer);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex >= FValueCount) then Exit;
  if FSensitive then WipeString(FValues[AIndex]);
  for i := AIndex to FValueCount - 2 do
    FValues[i] := FValues[i + 1];
  Dec(FValueCount);
  FValues[FValueCount] := '';
end;

function TLdapAttribute.IndexOfValue(const AValue: RawByteString): Integer;
var
  i: Integer;
begin
  for i := 0 to FValueCount - 1 do
    if FValues[i] = AValue then Exit(i);
  Result := -1;
end;

function TLdapAttribute.ValueCount: Integer;
begin
  Result := FValueCount;
end;

function TLdapAttribute.TotalBytes: Int64;
var
  i: Integer;
begin
  Result := Length(FDescription);
  for i := 0 to FValueCount - 1 do
    Inc(Result, Length(FValues[i]));
end;

function TLdapAttribute.BaseName: string;
begin
  Result := AttrBaseName(FDescription);
end;

function TLdapAttribute.HasOption(const AOption: string): Boolean;
var
  d: TAttrDescription;
  i: Integer;
begin
  d := ParseAttrDescription(FDescription);
  for i := 0 to High(d.Options) do
    if AsciiLowerCase(d.Options[i]) = AsciiLowerCase(AOption) then Exit(True);
  Result := False;
end;

constructor TLdapEntry.Create(const ADn: string);
begin
  inherited Create;
  FDn := ADn;
  FAttrs := TList.Create;
  FRequested := TStringList.Create;
  FRequested.CaseSensitive := False;
end;

destructor TLdapEntry.Destroy;
var
  i: Integer;
begin
  for i := 0 to FAttrs.Count - 1 do
    TLdapAttribute(FAttrs[i]).Free;
  FAttrs.Free;
  FRequested.Free;
  inherited Destroy;
end;

function TLdapEntry.Clone: TLdapEntry;
var
  i: Integer;
begin
  Result := TLdapEntry.Create(FDn);
  for i := 0 to FAttrs.Count - 1 do
    Result.FAttrs.Add(TLdapAttribute(FAttrs[i]).Clone);
  Result.FRequested.Assign(FRequested);
  Result.FDecodeIncomplete := FDecodeIncomplete;
end;

function TLdapEntry.GetAttr(AIndex: Integer): TLdapAttribute;
begin
  Result := TLdapAttribute(FAttrs[AIndex]);
end;

function IsObjectClassAttr(AAttr: TLdapAttribute): Boolean;
begin
  Result := AsciiLowerCase(AAttr.BaseName) = 'objectclass';
end;

function DisplayBefore(A, B: TLdapAttribute): Boolean;
var
  oa, ob: Boolean;
begin
  oa := IsObjectClassAttr(A);
  ob := IsObjectClassAttr(B);
  if oa <> ob then Exit(oa);
  Result := CompareText(A.Description, B.Description) < 0;
end;

function ObjectClassValueBefore(const A, B: RawByteString): Boolean;
var
  ta, tb: Boolean;
begin
  ta := SameText(Trim(A), 'top');
  tb := SameText(Trim(B), 'top');
  if ta <> tb then Exit(ta);
  Result := CompareText(A, B) < 0;
end;

procedure TLdapEntry.SortForDisplay;
var
  i, j, k: Integer;
  a: TLdapAttribute;
  vals: array of RawByteString;
  v: RawByteString;
begin
  for i := 1 to FAttrs.Count - 1 do
  begin
    a := TLdapAttribute(FAttrs[i]);
    j := i - 1;
    while (j >= 0) and DisplayBefore(a, TLdapAttribute(FAttrs[j])) do
    begin
      FAttrs[j + 1] := FAttrs[j];
      Dec(j);
    end;
    FAttrs[j + 1] := a;
  end;
  for i := 0 to FAttrs.Count - 1 do
  begin
    a := TLdapAttribute(FAttrs[i]);
    if not IsObjectClassAttr(a) then Continue;
    SetLength(vals, a.ValueCount);
    for j := 0 to a.ValueCount - 1 do
      vals[j] := a.Values[j];
    for j := 1 to High(vals) do
    begin
      v := vals[j];
      k := j - 1;
      while (k >= 0) and ObjectClassValueBefore(v, vals[k]) do
      begin
        vals[k + 1] := vals[k];
        Dec(k);
      end;
      vals[k + 1] := v;
    end;
    a.SetValues(vals);
  end;
end;

function TLdapEntry.Find(const ADescription: string): TLdapAttribute;
var
  i: Integer;
begin
  for i := 0 to FAttrs.Count - 1 do
    if SameAttrDescription(TLdapAttribute(FAttrs[i]).Description, ADescription) then
      Exit(TLdapAttribute(FAttrs[i]));
  Result := nil;
end;

function TLdapEntry.FindAllByBase(const ABase: string): TList;
var
  i: Integer;
  lb: string;
begin
  Result := TList.Create;
  lb := AsciiLowerCase(ABase);
  for i := 0 to FAttrs.Count - 1 do
    if AsciiLowerCase(TLdapAttribute(FAttrs[i]).BaseName) = lb then
      Result.Add(FAttrs[i]);
end;

function TLdapEntry.Ensure(const ADescription: string): TLdapAttribute;
begin
  Result := Find(ADescription);
  if Result = nil then
  begin
    Result := TLdapAttribute.Create(ADescription);
    FAttrs.Add(Result);
  end;
end;

function TLdapEntry.Add(AAttr: TLdapAttribute): TLdapAttribute;
begin
  FAttrs.Add(AAttr);
  Result := AAttr;
end;

procedure TLdapEntry.Remove(const ADescription: string);
var
  i: Integer;
  desc: string;
begin
  // Copie propre: l'appelant passe souvent a.Description, que cette boucle libere.
  // Comparer ensuite avec une chaine morte supprimait d'autres attributs.
  desc := ADescription;
  UniqueString(desc);
  for i := FAttrs.Count - 1 downto 0 do
    if SameAttrDescription(TLdapAttribute(FAttrs[i]).Description, desc) then
    begin
      TLdapAttribute(FAttrs[i]).Free;
      FAttrs.Delete(i);
    end;
end;

function TLdapEntry.AttrCount: Integer;
begin
  Result := FAttrs.Count;
end;

function TLdapEntry.FirstValue(const ADescription: string;
  const ADefault: RawByteString): RawByteString;
var
  a: TLdapAttribute;
begin
  a := Find(ADescription);
  if (a <> nil) and (a.ValueCount > 0) then
    Result := a.Values[0]
  else
    Result := ADefault;
end;

function TLdapEntry.TotalBytes: Int64;
var
  i: Integer;
begin
  Result := Length(FDn);
  for i := 0 to FAttrs.Count - 1 do
    Inc(Result, TLdapAttribute(FAttrs[i]).TotalBytes);
end;

function TLdapEntry.TotalValueCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FAttrs.Count - 1 do
    Inc(Result, TLdapAttribute(FAttrs[i]).ValueCount);
end;

function TLdapEntry.MemoryCost: Int64;
var
  i: Integer;
begin
  Result := Length(FDn) + ENTRY_OVERHEAD_BYTES;
  for i := 0 to FAttrs.Count - 1 do
    Inc(Result, TLdapAttribute(FAttrs[i]).TotalBytes + ATTR_OVERHEAD_BYTES +
      VALUE_OVERHEAD_BYTES * Int64(TLdapAttribute(FAttrs[i]).ValueCount));
end;

function TLdapEntry.AnyTruncated: Boolean;
var
  i: Integer;
begin
  for i := 0 to AttrCount - 1 do
    if Attrs[i].Truncated then Exit(True);
  Result := False;
end;

procedure TLdapEntry.SetRequested(const AAttrs: array of string);
var
  i: Integer;
begin
  FRequested.Clear;
  for i := 0 to High(AAttrs) do
    FRequested.Add(AAttrs[i]);
end;

function TLdapEntry.Presence(const ADescription: string;
  AIsOperational: Boolean): TAttrPresence;
var
  a: TLdapAttribute;
  i: Integer;
  explicit: Boolean;
begin
  a := Find(ADescription);
  if a <> nil then
  begin
    if a.Truncated then Exit(apTruncated);
    Exit(apPresent);
  end;
  explicit := False;
  for i := 0 to FRequested.Count - 1 do
    if SameAttrDescription(FRequested[i], ADescription) or
       SameAttrDescription(FRequested[i], AttrBaseName(ADescription)) then
      explicit := True;
  // Un refus d'ACL ressemble trait pour trait a une absence: on n'affirme jamais
  // qu'un attribut n'existe pas.
  if explicit then Exit(apAbsentRequested);
  if FRequested.Count = 0 then
    // liste vide = tous les attributs utilisateur (RFC 4511 4.5.1.8)
    if AIsOperational then Exit(apNotRequested) else Exit(apVisibilityUnknown);
  if AIsOperational then
  begin
    if FRequested.IndexOf('+') >= 0 then Exit(apVisibilityUnknown);
    Exit(apNotRequested);
  end;
  if FRequested.IndexOf('*') >= 0 then Exit(apVisibilityUnknown);
  Result := apNotRequested;
end;

end.
