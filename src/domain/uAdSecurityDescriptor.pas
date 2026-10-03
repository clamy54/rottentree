// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uAdSecurityDescriptor;

{$mode objfpc}{$H+}

// Descripteurs de securite AD (nTSecurityDescriptor, MS-DTYP 2.4.6). Chaque offset,
// taille et SID est verifie avant lecture, une ACE inconnue est gardee en octets,
// et un descripteur lu a moitie interdit toute modification. On montre les ACE
// enregistrees, pas les droits effectifs: le jeton, c'est l'affaire du DC.

interface

uses
  SysUtils, uSearchModel;

const
  SD_FLAGS_CONTROL_OID = '1.2.840.113556.1.4.801';
  SD_MAX_BYTES = 1024 * 1024;

  SI_OWNER = $1;
  SI_GROUP = $2;
  SI_DACL = $4;
  SI_SACL = $8;

  SE_OWNER_DEFAULTED = $0001;
  SE_GROUP_DEFAULTED = $0002;
  SE_DACL_PRESENT = $0004;
  SE_DACL_DEFAULTED = $0008;
  SE_SACL_PRESENT = $0010;
  SE_SACL_DEFAULTED = $0020;
  SE_DACL_AUTO_INHERIT_REQ = $0100;
  SE_SACL_AUTO_INHERIT_REQ = $0200;
  SE_DACL_AUTO_INHERITED = $0400;
  SE_SACL_AUTO_INHERITED = $0800;
  SE_DACL_PROTECTED = $1000;
  SE_SACL_PROTECTED = $2000;
  SE_RM_CONTROL_VALID = $4000;
  SE_SELF_RELATIVE = $8000;
  SE_DACL_BITS = SE_DACL_PRESENT or SE_DACL_DEFAULTED or SE_DACL_AUTO_INHERIT_REQ or
    SE_DACL_AUTO_INHERITED or SE_DACL_PROTECTED;

  ACCESS_ALLOWED_ACE_TYPE = $00;
  ACCESS_DENIED_ACE_TYPE = $01;
  SYSTEM_AUDIT_ACE_TYPE = $02;
  ACCESS_ALLOWED_OBJECT_ACE_TYPE = $05;
  ACCESS_DENIED_OBJECT_ACE_TYPE = $06;
  SYSTEM_AUDIT_OBJECT_ACE_TYPE = $07;

  OBJECT_INHERIT_ACE = $01;
  CONTAINER_INHERIT_ACE = $02;
  NO_PROPAGATE_INHERIT_ACE = $04;
  INHERIT_ONLY_ACE = $08;
  INHERITED_ACE = $10;
  SUCCESSFUL_ACCESS_ACE_FLAG = $40;
  FAILED_ACCESS_ACE_FLAG = $80;

  ACE_OBJECT_TYPE_PRESENT = $1;
  ACE_INHERITED_OBJECT_TYPE_PRESENT = $2;

  ADS_RIGHT_DS_CONTROL_ACCESS = $00000100;
  ADS_RIGHT_GENERIC_ALL = $10000000;
  ADS_FULL_CONTROL = $000F01FF;

  ADS_RIGHT_DS_DELETE_CHILD = $00000002;
  ADS_RIGHT_DS_DELETE_TREE = $00000040;
  ADS_RIGHT_DELETE = $00010000;
  // Protection anti-suppression facon console AD: refus a Everyone de DELETE et
  // DELETE_TREE sur l'objet, et de DELETE_CHILD sur le parent. Sans la regle du
  // parent, AD laisse supprimer a qui a DELETE_CHILD dessus, admins du domaine en
  // tete. Au retrait, celle du parent reste: d'autres enfants s'y abritent peut-etre.
  PROTECT_OBJECT_MASK = ADS_RIGHT_DELETE or ADS_RIGHT_DS_DELETE_TREE;
  PROTECT_PARENT_MASK = ADS_RIGHT_DS_DELETE_CHILD;

  CHANGE_PASSWORD_GUID = 'ab721a53-1e2f-11d0-9819-00aa0040529b';
  RESET_PASSWORD_GUID = '00299570-246d-11d0-a768-00aa006e0529';
  SID_SELF = 'S-1-5-10';
  SID_EVERYONE = 'S-1-1-0';

type
  // Section non demandee, non renvoyee, ACL NULL et ACL vide sont quatre etats
  // distincts. ACL NULL: tout est permis. ACL vide: rien ne l'est. Les confondre,
  // c'est ouvrir la porte en croyant la fermer.
  TSdSectionState = (
    ssNotRequested,
    ssNotReturned,
    ssNull,
    ssPresent);

  TAce = record
    AceType: Byte;
    AceFlags: Byte;
    Mask: LongWord;
    IsObject: Boolean;
    ObjectFlags: LongWord;
    ObjectType: RawByteString;
    InheritedObjectType: RawByteString;
    Sid: RawByteString;
    SidText: string;
    Known: Boolean;
    Raw: RawByteString;
  end;
  TAceArray = array of TAce;

  TAcl = record
    State: TSdSectionState;
    Revision: Byte;
    Aces: TAceArray;
    Decoded: Boolean;
    Error: string;
  end;

  TSecurityDescriptor = record
    Valid: Boolean;
    Error: string;
    Revision: Byte;
    Control: Word;
    OwnerState, GroupState: TSdSectionState;
    Owner, Group: RawByteString;
    OwnerText, GroupText: string;
    Sacl, Dacl: TAcl;
    Partial: Boolean;
  end;

  TCantChangeState = (ccIndeterminate, ccAllowed, ccDenied);

  TProtectionState = (prIndeterminate, prProtected, prUnprotected);

