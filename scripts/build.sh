#!/usr/bin/env bash
# Construction Linux (GTK3) et macOS (Cocoa): lazbuild sur app/rottentree.lpi,
# executable dans bin/rottentree.
# Usage: scripts/build.sh [--release]
# Variables: LAZBUILD (chemin de lazbuild), RT_WIDGETSET (gtk3, gtk2, qt5...)
#
# Linux: le GTK3 de Lazarus 4.8 boucle sur InvalidatePreferredSize et rend les
# champs de travers. Il faut Lazarus trunk (5.99) pour GTK3, ou forcer gtk2 et
# assumer ce qu'on y perd.
#
# Copyright (C) 2023-2026 Cyril LAMY
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "erreur: $*" >&2; exit 1; }

mode=()
case "${1:-}" in
  --release) mode=(--build-mode=Release) ;;
  "") ;;
  *) die "usage: scripts/build.sh [--release]" ;;
esac

case "$(uname -s)" in
  Linux) ws="${RT_WIDGETSET:-gtk3}" ;;
  Darwin) ws="${RT_WIDGETSET:-cocoa}" ;;
  *) die "systeme non pris en charge (Windows: scripts\\build.ps1)" ;;
esac

if [ -z "${LAZBUILD:-}" ]; then
  LAZBUILD="$(command -v lazbuild || true)"
  for c in /Applications/Lazarus/lazbuild "$HOME/fpcupdeluxe/lazarus/lazbuild" \
      "$HOME/lazarus/lazbuild" /usr/local/share/lazarus/lazbuild /usr/lib/lazarus/default/lazbuild; do
    [ -n "$LAZBUILD" ] && break
    [ -x "$c" ] && LAZBUILD="$c"
  done
fi
[ -n "$LAZBUILD" ] && [ -x "$LAZBUILD" ] || die "lazbuild introuvable (variable LAZBUILD)"

python3 "$ROOT/scripts/gen_lpi.py" --check
python3 "$ROOT/rottenui/tools/gen_res.py" --check

echo "lazbuild: $LAZBUILD ($("$LAZBUILD" --version | head -1)), widgetset $ws"
# lazbuild resout les chemins des ressources par rapport au repertoire
# courant, pas au .lpi. Lance depuis la racine, il cherche l'icone et les
# licences un etage trop haut.
(cd "$ROOT/app" && "$LAZBUILD" --ws="$ws" "${mode[@]}" rottentree.lpi)
echo "OK -> $ROOT/bin/rottentree"
