// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uProfileExchangeDialog;

{$mode objfpc}{$H+}

// Export et import d'une selection de profils. Aucun secret ne sort, meme pas sa reference;
// a l'import, chaque profil revient en lecture seule, sans secret, exceptions TLS remises au
// strict. Un fichier qui a voyage par mail n'a droit a aucune indulgence.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, CheckLst, Forms, Dialogs, uAppContext,
  uProfileCatalog;

function ExportProfilesDialog(AOwner: TComponent; ACtx: TAppContext; ACatalog: TProfileCatalog): Boolean;
function ImportProfilesDialog(AOwner: TComponent; ACtx: TAppContext; ACatalog: TProfileCatalog): Integer;

implementation

uses
  Contnrs, uUiKit, uConnectionProfile, uProfileExchange, uSafeSave, uStrings, uRtMessage;

resourcestring
  rsExTitle = 'Export profiles';
  rsImTitle = 'Import profiles';
  rsExIntro = 'Select the profiles to export. No password, secret or secret reference is ' +
    'written: secrets only travel inside an encrypted Rottentree document.';
  rsExFilter = 'Rottentree profiles (*.json)|*.json|All files|*.*';
  rsExDone = '%d profile(s) exported to %s';
  rsExNone = 'Select at least one profile.';
  rsImIntro = 'Imported profiles are created read-only, without secret, with strict TLS ' +
    'verification; the server type chosen in the file is kept.';
  rsImSkipped = 'Not imported (unreadable): %s';
  rsImDone = '%d profile(s) imported from %s';
  rsImTooLarge = 'The file is too large for a profile export.';
  rsImNoDocument = 'Open or create a document first.';
  rsImItem = '%s  (%s)  - %s';

function ExportProfilesDialog(AOwner: TComponent; ACtx: TAppContext; ACatalog: TProfileCatalog): Boolean;
var
  d: TRtDialog;
  list: TCheckListBox;
  i, n: Integer;
  sel: array of TConnectionProfile;
  sd: TSaveDialog;
  ms: TStringStream;
begin
  Result := False;
  d := TRtDialog.CreateDialog(AOwner, rsExTitle, 640, 520);
  d.SetIcon('file-export');
  try
    MakeLabel(d.Body, rsExIntro).WordWrap := True;
    list := TCheckListBox.Create(d.Body);
    list.Parent := d.Body;
    list.Align := alClient;
    for i := 0 to ACatalog.Count - 1 do
    begin
      list.Items.Add(ACatalog[i].Name + '  (' + ACatalog[i].DisplayEndpoint + ')');
      list.Checked[i] := True;
    end;
    d.AddButton(rsOk, mrOk, True);
    d.AddButton(rsCancel, mrCancel, False, True);
    d.ApplyTheme;
    if d.ShowModal <> mrOk then Exit;
    sel := nil;
    n := 0;
    SetLength(sel, ACatalog.Count);
    for i := 0 to ACatalog.Count - 1 do
      if list.Checked[i] then
      begin
        sel[n] := ACatalog[i];
        Inc(n);
      end;
    SetLength(sel, n);
  finally
    d.Free;
  end;
  if n = 0 then
  begin
    RtMessageDlg(rsExTitle, rsExNone, mtInformation, [mbOK], 0);
    Exit;
  end;
  sd := TSaveDialog.Create(AOwner);
  try
    sd.Filter := rsExFilter;
    sd.DefaultExt := 'json';
    sd.FileName := 'rottentree-profiles.json';
    sd.Options := sd.Options + [ofOverwritePrompt];
    if not sd.Execute then Exit;
    ms := TStringStream.Create(ExportProfilesJson(sel));
    try
      SavePrivateStream(sd.FileName, ms);
    finally
      ms.Free;
    end;
    ACtx.Log(mlInfo, rsExTitle, Format(rsExDone, [n, sd.FileName]));
    Result := True;
  finally
    sd.Free;
  end;
end;

function ReadLimitedFile(const APath: string; out AText: string): Boolean;
var
  fs: THandleStream;
  notReg: Boolean;
  raw: RawByteString;
begin
  Result := False;
  AText := '';
  // Fichier ordinaire seulement, ouvert sans blocage: un FIFO ou un peripherique est refuse
  // comme illisible, au lieu de geler l'interface en attendant qu'il veuille bien parler.
  fs := OpenRegularFileRead(APath, notReg);
  if fs = nil then Exit;
  try
    // Taille lue une fois, lecture bornee a cette taille: un fichier qui enfle pendant la
    // lecture n'enfle pas la memoire.
    Result := ReadWholeStream(fs, PORTABLE_EXPORT_MAX_BYTES, raw);
    if Result then AText := string(raw);
  finally
    fs.Free;
  end;
end;

function ImportProfilesDialog(AOwner: TComponent; ACtx: TAppContext; ACatalog: TProfileCatalog): Integer;
var
  od: TOpenDialog;
  text, err: string;
  imp: TProfileImport;
  existing: array of TConnectionProfile;
  i: Integer;
  d: TRtDialog;
  list: TCheckListBox;
  chosen: TObjectList;
begin
  Result := 0;
  if ACtx.Document = nil then
  begin
    RtMessageDlg(rsImTitle, rsImNoDocument, mtInformation, [mbOK], 0);
    Exit;
  end;
  od := TOpenDialog.Create(AOwner);
  imp := TProfileImport.Create;
  try
    od.Filter := rsExFilter;
    if not od.Execute then Exit;
    if not ReadLimitedFile(od.FileName, text) then
    begin
      RtMessageDlg(rsImTitle, rsImTooLarge, mtError, [mbOK], 0);
      Exit;
    end;
    existing := nil;
    SetLength(existing, ACatalog.Count);
    for i := 0 to ACatalog.Count - 1 do
      existing[i] := ACatalog[i];
    if not imp.Parse(text, existing, err) then
    begin
      RtMessageDlg(rsImTitle, err, mtError, [mbOK], 0);
      Exit;
    end;
    d := TRtDialog.CreateDialog(AOwner, rsImTitle, 720, 540);
  d.SetIcon('file-import');
    try
      MakeLabel(d.Body, rsImIntro).WordWrap := True;
      if imp.Skipped.Count > 0 then
        MakeLabel(d.Body, Format(rsImSkipped, [imp.Skipped.CommaText])).WordWrap := True;
      list := TCheckListBox.Create(d.Body);
      list.Parent := d.Body;
      list.Align := alClient;
      for i := 0 to imp.Count - 1 do
      begin
        list.Items.Add(Format(rsImItem, [imp[i].Name, imp[i].DisplayEndpoint,
          ImportConflictText(imp.Conflicts[i])]));
        list.Checked[i] := True;
      end;
      d.AddButton(rsOk, mrOk, True);
      d.AddButton(rsCancel, mrCancel, False, True);
      d.ApplyTheme;
      if d.ShowModal <> mrOk then Exit;
      for i := 0 to imp.Count - 1 do
        imp.Selected[i] := list.Checked[i];
    finally
      d.Free;
    end;
    chosen := imp.TakeSelected;
    try
      for i := 0 to chosen.Count - 1 do
        uProfileCatalog.StoreProfile(ACtx.Document, TConnectionProfile(chosen[i]), '', '', False);
      Result := chosen.Count;
    finally
      chosen.Free;
    end;
    ACtx.Log(mlInfo, rsImTitle, Format(rsImDone, [Result, od.FileName]));
  finally
    imp.Free;
    od.Free;
  end;
end;

end.
