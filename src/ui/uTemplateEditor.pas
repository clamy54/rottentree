// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTemplateEditor;

{$mode objfpc}{$H+}

// Editeur de modeles: classes en haut, une ligne par valeur, l'aide en bas. La source de chaque
// valeur se choisit d'un clic, une composition se monte en posant des jetons. Controle a chaque
// geste contre le schema ouvert: l'obligatoire ne peut pas manquer, une boucle ne s'enregistre pas.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, Dialogs, LCLType, Menus,
  uUiKit, uAppContext, uRtButton, uRtChips, uIcons, uLdapSchema, uEntryTemplate,
  uEntryCreationPlan, uConnectionProfile, uTemplateGroups, uSensitive, uRtCombo, uRtCheck,
  uAdPasswordRules, uUiInbox, uTaskTracker, uDirectoryWorker;

type
  TTemplateEditor = class;

  TTeRowKind = (trkField, trkAdd, trkEmpty);

  TTeMetrics = record
    EditH, RowH, BtnW, BtnH, SwitchH, ChipW, AttrW, SourceW, CapGap, FormatW: Integer;
  end;

  TTeRow = class(TCustomControl)
  private
    FDlg: TTemplateEditor;
    FKind: TTeRowKind;
    FIndex: Integer;
    FBuilt, FIsCurrent, FInLayout, FFilling, FLocked, FForced: Boolean;
    FForcedRect: TRect;
    FBase: TColor;
    FError, FLocalError: string;
    FWarning: Boolean;
    FSources: array of TTplSource;
    FRdnChip, FOptional, FMenuBtn, FDelBtn, FAddBtn: TRtFlatButton;
    FSource, FMode: TRtSegmented;
    FValue, FPrompt, FMin, FMax: TEdit;
    FChips: TRtChipBar;
    FFormat: TRtComboBox;
    FAttrLeft, FCap1Left, FCap2Left, FFormatLeft: Integer;
    FCap1, FCap2, FFormatCap: string;
    function MakeField(const AHint: string): TEdit;
    function MakeButton(const AIcon, AText: string; AInk: TColor): TRtFlatButton;
    procedure BuildControls;
    procedure BuildFormat(const F: TTplField);
    procedure FillChips;
    function SourceColor: TColor;
    procedure StyleRdnChip;
    procedure StyleOptional;
    procedure SyncForced;
    procedure DrawFrame(AEdit: TEdit; ABad: Boolean = False);
    procedure FieldChange(Sender: TObject);
    procedure FieldEnter(Sender: TObject);
    procedure FieldExit(Sender: TObject);
    procedure SourceChange(Sender: TObject);
    procedure ModeChange(Sender: TObject);
    procedure FormatChange(Sender: TObject);
    procedure RdnClick(Sender: TObject);
    procedure OptionalClick(Sender: TObject);
    procedure MenuClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure ChipsLayout(Sender: TObject);
    procedure ChipClick(Sender: TObject; AIndex: Integer; AButton: TMouseButton);
    procedure ChipClose(Sender: TObject; AIndex: Integer);
    procedure ChipEdited(Sender: TObject; AIndex: Integer; const AText: string);
    procedure ChipMoved(Sender: TObject; AFrom, ATo: Integer);
    procedure ChipAction(Sender: TObject; AIndex: Integer);
    procedure ChipsEnter(Sender: TObject);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor CreateRow(AOwner: TWinControl; ADlg: TTemplateEditor; AKind: TTeRowKind;
      AIndex: Integer);
    procedure Restyle;
    procedure LayoutRow;
    procedure SetCurrentLook(AValue: Boolean);
    procedure SetError(const AError: string; AWarning: Boolean);
    procedure SetNote(const ANote: string);
    property Kind: TTeRowKind read FKind;
    property Index: Integer read FIndex;
  end;

  TTemplateEditor = class(TRtDialog)
  private
    FCtx: TAppContext;
    FProfileUuid: string;
    FT: TEntryTemplate;
    FAnalysis: TClassAnalysis;
    FIssues: TTplIssues;
    FSamples: TStringArray;
    FRows: TFPList;
    FCurrent: Integer;
    FMetrics: TTeMetrics;
    FName, FDesc: TEdit;
    FClassRow, FGroupRow, FAccountRow: TPanel;
    FMustChange, FNeverExpires, FAccountDisabled: TRtCheckBox;
    FPolicy: TAdPwdPolicy;
    FPolicyTasks: TDirectoryTasks;
    FFillingAccount: Boolean;
    FClasses, FGroupBar: TRtChipBar;
    FScroll: TRtScrollBox;
    FStatus, FWords, FHelp: TLabel;
    FStatusIcon, FHelpIcon: TRtIcon;
    FHelpRow: TPanel;
    FUndoBtn, FCleanBtn: TRtFlatButton;
    FUndo: TStringList;
    FTypingOwner: TObject;
    FMenu: TPopupMenu;
    FMenuField, FMenuPart: Integer;
    FUpdating, FClosing, FRebuildQueued: Boolean;
    FRebuildFocus: Integer;
    FSave: TButton;
    procedure BuildUi;
    procedure ComputeMetrics;
    function Schema: TSchemaSnapshot;
    function Provider: TProviderKind;
    function RowOfField(AIndex: Integer): TTeRow;
    function RowOf(AControl: TControl): TTeRow;
    function FieldRequired(AIndex: Integer): Boolean;
    function RequiredReason(AIndex: Integer): string;
    function FieldSecret(AIndex: Integer): Boolean;
    function FieldIsNumber(AIndex: Integer): Boolean;
    function AllowedSources(AIndex: Integer): TTplIndexes;
    function PartColor(const APart: TTplPart): TColor;
    procedure FillClasses;
    procedure ClassesLayout(Sender: TObject);
    procedure ClassChipClick(Sender: TObject; AIndex: Integer; AButton: TMouseButton);
    procedure ClassChipClose(Sender: TObject; AIndex: Integer);
    procedure ClassAction(Sender: TObject; AIndex: Integer);
    procedure FillGroups;
    procedure FillAccount;
    function AllIssues: TTplIssues;
    procedure AccountChange(Sender: TObject);
    procedure PolicyMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
    procedure GroupChipClose(Sender: TObject; AIndex: Integer);
    procedure GroupAction(Sender: TObject; AIndex: Integer);
    procedure RebuildRows(AFocus: Integer);
    procedure QueueRebuild(AFocus: Integer);
    procedure RunRebuild(AData: PtrInt);
    procedure FocusRow(AIndex: Integer);
    procedure SetCurrent(AIndex: Integer);
    procedure Recheck;
    procedure UpdateStatus;
    procedure UpdateWords;
    procedure UpdateHelp;
    function AttrInfo(const AName: string): string;
    procedure PushUndo;
    procedure BeginTyping(AOwner: TObject);
    procedure RowEdited(ARow: TTeRow; ASender: TObject);
    procedure HeaderChange(Sender: TObject);
    procedure UndoClick(Sender: TObject);
    procedure CleanClick(Sender: TObject);
    function FieldDisallowed(AIndex: Integer): Boolean;
    procedure SaveClick(Sender: TObject);
    procedure FormResized(Sender: TObject);
    procedure ShowRowMenu(ARow: TTeRow; AAtMouse: Boolean);
    procedure ShowPartMenu(ARow: TTeRow; APart: Integer);
    procedure ShowAddPartMenu(ARow: TTeRow);
    procedure MenuItemClick(Sender: TObject);
    function PickClass(AKind: TObjectClassKind; out AName: string): Boolean;
    procedure AfterClassChange;
  protected
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure ApplyShellColors; override;
  public
    constructor CreateEditor(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
      const ATemplate: TEntryTemplate);
    destructor Destroy; override;
    procedure ChooseStructural;
    procedure SetStructural(const AName: string);
    procedure AddAuxiliary;
    procedure AddAuxiliaryClass(const AName: string);
    procedure RemoveAuxiliary(AIndex: Integer);
    function AddGroup(const ADn: string): Boolean;
    procedure RemoveGroup(AIndex: Integer);
    procedure AddAttribute;
    function AddField(const AAttr: string): Integer;
    procedure DeleteField(AIndex: Integer);
    procedure MoveField(AIndex, ADelta: Integer);
    procedure DuplicateField(AIndex: Integer);
    procedure SetRdn(AIndex: Integer);
    procedure SetSource(AIndex: Integer; ASource: TTplSource);
    procedure SetFormat(AIndex: Integer; const AScheme: string);
    procedure SetAccount(const AAccount: TTplAccount);
    function AccountShown: Boolean;
    procedure AddPart(AField: Integer; const APart: TTplPart);
    procedure RemovePart(AField, APart: Integer);
    procedure MovePart(AField, AFrom, ATo: Integer);
    procedure Undo;
    procedure RunCommand(ACommand, AField, APart: Integer);
    procedure RemoveDisallowed;
    function DisallowedCount: Integer;
    procedure Save;
    function StatusText: string;
    function SaveEnabled: Boolean;
    property Template: TEntryTemplate read FT;
    property Metrics: TTeMetrics read FMetrics;
  end;

// Vrai si le modele a ete enregistre; ATemplate porte alors son identifiant.
function EditTemplate(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
  var ATemplate: TEntryTemplate): Boolean;

function TemplateSourceColor(ASource: TTplSource): TColor;
function TemplateSourceName(ASource: TTplSource): string;
function PartBadge(const APart: TTplPart): string;
function FieldSummary(const F: TTplField; ASensitive: TSensitivePolicy = nil): string;
function TemplateKindText(const T: TEntryTemplate): string;
function TemplateSummary(const T: TEntryTemplate; ASensitive: TSensitivePolicy = nil): string;
procedure FillGroupChips(ABar: TRtChipBar; AGroups: TGroupTargets; AEditable: Boolean;
  const AAddCaption: string);

resourcestring
  rsTeSumGroups = 'Then added to: %s';
  rsTeGroups = 'Then added to';
  rsTeAddGroup = 'Group';
  rsTeGroupPrompt = 'Group every entry created from this template joins';
  rsTeGroupsHelp = 'Groups are named by their DN: they belong to one directory. Elsewhere the form says which ones are missing.';
  rsTeSumFixed = '%s: %s';
  rsTeSumPwdFixed = '%s: fixed password (%s)';
  rsTeSumPwdCompose = '%s: password composed from %s (%s)';
  rsTeSumHiddenText = '...';
  rsTeSumAsk = '%s: asked (%s)';
  rsTeSumAskOptional = '%s: asked, optional (%s)';
  rsTeSumCompose = '%s: %s';
  rsTeSumNumberHighest = '%s: free number after the highest';
  rsTeSumNumberFirst = '%s: first free number';
  rsTeSumRange = ' (%s to %s)';
  rsTeSumKind = 'Creates: %s, named by %s';
  rsTeSumOrigin = 'Designed on: %s';
  rsTeTitleNew = 'New entry template';
  rsTeTitleEdit = 'Entry template';
  rsTeName = 'Name';
  rsTeNameHint = 'what this template creates: POSIX user, team group, department...';
  rsTeDescription = 'Description';
  rsTeDescHint = 'optional: when to use it';
  rsTeClasses = 'Object classes';
  rsTeValues = 'Values of the new entry';
  rsTeUndo = 'Undo';
  rsTeClean = 'Remove the %d value(s) these classes do not allow';
  rsTeChooseClass = 'Choose what the entry is...';
  rsTeAddAuxiliary = 'Auxiliary class';
  rsTeAddAttribute = 'Add an attribute';
  rsTeEmptyTitle = 'Start with the kind of entry.';
  rsTeEmptyHint = 'A person, a group, an organizational unit: the class decides which attributes are required.';
  rsTeSourceFixed = 'Fixed';
  rsTeSourceAsk = 'Ask';
  rsTeSourceCompose = 'Compose';
  rsTeSourceNumber = 'Number';
  rsTeSourceRandom = 'Random';
  rsTeCapLength = 'length';
  rsTeBadLength = '%s: the length is a whole number of characters.';
  rsTeSumRandom = '%s: random password, %d characters, shown once (%s)';
  rsTeAccount = 'Account';
  rsTeMustChange = 'User must change password at next logon';
  rsTeNeverExpires = 'Password never expires';
  rsTeAccountDisabled = 'Account is disabled';
  rsTeHelpSecretRandom = 'Random: a strong password is drawn for each entry when it is created, shown once ' +
    '(and offered as a file for a batch), never kept in the template.';
  rsTeHelpSecretAdAsk = 'Ask: the password is typed twice in the form; Active Directory receives it with the ' +
    'new account, in the same request.';
  rsTeRdnChip = 'RDN';
  rsTeRdnHint = 'Names the entry: this value becomes the first part of its DN (click to choose)';
  rsTeHintFixed = 'value given to every entry';
  rsTeHintDefault = 'none';
  rsTeHintAny = 'any';
  rsTeCapLabel = 'label';
  rsTeCapDefault = 'default';
  rsTeCapFrom = 'from';
  rsTeCapTo = 'to';
  rsTeRequired = 'required';
  rsTeOptional = 'optional';
  rsTeForcedByClass = 'Required by %s: the form always insists on a value.';
  rsTeForcedByName = 'This value names the entry: it cannot stay empty.';
  rsTeForcedByCompose = 'Used to compose %s: left empty, it would leave holes in those values.';
  rsTeOptionalHint = 'Whether the form insists on a value (click to switch)';
  rsTeAfterHighest = 'Highest + 1';
  rsTeFirstFree = 'First free';
  rsTeAddAttrPart = 'Attribute';
  rsTeAddTextPart = 'Text';
  rsTeAddCounterPart = 'Number';
  rsTeCounterChip = 'number';
  rsTeCounterNone = 'nothing';
  rsTeCounterSepNone = 'No separator (jdupont1)';
  rsTeCounterSepDot = 'Dot (jean.dupont.1)';
  rsTeCounterSepDash = 'Hyphen (jdupont-1)';
  rsTeCounterSepUnder = 'Underscore (jdupont_1)';
  rsTeCounterDigits = 'At least %d digits (%s)';
  rsTeCounterAnyDigits = 'As many digits as needed (1, 2 ... 10)';
  rsTeCounterOmitOne = 'Nothing for the first one (jdupont, jdupont2)';
  rsTeNoOtherAttr = '(no other attribute in the template)';
  rsTeSample = '= %s';
  rsTeLocked = 'Required by the classes of the template: it cannot be removed.';
  rsTeBadNumber = '%s: the range takes whole numbers.';
  rsTeValid = 'Valid template.';
  rsTeValidWarn = 'Valid template, with %d warning(s): %s';
  rsTeInvalid = 'Not valid: %s';
  rsTeWords = 'Creates: %s';
  rsTeWordsAsk = 'Asks for: %s';
  rsTeWordsNone = 'Creates: (choose a class first)';
  rsTeContainer = '<container>';
  rsTeCaseAsIs = 'As typed';
  rsTeCaseUpper = 'UPPERCASE';
  rsTeCaseLower = 'lowercase';
  rsTeCaseCapital = 'Capitalized (First Letter Of Each Word)';
  rsTeBadgeUpper = 'UPPER';
  rsTeBadgeLower = 'lower';
  rsTeBadgeCapital = 'Capital';
  rsTeBadgeFirst = '1st letter';
  rsTeBadgeTake = '%d letters';
  rsTeBadgePlain = 'no accents';
  rsTeTakeAll = 'Whole value';
  rsTeTakeOne = 'First letter only';
  rsTeTakeMany = 'First %d letters';
  rsTePlain = 'Without accents or spaces';
  rsTeUseAttr = 'Use another attribute';
  rsTeMoveLeft = 'Move left'#9'Shift+Left';
  rsTeMoveRight = 'Move right'#9'Shift+Right';
  rsTeRemove = 'Remove'#9'Del';
  rsTeEditText = 'Edit the text'#9'Enter';
  rsTeMenuDuplicate = 'Add another value';
  rsTeMenuRdn = 'Name the entry with this value (RDN)';
  rsTeMenuUp = 'Move up'#9'Alt+Up';
  rsTeMenuDown = 'Move down'#9'Alt+Down';
  rsTeMenuDelete = 'Remove'#9'Alt+Del';
  rsTePickStructTitle = 'Kind of entry';
  rsTePickStructHelp = 'The structural class says what the entry is. Its required attributes are added to the template.';
  rsTePickAuxTitle = 'Auxiliary class';
  rsTePickAuxHelp = 'An auxiliary class brings more attributes (posixAccount, shadowAccount...). Its required attributes are added to the template.';
  rsTePickAttrTitle = 'Add an attribute';
  rsTePickAttrHelp = 'Attributes allowed by the classes of the template.';
  rsTePickChoose = 'Choose';
  rsTeColClass = 'Class';
  rsTeColAttr = 'Attribute';
  rsTeColUse = 'Use';
  rsTeColDesc = 'Description';
  rsTeUseRequired = 'required';
  rsTeUseOptional = 'optional';
  rsTeUseAgain = 'another value';
  rsTeMust = 'Required: %s';
  rsTeMay = 'Allowed: %s';
  rsTeNoSchema = 'The connection is closed: the template cannot be checked against a schema.';
  rsTeNoClassLeft = 'No other class to add.';
  rsTeNoAttrLeft = 'Every attribute allowed by these classes is already in the template.';
  rsTeHelpFixed = 'Fixed: every entry created from the template gets this value. It must fit the syntax of the attribute.';
  rsTeHelpAsk = 'Ask: the value is typed when the entry is created. The label is what the form shows; the default is proposed and can be changed.';
  rsTeHelpCompose = 'Compose: the value is built from other attributes and fixed texts. Click an attribute token to choose its case, how many letters to keep, or to drop accents. Drag a token to move it.';
  rsTeHelpCounter = 'Number: the lowest number that keeps every value carrying it free in the directory, the ' +
    'same in all of them (jdupont1, jean.dupont.1@...). It starts at 1; it can be left out for the first one.';
  rsTeHelpNumber = 'Number: the directory is searched for a free number when the entry is created. "Highest + 1" never reuses a number; "First free" fills the gaps, at the risk of handing a deleted account''s number to someone else.';
  rsTeHelpSecret = 'This secret is asked for when the entry is created, with the password tools: the template keeps none.';
  rsTeHelpSecretAsk = 'Ask: the password is set with the password tools when the entry is created; the template keeps none.';
  rsTeHelpSecretFixed = 'Fixed: every entry gets this password, stored in the chosen format. The template keeps it ' +
    'inside the encrypted document; an export asks before writing it out.';
  rsTeHelpSecretCompose = 'Compose: the password is built from other values when the entry is created (test ' +
    'accounts, or a {SASL} identity such as uid@REALM), then stored in the chosen format.';
  rsTeHelpSecretAd = 'Active Directory hashes the password itself. It goes with the new account in the same ' +
    'request: refused by the domain policy, nothing is created.';
  rsTeHintPassword = 'password given to every entry';
  rsTeHintIdentity = 'identity, e.g. user@REALM';
  rsTeFormatHint = 'How the server stores the password (the formats this server takes)';
  rsTeFormatAd = 'hashed by Active Directory';
  rsTeHelpStart = 'Choose a class, then decide for each attribute where its value comes from.';
  rsTeHelpRdn = 'This value names the entry.';
  rsTeKeys = 'Ctrl+Enter add an attribute  -  Alt+Up/Down move  -  Alt+Del remove  -  Ctrl+Z undo  -  Ctrl+S save';
  rsTeAttrSingle = 'single-valued';
  rsTeAttrRequiredBy = 'required by %s';
  rsTeAttrOptionalIn = 'optional (%s)';

