// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uExportActions;

{$mode objfpc}{$H+}

// Exports d'entrees: LDIF fidele, CSV protege pour les tableurs, JSON versionne.
// Tout ce que l'identite connectee peut lire est exporte, attributs sensibles compris:
// dire non, c'est le travail des ACL du serveur, pas celui de l'export.

interface

uses
  Classes, SysUtils, Contnrs, Forms, uAppContext, uLdapEntry;

resourcestring
  rsExportTitle = 'Export';
  rsExportDone = '%d entries exported to %s';
  rsExportCoverage = 'Coverage: %s';

const
  ENTRIES_JSON_FORMAT = 'rottentree-entries';
  ENTRIES_JSON_VERSION = 1;

procedure ExportEntriesLdif(AOwner: TComponent; ACtx: TAppContext; const AEntries: array of TLdapEntry;
  const ACoverage: string = '');
procedure ExportEntryList(AOwner: TComponent; ACtx: TAppContext; AEntries: TObjectList;
  const AColumns: array of string; const ACoverage: string);

procedure WriteEntriesLdif(AStream: TStream; const AEntries: array of TLdapEntry;
  const ACoverage: string);
procedure WriteEntriesCsv(AStream: TStream; const AEntries: array of TLdapEntry;
  const AColumns: array of string);
procedure WriteEntriesJson(AStream: TStream; const AEntries: array of TLdapEntry;
  const ACoverage: string);

implementation

uses
  Controls, Dialogs, uLdif, uSafeOutput, uSafeSave, uVersion, uCancel;

procedure WriteEntriesLdif(AStream: TStream; const AEntries: array of TLdapEntry;
  const ACoverage: string);
var
  w: TLdifWriter;
  i: Integer;
  e: TLdapEntry;
begin
  w := TLdifWriter.Create(AStream);
  try
    w.WriteVersion;
    w.WriteComment(Format('%s %s export, %s UTC', [RT_APP_NAME, RT_VERSION, FormatUtcIso(UtcNow)]));
    if ACoverage <> '' then
      w.WriteComment(Format(rsExportCoverage, [ACoverage]));
    w.WriteSeparator;
    for i := 0 to High(AEntries) do
    begin
      e := AEntries[i].Clone;
      try
        e.SortForDisplay;
        w.WriteEntry(e);
      finally
        e.Free;
      end;
    end;
  finally
    w.Free;
  end;
end;

procedure WriteEntriesCsv(AStream: TStream; const AEntries: array of TLdapEntry;
  const AColumns: array of string);
var
  csv: TCsvWriter;
  i, j, k: Integer;
  a: TLdapAttribute;
  cell: RawByteString;
begin
  csv := TCsvWriter.Create(AStream, DefaultCsvOptions);
  try
    csv.AddCell('dn');
    for j := 0 to High(AColumns) do
      csv.AddCell(AColumns[j]);
    csv.EndRow;
    for i := 0 to High(AEntries) do
    begin
      csv.AddCell(AEntries[i].Dn);
      for j := 0 to High(AColumns) do
      begin
        a := AEntries[i].Find(AColumns[j]);
        cell := '';
        if a <> nil then
          for k := 0 to a.ValueCount - 1 do
          begin
            if k > 0 then cell := cell + #10;
            cell := cell + a.Values[k];
          end;
        // Formules neutralisees cellule par cellule: une description qui commence par = n'a pas
        // a s'executer chez le comptable.
        csv.AddCell(cell);
      end;
      csv.EndRow;
    end;
  finally
    csv.Free;
  end;
end;

procedure WriteEntriesJson(AStream: TStream; const AEntries: array of TLdapEntry;
  const ACoverage: string);
var
  w: TJsonWriter;
  i, j, k: Integer;
  a: TLdapAttribute;
  e: TLdapEntry;
begin
  w := TJsonWriter.Create(AStream);
  try
    w.BeginObject;
    w.KeyStr('format', ENTRIES_JSON_FORMAT);
    w.KeyInt('version', ENTRIES_JSON_VERSION);
    w.KeyStr('generator', RT_APP_NAME + ' ' + RT_VERSION);
    w.KeyStr('exportedUtc', FormatUtcIso(UtcNow));
    w.KeyStr('coverage', ACoverage);
    // Toujours vrai, garde pour les lecteurs du format 1.
    w.KeyBool('sensitiveIncluded', True);
    w.Key('entries');
    w.BeginArray;
    for i := 0 to High(AEntries) do
    begin
      e := AEntries[i].Clone;
      try
        e.SortForDisplay;
        w.BeginObject;
        w.KeyStr('dn', e.Dn);
        w.Key('attributes');
        w.BeginObject;
        for j := 0 to e.AttrCount - 1 do
        begin
          a := e.Attrs[j];
          w.Key(a.Description);
          w.BeginArray;
          for k := 0 to a.ValueCount - 1 do
            w.TextOrBytes(a.Values[k]);
          w.EndArray;
        end;
        w.EndObject;
        w.EndObject;
      finally
        e.Free;
      end;
    end;
    w.EndArray;
    w.EndObject;
  finally
    w.Free;
  end;
end;

procedure ExportEntriesLdif(AOwner: TComponent; ACtx: TAppContext; const AEntries: array of TLdapEntry;
  const ACoverage: string);
var
  sd: TSaveDialog;
  ms: TMemoryStream;
begin
  if Length(AEntries) = 0 then Exit;
  sd := TSaveDialog.Create(AOwner);
  try
    sd.Filter := 'LDIF (*.ldif)|*.ldif|All files|*.*';
    sd.DefaultExt := 'ldif';
    sd.Options := sd.Options + [ofOverwritePrompt];
    if not sd.Execute then Exit;
    ms := TMemoryStream.Create;
    try
      WriteEntriesLdif(ms, AEntries, ACoverage);
      ms.Position := 0;
      SavePrivateStream(sd.FileName, ms);
      ACtx.Log(mlInfo, rsExportTitle, Format(rsExportDone, [Length(AEntries), sd.FileName]));
    finally
      ms.Free;
    end;
  finally
    sd.Free;
  end;
end;

procedure ExportEntryList(AOwner: TComponent; ACtx: TAppContext; AEntries: TObjectList;
  const AColumns: array of string; const ACoverage: string);
var
  sd: TSaveDialog;
  ms: TMemoryStream;
  arr: array of TLdapEntry;
  i: Integer;
begin
  if (AEntries = nil) or (AEntries.Count = 0) then Exit;
  SetLength(arr, AEntries.Count);
  for i := 0 to AEntries.Count - 1 do
    arr[i] := TLdapEntry(AEntries[i]);
  sd := TSaveDialog.Create(AOwner);
  try
    sd.Filter := 'LDIF (*.ldif)|*.ldif|CSV for spreadsheets (*.csv)|*.csv|JSON (*.json)|*.json';
    sd.Options := sd.Options + [ofOverwritePrompt];
    if not sd.Execute then Exit;
    ms := TMemoryStream.Create;
    try
      case sd.FilterIndex of
        2: WriteEntriesCsv(ms, arr, AColumns);
        3: WriteEntriesJson(ms, arr, ACoverage);
      else
        WriteEntriesLdif(ms, arr, ACoverage);
      end;
      ms.Position := 0;
      SavePrivateStream(sd.FileName, ms);
      ACtx.Log(mlInfo, rsExportTitle, Format(rsExportDone, [Length(arr), sd.FileName]));
    finally
      ms.Free;
    end;
  finally
    sd.Free;
  end;
end;

end.
