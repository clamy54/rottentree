// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uFilterBuilderDialog;

{$mode objfpc}{$H+}

// Constructeur graphique de filtres RFC 4515: le filtre texte en haut, une ligne par element au milieu,
// l'aide en bas. Les valeurs sont litterales et echappees a la serialisation, le texte produit est donc
// toujours valide. Ce que le constructeur ne sait pas representer, valeur binaire comprise, reste intact
// et verrouille: mieux vaut un cadenas qu'une reecriture creative.

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, Dialogs, LCLType, Menus,
  uUiKit, uAppContext, uRtCombo, uRtCheck, uRtButton, uIcons, uLdapFilter, uFilterBuilder,
  uLdapSchema;

type
  TFilterBuilderDialog = class;

  TFbRowKind = (frkGroup, frkNot, frkCondition, frkLocked, frkAdd, frkEmpty);
  TFbColors = array of TColor;

  TFbAction = (faAddCond, faAddInto, faAddGroupInto, faDelete, faNot, faToggleAndOr, faUp, faDown,
    faWrapAll, faWrapAny, faDuplicate, faUndo);

  TFbRow = class(TCustomControl)
  private
    FDlg: TFilterBuilderDialog;
    FKind: TFbRowKind;
    FNode: TFilterNode;
    FInner: TFilterNode;
    FNegated: Boolean;
    FGroup: TFilterNode;
    FDepth: Integer;
    FRails: TFbColors;
    FOwnColor: TColor;
    FBase: TColor;
    FIsCurrent: Boolean;
    FBuilt: Boolean;
    FLockReason: string;
    FError: string;
    FErrorField: Integer;
    FTextLeft, FValueLeft, FLockLeft: Integer;
    FSwitch: TRtSegmented;
    FAttr, FValue, FRule: TEdit;
    FOp: TRtComboBox;
    FDnAttrs: TRtCheckBox;
    FMenuBtn, FDelBtn, FUnNotBtn, FAddCond, FAddGroup, FNotChip: TRtFlatButton;
    function MakeField(const AHint: string): TEdit;
    function MakeButton(const AIcon, AText: string; AInk: TColor): TRtFlatButton;
    procedure BuildControls;
    function ContentLeft: Integer;
    procedure FieldChange(Sender: TObject);
    procedure FieldEnter(Sender: TObject);
    procedure FieldExit(Sender: TObject);
    procedure MenuClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure UnNotClick(Sender: TObject);
    procedure AddCondClick(Sender: TObject);
    procedure AddGroupClick(Sender: TObject);
    procedure SwitchToggle(Sender: TObject);
    procedure NotChipClick(Sender: TObject);
    procedure StyleNotChip;
    procedure DrawFrame(AEdit: TEdit; AError: Boolean);
    procedure DrawRails;
    procedure DrawTexts;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor CreateRow(AOwner: TWinControl; ADlg: TFilterBuilderDialog; AKind: TFbRowKind;
      ANode, AGroup: TFilterNode; ANegated: Boolean; ADepth: Integer; const ARails: TFbColors);
    procedure Restyle;
    procedure LayoutRow;
    procedure SetCurrentLook(AValue: Boolean);
    procedure SetError(const AError: string; const C: TFilterCondition);
    function ReadCondition: TFilterCondition;
    function IsNodeRow: Boolean;
    property Kind: TFbRowKind read FKind;
    property Node: TFilterNode read FNode;
    property Inner: TFilterNode read FInner;
    property Negated: Boolean read FNegated;
    property Depth: Integer read FDepth;
  end;

  TFbMetrics = record
    EditH, RowH, AddH, AttrW, OpW, RuleW, DnW, BtnW, BtnH, SwitchH, LinkH, ComboH, ChipW: Integer;
  end;

  TFilterBuilderDialog = class(TRtDialog)
  private
    FCtx: TAppContext;
    FProfileUuid: string;
    FRoot: TFilterNode;
    FRows: TFPList;
    FCurrent: TFbRow;
    FMetrics: TFbMetrics;
    FScroll: TRtScrollBox;
    FText: TMemo;
    FTextProblem: string;
    FUpdatingText, FUpdating, FClosing: Boolean;
    FWords, FStatus, FHelp: TLabel;
    FStatusIcon, FHelpIcon: TRtIcon;
    FUndoBtn, FHistoryBtn, FCopyBtn: TRtFlatButton;
    FHelpRow: TPanel;
    FUndo: TStringList;
    FTypingOwner: TObject;
    FSuggestBox: TPanel;
    FSuggest: TListBox;
    FSuggestInfo: TStringList;
    FSuggestFor: TFbRow;
    FMenu, FHistoryMenu: TPopupMenu;
    FMenuRow: TFbRow;
    FPending: TFPList;
    FOk: TButton;
    procedure BuildUi;
    procedure ComputeMetrics;
    function Schema: TSchemaSnapshot;
    function Serialized: string;
    function Selected: TFilterNode;
    function AddTarget: TFilterNode;
    function NodeRow(AIndex: Integer): TFbRow;
    function NodeRowCount: Integer;
    function NodeRowIndex(ARow: TFbRow): Integer;
    function RowOf(AControl: TControl): TFbRow;
    procedure RebuildRows(ASelect: TFilterNode; AFocus: Boolean; AFallbackIndex: Integer = 0);
    procedure FocusRow(ARow: TFbRow; ASameField: TControl = nil);
    procedure SetCurrent(ARow: TFbRow);
    procedure Changed(AFromText: Boolean);
    procedure SetExprText(const AText: string);
    procedure UpdateStatus;
    procedure UpdateHelp;
    function AttrInfo(const AName: string): string;
    procedure PushUndo;
    procedure BeginTyping(AOwner: TObject);
    procedure ReplaceRoot(ANew: TFilterNode);
    procedure RowEdited(ARow: TFbRow; AAttrChanged: Boolean);
    procedure RowFieldEntered(ARow: TFbRow; AField: TControl);
    procedure AttrExited;
    procedure CheckSuggestFocus(AData: PtrInt);
    procedure FillSuggestions(ARow: TFbRow; AShow: Boolean);
    procedure ShowSuggest;
    procedure HideSuggest;
    procedure PickSuggestion(AIndex: Integer);
    procedure SuggestDraw(Control: TWinControl; Index: Integer; ARect: TRect; State: TOwnerDrawState);
    procedure SuggestMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure ScrollWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint; var Handled: Boolean);
    procedure TextChanged(Sender: TObject);
    procedure TextEnter(Sender: TObject);
    procedure UndoClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure HistoryClick(Sender: TObject);
    procedure HistoryItemClick(Sender: TObject);
    procedure MenuItemClick(Sender: TObject);
    procedure ShowRowMenu(ARow: TFbRow; AAtMouse: Boolean);
    procedure Defer(ARow: TFbRow; AAction: TFbAction);
    procedure RunDeferred(AData: PtrInt);
    procedure AddInto(AGroup: TFilterNode; AAsGroup: Boolean);
    function CanMove(ANode: TFilterNode; ADelta: Integer): Boolean;
  protected
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure ApplyShellColors; override;
  public
    constructor CreateBuilder(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid,
      AFilter: string);
    destructor Destroy; override;
    function FilterText: string;
    function Problem: string;
    procedure SelectItem(AIndex: Integer);
    procedure AddCondition;
    procedure AddGroup(AOr: Boolean);
    procedure AddFromRow(AIndex: Integer; AAsGroup: Boolean);
    procedure ToggleNot;
    procedure ToggleAndOr;
    procedure WrapSelected(AOr: Boolean);
    procedure DuplicateSelected;
    procedure DeleteSelected;
    procedure MoveSelected(ADelta: Integer);
    procedure Undo;
    function CanUndo: Boolean;
    procedure SetCondition(const AAttr: string; AOp: TFilterOp; const AValue: string);
    procedure SetValueText(const AValue: string);
    procedure SetFilterText(const AText: string);
    function ExpressionText: string;
    function TreeText: string;
    function AddRowsText: string;
    function SuggestionsText: string;
    function WordsText: string;
    function StatusText: string;
    function HelpText: string;
    function EditorEnabled: Boolean;
    function OkEnabled: Boolean;
    function CurrentNegated: Boolean;
    property Metrics: TFbMetrics read FMetrics;
  end;

function EditFilterGraphically(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
  var AFilter: string): Boolean;

function FilterGroupColor(AKind: TFilterKind): TColor;