implementation

uses
  Math, LCLIntf, LazUTF8, uTheme, uConnections, uStrings, uMenuBar, uPickDialog, uRtMessage, uServerKind,
  uAttributeCodec, uTemplateLibrary, uLdapDn, uDirectoryService, uEntryPickDialog;

const
  RAIL_X = 6;
  RAIL_W = 3;
  ROW_LEFT = 16;
  TAKES: array[0..5] of Integer = (0, 1, 2, 3, 4, 8);
  // etiquettes des commandes de menu: millier = commande, reste = valeur
  MC_CASE = 1000;
  MC_TAKE = 2000;
  MC_PLAIN = 3000;
  MC_ATTR = 4000;
  MC_PART_LEFT = 5000;
  MC_PART_RIGHT = 5001;
  MC_PART_REMOVE = 5002;
  MC_PART_EDIT = 5003;
  MC_ADD_PART = 6000;
  MC_ROW_DUP = 7000;
  MC_ROW_RDN = 7001;
  MC_ROW_UP = 7002;
  MC_ROW_DOWN = 7003;
  MC_ROW_DELETE = 7004;
  MC_CTR_PREFIX = 8000;
  MC_CTR_DIGITS = 8100;
  MC_CTR_OMIT = 8200;
  COUNTER_PREFIXES: array[0..3] of string = ('', '.', '-', '_');

function TemplateSourceColor(ASource: TTplSource): TColor;
var
  dark: Boolean;
begin
  dark := IsDarkColor(clAppBg);
  case ASource of
    tsAsk: if dark then Result := RgbHexToColor($5B9BF0) else Result := RgbHexToColor($1F5FC4);
    tsCompose: if dark then Result := RgbHexToColor($B48CF2) else Result := RgbHexToColor($6F42C1);
    tsNumber: if dark then Result := RgbHexToColor($3CC2B0) else Result := RgbHexToColor($0F7F72);
    tsRandom: if dark then Result := RgbHexToColor($E0A458) else Result := RgbHexToColor($A15C00);
  else
    if dark then Result := RgbHexToColor($9AA7B8) else Result := RgbHexToColor($55606E);
  end;
end;

function TemplateSourceName(ASource: TTplSource): string;
begin
  case ASource of
    tsAsk: Result := rsTeSourceAsk;
    tsCompose: Result := rsTeSourceCompose;
    tsNumber: Result := rsTeSourceNumber;
    tsRandom: Result := rsTeSourceRandom;
  else
    Result := rsTeSourceFixed;
  end;
end;

function HasCounter(const F: TTplField): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(F.Parts) do
    if F.Parts[i].Kind = tpCounter then Exit(True);
  Result := False;
end;

function PartBadge(const APart: TTplPart): string;

  procedure Add(const S: string);
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + S;
  end;

begin
  Result := '';
  if APart.Kind = tpCounter then
  begin
    Result := CounterText(APart, 1);
    if Result = '' then Result := rsTeCounterNone;
    Exit(Result + ', ' + CounterText(APart, 2) + ', ' + CounterText(APart, 3) + '...');
  end;
  if APart.Kind <> tpAttr then Exit;
  case APart.CaseFn of
    tcUpper: Add(rsTeBadgeUpper);
    tcLower: Add(rsTeBadgeLower);
    tcCapital: Add(rsTeBadgeCapital);
  end;
  if APart.Take = 1 then Add(rsTeBadgeFirst)
  else if APart.Take > 1 then Add(Format(rsTeBadgeTake, [APart.Take]));
  if APart.Plain then Add(rsTeBadgePlain);
end;

function FieldSummary(const F: TTplField; ASensitive: TSensitivePolicy): string;
var
  i: Integer;
  parts, lo, hi, badge: string;
  hidden: Boolean;
begin
  // Un apercu de modele n'affiche jamais un mot de passe, valide ou pas.
  hidden := TemplatePasswordField(F, ASensitive);
  if hidden and (F.Source = tsFixed) and not TemplateSecretShown(F) then
    Exit(Format(rsTeSumPwdFixed, [F.Attr, F.Scheme]));
  case F.Source of
    tsAsk:
      if F.Optional then Result := Format(rsTeSumAskOptional, [F.Attr, FieldPrompt(F)])
      else Result := Format(rsTeSumAsk, [F.Attr, FieldPrompt(F)]);
    tsCompose:
      begin
        parts := '';
        for i := 0 to High(F.Parts) do
        begin
          if parts <> '' then parts := parts + ' + ';
          if (F.Parts[i].Kind = tpText) and hidden then
            parts := parts + '"' + rsTeSumHiddenText + '"'
          else if F.Parts[i].Kind = tpText then
            parts := parts + '"' + F.Parts[i].Text + '"'
          else if F.Parts[i].Kind = tpCounter then
            parts := parts + rsTeCounterChip + ' [' + PartBadge(F.Parts[i]) + ']'
          else
          begin
            parts := parts + F.Parts[i].Text;
            badge := PartBadge(F.Parts[i]);
            if badge <> '' then parts := parts + ' [' + badge + ']';
          end;
        end;
        if hidden then Result := Format(rsTeSumPwdCompose, [F.Attr, parts, F.Scheme])
        else Result := Format(rsTeSumCompose, [F.Attr, parts]);
      end;
    tsRandom:
      Result := Format(rsTeSumRandom, [F.Attr, F.RandomLength, F.Scheme]);
    tsNumber:
      begin
        if F.NumberMode = tnFirstFree then Result := Format(rsTeSumNumberFirst, [F.Attr])
        else Result := Format(rsTeSumNumberHighest, [F.Attr]);
        if F.HasMin or F.HasMax then
        begin
          lo := rsTeHintAny;
          hi := rsTeHintAny;
          if F.HasMin then lo := IntToStr(F.Min);
          if F.HasMax then hi := IntToStr(F.Max);
          Result := Result + Format(rsTeSumRange, [lo, hi]);
        end;
      end;
  else
    Result := Format(rsTeSumFixed, [F.Attr, F.Value]);
  end;
end;

function TemplateKindText(const T: TEntryTemplate): string;
var
  i: Integer;
begin
  Result := T.Structural;
  for i := 0 to High(T.Auxiliaries) do
    Result := Result + ' + ' + T.Auxiliaries[i];
end;

function TemplateSummary(const T: TEntryTemplate; ASensitive: TSensitivePolicy): string;
var
  i: Integer;
begin
  Result := '';
  if Trim(T.Description) <> '' then Result := Trim(T.Description) + #10;
  Result := Result + Format(rsTeSumKind, [TemplateKindText(T), T.RdnAttr]) + #10;
  if T.Origin <> '' then Result := Result + Format(rsTeSumOrigin, [T.Origin]) + #10;
  for i := 0 to High(T.Fields) do
    Result := Result + '  ' + FieldSummary(T.Fields[i], ASensitive) + #10;
  if Length(T.Groups) > 0 then
    Result := Result + Format(rsTeSumGroups, [string.Join('; ', T.Groups)]) + #10;
end;

procedure FillGroupChips(ABar: TRtChipBar; AGroups: TGroupTargets; AEditable: Boolean;
  const AAddCaption: string);
var
  i: Integer;
  t: TGroupTarget;
  ink: TColor;
  badge, hint: string;
begin
  ABar.Clear;
  ABar.ClearActions;
  hint := '';
  for i := 0 to AGroups.Count - 1 do
  begin
    t := AGroups[i];
    badge := '';
    case t.State of
      gtsReading:
        begin
          ink := ShellStateColor(usMuted);
          badge := '...';
        end;
      gtsProblem:
        begin
          ink := ShellStateColor(usError);
          badge := '!';
        end;
    else
      ink := clAccent;
    end;
    ABar.AddChip(RdnCaption(t.Dn), ink, badge, AEditable);
    if hint <> '' then hint := hint + LineEnding;
    hint := hint + t.Dn;
    if t.State = gtsProblem then hint := hint + ': ' + t.Problem;
  end;
  if AEditable then ABar.AddAction('plus', AAddCaption);
  ABar.Hint := hint;
  ABar.ShowHint := hint <> '';
end;

function MutedColor(ABack: TColor): TColor;
begin
  Result := BlendColor(clAppFg, ABack, 58);
end;

function EditTemplate(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
  var ATemplate: TEntryTemplate): Boolean;
var
  d: TTemplateEditor;
begin
  d := TTemplateEditor.CreateEditor(AOwner, ACtx, AProfileUuid, ATemplate);
  try
    Result := d.ShowModal = mrOk;
    if Result then ATemplate := CloneTemplate(d.Template);
  finally
    d.Free;
  end;
end;

{ TTeRow }

constructor TTeRow.CreateRow(AOwner: TWinControl; ADlg: TTemplateEditor; AKind: TTeRowKind;
  AIndex: Integer);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FDlg := ADlg;
  FKind := AKind;
  FIndex := AIndex;
  TabStop := False;
  Parent := AOwner;
  Align := alTop;
  if AKind = trkEmpty then Height := ADlg.Metrics.RowH * 3
  else Height := ADlg.Metrics.RowH;
  BuildControls;
  FBuilt := True;
  Restyle;
end;

function TTeRow.MakeField(const AHint: string): TEdit;
begin
  Result := TEdit.Create(Self);
  Result.Parent := Self;
  Result.BorderStyle := bsNone;
  Result.AutoSize := False;
  // Couleurs posees des la creation: apres coup, GTK3 montre un instant le fond du theme systeme.
  Result.Color := clEditorBg;
  Result.Font.Color := clEditorFg;
  Result.TextHint := AHint;
  Result.OnEnter := @FieldEnter;
  Result.OnExit := @FieldExit;
  Result.OnChange := @FieldChange;
end;

function TTeRow.MakeButton(const AIcon, AText: string; AInk: TColor): TRtFlatButton;
begin
  Result := TRtFlatButton.Create(Self);
  Result.Parent := Self;
  Result.Setup(AIcon, AText, AInk);
end;

function TTeRow.SourceColor: TColor;
begin
  if (FKind = trkField) and (FIndex <= High(FDlg.FT.Fields)) then
    Result := TemplateSourceColor(FDlg.FT.Fields[FIndex].Source)
  else
    Result := clAccent;
end;

procedure TTeRow.BuildControls;
var
  f: TTplField;
  allowed: TTplIndexes;
  labels: array of string;
  colors: array of TColor;
  i, sel: Integer;
  present: Boolean;
