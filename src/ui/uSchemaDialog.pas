// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uSchemaDialog;

{$mode objfpc}{$H+}

// Schema de la connexion: consultation et edition planifiee. L'origine exacte d'une definition
// est lue (cn=config pour OpenLDAP, cn=schema pour 389 DS); sans elle, rien n'est modifiable.
// Le plan montre avant/apres, dependances et LDIF, et ne part que si l'adaptateur sait le faire.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs, uAppContext, uUiKit, uRtList,
  uRtCombo, uRtCheck, uUiInbox, uLdapSchema, uLdapEntry, uSchemaDefinition, uSchemaChangePlan,
  uTaskTracker, uTaskDialog;

type
  TSchemaSourceEntry = record
    Dn: string;
    AttrValues: array of string;
    ClassValues: array of string;
  end;

  TSchemaBrowser = class(TTaskDialog)
  private
    FCaps: TSchemaCapabilities;
    FFilter: TEdit;
    FList: TRtListGrid;
    FKinds: array of TDefinitionKind;
    FDetail: TMemo;
    FSources: array of TSchemaSourceEntry;
    FSourcesRead: Boolean;
    FSourcesNote: string;
    FSourceValues: Integer;
    FSourceBytes: Int64;
    FExportTask: Int64;
    FEdit, FDelete, FNewAttr, FNewClass, FRefresh: TButton;
    function Schema: TSchemaSnapshot;
    procedure FilterChange(Sender: TObject);
    procedure ListSelect(Sender: TObject; AIndex: Integer);
    procedure FillList;
    procedure ShowDetail;
    procedure ReadSources;
    function WithinSourceBudget(AEntry: TLdapEntry): Boolean;
    procedure TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure LocalMessage(AMsg: TUiMessage);
    procedure DropStale(const ATag: string);
    function SelectedName(out AKind: TDefinitionKind): string;
    function SourceOf(AKind: TDefinitionKind; const AOid: string; out ASource: TSchemaSource): Boolean;
    procedure NewAttrClick(Sender: TObject);
    procedure NewClassClick(Sender: TObject);
    procedure EditClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure OpenEditor(AKind: TDefinitionKind; AOriginal: TSchemaDefinition);
    procedure AdCreate(AIsClass: Boolean);
    procedure AdDefunct(const AName: string; AKind: TDefinitionKind);
    function AdRoleOwner: string;
  public
    constructor CreateFor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string);
    function ShowPlan(APlan: TSchemaChangePlan): Boolean;
    procedure ExportPlan(APlan: TSchemaChangePlan; const APath: string);
    function StatusText: string;
    procedure SetFilter(const AText: string);
    function ItemCount: Integer;
    function ItemName(AIndex: Integer): string;
    procedure SelectItem(AIndex: Integer);
    function DetailText: string;
    procedure Refresh;
    function RefreshEnabled: Boolean;
    function SourcesComplete: Boolean;
    property Capabilities: TSchemaCapabilities read FCaps;
  end;

  TSchemaEditForm = class(TRtDialog)
  private
    FKind: TDefinitionKind;
    FOriginal: TSchemaDefinition;
    FIsNew: Boolean;
    FOid, FNames, FDesc, FSup, FSyntax, FEquality, FOrdering, FSubstr, FMust, FMay, FTarget: TEdit;
    FObsolete, FSingle, FCollective, FNoUserMod: TRtCheckBox;
    FUsage, FClassKind: TRtComboBox;
    FError: TLabel;
    function Field(const ACaption: string; const AValue: string): TEdit;
    procedure OkClick(Sender: TObject);
  public
    Definition: TSchemaDefinition;
    TargetEntry: string;
    constructor CreateFor(AOwner: TComponent; AKind: TDefinitionKind; AOriginal: TSchemaDefinition;
      AShowTarget: Boolean; const ADefaultTarget: string);
    function Build(out AError: string): Boolean;
    procedure SetText(const AField, AValue: string);
  end;

resourcestring
  rsSchemaTitle = 'Schema';
  rsSchemaFilter = 'Name, alias or OID';
  rsSchemaUnavailable = 'Schema unavailable for this connection: %s';
  rsSchemaColKind = 'Kind';
  rsSchemaColName = 'Name';
  rsSchemaColOid = 'OID';
  rsSchemaAttr = 'attribute';
  rsSchemaClass = 'class';
  rsSchemaNewAttr = 'New attribute type...';
  rsSchemaNewClass = 'New object class...';
  rsSchemaEdit = 'Edit...';
  rsSchemaDelete = 'Delete...';
  rsSchemaRefresh = 'Refresh';
  rsSchemaClose = 'Close';
  rsSchemaAdapter = 'Adapter: %s (%s)';
  rsSchemaAdapterOpenLdap = 'OpenLDAP (cn=config)';
  rsSchemaAdapter389 = '389 Directory Server (cn=schema)';
  rsSchemaAdapterAd = 'Active Directory';
  rsSchemaAdapterNone = 'consultation only';
  rsSchemaStale = 'cached schema, may be outdated';
  rsSchemaReadOnlyDef = 'Not editable: %s';
  rsSchemaSource = 'Held by: %s (%s)%s';
  rsSchemaSourceSystem = ', system definition (protected)';
  rsSchemaSourceUnknown = 'Holding entry on the server: %s';
  rsSchemaSourcesReading = 'being read';
  rsSchemaSourcesDenied = 'not readable (%s): definitions cannot be targeted';
  rsSchemaSourcesNone = 'not applicable for this adapter';
  rsSchemaDependencies = 'Known uses: %s';
  rsSchemaNoDependency = 'none in the schema';
  rsSchemaRefreshing = 'Reading the schema again...';
  rsSchemaRefreshed = 'Schema read again.';
  rsSchemaRefreshFailed = 'The schema could not be read again: %s. The previous one is kept, marked outdated.';
  rsSchemaRefreshFailedNone = 'The schema could not be read: %s.';
  rsSchemaNewerKept = 'A more recent schema was already loaded: it is kept.';
  rsSchemaSourcesSessionLost = 'not read: the connection changed during the reading; refresh to read them again';
  rsSchemaSourcesTooLarge = 'incomplete: the reading stopped at its limit (%s); definitions cannot be targeted';
  rsSchemaPlanTitle = 'Schema change plan';
  rsSchemaPlanOp = '# %s of %s on %s';
  rsSchemaPlanCreate = 'creation';
  rsSchemaPlanModify = 'modification';
  rsSchemaPlanDelete = 'deletion';
  rsSchemaPlanBefore = '# before';
  rsSchemaPlanAfter = '# after';
  rsSchemaPlanChecks = '# checks';
  rsSchemaPlanDeps = '# known uses (%s)';
  rsSchemaPlanLdif = '# exact change (LDIF)';
  rsSchemaPlanNotSent = 'Not sent: %s';
  rsSchemaPlanNoLdif = '(no change can be built)';
  rsSchemaExport = 'Export LDIF...';
  rsSchemaApply = 'Apply';
  rsSchemaExportNote = 'This export is not a backup of the server and gives no rollback.';
  rsSchemaExported = 'Plan exported to %s.';
  rsSchemaExportFailed = 'The plan was not exported: %s';
  rsSchemaDeleteConfirm = 'Plan the deletion of %s?';
  rsSchemaFieldOid = 'OID (from the arc your organization administers)';
  rsSchemaFieldNames = 'Names (space separated)';
  rsSchemaFieldDesc = 'Description';
  rsSchemaFieldSup = 'Superior';
  rsSchemaFieldSups = 'Superior classes (space separated)';
  rsSchemaFieldSyntax = 'Syntax OID {length}';
  rsSchemaFieldEquality = 'Equality rule';
  rsSchemaFieldOrdering = 'Ordering rule';
  rsSchemaFieldSubstr = 'Substring rule';
  rsSchemaFieldMust = 'Required attributes (space separated)';
  rsSchemaFieldMay = 'Allowed attributes (space separated)';
  rsSchemaFieldTarget = 'Schema entry (OpenLDAP)';
  rsSchemaFieldUsage = 'Usage';
  rsSchemaFieldKind = 'Kind';
  rsSchemaObsolete = 'Obsolete';
  rsSchemaSingle = 'Single-valued';
  rsSchemaCollective = 'Collective';
  rsSchemaNoUserMod = 'Not user-modifiable (set by the server only)';
  rsSchemaExtensionsKept = 'Extensions and fields not shown here are kept as they are.';
  rsSchemaNewTitle = 'New %s';
  rsSchemaFieldCn = 'Common name (cn)';
  rsSchemaFieldLdapName = 'lDAPDisplayName';
  rsSchemaFieldPossSup = 'Possible superiors (space separated)';
  rsSchemaFieldRange = 'Upper bound (rangeUpper, optional)';
  rsSchemaDeactivate = 'Deactivate...';
  rsSchemaAdEditUnavailable = 'Changing the properties of an Active Directory schema object is not available in this version.';
  rsSchemaEditTitle = 'Edit %s';

