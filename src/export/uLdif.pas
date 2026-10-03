// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdif;

{$mode objfpc}{$H+}

// LDIF RFC 2849, fidele aux octets. Les references externes ":<" sont refusees par
// defaut et aucune URL reseau n'est jamais suivie. Les erreurs donnent ligne et
// colonne, jamais la valeur: un message d'erreur n'a pas a recracher un mot de passe.

interface

uses
  SysUtils, Classes, Contnrs, uLdapEntry, uChangeSet;

const
  LDIF_MAX_VALUE_BYTES = 16 * 1024 * 1024;
  // Cumul des fichiers references lus par une meme analyse: un LDIF de trois lignes qui
  // cite mille fois le meme gros fichier ne doit pas epuiser la memoire.
  LDIF_MAX_EXTERNAL_TOTAL_BYTES = 128 * 1024 * 1024;
  LDIF_MAX_ERRORS = 500;
  LDIF_DEFAULT_MAX_RECORDS = 10000000;
  LDIF_FOLD_WIDTH = 76;

type
  TLdifExternalPolicy = record
    AllowLocalFiles: Boolean;
    AllowedRoots: array of string;
    MaxFileBytes: Int64;
    MaxTotalBytes: Int64;
  end;

  TLdifParseOptions = record
    External: TLdifExternalPolicy;
    MaxValueBytes: Int64;
    MaxRecords: Integer;
    AllowRawUtf8: Boolean;
  end;

  TLdifIssue = record
    Line: Integer;
    Column: Integer;
    Message: string;
    Fatal: Boolean;
  end;

  TLdifKind = (lkUnknown, lkContent, lkChanges);

  TLdifDocument = class
  private
    FRecords: TObjectList;
    FIssues: array of TLdifIssue;
    function GetRecord(AIndex: Integer): TLdapChange;
  public
    Version: Integer;
    Kind: TLdifKind;
    constructor Create;
    destructor Destroy; override;
    procedure AddIssue(ALine, ACol: Integer; const AMsg: string; AFatal: Boolean);
    function RecordCount: Integer;
    function IssueCount: Integer;
    function Issue(AIndex: Integer): TLdifIssue;
    function HasFatalIssues: Boolean;
    function AddRecord(AChange: TLdapChange): TLdapChange;
    property Records[AIndex: Integer]: TLdapChange read GetRecord; default;
  end;

  TLdifWriter = class
  private
    FOut: TStream;
    FFoldWidth: Integer;
    FEol: RawByteString;
    procedure WriteRaw(const S: RawByteString);
    procedure WriteFolded(const S: RawByteString);
  public
    constructor Create(AOut: TStream; AFoldWidth: Integer = LDIF_FOLD_WIDTH);
    procedure WriteVersion;
    procedure WriteComment(const AText: string);
    procedure WriteSeparator;
    procedure WriteAttrValue(const AAttr: string; const AValue: RawByteString);
    procedure WriteEntry(AEntry: TLdapEntry);
    procedure WriteChange(AChange: TLdapChange);
    property Eol: RawByteString read FEol write FEol;
  end;

function DefaultLdifParseOptions: TLdifParseOptions;
function LdifParse(const AText: RawByteString; const AOptions: TLdifParseOptions): TLdifDocument;

function LdifIsSafeString(const AValue: RawByteString): Boolean;
function LdifEntryToString(AEntry: TLdapEntry): RawByteString;
function LdifChangeToString(AChange: TLdapChange): RawByteString;

implementation

uses
  uRtBytes, uLdapDn, uLdapFilter, uSafeSave;

type
  TLogicalLine = record
    Text: RawByteString;
    Line: Integer;
  end;
  TLogicalLines = array of TLogicalLine;

  ELdifRecordError = class(Exception)
  public
    Line, Column: Integer;
    constructor CreateAt(ALine, ACol: Integer; const AMsg: string);
  end;

constructor ELdifRecordError.CreateAt(ALine, ACol: Integer; const AMsg: string);
begin
  inherited Create(AMsg);
  Line := ALine;
  Column := ACol;
end;

