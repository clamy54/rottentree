// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSafeOutput;

{$mode objfpc}{$H+}

// Encodages de sortie, un par destination: CSV neutralise pour les tableurs, HTML
// inerte, JSON strict. Des guillemets CSV n'ont jamais arrete une formule, et echapper
// du HTML ne protege pas un script.

interface

uses
  SysUtils, Classes;

type
  TCsvOptions = record
    Separator: Char;
    NeutralizeFormulas: Boolean;
    LineBreak: string;
  end;

  TCsvWriter = class
  private
    FOut: TStream;
    FOptions: TCsvOptions;
    FCells: array of string;
  public
    constructor Create(AOut: TStream; const AOptions: TCsvOptions);
    procedure AddCell(const AValue: RawByteString);
    procedure EndRow;
  end;

  TJsonWriter = class
  private
    FOut: TStream;
    FStack: array of Boolean;
    FIndent: Boolean;
    FPendingKey: Boolean;
    procedure Raw(const S: RawByteString);
    procedure BeforeValue;
    procedure NewLine;
  public
    constructor Create(AOut: TStream; AIndent: Boolean = True);
    procedure BeginObject;
    procedure EndObject;
    procedure BeginArray;
    procedure EndArray;
    procedure Key(const AName: string);
    procedure Str(const AValue: RawByteString);
    procedure Bytes(const AValue: RawByteString);
    procedure TextOrBytes(const AValue: RawByteString);
    procedure Int(AValue: Int64);
    procedure Bool(AValue: Boolean);
    procedure Null;
    procedure KeyStr(const AName: string; const AValue: RawByteString);
    procedure KeyInt(const AName: string; AValue: Int64);
    procedure KeyBool(const AName: string; AValue: Boolean);
  end;

function DefaultCsvOptions: TCsvOptions;
function CsvNeutralizeCell(const AValue: RawByteString; out ATransformed: Boolean): string;
function CsvQuote(const AValue: string; ASeparator: Char): string;

function HtmlEscape(const AValue: RawByteString): string;
function HtmlDisplayValue(const AValue: RawByteString; AMaxBytes: Integer = 4096): string;
function JsonEscapeString(const AValue: RawByteString): string;
// Une ligne de journal ne peut pas en forger une autre.
function LogSafeLine(const AValue: RawByteString; AMaxChars: Integer = 8192): string;

implementation

uses
  uRtBytes;

function DefaultCsvOptions: TCsvOptions;
begin
  Result.Separator := ',';
  Result.NeutralizeFormulas := True;
  Result.LineBreak := #13#10;
end;

function CsvNeutralizeCell(const AValue: RawByteString; out ATransformed: Boolean): string;
var
  i: Integer;
  c: Char;
  text: string;
