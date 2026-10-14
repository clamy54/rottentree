// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uTemplateBatch;

{$mode objfpc}{$H+}

// Creation en serie depuis un CSV: une ligne, une entree. Une ligne fautive est ecartee et dite,
// elle ne bloque pas les autres. Le fichier est une saisie hostile: il sort d'un tableur, donc
// du pire. Bornes verifiees pendant la lecture, binaire refuse, cellule douteuse = ligne ecartee.
// Il ne remplit que ce que le modele laisse ouvert: une valeur fixe reste fixe.

interface

uses
  SysUtils, Classes, Contnrs, uLdapSchema, uLdapEntry, uConnectionProfile, uSensitive,
  uEntryCreationPlan, uEntryTemplate, uNextId, uAdPasswordRules, uTemplateUnique;

const
  BATCH_MAX_ROWS = 5000;
  BATCH_MAX_BYTES = 16 * 1024 * 1024;
  BATCH_MAX_COLUMNS = 128;
  BATCH_MAX_CELL = 4096;
  BATCH_HEADER_SHOWN = 80;
  // Plafonds du lot entier: 16 Mo de fichier ne donnent pas droit a 5 Go de memoire.
  BATCH_COMPOSE_BUDGET = 32 * 1024 * 1024;
  BATCH_MAX_VALUE_BYTES = 64 * 1024 * 1024;
  // pas de colonne: le modele se debrouille
  BATCH_FROM_TEMPLATE = -1;

type
  TCsvTable = record
    Delimiter: Char;
    Headers: TStringArray;
    Rows: array of TStringArray;
    Lines: array of Integer;
    // cellules non vides au-dela des titres, par ligne: un separateur de trop, des donnees decalees
    Extra: array of Integer;
  end;

  TBatchRowState = (brsReady, brsProblem, brsSending, brsCreated, brsRefused, brsNotSent,
    brsUnknown);

  TBatchRow = class
  public
    Line: Integer;
    Dn: string;
    Problem: string;
    Entry: TLdapEntry;
    State: TBatchRowState;
    Detail: string;
    JoinsDone, JoinsFailed: Integer;
    // inscriptions jamais tentees: arret ou session perdue apres la creation
    JoinsSkipped: Integer;
    // Mots de passe a hacher juste avant l'envoi: en clair le moins longtemps possible.
    PwdAttrs, PwdSchemes: TStringArray;
    PwdPlain: array of RawByteString;
    // tire au sort: a remettre a l'operateur si la ligne est creee
    PwdDrawn: array of Boolean;
    Login: string;
    // numero d'homonyme retenu, ce qu'il a fallu sauter, et l'entree qui porte deja ce nom
    Counter: Integer;
    Skipped: string;
    Lookalike: string;
    procedure WipePasswords;
    destructor Destroy; override;
  end;

  TTemplateBatch = class
  private
    FT: TEntryTemplate;
    FSchema: TSchemaSnapshot;
    FProvider: TProviderKind;
    FSensitive: TSensitivePolicy;
    FParentDn: string;
    FAnalysis: TClassAnalysis;
    FTable: TCsvTable;
    FMapping: TTplIndexes;
    FNumbers: array of TInt64Array;
    FUsed: array of TInt64Array;
    FNumbersKnown, FNumbersFailed: array of Boolean;
    FRows: TObjectList;
    FPolicy: TAdPwdPolicy;
    FUnique: TUniqueScan;
    FUniqueKnown: Boolean;
    FUniqueFailed: string;
    function GetRow(AIndex: Integer): TBatchRow;
    function GetMapping(AField: Integer): Integer;
    procedure SetMapping(AField, AColumn: Integer);
    function IsSecret(AField: Integer): Boolean;
    // mot de passe que le lot pose lui-meme: fixe, compose ou tire
    function Computes(AField: Integer): Boolean;
    function FieldRequired(AField: Integer): Boolean;
  public
    constructor Create(const ATemplate: TEntryTemplate; ASensitive: TSensitivePolicy;
      const AParentDn: string);
    destructor Destroy; override;
    procedure SetTable(const ATable: TCsvTable);
    function Mappable(AField: Integer): Boolean;
    function NumberFields: TTplIndexes;
    function FileNumbers(AField: Integer): TInt64Array;
    procedure SetNumbers(AField: Integer; const APicked, AUsed: TInt64Array);
    // Annuaire muet: aucun numero n'est sur, ni tire ni impose.
    procedure FailNumbers(AField: Integer);
    procedure ForgetNumbers;
    function NumbersPending: Boolean;
    // Numero d'homonyme ou comptes AD a controler: l'annuaire doit etre lu avant.
    function UniqueNeeded(AProvider: TProviderKind; ASchema: TSchemaSnapshot): Boolean;
    // Le lot garde le recensement et le libere.
    procedure SetUnique(AScan: TUniqueScan);
    procedure FailUnique(const AReason: string);
    procedure ForgetUnique;
    function UniquePending: Boolean;
    function LookalikeCount: Integer;
    // Schema passe a chaque appel et oublie en sortant: une relecture libere l'ancien.
    procedure Compute(ASchema: TSchemaSnapshot; AProvider: TProviderKind);
    function Count: Integer;
    function ReadyCount: Integer;
    function CountIn(AState: TBatchRowState): Integer;
    // secrets que le lot ne pose pas
    function SecretNames: string;
    function HashedNames: string;
    property Template: TEntryTemplate read FT;
    // AD: politique du domaine; inconnue, rien n'est juge ici
    property Policy: TAdPwdPolicy read FPolicy write FPolicy;
    property Table: TCsvTable read FTable;
    property Rows[AIndex: Integer]: TBatchRow read GetRow; default;
    property Mapping[AField: Integer]: Integer read GetMapping write SetMapping;
  end;