procedure ShowSchemaBrowser(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string);

const
  // Budget de lecture des origines OpenLDAP: une installation chargee tient en quelques
  // dizaines d'entrees et quelques milliers de definitions. Un serveur compromis n'epuisera pas
  // la memoire pour autant.
  SCHEMA_SOURCES_MAX_ENTRIES = 1000;
  SCHEMA_SOURCES_MAX_VALUES = 50000;
  SCHEMA_SOURCES_MAX_BYTES = 32 * 1024 * 1024;
  SOURCE_VALUE_OVERHEAD = 32;

implementation

uses
  uTheme, uRtMessage, uConnections, uDirectoryWorker, uSearchModel, uServerKind,
  uValueFile, uAdSchemaPlan;

function SplitWords(const S: string): TStringArray;
var
  parts: TStringArray;
  i: Integer;
begin
  Result := nil;
  parts := StringReplace(Trim(S), #9, ' ', [rfReplaceAll]).Split([' ']);
  for i := 0 to High(parts) do
    if parts[i] <> '' then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := parts[i];
    end;
end;

procedure ShowSchemaBrowser(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string);
var
  c: TDirectoryConnection;
  d: TSchemaBrowser;
begin
  c := ACtx.Connections.Find(AProfileUuid);
  if c = nil then Exit;
  if c.Schema = nil then
  begin
    RtMessageDlg(rsSchemaTitle, Format(rsSchemaUnavailable, [c.SchemaReason]), mtInformation, [mbOK], 0);
    Exit;
  end;
  d := TSchemaBrowser.CreateFor(AOwner, ACtx, AProfileUuid);
  try
    d.ShowModal;
  finally
    d.Free;
  end;
end;

constructor TSchemaBrowser.CreateFor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string);
var
  c: TDirectoryConnection;
  row, bar, listPanel: TPanel;
  adapter: string;
begin
  inherited CreateDialog(AOwner, rsSchemaTitle, 1000, 680);
  SetIcon('schema');
  InitTasks(ACtx, AProfileUuid);
  c := FCtx.Connections.Find(AProfileUuid);
  if c <> nil then
  begin
    SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
    FCaps := DetectSchemaCapabilities(EffectiveServerKind(c.Profile, c.RootDse), c.RootDse);
  end;
  case FCaps.Adapter of
    sakOpenLdapConfig: adapter := rsSchemaAdapterOpenLdap;
    sak389Ds: adapter := rsSchemaAdapter389;
    sakActiveDirectory: adapter := rsSchemaAdapterAd;
  else
    adapter := rsSchemaAdapterNone;
  end;
  FStatus := MakeLabel(Body, Format(rsSchemaAdapter, [adapter, FCaps.Reason[soCreate]]));
  FStatus.WordWrap := True;
  row := MakeFieldRow(Body, rsSchemaFilter, 160);
  FFilter := MakeEdit(row, alClient);
  FFilter.OnChange := @FilterChange;
  bar := MakePanel(Body, alTop, 38);
  FNewAttr := MakeButton(bar, rsSchemaNewAttr, @NewAttrClick);
  FNewClass := MakeButton(bar, rsSchemaNewClass, @NewClassClick);
  FEdit := MakeButton(bar, rsSchemaEdit, @EditClick);
  if FCaps.Adapter = sakActiveDirectory then
    FDelete := MakeButton(bar, rsSchemaDeactivate, @DeleteClick)
  else
    FDelete := MakeButton(bar, rsSchemaDelete, @DeleteClick);
  FRefresh := MakeButton(bar, rsSchemaRefresh, @RefreshClick);
  listPanel := MakePanel(Body, alLeft, 400);
  FList := TRtListGrid.Create(listPanel);
  FList.Parent := listPanel;
  FList.Align := alClient;
  FList.FillWidth := True;
  FList.AddColumn(rsSchemaColKind, 95);
  FList.AddColumn(rsSchemaColName, 170);
  FList.AddColumn(rsSchemaColOid, 150);
  FList.OnSelectRow := @ListSelect;
  FDetail := MakeMemo(Body);
  FDetail.ReadOnly := True;
  FDetail.WordWrap := True;
  AddButton(rsSchemaClose, mrClose, True, True);
  ApplyTheme;
  FDetail.Color := clEditorBg;
  FDetail.Font.Color := clEditorFg;
  StyleMemo(FDetail);
  Tasks.OnMessage := @TaskMessage;
  Tasks.OnUntracked := @LocalMessage;
  FillList;
  ReadSources;
end;

function TSchemaBrowser.Schema: TSchemaSnapshot;
var
  c: TDirectoryConnection;
