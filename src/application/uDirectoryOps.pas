// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDirectoryOps;

{$mode objfpc}{$H+}

// Acces a un annuaire vu des services: on soumet une recherche, une lecture ou une ecriture, le
// resultat arrive plus tard par la boite de l'interface. Les services ne connaissent que cette
// classe.

interface

uses
  SysUtils, Classes, uSearchModel, uChangeSet, uLdapErrors, uConnections;

type
  // Une ecriture emise ne s'annule jamais et retient la fermeture de la vue.
  TTaskKind = (tkRead, tkSearch, tkWrite);
  TTaskKinds = set of TTaskKind;

  TConnectionOps = class;

  TOpsIssuedEvent = procedure(Sender: TConnectionOps; ATaskId: Int64; AKind: TTaskKind) of object;

  TDirectoryOps = class
  public
    function Search(const AReq: TSearchRequest; out AError: TLdapError): Int64; virtual; abstract;
    function ReadEntry(const ADn: string; const AAttrs: array of string;
      out AError: TLdapError): Int64; virtual; abstract;
    // AChange devient propriete de l'operation, meme en cas de refus.
    function Write(AChange: TLdapChange; const AAssertion: string;
      out AError: TLdapError): Int64; virtual; abstract;
    function ReadOnly: Boolean; virtual; abstract;
    procedure Cancel; virtual;
    function SessionCurrent: Boolean; virtual;
  end;

  // La connexion est retrouvee par profil a chaque appel. Epinglees, les operations ne suivent plus
  // rien: session fermee, remplacee ou schema change, tout envoi est refuse.
  TConnectionOps = class(TDirectoryOps)
  private
    FManager: TConnectionManager;
    FProfileUuid: string;
    FOwner: Pointer;
    FOnIssued: TOpsIssuedEvent;
    FTaskTag: string;
    FPinned: Boolean;
    FStamp: TSessionStamp;
    function Conn(out AError: TLdapError): TDirectoryConnection;
    function Issued(ATaskId: Int64; AKind: TTaskKind): Int64;
  public
    constructor Create(AManager: TConnectionManager; const AProfileUuid: string; AOwner: Pointer);
    function Search(const AReq: TSearchRequest; out AError: TLdapError): Int64; override;
    function ReadEntry(const ADn: string; const AAttrs: array of string;
      out AError: TLdapError): Int64; override;
    function Write(AChange: TLdapChange; const AAssertion: string;
      out AError: TLdapError): Int64; override;
    function ReadOnly: Boolean; override;
    procedure Cancel; override;
    function Pin: Boolean;
    function SessionCurrent: Boolean; override;
    property ProfileUuid: string read FProfileUuid;
    property Manager: TConnectionManager read FManager;
    property OnIssued: TOpsIssuedEvent read FOnIssued write FOnIssued;
    property TaskTag: string read FTaskTag write FTaskTag;
  end;

implementation

resourcestring
  rsOpsNotConnected = 'not connected';
  rsOpsSessionChanged = 'the connection or its schema changed since the preview';

procedure TDirectoryOps.Cancel;
begin
end;

function TDirectoryOps.SessionCurrent: Boolean;
begin
  Result := True;
end;

constructor TConnectionOps.Create(AManager: TConnectionManager; const AProfileUuid: string;
  AOwner: Pointer);
begin
  inherited Create;
  FManager := AManager;
  FProfileUuid := AProfileUuid;
  FOwner := AOwner;
end;

function TConnectionOps.Conn(out AError: TLdapError): TDirectoryConnection;
begin
  AError := NoError;
  if FPinned then
  begin
    Result := FManager.FindSame(FStamp);
    if Result = nil then
      AError := MakeError(lecOther, 0, 'directory', rsOpsSessionChanged);
    Exit;
  end;
  Result := FManager.Find(FProfileUuid);
  if (Result = nil) or not Result.IsReady then
  begin
    Result := nil;
    AError := MakeError(lecNetwork, 0, 'directory', rsOpsNotConnected);
  end;
end;

function TConnectionOps.Issued(ATaskId: Int64; AKind: TTaskKind): Int64;
begin
  Result := ATaskId;
  if (ATaskId <> 0) and Assigned(FOnIssued) then FOnIssued(Self, ATaskId, AKind);
end;

function TConnectionOps.Search(const AReq: TSearchRequest; out AError: TLdapError): Int64;
var
  c: TDirectoryConnection;
begin
  c := Conn(AError);
  if c = nil then Exit(0);
  // Plages AD reassemblees: une copie ne doit pas perdre de valeurs multiples. Une plage incomplete
  // reste marquee tronquee.
  Result := Issued(FManager.Search(c, AReq, FOwner, 0, True), tkSearch);
end;

function TConnectionOps.ReadEntry(const ADn: string; const AAttrs: array of string;
  out AError: TLdapError): Int64;
var
  c: TDirectoryConnection;
begin
  c := Conn(AError);
  if c = nil then Exit(0);
  Result := Issued(FManager.ReadEntry(c, ADn, AAttrs, FOwner, 0), tkRead);
end;

function TConnectionOps.Write(AChange: TLdapChange; const AAssertion: string;
  out AError: TLdapError): Int64;
var
  c: TDirectoryConnection;
begin
  c := Conn(AError);
  if c = nil then
  begin
    AChange.Free;
    Exit(0);
  end;
  Result := Issued(FManager.Write(c, AChange, AAssertion, FOwner, 0, AError), tkWrite);
end;

function TConnectionOps.ReadOnly: Boolean;
var
  c: TDirectoryConnection;
begin
  c := FManager.Find(FProfileUuid);
  Result := (c = nil) or c.Profile.ReadOnly;
end;

function TConnectionOps.Pin: Boolean;
var
  c: TDirectoryConnection;
  err: TLdapError;
begin
  FPinned := False;
  c := Conn(err);
  Result := c <> nil;
  if not Result then Exit;
  FStamp := c.Stamp;
  FPinned := True;
end;

function TConnectionOps.SessionCurrent: Boolean;
var
  err: TLdapError;
begin
  Result := not FPinned or (Conn(err) <> nil);
end;

procedure TConnectionOps.Cancel;
var
  c: TDirectoryConnection;
begin
  c := FManager.Find(FProfileUuid);
  if FPinned and (c <> nil) and
     ((c.SessionId <> FStamp.SessionId) or (c.Generation <> FStamp.Generation)) then
    c := nil;
  FManager.CancelTasks(c, FOwner);
end;

end.