begin
  case FKind of
    trkAdd:
      begin
        FAddBtn := MakeButton('plus', rsTeAddAttribute, clAccent);
        FAddBtn.OnClick := @AddClick;
      end;
    trkEmpty:
      begin
        FAddBtn := MakeButton('box', rsTeChooseClass, clAccent);
        FAddBtn.OnClick := @AddClick;
      end;
    trkField:
      begin
        f := FDlg.FT.Fields[FIndex];
        FLocked := FDlg.FieldRequired(FIndex) and (FieldCount(FDlg.FT, f.Attr) < 2);
        FRdnChip := MakeButton('', rsTeRdnChip, clDefault);
        FRdnChip.TabStop := False;
        FRdnChip.Hint := rsTeRdnHint;
        FRdnChip.ShowHint := True;
        FRdnChip.OnClick := @RdnClick;
        // La source en place reste montree meme si le schema n'en veut plus: on signale, on ne cache pas.
        allowed := FDlg.AllowedSources(FIndex);
        present := False;
        for i := 0 to High(allowed) do
          if TTplSource(allowed[i]) = f.Source then present := True;
        if not present then
        begin
          SetLength(allowed, Length(allowed) + 1);
          allowed[High(allowed)] := Ord(f.Source);
        end;
        SetLength(FSources, Length(allowed));
        labels := nil;
        colors := nil;
        SetLength(labels, Length(allowed));
        SetLength(colors, Length(allowed));
        sel := 0;
        for i := 0 to High(allowed) do
        begin
          FSources[i] := TTplSource(allowed[i]);
          labels[i] := TemplateSourceName(FSources[i]);
          colors[i] := TemplateSourceColor(FSources[i]);
          if FSources[i] = f.Source then sel := i;
        end;
        FSource := TRtSegmented.Create(Self);
        FSource.Parent := Self;
        FSource.SetChoices(labels, sel);
        FSource.SetColors(colors);
        FSource.OnChange := @SourceChange;
        FDlg.FUpdating := True;
        try
          case f.Source of
            tsFixed:
              if FDlg.FieldSecret(FIndex) then
              begin
                if TemplateSecretShown(f) then FValue := MakeField(rsTeHintIdentity)
                else
                begin
                  FValue := MakeField(rsTeHintPassword);
                  FValue.PasswordChar := '*';
                end;
                FValue.MaxLength := TEMPLATE_TEXT_MAX;
                FValue.Text := f.Value;
              end
              else
              begin
                FValue := MakeField(rsTeHintFixed);
                FValue.Text := f.Value;
              end;
            tsAsk:
              begin
                FCap1 := rsTeCapLabel;
                FPrompt := MakeField(DefaultPrompt(f.Attr));
                FPrompt.MaxLength := TEMPLATE_PROMPT_MAX;
                FPrompt.Text := f.Prompt;
                if not FDlg.FieldSecret(FIndex) then
                begin
                  FCap2 := rsTeCapDefault;
                  FValue := MakeField(rsTeHintDefault);
                  FValue.Text := f.Value;
                end;
                if not FDlg.FieldRequired(FIndex) then
                begin
                  FOptional := MakeButton('', rsTeOptional, clDefault);
                  FOptional.TabStop := False;
                  FOptional.Hint := rsTeOptionalHint;
                  FOptional.ShowHint := True;
                  FOptional.OnClick := @OptionalClick;
                end;
                SyncForced;
              end;
            tsCompose:
              begin
                FChips := TRtChipBar.Create(Self);
                FChips.Parent := Self;
                FChips.OnChipClick := @ChipClick;
                FChips.OnChipClose := @ChipClose;
                FChips.OnChipEdited := @ChipEdited;
                FChips.OnChipMoved := @ChipMoved;
                FChips.OnActionClick := @ChipAction;
                FChips.OnLayoutChanged := @ChipsLayout;
                FChips.OnEnter := @ChipsEnter;
                FillChips;
              end;
            tsNumber:
              begin
                FMode := TRtSegmented.Create(Self);
                FMode.Parent := Self;
                FMode.SetChoices([rsTeAfterHighest, rsTeFirstFree], Ord(f.NumberMode));
                FMode.SetColors([TemplateSourceColor(tsNumber), TemplateSourceColor(tsNumber)]);
                FMode.OnChange := @ModeChange;
                FCap1 := rsTeCapFrom;
                FCap2 := rsTeCapTo;
                FMin := MakeField(rsTeHintAny);
                FMax := MakeField(rsTeHintAny);
                if f.HasMin then FMin.Text := IntToStr(f.Min);
                if f.HasMax then FMax.Text := IntToStr(f.Max);
              end;
            tsRandom:
              begin
                FCap1 := rsTeCapLength;
                FMin := MakeField(IntToStr(RANDOM_PWD_DEFAULT));
                FMin.MaxLength := 3;
                FMin.Text := IntToStr(f.RandomLength);
              end;
          end;
          if FDlg.FieldSecret(FIndex) and (f.Source in [tsFixed, tsCompose, tsRandom]) then BuildFormat(f);
        finally
          FDlg.FUpdating := False;
        end;
        FMenuBtn := MakeButton('', '', clDefault);
        FMenuBtn.Glyph := rbgDots;
        FMenuBtn.TabStop := False;
        FMenuBtn.OnClick := @MenuClick;
        if FLocked then
        begin
          FDelBtn := MakeButton('lock', '', clDefault);
          FDelBtn.Hint := rsTeLocked;
          FDelBtn.ShowHint := True;
        end
        else
          FDelBtn := MakeButton('trash', '', clDefault);
        FDelBtn.TabStop := False;
        FDelBtn.OnClick := @DeleteClick;
      end;
  end;
end;

procedure TTeRow.BuildFormat(const F: TTplField);
var
  formats: TStringArray;
  k: Integer;
begin
  formats := TemplatePasswordFormats(FDlg.Provider);
  if (Length(formats) = 1) and SameText(formats[0], TEMPLATE_SCHEME_AD) and
     ((F.Scheme = '') or SameText(F.Scheme, TEMPLATE_SCHEME_AD)) then
  begin
    FFormatCap := rsTeFormatAd;
    Exit;
  end;
  FFormat := TRtComboBox.Create(Self);
  FFormat.Parent := Self;
  FFormat.TabStop := True;
  FFormat.Hint := rsTeFormatHint;
  FFormat.ShowHint := True;
  for k := 0 to High(formats) do
    FFormat.Items.Add(formats[k]);
  // Format venu d'un autre serveur: montre tel quel, la ligne dit ce qui ne va pas.
  if (F.Scheme <> '') and (FFormat.Items.IndexOf(F.Scheme) < 0) then FFormat.Items.Add(F.Scheme);
  FFormat.ItemIndex := FFormat.Items.IndexOf(F.Scheme);
  FFormat.OnChange := @FormatChange;
end;

procedure TTeRow.FillChips;
var
  f: TTplField;
  i: Integer;
begin
  if FChips = nil then Exit;
  f := FDlg.FT.Fields[FIndex];
  FFilling := True;
  try
    FChips.Clear;
    for i := 0 to High(f.Parts) do
      if f.Parts[i].Kind = tpText then
        FChips.AddTextChip(f.Parts[i].Text)
      else if f.Parts[i].Kind = tpCounter then
        FChips.AddChip(rsTeCounterChip, FDlg.PartColor(f.Parts[i]), PartBadge(f.Parts[i]))
      else
        FChips.AddChip(f.Parts[i].Text, FDlg.PartColor(f.Parts[i]), PartBadge(f.Parts[i]));
    FChips.ClearActions;
    FChips.AddAction('plus', rsTeAddAttrPart);
    FChips.AddAction('plus', rsTeAddTextPart);
    // Un seul numero par valeur, et jamais dans un secret: le suivant se devinerait.
    if not FDlg.FieldSecret(FIndex) and not HasCounter(f) then
      FChips.AddAction('plus', rsTeAddCounterPart);
  finally
    FFilling := False;
  end;
  LayoutRow;
end;

procedure TTeRow.Restyle;
var
  i: Integer;
begin
  ThemeControlTree(Self);
  FBase := clAppBg;
  if FKind = trkField then FBase := BlendColor(SourceColor, clAppBg, 4);
  StyleRdnChip;
  StyleOptional;
  if FChips <> nil then FChips.Font.Assign(Font);
  SetCurrentLook(FIsCurrent);
  if FMenuBtn <> nil then FMenuBtn.Ink := MutedColor(FBase);
  if FDelBtn <> nil then FDelBtn.Ink := MutedColor(FBase);
  for i := 0 to ControlCount - 1 do
    if (Controls[i] is TRtFlatButton) and (Controls[i] <> FRdnChip) then
      TRtFlatButton(Controls[i]).FitWidth;
  LayoutRow;
end;

procedure TTeRow.StyleRdnChip;
var
  on: Boolean;
begin
  if FRdnChip = nil then Exit;
  on := (FIndex <= High(FDlg.FT.Fields)) and
    SameAttr(FDlg.FT.Fields[FIndex].Attr, FDlg.FT.RdnAttr) and
    (FieldIndex(FDlg.FT, FDlg.FT.RdnAttr) = FIndex);
  if on then
  begin
    FRdnChip.Fill := clAccent;
    FRdnChip.Border := clAccent;
    FRdnChip.Ink := clAppBg;
  end
  else
  begin
    FRdnChip.Fill := clNone;
    FRdnChip.Border := BlendColor(clAppFg, FBase, 12);
    FRdnChip.Ink := BlendColor(clAppFg, FBase, 26);
  end;
  FRdnChip.Font.Style := [fsBold];
  FRdnChip.Invalidate;
end;

procedure TTeRow.StyleOptional;
var
  c: TColor;
begin
  if (FOptional = nil) or (FIndex > High(FDlg.FT.Fields)) then Exit;
  if FDlg.FT.Fields[FIndex].Optional then
  begin
    FOptional.Text := rsTeOptional;
    FOptional.Fill := clNone;
    FOptional.Border := BlendColor(clAppFg, FBase, 22);
    FOptional.Ink := BlendColor(clAppFg, FBase, 55);
  end
  else
  begin
    c := TemplateSourceColor(tsAsk);
    FOptional.Text := rsTeRequired;
    FOptional.Fill := BlendColor(c, FBase, 16);
    FOptional.Border := BlendColor(c, FBase, 50);
    FOptional.Ink := c;
  end;
  FOptional.Invalidate;
end;

// Pas de choix quand le schema l'exige, que la valeur nomme l'entree ou qu'une composition la
// reprend: la pastille au choix cede la place a celle qui ne se discute pas.
procedure TTeRow.SyncForced;
var
  forced: Boolean;
  reason: string;
begin
  if (FKind <> trkField) or (FPrompt = nil) or (FIndex > High(FDlg.FT.Fields)) then Exit;
  reason := FDlg.RequiredReason(FIndex);
  forced := reason <> '';
  if Hint <> reason then Hint := reason;
  ShowHint := forced;
  if (forced = FForced) and ((FOptional = nil) or (FOptional.Visible = not forced)) then Exit;
  FForced := forced;
  if FOptional <> nil then FOptional.Visible := not forced;
  LayoutRow;
end;

procedure TTeRow.SetCurrentLook(AValue: Boolean);
var
  i: Integer;
begin
  FIsCurrent := AValue;
  if AValue then Color := BlendColor(clAccent, FBase, 9) else Color := FBase;
  if FChips <> nil then FChips.Color := Color;
  Invalidate;
  for i := 0 to ControlCount - 1 do
    Controls[i].Invalidate;
end;

procedure TTeRow.SetError(const AError: string; AWarning: Boolean);
begin
  if (FError = AError) and (FWarning = AWarning) then Exit;
  FError := AError;
  FWarning := AWarning;
  Invalidate;
end;

procedure TTeRow.SetNote(const ANote: string);
begin
  if FChips <> nil then FChips.Note := ANote;
end;

procedure TTeRow.LayoutRow;
var
  m: TTeMetrics;
  cy, right, x, w, h, half, capW, optW, need: Integer;
begin
  // Parent et Align declenchent la mise en page avant que les controles existent.
  if not FBuilt or FInLayout or FFilling then Exit;
  FInLayout := True;
  try
    m := FDlg.Metrics;
    cy := m.RowH div 2;
    {$IFDEF LCLGtk3}
    // GTK3 impose a l'entry la hauteur minimale de son theme: on la contraint au cadre.
    if FValue <> nil then FValue.Constraints.MaxHeight := m.EditH;
    if FPrompt <> nil then FPrompt.Constraints.MaxHeight := m.EditH;
    if FMin <> nil then FMin.Constraints.MaxHeight := m.EditH;
    if FMax <> nil then FMax.Constraints.MaxHeight := m.EditH;
    {$ENDIF}
    case FKind of
      trkAdd:
        FAddBtn.SetBounds(ROW_LEFT + m.ChipW + 8, cy - m.BtnH div 2, FAddBtn.PreferredWidth, m.BtnH);
      trkEmpty:
        begin
          w := FAddBtn.PreferredWidth;
          FAddBtn.SetBounds((ClientWidth - w) div 2, (ClientHeight * 2) div 3 - m.BtnH div 2, w, m.BtnH);
        end;
      trkField:
        begin
          right := ClientWidth - 8;
          FDelBtn.SetBounds(right - m.BtnW, cy - m.BtnH div 2, m.BtnW, m.BtnH);
          Dec(right, m.BtnW + 2);
          FMenuBtn.SetBounds(right - m.BtnW, cy - m.BtnH div 2, m.BtnW, m.BtnH);
          Dec(right, m.BtnW + 8);
          if FFormat <> nil then
          begin
            FFormat.SetBounds(right - m.FormatW, cy - m.SwitchH div 2, m.FormatW, m.SwitchH);
            Dec(right, m.FormatW + 12);
          end
          else if FFormatCap <> '' then
          begin
            FFormatLeft := right - MeasureText(Font, FFormatCap);
            Dec(right, MeasureText(Font, FFormatCap) + 12);
          end;
          x := ROW_LEFT;
          FRdnChip.SetBounds(x, cy - m.BtnH div 2 + 2, m.ChipW, m.BtnH - 4);
          Inc(x, m.ChipW + 8);
          FAttrLeft := x;
          Inc(x, m.AttrW + 8);
          FSource.SetBounds(x, cy - m.SwitchH div 2, FSource.PreferredWidth, m.SwitchH);
          Inc(x, m.SourceW + 12);
          need := m.RowH;
          w := Max(60, right - x);
          if (FChips <> nil) then
          begin
            h := FChips.PreferredHeight(w);
            need := Max(m.RowH, h + 14);
            FChips.SetBounds(x, 7, w, h);
          end
          else if (FMin <> nil) and (FMode = nil) then
          begin
            FCap1Left := x;
            Inc(x, MeasureText(Font, FCap1) + m.CapGap);
            FMin.SetBounds(x + 7, cy - m.EditH div 2 + 1, Max(40, MeasureText(Font, '0000') + 10), m.EditH);
          end
          else if FMode <> nil then
          begin
            FMode.SetBounds(x, cy - m.SwitchH div 2, FMode.PreferredWidth, m.SwitchH);
            Inc(x, FMode.PreferredWidth + 14);
            capW := MeasureText(Font, FCap1) + m.CapGap;
            FCap1Left := x;
            Inc(x, capW);
            w := Max(56, Min(140, (right - x - MeasureText(Font, FCap2) - m.CapGap - 20) div 2));
            FMin.SetBounds(x + 7, cy - m.EditH div 2 + 1, w - 14, m.EditH);
            Inc(x, w + 12);
            FCap2Left := x;
            Inc(x, MeasureText(Font, FCap2) + m.CapGap);
            FMax.SetBounds(x + 7, cy - m.EditH div 2 + 1, w - 14, m.EditH);
          end
          else if FPrompt <> nil then
          begin
            optW := 0;
            // Meme largeur pour la pastille au choix et pour celle imposee: les champs restent alignes.
            half := Max(MeasureText(Font, rsTeOptional), MeasureText(Font, rsTeRequired) +
              ScreenIconSize(14) + 5) + 22;
            if FForced then
            begin
              optW := half;
              FForcedRect := Rect(right - optW, cy - m.BtnH div 2 + 2, right, cy + m.BtnH div 2 - 2);
              Inc(optW, 10);
            end;
            if (FOptional <> nil) and not FForced then
            begin
              optW := half;
              FOptional.SetBounds(right - optW, cy - m.BtnH div 2 + 2, optW, m.BtnH - 4);
              Inc(optW, 10);
            end;
            capW := MeasureText(Font, FCap1) + m.CapGap;
            FCap1Left := x;
            Inc(x, capW);
            w := right - optW - x;
            if FValue <> nil then
            begin
              half := (w - MeasureText(Font, FCap2) - m.CapGap - 12) div 2;
              half := Max(60, half);
              FPrompt.SetBounds(x + 7, cy - m.EditH div 2 + 1, half - 14, m.EditH);
              Inc(x, half + 12);
              FCap2Left := x;
              Inc(x, MeasureText(Font, FCap2) + m.CapGap);
              FValue.SetBounds(x + 7, cy - m.EditH div 2 + 1, Max(40, right - optW - x - 14), m.EditH);
            end
            else
              FPrompt.SetBounds(x + 7, cy - m.EditH div 2 + 1, Max(60, Min(w, 320)) - 14, m.EditH);
          end
          else if FValue <> nil then
            FValue.SetBounds(x + 7, cy - m.EditH div 2 + 1, Max(40, w - 14), m.EditH);
          if Height <> need then Height := need;
        end;
    end;
  finally
    FInLayout := False;
  end;
  Invalidate;
