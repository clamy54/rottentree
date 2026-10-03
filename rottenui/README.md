# RottenUI

Kit graphique commun aux applications Rotten (enfin, qui est censé le devenir) :
contrôles LCL thémés, fontes, icônes et thèmes **embarqués dans les unités**. Un
programme qui utilise le kit n'a aucune ressource à déclarer dans son projet.

Licence : GPL-3.0-or-later (`LICENSE`). Fontes Monaspace et JetBrains Mono : SIL OFL 1.1 ;
icônes Tabler : MIT. Leurs notices sont dans `assets/licenses/` et embarquées avec elles
(ressources `LICENSE_MONASPACE_OFL_1_1`, `LICENSE_JETBRAINSMONO_OFL_1_1`, `LICENSE_TABLER_MIT`).

Chaîne de compilation : FPC 3.2.2 / Lazarus 4.8.

## Contenu

| Unité | Rôle |
|---|---|
| `uTheme` | jetons de couleur et fontes courants, tailles choisies par l'utilisateur |
| `uThemeLoad`, `uThemeData`, `uThemePreview` | registre des thèmes (intégrés, embarqués, JSON utilisateur), application, aperçu |
| `uFontEmbed` | fontes embarquées, enregistrées pour le seul processus |
| `uIcons` (+ `uIconCatalog.inc`) | icônes Tabler en masques teintés à l'exécution, `TRtIcon` |
| `uUiKit` | `TRtDialog` et aides de mise en page (rangées, boutons, mémos, état) |
| `uRtMessage` | boîtes de message et de saisie |
| `uRtCombo`, `uRtCheck`, `uRtButton`, `uRtList` | liste déroulante, case à cocher, bouton, liste |
| `uTabBar`, `uMenuBar`, `uSearchBox`, `uTreeScrollBar`, `uPickDialog` | onglets, barre de menus, recherche, défilement, choix |
| `uSafeSave`, `uJsonGuard` | écriture atomique et lecture bornée de fichiers, garde JSON |

Ressources : `src/rottenui_fonts.res` (lié par `uFontEmbed`), `src/rottenui_icons.res`
(`uIcons`), `src/rottenui_themes.res` (`uThemeLoad`).

## Utiliser le kit dans un projet

Dans l'IDE : *Paquet > Ouvrir un fichier paquet* (`rottenui.lpk`), puis *Utiliser > Ajouter
au projet*. Ou directement dans le `.lpi`, sans installer le paquet dans l'IDE (chemin
relatif au `.lpi`) :

```xml
<RequiredPackages>
  <Item>
    <PackageName Value="RottenUI"/>
    <DefaultFilename Value="../rottenui/rottenui.lpk" Prefer="True"/>
  </Item>
</RequiredPackages>
```

Au démarrage, après `Application.Initialize` :

```pascal
EmbeddedFontManager.RegisterFonts;   // uFontEmbed
ApplyDefaultFonts;                   // uTheme
// facultatif: tailles choisies et dossier des thèmes JSON de l'utilisateur
// (défaut: <dossier de configuration>/themes)
PrefUiFontSize := 10;
ThemesUserDir := MonDossier + PathDelim + 'themes';
InitThemes('Rotten');                // uThemeLoad
```

## Modifier les ressources

Les `.res` sont versionnés : un projet qui utilise le kit n'a besoin ni de Python ni d'un
compilateur de ressources.

- **Ajouter une icône** : son nom Tabler dans `ICONS` de `tools/gen_icons.py`, puis
  `python tools/gen_icons.py --download` (dépendance : `resvg-py`). Les masques PNG,
  `src/uIconCatalog.inc` et `src/rottenui_icons.res` sont régénérés.
- **Fontes ou thèmes** : remplacer les fichiers de `assets/`, puis
  `python tools/gen_res.py`.
- **Contrôle** : `python tools/gen_res.py --check` échoue si un `.res` ne correspond plus
  à ses fichiers.

`gen_res.py` écrit un script `.rc` par jeu (liste lisible, versionnée) et le compile avec
`fpcres`, livré avec FPC sur toutes les plateformes. Un `.rc` déclaré directement par
`{$R x.rc}` serait confié à `windres` par FPC 3.2.2, y compris sous Linux où il manque
généralement (`compiler/rescmn.pas`, `res_elf_info`). D'où les `.res` précompilés.
