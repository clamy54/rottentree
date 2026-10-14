// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uGeneratedPasswords;

{$mode objfpc}{$H+}

// Mots de passe tires au sort: montres une fois, proposes en fichier prive, gardes nulle part.
// Fermer sans les noter, c'est reinitialiser les comptes demain matin.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Dialogs;

type
  TGeneratedPassword = record
    Dn: string;
    Account: string;
    Password: string;
    // vide: cree; sinon ce qu'il reste a verifier
    Status: string;
  end;
  TGeneratedPasswords = array of TGeneratedPassword;

procedure ShowGeneratedPasswords(AOwner: TComponent; var AList: TGeneratedPasswords);

type
  TGeneratedPasswordsOverride = procedure(const AList: TGeneratedPasswords);

var
  // essais: recoit la liste a la place du dialogue modal
  GeneratedPasswordsOverride: TGeneratedPasswordsOverride = nil;

// CSV: guillemets partout, ";" comme separateur, et toute cellule qui commencerait comme une
// formule prefixee d'une apostrophe: les guillemets, un tableur s'en moque.
function GeneratedPasswordsCsv(const AList: TGeneratedPasswords): string;
procedure WipeGeneratedPasswords(var AList: TGeneratedPasswords);

resourcestring
  rsGpTitle = 'Generated passwords';
  rsGpIntro = 'These passwords were drawn at random. They are shown here once and kept nowhere: save ' +
    'them now, or the accounts will need a reset.';
  rsGpSave = 'Save as CSV...';
  rsGpClose = 'Close';
  rsGpFilter = 'CSV file (*.csv)|*.csv';
  rsGpSaved = 'Saved to %s (readable by you only).';
  rsGpNotSaved = 'The passwords were not saved. They will not be shown again. Close anyway?';
  rsGpHeader = 'dn;account;password;status';
  rsGpToVerify = 'outcome unknown: check whether the account exists before resetting it';

implementation

uses
  uUiKit, uTheme, uSafeSave, uRtMessage, uRtSecretEdit;

type
  TGeneratedDialog = class(TRtDialog)
  private
    FMemo: TMemo;
    FStatus: TLabel;
    FSaved: Boolean;
    FList: TGeneratedPasswords;
    procedure SaveClick(Sender: TObject);
  public
    function CloseQuery: Boolean; override;
  end;

function Quote(const S: string): string;
var
  v: string;
begin
  v := S;
  if (v <> '') and ((v[1] in ['=', '+', '-', '@', #9, #13]) or (Copy(v, 1, 3) = #$EF#$BC#$9D) or
     (Copy(v, 1, 3) = #$EF#$BC#$8B) or (Copy(v, 1, 3) = #$EF#$BC#$8D) or (Copy(v, 1, 3) = #$EF#$BC#$A0)) then
    v := '''' + v;
  Result := '"' + StringReplace(v, '"', '""', [rfReplaceAll]) + '"';
end;

function GeneratedPasswordsCsv(const AList: TGeneratedPasswords): string;
var
  i: Integer;
begin
  Result := rsGpHeader + LineEnding;
  for i := 0 to High(AList) do
    Result := Result + Quote(AList[i].Dn) + ';' + Quote(AList[i].Account) + ';' +
      Quote(AList[i].Password) + ';' + Quote(AList[i].Status) + LineEnding;
end;

procedure WipeGeneratedPasswords(var AList: TGeneratedPasswords);
var
  i: Integer;
begin
  for i := 0 to High(AList) do
    RtWipeSecret(AList[i].Password);
  AList := nil;
end;

procedure TGeneratedDialog.SaveClick(Sender: TObject);
var
  sd: TSaveDialog;
  ms: TStringStream;
  csv: string;
begin
  sd := TSaveDialog.Create(Self);
  try
    sd.Filter := rsGpFilter;
    sd.DefaultExt := 'csv';
    sd.FileName := 'passwords.csv';
    sd.Options := sd.Options + [ofOverwritePrompt];
    if not sd.Execute then Exit;
    csv := GeneratedPasswordsCsv(FList);
    ms := TStringStream.Create(csv);
    try
      SavePrivateStream(sd.FileName, ms);
    finally
      ms.Free;
      RtWipeSecret(csv);
    end;
    FSaved := True;
    FStatus.Caption := Format(rsGpSaved, [sd.FileName]);
  finally
    sd.Free;
  end;
end;

function TGeneratedDialog.CloseQuery: Boolean;
begin
  Result := inherited CloseQuery;
  if Result and not FSaved then
    Result := RtMessageDlg(rsGpTitle, rsGpNotSaved, mtWarning, [mbYes, mbNo], 0) = mrYes;
end;

procedure ShowGeneratedPasswords(AOwner: TComponent; var AList: TGeneratedPasswords);
var
  d: TGeneratedDialog;
  i: Integer;
  lines: string;
begin
  if Length(AList) = 0 then Exit;
  if Assigned(GeneratedPasswordsOverride) then
  begin
    GeneratedPasswordsOverride(AList);
    WipeGeneratedPasswords(AList);
    Exit;
  end;
  d := TGeneratedDialog.CreateDialog(AOwner, rsGpTitle, 760, 460);
  try
    d.SetIcon('key');
    d.FList := AList;
    MakeLabel(d.Body, rsGpIntro).WordWrap := True;
    d.FMemo := MakeMemo(d.Body);
    d.FMemo.ReadOnly := True;
    d.FMemo.ScrollBars := ssAutoBoth;
    d.FMemo.Font.Name := MonoFontName;
    lines := '';
    for i := 0 to High(AList) do
    begin
      lines := lines + AList[i].Account + #9 + AList[i].Password + #9 + AList[i].Dn;
      if AList[i].Status <> '' then lines := lines + '  (' + AList[i].Status + ')';
      lines := lines + LineEnding;
    end;
    d.FMemo.Text := lines;
    RtWipeSecret(lines);
    d.FStatus := MakeLabel(d.Body, '', alBottom);
    MakeButton(d.ButtonBar, rsGpSave, @d.SaveClick, alLeft);
    d.AddButton(rsGpClose, mrClose, True, True);
    d.ApplyTheme;
    d.ShowModal;
  finally
    d.FMemo.Text := '';
    d.FList := nil;
    d.Free;
    WipeGeneratedPasswords(AList);
  end;
end;

end.
