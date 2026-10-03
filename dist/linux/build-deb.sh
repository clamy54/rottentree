#!/usr/bin/env bash
# .deb Debian/Ubuntu. Prerequis: scripts/build.sh --release, dpkg-deb.
# Usage: dist/linux/build-deb.sh [version]
#
# Copyright (C) 2023-2026 Cyril LAMY
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

ver="${1:-$(sed -n "s/.*RT_VERSION *= *'\([^']*\)'.*/\1/p" "$root/src/util/uVersion.pas" | head -1)}"
[ -n "$ver" ] || { echo "RT_VERSION introuvable dans src/util/uVersion.pas" >&2; exit 1; }
arch="$(dpkg --print-architecture)"
bin="$root/bin/rottentree"
[ -x "$bin" ] || { echo "bin/rottentree absent: scripts/build.sh --release d'abord" >&2; exit 1; }

pkg="$here/build/rottentree_${ver}_${arch}"
rm -rf "$pkg"
mkdir -p "$pkg/DEBIAN" "$pkg/usr/bin" "$pkg/usr/share/applications" \
	"$pkg/usr/share/doc/rottentree/licenses"

install -m 0755 "$bin" "$pkg/usr/bin/rottentree"
install -m 0644 "$here/rottentree.desktop" "$pkg/usr/share/applications/rottentree.desktop"
install -m 0644 "$root/LICENSE" "$pkg/usr/share/doc/rottentree/copyright"
install -m 0644 "$root"/licenses/* "$root"/rottenui/assets/licenses/* \
	"$pkg/usr/share/doc/rottentree/licenses/"

# ImageMagick optionnel; sans lui, l'icone 256 telle quelle
if command -v magick >/dev/null 2>&1; then im="magick"
elif command -v convert >/dev/null 2>&1; then im="convert"
else im=""
fi
icon="$root/resources/icons/rottentree-256.png"
if [ -n "$im" ]; then
	for s in 16 24 32 48 64 128 256; do
		d="$pkg/usr/share/icons/hicolor/${s}x${s}/apps"
		mkdir -p "$d"
		"$im" "$icon" -resize "${s}x${s}" "$d/rottentree.png"
		chmod 0644 "$d/rottentree.png"
	done
else
	echo "ImageMagick absent: icone posee telle quelle en 256x256" >&2
	d="$pkg/usr/share/icons/hicolor/256x256/apps"
	mkdir -p "$d"
	install -m 0644 "$icon" "$d/rottentree.png"
fi

# caches du bureau: un cache perime ne vaut pas une installation ratee
for script in postinst postrm; do
	cat > "$pkg/DEBIAN/$script" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
	update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
	gtk-update-icon-cache -q -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
EOF
	chmod 0755 "$pkg/DEBIAN/$script"
done

# Depends en deux temps. Ce qui est LIE (GTK, libc) vient de dpkg-shlibdeps:
# les noms de paquets bougent sous vos pieds (t64), et un Depends sur un paquet
# disparu donne un .deb installable sur zero machine.
deps=""
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
	sd="$here/build/shlibdeps"
	rm -rf "$sd"; mkdir -p "$sd/debian"
	: > "$sd/debian/control"
	if (cd "$sd" && dpkg-shlibdeps -O --ignore-missing-info "$pkg/usr/bin/rottentree" 2>/dev/null) > "$sd/out"; then
		deps="$(sed -n 's/^shlibs:Depends=//p' "$sd/out")"
	fi
	rm -rf "$sd"
fi
[ -n "$deps" ] || {
	echo "dpkg-shlibdeps indisponible: Depends de repli, a verifier" >&2
	deps="libc6"
}
# GTK3 ecrit en dur, que shlibdeps l'ait vu ou non: sans lui, l'executable ne
# s'ouvre meme pas, et le message d'erreur tient en une ligne de ld.so.
case "$deps" in
	*libgtk-3-0*) ;;
	*) deps="${deps}, libgtk-3-0t64 | libgtk-3-0" ;;
esac
# Ce qui est ouvert par dlopen est INVISIBLE pour shlibdeps. Oubliez cette
# liste et le paquet s'installe, demarre, affiche vos profils, puis refuse de
# se connecter au moindre annuaire.
deps="${deps}, libldap2 | libldap-2.5-0, libssl3t64 | libssl3, libsodium23"
deps="${deps}, libsqlite3-0, libargon2-1"

# substitution bash, pas sed: le | des alternatives fermerait s|...|...|
control="$(cat "$here/control.in")"
control="${control//@VERSION@/$ver}"
control="${control//@ARCH@/$arch}"
control="${control//@DEPENDS@/$deps}"
printf '%s\n' "$control" > "$pkg/DEBIAN/control"

dpkg-deb --build --root-owner-group "$pkg"
echo "OK -> ${pkg}.deb"
echo "Depends: $deps"
