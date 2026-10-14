// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uEntryTemplate;

{$mode objfpc}{$H+}

// Modeles d'entrees: classes, attribut de nommage, et une source par valeur (fixe, demandee,
// composee, numero libre). Le modele ne connait aucun serveur: le schema du jour tranche.
// Le JSON est relu comme une saisie hostile: il a voyage par courriel, comme tous les malheurs.

interface

uses
  SysUtils, Classes, uLdapSchema, uLdapEntry, uConnectionProfile, uSensitive, uEntryCreationPlan,
  uAttributeCodec, uAdPasswordRules;

const
  TEMPLATE_VERSION = 1;
  TEMPLATE_NAME_MAX = 120;
  // Bornes de relecture: l'editeur, l'enregistrement et le lecteur JSON en partagent une seule liste.
  TEMPLATE_DESC_MAX = 500;
  TEMPLATE_PROMPT_MAX = 200;
  TEMPLATE_ATTR_MAX = 256;
  TEMPLATE_DN_MAX = 1024;
  TEMPLATE_ORIGIN_MAX = 64;
  TEMPLATE_TEXT_MAX = 4096;
  TEMPLATE_MAX_BYTES = 512 * 1024;
  TEMPLATE_MAX_FIELDS = 256;
  TEMPLATE_MAX_PARTS = 32;
  TEMPLATE_MAX_CLASSES = 32;
  TEMPLATE_MAX_TAKE = 64;
  TEMPLATE_MAX_GROUPS = 32;
  TEMPLATE_SCHEME_MAX = 64;
  TEMPLATE_COUNTER_MAX = 9999;
  TEMPLATE_COUNTER_DIGITS = 4;
  // Active Directory hache lui-meme: pas de format a choisir, le mot de passe part avec le compte.
  TEMPLATE_SCHEME_AD = 'AD';
  // Plafond des reprises par calcul. Sans lui, 32 reprises sur six niveaux font d'un caractere
  // un gigaoctet, et d'un modele importe une panne.
  TEMPLATE_COMPOSE_BUDGET = 1024 * 1024;

type
  // tsRandom: mot de passe tire au sort a la creation, montre une fois, jamais garde.
  TTplSource = (tsFixed, tsAsk, tsCompose, tsNumber, tsRandom);
  TTplCase = (tcAsIs, tcUpper, tcLower, tcCapital);
  // tpCounter: numero d'unicite de l'entree, le meme pour tous les champs qui le portent.
  TTplPartKind = (tpText, tpAttr, tpCounter);

  TTplPart = record
    Kind: TTplPartKind;
    // tpCounter: texte place devant le numero, ecrit seulement avec lui
    Text: string;
    CaseFn: TTplCase;
    // 0: toute la valeur; tpCounter: chiffres au moins
    Take: Integer;
    Plain: Boolean;
    // tpCounter: rien du tout quand le numero vaut 1
    OmitOne: Boolean;
  end;
  TTplParts = array of TTplPart;

  TTplNumberMode = (tnAfterHighest, tnFirstFree);

  TTplField = record
    Attr: string;
    Source: TTplSource;
    Value: string;
    Prompt: string;
    Optional: Boolean;
    Parts: TTplParts;
    NumberMode: TTplNumberMode;
    HasMin, HasMax: Boolean;
    Min, Max: Int64;
    // format du mot de passe; vide hors secret
    Scheme: string;
    RandomLength: Integer;
  end;
  TTplFields = array of TTplField;

  // Compte utilisateur AD: reglages qui ne sont pas des valeurs d'attributs.
  TTplAccount = record
    MustChange: Boolean;
    NeverExpires: Boolean;
    Disabled: Boolean;
  end;

  TEntryTemplate = record
    Uuid: string;
    Name: string;
    Description: string;
    Origin: string;
    Structural: string;
    Auxiliaries: TStringArray;
    RdnAttr: string;
    Fields: TTplFields;
    // par DN: propres a un annuaire, verifies a l'usage
    Groups: TStringArray;
    Account: TTplAccount;
  end;
  TEntryTemplates = array of TEntryTemplate;

  TTplIssue = record
    Severity: TIssueSeverity;
    // -1: le modele entier
    Field: Integer;
    Text: string;
  end;
  TTplIssues = array of TTplIssue;

  TTplIndexes = array of Integer;

resourcestring
  rsTplNoName = 'Give the template a name.';
  rsTplNameTooLong = 'The name is longer than %d characters.';
  rsTplNoRdn = 'Choose the attribute that names the entry (RDN).';
  rsTplRdnSecret = '%s is a secret: it cannot name the entry.';
  rsTplNoAttr = 'Choose an attribute.';
  rsTplObjectClass = 'objectClass comes from the classes of the template.';
  rsTplFixedEmpty = '%s: type the fixed value.';
  rsTplValue = '%s: %s';
  rsTplComposeEmpty = '%s: add at least one element to compose the value.';
  rsTplPartNoAttr = '%s: choose the attribute of each element.';
  rsTplRefMissing = '%s uses %s, which is not in the template.';
  rsTplRefSecret = '%s uses %s, which is a secret.';
  rsTplCycle = 'Circular reference: %s.';
  rsTplNumberKind = '%s is not a number: a free number cannot be searched for it.';
  rsTplRange = '%s: the highest number must be above the lowest.';
  rsTplNumberDefault = '%s: a searched number takes no default value.';
  rsTplSecretAsk = '%s: a password asked for when the entry is created has no default value.';
  rsTplSecretNumber = '%s is a secret: it cannot be a number.';
  rsTplPwdAttr = '%s is a secret: only %s can be fixed or composed, other secrets are asked for.';
  rsTplPwdNoFormat = '%s: choose the format the server stores the password in.';
  rsTplPwdFormat = '%s: this server does not take the %s format.';
  rsTplPwdSame = '%s: every entry gets the same password.';
  rsTplPwdDerived = '%s: the password follows from values anyone who reads the entry sees. Test accounts only.';
  rsTplPwdClear = '%s: stored as typed, anyone who reads the entry reads the password.';
  rsTplNotUtf8 = 'not valid text';
  rsTplCounterSecret = '%s is a secret: it takes no number.';
  rsTplCounterTwice = '%s: one number per value.';
  rsTplRdnNoCounter = '%s names the entry and does not follow the number: two homonyms would collide in ' +
    'the same container.';
  rsTplOtherFamily = 'Designed for %s, and this server is %s: open it on a server of its kind, or adapt it ' +
    'in the template manager.';
  rsTplRandomNotPwd = '%s: only a password can be drawn at random.';
  rsTplRandomLength = '%s: a random password takes %d to %d characters.';
  rsTplAccountNotAd = 'The account options only apply to an Active Directory user account.';
  rsTplAccountBoth = 'The password must be changed at the next logon but never expires: the first logon ' +
    'changes it, after which it stays forever.';
  rsTplSkipAccount = 'read into the account options';
  rsTplPolicy = '%s: %s (domain password policy).';
  rsTplPolicySample = '%s: with the sample values, "%s" is %s (domain password policy).';
  rsTplPolicyRandom = '%s: the domain demands %d characters at least.';
  rsTplNotText = '%s holds a value that cannot be typed (%s).';
  rsTplSingle = '%s is single-valued: it appears more than once.';
  rsTplTooMany = 'The template has more than %d values.';
  rsTplUnreadable = 'unreadable template: %s';
  rsTplFutureVersion = 'template from a newer version (%d)';
  rsTplTooLarge = 'template larger than %d bytes';
  rsTplFieldTooLong = '"%s" is longer than %d bytes';
  rsTplTooLongFor = 'The %s is longer than %d bytes.';
  rsTplWhatDescription = 'description';
  rsTplWhatGroup = 'DN of a group';
  rsTplWhatLabel = 'label';
  rsTplWhatText = 'fixed text of a composition';
  rsTplTooManyOf = 'more than %d "%s"';
  rsTplSourceTruncated = 'The entry was not read completely (truncated attribute or decoding stopped): read it again before making a template of it.';
  rsTplSkipServer = 'set by the server';
  rsTplSkipSecret = 'secret';
  rsTplSkipBinary = 'not text';
  rsTplSkipTooLong = 'value longer than %d bytes';
  rsTplSkipFull = 'template full at %d values, %d left out';
  rsTplSkipBudget = 'too long to analyse';
  rsTplNotReadable = 'This template would not read back as saved (%s): nothing was written.';
  rsTplValueTooLong = 'longer than %d bytes';
  rsTplComposeTooLong = '%s: the composition grows beyond %d bytes; it repeats other values too many times.';
  rsTplAsciiOnly = '%s takes plain ASCII: a value of %s with an accent will be refused. ' +
    'Turn on "Without accents or spaces" for it.';
  rsTplPromptFirstName = 'First name';
  rsTplPromptLastName = 'Last name';
  rsTplPromptMember = 'Member';
  rsTplPromptLogin = 'Login';
  rsTplPromptMail = 'E-mail';
  rsTplPromptPhone = 'Phone';
  rsTplPromptMobile = 'Mobile';
  rsTplPromptDescription = 'Description';
  rsTplPromptName = 'Name';
  rsTplPromptTitle = 'Job title';
  rsTplPromptPassword = 'Password';
  rsTplPromptDisplayName = 'Display name';

function NewTemplate: TEntryTemplate;
function CloneTemplate(const T: TEntryTemplate): TEntryTemplate;
function TextPart(const AText: string): TTplPart;
function AttrPart(const AAttr: string; ACase: TTplCase = tcAsIs; ATake: Integer = 0;
  APlain: Boolean = False): TTplPart;
function CounterPart(const APrefix: string; ADigits: Integer = 0; AOmitOne: Boolean = False): TTplPart;
function CounterText(const APart: TTplPart; ACounter: Integer): string;
// Champs dont la valeur change avec le numero: ceux qui le portent et ceux qui les reprennent.
function TemplateCounterFields(const T: TEntryTemplate): TTplIndexes;
function TemplateHasCounter(const T: TEntryTemplate): Boolean;
function NewField(const AAttr: string; ASource: TTplSource): TTplField;
function SameAttr(const A, B: string): Boolean;
function FieldIndex(const T: TEntryTemplate; const AAttr: string): Integer;
function FieldCount(const T: TEntryTemplate; const AAttr: string): Integer;
// Attributs composes a partir de ce champ, separes par des virgules; vide si aucun.
function ComposedFrom(const T: TEntryTemplate; AIndex: Integer): string;
function DefaultPrompt(const AAttr: string): string;
function FieldPrompt(const F: TTplField): string;

function TemplateToJson(const T: TEntryTemplate): string;
function TemplateFromJson(const AText: string; out T: TEntryTemplate; out AError: string): Boolean;

function PlainAscii(const S: string): string;
function CapitalizeWords(const S: string): string;
function ApplyPart(const APart: TTplPart; const AValue: string): string;
function TemplateOrder(const T: TEntryTemplate; out AOrder, ACycle: TTplIndexes): Boolean;
// Debordement: coupee juste apres la borne, donc refusee au controle, jamais envoyee.
procedure ComposeValues(const T: TEntryTemplate; var AValues: TStringArray;
  const AManual: array of Boolean);
// Meme calcul sur un budget que l'appelant tient: un lot le partage entre toutes ses lignes.
procedure ComposeValuesWithin(const T: TEntryTemplate; var AValues: TStringArray;
  const AManual: array of Boolean; var ABudget: Int64);
