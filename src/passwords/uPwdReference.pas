// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPwdReference;

{$mode objfpc}{$H+}

// Formats reconnus sans verification locale ({SASL} et autres delegations, chiffrements
// reversibles, cles TOTP, dialectes 389 DS, prefixes inconnus): valeur conservee telle
// quelle. On ne touche pas a ce qu'on ne comprend pas. Les delegations se generent quand
// meme: rien a calculer, un prefixe a poser.

interface

uses
  SysUtils, uPwdCore;

type
  TReferenceScheme = class(TPasswordScheme)
  private
    FId, FPrefix, FName, FNote: string;
    FRec: TPwdRecommendation;
    FStorage: TPwdStorageLevel;
  public
    constructor Create(const AId, APrefix, AName, ANote: string; ARec: TPwdRecommendation;
      AStorage: TPwdStorageLevel);
    function Id: string; override;
    function DisplayName: string; override;
    function Recommendation: TPwdRecommendation; override;
    function Matches(const AValue: RawByteString): Boolean; override;
    function Inspect(const AValue: RawByteString): TPwdInfo; override;
    function Verify(const AValue, APassword: RawByteString; out ADetail: string): TPwdStatus; override;
  end;

  // ALabel vide: rien a saisir, la valeur est le prefixe seul ({K5KEY}).
  TDelegationScheme = class(TReferenceScheme)
  private
    FLabel, FGenNote: string;
  public
    constructor Create(const AId, APrefix, AName, ANote, ALabel, AGenNote: string);
    function CanGenerate: Boolean; override;
    function Generate(const AIdentity: RawByteString; const AParams: TPwdGenParams): RawByteString; override;
    function GenerationNote: string; override;
    function Servers: TPwdServers; override;
    function Input: TPwdInput; override;
    function InputLabel: string; override;
  end;

implementation

constructor TReferenceScheme.Create(const AId, APrefix, AName, ANote: string;
  ARec: TPwdRecommendation; AStorage: TPwdStorageLevel);
begin
  inherited Create;
  FStorage := AStorage;
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
  Result.Storage := FStorage;
  Result.Note := FNote;
end;

function TReferenceScheme.Verify(const AValue, APassword: RawByteString;
  out ADetail: string): TPwdStatus;
begin
  ADetail := FNote;
  Result := psUnverifiable;
end;

constructor TDelegationScheme.Create(const AId, APrefix, AName, ANote, ALabel, AGenNote: string);
begin
  inherited Create(AId, APrefix, AName, ANote, prReference, pslDelegated);
  FLabel := ALabel;
  FGenNote := AGenNote;
end;

function TDelegationScheme.CanGenerate: Boolean;
begin
  Result := True;
end;

function TDelegationScheme.GenerationNote: string;
begin
  Result := FGenNote;
end;

function TDelegationScheme.Servers: TPwdServers;
begin
  Result := [pwsOpenLdap, pwsOther];
end;

function TDelegationScheme.Input: TPwdInput;
begin
  if FLabel = '' then Result := pinNone else Result := pinIdentity;
end;

function TDelegationScheme.InputLabel: string;
begin
  Result := FLabel;
end;

function TDelegationScheme.Generate(const AIdentity: RawByteString;
  const AParams: TPwdGenParams): RawByteString;
var
  i: Integer;
begin
  if Input = pinNone then Exit(FPrefix);
  if AIdentity = '' then
    raise Exception.Create('the identity is empty');
  if Length(AIdentity) > PWD_MAX_VALUE_BYTES then
    raise Exception.Create('the identity is too long');
  if AIdentity[1] = '{' then
    raise Exception.Create('the identity is typed without any {scheme} prefix');
  for i := 1 to Length(AIdentity) do
    if AIdentity[i] in [#0..#31, #127] then
      raise Exception.Create('the identity contains a control character');
  Result := FPrefix + AIdentity;
end;

end.
