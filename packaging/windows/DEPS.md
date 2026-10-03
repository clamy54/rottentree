# Windows native libraries

The eight DLLs in `bin/` are committed, so that a fresh clone builds and runs
without anyone spending an evening on a package manager. They are not built
here. They come, unmodified, from the x86-64 packages of the
[MSYS2](https://www.msys2.org/) project, downloaded from
`https://repo.msys2.org/mingw/mingw64/`.

`scripts/fetch-deps-windows.ps1` is the recipe: it downloads the packages
below, refuses any whose SHA-256 differs, and extracts the DLLs into `bin/`.
Run it again after changing the table in that script, then update this file.
`scripts/check-win-deps.ps1` (run by the CI) checks that the DLLs in `bin/`
still match the sums listed here. A provenance document whose hashes nobody
checks proves nothing while looking exactly like proof.

## Packages

| Package | SHA-256 |
|---|---|
| `mingw-w64-x86_64-openldap-2.6.12-1-any.pkg.tar.zst` | `5f5702423b3eb86c3181d830ce03de5ec683017b9a15ed9c6b20e94f55304074` |
| `mingw-w64-x86_64-cyrus-sasl-2.1.28-6-any.pkg.tar.zst` | `c91ffefdc4835a793fba99993433bbe5915d9367cdf8bd16ad27a16526f9eb3a` |
| `mingw-w64-x86_64-openssl-3.6.4-1-any.pkg.tar.zst` | `d613ab4e1b5af9e95cde16895765e1be53ab05657d8d51ff2707d4e99c29c55b` |
| `mingw-w64-x86_64-libsodium-1.0.22-3-any.pkg.tar.zst` | `e8d8bc169fa122eccfc3e4252615937a62fa0bd6ca21ed4912bac48d6ed2f870` |
| `mingw-w64-x86_64-sqlite3-3.53.4-1-any.pkg.tar.zst` | `baca1837b4f5ae4ea39198c4ec98459a446eb4af17459ad6376d734b285b4ff0` |
| `mingw-w64-x86_64-argon2-20190702-2-any.pkg.tar.zst` | `34c21ec8fec34270a6916fef163d3f08899e9b20f199858175af4603b0c1e25c` |

## DLLs

| File | From | SHA-256 |
|---|---|---|
| `libldap.dll` | openldap 2.6.12 | `855ba1b5150d48ebe3bba78cf1d18bfb0d0623111cc41666e6cd93fe7b2f0245` |
| `liblber.dll` | openldap 2.6.12 | `efe64c1d2f14e416758f4951b6822cb3053f5459f5f7a39510f57eff7654fd7d` |
| `libsasl2-3.dll` | cyrus-sasl 2.1.28 | `ea10d3aa40ccb6a385af666173b3364fc41f39dfbdc90aa8f2f1d8071cb63537` |
| `libcrypto-3-x64.dll` | openssl 3.6.4 | `ad397e1391ae38100fa1043d69a3495efa73fd9c2784de0ffc3ede3df1fd092e` |
| `libssl-3-x64.dll` | openssl 3.6.4 | `910b31e8f975658a934e726b92c90f71f66d20bc87d8bc758b1b4354e6cb8aa6` |
| `libsodium-26.dll` | libsodium 1.0.22 | `dfe5a04cb895333a8a7d1af85c727ede8e39a439b28026844067216ff4abda15` |
| `libsqlite3-0.dll` | sqlite3 3.53.4 | `cc70f6965cc7abe3122ecec38981d08c608df2f2ffe423950b5a85e3a3b4ffed` |
| `libargon2.dll` | argon2 20190702 | `949258e5a9792d2c008978df0ce5cc721302d32bc65b38c11b232c11cbd19470` |

## Loading

The loaders resolve these files by absolute path, in the directory of the
executable, and Windows is told to search nowhere else
(`LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32`). Never the
`PATH`, never the current directory: a `libcrypto-3-x64.dll` left in the
Downloads folder by someone else's installer does not get a vote. The flip
side is that a copy of `rottentree.exe` on its own does nothing.

They are MinGW builds and need nothing beyond the system DLLs of Windows 10
and later.
