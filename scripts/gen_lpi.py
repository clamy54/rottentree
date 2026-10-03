# Genere app/rottentree.lpi: options de compilation, unites du projet,
# paquet RottenUI requis et ressources RCDATA propres a Rottentree (icone de
# l'application, licences). Fontes, icones et themes viennent de RottenUI,
# qui les embarque lui-meme (rottenui/tools/gen_res.py). A relancer apres
# ajout d'une unite ou d'une licence.
#
# Usage: python scripts/gen_lpi.py [--check]
#   --check: n'ecrit rien; code de sortie 1 si app/rottentree.lpi differe
#            de ce que le script produirait (unite ou ressource oubliee)
#
# Copyright (C) 2023-2026 Cyril LAMY
# SPDX-License-Identifier: GPL-3.0-or-later

import glob
import os
import sys
from xml.sax.saxutils import quoteattr

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

UNIT_DIRS = ["src/util", "src/domain", "src/application", "src/ldap", "src/passwords",
             "src/comparison", "src/storage", "src/crypto", "src/platform", "src/export",
             "src/ui"]

# paquet du kit graphique, ouvert par ce chemin relatif (pas d'installation
# dans l'IDE): Lazarus suit DefaultFilename quand Prefer est vrai
# (packagesystem.pas, TLazPackageGraph.OpenDependency)
ROTTENUI_LPK = "rottenui/rottenui.lpk"


def resources():
    # les licences des fontes et des icones sont embarquees par RottenUI
    res = [("APPICON_PNG", "../resources/icons/rottentree-256.png")]
    for path in sorted(glob.glob(os.path.join(ROOT, "licenses", "*.txt"))) + \
            sorted(glob.glob(os.path.join(ROOT, "licenses", "*.md"))):
        base = os.path.splitext(os.path.basename(path))[0]
        res.append(("LICENSE_" + "".join(c if c.isalnum() else "_" for c in base.upper()),
                    "../licenses/" + os.path.basename(path)))
    return res


def units():
    result = []
    for d in UNIT_DIRS:
        for path in sorted(glob.glob(os.path.join(ROOT, d, "*.pas"))):
            result.append("../" + d + "/" + os.path.basename(path))
    return result


def search_paths():
    return ";".join("../" + d for d in UNIT_DIRS)


# macOS: le linker d'Xcode 15+ (ld-prime) rejette les listes de methodes
# Objective-C produites par FPC 3.2.x dans la LCL Cocoa ("malformed method list
# atom"); l'ancien linker les accepte. Repris dans chaque mode et dans les
# options racine, que Lazarus applique au mode Default.
DARWIN_LINKER = ('<Conditionals Value="if TargetOS = \'darwin\' then&#xA;'
                 '  CustomOptions += \' -k-ld_classic\';"/>')


def build_mode(name, release):
    opt = []
    opt.append('      <Item Name="%s"%s>' % (name, ' Default="True"' if name == "Default" else ""))
    opt.append("        <CompilerOptions>")
    opt.append('          <Version Value="11"/>')
    opt.append('          ' + DARWIN_LINKER)
    opt.append("          <Target>")
    opt.append('            <Filename Value="../bin/rottentree"/>')
    opt.append("          </Target>")
    opt.append("          <SearchPaths>")
    opt.append('            <IncludeFiles Value="$(ProjOutDir)"/>')
    opt.append('            <OtherUnitFiles Value="%s"/>' % search_paths())
    opt.append('            <UnitOutputDirectory Value="../lib/$(TargetCPU)-$(TargetOS)-%s"/>'
               % ("release" if release else "debug"))
    opt.append("          </SearchPaths>")
    opt.append("          <Parsing>")
    opt.append("            <SyntaxOptions>")
    opt.append('              <SyntaxMode Value="ObjFPC"/>')
    opt.append("            </SyntaxOptions>")
    opt.append("          </Parsing>")
    opt.append("          <CodeGeneration>")
    if release:
        opt.append('            <SmartLinkUnit Value="True"/>')
    # controles d'intervalle et de debordement conserves en Release: le code
    # decode du BER, des empreintes et des structures natives venues de
    # serveurs qu'on n'a aucune raison de croire. Mieux vaut une exception
    # qu'un debordement poli.
    opt.append("            <Checks>")
    opt.append('              <IOChecks Value="True"/>')
    opt.append('              <RangeChecks Value="True"/>')
    opt.append('              <OverflowChecks Value="True"/>')
    if not release:
        opt.append('              <StackChecks Value="True"/>')
    opt.append("            </Checks>")
    if release:
        opt.append("            <Optimizations>")
        opt.append('              <OptimizationLevel Value="2"/>')
        opt.append("            </Optimizations>")
    opt.append("          </CodeGeneration>")
    opt.append("          <Linking>")
    opt.append("            <Debugging>")
    if release:
        opt.append('              <GenerateDebugInfo Value="False"/>')
        opt.append('              <StripSymbols Value="True"/>')
    else:
        opt.append('              <DebugInfoType Value="dsDwarf3"/>')
        opt.append('              <UseHeaptrc Value="False"/>')
    opt.append("            </Debugging>")
    if release:
        opt.append('            <LinkSmart Value="True"/>')
    opt.append("            <Options>")
    opt.append("              <Win32>")
    opt.append('                <GraphicApplication Value="True"/>')
    opt.append("              </Win32>")
    opt.append("            </Options>")
    opt.append("          </Linking>")
    opt.append("        </CompilerOptions>")
    opt.append("      </Item>")
    return "\n".join(opt)


