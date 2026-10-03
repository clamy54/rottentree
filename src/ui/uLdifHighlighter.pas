// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uLdifHighlighter;

{$mode objfpc}{$H+}

// Coloration LDIF pour SynEdit, aux couleurs du theme. Ligne par ligne, sans etat:
// le LDIF est deja assez penible a lire sans qu'on se souvienne de la ligne d'avant.

interface

uses
  Classes, SysUtils, Graphics, SynEditHighlighter;

type
  TLdifTokenKind = (ltkNone, ltkComment, ltkKey, ltkKeyword, ltkSeparator, ltkValue,
    ltkBase64, ltkInvalid, ltkContinuation);

  TSynLdifHighlighter = class(TSynCustomHighlighter)
  private
    FLine: string;
    FPos: Integer;
    FTokenStart: Integer;
    FKind: TLdifTokenKind;
    FCommentAttr, FKeyAttr, FKeywordAttr, FSepAttr, FValueAttr, FBase64Attr,
      FInvalidAttr: TSynHighlighterAttributes;
    FValueMode: Integer;
    FIsBase64: Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetLine(const NewValue: string; LineNumber: Integer); override;
    procedure Next; override;
    function GetEol: Boolean; override;
    function GetToken: string; override;
    procedure GetTokenEx(out TokenStart: PChar; out TokenLength: Integer); override;
    function GetTokenAttribute: TSynHighlighterAttributes; override;
    function GetTokenKind: Integer; override;
    function GetTokenPos: Integer; override;
    function GetDefaultAttribute(Index: Integer): TSynHighlighterAttributes; override;
    procedure ApplyTheme;
  end;

implementation

uses
  uTheme;

const
  KEYWORDS: array[0..9] of string = ('dn', 'changetype', 'add', 'delete', 'replace', 'increment',
    'newrdn', 'deleteoldrdn', 'newsuperior', 'control');

constructor TSynLdifHighlighter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCommentAttr := TSynHighlighterAttributes.Create('Comment', 'Comment');
  AddAttribute(FCommentAttr);
  FKeyAttr := TSynHighlighterAttributes.Create('Attribute', 'Attribute');
  AddAttribute(FKeyAttr);
  FKeywordAttr := TSynHighlighterAttributes.Create('Keyword', 'Keyword');
  AddAttribute(FKeywordAttr);
  FSepAttr := TSynHighlighterAttributes.Create('Separator', 'Separator');
  AddAttribute(FSepAttr);
  FValueAttr := TSynHighlighterAttributes.Create('Value', 'Value');
  AddAttribute(FValueAttr);
  FBase64Attr := TSynHighlighterAttributes.Create('Base64', 'Base64');
  AddAttribute(FBase64Attr);
  FInvalidAttr := TSynHighlighterAttributes.Create('Invalid', 'Invalid');
  AddAttribute(FInvalidAttr);
  ApplyTheme;
end;

procedure TSynLdifHighlighter.ApplyTheme;
begin
  FCommentAttr.Foreground := clCodeComment;
  FKeyAttr.Foreground := clCodeVariable;
  FKeywordAttr.Foreground := clCodeKeyword;
  FSepAttr.Foreground := clEditorFg;
  FValueAttr.Foreground := clEditorFg;
  FBase64Attr.Foreground := clCodeString;
  FInvalidAttr.Foreground := clCodeInvalid;
end;

procedure TSynLdifHighlighter.SetLine(const NewValue: string; LineNumber: Integer);
begin
  inherited SetLine(NewValue, LineNumber);
  FLine := NewValue;
  FPos := 1;
  FValueMode := 0;
  FIsBase64 := False;
  Next;
end;

procedure TSynLdifHighlighter.Next;
var
  p, k: Integer;
  key: string;
begin
  FTokenStart := FPos;
  if FPos > Length(FLine) then
  begin
    FKind := ltkNone;
    Exit;
  end;
  if (FPos = 1) and (FLine[1] = '#') then
  begin
    FKind := ltkComment;
    FPos := Length(FLine) + 1;
    Exit;
  end;
  if (FPos = 1) and (FLine[1] = ' ') then
  begin
    FKind := ltkContinuation;
    FPos := Length(FLine) + 1;
    Exit;
  end;
  if (FPos = 1) and (FLine = '-') then
  begin
    FKind := ltkKeyword;
    FPos := 2;
    Exit;
  end;
  case FValueMode of
    0:
      begin
        p := Pos(':', FLine);
        if p = 0 then
        begin
          FKind := ltkInvalid;
          FPos := Length(FLine) + 1;
          Exit;
        end;
        key := LowerCase(Copy(FLine, 1, p - 1));
        FKind := ltkKey;
        for k := 0 to High(KEYWORDS) do
          if KEYWORDS[k] = key then FKind := ltkKeyword;
        FPos := p;
        FValueMode := 1;
      end;
    1:
      begin
        FKind := ltkSeparator;
        Inc(FPos);
        FIsBase64 := (FPos <= Length(FLine)) and (FLine[FPos] in [':', '<']);
        if FIsBase64 then Inc(FPos);
        FValueMode := 2;
      end;
  else
    begin
      if FIsBase64 then FKind := ltkBase64 else FKind := ltkValue;
      FPos := Length(FLine) + 1;
    end;
  end;
end;

function TSynLdifHighlighter.GetEol: Boolean;
begin
  Result := FKind = ltkNone;
end;

function TSynLdifHighlighter.GetToken: string;
begin
  Result := Copy(FLine, FTokenStart, FPos - FTokenStart);
end;

procedure TSynLdifHighlighter.GetTokenEx(out TokenStart: PChar; out TokenLength: Integer);
begin
  TokenLength := FPos - FTokenStart;
  if TokenLength > 0 then
    TokenStart := @FLine[FTokenStart]
  else
    TokenStart := nil;
end;

function TSynLdifHighlighter.GetTokenAttribute: TSynHighlighterAttributes;
begin
  case FKind of
    ltkComment: Result := FCommentAttr;
    ltkKey: Result := FKeyAttr;
    ltkKeyword: Result := FKeywordAttr;
    ltkSeparator: Result := FSepAttr;
    ltkBase64: Result := FBase64Attr;
    ltkInvalid: Result := FInvalidAttr;
  else
    Result := FValueAttr;
  end;
end;

function TSynLdifHighlighter.GetTokenKind: Integer;
begin
  Result := Ord(FKind);
end;

function TSynLdifHighlighter.GetTokenPos: Integer;
begin
  Result := FTokenStart - 1;
end;

function TSynLdifHighlighter.GetDefaultAttribute(Index: Integer): TSynHighlighterAttributes;
begin
  case Index of
    SYN_ATTR_COMMENT: Result := FCommentAttr;
    SYN_ATTR_KEYWORD: Result := FKeywordAttr;
    SYN_ATTR_STRING: Result := FBase64Attr;
  else
    Result := nil;
  end;
end;

end.
