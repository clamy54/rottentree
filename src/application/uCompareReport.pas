// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uCompareReport;

{$mode objfpc}{$H+}

// Rapports de comparaison: JSON versionne, HTML statique, CSV neutralise. Les valeurs sensibles
// restent masquees sauf demande expresse: un rapport finit toujours en piece jointe chez quelqu'un.

interface

uses
  SysUtils, Classes, uCompareRunner, uSensitive;

type
  TReportFormat = (rfJson, rfHtml, rfCsv);

procedure WriteCompareReport(AFormat: TReportFormat; AOut: TStream; ARun: TCompareRunResult;
  ASensitive: TSensitivePolicy; AIncludeSensitive: Boolean);

function ReportFormatExtension(AFormat: TReportFormat): string;

implementation

uses
  uCompareModel, uCompareEngine, uCanonical, uSafeOutput, uCancel, uCsn, uVersion,
  uSearchModel, uRtBytes;

function ReportFormatExtension(AFormat: TReportFormat): string;
begin
  case AFormat of
    rfJson: Result := '.json';
    rfHtml: Result := '.html';
  else
    Result := '.csv';
  end;
end;

function PersistenceName(P: TPersistence): string;
begin
  case P of
    psTransient: Result := 'transient divergence observed';
    psPersistent: Result := 'persistent divergence observed';
  else
    Result := 'not read again';
  end;
end;

function SourceName(ARun: TCompareRunResult; AIndex: Integer): string;
begin
  Result := ARun.Engine.Profile.Sources[AIndex].Name;
end;

function MaskAttr(ASensitive: TSensitivePolicy; AInclude: Boolean; const AAttr: string): Boolean;
begin
  Result := (not AInclude) and (ASensitive <> nil) and ASensitive.IsSensitive(AAttr);
end;

procedure WriteJson(AOut: TStream; ARun: TCompareRunResult; ASensitive: TSensitivePolicy;
  AInclude: Boolean);
var
  w: TJsonWriter;
  e: TComparisonEngine;
  p: TComparisonProfile;
  i, j, k: Integer;
  obs: TSourceObservation;
  d: TEntryDiff;
  masked: Boolean;