begin
  // Retrouve a chaque usage: un rafraichissement libere l'ancien schema, et un pointeur garde
  // viserait un cadavre.
  c := FCtx.Connections.Find(FProfileUuid);
  if c = nil then Result := nil else Result := c.Schema;
end;

function TSchemaBrowser.StatusText: string;
begin
  Result := FStatus.Caption;
end;

procedure TSchemaBrowser.SetFilter(const AText: string);
begin
  FFilter.Text := AText;
  FillList;
end;

function TSchemaBrowser.ItemCount: Integer;
begin
  Result := FList.Count;
end;

function TSchemaBrowser.ItemName(AIndex: Integer): string;
begin
  Result := FList.CellText(AIndex, 1);
end;

procedure TSchemaBrowser.SelectItem(AIndex: Integer);
begin
  FList.ItemIndex := AIndex;
  ShowDetail;
end;

function TSchemaBrowser.DetailText: string;
begin
  Result := FDetail.Text;
end;

procedure TSchemaBrowser.FilterChange(Sender: TObject);
begin
  FillList;
end;

procedure TSchemaBrowser.FillList;
var
  s: TSchemaSnapshot;
  sug: TSchemaSuggestionArray;
  i: Integer;
begin
  FList.Clear;
  FKinds := nil;
  s := Schema;
  if s = nil then Exit;
  sug := s.SuggestAttributes(Trim(FFilter.Text), [], 3000);
  for i := 0 to High(sug) do
  begin
    FList.AddRow([rsSchemaAttr, sug[i].Name, sug[i].Oid]);
    SetLength(FKinds, Length(FKinds) + 1);
    FKinds[High(FKinds)] := dkAttribute;
  end;
  sug := s.SuggestObjectClasses(Trim(FFilter.Text), 3000);
  for i := 0 to High(sug) do
  begin
    FList.AddRow([rsSchemaClass, sug[i].Name, sug[i].Oid]);
    SetLength(FKinds, Length(FKinds) + 1);
    FKinds[High(FKinds)] := dkClass;
  end;
  FDetail.Clear;
end;

function TSchemaBrowser.SelectedName(out AKind: TDefinitionKind): string;
var
  i: Integer;
begin
  Result := '';
  AKind := dkAttribute;
  i := FList.ItemIndex;
  if (i < 0) or (i > High(FKinds)) then Exit;
  AKind := FKinds[i];
  Result := FList.CellText(i, 2);
end;

procedure TSchemaBrowser.ListSelect(Sender: TObject; AIndex: Integer);
begin
  ShowDetail;
end;

function TSchemaBrowser.SourceOf(AKind: TDefinitionKind; const AOid: string;
  out ASource: TSchemaSource): Boolean;
var
  s: TSchemaSnapshot;
  i: Integer;
  values: array of string;
begin
  ASource := Default(TSchemaSource);
  Result := False;
  case FCaps.Adapter of
    sak389Ds:
      begin
        s := Schema;
        if s = nil then Exit;
        values := nil;
        if AKind = dkAttribute then
          for i := 0 to s.AttributeTypeCount - 1 do
          begin
            SetLength(values, Length(values) + 1);
            values[High(values)] := s.AttributeTypeAt(i).Raw;
          end
        else
          for i := 0 to s.ObjectClassCount - 1 do
          begin
            SetLength(values, Length(values) + 1);
            values[High(values)] := s.ObjectClassAt(i).Raw;
          end;
        if AKind = dkAttribute then
          Result := LocateSource(sak389Ds, 'cn=schema', 'attributeTypes', values, AOid, ASource)
        else
          Result := LocateSource(sak389Ds, 'cn=schema', 'objectClasses', values, AOid, ASource);
      end;
    sakOpenLdapConfig:
      // Lecture partielle ou interrompue: une origine trouvee parmi les entrees lues ne prouve pas
      // qu'il n'y en a pas d'autre.
      if FSourcesRead then
      for i := 0 to High(FSources) do
      begin
        if AKind = dkAttribute then
          Result := LocateSource(sakOpenLdapConfig, FSources[i].Dn, 'olcAttributeTypes',
            FSources[i].AttrValues, AOid, ASource)
        else
          Result := LocateSource(sakOpenLdapConfig, FSources[i].Dn, 'olcObjectClasses',
            FSources[i].ClassValues, AOid, ASource);
        if Result then Exit;
      end;
  end;
end;

procedure TSchemaBrowser.ShowDetail;
var
  s: TSchemaSnapshot;
  kind: TDefinitionKind;
  oid, raw, deps: string;
  a: TSchemaAttributeType;
  c: TSchemaObjectClass;
  def: TSchemaDefinition;
  src: TSchemaSource;
  rep: TDependencyReport;
  i: Integer;
begin
  FDetail.Clear;
  s := Schema;
  oid := SelectedName(kind);
  if (s = nil) or (oid = '') then Exit;
  if kind = dkAttribute then
  begin
    a := s.AttributeType(oid);
    if a = nil then Exit;
    raw := a.Raw;
    FDetail.Lines.Add(raw);
    FDetail.Lines.Add('');
    FDetail.Lines.Add('Effective equality: ' + s.EffectiveEquality(oid));
    FDetail.Lines.Add('Effective syntax: ' + s.EffectiveSyntax(oid));
    FDetail.Lines.Add('Operational: ' + BoolToStr(s.IsOperational(oid), True));
  end
  else
  begin
    c := s.ObjectClass(oid);
    if c = nil then Exit;
    raw := c.Raw;
    FDetail.Lines.Add(raw);
    FDetail.Lines.Add('');
  end;
  def := TSchemaDefinition.Create(kind, raw);
  try
    if not def.Editable then FDetail.Lines.Add(Format(rsSchemaReadOnlyDef, [def.Reason]));
  finally
    def.Free;
  end;
  if SourceOf(kind, oid, src) then
  begin
    if src.System then
      FDetail.Lines.Add(Format(rsSchemaSource, [src.EntryDn, src.Attribute, rsSchemaSourceSystem]))
    else
      FDetail.Lines.Add(Format(rsSchemaSource, [src.EntryDn, src.Attribute, '']));
  end
  else if FCaps.Adapter = sakOpenLdapConfig then
    FDetail.Lines.Add(Format(rsSchemaSourceUnknown, [FSourcesNote]))
  else
    FDetail.Lines.Add(Format(rsSchemaSourceUnknown, [rsSchemaSourcesNone]));
  rep := FindDependencies(s, kind, oid);
  deps := '';
  for i := 0 to High(rep.Items) do
  begin
    if deps <> '' then deps := deps + '; ';
    deps := deps + rep.Items[i].Relation + ' ' + rep.Items[i].Name;
  end;
  if deps = '' then deps := rsSchemaNoDependency;
  FDetail.Lines.Add(Format(rsSchemaDependencies, [deps]));
  FDetail.Lines.Add(rep.Coverage);
  if s.Stale then FDetail.Lines.Add(rsSchemaStale);