function DefaultLdifParseOptions: TLdifParseOptions;
begin
  Result.External.AllowLocalFiles := False;
  Result.External.AllowedRoots := nil;
  Result.External.MaxFileBytes := LDIF_MAX_VALUE_BYTES;
  Result.External.MaxTotalBytes := LDIF_MAX_EXTERNAL_TOTAL_BYTES;
  Result.MaxValueBytes := LDIF_MAX_VALUE_BYTES;
  Result.MaxRecords := LDIF_DEFAULT_MAX_RECORDS;
  Result.AllowRawUtf8 := True;
end;

constructor TLdifDocument.Create;
begin
  inherited Create;
  FRecords := TObjectList.Create(True);
end;

destructor TLdifDocument.Destroy;
begin
  FRecords.Free;
  inherited Destroy;
end;

procedure TLdifDocument.AddIssue(ALine, ACol: Integer; const AMsg: string; AFatal: Boolean);
begin
  if Length(FIssues) >= LDIF_MAX_ERRORS then Exit;
  SetLength(FIssues, Length(FIssues) + 1);
  FIssues[High(FIssues)].Line := ALine;
  FIssues[High(FIssues)].Column := ACol;
  FIssues[High(FIssues)].Message := AMsg;
  FIssues[High(FIssues)].Fatal := AFatal;
end;

function TLdifDocument.RecordCount: Integer;
begin
  Result := FRecords.Count;
end;

function TLdifDocument.IssueCount: Integer;
begin
  Result := Length(FIssues);
end;

function TLdifDocument.Issue(AIndex: Integer): TLdifIssue;
begin
  Result := FIssues[AIndex];
end;

function TLdifDocument.HasFatalIssues: Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FIssues) do
    if FIssues[i].Fatal then Exit(True);
  Result := False;
end;

function TLdifDocument.AddRecord(AChange: TLdapChange): TLdapChange;
begin
  FRecords.Add(AChange);
  Result := AChange;
end;

function TLdifDocument.GetRecord(AIndex: Integer): TLdapChange;
begin
  Result := TLdapChange(FRecords[AIndex]);
end;

