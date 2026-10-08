// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uDirectoryScan;

{$mode objfpc}{$H+}

// Parcours de plusieurs bases sans limite de taille cote client, pour les audits. Chaque entree
// passe par le rappel, qui la libere: rien ne s'empile ici, la memoire du poste n'est pas une
// replique de l'annuaire.

interface

uses
  SysUtils, uSearchModel, uLdapSchema, uDirectorySession, uDirectoryWorker;

type
  TDirectoryScanCmd = class(TWorkerCommand)
  protected
    FWorker: TDirectoryWorker;
    // Une seule base incomplete et tout le bilan est partiel: on ne fait pas de moyenne avec
    // la verite. Le premier defaut rencontre est garde.
    function ScanAll(const AFilter: string; const AAttrs: array of string;
      AOnEntry: TSearchEntryEvent): TSearchCompletion;
  public
    Bases: TStringArray;
    PageSize: Integer;
  end;

// Termes (objectClass=...) des classes de compte que ce schema connait: certains serveurs
// jettent tout le filtre pour une classe inconnue. Sans schema complet, toutes.
function AccountClassTerms(ASchema: TSchemaSnapshot): string;
// Valeur montrable dans une liste; vide si ce n'est pas du texte.
function ScanText(const AValue: RawByteString): string;
// Cle de comparaison d'un DN: types en minuscules, echappements normalises, AVA d'un RDN
// multivalue ranges. "cn=Jean\, D" et "cn=Jean\2c D" donnent la meme cle. La casse ASCII des
// valeurs est pliee: les attributs de nommage usuels sont caseIgnore, un schema caseExact
// exotique y perd un doublon d'affichage, pas une entree. Un DN imparsable ne s'egale qu'a
// lui-meme, au byte pres.
function ScanDnKey(const ADn: string): string;

implementation

uses
  uRtBytes, uLdapDn;

const
  ACCOUNT_CLASSES: array[0..6] of string = ('person', 'organizationalPerson', 'inetOrgPerson',
    'account', 'posixAccount', 'shadowAccount', 'simpleSecurityObject');

function AccountClassTerms(ASchema: TSchemaSnapshot): string;
var
  i: Integer;
  all: Boolean;
begin
  all := (ASchema = nil) or not ASchema.Complete or (ASchema.ObjectClassCount = 0);
  Result := '';
  for i := 0 to High(ACCOUNT_CLASSES) do
    if all or (ASchema.ObjectClass(ACCOUNT_CLASSES[i]) <> nil) then
      Result := Result + '(objectClass=' + ACCOUNT_CLASSES[i] + ')';
end;

function ScanText(const AValue: RawByteString): string;
begin
  if IsValidUtf8(AValue) then
    Result := EscapeControlChars(AValue)
  else
    Result := '';
end;

function ScanDnKey(const ADn: string): string;
var
  dn: TLdapDn;
  parts: array of string;
  i, j, k: Integer;
  tmp, rdnKey: string;
begin
  if not DnTryParse(ADn, dn) then
    Exit('!' + ADn);
  Result := '';
  for i := 0 to High(dn.Rdns) do
  begin
    parts := nil;
    SetLength(parts, Length(dn.Rdns[i].Avas));
    for j := 0 to High(dn.Rdns[i].Avas) do
      with dn.Rdns[i].Avas[j] do
        if HexForm then
          parts[j] := LowerCase(AttrType) + '=#' + LowerCase(HexEncode(Value))
        else
          parts[j] := LowerCase(AttrType) + '=' + DnEscapeValue(LowerCase(Value));
    for j := 1 to High(parts) do
    begin
      tmp := parts[j];
      k := j - 1;
      while (k >= 0) and (parts[k] > tmp) do
      begin
        parts[k + 1] := parts[k];
        Dec(k);
      end;
      parts[k + 1] := tmp;
    end;
    rdnKey := '';
    for j := 0 to High(parts) do
    begin
      if j > 0 then rdnKey := rdnKey + '+';
      rdnKey := rdnKey + parts[j];
    end;
    if i > 0 then Result := Result + ',';
    Result := Result + rdnKey;
  end;
end;

function TDirectoryScanCmd.ScanAll(const AFilter: string; const AAttrs: array of string;
  AOnEntry: TSearchEntryEvent): TSearchCompletion;
var
  req: TSearchRequest;
  c: TSearchCompletion;
  i, k: Integer;
begin
  Result := Default(TSearchCompletion);
  Result.HasResult := Length(Bases) > 0;
  for i := 0 to High(Bases) do
  begin
    req := DefaultSearchRequest;
    req.BaseDn := Bases[i];
    req.Scope := ssSubtree;
    req.Filter := AFilter;
    req.PageSize := PageSize;
    req.SizeLimit := 0;
    req.TimeLimitSec := 0;
    SetLength(req.Attributes, Length(AAttrs));
    for k := 0 to High(AAttrs) do
      req.Attributes[k] := AAttrs[k];
    FWorker.Session.Search(req, AOnEntry, Cancel, c, False);
    Result.HasResult := Result.HasResult and c.HasResult;
    Inc(Result.EntryCount, c.EntryCount);
    Inc(Result.PageCount, c.PageCount);
    Inc(Result.ReferralsIgnored, c.ReferralsIgnored);
    Inc(Result.ContinuationsIgnored, c.ContinuationsIgnored);
    Inc(Result.DecodeFailures, c.DecodeFailures);
    Inc(Result.TruncatedEntries, c.TruncatedEntries);
    Result.SizeLimitHit := Result.SizeLimitHit or c.SizeLimitHit;
    Result.TimeLimitHit := Result.TimeLimitHit or c.TimeLimitHit;
    Result.ClientLimitHit := Result.ClientLimitHit or c.ClientLimitHit;
    Result.RangeIncomplete := Result.RangeIncomplete or c.RangeIncomplete;
    Result.Cancelled := Result.Cancelled or c.Cancelled;
    if Result.PagingAnomaly = '' then Result.PagingAnomaly := c.PagingAnomaly;
    if Result.ResultCode = LDAP_RC_SUCCESS then
    begin
      Result.ResultCode := c.ResultCode;
      Result.DiagnosticMessage := c.DiagnosticMessage;
      Result.MatchedDn := c.MatchedDn;
    end;
    if c.Cancelled or (SearchOutcome(c) = soFailed) then Break;
  end;
end;

end.