end;

procedure TSchemaBrowser.ReadSources;
var
  c: TDirectoryConnection;
  req: TSearchRequest;
begin
  FSources := nil;
  FSourcesRead := False;
  FSourceValues := 0;
  FSourceBytes := 0;
  if FCaps.Adapter <> sakOpenLdapConfig then
  begin
    FSourcesNote := rsSchemaSourcesNone;
    Exit;
  end;
  c := FCtx.Connections.Find(FProfileUuid);
  if (c = nil) or not c.IsReady then Exit;
  req := DefaultSearchRequest;
  req.BaseDn := FCaps.Context;
  req.Scope := ssOneLevel;
  req.Filter := '(objectClass=olcSchemaConfig)';
  req.Attributes := ['cn', 'olcAttributeTypes', 'olcObjectClasses'];
  // Une entree de plus que le budget, pour que le depassement se voie.
  req.SizeLimit := SCHEMA_SOURCES_MAX_ENTRIES + 1;
  FSourcesNote := rsSchemaSourcesReading;
  Tasks.Cancel('sources');
  Tasks.Search('sources', req);
end;

procedure TSchemaBrowser.LocalMessage(AMsg: TUiMessage);
var
  f: TValueFileMsg;
begin
  if not (AMsg is TValueFileMsg) then Exit;
  f := TValueFileMsg(AMsg);
  if f.TaskId <> FExportTask then Exit;
  FExportTask := 0;
  if f.Ok then FStatus.Caption := Format(rsSchemaExported, [f.Path])
  else FStatus.Caption := Format(rsSchemaExportFailed, [f.ErrorText]);
end;

procedure TSchemaBrowser.TaskMessage(AMsg: TUiMessage; const ATask: TTrackedTask;
  AEnding: TTaskEnding);
var
  c: TDirectoryConnection;
  m: TEntriesMsg;
  e: TLdapEntry;
  i, j: Integer;
  a: TLdapAttribute;
  ev: TConnectionEvent;
begin
  if AEnding = teStale then
  begin
    DropStale(ATask.Tag);
    Exit;
  end;
  c := FCtx.Connections.Find(FProfileUuid);
  if ATask.Tag = 'refresh' then
  begin
    FRefresh.Enabled := True;
    if FCtx.Connections.ApplyMessage(AMsg, Self, FCtx.Sensitive, ev) then
      case ev.Kind of
        cekSchema:
          begin
            FStatus.Caption := rsSchemaRefreshed;
            FillList;
            ReadSources;
          end;
        cekSchemaFailed:
          begin
            if c.Schema <> nil then
              FStatus.Caption := Format(rsSchemaRefreshFailed, [c.SchemaReason])
            else
              FStatus.Caption := Format(rsSchemaRefreshFailedNone, [c.SchemaReason]);
            ShowDetail;
          end;
      else
        FStatus.Caption := rsSchemaNewerKept;
      end
    else if AMsg is TTaskFailedMsg then
      FStatus.Caption := Format(rsSchemaRefreshFailedNone, [TTaskFailedMsg(AMsg).Text]);
    Exit;
  end;
  if ATask.Tag = 'sources' then
  begin
    if AMsg is TTaskFailedMsg then
    begin
      FSourcesNote := Format(rsSchemaSourcesDenied, [TTaskFailedMsg(AMsg).Text]);
      Exit;
    end;
    if not (AMsg is TEntriesMsg) then Exit;
    m := TEntriesMsg(AMsg);
    for i := 0 to m.Entries.Count - 1 do
    begin
      e := TLdapEntry(m.Entries[i]);
      if not WithinSourceBudget(e) then
      begin
        Tasks.Cancel('sources');
        FSources := nil;
        FSourcesRead := False;
        FSourcesNote := Format(rsSchemaSourcesTooLarge, [Format('%d entries, %d values, %d bytes',
          [SCHEMA_SOURCES_MAX_ENTRIES, SCHEMA_SOURCES_MAX_VALUES, SCHEMA_SOURCES_MAX_BYTES])]);
        ShowDetail;
        Exit;
      end;
      SetLength(FSources, Length(FSources) + 1);
      FSources[High(FSources)].Dn := e.Dn;
      a := e.Find('olcAttributeTypes');
      if a <> nil then
        for j := 0 to a.ValueCount - 1 do
        begin
          SetLength(FSources[High(FSources)].AttrValues, Length(FSources[High(FSources)].AttrValues) + 1);
          FSources[High(FSources)].AttrValues[j] := string(a.Values[j]);
        end;
      a := e.Find('olcObjectClasses');
      if a <> nil then
        for j := 0 to a.ValueCount - 1 do
        begin
          SetLength(FSources[High(FSources)].ClassValues, Length(FSources[High(FSources)].ClassValues) + 1);
          FSources[High(FSources)].ClassValues[j] := string(a.Values[j]);
        end;
    end;
    if m.Final then
    begin
      FSourcesRead := SearchOutcome(m.Completion) = soComplete;
      if not FSourcesRead then
        FSourcesNote := Format(rsSchemaSourcesDenied, [ResultCodeName(m.Completion.ResultCode)]);
      ShowDetail;
    end;
  end;
end;

procedure TSchemaBrowser.DropStale(const ATag: string);
begin
  if ATag = 'refresh' then
  begin
    FRefresh.Enabled := True;
    FStatus.Caption := rsTdReadSessionLost;
  end;
  if ATag = 'sources' then
  begin
    FSources := nil;
    FSourcesRead := False;
    FSourcesNote := rsSchemaSourcesSessionLost;
    ShowDetail;
  end;
end;

function TSchemaBrowser.WithinSourceBudget(AEntry: TLdapEntry): Boolean;
var
  k: Integer;
  a: TLdapAttribute;
  values: Integer;
  bytes: Int64;
begin
  values := 0;
  bytes := Length(AEntry.Dn) + SOURCE_VALUE_OVERHEAD;
  a := AEntry.Find('olcAttributeTypes');
  if a <> nil then
    for k := 0 to a.ValueCount - 1 do
    begin
      Inc(values);
      Inc(bytes, Length(a.Values[k]) + SOURCE_VALUE_OVERHEAD);
    end;
  a := AEntry.Find('olcObjectClasses');
  if a <> nil then
    for k := 0 to a.ValueCount - 1 do
    begin
      Inc(values);
      Inc(bytes, Length(a.Values[k]) + SOURCE_VALUE_OVERHEAD);
    end;
  Result := (Length(FSources) < SCHEMA_SOURCES_MAX_ENTRIES) and
    (FSourceValues + values <= SCHEMA_SOURCES_MAX_VALUES) and
    (FSourceBytes + bytes <= SCHEMA_SOURCES_MAX_BYTES);
  if Result then
  begin
    Inc(FSourceValues, values);
    Inc(FSourceBytes, bytes);
  end;