def main():
    res = resources()
    out = []
    out.append('<?xml version="1.0" encoding="UTF-8"?>')
    out.append("<!-- Genere par scripts/gen_lpi.py; ne pas editer a la main. -->")
    out.append("<CONFIG>")
    out.append("  <ProjectOptions>")
    out.append('    <Version Value="12"/>')
    out.append("    <General>")
    out.append("      <Flags>")
    out.append('        <MainUnitHasCreateFormStatements Value="False"/>')
    out.append('        <CompatibilityMode Value="True"/>')
    out.append("      </Flags>")
    out.append('      <SessionStorage Value="None"/>')
    out.append('      <Title Value="Rottentree"/>')
    out.append('      <Scaled Value="True"/>')
    out.append('      <UseAppBundle Value="False"/>')
    out.append('      <ResourceType Value="res"/>')
    out.append('      <UseXPManifest Value="True"/>')
    out.append('      <XPManifest>')
    out.append('        <DpiAware Value="True/PM"/>')
    out.append('        <LongPathAware Value="True"/>')
    out.append('        <TextName Value="Rottentree"/>')
    out.append('        <TextDesc Value="LDAP administration client"/>')
    out.append('      </XPManifest>')
    out.append('      <Icon Value="0"/>')
    out.append('      <Resources Count="%d">' % len(res))
    for i, (name, path) in enumerate(res):
        out.append('        <Resource_%d FileName=%s Type="RCDATA" ResourceName="%s"/>' % (i, quoteattr(path), name))
    out.append("      </Resources>")
    out.append("    </General>")
    out.append('    <VersionInfo>')
    out.append('      <UseVersionInfo Value="True"/>')
    out.append('      <MajorVersionNr Value="1"/>')
    out.append('      <StringTable CompanyName="Cyril LAMY" FileDescription="Rottentree LDAP client" '
               'LegalCopyright="GPL-3.0-or-later" ProductName="Rottentree"/>')
    out.append('    </VersionInfo>')
    out.append("    <BuildModes>")
    out.append(build_mode("Default", False))
    out.append(build_mode("Release", True))
    out.append("    </BuildModes>")
    out.append("    <PublishOptions>")
    out.append('      <Version Value="2"/>')
    out.append("    </PublishOptions>")
    out.append("    <RunParams>")
    out.append('      <FormatVersion Value="2"/>')
    out.append("    </RunParams>")
    out.append("    <RequiredPackages>")
    out.append("      <Item>")
    out.append('        <PackageName Value="SynEdit"/>')
    out.append("      </Item>")
    out.append("      <Item>")
    out.append('        <PackageName Value="LCL"/>')
    out.append("      </Item>")
    out.append("      <Item>")
    out.append('        <PackageName Value="RottenUI"/>')
    out.append('        <DefaultFilename Value="../%s" Prefer="True"/>' % ROTTENUI_LPK)
    out.append("      </Item>")
    out.append("    </RequiredPackages>")
    unit_list = ["rottentree.lpr"] + units()
    out.append('    <Units Count="%d">' % len(unit_list))
    for i, u in enumerate(unit_list):
        out.append("      <Unit%d>" % i)
        out.append('        <Filename Value=%s/>' % quoteattr(u))
        out.append('        <IsPartOfProject Value="True"/>')
        out.append("      </Unit%d>" % i)
    out.append("    </Units>")
    out.append("  </ProjectOptions>")
    out.append("  <CompilerOptions>")
    out.append('    <Version Value="11"/>')
    out.append('    ' + DARWIN_LINKER)
    out.append("    <Target>")
    out.append('      <Filename Value="../bin/rottentree"/>')
    out.append("    </Target>")
    out.append("    <SearchPaths>")
    out.append('      <IncludeFiles Value="$(ProjOutDir)"/>')
    out.append('      <OtherUnitFiles Value="%s"/>' % search_paths())
    out.append('      <UnitOutputDirectory Value="../lib/$(TargetCPU)-$(TargetOS)-debug"/>')
    out.append("    </SearchPaths>")
    out.append("    <Linking>")
    out.append("      <Options>")
    out.append("        <Win32>")
    out.append('          <GraphicApplication Value="True"/>')
    out.append("        </Win32>")
    out.append("      </Options>")
    out.append("    </Linking>")
    out.append("  </CompilerOptions>")
    out.append("</CONFIG>")
    text = "\n".join(out) + "\n"
    path = os.path.join(ROOT, "app", "rottentree.lpi")
    if "--check" in sys.argv[1:]:
        with open(path, encoding="utf-8", newline="") as f:
            current = f.read().replace("\r\n", "\n")
        if current != text:
            print("app/rottentree.lpi n'est plus a jour: relancer python scripts/gen_lpi.py")
            sys.exit(1)
        print("lpi: a jour (%d ressources, %d unites)" % (len(res), len(unit_list)))
        return
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("lpi: %d ressources, %d unites" % (len(res), len(unit_list)))

main()