begin
  ATransformed := False;
  if not IsValidUtf8(AValue) then
  begin
    ATransformed := True;
    Exit('{base64}' + Base64EncodeStr(AValue));
  end;
  text := AValue;
  i := 1;
  // Le tableur saute les blancs et controles de tete avant d'evaluer: " =1+1" reste une
  // formule.
  while (i <= Length(text)) and ((text[i] = ' ') or (Byte(text[i]) < 32)) do
  begin
    if text[i] in [#9, #13, #10] then
    begin
      ATransformed := True;
      Break;
    end;
    Inc(i);
  end;
  if (not ATransformed) and (i <= Length(text)) then
  begin
    c := text[i];
    if c in ['=', '+', '-', '@', '|', '%'] then
      ATransformed := True;
    // Formes pleine chasse (U+FF1D =, U+FF0B +, U+FF0D -, U+FF20 @): neutralisees comme
    // leurs equivalents ASCII, par prudence.
    if (not ATransformed) and (i + 2 <= Length(text)) and (text[i] = #$EF) and
       (((text[i + 1] = #$BC) and (text[i + 2] in [#$9D, #$8B, #$8D])) or
        ((text[i + 1] = #$BC) and (text[i + 2] = #$A0))) then
      ATransformed := True;
  end;
  if ATransformed then
    Result := '''' + text
  else
    Result := text;
end;

function CsvQuote(const AValue: string; ASeparator: Char): string;
begin
  Result := '"' + StringReplace(AValue, '"', '""', [rfReplaceAll]) + '"';
end;

constructor TCsvWriter.Create(AOut: TStream; const AOptions: TCsvOptions);
begin
  inherited Create;
  FOut := AOut;
  FOptions := AOptions;
end;

procedure TCsvWriter.AddCell(const AValue: RawByteString);
var
  v: string;
  t: Boolean;
begin
  if FOptions.NeutralizeFormulas then
    v := CsvNeutralizeCell(AValue, t)
  else
    v := AValue;
  SetLength(FCells, Length(FCells) + 1);
  FCells[High(FCells)] := CsvQuote(v, FOptions.Separator);
end;

procedure TCsvWriter.EndRow;
var
  line: string;
  i: Integer;
begin
  line := '';
  for i := 0 to High(FCells) do
  begin
    if i > 0 then line := line + FOptions.Separator;
    line := line + FCells[i];
  end;
  line := line + FOptions.LineBreak;
  FOut.WriteBuffer(line[1], Length(line));
  FCells := nil;
end;

function HtmlEscape(const AValue: RawByteString): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(AValue) do
  begin
    c := AValue[i];
    case c of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&#39;';
      '`': Result := Result + '&#96;';
    else
      if (Byte(c) < 32) and not (c in [#9, #10]) then
        Result := Result + '&#xFFFD;'
      else
        Result := Result + c;
    end;
  end;
end;

function HtmlDisplayValue(const AValue: RawByteString; AMaxBytes: Integer): string;
var
  part: RawByteString;
begin
  if IsValidUtf8(AValue) and (Length(AValue) <= AMaxBytes) then
    Exit(HtmlEscape(AValue));
  part := Copy(AValue, 1, AMaxBytes);
  Result := '<span class="bin">[' + IntToStr(Length(AValue)) + ' bytes] ' +
    HexEncode(part) + '</span>';
  if Length(AValue) > AMaxBytes then
    Result := Result + ' &hellip;';
end;

function JsonEscapeString(const AValue: RawByteString): string;
var
  i: Integer;
  c: Char;
begin
  Result := '"';
  i := 1;
  while i <= Length(AValue) do
  begin
    c := AValue[i];
    case c of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
      // '<' echappe pour qu'un </script> ne ferme rien si le JSON finit embarque dans
      // une page. '\' et 'u' separes a dessein.
      '<': Result := Result + '\' + 'u003c';
      '>': Result := Result + '\' + 'u003e';
    else
      if Byte(c) < 32 then
        Result := Result + '\' + 'u00' + HexEncode(c)
      else if (c = #$E2) and (i + 2 <= Length(AValue)) and (AValue[i + 1] = #$80) and
              (AValue[i + 2] in [#$A8, #$A9]) then
      begin
        // U+2028 et U+2029: valides en JSON, pas dans une chaine JavaScript d'avant
        // ES2019.
        if AValue[i + 2] = #$A8 then
          Result := Result + '\' + 'u2028'
        else
          Result := Result + '\' + 'u2029';
        Inc(i, 2);
      end
      else
        Result := Result + c;
    end;
    Inc(i);
  end;
  Result := Result + '"';
end;

function LogSafeLine(const AValue: RawByteString; AMaxChars: Integer): string;
var
  i: Integer;
begin
  Result := Copy(AValue, 1, AMaxChars);
  for i := 1 to Length(Result) do
    if (Byte(Result[i]) < 32) or (Byte(Result[i]) = 127) then
      Result[i] := ' ';
  if Length(AValue) > AMaxChars then
    Result := Result + ' [truncated]';
end;

constructor TJsonWriter.Create(AOut: TStream; AIndent: Boolean);
begin
  inherited Create;
  FOut := AOut;
  FIndent := AIndent;
end;

procedure TJsonWriter.Raw(const S: RawByteString);
begin
  if S <> '' then
    FOut.WriteBuffer(S[1], Length(S));
end;

procedure TJsonWriter.NewLine;
begin
  if FIndent then
    Raw(#10 + StringOfChar(' ', 2 * Length(FStack)));
end;

procedure TJsonWriter.BeforeValue;
begin
  if FPendingKey then
  begin
    FPendingKey := False;
    Exit;
  end;
  if Length(FStack) = 0 then Exit;
  if not FStack[High(FStack)] then
    Raw(',');
  FStack[High(FStack)] := False;
  NewLine;
end;

procedure TJsonWriter.BeginObject;
begin
  BeforeValue;
  Raw('{');
  SetLength(FStack, Length(FStack) + 1);
  FStack[High(FStack)] := True;
end;

procedure TJsonWriter.EndObject;
var
  empty: Boolean;
begin
  empty := FStack[High(FStack)];
  SetLength(FStack, Length(FStack) - 1);
  if not empty then NewLine;
  Raw('}');
end;

procedure TJsonWriter.BeginArray;
begin
  BeforeValue;
  Raw('[');
  SetLength(FStack, Length(FStack) + 1);
  FStack[High(FStack)] := True;
end;

procedure TJsonWriter.EndArray;
var
  empty: Boolean;
begin
  empty := FStack[High(FStack)];
  SetLength(FStack, Length(FStack) - 1);
  if not empty then NewLine;
  Raw(']');
end;

procedure TJsonWriter.Key(const AName: string);
begin
  BeforeValue;
  Raw(JsonEscapeString(AName));
  if FIndent then Raw(': ') else Raw(':');
  FPendingKey := True;
end;

function HexifyNonAscii(const AValue: RawByteString): RawByteString;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(AValue) do
    if Byte(AValue[i]) >= $80 then
      Result := Result + '\x' + HexEncode(AValue[i])
    else
      Result := Result + AValue[i];
end;

procedure TJsonWriter.Str(const AValue: RawByteString);
begin
  BeforeValue;
  if IsValidUtf8(AValue) then
    Raw(JsonEscapeString(AValue))
  else
    Raw(JsonEscapeString(HexifyNonAscii(AValue)));
end;

procedure TJsonWriter.Bytes(const AValue: RawByteString);
begin
  BeginObject;
  KeyStr('base64', Base64EncodeStr(AValue));
  EndObject;
end;

procedure TJsonWriter.TextOrBytes(const AValue: RawByteString);
begin
  if IsValidUtf8(AValue) then
    Str(AValue)
  else
    Bytes(AValue);
end;

procedure TJsonWriter.Int(AValue: Int64);
begin
  BeforeValue;
  Raw(IntToStr(AValue));
end;

procedure TJsonWriter.Bool(AValue: Boolean);
begin
  BeforeValue;
  if AValue then Raw('true') else Raw('false');
end;

procedure TJsonWriter.Null;
begin
  BeforeValue;
  Raw('null');
end;

procedure TJsonWriter.KeyStr(const AName: string; const AValue: RawByteString);
begin
  Key(AName);
  Str(AValue);
end;

procedure TJsonWriter.KeyInt(const AName: string; AValue: Int64);
begin
  Key(AName);
  Int(AValue);
end;

procedure TJsonWriter.KeyBool(const AName: string; AValue: Boolean);
begin
  Key(AName);
  Bool(AValue);
end;

end.
