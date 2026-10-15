// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTemplateManager;

{$mode objfpc}{$H+}

// Gestionnaire des modeles du document: creer, modifier, dupliquer, supprimer, echanger par
// fichier. La liste dit lesquels tiennent sur le serveur ouvert, et pourquoi les autres non.
// Sans connexion on range; on n'edite pas a l'aveugle.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, Dialogs, LCLType,
  uUiKit, uAppContext, uRtList, uEntryTemplate, uLdapEntry;

type
  TTemplateManager = class(TRtDialog)
  private
    FCtx: TAppContext;
    FProfileUuid: string;
    FItems: TEntryTemplates;
    FProblems: TStringArray;
    FList: TRtListGrid;
    FInfo: TMemo;
    FNote: TLabel;
    FNew, FEdit, FCopy, FDelete, FImport, FExport: TButton;
    FChanged: Boolean;
    procedure BuildUi;
    function CanEdit: Boolean;
    function Selected: Integer;
    procedure Reload(const ASelectUuid: string);
    procedure UpdateButtons;
    procedure ListSelect(Sender: TObject; AIndex: Integer);
    procedure ListActivate(Sender: TObject; AIndex: Integer);
    function CellIcon(Sender: TObject; AIndex, ACol: Integer; out AColor: TColor): string;
    procedure NewClick(Sender: TObject);
    procedure EditClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure ImportClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
  public
    constructor CreateManager(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string);
    function ListText: string;
    function Select(const AName: string): Boolean;
    procedure DuplicateSelected;
    procedure DeleteSelected;
    function InfoText: string;
    property Changed: Boolean read FChanged;
  end;

procedure ShowTemplateManager(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string);
function NewTemplateFromEntry(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
  AEntry: TLdapEntry): Boolean;
// Vide: le modele tient sur ce serveur. Sinon, le motif.
function TemplateProblemOn(ACtx: TAppContext; const AProfileUuid: string;
  const T: TEntryTemplate): string;
// Connexion ou editer un modele: l'active si elle est de sa famille, sinon une autre ouverte qui
// l'est. Vide: aucune.
function TemplateConnection(ACtx: TAppContext; const AActiveUuid: string;
  const T: TEntryTemplate): string;

resourcestring
  rsTmTitle = 'Entry templates';
  rsTmHelp = 'A template creates entries of one kind with a short form: fixed values, values asked ' +
    'for, values composed from others, free numbers. Use one from the tree: right click a container, ' +
    'then "Create from template...".';
  rsTmNew = 'New...';
  rsTmEdit = 'Edit...';
  rsTmCopy = 'Duplicate';
  rsTmDelete = 'Delete';
  rsTmImport = 'Import...';
  rsTmExport = 'Export all...';
  rsTmColName = 'Template';
  rsTmColKind = 'Creates';
  rsTmColRdn = 'Named by';
  rsTmColStatus = 'On this server';
  rsTmColDesc = 'Description';
  rsTmUsable = 'ready';
  rsTmAdapt = '"%s" was designed for %s, and no connection of that kind is open.' + LineEnding +
    LineEnding + 'Adapt it to %s? It becomes a template for that kind of server.';
  rsTmNotUsable = 'needs changes';
  rsTmUnknown = 'not checked';
  rsTmNoDocument = 'Open or create a document first: templates are kept in the document.';
  rsTmNoConnection = 'Connect to a directory to create or edit templates: the editor works from its schema.';
  rsTmUnreadable = '%d template(s) of this document could not be read and are not shown.';
  rsTmConfirmDelete = 'Delete the template "%s"? Entries created from it are not affected.';
  rsTmCopyOf = '%s (copy)';
  rsTmFilter = 'Template export (*.json)|*.json|All files|*.*';
  rsTmExported = '%d template(s) exported to %s.';
  rsTmImported = '%d template(s) imported.';
  rsTmImportedBad = '%d template(s) imported, %d left aside (unreadable, or beyond the %d the document can hold).';
  rsTmExportPasswords = '%d password(s) written in the template (fixed, or text of a composition) in: %s. ' +
    'The export file is not encrypted.' + LineEnding + LineEnding + 'Yes: write them into the file.' +
    LineEnding + 'No: leave them out; those values are to be set again after the import.';
  rsTmConfirmParts = 'The export needs %d files:%s' + LineEnding + LineEnding + 'Write them?';
  rsTmWillReplace = '(will be replaced)';
  rsTmWillRemove = '(older export, removed)';
  rsTmExportedParts = '%d template(s) exported in %d files, %s and following: one file would be too large to import.';
  rsTmImportNone = 'The file holds no template.';
  rsTmReadFailed = 'The file cannot be read.';
  rsTmNothingToExport = 'There is no template to export.';
  rsTmProblem = 'On this server: %s';
  rsTmReady = 'On this server: ready to use.';
  rsTmFromEntrySkipped = 'Left out of the template: %s';
  rsTmFromEntryTitle = 'Template from an entry';

