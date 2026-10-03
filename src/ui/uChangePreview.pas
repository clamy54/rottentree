// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uChangePreview;

{$mode objfpc}{$H+}

// Apercu avant toute ecriture: serveur cible, DN, operation, nombre d'entrees, delta LDIF.
// Les valeurs sensibles sont masquees a l'ecran, pas dans la requete: le serveur, lui, a
// besoin du vrai mot de passe.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Graphics, uUiKit, uChangeSet, uSensitive,
  uConnections;

resourcestring
  rsPreviewSessionChanged = 'The connection was closed or re-established, or its schema was read again, ' +
    'during the confirmation: nothing was sent. Review the change again.';
  rsPreviewTitle = 'Review changes before writing';
  rsPreviewSummary = '%s on %d entr%s';
  rsPreviewApply = 'Apply';
  rsPreviewCancel = 'Cancel';
  rsPreviewNotAtomic = 'Batches are not atomic: operations run one by one and the result of each is reported.';
  rsPreviewReadOnly = 'This profile is read-only: nothing will be written.';

type
  TConfirmChangesFn = function(const AChanges: array of TLdapChange; AReadOnly: Boolean): Boolean;

var
  ConfirmChangesOverride: TConfirmChangesFn = nil;

function ConfirmChanges(AOwner: TComponent; const AServer, ABadge: string;
  const AChanges: array of TLdapChange; ASensitive: TSensitivePolicy;
  AReadOnly: Boolean; const AExtraNote: string = ''): Boolean;
function ConfirmChangesOn(AOwner: TComponent; AConns: TConnectionManager;
  var AConn: TDirectoryConnection; const AChanges: array of TLdapChange;
  ASensitive: TSensitivePolicy; out AReason: string; const AExtraNote: string = ''): Boolean;
function MaskedChangeLdif(AChange: TLdapChange; ASensitive: TSensitivePolicy): string;
function ChangeKindIcon(AKind: TChangeKind; out AColor: TColor): string;

implementation

uses
  Dialogs, uLdif, uTheme, uIcons;

function ChangeKindIcon(AKind: TChangeKind; out AColor: TColor): string;
begin
  case AKind of
    ckAdd:
      begin
        AColor := clDiffAdded;
        Result := 'plus';
      end;
    ckModify:
      begin
        AColor := clDiffChanged;
        Result := 'pencil';
      end;
    ckDelete:
      begin
        AColor := clDiffAbsent;
        Result := 'trash';
      end;
  else
    AColor := clAccent;
    Result := 'arrows-move';
  end;
end;

procedure AddKindCounts(AParent: TWinControl; const AChanges: array of TLdapChange);
var
  counts: array[TChangeKind] of Integer;
  k: TChangeKind;
  i: Integer;
  row: TPanel;
  icon: TRtIcon;
  lbl: TLabel;
  color: TColor;
begin
  for k := Low(TChangeKind) to High(TChangeKind) do counts[k] := 0;
  for i := 0 to High(AChanges) do Inc(counts[AChanges[i].Kind]);
  row := MakePanel(AParent, alTop, ScreenIconSize(16) + 12);
  row.Name := 'KindCounts';
  row.Caption := '';
  for k := Low(TChangeKind) to High(TChangeKind) do
    if counts[k] > 0 then
    begin
      icon := TRtIcon.Create(row);
      icon.Parent := row;
      icon.Align := alLeft;
      icon.SetIcon(ChangeKindIcon(k, color), 16, color);
      icon.Name := 'Kind' + ChangeKindName(k);
      lbl := MakeLabel(row, Format('%d %s', [counts[k], ChangeKindName(k)]), alLeft);
      lbl.Layout := tlCenter;
      lbl.BorderSpacing.Left := 6;
      lbl.BorderSpacing.Right := 16;
    end;
end;

function ConfirmChangesOn(AOwner: TComponent; AConns: TConnectionManager;
  var AConn: TDirectoryConnection; const AChanges: array of TLdapChange;
  ASensitive: TSensitivePolicy; out AReason: string; const AExtraNote: string): Boolean;
var
  stamp: TSessionStamp;
