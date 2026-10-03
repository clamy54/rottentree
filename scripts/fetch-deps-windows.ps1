# Recupere les bibliotheques natives Windows x86-64 depuis les paquets MSYS2
# epingles ci-dessous, verifie leur SHA-256 et copie les DLL dans bin\.
# Aucun telechargement n'a lieu au lancement de Rottentree: ce script sert a la
# construction et au packaging, pas a l'execution.
#
# Usage: powershell -File scripts\fetch-deps-windows.ps1 [-Force]
#
# Copyright (C) 2023-2026 Cyril LAMY
# SPDX-License-Identifier: GPL-3.0-or-later
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$cache = Join-Path $root 'third_party\cache'
$bin = Join-Path $root 'bin'
$tools = Join-Path $root 'third_party\tools'
$mirror = 'https://repo.msys2.org/mingw/mingw64'

# Toute mise a jour passe par ce tableau, puis par packaging\windows\DEPS.md
# et licenses\THIRD-PARTY-NOTICES.md. Une OpenSSL changee en douce, c'est un
# rapport d'incident ecrit par quelqu'un d'autre.
$packages = @(
  @{ Name = 'mingw-w64-x86_64-openldap-2.6.12-1-any.pkg.tar.zst';
     Sha256 = '5f5702423b3eb86c3181d830ce03de5ec683017b9a15ed9c6b20e94f55304074';
     Dlls = @('libldap.dll', 'liblber.dll') },
  @{ Name = 'mingw-w64-x86_64-cyrus-sasl-2.1.28-6-any.pkg.tar.zst';
     Sha256 = 'c91ffefdc4835a793fba99993433bbe5915d9367cdf8bd16ad27a16526f9eb3a';
     Dlls = @('libsasl2-3.dll') },
  @{ Name = 'mingw-w64-x86_64-openssl-3.6.4-1-any.pkg.tar.zst';
     Sha256 = 'd613ab4e1b5af9e95cde16895765e1be53ab05657d8d51ff2707d4e99c29c55b';
     Dlls = @('libcrypto-3-x64.dll', 'libssl-3-x64.dll');
     Tools = @('openssl.exe') },
  @{ Name = 'mingw-w64-x86_64-libsodium-1.0.22-3-any.pkg.tar.zst';
     Sha256 = 'e8d8bc169fa122eccfc3e4252615937a62fa0bd6ca21ed4912bac48d6ed2f870';
     Dlls = @('libsodium-26.dll') },
  @{ Name = 'mingw-w64-x86_64-sqlite3-3.53.4-1-any.pkg.tar.zst';
     Sha256 = 'baca1837b4f5ae4ea39198c4ec98459a446eb4af17459ad6376d734b285b4ff0';
     Dlls = @('libsqlite3-0.dll') },
  @{ Name = 'mingw-w64-x86_64-argon2-20190702-2-any.pkg.tar.zst';
     Sha256 = '34c21ec8fec34270a6916fef163d3f08899e9b20f199858175af4603b0c1e25c';
     Dlls = @('libargon2.dll') }
)

# bsdtar de Windows 10+ lit le zstd; celui de Git Bash non.
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path $tar)) { Write-Error 'tar.exe (bsdtar) introuvable dans System32.' }

New-Item -ItemType Directory -Force $cache, $bin, $tools | Out-Null

foreach ($p in $packages) {
  $file = Join-Path $cache $p.Name
  if ($Force -or -not (Test-Path $file)) {
    Write-Host "telechargement: $($p.Name)"
    Invoke-WebRequest -UseBasicParsing -Uri "$mirror/$($p.Name)" -OutFile $file
  }
  $sum = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant()
  if ($sum -ne $p.Sha256) {
    Remove-Item $file -Force
    Write-Error "empreinte inattendue pour $($p.Name): $sum"
  }
  $work = Join-Path $cache ([IO.Path]::GetFileNameWithoutExtension($p.Name) + '.d')
  if (Test-Path $work) { Remove-Item -Recurse -Force $work }
  New-Item -ItemType Directory -Force $work | Out-Null
  & $tar -xf $file -C $work
  if ($LASTEXITCODE -ne 0) { Write-Error "extraction impossible: $($p.Name)" }
  foreach ($d in $p.Dlls) {
    Copy-Item -Force (Join-Path $work "mingw64\bin\$d") $bin
  }
  if ($p.Tools) {
    foreach ($t in $p.Tools) {
      Copy-Item -Force (Join-Path $work "mingw64\bin\$t") $tools
    }
  }
}

Write-Host "OK -> $bin"