function PartName(const ABase: string; AIndex, ACount: Integer): string;
function PublishParts(const AParts, ATargets, AStale: TStringArray; out AError: string): Boolean;

implementation

uses
  uTheme, uConnections, uConnectionProfile, uServerKind, uRtMessage, uSafeSave,
  uTemplateLibrary, uTemplateEditor, uEntryCreationPlan, uStrings, uFilePublish;

function TemplateProblemOn(ACtx: TAppContext; const AProfileUuid: string;
  const T: TEntryTemplate): string;
var
  c: TDirectoryConnection;
  analysis: TClassAnalysis;
  issues: TTplIssues;
begin
  Result := '';
  c := ACtx.Connections.Find(AProfileUuid);
  if (c = nil) or not c.IsReady or (c.Schema = nil) then Exit(rsCpNoSchema);
  issues := CheckTemplate(T, c.Schema, EffectiveServerKind(c.Profile, c.RootDse), ACtx.Sensitive,
    analysis);
  Result := FirstTemplateError(issues);
end;

function TemplateConnection(ACtx: TAppContext; const AActiveUuid: string;
  const T: TEntryTemplate): string;
var
  c: TDirectoryConnection;
  i: Integer;
begin
  c := ACtx.Connections.Find(AActiveUuid);
  if (c <> nil) and c.IsReady and TemplateFitsProvider(T, EffectiveServerKind(c.Profile, c.RootDse)) then
    Exit(AActiveUuid);
  for i := 0 to ACtx.Connections.Count - 1 do
  begin
    c := ACtx.Connections.Item(i);
    if c.IsReady and (c.Schema <> nil) and TemplateFitsProvider(T, EffectiveServerKind(c.Profile, c.RootDse)) then
      Exit(c.Profile.Uuid);
  end;
  Result := '';
end;

procedure ShowTemplateManager(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string);
var
  d: TTemplateManager;
begin
  if ACtx.Document = nil then
  begin
    RtMessageDlg(rsTmTitle, rsTmNoDocument, mtInformation, [mbOK], 0);
    Exit;
  end;
  d := TTemplateManager.CreateManager(AOwner, ACtx, AProfileUuid);
  try
    d.ShowModal;
  finally
    d.Free;
  end;
end;

function NewTemplateFromEntry(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
  AEntry: TLdapEntry): Boolean;
var
  c: TDirectoryConnection;
  t: TEntryTemplate;
  skipped: TStringArray;
  err: string;
begin
  Result := False;
  if ACtx.Document = nil then
  begin
    RtMessageDlg(rsTmFromEntryTitle, rsTmNoDocument, mtInformation, [mbOK], 0);
    Exit;
  end;
  c := ACtx.Connections.Find(AProfileUuid);
  if (c = nil) or not c.IsReady or (c.Schema = nil) or (AEntry = nil) then
  begin
    RtMessageDlg(rsTmFromEntryTitle, rsCpNoSchema, mtWarning, [mbOK], 0);
    Exit;
  end;
  if not TemplateFromEntry(AEntry, c.Schema, EffectiveServerKind(c.Profile, c.RootDse),
    ACtx.Sensitive, t, skipped, err) then
  begin
    RtMessageDlg(rsTmFromEntryTitle, err, mtWarning, [mbOK], 0);
    Exit;
  end;
  t.Name := UniqueTemplateName(ACtx.Document, t.Structural);
  if Length(skipped) > 0 then
    ACtx.Log(mlInfo, rsTmFromEntryTitle, Format(rsTmFromEntrySkipped, [string.Join(', ', skipped)]));
  Result := EditTemplate(AOwner, ACtx, AProfileUuid, t);