end;

function TSchemaBrowser.SourcesComplete: Boolean;
begin
  Result := FSourcesRead;
end;

procedure TSchemaBrowser.Refresh;
begin
  RefreshClick(nil);
end;

function TSchemaBrowser.RefreshEnabled: Boolean;
begin
  Result := FRefresh.Enabled;
end;

procedure TSchemaBrowser.RefreshClick(Sender: TObject);
var
  c: TDirectoryConnection;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  if (c = nil) or not c.IsReady or Tasks.Pending('refresh') then Exit;
  FStatus.Caption := rsSchemaRefreshing;
  FRefresh.Enabled := False;
  if Tasks.FetchSchema('refresh') = 0 then FRefresh.Enabled := True;
end;

procedure TSchemaBrowser.OpenEditor(AKind: TDefinitionKind; AOriginal: TSchemaDefinition);
var
  f: TSchemaEditForm;
  plan: TSchemaChangePlan;
  src: TSchemaSource;
  s: TSchemaSnapshot;
  op: TSchemaOp;
  target: string;
  i: Integer;
begin
  s := Schema;
  if s = nil then Exit;
  if FCaps.Adapter = sakOpenLdapConfig then target := 'cn=local,' + FCaps.Context else target := '';
  f := TSchemaEditForm.CreateFor(Self, AKind, AOriginal, FCaps.Adapter = sakOpenLdapConfig, target);
  try
    if f.ShowModal <> mrOk then Exit;
    s := Schema;
    if s = nil then Exit;
    if AOriginal = nil then
    begin
      op := soCreate;
      src := Default(TSchemaSource);
      if (FCaps.Adapter = sakOpenLdapConfig) and FSourcesRead then
      begin
        src.EntryDn := f.TargetEntry;
        src.NewEntry := True;
        for i := 0 to High(FSources) do
          if SameText(FSources[i].Dn, f.TargetEntry) then src.NewEntry := False;
      end;
    end
    else
    begin
      op := soModify;
      SourceOf(AKind, AOriginal.Oid, src);
    end;
    plan := BuildSchemaPlan(s, FCaps, op, AOriginal, f.Definition, src);
    try
      ShowPlan(plan);
    finally
      plan.Free;
    end;
  finally
    f.Definition.Free;
    f.Free;
  end;
end;

type
  TAdSchemaForm = class(TRtDialog)
  public
    IsClass: Boolean;
    CnEdit, NameEdit, OidEdit, DescEdit, SupEdit, MustEdit, MayEdit, SuperiorsEdit, RangeEdit: TEdit;
    SyntaxCombo, CategoryCombo: TRtComboBox;
    SingleCheck: TRtCheckBox;
  end;

function AdField(AForm: TAdSchemaForm; const ACaption, AValue: string): TEdit;
var
  row: TPanel;
begin
  row := MakeFieldRow(AForm.Body, ACaption, 220);
  Result := MakeEdit(row, alClient);
  Result.Text := AValue;
end;

function AdCombo(AForm: TAdSchemaForm; const ACaption: string): TRtComboBox;
var
  row: TPanel;
begin
  row := MakeFieldRow(AForm.Body, ACaption, 220);
  Result := TRtComboBox.Create(row);
  Result.Parent := row;
  Result.Align := alClient;
  Result.Style := csDropDownList;
  Result.BorderSpacing.Around := 3;
end;

function AdToPlan(var AAd: TAdSchemaPlan; AOp: TSchemaOp; AKind: TDefinitionKind;
  const ACaps: TSchemaCapabilities): TSchemaChangePlan;
var
  i: Integer;
begin
  Result := TSchemaChangePlan.Create;
  Result.Operation := AOp;
  Result.Kind := AKind;
  Result.Adapter := sakActiveDirectory;
  Result.Change := AAd.Change;
  Result.Extra := AAd.Refresh;
  AAd.Change := nil;
  AAd.Refresh := nil;
  for i := 0 to High(AAd.Errors) do
  begin
    SetLength(Result.Issues, Length(Result.Issues) + 1);
    Result.Issues[High(Result.Issues)].IsError := True;
    Result.Issues[High(Result.Issues)].Text := AAd.Errors[i];
  end;
  for i := 0 to High(AAd.Warnings) do
  begin
    SetLength(Result.Issues, Length(Result.Issues) + 1);
    Result.Issues[High(Result.Issues)].IsError := False;
    Result.Issues[High(Result.Issues)].Text := AAd.Warnings[i];
  end;
  if Length(AAd.Errors) > 0 then Result.Reason := AAd.Errors[0]
  else Result.Reason := ACaps.Reason[AOp];
  Result.Sendable := AAd.Ok and ACaps.Qualified[AOp];
end;

procedure TSchemaBrowser.AdCreate(AIsClass: Boolean);
var
  f: TAdSchemaForm;
  c: TDirectoryConnection;
  s: TSchemaSnapshot;
  ad: TAdSchemaPlan;
  plan: TSchemaChangePlan;
  attr: TAdAttributeDraft;
  cls: TAdClassDraft;
  ch: TAdSyntaxChoice;
  v: Int64;
  title: string;