// Avec le numero d'unicite de l'entree; les autres variantes prennent 1.
procedure ComposeValuesCounted(const T: TEntryTemplate; var AValues: TStringArray;
  const AManual: array of Boolean; ACounter: Integer; var ABudget: Int64);
function SampleValues(const T: TEntryTemplate): TStringArray;

function CheckTemplate(const T: TEntryTemplate; ASchema: TSchemaSnapshot; AProvider: TProviderKind;
  ASensitive: TSensitivePolicy; out AAnalysis: TClassAnalysis): TTplIssues;
function TemplateHasErrors(const AIssues: TTplIssues): Boolean;
function FirstTemplateError(const AIssues: TTplIssues): string;
function IsRequiredAttr(const AAnalysis: TClassAnalysis; ASchema: TSchemaSnapshot;
  const AAttr: string): Boolean;
function SyncRequiredFields(var T: TEntryTemplate; ASchema: TSchemaSnapshot;
  AProvider: TProviderKind; ASensitive: TSensitivePolicy): Integer;
function TemplateAttributeChoices(const AAnalysis: TClassAnalysis; ASchema: TSchemaSnapshot;
  AProvider: TProviderKind; ASensitive: TSensitivePolicy): TStringArray;
// Le seul secret qui se fixe, se compose ou se tire: userPassword, unicodePwd chez AD.
function TemplatePasswordAttr(const AAttr: string; AProvider: TProviderKind;
  ASchema: TSchemaSnapshot): Boolean;
function TemplatePasswordAttrName(AProvider: TProviderKind): string;
// Formats que le serveur comprend; AD n'en a qu'un, le sien.
function TemplatePasswordFormats(AProvider: TProviderKind): TStringArray;
function TemplateDefaultFormat(AProvider: TProviderKind): string;
// Une identite deleguee ({SASL}user@REALM) se montre, un mot de passe non.
function TemplateSecretShown(const F: TTplField): Boolean;
// Compte utilisateur AD: les options de compte s'y appliquent (pas a une machine ni a une OU).
function TemplateIsAdUser(const AAnalysis: TClassAnalysis; AProvider: TProviderKind): Boolean;
// Concu sur Active Directory. Un inetOrgPerson LDAP ouvert sur un AD y passe pour un user: ce
// n'est pas pour autant un modele AD.
function TemplateDesignedForAd(const T: TEntryTemplate): Boolean;
// Meme famille que le serveur: AD d'un cote, tous les LDAP de l'autre. Sans origine, partout.
function TemplateFitsProvider(const T: TEntryTemplate; AProvider: TProviderKind): Boolean;
// Face a la politique du domaine: avertissements seulement, une PSO peut en decider autrement.
function TemplatePolicyIssues(const T: TEntryTemplate; const APolicy: TAdPwdPolicy): TTplIssues;
// Champ de mot de passe, valide ou bricole: format pose, attribut sensible.
function TemplatePasswordField(const F: TTplField; ASensitive: TSensitivePolicy = nil): Boolean;
// Du clair dans le modele lui-meme: valeur fixe, ou texte d'une composition de mot de passe.
function TemplateSecretInClear(const F: TTplField; ASensitive: TSensitivePolicy = nil): Boolean;
// Retire ce clair: le champ redevient une valeur fixe vide, a ressaisir apres l'import.
procedure TemplateDropSecret(var F: TTplField);
function TemplateCanHold(AKind: TValueKind): Boolean;
function TemplateValueProblem(ASchema: TSchemaSnapshot; AProvider: TProviderKind;
  const AAttr, AText: string): string;
function AttrIsAsciiOnly(ASchema: TSchemaSnapshot; const AAttr: string): Boolean;
// nil avec le motif. Aucun secret: ALater nomme ceux que l'appelant ajoutera, haches ou encodes.
function BuildTemplateEntry(const T: TEntryTemplate; const AValues: array of string;
  const AParentDn: string; ASchema: TSchemaSnapshot; AProvider: TProviderKind;
  ASensitive: TSensitivePolicy; const AAnalysis: TClassAnalysis; out AProblem: string;
  const ALater: TStringArray = nil): TLdapEntry;
function TemplateFromEntry(AEntry: TLdapEntry; ASchema: TSchemaSnapshot; AProvider: TProviderKind;
  ASensitive: TSensitivePolicy; out T: TEntryTemplate; out ASkipped: TStringArray;
  out AError: string): Boolean;

implementation

uses
  fpjson, jsonparser, LazUTF8, uJsonGuard, uLdapSyntaxCheck, uClonePlan, uPwdCore, uPasswordSchemes,
  uServerKind;

const
  SOURCE_NAMES: array[TTplSource] of string = ('fixed', 'ask', 'compose', 'number', 'random');
  CASE_NAMES: array[TTplCase] of string = ('', 'upper', 'lower', 'capital');
  // U+00C0..U+00FF puis U+0100..U+017F, lettre de base par rang; '?' se traite a part
  LATIN1_BASE = 'AAAAAA?CEEEEIIIIDNOOOOO?OUUUUY??aaaaaa?ceeeeiiiidnooooo?ouuuuy?y';
  LATIN_A_BASE = 'AaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIiIiJjKkkLlLlLlL' +
    'lLlNnNnNnnNnOoOoOoOoRrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZzs';
  // Propres a une personne: jamais recopies d'une entree modele.
  PERSONAL: array[0..27] of string = ('mail', 'telephoneNumber', 'mobile', 'homePhone',
    'facsimileTelephoneNumber', 'employeeNumber', 'title', 'description', 'displayName',
    'initials', 'street', 'postalAddress', 'postalCode', 'roomNumber', 'pager', 'labeledURI',
    'userPrincipalName', 'sAMAccountName', 'gecos', 'homeDirectory', 'member', 'uniqueMember',
    'memberUid', 'givenName', 'sn', 'cn', 'uid', 'ou');

const
  LOGIN_LIKE: array[0..3] of string = ('uid', 'sAMAccountName', 'userPrincipalName', 'mailNickname');
  // comparaisons accordees a la deduction des compositions, pour toute l'entree
  DERIVE_BUDGET = 20000000;

function NewTemplate: TEntryTemplate;
begin
  Result := Default(TEntryTemplate);
end;

function CloneTemplate(const T: TEntryTemplate): TEntryTemplate;
var
  i: Integer;
begin
  Result := T;
  Result.Auxiliaries := Copy(T.Auxiliaries, 0, Length(T.Auxiliaries));
  Result.Fields := Copy(T.Fields, 0, Length(T.Fields));
  Result.Groups := Copy(T.Groups, 0, Length(T.Groups));
  for i := 0 to High(Result.Fields) do
    Result.Fields[i].Parts := Copy(T.Fields[i].Parts, 0, Length(T.Fields[i].Parts));
end;

function TextPart(const AText: string): TTplPart;
begin
  Result := Default(TTplPart);
  Result.Kind := tpText;
  Result.Text := AText;
end;

function AttrPart(const AAttr: string; ACase: TTplCase; ATake: Integer; APlain: Boolean): TTplPart;
begin
  Result := Default(TTplPart);
  Result.Kind := tpAttr;
  Result.Text := AAttr;
  Result.CaseFn := ACase;
  Result.Take := ATake;
  Result.Plain := APlain;
end;

function CounterPart(const APrefix: string; ADigits: Integer; AOmitOne: Boolean): TTplPart;
begin
  Result := Default(TTplPart);
  Result.Kind := tpCounter;
  Result.Text := APrefix;
  Result.Take := ADigits;
  Result.OmitOne := AOmitOne;
end;

function CounterText(const APart: TTplPart; ACounter: Integer): string;
begin
  if APart.OmitOne and (ACounter <= 1) then Exit('');
  Result := IntToStr(ACounter);
  while Length(Result) < APart.Take do Result := '0' + Result;
  Result := APart.Text + Result;
end;

function TemplateCounterFields(const T: TEntryTemplate): TTplIndexes;
var
  marked: array of Boolean;
  changed: Boolean;
  i, j, target: Integer;
begin
  marked := nil;
  SetLength(marked, Length(T.Fields));
  // Point fixe borne par le nombre de champs: une boucle de reprises ne tourne pas sans fin.
  repeat
    changed := False;
    for i := 0 to High(T.Fields) do
    begin
      if marked[i] or (T.Fields[i].Source <> tsCompose) then Continue;
      for j := 0 to High(T.Fields[i].Parts) do
      begin
        if T.Fields[i].Parts[j].Kind = tpCounter then marked[i] := True
        else if T.Fields[i].Parts[j].Kind = tpAttr then
        begin
          target := FieldIndex(T, T.Fields[i].Parts[j].Text);
          if (target >= 0) and marked[target] then marked[i] := True;
        end;
      end;
      if marked[i] then changed := True;
    end;
  until not changed;
  Result := nil;
  for i := 0 to High(marked) do
    if marked[i] then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := i;
    end;
end;

function TemplateHasCounter(const T: TEntryTemplate): Boolean;
var
  i, j: Integer;
begin
  Result := False;
  for i := 0 to High(T.Fields) do
    if T.Fields[i].Source = tsCompose then
      for j := 0 to High(T.Fields[i].Parts) do
        if T.Fields[i].Parts[j].Kind = tpCounter then Exit(True);
end;

function NewField(const AAttr: string; ASource: TTplSource): TTplField;
begin
  Result := Default(TTplField);
  Result.Attr := AAttr;
  Result.Source := ASource;
end;

function SameAttr(const A, B: string): Boolean;
begin
  Result := AsciiLowerCase(AttrBaseName(A)) = AsciiLowerCase(AttrBaseName(B));
end;