end;

procedure TTeRow.Resize;
begin
  inherited Resize;
  if FDlg <> nil then LayoutRow;
end;

procedure TTeRow.DrawFrame(AEdit: TEdit; ABad: Boolean);
var
  r: TRect;
begin
  if (AEdit = nil) or not AEdit.Visible then Exit;
  r := AEdit.BoundsRect;
  InflateRect(r, 7, 5);
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clEditorBg;
  if ABad then Canvas.Pen.Color := DialogStateColor(usError)
  else if AEdit.Focused then Canvas.Pen.Color := clAccent
  else Canvas.Pen.Color := BlendColor(clAppFg, Color, 30);
  Canvas.Pen.Width := 1;
  Canvas.RoundRect(r.Left, r.Top, r.Right, r.Bottom, 8, 8);
end;

procedure TTeRow.Paint;
var
  m: TTeMetrics;
  y, w: Integer;
  f: TTplField;
  r: TRect;
  rail: TColor;
  bmp: TBitmap;
  rangeBad: Boolean;
begin
  m := FDlg.Metrics;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);
  Canvas.Font.Assign(Font);
  y := (m.RowH - Canvas.TextHeight('Ag')) div 2;
  case FKind of
    trkEmpty:
      begin
        Canvas.Brush.Style := bsClear;
        Canvas.Font.Style := [fsBold];
        Canvas.Font.Color := clAppFg;
        Canvas.TextOut((ClientWidth - Canvas.TextWidth(rsTeEmptyTitle)) div 2,
          ClientHeight div 3 - Canvas.TextHeight('Ag'), rsTeEmptyTitle);
        Canvas.Font.Style := [];
        Canvas.Font.Color := MutedColor(Color);
        Canvas.TextOut((ClientWidth - Canvas.TextWidth(rsTeEmptyHint)) div 2,
          ClientHeight div 3 + 2, rsTeEmptyHint);
      end;
    trkField:
      begin
        if FIndex > High(FDlg.FT.Fields) then Exit;
        f := FDlg.FT.Fields[FIndex];
        if FIsCurrent then
        begin
          Canvas.Brush.Color := clAccent;
          Canvas.FillRect(Rect(0, 2, 3, ClientHeight - 2));
        end;
        rail := SourceColor;
        if (FError <> '') and not FWarning then rail := DialogStateColor(usError);
        Canvas.Brush.Color := rail;
        Canvas.FillRect(Rect(RAIL_X, 4, RAIL_X + RAIL_W, ClientHeight - 4));
        DrawFrame(FValue);
        DrawFrame(FPrompt);
        rangeBad := (f.Source = tsNumber) and f.HasMin and f.HasMax and (f.Min >= f.Max);
        DrawFrame(FMin, rangeBad);
        DrawFrame(FMax, rangeBad);
        Canvas.Brush.Style := bsClear;
        if FDlg.FieldRequired(FIndex) then Canvas.Font.Style := [fsBold];
        if (FError <> '') and not FWarning then Canvas.Font.Color := DialogStateColor(usError)
        else if FError <> '' then Canvas.Font.Color := DialogStateColor(usWarning)
        else Canvas.Font.Color := clAppFg;
        w := m.AttrW;
        r := Rect(FAttrLeft, 0, FAttrLeft + w, m.RowH);
        Canvas.TextRect(r, r.Left, y, f.Attr);
        Canvas.Font.Style := [];
        Canvas.Font.Color := MutedColor(Color);
        if FCap1 <> '' then Canvas.TextOut(FCap1Left, y, FCap1);
        if (FCap2 <> '') and ((FValue <> nil) or (FMax <> nil)) then Canvas.TextOut(FCap2Left, y, FCap2);
        if FFormatCap <> '' then Canvas.TextOut(FFormatLeft, y, FFormatCap);
        if FForced then
        begin
          rail := DialogStateColor(usError);
          Canvas.Brush.Style := bsSolid;
          Canvas.Brush.Color := BlendColor(rail, Color, 16);
          Canvas.Pen.Color := BlendColor(rail, Color, 55);
          Canvas.RoundRect(FForcedRect.Left, FForcedRect.Top, FForcedRect.Right, FForcedRect.Bottom, 8, 8);
          w := ScreenIconSize(14);
          bmp := IconBitmap('lock', w, rail);
          if bmp <> nil then
            Canvas.Draw(FForcedRect.Left + 10, (FForcedRect.Top + FForcedRect.Bottom - w) div 2, bmp);
          Canvas.Brush.Style := bsClear;
          Canvas.Font.Color := rail;
          Canvas.TextOut(FForcedRect.Left + 10 + w + 5, y, rsTeRequired);
        end;
      end;
  end;
end;

procedure TTeRow.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if FKind <> trkField then Exit;
  FDlg.SetCurrent(FIndex);
end;

procedure TTeRow.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbRight) and (FKind = trkField) then FDlg.ShowRowMenu(Self, True);
end;

procedure TTeRow.FieldChange(Sender: TObject);
begin
  if FDlg.FUpdating or FDlg.FClosing then Exit;
  FDlg.RowEdited(Self, Sender);
end;

procedure TTeRow.FieldEnter(Sender: TObject);
begin
  if FDlg.FClosing then Exit;
  FDlg.SetCurrent(FIndex);
  Invalidate;
end;

procedure TTeRow.FieldExit(Sender: TObject);
begin
  if FDlg.FClosing then Exit;
  Invalidate;
end;

procedure TTeRow.ChipsEnter(Sender: TObject);
begin
  if FDlg.FClosing then Exit;
  FDlg.SetCurrent(FIndex);
end;

procedure TTeRow.SourceChange(Sender: TObject);
begin
  if FDlg.FUpdating or FDlg.FRebuildQueued then Exit;
  if (FSource.ItemIndex < 0) or (FSource.ItemIndex > High(FSources)) then Exit;
  FDlg.SetSource(FIndex, FSources[FSource.ItemIndex]);
end;

procedure TTeRow.ModeChange(Sender: TObject);
begin
  if FDlg.FUpdating or FDlg.FRebuildQueued or (FIndex > High(FDlg.FT.Fields)) then Exit;
  FDlg.PushUndo;
  FDlg.FT.Fields[FIndex].NumberMode := TTplNumberMode(FMode.ItemIndex);
  FDlg.SetCurrent(FIndex);
  FDlg.Recheck;
end;

procedure TTeRow.FormatChange(Sender: TObject);
begin
  if FDlg.FUpdating or FDlg.FRebuildQueued or (FFormat = nil) or (FFormat.ItemIndex < 0) then Exit;
  FDlg.SetFormat(FIndex, FFormat.Text);
end;

procedure TTeRow.RdnClick(Sender: TObject);
begin
  if FDlg.FRebuildQueued then Exit;
  FDlg.SetRdn(FIndex);
end;

procedure TTeRow.OptionalClick(Sender: TObject);
begin
  if FDlg.FRebuildQueued or (FIndex > High(FDlg.FT.Fields)) then Exit;
  FDlg.PushUndo;
  FDlg.FT.Fields[FIndex].Optional := not FDlg.FT.Fields[FIndex].Optional;
  StyleOptional;
  FDlg.SetCurrent(FIndex);
  FDlg.Recheck;
end;

procedure TTeRow.MenuClick(Sender: TObject);
begin
  if FDlg.FRebuildQueued then Exit;
  FDlg.ShowRowMenu(Self, False);
end;

procedure TTeRow.DeleteClick(Sender: TObject);
begin
  if FDlg.FRebuildQueued or FLocked then Exit;
  FDlg.DeleteField(FIndex);
end;

procedure TTeRow.AddClick(Sender: TObject);
begin
  if FDlg.FRebuildQueued then Exit;
  if FKind = trkEmpty then FDlg.ChooseStructural else FDlg.AddAttribute;
end;

procedure TTeRow.ChipsLayout(Sender: TObject);
begin
  LayoutRow;
end;

procedure TTeRow.ChipClick(Sender: TObject; AIndex: Integer; AButton: TMouseButton);
begin
  if FDlg.FRebuildQueued then Exit;
  FDlg.SetCurrent(FIndex);
  FDlg.ShowPartMenu(Self, AIndex);
end;

procedure TTeRow.ChipClose(Sender: TObject; AIndex: Integer);
begin
  if FDlg.FRebuildQueued then Exit;
  FDlg.RemovePart(FIndex, AIndex);
end;

procedure TTeRow.ChipEdited(Sender: TObject; AIndex: Integer; const AText: string);
begin
  if FDlg.FRebuildQueued or FDlg.FClosing or (FIndex > High(FDlg.FT.Fields)) then Exit;
  if AIndex > High(FDlg.FT.Fields[FIndex].Parts) then Exit;
  if AText = '' then
  begin
    FDlg.RemovePart(FIndex, AIndex);
    Exit;
  end;
  FDlg.PushUndo;
  FDlg.FT.Fields[FIndex].Parts[AIndex].Text := AText;
  FillChips;
  FDlg.Recheck;
end;

procedure TTeRow.ChipMoved(Sender: TObject; AFrom, ATo: Integer);
begin
  if FDlg.FRebuildQueued then Exit;
  FDlg.MovePart(FIndex, AFrom, ATo);
end;

procedure TTeRow.ChipAction(Sender: TObject; AIndex: Integer);
begin
  if FDlg.FRebuildQueued then Exit;
  FDlg.SetCurrent(FIndex);
  if AIndex = 0 then
    FDlg.ShowAddPartMenu(Self)
  else if AIndex = 2 then
    FDlg.AddPart(FIndex, CounterPart(''))
  else
  begin
    FDlg.AddPart(FIndex, TextPart(''));
    if FChips <> nil then FChips.EditChip(FChips.Count - 1);
  end;
end;

{ TTemplateEditor }

constructor TTemplateEditor.CreateEditor(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid: string; const ATemplate: TEntryTemplate);
var
  c: TDirectoryConnection;
begin
  if ATemplate.Uuid = '' then inherited CreateDialog(AOwner, rsTeTitleNew, 1240, 820)
  else inherited CreateDialog(AOwner, rsTeTitleEdit, 1240, 820);
  SetIcon('file-text');
  FCtx := ACtx;
  FProfileUuid := AProfileUuid;
  FT := CloneTemplate(ATemplate);
  FRows := TFPList.Create;
  FUndo := TStringList.Create;
  FCurrent := -1;
  c := FCtx.Connections.Find(FProfileUuid);
  if c <> nil then
  begin
    SetTarget(c.Profile.DisplayEndpoint, c.Profile.EnvironmentBadge);
    if FT.Origin = '' then FT.Origin := ServerKindName(Provider);
  end;
  BuildUi;
  ComputeMetrics;
  FUpdating := True;
  try
    FName.Text := FT.Name;
    FDesc.Text := FT.Description;
  finally
    FUpdating := False;
  end;
  // Un modele ouvert sur un autre serveur que le sien y gagne ce que ce schema exige.
  SyncRequiredFields(FT, Schema, Provider, FCtx.Sensitive);
  // AD: la politique du domaine, lue une fois, pour prevenir avant que trois cents creations echouent.
  c := FCtx.Connections.Find(FProfileUuid);
  if (Provider = pkActiveDirectory) and (c <> nil) and c.IsReady and (c.RootDse <> nil) and
     (c.RootDse.FirstValue('defaultNamingContext') <> '') then
  begin
    FPolicyTasks := TDirectoryTasks.Create(FCtx.Connections, FProfileUuid, Self);
    FPolicyTasks.OnMessage := @PolicyMessage;
    FPolicyTasks.ReadEntry('policy', c.RootDse.FirstValue('defaultNamingContext'), AD_POLICY_ATTRS);
  end;
  RebuildRows(-1);
  ApplyTheme;
  OnResize := @FormResized;
end;

destructor TTemplateEditor.Destroy;
begin
  FClosing := True;
  Application.RemoveAsyncCalls(Self);
  FreeAndNil(FPolicyTasks);
  FRows.Free;
  FUndo.Free;
  inherited Destroy;
end;

function TTemplateEditor.AllIssues: TTplIssues;
var
  extra: TTplIssues;
  i: Integer;
begin
  Result := CheckTemplate(FT, Schema, Provider, FCtx.Sensitive, FAnalysis);
  if Provider <> pkActiveDirectory then Exit;
  extra := TemplatePolicyIssues(FT, FPolicy);
  for i := 0 to High(extra) do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := extra[i];
  end;
end;

procedure TTemplateEditor.PolicyMessage(AMsg: TUiMessage; const ATask: TTrackedTask; AEnding: TTaskEnding);
begin
  if FClosing or (AEnding = teStale) or not (AMsg is TEntryMsg) or (TEntryMsg(AMsg).Entry = nil) then Exit;
  FPolicy := AdPolicyFromDomain(TEntryMsg(AMsg).Entry);
  Recheck;
end;

function TTemplateEditor.AccountShown: Boolean;
begin
  // Modele AD seulement. Coche sans objet sur un modele AD: montree, qu'on puisse la decocher.
  Result := TemplateDesignedForAd(FT) and (((Schema <> nil) and TemplateIsAdUser(FAnalysis, Provider)) or
    FT.Account.MustChange or FT.Account.NeverExpires or FT.Account.Disabled);
end;

procedure TTemplateEditor.FillAccount;
var
  shown: Boolean;
begin
  if FAccountRow = nil then Exit;
  FFillingAccount := True;
  try
    FMustChange.Checked := FT.Account.MustChange;
    FNeverExpires.Checked := FT.Account.NeverExpires;
    FAccountDisabled.Checked := FT.Account.Disabled;
  finally
    FFillingAccount := False;
  end;
  shown := AccountShown;
  if FAccountRow.Visible <> shown then
  begin
    FAccountRow.Visible := shown;
    StackByCreation(Body);
  end;
