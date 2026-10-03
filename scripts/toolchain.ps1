# Localise fpc et lazbuild. Importe par les autres scripts (dot-source).
#
# Copyright (C) 2023-2026 Cyril LAMY
# SPDX-License-Identifier: GPL-3.0-or-later

$LazBuildExe = (Get-Command lazbuild -ErrorAction SilentlyContinue).Source
if (-not $LazBuildExe) {
  foreach ($c in @('C:\lazarus\lazbuild.exe', 'C:\fpcupdeluxe\lazarus\lazbuild.exe',
      "$env:USERPROFILE\fpcupdeluxe\lazarus\lazbuild.exe",
      'C:\Program Files\Lazarus\lazbuild.exe')) {
    if (Test-Path $c) { $LazBuildExe = $c; break }
  }
}
if (-not $LazBuildExe) { Write-Error 'lazbuild introuvable. Ajouter Lazarus au PATH.' }

$LazarusDir = Split-Path -Parent $LazBuildExe
$FpcExe = (Get-Command fpc -ErrorAction SilentlyContinue).Source
if (-not $FpcExe) {
  $found = Get-ChildItem -Path (Join-Path $LazarusDir 'fpc') -Recurse -Filter 'fpc.exe' `
    -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'x86_64-win64' } |
    Select-Object -First 1
  if ($found) { $FpcExe = $found.FullName }
}
if (-not $FpcExe) { Write-Error 'fpc introuvable.' }

# Versions epinglees: pas de changement de compilateur en douce entre deux
# livraisons. ROTTENTREE_ALLOW_TOOLCHAIN=1 autorise un essai avec une autre
# version, signale a chaque construction pour que personne ne l'oublie.
$ExpectedFpc = '3.2.2'
$ExpectedLazarus = '4.8'
$fpcVersion = "$(& $FpcExe -iV | Select-Object -First 1)".Trim()
$lazVersion = "$(& $LazBuildExe --version | Select-Object -First 1)".Trim()
if (($fpcVersion -ne $ExpectedFpc) -or ($lazVersion -ne $ExpectedLazarus)) {
  $msg = "chaine de compilation FPC $fpcVersion / Lazarus $lazVersion; attendu FPC $ExpectedFpc / Lazarus $ExpectedLazarus"
  if ($env:ROTTENTREE_ALLOW_TOOLCHAIN -eq '1') { Write-Warning $msg } else { Write-Error $msg }
}