begin
  if AIsClass then title := Format(rsSchemaNewTitle, ['Active Directory class'])
  else title := Format(rsSchemaNewTitle, ['Active Directory attribute']);
  f := TAdSchemaForm.CreateDialog(Self, title, 720, 560);
  f.SetIcon('schema');
  try
    f.IsClass := AIsClass;
    f.CnEdit := AdField(f, rsSchemaFieldCn, '');
    f.NameEdit := AdField(f, rsSchemaFieldLdapName, '');
    f.OidEdit := AdField(f, rsSchemaFieldOid, '');
    f.DescEdit := AdField(f, rsSchemaFieldDesc, '');
    if AIsClass then
    begin
      f.CategoryCombo := AdCombo(f, rsSchemaFieldKind);
      f.CategoryCombo.Items.Add('STRUCTURAL');
      f.CategoryCombo.Items.Add('ABSTRACT');
      f.CategoryCombo.Items.Add('AUXILIARY');
      f.CategoryCombo.ItemIndex := 2;
      f.SupEdit := AdField(f, rsSchemaFieldSup, 'top');
      f.MustEdit := AdField(f, rsSchemaFieldMust, '');
      f.MayEdit := AdField(f, rsSchemaFieldMay, '');
      f.SuperiorsEdit := AdField(f, rsSchemaFieldPossSup, '');
    end
    else
    begin
      f.SyntaxCombo := AdCombo(f, rsSchemaFieldSyntax);
      for ch := Low(TAdSyntaxChoice) to High(TAdSyntaxChoice) do
        f.SyntaxCombo.Items.Add(AdSyntaxChoiceName(ch));
      f.SyntaxCombo.ItemIndex := 0;
      f.SingleCheck := MakeCheck(f.Body, rsSchemaSingle);
      f.RangeEdit := AdField(f, rsSchemaFieldRange, '');
    end;
    f.AddButton('Cancel', mrCancel, False, True);
    f.AddButton('OK', mrOk, True);
    f.ApplyTheme;
    if f.ShowModal <> mrOk then Exit;
    // Schema et connexion retrouves apres le modal: l'un comme l'autre a pu mourir entre-temps.
    c := FCtx.Connections.Find(FProfileUuid);
    s := Schema;
    if (c = nil) or (s = nil) then Exit;
    if AIsClass then
    begin
      cls := Default(TAdClassDraft);
      cls.Cn := Trim(f.CnEdit.Text);
      cls.LdapDisplayName := Trim(f.NameEdit.Text);
      cls.GovernsId := Trim(f.OidEdit.Text);
      cls.Description := Trim(f.DescEdit.Text);
      case f.CategoryCombo.ItemIndex of
        0: cls.Category := 1;
        1: cls.Category := 2;
      else
        cls.Category := 3;
      end;
      cls.SubClassOf := Trim(f.SupEdit.Text);
      cls.Must := SplitWords(f.MustEdit.Text);
      cls.May := SplitWords(f.MayEdit.Text);
      cls.PossSuperiors := SplitWords(f.SuperiorsEdit.Text);
      ad := PlanAdClass(s.AdMeta, s, cls, AdRoleOwner, string(c.RootDse.FirstValue('dsServiceName', '')));
    end
    else
    begin
      attr := Default(TAdAttributeDraft);
      attr.Cn := Trim(f.CnEdit.Text);
      attr.LdapDisplayName := Trim(f.NameEdit.Text);
      attr.AttributeId := Trim(f.OidEdit.Text);
      attr.Description := Trim(f.DescEdit.Text);
      attr.Syntax := TAdSyntaxChoice(f.SyntaxCombo.ItemIndex);
      attr.SingleValued := f.SingleCheck.Checked;
      attr.HasRangeUpper := TryStrToInt64(Trim(f.RangeEdit.Text), v);
      attr.RangeUpper := v;
      ad := PlanAdAttribute(s.AdMeta, s, attr, AdRoleOwner, string(c.RootDse.FirstValue('dsServiceName', '')));
    end;
    if AIsClass then plan := AdToPlan(ad, soCreate, dkClass, FCaps)
    else plan := AdToPlan(ad, soCreate, dkAttribute, FCaps);
    try
      ShowPlan(plan);
    finally
      plan.Free;
      FreeAdSchemaPlan(ad);
    end;
  finally
    f.Free;
  end;
end;

procedure TSchemaBrowser.AdDefunct(const AName: string; AKind: TDefinitionKind);
var
  c: TDirectoryConnection;
  s: TSchemaSnapshot;
  ad: TAdSchemaPlan;
  plan: TSchemaChangePlan;
begin
  c := FCtx.Connections.Find(FProfileUuid);
  s := Schema;
  if (c = nil) or (s = nil) then Exit;
  ad := PlanAdDefunct(s.AdMeta, AName, AdRoleOwner, string(c.RootDse.FirstValue('dsServiceName', '')));
  plan := AdToPlan(ad, soDelete, AKind, FCaps);
  try
    ShowPlan(plan);
  finally
    plan.Free;
    FreeAdSchemaPlan(ad);
  end;
end;

function TSchemaBrowser.AdRoleOwner: string;
var
  s: TSchemaSnapshot;
begin
  s := Schema;
  if (s = nil) or (s.AdMeta = nil) then Result := '' else Result := s.AdMeta.RoleOwner;
end;

procedure TSchemaBrowser.NewAttrClick(Sender: TObject);
begin
  if FCaps.Adapter = sakActiveDirectory then AdCreate(False)
  else OpenEditor(dkAttribute, nil);
end;

procedure TSchemaBrowser.NewClassClick(Sender: TObject);
begin
  if FCaps.Adapter = sakActiveDirectory then AdCreate(True)
  else OpenEditor(dkClass, nil);
end;

procedure TSchemaBrowser.EditClick(Sender: TObject);
var
  kind: TDefinitionKind;
  oid: string;
  s: TSchemaSnapshot;
  def: TSchemaDefinition;
begin
  s := Schema;
  oid := SelectedName(kind);
  if (s = nil) or (oid = '') then Exit;
  if FCaps.Adapter = sakActiveDirectory then
  begin
    FStatus.Caption := rsSchemaAdEditUnavailable;
    Exit;
  end;
  if kind = dkAttribute then def := TSchemaDefinition.Create(kind, s.AttributeType(oid).Raw)
  else def := TSchemaDefinition.Create(kind, s.ObjectClass(oid).Raw);
  try
    OpenEditor(kind, def);
  finally
    def.Free;
  end;
end;

procedure TSchemaBrowser.DeleteClick(Sender: TObject);
var
  kind: TDefinitionKind;
  oid: string;
  s: TSchemaSnapshot;
  def: TSchemaDefinition;
  src: TSchemaSource;
  plan: TSchemaChangePlan;
