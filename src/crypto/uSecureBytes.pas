// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSecureBytes;

{$mode objfpc}{$H+}

// Tampon pour secrets: alloue par sodium_malloc (pages gardees, effacees a la
// liberation), verrouille par sodium_mlock quand l'OS veut bien. Ne jamais en copier le
// contenu dans une string ordinaire. Le swap, les controles natifs et les vidages
// memoire, eux, n'ont rien promis.

interface

uses
  SysUtils;

type
  TSecureBytes = class
  private
    FData: PByte;
    FLength: NativeUInt;
    FLocked: Boolean;
  public
    constructor Create(ALength: NativeUInt);
    // Copie AData; effacer la source reste le travail de l'appelant.
    constructor CreateFrom(const AData; ALength: NativeUInt);
    destructor Destroy; override;
    procedure Clear;
    function Data: PByte;
    function Len: NativeUInt;
    // Comparaison a temps constant: le chronometre ne doit rien apprendre.
    function Equals(AOther: TSecureBytes): Boolean; reintroduce;
  end;

implementation

uses
  uSodiumApi;

constructor TSecureBytes.Create(ALength: NativeUInt);
begin
  inherited Create;
  SodiumEnsureLoaded;
  FLength := ALength;
  if ALength = 0 then
    ALength := 1;
  FData := sodium_malloc(ALength);
  if FData = nil then
    raise EOutOfMemory.Create('sodium_malloc failed');
  FillChar(FData^, ALength, 0);
  FLocked := sodium_mlock(FData, ALength) = 0;
end;

constructor TSecureBytes.CreateFrom(const AData; ALength: NativeUInt);
begin
  Create(ALength);
  if ALength > 0 then
    Move(AData, FData^, ALength);
end;

destructor TSecureBytes.Destroy;
begin
  if FData <> nil then
  begin
    // sodium_free efface la region, mais il faut d'abord la deverrouiller.
    if FLocked then
      sodium_munlock(FData, FLength);
    sodium_free(FData);
  end;
  inherited Destroy;
end;

procedure TSecureBytes.Clear;
begin
  if (FData <> nil) and (FLength > 0) then
    sodium_memzero(FData, FLength);
end;

function TSecureBytes.Data: PByte;
begin
  Result := FData;
end;

function TSecureBytes.Len: NativeUInt;
begin
  Result := FLength;
end;

function TSecureBytes.Equals(AOther: TSecureBytes): Boolean;
var
  i: NativeUInt;
  diff: Byte;
begin
  Result := False;
  if (AOther = nil) or (FLength <> AOther.FLength) then Exit;
  diff := 0;
  if FLength > 0 then
    for i := 0 to FLength - 1 do
      diff := diff or ((FData + i)^ xor (AOther.FData + i)^);
  Result := diff = 0;
end;

end.