function ParseCsv(const AText: RawByteString; out ATable: TCsvTable; out AError: string): Boolean;
function CellProblem(const AValue: string): string;

resourcestring
  rsTbNotText = 'this is not a text file (it holds null bytes): export the sheet as CSV';
  rsTbCellControl = 'control character or line break';
  rsTbCellBidi = 'hidden character that reverses or hides text';
  rsTbCellFormula = 'starts like a spreadsheet formula (%s)';
  rsTbCellUtf8 = 'not valid text';
  rsTbBadCell = 'column "%s": %s';
  rsTbColumnN = 'column %d';
  rsTbNumberRange = '%s: %s is outside the range of the template';
  rsTbNumberReserved = '%s: %s is a system or reserved identifier';
  rsTbNumberUsed = '%s: %s is already used in the directory';
  rsTbNumberTwice = '%s: same number as line %d';
  rsTbExtraCells = '%d value(s) more than there are column titles: a separator too many?';
  rsTbTooMuch = 'the batch is too large to compute: split the file, or simplify the template';
  rsTbNumberUnchecked = '%s: the directory could not be searched, so no number is safe';
  rsTbTooLarge = 'the file is larger than %d MB';
  rsTbEmpty = 'the file is empty: a first line with the column titles is expected';
  rsTbNoRows = 'the file has column titles but no line below them';
  rsTbTooManyRows = 'the file has more than %d lines';
  rsTbTooManyColumns = 'the file has more than %d columns';
  rsTbQuote = 'line %d: a quoted value is never closed';
  rsTbCellTooLong = 'line %d: a value is longer than %d bytes';
  rsTbMissing = '%s is missing';
  rsTbSameDn = 'same DN as line %d';
  rsTbNoNumber = '%s: no free number left in the range';
  rsTbNumberPending = '%s: waiting for the directory to say which numbers are free';
  rsTbUniquePending = 'waiting for the directory to say which names are taken';
  rsTbUniqueUnchecked = 'names could not be checked against the directory (%s)';

implementation

uses
  Math, LazUTF8, LConvEncoding, uRtBytes, uLdapDn, uDirectoryService;

procedure TBatchRow.WipePasswords;
var
  i: Integer;
begin
  for i := 0 to High(PwdPlain) do
    WipeString(PwdPlain[i]);
  PwdPlain := nil;
  PwdAttrs := nil;
  PwdSchemes := nil;
  PwdDrawn := nil;
end;

destructor TBatchRow.Destroy;
begin
  WipePasswords;
  Entry.Free;
  inherited Destroy;
end;

{ CSV }

