// Copyright (C) 2024 - 2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uJsonGuard;

{$mode objfpc}{$H+}

// Garde-fou avant GetJSON: le DOM fpjson se construit par recursion, dix mille '[' epuisent
// sa pile et le try/except n'y peut rien, c'est une violation d'acces. Les themes passent
// aussi par la: un theme piege, lu avant la fenetre principale, planterait chaque demarrage.

interface

const
  // Tres au-dela de tout fichier honnete, tres en deca de ce qui fait tomber le parseur.
  JSON_MAX_DEPTH_DEFAULT = 64;

function JsonNestingTooDeep(const AText: string;
  AMax: Integer = JSON_MAX_DEPTH_DEFAULT): Boolean;

implementation

function JsonNestingTooDeep(const AText: string; AMax: Integer): Boolean;
var
  i, depth: Integer;
  inStr, esc: Boolean;
  c: Char;
begin
  Result := False;
  depth := 0;
  inStr := False;
  esc := False;
  for i := 1 to Length(AText) do
  begin
    c := AText[i];
    if inStr then
    begin
      if esc then esc := False
      else if c = '\' then esc := True
      else if c = '"' then inStr := False;
      Continue;
    end;
    case c of
      '"': inStr := True;
      '[', '{':
        begin
          Inc(depth);
          if depth > AMax then Exit(True);
        end;
      ']', '}': if depth > 0 then Dec(depth);
    end;
  end;
end;

end.
