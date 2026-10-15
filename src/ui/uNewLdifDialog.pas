// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uNewLdifDialog;

{$mode objfpc}{$H+}

// Nouveau fichier LDIF: un annuaire hors ligne, avec le schema de sa cible a cote. On y prepare
// la rentree au calme, on relit, puis on importe. Le fichier ne contient que des donnees.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs, uUiKit, uAppContext, uRtCombo, uRtCheck;

type
  TNewLdifDialog = class(TRtDialog)
  private
    FCtx: TAppContext;
    FKind, FSource: TRtComboBox;
    FSourceKeys: TStringList;
    FContainer, FFile: TEdit;
    FCreateIt: TRtCheckBox;
    FStatus: TLabel;
    FContainerTouched, FFilling: Boolean;
    FCreatedPath: string;
    procedure FillSources;
    procedure KindChange(Sender: TObject);
    procedure SourceChange(Sender: TObject);
    procedure ContainerChange(Sender: TObject);
    procedure BrowseClick(Sender: TObject);
    procedure CreateClick(Sender: TObject);
    function ActiveDirectory: Boolean;
  public
    constructor CreateNew(AOwner: TComponent; ACtx: TAppContext);
    destructor Destroy; override;
    // essais
    procedure SetChoices(AAd: Boolean; const ASourceKey, AContainer: string; ACreateIt: Boolean;
      const APath: string);
    procedure Submit;
    function StatusText: string;
    function SourceKeys: string;
    property CreatedPath: string read FCreatedPath;
  end;

// Chemin du fichier cree, vide si abandon.
function ShowNewLdif(AOwner: TComponent; ACtx: TAppContext): string;

const
  NEW_LDIF_STANDARD = 'standard';

resourcestring
  rsNlTitle = 'New LDIF file';
  rsNlIntro = 'An LDIF file worked on like a directory: entries, templates and CSV batches go in, ' +
    'nothing reaches a server until the file is imported. The schema of the target is kept next to ' +
    'it, in a .rtschema file that is never imported.';
  rsNlKind = 'Directory';
  rsNlKindLdap = 'LDAP (OpenLDAP, 389 DS, ApacheDS...)';
  rsNlKindAd = 'Active Directory';
  rsNlSource = 'Schema from';
  rsNlStandard = 'Standard LDAP schema (built in: core, cosine, inetOrgPerson, nis)';
  rsNlNoAdSource = '(connect to an Active Directory first: its schema is too large and too local to guess)';
  rsNlContainer = 'Container';
  rsNlContainerHint = 'e.g. ou=People,dc=example,dc=com';
  rsNlCreateIt = 'Create this container in the file (otherwise it already exists in the target)';
  rsNlFile = 'File';
  rsNlBrowse = 'Browse...';
  rsNlCreate = 'Create';
  rsNlCancel = 'Cancel';
  rsNlNoContainer = 'Give the container the entries will go under.';
  rsNlBadContainer = 'The container is not a DN: %s';
  rsNlNoFile = 'Choose where to save the file.';
  rsNlNoSource = 'Choose where the schema comes from.';
  rsNlSourceGone = 'The connection the schema came from is closed.';
  rsNlInUse = '%s is open in another tab: close it first.';
  rsNlOverwrite = '%s already exists. Replace it with an empty file?';
  rsNlWriteFailed = 'The file could not be written: %s';
  rsNlAdNoPassword = 'Active Directory passwords are not written into the file: accounts are created ' +
    'disabled, to be given a password and enabled after the import.';

implementation

uses
  uConnections, uConnectionProfile, uLdapSchema, uLdapEntry, uLdapDn, uLdif, uLdifMeta, uSchemaFiles,
  uServerKind, uFilePublish, uRtMessage, uStrings;

function DefaultDir: string;
begin
  Result := IncludeTrailingPathDelimiter(GetUserDir);
  if DirectoryExists(Result + 'Documents') then
    Result := IncludeTrailingPathDelimiter(Result + 'Documents');
end;

function ShowNewLdif(AOwner: TComponent; ACtx: TAppContext): string;
var
  d: TNewLdifDialog;
begin
  d := TNewLdifDialog.CreateNew(AOwner, ACtx);
  try
    d.ShowModal;
    Result := d.CreatedPath;
  finally
    d.Free;
  end;
end;