function DetectDelimiter(const AFirstLine: string): Char;
const
  CANDIDATES: array[0..2] of Char = (';', ',', #9);
var
  counts: array[0..2] of Integer;
  i, k, best: Integer;
  quoted: Boolean;
begin
  for k := 0 to 2 do counts[k] := 0;
  quoted := False;
  for i := 1 to Length(AFirstLine) do
  begin
    if AFirstLine[i] = '"' then quoted := not quoted
    else if not quoted then
      for k := 0 to 2 do
        if AFirstLine[i] = CANDIDATES[k] then Inc(counts[k]);
  end;
  best := 0;
  for k := 1 to 2 do
    if counts[k] > counts[best] then best := k;
  Result := CANDIDATES[best];
end;

function CellProblem(const AValue: string): string;
var
  p, pEnd: PChar;
  len, i: Integer;
  cp: Cardinal;
  rest: string;
  c: Char;
  numberLike: Boolean;
begin
  Result := '';
  if AValue = '' then Exit;
  if not IsValidUtf8(AValue) then Exit(rsTbCellUtf8);
  p := PChar(AValue);
  pEnd := p + Length(AValue);
  while p < pEnd do
  begin
    cp := UTF8CodepointToUnicode(p, len);
    if len <= 0 then Exit(rsTbCellUtf8);
    // C0, DEL, C1, separateurs de ligne: rien de cela ne se tape dans un nom.
    if (cp < 32) or (cp = 127) or ((cp >= $80) and (cp <= $9F)) or (cp = $2028) or (cp = $2029) then
      Exit(rsTbCellControl);
    // Un login qui s'affiche autrement qu'il ne s'ecrit, c'est une usurpation prete a servir.
    if ((cp >= $202A) and (cp <= $202E)) or ((cp >= $2066) and (cp <= $2069)) or (cp = $200E) or
       (cp = $200F) or (cp = $200B) or (cp = $2060) or (cp = $FEFF) or (cp = $061C) then
      Exit(rsTbCellBidi);
    Inc(p, len);
  end;
  // Formule de tableur: elle dormirait dans l'annuaire jusqu'au prochain export ouvert par un
  // collegue confiant. Formes pleine chasse comprises.
  rest := TrimLeft(AValue);
  if rest = '' then Exit;
  c := rest[1];
  if (c in ['=', '@', '|', '%']) or (Copy(rest, 1, 3) = #$EF#$BC#$9D) or (Copy(rest, 1, 3) = #$EF#$BC#$A0) or
     (Copy(rest, 1, 3) = #$EF#$BC#$8B) or (Copy(rest, 1, 3) = #$EF#$BC#$8D) then
    Exit(Format(rsTbCellFormula, [Copy(rest, 1, 1)]));
  if c in ['+', '-'] then
  begin
    // +33 1 23 passe; "+cmd|..." non.
    numberLike := Length(rest) > 1;
    for i := 2 to Length(rest) do
      if not (rest[i] in ['0'..'9', ' ', '.', '(', ')', '-', '/']) then numberLike := False;
    if not numberLike then Exit(Format(rsTbCellFormula, [c]));
  end;
end;

function CleanHeader(const AHeader: string; AIndex: Integer): string;
var
  i: Integer;
begin
  Result := AHeader;
  if not IsValidUtf8(Result) or (CellProblem(Result) = rsTbCellBidi) then Result := '';
  for i := 1 to Length(Result) do
    if Result[i] < ' ' then Result[i] := ' ';
  Result := Trim(Result);
  if UTF8Length(Result) > BATCH_HEADER_SHOWN then Result := UTF8Copy(Result, 1, BATCH_HEADER_SHOWN);
  if Result = '' then Result := Format(rsTbColumnN, [AIndex + 1]);
end;

function DecodeText(const ARaw: RawByteString; out AText: string): Boolean;
var
  ws: UnicodeString;
  i, n: Integer;
  w: Word;
begin
  Result := True;
  AText := '';
  n := Length(ARaw);
  // UTF-16: le "texte Unicode" des tableurs.
  if (n >= 2) and (((ARaw[1] = #$FF) and (ARaw[2] = #$FE)) or ((ARaw[1] = #$FE) and (ARaw[2] = #$FF))) then
  begin
    ws := '';
    SetLength(ws, (n - 2) div 2);
    for i := 0 to Length(ws) - 1 do
    begin
      if ARaw[1] = #$FF then w := Ord(ARaw[3 + 2 * i]) or (Ord(ARaw[4 + 2 * i]) shl 8)
      else w := (Ord(ARaw[3 + 2 * i]) shl 8) or Ord(ARaw[4 + 2 * i]);
      ws[i + 1] := WideChar(w);
    end;
    AText := UTF8Encode(ws);
  end
  else
  begin
    AText := ARaw;
    if (n >= 3) and (AText[1] = #$EF) and (AText[2] = #$BB) and (AText[3] = #$BF) then
      Delete(AText, 1, 3);
    // Pas de l'UTF-8 valide: du Windows-1252, cadeau d'un tableur.
    if not IsValidUtf8(AText) then AText := CP1252ToUTF8(AText);
  end;
  // Un octet nul dans un CSV: classeur, image ou archive. On ne devine pas.
  if Pos(#0, AText) > 0 then Result := False;
end;

function ParseCsv(const AText: RawByteString; out ATable: TCsvTable; out AError: string): Boolean;
var
  text, firstLine: string;
  cell: string;
  cellLen: Integer;
  record_: TStringArray;
  recordLen: Integer;
  i, n, line, startLine, k: Integer;
  quoted, wasQuoted, cellBlank, any: Boolean;
  ch: Char;

  procedure Put(C: Char);
  begin
    if cellLen = Length(cell) then SetLength(cell, cellLen * 2 + 64);
    Inc(cellLen);
    cell[cellLen] := C;
    if not (C in [' ', #9]) then cellBlank := False;
  end;

  function EndCell: Boolean;
  var
    v: string;
  begin
    Result := True;
    if recordLen >= BATCH_MAX_COLUMNS then
    begin
      AError := Format(rsTbTooManyColumns, [BATCH_MAX_COLUMNS]);
      Exit(False);
    end;
    v := Copy(cell, 1, cellLen);
    if not wasQuoted then v := Trim(v);
    if recordLen = Length(record_) then SetLength(record_, recordLen * 2 + 8);
    record_[recordLen] := v;
    Inc(recordLen);
    cellLen := 0;
    cellBlank := True;
    wasQuoted := False;
  end;

  function EndRecord: Boolean;
  var
    j, cols, extra: Integer;
    blank: Boolean;
    rec: TStringArray;
  begin
    Result := EndCell;
    if not Result then Exit;
    blank := True;
    for j := 0 to recordLen - 1 do
      if record_[j] <> '' then blank := False;
    if not blank then
    begin
      if Length(ATable.Headers) = 0 then
      begin
        ATable.Headers := Copy(record_, 0, recordLen);
        for j := 0 to High(ATable.Headers) do
          ATable.Headers[j] := CleanHeader(ATable.Headers[j], j);
      end
      else
      begin
        if Length(ATable.Rows) >= BATCH_MAX_ROWS then
        begin
          AError := Format(rsTbTooManyRows, [BATCH_MAX_ROWS]);
          Exit(False);
        end;
        cols := Length(ATable.Headers);
        // Trop longue: une virgule de trop a decale les donnees. On ne cree pas un compte avec le
        // prenom du voisin.
        extra := 0;
        for j := cols to recordLen - 1 do
          if record_[j] <> '' then Inc(extra);
        rec := Copy(record_, 0, recordLen);
        SetLength(rec, cols);
        SetLength(ATable.Rows, Length(ATable.Rows) + 1);
        ATable.Rows[High(ATable.Rows)] := rec;
        SetLength(ATable.Lines, Length(ATable.Rows));
        ATable.Lines[High(ATable.Lines)] := startLine;
        SetLength(ATable.Extra, Length(ATable.Rows));
        ATable.Extra[High(ATable.Extra)] := extra;
      end;
    end;
    recordLen := 0;
    any := False;
  end;

begin
  Result := False;
  ATable := Default(TCsvTable);
  AError := '';
  if Length(AText) > BATCH_MAX_BYTES then
  begin
    AError := Format(rsTbTooLarge, [BATCH_MAX_BYTES div (1024 * 1024)]);
    Exit;
  end;
  if not DecodeText(AText, text) then
  begin
    AError := rsTbNotText;
    Exit;
  end;
  n := Length(text);
  k := 1;
  while (k <= n) and (text[k] in [#10, #13, ' ', #9]) do Inc(k);
  i := k;
  while (i <= n) and not (text[i] in [#10, #13]) and (i - k < 64 * 1024) do Inc(i);
  firstLine := Copy(text, k, i - k);
  ATable.Delimiter := DetectDelimiter(firstLine);
  record_ := nil;
  recordLen := 0;
  cell := '';
  cellLen := 0;
  cellBlank := True;
  quoted := False;
  wasQuoted := False;
  any := False;
  line := 1;
  startLine := 1;
  i := 1;
  while i <= n do
  begin
    ch := text[i];
    if quoted then
    begin
      if ch = '"' then
      begin
        if (i < n) and (text[i + 1] = '"') then
        begin
          Put('"');
          Inc(i);
        end
        else
          quoted := False;
      end
      else
      begin
        if ch = #10 then Inc(line);
        Put(ch);
      end;
    end
    else if (ch = '"') and cellBlank and not wasQuoted then
    begin
      quoted := True;
      wasQuoted := True;
      cellLen := 0;
      any := True;
    end
    else if ch = ATable.Delimiter then
    begin
      if not EndCell then Exit;
      any := True;
    end
    else if ch in [#10, #13] then
    begin
      if (ch = #13) and (i < n) and (text[i + 1] = #10) then Inc(i);
      if not EndRecord then Exit;
      Inc(line);
      startLine := line;
    end
    else
    begin
      Put(ch);
      any := True;
    end;
    if cellLen > BATCH_MAX_CELL then
    begin
      AError := Format(rsTbCellTooLong, [line, BATCH_MAX_CELL]);
      Exit;
    end;
    Inc(i);
  end;
  if quoted then
  begin
    AError := Format(rsTbQuote, [startLine]);
    Exit;
  end;
  if any or (cellLen > 0) or (recordLen > 0) then
    if not EndRecord then Exit;
  if Length(ATable.Headers) = 0 then
  begin
    AError := rsTbEmpty;
    Exit;
  end;
  if Length(ATable.Rows) = 0 then
  begin
    AError := rsTbNoRows;
    Exit;
  end;
  Result := True;
end;

{ Correspondance des colonnes }

function Fold(const S: string): string;
begin
  Result := LowerCase(PlainAscii(S));
  Result := StringReplace(Result, '-', '', [rfReplaceAll]);
  Result := StringReplace(Result, '_', '', [rfReplaceAll]);
  Result := StringReplace(Result, '.', '', [rfReplaceAll]);
end;

function AliasesOf(const AAttr: string): TStringArray;
var
  a: string;
begin
  a := AsciiLowerCase(AttrBaseName(AAttr));
  if a = 'givenname' then Result := ['firstname', 'prenom', 'first', 'forename']
  else if a = 'sn' then Result := ['lastname', 'surname', 'nom', 'last', 'familyname', 'nomdefamille']
  else if a = 'mail' then Result := ['email', 'courriel', 'emailaddress', 'adressemail']
  else if (a = 'uid') or (a = 'samaccountname') then Result := ['login', 'username', 'user', 'identifiant']
  else if a = 'telephonenumber' then Result := ['phone', 'telephone', 'tel']
  else if a = 'mobile' then Result := ['mobilephone', 'portable', 'cell']
  else if a = 'title' then Result := ['jobtitle', 'fonction', 'poste']
  else if a = 'cn' then Result := ['name', 'fullname', 'nomcomplet', 'commonname']
  else if a = 'ou' then Result := ['name', 'unit', 'department', 'service']
  else if a = 'employeenumber' then Result := ['employeeid', 'matricule']
  else Result := nil;
end;

{ TTemplateBatch }

constructor TTemplateBatch.Create(const ATemplate: TEntryTemplate; ASensitive: TSensitivePolicy;
  const AParentDn: string);
var
  i: Integer;
begin
  inherited Create;
  FT := CloneTemplate(ATemplate);
  FSensitive := ASensitive;
  FParentDn := AParentDn;
  FRows := TObjectList.Create(True);
  SetLength(FMapping, Length(FT.Fields));
  SetLength(FNumbers, Length(FT.Fields));
  SetLength(FUsed, Length(FT.Fields));
  SetLength(FNumbersKnown, Length(FT.Fields));
  SetLength(FNumbersFailed, Length(FT.Fields));
  for i := 0 to High(FMapping) do FMapping[i] := BATCH_FROM_TEMPLATE;
end;

destructor TTemplateBatch.Destroy;
begin
  FUnique.Free;
  FRows.Free;
  inherited Destroy;
end;

function TTemplateBatch.GetRow(AIndex: Integer): TBatchRow;
begin
  Result := TBatchRow(FRows[AIndex]);
end;

function TTemplateBatch.Count: Integer;
begin
  Result := FRows.Count;
end;

function TTemplateBatch.CountIn(AState: TBatchRowState): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FRows.Count - 1 do
    if TBatchRow(FRows[i]).State = AState then Inc(Result);
end;

function TTemplateBatch.ReadyCount: Integer;
begin
  Result := CountIn(brsReady);
end;

function TTemplateBatch.GetMapping(AField: Integer): Integer;
begin
  if (AField < 0) or (AField > High(FMapping)) then Exit(BATCH_FROM_TEMPLATE);
  Result := FMapping[AField];
end;

function TTemplateBatch.Mappable(AField: Integer): Boolean;
begin
  Result := (AField >= 0) and (AField <= High(FT.Fields)) and not IsSecret(AField) and
    (FT.Fields[AField].Source <> tsFixed);
end;

procedure TTemplateBatch.SetMapping(AField, AColumn: Integer);
begin
  if (AField < 0) or (AField > High(FMapping)) then Exit;
  if (AColumn < 0) or (AColumn > High(FTable.Headers)) or not Mappable(AField) then
    AColumn := BATCH_FROM_TEMPLATE;
  FMapping[AField] := AColumn;
end;

function TTemplateBatch.IsSecret(AField: Integer): Boolean;
begin
  Result := (FSensitive <> nil) and FSensitive.IsSensitive(FT.Fields[AField].Attr);
end;

function TTemplateBatch.FieldRequired(AField: Integer): Boolean;
begin
  Result := (SameAttr(FT.Fields[AField].Attr, FT.RdnAttr) and (FieldIndex(FT, FT.RdnAttr) = AField)) or
    ((FieldIndex(FT, FT.Fields[AField].Attr) = AField) and
      IsRequiredAttr(FAnalysis, FSchema, FT.Fields[AField].Attr)) or
    ((FT.Fields[AField].Source = tsAsk) and
      (not FT.Fields[AField].Optional or (ComposedFrom(FT, AField) <> '')));
end;

function TTemplateBatch.Computes(AField: Integer): Boolean;
begin
  Result := IsSecret(AField) and (FT.Fields[AField].Source in [tsFixed, tsCompose, tsRandom]);
end;

function TTemplateBatch.HashedNames: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FT.Fields) do
    if Computes(i) then
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + FT.Fields[i].Attr + ' (' + FT.Fields[i].Scheme + ')';
    end;
end;

function TTemplateBatch.SecretNames: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FT.Fields) do
    if IsSecret(i) and not Computes(i) then
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + FT.Fields[i].Attr;
    end;
end;

procedure TTemplateBatch.SetTable(const ATable: TCsvTable);
var
  i, c, k: Integer;
  folded, aliases: TStringArray;
  used: array of Boolean;
  key: string;

  function Find(const AKey: string): Integer;
  var
    j: Integer;
  begin
    for j := 0 to High(folded) do
      if not used[j] and (folded[j] = AKey) and (AKey <> '') then Exit(j);
    Result := -1;
  end;

begin
  FTable := ATable;
  ForgetNumbers;
  folded := nil;
  used := nil;
  SetLength(folded, Length(FTable.Headers));
  SetLength(used, Length(FTable.Headers));
  for i := 0 to High(folded) do folded[i] := Fold(FTable.Headers[i]);
  for i := 0 to High(FMapping) do FMapping[i] := BATCH_FROM_TEMPLATE;
  // Seul ce que le modele demande est relie d'office: une colonne "gidNumber" ne remplace rien.
  for i := 0 to High(FT.Fields) do
  begin
    if not Mappable(i) or (FT.Fields[i].Source <> tsAsk) or
       (FieldIndex(FT, FT.Fields[i].Attr) <> i) then Continue;
    c := Find(Fold(AttrBaseName(FT.Fields[i].Attr)));
    if c >= 0 then
    begin
      FMapping[i] := c;
      used[c] := True;
    end;
  end;
  for i := 0 to High(FT.Fields) do
  begin
    if (FMapping[i] >= 0) or not Mappable(i) or (FT.Fields[i].Source <> tsAsk) then Continue;
    c := Find(Fold(FieldPrompt(FT.Fields[i])));
    if c < 0 then
    begin
      aliases := AliasesOf(FT.Fields[i].Attr);
      for k := 0 to High(aliases) do
      begin
        key := aliases[k];
        c := Find(key);
        if c >= 0 then Break;
      end;
    end;
    if c >= 0 then
    begin
      FMapping[i] := c;
      used[c] := True;
    end;
  end;
  FRows.Clear;
end;

function TTemplateBatch.NumberFields: TTplIndexes;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to High(FT.Fields) do
    if FT.Fields[i].Source = tsNumber then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := i;
    end;
end;

function TTemplateBatch.FileNumbers(AField: Integer): TInt64Array;
var
  r, col, n: Integer;
  v: Int64;
begin
  Result := nil;
  if (AField < 0) or (AField > High(FMapping)) then Exit;
  col := FMapping[AField];
  if col < 0 then Exit;
  SetLength(Result, Length(FTable.Rows));
  n := 0;
  for r := 0 to High(FTable.Rows) do
    if (col <= High(FTable.Rows[r])) and TryStrToInt64(Trim(FTable.Rows[r][col]), v) then
    begin
      Result[n] := v;
      Inc(n);
    end;
  SetLength(Result, n);
end;

procedure TTemplateBatch.SetNumbers(AField: Integer; const APicked, AUsed: TInt64Array);
begin
  if (AField < 0) or (AField > High(FNumbers)) then Exit;
  FNumbers[AField] := Copy(APicked, 0, Length(APicked));
  FUsed[AField] := Copy(AUsed, 0, Length(AUsed));
  FNumbersKnown[AField] := True;
  FNumbersFailed[AField] := False;
end;

procedure TTemplateBatch.FailNumbers(AField: Integer);
begin
  if (AField < 0) or (AField > High(FNumbers)) then Exit;
  FNumbers[AField] := nil;
  FUsed[AField] := nil;
  FNumbersKnown[AField] := True;
  FNumbersFailed[AField] := True;
end;

procedure TTemplateBatch.ForgetNumbers;
var
  i: Integer;
begin
  for i := 0 to High(FNumbers) do
  begin
    FNumbers[i] := nil;
    FUsed[i] := nil;
    FNumbersKnown[i] := False;
    FNumbersFailed[i] := False;
  end;
end;

function TTemplateBatch.NumbersPending: Boolean;
var
  fields: TTplIndexes;
  i: Integer;
begin
  fields := NumberFields;
  for i := 0 to High(fields) do
    if not FNumbersKnown[fields[i]] then Exit(True);
  Result := False;
end;

function TTemplateBatch.UniqueNeeded(AProvider: TProviderKind; ASchema: TSchemaSnapshot): Boolean;
var
  probe: TUniqueScan;
begin
  probe := TUniqueScan.Create(FT, AProvider, ASchema);
  try
    Result := probe.Needed;
  finally
    probe.Free;
  end;
end;

procedure TTemplateBatch.SetUnique(AScan: TUniqueScan);
begin
  if AScan <> FUnique then FUnique.Free;
  FUnique := AScan;
  FUniqueKnown := True;
  FUniqueFailed := '';
end;

procedure TTemplateBatch.FailUnique(const AReason: string);
begin
  FreeAndNil(FUnique);
  FUniqueKnown := True;
  FUniqueFailed := AReason;
  if FUniqueFailed = '' then FUniqueFailed := '?';
end;

procedure TTemplateBatch.ForgetUnique;
begin
  FreeAndNil(FUnique);
  FUniqueKnown := False;
  FUniqueFailed := '';
end;

function TTemplateBatch.UniquePending: Boolean;
begin
  Result := not FUniqueKnown;
end;

function TTemplateBatch.LookalikeCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to Count - 1 do
    if (Rows[i].State = brsReady) and (Rows[i].Lookalike <> '') then Inc(Result);
end;

procedure TTemplateBatch.Compute(ASchema: TSchemaSnapshot; AProvider: TProviderKind);
var
  r, i, col, other, k: Integer;
  later: TStringArray;
  row: TBatchRow;
  manual: array of Boolean;
  taken: array of Integer;
  seen, seenNumbers: TStringList;
  cellText, key, bad, blocked: string;
  values: TStringArray;
  rules: TDnCaseRules;
  composeLeft, rowBudget, kept: Int64;
  checkUnique: Boolean;
  uq: TUniqueResult;

  function FieldValue(const AAttr: string): string;
  var
    q: Integer;
  begin
    q := FieldIndex(FT, AAttr);
    if (q >= 0) and (q <= High(values)) then Result := values[q] else Result := '';
  end;

  function NumberProblem(AField: Integer; const AText: string; ALine: Integer): string;
  var
    v: Int64;
    f: TTplField;
    lo, hi, mid, at: Integer;
    nk: string;
  begin
    Result := '';
    f := FT.Fields[AField];
    if not TryStrToInt64(Trim(AText), v) then Exit;
    if (f.HasMin and (v < f.Min)) or (f.HasMax and (v > f.Max)) then
      Exit(Format(rsTbNumberRange, [f.Attr, AText]));
    // uidNumber 0 dans une colonne, c'est root par tableur interpose.
    if IsNextIdAttribute(f.Attr, FProvider, FSchema) and
       (IsReservedId(v) or (not f.HasMin and (v < NEXT_ID_FIRST))) then
      Exit(Format(rsTbNumberReserved, [f.Attr, AText]));
    lo := 0;
    hi := High(FUsed[AField]);
    while lo <= hi do
    begin
      mid := lo + (hi - lo) div 2;
      if FUsed[AField][mid] = v then Exit(Format(rsTbNumberUsed, [f.Attr, AText]));
      if FUsed[AField][mid] < v then lo := mid + 1 else hi := mid - 1;
    end;
    nk := IntToStr(AField) + ':' + IntToStr(v);
    at := seenNumbers.IndexOf(nk);
    if at >= 0 then Exit(Format(rsTbNumberTwice, [f.Attr, PtrInt(seenNumbers.Objects[at])]));
    seenNumbers.AddObject(nk, TObject(PtrInt(ALine)));
  end;

begin
  FRows.Clear;
  FSchema := ASchema;
  FProvider := AProvider;
  if ASchema = nil then blocked := rsCpNoSchema
  else blocked := FirstTemplateError(CheckTemplate(FT, ASchema, AProvider, FSensitive, FAnalysis));
  taken := nil;
  SetLength(taken, Length(FT.Fields));
  composeLeft := BATCH_COMPOSE_BUDGET;
  kept := 0;
  rules := TDnCaseRules.CreateFor(ASchema, AProvider);
  checkUnique := UniqueNeeded(AProvider, ASchema);
  if FUnique <> nil then FUnique.ClearReserved;
  seen := TStringList.Create;
  seenNumbers := TStringList.Create;
  try
    seen.Sorted := True;
    seen.CaseSensitive := True;
    seenNumbers.Sorted := True;
    for r := 0 to High(FTable.Rows) do
    begin
      row := TBatchRow.Create;
      FRows.Add(row);
      row.Line := FTable.Lines[r];
      if blocked <> '' then
      begin
        row.Problem := blocked;
        row.State := brsProblem;
        Continue;
      end;
      if (composeLeft <= 0) or (kept > BATCH_MAX_VALUE_BYTES) then
      begin
        row.Problem := rsTbTooMuch;
        row.State := brsProblem;
        Continue;
      end;
      if (r <= High(FTable.Extra)) and (FTable.Extra[r] > 0) then
      begin
        row.Problem := Format(rsTbExtraCells, [FTable.Extra[r]]);
        row.State := brsProblem;
        Continue;
      end;
      values := nil;
      SetLength(values, Length(FT.Fields));
      manual := nil;
      SetLength(manual, Length(FT.Fields));
      for i := 0 to High(FT.Fields) do
      begin
        if IsSecret(i) then
        begin
          // Jamais tire d'une cellule: un mot de passe ne voyage pas dans un tableur.
          if Computes(i) and (FT.Fields[i].Source = tsFixed) then values[i] := FT.Fields[i].Value;
          Continue;
        end;
        col := FMapping[i];
        cellText := '';
        if (col >= 0) and (col <= High(FTable.Rows[r])) then cellText := FTable.Rows[r][col];
        if cellText <> '' then
        begin
          // Cellule douteuse: ligne ecartee. On ne nettoie pas une valeur a la place de son auteur.
          bad := CellProblem(cellText);
          if (bad <> '') and (row.Problem = '') then
            row.Problem := Format(rsTbBadCell, [FTable.Headers[col], bad]);
          if (bad = '') and (FT.Fields[i].Source = tsNumber) and (row.Problem = '') then
          begin
            if not FNumbersKnown[i] then
              row.Problem := Format(rsTbNumberPending, [FT.Fields[i].Attr])
            else if FNumbersFailed[i] then
              row.Problem := Format(rsTbNumberUnchecked, [FT.Fields[i].Attr])
            else
              row.Problem := NumberProblem(i, cellText, row.Line);
          end;
          values[i] := cellText;
          manual[i] := True;
          Continue;
        end;
        // Un numero vient de l'annuaire ou d'une cellule controlee, jamais du modele.
        if FT.Fields[i].Source in [tsFixed, tsAsk] then
          values[i] := FT.Fields[i].Value;
      end;
      // Avant de depenser un numero pour une ligne qui n'ira nulle part.
      for i := 0 to High(FT.Fields) do
        if (row.Problem = '') and (FT.Fields[i].Source = tsAsk) and not IsSecret(i) and
           (values[i] = '') and FieldRequired(i) then
        begin
          row.Problem := Format(rsTbMissing, [FieldPrompt(FT.Fields[i])]);
          Break;
        end;
      if row.Problem = '' then
        for i := 0 to High(FT.Fields) do
        begin
          if (FT.Fields[i].Source <> tsNumber) or (values[i] <> '') then Continue;
          if not FNumbersKnown[i] then
            row.Problem := Format(rsTbNumberPending, [FT.Fields[i].Attr])
          else if FNumbersFailed[i] then
            row.Problem := Format(rsTbNumberUnchecked, [FT.Fields[i].Attr])
          else if taken[i] > High(FNumbers[i]) then
            row.Problem := Format(rsTbNoNumber, [FT.Fields[i].Attr])
          else
          begin
            values[i] := IntToStr(FNumbers[i][taken[i]]);
            Inc(taken[i]);
          end;
        end;
      if (row.Problem = '') and checkUnique then
      begin
        if not FUniqueKnown then row.Problem := rsTbUniquePending
        else if FUniqueFailed <> '' then row.Problem := Format(rsTbUniqueUnchecked, [FUniqueFailed]);
      end;
      rowBudget := composeLeft;
      if rowBudget > TEMPLATE_COMPOSE_BUDGET then rowBudget := TEMPLATE_COMPOSE_BUDGET;
      composeLeft := composeLeft - rowBudget;
      if checkUnique and (row.Problem = '') and (FUnique <> nil) then
      begin
        uq := FUnique.Resolve(FT, values, manual, rowBudget);
        row.Counter := uq.Counter;
        row.Skipped := uq.Skipped;
        row.Lookalike := uq.Lookalike;
        if uq.Problem <> '' then row.Problem := uq.Problem;
      end
      else
        ComposeValuesWithin(FT, values, manual, rowBudget);
      // Tire apres les compositions: AD refuse un mot de passe qui contient le compte ou le nom.
      for i := 0 to High(FT.Fields) do
        if Computes(i) and (FT.Fields[i].Source = tsRandom) then
        begin
          if FProvider = pkActiveDirectory then
            values[i] := RandomAdPassword(FT.Fields[i].RandomLength, FPolicy, FieldValue('sAMAccountName'),
              FieldValue('displayName'))
          else
            values[i] := RandomPassword(Max(FT.Fields[i].RandomLength, FPolicy.MinLength));
        end;
      if rowBudget > 0 then composeLeft := composeLeft + rowBudget;
      if row.Problem = '' then
        for i := 0 to High(FT.Fields) do
          if (not IsSecret(i) or Computes(i)) and (values[i] = '') and FieldRequired(i) then
          begin
            row.Problem := Format(rsTbMissing, [FieldPrompt(FT.Fields[i])]);
            Break;
          end;
      later := nil;
      for i := 0 to High(FT.Fields) do
        if Computes(i) and (values[i] <> '') then
        begin
          SetLength(later, Length(later) + 1);
          later[High(later)] := FT.Fields[i].Attr;
        end;
      if row.Problem = '' then
        row.Entry := BuildTemplateEntry(FT, values, FParentDn, FSchema, FProvider, FSensitive,
          FAnalysis, row.Problem, later);
      if row.Entry <> nil then
      begin
        row.Dn := row.Entry.Dn;
        Inc(kept, row.Entry.TotalBytes);
        // Casse selon le schema: deux valeurs d'un attribut caseExact restent deux entrees.
        key := DnFoldKey(row.Dn, @rules.Folds, @rules.Canon);
        other := seen.IndexOf(key);
        if other >= 0 then
        begin
          row.Problem := Format(rsTbSameDn, [PtrInt(seen.Objects[other])]);
          FreeAndNil(row.Entry);
        end
        else
          seen.AddObject(key, TObject(PtrInt(row.Line)));
      end;
      if row.Entry <> nil then
        for i := 0 to High(FT.Fields) do
        begin
          if not Computes(i) or (values[i] = '') then Continue;
          if Length(values[i]) > TEMPLATE_TEXT_MAX then
          begin
            row.Problem := Format(rsTplValue, [FT.Fields[i].Attr, Format(rsTplValueTooLong, [TEMPLATE_TEXT_MAX])]);
            row.WipePasswords;
            FreeAndNil(row.Entry);
            Break;
          end;
          if (FProvider = pkActiveDirectory) and (FT.Fields[i].Source <> tsRandom) then
          begin
            bad := AdPasswordProblem(values[i], FPolicy, FieldValue('sAMAccountName'),
              FieldValue('displayName'));
            if bad <> '' then
            begin
              row.Problem := Format(rsTplValue, [FT.Fields[i].Attr, bad]);
              row.WipePasswords;
              FreeAndNil(row.Entry);
              Break;
            end;
          end;
          k := Length(row.PwdPlain);
          SetLength(row.PwdPlain, k + 1);
          SetLength(row.PwdAttrs, k + 1);
          SetLength(row.PwdSchemes, k + 1);
          SetLength(row.PwdDrawn, k + 1);
          row.PwdPlain[k] := values[i];
          row.PwdAttrs[k] := FT.Fields[i].Attr;
          row.PwdSchemes[k] := FT.Fields[i].Scheme;
          row.PwdDrawn[k] := FT.Fields[i].Source = tsRandom;
          Inc(kept, Length(values[i]));
        end;
      // Retenue meme si elle echoue plus loin a l'envoi: au pire un numero saute, jamais un doublon.
      if (row.Entry <> nil) and checkUnique and (FUnique <> nil) then
        FUnique.Reserve(FT, values, Format(rsUqBatchLine, [row.Line]));
      if row.Entry <> nil then
      begin
        row.Login := FieldValue('sAMAccountName');
        if row.Login = '' then row.Login := FieldValue('uid');
        if row.Login = '' then row.Login := FieldValue(FT.RdnAttr);
      end;
      if row.Entry <> nil then row.State := brsReady else row.State := brsProblem;
    end;
  finally
    seenNumbers.Free;
    seen.Free;
    rules.Free;
    // Rien ne survit a l'appel: le schema peut mourir a la prochaine relecture.
    FSchema := nil;
  end;
end;

end.
