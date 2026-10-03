#!/usr/bin/env bash
# FPC 3.2.2 + Lazarus trunk epingle, runner Linux amd64 (ci.yml, release.yml).
# Trunk et pas 4.8: le GTK3 de la 4.8 boucle sur InvalidatePreferredSize et
# dessine les champs a cote de leur cadre. Le commit est epingle: un trunk qui
# bouge sous la CI, c'est un build vert lundi et rouge mardi sans un octet de
# change dans ce depot.
# Empreintes des paquets FPC verifiees AVANT installation: le compilateur des
# binaires publies ne sort pas d'un cache douteux.
set -euo pipefail

LAZARUS_COMMIT="${LAZARUS_COMMIT:-0263f8d05e0fb6902d1aa0a7e001ef0275ed29d2}"
LAZARUS_REPO="https://gitlab.com/freepascal.org/lazarus/lazarus.git"

mirror="https://github.com/clamy54/lazarus-mirror/releases/download/lazarus-4.8-linux-amd64"
sf="https://sourceforge.net/projects/lazarus/files/Lazarus%20Linux%20amd64%20DEB/Lazarus%204.8"
dl="$HOME/laz-dl"; mkdir -p "$dl"
laz="$HOME/lazarus-trunk"

verify() {  # $1 fichier, $2 SHA-256 attendu
  [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]
}

fetch() {  # $1 nom du fichier, $2 SHA-256 attendu
  if [ -s "$dl/$1" ]; then
    if verify "$dl/$1" "$2"; then echo "$1: depuis le cache (empreinte OK)"; return 0; fi
    echo "$1: copie du cache corrompue, retelechargement" >&2
    rm -f "$dl/$1"
  fi
  local tmp="$dl/$1.part"
  rm -f "$tmp"
  if curl -fsSL --retry 3 -o "$tmp" "$mirror/$1"; then
    echo "$1: depuis le miroir GitHub"
  else
    echo "$1: miroir indisponible, repli SourceForge" >&2
    curl -fsSL --retry 3 -o "$tmp" "$sf/$1/download"
  fi
  if ! verify "$tmp" "$2"; then
    echo "$1: empreinte SHA-256 inattendue, fichier refuse" >&2
    sha256sum "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  mv -f "$tmp" "$dl/$1"
  echo "$1: empreinte OK"
}

fetch fpc-laz_3.2.2-210709_amd64.deb 92000f2b831184e153aab0c910f8ae9240450e5c6d76dc189cf53116ee501d83
fetch fpc-src_3.2.2-210709_amd64.deb 8c9e145d8056754a9ca39ce3e52e982b8e4816124984c5f542f2a874e721ad53

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  "$dl/fpc-laz_3.2.2-210709_amd64.deb" "$dl/fpc-src_3.2.2-210709_amd64.deb" \
  git make libgtk-3-dev
fpc -iV

# sources Lazarus au commit epingle (le cache peut deja les avoir)
if [ "$(git -C "$laz" rev-parse HEAD 2>/dev/null || true)" != "$LAZARUS_COMMIT" ]; then
  rm -rf "$laz"
  git init -q "$laz"
  git -C "$laz" remote add origin "$LAZARUS_REPO"
  git -C "$laz" fetch -q --depth 1 origin "$LAZARUS_COMMIT"
  git -C "$laz" checkout -q FETCH_HEAD
fi
make -C "$laz" lazbuild >/dev/null
# Un wrapper, pas un lien symbolique: lazbuild deduit le repertoire de Lazarus de
# son propre chemin, et depuis /usr/local/bin il n'y trouve pas l'ombre d'une LCL.
sudo tee /usr/local/bin/lazbuild >/dev/null <<EOF
#!/bin/sh
exec "$laz/lazbuild" --lazarusdir="$laz" "\$@"
EOF
sudo chmod 0755 /usr/local/bin/lazbuild
lazbuild --version