resourcestring
  rsFbTitle = 'Filter builder';
  rsFbExprTitle = 'LDAP filter';
  rsFbCopy = 'Copy';
  rsFbRecent = 'Recent';
  rsFbNoRecent = '(no search yet on this server)';
  rsFbNoDocument = '(open a document to keep a search history)';
  rsFbConditions = 'Conditions';
  rsFbUndo = 'Undo';
  rsFbWords = 'Reads as: %s';
  rsFbWordsEmpty = 'Reads as: (no condition yet)';
  rsFbAll = 'AND';
  rsFbAny = 'OR';
  rsFbGroupAndText = 'all of these must match';
  rsFbGroupOrText = 'at least one of these must match';
  rsFbNotChipHint = 'NOT: keep the entries that do not match (click to switch, Alt+N)';
  rsFbItems = '%d item(s)';
  rsFbNotChip = 'NOT';
  rsFbNotText = 'the following must not match';
  rsFbRemoveNot = 'Remove NOT';
  rsFbAddCondShort = 'Condition';
  rsFbAddAllGroup = 'AND group';
  rsFbAddAnyGroup = 'OR group';
  rsFbEmptyTitle = 'No condition yet.';
  rsFbEmptyHint = 'Start with one: an attribute, an operator, a value.';
  rsFbAddFirst = 'Add a condition';
  rsFbNoValue = 'no value needed';
  rsFbPlaceAttr = 'attribute';
  rsFbPlaceValue = 'value';
  rsFbPlaceRule = 'matching rule';
  rsFbValid = 'Valid filter.';
  rsFbInvalid = 'Not valid: %s';
  rsFbEmptyStatus = 'Empty filter: add a condition.';
  rsFbTextInvalid = 'The text is not a valid filter yet (%s): the conditions below show the last valid one.';
  rsFbNotEditable = 'This expression cannot be shown as a condition; it is kept as it is.';
  rsFbBinaryValue = 'This condition holds a binary value that a text field cannot show; it is kept as it is.';
  rsFbSingle = 'single-valued';
  rsFbOperational = 'operational';
  rsFbReadOnly = 'not modifiable';
  rsFbUnknownAttr = '%s: not in the schema of this server.';
  rsFbLiteral = 'The value is taken literally: * ( ) \ are escaped.';
  rsFbFragment = 'LDAP: %s';
  rsFbOpEquals = 'equals: compared with the equality rule of the attribute (often case-insensitive).';
  rsFbOpNotEquals = 'differs from: entries without this value, including those without the attribute.';
  rsFbOpStarts = 'starts with: values that begin with the text.';
  rsFbOpEnds = 'ends with: values that end with the text.';
  rsFbOpContains = 'contains: values that include the text anywhere.';
  rsFbOpPattern = 'matches pattern: "*" stands for any text (Jo*n matches John and Jordan).';
  rsFbOpPresent = 'is present: entries that have this attribute, whatever its value.';
  rsFbOpAbsent = 'is absent: entries that do not have this attribute.';
  rsFbOpGe = 'at least: ordered comparison (numbers, dates, text) by the ordering rule of the attribute.';
  rsFbOpLe = 'at most: ordered comparison (numbers, dates, text) by the ordering rule of the attribute.';
  rsFbOpApprox = 'approximately: "sounds like"; each server decides what it means.';
  rsFbOpExt = 'extensible match: compared with a named matching rule; ":dn" also tests the values of the DN.';
  rsFbHelpAll = 'AND: an entry matches when every item of the group matches. OR accepts entries matching at least one.';
  rsFbHelpAny = 'OR: an entry matches when at least one item of the group matches. AND requires every item.';
  rsFbHelpNegated = 'NOT is on: the entries kept are those that do NOT match this %s.';
  rsFbWordCondition = 'condition';
  rsFbWordGroup = 'group';
  rsFbHelpNot = 'NOT: an entry matches when the item below does not match.';
  rsFbHelpText = 'Type or paste a filter: the conditions follow it while it is valid. Enter applies it.';
  rsFbHelpStart = 'Add a condition to start; a second one forms an AND group, which can switch to OR.';
  rsFbKeys = 'Ctrl+Enter new condition  -  Alt+N NOT  -  Up/Down previous/next row  -  Alt+Up/Down move  -  Alt+Del delete  -  Ctrl+Z undo';
  rsFbMenuNot = 'Negate (NOT)'#9'Alt+N';
  rsFbMenuUnNot = 'Remove the NOT'#9'Alt+N';
  rsFbMenuToAny = 'Switch to OR';
  rsFbMenuToAll = 'Switch to AND';
  rsFbMenuWrapAll = 'Put in an AND group';
  rsFbMenuWrapAny = 'Put in an OR group';
  rsFbMenuDuplicate = 'Duplicate';
  rsFbMenuAddCond = 'Add a condition after'#9'Ctrl+Enter';
  rsFbMenuUp = 'Move up'#9'Alt+Up';
  rsFbMenuDown = 'Move down'#9'Alt+Down';
  rsFbMenuDelete = 'Delete'#9'Alt+Del';

implementation

uses
  Math, Clipbrd, LCLIntf, uTheme, uConnections, uRtBytes, uStrings, uMenuBar, uSearchLibrary, uSavedSearch;

const
  RAIL_X0 = 14;
  RAIL_STEP = 24;
  RAIL_W = 3;
  OP_SHOWN: array[0..9] of TFilterOp = (foEquals, foStartsWith, foEndsWith, foContains, foPattern,
    foPresent, foGreaterOrEqual, foLessOrEqual, foApprox, foExtensible);
  OP_LABELS: array[TFilterOp] of string = ('equals', 'differs from', 'starts with', 'ends with',
    'contains', 'matches pattern (*)', 'is present', 'is absent', 'at least (>=)', 'at most (<=)',
    'approximately (~=)', 'extensible match');

type
  TFbDeferred = class
    Row: TFbRow;
    Action: TFbAction;
  end;

function FilterGroupColor(AKind: TFilterKind): TColor;
var
  dark: Boolean;
begin
  dark := IsDarkColor(clAppBg);
  case AKind of
    fkAnd: if dark then Result := RgbHexToColor($5B9BF0) else Result := RgbHexToColor($1F5FC4);
    fkOr: if dark then Result := RgbHexToColor($E3A23B) else Result := RgbHexToColor($A15F00);
  else
    if dark then Result := RgbHexToColor($EE6E6E) else Result := RgbHexToColor($C0282D);
  end;
end;

function OpIndex(AOp: TFilterOp): Integer;
var
  i: Integer;
begin
  for i := 0 to High(OP_SHOWN) do
    if OP_SHOWN[i] = AOp then Exit(i);
  Result := 0;
end;

function OpAt(AIndex: Integer): TFilterOp;
begin
  if (AIndex < 0) or (AIndex > High(OP_SHOWN)) then Exit(foEquals);
  Result := OP_SHOWN[AIndex];
end;

function MutedColor(ABack: TColor): TColor;
begin
  Result := BlendColor(clAppFg, ABack, 58);
end;

function OpHelp(AOp: TFilterOp): string;
begin
  case AOp of
    foEquals: Result := rsFbOpEquals;
    foNotEquals: Result := rsFbOpNotEquals;
    foStartsWith: Result := rsFbOpStarts;
    foEndsWith: Result := rsFbOpEnds;
    foContains: Result := rsFbOpContains;
    foPattern: Result := rsFbOpPattern;
    foPresent: Result := rsFbOpPresent;
    foAbsent: Result := rsFbOpAbsent;
    foGreaterOrEqual: Result := rsFbOpGe;
    foLessOrEqual: Result := rsFbOpLe;
    foApprox: Result := rsFbOpApprox;
  else
    Result := rsFbOpExt;
  end;
end;

function AppendColor(const A: TFbColors; AColor: TColor): TFbColors;
var
  i: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A) + 1);
  for i := 0 to High(A) do Result[i] := A[i];
  Result[High(Result)] := AColor;
end;

function EditFilterGraphically(AOwner: TComponent; ACtx: TAppContext; const AProfileUuid: string;
  var AFilter: string): Boolean;
var
  d: TFilterBuilderDialog;
begin
  Result := False;
  d := TFilterBuilderDialog.CreateBuilder(AOwner, ACtx, AProfileUuid, AFilter);
  try
    if (d.ShowModal = mrOk) and (d.FilterText <> '') then
    begin
      AFilter := d.FilterText;
      Result := True;
    end;
  finally
    d.Free;
  end;
end;

constructor TFbRow.CreateRow(AOwner: TWinControl; ADlg: TFilterBuilderDialog; AKind: TFbRowKind;
  ANode, AGroup: TFilterNode; ANegated: Boolean; ADepth: Integer; const ARails: TFbColors);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  FDlg := ADlg;
  FKind := AKind;
  FNode := ANode;
  FNegated := ANegated;
  FInner := ANode;
  if ANegated then FInner := ANode.Children[0];
  FGroup := AGroup;
  FDepth := ADepth;
  FRails := Copy(ARails, 0, Length(ARails));
  FOwnColor := clNone;
  if (FInner <> nil) and (AKind in [frkGroup, frkNot]) then
    FOwnColor := FilterGroupColor(FInner.Kind);
  TabStop := False;
  Parent := AOwner;
  Align := alTop;
  case AKind of
    frkAdd: Height := ADlg.Metrics.AddH;
    frkEmpty: Height := ADlg.Metrics.RowH * 3;
  else
    Height := ADlg.Metrics.RowH;
  end;
  BuildControls;
  FBuilt := True;
  Restyle;
end;

function TFbRow.IsNodeRow: Boolean;
begin
  Result := FKind in [frkGroup, frkNot, frkCondition, frkLocked];
end;

function TFbRow.MakeField(const AHint: string): TEdit;
begin
  Result := TEdit.Create(Self);
  Result.Parent := Self;
  Result.BorderStyle := bsNone;
  Result.AutoSize := False;
  // Couleurs posees des la creation: posees apres coup, GTK3 montre un instant le fond clair du theme
  // systeme a chaque reconstruction. Un flash par ligne, une migraine par filtre.
  Result.Color := clEditorBg;
  Result.Font.Color := clEditorFg;
  Result.TextHint := AHint;
  Result.OnEnter := @FieldEnter;
  Result.OnExit := @FieldExit;
  Result.OnChange := @FieldChange;
end;

function TFbRow.MakeButton(const AIcon, AText: string; AInk: TColor): TRtFlatButton;
begin
  Result := TRtFlatButton.Create(Self);
  Result.Parent := Self;
  Result.Setup(AIcon, AText, AInk);
end;

procedure TFbRow.BuildControls;
var
  c: TFilterCondition;
  i: Integer;
  groupColor: TColor;
  isOrParent: Boolean;
begin
  case FKind of
    frkCondition:
      begin
        NodeToCondition(FInner, c);
        FAttr := MakeField(rsFbPlaceAttr);
        FOp := TRtComboBox.Create(Self);
        FOp.Parent := Self;
        for i := 0 to High(OP_SHOWN) do FOp.Items.Add(OP_LABELS[OP_SHOWN[i]]);
        FRule := MakeField(rsFbPlaceRule);
        FDnAttrs := TRtCheckBox.Create(Self);
        FDnAttrs.Parent := Self;
        // Place a la main: AutoSize se battrait avec SetBounds, et ce combat n'a jamais de gagnant.
        FDnAttrs.AutoSize := False;
        FDnAttrs.Caption := ':dn';
        FValue := MakeField(rsFbPlaceValue);
        FDlg.FUpdating := True;
        try
          FAttr.Text := c.Attr;
          FOp.ItemIndex := OpIndex(c.Op);
          FRule.Text := c.MatchingRule;
          FDnAttrs.Checked := c.DnAttributes;
          FValue.Text := string(c.Value);
        finally
          FDlg.FUpdating := False;
        end;
        FOp.OnChange := @FieldChange;
        FOp.OnEnter := @FieldEnter;
        FDnAttrs.OnChange := @FieldChange;
      end;
    frkGroup:
      begin
        FSwitch := TRtSegmented.Create(Self);
        FSwitch.Parent := Self;
        FSwitch.SetChoices([rsFbAll, rsFbAny], Ord(FInner.Kind = fkOr));
        FSwitch.OnChange := @SwitchToggle;
      end;
    frkNot:
      begin
        FUnNotBtn := MakeButton('circle-minus', rsFbRemoveNot, FOwnColor);
        FUnNotBtn.TabStop := False;
        FUnNotBtn.OnClick := @UnNotClick;
      end;
    frkAdd, frkEmpty:
      begin
        if Length(FRails) > 0 then groupColor := FRails[High(FRails)] else groupColor := clDefault;
        if FKind = frkEmpty then
          FAddCond := MakeButton('plus', rsFbAddFirst, clAccent)
        else
          FAddCond := MakeButton('plus', rsFbAddCondShort, groupColor);
        FAddCond.OnClick := @AddCondClick;
        if FKind = frkAdd then
        begin
          isOrParent := (FGroup <> nil) and (FGroup.Kind = fkOr);
          if isOrParent then
            FAddGroup := MakeButton('folders', rsFbAddAllGroup, groupColor)
          else
            FAddGroup := MakeButton('folders', rsFbAddAnyGroup, groupColor);
          FAddGroup.OnClick := @AddGroupClick;
        end;
      end;
  end;
  if FKind in [frkGroup, frkCondition, frkLocked] then
  begin
    FNotChip := MakeButton('', 'NOT', clDefault);
    FNotChip.TabStop := False;
    FNotChip.Hint := rsFbNotChipHint;
    FNotChip.ShowHint := True;
    FNotChip.OnClick := @NotChipClick;
  end;
  if FKind in [frkGroup, frkNot, frkCondition, frkLocked] then
  begin
    FMenuBtn := MakeButton('', '', clDefault);
    FMenuBtn.Glyph := rbgDots;
    FMenuBtn.TabStop := False;
    FMenuBtn.OnClick := @MenuClick;
    FDelBtn := MakeButton('trash', '', clDefault);
    FDelBtn.TabStop := False;
    FDelBtn.OnClick := @DeleteClick;
  end;
  if FKind = frkLocked then
  begin
    if NodeToCondition(FInner, c) then FLockReason := rsFbBinaryValue
    else FLockReason := rsFbNotEditable;
  end;