end;

procedure TTemplateEditor.AccountChange(Sender: TObject);
begin
  if FFillingAccount or FUpdating or FClosing then Exit;
  PushUndo;
  FT.Account.MustChange := FMustChange.Checked;
  FT.Account.NeverExpires := FNeverExpires.Checked;
  FT.Account.Disabled := FAccountDisabled.Checked;
  Recheck;
end;

procedure TTemplateEditor.SetAccount(const AAccount: TTplAccount);
begin
  PushUndo;
  FT.Account := AAccount;
  Recheck;
end;

function TTemplateEditor.Schema: TSchemaSnapshot;
var
  c: TDirectoryConnection;
begin
  // Relu a chaque usage: une reconnexion remplace le schema, et l'ancien n'existe plus.
  Result := nil;
  if FCtx = nil then Exit;
  c := FCtx.Connections.Find(FProfileUuid);
  if c <> nil then Result := c.Schema;
end;

function TTemplateEditor.Provider: TProviderKind;
var
  c: TDirectoryConnection;
begin
  Result := pkAuto;
  c := FCtx.Connections.Find(FProfileUuid);
  if c <> nil then Result := EffectiveServerKind(c.Profile, c.RootDse);
end;

procedure TTemplateEditor.BuildUi;
var
  head, statusRow, row: TPanel;
  lbl: TLabel;
begin
  FName := MakeEditRow(Body, rsTeName);
  FName.TextHint := rsTeNameHint;
  FName.MaxLength := TEMPLATE_NAME_MAX;
  FName.OnChange := @HeaderChange;
  FDesc := MakeEditRow(Body, rsTeDescription);
  FDesc.TextHint := rsTeDescHint;
  FDesc.MaxLength := TEMPLATE_DESC_MAX;
  FDesc.OnChange := @HeaderChange;
  FClassRow := MakeFieldRow(Body, rsTeClasses);
  FClasses := TRtChipBar.Create(FClassRow);
  FClasses.Parent := FClassRow;
  FClasses.Align := alClient;
  FClasses.BorderSpacing.Top := 2;
  FClasses.BorderSpacing.Left := 2;
  FClasses.Reorder := False;
  FClasses.OnChipClick := @ClassChipClick;
  FClasses.OnChipClose := @ClassChipClose;
  FClasses.OnActionClick := @ClassAction;
  FClasses.OnLayoutChanged := @ClassesLayout;
  FGroupRow := MakeFieldRow(Body, rsTeGroups);
  FGroupBar := TRtChipBar.Create(FGroupRow);
  FGroupBar.Parent := FGroupRow;
  FGroupBar.Align := alClient;
  FGroupBar.BorderSpacing.Top := 2;
  FGroupBar.BorderSpacing.Left := 2;
  FGroupBar.Reorder := False;
  FGroupBar.OnChipClose := @GroupChipClose;
  FGroupBar.OnActionClick := @GroupAction;
  FGroupBar.OnLayoutChanged := @ClassesLayout;

  FAccountRow := MakeFieldRow(Body, rsTeAccount);
  FMustChange := MakeCheck(FAccountRow, rsTeMustChange, alLeft);
  FNeverExpires := MakeCheck(FAccountRow, rsTeNeverExpires, alLeft);
  FAccountDisabled := MakeCheck(FAccountRow, rsTeAccountDisabled, alLeft);
  FMustChange.OnChange := @AccountChange;
  FNeverExpires.OnChange := @AccountChange;
  FAccountDisabled.OnChange := @AccountChange;
  FAccountRow.Visible := False;

  statusRow := MakePanel(Body, alTop, 26);
  statusRow.BorderSpacing.Top := 4;
  FStatusIcon := TRtIcon.Create(statusRow);
  FStatusIcon.Parent := statusRow;
  FStatusIcon.Align := alLeft;
  FStatusIcon.Width := 24;
  FStatus := MakeDataLabel(statusRow, '', alClient);
  FStatus.Layout := tlCenter;
  FStatus.WordWrap := False;
  FWords := MakeDataLabel(Body, '', alTop);
  FWords.WordWrap := True;

  head := MakePanel(Body, alTop, 34);
  head.BorderSpacing.Top := 6;
  lbl := MakeLabel(head, rsTeValues, alLeft);
  lbl.Layout := tlCenter;
  lbl.Font.Style := [fsBold];
  FUndoBtn := TRtFlatButton.Create(head);
  FUndoBtn.Parent := head;
  FUndoBtn.Align := alRight;
  FUndoBtn.Setup('refresh', rsTeUndo);
  FUndoBtn.OnClick := @UndoClick;
  FUndoBtn.Enabled := False;
  FCleanBtn := TRtFlatButton.Create(head);
  FCleanBtn.Parent := head;
  FCleanBtn.Align := alRight;
  FCleanBtn.BorderSpacing.Right := 6;
  FCleanBtn.Setup('trash', '');
  FCleanBtn.OnClick := @CleanClick;
  FCleanBtn.Visible := False;

  row := MakePanel(Body, alBottom, 58);
  row.BorderSpacing.Top := 4;
  FHelpIcon := TRtIcon.Create(row);
  FHelpIcon.Parent := row;
  FHelpIcon.Align := alLeft;
  FHelpIcon.Width := 24;
  FHelpIcon.TopAligned := True;
  FHelpIcon.BorderSpacing.Top := 4;
  FHelp := MakeDataLabel(row, '', alClient);
  FHelp.WordWrap := True;
  FHelpRow := row;

  FScroll := TRtScrollBox.Create(Body);
  FScroll.Parent := Body;
  FScroll.Align := alClient;
  FScroll.HorzScrollBar.Visible := False;
  FScroll.VertScrollBar.Tracking := True;

  FMenu := TPopupMenu.Create(Self);

  FSave := AddButton(rsSave, mrNone, False);
  FSave.OnClick := @SaveClick;
  AddButton(rsCancel, mrCancel, False, True);
end;

procedure TTemplateEditor.ComputeMetrics;
var
  bmp: Graphics.TBitmap;
  s: TTplSource;
  w: Integer;
begin
  bmp := Graphics.TBitmap.Create;
  try
    bmp.Canvas.Font.Assign(Font);
    if RSUiFontName <> '' then bmp.Canvas.Font.Name := RSUiFontName;
    bmp.Canvas.Font.Size := RSUiFontSize;
    FMetrics.EditH := bmp.Canvas.TextHeight('Ag') + 4;
    FMetrics.RowH := FMetrics.EditH + 22;
    FMetrics.BtnH := FMetrics.EditH + 8;
    FMetrics.BtnW := FMetrics.BtnH + 4;
    FMetrics.SwitchH := FMetrics.EditH + 8;
    FMetrics.AttrW := bmp.Canvas.TextWidth('0') * 20;
    FMetrics.CapGap := 8;
    bmp.Canvas.Font.Style := [fsBold];
    FMetrics.ChipW := bmp.Canvas.TextWidth(rsTeRdnChip) + 18;
    w := 0;
    for s := Low(TTplSource) to High(TTplSource) do
      w := Max(w, bmp.Canvas.TextWidth(TemplateSourceName(s)));
    // Quatre choix au plus sur une ligne: nombre ou mot de passe, jamais les deux.
    FMetrics.SourceW := 4 * (w + 22) + 4;
    bmp.Canvas.Font.Style := [];
    FMetrics.FormatW := bmp.Canvas.TextWidth('PBKDF2-SHA512') + 44;
  finally
    bmp.Free;
  end;
end;

procedure TTemplateEditor.ApplyShellColors;
var
  i: Integer;
begin
  inherited ApplyShellColors;
  ComputeMetrics;
  FHelpRow.Height := FontTextHeight(FHelp.Font) * 5 + 10;
  FWords.Font.Color := DialogStateColor(usMuted);
  FHelp.Font.Color := DialogStateColor(usMuted);
  FHelpIcon.SetIcon('info-circle', 16, DialogStateColor(usMuted));
  FClasses.Color := clAppBg;
  FGroupBar.Color := clAppBg;
  for i := 0 to FRows.Count - 1 do
    TTeRow(FRows[i]).Restyle;
  FillClasses;
  FillGroups;
  UpdateStatus;
end;

procedure TTemplateEditor.FormResized(Sender: TObject);
begin
  ClassesLayout(nil);
end;

function TTemplateEditor.RowOfField(AIndex: Integer): TTeRow;
var
  i: Integer;
begin
  for i := 0 to FRows.Count - 1 do
    if (TTeRow(FRows[i]).Kind = trkField) and (TTeRow(FRows[i]).Index = AIndex) then
      Exit(TTeRow(FRows[i]));
  Result := nil;
end;

function TTemplateEditor.RowOf(AControl: TControl): TTeRow;
begin
  while (AControl <> nil) and not (AControl is TTeRow) do
    AControl := AControl.Parent;
  Result := TTeRow(AControl);
end;

function TTemplateEditor.FieldRequired(AIndex: Integer): Boolean;
begin
  Result := False;
  if (AIndex < 0) or (AIndex > High(FT.Fields)) then Exit;
  Result := IsRequiredAttr(FAnalysis, Schema, FT.Fields[AIndex].Attr) or
    (SameAttr(FT.Fields[AIndex].Attr, FT.RdnAttr) and (FieldIndex(FT, FT.RdnAttr) = AIndex));
end;

function TTemplateEditor.RequiredReason(AIndex: Integer): string;
var
  ri: Integer;
begin
  Result := '';
  if (AIndex < 0) or (AIndex > High(FT.Fields)) then Exit;
  ri := FindRequirement(FAnalysis, Schema, FT.Fields[AIndex].Attr);
  if (ri >= 0) and (FAnalysis.Requirements[ri].Kind = rqMust) and
     (FAnalysis.Requirements[ri].Supply = rsUser) then
    Result := Format(rsTeForcedByClass, [FAnalysis.Requirements[ri].Origin])
  else if SameAttr(FT.Fields[AIndex].Attr, FT.RdnAttr) and (FieldIndex(FT, FT.RdnAttr) = AIndex) then
    Result := rsTeForcedByName
  else if ComposedFrom(FT, AIndex) <> '' then
    Result := Format(rsTeForcedByCompose, [ComposedFrom(FT, AIndex)]);
end;

function TTemplateEditor.FieldSecret(AIndex: Integer): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex <= High(FT.Fields)) and
    FCtx.Sensitive.IsSensitive(FT.Fields[AIndex].Attr);
end;

function TTemplateEditor.FieldIsNumber(AIndex: Integer): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex <= High(FT.Fields)) and (Schema <> nil) and
    (ResolveValueKind(Schema, FT.Fields[AIndex].Attr, Provider).Kind = vkInteger);
end;

function TTemplateEditor.AllowedSources(AIndex: Integer): TTplIndexes;
begin
  // Seul le mot de passe se fixe, se compose ou se tire au sort; les autres secrets se demandent.
  if FieldSecret(AIndex) then
  begin
    if not TemplatePasswordAttr(FT.Fields[AIndex].Attr, Provider, Schema) then Result := [Ord(tsAsk)]
    else Result := [Ord(tsFixed), Ord(tsAsk), Ord(tsCompose), Ord(tsRandom)];
  end
  else if FieldIsNumber(AIndex) then
    Result := [Ord(tsFixed), Ord(tsAsk), Ord(tsCompose), Ord(tsNumber)]
  else
    Result := [Ord(tsFixed), Ord(tsAsk), Ord(tsCompose)];
end;

function TTemplateEditor.PartColor(const APart: TTplPart): TColor;
var
  target: Integer;
begin
  if APart.Kind = tpCounter then Exit(TemplateSourceColor(tsNumber));
  target := FieldIndex(FT, APart.Text);
  if target < 0 then Exit(DialogStateColor(usError));
  Result := TemplateSourceColor(FT.Fields[target].Source);
end;

procedure TTemplateEditor.FillClasses;
var
  i: Integer;
  chip: TRtChip;
begin
  FClasses.OnLayoutChanged := nil;
  try
    FClasses.Clear;
    FClasses.ClearActions;
    if FT.Structural = '' then
      FClasses.AddAction('box', rsTeChooseClass)
    else
    begin
      i := FClasses.AddChip(FT.Structural, clAccent, '', False);
      chip := FClasses.Chips[i];
      chip.IconId := 'box';
      FClasses.Chips[i] := chip;
      for i := 0 to High(FT.Auxiliaries) do
        FClasses.AddChip(FT.Auxiliaries[i], TemplateSourceColor(tsFixed));
      FClasses.AddAction('plus', rsTeAddAuxiliary);
    end;
  finally
    FClasses.OnLayoutChanged := @ClassesLayout;
  end;
  ClassesLayout(nil);
end;

procedure TTemplateEditor.ClassesLayout(Sender: TObject);
var
  h: Integer;
begin
  if (FClasses = nil) or (FClassRow = nil) then Exit;
  h := Max(30, FClasses.PreferredHeight(Max(100, FClasses.ClientWidth)) + 6);
  if FClassRow.Height <> h then FClassRow.Height := h;
  if (FGroupBar = nil) or (FGroupRow = nil) then Exit;
  h := Max(30, FGroupBar.PreferredHeight(Max(100, FGroupBar.ClientWidth)) + 6);
  if FGroupRow.Height <> h then FGroupRow.Height := h;
end;

procedure TTemplateEditor.FillGroups;
var
  i: Integer;
  tip: string;
begin
  FGroupBar.OnLayoutChanged := nil;
  try
    FGroupBar.Clear;
    FGroupBar.ClearActions;
    tip := rsTeGroupsHelp;
    for i := 0 to High(FT.Groups) do
    begin
      FGroupBar.AddChip(RdnCaption(FT.Groups[i]), clAccent);
      tip := tip + LineEnding + FT.Groups[i];
    end;
    FGroupBar.AddAction('plus', rsTeAddGroup);
    FGroupBar.Hint := tip;
    FGroupBar.ShowHint := True;
  finally
    FGroupBar.OnLayoutChanged := @ClassesLayout;
  end;
  ClassesLayout(nil);
end;

procedure TTemplateEditor.GroupChipClose(Sender: TObject; AIndex: Integer);
begin
  if FRebuildQueued then Exit;
  RemoveGroup(AIndex);
end;

procedure TTemplateEditor.GroupAction(Sender: TObject; AIndex: Integer);
var
  c: TDirectoryConnection;
  dn: string;
begin
  if FRebuildQueued then Exit;
  c := FCtx.Connections.Find(FProfileUuid);
  if (c = nil) or not c.IsReady then
  begin
    RtMessageDlg(Caption, rsTeNoSchema, mtWarning, [mbOK], 0);
    Exit;
  end;
  dn := '';
  if not PickDirectoryEntry(Self, FCtx, FProfileUuid, rsTeGroups, rsTeGroupPrompt,
    DefaultSearchBase(c), '', dn) then Exit;
  AddGroup(dn);
end;

function TTemplateEditor.AddGroup(const ADn: string): Boolean;
var
  i: Integer;
  dn: string;
  rules: TDnCaseRules;
