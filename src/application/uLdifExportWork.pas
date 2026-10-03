// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdifExportWork;

{$mode objfpc}{$H+}

// Ecriture d'un export LDIF hors du fil graphique, entree par entree dans un fichier temporaire,
// sans copie complete en memoire. Une annulation laisse le fichier precedent intact.

interface

uses
  SysUtils, Classes, uLdifExport, uPasswordWork;

type
  TLdifSaveThread = class(TPwdWorkThread)
  private
    FPath: string;
    FCollector: TLdifExportCollector;
    FHeader: array of string;
    procedure Fill(ADest: TStream);
  protected
    procedure Run; override;
  public
    constructor CreateSave(const APath: string; ACollector: TLdifExportCollector;
      const AHeader: array of string; AOwner: Pointer; ATaskId: Int64);
    destructor Destroy; override;
  end;

// Prend possession de ACollector dans tous les cas, meme quand elle refuse.
function StartLdifSave(const APath: string; ACollector: TLdifExportCollector;
  const AHeader: array of string; AOwner: Pointer): Int64;

implementation

uses
  uSafeSave, uValueFile, uUiInbox;

constructor TLdifSaveThread.CreateSave(const APath: string; ACollector: TLdifExportCollector;
  const AHeader: array of string; AOwner: Pointer; ATaskId: Int64);
var
  i: Integer;
begin
  FPath := APath;
  FCollector := ACollector;
  SetLength(FHeader, Length(AHeader));
  for i := 0 to High(AHeader) do FHeader[i] := AHeader[i];
  inherited Create(AOwner, ATaskId);
end;

destructor TLdifSaveThread.Destroy;
begin
  FCollector.Free;
  inherited Destroy;
end;

procedure TLdifSaveThread.Fill(ADest: TStream);
begin
  FCollector.WriteTo(ADest, FHeader, Cancel);
end;

procedure TLdifSaveThread.Run;
var
  m: TValueFileMsg;
begin
  m := TValueFileMsg.Create;
  try
    m.Owner := Owner;
    m.TaskId := TaskId;
    m.Op := vfoSave;
    m.Path := FPath;
    m.ErrorText := ValueFilePathProblem(FPath);
    if (m.ErrorText = '') and Cancel.IsCancelled then m.ErrorText := rsVfCancelled;
    if m.ErrorText = '' then
      try
        SavePrivateFill(FPath, @Fill);
        m.Ok := True;
      except
        on E: EAbort do m.ErrorText := rsVfCancelled;
        on E: Exception do m.ErrorText := Format(rsVfWriteFailed, [E.Message]);
      end;
    m.Cancelled := (not m.Ok) and Cancel.IsCancelled;
    UiInbox.Post(m);
    m := nil;
  finally
    m.Free;
  end;
end;

function StartLdifSave(const APath: string; ACollector: TLdifExportCollector;
  const AHeader: array of string; AOwner: Pointer): Int64;
begin
  Result := NextTaskId;
  if not PasswordWork.Launch(TLdifSaveThread.CreateSave(APath, ACollector, AHeader, AOwner, Result)) then
    Result := 0;
end;

end.
