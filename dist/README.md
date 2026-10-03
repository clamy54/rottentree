# Packaging Rottentree

Build the binary first (see [`../BUILD.md`](../BUILD.md)), then wrap it for
the target platform.

Two things every package must carry, whatever the platform:

- **The native libraries, where the loaders look for them.** On Windows, the
  DLLs sit *in* the install directory, next to the executable. On macOS, the
  libraries live in `Contents/Frameworks/` of the bundle. On Linux, nothing is
  bundled: the package depends on the distribution's libraries instead.
- **The licenses.** Every package ships `LICENSE`, `licenses/` and the font and
  icon licenses of RottenUI (`rottenui/assets/licenses/`). Shipping somebody
  else's binary without their license text is not an oversight, it is a
  license violation with extra steps.

The version comes from `RT_VERSION` in `src/util/uVersion.pas`, the single
source of truth, also shown in *Help > About*. All three packagings read it
themselves.

## Windows (`windows/`)

Inno Setup 6 installer.

1. `powershell -File scripts\build.ps1 -Release`
2. `ISCC.exe dist\windows\rottentree.iss`

Output: `dist\windows\output\Rottentree-Setup-<version>.exe`. It installs the
executable, its eight DLLs, the licenses, Start Menu (and optional desktop)
shortcuts.

The wizard's **License Agreement** page shows `LICENSE` (GPL-3), the one the
user accepts. The **Information** page right after shows the third-party
inventory, rendered from `licenses/THIRD-PARTY-NOTICES.md` to plain text by
`make-notices.ps1`, which `rottentree.iss` runs at every compilation, along
with `make-version.ps1`. A generated page that is regenerated at every build
cannot drift from its source; one regenerated "when someone remembers" always
does.

## Linux (`linux/`)

`.deb` for Debian and Ubuntu: `dist/linux/build-deb.sh [version]`, after
`scripts/build.sh --release`. Needs `dpkg-deb`; `dpkg-dev` for computed
dependencies and ImageMagick for properly sized icons are optional but
recommended. Output: `dist/linux/build/rottentree_<version>_<arch>.deb`.

**Dependencies come from two places, and the second one is the trap.** What is
*linked* into the binary (GTK3, libc) is computed by `dpkg-shlibdeps` and
never hand-written, because package names drift under you: Ubuntu's time64
transition renamed half the archive, and a `Depends` on a package that no
longer exists produces a `.deb` installable on precisely zero machines.

But libldap, OpenSSL, libsodium, SQLite and libargon2 are opened with
`dlopen`, which makes them invisible to `dpkg-shlibdeps`, a tool that reads
symbol tables and not intentions. They are listed by hand in `build-deb.sh`.
Delete that list and the package builds cleanly, installs cleanly, starts
cleanly, shows you all your profiles, and then fails to connect to a single
directory.

## macOS (`macos/`)

`.app` bundle, then `.dmg`.

1. `scripts/package-macos.sh` builds `dist/macos/build/Rottentree.app`. That
   script is the macOS pipeline (release build, Homebrew libraries copied into
   the bundle and relocated, `.icns`, `Info.plist`, signature) and it is not
   duplicated here.
2. `dist/macos/make-dmg.sh [version]` wraps the bundle into a
   drag-to-Applications `.dmg`. Output:
   `dist/macos/build/Rottentree-<version>.dmg`.

The install window is laid out (app on the left, `/Applications` on the right,
`Licenses` below). That layout lives in the volume's `.DS_Store`, so the script
builds a writable image, styles it **through the Finder**, then compresses it.
Yes, the packaging pipeline drives a file manager with AppleScript to move
icons around a window. Driving the Finder needs an automation permission that
may be missing (CI, locked session), so the script gives it 30 seconds and
then ships the `.dmg` unstyled rather than hanging the build until someone
notices.

## Releases (GitHub Actions)

Everything above also runs unattended in
[`../.github/workflows/release.yml`](../.github/workflows/release.yml):

1. Bump `RT_VERSION` in `src/util/uVersion.pas`, commit.
2. `git tag v<version> && git push origin v<version>`.

The workflow refuses a tag that does not match `RT_VERSION` before building
anything. That check exists solely to prevent the traditional release: tag
pushed, three platforms compiled, forty minutes burned, and a `v1.1` package
containing a binary that reports 1.0 in its About box for the rest of its
life.

It then builds the three packages (Windows x64 setup, zipped; Ubuntu amd64
`.deb`; macOS arm64 `.dmg`) and attaches them to a **draft** release. Review
the draft on the releases page, then publish it yourself. Nothing here
publishes on your behalf.

Dry run without a tag: *Actions > release > Run workflow*. It builds and
uploads the packages as run artifacts and skips the release.
