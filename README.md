# nobuffr-libvlc

The libVLC build used by the NoBuffr macOS app: **libVLC 3.0.24**, arm64, macOS 15.0 or later.

Release version: `3.0.24-nobuffr-macos.1` (VLC 3.0.24, build script revision 1).

## What is in this repository

| File | What it is |
| --- | --- |
| `build-libvlc-macos.sh` | The script that downloads VLC 3.0.24, builds its third-party libraries ("contribs") and VLC itself, and installs only the libraries and plugins listed in it. |
| `MANIFEST.txt` | The record of the shipped build: upstream source and checksum, toolchain, every third-party library with its license, the plugin list and checksums of the output files. |
| `COPYING.LIB` | VLC's license text (LGPL-2.1), from the VLC 3.0.24 source tarball. |
| `LICENSE`, `LICENSES/` | License of the script and documentation. |

VLC and all contribs are **unmodified upstream sources**. We apply no patches. The script
only chooses which components to build and how.

## Rebuilding

You need Xcode plus `autoconf automake libtool pkg-config cmake meson ninja nasm` (for
example from Homebrew). They are build tools only; nothing from them is linked.

```
./build-libvlc-macos.sh
```

Options: `WORK=<dir>` (build tree, default `./work`), `OUT=<dir>` (result, default `./out`),
`JOBS=<n>`. The script downloads `vlc-3.0.24.tar.xz` from
https://download.videolan.org/pub/videolan/vlc/3.0.24/ and checks it against the pinned
sha256 `e7cab503d1d7d5849b89d2cf0e1ee60d0ef6d012407791b644b9cfc0cc225fdf`. VLC's contrib
makefiles verify every contrib download. The result is `out/lib/libvlc.dylib`,
`out/lib/libvlccore.dylib`, `out/plugins/` and a `MANIFEST.txt`.

The release page also carries the exact upstream sources the shipped build used, so you can
rebuild without network access to the upstream sites: the VLC tarball, and one archive of
every contrib source tarball.

## Components and licenses

VLC itself (libvlc, libvlccore and all shipped plugins): LGPL-2.1-or-later. GPL-only modules
are not built. The third-party libraries are linked statically into the plugins:

| Library | License |
| --- | --- |
| FFmpeg 8.1.2 (configured without `--enable-gpl`, `--enable-version3`, `--enable-nonfree`) | LGPL-2.1-or-later |
| FriBidi 1.0.12 | LGPL-2.1-or-later |
| libdvbpsi 1.3.3 | LGPL-2.1-or-later |
| libebml 1.4.6, libmatroska 1.7.2 | LGPL-2.1-or-later |
| libgcrypt 1.12.2, libgpg-error 1.61 | LGPL-2.1-or-later |
| soxr 0.1.3 | LGPL-2.1-or-later |
| libass 0.17.5 | ISC |
| FreeType 2.14.3 | FreeType License (FTL) |
| HarfBuzz 14.2.1 | MIT |
| libxml2 2.15.3 | MIT |
| libpng 1.6.58 | libpng-2.0 |
| OpenJPEG 2.5.4 | BSD-2-Clause |
| libgsm 1.0.13 | TU-Berlin-2.0 (permissive) |
| zlib 1.3.2 | Zlib |
| utfcpp 3.2.5 | BSL-1.0 |

TLS uses the system Security framework, so GnuTLS, nettle and gmp are not built.
`MANIFEST.txt` is the authoritative list.

Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved.

## Replacing the libraries

The libraries are dynamic (`libvlc.dylib`, `libvlccore.dylib`, plugin `.dylib` files), so you can
build your own with the script, swap them into the app bundle's libVLC folder and sign the
app again (libraries first, then the app).

## Contact and copyright

Questions about this build, or a request for the corresponding source: hello@nobuffr.com

Copyright for the build script and documentation: 24 Ventures, LLC. VLC and the other
libraries remain under their own licenses and copyrights.