begin
  Result := False;
  dn := Trim(ADn);
  if (dn = '') or (Length(FT.Groups) >= TEMPLATE_MAX_GROUPS) then Exit;
  rules := TDnCaseRules.Create(FCtx.Connections.Find(FProfileUuid));
  try
    for i := 0 to High(FT.Groups) do
      if DnFoldKey(FT.Groups[i], @rules.Folds, @rules.Canon) = DnFoldKey(dn, @rules.Folds, @rules.Canon) then Exit;
  finally
    rules.Free;
  end;
  PushUndo;
  SetLength(FT.Groups, Length(FT.Groups) + 1);
  FT.Groups[High(FT.Groups)] := dn;
  FillGroups;
  Recheck;
  Result := True;
end;

procedure TTemplateEditor.RemoveGroup(AIndex: Integer);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FT.Groups)) then Exit;
  PushUndo;
  for i := AIndex to High(FT.Groups) - 1 do
    FT.Groups[i] := FT.Groups[i + 1];
  SetLength(FT.Groups, Length(FT.Groups) - 1);
  FillGroups;
  Recheck;
end;

procedure TTemplateEditor.ClassChipClick(Sender: TObject; AIndex: Integer; AButton: TMouseButton);
begin
  if FRebuildQueued then Exit;
  if AIndex = 0 then ChooseStructural;
end;

procedure TTemplateEditor.ClassChipClose(Sender: TObject; AIndex: Integer);
begin
  if FRebuildQueued then Exit;
  RemoveAuxiliary(AIndex - 1);
end;

procedure TTemplateEditor.ClassAction(Sender: TObject; AIndex: Integer);
begin
  if FRebuildQueued then Exit;
  if FT.Structural = '' then ChooseStructural else AddAuxiliary;
end;

procedure TTemplateEditor.RebuildRows(AFocus: Integer);
var
  i, y, pos: Integer;

  procedure NewRow(AKind: TTeRowKind; AIndex: Integer);
  var
    row: TTeRow;
  begin
    row := TTeRow.CreateRow(FScroll, Self, AKind, AIndex);
    row.Top := y;
    Inc(y, row.Height);
    FRows.Add(row);
  end;

begin
  FRebuildQueued := False;
  pos := FScroll.VertScrollBar.Position;
  FIssues := AllIssues;
  FUpdating := True;
  FScroll.DisableAlign;
  try
    for i := FRows.Count - 1 downto 0 do
      TObject(FRows[i]).Free;
    FRows.Clear;
    y := 0;
    if FT.Structural = '' then
      NewRow(trkEmpty, -1)
    else
    begin
      for i := 0 to High(FT.Fields) do
        NewRow(trkField, i);
      NewRow(trkAdd, -1);
    end;
  finally
    FScroll.EnableAlign;
    FUpdating := False;
  end;
  FScroll.VertScrollBar.Position := pos;
  FCurrent := -1;
  FillClasses;
  FillGroups;
  Recheck;
  FUndoBtn.Enabled := FUndo.Count > 0;
  if (AFocus >= 0) and (AFocus <= High(FT.Fields)) then
  begin
    SetCurrent(AFocus);
    FocusRow(AFocus);
  end;
end;

procedure TTemplateEditor.QueueRebuild(AFocus: Integer);
begin
  FRebuildFocus := AFocus;
  if FRebuildQueued or FClosing then Exit;
  // Jamais depuis le gestionnaire d'un controle qu'on va detruire: il est encore sur la pile.
  FRebuildQueued := True;
  Application.QueueAsyncCall(@RunRebuild, 0);
end;

procedure TTemplateEditor.RunRebuild(AData: PtrInt);
begin
  if FClosing then Exit;
  RebuildRows(FRebuildFocus);
end;

procedure TTemplateEditor.FocusRow(AIndex: Integer);
var
  row: TTeRow;
  target: TWinControl;
begin
  row := RowOfField(AIndex);
  if (row = nil) or not Showing then Exit;
  FScroll.ScrollInView(row);
  target := nil;
  if row.FValue <> nil then target := row.FValue
  else if row.FPrompt <> nil then target := row.FPrompt
  else if row.FChips <> nil then target := row.FChips
  else if row.FMin <> nil then target := row.FMin;
  if (target <> nil) and target.CanFocus then target.SetFocus;
end;

procedure TTemplateEditor.SetCurrent(AIndex: Integer);
var
  row: TTeRow;
begin
  if (AIndex < 0) or (AIndex > High(FT.Fields)) then AIndex := -1;
  if AIndex <> FCurrent then
  begin
    row := RowOfField(FCurrent);
    if row <> nil then row.SetCurrentLook(False);
    FCurrent := AIndex;
    row := RowOfField(FCurrent);
    if row <> nil then row.SetCurrentLook(True);
  end;
  UpdateStatus;
  UpdateHelp;
end;

procedure TTemplateEditor.Recheck;
var
  i, j: Integer;
  row: TTeRow;
  err: string;
  warn: Boolean;
begin
  FIssues := AllIssues;
  FSamples := SampleValues(FT);
  FillAccount;
  for i := 0 to FRows.Count - 1 do
  begin
    row := TTeRow(FRows[i]);
    if (row.Kind <> trkField) or (row.Index > High(FT.Fields)) then Continue;
    err := row.FLocalError;
    warn := False;
    if err = '' then
      for j := 0 to High(FIssues) do
        if (FIssues[j].Field = row.Index) and (FIssues[j].Severity = isError) then
        begin
          err := FIssues[j].Text;
          Break;
        end;
    if err = '' then
      for j := 0 to High(FIssues) do
        if FIssues[j].Field = row.Index then
        begin
          err := FIssues[j].Text;
          warn := True;
          Break;
        end;
    row.SetError(err, warn);
    if FT.Fields[row.Index].Source = tsCompose then
    begin
      if (Length(FT.Fields[row.Index].Parts) > 0) and (row.Index <= High(FSamples)) then
      begin
        err := FSamples[row.Index];
        if Length(err) > 160 then err := UTF8Copy(err, 1, 120) + '...';
        row.SetNote(Format(rsTeSample, [err]));
      end
      else
        row.SetNote('');
    end;
    row.StyleRdnChip;
    row.SyncForced;
  end;
  UpdateStatus;
  UpdateWords;
  UpdateHelp;
end;

procedure TTemplateEditor.UpdateStatus;
var
  err, firstWarn: string;
  i, warnings: Integer;
  row: TTeRow;
  state: TUiState;
  iconId: string;
begin
  if FStatus = nil then Exit;
  err := '';
  row := RowOfField(FCurrent);
  if (row <> nil) and (row.FError <> '') and not row.FWarning then err := row.FError;
  if err = '' then
    for i := 0 to FRows.Count - 1 do
      if TTeRow(FRows[i]).FLocalError <> '' then
      begin
        err := TTeRow(FRows[i]).FLocalError;
        Break;
      end;
  if err = '' then err := FirstTemplateError(FIssues);
  warnings := 0;
  firstWarn := '';
  for i := 0 to High(FIssues) do
    if FIssues[i].Severity = isWarning then
    begin
      if warnings = 0 then firstWarn := FIssues[i].Text;
      Inc(warnings);
    end;
  if Schema = nil then
  begin
    FStatus.Caption := rsTeNoSchema;
    state := usError;
  end
  else if err <> '' then
  begin
    FStatus.Caption := Format(rsTeInvalid, [err]);
    state := usError;
  end
  else if warnings > 0 then
  begin
    FStatus.Caption := Format(rsTeValidWarn, [warnings, firstWarn]);
    state := usWarning;
  end
  else
  begin
    FStatus.Caption := rsTeValid;
    state := usOk;
  end;
  FStatus.Font.Color := DialogStateColor(state);
  case state of
    usOk: iconId := 'circle-check';
    usError: iconId := 'alert-triangle';
  else
    iconId := 'info-circle';
  end;
  FStatusIcon.SetIcon(iconId, 16, DialogStateColor(state));
  FSave.Enabled := state <> usError;
  i := DisallowedCount;
  if i > 0 then
  begin
    FCleanBtn.Text := Format(rsTeClean, [i]);
    FCleanBtn.Ink := DialogStateColor(usError);
    FCleanBtn.FitWidth;
  end;
  if FCleanBtn.Visible <> (i > 0) then FCleanBtn.Visible := i > 0;
end;

procedure TTemplateEditor.UpdateWords;
var
  i, ri: Integer;
  asked, dn: string;
begin
  if FWords = nil then Exit;
  if FT.Structural = '' then
  begin
    FWords.Caption := rsTeWordsNone;
    Exit;
  end;
  ri := FieldIndex(FT, FT.RdnAttr);
  dn := rsTeContainer;
  if (ri >= 0) and (ri <= High(FSamples)) then
    dn := FT.RdnAttr + '=' + FSamples[ri] + ',' + rsTeContainer;
  asked := '';
  for i := 0 to High(FT.Fields) do
    if FT.Fields[i].Source = tsAsk then
    begin
      if asked <> '' then asked := asked + ', ';
      asked := asked + FieldPrompt(FT.Fields[i]);
    end;
  if asked = '' then FWords.Caption := Format(rsTeWords, [dn])
  else FWords.Caption := Format(rsTeWords, [dn]) + '   -   ' + Format(rsTeWordsAsk, [asked]);
end;

function TTemplateEditor.AttrInfo(const AName: string): string;
var
  s: TSchemaSnapshot;
  at: TSchemaAttributeType;
  ri: Integer;
begin
  Result := '';
  s := Schema;
  if (s = nil) or (AName = '') then Exit;
  at := s.AttributeType(AName);
  if at = nil then Exit;
  Result := at.PrimaryName + ': ' + ValueKindName(ResolveValueKind(s, AName, Provider).Kind);
  if at.SingleValue then Result := Result + ', ' + rsTeAttrSingle;
  ri := FindRequirement(FAnalysis, s, AName);
  if ri >= 0 then
  begin
    if FAnalysis.Requirements[ri].Kind = rqMust then
      Result := Result + ', ' + Format(rsTeAttrRequiredBy, [FAnalysis.Requirements[ri].Origin])
    else
      Result := Result + ', ' + Format(rsTeAttrOptionalIn, [FAnalysis.Requirements[ri].Origin]);
  end;
  if at.Desc <> '' then Result := Result + ' - ' + at.Desc;
end;

procedure TTemplateEditor.UpdateHelp;
var
  t, info: string;
  row: TTeRow;
begin
  if FHelp = nil then Exit;
  t := '';
  row := RowOfField(FCurrent);
  if (FCurrent < 0) or (FCurrent > High(FT.Fields)) then
    t := rsTeHelpStart
  else
  begin
    info := AttrInfo(FT.Fields[FCurrent].Attr);
    if info <> '' then t := info + LineEnding;
    if (row <> nil) and (row.FError <> '') then t := t + row.FError + LineEnding;
    if FieldSecret(FCurrent) then
    begin
      if not TemplatePasswordAttr(FT.Fields[FCurrent].Attr, Provider, Schema) then t := t + rsTeHelpSecret
      else
      begin
        case FT.Fields[FCurrent].Source of
          tsFixed: t := t + rsTeHelpSecretFixed;
          tsCompose: t := t + rsTeHelpSecretCompose;
          tsRandom: t := t + rsTeHelpSecretRandom;
        else
          if Provider = pkActiveDirectory then t := t + rsTeHelpSecretAdAsk
          else t := t + rsTeHelpSecretAsk;
        end;
        if Provider = pkActiveDirectory then t := t + ' ' + rsTeHelpSecretAd;
      end;
    end
    else
      case FT.Fields[FCurrent].Source of
        tsAsk: t := t + rsTeHelpAsk;
        tsCompose: t := t + rsTeHelpCompose + ' ' + rsTeHelpCounter;
        tsNumber: t := t + rsTeHelpNumber;
      else
        t := t + rsTeHelpFixed;
      end;
    if SameAttr(FT.Fields[FCurrent].Attr, FT.RdnAttr) and (FieldIndex(FT, FT.RdnAttr) = FCurrent) then
      t := t + ' ' + rsTeHelpRdn;
  end;
  FHelp.Caption := t + LineEnding + rsTeKeys;
end;

procedure TTemplateEditor.PushUndo;
var
  s: string;
begin
  s := TemplateToJson(FT);
  FTypingOwner := nil;
  if (FUndo.Count > 0) and (FUndo[FUndo.Count - 1] = s) then Exit;
  FUndo.Add(s);
  if FUndo.Count > 200 then FUndo.Delete(0);
  FUndoBtn.Enabled := True;
end;

procedure TTemplateEditor.BeginTyping(AOwner: TObject);
begin
  if FTypingOwner = AOwner then Exit;
  PushUndo;
  FTypingOwner := AOwner;
end;

procedure TTemplateEditor.Undo;
var
  t: TEntryTemplate;
  err, uuid: string;
begin
  if FUndo.Count = 0 then Exit;
  uuid := FT.Uuid;
  if TemplateFromJson(FUndo[FUndo.Count - 1], t, err) then
  begin
    t.Uuid := uuid;
    FT := t;
    FUpdating := True;
    try
      FName.Text := FT.Name;
      FDesc.Text := FT.Description;
    finally
      FUpdating := False;
    end;
  end;
  FUndo.Delete(FUndo.Count - 1);
  FTypingOwner := nil;
  RebuildRows(Min(FCurrent, High(FT.Fields)));
end;

function TTemplateEditor.FieldDisallowed(AIndex: Integer): Boolean;
var
  s: TSchemaSnapshot;
begin
  Result := False;
  s := Schema;
  if (s = nil) or not FAnalysis.Ok or (AIndex < 0) or (AIndex > High(FT.Fields)) then Exit;
  if IsPrecluded(FAnalysis, s, FT.Fields[AIndex].Attr) then Exit(True);
  // Schema lu en partie ou extensibleObject: on ne sait pas, donc on ne retire rien.
  Result := (FindRequirement(FAnalysis, s, FT.Fields[AIndex].Attr) < 0) and
    not FAnalysis.ExtensibleObject and not FAnalysis.AllowedIncomplete;
end;

function TTemplateEditor.DisallowedCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FT.Fields) do
    if FieldDisallowed(i) then Inc(Result);
end;

procedure TTemplateEditor.RemoveDisallowed;
var
  i, n: Integer;
begin
  if DisallowedCount = 0 then Exit;
  PushUndo;
  n := 0;
  for i := 0 to High(FT.Fields) do
    if not FieldDisallowed(i) then
    begin
      FT.Fields[n] := FT.Fields[i];
      Inc(n);
    end;
  SetLength(FT.Fields, n);
  if FieldIndex(FT, FT.RdnAttr) < 0 then FT.RdnAttr := '';
  SyncRequiredFields(FT, Schema, Provider, FCtx.Sensitive);
  QueueRebuild(-1);
end;

procedure TTemplateEditor.CleanClick(Sender: TObject);
begin
  if FRebuildQueued then Exit;
  RemoveDisallowed;
end;

procedure TTemplateEditor.UndoClick(Sender: TObject);
begin
  if FRebuildQueued then Exit;
  Undo;
end;

procedure TTemplateEditor.HeaderChange(Sender: TObject);
begin
  if FUpdating or FClosing then Exit;
  BeginTyping(Sender);
  FT.Name := FName.Text;
  FT.Description := FDesc.Text;
  Recheck;
end;

procedure TTemplateEditor.RowEdited(ARow: TTeRow; ASender: TObject);
var
  i: Integer;
  n: Int64;
  txt: string;