begin
  s := Schema;
  oid := SelectedName(kind);
  if (s = nil) or (oid = '') then Exit;
  if RtMessageDlg(rsSchemaTitle, Format(rsSchemaDeleteConfirm, [oid]), mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  // AD ne supprime pas une definition de schema: on la declare defunte (isDefunct).
  if FCaps.Adapter = sakActiveDirectory then
  begin
    if kind = dkAttribute then AdDefunct(s.AttributeType(oid).PrimaryName, kind)
    else AdDefunct(s.ObjectClass(oid).PrimaryName, kind);
    Exit;
  end;
  if kind = dkAttribute then def := TSchemaDefinition.Create(kind, s.AttributeType(oid).Raw)
  else def := TSchemaDefinition.Create(kind, s.ObjectClass(oid).Raw);
  try
    SourceOf(kind, oid, src);
    plan := BuildSchemaPlan(s, FCaps, soDelete, def, nil, src);
    try
      ShowPlan(plan);
    finally
      plan.Free;
    end;
  finally
    def.Free;
  end;
end;

procedure TSchemaBrowser.ExportPlan(APlan: TSchemaChangePlan; const APath: string);
var
  content: string;
begin
  content := '# ' + rsSchemaExportNote + LineEnding + APlan.Ldif;
  FExportTask := StartValueSave(APath, RawByteString(content), Self);
end;

type
  TPlanDialog = class(TRtDialog)
  public
    Browser: TSchemaBrowser;
    Plan: TSchemaChangePlan;
    procedure ExportClick(Sender: TObject);
  end;

procedure TPlanDialog.ExportClick(Sender: TObject);
var
  sd: TSaveDialog;
begin
  sd := TSaveDialog.Create(Self);
  try
    sd.Filter := 'LDIF (*.ldif)|*.ldif|All files|*.*';
    sd.DefaultExt := 'ldif';
    sd.Options := sd.Options + [ofOverwritePrompt];
    if sd.Execute then Browser.ExportPlan(Plan, sd.FileName);
  finally
    sd.Free;
  end;
end;

function TSchemaBrowser.ShowPlan(APlan: TSchemaChangePlan): Boolean;
var
  d: TPlanDialog;
  memo: TMemo;
  i: Integer;
  op, deps, kindName: string;
  bExport, bApply: TButton;
  note: TLabel;
begin
  Result := False;
  case APlan.Operation of
    soCreate: op := rsSchemaPlanCreate;
    soModify: op := rsSchemaPlanModify;
  else
    op := rsSchemaPlanDelete;
  end;
  d := TPlanDialog.CreateDialog(Self, rsSchemaPlanTitle, 960, 640);
  d.SetIcon('list-details');
  try
    d.Browser := Self;
    d.Plan := APlan;
    note := MakeLabel(d.Body, '');
    note.WordWrap := True;
    if not APlan.Sendable then note.Caption := Format(rsSchemaPlanNotSent, [APlan.Reason]);
    memo := MakeMemo(d.Body);
    memo.ReadOnly := True;
    memo.ScrollBars := ssAutoBoth;
    memo.WordWrap := False;
    if APlan.Kind = dkAttribute then kindName := 'attribute type' else kindName := 'object class';
    memo.Lines.Add(Format(rsSchemaPlanOp, [op, kindName, FCaps.Context]));
    if APlan.Before <> '' then
    begin
      memo.Lines.Add(rsSchemaPlanBefore);
      memo.Lines.Add(APlan.Before);
    end;
    if APlan.After <> '' then
    begin
      memo.Lines.Add(rsSchemaPlanAfter);
      memo.Lines.Add(APlan.After);
    end;
    if Length(APlan.Issues) > 0 then
    begin
      memo.Lines.Add(rsSchemaPlanChecks);
      for i := 0 to High(APlan.Issues) do
        if APlan.Issues[i].IsError then memo.Lines.Add('# ERROR: ' + APlan.Issues[i].Text)
        else memo.Lines.Add('# warning: ' + APlan.Issues[i].Text);
    end;
    if Length(APlan.Dependencies.Items) > 0 then
    begin
      memo.Lines.Add(Format(rsSchemaPlanDeps, [APlan.Dependencies.Coverage]));
      for i := 0 to High(APlan.Dependencies.Items) do
      begin
        deps := APlan.Dependencies.Items[i].Relation + ' ' + APlan.Dependencies.Items[i].Name;
        memo.Lines.Add('# ' + deps);
      end;
    end;
    memo.Lines.Add(rsSchemaPlanLdif);
    if APlan.Ldif <> '' then memo.Lines.Add(APlan.Ldif) else memo.Lines.Add(rsSchemaPlanNoLdif);
    d.AddButton(rsSchemaClose, mrClose, True, True);
    bApply := d.AddButton(rsSchemaApply, mrOk);
    bApply.Enabled := APlan.Sendable;
    bExport := d.AddButton(rsSchemaExport, mrNone);
    bExport.OnClick := @d.ExportClick;
    bExport.Enabled := APlan.Change <> nil;
    d.ApplyTheme;
    memo.Color := clEditorBg;
    memo.Font.Color := clEditorFg;
    StyleMemo(memo);
    Result := (d.ShowModal = mrOk) and APlan.Sendable;
  finally
    d.Free;
  end;
end;

function TSchemaEditForm.Field(const ACaption: string; const AValue: string): TEdit;
var
  row: TPanel;
begin
  row := MakeFieldRow(Body, ACaption, 220);
  Result := MakeEdit(row, alClient);
  Result.Text := AValue;
end;

constructor TSchemaEditForm.CreateFor(AOwner: TComponent; AKind: TDefinitionKind;
  AOriginal: TSchemaDefinition; AShowTarget: Boolean; const ADefaultTarget: string);
var
  row: TPanel;
  kindName: string;
  ok: TButton;
begin
  if AKind = dkAttribute then kindName := 'attribute type' else kindName := 'object class';
  if AOriginal = nil then
    inherited CreateDialog(AOwner, Format(rsSchemaNewTitle, [kindName]), 760, 640)
  else
    inherited CreateDialog(AOwner, Format(rsSchemaEditTitle, [kindName]), 760, 640);
  SetIcon('schema');
  FKind := AKind;
  FOriginal := AOriginal;
  FIsNew := AOriginal = nil;
  if FIsNew then
    FOid := Field(rsSchemaFieldOid, '')
  else
  begin
    FOid := Field(rsSchemaFieldOid, AOriginal.Oid);
    FOid.ReadOnly := True;
    FOid.Enabled := False;
  end;
  if AOriginal = nil then
  begin
    FNames := Field(rsSchemaFieldNames, '');
    FDesc := Field(rsSchemaFieldDesc, '');
  end
  else
  begin
    FNames := Field(rsSchemaFieldNames, string.Join(' ', AOriginal.Values('NAME')));
    FDesc := Field(rsSchemaFieldDesc, AOriginal.Value('DESC'));
  end;
  FObsolete := MakeCheck(Body, rsSchemaObsolete);
  if AOriginal <> nil then FObsolete.Checked := AOriginal.Has('OBSOLETE');
  if AKind = dkAttribute then
  begin
    if AOriginal = nil then
    begin
      FSup := Field(rsSchemaFieldSup, '');
      FSyntax := Field(rsSchemaFieldSyntax, '1.3.6.1.4.1.1466.115.121.1.15');
      FEquality := Field(rsSchemaFieldEquality, 'caseIgnoreMatch');
      FOrdering := Field(rsSchemaFieldOrdering, '');
      FSubstr := Field(rsSchemaFieldSubstr, 'caseIgnoreSubstringsMatch');
    end
    else
    begin
      FSup := Field(rsSchemaFieldSup, AOriginal.Value('SUP'));
      FSyntax := Field(rsSchemaFieldSyntax, AOriginal.Value('SYNTAX'));
      FEquality := Field(rsSchemaFieldEquality, AOriginal.Value('EQUALITY'));
      FOrdering := Field(rsSchemaFieldOrdering, AOriginal.Value('ORDERING'));
      FSubstr := Field(rsSchemaFieldSubstr, AOriginal.Value('SUBSTR'));
    end;
    FSingle := MakeCheck(Body, rsSchemaSingle);
    FCollective := MakeCheck(Body, rsSchemaCollective);
    FNoUserMod := MakeCheck(Body, rsSchemaNoUserMod);
    row := MakeFieldRow(Body, rsSchemaFieldUsage, 220);
    FUsage := TRtComboBox.Create(row);
    FUsage.Parent := row;
    FUsage.Align := alClient;
    FUsage.Style := csDropDownList;
    FUsage.BorderSpacing.Around := 3;
    FUsage.Items.Add('userApplications');
    FUsage.Items.Add('directoryOperation');
    FUsage.Items.Add('distributedOperation');
    FUsage.Items.Add('dSAOperation');
    FUsage.ItemIndex := 0;
    if AOriginal <> nil then
    begin
      FSingle.Checked := AOriginal.Has('SINGLE-VALUE');
      FCollective.Checked := AOriginal.Has('COLLECTIVE');
      FNoUserMod.Checked := AOriginal.Has('NO-USER-MODIFICATION');
      if AOriginal.Value('USAGE') <> '' then
        FUsage.ItemIndex := FUsage.Items.IndexOf(AOriginal.Value('USAGE'));
      FUsage.Enabled := False;
      FNoUserMod.Enabled := False;
    end;
  end
  else
  begin
    row := MakeFieldRow(Body, rsSchemaFieldKind, 220);
    FClassKind := TRtComboBox.Create(row);
    FClassKind.Parent := row;
    FClassKind.Align := alClient;
    FClassKind.Style := csDropDownList;
    FClassKind.BorderSpacing.Around := 3;
    FClassKind.Items.Add('STRUCTURAL');
    FClassKind.Items.Add('AUXILIARY');
    FClassKind.Items.Add('ABSTRACT');
    FClassKind.ItemIndex := 1;
    if AOriginal = nil then
    begin
      FSup := Field(rsSchemaFieldSups, 'top');
      FMust := Field(rsSchemaFieldMust, '');
      FMay := Field(rsSchemaFieldMay, '');
    end
    else
    begin
      if AOriginal.Has('STRUCTURAL') then FClassKind.ItemIndex := 0
      else if AOriginal.Has('ABSTRACT') then FClassKind.ItemIndex := 2;
      FClassKind.Enabled := False;
      FSup := Field(rsSchemaFieldSups, string.Join(' ', AOriginal.Values('SUP')));
      FMust := Field(rsSchemaFieldMust, string.Join(' ', AOriginal.Values('MUST')));
      FMay := Field(rsSchemaFieldMay, string.Join(' ', AOriginal.Values('MAY')));
    end;
  end;
  if AShowTarget and (AOriginal = nil) then
    FTarget := Field(rsSchemaFieldTarget, ADefaultTarget);
  MakeLabel(Body, rsSchemaExtensionsKept);
  FError := MakeLabel(Body, '');
  FError.WordWrap := True;
  AddButton('Cancel', mrCancel, False, True);
  ok := AddButton('OK', mrNone, True);
  ok.OnClick := @OkClick;
  ApplyTheme;
end;

procedure TSchemaEditForm.SetText(const AField, AValue: string);
begin
  if AField = 'oid' then FOid.Text := AValue
  else if AField = 'names' then FNames.Text := AValue
  else if AField = 'desc' then FDesc.Text := AValue
  else if AField = 'sup' then FSup.Text := AValue
  else if (AField = 'syntax') and (FSyntax <> nil) then FSyntax.Text := AValue
  else if (AField = 'equality') and (FEquality <> nil) then FEquality.Text := AValue
  else if (AField = 'must') and (FMust <> nil) then FMust.Text := AValue
  else if (AField = 'may') and (FMay <> nil) then FMay.Text := AValue;
end;

function TSchemaEditForm.Build(out AError: string): Boolean;
var
  d: TSchemaDefinition;

  function Put(const AKeyword, AText: string; AList: Boolean): Boolean;
  var
    words: TStringArray;
    cur: string;
  begin
    Result := True;
    if AList then
    begin
      words := SplitWords(AText);
      cur := string.Join(' ', d.Values(AKeyword));
      if string.Join(' ', words) = cur then Exit;
      if Length(words) = 0 then Exit(d.Remove(AKeyword, AError));
      Result := d.SetValues(AKeyword, words, AError);
    end
    else
    begin
      if AText = d.Value(AKeyword) then Exit;
      if AText = '' then Exit(d.Remove(AKeyword, AError));
      Result := d.SetValue(AKeyword, AText, AError);
    end;
  end;

  function Flag(const AKeyword: string; ABox: TRtCheckBox): Boolean;
  begin
    Result := True;
    if (ABox = nil) or not ABox.Enabled or (ABox.Checked = d.Has(AKeyword)) then Exit;
    Result := d.SetFlag(AKeyword, ABox.Checked, AError);
  end;

begin
  Result := False;
  AError := '';
  FreeAndNil(Definition);
  if FIsNew then d := TSchemaDefinition.CreateNew(FKind, Trim(FOid.Text))
  else d := FOriginal.Clone;
  try
    if not d.Editable then
    begin
      AError := d.Reason;
      Exit;
    end;
    if not Put('NAME', FNames.Text, True) then Exit;
    if not Put('DESC', FDesc.Text, False) then Exit;
    if not Flag('OBSOLETE', FObsolete) then Exit;
    if FKind = dkAttribute then
    begin
      if not Put('SUP', Trim(FSup.Text), False) then Exit;
      if not Put('EQUALITY', Trim(FEquality.Text), False) then Exit;
      if not Put('ORDERING', Trim(FOrdering.Text), False) then Exit;
      if not Put('SUBSTR', Trim(FSubstr.Text), False) then Exit;
      if not Put('SYNTAX', Trim(FSyntax.Text), False) then Exit;
      if not Flag('SINGLE-VALUE', FSingle) then Exit;
      if not Flag('COLLECTIVE', FCollective) then Exit;
      if not Flag('NO-USER-MODIFICATION', FNoUserMod) then Exit;
      if FUsage.Enabled and (FUsage.ItemIndex > 0) then
        if not Put('USAGE', FUsage.Text, False) then Exit;
    end
    else
    begin
      if not Put('SUP', FSup.Text, True) then Exit;
      if FClassKind.Enabled then
        if not d.SetClassKind(FClassKind.Text, AError) then Exit;
      if not Put('MUST', FMust.Text, True) then Exit;
      if not Put('MAY', FMay.Text, True) then Exit;
    end;
    Definition := d;
    d := nil;
    if FTarget <> nil then TargetEntry := Trim(FTarget.Text);
    Result := True;
  finally
    d.Free;
  end;
end;

procedure TSchemaEditForm.OkClick(Sender: TObject);
var
  err: string;
begin
  if Build(err) then ModalResult := mrOk
  else FError.Caption := err;
end;

end.
