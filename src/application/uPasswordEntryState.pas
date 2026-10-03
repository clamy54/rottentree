// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uPasswordEntryState;

{$mode objfpc}{$H+}

// Etat de l'entree vue par les outils de mot de passe. Apres une ecriture confirmee ou d'issue
// inconnue, la copie lue devient historique et ne sert plus tant qu'une relecture ne l'a pas
// remplacee. Chaque changement avance la version, et seule la derniere lecture lancee compte.

interface

uses
  SysUtils, uLdapEntry;

type
  TPwdRawValues = array of RawByteString;

  TPwdEntryState = class
  private
    FDn: string;
    FEntry: TLdapEntry;
    FStale: Boolean;
    FVersion: Integer;
    FReadTask: Int64;
    FReadFailed: Boolean;
    procedure Replace(AEntry: TLdapEntry);
  public
    constructor Create(AEntry: TLdapEntry);
    destructor Destroy; override;
    function Usable(AEntry: TLdapEntry): Boolean;
    function WriteSettled(var AReread: TLdapEntry): Boolean;
    procedure ReadStarted(ATaskId: Int64);
    function ReadDelivered(ATaskId: Int64; var AEntry: TLdapEntry): Boolean;
    function CurrentValues(out AValues: TPwdRawValues): Boolean;
    function CurrentUac(out ARaw: string): Boolean;
    function HasTarget: Boolean;
    property Dn: string read FDn;
    property Entry: TLdapEntry read FEntry;
    property Stale: Boolean read FStale;
    property Version: Integer read FVersion;
    property ReadTask: Int64 read FReadTask;
    property ReadFailed: Boolean read FReadFailed;
  end;

implementation

constructor TPwdEntryState.Create(AEntry: TLdapEntry);
begin
  inherited Create;
  if AEntry <> nil then
  begin
    FEntry := AEntry.Clone;
    FDn := AEntry.Dn;
  end;
end;

destructor TPwdEntryState.Destroy;
begin
  FEntry.Free;
  inherited Destroy;
end;

function TPwdEntryState.HasTarget: Boolean;
begin
  Result := FDn <> '';
end;

function TPwdEntryState.Usable(AEntry: TLdapEntry): Boolean;
begin
  Result := (AEntry <> nil) and (AEntry.Dn = FDn) and
    not AEntry.DecodeIncomplete and not AEntry.AnyTruncated;
end;

procedure TPwdEntryState.Replace(AEntry: TLdapEntry);
begin
  FEntry.Free;
  FEntry := AEntry;
  FStale := False;
  FReadFailed := False;
  Inc(FVersion);
end;

function TPwdEntryState.WriteSettled(var AReread: TLdapEntry): Boolean;
begin
  Result := False;
  if not HasTarget then Exit;
  // Toute lecture lancee avant cette issue est abandonnee: elle decrit un monde qui n'existe plus.
  FReadTask := 0;
  if Usable(AReread) then
  begin
    Replace(AReread);
    AReread := nil;
    Exit;
  end;
  FStale := True;
  FReadFailed := False;
  Inc(FVersion);
  Result := True;
end;

procedure TPwdEntryState.ReadStarted(ATaskId: Int64);
begin
  FReadTask := ATaskId;
  if ATaskId = 0 then FReadFailed := True;
end;

function TPwdEntryState.ReadDelivered(ATaskId: Int64; var AEntry: TLdapEntry): Boolean;
begin
  Result := (ATaskId <> 0) and (ATaskId = FReadTask);
  if not Result then Exit;
  FReadTask := 0;
  if Usable(AEntry) then
  begin
    Replace(AEntry);
    AEntry := nil;
  end
  else
    FReadFailed := True;
end;

function TPwdEntryState.CurrentValues(out AValues: TPwdRawValues): Boolean;
var
  a: TLdapAttribute;
  i: Integer;
begin
  AValues := nil;
  Result := (FEntry <> nil) and not FStale;
  if not Result then Exit;
  a := FEntry.Find('userPassword');
  if a = nil then Exit;
  SetLength(AValues, a.ValueCount);
  for i := 0 to a.ValueCount - 1 do
    AValues[i] := a.Values[i];
end;

function TPwdEntryState.CurrentUac(out ARaw: string): Boolean;
var
  a: TLdapAttribute;
begin
  ARaw := '';
  Result := False;
  if (FEntry = nil) or FStale then Exit;
  a := FEntry.Find('userAccountControl');
  if (a = nil) or (a.ValueCount <> 1) then Exit;
  ARaw := a.Values[0];
  Result := True;
end;

end.
