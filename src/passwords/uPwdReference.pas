// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPwdReference;

{$mode objfpc}{$H+}

// Formats reconnus sans verification locale ({SASL}, dialectes 389 DS, prefixes
// inconnus): valeur conservee telle quelle. On ne touche pas a ce qu'on ne comprend
// pas. {SASL} se genere quand meme: ce n'est qu'une identite a prefixer.

interface

uses
  SysUtils, uPwdCore;

type
  TReferenceScheme = class(TPasswordScheme)
  private
    FId, FPrefix, FName, FNote: string;
    FRec: TPwdRecommendation;
  public
    constructor Create(const AId, APrefix, AName, ANote: string; ARec: TPwdRecommendation);
    function Id: string; override;
    function DisplayName: string; override;
    function Recommendation: TPwdRecommendation; override;
    function Matches(const AValue: RawByteString): Boolean; override;
    function Inspect(const AValue: RawByteString): TPwdInfo; override;
    function Verify(const AValue, APassword: RawByteString; out ADetail: string): TPwdStatus; override;
  end;

  TSaslScheme = class(TReferenceScheme)
  public
    constructor Create;
    function CanGenerate: Boolean; override;
    function Generate(const AIdentity: RawByteString; const AParams: TPwdGenParams): RawByteString; override;
    function GenerationNote: string; override;
  end;

implementation

constructor TReferenceScheme.Create(const AId, APrefix, AName, ANote: string;
  ARec: TPwdRecommendation);
begin
  inherited Create;
  FId := AId;
  FPrefix := APrefix;
  FName := AName;
  FNote := ANote;
  FRec := ARec;
end;

function TReferenceScheme.Id: string;
begin
  Result := FId;
end;

function TReferenceScheme.DisplayName: string;
begin
  Result := FName;
end;

function TReferenceScheme.Recommendation: TPwdRecommendation;
begin
  Result := FRec;
end;

function TReferenceScheme.Matches(const AValue: RawByteString): Boolean;
var
  rest: RawByteString;
begin
  if FPrefix = '' then
    Result := LooksLikeSchemePrefix(AValue)
  else
    Result := HasPrefix(AValue, FPrefix, rest);
end;

function TReferenceScheme.Inspect(const AValue: RawByteString): TPwdInfo;
var
  p: Integer;
begin
  Result := BaseInfo(Self, FPrefix);
  if FPrefix = '' then
  begin
    p := Pos('}', AValue);
    Result.Prefix := Copy(AValue, 1, p);
  end;
  Result.CanVerify := False;
  Result.Note := FNote;
end;

function TReferenceScheme.Verify(const AValue, APassword: RawByteString;
  out ADetail: string): TPwdStatus;
begin
  ADetail := FNote;
  Result := psUnverifiable;
end;

constructor TSaslScheme.Create;
begin
  inherited Create('SASL', '{SASL}', '{SASL} pass-through authentication',
    'not a hash: the server delegates authentication to SASL', prReference);
end;

function TSaslScheme.CanGenerate: Boolean;
begin
  Result := True;
end;

function TSaslScheme.GenerationNote: string;
begin
  Result := 'Stores {SASL}identity: the server hands the bind to its SASL stack (saslauthd, ' +
    'Kerberos...). The identity is usually user@REALM; nothing is hashed.';
end;

function TSaslScheme.Generate(const AIdentity: RawByteString;
  const AParams: TPwdGenParams): RawByteString;
var
  i: Integer;
begin
  if AIdentity = '' then
    raise Exception.Create('the SASL identity is empty');
  if Length(AIdentity) > PWD_MAX_VALUE_BYTES then
    raise Exception.Create('the SASL identity is too long');
  if AIdentity[1] = '{' then
    raise Exception.Create('the SASL identity is typed without any {scheme} prefix');
  for i := 1 to Length(AIdentity) do
    if AIdentity[i] in [#0..#31, #127] then
      raise Exception.Create('the SASL identity contains a control character');
  Result := '{SASL}' + AIdentity;
end;

end.
