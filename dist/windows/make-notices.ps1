# THIRD-PARTY-NOTICES.md en texte brut: Inno affiche tel quel, markdown compris.
# Lance par rottentree.iss a chaque compilation, donc jamais perime.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here '..\..\licenses\THIRD-PARTY-NOTICES.md'
$dst  = Join-Path $here 'third-party.txt'

$out = New-Object System.Collections.Generic.List[string]

function Inline([string]$s) {
  # libelle = cible: pas de "X (X)"
  $s = [regex]::Replace($s, '\[`?([^\]]+?)`?\]\(([^)]+)\)', {
    param($m)
    if ($m.Groups[1].Value -eq $m.Groups[2].Value) { $m.Groups[1].Value }
    else { $m.Groups[1].Value + ' (' + $m.Groups[2].Value + ')' }
  })
  $s = $s -replace '<(https?://[^>]+)>', '$1'  # url entre chevrons
  $s = $s -replace '`', ''                     # code
  # les emphases enjambent des lignes: par paires, des ** resteraient orphelins
  $s = $s -replace '\*', ''
  return $s.TrimEnd()
}

$inFence = $false
foreach ($raw in Get-Content -LiteralPath $src -Encoding UTF8) {
  $l = $raw.TrimEnd()

  if ($l -match '^\s*```') { $inFence = -not $inFence; continue }
  if ($inFence) { $out.Add('    ' + $l); continue }        # bloc de code, brut

  if ($l -match '^\s*\|\s*-{2,}') { continue }             # separateur de tableau
  if ($l -match '^\s*\|(\s*\|)+\s*$') { continue }         # ligne de tableau vide
  if ($l -match '^\s*---+\s*$') { $out.Add(''); $out.Add(('-' * 70)); $out.Add(''); continue }

  if ($l -match '^\s*\|(.*)\|\s*$') {                      # | cle | valeur |
    $cells = $Matches[1] -split '\|' | ForEach-Object { (Inline $_).Trim() }
    $cells = @($cells | Where-Object { $_ -ne '' })
    if ($cells.Count -ge 3) { $out.Add(('  - {0}: {1}' -f $cells[0], ($cells[1..($cells.Count-1)] -join ' / '))) }
    elseif ($cells.Count -eq 2) { $out.Add(('  {0,-14}{1}' -f ($cells[0] + ':'), $cells[1])) }
    elseif ($cells.Count -eq 1) { $out.Add('  ' + $cells[0]) }
    continue
  }

  if ($l -match '^(#{1,6})\s+(.*)$') {                     # titre: souligne
    $txt = Inline $Matches[2]
    $out.Add('')
    $out.Add($txt)
    $out.Add(('=' * $txt.Length))
    continue
  }

  $out.Add((Inline $l))
}

# pas plus d'une ligne vide d'affilee
$clean = New-Object System.Collections.Generic.List[string]
foreach ($l in $out) {
  if ($l -eq '' -and $clean.Count -gt 0 -and $clean[$clean.Count-1] -eq '') { continue }
  $clean.Add($l)
}

# BOM obligatoire: sans lui, le RichEdit d'Inno lit les accents en ANSI
$text = ($clean -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($dst, $text, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "OK -> $dst ($($clean.Count) lignes)"
