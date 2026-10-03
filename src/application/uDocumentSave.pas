// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDocumentSave;

{$mode objfpc}{$H+}

// Sauvegarde au verrouillage, hors du fil graphique. Le fil devient seul proprietaire du document
// chiffre: sauvegarde, copie de recuperation si ca rate, issue postee a l'interface. Un disque qui
// rame retarde la sauvegarde, pas l'ecran de verrouillage.

interface

uses
  SysUtils, Classes, uRtDocument, uUiInbox, uOwnedThread;

type
  TDocSaveOutcome = (dsoNotNeeded, dsoSaved, dsoRecovery, dsoLost);

  TDocSaveMsg = class(TUiMessage)
  public
    Outcome: TDocSaveOutcome;
    Path: string;
    ErrorText: string;
    RecoveryError: string;
    OldUuid, NewUuid: string;
    PreviousStale: Boolean;
    DurabilityUnconfirmed: Boolean;
  end;

  // Une sauvegarde n'est jamais annulee par Release: fil fini, il est libere; sinon il est detache
  // et emporte le document avec lui.
  TDocumentSaveThread = class(TOwnedThread)
  private
    FDoc: TRtDocument;
    FOwner: Pointer;
    FTaskId: Int64;
  protected
    procedure Run; override;
  public
    constructor Create(ADoc: TRtDocument; AOwner: Pointer);
    destructor Destroy; override;
    property TaskId: Int64 read FTaskId;
  end;

// Fil termine ne veut pas dire issue presentee: le message terminal peut encore attendre en file.
// Ce qui reste dans la liste en vol apres drainage est un resultat non recu, donc bloquant.
function SaveCloseBusy(ALockSavePresent, ALockExecuteDone: Boolean;
  ASavesInFlight: Integer): Boolean;

implementation

function SaveCloseBusy(ALockSavePresent, ALockExecuteDone: Boolean;
  ASavesInFlight: Integer): Boolean;
begin
  Result := (ALockSavePresent and not ALockExecuteDone) or (ASavesInFlight > 0);
end;

constructor TDocumentSaveThread.Create(ADoc: TRtDocument; AOwner: Pointer);
begin
  FDoc := ADoc;
  FOwner := AOwner;
  FTaskId := NextTaskId;
  inherited Create;
end;

destructor TDocumentSaveThread.Destroy;
begin
  FDoc.Free;
  inherited Destroy;
end;

procedure TDocumentSaveThread.Run;
var
  m: TDocSaveMsg;
  recovery: string;
begin
  m := TDocSaveMsg.Create;
  try
    m.Owner := FOwner;
    m.TaskId := FTaskId;
    m.Path := FDoc.Path;
    m.Outcome := dsoNotNeeded;
    m.OldUuid := FDoc.Uuid;
    if FDoc.Modified and (FDoc.Path <> '') then
    begin
      try
        FDoc.Save;
        m.Outcome := dsoSaved;
      except
        on E: Exception do
        begin
          m.ErrorText := E.Message;
          recovery := ChangeFileExt(FDoc.Path, '') + '.recovery-' +
            FormatDateTime('yyyymmdd-hhnnss', Now) + '.rtt';
          try
            FDoc.SaveAs(recovery);
            m.Outcome := dsoRecovery;
            m.Path := recovery;
          except
            on E2: Exception do
            begin
              m.Outcome := dsoLost;
              m.RecoveryError := E2.Message;
            end;
          end;
        end;
      end;
      if m.Outcome in [dsoSaved, dsoRecovery] then
      begin
        m.PreviousStale := FDoc.PreviousCopyStale;
        m.DurabilityUnconfirmed := FDoc.DurabilityUnconfirmed;
      end;
    end;
    m.NewUuid := FDoc.Uuid;
    // Document et verrou de fichier rendus avant que l'interface apprenne l'issue: un
    // deverrouillage peut rouvrir le fichier. Le message terminal part avant la sortie de Run, le
    // drainage le trouvera.
    FreeAndNil(FDoc);
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
end;

end.
