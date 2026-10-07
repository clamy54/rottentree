# Construction Windows: lazbuild sur app\rottentree.lpi, executable dans bin\.
# Prealable: scripts\fetch-deps-windows.ps1 (bibliotheques natives epinglees).
# Usage: powershell -File scripts\build.ps1 [-Release]
#
# Copyright (C) 2023-2026 Cyril LAMY
# SPDX-License-Identifier: GPL-3.0-or-later
param([switch]$Release)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'toolchain.ps1')

$lpi = Join-Path $root 'app\rottentree.lpi'
# Aucun processus n'est tue par son nom: une instance ouverte peut porter des
# modifications ou une ecriture LDAP en cours. Elle doit etre fermee normalement.
$exe = Join-Path $root 'bin\rottentree.exe'
$busy = Get-Process rottentree -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -and ([IO.Path]::GetFullPath($_.Path) -ieq [IO.Path]::GetFullPath($exe)) }
if ($busy) {
  Write-Error "bin\rottentree.exe est en cours d'execution (PID $($busy.Id -join ', ')): fermer l'application avant de compiler"
  exit 3
}

if (-not (Test-Path (Join-Path $root 'rottenui\rottenui.lpk'))) {
  Write-Error 'rottenui\ est vide: git submodule update --init'
  exit 3
}

# projet genere: une unite ou une ressource oubliee dans le .lpi est une
# erreur; de meme une ressource de RottenUI (fontes, icones, themes) dont le
# .res n'a pas ete reconstruit
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if ($python) {
  & $python (Join-Path $PSScriptRoot 'gen_lpi.py') --check
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & $python (Join-Path $root 'rottenui\tools\gen_res.py') --check
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
  Write-Warning 'python introuvable: coherence de app\rottentree.lpi et des ressources RottenUI non verifiee'
}

$buildArgs = @()
if ($Release) { $buildArgs += '--build-mode=Release' }
$buildArgs += $lpi

Write-Host "lazbuild: $LazBuildExe"
# lazbuild resout les chemins de ressources par rapport au dossier courant
Push-Location (Join-Path $root 'app')
try {
  & $LazBuildExe @buildArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}
# l'Explorateur garde l'icone d'un fichier recompile au meme chemin: il est
# prevenu que l'executable a change (SHChangeNotify, SHCNE_UPDATEITEM)
try {
  Add-Type -Namespace RtBuild -Name Shell -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern void SHChangeNotify(int eventId, uint flags, string item1, System.IntPtr item2);
'@ -ErrorAction Stop
  # SHCNE_UPDATEITEM = 0x2000; SHCNF_PATHW (0x0005) | SHCNF_FLUSH (0x1000)
  [RtBuild.Shell]::SHChangeNotify(0x2000, 0x1005, $exe, [IntPtr]::Zero)
} catch {
  Write-Warning "notification de l'Explorateur impossible: $($_.Exception.Message)"
}
Write-Host "OK -> $root\bin\rottentree.exe"
