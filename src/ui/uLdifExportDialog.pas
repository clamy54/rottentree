// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdifExportDialog;

{$mode objfpc}{$H+}

// Export LDIF d'une entree ou d'une selection. Incomplet: ecrit seulement sur accord, et le
// fichier l'avoue.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs, uAppContext, uLdapEntry,
  uOpsDialog, uDirectoryWorker, uLdifExport, uRtCheck, uUiInbox, uConnections;

resourcestring
  rsLxTitle = 'Export LDIF';
  rsLxEntry = 'Entry: %s';
  rsLxSelection = 'Selection: %d entries, from %s';
  rsLxFile = 'Destination file';
  rsLxBrowse = 'Browse...';
  rsLxChildren = 'Include child entries';
  rsLxExclude = 'Leave out attributes managed by the server (createTimestamp, entryCSN, entryUUID...)';
  rsLxExport = 'Export';
  rsLxCancel = 'Cancel';
  rsLxNoFile = 'Choose the destination file.';
  rsLxOverwrite = '%s already exists. Replace it?';
  rsLxReading = 'Reading the subtree: %d entries...';
  rsLxDone = '%d entries exported to %s';
  rsLxWriteFailed = 'Nothing written: %s';
  rsLxWriting = 'Writing %d entries to %s...';
  rsLxWriteCancelled = 'Export cancelled: %s was not written.';
  rsLxTaskBusy = 'Nothing written: too many file operations are running. Try again.';
  rsLxSearchFailed = 'Nothing written: the subtree could not be read (%s).';
  rsLxPartial = 'Only %d entries could be read (%s). Save this partial export? The file will say it is partial.';
  rsLxPartialNotSaved = 'Partial export not saved.';
  rsLxCoverage = 'Coverage: %s';
  rsLxOmitted = 'Attributes managed by the server left out: %s';
  rsLxTooLarge = 'Nothing written: the export exceeds %d entries or %d MiB. Export a smaller subtree.';
  rsLxEntryPartial = 'The entry as displayed is incomplete (%s). Save this partial export? The file will say it is partial.';
  rsLxEntryIncomplete = 'some values could not be decoded';
  rsLxEntryTruncated = 'some attributes were truncated by a size limit';
  rsLxSchemaChanged = 'Nothing written: the schema of the connection was read again during the export. Export again.';
  rsLxBaseFailed = 'Nothing written: %s could not be read (%s).';
  rsLxNotConnected = 'not connected';

type
  TLdifExportDialog = class(TOpsDialog)
  private
    FEntry: TLdapEntry;
    FDns: TStringArray;
    FBases: TStringArray;
    FBaseIndex: Integer;
    // Entrees rendues par la base en cours: zero, c'est une entree choisie absente du fichier.
    FBaseGot: Integer;
    FPartial: string;
    FSeen: TStringList;
    FFile: TEdit;
    FChildren: TRtCheckBox;
    FExclude: TRtCheckBox;
    FExportBtn, FBrowseBtn: TButton;
    FCollector: TLdifExportCollector;
    FCollectorStamp: TSessionStamp;
    FSaveTask: Int64;
    FSavedCount: Integer;
    FDest: string;
    FMaxEntries: Integer;
    FAutoAnswer: TModalResult;
    function Ask(const AText: string; AType: TMsgDlgType): TModalResult;
    procedure BrowseClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
    procedure CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
    procedure SetRunning(ARunning: Boolean);
    function NewCollector: TLdifExportCollector;
    function CollectorSchemaKept: Boolean;
    function Save(const ACoverage: string): Boolean;
    function SearchBase: Boolean;
    function CoverageLabel: string;
  protected
    procedure OnEntries(AMsg: TEntriesMsg); override;
    procedure OnFailed(AMsg: TTaskFailedMsg); override;
    procedure OnStale(AMsg: TUiMessage); override;
    procedure OnOther(AMsg: TUiMessage); override;
    function AcceptsForeign(AMsg: TUiMessage): Boolean; override;
  public
    // AEntry est copiee: l'entree de l'arbre peut disparaitre en plein export.
    constructor CreateExport(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
      AEntry: TLdapEntry);
    constructor CreateExportMany(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
      const ADns: TStringArray);
    destructor Destroy; override;
    procedure SetFileName(const APath: string);
    procedure SetOptions(AChildren, AExclude: Boolean);
    procedure StartExport;
    function SaveTask: Int64;
    function StatusText: string;
    property AutoAnswer: TModalResult read FAutoAnswer write FAutoAnswer;
    property MaxEntries: Integer read FMaxEntries write FMaxEntries;
  end;