resourcestring
  rsSdTooShort = 'the value is shorter than a security descriptor header (%d bytes)';
  rsSdTooLarge = 'the value is larger than %d bytes';
  rsSdRevision = 'unsupported revision %d';
  rsSdNotSelfRelative = 'not a self-relative security descriptor';
  rsSdOffset = '%s offset %d is outside the value';
  rsSdSid = '%s: invalid SID (%s)';
  rsSdAclHeader = '%s: ACL header outside the value';
  rsSdAclSize = '%s: ACL size %d is invalid';
  rsSdAceHeader = '%s: ACE %d header outside the ACL';
  rsSdAceSize = '%s: ACE %d size %d is invalid';
  rsSdAceBody = '%s: ACE %d is truncated';
  rsSdAceCount = '%s: %d ACE(s) announced, %d read';

  rsCcDenied = 'The user cannot change the password: explicit deny rules for SELF and Everyone.';
  rsCcAllowed = 'Nothing denies SELF or Everyone the right to change the password.';
  rsCcNoDacl = 'The access list was not read: the state is unknown.';
  rsCcNullDacl = 'The access list is NULL (everything is allowed): the state cannot be set by a targeted rule.';
  rsCcPartial = 'The access list could not be read completely: no targeted change is possible.';
  rsCcMixed = 'Only one of SELF and Everyone is denied: the state is not conclusive.';
  rsCcInherited = 'An inherited rule denies changing the password: only the parent or the inheritance settings can change it.';
  rsCcBroader = 'A broader rule (%s) applies to SELF or Everyone: the result is not conclusive and is not changed here.';
  rsCcNoGrant = 'No rule grants SELF or Everyone the right to change the password; other groups may.';
  rsCcNotCanonical = 'The explicit rules are not in canonical order (deny before allow): the assistant does not reorder them.';
  rsCcUnknownAce = 'The access list holds rules of an unknown type: their position cannot be judged safely.';
  rsCcAlready = 'Nothing to change: the rules already give this state.';
  rsCcAddDeny = 'add: deny Change Password to %s';
  rsCcRemoveAllow = 'remove: allow Change Password to %s (replaced by the deny rule)';
  rsCcRemoveDeny = 'remove: deny Change Password to %s';
  rsCcAddAllow = 'add: allow Change Password to %s';

  rsPdProtected = 'Protected from accidental deletion: Everyone is denied Delete and Delete subtree on this object.';
  rsPdInherited = 'Protected by an inherited rule: only the parent or the inheritance settings can change it.';
  rsPdUnprotected = 'Not protected from accidental deletion.';
  rsPdPartial = 'Not fully protected: Everyone is denied only %s.';
  rsPdBroader = 'A broader rule denies deletion to Everyone (%s): it is not changed here.';
  rsPdAlready = 'Nothing to change: the rules already give this state.';
  rsPdAddObject = 'add on the object: deny Everyone Delete and Delete subtree (this object only)';
  rsPdRemoveObject = 'remove on the object: deny Everyone %s';
  rsPdAddParent = 'add on the parent: deny Everyone Delete all child objects (one rule on the parent, ' +
    'as the Active Directory console writes it: it blocks deleting EVERY child of the parent, not only ' +
    'this object, and it is kept when the protection is removed)';
  rsPdParentHas = 'the parent already denies Everyone Delete all child objects';
  rsPdDelete = 'Delete';
  rsPdDeleteTree = 'Delete subtree';
  rsPdDeleteChild = 'Delete all child objects';
  rsPdAnd = ' and ';

function SdFlagsControl(AFlags: Byte; ACritical: Boolean): TRequestControl;
function ParseSecurityDescriptor(const ABytes: RawByteString; ARequested: Byte): TSecurityDescriptor;
// AD refuse de supprimer l'ancienne valeur exacte de nTSecurityDescriptor
// (00002077 WILL_NOT_PERFORM): pas d'ecriture atomique. La DACL est relue juste
// avant, remplacee seule (SD Flags = DACL, critique) puis relue a l'octet pres.
// Proprietaire, groupe et SACL ne repartent jamais.
function SerializeDaclOnly(const ASd: TSecurityDescriptor; const ADacl: TAcl): RawByteString;
function EncodeObjectAce(AType, AFlags: Byte; AMask: LongWord; const AObjectType: RawByteString;
  const ASid: RawByteString): RawByteString;
function DescribeSecurityDescriptor(const ASd: TSecurityDescriptor): TStringArray;
function AceTypeName(AType: Byte): string;
function SectionStateText(AState: TSdSectionState): string;

function EvaluateCantChangePassword(const ASd: TSecurityDescriptor; out AReason: string): TCantChangeState;
function PlanCantChangePassword(const ASd: TSecurityDescriptor; ADeny: Boolean; out ANewDacl: TAcl;
  out ASteps: TStringArray; out AError: string): Boolean;

function EvaluateDeletionProtection(const ASd: TSecurityDescriptor; out AReason: string): TProtectionState;
function PlanDeletionProtection(const ASd: TSecurityDescriptor; AProtect: Boolean; out ANewDacl: TAcl;
  out ASteps: TStringArray; out AError: string): Boolean;
function PlanParentDeleteChildDeny(const ASd: TSecurityDescriptor; out ANewDacl: TAcl;
  out ANeeded: Boolean; out AError: string): Boolean;
function DaclMatchesPlan(const ARead: TSecurityDescriptor; const APlanned: TAcl): Boolean;
function DeletionRightsText(AMask: LongWord): string;

implementation

uses
  uBer, uAttributeCodec, uRtBytes;

function ReadU16(const S: RawByteString; AOffset: Integer): Word;
begin
  Result := Byte(S[AOffset + 1]) or (Word(Byte(S[AOffset + 2])) shl 8);
end;

function ReadU32(const S: RawByteString; AOffset: Integer): LongWord;
begin
  Result := ReadUInt32LE(S, AOffset + 1);
end;

function U16(AValue: Word): RawByteString;
begin
  Result := Char(AValue and $FF) + Char(AValue shr 8);
end;

function U32(AValue: LongWord): RawByteString;
begin
  Result := Char(AValue and $FF) + Char((AValue shr 8) and $FF) + Char((AValue shr 16) and $FF) +
    Char(AValue shr 24);
end;

