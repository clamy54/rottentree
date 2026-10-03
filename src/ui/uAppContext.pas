// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAppContext;

{$mode objfpc}{$H+}

// Contexte partage par les onglets: connexions, document, journal visible (expurge), statut.
// Aucun onglet ne parle LDAP en direct: tout passe par le gestionnaire de connexions.

interface

uses
  Classes, SysUtils, uConnections, uRtDocument, uSensitive, uCancel, uUiInbox, uWriteJournal,
  uDirectoryService;

resourcestring
  rsOrphanSource = 'Closed view';
  rsUnclaimedSource = 'Earlier connection';
  rsOrphanUnknownOutcome = 'The write result is unknown. The entry was not re-sent: read it again before any retry.';

type
  TMessageLevel = (mlInfo, mlWarning, mlError);

  TLogEvent = procedure(ALevel: TMessageLevel; const ASource, AText: string) of object;

  TAppContext = class
  private
    procedure SettleAndLog(AMsg: TUiMessage; const ASource: string);
    procedure NoteLdifWrite(AMsg: TUiMessage);
  public
    Connections: TConnectionManager;
    Document: TRtDocument;
    Journal: TWriteJournal;
    Sensitive: TSensitivePolicy;
    OnLog: TLogEvent;
    OnStatusChanged: TNotifyEvent;
    OnLdifModified: TNotifyEvent;
    // Echeance monotone commune a tous les arrets d'un verrouillage ou d'une fermeture: les attentes
    // ne s'additionnent pas, la patience de l'utilisateur non plus.
    ShutdownDeadlineMs: Int64;
    constructor Create;
    destructor Destroy; override;
    procedure Log(ALevel: TMessageLevel; const ASource, AText: string);
    procedure LogWriteOutcome(AKind: TOrphanWriteKind; const ASource, AText: string);
    // L'issue d'une ecriture deja partie survit a la fermeture de la vue qui l'a demandee: journal, et
    // consignation si elle est inconnue. Fil de l'interface seulement. Jamais de renvoi de l'ecriture.
    procedure HandleOrphanMessage(AMsg: TUiMessage);
    // Filet: une issue d'ecriture qu'une vue a ecartee sans la solder (reponse tardive d'une session
    // remplacee, tache oubliee) suit le chemin des orphelins. Personne ne l'attendait, elle compte quand meme.
    procedure HandleDeliveredMessage(AMsg: TUiMessage);
    procedure StatusChanged;
    function ShutdownWaitMs(ADefaultMs: Integer): Integer;
  end;

implementation

constructor TAppContext.Create;
begin
  inherited Create;
  Connections := TConnectionManager.Create;
  Journal := TWriteJournal.Create;
  Connections.Journal := Journal;
  Sensitive := TSensitivePolicy.Create;
end;

destructor TAppContext.Destroy;
begin
  // Les connexions partent en premier: aucun Write ne doit inscrire sa tache dans un journal deja libere.
  Connections.Free;
  Journal.Free;
  Sensitive.Free;
  inherited Destroy;
end;

procedure TAppContext.Log(ALevel: TMessageLevel; const ASource, AText: string);
begin
  if Assigned(OnLog) then
    OnLog(ALevel, ASource, AText);
end;

procedure TAppContext.SettleAndLog(AMsg: TUiMessage; const ASource: string);
var
  text: string;
begin
  // L'issue inconnue est consignee dans le document d'origine de la soumission, pas dans celui
  // qu'on a sous les yeux maintenant.
  LogWriteOutcome(SettleWriteOutcome(AMsg, Connections, Journal, text), ASource, text);
end;

procedure TAppContext.LogWriteOutcome(AKind: TOrphanWriteKind; const ASource, AText: string);
begin
  case AKind of
    owkSuccess: Log(mlInfo, ASource, AText);
    owkUnknownOutcome: Log(mlError, ASource, rsOrphanUnknownOutcome + ' ' + AText);
    owkFailed: Log(mlError, ASource, AText);
  else
    // owkNone: lecture ou lot de recherche, il n'y a rien a solder.
  end;
end;

procedure TAppContext.NoteLdifWrite(AMsg: TUiMessage);
begin
  if Connections.NoteDelivered(AMsg) and Assigned(OnLdifModified) then
    OnLdifModified(Self);
end;

procedure TAppContext.HandleOrphanMessage(AMsg: TUiMessage);
begin
  NoteLdifWrite(AMsg);
  SettleAndLog(AMsg, rsOrphanSource);
end;

procedure TAppContext.HandleDeliveredMessage(AMsg: TUiMessage);
begin
  NoteLdifWrite(AMsg);
  if not IsUnsettledWrite(AMsg, Journal) then Exit;
  SettleAndLog(AMsg, rsUnclaimedSource);
end;

procedure TAppContext.StatusChanged;
begin
  if Assigned(OnStatusChanged) then
    OnStatusChanged(Self);
end;

function TAppContext.ShutdownWaitMs(ADefaultMs: Integer): Integer;
var
  remaining: Int64;
begin
  if ShutdownDeadlineMs = 0 then Exit(ADefaultMs);
  remaining := ShutdownDeadlineMs - MonotonicMs;
  if remaining < 0 then remaining := 0;
  if remaining > ADefaultMs then remaining := ADefaultMs;
  Result := remaining;
end;

end.
