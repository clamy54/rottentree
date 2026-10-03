// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSessionModel;

{$mode objfpc}{$H+}

// Etat d'une session LDAP vu par l'application: connexion, test de connexion, transport
// et TLS. Aucun lien avec libldap ni OpenSSL: la couche ldap remplit ces types, tout le
// reste les lit.

interface

uses
  SysUtils, uConnectionProfile, uTlsPolicy, uLdapErrors;

type
  TConnState = (csDisconnected, csResolving, csConnecting, csSecuring,
    csAuthenticating, csReady, csClosing, csFailed, csCancelled);

  TConnectStep = (stResolve, stTcp, stSecurity, stAuthentication, stRootDse, stBaseAccess);

  TConnectStepResult = record
    Step: TConnectStep;
    Ok: Boolean;
    Skipped: Boolean;
    DurationMs: Int64;
    Detail: string;
  end;

  TConnectStepEvent = procedure(const AResult: TConnectStepResult) of object;

  TTlsSessionInfo = record
    Established: Boolean;
    ProtocolVersion: Integer;
    ProtocolName: string;
    Cipher: string;
    PeerChainDer: array of RawByteString;
    LeafSha256: string;
  end;

  TTlsVerification = record
    Session: TTlsSessionInfo;
    Issues: TTlsIssues;
    Decision: TTlsDecision;
    TrustAnchorsLoaded: Integer;
  end;

  // Le backend dit si c'est chiffre. Le profil, lui, dit seulement ce qu'il esperait.
  TTransportInfo = record
    Mode: TTransportMode;
    Encrypted: Boolean;
    Tls: TTlsVerification;
    StatusLabel: string;
    BoundIdentity: string;
    AuthzId: string;
    Anonymous: Boolean;
  end;

  TWriteResult = record
    Ok: Boolean;
    // True: la requete est partie chez libldap, un echec vient du serveur ou reste
    // d'issue inconnue. False: echec local avant envoi, rien n'a touche l'annuaire.
    Sent: Boolean;
    Error: TLdapError;
    Generated: RawByteString;
  end;

resourcestring
  rsStepResolve = 'name resolution';
  rsStepTcp = 'TCP connection';
  rsStepSecurity = 'security';
  rsStepAuthentication = 'authentication';
  rsStepRootDse = 'root DSE';
  rsStepBaseAccess = 'base access';
  rsStateDisconnected = 'disconnected';
  rsStateResolving = 'resolving';
  rsStateConnecting = 'connecting';
  rsStateSecuring = 'securing';
  rsStateAuthenticating = 'authenticating';
  rsStateReady = 'ready';
  rsStateClosing = 'closing';
  rsStateFailed = 'failed';
  rsStateCancelled = 'cancelled';

function ConnectStepName(AStep: TConnectStep): string;
function ConnStateName(AState: TConnState): string;

implementation

function ConnectStepName(AStep: TConnectStep): string;
begin
  case AStep of
    stResolve: Result := rsStepResolve;
    stTcp: Result := rsStepTcp;
    stSecurity: Result := rsStepSecurity;
    stAuthentication: Result := rsStepAuthentication;
    stRootDse: Result := rsStepRootDse;
  else
    Result := rsStepBaseAccess;
  end;
end;

function ConnStateName(AState: TConnState): string;
begin
  case AState of
    csDisconnected: Result := rsStateDisconnected;
    csResolving: Result := rsStateResolving;
    csConnecting: Result := rsStateConnecting;
    csSecuring: Result := rsStateSecuring;
    csAuthenticating: Result := rsStateAuthenticating;
    csReady: Result := rsStateReady;
    csClosing: Result := rsStateClosing;
    csFailed: Result := rsStateFailed;
  else
    Result := rsStateCancelled;
  end;
end;

end.
