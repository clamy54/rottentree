#!/usr/bin/env bash
# Paquet macOS: construit Rottentree (Release, Cocoa), assemble
# dist/macos/build/Rottentree.app avec ses bibliotheques natives dans Contents/Frameworks
# (premier dossier de recherche de uNativeLib sous Darwin), signe le tout et
# produit une archive zip.
#
# Les bibliotheques viennent de Homebrew (brew install openldap openssl@3
# libsodium sqlite argon2): leurs chemins /opt/homebrew sont reecrits en
# @loader_path pour que le paquet ne depende plus de Homebrew. libsasl2, libz
# et libresolv restent celles du systeme. Le paquet herite du systeme minimal
# des bouteilles Homebrew (LSMinimumSystemVersion calcule ci-dessous).
#
# Signature: ROTTENTREE_SIGN_IDENTITY="Developer ID Application: ..." pour une
# identite reelle (runtime renforce + horodatage); sinon signature ad hoc,
# valable sur cette machine mais refusee par Gatekeeper ailleurs.
#
# Usage: scripts/package-macos.sh
# Variables: LAZBUILD, ROTTENTREE_SIGN_IDENTITY, ROTTENTREE_BUNDLE_ID
#
# Copyright (C) 2023-2026 Cyril LAMY
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/macos/build"
APP="$DIST/Rottentree.app"
IDENTITY="${ROTTENTREE_SIGN_IDENTITY:--}"
BUNDLE_ID="${ROTTENTREE_BUNDLE_ID:-io.github.clamy54.rottentree}"

# formule Homebrew:fichier, nom attendu par src/**/u*Api.pas (LibNames)
LIBS=(
  "openldap:libldap.2.dylib"
  "openldap:liblber.2.dylib"
  "openssl@3:libssl.3.dylib"
  "openssl@3:libcrypto.3.dylib"
  "libsodium:libsodium.26.dylib"
  "sqlite:libsqlite3.0.dylib"
  "argon2:libargon2.1.dylib"
)

die() { echo "erreur: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "script reserve a macOS"

if [ -z "${LAZBUILD:-}" ]; then
  LAZBUILD="$(command -v lazbuild || true)"
  for c in /Applications/Lazarus/lazbuild "$HOME/fpcupdeluxe/lazarus/lazbuild" \
      "$HOME/lazarus/lazbuild" "$HOME/Downloads/lazarus/lazbuild"; do
    [ -n "$LAZBUILD" ] && break
    [ -x "$c" ] && LAZBUILD="$c"
  done
fi
[ -n "$LAZBUILD" ] && [ -x "$LAZBUILD" ] || die "lazbuild introuvable (variable LAZBUILD)"
command -v brew >/dev/null || die "Homebrew introuvable"

# projet genere: meme controle de coherence que scripts/build.ps1
python3 "$ROOT/scripts/gen_lpi.py" --check
python3 "$ROOT/rottenui/tools/gen_res.py" --check

mkdir -p "$DIST"
echo "lazbuild: $LAZBUILD"
# lazbuild resout les chemins de ressources par rapport au dossier courant
(cd "$ROOT/app" && "$LAZBUILD" --ws=cocoa --build-mode=Release rottentree.lpi) \
  > "$DIST/build.log" 2>&1 || { tail -30 "$DIST/build.log"; die "echec de la construction ($DIST/build.log)"; }
rm -f "$DIST/build.log"

VERSION="$(sed -n "s/^ *RT_VERSION = '\(.*\)';/\1/p" "$ROOT/src/util/uVersion.pas")"
[ -n "$VERSION" ] || die "RT_VERSION introuvable dans src/util/uVersion.pas"
# CFBundleShortVersionString n'admet que des nombres: 1.0.0-dev -> 1.0.0
SHORT_VERSION="${VERSION%%-*}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/licenses"
cp "$ROOT/bin/rottentree" "$APP/Contents/MacOS/rottentree"

names=()
for spec in "${LIBS[@]}"; do
  formula="${spec%%:*}"; name="${spec#*:}"
  src="$(brew --prefix "$formula")/lib/$name"
  [ -f "$src" ] || die "$src absent (brew install $formula)"
  cp -L "$src" "$APP/Contents/Frameworks/$name"
  chmod u+w "$APP/Contents/Frameworks/$name"
  names+=("$name")
  echo "embarque: $name ($formula $(brew list --versions "$formula" | awk '{print $2}'))"
done

# dependances entre bibliotheques embarquees: rapprochees par nom de fichier
# (Homebrew reference indifferemment opt/ et Cellar/, et libsqlite3.dylib pour
# libsqlite3.0.dylib)
embedded_name() {
  local base; base="$(basename "$1")"
  for n in "${names[@]}"; do
    if [ "$n" = "$base" ] || [ "${n%%.*}.dylib" = "$base" ]; then echo "$n"; return; fi
  done
}
for name in "${names[@]}"; do
  lib="$APP/Contents/Frameworks/$name"
  install_name_tool -id "@rpath/$name" "$lib" 2>/dev/null
  otool -L "$lib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    target="$(embedded_name "$dep")"
    [ -n "$target" ] && [ "$dep" != "@rpath/$name" ] &&
      install_name_tool -change "$dep" "@loader_path/$target" "$lib" 2>/dev/null
    true
  done
done
# plus aucune reference hors du paquet et du systeme
leaks="$(for f in "$APP/Contents/MacOS/rottentree" "$APP"/Contents/Frameworks/*.dylib; do
  otool -L "$f" | tail -n +2 | awk '{print $1}'; done | grep -vE '^(/usr/lib/|/System/|@rpath/|@loader_path/)' || true)"
[ -z "$leaks" ] || die "references externes restantes: $leaks"

# systeme minimal: le plus exigeant de l'executable et des bibliotheques
MIN_OS="$(for f in "$APP/Contents/MacOS/rottentree" "$APP"/Contents/Frameworks/*.dylib; do
  otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; b=0}'; done | sort -t. -k1,1n -k2,2n | tail -1)"

python3 "$ROOT/scripts/gen_app_icon.py" --icns "$APP/Contents/Resources/rottentree.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/licenses/LICENSE"
cp "$ROOT"/licenses/* "$ROOT"/rottenui/assets/licenses/* "$APP/Contents/Resources/licenses/"

# pas de NSPrincipalClass: la LCL cree elle-meme sa sous-classe
# TCocoaApplication; un NSApplication instancie avant elle fait echouer
# lclSetLCLMainLoop au demarrage
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>rottentree</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Rottentree</string>
  <key>CFBundleDisplayName</key><string>Rottentree</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>rottentree</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright (C) 2023-2026 Cyril LAMY, GPL-3.0-or-later</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# attributs etendus (provenance, quarantaine) refuses par codesign --strict
xattr -cr "$APP"
# de l'interieur vers l'exterieur, sans --deep: chaque bibliotheque, puis le
# paquet (qui scelle l'executable, Info.plist et les ressources)
if [ "$IDENTITY" = "-" ]; then
  sign=(codesign --force --sign -)
  echo "signature: ad hoc (aucune identite fournie)"
else
  sign=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
  echo "signature: $IDENTITY"
fi
for name in "${names[@]}"; do
  "${sign[@]}" "$APP/Contents/Frameworks/$name"
done
"${sign[@]}" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ZIP="$DIST/Rottentree-$VERSION-macos-$(uname -m).zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "OK -> $APP (macOS >= $MIN_OS)"
echo "     $ZIP"