end;

procedure TFbRow.Restyle;
var
  i: Integer;
begin
  ThemeControlTree(Self);
  if FOp <> nil then
  begin
    FOp.BorderSpacing.Top := 0;
    FOp.BorderSpacing.Bottom := 0;
  end;
  if FKind in [frkGroup, frkNot] then
    FBase := BlendColor(FOwnColor, clAppBg, 11)
  else if Length(FRails) > 0 then
    FBase := BlendColor(FRails[High(FRails)], clAppBg, 4)
  else
    FBase := clAppBg;
  if FNegated then FBase := BlendColor(FilterGroupColor(fkNot), FBase, 10);
  if FSwitch <> nil then
    FSwitch.SetColors([FilterGroupColor(fkAnd), FilterGroupColor(fkOr)]);
  StyleNotChip;
  SetCurrentLook(FIsCurrent);
  if FMenuBtn <> nil then FMenuBtn.Ink := MutedColor(FBase);
  if FDelBtn <> nil then FDelBtn.Ink := MutedColor(FBase);
  for i := 0 to ControlCount - 1 do
    if Controls[i] is TRtFlatButton then TRtFlatButton(Controls[i]).FitWidth;
  LayoutRow;
end;

procedure TFbRow.StyleNotChip;
begin
  if FNotChip = nil then Exit;
  if FNegated then
  begin
    FNotChip.Fill := FilterGroupColor(fkNot);
    FNotChip.Border := FilterGroupColor(fkNot);
    FNotChip.Ink := clAppBg;
  end
  else
  begin
    FNotChip.Fill := clNone;
    FNotChip.Border := BlendColor(clAppFg, FBase, 22);
    FNotChip.Ink := BlendColor(clAppFg, FBase, 45);
  end;
  FNotChip.Font.Style := [fsBold];
  FNotChip.Invalidate;
end;

procedure TFbRow.NotChipClick(Sender: TObject);
begin
  FDlg.Defer(Self, faNot);
end;

procedure TFbRow.SetCurrentLook(AValue: Boolean);
var
  i: Integer;
begin
  FIsCurrent := AValue;
  if AValue then Color := BlendColor(clAccent, FBase, 9) else Color := FBase;
  Invalidate;
  for i := 0 to ControlCount - 1 do
    Controls[i].Invalidate;
end;

function TFbRow.ContentLeft: Integer;
begin
  Result := RAIL_X0 + FDepth * RAIL_STEP - 2;
end;

procedure TFbRow.LayoutRow;
var
  m: TFbMetrics;
  h, cy, right, x, w: Integer;
  op: TFilterOp;
  showRule, showValue: Boolean;
begin
  // Parent et Align declenchent la mise en page avant que les controles existent.
  if not FBuilt then Exit;
  m := FDlg.Metrics;
  h := ClientHeight;
  cy := h div 2;
  right := ClientWidth - 8;
  if FDelBtn <> nil then
  begin
    FDelBtn.SetBounds(right - m.BtnW, cy - m.BtnH div 2, m.BtnW, m.BtnH);
    Dec(right, m.BtnW + 2);
  end;
  if FMenuBtn <> nil then
  begin
    FMenuBtn.SetBounds(right - m.BtnW, cy - m.BtnH div 2, m.BtnW, m.BtnH);
    Dec(right, m.BtnW + 2);
  end;
  if FUnNotBtn <> nil then
  begin
    w := FUnNotBtn.PreferredWidth;
    FUnNotBtn.SetBounds(right - w, cy - m.BtnH div 2, w, m.BtnH);
    Dec(right, w + 6);
  end;
  x := ContentLeft;
  if FNotChip <> nil then
  begin
    FNotChip.SetBounds(x, cy - m.BtnH div 2 + 2, m.ChipW, m.BtnH - 4);
    Inc(x, m.ChipW + 8);
  end;
  {$IFDEF LCLGtk3}
  // GTK3 impose a l'entry la hauteur minimale de son theme et la laisse deborder du cadre. On la contraint.
  // Elle boude, mais elle reste dedans.
  if FAttr <> nil then FAttr.Constraints.MaxHeight := m.EditH;
  if FRule <> nil then FRule.Constraints.MaxHeight := m.EditH;
  if FValue <> nil then FValue.Constraints.MaxHeight := m.EditH;
  {$ENDIF}
  case FKind of
    frkCondition:
      begin
        FAttr.SetBounds(x + 7, cy - m.EditH div 2 + 1, m.AttrW - 14, m.EditH);
        Inc(x, m.AttrW + 8);
        FOp.SetBounds(x, cy - m.ComboH div 2, m.OpW, m.ComboH);
        Inc(x, m.OpW + 8);
        op := OpAt(FOp.ItemIndex);
        showRule := op = foExtensible;
        FRule.Visible := showRule;
        FDnAttrs.Visible := showRule;
        if showRule then
        begin
          FRule.SetBounds(x + 7, cy - m.EditH div 2 + 1, m.RuleW - 14, m.EditH);
          Inc(x, m.RuleW + 6);
          FDnAttrs.SetBounds(x, cy - m.ComboH div 2, m.DnW, m.ComboH);
          Inc(x, m.DnW + 6);
        end;
        showValue := not (op in [foPresent, foAbsent]);
        FValue.Visible := showValue;
        FValueLeft := x;
        if showValue then
          FValue.SetBounds(x + 7, cy - m.EditH div 2 + 1, Max(40, right - 8 - x - 14), m.EditH);
      end;
    frkGroup:
      begin
        w := FSwitch.PreferredWidth;
        FSwitch.SetBounds(x, cy - m.SwitchH div 2, w, m.SwitchH);
        FTextLeft := x + w + 12;
      end;
    frkNot:
      FTextLeft := x + MeasureText(Font, rsFbNotChip, [fsBold]) + 24 + 12;
    frkLocked:
      begin
        FLockLeft := x;
        FTextLeft := x + ScreenIconSize(16) + 10;
      end;
    frkAdd:
      begin
        w := FAddCond.PreferredWidth;
        FAddCond.SetBounds(x + 8, cy - m.LinkH div 2, w, m.LinkH);
        FAddGroup.SetBounds(x + 8 + w + 6, cy - m.LinkH div 2, FAddGroup.PreferredWidth, m.LinkH);
      end;
    frkEmpty:
      begin
        w := FAddCond.PreferredWidth;
        FAddCond.SetBounds((ClientWidth - w) div 2, (h * 2) div 3 - m.LinkH div 2, w, m.LinkH);
      end;
  end;
  Invalidate;
end;

procedure TFbRow.Resize;
begin
  inherited Resize;
  if FDlg <> nil then LayoutRow;
end;

procedure TFbRow.DrawFrame(AEdit: TEdit; AError: Boolean);
var
  r: TRect;
begin
  if (AEdit = nil) or not AEdit.Visible then Exit;
  r := AEdit.BoundsRect;
  InflateRect(r, 7, 5);
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clEditorBg;
  if AError then Canvas.Pen.Color := DialogStateColor(usError)
  else if AEdit.Focused then Canvas.Pen.Color := clAccent
  else Canvas.Pen.Color := BlendColor(clAppFg, Color, 30);
  Canvas.Pen.Width := 1;
  Canvas.RoundRect(r.Left, r.Top, r.Right, r.Bottom, 8, 8);
end;

procedure TFbRow.DrawRails;
var
  i, x, h, mid, last: Integer;
begin
  h := ClientHeight;
  mid := h div 2;
  Canvas.Pen.Style := psClear;
  last := High(FRails);
  for i := 0 to last do
  begin
    x := RAIL_X0 + i * RAIL_STEP;
    Canvas.Brush.Color := FRails[i];
    if (FKind = frkAdd) and (i = last) then
    begin
      Canvas.FillRect(Rect(x, 0, x + RAIL_W, mid + 1));
      Canvas.FillRect(Rect(x, mid - 1, ContentLeft + 4, mid + 2));
    end
    else
      Canvas.FillRect(Rect(x, 0, x + RAIL_W, h));
  end;
  if (FKind in [frkGroup, frkNot]) and (FOwnColor <> clNone) then
  begin
    x := RAIL_X0 + FDepth * RAIL_STEP;
    Canvas.Brush.Color := FOwnColor;
    Canvas.FillRect(Rect(x, mid + FDlg.Metrics.SwitchH div 2, x + RAIL_W, h));
  end;
  Canvas.Pen.Style := psSolid;
end;

procedure TFbRow.DrawTexts;
var
  x, y, w, px: Integer;
  t, muted: string;
  r: TRect;
  bmp: TBitmap;
  chip: TRect;