function SdFlagsControl(AFlags: Byte; ACritical: Boolean): TRequestControl;
begin
  Result := Default(TRequestControl);
  Result.Oid := SD_FLAGS_CONTROL_OID;
  Result.Critical := ACritical;
  Result.HasValue := True;
  Result.Value := BerTlv($30, BerTlv($02, Char(AFlags)));
end;

// Longueur du SID deduite du compte de sous-autorites et verifiee avant toute
// lecture: un descripteur forge ne nous fera pas lire a cote.
function ReadSidAt(const S: RawByteString; AOffset, ALimit: Integer; out ASid: RawByteString;
  out AText, AError: string): Boolean;
var
  count, len: Integer;
begin
  Result := False;
  ASid := '';
  AText := '';
  AError := '';
  if (AOffset < 0) or (AOffset + 8 > ALimit) then
  begin
    AError := 'header';
    Exit;
  end;
  count := Byte(S[AOffset + 2]);
  len := 8 + 4 * count;
  if (count > 15) or (AOffset + len > ALimit) then
  begin
    AError := 'length';
    Exit;
  end;
  ASid := Copy(S, AOffset + 1, len);
  Result := SidToText(ASid, AText, AError);
end;

function ParseAcl(const S: RawByteString; AOffset: Integer; const AName: string; var AAcl: TAcl): Boolean;
var
  size, count, pos, i, aceSize, sidOff, aceEnd: Integer;
  ace: TAce;
  err: string;
begin
  Result := False;
  AAcl.Decoded := False;
  AAcl.Aces := nil;
  if AOffset + 8 > Length(S) then
  begin
    AAcl.Error := Format(rsSdAclHeader, [AName]);
    Exit;
  end;
  AAcl.Revision := Byte(S[AOffset + 1]);
  size := ReadU16(S, AOffset + 2);
  count := ReadU16(S, AOffset + 4);
  if (size < 8) or (AOffset + size > Length(S)) then
  begin
    AAcl.Error := Format(rsSdAclSize, [AName, size]);
    Exit;
  end;
  // Une ACE mesure au moins 8 octets: le compte annonce est borne par la taille reelle.
  if count > (size - 8) div 8 then
  begin
    AAcl.Error := Format(rsSdAceCount, [AName, count, 0]);
    Exit;
  end;
  pos := AOffset + 8;
  for i := 0 to count - 1 do
  begin
    if pos + 4 > AOffset + size then
    begin
      AAcl.Error := Format(rsSdAceHeader, [AName, i + 1]);
      Exit;
    end;
    aceSize := ReadU16(S, pos + 2);
    if (aceSize < 8) or (pos + aceSize > AOffset + size) then
    begin
      AAcl.Error := Format(rsSdAceSize, [AName, i + 1, aceSize]);
      Exit;
    end;
    ace := Default(TAce);
    ace.AceType := Byte(S[pos + 1]);
    ace.AceFlags := Byte(S[pos + 2]);
    ace.Raw := Copy(S, pos + 1, aceSize);
    ace.Mask := ReadU32(S, pos + 4);
    aceEnd := pos + aceSize;
    case ace.AceType of
      ACCESS_ALLOWED_ACE_TYPE, ACCESS_DENIED_ACE_TYPE, SYSTEM_AUDIT_ACE_TYPE:
        begin
          sidOff := pos + 8;
          if not ReadSidAt(S, sidOff, aceEnd, ace.Sid, ace.SidText, err) then
          begin
            AAcl.Error := Format(rsSdAceBody, [AName, i + 1]);
            Exit;
          end;
          ace.Known := True;
        end;
      ACCESS_ALLOWED_OBJECT_ACE_TYPE, ACCESS_DENIED_OBJECT_ACE_TYPE, SYSTEM_AUDIT_OBJECT_ACE_TYPE:
        begin
          ace.IsObject := True;
          if pos + 12 > aceEnd then
          begin
            AAcl.Error := Format(rsSdAceBody, [AName, i + 1]);
            Exit;
          end;
          ace.ObjectFlags := ReadU32(S, pos + 8);
          sidOff := pos + 12;
          if (ace.ObjectFlags and ACE_OBJECT_TYPE_PRESENT) <> 0 then
          begin
            if sidOff + 16 > aceEnd then
            begin
              AAcl.Error := Format(rsSdAceBody, [AName, i + 1]);
              Exit;
            end;
            ace.ObjectType := Copy(S, sidOff + 1, 16);
            Inc(sidOff, 16);
          end;
          if (ace.ObjectFlags and ACE_INHERITED_OBJECT_TYPE_PRESENT) <> 0 then
          begin
            if sidOff + 16 > aceEnd then
            begin
              AAcl.Error := Format(rsSdAceBody, [AName, i + 1]);
              Exit;
            end;
            ace.InheritedObjectType := Copy(S, sidOff + 1, 16);
            Inc(sidOff, 16);
          end;
          if not ReadSidAt(S, sidOff, aceEnd, ace.Sid, ace.SidText, err) then
          begin
            AAcl.Error := Format(rsSdAceBody, [AName, i + 1]);
            Exit;
          end;
          ace.Known := True;
        end;
    else
      ace.Known := False;
    end;
    SetLength(AAcl.Aces, Length(AAcl.Aces) + 1);
    AAcl.Aces[High(AAcl.Aces)] := ace;
    Inc(pos, aceSize);
  end;
  AAcl.Decoded := True;
  Result := True;
end;

function ParseSecurityDescriptor(const ABytes: RawByteString; ARequested: Byte): TSecurityDescriptor;
var
  offOwner, offGroup, offSacl, offDacl: LongWord;
  err: string;
  len: Integer;
