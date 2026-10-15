// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uFilePublish;

{$mode objfpc}{$H+}

// Plusieurs fichiers qui vont ensemble publies ensemble: tous prepares a cote, les anciens mis de
// cote, puis mis en place. Au moindre accroc les anciens reviennent. Une sauvegarde faite de deux
// generations, c'est deux sauvegardes fausses.

interface

uses
  SysUtils, Classes, uSafeSave;

type
  TPublishPart = record
    Target: string;
    // contenu tout fait, ou rempli au fil de l'eau (un LDIF d'un giga ne passe pas par une chaine)
    Text: RawByteString;
    Fill: TStreamFill;
  end;
  TPublishParts = array of TPublishPart;

function PublishText(const ATarget: string; const AText: RawByteString): TPublishPart;
function PublishFill(const ATarget: string; AFill: TStreamFill): TPublishPart;
// AStale: fichiers qui ne doivent plus exister une fois les autres publies.
function PublishFiles(const AParts: array of TPublishPart; const AStale: array of string;
  out AError: string): Boolean;

resourcestring
  rsFpRenameFailed = '%s could not be put in place.';
  rsFpRestoreFailed = 'The previous %s could not be put back: it is kept as %s.';

implementation

function PublishText(const ATarget: string; const AText: RawByteString): TPublishPart;
begin
  Result := Default(TPublishPart);
  Result.Target := ATarget;
  Result.Text := AText;
end;

function PublishFill(const ATarget: string; AFill: TStreamFill): TPublishPart;
begin
  Result := Default(TPublishPart);
  Result.Target := ATarget;
  Result.Fill := AFill;
end;

function PublishFiles(const AParts: array of TPublishPart; const AStale: array of string;
  out AError: string): Boolean;
var
  tag, fail: string;
  staged, saved, moved: TStringArray;
  placed, i, n: Integer;
  ms: TStringStream;
  g: TGUID;
begin
  Result := False;
  AError := '';
  staged := nil;
  saved := nil;
  moved := nil;
  placed := 0;
  CreateGUID(g);
  tag := '.' + LowerCase(Copy(GUIDToString(g), 2, 8));
  SetLength(staged, Length(AParts));
  try
    for i := 0 to High(AParts) do
    begin
      // Nom deja pris: pas le notre, on n'y touche pas, ni maintenant ni au menage.
      if FileExists(AParts[i].Target + tag + '.part') then
        raise EStreamError.CreateFmt(rsFpRenameFailed, [AParts[i].Target + tag + '.part']);
      staged[i] := AParts[i].Target + tag + '.part';
      if Assigned(AParts[i].Fill) then
        SavePrivateFill(staged[i], AParts[i].Fill)
      else
      begin
        ms := TStringStream.Create(AParts[i].Text);
        try
          SavePrivateStream(staged[i], ms);
        finally
          ms.Free;
        end;
      end;
    end;
    for i := 0 to High(AParts) + Length(AStale) do
    begin
      n := Length(saved);
      if i <= High(AParts) then
      begin
        if not FileExists(AParts[i].Target) then Continue;
        SetLength(saved, n + 1);
        SetLength(moved, n + 1);
        saved[n] := AParts[i].Target;
      end
      else
      begin
        if not FileExists(AStale[i - Length(AParts)]) then Continue;
        SetLength(saved, n + 1);
        SetLength(moved, n + 1);
        saved[n] := AStale[i - Length(AParts)];
      end;
      moved[n] := saved[n] + tag + '.old';
      if FileExists(moved[n]) or not RenameFile(saved[n], moved[n]) then
      begin
        fail := saved[n];
        SetLength(saved, n);
        SetLength(moved, n);
        raise EStreamError.CreateFmt(rsFpRenameFailed, [fail]);
      end;
    end;
    for i := 0 to High(AParts) do
    begin
      if not ReplaceByRenamePrivate(staged[i], AParts[i].Target) then
        raise EStreamError.CreateFmt(rsFpRenameFailed, [AParts[i].Target]);
      staged[i] := '';
      placed := i + 1;
    end;
    for i := 0 to High(moved) do
      DeleteFile(moved[i]);
    Result := True;
  except
    on E: Exception do
    begin
      AError := E.Message;
      for i := 0 to placed - 1 do
        DeleteFile(AParts[i].Target);
      for i := 0 to High(moved) do
        if not RenameFile(moved[i], saved[i]) then
          AError := AError + LineEnding + Format(rsFpRestoreFailed, [saved[i], moved[i]]);
      for i := 0 to High(staged) do
        if staged[i] <> '' then DeleteFile(staged[i]);
    end;
  end;
end;

end.
