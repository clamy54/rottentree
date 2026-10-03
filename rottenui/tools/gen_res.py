# Construit les ressources embarquees de RottenUI: src/rottenui_fonts.res,
# src/rottenui_icons.res et src/rottenui_themes.res, liees par les unites
# uFontEmbed, uIcons et uThemeLoad ({$R ...}). Un programme qui utilise le kit
# les embarque donc sans rien declarer dans son projet.
#
# Pour chaque jeu, un script .rc (liste lisible, versionnee) est ecrit dans
# src/, puis compile en .res par fpcres, livre avec FPC sur toutes les
# plateformes. Les .res sont versionnes: un projet qui utilise le kit n'a
# besoin ni de Python ni d'un compilateur de ressources (FPC 3.2.2 confie un
# .rc a windres, absent sous Linux: compiler/rescmn.pas, res_elf_info).
#
# Usage: python tools/gen_res.py [--check] [fonts|icons|themes...]
#   --check: n'ecrit rien; code de sortie 1 si un .rc ou un .res n'est plus a
#            jour (fpcres produit un .res deterministe)
# fpcres: variable FPCRES, sinon PATH, sinon une installation Lazarus connue.
#
# Copyright (C) 2023-2026 Cyril LAMY
# SPDX-License-Identifier: GPL-3.0-or-later

import glob
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
ASSETS = os.path.join(ROOT, "assets")

FONTS = [
    ("NEON", "MonaspaceNeonFrozen"), ("ARGON", "MonaspaceArgonFrozen"),
    ("XENON", "MonaspaceXenonFrozen"), ("RADON", "MonaspaceRadonFrozen"),
    ("KRYPTON", "MonaspaceKryptonFrozen"), ("JETBRAINSMONO", "JetBrainsMonoNLNerdFontMono"),
]
STYLES = [("REGULAR", "Regular"), ("BOLD", "Bold"), ("ITALIC", "Italic"), ("BOLDITALIC", "BoldItalic")]
FONT_LICENSES = ["Monaspace-OFL-1.1.txt", "JetBrainsMono-OFL-1.1.txt"]
ICON_LICENSES = ["Tabler-MIT.txt"]


def license_entry(fname):
    base = os.path.splitext(fname)[0]
    return ("LICENSE_" + "".join(c if c.isalnum() else "_" for c in base.upper()),
            "licenses/" + fname)


def fonts():
    res = []
    for key, prefix in FONTS:
        for skey, sfile in STYLES:
            res.append(("%s_%s" % (key, skey), "fonts/%s-%s.ttf" % (prefix, sfile)))
    return res + [license_entry(f) for f in FONT_LICENSES]


def icons():
    res = []
    for path in sorted(glob.glob(os.path.join(ASSETS, "icons", "*.png"))):
        fname = os.path.basename(path)
        ident, size = os.path.splitext(fname)[0].rsplit("_", 1)
        res.append(("ICON_%s_%s" % (ident.upper().replace("-", "_"), size), "icons/" + fname))
    return res + [license_entry(f) for f in ICON_LICENSES]


def themes():
    res = []
    for path in sorted(glob.glob(os.path.join(ASSETS, "themes", "*.json"))):
        base = os.path.splitext(os.path.basename(path))[0]
        res.append(("THEME_" + base.upper().replace("-", "_"), "themes/" + os.path.basename(path)))
    return res


SETS = {"fonts": fonts, "icons": icons, "themes": themes}


def rc_text(name, entries):
    lines = ["// Genere par tools/gen_res.py (jeu %s); ne pas editer a la main." % name]
    for res, path in entries:
        if not os.path.isfile(os.path.join(ASSETS, path)):
            sys.exit("ressource absente: assets/" + path)
        lines.append('%s RCDATA "../assets/%s"' % (res, path))
    return "\n".join(lines) + "\n"


def find_fpcres():
    if os.environ.get("FPCRES"):
        return os.environ["FPCRES"]
    found = shutil.which("fpcres")
    if found:
        return found
    for pattern in (r"C:\lazarus\fpc\*\bin\*\fpcres.exe", r"C:\fpcupdeluxe\fpc\bin\*\fpcres.exe",
                    "/usr/lib/fpc/*/fpcres", "/usr/local/lib/fpc/*/fpcres"):
        hits = sorted(glob.glob(pattern))
        if hits:
            return hits[-1]
    sys.exit("fpcres introuvable: le placer dans le PATH ou poser FPCRES")


def compile_rc(rc_path, res_path):
    # chemins des fichiers relatifs au .rc: fpcres travaille depuis src/
    subprocess.run([find_fpcres(), "-of", "res", "-o", res_path, rc_path], cwd=SRC, check=True,
                   stdout=subprocess.DEVNULL)


def build(names=None, check=False):
    stale = []
    for name in names or sorted(SETS):
        rc_path = os.path.join(SRC, "rottenui_%s.rc" % name)
        res_path = os.path.join(SRC, "rottenui_%s.res" % name)
        text = rc_text(name, SETS[name]())
        if check:
            current = open(rc_path, encoding="utf-8").read() if os.path.exists(rc_path) else None
            if current != text:
                stale.append(os.path.basename(rc_path))
                continue
            with tempfile.TemporaryDirectory() as tmp:
                fresh = os.path.join(tmp, "check.res")
                compile_rc(rc_path, fresh)
                if not os.path.exists(res_path) or \
                        open(fresh, "rb").read() != open(res_path, "rb").read():
                    stale.append(os.path.basename(res_path))
            continue
        with open(rc_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        compile_rc(rc_path, res_path)
        print("%s: %d ressources" % (os.path.basename(res_path), len(SETS[name]())))
    if check:
        if stale:
            print("RottenUI: ressources perimees (%s): relancer python rottenui/tools/gen_res.py"
                  % ", ".join(stale))
            sys.exit(1)
        print("RottenUI: ressources a jour")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    for a in args:
        if a not in SETS:
            sys.exit("jeu inconnu: %s (fonts, icons, themes)" % a)
    build(args or None, "--check" in sys.argv[1:])