begin
  Result := Default(TSecurityDescriptor);
  Result.Sacl.State := ssNotRequested;
  Result.Dacl.State := ssNotRequested;
  Result.OwnerState := ssNotRequested;
  Result.GroupState := ssNotRequested;
  len := Length(ABytes);
  if len > SD_MAX_BYTES then
  begin
    Result.Error := Format(rsSdTooLarge, [SD_MAX_BYTES]);
    Exit;
  end;
  if len < 20 then
  begin
    Result.Error := Format(rsSdTooShort, [len]);
    Exit;
  end;
  Result.Revision := Byte(ABytes[1]);
  if Result.Revision <> 1 then
  begin
    Result.Error := Format(rsSdRevision, [Result.Revision]);
    Exit;
  end;
  Result.Control := ReadU16(ABytes, 2);
  if (Result.Control and SE_SELF_RELATIVE) = 0 then
  begin
    Result.Error := rsSdNotSelfRelative;
    Exit;
  end;
  offOwner := ReadU32(ABytes, 4);
  offGroup := ReadU32(ABytes, 8);
  offSacl := ReadU32(ABytes, 12);
  offDacl := ReadU32(ABytes, 16);
  Result.Valid := True;
  if (ARequested and SI_OWNER) <> 0 then
  begin
    if offOwner = 0 then Result.OwnerState := ssNotReturned
    else if (offOwner < 20) or (offOwner >= LongWord(len)) then
    begin
      Result.OwnerState := ssNotReturned;
      Result.Partial := True;
      Result.Error := Format(rsSdOffset, ['owner', Int64(offOwner)]);
    end
    else if ReadSidAt(ABytes, offOwner, len, Result.Owner, Result.OwnerText, err) then
      Result.OwnerState := ssPresent
    else
    begin
      Result.Partial := True;
      Result.Error := Format(rsSdSid, ['owner', err]);
    end;
  end;
  if (ARequested and SI_GROUP) <> 0 then
  begin
    if offGroup = 0 then Result.GroupState := ssNotReturned
    else if (offGroup < 20) or (offGroup >= LongWord(len)) then
    begin
      Result.GroupState := ssNotReturned;
      Result.Partial := True;
      Result.Error := Format(rsSdOffset, ['group', Int64(offGroup)]);
    end
    else if ReadSidAt(ABytes, offGroup, len, Result.Group, Result.GroupText, err) then
      Result.GroupState := ssPresent
    else
    begin
      Result.Partial := True;
      Result.Error := Format(rsSdSid, ['group', err]);
    end;
  end;
  if (ARequested and SI_DACL) <> 0 then
  begin
    if (Result.Control and SE_DACL_PRESENT) = 0 then
      Result.Dacl.State := ssNotReturned
    else if offDacl = 0 then
      Result.Dacl.State := ssNull
    else if (offDacl < 20) or (offDacl >= LongWord(len)) then
    begin
      Result.Dacl.State := ssPresent;
      Result.Dacl.Error := Format(rsSdOffset, ['DACL', Int64(offDacl)]);
      Result.Partial := True;
    end
    else
    begin
      Result.Dacl.State := ssPresent;
      if not ParseAcl(ABytes, offDacl, 'DACL', Result.Dacl) then Result.Partial := True;
    end;
  end;
  if (ARequested and SI_SACL) <> 0 then
  begin
    if (Result.Control and SE_SACL_PRESENT) = 0 then
      Result.Sacl.State := ssNotReturned
    else if offSacl = 0 then
      Result.Sacl.State := ssNull
    else if (offSacl < 20) or (offSacl >= LongWord(len)) then
    begin
      Result.Sacl.State := ssPresent;
      Result.Sacl.Error := Format(rsSdOffset, ['SACL', Int64(offSacl)]);
      Result.Partial := True;
    end
    else
    begin
      Result.Sacl.State := ssPresent;
      if not ParseAcl(ABytes, offSacl, 'SACL', Result.Sacl) then Result.Partial := True;
    end;
  end;
end;

function EncodeObjectAce(AType, AFlags: Byte; AMask: LongWord; const AObjectType: RawByteString;
  const ASid: RawByteString): RawByteString;
var
  body: RawByteString;
  flags: LongWord;
begin
  flags := 0;
  if AObjectType <> '' then flags := ACE_OBJECT_TYPE_PRESENT;
  body := U32(AMask) + U32(flags) + AObjectType + ASid;
  Result := Char(AType) + Char(AFlags) + U16(4 + Length(body)) + body;
end;

function SerializeAcl(const AAcl: TAcl): RawByteString;
var
  i: Integer;
  aces: RawByteString;
begin
  aces := '';
  for i := 0 to High(AAcl.Aces) do
    aces := aces + AAcl.Aces[i].Raw;
  Result := Char(AAcl.Revision) + #0 + U16(8 + Length(aces)) + U16(Length(AAcl.Aces)) + #0#0 + aces;
end;

function SerializeDaclOnly(const ASd: TSecurityDescriptor; const ADacl: TAcl): RawByteString;
var
  control: Word;
  acl: RawByteString;
begin
  Result := '';
  // Descripteur lu en partie: aucune reemission, meme de la seule DACL.
  if not ASd.Valid or ASd.Partial or (ADacl.State <> ssPresent) or not ADacl.Decoded then Exit;
  acl := SerializeAcl(ADacl);
  if Length(acl) > $FFFF then Exit;
  // Les indicateurs propres a la DACL (protection, heritage auto) sont conserves.
  control := (ASd.Control and SE_DACL_BITS) or SE_DACL_PRESENT or SE_SELF_RELATIVE;
  Result := #1#0 + U16(control) + U32(0) + U32(0) + U32(0) + U32(20) + acl;
end;

function AceTypeName(AType: Byte): string;
begin
  case AType of
    ACCESS_ALLOWED_ACE_TYPE: Result := 'allow';
    ACCESS_DENIED_ACE_TYPE: Result := 'deny';
    SYSTEM_AUDIT_ACE_TYPE: Result := 'audit';
    ACCESS_ALLOWED_OBJECT_ACE_TYPE: Result := 'allow (object)';
    ACCESS_DENIED_OBJECT_ACE_TYPE: Result := 'deny (object)';
    SYSTEM_AUDIT_OBJECT_ACE_TYPE: Result := 'audit (object)';
  else
    Result := Format('type 0x%.2x', [AType]);
  end;