begin
  i := ARow.Index;
  if FUpdating or FRebuildQueued or (i < 0) or (i > High(FT.Fields)) then Exit;
  BeginTyping(ASender);
  ARow.FLocalError := '';
  case FT.Fields[i].Source of
    tsFixed: FT.Fields[i].Value := ARow.FValue.Text;
    tsAsk:
      begin
        FT.Fields[i].Prompt := Trim(ARow.FPrompt.Text);
        if ARow.FValue <> nil then FT.Fields[i].Value := ARow.FValue.Text;
      end;
    tsNumber:
      begin
        txt := Trim(ARow.FMin.Text);
        FT.Fields[i].HasMin := (txt <> '') and TryStrToInt64(txt, n);
        if FT.Fields[i].HasMin then FT.Fields[i].Min := n
        else if txt <> '' then ARow.FLocalError := Format(rsTeBadNumber, [FT.Fields[i].Attr]);
        txt := Trim(ARow.FMax.Text);
        FT.Fields[i].HasMax := (txt <> '') and TryStrToInt64(txt, n);
        if FT.Fields[i].HasMax then FT.Fields[i].Max := n
        else if txt <> '' then ARow.FLocalError := Format(rsTeBadNumber, [FT.Fields[i].Attr]);
      end;
    tsRandom:
      begin
        txt := Trim(ARow.FMin.Text);
        if TryStrToInt64(txt, n) and (n > 0) and (n < 1000) then FT.Fields[i].RandomLength := n
        else ARow.FLocalError := Format(rsTeBadLength, [FT.Fields[i].Attr]);
      end;
  end;
  Recheck;
end;

{ Classes }

function TTemplateEditor.PickClass(AKind: TObjectClassKind; out AName: string): Boolean;
var
  d: TPickDialog;
  s: TSchemaSnapshot;
  names: TStringArray;
  rows: TPickRows;
  i, n: Integer;
  oc: TSchemaObjectClass;
  taken: Boolean;
  j: Integer;
begin
  Result := False;
  AName := '';
  s := Schema;
  if s = nil then
  begin
    RtMessageDlg(Caption, rsTeNoSchema, mtWarning, [mbOK], 0);
    Exit;
  end;
  names := FindClasses(s, '', AKind, 20000);
  rows := nil;
  n := 0;
  SetLength(rows, Length(names));
  for i := 0 to High(names) do
  begin
    taken := SameText(names[i], FT.Structural);
    for j := 0 to High(FT.Auxiliaries) do
      if SameText(FT.Auxiliaries[j], names[i]) then taken := True;
    if taken and (AKind = ockAuxiliary) then Continue;
    oc := s.ObjectClass(names[i]);
    if oc = nil then Continue;
    rows[n].Key := names[i];
    rows[n].Cells := [names[i], oc.Desc];
    rows[n].Info := names[i] + '  (' + oc.Oid + ')' + #10 + oc.Desc + #10 +
      Format(rsTeMust, [string.Join('  ', oc.Must)]) + #10 + Format(rsTeMay, [string.Join('  ', oc.May)]);
    Inc(n);
  end;
  SetLength(rows, n);
  if n = 0 then
  begin
    RtMessageDlg(Caption, rsTeNoClassLeft, mtInformation, [mbOK], 0);
    Exit;
  end;
  if AKind = ockStructural then
    d := TPickDialog.CreatePick(Self, rsTePickStructTitle, rsTePickStructHelp,
      [rsTeColClass, rsTeColDesc], [240, 560])
  else
    d := TPickDialog.CreatePick(Self, rsTePickAuxTitle, rsTePickAuxHelp,
      [rsTeColClass, rsTeColDesc], [240, 560]);
  try
    if AKind = ockStructural then d.OkCaption := rsTePickChoose;
    d.SetRows(rows);
    if (AKind = ockStructural) and (FT.Structural <> '') then d.Choose(FT.Structural);
    if RunPick(d) <> mrOk then Exit;
    AName := d.Chosen;
    Result := AName <> '';
  finally
    d.Free;
  end;
end;

procedure TTemplateEditor.AfterClassChange;
begin
  SyncRequiredFields(FT, Schema, Provider, FCtx.Sensitive);
  QueueRebuild(FCurrent);
end;

procedure TTemplateEditor.ChooseStructural;
var
  cls: string;
begin
  if PickClass(ockStructural, cls) then SetStructural(cls);
end;

procedure TTemplateEditor.SetStructural(const AName: string);
begin
  if SameText(AName, FT.Structural) then Exit;
  PushUndo;
  FT.Structural := AName;
  AfterClassChange;
end;

procedure TTemplateEditor.AddAuxiliary;
var
  cls: string;
begin
  if PickClass(ockAuxiliary, cls) then AddAuxiliaryClass(cls);
end;

procedure TTemplateEditor.AddAuxiliaryClass(const AName: string);
var
  i: Integer;
begin
  for i := 0 to High(FT.Auxiliaries) do
    if SameText(FT.Auxiliaries[i], AName) then Exit;
  if Length(FT.Auxiliaries) >= TEMPLATE_MAX_CLASSES then Exit;
  PushUndo;
  SetLength(FT.Auxiliaries, Length(FT.Auxiliaries) + 1);
  FT.Auxiliaries[High(FT.Auxiliaries)] := AName;
  AfterClassChange;
end;

procedure TTemplateEditor.RemoveAuxiliary(AIndex: Integer);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FT.Auxiliaries)) then Exit;
  PushUndo;
  for i := AIndex to High(FT.Auxiliaries) - 1 do
    FT.Auxiliaries[i] := FT.Auxiliaries[i + 1];
  SetLength(FT.Auxiliaries, Length(FT.Auxiliaries) - 1);
  AfterClassChange;
end;

{ Champs }

procedure TTemplateEditor.AddAttribute;
var
  d: TPickDialog;
  s: TSchemaSnapshot;
  names: TStringArray;
  rows: TPickRows;
  i, n, ri: Integer;
  at: TSchemaAttributeType;
  use, desc: string;
  present: Boolean;
  chosen: string;
begin
  s := Schema;
  if (s = nil) or (FT.Structural = '') then Exit;
  names := TemplateAttributeChoices(FAnalysis, s, Provider, FCtx.Sensitive);
  rows := nil;
  SetLength(rows, Length(names));
  n := 0;
  for i := 0 to High(names) do
  begin
    present := FieldIndex(FT, names[i]) >= 0;
    at := s.AttributeType(names[i]);
    if present and ((at = nil) or at.SingleValue or FCtx.Sensitive.IsSensitive(names[i])) then Continue;
    ri := FindRequirement(FAnalysis, s, names[i]);
    if present then use := rsTeUseAgain
    else if (ri >= 0) and (FAnalysis.Requirements[ri].Kind = rqMust) then use := rsTeUseRequired
    else use := rsTeUseOptional;
    desc := '';
    if at <> nil then desc := at.Desc;
    rows[n].Key := names[i];
    rows[n].Cells := [names[i], use, desc];
    rows[n].Info := AttrInfo(names[i]);
    Inc(n);
  end;
  SetLength(rows, n);
  if n = 0 then
  begin
    RtMessageDlg(Caption, rsTeNoAttrLeft, mtInformation, [mbOK], 0);
    Exit;
  end;
  d := TPickDialog.CreatePick(Self, rsTePickAttrTitle, rsTePickAttrHelp,
    [rsTeColAttr, rsTeColUse, rsTeColDesc], [220, 120, 460]);
  try
    d.SetRows(rows);
    if RunPick(d) <> mrOk then Exit;
    chosen := d.Chosen;
  finally
    d.Free;
  end;
  if chosen <> '' then QueueRebuild(AddField(chosen));
end;

function TTemplateEditor.AddField(const AAttr: string): Integer;
var
  f: TTplField;
begin
  Result := -1;
  if Length(FT.Fields) >= TEMPLATE_MAX_FIELDS then Exit;
  PushUndo;
  f := NewField(AAttr, tsAsk);
  f.Optional := not IsRequiredAttr(FAnalysis, Schema, AAttr);
  if SameAttr(AAttr, 'uidNumber') then f.Source := tsNumber;
  SetLength(FT.Fields, Length(FT.Fields) + 1);
  FT.Fields[High(FT.Fields)] := f;
  Result := High(FT.Fields);
  if FT.RdnAttr = '' then FT.RdnAttr := AAttr;
end;

procedure TTemplateEditor.DeleteField(AIndex: Integer);
var
  i: Integer;
  wasRdn: Boolean;
begin
  if (AIndex < 0) or (AIndex > High(FT.Fields)) then Exit;
  PushUndo;
  wasRdn := SameAttr(FT.Fields[AIndex].Attr, FT.RdnAttr) and (FieldCount(FT, FT.RdnAttr) = 1);
  for i := AIndex to High(FT.Fields) - 1 do
    FT.Fields[i] := FT.Fields[i + 1];
  SetLength(FT.Fields, Length(FT.Fields) - 1);
  if wasRdn then FT.RdnAttr := '';
  // L'obligatoire revient aussitot: pas de modele bancal laisse derriere soi.
  SyncRequiredFields(FT, Schema, Provider, FCtx.Sensitive);
  QueueRebuild(Min(AIndex, High(FT.Fields)));
end;

procedure TTemplateEditor.MoveField(AIndex, ADelta: Integer);
var
  t: TTplField;
  j: Integer;
begin
  j := AIndex + ADelta;
  if (AIndex < 0) or (AIndex > High(FT.Fields)) or (j < 0) or (j > High(FT.Fields)) then Exit;
  PushUndo;
  t := FT.Fields[AIndex];
  FT.Fields[AIndex] := FT.Fields[j];
  FT.Fields[j] := t;
  QueueRebuild(j);
end;

procedure TTemplateEditor.DuplicateField(AIndex: Integer);
var
  f: TTplField;
  i: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FT.Fields)) or (Length(FT.Fields) >= TEMPLATE_MAX_FIELDS) then Exit;
  PushUndo;
  f := NewField(FT.Fields[AIndex].Attr, tsFixed);
  SetLength(FT.Fields, Length(FT.Fields) + 1);
  for i := High(FT.Fields) downto AIndex + 2 do
    FT.Fields[i] := FT.Fields[i - 1];
  FT.Fields[AIndex + 1] := f;
  QueueRebuild(AIndex + 1);
end;

procedure TTemplateEditor.SetRdn(AIndex: Integer);
var
  t: TTplField;
  first, i: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FT.Fields)) or FieldSecret(AIndex) then Exit;
  first := FieldIndex(FT, FT.Fields[AIndex].Attr);
  if SameAttr(FT.RdnAttr, FT.Fields[AIndex].Attr) and (first = AIndex) then Exit;
  PushUndo;
  FT.RdnAttr := FT.Fields[AIndex].Attr;
  // La premiere valeur de l'attribut nomme l'entree: celle qu'on a cliquee passe devant.
  if first <> AIndex then
  begin
    t := FT.Fields[AIndex];
    for i := AIndex downto first + 1 do
      FT.Fields[i] := FT.Fields[i - 1];
    FT.Fields[first] := t;
    AIndex := first;
  end;
  QueueRebuild(AIndex);
end;

procedure TTemplateEditor.SetSource(AIndex: Integer; ASource: TTplSource);
var
  allowed: TTplIndexes;
  i: Integer;
  ok: Boolean;
begin
  if (AIndex < 0) or (AIndex > High(FT.Fields)) or (FT.Fields[AIndex].Source = ASource) then Exit;
  allowed := AllowedSources(AIndex);
  ok := False;
  for i := 0 to High(allowed) do
    if allowed[i] = Ord(ASource) then ok := True;
  if not ok then Exit;
  PushUndo;
  FT.Fields[AIndex].Source := ASource;
  if FieldSecret(AIndex) then
  begin
    // Un mot de passe masque ne devient pas un jeton lisible au detour d'un clic.
    if ASource = tsAsk then FT.Fields[AIndex].Value := '';
    if (ASource in [tsFixed, tsCompose, tsRandom]) and (FT.Fields[AIndex].Scheme = '') then
      FT.Fields[AIndex].Scheme := TemplateDefaultFormat(Provider);
    if (ASource = tsRandom) and (FT.Fields[AIndex].RandomLength = 0) then
      FT.Fields[AIndex].RandomLength := Max(RANDOM_PWD_DEFAULT, FPolicy.MinLength);
  end
  else if (ASource = tsCompose) and (Length(FT.Fields[AIndex].Parts) = 0) and
     (FT.Fields[AIndex].Value <> '') then
    FT.Fields[AIndex].Parts := [TextPart(FT.Fields[AIndex].Value)];
  if ASource = tsNumber then FT.Fields[AIndex].Value := '';
  QueueRebuild(AIndex);
end;

procedure TTemplateEditor.SetFormat(AIndex: Integer; const AScheme: string);
var
  wasShown: Boolean;
begin
  if (AIndex < 0) or (AIndex > High(FT.Fields)) or not FieldSecret(AIndex) or
     SameText(FT.Fields[AIndex].Scheme, AScheme) then Exit;
  PushUndo;
  wasShown := TemplateSecretShown(FT.Fields[AIndex]);
  FT.Fields[AIndex].Scheme := AScheme;
  SetCurrent(AIndex);
  // Passer de {SASL} a un hachage masque la saisie, et inversement: la ligne se refait.
  if (FT.Fields[AIndex].Source = tsFixed) and (wasShown <> TemplateSecretShown(FT.Fields[AIndex])) then
    QueueRebuild(AIndex)
  else
    Recheck;
end;

{ Composition }

procedure TTemplateEditor.AddPart(AField: Integer; const APart: TTplPart);
var
  row: TTeRow;
begin
  if (AField < 0) or (AField > High(FT.Fields)) then Exit;
  if Length(FT.Fields[AField].Parts) >= TEMPLATE_MAX_PARTS then Exit;
  PushUndo;
  SetLength(FT.Fields[AField].Parts, Length(FT.Fields[AField].Parts) + 1);
  FT.Fields[AField].Parts[High(FT.Fields[AField].Parts)] := APart;
  row := RowOfField(AField);
  if row <> nil then row.FillChips;
  Recheck;
end;

procedure TTemplateEditor.RemovePart(AField, APart: Integer);
var
  i: Integer;
  row: TTeRow;
begin
  if (AField < 0) or (AField > High(FT.Fields)) then Exit;
  if (APart < 0) or (APart > High(FT.Fields[AField].Parts)) then Exit;
  PushUndo;
  for i := APart to High(FT.Fields[AField].Parts) - 1 do
    FT.Fields[AField].Parts[i] := FT.Fields[AField].Parts[i + 1];
  SetLength(FT.Fields[AField].Parts, Length(FT.Fields[AField].Parts) - 1);
  row := RowOfField(AField);
  if row <> nil then row.FillChips;
  Recheck;
end;

procedure TTemplateEditor.MovePart(AField, AFrom, ATo: Integer);
var
  p: TTplPart;
  i: Integer;
  row: TTeRow;