constructor TNewLdifDialog.CreateNew(AOwner: TComponent; ACtx: TAppContext);
var
  row: TPanel;
begin
  inherited CreateDialog(AOwner, rsNlTitle, 760, 380);
  SetIcon('file-plus');
  FCtx := ACtx;
  FSourceKeys := TStringList.Create;
  MakeLabel(Body, rsNlIntro).WordWrap := True;
  FKind := MakeComboRow(Body, rsNlKind, [rsNlKindLdap, rsNlKindAd]);
  FKind.ItemIndex := 0;
  FKind.OnChange := @KindChange;
  FSource := MakeComboRow(Body, rsNlSource, []);
  FSource.OnChange := @SourceChange;
  FContainer := MakeEditRow(Body, rsNlContainer);
  FContainer.TextHint := rsNlContainerHint;
  FContainer.OnChange := @ContainerChange;
  FCreateIt := MakeCheck(Body, rsNlCreateIt);
  FFile := MakeEditRow(Body, rsNlFile);
  FFile.Text := DefaultDir + 'new.ldif';
  row := TPanel(FFile.Parent);
  MakeButton(row, rsNlBrowse, @BrowseClick, alRight);
  FStatus := MakeLabel(Body, '');
  FStatus.WordWrap := True;
  AddButton(rsNlCreate, mrNone, True).OnClick := @CreateClick;
  AddButton(rsNlCancel, mrCancel, False, True);
  FillSources;
  ApplyTheme;
end;

destructor TNewLdifDialog.Destroy;
begin
  FSourceKeys.Free;
  inherited Destroy;
end;

function TNewLdifDialog.ActiveDirectory: Boolean;
begin
  Result := FKind.ItemIndex = 1;
end;

procedure TNewLdifDialog.FillSources;
var
  i: Integer;
  c: TDirectoryConnection;
  ad: Boolean;
begin
  FFilling := True;
  try
    FSource.Items.Clear;
    FSourceKeys.Clear;
    for i := 0 to FCtx.Connections.Count - 1 do
    begin
      c := FCtx.Connections.Item(i);
      if not c.IsReady or (c.Schema = nil) then Continue;
      ad := EffectiveServerKind(c.Profile, c.RootDse) = pkActiveDirectory;
      if ad <> ActiveDirectory then Continue;
      FSource.Items.Add(c.Profile.Name + '  -  ' + c.Profile.DisplayEndpoint);
      FSourceKeys.Add(c.Profile.Uuid);
    end;
    if not ActiveDirectory then
    begin
      FSource.Items.Add(rsNlStandard);
      FSourceKeys.Add(NEW_LDIF_STANDARD);
    end
    else if FSourceKeys.Count = 0 then
    begin
      FSource.Items.Add(rsNlNoAdSource);
      FSourceKeys.Add('');
    end;
    FSource.ItemIndex := 0;
  finally
    FFilling := False;
  end;
  SourceChange(nil);
end;

procedure TNewLdifDialog.KindChange(Sender: TObject);
begin
  FillSources;
  if ActiveDirectory then FStatus.Caption := rsNlAdNoPassword else FStatus.Caption := '';
end;

procedure TNewLdifDialog.SourceChange(Sender: TObject);
var
  c: TDirectoryConnection;
  nc: string;
begin
  if FFilling or FContainerTouched or (FSource.ItemIndex < 0) then Exit;
  c := FCtx.Connections.Find(FSourceKeys[FSource.ItemIndex]);
  nc := '';
  // La base de la source, a completer: on part rarement de la racine du domaine.
  if (c <> nil) and (c.RootDse <> nil) then
  begin
    nc := c.RootDse.FirstValue('defaultNamingContext', '');
    if nc = '' then nc := c.RootDse.FirstValue('namingContexts', '');
  end;
  FFilling := True;
  try
    FContainer.Text := nc;
  finally
    FFilling := False;
  end;
end;

procedure TNewLdifDialog.ContainerChange(Sender: TObject);
begin
  if not FFilling then FContainerTouched := True;
end;

procedure TNewLdifDialog.BrowseClick(Sender: TObject);
var
  sd: TSaveDialog;
begin
  sd := TSaveDialog.Create(Self);
  try
    sd.Filter := rsLdifFileFilter;
    sd.DefaultExt := 'ldif';
    sd.FileName := FFile.Text;
    sd.Options := sd.Options + [ofOverwritePrompt];
    if sd.Execute then FFile.Text := sd.FileName;
  finally
    sd.Free;
  end;