begin
  Canvas.Font.Assign(Font);
  Canvas.Brush.Style := bsClear;
  y := (ClientHeight - Canvas.TextHeight('Ag')) div 2;
  case FKind of
    frkGroup:
      begin
        Canvas.Font.Color := clAppFg;
        if FInner.Kind = fkAnd then t := rsFbGroupAndText else t := rsFbGroupOrText;
        Canvas.TextOut(FTextLeft, y, t);
        x := FTextLeft + Canvas.TextWidth(t) + 12;
        if FInner.Kind = fkAnd then t := '(&)' else t := '(|)';
        if FNegated then t := '(!' + t + ')';
        muted := Format(rsFbItems, [FInner.ChildCount]) + '  ' + t;
        Canvas.Font.Color := MutedColor(Color);
        Canvas.TextOut(x, y, muted);
      end;
    frkNot:
      begin
        Canvas.Font.Style := [fsBold];
        w := Canvas.TextWidth(rsFbNotChip) + 24;
        chip := Rect(ContentLeft, (ClientHeight - FDlg.Metrics.SwitchH) div 2, ContentLeft + w,
          (ClientHeight + FDlg.Metrics.SwitchH) div 2);
        Canvas.Brush.Style := bsSolid;
        Canvas.Brush.Color := FOwnColor;
        Canvas.Pen.Color := FOwnColor;
        Canvas.RoundRect(chip.Left, chip.Top, chip.Right, chip.Bottom, 8, 8);
        Canvas.Brush.Style := bsClear;
        Canvas.Font.Color := clAppBg;
        Canvas.TextOut(chip.Left + 12, y, rsFbNotChip);
        Canvas.Font.Style := [];
        Canvas.Font.Color := clAppFg;
        Canvas.TextOut(FTextLeft, y, rsFbNotText);
        Canvas.Font.Color := MutedColor(Color);
        Canvas.TextOut(FTextLeft + Canvas.TextWidth(rsFbNotText) + 12, y, '(!)');
      end;
    frkCondition:
      if not FValue.Visible then
      begin
        Canvas.Font.Color := MutedColor(Color);
        Canvas.Font.Style := [fsItalic];
        Canvas.TextOut(FValueLeft + 4, y, rsFbNoValue);
      end;
    frkLocked:
      begin
        px := ScreenIconSize(16);
        bmp := IconBitmap('lock', px, MutedColor(Color));
        if bmp <> nil then Canvas.Draw(FLockLeft + 2, (ClientHeight - px) div 2, bmp);
        if FMenuBtn <> nil then w := FMenuBtn.Left - 10 - FTextLeft else w := ClientWidth - FTextLeft;
        r := Rect(FTextLeft, 0, FTextLeft + Max(0, w), ClientHeight);
        Canvas.Font.Color := clAppFg;
        t := FilterToString(FInner);
        Canvas.TextRect(r, r.Left, y, t);
        x := r.Left + Canvas.TextWidth(t) + 14;
        if x < r.Right then
        begin
          Canvas.Font.Assign(Font);
          Canvas.Font.Color := MutedColor(Color);
          Canvas.TextRect(Rect(x, 0, r.Right, ClientHeight), x, y, FLockReason);
        end;
      end;
    frkEmpty:
      begin
        Canvas.Font.Style := [fsBold];
        Canvas.Font.Color := clAppFg;
        Canvas.TextOut((ClientWidth - Canvas.TextWidth(rsFbEmptyTitle)) div 2,
          ClientHeight div 3 - Canvas.TextHeight('Ag'), rsFbEmptyTitle);
        Canvas.Font.Style := [];
        Canvas.Font.Color := MutedColor(Color);
        Canvas.TextOut((ClientWidth - Canvas.TextWidth(rsFbEmptyHint)) div 2,
          ClientHeight div 3 + 2, rsFbEmptyHint);
      end;
  end;
end;

procedure TFbRow.Paint;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);
  if FIsCurrent then
  begin
    Canvas.Brush.Color := clAccent;
    Canvas.FillRect(Rect(0, 2, 3, ClientHeight - 2));
  end;
  DrawRails;
  DrawFrame(FAttr, FErrorField = 1);
  DrawFrame(FRule, FErrorField = 3);
  DrawFrame(FValue, FErrorField = 2);
  DrawTexts;
end;

procedure TFbRow.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if not IsNodeRow then Exit;
  FDlg.SetCurrent(Self);
  if CanFocus then SetFocus;
end;

procedure TFbRow.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbRight) and IsNodeRow then FDlg.ShowRowMenu(Self, True);
end;

procedure TFbRow.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if not IsNodeRow then Exit;
  if (Key = VK_DELETE) and (Shift = []) then
  begin
    FDlg.Defer(Self, faDelete);
    Key := 0;
  end
  else if (Key = VK_APPS) or ((Key = VK_F10) and (Shift = [ssShift])) then
  begin
    FDlg.ShowRowMenu(Self, False);
    Key := 0;
  end;
end;

procedure TFbRow.FieldChange(Sender: TObject);
begin
  if FDlg.FUpdating or FDlg.FClosing then Exit;
  FDlg.RowEdited(Self, Sender = FAttr);
end;

procedure TFbRow.FieldEnter(Sender: TObject);
begin
  if FDlg.FClosing then Exit;
  FDlg.RowFieldEntered(Self, TControl(Sender));
  Invalidate;
end;

procedure TFbRow.FieldExit(Sender: TObject);
begin
  if FDlg.FClosing then Exit;
  Invalidate;
  if Sender = FAttr then FDlg.AttrExited;
end;

procedure TFbRow.MenuClick(Sender: TObject);
begin
  FDlg.SetCurrent(Self);
  FDlg.ShowRowMenu(Self, False);
end;

procedure TFbRow.DeleteClick(Sender: TObject);
begin
  FDlg.Defer(Self, faDelete);
end;

procedure TFbRow.UnNotClick(Sender: TObject);
begin
  FDlg.Defer(Self, faNot);
end;

procedure TFbRow.AddCondClick(Sender: TObject);
begin
  FDlg.Defer(Self, faAddInto);
end;

procedure TFbRow.AddGroupClick(Sender: TObject);
begin
  FDlg.Defer(Self, faAddGroupInto);
end;

procedure TFbRow.SwitchToggle(Sender: TObject);
begin
  FDlg.Defer(Self, faToggleAndOr);
end;

function TFbRow.ReadCondition: TFilterCondition;
begin
  Result := Default(TFilterCondition);
  if FKind <> frkCondition then Exit;
  Result.Attr := Trim(FAttr.Text);
  Result.Op := OpAt(FOp.ItemIndex);
  Result.Value := RawByteString(FValue.Text);
  Result.MatchingRule := Trim(FRule.Text);
  Result.DnAttributes := FDnAttrs.Checked;
end;

procedure TFbRow.SetError(const AError: string; const C: TFilterCondition);
begin
  FError := AError;
  FErrorField := 0;
  if AError <> '' then
  begin
    if (AError = rsFbNoAttr) or (AError = Format(rsFbBadAttr, [C.Attr])) or (AError = rsFbExtNeeds) then
      FErrorField := 1
    else if AError = rsFbEmptyPattern then
      FErrorField := 2
    else if AError = Format(rsFbBadRule, [C.MatchingRule]) then
      FErrorField := 3;
  end;
  Invalidate;
end;

constructor TFilterBuilderDialog.CreateBuilder(AOwner: TComponent; ACtx: TAppContext;
  const AProfileUuid, AFilter: string);
var
  err: string;
begin
  inherited CreateDialog(AOwner, rsFbTitle, 1060, 720);
  SetIcon('filter');
  FCtx := ACtx;
  FProfileUuid := AProfileUuid;
  FRows := TFPList.Create;
  FPending := TFPList.Create;
  FUndo := TStringList.Create;
  FSuggestInfo := TStringList.Create;
  BuildUi;
  ComputeMetrics;
  err := '';
  if Trim(AFilter) <> '' then
    FRoot := FilterParse(AFilter, err);
  RebuildRows(nil, False);
  if err <> '' then
  begin
    SetExprText(AFilter);
    FTextProblem := err;
    Changed(True);
  end
  else
    Changed(False);
  ApplyTheme;
end;

destructor TFilterBuilderDialog.Destroy;
var
  i: Integer;
begin
  FClosing := True;
  Application.RemoveAsyncCalls(Self);
  for i := 0 to FPending.Count - 1 do
    TObject(FPending[i]).Free;
  FPending.Free;
  FRows.Free;
  FUndo.Free;
  FSuggestInfo.Free;
  FRoot.Free;
  FRoot := nil;
  inherited Destroy;
end;

function TFilterBuilderDialog.Schema: TSchemaSnapshot;
var
  c: TDirectoryConnection;
begin
  // Relu a chaque usage: une reconnexion peut remplacer le schema, et l'ancien n'existe plus.
  Result := nil;
  if FCtx = nil then Exit;
  c := FCtx.Connections.Find(FProfileUuid);
  if c <> nil then Result := c.Schema;
end;

procedure TFilterBuilderDialog.BuildUi;
var
  topPanel, head, statusRow, rulesHead, helpRow: TPanel;
  lbl: TLabel;
