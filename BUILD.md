# Building Rottentree

Three platforms, three slightly different stories. The language is the same
everywhere; what differs is which Lazarus you need, where the native
libraries come from, and how creatively each operating system makes that
difficult.

Everything below assumes you cloned the repository and are sitting in its
root. It also assumes you want to build this rather than download it, which is
a choice, and one you are about to have several opportunities to reconsider.

## Common requirements

- **Free Pascal 3.2.2** (3.2.4 on Apple Silicon) and **Lazarus**: 4.8 on
  Windows and macOS, **trunk** on Linux (see below). Only `lazbuild` is
  needed, the IDE is optional.
- **Python 3**. The build scripts run `scripts/gen_lpi.py --check` and
  `rottenui/tools/gen_res.py --check` first: the project file and the embedded
  resources are generated, and a unit or a resource forgotten in them is a
  build error rather than a surprise at run time.

Every build script takes an optional `--release` / `-Release`. Without it you
get a debug build with range and overflow checks and a much larger binary.
Use it for anything you intend to hand to someone else.

**One quirk worth knowing before it bites you:** `lazbuild` resolves the
resource paths declared in the `.lpi` relative to the *current directory*, not
to the `.lpi`. The scripts `cd` into `app/` for the duration of the build. Call
`lazbuild` by hand from the repository root and it looks for the icon and the
license texts one directory too high.

The executable lands in `bin/`.

---

## Windows

The easy one, because the native DLLs are committed to the repository.

```powershell
powershell -File scripts\build.ps1 -Release
```

Output: `bin\rottentree.exe`, next to its eight DLLs. Run it from there: the
loaders look for the DLLs *next to the executable*, by absolute path, and
nowhere else. Never the `PATH`, never the current directory. That is
deliberate, and it means a copy of the `.exe` on its own does nothing.

`scripts\toolchain.ps1` finds `lazbuild` (the `PATH` first, then the usual
install locations) and refuses any compiler other than FPC 3.2.2 /
Lazarus 4.8. Set `ROTTENTREE_ALLOW_TOOLCHAIN=1` to try another one anyway; it
will warn you at every build, as it should.

### The DLLs

OpenLDAP, Cyrus SASL, OpenSSL, libsodium, SQLite and Argon2, x86-64 builds
taken unmodified from the MSYS2 project. Provenance, versions and SHA-256 for
every file are in [`packaging/windows/DEPS.md`](packaging/windows/DEPS.md);
`scripts\check-win-deps.ps1` checks that the document and the files still
agree, and the CI runs it on every push. To move to newer versions, edit the
table in `scripts\fetch-deps-windows.ps1` (package name and SHA-256), run it,
then update `DEPS.md`. The script refuses any package whose hash does not
match, which is the whole point of having a hash.

### Installer

Inno Setup 6, then:

```powershell
ISCC.exe dist\windows\rottentree.iss
```

Output: `dist\windows\output\Rottentree-Setup-<version>.exe`. See
[`dist/README.md`](dist/README.md).

---

## Linux

```sh
sudo apt install libgtk-3-dev libldap2 libssl3t64 libsodium23 libsqlite3-0 libargon2-1
scripts/build.sh --release
```

(On older releases, `libssl3` and `libldap-2.5-0` instead of their newer
names. Package names drift; the loaders accept both generations.)

Output: `bin/rottentree`, GTK3.

**Lazarus 4.8 is not enough here.** Its GTK3 widgetset loops on layout
(`InvalidatePreferredSize`) and draws edit fields beside their own frame,
which is a look, but not one you want in an administration tool. Lazarus
trunk fixes that. The CI builds a pinned trunk commit with FPC 3.2.2, see
[`.github/install-lazarus-linux.sh`](.github/install-lazarus-linux.sh); do the
same, or use fpcupdeluxe. `RT_WIDGETSET=gtk2 scripts/build.sh` builds the GTK2
flavour with whatever Lazarus you have, untested and unsupported, for
distributions where GTK2 still exists.

The native libraries are not bundled: they are the distribution's, opened at
run time from the usual library directories (or from `lib/` next to the
executable, if you insist on carrying your own).

The `.deb`: `dist/linux/build-deb.sh`, after the build. See
[`dist/README.md`](dist/README.md).

---

## macOS

Apple Silicon. Lazarus 4.8 aarch64 with FPC 3.2.4, Xcode command line tools,
and the libraries from Homebrew:

```sh
brew install openldap openssl@3 libsodium sqlite argon2
scripts/build.sh --release           # bin/rottentree, for development
scripts/package-macos.sh             # dist/macos/build/Rottentree.app
```

`scripts/build.sh` produces a bare binary that loads its libraries from
`/opt/homebrew`. That is fine on your machine and useless on anybody else's.
`scripts/package-macos.sh` is the real pipeline: release build, `.app` bundle,
the Homebrew libraries copied into `Contents/Frameworks` with their install
names rewritten to `@loader_path`, `.icns`, `Info.plist`, licenses, signature.
It **fails the build if any library still references `/opt/homebrew`** after
relocation, because that failure mode is invisible from the machine that
caused it: everything launches, everything works, and the app is broken for
every human being who is not you.

The project links with `-ld_classic`: the linker of Xcode 15 and later rejects
the Objective-C method lists emitted for the LCL Cocoa widgetset.

Signing is ad hoc unless `ROTTENTREE_SIGN_IDENTITY` names a Developer ID. Ad
hoc is enough to run on Apple Silicon, not enough for Gatekeeper on somebody
else's Mac: the first launch is blocked until allowed in *System Settings >
Privacy & Security*. Notarization is described at the top of
`dist/macos/make-dmg.sh`.

---

## Generated files

Committed, so a normal build never regenerates them. When you change their
sources:

| After changing | Run |
|---|---|
| a unit added to or removed from `src/` | `python scripts/gen_lpi.py` |
| a license text in `licenses/` | `python scripts/gen_lpi.py` |
| `icons/icon.png` | `python scripts/gen_app_icon.py` (needs Pillow) |
| RottenUI icons | `python rottenui/tools/gen_icons.py` (needs resvg-py; `--download` for a new icon) |
| RottenUI fonts or themes | `python rottenui/tools/gen_res.py` |

## Signing (there is none)

Neither the Windows executable nor its installer is Authenticode signed. A
certificate costs a few hundred euros a year for the privilege of a warning
dialog being slightly less rude about you. So SmartScreen will meet the first
downloads with *"Windows protected your PC"*, and will render the *Don't run*
button noticeably larger than the one you actually want. Click *More info*,
then *Run anyway*.