end;

function SectionStateText(AState: TSdSectionState): string;
begin
  case AState of
    ssNotRequested: Result := 'not requested';
    ssNotReturned: Result := 'not returned';
    ssNull: Result := 'NULL (everything allowed)';
  else
    Result := 'present';
  end;
end;

function AceFlagsText(AFlags: Byte): string;
begin
  Result := '';
  if (AFlags and INHERITED_ACE) <> 0 then Result := Result + 'inherited ';
  if (AFlags and OBJECT_INHERIT_ACE) <> 0 then Result := Result + 'object-inherit ';
  if (AFlags and CONTAINER_INHERIT_ACE) <> 0 then Result := Result + 'container-inherit ';
  if (AFlags and NO_PROPAGATE_INHERIT_ACE) <> 0 then Result := Result + 'no-propagate ';
  if (AFlags and INHERIT_ONLY_ACE) <> 0 then Result := Result + 'inherit-only ';
  Result := Trim(Result);
  if Result = '' then Result := 'explicit';
end;

function GuidText(const AGuid: RawByteString): string;
begin
  if (AGuid = '') or not GuidToText(AGuid, Result) then Result := '';
  if SameText(Result, CHANGE_PASSWORD_GUID) then Result := Result + ' (Change Password)'
  else if SameText(Result, RESET_PASSWORD_GUID) then Result := Result + ' (Reset Password)';
end;

procedure AddAclLines(var ALines: TStringArray; const AName: string; const AAcl: TAcl);
var
  i: Integer;
  a: TAce;
  s: string;

  procedure Add(const T: string);
  begin
    SetLength(ALines, Length(ALines) + 1);
    ALines[High(ALines)] := T;
  end;

begin
  Add(Format('%s: %s, %d ACE(s)', [AName, SectionStateText(AAcl.State), Length(AAcl.Aces)]));
  if AAcl.Error <> '' then Add('  ' + AAcl.Error);
  for i := 0 to High(AAcl.Aces) do
  begin
    a := AAcl.Aces[i];
    if not a.Known then
    begin
      Add(Format('  %d. %s, %d bytes kept as is', [i + 1, AceTypeName(a.AceType), Length(a.Raw)]));
      Continue;
    end;
    s := Format('  %d. %s %s mask 0x%.8x [%s]', [i + 1, AceTypeName(a.AceType), a.SidText, Int64(a.Mask),
      AceFlagsText(a.AceFlags)]);
    if a.ObjectType <> '' then s := s + ' object ' + GuidText(a.ObjectType);
    if a.InheritedObjectType <> '' then s := s + ' inherited object ' + GuidText(a.InheritedObjectType);
    Add(s);
  end;
end;