end;

constructor TTemplateManager.CreateManager(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid: string);
var
  c: TDirectoryConnection;
begin
  inherited CreateDialog(AOwner, rsTmTitle, 980, 640);
  SetIcon('file-text');
  FCtx := ACtx;
  FProfileUuid := AProfileUuid;
  c := FCtx.Connections.Find(FProfileUuid);
  if (c <> nil) and c.IsReady then SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
  BuildUi;
  ApplyTheme;
  FInfo.Color := clEditorBg;
  FInfo.Font.Color := clEditorFg;
  StyleMemo(FInfo);
  Reload('');
end;

procedure TTemplateManager.BuildUi;
var
  bar: TPanel;
  lbl: TLabel;
begin
  lbl := MakeLabel(Body, rsTmHelp);
  lbl.WordWrap := True;
  FNote := MakeDataLabel(Body, '');
  FNote.WordWrap := True;
  FNote.Visible := False;
  bar := MakePanel(Body, alTop, 38);
  bar.BorderSpacing.Top := 4;
  FNew := MakeButton(bar, rsTmNew, @NewClick);
  FEdit := MakeButton(bar, rsTmEdit, @EditClick);
  FCopy := MakeButton(bar, rsTmCopy, @CopyClick);
  FDelete := MakeButton(bar, rsTmDelete, @DeleteClick);
  FExport := MakeButton(bar, rsTmExport, @ExportClick, alRight);
  FImport := MakeButton(bar, rsTmImport, @ImportClick, alRight);
  FInfo := MakeMemo(Body, alBottom);
  FInfo.Height := 170;
  FInfo.ReadOnly := True;
  FInfo.WordWrap := True;
  FInfo.ScrollBars := ssAutoVertical;
  FList := TRtListGrid.Create(Body);
  FList.Parent := Body;
  FList.Align := alClient;
  FList.BorderSpacing.Top := 4;
  FList.BorderSpacing.Bottom := 4;
  FList.FillWidth := True;
  FList.AddColumn(rsTmColName, 220);
  FList.AddColumn(rsTmColKind, 230);
  FList.AddColumn(rsTmColRdn, 90);
  FList.AddColumn(rsTmColStatus, 130);
  FList.AddColumn(rsTmColDesc, 260);
  FList.OnSelectRow := @ListSelect;
  FList.OnActivateRow := @ListActivate;
  FList.OnGetCellIcon := @CellIcon;
  AddButton(rsClose, mrClose, True, True);
end;

function TTemplateManager.CanEdit: Boolean;
var
  c: TDirectoryConnection;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  Result := (FCtx.Document <> nil) and (c <> nil) and c.IsReady and (c.Schema <> nil);
end;

function TTemplateManager.Selected: Integer;
begin
  Result := FList.ItemIndex;
  if (Result < 0) or (Result > High(FItems)) then Result := -1;
end;

procedure TTemplateManager.Reload(const ASelectUuid: string);
var
  bad, i, pick: Integer;
  status: string;
  checked: Boolean;
begin
  FItems := LoadTemplates(FCtx.Document, bad);
  checked := CanEdit;
  SetLength(FProblems, Length(FItems));
  FList.Clear;
  pick := -1;
  for i := 0 to High(FItems) do
  begin
    FProblems[i] := '';
    if not checked then status := rsTmUnknown
    else
    begin
      FProblems[i] := TemplateProblemOn(FCtx, FProfileUuid, FItems[i]);
      if FProblems[i] = '' then status := rsTmUsable else status := rsTmNotUsable;
    end;
    FList.AddRow([FItems[i].Name, TemplateKindText(FItems[i]), FItems[i].RdnAttr, status,
      FItems[i].Description]);
    if FItems[i].Uuid = ASelectUuid then pick := i;
  end;
  if (pick < 0) and (Length(FItems) > 0) then pick := 0;
  if pick >= 0 then FList.ItemIndex := pick;
  FNote.Visible := (bad > 0) or not checked;
  if not checked then FNote.Caption := rsTmNoConnection
  else if bad > 0 then FNote.Caption := Format(rsTmUnreadable, [bad]);
  FNote.Font.Color := DialogStateColor(usWarning);
  ListSelect(FList, pick);
  UpdateButtons;
