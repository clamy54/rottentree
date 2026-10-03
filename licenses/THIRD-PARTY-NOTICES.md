# Third-party notices

Rottentree is free software under the GNU General Public License, version 3 or
later (`GPL-3.0-or-later.txt`). It is built with, and ships, the third-party
works listed below. Each one keeps its own license, whose full text sits next
to this file.

None of them was modified by the Rottentree project.

## Native libraries

Loaded at run time, from the directory of the executable first.

| Component | Version shipped on Windows | License | Text |
|---|---|---|---|
| OpenLDAP client libraries (libldap, liblber) | 2.6.12 | OpenLDAP Public License 2.8 | `OpenLDAP-Public-License-2.8.txt` |
| Cyrus SASL (libsasl2) | 2.1.28 | BSD with attribution | `Cyrus-SASL-BSD-Attribution.txt` |
| OpenSSL (libssl, libcrypto) | 3.6.4 | Apache License 2.0 | `OpenSSL-Apache-2.0.txt` |
| libsodium | 1.0.22 | ISC | `libsodium-ISC.txt` |
| SQLite | 3.53.4 | Public domain | `SQLite-Public-Domain.txt` |
| Argon2 reference implementation (libargon2) | 20190702 | CC0 1.0 or Apache License 2.0 | `Argon2-CC0-or-Apache-2.0.txt` |

**Windows**: the DLLs are the x86-64 builds of the MSYS2 project
(<https://www.msys2.org/>), taken unmodified from its pinned packages. The
package names, versions and SHA-256 sums are listed in
`packaging/windows/DEPS.md` of the source repository.

**macOS**: the `.app` bundle embeds the Homebrew builds of the same libraries,
at the versions current when the bundle was made. Cyrus SASL is the one of the
system.

**Linux**: nothing is bundled. The libraries are the ones of the distribution,
declared as package dependencies.

## Embedded in the executable

Through the RottenUI widget kit (`rottenui/assets/licenses/` in the source
repository, copied next to this file by the packages).

| Component | License | Text |
|---|---|---|
| Monaspace fonts (GitHub Next) | SIL Open Font License 1.1 | `Monaspace-OFL-1.1.txt` |
| JetBrains Mono font | SIL Open Font License 1.1 | `JetBrainsMono-OFL-1.1.txt` |
| Tabler Icons | MIT | `Tabler-MIT.txt` |

## Compiler runtime

| Component | License | Text |
|---|---|---|
| Free Pascal run-time library, Lazarus Component Library | LGPL with static linking exception | `FPC-LCL-modified-LGPL.txt` |