function ShowLdifExport(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
  AEntry: TLdapEntry): Boolean;
function ShowLdifExportMany(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
  const ADns: TStringArray): Boolean;

implementation

uses
  uUiKit, uTheme, uSearchModel, uValueFile, uLdifExportWork, uRtMessage, uVersion,
  uCancel, uLdapDn, uPasswordWork, uDirectoryService, LazFileUtils;

var
  GIncludeChildren: Boolean = False;
  GExcludeManaged: Boolean = True;
  GLastDir: string = '';

// Nom propose depuis le RDN, caracteres interdits remplaces: un DN n'a pas a dicter un chemin.
function SuggestedName(const ADn: string): string;
var
  dn: TLdapDn;
  i: Integer;
begin
  Result := 'export';
  if DnTryParse(ADn, dn) and (DnRdnCount(dn) > 0) and (Length(DnLeaf(dn).Avas) > 0) then
    Result := string(DnLeaf(dn).Avas[0].Value);
  for i := 1 to Length(Result) do
    if Result[i] in ['\', '/', ':', '*', '?', '"', '<', '>', '|', #0..#31] then Result[i] := '_';
  if Trim(Result) = '' then Result := 'export';
  Result := Result + '.ldif';
end;

function DefaultDir: string;
begin
  if (GLastDir <> '') and DirectoryExists(GLastDir) then Exit(IncludeTrailingPathDelimiter(GLastDir));
  Result := IncludeTrailingPathDelimiter(GetUserDir);
  if DirectoryExists(Result + 'Documents') then
    Result := IncludeTrailingPathDelimiter(Result + 'Documents');
end;

constructor TLdifExportDialog.CreateExport(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid: string; AEntry: TLdapEntry);
begin
  inherited CreateFor(AOwner, ACtx, AProfileUuid, rsLxTitle, 760, 270);
  SetIcon('file-export');
  FEntry := AEntry.Clone;
  FAutoAnswer := mrNone;
  FMaxEntries := EXPORT_MAX_ENTRIES;
  MakeDataLabel(Body, Format(rsLxEntry, [FEntry.Dn]));
  FFile := MakeEditRow(Body, rsLxFile);
  FFile.Text := DefaultDir + SuggestedName(FEntry.Dn);
  FBrowseBtn := MakeButton(FFile.Parent, rsLxBrowse, @BrowseClick, alRight);
  FChildren := MakeCheck(Body, rsLxChildren);
  FChildren.Checked := GIncludeChildren;
  FExclude := MakeCheck(Body, rsLxExclude);
  FExclude.Checked := GExcludeManaged;
  FExportBtn := AddButton(rsLxExport, mrNone, True);
  FExportBtn.OnClick := @ExportClick;
  AddButton(rsLxCancel, mrCancel, False, True);
  OnCloseQuery := @CloseQueryHandler;
  ApplyTheme;
end;

constructor TLdifExportDialog.CreateExportMany(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid: string; const ADns: TStringArray);
begin
  inherited CreateFor(AOwner, ACtx, AProfileUuid, rsLxTitle, 760, 270);
  SetIcon('file-export');
  FDns := Copy(ADns);
  FAutoAnswer := mrNone;
  FMaxEntries := EXPORT_MAX_ENTRIES;
  if Length(FDns) > 0 then
    MakeDataLabel(Body, Format(rsLxSelection, [Length(FDns), FDns[0]]));
  FFile := MakeEditRow(Body, rsLxFile);
  FFile.Text := DefaultDir + SuggestedName('');
  FBrowseBtn := MakeButton(FFile.Parent, rsLxBrowse, @BrowseClick, alRight);
  FChildren := MakeCheck(Body, rsLxChildren);
  FChildren.Checked := GIncludeChildren;
  FExclude := MakeCheck(Body, rsLxExclude);
  FExclude.Checked := GExcludeManaged;
  FExportBtn := AddButton(rsLxExport, mrNone, True);
  FExportBtn.OnClick := @ExportClick;
  AddButton(rsLxCancel, mrCancel, False, True);
  OnCloseQuery := @CloseQueryHandler;
  ApplyTheme;
end;

destructor TLdifExportDialog.Destroy;
begin
  // Ecriture en cours annulee: le fichier precedent reste en place.
  if FSaveTask <> 0 then PasswordWork.CancelOwner(Self);
  FCollector.Free;
  FSeen.Free;
  FEntry.Free;
  inherited Destroy;
end;

function TLdifExportDialog.Ask(const AText: string; AType: TMsgDlgType): TModalResult;
begin
  if FAutoAnswer <> mrNone then Exit(FAutoAnswer);
  Result := RtMessageDlg(rsLxTitle, AText, AType, [mbYes, mbNo], 0);
end;

procedure TLdifExportDialog.SetFileName(const APath: string);
begin
  FFile.Text := APath;
end;

procedure TLdifExportDialog.SetOptions(AChildren, AExclude: Boolean);
begin
  FChildren.Checked := AChildren;
  FExclude.Checked := AExclude;
end;

function TLdifExportDialog.SaveTask: Int64;
begin
  Result := FSaveTask;
end;

function TLdifExportDialog.StatusText: string;
begin
  Result := FStatus.Caption;
end;

procedure TLdifExportDialog.BrowseClick(Sender: TObject);
var
  sd: TSaveDialog;
begin
  sd := TSaveDialog.Create(Self);
  try
    sd.Filter := 'LDIF (*.ldif)|*.ldif|All files|*.*';
    sd.DefaultExt := 'ldif';
    sd.InitialDir := ExtractFilePath(FFile.Text);
    sd.FileName := ExtractFileName(FFile.Text);
    // L'ecrasement est confirme a l'export, pour couvrir aussi un chemin tape a la main.
    if sd.Execute then FFile.Text := sd.FileName;
  finally
    sd.Free;
  end;
end;

procedure TLdifExportDialog.SetRunning(ARunning: Boolean);
begin
  FFile.Enabled := not ARunning;
  FBrowseBtn.Enabled := not ARunning;
  FChildren.Enabled := not ARunning;
  FExclude.Enabled := not ARunning;
  FExportBtn.Enabled := not ARunning;
end;

function TLdifExportDialog.NewCollector: TLdifExportCollector;
var
  c: TDirectoryConnection;
begin
  c := Conn;
  FCollectorStamp := Default(TSessionStamp);
  if (c = nil) or not FExclude.Checked then
    Result := TLdifExportCollector.Create(nil, FExclude.Checked)
  else
  begin
    FCollectorStamp := c.Stamp;
    Result := TLdifExportCollector.Create(c.Schema, True);
  end;
  Result.MaxEntries := FMaxEntries;
end;

function TLdifExportDialog.CollectorSchemaKept: Boolean;
begin
  // Un schema relu libere l'ancien: le collecteur ne doit plus y toucher, sauf a lire dans le vide.
  Result := (FCollectorStamp.SessionId = '') or
    (FCtx.Connections.FindSame(FCollectorStamp) <> nil);
end;

// Entree affichee incomplete (decodage borne, plage AD inachevee): jamais exportee comme complete
// sans accord. Chaine vide si elle est complete.
function EntryCoverageProblem(AEntry: TLdapEntry): string;
begin
  Result := '';
  if AEntry.DecodeIncomplete then Result := rsLxEntryIncomplete;
  if AEntry.AnyTruncated then
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + rsLxEntryTruncated;
  end;
end;

procedure TLdifExportDialog.ExportClick(Sender: TObject);
begin
  StartExport;
end;

procedure TLdifExportDialog.StartExport;
var
  path, problem: string;
  rules: TDnCaseRules;
begin
  if Tasks.Pending('export') then Exit;
  path := Trim(FFile.Text);
  if (path = '') or (ExtractFileName(path) = '') or not FilenameIsAbsolute(path) then
  begin
    SetStatus(rsLxNoFile, usError);
    Exit;
  end;
  problem := ValueFilePathProblem(path);
  if problem <> '' then
  begin
    SetStatus(Format(rsLxWriteFailed, [problem]), usError);
    Exit;
  end;
  if FileExists(path) and (Ask(Format(rsLxOverwrite, [path]), mtConfirmation) <> mrYes) then
    Exit;
  // Seule cette destination, validee et confirmee, a le droit d'etre ecrasee.
  FDest := path;
  GIncludeChildren := FChildren.Checked;
  GExcludeManaged := FExclude.Checked;
  FreeAndNil(FCollector);
  FCollector := NewCollector;
  if (FEntry <> nil) and not FChildren.Checked then
  begin
    problem := EntryCoverageProblem(FEntry);
    FCollector.Add(FEntry);
    if problem <> '' then
    begin
      if Ask(Format(rsLxEntryPartial, [problem]), mtWarning) <> mrYes then
      begin
        SetStatus(rsLxPartialNotSaved, usWarning);
        Exit;
      end;
      Save(Format('entry %s, PARTIAL: %s', [FEntry.Dn, problem]));
      Exit;
    end;
    Save('entry ' + FEntry.Dn);
    Exit;
  end;
  // Une recherche par base; une base couverte par une autre n'est pas relue.
  if FEntry <> nil then
  begin
    SetLength(FBases, 1);
    FBases[0] := FEntry.Dn;
  end
  else if FChildren.Checked then
  begin
    rules := TDnCaseRules.Create(Conn);
    try
      FBases := DnOutermost(FDns, @rules.Folds, @rules.Canon);
    finally
      rules.Free;
    end;
  end
  else
    FBases := Copy(FDns);
  if Length(FBases) = 0 then Exit;
  FBaseIndex := 0;
  FPartial := '';
  FreeAndNil(FSeen);
  FSeen := TStringList.Create;
  FSeen.CaseSensitive := True;
  FSeen.Sorted := True;
  if not SearchBase then Exit;
  SetRunning(True);
  SetStatus(Format(rsLxReading, [0]), usMuted);
end;

function TLdifExportDialog.SearchBase: Boolean;
var
  req: TSearchRequest;
begin
  FBaseGot := 0;
  req := DefaultSearchRequest;
  req.BaseDn := FBases[FBaseIndex];
  if FChildren.Checked then req.Scope := ssSubtree else req.Scope := ssBase;
  req.Filter := '(objectClass=*)';
  req.Attributes := ['*', '+'];
  req.SizeLimit := 0;
  req.TimeLimitSec := 0;
  Result := Search(req, 'export') <> 0;
end;

function TLdifExportDialog.CoverageLabel: string;
begin
  if FEntry <> nil then
    Result := 'subtree of ' + FEntry.Dn
  else if FChildren.Checked then
    Result := Format('subtrees of %d selected entries', [Length(FDns)])
  else
    Result := Format('%d selected entries', [Length(FDns)]);
end;

procedure TLdifExportDialog.OnEntries(AMsg: TEntriesMsg);
var
  i: Integer;
  outcome: TSearchOutcome;
  reason: string;
begin
  if (Tasks.Current.Tag <> 'export') or (FCollector = nil) then Exit;
  if not CollectorSchemaKept then
  begin
    Tasks.Cancel('export');
    SetRunning(False);
    FreeAndNil(FCollector);
    SetStatus(rsLxSchemaChanged, usError);
    FCtx.Log(mlError, rsLxTitle, StatusText);
    Exit;
  end;
  if AMsg.Entries <> nil then
    for i := 0 to AMsg.Entries.Count - 1 do
    begin
      Inc(FBaseGot);
      // Bases qui se recouvrent malgre l'elagage: une entree n'est ecrite qu'une fois.
      if FSeen <> nil then
      begin
        if FSeen.IndexOf(TLdapEntry(AMsg.Entries[i]).Dn) >= 0 then Continue;
        FSeen.Add(TLdapEntry(AMsg.Entries[i]).Dn);
      end;
      if not FCollector.Add(TLdapEntry(AMsg.Entries[i])) then
      begin
        // Budget depasse: la recherche s'arrete et rien n'est ecrit.
        Tasks.Cancel('export');
        SetRunning(False);
        SetStatus(Format(rsLxTooLarge, [FCollector.MaxEntries, EXPORT_MAX_BYTES div (1024 * 1024)]), usError);
        FCtx.Log(mlError, rsLxTitle, StatusText);
        Exit;
      end;
    end;
  if not AMsg.Final then
  begin
    SetStatus(Format(rsLxReading, [FCollector.Count]), usMuted);
    Exit;
  end;
  outcome := SearchOutcome(AMsg.Completion);
  reason := CoverageDescription(srsDone, AMsg.Completion);
  if outcome = soCancelled then
  begin
    SetRunning(False);
    Exit;
  end;
  if outcome = soFailed then
  begin
    SetRunning(False);
    if FEntry <> nil then
      SetStatus(Format(rsLxSearchFailed, [reason]), usError)
    else
      SetStatus(Format(rsLxBaseFailed, [FBases[FBaseIndex], reason]), usError);
    FCtx.Log(mlError, rsLxTitle, StatusText);
    Exit;
  end;
  if outcome = soPartial then
  begin
    if FPartial <> '' then FPartial := FPartial + '; ';
    if FEntry <> nil then FPartial := FPartial + reason
    else FPartial := FPartial + FBases[FBaseIndex] + ': ' + reason;
  end
  else if (FEntry = nil) and (FBaseGot = 0) then
  begin
    // Reussie mais vide (entree disparue, ACL): un trou silencieux, l'export devient partiel.
    if FPartial <> '' then FPartial := FPartial + '; ';
    FPartial := FPartial + FBases[FBaseIndex] + ': no entry returned';
  end;
  if FBaseIndex < High(FBases) then
  begin
    Inc(FBaseIndex);
    if not SearchBase then
    begin
      SetRunning(False);
      SetStatus(Format(rsLxBaseFailed, [FBases[FBaseIndex], rsLxNotConnected]), usError);
      FCtx.Log(mlError, rsLxTitle, StatusText);
    end;
    Exit;
  end;
  SetRunning(False);
  if FCollector.Count = 0 then
  begin
    SetStatus(Format(rsLxSearchFailed, [reason]), usError);
    FCtx.Log(mlError, rsLxTitle, StatusText);
    Exit;
  end;
  if FPartial <> '' then
  begin
    // Jamais de fichier incomplet sans accord explicite: une sauvegarde trouee ne se remarque qu'a la
    // restauration.
    if Ask(Format(rsLxPartial, [FCollector.Count, FPartial]), mtWarning) <> mrYes then
    begin
      SetStatus(rsLxPartialNotSaved, usWarning);
      Exit;
    end;
    Save(Format('%s, PARTIAL: %s', [CoverageLabel, FPartial]));
    Exit;
  end;
  Save(Format('%s, %s', [CoverageLabel, reason]));
end;

procedure TLdifExportDialog.OnFailed(AMsg: TTaskFailedMsg);
begin
  if Tasks.Current.Tag <> 'export' then Exit;
  SetRunning(False);
  SetStatus(Format(rsLxSearchFailed, [AMsg.Text]), usError);
  FCtx.Log(mlError, rsLxTitle, StatusText);
end;

procedure TLdifExportDialog.OnStale(AMsg: TUiMessage);
begin
  // Session remplacee pendant la lecture: rien n'est ecrit, et le dialogue ne reste pas fige.
  inherited OnStale(AMsg);
  if Tasks.Current.Tag <> 'export' then Exit;
  SetRunning(False);
  FreeAndNil(FCollector);
  FCtx.Log(mlError, rsLxTitle, StatusText);
end;

function TLdifExportDialog.Save(const ACoverage: string): Boolean;
var
  path, omitted, stamp: string;
begin
  Result := False;
  if (FCollector = nil) or (FSaveTask <> 0) then Exit;
  // Jamais le champ relu: on ecrit la ou l'operateur a confirme, pas la ou le champ pointe maintenant.
  path := FDest;
  omitted := FCollector.StrippedNames;
  FSavedCount := FCollector.Count;
  stamp := Format('%s %s export, %s UTC', [RT_APP_NAME, RT_VERSION, FormatUtcIso(UtcNow)]);
  // Le collecteur, fige, part avec le fil d'ecriture: entree par entree dans un temporaire, sans
  // seconde copie, et l'interface ne gele pas sur un disque lent.
  if omitted <> '' then
    FSaveTask := StartLdifSave(path, FCollector, [stamp, Format(rsLxCoverage, [ACoverage]),
      Format(rsLxOmitted, [omitted])], Self)
  else
    FSaveTask := StartLdifSave(path, FCollector, [stamp, Format(rsLxCoverage, [ACoverage])], Self);
  FCollector := nil;
  if FSaveTask = 0 then
  begin
    SetStatus(rsLxTaskBusy, usError);
    FCtx.Log(mlError, rsLxTitle, StatusText);
    Exit;
  end;
  SetRunning(True);
  SetStatus(Format(rsLxWriting, [FSavedCount, path]), usMuted);
  Result := True;
end;

function TLdifExportDialog.AcceptsForeign(AMsg: TUiMessage): Boolean;
begin
  Result := (AMsg is TValueFileMsg) and (FSaveTask <> 0) and (AMsg.TaskId = FSaveTask);
end;

procedure TLdifExportDialog.OnOther(AMsg: TUiMessage);
var
  f: TValueFileMsg;
begin
  if not (AMsg is TValueFileMsg) or (FSaveTask = 0) or (AMsg.TaskId <> FSaveTask) then Exit;
  f := TValueFileMsg(AMsg);
  FSaveTask := 0;
  SetRunning(False);
  if not f.Ok then
  begin
    if f.Cancelled then
      SetStatus(Format(rsLxWriteCancelled, [f.Path]), usWarning)
    else
      SetStatus(Format(rsLxWriteFailed, [f.ErrorText]), usError);
    FCtx.Log(mlError, rsLxTitle, StatusText);
    Exit;
  end;
  GLastDir := ExtractFilePath(f.Path);
  SetStatus(Format(rsLxDone, [FSavedCount, f.Path]), usOk);
  FCtx.Log(mlInfo, rsLxTitle, StatusText);
  ModalResult := mrOk;
end;

procedure TLdifExportDialog.CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
begin
  // Fermeture pendant la lecture: recherche annulee, rien n'est ecrit.
  Tasks.Cancel('export');
  // Fermeture pendant l'ecriture: le temporaire est abandonne, le fichier precedent reste, et
  // personne n'annonce de succes.
  if (FSaveTask <> 0) and (ModalResult <> mrOk) then
  begin
    PasswordWork.CancelOwner(Self);
    FSaveTask := 0;
  end;
  CanClose := True;
end;

function ShowLdifExport(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
  AEntry: TLdapEntry): Boolean;
var
  d: TLdifExportDialog;
begin
  Result := False;
  if AEntry = nil then Exit;
  d := TLdifExportDialog.CreateExport(AOwner, ACtx, AProfileUuid, AEntry);
  try
    Result := d.ShowModal = mrOk;
  finally
    d.Free;
  end;
end;

function ShowLdifExportMany(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
  const ADns: TStringArray): Boolean;
var
  d: TLdifExportDialog;
begin
  Result := False;
  if Length(ADns) = 0 then Exit;
  d := TLdifExportDialog.CreateExportMany(AOwner, ACtx, AProfileUuid, ADns);
  try
    Result := d.ShowModal = mrOk;
  finally
    d.Free;
  end;
end;

end.