begin
  topPanel := MakePanel(Body, alTop);
  topPanel.AutoSize := True;
  head := MakePanel(topPanel, alTop, 30);
  lbl := MakeLabel(head, rsFbExprTitle, alLeft);
  lbl.Layout := tlCenter;
  lbl.Font.Style := [fsBold];
  FCopyBtn := TRtFlatButton.Create(head);
  FCopyBtn.Parent := head;
  FCopyBtn.Align := alRight;
  FCopyBtn.Setup('copy', rsFbCopy);
  FCopyBtn.OnClick := @CopyClick;
  FHistoryBtn := TRtFlatButton.Create(head);
  FHistoryBtn.Parent := head;
  FHistoryBtn.Align := alRight;
  FHistoryBtn.Setup('history', rsFbRecent + ' ' + #$E2#$96#$BE);
  FHistoryBtn.OnClick := @HistoryClick;
  FHistoryBtn.BorderSpacing.Right := 4;
  FText := MakeMemo(topPanel, alTop);
  FText.Height := 64;
  FText.WordWrap := True;
  FText.WantReturns := False;
  FText.ScrollBars := ssAutoVertical;
  FText.OnChange := @TextChanged;
  FText.OnEnter := @TextEnter;
  StackTop(FText);
  statusRow := MakePanel(topPanel, alTop, 26);
  FStatusIcon := TRtIcon.Create(statusRow);
  FStatusIcon.Parent := statusRow;
  FStatusIcon.Align := alLeft;
  FStatusIcon.Width := 24;
  FStatus := MakeDataLabel(statusRow, '', alClient);
  FStatus.Layout := tlCenter;
  FStatus.WordWrap := False;
  FWords := MakeDataLabel(topPanel, '', alTop);
  FWords.WordWrap := True;

  rulesHead := MakePanel(Body, alTop, 34);
  rulesHead.BorderSpacing.Top := 6;
  lbl := MakeLabel(rulesHead, rsFbConditions, alLeft);
  lbl.Layout := tlCenter;
  lbl.Font.Style := [fsBold];
  FUndoBtn := TRtFlatButton.Create(rulesHead);
  FUndoBtn.Parent := rulesHead;
  FUndoBtn.Align := alRight;
  FUndoBtn.Setup('refresh', rsFbUndo);
  FUndoBtn.OnClick := @UndoClick;

  helpRow := MakePanel(Body, alBottom, 58);
  helpRow.BorderSpacing.Top := 4;
  FHelpIcon := TRtIcon.Create(helpRow);
  FHelpIcon.Parent := helpRow;
  FHelpIcon.Align := alLeft;
  FHelpIcon.Width := 24;
  FHelpIcon.TopAligned := True;
  FHelpIcon.BorderSpacing.Top := 4;
  FHelp := MakeDataLabel(helpRow, '', alClient);
  FHelp.WordWrap := True;
  FHelpRow := helpRow;

  FScroll := TRtScrollBox.Create(Body);
  FScroll.Parent := Body;
  FScroll.Align := alClient;
  FScroll.HorzScrollBar.Visible := False;
  FScroll.VertScrollBar.Tracking := True;
  FScroll.OnMouseWheel := @ScrollWheel;

  FSuggestBox := TPanel.Create(Self);
  FSuggestBox.Parent := Self;
  FSuggestBox.BevelOuter := bvNone;
  FSuggestBox.ParentColor := False;
  FSuggestBox.Visible := False;
  FSuggest := TListBox.Create(FSuggestBox);
  FSuggest.Parent := FSuggestBox;
  FSuggest.Align := alClient;
  FSuggest.BorderSpacing.Around := 1;
  FSuggest.BorderStyle := bsNone;
  FSuggest.Style := lbOwnerDrawFixed;
  FSuggest.OnDrawItem := @SuggestDraw;
  FSuggest.OnMouseUp := @SuggestMouseUp;

  FMenu := TPopupMenu.Create(Self);
  FHistoryMenu := TPopupMenu.Create(Self);

  FOk := AddButton(rsOk, mrOk, True);
  AddButton(rsCancel, mrCancel, False, True);
end;

procedure TFilterBuilderDialog.ComputeMetrics;
var
  bmp: Graphics.TBitmap;
  op: TFilterOp;
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
    FMetrics.ComboH := FMetrics.EditH + 10;
    FMetrics.LinkH := FMetrics.EditH + 6;
    FMetrics.AddH := FMetrics.LinkH + 8;
    FMetrics.AttrW := bmp.Canvas.TextWidth('0') * 20 + 14;
    FMetrics.RuleW := bmp.Canvas.TextWidth('0') * 16 + 14;
    FMetrics.DnW := bmp.Canvas.TextWidth(':dn') + FMetrics.EditH + 26;
    w := 0;
    for op := Low(TFilterOp) to High(TFilterOp) do
      w := Max(w, bmp.Canvas.TextWidth(OP_LABELS[op]));
    FMetrics.ChipW := bmp.Canvas.TextWidth('NOT') + 18;
    FMetrics.OpW := w + 34;
  finally
    bmp.Free;
  end;
end;

procedure TFilterBuilderDialog.ApplyShellColors;
var
  i: Integer;
begin
  inherited ApplyShellColors;
  ComputeMetrics;
  FText.Height := FontTextHeight(FText.Font) * 3 + 12;
  FHelpRow.Height := FontTextHeight(FHelp.Font) * 4 + 10;
  FSuggestBox.Color := BlendColor(clAppFg, clMenuPopupBg, 30);
  FSuggest.Color := clMenuPopupBg;
  FSuggest.Font.Color := clMenuText;
  if RSUiFontName <> '' then FSuggest.Font.Name := RSUiFontName;
  FSuggest.Font.Size := RSUiFontSize;
  FSuggest.ItemHeight := FontTextHeight(FSuggest.Font) + 8;
  FWords.Font.Color := DialogStateColor(usMuted);
  FHelp.Font.Color := DialogStateColor(usMuted);
  FHelpIcon.SetIcon('info-circle', 16, DialogStateColor(usMuted));
  for i := 0 to FRows.Count - 1 do
    TFbRow(FRows[i]).Restyle;
  UpdateStatus;
end;

function TFilterBuilderDialog.Serialized: string;
begin
  if FRoot = nil then Result := '' else Result := FilterToString(FRoot);
end;

function TFilterBuilderDialog.Selected: TFilterNode;
begin
  Result := nil;
  if FCurrent <> nil then Result := FCurrent.Node;
end;

function TFilterBuilderDialog.NodeRowCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FRows.Count - 1 do
    if TFbRow(FRows[i]).IsNodeRow then Inc(Result);
end;

function TFilterBuilderDialog.NodeRow(AIndex: Integer): TFbRow;
var
  i, n: Integer;
begin
  n := 0;
  for i := 0 to FRows.Count - 1 do
    if TFbRow(FRows[i]).IsNodeRow then
    begin
      if n = AIndex then Exit(TFbRow(FRows[i]));
      Inc(n);
    end;
  Result := nil;
end;

function TFilterBuilderDialog.NodeRowIndex(ARow: TFbRow): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to FRows.Count - 1 do
    if TFbRow(FRows[i]).IsNodeRow then
    begin
      Inc(Result);
      if FRows[i] = Pointer(ARow) then Exit;
    end;
  Result := -1;
end;

function TFilterBuilderDialog.RowOf(AControl: TControl): TFbRow;
begin
  while (AControl <> nil) and not (AControl is TFbRow) do
    AControl := AControl.Parent;
  Result := TFbRow(AControl);
end;

procedure TFilterBuilderDialog.RebuildRows(ASelect: TFilterNode; AFocus: Boolean;
  AFallbackIndex: Integer);
var
  y: Integer;
  pick: TFbRow;
  i: Integer;

  function NewRow(AKind: TFbRowKind; ANode, AGroup: TFilterNode; ADepth: Integer;
    const ARails: TFbColors; ANegated: Boolean = False): TFbRow;
  begin
    Result := TFbRow.CreateRow(FScroll, Self, AKind, ANode, AGroup, ANegated, ADepth, ARails);
    Result.Top := y;
    Inc(y, Result.Height);
    FRows.Add(Result);
    if (ANode <> nil) and (ANode = ASelect) then pick := Result;
  end;

  procedure AddNode(ANode: TFilterNode; ADepth: Integer; const ARails: TFbColors);
  var
    c: TFilterCondition;
    rails: TFbColors;
    k: Integer;
    inner: TFilterNode;
  begin
    if (ANode.Kind = fkNot) and (ANode.ChildCount = 1) and (ANode.Children[0].Kind <> fkNot) then
    begin
      inner := ANode.Children[0];
      if inner.Kind in [fkAnd, fkOr] then
      begin
        NewRow(frkGroup, ANode, nil, ADepth, ARails, True);
        rails := AppendColor(ARails, FilterGroupColor(inner.Kind));
        for k := 0 to inner.ChildCount - 1 do
          AddNode(inner.Children[k], ADepth + 1, rails);
        NewRow(frkAdd, nil, inner, ADepth + 1, rails);
        Exit;
      end;
      if NodeToCondition(inner, c) then
      begin
        if not (c.Op in [foPresent, foAbsent]) and not IsValidUtf8(c.Value) then
          NewRow(frkLocked, ANode, nil, ADepth, ARails, True)
        else
          NewRow(frkCondition, ANode, nil, ADepth, ARails, True);
        Exit;
      end;
    end;
    if NodeToCondition(ANode, c) then
    begin
      // Valeur non representable dans un champ texte: verrouillee et intacte. L'editer la remplacerait en
      // silence.
      if not (c.Op in [foPresent, foAbsent]) and not IsValidUtf8(c.Value) then
        NewRow(frkLocked, ANode, nil, ADepth, ARails)
      else
        NewRow(frkCondition, ANode, nil, ADepth, ARails);
      Exit;
    end;
    case ANode.Kind of
      fkAnd, fkOr:
        begin
          NewRow(frkGroup, ANode, nil, ADepth, ARails);
          rails := AppendColor(ARails, FilterGroupColor(ANode.Kind));
          for k := 0 to ANode.ChildCount - 1 do
            AddNode(ANode.Children[k], ADepth + 1, rails);
          NewRow(frkAdd, nil, ANode, ADepth + 1, rails);
        end;
      fkNot:
        begin
          NewRow(frkNot, ANode, nil, ADepth, ARails);
          rails := AppendColor(ARails, FilterGroupColor(fkNot));
          for k := 0 to ANode.ChildCount - 1 do
            AddNode(ANode.Children[k], ADepth + 1, rails);
        end;
    else
      NewRow(frkLocked, ANode, nil, ADepth, ARails);
    end;
  end;

begin
  HideSuggest;
  FSuggestFor := nil;
  FMenuRow := nil;
  FUpdating := True;
  FScroll.DisableAlign;
  try
    for i := FRows.Count - 1 downto 0 do
      TObject(FRows[i]).Free;
    FRows.Clear;
    FCurrent := nil;
    pick := nil;
    y := 0;
    if FRoot = nil then
      NewRow(frkEmpty, nil, nil, 0, nil)
    else
    begin
      AddNode(FRoot, 0, nil);
      if not (FRoot.Kind in [fkAnd, fkOr]) then
        NewRow(frkAdd, nil, nil, 0, nil);
    end;
  finally
    FScroll.EnableAlign;
    FUpdating := False;
  end;
  if (pick = nil) and (NodeRowCount > 0) then
    pick := NodeRow(Min(Max(AFallbackIndex, 0), NodeRowCount - 1));
  SetCurrent(pick);
  if AFocus then FocusRow(pick);
end;

procedure TFilterBuilderDialog.FocusRow(ARow: TFbRow; ASameField: TControl);
var
  target: TWinControl;
begin
  if (ARow = nil) or not Showing then Exit;
  FScroll.ScrollInView(ARow);
  target := nil;
  if ARow.Kind = frkCondition then
  begin
    target := ARow.FAttr;
    if (ASameField is TEdit) and (RowOf(ASameField) <> nil) then
    begin
      if (ASameField = RowOf(ASameField).FValue) and ARow.FValue.Visible then target := ARow.FValue
      else if ASameField = RowOf(ASameField).FRule then
      begin
        if ARow.FRule.Visible then target := ARow.FRule;
      end;
    end;
  end
  else if ARow.Kind = frkGroup then
    target := ARow.FSwitch;
  if (target <> nil) and target.CanFocus then
  begin
    target.SetFocus;
    if target is TEdit then TEdit(target).SelectAll;
  end
  else if ARow.CanFocus then
    ARow.SetFocus;
end;

procedure TFilterBuilderDialog.SetCurrent(ARow: TFbRow);
begin
  if (ARow <> nil) and not ARow.IsNodeRow then ARow := nil;
  if FCurrent <> ARow then
  begin
    if FCurrent <> nil then FCurrent.SetCurrentLook(False);
    FCurrent := ARow;
    if FCurrent <> nil then FCurrent.SetCurrentLook(True);
  end;
  UpdateHelp;
  UpdateStatus;
end;

procedure TFilterBuilderDialog.SetExprText(const AText: string);
begin
  FUpdatingText := True;
  try
    FText.Text := AText;
  finally
    FUpdatingText := False;
  end;
end;

procedure TFilterBuilderDialog.Changed(AFromText: Boolean);
begin
  if not AFromText then
  begin
    FTextProblem := '';
    SetExprText(Serialized);
  end;
  if FRoot = nil then
    FWords.Caption := rsFbWordsEmpty
  else
    FWords.Caption := Format(rsFbWords, [FilterInWords(FRoot)]);
  UpdateStatus;
  UpdateHelp;
  FUndoBtn.Enabled := FUndo.Count > 0;
end;

procedure TFilterBuilderDialog.UpdateStatus;
var
  err, p: string;
  i: Integer;
  state: TUiState;
  iconId: string;
begin
  if FStatus = nil then Exit;
  err := '';
  if (FCurrent <> nil) and (FCurrent.FError <> '') then err := FCurrent.FError;
  if err = '' then
    for i := 0 to FRows.Count - 1 do
      if TFbRow(FRows[i]).FError <> '' then
      begin
        err := TFbRow(FRows[i]).FError;
        Break;
      end;
  if FTextProblem <> '' then
  begin
    FStatus.Caption := Format(rsFbTextInvalid, [FTextProblem]);
    state := usError;
  end
  else if err <> '' then
  begin
    FStatus.Caption := Format(rsFbInvalid, [err]);
    state := usError;
  end
  else
  begin
    p := BuilderProblem(FRoot);
    if p = '' then
    begin
      FStatus.Caption := rsFbValid;
      state := usOk;
    end
    else if FRoot = nil then
    begin
      FStatus.Caption := rsFbEmptyStatus;
      state := usMuted;
    end
    else
    begin
      FStatus.Caption := Format(rsFbInvalid, [p]);
      state := usError;
    end;
  end;
  FStatus.Font.Color := DialogStateColor(state);
  case state of
    usOk: iconId := 'circle-check';
    usError: iconId := 'alert-triangle';
  else
    iconId := 'info-circle';
  end;
  FStatusIcon.SetIcon(iconId, 16, DialogStateColor(state));
  FOk.Enabled := state = usOk;
end;

function TFilterBuilderDialog.AttrInfo(const AName: string): string;
var
  s: TSchemaSnapshot;
  sug: TSchemaSuggestionArray;
  i: Integer;
begin
  Result := '';
  s := Schema;
  if (s = nil) or (AName = '') then Exit;
  sug := s.SuggestAttributes(AName, [], 60);
  for i := 0 to High(sug) do
    if SameText(sug[i].Name, AName) then
    begin
      Result := sug[i].Name + ': ' + sug[i].Oid;
      if sug[i].SingleValue then Result := Result + ', ' + rsFbSingle;
      if sug[i].Kind = sskOperational then Result := Result + ', ' + rsFbOperational;
      if sug[i].ReadOnly then Result := Result + ', ' + rsFbReadOnly;
      if sug[i].Help <> '' then Result := Result + ' - ' + sug[i].Help;
      Exit;
    end;
  // Attribut inconnu du schema: accepte, le serveur l'evaluera comme Undefined.
  if IsValidAttributeDescription(AName) and (Pos(';', AName) = 0) then
    Result := Format(rsFbUnknownAttr, [AName]);
end;

procedure TFilterBuilderDialog.UpdateHelp;
var
  t: string;
  c: TFilterCondition;
  info: string;
begin
  if FHelp = nil then Exit;
  t := '';
  if (ActiveControl = FText) and (FText <> nil) then
    t := rsFbHelpText
  else if FCurrent = nil then
    t := rsFbHelpStart
  else
    case FCurrent.Kind of
      frkCondition:
        begin
          c := FCurrent.ReadCondition;
          info := AttrInfo(c.Attr);
          if info <> '' then t := info + LineEnding;
          t := t + OpHelp(c.Op);
          if (c.Op in [foEquals, foNotEquals, foStartsWith, foEndsWith, foContains,
            foGreaterOrEqual, foLessOrEqual, foApprox, foExtensible]) and
            (LastDelimiter('*()\', string(c.Value)) > 0) then
            t := t + ' ' + rsFbLiteral;
          if FCurrent.Negated then t := Format(rsFbHelpNegated, [rsFbWordCondition]) + LineEnding + t;
          if FCurrent.FError = '' then
            t := t + LineEnding + Format(rsFbFragment, [FilterToString(FCurrent.Node)]);
        end;
      frkGroup:
        begin
          if FCurrent.Inner.Kind = fkAnd then t := rsFbHelpAll else t := rsFbHelpAny;
          if FCurrent.Negated then t := Format(rsFbHelpNegated, [rsFbWordGroup]) + ' ' + t;
          t := t + LineEnding + Format(rsFbFragment, [FilterToString(FCurrent.Node)]);
        end;
      frkNot:
        t := rsFbHelpNot + LineEnding + Format(rsFbFragment, [FilterToString(FCurrent.Node)]);
      frkLocked:
        t := FCurrent.FLockReason;
    end;
  FHelp.Caption := t + LineEnding + rsFbKeys;
end;

procedure TFilterBuilderDialog.PushUndo;
var
  s: string;
begin
  s := Serialized;
  if (FUndo.Count > 0) and (FUndo[FUndo.Count - 1] = s) then Exit;
  FUndo.Add(s);
  if FUndo.Count > 200 then FUndo.Delete(0);
  FUndoBtn.Enabled := True;
end;

procedure TFilterBuilderDialog.BeginTyping(AOwner: TObject);
begin
  if FTypingOwner = AOwner then Exit;
  PushUndo;
  FTypingOwner := AOwner;
end;

procedure TFilterBuilderDialog.ReplaceRoot(ANew: TFilterNode);
begin
  FRoot.Free;
  FRoot := ANew;
end;

procedure TFilterBuilderDialog.RowEdited(ARow: TFbRow; AAttrChanged: Boolean);
var
  c: TFilterCondition;
  n: TFilterNode;
  err: string;
begin
  if FUpdating or (ARow.Kind <> frkCondition) then Exit;
  BeginTyping(ARow);
  c := ARow.ReadCondition;
  ARow.LayoutRow;
  n := ConditionToNode(c, err);
  if AAttrChanged then FillSuggestions(ARow, True);
  if n = nil then
  begin
    ARow.SetError(err, c);
    UpdateStatus;
    UpdateHelp;
    Exit;
  end;
  ARow.SetError('', c);
  if ARow.FNegated then n := FltNot(n);
  BuilderReplace(FRoot, ARow.FNode, n);
  ARow.FNode := n;
  if ARow.FNegated then ARow.FInner := n.Children[0] else ARow.FInner := n;
  Changed(False);
end;

procedure TFilterBuilderDialog.RowFieldEntered(ARow: TFbRow; AField: TControl);
begin
  SetCurrent(ARow);
  if AField = ARow.FAttr then FillSuggestions(ARow, True) else HideSuggest;
end;

procedure TFilterBuilderDialog.AttrExited;
begin
  // Le clic dans la liste lui donne le focus: on verifie apres coup, une fois le focus vraiment pose.
  if not FClosing then Application.QueueAsyncCall(@CheckSuggestFocus, 0);
end;

procedure TFilterBuilderDialog.CheckSuggestFocus(AData: PtrInt);
begin
  if FClosing or not FSuggestBox.Visible then Exit;
  if (ActiveControl = FSuggest) then Exit;
  if (FSuggestFor <> nil) and FSuggestFor.FAttr.Focused then Exit;
  HideSuggest;
end;

procedure TFilterBuilderDialog.FillSuggestions(ARow: TFbRow; AShow: Boolean);
var
  s: TSchemaSnapshot;
  sug: TSchemaSuggestionArray;
  i: Integer;
  info, prefix: string;
begin
  FSuggestFor := ARow;
  FSuggest.Items.BeginUpdate;
  try
    FSuggest.Items.Clear;
    FSuggestInfo.Clear;
    s := Schema;
    if (s = nil) or (ARow = nil) or (ARow.FAttr = nil) then Exit;
    prefix := Trim(ARow.FAttr.Text);
    sug := s.SuggestAttributes(prefix, [], 60);
    for i := 0 to High(sug) do
    begin
      if sug[i].Obsolete then Continue;
      FSuggest.Items.Add(sug[i].Name);
      info := '';
      if sug[i].SingleValue then info := rsFbSingle;
      if sug[i].Kind = sskOperational then
      begin
        if info <> '' then info := info + ', ';
        info := info + rsFbOperational;
      end;
      FSuggestInfo.Add(info);
    end;
  finally
    FSuggest.Items.EndUpdate;
  end;
  if (FSuggest.Items.Count = 0) or ((FSuggest.Items.Count = 1) and
     SameText(FSuggest.Items[0], Trim(ARow.FAttr.Text))) then
    HideSuggest
  else if AShow then
    ShowSuggest;
end;

procedure TFilterBuilderDialog.ShowSuggest;
var
  p: TPoint;
  e: TEdit;
  h, w, n: Integer;
begin
  if (FSuggestFor = nil) or not Showing or not FSuggestFor.FAttr.Focused then Exit;
  e := FSuggestFor.FAttr;
  n := Min(FSuggest.Items.Count, 9);
  h := n * FSuggest.ItemHeight + 2;
  w := Max(e.Width + 14, Metrics.AttrW + 140);
  p := ScreenToClient(e.ClientToScreen(Point(-7, e.Height + 6)));
  if p.Y + h > ClientHeight - 4 then
    p.Y := ScreenToClient(e.ClientToScreen(Point(0, -6))).Y - h;
  FSuggestBox.SetBounds(p.X, p.Y, w, h);
  FSuggest.ItemIndex := -1;
  FSuggestBox.Visible := True;
  FSuggestBox.BringToFront;
end;

procedure TFilterBuilderDialog.HideSuggest;
begin
  if FSuggestBox <> nil then FSuggestBox.Visible := False;
end;

procedure TFilterBuilderDialog.PickSuggestion(AIndex: Integer);
var
  row: TFbRow;
begin
  row := FSuggestFor;
  if (row = nil) or (FRows.IndexOf(row) < 0) or (AIndex < 0) or
     (AIndex >= FSuggest.Items.Count) then Exit;
  HideSuggest;
  row.FAttr.Text := FSuggest.Items[AIndex];
  row.FAttr.SelStart := Length(row.FAttr.Text);
  HideSuggest;
  if row.FOp.CanFocus then row.FOp.SetFocus;
end;

procedure TFilterBuilderDialog.SuggestDraw(Control: TWinControl; Index: Integer; ARect: TRect;
  State: TOwnerDrawState);
var
  cv: TCanvas;
  bg: TColor;
  info: string;
  y: Integer;
begin
  cv := FSuggest.Canvas;
  if odSelected in State then bg := clMenuHover else bg := clMenuPopupBg;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := bg;
  cv.FillRect(ARect);
  cv.Font.Assign(FSuggest.Font);
  cv.Font.Color := clMenuText;
  y := ARect.Top + (ARect.Bottom - ARect.Top - cv.TextHeight('Ag')) div 2;
  cv.Brush.Style := bsClear;
  cv.TextOut(ARect.Left + 8, y, FSuggest.Items[Index]);
  if Index < FSuggestInfo.Count then
  begin
    info := FSuggestInfo[Index];
    if info <> '' then
    begin
      cv.Font.Color := BlendColor(clMenuText, bg, 55);
      cv.TextOut(ARect.Right - 8 - cv.TextWidth(info), y, info);
    end;
  end;
end;

procedure TFilterBuilderDialog.SuggestMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  if Button <> mbLeft then Exit;
  i := FSuggest.ItemAtPos(Point(X, Y), True);
  if i >= 0 then PickSuggestion(i);
end;

procedure TFilterBuilderDialog.ScrollWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint; var Handled: Boolean);
begin
  HideSuggest;
end;

procedure TFilterBuilderDialog.TextChanged(Sender: TObject);
var
  t, err: string;
  n: TFilterNode;
begin
  if FUpdatingText or FClosing then Exit;
  BeginTyping(FText);
  // Un filtre colle arrive souvent avec ses retours a la ligne, que RFC 4515 ignore superbement.
  t := Trim(StringReplace(StringReplace(FText.Text, #13, '', [rfReplaceAll]), #10, '',
    [rfReplaceAll]));
  if t = '' then
  begin
    ReplaceRoot(nil);
    FTextProblem := '';
    RebuildRows(nil, False);
    Changed(True);
    Exit;
  end;
  n := FilterParse(t, err);
  if n = nil then
  begin
    FTextProblem := err;
    UpdateStatus;
    Exit;
  end;
  ReplaceRoot(n);
  FTextProblem := '';
  RebuildRows(nil, False, NodeRowIndex(FCurrent));
  Changed(True);
end;

procedure TFilterBuilderDialog.TextEnter(Sender: TObject);
begin
  HideSuggest;
  UpdateHelp;
end;

procedure TFilterBuilderDialog.UndoClick(Sender: TObject);
begin
  Defer(nil, faUndo);
end;

procedure TFilterBuilderDialog.CopyClick(Sender: TObject);
begin
  Clipboard.AsText := FText.Text;
end;

procedure TFilterBuilderDialog.HistoryClick(Sender: TObject);
var
  hist: TSavedSearches;
  seen: TStringList;
  i: Integer;
  mi: TMenuItem;
  p: TPoint;
  cap: string;
begin
  FHistoryMenu.Items.Clear;
  seen := TStringList.Create;
  try
    seen.Sorted := True;
    seen.Duplicates := dupIgnore;
    if FCtx.Document = nil then
    begin
      mi := TMenuItem.Create(FHistoryMenu);
      mi.Caption := rsFbNoDocument;
      mi.Enabled := False;
      FHistoryMenu.Items.Add(mi);
    end
    else
    begin
      hist := LoadSearchHistory(FCtx.Document, FProfileUuid);
      for i := 0 to High(hist) do
      begin
        if (Trim(hist[i].Filter) = '') or (seen.IndexOf(hist[i].Filter) >= 0) then Continue;
        seen.Add(hist[i].Filter);
        mi := TMenuItem.Create(FHistoryMenu);
        cap := hist[i].Filter;
        if Length(cap) > 90 then cap := Copy(cap, 1, 89) + #$E2#$80#$A6;
        mi.Caption := StringReplace(cap, '&', '&&', [rfReplaceAll]);
        mi.Hint := hist[i].Filter;
        mi.OnClick := @HistoryItemClick;
        FHistoryMenu.Items.Add(mi);
        if FHistoryMenu.Items.Count >= 20 then Break;
      end;
      if FHistoryMenu.Items.Count = 0 then
      begin
        mi := TMenuItem.Create(FHistoryMenu);
        mi.Caption := rsFbNoRecent;
        mi.Enabled := False;
        FHistoryMenu.Items.Add(mi);
      end;
    end;
  finally
    seen.Free;
  end;
  ThemePopupMenu(FHistoryMenu);
  p := FHistoryBtn.ClientToScreen(Point(0, FHistoryBtn.Height));
  FHistoryMenu.PopUp(p.X, p.Y);
end;

procedure TFilterBuilderDialog.HistoryItemClick(Sender: TObject);
begin
  if not (Sender is TMenuItem) then Exit;
  FTypingOwner := nil;
  PushUndo;
  FTypingOwner := FText;
  SetFilterText(TMenuItem(Sender).Hint);
  FTypingOwner := nil;
end;

procedure TFilterBuilderDialog.ShowRowMenu(ARow: TFbRow; AAtMouse: Boolean);
var
  p: TPoint;
  n, par: TFilterNode;
  idx: Integer;

  procedure Item(const ACaption: string; AAction: TFbAction; AEnabled: Boolean = True);
  var
    mi: TMenuItem;
  begin
    mi := TMenuItem.Create(FMenu);
    mi.Caption := ACaption;
    mi.Tag := Ord(AAction);
    mi.Enabled := AEnabled;
    mi.OnClick := @MenuItemClick;
    FMenu.Items.Add(mi);
  end;

  procedure Sep;
  var
    mi: TMenuItem;
  begin
    mi := TMenuItem.Create(FMenu);
    mi.Caption := '-';
    FMenu.Items.Add(mi);
  end;

begin
  if (ARow = nil) or not ARow.IsNodeRow then Exit;
  SetCurrent(ARow);
  FMenuRow := ARow;
  n := ARow.Node;
  par := FindParent(FRoot, n, idx);
  FMenu.Items.Clear;
  Item(rsFbMenuAddCond, faAddCond);
  Sep;
  case ARow.Kind of
    frkGroup:
      begin
        if ARow.Inner.Kind = fkAnd then Item(rsFbMenuToAny, faToggleAndOr)
        else Item(rsFbMenuToAll, faToggleAndOr);
        if ARow.Negated then Item(rsFbMenuUnNot, faNot) else Item(rsFbMenuNot, faNot);
      end;
    frkNot:
      Item(rsFbMenuUnNot, faNot);
  else
    if ARow.Negated or ((par <> nil) and (par.Kind = fkNot)) then Item(rsFbMenuUnNot, faNot)
    else Item(rsFbMenuNot, faNot);
  end;
  Item(rsFbMenuWrapAll, faWrapAll);
  Item(rsFbMenuWrapAny, faWrapAny);
  Item(rsFbMenuDuplicate, faDuplicate);
  Sep;
  Item(rsFbMenuUp, faUp, CanMove(n, -1));
  Item(rsFbMenuDown, faDown, CanMove(n, 1));
  Sep;
  Item(rsFbMenuDelete, faDelete);
  ThemePopupMenu(FMenu);
  if AAtMouse then
    p := Mouse.CursorPos
  else if ARow.FMenuBtn <> nil then
    p := ARow.FMenuBtn.ClientToScreen(Point(0, ARow.FMenuBtn.Height))
  else
    p := ARow.ClientToScreen(Point(ARow.ContentLeft, ARow.Height));
  FMenu.PopUp(p.X, p.Y);
end;

procedure TFilterBuilderDialog.MenuItemClick(Sender: TObject);
begin
  if Sender is TMenuItem then
    Defer(FMenuRow, TFbAction(TMenuItem(Sender).Tag));
end;

function TFilterBuilderDialog.CanMove(ANode: TFilterNode; ADelta: Integer): Boolean;
var
  par: TFilterNode;
  idx: Integer;
begin
  par := FindParent(FRoot, ANode, idx);
  Result := (par <> nil) and (idx + ADelta >= 0) and (idx + ADelta < par.ChildCount);
end;

procedure TFilterBuilderDialog.Defer(ARow: TFbRow; AAction: TFbAction);
var
  d: TFbDeferred;
begin
  if FClosing then Exit;
  // Reconstruction differee: jamais depuis le gestionnaire d'un des controles detruits, encore sur la pile.
  // Scier la branche, d'accord, mais pas assis dessus.
  d := TFbDeferred.Create;
  d.Row := ARow;
  d.Action := AAction;
  FPending.Add(d);
  Application.QueueAsyncCall(@RunDeferred, PtrInt(d));
end;

procedure TFilterBuilderDialog.RunDeferred(AData: PtrInt);
var
  d: TFbDeferred;
  row: TFbRow;
  act: TFbAction;
begin
  d := TFbDeferred(AData);
  if FPending.IndexOf(d) < 0 then Exit;
  FPending.Remove(d);
  row := d.Row;
  act := d.Action;
  d.Free;
  if FClosing then Exit;
  if (row <> nil) and (FRows.IndexOf(row) < 0) then Exit;
  case act of
    faUndo: Undo;
    faAddInto, faAddGroupInto:
      if row <> nil then
      begin
        if row.IsNodeRow then
        begin
          SetCurrent(row);
          if act = faAddInto then AddCondition else AddGroup(row.Inner.Kind = fkAnd);
        end
        else
          AddInto(row.FGroup, act = faAddGroupInto);
      end;
  else
    if row <> nil then SetCurrent(row);
    case act of
      faAddCond: AddCondition;
      faDelete: DeleteSelected;
      faNot: ToggleNot;
      faToggleAndOr: ToggleAndOr;
      faUp: MoveSelected(-1);
      faDown: MoveSelected(1);
      faWrapAll: WrapSelected(False);
      faWrapAny: WrapSelected(True);
      faDuplicate: DuplicateSelected;
    end;
  end;
end;

procedure TFilterBuilderDialog.AddInto(AGroup: TFilterNode; AAsGroup: Boolean);
var
  c: TFilterCondition;
  err: string;
  child, n: TFilterNode;
  asOr: Boolean;
begin
  FTypingOwner := nil;
  PushUndo;
  c := DefaultCondition;
  child := ConditionToNode(c, err);
  n := child;
  if AAsGroup then
  begin
    asOr := not ((AGroup <> nil) and (AGroup.Kind = fkOr));
    if asOr then n := FltOr([child]) else n := FltAnd([child]);
  end;
  if AGroup <> nil then AGroup.AddChild(n) else BuilderAdd(FRoot, nil, n);
  RebuildRows(child, Showing);
  Changed(False);
end;

procedure TFilterBuilderDialog.KeyDown(var Key: Word; Shift: TShiftState);
var
  ac: TWinControl;
  row, target: TFbRow;
  i: Integer;
begin
  ac := ActiveControl;
  if FSuggestBox.Visible and (FSuggestFor <> nil) and (ac = FSuggestFor.FAttr) then
    case Key of
      VK_DOWN, VK_UP:
        if Shift = [] then
        begin
          i := FSuggest.ItemIndex;
          if Key = VK_DOWN then Inc(i) else Dec(i);
          FSuggest.ItemIndex := Max(0, Min(FSuggest.Items.Count - 1, i));
          Key := 0;
          Exit;
        end;
      VK_RETURN, VK_TAB:
        if (Shift = []) and (FSuggest.ItemIndex >= 0) then
        begin
          PickSuggestion(FSuggest.ItemIndex);
          Key := 0;
          Exit;
        end;
      VK_ESCAPE:
        begin
          HideSuggest;
          Key := 0;
          Exit;
        end;
    end;
  row := RowOf(ac);
  if (Key = VK_RETURN) and (Shift = [ssCtrl]) then
  begin
    if row = nil then row := FCurrent;
    Defer(row, faAddCond);
    Key := 0;
    Exit;
  end;
  if (Key = VK_N) and (Shift = [ssAlt]) and (row <> nil) then
  begin
    Defer(row, faNot);
    Key := 0;
    Exit;
  end;
  if (Key = VK_DELETE) and (Shift = [ssAlt]) and (row <> nil) then
  begin
    Defer(row, faDelete);
    Key := 0;
    Exit;
  end;
  if (Key in [VK_UP, VK_DOWN]) and (Shift = [ssAlt]) and (row <> nil) and
     not (ac is TRtComboBox) then
  begin
    if Key = VK_UP then Defer(row, faUp) else Defer(row, faDown);
    Key := 0;
    Exit;
  end;
  if (Key = VK_Z) and (Shift = [ssCtrl]) and (ac <> FText) then
  begin
    Defer(nil, faUndo);
    Key := 0;
    Exit;
  end;
  if (Key in [VK_UP, VK_DOWN]) and (Shift = []) and (row <> nil) and
     ((ac is TEdit) or (ac = row) or (ac is TRtSegmented)) then
  begin
    i := NodeRowIndex(row);
    if Key = VK_UP then Dec(i) else Inc(i);
    target := NodeRow(i);
    if target <> nil then
    begin
      HideSuggest;
      SetCurrent(target);
      FocusRow(target, ac);
    end;
    Key := 0;
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

function TFilterBuilderDialog.FilterText: string;
begin
  if not OkEnabled then Exit('');
  Result := Serialized;
end;

function TFilterBuilderDialog.Problem: string;
begin
  Result := BuilderProblem(FRoot);
end;

procedure TFilterBuilderDialog.SelectItem(AIndex: Integer);
var
  row: TFbRow;
begin
  row := NodeRow(AIndex);
  if row <> nil then SetCurrent(row);
end;

function TFilterBuilderDialog.AddTarget: TFilterNode;
begin
  Result := Selected;
  if (FCurrent <> nil) and (FCurrent.Kind = frkGroup) then Result := FCurrent.Inner;
end;

procedure TFilterBuilderDialog.AddCondition;
var
  c: TFilterCondition;
  err: string;
  n: TFilterNode;
begin
  FTypingOwner := nil;
  PushUndo;
  c := DefaultCondition;
  n := ConditionToNode(c, err);
  BuilderAdd(FRoot, AddTarget, n);
  RebuildRows(n, Showing);
  Changed(False);
end;

procedure TFilterBuilderDialog.AddGroup(AOr: Boolean);
var
  c: TFilterCondition;
  err: string;
  child, g: TFilterNode;
begin
  FTypingOwner := nil;
  PushUndo;
  // Un groupe nait avec une condition: jamais de groupe vide a valider. Un (&) vide vaut vrai partout,
  // ce qui fait beaucoup d'entrees.
  c := DefaultCondition;
  child := ConditionToNode(c, err);
  if AOr then g := FltOr([child]) else g := FltAnd([child]);
  BuilderAdd(FRoot, AddTarget, g);
  RebuildRows(child, Showing);
  Changed(False);
end;

procedure TFilterBuilderDialog.AddFromRow(AIndex: Integer; AAsGroup: Boolean);
var
  i, n: Integer;
  row: TFbRow;
begin
  n := 0;
  for i := 0 to FRows.Count - 1 do
  begin
    row := TFbRow(FRows[i]);
    if row.Kind in [frkAdd, frkEmpty] then
    begin
      if n = AIndex then
      begin
        AddInto(row.FGroup, AAsGroup);
        Exit;
      end;
      Inc(n);
    end;
  end;
end;

procedure TFilterBuilderDialog.ToggleNot;
var
  n, par: TFilterNode;
  idx: Integer;
begin
  n := Selected;
  if n = nil then Exit;
  FTypingOwner := nil;
  PushUndo;
  par := FindParent(FRoot, n, idx);
  if not FCurrent.Negated and (n.Kind <> fkNot) and (par <> nil) and (par.Kind = fkNot) then n := par;
  n := BuilderToggleNot(FRoot, n);
  RebuildRows(n, Showing);
  Changed(False);
end;

procedure TFilterBuilderDialog.ToggleAndOr;
var
  n, up: TFilterNode;
  idx: Integer;
begin
  n := Selected;
  if n = nil then Exit;
  if FCurrent.Kind = frkGroup then n := FCurrent.Inner;
  if not (n.Kind in [fkAnd, fkOr]) then
  begin
    up := FindParent(FRoot, n, idx);
    while (up <> nil) and not (up.Kind in [fkAnd, fkOr]) do
      up := FindParent(FRoot, up, idx);
    if up = nil then Exit;
    n := up;
  end;
  FTypingOwner := nil;
  PushUndo;
  BuilderToggleAndOr(n);
  RebuildRows(n, Showing);
  Changed(False);
end;

procedure TFilterBuilderDialog.WrapSelected(AOr: Boolean);
var
  n: TFilterNode;
begin
  n := Selected;
  if n = nil then Exit;
  FTypingOwner := nil;
  PushUndo;
  BuilderWrap(FRoot, n, AOr);
  RebuildRows(n, Showing);
  Changed(False);
end;

procedure TFilterBuilderDialog.DuplicateSelected;
var
  n, copyNode: TFilterNode;
begin
  n := Selected;
  if n = nil then Exit;
  copyNode := BuilderClone(n);
  if copyNode = nil then Exit;
  FTypingOwner := nil;
  PushUndo;
  BuilderAddAfter(FRoot, n, copyNode);
  RebuildRows(copyNode, Showing);
  Changed(False);
end;

procedure TFilterBuilderDialog.DeleteSelected;
var
  n: TFilterNode;
  idx: Integer;
begin
  n := Selected;
  if n = nil then Exit;
  FTypingOwner := nil;
  PushUndo;
  idx := NodeRowIndex(FCurrent);
  BuilderDelete(FRoot, n);
  RebuildRows(nil, Showing, idx);
  Changed(False);
end;

procedure TFilterBuilderDialog.MoveSelected(ADelta: Integer);
var
  n: TFilterNode;
begin
  n := Selected;
  if (n = nil) or not CanMove(n, ADelta) then Exit;
  FTypingOwner := nil;
  PushUndo;
  BuilderMove(FRoot, n, ADelta);
  RebuildRows(n, Showing);
  Changed(False);
end;

procedure TFilterBuilderDialog.Undo;
var
  s, err: string;
  n: TFilterNode;
  idx: Integer;
begin
  if FUndo.Count = 0 then Exit;
  s := FUndo[FUndo.Count - 1];
  FUndo.Delete(FUndo.Count - 1);
  n := nil;
  if s <> '' then
  begin
    n := FilterParse(s, err);
    if n = nil then Exit;
  end;
  idx := NodeRowIndex(FCurrent);
  ReplaceRoot(n);
  FTypingOwner := nil;
  RebuildRows(nil, Showing, idx);
  Changed(False);
end;

function TFilterBuilderDialog.CanUndo: Boolean;
begin
  Result := FUndo.Count > 0;
end;

procedure TFilterBuilderDialog.SetCondition(const AAttr: string; AOp: TFilterOp; const AValue: string);
var
  row: TFbRow;
begin
  row := FCurrent;
  if (row = nil) or (row.Kind <> frkCondition) then Exit;
  FUpdating := True;
  try
    row.FAttr.Text := AAttr;
    row.FNegated := AOp in [foNotEquals, foAbsent];
    case AOp of
      foNotEquals: AOp := foEquals;
      foAbsent: AOp := foPresent;
    end;
    row.FOp.ItemIndex := OpIndex(AOp);
    row.FValue.Text := AValue;
  finally
    FUpdating := False;
  end;
  row.Restyle;
  RowEdited(row, True);
end;

procedure TFilterBuilderDialog.SetValueText(const AValue: string);
var
  row: TFbRow;
begin
  row := FCurrent;
  if (row = nil) or (row.Kind <> frkCondition) then Exit;
  FUpdating := True;
  try
    row.FValue.Text := AValue;
  finally
    FUpdating := False;
  end;
  RowEdited(row, False);
end;

procedure TFilterBuilderDialog.SetFilterText(const AText: string);
begin
  SetExprText(AText);
  TextChanged(FText);
end;

function TFilterBuilderDialog.ExpressionText: string;
begin
  Result := FText.Text;
end;

function TFilterBuilderDialog.TreeText: string;
var
  i: Integer;
  row: TFbRow;
begin
  Result := '';
  for i := 0 to FRows.Count - 1 do
  begin
    row := TFbRow(FRows[i]);
    if row.IsNodeRow and row.Negated and (row.Kind = frkGroup) then
      Result := Result + StringOfChar(' ', 2 * row.Depth) + 'NOT ' + FilterNodeCaption(row.Inner) + LineEnding
    else if row.IsNodeRow then
      Result := Result + StringOfChar(' ', 2 * row.Depth) + FilterNodeCaption(row.Node) + LineEnding;
  end;
end;

function TFilterBuilderDialog.AddRowsText: string;
var
  i: Integer;
  row: TFbRow;
begin
  Result := '';
  for i := 0 to FRows.Count - 1 do
  begin
    row := TFbRow(FRows[i]);
    if row.Kind = frkAdd then
      Result := Result + StringOfChar(' ', 2 * row.Depth) + row.FAddCond.Text + ' | ' +
        row.FAddGroup.Text + LineEnding
    else if row.Kind = frkEmpty then
      Result := Result + row.FAddCond.Text + LineEnding;
  end;
end;

function TFilterBuilderDialog.SuggestionsText: string;
begin
  Result := FSuggest.Items.CommaText;
end;

function TFilterBuilderDialog.WordsText: string;
begin
  Result := FWords.Caption;
end;

function TFilterBuilderDialog.StatusText: string;
begin
  Result := FStatus.Caption;
end;

function TFilterBuilderDialog.HelpText: string;
begin
  Result := FHelp.Caption;
end;

function TFilterBuilderDialog.EditorEnabled: Boolean;
begin
  Result := (FCurrent <> nil) and (FCurrent.Kind = frkCondition);
end;

function TFilterBuilderDialog.OkEnabled: Boolean;
begin
  Result := FOk.Enabled;
end;

function TFilterBuilderDialog.CurrentNegated: Boolean;
begin
  Result := (FCurrent <> nil) and FCurrent.Negated;
end;

end.
