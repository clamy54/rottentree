# Icone de l'application Rottentree, depuis icons/icon.png (fond transparent;
# une image non carree est centree sur un carre transparent): seule source
# pour toutes les plateformes. Produit resources/icons/rottentree-256.png
# (ressource APPICON_PNG, scripts/gen_lpi.py) et app/rottentree.ico (MAINICON
# du projet). Les icones de l'interface viennent de RottenUI
# (rottenui/tools/gen_icons.py).
#
# Usage: python scripts/gen_app_icon.py
#        python scripts/gen_app_icon.py --icns CHEMIN   (icone du paquet macOS,
#        produite a la construction par scripts/package-macos.sh, non versionnee)
# Dependance: Pillow
#
# Copyright (C) 2023-2026 Cyril LAMY
# SPDX-License-Identifier: GPL-3.0-or-later

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_ICON_SOURCE = os.path.join(ROOT, "icons", "icon.png")
APP_ICON_PNG = os.path.join(ROOT, "resources", "icons", "rottentree-256.png")
APP_ICON_ICO = os.path.join(ROOT, "app", "rottentree.ico")
APP_ICON_SIZES = [(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64),
                  (128, 128), (256, 256)]


def square_source():
    from PIL import Image
    src = Image.open(APP_ICON_SOURCE).convert("RGBA")
    # marges transparentes retirees, puis image non carree centree sur un
    # carre transparent (la source n'est jamais modifiee)
    bbox = src.getchannel("A").getbbox()
    if bbox is not None:
        src = src.crop(bbox)
    if src.width != src.height:
        side = max(src.width, src.height)
        square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        square.paste(src, ((side - src.width) // 2, (side - src.height) // 2))
        src = square
    return src


def app_icon():
    # Le .ico devient la ressource MAINICON du projet (lazbuild); la LCL la
    # charge au demarrage sous Windows, Linux et macOS (application.inc) et
    # chaque widgetset l'applique: fenetres et barre des taches, fenetres GTK,
    # Dock macOS (cocoaint.pas, setApplicationIconImage)
    from PIL import Image
    src = square_source()
    os.makedirs(os.path.dirname(APP_ICON_PNG), exist_ok=True)
    big = src.resize((256, 256), Image.Resampling.LANCZOS)
    big.save(APP_ICON_PNG, optimize=True)
    # entrees BMP: le lecteur d'icones de la LCL ne decode pas les entrees PNG;
    # chaque taille est reduite depuis la source pleine resolution
    frames = [src.resize(s, Image.Resampling.LANCZOS) for s in APP_ICON_SIZES]
    frames[-1].save(APP_ICON_ICO, bitmap_format="bmp", sizes=APP_ICON_SIZES,
                    append_images=frames[:-1])


def app_icns(path):
    # Finder et Dock lisent l'icone du paquet (CFBundleIconFile) avant le
    # demarrage de la LCL; Pillow derive toutes les tailles ICNS de 1024 px
    from PIL import Image
    src = square_source().resize((1024, 1024), Image.Resampling.LANCZOS)
    src.save(path, format="ICNS")


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--icns":
        app_icns(args[1])
    elif not args:
        app_icon()
        print("icone de l'application regeneree depuis icons/icon.png")
    else:
        sys.exit("usage: gen_app_icon.py [--icns CHEMIN]")
