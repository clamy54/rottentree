# Genere les icones de RottenUI a partir des SVG Tabler Icons (MIT), version
# epinglee. Les SVG sources sont conserves dans assets/tabler/ pour la
# tracabilite; les PNG produits vont dans assets/icons/, la liste des
# identifiants dans src/uIconCatalog.inc, puis src/rottenui_icons.res est
# reconstruit (gen_res.py). Outil de construction: rien n'est lu a
# l'execution.
#
# Chaque PNG est un masque: trace blanc, transparence de l'icone. La couleur
# est posee a l'execution (uIcons.LoadIconTinted) d'apres le theme: etat
# d'erreur, d'avertissement, accent, texte. Un seul jeu sert tous les themes.
#
# Ajouter une icone: son nom Tabler dans ICONS, puis
#   python tools/gen_icons.py --download
# Dependance: resvg-py (rendu SVG)
#
# Copyright (C) 2023-2026 Cyril LAMY
# SPDX-License-Identifier: GPL-3.0-or-later

import os
import sys
import urllib.request

TABLER_VERSION = "3.46.0"
# 16-32: listes, arbres, en-tetes; 40-64: boites de message a 125-200 %
SIZES = (16, 20, 24, 32, 40, 48, 64)
MASK_COLOR = "#FFFFFF"

ICONS = [
    # coque et documents
    "folder", "folder-open", "server", "server-2", "database", "world", "trees",
    # entrees d'annuaire
    "sitemap", "folders", "user", "users", "user-off", "id-badge-2", "device-desktop",
    "printer", "mail", "file", "box", "building", "hierarchy-2", "link",
    # securite et mots de passe
    "key", "lock", "lock-open", "certificate", "shield-check", "shield-exclamation",
    "shield-x",
    # outils
    "search", "git-compare", "refresh", "arrows-exchange", "schema", "list-details",
    "tag", "file-text", "file-export", "file-import", "plug-connected",
    "plug-connected-x", "activity", "chart-bar", "binary", "photo", "clock", "filter",
    "history", "star", "settings", "terminal-2",
    # etats
    "alert-triangle", "circle-check", "circle-x", "info-circle", "help-circle",
    "loader-2", "eye", "eye-off", "player-stop", "player-play",
    # actions
    "trash", "pencil", "copy", "arrows-move", "plus", "minus", "x", "check",
    "chevron-right", "chevron-down",
    # dialogues et etapes
    "shield-lock", "file-plus", "circle-dashed", "circle-dot", "circle-minus",
]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "tabler")
DST = os.path.join(ROOT, "assets", "icons")


def download():
    os.makedirs(SRC, exist_ok=True)
    missing = []
    for name in ICONS:
        path = os.path.join(SRC, name + ".svg")
        if os.path.exists(path):
            continue
        url = "https://cdn.jsdelivr.net/npm/@tabler/icons@%s/icons/outline/%s.svg" % (TABLER_VERSION, name)
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                data = r.read()
        except Exception:
            missing.append(name)
            continue
        with open(path, "wb") as f:
            f.write(data)
    lic = os.path.join(SRC, "LICENSE")
    if not os.path.exists(lic):
        url = "https://cdn.jsdelivr.net/npm/@tabler/icons@%s/LICENSE" % TABLER_VERSION
        with urllib.request.urlopen(url, timeout=30) as r:
            open(lic, "wb").write(r.read())
    if missing:
        sys.exit("icones Tabler introuvables: " + ", ".join(missing))


def render(svg_text, size, color):
    import resvg_py
    svg = svg_text.replace("currentColor", color)
    png = resvg_py.svg_to_bytes(svg_string=svg, width=size, height=size)
    return bytes(png)


def main():
    if "--download" in sys.argv:
        download()
    os.makedirs(DST, exist_ok=True)
    # anciens PNG (icones retirees, autres tailles): jamais embarques
    for old in os.listdir(DST):
        if old.endswith(".png"):
            os.remove(os.path.join(DST, old))
    count = 0
    for name in ICONS:
        with open(os.path.join(SRC, name + ".svg"), encoding="utf-8") as f:
            svg = f.read()
        for size in SIZES:
            fname = "%s_%d.png" % (name, size)
            open(os.path.join(DST, fname), "wb").write(render(svg, size, MASK_COLOR))
            count += 1
    with open(os.path.join(ROOT, "src", "uIconCatalog.inc"), "w", encoding="utf-8", newline="
") as f:
        f.write("// Genere par tools/gen_icons.py; ne pas editer a la main.
")
        f.write("const
  ICON_IDS: array[0..%d] of string = (
" % (len(ICONS) - 1))
        f.write(",
".join("    '%s'" % n for n in ICONS))
        f.write(");
  ICON_SIZES: array[0..%d] of Integer = (%s);
" % (len(SIZES) - 1, ", ".join(map(str, SIZES))))
    print("%d icones, %d masques PNG" % (len(ICONS), count))
    # les PNG changent: la ressource embarquee aussi
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import gen_res
    gen_res.build(["icons"])


main()