begin
  AReason := '';
  Result := False;
  if AConn = nil then Exit;
  stamp := AConn.Stamp;
  Result := ConfirmChanges(AOwner, AConn.Profile.DisplayEndpoint, AConn.Profile.EnvironmentBadge,
    AChanges, ASensitive, AConn.Profile.ReadOnly, AExtraNote);
  // La boucle modale traite les messages: pendant que l'operateur hesite, AConn a pu etre
  // libere ou remplace. Seule la capture est relue, accord ou refus; un pointeur mort ne
  // confirme rien.
  AConn := AConns.FindSame(stamp);
  if not Result then Exit;
  Result := False;
  if AConn = nil then
  begin
    AReason := rsPreviewSessionChanged;
    Exit;
  end;
  Result := True;
end;

function MaskedChangeLdif(AChange: TLdapChange; ASensitive: TSensitivePolicy): string;
var
  c: TLdapChange;
  i, j: Integer;
begin
  c := AChange.Clone;
  try
    for i := 0 to High(c.Mods) do
      if ASensitive.IsSensitive(c.Mods[i].Attr) then
        for j := 0 to High(c.Mods[i].Values) do
          c.Mods[i].Values[j] := MASK_TEXT;
    if c.Entry <> nil then
      for i := 0 to c.Entry.AttrCount - 1 do
        if ASensitive.IsSensitive(c.Entry.Attrs[i].Description) then
          for j := c.Entry.Attrs[i].ValueCount - 1 downto 0 do
          begin
            c.Entry.Attrs[i].DeleteValue(j);
            c.Entry.Attrs[i].AddValue(MASK_TEXT);
          end;
    Result := LdifChangeToString(c);
  finally
    c.Free;
  end;
end;

function ConfirmChanges(AOwner: TComponent; const AServer, ABadge: string;
  const AChanges: array of TLdapChange; ASensitive: TSensitivePolicy;
  AReadOnly: Boolean; const AExtraNote: string): Boolean;
var
  d: TRtDialog;
  memo: TMemo;
  i: Integer;
  kinds: string;
  suffix: string;
  applyBtn: TButton;
  maxShown: Integer;
begin
  Result := False;
  if Length(AChanges) = 0 then Exit;
  if Assigned(ConfirmChangesOverride) then
    Exit(ConfirmChangesOverride(AChanges, AReadOnly) and not AReadOnly);
  d := TRtDialog.CreateDialog(AOwner, rsPreviewTitle, 760, 560);
  try
    d.SetIcon('git-compare');
    d.SetTarget(AServer, ABadge);
    kinds := ChangeKindName(AChanges[0].Kind);
    for i := 1 to High(AChanges) do
      if ChangeKindName(AChanges[i].Kind) <> kinds then
        kinds := 'mixed operations';
    if Length(AChanges) = 1 then suffix := 'y' else suffix := 'ies';
    MakeLabel(d.Body, Format(rsPreviewSummary, [kinds, Length(AChanges), suffix])).Font.Style := [];
    AddKindCounts(d.Body, AChanges);
    if Length(AChanges) = 1 then
      MakeLabel(d.Body, AChanges[0].Dn)
    else
      MakeLabel(d.Body, rsPreviewNotAtomic);
    if AExtraNote <> '' then
      MakeLabel(d.Body, AExtraNote).Font.Color := DialogStateColor(usWarning);
    if AReadOnly then
      MakeLabel(d.Body, rsPreviewReadOnly).Font.Color := DialogStateColor(usError);
    memo := MakeMemo(d.Body);
    memo.ReadOnly := True;
    memo.Lines.BeginUpdate;
    try
      maxShown := 2000;
      for i := 0 to High(AChanges) do
      begin
        if i >= maxShown then
        begin
          memo.Lines.Add(Format('# ... %d more operations', [Length(AChanges) - maxShown]));
          Break;
        end;
        memo.Lines.Add(MaskedChangeLdif(AChanges[i], ASensitive));
      end;
    finally
      memo.Lines.EndUpdate;
    end;
    applyBtn := d.AddButton(rsPreviewApply, mrOk, False);
    applyBtn.Enabled := not AReadOnly;
    d.AddButton(rsPreviewCancel, mrCancel, True, True);
    d.ApplyTheme;
    Result := (d.ShowModal = mrOk) and not AReadOnly;
  finally
    d.Free;
  end;
end;

end.