begin
  e := ARun.Engine;
  p := e.Profile;
  w := TJsonWriter.Create(AOut, True);
  try
    w.BeginObject;
    w.KeyInt('reportFormatVersion', REPORT_FORMAT_VERSION);
    w.KeyInt('canonicalFormatVersion', CANONICAL_FORMAT_VERSION);
    w.KeyStr('generator', RT_APP_NAME + ' ' + RT_VERSION);
    w.KeyStr('caveat', PERMANENT_CAVEAT);
    w.KeyBool('sensitiveValuesIncluded', AInclude);
    w.Key('verdict');
    w.BeginObject;
    w.KeyStr('headline', ARun.Verdict.Headline);
    w.KeyStr('execution', ExecutionName(ARun.Verdict.Execution));
    w.KeyStr('coverage', CoverageName(ARun.Verdict.Coverage));
    w.KeyStr('stability', StabilityName(ARun.Verdict.Stability));
    w.KeyStr('result', ResultStateName(ARun.Verdict.Result));
    w.Key('coverageReasons');
    w.BeginArray;
    for i := 0 to High(ARun.Verdict.CoverageReasons) do w.Str(ARun.Verdict.CoverageReasons[i]);
    w.EndArray;
    w.Key('stabilityReasons');
    w.BeginArray;
    for i := 0 to High(ARun.Verdict.StabilityReasons) do w.Str(ARun.Verdict.StabilityReasons[i]);
    w.EndArray;
    w.EndObject;
    w.Key('run');
    w.BeginObject;
    w.KeyStr('startedUtc', FormatUtcIso(ARun.StartedUtc));
    w.KeyStr('finishedUtc', FormatUtcIso(ARun.FinishedUtc));
    w.KeyInt('durationMs', ARun.DurationMs);
    w.KeyInt('passes', ARun.Passes);
    w.KeyBool('markersMoved', ARun.MarkersMoved);
    w.Key('notes');
    w.BeginArray;
    for i := 0 to High(ARun.Notes) do w.Str(ARun.Notes[i]);
    w.EndArray;
    w.EndObject;
    w.Key('parameters');
    w.BeginObject;
    w.KeyStr('name', p.Name);
    w.KeyStr('mode', ModeName(p.Mode));
    if p.Topology = ctReference then
      w.KeyStr('topology', 'reference: ' + p.Sources[p.ReferenceIndex].Name)
    else
      w.KeyStr('topology', 'symmetric');
    if p.Strictness = csSemantic then w.KeyStr('strictness', 'semantic') else w.KeyStr('strictness', 'strict');
    w.KeyStr('identity', IdentityName(p.Identity));
    if p.Identity = imBusinessKey then w.KeyStr('businessKey', p.BusinessKeyAttr);
    w.KeyStr('scope', ScopeName(p.Scope));
    w.KeyStr('filter', p.Filter);
    w.Key('includedAttributes');
    w.BeginArray;
    for i := 0 to p.IncludeAttrs.Count - 1 do w.Str(p.IncludeAttrs[i]);
    w.EndArray;
    w.Key('excludedAttributes');
    w.BeginArray;
    for i := 0 to p.ExcludeAttrs.Count - 1 do w.Str(p.ExcludeAttrs[i]);
    w.EndArray;
    w.KeyBool('includeOperational', p.IncludeOperational);
    w.KeyBool('rewriteDnValues', p.RewriteDnValues);
    if p.Mode = cmSample then
    begin
      w.KeyInt('sampleSize', p.SampleSize);
      w.KeyStr('sampleMethod', 'first keys ordered by SHA-256 identity hash');
    end;
    w.KeyInt('passDelaySec', p.PassDelaySec);
    w.KeyInt('stabilizationWindowSec', p.StabilizationWindowSec);
    w.KeyBool('aclAttestedByOperator', p.AclAttestation);
    w.EndObject;
    w.Key('sources');
    w.BeginArray;
    for i := 0 to High(p.Sources) do
    begin
      obs := e.Observation(i);
      w.BeginObject;
      w.KeyStr('name', obs.Name);
      w.KeyStr('endpoint', obs.Endpoint);
      w.KeyStr('transport', obs.TransportLabel);
      w.KeyStr('boundIdentity', obs.BoundIdentity);
      w.KeyStr('authzId', obs.AuthzId);
      w.KeyStr('baseDn', obs.BaseDn);
      w.KeyStr('completion', ResultCodeName(obs.Completion.ResultCode));
      w.KeyInt('entriesRead', obs.EntryCount);
      w.KeyInt('pages', obs.Completion.PageCount);
      w.KeyInt('duplicateKeys', obs.DuplicateKeys);
      w.KeyInt('truncatedEntries', obs.TruncatedEntries);
      w.KeyInt('skippedRecords', obs.SkippedRecords);
      w.KeyInt('decodeFailures', obs.Completion.DecodeFailures);
      w.KeyInt('entriesWithOmittedValues', obs.Completion.TruncatedEntries);
      w.KeyInt('missingIdentity', obs.MissingIdentity);
      w.KeyInt('outsideBase', obs.OutsideBase);
      w.KeyInt('notObservedHere', e.Counters.PerSourceAbsent[i]);
      w.KeyBool('schemaAvailable', obs.SchemaAvailable);
      w.Key('markersBefore');
      w.BeginArray;
      for j := 0 to High(obs.MarkersBefore) do w.Str(obs.MarkersBefore[j]);
      w.EndArray;
      w.Key('markersAfter');
      w.BeginArray;
      for j := 0 to High(obs.MarkersAfter) do w.Str(obs.MarkersAfter[j]);
      w.EndArray;
      w.Key('errors');
      w.BeginArray;
      for j := 0 to High(obs.Errors) do w.Str(obs.Errors[j]);
      w.EndArray;
      w.EndObject;
    end;
    w.EndArray;
    w.Key('replicationIndicators');
    w.BeginArray;
    for i := 0 to High(ARun.MarkerComparisons) do
      for j := 0 to High(ARun.MarkerComparisons[i].Sids) do
      begin
        w.BeginObject;
        w.KeyStr('a', SourceName(ARun, ARun.MarkerComparisons[i].SourceA));
        w.KeyStr('b', SourceName(ARun, ARun.MarkerComparisons[i].SourceB));
        w.KeyInt('sid', ARun.MarkerComparisons[i].Sids[j].Sid);
        w.KeyStr('stateOfB', SidStateName(ARun.MarkerComparisons[i].Sids[j].State));
        w.KeyStr('csnA', ARun.MarkerComparisons[i].Sids[j].A);
        w.KeyStr('csnB', ARun.MarkerComparisons[i].Sids[j].B);
        w.EndObject;
      end;
    w.EndArray;
    w.Key('counters');
    w.BeginObject;
    w.KeyInt('keys', e.Counters.Keys);
    w.KeyInt('equal', e.Counters.EqualKeys);
    w.KeyInt('differing', e.Counters.DifferingKeys);
    w.KeyInt('notObserved', e.Counters.MissingKeys);
    w.KeyInt('valuesDiffer', e.Counters.ContentKeys);
    w.KeyInt('renamed', e.Counters.RenamedKeys);
    w.KeyInt('ambiguous', e.Counters.AmbiguousKeys);
    w.KeyInt('transient', e.Counters.TransientKeys);
    w.KeyInt('persistent', e.Counters.PersistentKeys);
    w.EndObject;
    w.Key('differences');
    w.BeginArray;
    for i := 0 to e.DiffCount - 1 do
    begin
      d := e.Diff(i);
      w.BeginObject;
      w.KeyStr('key', d.DisplayKey);
      w.KeyStr('kinds', DiffKindsText(d.Kinds));
      w.KeyStr('persistence', PersistenceName(d.Persistence));
      w.KeyStr('objectClass', d.ObjectClass);
      w.Key('dnBySource');
      w.BeginObject;
      for j := 0 to High(d.Dns) do
        if d.Dns[j] <> '' then
          w.KeyStr(SourceName(ARun, j), d.Dns[j])
        else
          begin
            w.Key(SourceName(ARun, j));
            w.Null;
          end;
      w.EndObject;
      w.Key('variants');
      w.BeginArray;
      for j := 0 to High(d.Variants) do
      begin
        w.BeginArray;
        for k := 0 to High(d.Variants[j].Members) do
          w.Str(SourceName(ARun, d.Variants[j].Members[k]));
        w.EndArray;
      end;
      w.EndArray;
      w.Key('attributes');
      w.BeginArray;
      for j := 0 to High(d.AttrDiffs) do
      begin
        masked := MaskAttr(ASensitive, AInclude, d.AttrDiffs[j].Attr);
        w.BeginObject;
        w.KeyStr('attribute', d.AttrDiffs[j].Attr);
        w.KeyBool('semanticUndetermined', d.AttrDiffs[j].SemanticUndetermined);
        w.Key('onlyInFirstVariant');
        if masked then
          w.Str(MaskedValuesText(Length(d.AttrDiffs[j].OnlyInBase)))
        else
        begin
          w.BeginArray;
          for k := 0 to High(d.AttrDiffs[j].OnlyInBase) do w.TextOrBytes(d.AttrDiffs[j].OnlyInBase[k]);
          w.EndArray;
        end;
        w.Key('onlyInOtherVariant');
        if masked then
          w.Str(MaskedValuesText(Length(d.AttrDiffs[j].OnlyInOther)))
        else
        begin
          w.BeginArray;
          for k := 0 to High(d.AttrDiffs[j].OnlyInOther) do w.TextOrBytes(d.AttrDiffs[j].OnlyInOther[k]);
          w.EndArray;
        end;
        w.EndObject;
      end;
      w.EndArray;
      w.EndObject;
    end;
    w.EndArray;
    w.EndObject;
  finally
    w.Free;
  end;