begin
  if (AField < 0) or (AField > High(FT.Fields)) then Exit;
  if (AFrom < 0) or (AFrom > High(FT.Fields[AField].Parts)) or (ATo < 0) or
     (ATo > High(FT.Fields[AField].Parts)) or (AFrom = ATo) then Exit;
  PushUndo;
  p := FT.Fields[AField].Parts[AFrom];
  if ATo > AFrom then
    for i := AFrom to ATo - 1 do FT.Fields[AField].Parts[i] := FT.Fields[AField].Parts[i + 1]
  else
    for i := AFrom downto ATo + 1 do FT.Fields[AField].Parts[i] := FT.Fields[AField].Parts[i - 1];
  FT.Fields[AField].Parts[ATo] := p;
  row := RowOfField(AField);
  if row <> nil then
  begin
    row.FillChips;
    if row.FChips <> nil then
    begin
      row.FChips.FocusedChip := ATo;
      row.FChips.Invalidate;
    end;
  end;
  Recheck;
end;

{ Menus }

procedure TTemplateEditor.ShowPartMenu(ARow: TTeRow; APart: Integer);
var
  part: TTplPart;
  r: TRect;
  p: TPoint;
  i: Integer;
  sub, mi: TMenuItem;
  count: Integer;

  function Item(AParent: TMenuItem; const ACaption: string; ATag: Integer; AChecked: Boolean = False;
    AGroup: Integer = 0; AEnabled: Boolean = True): TMenuItem;
  begin
    Result := TMenuItem.Create(FMenu);
    Result.Caption := ACaption;
    Result.Tag := ATag;
    Result.Enabled := AEnabled;
    if AGroup > 0 then
    begin
      Result.RadioItem := True;
      Result.GroupIndex := AGroup;
    end;
    Result.Checked := AChecked;
    if ATag >= 0 then Result.OnClick := @MenuItemClick;
    AParent.Add(Result);
  end;

begin
  if (ARow = nil) or (ARow.Index > High(FT.Fields)) or (ARow.FChips = nil) then Exit;
  if (APart < 0) or (APart > High(FT.Fields[ARow.Index].Parts)) then Exit;
  part := FT.Fields[ARow.Index].Parts[APart];
  count := Length(FT.Fields[ARow.Index].Parts);
  FMenuField := ARow.Index;
  FMenuPart := APart;
  FMenu.Items.Clear;
  if part.Kind = tpAttr then
  begin
    Item(FMenu.Items, rsTeCaseAsIs, MC_CASE + Ord(tcAsIs), part.CaseFn = tcAsIs, 1);
    Item(FMenu.Items, rsTeCaseUpper, MC_CASE + Ord(tcUpper), part.CaseFn = tcUpper, 1);
    Item(FMenu.Items, rsTeCaseLower, MC_CASE + Ord(tcLower), part.CaseFn = tcLower, 1);
    Item(FMenu.Items, rsTeCaseCapital, MC_CASE + Ord(tcCapital), part.CaseFn = tcCapital, 1);
    Item(FMenu.Items, '-', -1);
    for i := 0 to High(TAKES) do
      if TAKES[i] = 0 then Item(FMenu.Items, rsTeTakeAll, MC_TAKE, part.Take = 0, 2)
      else if TAKES[i] = 1 then Item(FMenu.Items, rsTeTakeOne, MC_TAKE + 1, part.Take = 1, 2)
      else Item(FMenu.Items, Format(rsTeTakeMany, [TAKES[i]]), MC_TAKE + TAKES[i], part.Take = TAKES[i], 2);
    Item(FMenu.Items, '-', -1);
    Item(FMenu.Items, rsTePlain, MC_PLAIN, part.Plain);
    Item(FMenu.Items, '-', -1);
    sub := Item(FMenu.Items, rsTeUseAttr, -1);
    for i := 0 to High(FT.Fields) do
      if (FieldIndex(FT, FT.Fields[i].Attr) = i) and not FieldSecret(i) and (i <> ARow.Index) then
      begin
        mi := Item(sub, FT.Fields[i].Attr, MC_ATTR + i, SameAttr(FT.Fields[i].Attr, part.Text));
        mi.Caption := StringReplace(mi.Caption, '&', '&&', [rfReplaceAll]);
      end;
  end
  else if part.Kind = tpCounter then
  begin
    Item(FMenu.Items, rsTeCounterSepNone, MC_CTR_PREFIX, part.Text = COUNTER_PREFIXES[0], 1);
    Item(FMenu.Items, rsTeCounterSepDot, MC_CTR_PREFIX + 1, part.Text = COUNTER_PREFIXES[1], 1);
    Item(FMenu.Items, rsTeCounterSepDash, MC_CTR_PREFIX + 2, part.Text = COUNTER_PREFIXES[2], 1);
    Item(FMenu.Items, rsTeCounterSepUnder, MC_CTR_PREFIX + 3, part.Text = COUNTER_PREFIXES[3], 1);
    Item(FMenu.Items, '-', -1);
    Item(FMenu.Items, rsTeCounterAnyDigits, MC_CTR_DIGITS, part.Take <= 1, 2);
    Item(FMenu.Items, Format(rsTeCounterDigits, [2, '01, 02']), MC_CTR_DIGITS + 2, part.Take = 2, 2);
    Item(FMenu.Items, Format(rsTeCounterDigits, [3, '001, 002']), MC_CTR_DIGITS + 3, part.Take = 3, 2);
    Item(FMenu.Items, '-', -1);
    Item(FMenu.Items, rsTeCounterOmitOne, MC_CTR_OMIT, part.OmitOne);
  end
  else
    Item(FMenu.Items, rsTeEditText, MC_PART_EDIT);
  Item(FMenu.Items, '-', -1);
  Item(FMenu.Items, rsTeMoveLeft, MC_PART_LEFT, False, 0, APart > 0);
  Item(FMenu.Items, rsTeMoveRight, MC_PART_RIGHT, False, 0, APart < count - 1);
  Item(FMenu.Items, rsTeRemove, MC_PART_REMOVE);
  ThemePopupMenu(FMenu);
  r := ARow.FChips.ChipRect(APart);
  p := ARow.FChips.ClientToScreen(Point(r.Left, r.Bottom + 2));
  FMenu.PopUp(p.X, p.Y);
end;

procedure TTemplateEditor.ShowAddPartMenu(ARow: TTeRow);
var
  i, n: Integer;
  mi: TMenuItem;
  r: TRect;
  p: TPoint;
begin
  if (ARow = nil) or (ARow.Index > High(FT.Fields)) or (ARow.FChips = nil) then Exit;
  FMenuField := ARow.Index;
  FMenuPart := -1;
  FMenu.Items.Clear;
  n := 0;
  for i := 0 to High(FT.Fields) do
    if (FieldIndex(FT, FT.Fields[i].Attr) = i) and not FieldSecret(i) and (i <> ARow.Index) then
    begin
      mi := TMenuItem.Create(FMenu);
      mi.Caption := StringReplace(FT.Fields[i].Attr, '&', '&&', [rfReplaceAll]);
      mi.Tag := MC_ADD_PART + i;
      mi.OnClick := @MenuItemClick;
      FMenu.Items.Add(mi);
      Inc(n);
    end;
  if n = 0 then
  begin
    mi := TMenuItem.Create(FMenu);
    mi.Caption := rsTeNoOtherAttr;
    mi.Enabled := False;
    FMenu.Items.Add(mi);
  end;
  ThemePopupMenu(FMenu);
  r := ARow.FChips.ActionRect(0);
  p := ARow.FChips.ClientToScreen(Point(r.Left, r.Bottom + 2));
  FMenu.PopUp(p.X, p.Y);
end;

procedure TTemplateEditor.ShowRowMenu(ARow: TTeRow; AAtMouse: Boolean);
var
  p: TPoint;
  i: Integer;
  at: TSchemaAttributeType;
  multi: Boolean;

  procedure Item(const ACaption: string; ATag: Integer; AEnabled: Boolean = True);
  var
    mi: TMenuItem;
  begin
    mi := TMenuItem.Create(FMenu);
    mi.Caption := ACaption;
    mi.Tag := ATag;
    mi.Enabled := AEnabled;
    if ATag >= 0 then mi.OnClick := @MenuItemClick;
    FMenu.Items.Add(mi);
  end;

begin
  if (ARow = nil) or (ARow.Kind <> trkField) or (ARow.Index > High(FT.Fields)) then Exit;
  i := ARow.Index;
  SetCurrent(i);
  FMenuField := i;
  FMenuPart := -1;
  at := nil;
  if Schema <> nil then at := Schema.AttributeType(FT.Fields[i].Attr);
  multi := (at <> nil) and not at.SingleValue and not FieldSecret(i);
  FMenu.Items.Clear;
  Item(rsTeMenuRdn, MC_ROW_RDN, not FieldSecret(i) and
    not (SameAttr(FT.Fields[i].Attr, FT.RdnAttr) and (FieldIndex(FT, FT.RdnAttr) = i)));
  Item(rsTeMenuDuplicate, MC_ROW_DUP, multi);
  Item('-', -1);
  Item(rsTeMenuUp, MC_ROW_UP, i > 0);
  Item(rsTeMenuDown, MC_ROW_DOWN, i < High(FT.Fields));
  Item('-', -1);
  Item(rsTeMenuDelete, MC_ROW_DELETE, not ARow.FLocked);
  ThemePopupMenu(FMenu);
  if AAtMouse then
    p := Mouse.CursorPos
  else
    p := ARow.FMenuBtn.ClientToScreen(Point(0, ARow.FMenuBtn.Height));
  FMenu.PopUp(p.X, p.Y);
end;

procedure TTemplateEditor.MenuItemClick(Sender: TObject);
begin
  RunCommand(TMenuItem(Sender).Tag, FMenuField, FMenuPart);
end;

procedure TTemplateEditor.RunCommand(ACommand, AField, APart: Integer);
var
  cmd, f, p: Integer;
  row: TTeRow;
  touched: Boolean;
begin
  if FRebuildQueued or FClosing then Exit;
  cmd := ACommand;
  f := AField;
  p := APart;
  if (f < 0) or (f > High(FT.Fields)) then Exit;
  case cmd of
    MC_ROW_DUP: DuplicateField(f);
    MC_ROW_RDN: SetRdn(f);
    MC_ROW_UP: MoveField(f, -1);
    MC_ROW_DOWN: MoveField(f, 1);
    MC_ROW_DELETE: DeleteField(f);
  else
    if (cmd >= MC_CTR_PREFIX) and (cmd <= MC_CTR_OMIT) then
    begin
      if (p < 0) or (p > High(FT.Fields[f].Parts)) or (FT.Fields[f].Parts[p].Kind <> tpCounter) then Exit;
      PushUndo;
      if cmd = MC_CTR_OMIT then
        FT.Fields[f].Parts[p].OmitOne := not FT.Fields[f].Parts[p].OmitOne
      else if cmd >= MC_CTR_DIGITS then
        FT.Fields[f].Parts[p].Take := cmd - MC_CTR_DIGITS
      else if cmd - MC_CTR_PREFIX <= High(COUNTER_PREFIXES) then
        FT.Fields[f].Parts[p].Text := COUNTER_PREFIXES[cmd - MC_CTR_PREFIX];
      row := RowOfField(f);
      if row <> nil then row.FillChips;
      Recheck;
      Exit;
    end;
    if cmd >= MC_ADD_PART then
    begin
      if cmd - MC_ADD_PART <= High(FT.Fields) then
        AddPart(f, AttrPart(FT.Fields[cmd - MC_ADD_PART].Attr));
      Exit;
    end;
    if (p < 0) or (p > High(FT.Fields[f].Parts)) then Exit;
    row := RowOfField(f);
    case cmd of
      MC_PART_LEFT: MovePart(f, p, p - 1);
      MC_PART_RIGHT: MovePart(f, p, p + 1);
      MC_PART_REMOVE: RemovePart(f, p);
      MC_PART_EDIT:
        if (row <> nil) and (row.FChips <> nil) then row.FChips.EditChip(p);
    else
      touched := True;
      PushUndo;
      if (cmd >= MC_ATTR) and (cmd - MC_ATTR <= High(FT.Fields)) then
        FT.Fields[f].Parts[p].Text := FT.Fields[cmd - MC_ATTR].Attr
      else if cmd = MC_PLAIN then
        FT.Fields[f].Parts[p].Plain := not FT.Fields[f].Parts[p].Plain
      else if (cmd >= MC_TAKE) and (cmd < MC_PLAIN) then
        FT.Fields[f].Parts[p].Take := cmd - MC_TAKE
      else if (cmd >= MC_CASE) and (cmd < MC_TAKE) then
        FT.Fields[f].Parts[p].CaseFn := TTplCase(cmd - MC_CASE)
      else
        touched := False;
      if touched then
      begin
        if row <> nil then row.FillChips;
        Recheck;
      end;
    end;
  end;
end;

{ Clavier, enregistrement }

procedure TTemplateEditor.KeyDown(var Key: Word; Shift: TShiftState);
var
  ac: TWinControl;
  row: TTeRow;
  bar: TRtChipBar;
begin
  ac := ActiveControl;
  // Saisie d'un texte fixe en cours: Echap et Entree sont pour elle, pas pour le dialogue.
  if (ac is TEdit) and (ac.Parent is TRtChipBar) then
  begin
    bar := TRtChipBar(ac.Parent);
    if bar.Editing and (Key in [VK_ESCAPE, VK_RETURN]) and (Shift = []) then
    begin
      bar.EndEdit(Key = VK_RETURN);
      Key := 0;
      Exit;
    end;
  end;
  if FRebuildQueued then
  begin
    inherited KeyDown(Key, Shift);
    Exit;
  end;
  row := RowOf(ac);
  if (Key = VK_RETURN) and (Shift = [ssCtrl]) then
  begin
    Key := 0;
    if FT.Structural = '' then ChooseStructural else AddAttribute;
    Exit;
  end;
  if (Key = VK_S) and (Shift = [ssCtrl]) then
  begin
    Key := 0;
    SaveClick(nil);
    Exit;
  end;
  if (Key = VK_Z) and (Shift = [ssCtrl]) then
  begin
    Key := 0;
    Undo;
    Exit;
  end;
  if (row <> nil) and (row.Kind = trkField) and (Shift = [ssAlt]) then
    case Key of
      VK_DELETE:
        begin
          Key := 0;
          if not row.FLocked then DeleteField(row.Index);
          Exit;
        end;
      VK_UP:
        begin
          Key := 0;
          MoveField(row.Index, -1);
          Exit;
        end;
      VK_DOWN:
        begin
          Key := 0;
          MoveField(row.Index, 1);
          Exit;
        end;
    end;
  inherited KeyDown(Key, Shift);
end;

procedure TTemplateEditor.SaveClick(Sender: TObject);
var
  err: string;
begin
  if FRebuildQueued then Exit;
  FT.Name := Trim(FName.Text);
  FT.Description := Trim(FDesc.Text);
  Recheck;
  if not FSave.Enabled then Exit;
  if not StoreTemplate(FCtx.Document, FT, err) then
  begin
    RtMessageDlg(Caption, err, mtWarning, [mbOK], 0);
    if FName.CanFocus then FName.SetFocus;
    Exit;
  end;
  FCtx.StatusChanged;
  ModalResult := mrOk;
end;

procedure TTemplateEditor.Save;
begin
  SaveClick(nil);
end;

function TTemplateEditor.StatusText: string;
begin
  Result := FStatus.Caption;
end;

function TTemplateEditor.SaveEnabled: Boolean;
begin
  Result := FSave.Enabled;
end;

end.