end;

procedure TNewLdifDialog.CreateClick(Sender: TObject);
var
  path, dnText, err, key, report: string;
  d: TLdapDn;
  c: TDirectoryConnection;
  schema, owned: TSchemaSnapshot;
  container, meta: TLdapEntry;
  info: TLdifMeta;
  ms: TStringStream;
  w: TLdifWriter;
  content: RawByteString;
begin
  FStatus.Caption := '';
  dnText := Trim(FContainer.Text);
  path := Trim(FFile.Text);
  if dnText = '' then
  begin
    FStatus.Caption := rsNlNoContainer;
    Exit;
  end;
  if not DnParse(dnText, d, err) or (DnRdnCount(d) = 0) then
  begin
    FStatus.Caption := Format(rsNlBadContainer, [err]);
    Exit;
  end;
  if path = '' then
  begin
    FStatus.Caption := rsNlNoFile;
    Exit;
  end;
  path := ExpandFileName(path);
  if ExtractFileExt(path) = '' then path := path + '.ldif';
  if (FSource.ItemIndex < 0) or (FSourceKeys[FSource.ItemIndex] = '') then
  begin
    FStatus.Caption := rsNlNoSource;
    Exit;
  end;
  c := FCtx.Connections.LdifPathInUse(path, nil);
  if c <> nil then
  begin
    FStatus.Caption := Format(rsNlInUse, [ExtractFileName(path)]);
    Exit;
  end;
  if FileExists(path) and (RtMessageDlg(rsNlTitle, Format(rsNlOverwrite, [path]), mtWarning,
     [mbYes, mbNo], 0) <> mrYes) then Exit;
  key := FSourceKeys[FSource.ItemIndex];
  owned := nil;
  if key = NEW_LDIF_STANDARD then
  begin
    owned := StandardLdapSchema(report);
    schema := owned;
  end
  else
  begin
    // le dialogue est modal, pas le reste: la connexion a pu fermer entre-temps
    c := FCtx.Connections.Find(key);
    if (c = nil) or (c.Schema = nil) then
    begin
      FStatus.Caption := rsNlSourceGone;
      Exit;
    end;
    schema := c.Schema;
  end;
  container := nil;
  meta := nil;
  try
    info := Default(TLdifMeta);
    info.ActiveDirectory := ActiveDirectory;
    if FCreateIt.Checked then
    begin
      container := NewContainerEntry(dnText, ActiveDirectory, schema, err);
      if container = nil then
      begin
        FStatus.Caption := err;
        Exit;
      end;
    end
    else
      info.Bases := [DnToString(d)];
    meta := BuildLdifMeta(schema, info);
    ms := TStringStream.Create('');
    try
      w := TLdifWriter.Create(ms);
      try
        w.WriteVersion;
        if container <> nil then w.WriteEntry(container);
      finally
        w.Free;
      end;
      content := ms.DataString;
    finally
      ms.Free;
    end;
    // Les deux ensemble ou aucun: un LDIF neuf pose sur le schema d'un ancien, c'est pire que rien.
    if not PublishFiles([PublishText(LdifMetaPath(path), LdifMetaText(meta)), PublishText(path, content)],
       [], err) then
    begin
      FStatus.Caption := Format(rsNlWriteFailed, [err]);
      Exit;
    end;
  finally
    container.Free;
    meta.Free;
    owned.Free;
  end;
  FCreatedPath := path;
  ModalResult := mrOk;
end;

procedure TNewLdifDialog.SetChoices(AAd: Boolean; const ASourceKey, AContainer: string;
  ACreateIt: Boolean; const APath: string);
var
  i: Integer;
begin
  if AAd then FKind.ItemIndex := 1 else FKind.ItemIndex := 0;
  KindChange(nil);
  i := FSourceKeys.IndexOf(ASourceKey);
  if i >= 0 then FSource.ItemIndex := i;
  FContainer.Text := AContainer;
  FCreateIt.Checked := ACreateIt;
  FFile.Text := APath;
end;

procedure TNewLdifDialog.Submit;
begin
  CreateClick(nil);
end;

function TNewLdifDialog.StatusText: string;
begin
  Result := FStatus.Caption;
end;

function TNewLdifDialog.SourceKeys: string;
begin
  Result := FSourceKeys.CommaText;
end;

end.