function DescribeSecurityDescriptor(const ASd: TSecurityDescriptor): TStringArray;

  procedure Add(const T: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := T;
  end;

begin
  Result := nil;
  if not ASd.Valid then
  begin
    Add('Unreadable security descriptor: ' + ASd.Error);
    Exit;
  end;
  Add(Format('Revision %d, control 0x%.4x', [ASd.Revision, ASd.Control]));
  if (ASd.Control and SE_DACL_PROTECTED) <> 0 then Add('DACL protected: inheritance from the parent is blocked');
  if ASd.OwnerState = ssPresent then Add('Owner: ' + ASd.OwnerText)
  else Add('Owner: ' + SectionStateText(ASd.OwnerState));
  if ASd.GroupState = ssPresent then Add('Group: ' + ASd.GroupText)
  else Add('Group: ' + SectionStateText(ASd.GroupState));
  AddAclLines(Result, 'DACL', ASd.Dacl);
  AddAclLines(Result, 'SACL', ASd.Sacl);
  if ASd.Partial then Add('Partially decoded: ' + ASd.Error + '; kept as bytes, no targeted change.');
end;

function IsTrustee(const AAce: TAce): Integer;
begin
  if AAce.SidText = SID_SELF then Result := 1
  else if AAce.SidText = SID_EVERYONE then Result := 2
  else Result := 0;
end;

function IsChangePasswordAce(const AAce: TAce): Boolean;
var
  g: string;
begin
  Result := AAce.IsObject and (AAce.ObjectType <> '') and GuidToText(AAce.ObjectType, g) and
    SameText(g, CHANGE_PASSWORD_GUID) and ((AAce.Mask and ADS_RIGHT_DS_CONTROL_ACCESS) <> 0);
end;

function IsBroaderAce(const AAce: TAce): Boolean;
begin
  Result := False;
  if not AAce.Known or (AAce.AceType in [SYSTEM_AUDIT_ACE_TYPE, SYSTEM_AUDIT_OBJECT_ACE_TYPE]) then Exit;
  if (AAce.Mask and ADS_RIGHT_GENERIC_ALL) <> 0 then Exit(True);
  if (AAce.Mask and ADS_FULL_CONTROL) = ADS_FULL_CONTROL then Exit(True);
  if ((AAce.Mask and ADS_RIGHT_DS_CONTROL_ACCESS) <> 0) and (AAce.ObjectType = '') then Exit(True);
end;

function IsDeny(const AAce: TAce): Boolean;
begin
  Result := AAce.AceType in [ACCESS_DENIED_ACE_TYPE, ACCESS_DENIED_OBJECT_ACE_TYPE];
end;

function IsAllow(const AAce: TAce): Boolean;
begin
  Result := AAce.AceType in [ACCESS_ALLOWED_ACE_TYPE, ACCESS_ALLOWED_OBJECT_ACE_TYPE];
end;

function IsInherited(const AAce: TAce): Boolean;
begin
  Result := (AAce.AceFlags and INHERITED_ACE) <> 0;
end;

function AppliesHere(const AAce: TAce): Boolean;
begin
  // Une ACE "heritage seulement" vise les enfants, pas cet objet.
  Result := (AAce.AceFlags and INHERIT_ONLY_ACE) = 0;
end;

function IsExactRuleAce(const AAce: TAce): Boolean;
begin
  Result := IsChangePasswordAce(AAce) and (AAce.Mask = ADS_RIGHT_DS_CONTROL_ACCESS) and
    not IsInherited(AAce) and
    ((AAce.AceFlags and (OBJECT_INHERIT_ACE or CONTAINER_INHERIT_ACE or INHERIT_ONLY_ACE)) = 0) and
    (AAce.InheritedObjectType = '');
end;

function EvaluateCantChangePassword(const ASd: TSecurityDescriptor; out AReason: string): TCantChangeState;
var
  i, t: Integer;
  a: TAce;
  first: array[1..2] of Integer;
  inheritedDeny, broader: Boolean;
begin
  Result := ccIndeterminate;
  AReason := '';
  if not ASd.Valid or (ASd.Dacl.State in [ssNotRequested, ssNotReturned]) then
  begin
    AReason := rsCcNoDacl;
    Exit;
  end;
  if ASd.Dacl.State = ssNull then
  begin
    AReason := rsCcNullDacl;
    Exit;
  end;
  if not ASd.Dacl.Decoded then
  begin
    AReason := rsCcPartial;
    Exit;
  end;
  first[1] := 0;
  first[2] := 0;
  inheritedDeny := False;
  broader := False;
  // La premiere regle applicable a chaque identite decide: l'ordre des ACE fait loi.
  for i := 0 to High(ASd.Dacl.Aces) do
  begin
    a := ASd.Dacl.Aces[i];
    // Regle d'un type non decode (conditionnelle, etiquette...): elle peut porter sur
    // ce droit, donc rien n'est conclu.
    if not a.Known then
    begin
      AReason := rsCcUnknownAce;
      Exit;
    end;
    t := IsTrustee(a);
    if (t = 0) or not AppliesHere(a) then Continue;
    if IsBroaderAce(a) then
    begin
      broader := True;
      Continue;
    end;
    if not IsChangePasswordAce(a) then Continue;
    if IsDeny(a) and IsInherited(a) then inheritedDeny := True;
    if first[t] = 0 then
    begin
      if IsDeny(a) then first[t] := -1 else if IsAllow(a) then first[t] := 1;
    end;
  end;
  if broader then
  begin
    AReason := Format(rsCcBroader, ['all extended rights or full control']);
    Exit;
  end;
  if (first[1] = -1) and (first[2] = -1) then
  begin
    if inheritedDeny then AReason := rsCcInherited else AReason := rsCcDenied;
    Exit(ccDenied);
  end;
  if (first[1] = -1) or (first[2] = -1) then
  begin
    if inheritedDeny then AReason := rsCcInherited else AReason := rsCcMixed;
    Exit;
  end;
  if (first[1] = 0) and (first[2] = 0) then
  begin
    AReason := rsCcNoGrant;
    Exit;
  end;
  AReason := rsCcAllowed;
  Result := ccAllowed;
end;

// Ordre canonique (MS-DTYP 2.4.5): refus avant autorisations, explicites avant
// heritees. Une DACL non canonique n'est pas remise en ordre ici: on refuse.
function ExplicitCanonical(const AAcl: TAcl; out AFirstAllow, AFirstInherited: Integer): Boolean;
var
  i: Integer;
  seenAllow, seenInherited: Boolean;
begin
  Result := False;
  AFirstAllow := -1;
  AFirstInherited := Length(AAcl.Aces);
  seenAllow := False;
  seenInherited := False;
  for i := 0 to High(AAcl.Aces) do
  begin
    if not AAcl.Aces[i].Known then Exit;
    if IsInherited(AAcl.Aces[i]) then
    begin
      if not seenInherited then AFirstInherited := i;
      seenInherited := True;
      Continue;
    end;
    if seenInherited then Exit;
    if IsAllow(AAcl.Aces[i]) then
    begin
      if not seenAllow then AFirstAllow := i;
      seenAllow := True;
    end
    else if IsDeny(AAcl.Aces[i]) and seenAllow then
      Exit;
  end;
  if AFirstAllow < 0 then AFirstAllow := AFirstInherited;
  Result := True;
end;

procedure InsertAce(var AAcl: TAcl; AIndex: Integer; const AAce: TAce);
var
  i: Integer;
begin
  SetLength(AAcl.Aces, Length(AAcl.Aces) + 1);
  for i := High(AAcl.Aces) downto AIndex + 1 do
    AAcl.Aces[i] := AAcl.Aces[i - 1];
  AAcl.Aces[AIndex] := AAce;
end;

procedure DeleteAce(var AAcl: TAcl; AIndex: Integer);
var
  i: Integer;
begin
  for i := AIndex to High(AAcl.Aces) - 1 do
    AAcl.Aces[i] := AAcl.Aces[i + 1];
  SetLength(AAcl.Aces, Length(AAcl.Aces) - 1);
end;

function MakeRuleAce(AType: Byte; const ASidText: string): TAce;
var
  guid, sid: RawByteString;
  err: string;
begin
  Result := Default(TAce);
  GuidFromText(CHANGE_PASSWORD_GUID, guid);
  SidFromText(ASidText, sid, err);
  Result.AceType := AType;
  Result.AceFlags := 0;
  Result.Mask := ADS_RIGHT_DS_CONTROL_ACCESS;
  Result.IsObject := True;
  Result.ObjectFlags := ACE_OBJECT_TYPE_PRESENT;
  Result.ObjectType := guid;
  Result.Sid := sid;
  Result.SidText := ASidText;
  Result.Known := True;
  Result.Raw := EncodeObjectAce(AType, 0, ADS_RIGHT_DS_CONTROL_ACCESS, guid, sid);
end;

function PlanCantChangePassword(const ASd: TSecurityDescriptor; ADeny: Boolean; out ANewDacl: TAcl;
  out ASteps: TStringArray; out AError: string): Boolean;
var
  reason, name: string;
  state: TCantChangeState;
  i, t, firstAllow, firstInherited: Integer;
  trustee: string;
  hasExplicitDeny, hasAllow: Boolean;
  a: TAce;

  procedure Step(const T: string);
  begin
    SetLength(ASteps, Length(ASteps) + 1);
    ASteps[High(ASteps)] := T;
  end;

begin
  Result := False;
  ASteps := nil;
  AError := '';
  ANewDacl := ASd.Dacl;
  ANewDacl.Aces := Copy(ASd.Dacl.Aces, 0, Length(ASd.Dacl.Aces));
  if not ASd.Valid or (ASd.Dacl.State <> ssPresent) or not ASd.Dacl.Decoded or ASd.Partial then
  begin
    state := EvaluateCantChangePassword(ASd, reason);
    if reason = '' then reason := rsCcPartial;
    AError := reason;
    Exit;
  end;
  // Une regle plus large ou heritee n'est jamais forcee par une ACE ciblee.
  state := EvaluateCantChangePassword(ASd, reason);
  for i := 0 to High(ASd.Dacl.Aces) do
  begin
    a := ASd.Dacl.Aces[i];
    if not a.Known then
    begin
      AError := rsCcUnknownAce;
      Exit;
    end;
    t := IsTrustee(a);
    if (t <> 0) and AppliesHere(a) and IsBroaderAce(a) then
    begin
      AError := Format(rsCcBroader, ['all extended rights or full control']);
      Exit;
    end;
    if (t <> 0) and IsChangePasswordAce(a) and IsInherited(a) and IsDeny(a) and not ADeny then
    begin
      AError := rsCcInherited;
      Exit;
    end;
    if (t <> 0) and IsChangePasswordAce(a) and not IsInherited(a) and not IsExactRuleAce(a) then
    begin
      AError := Format(rsCcBroader, [AceTypeName(a.AceType) + ' ' + a.SidText]);
      Exit;
    end;
  end;
  if not ExplicitCanonical(ANewDacl, firstAllow, firstInherited) then
  begin
    AError := rsCcNotCanonical;
    Exit;
  end;
  if (ADeny and (state = ccDenied)) or (not ADeny and (state = ccAllowed)) then
  begin
    AError := rsCcAlready;
    Exit;
  end;
  for t := 1 to 2 do
  begin
    if t = 1 then trustee := SID_SELF else trustee := SID_EVERYONE;
    if t = 1 then name := 'SELF' else name := 'Everyone';
    hasExplicitDeny := False;
    hasAllow := False;
    for i := 0 to High(ANewDacl.Aces) do
      if (ANewDacl.Aces[i].SidText = trustee) and IsExactRuleAce(ANewDacl.Aces[i]) then
      begin
        if IsDeny(ANewDacl.Aces[i]) then hasExplicitDeny := True;
        if IsAllow(ANewDacl.Aces[i]) then hasAllow := True;
      end;
    if ADeny then
    begin
      if hasExplicitDeny then Continue;
      // Comme le documente Microsoft, l'autorisation explicite exacte devient un refus;
      // les autres ACE ne bougent pas.
      for i := High(ANewDacl.Aces) downto 0 do
        if (ANewDacl.Aces[i].SidText = trustee) and IsExactRuleAce(ANewDacl.Aces[i]) and
           IsAllow(ANewDacl.Aces[i]) then
        begin
          DeleteAce(ANewDacl, i);
          Step(Format(rsCcRemoveAllow, [name]));
        end;
      InsertAce(ANewDacl, 0, MakeRuleAce(ACCESS_DENIED_OBJECT_ACE_TYPE, trustee));
      Step(Format(rsCcAddDeny, [name]));
    end
    else
    begin
      if not hasExplicitDeny then Continue;
      for i := High(ANewDacl.Aces) downto 0 do
        if (ANewDacl.Aces[i].SidText = trustee) and IsExactRuleAce(ANewDacl.Aces[i]) and
           IsDeny(ANewDacl.Aces[i]) then
        begin
          DeleteAce(ANewDacl, i);
          Step(Format(rsCcRemoveDeny, [name]));
        end;
      if not hasAllow then
      begin
        ExplicitCanonical(ANewDacl, firstAllow, firstInherited);
        InsertAce(ANewDacl, firstAllow, MakeRuleAce(ACCESS_ALLOWED_OBJECT_ACE_TYPE, trustee));
        Step(Format(rsCcAddAllow, [name]));
      end;
    end;
  end;
  if Length(ASteps) = 0 then
  begin
    AError := rsCcAlready;
    Exit;
  end;
  Result := True;
end;

function MakePlainAce(AType: Byte; AMask: LongWord; const ASidText: string): TAce;
var
  sid: RawByteString;
  err: string;
begin
  Result := Default(TAce);
  SidFromText(ASidText, sid, err);
  Result.AceType := AType;
  Result.AceFlags := 0;
  Result.Mask := AMask;
  Result.Sid := sid;
  Result.SidText := ASidText;
  Result.Known := True;
  Result.Raw := Char(AType) + #0 + U16(8 + Length(sid)) + U32(AMask) + sid;
end;

// Une ACE objet qui vise un type precis (propriete, classe d'enfant) n'est pas un
// refus general.
function DeniedToEveryone(const AAcl: TAcl; AExplicit: Boolean): LongWord;
var
  i: Integer;
  a: TAce;
begin
  Result := 0;
  for i := 0 to High(AAcl.Aces) do
  begin
    a := AAcl.Aces[i];
    if not a.Known or not IsDeny(a) or (a.SidText <> SID_EVERYONE) or not AppliesHere(a) then Continue;
    if a.IsObject and (a.ObjectType <> '') then Continue;
    if IsInherited(a) = AExplicit then Continue;
    if (a.Mask and ADS_RIGHT_GENERIC_ALL) <> 0 then Result := Result or ADS_FULL_CONTROL;
    Result := Result or a.Mask;
  end;
end;

function DeletionRightsText(AMask: LongWord): string;

  procedure Add(const T: string);
  begin
    if Result <> '' then Result := Result + rsPdAnd;
    Result := Result + T;
  end;

begin
  Result := '';
  if (AMask and ADS_RIGHT_DELETE) <> 0 then Add(rsPdDelete);
  if (AMask and ADS_RIGHT_DS_DELETE_TREE) <> 0 then Add(rsPdDeleteTree);
  if (AMask and ADS_RIGHT_DS_DELETE_CHILD) <> 0 then Add(rsPdDeleteChild);
end;

function DaclReadable(const ASd: TSecurityDescriptor; out AReason: string): Boolean;
begin
  Result := False;
  AReason := '';
  if not ASd.Valid or (ASd.Dacl.State in [ssNotRequested, ssNotReturned]) then
    AReason := rsCcNoDacl
  else if ASd.Dacl.State = ssNull then
    AReason := rsCcNullDacl
  else if ASd.Partial or not ASd.Dacl.Decoded then
    AReason := rsCcPartial
  else
    Result := True;
end;

function EvaluateDeletionProtection(const ASd: TSecurityDescriptor; out AReason: string): TProtectionState;
var
  expl, inh: LongWord;
begin
  Result := prIndeterminate;
  if not DaclReadable(ASd, AReason) then Exit;
  expl := DeniedToEveryone(ASd.Dacl, True) and PROTECT_OBJECT_MASK;
  inh := DeniedToEveryone(ASd.Dacl, False) and PROTECT_OBJECT_MASK;
  if (expl or inh) = PROTECT_OBJECT_MASK then
  begin
    if expl = PROTECT_OBJECT_MASK then AReason := rsPdProtected else AReason := rsPdInherited;
    Exit(prProtected);
  end;
  if (expl or inh) <> 0 then AReason := Format(rsPdPartial, [DeletionRightsText(expl or inh)])
  else AReason := rsPdUnprotected;
  Result := prUnprotected;
end;

function PlanDeletionProtection(const ASd: TSecurityDescriptor; AProtect: Boolean; out ANewDacl: TAcl;
  out ASteps: TStringArray; out AError: string): Boolean;
var
  state: TProtectionState;
  reason: string;
  i: Integer;
  a: TAce;

  procedure Step(const T: string);
  begin
    SetLength(ASteps, Length(ASteps) + 1);
    ASteps[High(ASteps)] := T;
  end;

begin
  Result := False;
  ASteps := nil;
  AError := '';
  ANewDacl := ASd.Dacl;
  ANewDacl.Aces := Copy(ASd.Dacl.Aces, 0, Length(ASd.Dacl.Aces));
  if not DaclReadable(ASd, AError) then Exit;
  state := EvaluateDeletionProtection(ASd, reason);
  if AProtect then
  begin
    if state = prProtected then
    begin
      AError := rsPdAlready;
      Exit;
    end;
    InsertAce(ANewDacl, 0, MakePlainAce(ACCESS_DENIED_ACE_TYPE, PROTECT_OBJECT_MASK, SID_EVERYONE));
    Step(rsPdAddObject);
    Exit(True);
  end;
  if (DeniedToEveryone(ASd.Dacl, False) and PROTECT_OBJECT_MASK) <> 0 then
  begin
    AError := rsPdInherited;
    Exit;
  end;
  for i := High(ANewDacl.Aces) downto 0 do
  begin
    a := ANewDacl.Aces[i];
    if not a.Known or not IsDeny(a) or (a.SidText <> SID_EVERYONE) or IsInherited(a) or
       not AppliesHere(a) or (a.IsObject and (a.ObjectType <> '')) or
       ((a.Mask and (PROTECT_OBJECT_MASK or ADS_RIGHT_GENERIC_ALL)) = 0) then Continue;
    if ((a.Mask and not PROTECT_OBJECT_MASK) <> 0) or
       ((a.AceFlags and (OBJECT_INHERIT_ACE or CONTAINER_INHERIT_ACE or INHERIT_ONLY_ACE)) <> 0) then
    begin
      ASteps := nil;
      AError := Format(rsPdBroader, [Format('%s mask 0x%.8x [%s]', [AceTypeName(a.AceType), Int64(a.Mask),
        AceFlagsText(a.AceFlags)])]);
      Exit;
    end;
    DeleteAce(ANewDacl, i);
    Step(Format(rsPdRemoveObject, [DeletionRightsText(a.Mask)]));
  end;
  if Length(ASteps) = 0 then
  begin
    AError := rsPdAlready;
    Exit;
  end;
  Result := True;
end;

function PlanParentDeleteChildDeny(const ASd: TSecurityDescriptor; out ANewDacl: TAcl;
  out ANeeded: Boolean; out AError: string): Boolean;
begin
  Result := False;
  ANeeded := False;
  ANewDacl := ASd.Dacl;
  ANewDacl.Aces := Copy(ASd.Dacl.Aces, 0, Length(ASd.Dacl.Aces));
  if not DaclReadable(ASd, AError) then Exit;
  Result := True;
  if ((DeniedToEveryone(ASd.Dacl, True) or DeniedToEveryone(ASd.Dacl, False)) and
      PROTECT_PARENT_MASK) <> 0 then Exit;
  InsertAce(ANewDacl, 0, MakePlainAce(ACCESS_DENIED_ACE_TYPE, PROTECT_PARENT_MASK, SID_EVERYONE));
  ANeeded := True;
end;

function DaclMatchesPlan(const ARead: TSecurityDescriptor; const APlanned: TAcl): Boolean;
var
  i: Integer;
begin
  Result := False;
  if not ARead.Valid or ARead.Partial or (ARead.Dacl.State <> ssPresent) or not ARead.Dacl.Decoded then Exit;
  if Length(ARead.Dacl.Aces) <> Length(APlanned.Aces) then Exit;
  for i := 0 to High(APlanned.Aces) do
    if ARead.Dacl.Aces[i].Raw <> APlanned.Aces[i].Raw then Exit;
  Result := True;
end;

end.