end;

procedure Emit(AOut: TStream; const S: string);
begin
  if S <> '' then AOut.WriteBuffer(S[1], Length(S));
end;

function ValuesHtml(const AValues: array of RawByteString; AMasked: Boolean): string;
var
  i: Integer;
begin
  if AMasked then Exit(HtmlEscape(MaskedValuesText(Length(AValues))));
  Result := '';
  for i := 0 to High(AValues) do
  begin
    if i > 0 then Result := Result + '<br>';
    Result := Result + HtmlDisplayValue(AValues[i]);
  end;
end;

procedure WriteHtml(AOut: TStream; ARun: TCompareRunResult; ASensitive: TSensitivePolicy;
  AInclude: Boolean);
var
  e: TComparisonEngine;
  p: TComparisonProfile;
  i, j, k: Integer;
  obs: TSourceObservation;
  d: TEntryDiff;
  members: string;
begin
  e := ARun.Engine;
  p := e.Profile;
  // HTML inerte: aucun script, aucune ressource externe, CSP restrictive. Les valeurs viennent de
  // l'annuaire, donc de n'importe qui.
  Emit(AOut, '<!DOCTYPE html>'#10'<html lang="en"><head><meta charset="utf-8">' +
    '<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''">' +
    '<title>' + HtmlEscape('Comparison report - ' + p.Name) + '</title><style>' +
    'body{font-family:sans-serif;margin:24px;color:#1d1d1d;background:#fff}' +
    'table{border-collapse:collapse;margin:8px 0 20px}td,th{border:1px solid #bbb;padding:4px 8px;' +
    'vertical-align:top;text-align:left}th{background:#eee}.caveat{border-left:4px solid #b58900;' +
    'padding:6px 12px;background:#fdf6e3}code{word-break:break-all}</style></head><body>'#10);
  Emit(AOut, '<h1>' + HtmlEscape(ARun.Verdict.Headline) + '</h1>'#10);
  Emit(AOut, '<p class="caveat">' + HtmlEscape(PERMANENT_CAVEAT) + '</p>'#10);
  Emit(AOut, '<table><tr><th>Execution</th><td>' + HtmlEscape(ExecutionName(ARun.Verdict.Execution)) +
    '</td></tr><tr><th>Coverage</th><td>' + HtmlEscape(CoverageName(ARun.Verdict.Coverage)));
  for i := 0 to High(ARun.Verdict.CoverageReasons) do
    Emit(AOut, '<br>' + HtmlEscape(ARun.Verdict.CoverageReasons[i]));
  Emit(AOut, '</td></tr><tr><th>Stability</th><td>' + HtmlEscape(StabilityName(ARun.Verdict.Stability)));
  for i := 0 to High(ARun.Verdict.StabilityReasons) do
    Emit(AOut, '<br>' + HtmlEscape(ARun.Verdict.StabilityReasons[i]));
  Emit(AOut, '</td></tr><tr><th>Result</th><td>' + HtmlEscape(ResultStateName(ARun.Verdict.Result)) +
    '</td></tr><tr><th>Mode</th><td>' + HtmlEscape(ModeName(p.Mode) + ', identity: ' +
    IdentityName(p.Identity) + ', scope: ' + ScopeName(p.Scope) + ', filter: ' + p.Filter) +
    '</td></tr><tr><th>Run (UTC)</th><td>' + HtmlEscape(FormatUtcIso(ARun.StartedUtc) + ' - ' +
    FormatUtcIso(ARun.FinishedUtc) + Format(', %d pass(es), %d ms', [ARun.Passes, ARun.DurationMs])) +
    '</td></tr><tr><th>Excluded attributes</th><td>' + HtmlEscape(p.ExcludeAttrs.CommaText) +
    '</td></tr><tr><th>Sensitive values</th><td>');
  if AInclude then Emit(AOut, 'INCLUDED') else Emit(AOut, 'masked');
  Emit(AOut, '</td></tr></table>'#10);
  for i := 0 to High(ARun.Notes) do
    Emit(AOut, '<p>' + HtmlEscape(ARun.Notes[i]) + '</p>'#10);
  Emit(AOut, '<h2>Directories</h2><table><tr><th>Name</th><th>Endpoint</th><th>Transport</th>' +
    '<th>Identity</th><th>Base</th><th>Read</th><th>Entries</th><th>Not observed here</th>' +
    '<th>Duplicates</th><th>Markers before / after</th><th>Errors</th></tr>'#10);
  for i := 0 to High(p.Sources) do
  begin
    obs := e.Observation(i);
    Emit(AOut, '<tr><td>' + HtmlEscape(obs.Name) + '</td><td>' + HtmlEscape(obs.Endpoint) +
      '</td><td>' + HtmlEscape(obs.TransportLabel) + '</td><td>' + HtmlEscape(obs.BoundIdentity) +
      '<br>' + HtmlEscape(obs.AuthzId) + '</td><td>' + HtmlEscape(obs.BaseDn) + '</td><td>' +
      HtmlEscape(ResultCodeName(obs.Completion.ResultCode)) + '</td><td>' + IntToStr(obs.EntryCount) +
      '</td><td>' + IntToStr(e.Counters.PerSourceAbsent[i]) + '</td><td>' + IntToStr(obs.DuplicateKeys) +
      '</td><td>');
    for j := 0 to High(obs.MarkersBefore) do
      Emit(AOut, HtmlEscape(obs.MarkersBefore[j]) + '<br>');
    Emit(AOut, '/<br>');
    for j := 0 to High(obs.MarkersAfter) do
      Emit(AOut, HtmlEscape(obs.MarkersAfter[j]) + '<br>');
    Emit(AOut, '</td><td>');
    for j := 0 to High(obs.Errors) do
      Emit(AOut, HtmlEscape(obs.Errors[j]) + '<br>');
    Emit(AOut, '</td></tr>'#10);
  end;
  Emit(AOut, '</table>'#10);
  Emit(AOut, Format('<h2>Counters</h2><p>%d keys, %d equal, %d differing (%d not observed everywhere, ' +
    '%d values differ, %d renamed, %d ambiguous), %d transient, %d persistent.</p>'#10,
    [e.Counters.Keys, e.Counters.EqualKeys, e.Counters.DifferingKeys, e.Counters.MissingKeys,
     e.Counters.ContentKeys, e.Counters.RenamedKeys, e.Counters.AmbiguousKeys,
     e.Counters.TransientKeys, e.Counters.PersistentKeys]));
  Emit(AOut, '<h2>Differences</h2>'#10);
  for i := 0 to e.DiffCount - 1 do
  begin
    d := e.Diff(i);
    Emit(AOut, '<h3><code>' + HtmlEscape(d.DisplayKey) + '</code></h3><p>' +
      HtmlEscape(DiffKindsText(d.Kinds) + ' - ' + PersistenceName(d.Persistence)) + '</p><table>');
    for j := 0 to High(d.Dns) do
      if d.Dns[j] <> '' then
        Emit(AOut, '<tr><th>' + HtmlEscape(SourceName(ARun, j)) + '</th><td><code>' +
          HtmlEscape(d.Dns[j]) + '</code></td></tr>')
      else
        Emit(AOut, '<tr><th>' + HtmlEscape(SourceName(ARun, j)) + '</th><td>not observed</td></tr>');
    for j := 0 to High(d.Variants) do
    begin
      members := '';
      for k := 0 to High(d.Variants[j].Members) do
      begin
        if members <> '' then members := members + ', ';
        members := members + SourceName(ARun, d.Variants[j].Members[k]);
      end;
      Emit(AOut, Format('<tr><th>Variant %d</th><td>%s</td></tr>', [j + 1, HtmlEscape(members)]));
    end;
    Emit(AOut, '</table>');
    if Length(d.AttrDiffs) > 0 then
    begin
      Emit(AOut, '<table><tr><th>Attribute</th><th>Only in first variant</th><th>Only in other variant</th></tr>');
      for j := 0 to High(d.AttrDiffs) do
      begin
        Emit(AOut, '<tr><td>' + HtmlEscape(d.AttrDiffs[j].Attr));
        if d.AttrDiffs[j].SemanticUndetermined then
          Emit(AOut, '<br>(semantic equivalence undetermined)');
        Emit(AOut, '</td><td>' + ValuesHtml(d.AttrDiffs[j].OnlyInBase,
          MaskAttr(ASensitive, AInclude, d.AttrDiffs[j].Attr)) + '</td><td>' +
          ValuesHtml(d.AttrDiffs[j].OnlyInOther, MaskAttr(ASensitive, AInclude, d.AttrDiffs[j].Attr)) +
          '</td></tr>');
      end;
      Emit(AOut, '</table>'#10);
    end;
  end;
  Emit(AOut, '<p>' + HtmlEscape(RT_APP_NAME + ' ' + RT_VERSION) + '</p></body></html>'#10);
end;

procedure WriteCsv(AOut: TStream; ARun: TCompareRunResult; ASensitive: TSensitivePolicy;
  AInclude: Boolean);
var
  w: TCsvWriter;
  e: TComparisonEngine;
  i, j, k: Integer;
  d: TEntryDiff;
  masked: Boolean;

  function Joined(const AValues: array of RawByteString): RawByteString;
  var
    n: Integer;
  begin
    Result := '';
    for n := 0 to High(AValues) do
    begin
      if n > 0 then Result := Result + ' | ';
      if IsValidUtf8(AValues[n]) then
        Result := Result + AValues[n]
      else
        Result := Result + 'base64:' + Base64EncodeStr(AValues[n]);
    end;
  end;

begin
  e := ARun.Engine;
  w := TCsvWriter.Create(AOut, DefaultCsvOptions);
  try
    w.AddCell('# ' + ARun.Verdict.Headline);
    w.EndRow;
    w.AddCell('# ' + PERMANENT_CAVEAT);
    w.EndRow;
    w.AddCell('key');
    w.AddCell('kinds');
    w.AddCell('persistence');
    w.AddCell('directory');
    w.AddCell('dn');
    w.AddCell('attribute');
    w.AddCell('only in first variant');
    w.AddCell('only in other variant');
    w.EndRow;
    for i := 0 to e.DiffCount - 1 do
    begin
      d := e.Diff(i);
      for j := 0 to High(d.Dns) do
      begin
        w.AddCell(d.DisplayKey);
        w.AddCell(DiffKindsText(d.Kinds));
        w.AddCell(PersistenceName(d.Persistence));
        w.AddCell(SourceName(ARun, j));
        if d.Dns[j] <> '' then w.AddCell(d.Dns[j]) else w.AddCell('(not observed)');
        w.AddCell('');
        w.AddCell('');
        w.AddCell('');
        w.EndRow;
      end;
      for k := 0 to High(d.AttrDiffs) do
      begin
        masked := MaskAttr(ASensitive, AInclude, d.AttrDiffs[k].Attr);
        w.AddCell(d.DisplayKey);
        w.AddCell(DiffKindsText(d.Kinds));
        w.AddCell(PersistenceName(d.Persistence));
        w.AddCell('');
        w.AddCell('');
        w.AddCell(d.AttrDiffs[k].Attr);
        if masked then
        begin
          w.AddCell(MaskedValuesText(Length(d.AttrDiffs[k].OnlyInBase)));
          w.AddCell(MaskedValuesText(Length(d.AttrDiffs[k].OnlyInOther)));
        end
        else
        begin
          w.AddCell(Joined(d.AttrDiffs[k].OnlyInBase));
          w.AddCell(Joined(d.AttrDiffs[k].OnlyInOther));
        end;
        w.EndRow;
      end;
    end;
  finally
    w.Free;
  end;
end;

procedure WriteCompareReport(AFormat: TReportFormat; AOut: TStream; ARun: TCompareRunResult;
  ASensitive: TSensitivePolicy; AIncludeSensitive: Boolean);
begin
  if (ARun = nil) or (ARun.Engine = nil) then
    raise Exception.Create('No comparison result to report.');
  case AFormat of
    rfJson: WriteJson(AOut, ARun, ASensitive, AIncludeSensitive);
    rfHtml: WriteHtml(AOut, ARun, ASensitive, AIncludeSensitive);
    rfCsv: WriteCsv(AOut, ARun, ASensitive, AIncludeSensitive);
  end;
end;

end.