end;

procedure TTemplateManager.UpdateButtons;
var
  sel: Boolean;
begin
  sel := Selected >= 0;
  FNew.Enabled := CanEdit;
  FEdit.Enabled := CanEdit and sel;
  FCopy.Enabled := sel;
  FDelete.Enabled := sel;
  FExport.Enabled := Length(FItems) > 0;
end;

procedure TTemplateManager.ListSelect(Sender: TObject; AIndex: Integer);
var
  info: string;
begin
  FInfo.Clear;
  if (AIndex < 0) or (AIndex > High(FItems)) then
  begin
    UpdateButtons;
    Exit;
  end;
  info := TemplateSummary(FItems[AIndex], FCtx.Sensitive);
  if CanEdit then
  begin
    if FProblems[AIndex] = '' then info := rsTmReady + #10 + info
    else info := Format(rsTmProblem, [FProblems[AIndex]]) + #10 + info;
  end;
  FInfo.Text := StringReplace(info, #10, LineEnding, [rfReplaceAll]);
  UpdateButtons;
end;

procedure TTemplateManager.ListActivate(Sender: TObject; AIndex: Integer);
begin
  if FEdit.Enabled then EditClick(nil);
end;

function TTemplateManager.CellIcon(Sender: TObject; AIndex, ACol: Integer; out AColor: TColor): string;
begin
  Result := '';
  AColor := clNone;
  if (ACol <> 3) or (AIndex < 0) or (AIndex > High(FItems)) or not CanEdit then Exit;
  if FProblems[AIndex] = '' then
  begin
    Result := 'circle-check';
    AColor := ShellStateColor(usOk);
  end
  else
  begin
    Result := 'alert-triangle';
    AColor := ShellStateColor(usWarning);
  end;
end;

procedure TTemplateManager.NewClick(Sender: TObject);
var
  t: TEntryTemplate;
begin
  if not CanEdit then Exit;
  t := NewTemplate;
  if EditTemplate(Self, FCtx, FProfileUuid, t) then
  begin
    FChanged := True;
    Reload(t.Uuid);
  end;
end;

procedure TTemplateManager.EditClick(Sender: TObject);
var
  t: TEntryTemplate;
  i: Integer;
  uuid, kind: string;
  c: TDirectoryConnection;
begin
  i := Selected;
  if (i < 0) or not CanEdit then Exit;
  t := CloneTemplate(FItems[i]);
  // Un modele LDAP se modifie selon un LDAP: l'onglet actif n'a pas a lui imposer les regles d'AD.
  uuid := TemplateConnection(FCtx, FProfileUuid, t);
  if uuid = '' then
  begin
    c := FCtx.Connections.Find(FProfileUuid);
    kind := ServerKindName(EffectiveServerKind(c.Profile, c.RootDse));
    if RtMessageDlg(rsTmTitle, Format(rsTmAdapt, [t.Name, t.Origin, kind]), mtConfirmation,
       [mbYes, mbNo], 0) <> mrYes then Exit;
    t.Origin := kind;
    uuid := FProfileUuid;
  end;
  if EditTemplate(Self, FCtx, uuid, t) then
  begin
    FChanged := True;
    Reload(t.Uuid);
  end;
end;

procedure TTemplateManager.CopyClick(Sender: TObject);
var
  t: TEntryTemplate;
  i: Integer;
  err: string;
begin
  i := Selected;
  if i < 0 then Exit;
  t := CloneTemplate(FItems[i]);
  t.Uuid := '';
  t.Name := UniqueTemplateName(FCtx.Document, Format(rsTmCopyOf, [FItems[i].Name]));
  if not StoreTemplate(FCtx.Document, t, err) then
  begin
    RtMessageDlg(rsTmTitle, err, mtWarning, [mbOK], 0);
    Exit;
  end;
  FChanged := True;
  FCtx.StatusChanged;
  Reload(t.Uuid);
end;

procedure TTemplateManager.DeleteClick(Sender: TObject);
var
  i: Integer;
begin
  i := Selected;
  if i < 0 then Exit;
  if RtMessageDlg(rsTmTitle, Format(rsTmConfirmDelete, [FItems[i].Name]), mtConfirmation,
    [mbYes, mbNo], 0) <> mrYes then Exit;
  if DeleteTemplate(FCtx.Document, FItems[i].Uuid) then
  begin
    FChanged := True;
    FCtx.StatusChanged;
  end;
  Reload('');
end;

function PartName(const ABase: string; AIndex, ACount: Integer): string;
begin
  if ACount = 1 then Result := ABase
  else Result := ChangeFileExt(ABase, '') + '-' + IntToStr(AIndex) + ExtractFileExt(ABase);
end;

function PublishParts(const AParts, ATargets, AStale: TStringArray; out AError: string): Boolean;
var
  parts: TPublishParts;
  i: Integer;
begin
  parts := nil;
  SetLength(parts, Length(ATargets));
  for i := 0 to High(ATargets) do parts[i] := PublishText(ATargets[i], AParts[i]);
  Result := PublishFiles(parts, AStale, AError);
end;

procedure TTemplateManager.ExportClick(Sender: TObject);
var
  sd: TSaveDialog;
  parts, targets, stale: TStringArray;
  i, j, k, count: Integer;
  first, listing, names, err: string;
  items: TEntryTemplates;
begin
  if Length(FItems) = 0 then
  begin
    RtMessageDlg(rsTmTitle, rsTmNothingToExport, mtInformation, [mbOK], 0);
    Exit;
  end;
  items := nil;
  SetLength(items, Length(FItems));
  names := '';
  count := 0;
  for i := 0 to High(FItems) do
  begin
    items[i] := CloneTemplate(FItems[i]);
    for j := 0 to High(items[i].Fields) do
      if TemplateSecretInClear(items[i].Fields[j], FCtx.Sensitive) then
      begin
        Inc(count);
        if Pos(items[i].Name, names) = 0 then
        begin
          if names <> '' then names := names + ', ';
          names := names + items[i].Name;
        end;
      end;
  end;
  if count > 0 then
  begin
    // Le fichier exporte n'est pas chiffre: il part en courriel, sur une cle, dans un ticket.
    case RtMessageDlg(rsTmTitle, Format(rsTmExportPasswords, [count, names]), mtWarning,
      [mbYes, mbNo, mbCancel], 0) of
      mrYes: ;
      mrNo:
        for i := 0 to High(items) do
          for j := 0 to High(items[i].Fields) do
            if TemplateSecretInClear(items[i].Fields[j], FCtx.Sensitive) then
              TemplateDropSecret(items[i].Fields[j]);
    else
      Exit;
    end;
  end;
  sd := TSaveDialog.Create(Self);
  try
    sd.Filter := rsTmFilter;
    sd.DefaultExt := 'json';
    sd.FileName := 'rottentree-templates.json';
    sd.Options := sd.Options + [ofOverwritePrompt];
    if not sd.Execute then Exit;
    parts := ExportTemplatesParts(items);
    targets := nil;
    SetLength(targets, Length(parts));
    listing := '';
    for i := 0 to High(parts) do
    begin
      targets[i] := PartName(sd.FileName, i + 1, Length(parts));
      listing := listing + LineEnding + ExtractFileName(targets[i]);
      if FileExists(targets[i]) then listing := listing + '  ' + rsTmWillReplace;
    end;
    // Restes d'un export plus long: laisses la, ils se reimporteraient avec les nouvelles.
    stale := nil;
    if (Length(parts) > 1) and FileExists(sd.FileName) then stale := [sd.FileName];
    k := 1;
    if Length(parts) > 1 then k := Length(parts) + 1;
    while (k < 10000) and FileExists(PartName(sd.FileName, k, 2)) do
    begin
      SetLength(stale, Length(stale) + 1);
      stale[High(stale)] := PartName(sd.FileName, k, 2);
      Inc(k);
    end;
    for i := 0 to High(stale) do
      listing := listing + LineEnding + ExtractFileName(stale[i]) + '  ' + rsTmWillRemove;
    // Le dialogue n'a confirme qu'un nom; les fichiers numerotes, eux, n'ont rien promis.
    if ((Length(parts) > 1) or (Length(stale) > 0)) and (RtMessageDlg(rsTmTitle,
        Format(rsTmConfirmParts, [Length(parts), listing]), mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then
      Exit;
    if not PublishParts(parts, targets, stale, err) then
    begin
      RtMessageDlg(rsTmTitle, err, mtError, [mbOK], 0);
      Exit;
    end;
    first := targets[0];
    if Length(parts) = 1 then
      FCtx.Log(mlInfo, rsTmTitle, Format(rsTmExported, [Length(FItems), first]))
    else
      FCtx.Log(mlWarning, rsTmTitle, Format(rsTmExportedParts, [Length(FItems), Length(parts), first]));
  finally
    sd.Free;
  end;
end;

procedure TTemplateManager.ImportClick(Sender: TObject);
var
  od: TOpenDialog;
  fs: THandleStream;
  notReg: Boolean;
  raw: RawByteString;
  list: TEntryTemplates;
  bad, i, done: Integer;
  err, last: string;
begin
  od := TOpenDialog.Create(Self);
  try
    od.Filter := rsTmFilter;
    if not od.Execute then Exit;
    // Fichier ordinaire, lu une fois et borne: un FIFO ne gele pas l'interface.
    fs := OpenRegularFileRead(od.FileName, notReg);
    if fs = nil then
    begin
      RtMessageDlg(rsTmTitle, rsTmReadFailed, mtWarning, [mbOK], 0);
      Exit;
    end;
    try
      if not ReadWholeStream(fs, TEMPLATE_EXPORT_MAX_BYTES, raw) then
      begin
        RtMessageDlg(rsTmTitle, rsTlTooLarge, mtWarning, [mbOK], 0);
        Exit;
      end;
    finally
      fs.Free;
    end;
  finally
    od.Free;
  end;
  if not ImportTemplatesJson(string(raw), list, bad, err) then
  begin
    RtMessageDlg(rsTmTitle, err, mtWarning, [mbOK], 0);
    Exit;
  end;
  done := 0;
  last := '';
  for i := 0 to High(list) do
  begin
    // Jamais d'ecrasement: l'importe arrive a cote des autres, sous un nom libre.
    list[i].Uuid := '';
    list[i].Name := UniqueTemplateName(FCtx.Document, list[i].Name);
    if StoreTemplate(FCtx.Document, list[i], err) then
    begin
      Inc(done);
      last := list[i].Uuid;
    end
    else
      Inc(bad);
  end;
  if done > 0 then
  begin
    FChanged := True;
    FCtx.StatusChanged;
  end;
  Reload(last);
  if (done = 0) and (bad = 0) then
    RtMessageDlg(rsTmTitle, rsTmImportNone, mtInformation, [mbOK], 0)
  else if bad > 0 then
    RtMessageDlg(rsTmTitle, Format(rsTmImportedBad, [done, bad, TEMPLATE_LIBRARY_MAX]), mtWarning, [mbOK], 0)
  else
    FCtx.Log(mlInfo, rsTmTitle, Format(rsTmImported, [done]));
end;

function TTemplateManager.Select(const AName: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    if SameText(FItems[i].Name, AName) then
    begin
      FList.ItemIndex := i;
      ListSelect(FList, i);
      Exit(True);
    end;
  Result := False;
end;

procedure TTemplateManager.DuplicateSelected;
begin
  CopyClick(nil);
end;

procedure TTemplateManager.DeleteSelected;
begin
  DeleteClick(nil);
end;

function TTemplateManager.InfoText: string;
begin
  Result := FInfo.Text;
end;

function TTemplateManager.ListText: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to FList.Count - 1 do
    Result := Result + FList.CellText(i, 0) + ' | ' + FList.CellText(i, 1) + ' | ' +
      FList.CellText(i, 3) + LineEnding;
end;

end.
