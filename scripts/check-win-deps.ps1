# Les DLL de bin\ contre les empreintes de packaging\windows\DEPS.md.
# Un document de provenance que personne ne verifie finit toujours par mentir.
#
# Usage: powershell -File scripts\check-win-deps.ps1
#
# Copyright (C) 2023-2026 Cyril LAMY
# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$doc = Join-Path $root 'packaging\windows\DEPS.md'
$bin = Join-Path $root 'bin'

$expected = @{}
foreach ($line in Get-Content -LiteralPath $doc) {
  if ($line -match '^\|\s*`([^`]+\.dll)`\s*\|[^|]*\|\s*`([0-9a-f]{64})`\s*\|') {
    $expected[$Matches[1]] = $Matches[2]
  }
}
if ($expected.Count -eq 0) { Write-Error "aucune DLL listee dans $doc" }

$bad = 0
foreach ($name in $expected.Keys | Sort-Object) {
  $file = Join-Path $bin $name
  if (-not (Test-Path -LiteralPath $file)) {
    Write-Host "ABSENTE  $name"
    $bad++
    continue
  }
  $sum = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
  if ($sum -ne $expected[$name]) {
    Write-Host "DIFFERE  $name ($sum)"
    $bad++
  } else {
    Write-Host "OK       $name"
  }
}
foreach ($f in Get-ChildItem -LiteralPath $bin -Filter '*.dll') {
  if (-not $expected.ContainsKey($f.Name)) {
    Write-Host "INCONNUE $($f.Name): presente dans bin\ mais absente de DEPS.md"
    $bad++
  }
}
if ($bad -gt 0) { Write-Error "$bad DLL non conforme(s) a packaging\windows\DEPS.md" }
Write-Host "DLL conformes a packaging\windows\DEPS.md ($($expected.Count))"
