// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDirectorySession;

{$mode objfpc}{$H+}

// Session d'annuaire vue du fil de travail: un vrai serveur LDAP ou un fichier
// LDIF en memoire, memes operations et memes erreurs. Une instance, un fil.

interface

uses
  SysUtils, uConnectionProfile, uLdapEntry, uSearchModel, uLdapErrors, uChangeSet, uCancel,
  uSensitive, uSessionModel;

type
  TSearchEntryEvent = procedure(AEntry: TLdapEntry; var AStop: Boolean) of object;

  TDirectorySession = class
  protected
    FProfile: TConnectionProfile;
    FSessionId: string;
    FGeneration: Int64;
    FState: TConnState;
    FTransport: TTransportInfo;
    FLastError: TLdapError;
    FOnStep: TConnectStepEvent;
    FSensitive: TSensitivePolicy;
    FConnectSummary: string;
    FConnectWarnings: TStringArray;
    FConnectRewriteNote: string;
  public
    constructor Create(AProfile: TConnectionProfile; const ASessionId: string;
      AGeneration: Int64);
    destructor Destroy; override;
    // L'appelant efface sa copie du secret apres l'appel.
    function Connect(const ASecret: RawByteString; ACancel: TCancelToken): Boolean; virtual; abstract;
    procedure Close; virtual; abstract;
    function Search(const AReq: TSearchRequest; AOnEntry: TSearchEntryEvent;
      ACancel: TCancelToken; out ACompletion: TSearchCompletion;
      AAssembleRanges: Boolean = False): Boolean; virtual; abstract;
    function ReadEntry(const ADn: string; const AAttrs: array of string;
      ACancel: TCancelToken; AAssembleRanges: Boolean = True): TLdapEntry; overload; virtual; abstract;
    function ReadEntry(const ADn: string; const AAttrs: array of string;
      const AControls: TRequestControlArray; ACancel: TCancelToken): TLdapEntry; overload; virtual; abstract;
    function ReadRootDse(ACancel: TCancelToken): TLdapEntry; virtual; abstract;
    function WhoAmI(ACancel: TCancelToken; out AAuthzId: string): Boolean; virtual; abstract;
    function Modify(const ADn: string; const AMods: TLdapModArray;
      const AAssertionFilter: string; ACancel: TCancelToken): TWriteResult; overload; virtual; abstract;
    function Modify(const ADn: string; const AMods: TLdapModArray;
      const AAssertionFilter: string; const AControls: TRequestControlArray;
      ACancel: TCancelToken): TWriteResult; overload; virtual; abstract;
    function Add(AEntry: TLdapEntry; ACancel: TCancelToken): TWriteResult; virtual; abstract;
    function Delete(const ADn: string; const AAssertionFilter: string;
      ACancel: TCancelToken): TWriteResult; virtual; abstract;
    function Rename(const ADn, ANewRdn, ANewSuperior: string; AHasNewSuperior,
      ADeleteOldRdn: Boolean; ACancel: TCancelToken): TWriteResult; virtual; abstract;
    function PasswordModify(const AUserDn: string; const AOld, ANew: RawByteString;
      AHasOld, AHasNew: Boolean; ACancel: TCancelToken): TWriteResult; virtual; abstract;
    function Compare(const ADn, AAttr: string; const AValue: RawByteString;
      ACancel: TCancelToken; out AMatch: Boolean): Boolean; virtual; abstract;
    function IsConnected: Boolean; virtual; abstract;
    property State: TConnState read FState;
    property Transport: TTransportInfo read FTransport;
    property LastError: TLdapError read FLastError;
    property SessionId: string read FSessionId;
    property Generation: Int64 read FGeneration;
    property Profile: TConnectionProfile read FProfile;
    property OnStep: TConnectStepEvent read FOnStep write FOnStep;
    // La garde contre l'ecriture d'un secret en clair s'appuie sur cette politique,
    // pas sur ce que l'ecran a bien voulu masquer.
    property Sensitive: TSensitivePolicy read FSensitive;
    property ConnectSummary: string read FConnectSummary;
    property ConnectWarnings: TStringArray read FConnectWarnings;
    property ConnectRewriteNote: string read FConnectRewriteNote;
  end;

implementation

constructor TDirectorySession.Create(AProfile: TConnectionProfile; const ASessionId: string;
  AGeneration: Int64);
begin
  inherited Create;
  // Copie privee: le profil peut etre edite pendant que le fil travaille sans que
  // la session change de serveur en cours de route.
  FProfile := TConnectionProfile.Create;
  FProfile.Assign(AProfile);
  FSessionId := ASessionId;
  FGeneration := AGeneration;
  FState := csDisconnected;
  FLastError := NoError;
  FSensitive := TSensitivePolicy.Create;
end;

destructor TDirectorySession.Destroy;
begin
  FSensitive.Free;
  FProfile.Free;
  inherited Destroy;
end;

end.