function FieldIndex(const T: TEntryTemplate; const AAttr: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(T.Fields) do
    if SameAttr(T.Fields[i].Attr, AAttr) then Exit(i);
  Result := -1;
end;

function FieldCount(const T: TEntryTemplate; const AAttr: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(T.Fields) do
    if SameAttr(T.Fields[i].Attr, AAttr) then Inc(Result);
end;

function ComposedFrom(const T: TEntryTemplate; AIndex: Integer): string;
var
  i, j: Integer;
  hit: Boolean;
begin
  Result := '';
  if (AIndex < 0) or (AIndex > High(T.Fields)) then Exit;
  // Seule la premiere valeur d'un attribut est reprise par les compositions.
  if FieldIndex(T, T.Fields[AIndex].Attr) <> AIndex then Exit;
  for i := 0 to High(T.Fields) do
  begin
    if (i = AIndex) or (T.Fields[i].Source <> tsCompose) then Continue;
    hit := False;
    for j := 0 to High(T.Fields[i].Parts) do
      if (T.Fields[i].Parts[j].Kind = tpAttr) and
         SameAttr(T.Fields[i].Parts[j].Text, T.Fields[AIndex].Attr) then hit := True;
    if not hit then Continue;
    if Result <> '' then Result := Result + ', ';
    Result := Result + T.Fields[i].Attr;
  end;
end;

function DefaultPrompt(const AAttr: string): string;
var
  a: string;
begin
  a := AsciiLowerCase(AttrBaseName(AAttr));
  if a = 'givenname' then Result := rsTplPromptFirstName
  else if (a = 'sn') or (a = 'surname') then Result := rsTplPromptLastName
  else if (a = 'cn') or (a = 'ou') or (a = 'o') or (a = 'dc') then Result := rsTplPromptName
  else if (a = 'member') or (a = 'uniquemember') or (a = 'memberuid') then Result := rsTplPromptMember
  else if (a = 'uid') or (a = 'samaccountname') then Result := rsTplPromptLogin
  else if a = 'mail' then Result := rsTplPromptMail
  else if a = 'telephonenumber' then Result := rsTplPromptPhone
  else if a = 'mobile' then Result := rsTplPromptMobile
  else if a = 'description' then Result := rsTplPromptDescription
  else if a = 'title' then Result := rsTplPromptTitle
  else if a = 'displayname' then Result := rsTplPromptDisplayName
  else if (a = 'userpassword') or (a = 'unicodepwd') then Result := rsTplPromptPassword
  else Result := AttrBaseName(AAttr);
end;

function FieldPrompt(const F: TTplField): string;
begin
  Result := Trim(F.Prompt);
  if Result = '' then Result := DefaultPrompt(F.Attr);
end;

{ JSON }

function FieldToObject(const F: TTplField): TJSONObject;
var
  parts: TJSONArray;
  p: TJSONObject;
  i: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('attr', F.Attr);
  Result.Add('source', SOURCE_NAMES[F.Source]);
  if (F.Source in [tsFixed, tsCompose, tsRandom]) and (F.Scheme <> '') then Result.Add('scheme', F.Scheme);
  if F.Source = tsRandom then Result.Add('length', F.RandomLength);
  case F.Source of
    tsFixed: Result.Add('value', F.Value);
    tsAsk:
      begin
        Result.Add('prompt', F.Prompt);
        Result.Add('default', F.Value);
        Result.Add('optional', F.Optional);
      end;
    tsCompose:
      begin
        parts := TJSONArray.Create;
        for i := 0 to High(F.Parts) do
        begin
          p := TJSONObject.Create;
          if F.Parts[i].Kind = tpText then
            p.Add('text', F.Parts[i].Text)
          else if F.Parts[i].Kind = tpCounter then
          begin
            p.Add('counter', True);
            if F.Parts[i].Text <> '' then p.Add('prefix', F.Parts[i].Text);
            if F.Parts[i].Take > 0 then p.Add('digits', F.Parts[i].Take);
            if F.Parts[i].OmitOne then p.Add('omitOne', True);
          end
          else
          begin
            p.Add('attr', F.Parts[i].Text);
            if F.Parts[i].CaseFn <> tcAsIs then p.Add('case', CASE_NAMES[F.Parts[i].CaseFn]);
            if F.Parts[i].Take > 0 then p.Add('take', F.Parts[i].Take);
            if F.Parts[i].Plain then p.Add('plain', True);
          end;
          parts.Add(p);
        end;
        Result.Add('parts', parts);
      end;
    tsNumber:
      begin
        if F.NumberMode = tnFirstFree then Result.Add('mode', 'first-free')
        else Result.Add('mode', 'after-highest');
        if F.HasMin then Result.Add('min', F.Min);
        if F.HasMax then Result.Add('max', F.Max);
      end;
  end;
end;

function TemplateToJson(const T: TEntryTemplate): string;
var
  o, acc: TJSONObject;
  arr: TJSONArray;
  i: Integer;
begin
  o := TJSONObject.Create;
  try
    o.Add('version', TEMPLATE_VERSION);
    o.Add('name', T.Name);
    o.Add('description', T.Description);
    o.Add('origin', T.Origin);
    o.Add('structural', T.Structural);
    arr := TJSONArray.Create;
    for i := 0 to High(T.Auxiliaries) do arr.Add(T.Auxiliaries[i]);
    o.Add('auxiliary', arr);
    o.Add('rdn', T.RdnAttr);
    arr := TJSONArray.Create;
    for i := 0 to High(T.Fields) do arr.Add(FieldToObject(T.Fields[i]));
    o.Add('fields', arr);
    if Length(T.Groups) > 0 then
    begin
      arr := TJSONArray.Create;
      for i := 0 to High(T.Groups) do arr.Add(T.Groups[i]);
      o.Add('groups', arr);
    end;
    if T.Account.MustChange or T.Account.NeverExpires or T.Account.Disabled then
    begin
      acc := TJSONObject.Create;
      if T.Account.MustChange then acc.Add('mustChange', True);
      if T.Account.NeverExpires then acc.Add('neverExpires', True);
      if T.Account.Disabled then acc.Add('disabled', True);
      o.Add('account', acc);
    end;
    Result := o.AsJSON;
  finally
    o.Free;
  end;
end;

type
  ETemplateTooLong = class(Exception);

// Trop long: refuse, jamais raccourci; une valeur coupee se deploierait comme entiere.
function Bounded(const AValue, AKey: string; AMax: Integer): string;
begin
  if Length(AValue) > AMax then
    raise ETemplateTooLong.CreateFmt(rsTplFieldTooLong, [AKey, AMax]);
  Result := AValue;
end;

function Str(AObj: TJSONObject; const AKey: string; AMax: Integer = TEMPLATE_TEXT_MAX): string;
var
  d: TJSONData;
begin
  Result := '';
  d := AObj.Find(AKey);
  if (d <> nil) and (d is TJSONString) then Result := Bounded(d.AsString, AKey, AMax);
end;

function Flag(AObj: TJSONObject; const AKey: string): Boolean;
var
  d: TJSONData;
begin
  d := AObj.Find(AKey);
  Result := (d <> nil) and (d is TJSONBoolean) and d.AsBoolean;
end;

function Int(AObj: TJSONObject; const AKey: string; out AValue: Int64): Boolean;
var
  d: TJSONData;
begin
  AValue := 0;
  d := AObj.Find(AKey);
  Result := (d <> nil) and ((d is TJSONIntegerNumber) or (d is TJSONInt64Number));
  if Result then AValue := d.AsInt64;
end;

function FieldFromObject(AObj: TJSONObject; out F: TTplField): Boolean;
var
  s: string;
  src: TTplSource;
  c: TTplCase;
  d: TJSONData;
  arr: TJSONArray;
  p: TJSONObject;
  part: TTplPart;
  i: Integer;
  n: Int64;
begin
  Result := False;
  F := Default(TTplField);
  F.Attr := Trim(Str(AObj, 'attr', TEMPLATE_ATTR_MAX));
  if F.Attr = '' then Exit;
  s := Str(AObj, 'source', 32);
  for src := Low(TTplSource) to High(TTplSource) do
    if SOURCE_NAMES[src] = s then
    begin
      F.Source := src;
      Result := True;
    end;
  if not Result then Exit;
  if F.Source in [tsFixed, tsCompose, tsRandom] then F.Scheme := Trim(Str(AObj, 'scheme', TEMPLATE_SCHEME_MAX));
  if (F.Source = tsRandom) and Int(AObj, 'length', n) and (n >= RANDOM_PWD_MIN) and (n <= RANDOM_PWD_MAX) then
    F.RandomLength := n
  else if F.Source = tsRandom then
    F.RandomLength := RANDOM_PWD_DEFAULT;
  case F.Source of
    tsFixed: F.Value := Str(AObj, 'value');
    tsAsk:
      begin
        F.Prompt := Str(AObj, 'prompt', TEMPLATE_PROMPT_MAX);
        F.Value := Str(AObj, 'default');
        F.Optional := Flag(AObj, 'optional');
      end;
    tsCompose:
      begin
        d := AObj.Find('parts');
        if (d = nil) or not (d is TJSONArray) then Exit(False);
        arr := TJSONArray(d);
        if arr.Count > TEMPLATE_MAX_PARTS then Exit(False);
        for i := 0 to arr.Count - 1 do
        begin
          if not (arr[i] is TJSONObject) then Exit(False);
          p := TJSONObject(arr[i]);
          if Flag(p, 'counter') then
          begin
            part := CounterPart(Str(p, 'prefix', TEMPLATE_PROMPT_MAX));
            if Int(p, 'digits', n) and (n > 0) and (n <= TEMPLATE_COUNTER_DIGITS) then part.Take := n;
            part.OmitOne := Flag(p, 'omitOne');
          end
          else if p.Find('attr') <> nil then
          begin
            part := AttrPart(Trim(Str(p, 'attr', TEMPLATE_ATTR_MAX)));
            s := Str(p, 'case', 32);
            for c := Low(TTplCase) to High(TTplCase) do
              if CASE_NAMES[c] = s then part.CaseFn := c;
            if Int(p, 'take', n) and (n > 0) and (n <= TEMPLATE_MAX_TAKE) then part.Take := n;
            part.Plain := Flag(p, 'plain');
          end
          else
            part := TextPart(Str(p, 'text'));
          SetLength(F.Parts, Length(F.Parts) + 1);
          F.Parts[High(F.Parts)] := part;
        end;
      end;
    tsNumber:
      begin
        if Str(AObj, 'mode', 32) = 'first-free' then F.NumberMode := tnFirstFree;
        F.HasMin := Int(AObj, 'min', F.Min);
        F.HasMax := Int(AObj, 'max', F.Max);
        // Pas de "default" lu pour un numero: le meme uidNumber pour tout le monde, 0 de preference,
        // non merci.
      end;
  end;
end;

function TemplateFromJson(const AText: string; out T: TEntryTemplate; out AError: string): Boolean;
var
  data, d: TJSONData;
  o: TJSONObject;
  arr: TJSONArray;
  i: Integer;
  f: TTplField;
begin
  Result := False;
  T := Default(TEntryTemplate);
  AError := '';
  if Length(AText) > TEMPLATE_MAX_BYTES then
  begin
    AError := Format(rsTplTooLarge, [TEMPLATE_MAX_BYTES]);
    Exit;
  end;
  data := nil;
  try
    try
      data := SafeGetJSON(AText, 8);
    except
      on E: Exception do
      begin
        AError := Format(rsTplUnreadable, [E.Message]);
        Exit;
      end;
    end;
    if not (data is TJSONObject) then
    begin
      AError := Format(rsTplUnreadable, ['object']);
      Exit;
    end;
    o := TJSONObject(data);
    try
    d := o.Find('version');
    if (d = nil) or not (d is TJSONIntegerNumber) then
    begin
      AError := Format(rsTplUnreadable, ['version']);
      Exit;
    end;
    if d.AsInt64 > TEMPLATE_VERSION then
    begin
      AError := Format(rsTplFutureVersion, [d.AsInt64]);
      Exit;
    end;
    T.Name := Trim(Str(o, 'name', TEMPLATE_NAME_MAX));
    T.Description := Str(o, 'description', TEMPLATE_DESC_MAX);
    T.Origin := Str(o, 'origin', TEMPLATE_ORIGIN_MAX);
    T.Structural := Trim(Str(o, 'structural', TEMPLATE_ATTR_MAX));
    T.RdnAttr := Trim(Str(o, 'rdn', TEMPLATE_ATTR_MAX));
    d := o.Find('auxiliary');
    if (d <> nil) and (d is TJSONArray) then
    begin
      arr := TJSONArray(d);
      for i := 0 to arr.Count - 1 do
        if (arr[i] is TJSONString) and (Trim(arr[i].AsString) <> '') then
        begin
          if Length(T.Auxiliaries) >= TEMPLATE_MAX_CLASSES then
            raise ETemplateTooLong.CreateFmt(rsTplTooManyOf, [TEMPLATE_MAX_CLASSES, 'auxiliary']);
          SetLength(T.Auxiliaries, Length(T.Auxiliaries) + 1);
          T.Auxiliaries[High(T.Auxiliaries)] := Bounded(Trim(arr[i].AsString), 'auxiliary', TEMPLATE_ATTR_MAX);
        end;
    end;
    d := o.Find('fields');
    if (d = nil) or not (d is TJSONArray) then
    begin
      AError := Format(rsTplUnreadable, ['fields']);
      Exit;
    end;
    arr := TJSONArray(d);
    if arr.Count > TEMPLATE_MAX_FIELDS then
    begin
      AError := Format(rsTplTooMany, [TEMPLATE_MAX_FIELDS]);
      Exit;
    end;
    for i := 0 to arr.Count - 1 do
    begin
      if not (arr[i] is TJSONObject) or not FieldFromObject(TJSONObject(arr[i]), f) then
      begin
        AError := Format(rsTplUnreadable, [Format('fields[%d]', [i])]);
        Exit;
      end;
      SetLength(T.Fields, Length(T.Fields) + 1);
      T.Fields[High(T.Fields)] := f;
    end;
    d := o.Find('groups');
    if (d <> nil) and (d is TJSONArray) then
    begin
      arr := TJSONArray(d);
      for i := 0 to arr.Count - 1 do
        if (arr[i] is TJSONString) and (Trim(arr[i].AsString) <> '') then
        begin
          if Length(T.Groups) >= TEMPLATE_MAX_GROUPS then
            raise ETemplateTooLong.CreateFmt(rsTplTooManyOf, [TEMPLATE_MAX_GROUPS, 'groups']);
          SetLength(T.Groups, Length(T.Groups) + 1);
          T.Groups[High(T.Groups)] := Bounded(Trim(arr[i].AsString), 'groups', TEMPLATE_DN_MAX);
        end;
    end;
    d := o.Find('account');
    if (d <> nil) and (d is TJSONObject) then
    begin
      T.Account.MustChange := Flag(TJSONObject(d), 'mustChange');
      T.Account.NeverExpires := Flag(TJSONObject(d), 'neverExpires');
      T.Account.Disabled := Flag(TJSONObject(d), 'disabled');
    end;
    Result := True;
    except
      on E: ETemplateTooLong do
      begin
        T := Default(TEntryTemplate);
        AError := Format(rsTplUnreadable, [E.Message]);
        Result := False;
      end;
    end;
  finally
    data.Free;
  end;
end;

{ Composition }

function PlainAscii(const S: string): string;
var
  p, pEnd: PChar;
  len: Integer;
  cp: Cardinal;
  c: Char;
begin
  Result := '';
  if S = '' then Exit;
  p := PChar(S);
  pEnd := p + Length(S);
  while p < pEnd do
  begin
    cp := UTF8CodepointToUnicode(p, len);
    if len <= 0 then len := 1;
    if cp < 128 then
    begin
      c := Chr(cp);
      if c in ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-'] then Result := Result + c;
    end
    else if cp = $C6 then Result := Result + 'AE'
    else if cp = $E6 then Result := Result + 'ae'
    else if cp = $DE then Result := Result + 'TH'
    else if cp = $FE then Result := Result + 'th'
    else if cp = $DF then Result := Result + 'ss'
    else if cp = $152 then Result := Result + 'OE'
    else if cp = $153 then Result := Result + 'oe'
    else if (cp >= $C0) and (cp <= $FF) then
    begin
      c := LATIN1_BASE[cp - $C0 + 1];
      if c <> '?' then Result := Result + c;
    end
    else if (cp >= $100) and (cp <= $17F) then
      Result := Result + LATIN_A_BASE[cp - $100 + 1]
    else if (cp = $A0) or (cp = $2019) or (cp = $2018) or (cp = $202F) then
    else
      // Ecriture non latine: laissee telle quelle, le serveur jugera.
      Result := Result + Copy(S, p - PChar(S) + 1, len);
    Inc(p, len);
  end;
end;

function CapitalizeWords(const S: string): string;
var
  p, pEnd: PChar;
  len: Integer;
  ch: string;
  start: Boolean;
begin
  Result := '';
  if S = '' then Exit;
  p := PChar(S);
  pEnd := p + Length(S);
  start := True;
  while p < pEnd do
  begin
    len := UTF8CodepointSize(p);
    if len <= 0 then len := 1;
    SetString(ch, p, len);
    if start then Result := Result + UTF8UpperCase(ch) else Result := Result + UTF8LowerCase(ch);
    start := (len = 1) and (p^ in [' ', '-', '''', '.', '_', #9]);
    Inc(p, len);
  end;
end;

function ApplyPart(const APart: TTplPart; const AValue: string): string;
begin
  if APart.Kind = tpText then Exit(APart.Text);
  Result := AValue;
  if APart.Plain then Result := PlainAscii(Result);
  if APart.Take > 0 then Result := UTF8Copy(Result, 1, APart.Take);
  case APart.CaseFn of
    tcUpper: Result := UTF8UpperCase(Result);
    tcLower: Result := UTF8LowerCase(Result);
    tcCapital: Result := CapitalizeWords(Result);
  end;
end;

function TemplateOrder(const T: TEntryTemplate; out AOrder, ACycle: TTplIndexes): Boolean;
var
  state: array of Byte;
  stack: TTplIndexes;
  order, cycle: TTplIndexes;

  procedure Visit(AIndex: Integer);
  var
    k, j, target: Integer;
  begin
    if state[AIndex] = 2 then Exit;
    if state[AIndex] = 1 then
    begin
      if Length(cycle) = 0 then
        for k := 0 to High(stack) do
          if stack[k] = AIndex then
          begin
            cycle := Copy(stack, k, Length(stack) - k);
            Break;
          end;
      Exit;
    end;
    state[AIndex] := 1;
    SetLength(stack, Length(stack) + 1);
    stack[High(stack)] := AIndex;
    if T.Fields[AIndex].Source = tsCompose then
      for j := 0 to High(T.Fields[AIndex].Parts) do
        if T.Fields[AIndex].Parts[j].Kind = tpAttr then
        begin
          target := FieldIndex(T, T.Fields[AIndex].Parts[j].Text);
          if target >= 0 then Visit(target);
        end;
    SetLength(stack, Length(stack) - 1);
    state[AIndex] := 2;
    SetLength(order, Length(order) + 1);
    order[High(order)] := AIndex;
  end;

var
  i: Integer;
begin
  state := nil;
  SetLength(state, Length(T.Fields));
  stack := nil;
  order := nil;
  cycle := nil;
  for i := 0 to High(T.Fields) do Visit(i);
  AOrder := order;
  ACycle := cycle;
  Result := Length(cycle) = 0;
end;

procedure ComposeValues(const T: TEntryTemplate; var AValues: TStringArray;
  const AManual: array of Boolean);
var
  budget: Int64;
begin
  budget := TEMPLATE_COMPOSE_BUDGET;
  ComposeValuesWithin(T, AValues, AManual, budget);
end;

procedure ComposeValuesWithin(const T: TEntryTemplate; var AValues: TStringArray;
  const AManual: array of Boolean; var ABudget: Int64);
begin
  ComposeValuesCounted(T, AValues, AManual, 1, ABudget);
end;

procedure ComposeValuesCounted(const T: TEntryTemplate; var AValues: TStringArray;
  const AManual: array of Boolean; ACounter: Integer; var ABudget: Int64);
var
  order, cycle: TTplIndexes;
  i, j, k, target: Integer;
  v, src: string;
  inCycle: Boolean;
begin
  if Length(AValues) <> Length(T.Fields) then SetLength(AValues, Length(T.Fields));
  TemplateOrder(T, order, cycle);
  for i := 0 to High(order) do
  begin
    k := order[i];
    if T.Fields[k].Source <> tsCompose then Continue;
    if (k <= High(AManual)) and AManual[k] then Continue;
    inCycle := False;
    for j := 0 to High(cycle) do
      if cycle[j] = k then inCycle := True;
    if inCycle then
    begin
      AValues[k] := '';
      Continue;
    end;
    v := '';
    for j := 0 to High(T.Fields[k].Parts) do
    begin
      if Length(v) > TEMPLATE_TEXT_MAX then Break;
      if T.Fields[k].Parts[j].Kind = tpText then
        v := v + T.Fields[k].Parts[j].Text
      else if T.Fields[k].Parts[j].Kind = tpCounter then
        v := v + CounterText(T.Fields[k].Parts[j], ACounter)
      else
      begin
        target := FieldIndex(T, T.Fields[k].Parts[j].Text);
        if target < 0 then Continue;
        src := Copy(AValues[target], 1, TEMPLATE_TEXT_MAX + 1);
        Dec(ABudget, Length(src));
        if ABudget < 0 then
        begin
          // Budget epuise: marquee trop longue, on n'assemble plus rien.
          v := StringOfChar('?', TEMPLATE_TEXT_MAX + 1);
          Break;
        end;
        v := v + ApplyPart(T.Fields[k].Parts[j], src);
      end;
    end;
    if Length(v) > TEMPLATE_TEXT_MAX then SetLength(v, TEMPLATE_TEXT_MAX + 1);
    AValues[k] := v;
  end;
end;

function SampleFor(const AAttr: string): string;
var
  a: string;
begin
  a := AsciiLowerCase(AttrBaseName(AAttr));
  if a = 'givenname' then Result := 'Jean'
  else if (a = 'sn') or (a = 'surname') then Result := 'Dupont'
  else if (a = 'cn') or (a = 'displayname') then Result := 'Jean Dupont'
  else if (a = 'uid') or (a = 'samaccountname') then Result := 'jdupont'
  else if a = 'mail' then Result := 'jean.dupont@example.com'
  else if a = 'ou' then Result := 'Sales'
  else if a = 'o' then Result := 'Example'
  else if a = 'dc' then Result := 'example'
  else if a = 'l' then Result := 'Paris'
  else if a = 'initials' then Result := 'JD'
  else if a = 'employeenumber' then Result := '1042'
  else if a = 'telephonenumber' then Result := '+33 1 23 45 67 89'
  else Result := '';
end;

function SampleValues(const T: TEntryTemplate): TStringArray;
var
  i: Integer;
begin
  Result := nil;
  SetLength(Result, Length(T.Fields));
  for i := 0 to High(T.Fields) do
    case T.Fields[i].Source of
      tsFixed: Result[i] := T.Fields[i].Value;
      tsAsk:
        begin
          Result[i] := T.Fields[i].Value;
          if (Result[i] = '') and not ((SameAttr(T.Fields[i].Attr, 'cn') or
            SameAttr(T.Fields[i].Attr, 'displayName')) and (FieldIndex(T, 'sn') < 0)) then
            Result[i] := SampleFor(T.Fields[i].Attr);
          if Result[i] = '' then Result[i] := '<' + FieldPrompt(T.Fields[i]) + '>';
        end;
      tsNumber:
        if T.Fields[i].HasMin then Result[i] := IntToStr(T.Fields[i].Min)
        else Result[i] := '1000';
    end;
  ComposeValues(T, Result, []);
end;

{ Controle }

procedure AddIssue(var AIssues: TTplIssues; ASeverity: TIssueSeverity; AField: Integer;
  const AText: string);
begin
  SetLength(AIssues, Length(AIssues) + 1);
  AIssues[High(AIssues)].Severity := ASeverity;
  AIssues[High(AIssues)].Field := AField;
  AIssues[High(AIssues)].Text := AText;
end;

function TemplateHasErrors(const AIssues: TTplIssues): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AIssues) do
    if AIssues[i].Severity = isError then Exit(True);
  Result := False;
end;

function FirstTemplateError(const AIssues: TTplIssues): string;
var
  i: Integer;
begin
  for i := 0 to High(AIssues) do
    if AIssues[i].Severity = isError then Exit(AIssues[i].Text);
  Result := '';
end;

function IsRequiredAttr(const AAnalysis: TClassAnalysis; ASchema: TSchemaSnapshot;
  const AAttr: string): Boolean;
var
  ri: Integer;
begin
  ri := FindRequirement(AAnalysis, ASchema, AAttr);
  Result := (ri >= 0) and (AAnalysis.Requirements[ri].Kind = rqMust) and
    (AAnalysis.Requirements[ri].Supply = rsUser);
end;

function IsSecret(ASensitive: TSensitivePolicy; const AAttr: string): Boolean;
begin
  Result := (ASensitive <> nil) and ASensitive.IsSensitive(AAttr);
end;

function CyclePath(const T: TEntryTemplate; const ACycle: TTplIndexes): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(ACycle) do
    Result := Result + T.Fields[ACycle[i]].Attr + ' > ';
  if Length(ACycle) > 0 then Result := Result + T.Fields[ACycle[0]].Attr;
end;

function CheckTemplate(const T: TEntryTemplate; ASchema: TSchemaSnapshot; AProvider: TProviderKind;
  ASensitive: TSensitivePolicy; out AAnalysis: TClassAnalysis): TTplIssues;
var
  i, j, ri: Integer;
  f: TTplField;
  res: TValueResolution;
  err, rule: string;
  ok: Boolean;
  order, cycle, counted: TTplIndexes;
  req: TAttrRequirement;
  samples: TStringArray;

  procedure CheckText(AIndex: Integer; const AText: string);
  begin
    err := TemplateValueProblem(ASchema, AProvider, T.Fields[AIndex].Attr, AText);
    if err <> '' then
      AddIssue(Result, isError, AIndex, Format(rsTplValue, [T.Fields[AIndex].Attr, err]));
  end;

  // Un secret n'a pas de syntaxe a verifier: le hachage en fait des octets quelconques.
  procedure CheckParts(AIndex: Integer; const F: TTplField; ASecret: Boolean);
  var
    k, target, counters: Integer;
    allLiteral: Boolean;
    literal: string;
  begin
    counters := 0;
    if Length(F.Parts) = 0 then
      AddIssue(Result, isError, AIndex, Format(rsTplComposeEmpty, [F.Attr]));
    allLiteral := Length(F.Parts) > 0;
    literal := '';
    for k := 0 to High(F.Parts) do
    begin
      if F.Parts[k].Kind = tpText then
      begin
        literal := literal + F.Parts[k].Text;
        Continue;
      end;
      allLiteral := False;
      if F.Parts[k].Kind = tpCounter then
      begin
        Inc(counters);
        // Un mot de passe numerote, c'est un mot de passe qu'on devine au suivant.
        if ASecret then AddIssue(Result, isError, AIndex, Format(rsTplCounterSecret, [F.Attr]))
        else if counters = 2 then AddIssue(Result, isError, AIndex, Format(rsTplCounterTwice, [F.Attr]));
        Continue;
      end;
      if Trim(F.Parts[k].Text) = '' then
      begin
        AddIssue(Result, isError, AIndex, Format(rsTplPartNoAttr, [F.Attr]));
        Continue;
      end;
      target := FieldIndex(T, F.Parts[k].Text);
      if target < 0 then
        AddIssue(Result, isError, AIndex, Format(rsTplRefMissing, [F.Attr, F.Parts[k].Text]))
      else if IsSecret(ASensitive, F.Parts[k].Text) then
        AddIssue(Result, isError, AIndex, Format(rsTplRefSecret, [F.Attr, F.Parts[k].Text]))
      // Le premier accent dans une adresse ferait refuser l'entree.
      else if not ASecret and not F.Parts[k].Plain and (T.Fields[target].Source = tsAsk) and
        AttrIsAsciiOnly(ASchema, F.Attr) and not AttrIsAsciiOnly(ASchema, F.Parts[k].Text) then
        AddIssue(Result, isWarning, AIndex, Format(rsTplAsciiOnly, [F.Attr, F.Parts[k].Text]));
    end;
    if allLiteral then
    begin
      if literal = '' then AddIssue(Result, isError, AIndex, Format(rsTplFixedEmpty, [F.Attr]))
      else if not ASecret then CheckText(AIndex, literal);
    end;
  end;

  procedure CheckSecret(AIndex: Integer; const F: TTplField);
  var
    formats: TStringArray;
    k: Integer;
    known: Boolean;
    sch: TPasswordScheme;
  begin
    case F.Source of
      tsAsk:
        begin
          if F.Value <> '' then
            AddIssue(Result, isError, AIndex, Format(rsTplSecretAsk, [F.Attr]));
          Exit;
        end;
      tsNumber:
        begin
          AddIssue(Result, isError, AIndex, Format(rsTplSecretNumber, [F.Attr]));
          Exit;
        end;
    end;
    if not TemplatePasswordAttr(F.Attr, AProvider, ASchema) then
    begin
      AddIssue(Result, isError, AIndex, Format(rsTplPwdAttr, [F.Attr, TemplatePasswordAttrName(AProvider)]));
      Exit;
    end;
    // Format d'un autre serveur: stocke tel quel, personne ne s'y connecterait jamais.
    if F.Scheme = '' then
      AddIssue(Result, isError, AIndex, Format(rsTplPwdNoFormat, [F.Attr]))
    else
    begin
      formats := TemplatePasswordFormats(AProvider);
      known := False;
      for k := 0 to High(formats) do
        if SameText(formats[k], F.Scheme) then known := True;
      if not known then AddIssue(Result, isError, AIndex, Format(rsTplPwdFormat, [F.Attr, F.Scheme]));
    end;
    if F.Source = tsRandom then
    begin
      if (F.RandomLength < RANDOM_PWD_MIN) or (F.RandomLength > RANDOM_PWD_MAX) then
        AddIssue(Result, isError, AIndex, Format(rsTplRandomLength, [F.Attr, RANDOM_PWD_MIN, RANDOM_PWD_MAX]));
    end
    else if F.Source = tsFixed then
    begin
      if F.Value = '' then AddIssue(Result, isError, AIndex, Format(rsTplFixedEmpty, [F.Attr]))
      else if Length(F.Value) > TEMPLATE_TEXT_MAX then
        AddIssue(Result, isError, AIndex, Format(rsTplValue, [F.Attr, Format(rsTplValueTooLong, [TEMPLATE_TEXT_MAX])]))
      else if FindInvalidUTF8Codepoint(PChar(F.Value), Length(F.Value)) >= 0 then
        AddIssue(Result, isError, AIndex, Format(rsTplValue, [F.Attr, rsTplNotUtf8]));
    end
    else
      CheckParts(AIndex, F, True);
    sch := nil;
    if not SameText(F.Scheme, TEMPLATE_SCHEME_AD) then sch := PasswordRegistry.FindById(F.Scheme);
    if (sch <> nil) and (sch.Input = pinIdentity) then Exit;
    if (sch <> nil) and (sch.Recommendation = prCleartext) then
      AddIssue(Result, isWarning, AIndex, Format(rsTplPwdClear, [F.Attr]))
    else if F.Source = tsRandom then
    else if F.Source = tsFixed then
      AddIssue(Result, isWarning, AIndex, Format(rsTplPwdSame, [F.Attr]))
    else
      AddIssue(Result, isWarning, AIndex, Format(rsTplPwdDerived, [F.Attr]));
  end;

begin
  Result := nil;
  if Trim(T.Name) = '' then AddIssue(Result, isError, -1, rsTplNoName)
  else if Length(T.Name) > TEMPLATE_NAME_MAX then
    AddIssue(Result, isError, -1, Format(rsTplNameTooLong, [TEMPLATE_NAME_MAX]));
  if Length(T.Description) > TEMPLATE_DESC_MAX then
    AddIssue(Result, isError, -1, Format(rsTplTooLongFor, [rsTplWhatDescription, TEMPLATE_DESC_MAX]));
  for i := 0 to High(T.Groups) do
    if Length(T.Groups[i]) > TEMPLATE_DN_MAX then
      AddIssue(Result, isError, -1, Format(rsTplTooLongFor, [rsTplWhatGroup, TEMPLATE_DN_MAX]));
  // En tete: un modele LDAP juge selon AD n'accumulerait que des erreurs qui ne le concernent pas.
  if not TemplateFitsProvider(T, AProvider) then
    AddIssue(Result, isError, -1, Format(rsTplOtherFamily, [T.Origin, ServerKindName(AProvider)]));
  for i := 0 to High(T.Fields) do
  begin
    if Length(T.Fields[i].Prompt) > TEMPLATE_PROMPT_MAX then
      AddIssue(Result, isError, i, Format(rsTplTooLongFor, [rsTplWhatLabel, TEMPLATE_PROMPT_MAX]));
    for j := 0 to High(T.Fields[i].Parts) do
      if (T.Fields[i].Parts[j].Kind = tpText) and (Length(T.Fields[i].Parts[j].Text) > TEMPLATE_TEXT_MAX) then
        AddIssue(Result, isError, i, Format(rsTplTooLongFor, [rsTplWhatText, TEMPLATE_TEXT_MAX]));
  end;
  if T.Structural = '' then
  begin
    AAnalysis := Default(TClassAnalysis);
    AddIssue(Result, isError, -1, rsCpNoStructural);
  end
  else
    AAnalysis := AnalyzeClasses(ASchema, [T.Structural], T.Auxiliaries, AProvider);
  for i := 0 to High(AAnalysis.Issues) do
    AddIssue(Result, AAnalysis.Issues[i].Severity, -1, AAnalysis.Issues[i].Text);
  if Length(T.Fields) > TEMPLATE_MAX_FIELDS then
    AddIssue(Result, isError, -1, Format(rsTplTooMany, [TEMPLATE_MAX_FIELDS]));
  if not AAnalysis.Ok then Exit;

  if T.RdnAttr = '' then AddIssue(Result, isError, -1, rsTplNoRdn)
  else if FieldIndex(T, T.RdnAttr) < 0 then AddIssue(Result, isError, -1, rsTplNoRdn)
  else if IsSecret(ASensitive, T.RdnAttr) then
    AddIssue(Result, isError, FieldIndex(T, T.RdnAttr), Format(rsTplRdnSecret, [T.RdnAttr]));

  for i := 0 to High(T.Fields) do
  begin
    f := T.Fields[i];
    if Trim(f.Attr) = '' then
    begin
      AddIssue(Result, isError, i, rsTplNoAttr);
      Continue;
    end;
    if SameAttr(f.Attr, 'objectClass') then
    begin
      AddIssue(Result, isError, i, rsTplObjectClass);
      Continue;
    end;
    ri := FindRequirement(AAnalysis, ASchema, f.Attr);
    if IsPrecluded(AAnalysis, ASchema, f.Attr) then
      AddIssue(Result, isError, i, Format(rsCpPrecluded, [f.Attr, AAnalysis.ContentRule]))
    else if (ri < 0) and not AAnalysis.ExtensibleObject then
    begin
      if AAnalysis.AllowedIncomplete then
        AddIssue(Result, isWarning, i, Format(rsCpNotAllowedMaybe, [f.Attr]))
      else
        AddIssue(Result, isError, i, Format(rsCpNotAllowed, [f.Attr]));
    end;
    if AdRefusesOnAdd(AProvider, f.Attr) then
    begin
      AddIssue(Result, isError, i, Format(rsCpAdOnAdd, [f.Attr]));
      Continue;
    end;
    res := ResolveValueKind(ASchema, f.Attr, AProvider);
    if res.ReadOnly then
      AddIssue(Result, isError, i, Format(rsCpReadOnly, [f.Attr, res.ReadOnlyReason]))
    else if IsServerGeneratedOnCreate(AProvider, f.Attr, rule) and
      not SameAttr(f.Attr, 'sAMAccountName') then
      AddIssue(Result, isWarning, i, Format(rsCpOverride, [f.Attr]));
    if res.SingleValued and (FieldIndex(T, f.Attr) <> i) then
      AddIssue(Result, isError, i, Format(rsTplSingle, [f.Attr]));
    if IsSecret(ASensitive, f.Attr) then
    begin
      CheckSecret(i, f);
      Continue;
    end;
    if not TemplateCanHold(res.Kind) then
    begin
      AddIssue(Result, isError, i, Format(rsTplNotText, [f.Attr, ValueKindName(res.Kind)]));
      Continue;
    end;
    case f.Source of
      tsFixed:
        if f.Value = '' then AddIssue(Result, isError, i, Format(rsTplFixedEmpty, [f.Attr]))
        else CheckText(i, f.Value);
      tsAsk:
        if f.Value <> '' then CheckText(i, f.Value);
      tsCompose: CheckParts(i, f, False);
      tsRandom: AddIssue(Result, isError, i, Format(rsTplRandomNotPwd, [f.Attr]));
      tsNumber:
        begin
          if res.Kind <> vkInteger then
            AddIssue(Result, isError, i, Format(rsTplNumberKind, [f.Attr]));
          // Une plage d'un seul numero sert une fois, puis bloque tout le monde.
          if f.HasMin and f.HasMax and (f.Min >= f.Max) then
            AddIssue(Result, isError, i, Format(rsTplRange, [f.Attr]));
          // Un modele bricole hors de l'editeur ne fait pas passer un numero en douce.
          if f.Value <> '' then
            AddIssue(Result, isError, i, Format(rsTplNumberDefault, [f.Attr]));
        end;
    end;
  end;

  for i := 0 to High(AAnalysis.Requirements) do
  begin
    req := AAnalysis.Requirements[i];
    if req.Kind <> rqMust then Continue;
    ok := False;
    for j := 0 to High(T.Fields) do
      if FindRequirement(AAnalysis, ASchema, T.Fields[j].Attr) = i then ok := True;
    case req.Supply of
      rsUser:
        // AD: unicodePwd ne s'exige pas a la creation; un compte sans lui nait desactive.
        if not ok and not ((AProvider = pkActiveDirectory) and IsSecret(ASensitive, req.Name)) then
          AddIssue(Result, isError, -1, Format(rsCpMissing, [req.Name, req.Origin]));
      rsServerOnly:
        AddIssue(Result, isWarning, -1, Format(rsCpServerOnlyRequired, [req.Name, req.Origin]));
    end;
  end;

  if not TemplateOrder(T, order, cycle) then
    for i := 0 to High(cycle) do
      AddIssue(Result, isError, cycle[i], Format(rsTplCycle, [CyclePath(T, cycle)]));
  // Si ca deborde avec "Jean Dupont", ca debordera avec tout le monde.
  samples := SampleValues(T);
  for i := 0 to High(T.Fields) do
    if (T.Fields[i].Source = tsCompose) and (i <= High(samples)) and
       (Length(samples[i]) > TEMPLATE_TEXT_MAX) then
      AddIssue(Result, isError, i, Format(rsTplComposeTooLong, [T.Fields[i].Attr, TEMPLATE_TEXT_MAX]));
  if TemplateHasCounter(T) and (FieldIndex(T, T.RdnAttr) >= 0) then
  begin
    counted := TemplateCounterFields(T);
    ok := False;
    for i := 0 to High(counted) do
      if counted[i] = FieldIndex(T, T.RdnAttr) then ok := True;
    if not ok then
      AddIssue(Result, isWarning, FieldIndex(T, T.RdnAttr), Format(rsTplRdnNoCounter, [T.RdnAttr]));
  end;
  if T.Account.MustChange or T.Account.NeverExpires or T.Account.Disabled then
  begin
    if not TemplateIsAdUser(AAnalysis, AProvider) or not TemplateDesignedForAd(T) then
      AddIssue(Result, isWarning, -1, rsTplAccountNotAd)
    else if T.Account.MustChange and T.Account.NeverExpires then
      AddIssue(Result, isWarning, -1, rsTplAccountBoth);
  end;
end;

function TemplatePasswordAttrName(AProvider: TProviderKind): string;
begin
  if AProvider = pkActiveDirectory then Result := 'unicodePwd' else Result := 'userPassword';
end;

function TemplatePasswordAttr(const AAttr: string; AProvider: TProviderKind;
  ASchema: TSchemaSnapshot): Boolean;
var
  a: string;
  at: TSchemaAttributeType;
begin
  a := AttrBaseName(AAttr);
  if ASchema <> nil then
  begin
    at := ASchema.AttributeType(a);
    if at <> nil then a := at.PrimaryName;
  end;
  Result := SameText(a, TemplatePasswordAttrName(AProvider));
end;

function PwdServerOfProvider(AProvider: TProviderKind): TPwdServer;
begin
  case AProvider of
    pkOpenLdap: Result := pwsOpenLdap;
    pk389Ds: Result := pws389Ds;
    pkApacheDs: Result := pwsApacheDs;
    pkActiveDirectory: Result := pwsActiveDirectory;
  else
    Result := pwsOther;
  end;
end;

function TemplatePasswordFormats(AProvider: TProviderKind): TStringArray;
var
  ids: TStringArray;
  i, n: Integer;
  sch: TPasswordScheme;
begin
  if AProvider = pkActiveDirectory then Exit([TEMPLATE_SCHEME_AD]);
  ids := PasswordRegistry.GeneratorIds(PwdServerOfProvider(AProvider));
  Result := nil;
  SetLength(Result, Length(ids));
  n := 0;
  for i := 0 to High(ids) do
  begin
    sch := PasswordRegistry.FindById(ids[i]);
    // {K5KEY} ne prend rien: rien a fixer, rien a composer.
    if (sch = nil) or (sch.Input = pinNone) then Continue;
    Result[n] := ids[i];
    Inc(n);
  end;
  SetLength(Result, n);
end;

function TemplateDefaultFormat(AProvider: TProviderKind): string;
var
  formats: TStringArray;
  i: Integer;
begin
  formats := TemplatePasswordFormats(AProvider);
  Result := '';
  if Length(formats) > 0 then Result := formats[0];
  for i := 0 to High(formats) do
    if SameText(formats[i], DEFAULT_GENERATOR_ID) then Exit(formats[i]);
end;

function TemplateSecretShown(const F: TTplField): Boolean;
var
  sch: TPasswordScheme;
begin
  sch := nil;
  if (F.Scheme <> '') and not SameText(F.Scheme, TEMPLATE_SCHEME_AD) then
    sch := PasswordRegistry.FindById(F.Scheme);
  Result := (sch <> nil) and (sch.Input = pinIdentity);
end;

function TemplateDesignedForAd(const T: TEntryTemplate): Boolean;
begin
  Result := SameText(T.Origin, ServerKindName(pkActiveDirectory));
end;

function TemplateFitsProvider(const T: TEntryTemplate; AProvider: TProviderKind): Boolean;
begin
  Result := (T.Origin = '') or (AProvider = pkAuto) or
    (TemplateDesignedForAd(T) = (AProvider = pkActiveDirectory));
end;

function TemplateIsAdUser(const AAnalysis: TClassAnalysis; AProvider: TProviderKind): Boolean;
var
  i: Integer;
begin
  Result := IsAdAccount(AAnalysis, AProvider);
  if Result then
    for i := 0 to High(AAnalysis.ObjectClasses) do
      if SameText(AAnalysis.ObjectClasses[i], 'computer') then Exit(False);
end;

function TemplatePolicyIssues(const T: TEntryTemplate; const APolicy: TAdPwdPolicy): TTplIssues;
var
  samples: TStringArray;
  i, ai, di: Integer;
  account, display, err: string;
begin
  Result := nil;
  if not APolicy.Known then Exit;
  samples := SampleValues(T);
  account := '';
  display := '';
  ai := FieldIndex(T, 'sAMAccountName');
  di := FieldIndex(T, 'displayName');
  if (ai >= 0) and (ai <= High(samples)) then account := samples[ai];
  if (di >= 0) and (di <= High(samples)) then display := samples[di];
  for i := 0 to High(T.Fields) do
  begin
    if not SameAttr(T.Fields[i].Attr, 'unicodePwd') then Continue;
    case T.Fields[i].Source of
      tsFixed:
        begin
          err := AdPasswordProblem(T.Fields[i].Value, APolicy, '', '');
          if err <> '' then AddIssue(Result, isWarning, i, Format(rsTplPolicy, [T.Fields[i].Attr, err]));
        end;
      tsCompose:
        if i <= High(samples) then
        begin
          err := AdPasswordProblem(samples[i], APolicy, account, display);
          if err <> '' then
            AddIssue(Result, isWarning, i, Format(rsTplPolicySample, [T.Fields[i].Attr, samples[i], err]));
        end;
      tsRandom:
        if T.Fields[i].RandomLength < APolicy.MinLength then
          AddIssue(Result, isWarning, i, Format(rsTplPolicyRandom, [T.Fields[i].Attr, APolicy.MinLength]));
    end;
  end;
end;

function TemplatePasswordField(const F: TTplField; ASensitive: TSensitivePolicy): Boolean;
begin
  Result := ((F.Scheme <> '') and not TemplateSecretShown(F)) or IsBuiltinSensitiveAttr(F.Attr) or
    ((ASensitive <> nil) and ASensitive.IsSensitive(F.Attr));
end;

function TemplateSecretInClear(const F: TTplField; ASensitive: TSensitivePolicy): Boolean;
var
  i: Integer;
begin
  Result := False;
  if not TemplatePasswordField(F, ASensitive) then Exit;
  case F.Source of
    tsFixed: Result := F.Value <> '';
    tsCompose:
      for i := 0 to High(F.Parts) do
        if (F.Parts[i].Kind = tpText) and (F.Parts[i].Text <> '') then Exit(True);
  end;
end;

procedure TemplateDropSecret(var F: TTplField);
begin
  // Retirer les seuls textes d'une composition changerait le mot de passe sans le dire.
  F.Source := tsFixed;
  F.Value := '';
  F.Parts := nil;
end;

function TemplateCanHold(AKind: TValueKind): Boolean;
begin
  Result := AKind in [vkText, vkBoolean, vkInteger, vkDn, vkGeneralizedTime, vkAdFileTime,
    vkAdInterval];
end;

function TemplateValueProblem(ASchema: TSchemaSnapshot; AProvider: TProviderKind;
  const AAttr, AText: string): string;
var
  res: TValueResolution;
  bytes: RawByteString;
  syn: string;
  maxLen: Integer;
begin
  if Length(AText) > TEMPLATE_TEXT_MAX then Exit(Format(rsTplValueTooLong, [TEMPLATE_TEXT_MAX]));
  Result := '';
  res := ResolveValueKind(ASchema, AAttr, AProvider);
  if not EncodeTyped(res, AText, '', bytes, Result) then Exit;
  Result := '';
  if ASchema = nil then Exit;
  syn := EffectiveSyntaxAndLen(ASchema, AAttr, maxLen);
  if (syn <> '') and IsSyntaxChecked(syn) then Result := CheckSyntaxValue(syn, maxLen, bytes);
end;

function AttrIsAsciiOnly(ASchema: TSchemaSnapshot; const AAttr: string): Boolean;
begin
  Result := (ASchema <> nil) and
    (ASchema.EffectiveSyntax(AttrBaseName(AAttr)) = '1.3.6.1.4.1.1466.115.121.1.26');
end;

function BuildTemplateEntry(const T: TEntryTemplate; const AValues: array of string;
  const AParentDn: string; ASchema: TSchemaSnapshot; AProvider: TProviderKind;
  ASensitive: TSensitivePolicy; const AAnalysis: TClassAnalysis; out AProblem: string;
  const ALater: TStringArray): TLdapEntry;
var
  plan: TEntryCreationPlan;
  issues: TPlanIssues;
  i, ri: Integer;
  res: TValueResolution;
  bytes: RawByteString;
  err: string;
begin
  Result := nil;
  AProblem := '';
  ri := FieldIndex(T, T.RdnAttr);
  if (ri < 0) or (ri > High(AValues)) or (AValues[ri] = '') then
  begin
    AProblem := rsTplNoRdn;
    if (ri >= 0) and (ri <= High(AValues)) then AProblem := Format(rsCpRdnEmpty, [T.RdnAttr]);
    Exit;
  end;
  err := TemplateValueProblem(ASchema, AProvider, T.RdnAttr, AValues[ri]);
  if err <> '' then
  begin
    AProblem := Format(rsTplValue, [T.RdnAttr, err]);
    Exit;
  end;
  plan := TEntryCreationPlan.Create;
  try
    plan.Provider := AProvider;
    plan.ParentDn := AParentDn;
    plan.Structural := [T.Structural];
    plan.Auxiliaries := Copy(T.Auxiliaries, 0, Length(T.Auxiliaries));
    plan.SetRdn(T.RdnAttr, AValues[ri]);
    for i := 0 to High(T.Fields) do
    begin
      if (i = ri) or (i > High(AValues)) or (AValues[i] = '') then Continue;
      if (ASensitive <> nil) and ASensitive.IsSensitive(T.Fields[i].Attr) then Continue;
      err := TemplateValueProblem(ASchema, AProvider, T.Fields[i].Attr, AValues[i]);
      if err <> '' then
      begin
        AProblem := Format(rsTplValue, [T.Fields[i].Attr, err]);
        Exit;
      end;
      res := ResolveValueKind(ASchema, T.Fields[i].Attr, AProvider);
      if not EncodeTyped(res, AValues[i], '', bytes, err) then
      begin
        AProblem := Format(rsTplValue, [T.Fields[i].Attr, err]);
        Exit;
      end;
      plan.Values.Ensure(T.Fields[i].Attr).AddValue(bytes);
    end;
    // AD: avec le mot de passe, tout part dans l'ajout; sans, compte desactive et etapes a part.
    if AProvider = pkActiveDirectory then
    begin
      for i := 0 to High(ALater) do
        if SameAttr(ALater[i], 'unicodePwd') then plan.AdPasswordInAdd := True;
      // Options d'un compte utilisateur: un modele devenu ordinateur ne les traine pas avec lui.
      plan.AdAccountOptions := TemplateIsAdUser(AAnalysis, AProvider) and TemplateDesignedForAd(T);
      plan.AdMustChange := plan.AdAccountOptions and T.Account.MustChange;
      plan.AdNeverExpires := plan.AdAccountOptions and T.Account.NeverExpires;
      plan.AdDisabled := plan.AdAccountOptions and T.Account.Disabled;
    end;
    // Bouche-trou le temps du controle, retire aussitot: le vrai hache arrive a l'envoi.
    for i := 0 to High(ALater) do
    begin
      plan.Values.Ensure(ALater[i]).AddValue(#0);
      SetLength(plan.ComputedSecrets, Length(plan.ComputedSecrets) + 1);
      plan.ComputedSecrets[High(plan.ComputedSecrets)] := AttrBaseName(ALater[i]);
    end;
    Result := BuildCreationEntry(ASchema, plan, AAnalysis, ASensitive, issues);
    if Result <> nil then
      for i := 0 to High(ALater) do
        Result.Remove(ALater[i]);
    if Result = nil then
      for i := 0 to High(issues) do
        if issues[i].Severity = isError then
        begin
          AProblem := issues[i].Text;
          Break;
        end;
  finally
    plan.Free;
  end;
end;

function TemplateAttributeChoices(const AAnalysis: TClassAnalysis; ASchema: TSchemaSnapshot;
  AProvider: TProviderKind; ASensitive: TSensitivePolicy): TStringArray;
var
  i: Integer;
  list: TStringList;
  r: TAttrRequirement;
begin
  Result := nil;
  list := TStringList.Create;
  try
    list.CaseSensitive := False;
    for i := 0 to High(AAnalysis.Requirements) do
    begin
      r := AAnalysis.Requirements[i];
      if not ((r.Supply = rsUser) or
        ((r.Supply = rsServerGenerated) and SameAttr(r.Name, 'sAMAccountName'))) then Continue;
      if IsSecret(ASensitive, r.Name) then
      begin
        if (AProvider = pkActiveDirectory) and not TemplatePasswordAttr(r.Name, AProvider, ASchema) then
          Continue;
      end
      else if not TemplateCanHold(ResolveValueKind(ASchema, r.Name, AProvider).Kind) then
        Continue;
      list.Add(r.Name);
    end;
    list.Sort;
    SetLength(Result, list.Count);
    for i := 0 to list.Count - 1 do Result[i] := list[i];
  finally
    list.Free;
  end;
end;

function SyncRequiredFields(var T: TEntryTemplate; ASchema: TSchemaSnapshot;
  AProvider: TProviderKind; ASensitive: TSensitivePolicy): Integer;
var
  a: TClassAnalysis;
  i, j: Integer;
  req: TAttrRequirement;
  present: Boolean;
  f: TTplField;
  def: string;
begin
  Result := 0;
  if (ASchema = nil) or (T.Structural = '') then Exit;
  a := AnalyzeClasses(ASchema, [T.Structural], T.Auxiliaries, AProvider);
  if not a.Ok then Exit;
  for i := 0 to High(a.Requirements) do
  begin
    req := a.Requirements[i];
    if (req.Kind <> rqMust) or (req.Supply <> rsUser) then Continue;
    if IsSecret(ASensitive, req.Name) and (AProvider = pkActiveDirectory) then Continue;
    present := False;
    for j := 0 to High(T.Fields) do
      if FindRequirement(a, ASchema, T.Fields[j].Attr) = i then present := True;
    if present or (Length(T.Fields) >= TEMPLATE_MAX_FIELDS) then Continue;
    f := NewField(req.Name, tsAsk);
    if SameAttr(req.Name, 'uidNumber') then f.Source := tsNumber;
    SetLength(T.Fields, Length(T.Fields) + 1);
    T.Fields[High(T.Fields)] := f;
    Inc(Result);
  end;
  if (T.RdnAttr = '') or (FieldIndex(T, T.RdnAttr) < 0) then
  begin
    def := DefaultRdnAttribute(a);
    if (def <> '') and (FieldIndex(T, def) < 0) and not IsSecret(ASensitive, def) and
       (Length(T.Fields) < TEMPLATE_MAX_FIELDS) then
    begin
      SetLength(T.Fields, Length(T.Fields) + 1);
      T.Fields[High(T.Fields)] := NewField(def, tsAsk);
      Inc(Result);
    end;
    if def <> '' then T.RdnAttr := def
    else if Length(T.Fields) > 0 then T.RdnAttr := T.Fields[0].Attr;
  end;
end;

{ Depuis une entree }

type
  TSourceValue = record
    Attr: string;
    Value: string;
  end;
  TSourceValues = array of TSourceValue;

function MatchAt(const AText: string; APos: Integer; const ANeedle: string): Boolean;
begin
  Result := (ANeedle <> '') and (APos + Length(ANeedle) - 1 <= Length(AText)) and
    (CompareByte(AText[APos], ANeedle[1], Length(ANeedle)) = 0);
end;

// La plus longue correspondance gagne, le reste devient du texte fixe.
type
  TShaped = record
    Part: TTplPart;
    Text: string;
  end;
  TShapedList = array of TShaped;

// Formes d'une valeur source (casse, accents), calculees une fois, la plus simple d'abord.
function ShapedVariants(const ASrc: TSourceValue; ATake: Integer): TShapedList;
const
  CASES: array[0..2] of TTplCase = (tcAsIs, tcLower, tcUpper);
var
  pl: Boolean;
  m, k, n: Integer;
  p: TTplPart;
  sh: string;
  dup: Boolean;
begin
  Result := nil;
  SetLength(Result, 2 * Length(CASES));
  n := 0;
  for pl := False to True do
    for m := 0 to High(CASES) do
    begin
      p := AttrPart(ASrc.Attr, CASES[m], ATake, pl);
      sh := ApplyPart(p, ASrc.Value);
      if sh = '' then Continue;
      dup := False;
      for k := 0 to n - 1 do
        if Result[k].Text = sh then dup := True;
      if dup then Continue;
      Result[n].Part := p;
      Result[n].Text := sh;
      Inc(n);
    end;
  SetLength(Result, n);
end;

// ABudget: comparaisons restantes pour toute l'entree. Epuise, la valeur reste une valeur fixe:
// une description de 4 Ko confrontee a 250 sources ne doit pas figer l'interface.
function DeriveParts(const AValue: string; const ASources: TSourceValues;
  out AParts: TTplParts; var ABudget: Int64): Boolean;
var
  full, init: array of TShapedList;
  i, s, k, bestLen, len: Integer;
  best: TTplPart;
  literal: string;
  found: Boolean;

  procedure Flush;
  begin
    if literal = '' then Exit;
    SetLength(AParts, Length(AParts) + 1);
    AParts[High(AParts)] := TextPart(literal);
    literal := '';
  end;

  function Matches(APos: Integer; const AText: string): Boolean;
  begin
    Dec(ABudget);
    Result := MatchAt(AValue, APos, AText);
  end;

  function FullMatch(APos: Integer; AExcept: Integer; out APart: TTplPart): Integer;
  var
    k, m: Integer;
  begin
    Result := 0;
    APart := Default(TTplPart);
    for k := 0 to High(full) do
    begin
      if k = AExcept then Continue;
      for m := 0 to High(full[k]) do
        if (Length(full[k][m].Text) > Result) and Matches(APos, full[k][m].Text) then
        begin
          Result := Length(full[k][m].Text);
          APart := full[k][m].Part;
        end;
    end;
  end;

begin
  AParts := nil;
  Result := False;
  full := nil;
  init := nil;
  SetLength(full, Length(ASources));
  SetLength(init, Length(ASources));
  for s := 0 to High(ASources) do
    if UTF8Length(ASources[s].Value) >= 2 then
    begin
      full[s] := ShapedVariants(ASources[s], 0);
      init[s] := ShapedVariants(ASources[s], 1);
    end;
  literal := '';
  i := 1;
  while (i <= Length(AValue)) and (Length(AParts) < TEMPLATE_MAX_PARTS - 2) do
  begin
    if ABudget <= 0 then
    begin
      AParts := nil;
      Exit(False);
    end;
    bestLen := FullMatch(i, -1, best);
    if bestLen = 0 then
      // Initiale suivie d'une valeur entiere: jdupont.
      for s := 0 to High(init) do
      begin
        if bestLen > 0 then Break;
        for k := 0 to High(init[s]) do
        begin
          if bestLen > 0 then Break;
          if not Matches(i, init[s][k].Text) then Continue;
          len := FullMatch(i + Length(init[s][k].Text), s, best);
          if len > 0 then
          begin
            bestLen := Length(init[s][k].Text);
            best := init[s][k].Part;
          end;
        end;
      end;
    if bestLen > 0 then
    begin
      Flush;
      SetLength(AParts, Length(AParts) + 1);
      AParts[High(AParts)] := best;
      Inc(i, bestLen);
      Result := True;
    end
    else
    begin
      literal := literal + AValue[i];
      Inc(i);
    end;
  end;
  if i <= Length(AValue) then literal := literal + Copy(AValue, i, MaxInt);
  Flush;
  found := Result;
  if not found then AParts := nil;
end;

function InList(const AName: string; const AList: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AList) do
    if SameAttr(AList[i], AName) then Exit(True);
  Result := False;
end;

function TemplateFromEntry(AEntry: TLdapEntry; ASchema: TSchemaSnapshot; AProvider: TProviderKind;
  ASensitive: TSensitivePolicy; out T: TEntryTemplate; out ASkipped: TStringArray;
  out AError: string): Boolean;
const
  FIRST: array[0..7] of string = ('givenName', 'sn', 'uid', 'sAMAccountName', 'cn', 'displayName',
    'mail', 'ou');
var
  oc, attr: TLdapAttribute;
  cls: TSchemaObjectClass;
  chain: TStringArray;
  issue, rdnAttr: string;
  i, j, best, bestLen: Integer;
  analysis: TClassAnalysis;
  adUser: Boolean;
  uac: Int64;
  sources: TSourceValues;
  done: TStringList;
  res: TValueResolution;
  rule: string;
  cloneOpts: TCloneOptions;
  budget: Int64;

  procedure Skip(const AAttr, AWhy: string);
  begin
    SetLength(ASkipped, Length(ASkipped) + 1);
    ASkipped[High(ASkipped)] := AAttr + ' (' + AWhy + ')';
  end;

  // Faux: le modele est plein. A l'appelant de dire ce qui reste dehors.
  function Push(const F: TTplField): Boolean;
  begin
    Result := Length(T.Fields) < TEMPLATE_MAX_FIELDS;
    if not Result then Exit;
    SetLength(T.Fields, Length(T.Fields) + 1);
    T.Fields[High(T.Fields)] := F;
  end;

  procedure Learn(const AAttr, AValue: string);
  begin
    SetLength(sources, Length(sources) + 1);
    sources[High(sources)].Attr := AAttr;
    sources[High(sources)].Value := AValue;
  end;

  procedure Take(AAttr: TLdapAttribute);
  var
    k, ri, m: Integer;
    f: TTplField;
    parts: TTplParts;
    v, canon: string;
    isRdn, must, primary: Boolean;
  begin
    if done.IndexOf(AsciiLowerCase(AAttr.BaseName)) >= 0 then Exit;
    done.Add(AsciiLowerCase(AAttr.BaseName));
    if SameAttr(AAttr.BaseName, 'objectClass') or (AAttr.ValueCount = 0) then Exit;
    ri := FindRequirement(analysis, ASchema, AAttr.Description);
    canon := AAttr.BaseName;
    if ri >= 0 then canon := analysis.Requirements[ri].Name;
    res := ResolveValueKind(ASchema, AAttr.Description, AProvider);
    // Memes exclusions que pour un clone: ce que le serveur tient lui-meme.
    if not (CloneExclusion(AAttr.Description, cloneOpts) in [crKept, crSecret]) or
       (ASchema.IsOperational(AAttr.BaseName)) or res.ReadOnly or
       ((ri >= 0) and (analysis.Requirements[ri].Supply = rsServerOnly)) or
       (IsServerGeneratedOnCreate(AProvider, AAttr.BaseName, rule) and
        not SameAttr(AAttr.BaseName, 'sAMAccountName')) or
       ((ri < 0) and not analysis.ExtensibleObject and not analysis.AllowedIncomplete) then
    begin
      Skip(AAttr.Description, rsTplSkipServer);
      Exit;
    end;
    // Les bits utiles de userAccountControl deviennent les options du compte; le reste, AD le pose.
    if adUser and SameAttr(canon, 'userAccountControl') then
    begin
      if TryStrToInt64(Trim(string(AAttr.Values[0])), uac) then
      begin
        T.Account.NeverExpires := uac and AD_UF_DONT_EXPIRE_PASSWD <> 0;
        T.Account.Disabled := uac and CREATE_UF_ACCOUNTDISABLE <> 0;
      end;
      Skip(AAttr.Description, rsTplSkipAccount);
      Exit;
    end;
    isRdn := SameAttr(canon, rdnAttr);
    must := (ri >= 0) and (analysis.Requirements[ri].Kind = rqMust);
    if (ASensitive <> nil) and ASensitive.IsSensitive(AAttr.Description) then
    begin
      // Le secret ne sort pas de l'entree: le modele en demandera un neuf.
      if AProvider = pkActiveDirectory then Skip(AAttr.Description, rsTplSkipSecret)
      else if not Push(NewField(canon, tsAsk)) then
        Skip(AAttr.Description, Format(rsTplSkipFull, [TEMPLATE_MAX_FIELDS, 1]));
      Exit;
    end;
    if not TemplateCanHold(res.Kind) or (Pos(';', AAttr.Description) > 0) then
    begin
      Skip(AAttr.Description, rsTplSkipBinary);
      Exit;
    end;
    primary := SameAttr(canon, 'givenName') or SameAttr(canon, 'sn');
    for k := 0 to AAttr.ValueCount - 1 do
    begin
      v := EditableText(res, AAttr.Values[k]);
      if v = '' then Continue;
      if Length(v) > TEMPLATE_TEXT_MAX then
      begin
        Skip(AAttr.Description, Format(rsTplSkipTooLong, [TEMPLATE_TEXT_MAX]));
        Continue;
      end;
      f := NewField(canon, tsFixed);
      if not primary and (budget > 0) and DeriveParts(v, sources, parts, budget) then
      begin
        f.Source := tsCompose;
        // Le modele servira a d'autres que celui-ci: ni accents ni espaces dans un login.
        if AttrIsAsciiOnly(ASchema, canon) or InList(canon, LOGIN_LIKE) then
          for m := 0 to High(parts) do
            if parts[m].Kind = tpAttr then parts[m].Plain := True;
        f.Parts := parts;
      end
      else if (res.Kind = vkInteger) and SameAttr(canon, 'uidNumber') then
        f.Source := tsNumber
      else if primary or isRdn or InList(canon, PERSONAL) then
        f.Source := tsAsk
      else
        f.Value := v;
      if f.Source = tsAsk then f.Optional := not (must or isRdn or primary) or (k > 0);
      if not Push(f) then
      begin
        Skip(AAttr.Description, Format(rsTplSkipFull, [TEMPLATE_MAX_FIELDS, AAttr.ValueCount - k]));
        Exit;
      end;
      if (k = 0) and (f.Source in [tsAsk, tsCompose]) then Learn(canon, v);
    end;
  end;

begin
  Result := False;
  T := NewTemplate;
  T.Origin := ServerKindName(AProvider);
  ASkipped := nil;
  AError := '';
  if (AEntry = nil) or (ASchema = nil) then
  begin
    AError := rsCpNoSchema;
    Exit;
  end;
  // Une lecture tronquee (plages AD non recollees, budget depasse) ferait un modele a trous
  // qu'on prendrait pour complet. On refuse.
  if AEntry.DecodeIncomplete or AEntry.AnyTruncated then
  begin
    AError := rsTplSourceTruncated;
    Exit;
  end;
  budget := DERIVE_BUDGET;
  oc := AEntry.Find('objectClass');
  if (oc = nil) or (oc.ValueCount = 0) then
  begin
    AError := rsCpNoStructural;
    Exit;
  end;
  best := -1;
  bestLen := 0;
  for i := 0 to oc.ValueCount - 1 do
  begin
    cls := ASchema.ObjectClass(string(oc.Values[i]));
    if (cls = nil) or (cls.Kind <> ockStructural) then Continue;
    InheritanceChain(ASchema, cls.PrimaryName, chain, issue);
    if Length(chain) > bestLen then
    begin
      bestLen := Length(chain);
      best := i;
    end;
  end;
  if best < 0 then
  begin
    AError := rsCpNoStructural;
    Exit;
  end;
  T.Structural := ASchema.ObjectClass(string(oc.Values[best])).PrimaryName;
  for i := 0 to oc.ValueCount - 1 do
  begin
    cls := ASchema.ObjectClass(string(oc.Values[i]));
    if (cls <> nil) and (cls.Kind = ockAuxiliary) and
       (Length(T.Auxiliaries) < TEMPLATE_MAX_CLASSES) then
    begin
      SetLength(T.Auxiliaries, Length(T.Auxiliaries) + 1);
      T.Auxiliaries[High(T.Auxiliaries)] := cls.PrimaryName;
    end;
  end;
  analysis := AnalyzeClasses(ASchema, [T.Structural], T.Auxiliaries, AProvider);
  adUser := TemplateIsAdUser(analysis, AProvider);
  if not analysis.Ok then
  begin
    for i := 0 to High(analysis.Issues) do
      if analysis.Issues[i].Severity = isError then
      begin
        AError := analysis.Issues[i].Text;
        Break;
      end;
    Exit;
  end;
  rdnAttr := '';
  i := Pos('=', AEntry.Dn);
  if i > 1 then rdnAttr := Trim(Copy(AEntry.Dn, 1, i - 1));
  if rdnAttr <> '' then
  begin
    i := FindRequirement(analysis, ASchema, rdnAttr);
    if i >= 0 then rdnAttr := analysis.Requirements[i].Name;
  end;
  sources := nil;
  cloneOpts := DefaultCloneOptions;
  cloneOpts.Schema := ASchema;
  cloneOpts.Sensitive := ASensitive;
  done := TStringList.Create;
  try
    for i := 0 to High(FIRST) do
    begin
      attr := nil;
      for j := 0 to AEntry.AttrCount - 1 do
        if SameAttr(AEntry.Attrs[j].BaseName, FIRST[i]) then attr := AEntry.Attrs[j];
      if attr <> nil then Take(attr);
    end;
    for i := 0 to AEntry.AttrCount - 1 do
      if SameAttr(AEntry.Attrs[i].BaseName, rdnAttr) then Take(AEntry.Attrs[i]);
    for i := 0 to AEntry.AttrCount - 1 do
      Take(AEntry.Attrs[i]);
  finally
    done.Free;
  end;
  if FieldIndex(T, rdnAttr) >= 0 then T.RdnAttr := T.Fields[FieldIndex(T, rdnAttr)].Attr;
  // unicodePwd ne se lit jamais: le modele d'un compte AD en demande un neuf.
  if adUser and (FieldIndex(T, 'unicodePwd') < 0) and (Length(T.Fields) < TEMPLATE_MAX_FIELDS) then
  begin
    SetLength(T.Fields, Length(T.Fields) + 1);
    T.Fields[High(T.Fields)] := NewField('unicodePwd', tsAsk);
  end;
  SyncRequiredFields(T, ASchema, AProvider, ASensitive);
  Result := True;
end;

end.