function IsWindowsDrivePath(const P: string): Boolean;
begin
  Result := (Length(P) >= 3) and (P[1] in ['A'..'Z', 'a'..'z']) and (P[2] = ':') and
    (P[3] in ['/', '\']);
end;

function UnderRoot(const APhysical, ARootPhysical: string): Boolean;
var
  root: string;
begin
  if (APhysical = '') or (ARootPhysical = '') then Exit(False);
  root := IncludeTrailingPathDelimiter(ARootPhysical);
  {$IFDEF WINDOWS}
  Result := SameText(Copy(APhysical, 1, Length(root)), root);
  {$ELSE}
  Result := Copy(APhysical, 1, Length(root)) = root;
  {$ENDIF}
end;

// file:/// uniquement, sous une racine autorisee. C'est le fichier effectivement ouvert
// qui est verifie (chemin physique, liens et jonctions resolus, fichier ordinaire): un
// controle du chemin avant l'ouverture perd la course contre un lien echange
// entre-temps.
procedure LoadExternal(const AUrl: string; const APolicy: TLdifExternalPolicy;
  ALine: Integer; var AUsed: Int64; out AValue: RawByteString);
var
  path, full, root, phys, rootPhys: string;
  i: Integer;
  inside, notReg: Boolean;
  fs: THandleStream;
  budget: Int64;
  attrs: LongInt;
  dev1, ino1, dev2, ino2: Int64;
begin
  AValue := '';
  if not APolicy.AllowLocalFiles then
    raise ELdifRecordError.CreateAt(ALine, 1,
      'external value references (":<") are disabled');
  if not SameText(Copy(AUrl, 1, 8), 'file:///') then
    raise ELdifRecordError.CreateAt(ALine, 1,
      'only local file:/// references can be allowed; network and relative URLs are refused');
  path := Copy(AUrl, 8, MaxInt);
  if Pos('%', path) > 0 then
    raise ELdifRecordError.CreateAt(ALine, 1, 'percent-encoded file references are refused');
  {$IFDEF WINDOWS}
  if (Length(path) >= 2) and IsWindowsDrivePath(Copy(path, 2, MaxInt)) then
    path := StringReplace(Copy(path, 2, MaxInt), '/', '\', [rfReplaceAll])
  else
    raise ELdifRecordError.CreateAt(ALine, 1, 'file reference must name a local drive path');
  {$ENDIF}
  if (Pos('..', path) > 0) or (Pos('\\', path) = 1) or (Pos('//', path) = 1) then
    raise ELdifRecordError.CreateAt(ALine, 1, 'relative or UNC file references are refused');
  full := ExpandFileName(path);
  inside := False;
  for i := 0 to High(APolicy.AllowedRoots) do
  begin
    root := IncludeTrailingPathDelimiter(ExpandFileName(APolicy.AllowedRoots[i]));
    {$IFDEF WINDOWS}
    if SameText(Copy(full, 1, Length(root)), root) then inside := True;
    {$ELSE}
    if Copy(full, 1, Length(root)) = root then inside := True;
    {$ENDIF}
  end;
  if not inside then
    raise ELdifRecordError.CreateAt(ALine, 1, 'file reference outside the allowed folders');
  attrs := FileGetAttr(full);
  if attrs = -1 then
    raise ELdifRecordError.CreateAt(ALine, 1, 'referenced file not found');
  // FPC signale faSymLink comme non portable. Voulu: les liens symboliques sont refuses
  // partout ou le systeme en expose.
  {$WARN SYMBOL_PLATFORM OFF}
  if (attrs and faSymLink) <> 0 then
    raise ELdifRecordError.CreateAt(ALine, 1, 'symbolic links are refused');
  {$WARN SYMBOL_PLATFORM ON}
  if (attrs and faDirectory) <> 0 then
    raise ELdifRecordError.CreateAt(ALine, 1, 'reference names a directory');
  // Ouverture non bloquante: sous Unix, un FIFO sans ecrivain bloquerait l'open avant
  // tout controle. Le type se verifie sur le descripteur deja ouvert.
  fs := OpenRegularFileRead(full, notReg);
  if fs = nil then
    raise ELdifRecordError.CreateAt(ALine, 1, 'reference is not a regular file');
  try
    if not HandleIsRegularFile(fs.Handle) then
      raise ELdifRecordError.CreateAt(ALine, 1, 'reference is not a regular file');
    phys := HandleFinalPath(fs.Handle);
    if phys = '' then
    begin
      phys := PhysicalPath(full);
      if (phys = '') or not (FileIdentity(phys, dev1, ino1) and HandleIdentity(fs.Handle, dev2, ino2)) or
         (dev1 <> dev2) or (ino1 <> ino2) then
        raise ELdifRecordError.CreateAt(ALine, 1, 'referenced file could not be verified');
    end;
    inside := False;
    for i := 0 to High(APolicy.AllowedRoots) do
    begin
      rootPhys := PhysicalPath(ExpandFileName(APolicy.AllowedRoots[i]));
      if UnderRoot(phys, rootPhys) then inside := True;
    end;
    if not inside then
      raise ELdifRecordError.CreateAt(ALine, 1,
        'file reference resolves outside the allowed folders (link, junction or mount)');
    if fs.Size > APolicy.MaxFileBytes then
      raise ELdifRecordError.CreateAt(ALine, 1, 'referenced file too large');
    // Plafond cumule verifie avant l'allocation; le reliquat borne aussi la lecture, et
    // un fichier qui grossit entre-temps est refuse.
    budget := APolicy.MaxTotalBytes - AUsed;
    if budget > APolicy.MaxFileBytes then budget := APolicy.MaxFileBytes;
    if fs.Size > budget then
      raise ELdifRecordError.CreateAt(ALine, 1, Format(
        'referenced files exceed the total limit of %d MB for one analysis',
        [APolicy.MaxTotalBytes div (1024 * 1024)]));
    // Meme descripteur que les controles d'identite, taille lue une seule fois: pas de
    // seconde ouverture a substituer.
    if not ReadWholeStream(fs, budget, AValue) then
      raise ELdifRecordError.CreateAt(ALine, 1, 'referenced file changed while it was read');
    Inc(AUsed, Length(AValue));
  finally
    fs.Free;
  end;
end;

procedure SplitSpec(const L: TLogicalLine; const AOptions: TLdifParseOptions;
  var AUsed: Int64; out AName: string; out AValue: RawByteString);
var
  p, start: Integer;
  s, enc: RawByteString;
begin
  s := L.Text;
  p := Pos(':', s);
  if p <= 1 then
    raise ELdifRecordError.CreateAt(L.Line, 1, '"name: value" expected');
  AName := Copy(s, 1, p - 1);
  if (p < Length(s)) and (s[p + 1] = ':') then
  begin
    start := p + 2;
    while (start <= Length(s)) and (s[start] = ' ') do Inc(start);
    enc := Copy(s, start, MaxInt);
    while (Length(enc) > 0) and (enc[Length(enc)] = ' ') do
      SetLength(enc, Length(enc) - 1);
    if (Int64(Length(enc)) div 4) * 3 > AOptions.MaxValueBytes then
      raise ELdifRecordError.CreateAt(L.Line, start, 'value too large');
    if not Base64DecodeStrict(enc, AValue) then
      raise ELdifRecordError.CreateAt(L.Line, start, 'invalid base64 value');
    Exit;
  end;
  if (p < Length(s)) and (s[p + 1] = '<') then
  begin
    start := p + 2;
    while (start <= Length(s)) and (s[start] = ' ') do Inc(start);
    LoadExternal(Copy(s, start, MaxInt), AOptions.External, L.Line, AUsed, AValue);
    Exit;
  end;
  start := p + 1;
  while (start <= Length(s)) and (s[start] = ' ') do Inc(start);
  AValue := Copy(s, start, MaxInt);
  if Length(AValue) > AOptions.MaxValueBytes then
    raise ELdifRecordError.CreateAt(L.Line, start, 'value too large');
  if (Length(AValue) > 0) and (AValue[1] in [':', '<']) then
    raise ELdifRecordError.CreateAt(L.Line, start, 'value must be base64-encoded');
  if (not AOptions.AllowRawUtf8) and not IsAsciiPrintable(AValue) then
    raise ELdifRecordError.CreateAt(L.Line, start, 'non-ASCII value must be base64-encoded');
  if not IsValidUtf8(AValue) then
    raise ELdifRecordError.CreateAt(L.Line, start, 'value is not valid UTF-8; use base64');
end;

function KeyOf(const L: TLogicalLine): string;
var
  p: Integer;
begin
  p := Pos(':', L.Text);
  if p = 0 then
    Result := ''
  else
    Result := AsciiLowerCase(Copy(L.Text, 1, p - 1));
end;

procedure CheckAttrName(const L: TLogicalLine; const AName: string);
begin
  if not IsValidAttributeDescription(AName) then
    raise ELdifRecordError.CreateAt(L.Line, 1, 'invalid attribute description');
end;

procedure ParseControl(AChange: TLdapChange; const L: TLogicalLine;
  const AOptions: TLdifParseOptions; var AUsed: Int64);
var
  rest, oid: string;
  p: Integer;
  spec: TLdapControlSpec;
  tmp: TLogicalLine;
  dummy: string;
begin
  rest := Trim(Copy(L.Text, Length('control:') + 1, MaxInt));
  p := 1;
  while (p <= Length(rest)) and not (rest[p] in [' ', ':']) do Inc(p);
  oid := Copy(rest, 1, p - 1);
  if not IsNumericOid(oid) then
    raise ELdifRecordError.CreateAt(L.Line, 9, 'control OID expected');
  spec.Oid := oid;
  spec.Critical := False;
  spec.HasValue := False;
  spec.Value := '';
  rest := TrimLeft(Copy(rest, p, MaxInt));
  if Copy(rest, 1, 4) = 'true' then
  begin
    spec.Critical := True;
    rest := TrimLeft(Copy(rest, 5, MaxInt));
  end
  else if Copy(rest, 1, 5) = 'false' then
    rest := TrimLeft(Copy(rest, 6, MaxInt));
  if rest <> '' then
  begin
    if rest[1] <> ':' then
      raise ELdifRecordError.CreateAt(L.Line, 1, 'invalid control value');
    tmp.Line := L.Line;
    tmp.Text := 'x' + rest;
    SplitSpec(tmp, AOptions, AUsed, dummy, spec.Value);
    spec.HasValue := True;
  end;
  SetLength(AChange.Controls, Length(AChange.Controls) + 1);
  AChange.Controls[High(AChange.Controls)] := spec;
end;

function ParseRecord(const ALines: TLogicalLines; const AOptions: TLdifParseOptions;
  var AUsed: Int64; out AIsChange: Boolean): TLdapChange;
var
  i, j: Integer;
  name, dn, ct: string;
  value: RawByteString;
  d: TLdapDn;
  err, key: string;
  modOp: TModOp;
  modAttr: string;
  values: array of RawByteString;
  change: TLdapChange;
begin
  AIsChange := False;
  if KeyOf(ALines[0]) <> 'dn' then
    raise ELdifRecordError.CreateAt(ALines[0].Line, 1, '"dn:" expected');
  SplitSpec(ALines[0], AOptions, AUsed, name, value);
  dn := value;
  if not DnParse(dn, d, err) then
    raise ELdifRecordError.CreateAt(ALines[0].Line, 1, 'invalid DN: ' + err);
  change := TLdapChange.Create;
  try
    change.Dn := dn;
    change.SourceLine := ALines[0].Line;
    i := 1;
    while (i <= High(ALines)) and (KeyOf(ALines[i]) = 'control') do
    begin
      ParseControl(change, ALines[i], AOptions, AUsed);
      AIsChange := True;
      Inc(i);
    end;
    if (i <= High(ALines)) and (KeyOf(ALines[i]) = 'changetype') then
    begin
      AIsChange := True;
      SplitSpec(ALines[i], AOptions, AUsed, name, value);
      ct := AsciiLowerCase(Trim(value));
      Inc(i);
      if ct = 'add' then
      begin
        change.Kind := ckAdd;
        change.Entry := TLdapEntry.Create(dn);
        if i > High(ALines) then
          raise ELdifRecordError.CreateAt(ALines[0].Line, 1, 'add record without attributes');
        for j := i to High(ALines) do
        begin
          SplitSpec(ALines[j], AOptions, AUsed, name, value);
          CheckAttrName(ALines[j], name);
          change.Entry.Ensure(name).AddValue(value);
        end;
      end
      else if ct = 'delete' then
      begin
        change.Kind := ckDelete;
        if i <= High(ALines) then
          raise ELdifRecordError.CreateAt(ALines[i].Line, 1, 'unexpected line in delete record');
      end
      else if (ct = 'modrdn') or (ct = 'moddn') then
      begin
        change.Kind := ckModDn;
        if (i > High(ALines)) or (KeyOf(ALines[i]) <> 'newrdn') then
          raise ELdifRecordError.CreateAt(ALines[0].Line, 1, '"newrdn:" expected');
        SplitSpec(ALines[i], AOptions, AUsed, name, value);
        change.NewRdn := value;
        if not DnParse(change.NewRdn, d, err) or (DnRdnCount(d) <> 1) then
          raise ELdifRecordError.CreateAt(ALines[i].Line, 1, 'invalid new RDN');
        Inc(i);
        if (i > High(ALines)) or (KeyOf(ALines[i]) <> 'deleteoldrdn') then
          raise ELdifRecordError.CreateAt(ALines[0].Line, 1, '"deleteoldrdn:" expected');
        SplitSpec(ALines[i], AOptions, AUsed, name, value);
        if value = '1' then change.DeleteOldRdn := True
        else if value = '0' then change.DeleteOldRdn := False
        else
          raise ELdifRecordError.CreateAt(ALines[i].Line, 1, 'deleteoldrdn must be 0 or 1');
        Inc(i);
        if (i <= High(ALines)) and (KeyOf(ALines[i]) = 'newsuperior') then
        begin
          SplitSpec(ALines[i], AOptions, AUsed, name, value);
          change.NewSuperior := value;
          change.HasNewSuperior := True;
          if not DnParse(change.NewSuperior, d, err) then
            raise ELdifRecordError.CreateAt(ALines[i].Line, 1, 'invalid new superior DN');
          Inc(i);
        end;
        if i <= High(ALines) then
          raise ELdifRecordError.CreateAt(ALines[i].Line, 1, 'unexpected line in moddn record');
      end
      else if ct = 'modify' then
      begin
        change.Kind := ckModify;
        while i <= High(ALines) do
        begin
          key := KeyOf(ALines[i]);
          if key = 'add' then modOp := moAdd
          else if key = 'delete' then modOp := moDelete
          else if key = 'replace' then modOp := moReplace
          else if key = 'increment' then modOp := moIncrement
          else
            raise ELdifRecordError.CreateAt(ALines[i].Line, 1,
              '"add:", "delete:", "replace:" or "increment:" expected');
          SplitSpec(ALines[i], AOptions, AUsed, name, value);
          modAttr := value;
          CheckAttrName(ALines[i], modAttr);
          Inc(i);
          values := nil;
          while (i <= High(ALines)) and (ALines[i].Text <> '-') do
          begin
            SplitSpec(ALines[i], AOptions, AUsed, name, value);
            if not SameAttrDescription(name, modAttr) then
              raise ELdifRecordError.CreateAt(ALines[i].Line, 1,
                'attribute does not match the modification');
            SetLength(values, Length(values) + 1);
            values[High(values)] := value;
            Inc(i);
          end;
          if (modOp = moIncrement) and (Length(values) <> 1) then
            raise ELdifRecordError.CreateAt(ALines[i - 1].Line, 1,
              'increment needs exactly one value');
          if (modOp = moAdd) and (Length(values) = 0) then
            raise ELdifRecordError.CreateAt(ALines[i - 1].Line, 1, 'add needs at least one value');
          change.AddMod(modOp, modAttr, values);
          if i <= High(ALines) then Inc(i);
        end;
      end
      else
        raise ELdifRecordError.CreateAt(ALines[i - 1].Line, 1, 'unknown changetype');
    end
    else
    begin
      if Length(change.Controls) > 0 then
        raise ELdifRecordError.CreateAt(ALines[0].Line, 1, 'controls require a changetype');
      change.Kind := ckAdd;
      change.Entry := TLdapEntry.Create(dn);
      for j := i to High(ALines) do
      begin
        SplitSpec(ALines[j], AOptions, AUsed, name, value);
        CheckAttrName(ALines[j], name);
        change.Entry.Ensure(name).AddValue(value);
      end;
    end;
    Result := change;
  except
    change.Free;
    raise;
  end;
end;

function LdifParse(const AText: RawByteString; const AOptions: TLdifParseOptions): TLdifDocument;
var
  doc: TLdifDocument;
  p, n, lineNo, eol, next: Integer;
  raw: RawByteString;
  logical: TLogicalLines;
  inComment, isChange, versionSeen, firstRecord: Boolean;
  externalUsed: Int64;

  procedure FlushRecord;
  var
    rec: TLdapChange;
    kind: TLdifKind;
  begin
    if Length(logical) = 0 then Exit;
    try
      if (not versionSeen) and firstRecord and (KeyOf(logical[0]) = 'version') then
      begin
        versionSeen := True;
        if Trim(Copy(logical[0].Text, 9, MaxInt)) <> '1' then
          raise ELdifRecordError.CreateAt(logical[0].Line, 1, 'unsupported LDIF version');
        doc.Version := 1;
        if Length(logical) = 1 then
        begin
          logical := nil;
          Exit;
        end;
        logical := Copy(logical, 1, MaxInt);
      end;
      firstRecord := False;
      if doc.RecordCount >= AOptions.MaxRecords then
      begin
        doc.AddIssue(logical[0].Line, 1, 'record limit reached; remainder ignored', True);
        logical := nil;
        Exit;
      end;
      rec := ParseRecord(logical, AOptions, externalUsed, isChange);
      if isChange then kind := lkChanges else kind := lkContent;
      if (doc.Kind <> lkUnknown) and (doc.Kind <> kind) then
      begin
        rec.Free;
        raise ELdifRecordError.CreateAt(logical[0].Line, 1,
          'content and change records cannot be mixed');
      end;
      doc.Kind := kind;
      doc.AddRecord(rec);
    except
      on E: ELdifRecordError do
        doc.AddIssue(E.Line, E.Column, E.Message, True);
      on E: EStreamError do
        doc.AddIssue(logical[0].Line, 1, 'cannot read referenced file', True);
    end;
    logical := nil;
  end;

begin
  doc := TLdifDocument.Create;
  logical := nil;
  externalUsed := 0;
  inComment := False;
  versionSeen := False;
  firstRecord := True;
  n := Length(AText);
  p := 1;
  lineNo := 0;
  if (n >= 3) and (AText[1] = #$EF) and (AText[2] = #$BB) and (AText[3] = #$BF) then
    p := 4;
  while p <= n do
  begin
    Inc(lineNo);
    eol := p;
    while (eol <= n) and not (AText[eol] in [#10, #13]) do Inc(eol);
    raw := Copy(AText, p, eol - p);
    next := eol;
    if (next <= n) and (AText[next] = #13) then Inc(next);
    if (next <= n) and (AText[next] = #10) then Inc(next);
    p := next;
    if (Length(raw) > 0) and (raw[1] = ' ') then
    begin
      if inComment then Continue;
      if Length(logical) = 0 then
      begin
        doc.AddIssue(lineNo, 1, 'continuation line without a preceding line', True);
        Continue;
      end;
      if Int64(Length(logical[High(logical)].Text)) + Length(raw) >
         AOptions.MaxValueBytes * 2 then
      begin
        doc.AddIssue(lineNo, 1, 'line too long', True);
        Continue;
      end;
      logical[High(logical)].Text := logical[High(logical)].Text + Copy(raw, 2, MaxInt);
      Continue;
    end;
    inComment := False;
    if raw = '' then
    begin
      FlushRecord;
      Continue;
    end;
    if raw[1] = '#' then
    begin
      inComment := True;
      Continue;
    end;
    SetLength(logical, Length(logical) + 1);
    logical[High(logical)].Text := raw;
    logical[High(logical)].Line := lineNo;
  end;
  FlushRecord;
  Result := doc;
end;

function LdifIsSafeString(const AValue: RawByteString): Boolean;
var
  i: Integer;
  b: Byte;
begin
  if AValue = '' then Exit(True);
  if AValue[1] in [' ', ':', '<'] then Exit(False);
  if AValue[Length(AValue)] = ' ' then Exit(False);
  for i := 1 to Length(AValue) do
  begin
    b := Byte(AValue[i]);
    if (b = 0) or (b = 10) or (b = 13) or (b > 127) then Exit(False);
  end;
  Result := True;
end;

constructor TLdifWriter.Create(AOut: TStream; AFoldWidth: Integer);
begin
  inherited Create;
  FOut := AOut;
  FFoldWidth := AFoldWidth;
  if FFoldWidth < 2 then FFoldWidth := 0;
  FEol := #10;
end;

procedure TLdifWriter.WriteRaw(const S: RawByteString);
var
  t: RawByteString;
begin
  if S = '' then Exit;
  if FEol <> #10 then
    t := StringReplace(S, #10, FEol, [rfReplaceAll])
  else
    t := S;
  FOut.WriteBuffer(t[1], Length(t));
end;

procedure TLdifWriter.WriteFolded(const S: RawByteString);
var
  p, chunk: Integer;
begin
  if (FFoldWidth = 0) or (Length(S) <= FFoldWidth) then
  begin
    WriteRaw(S + #10);
    Exit;
  end;
  WriteRaw(Copy(S, 1, FFoldWidth) + #10);
  p := FFoldWidth + 1;
  chunk := FFoldWidth - 1;
  while p <= Length(S) do
  begin
    WriteRaw(' ' + Copy(S, p, chunk) + #10);
    Inc(p, chunk);
  end;
end;

procedure TLdifWriter.WriteVersion;
begin
  WriteRaw('version: 1'#10#10);
end;

procedure TLdifWriter.WriteComment(const AText: string);
var
  lines: TStringArray;
  i: Integer;
begin
  lines := AText.Split([#10]);
  for i := 0 to High(lines) do
    WriteRaw('# ' + StringReplace(lines[i], #13, '', [rfReplaceAll]) + #10);
end;

procedure TLdifWriter.WriteSeparator;
begin
  WriteRaw(#10);
end;

procedure TLdifWriter.WriteAttrValue(const AAttr: string; const AValue: RawByteString);
begin
  if LdifIsSafeString(AValue) then
    WriteFolded(AAttr + ': ' + AValue)
  else
    WriteFolded(AAttr + ':: ' + Base64EncodeStr(AValue));
end;

procedure TLdifWriter.WriteEntry(AEntry: TLdapEntry);
var
  i, j: Integer;
  a: TLdapAttribute;
begin
  WriteAttrValue('dn', AEntry.Dn);
  for i := 0 to AEntry.AttrCount - 1 do
  begin
    a := AEntry.Attrs[i];
    for j := 0 to a.ValueCount - 1 do
      WriteAttrValue(a.Description, a.Values[j]);
  end;
  WriteSeparator;
end;

procedure TLdifWriter.WriteChange(AChange: TLdapChange);
var
  i, j: Integer;
  c: TLdapControlSpec;
  line: RawByteString;
begin
  WriteAttrValue('dn', AChange.Dn);
  for i := 0 to High(AChange.Controls) do
  begin
    c := AChange.Controls[i];
    line := 'control: ' + c.Oid;
    if c.Critical then line := line + ' true' else line := line + ' false';
    if c.HasValue then
    begin
      if LdifIsSafeString(c.Value) then
        line := line + ': ' + c.Value
      else
        line := line + ':: ' + Base64EncodeStr(c.Value);
    end;
    WriteFolded(line);
  end;
  WriteRaw('changetype: ' + ChangeKindName(AChange.Kind) + #10);
  case AChange.Kind of
    ckAdd:
      if AChange.Entry <> nil then
        for i := 0 to AChange.Entry.AttrCount - 1 do
          for j := 0 to AChange.Entry.Attrs[i].ValueCount - 1 do
            WriteAttrValue(AChange.Entry.Attrs[i].Description, AChange.Entry.Attrs[i].Values[j]);
    ckModify:
      for i := 0 to High(AChange.Mods) do
      begin
        WriteRaw(ModOpName(AChange.Mods[i].Op) + ': ' + AChange.Mods[i].Attr + #10);
        for j := 0 to High(AChange.Mods[i].Values) do
          WriteAttrValue(AChange.Mods[i].Attr, AChange.Mods[i].Values[j]);
        WriteRaw('-'#10);
      end;
    ckModDn:
      begin
        WriteAttrValue('newrdn', AChange.NewRdn);
        if AChange.DeleteOldRdn then
          WriteRaw('deleteoldrdn: 1'#10)
        else
          WriteRaw('deleteoldrdn: 0'#10);
        if AChange.HasNewSuperior then
          WriteAttrValue('newsuperior', AChange.NewSuperior);
      end;
  end;
  WriteSeparator;
end;

function LdifEntryToString(AEntry: TLdapEntry): RawByteString;
var
  ms: TStringStream;
  w: TLdifWriter;
begin
  ms := TStringStream.Create('');
  w := TLdifWriter.Create(ms);
  try
    w.WriteEntry(AEntry);
    Result := ms.DataString;
  finally
    w.Free;
    ms.Free;
  end;
end;

function LdifChangeToString(AChange: TLdapChange): RawByteString;
var
  ms: TStringStream;
  w: TLdifWriter;
begin
  ms := TStringStream.Create('');
  w := TLdifWriter.Create(ms);
  try
    w.WriteChange(AChange);
    Result := ms.DataString;
  finally
    w.Free;
    ms.Free;
  end;
end;

end.
