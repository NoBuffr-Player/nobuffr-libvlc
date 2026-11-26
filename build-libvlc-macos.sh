#!/bin/bash
# Builds an LGPL-only libVLC 3.0 for macOS arm64, for bundling inside a sandboxed
# Mac App Store app that talks to libVLC through its public C API.
#
# The app is proprietary, so everything this script ships must be LGPL-2.1-or-later
# or more permissive. It therefore builds VLC and its third-party libraries
# ("contribs") from source and never touches VideoLAN's prebuilt VLC.app or prebuilt
# contribs, which contain GPL modules.
#
# Pinning: the VLC tarball is pinned by sha256 below. Every contrib version and its
# SHA512 comes from that tarball (contrib/src/<name>/rules.mak + SHA512SUMS), and
# VLC's contrib makefiles verify each download. The Xcode toolchain is not pinned;
# MANIFEST.txt records the one used.
#
# Usage: scripts/vlc/build-libvlc-macos.sh
#   WORK=<dir>  build tree (default ./work)      OUT=<dir>  result (default ./out)
#   JOBS=<n>    parallel jobs (default: CPU count)
# The absolute WORK path ends up inside the binaries (FFmpeg and VLC record their
# configure line, asserts record file names), so build release artifacts under a
# neutral path such as /private/tmp/libvlc-macos, not under a home directory.
# Needs Xcode plus: autoconf automake libtool pkg-config cmake meson ninja nasm
# (for example from Homebrew). They are build tools only; nothing from them is linked.
#
# Output: $OUT/lib/libvlc.dylib, $OUT/lib/libvlccore.dylib (install names @rpath/...),
# $OUT/plugins/*.dylib, $OUT/plugins/plugins.dat, $OUT/MANIFEST.txt.
# The binaries are ad-hoc signed. Re-sign them with the app's identity, and run
# vlc-cache-gen again afterwards if a valid plugins.dat is wanted (signing changes
# the file sizes the cache records; a stale cache is ignored, not fatal).
set -euo pipefail
#
VLC_VERSION=3.0.24
# Published at https://download.videolan.org/pub/videolan/vlc/3.0.24/vlc-3.0.24.tar.xz.sha256
VLC_SHA256=e7cab503d1d7d5849b89d2cf0e1ee60d0ef6d012407791b644b9cfc0cc225fdf
VLC_URL="https://download.videolan.org/pub/videolan/vlc/$VLC_VERSION/vlc-$VLC_VERSION.tar.xz"
ARCH=arm64
MIN_MACOS=15.0
WORK=${WORK:-$PWD/work}
OUT=${OUT:-$PWD/out}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
#
# Contribs to build. Their dependencies (third column of CONTRIB_LICENSES) are pulled
# in by VLC's contrib makefiles.
#   ffmpeg     software decoding, extra demuxers, swscale
#   ass        ASS/SSA subtitle rendering (CoreText font lookup on macOS)
#   freetype2 fribidi harfbuzz   text renderer for every other subtitle format
#   libxml2    TTML subtitles, DASH manifests
#   dvbpsi     MPEG-TS demuxer
#   matroska   MKV demuxer (with ebml)
#   gcrypt     AES-128 HLS segment decryption, SRTP
#   soxr       audio resampler, the GPL-free alternative to libsamplerate. VLC only
#              uses it when asked: pass --audio-resampler=soxr to libvlc_new().
CONTRIBS="ffmpeg ass freetype2 fribidi harfbuzz libxml2 dvbpsi matroska gcrypt soxr"
#
# Source tarball prefix | license | why it is built. Every tarball the contrib build
# downloads must match a row, or the script fails: a new dependency needs a license
# decision before it ships. Licenses were read from each project's COPYING/LICENSE.
# TLS needs no row: on macOS VLC 3.0 uses the system SecureTransport framework, so
# gnutls (whose nettle/gmp dependencies are LGPL-3.0/GPL-2.0) is never built.
CONTRIB_LICENSES="
ffmpeg|LGPL-2.1-or-later (configured without --enable-gpl/--enable-version3/--enable-nonfree)|listed
zlib|Zlib|ffmpeg, freetype2, png
libgsm|TU-Berlin-2.0 (permissive)|ffmpeg
openjpeg|BSD-2-Clause|ffmpeg
libass|ISC|listed
freetype|FTL (BSD-style with credit clause; chosen from the FTL/GPL-2.0 dual license)|listed
fribidi|LGPL-2.1-or-later|listed
harfbuzz|MIT|listed
libpng|libpng-2.0|harfbuzz
libxml2|MIT|listed
libdvbpsi|LGPL-2.1-or-later|listed
libebml|LGPL-2.1-or-later|matroska
libmatroska|LGPL-2.1-or-later|listed
utfcpp|BSL-1.0|ebml
libgcrypt|LGPL-2.1-or-later|listed
libgpg-error|LGPL-2.1-or-later|gcrypt
soxr|LGPL-2.1-or-later|listed
"
#
# Plugins to build and ship. Only these make targets are built, so nothing else can
# end up in the output. All are VLC modules whose sources carry the LGPL-2.1+ header.
PLUGINS="
filesystem http https tcp udp rtp attachment
prefetch cache_read cache_block inflate skiptags
adaptive ts ps mp4 mkv es h26x mpgv playlist avi asf wav flacsys subtitle ttml
avcodec videotoolbox spdif araw lpcm adpcm g711 rawvideo
subsdec subsusf libass dvbsub spudec cc scte18 scte27 stl substx3g textst webvtt
svcdsub cvdsub telx
packetizer_mpeg4audio packetizer_mpegaudio packetizer_a52 packetizer_dts
packetizer_h264 packetizer_hevc packetizer_mpegvideo packetizer_mpeg4video
packetizer_copy packetizer_mlp packetizer_vc1 packetizer_flac packetizer_av1
audio_format trivial_channel_mixer simple_channel_mixer remap ugly_resampler
soxr scaletempo tospdif gain float_mixer integer_mixer
auhal amem
swscale cvpx chain i420_rgb i420_yuy2 i420_nv12 i422_i420 i422_yuy2 yuy2_i420
yuy2_i422 rv32 grey_yuv yuvp
vmem scale blend freetype
securetransport xml console_logger memory_keystore
"
#
# GPL deny-list: plugins that must never be in the output. How it was determined:
#  1. VLC states each module's license in its source header. For 3.0.24 this lists
#     the files that are GPL and not LGPL:
#       grep -rl "GNU General Public License" src lib compat include modules \
#         | xargs grep -L "Lesser"
#     Each hit was mapped to its plugin through the lib<name>_plugin_la_SOURCES
#     lines of modules/*/Makefile.am (first block below).
#  2. Plugins that are LGPL themselves but link a GPL or LGPL-3.0 library
#     (second block; the library is named after each plugin).
# audit_sources() repeats step 1 on the files actually compiled, so a module whose
# license changes in a later VLC version is caught even if this list is stale.
GPL_DENYLIST="
visual glspectrum export logger stats audioscrobbler vod_rtsp osx_notifications
notify file_logger syslog access_realrtsp x262 x264 x26410b x265 t140 wma_fixed
deinterlace rotate hqdn3d mediadirs mtp podcast sap avahi mono
headphone_channel_mixer dolby_surround_decoder mpc real stream_out_rtp dummy
gestures hotkeys netsync oldrc motion lirc dbus remoteosd lua macosx
minimal_macosx qt skins2 ncurses
a52 dca faad libmpeg2 mad samplerate postproc zvbi dvdread dvdnav sid goom
projectm gnutls aribsub
"
# a52: liba52. dca: libdca. faad: faad2. libmpeg2: libmpeg2. mad: libmad.
# samplerate: libsamplerate. postproc: libpostproc. zvbi: zvbi. dvdread/dvdnav:
# libdvdread/libdvdnav. sid: sidplay2. goom: goom. projectm: projectM (all GPL).
# gnutls: nettle + gmp (LGPL-3.0 or GPL-2.0). aribsub: aribb24 (LGPL-3.0).
# AC-3, DTS, AAC, MPEG-2 and MP3 are decoded by FFmpeg's own LGPL decoders instead.
#
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
#
for tool in xcrun autoconf automake glibtoolize pkg-config cmake meson ninja nasm; do
  command -v "$tool" >/dev/null || die "missing build tool: $tool"
done
[ "$(uname -m)" = "$ARCH" ] || die "run this on an $ARCH Mac (no cross build)"
mkdir -p "$WORK" "$OUT"
WORK=$(cd "$WORK" && pwd)
OUT=$(cd "$OUT" && pwd)
SRC="$WORK/vlc-$VLC_VERSION"
BUILD="$WORK/build"
TRIPLET="aarch64-apple-darwin$(uname -r | cut -d. -f1)"
PREFIX="$SRC/contrib/$TRIPLET"
#
log "Fetching VLC $VLC_VERSION"
TARBALL="$WORK/vlc-$VLC_VERSION.tar.xz"
[ -f "$TARBALL" ] || curl -fL --retry 3 -o "$TARBALL" "$VLC_URL"
echo "$VLC_SHA256  $TARBALL" | shasum -a 256 -c - || die "VLC tarball sha256 mismatch"
[ -d "$SRC" ] || tar -xf "$TARBALL" -C "$WORK"
#
# Toolchain: Xcode's clang against the macOS SDK. -mmacosx-version-min makes the
# binaries load on MIN_MACOS and later.
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
TARGET_FLAGS="-isysroot $SDKROOT -mmacosx-version-min=$MIN_MACOS -arch $ARCH"
export SDKROOT MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
export CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)" OBJC="$(xcrun -f clang)"
export OBJCXX="$CXX" AR="$(xcrun -f ar)" RANLIB="$(xcrun -f ranlib)"
export NM="$(xcrun -f nm)" STRIP="$(xcrun -f strip)"
# Contrib tools first, then whatever the caller has (build tools only).
export PATH="$PREFIX/bin:$PATH"
# Look for libraries only in the contrib prefix. Without this, pkg-config would
# also find libraries installed on the build machine (Homebrew), some of them GPL.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH
#
log "Building contribs: $CONTRIBS"
# EXTRA_CFLAGS/EXTRA_LDFLAGS are how VLC's contrib system takes target flags.
# USE_FFMPEG=1 selects FFmpeg (not Libav), as VLC's own macOS build does.
export EXTRA_CFLAGS="$TARGET_FLAGS" EXTRA_LDFLAGS="$TARGET_FLAGS" USE_FFMPEG=1
mkdir -p "$SRC/contrib/contrib-build"
cd "$SRC/contrib/contrib-build"
# --disable-gpl      VLC's switch that drops GPL contribs and GPL options of others
# --disable-gnuv3    same for (L)GPL-3.0 code
# --disable-sout     no encoders or muxers (FFmpeg: --disable-encoders --disable-muxers)
# --disable-disc     no DVD/Blu-ray libraries
# --enable-ad-clauses  accept licenses with an acknowledgement clause. FreeType needs it:
#                    without GPL it is used under the FTL, which requires crediting the
#                    FreeType Project in the app's documentation (license/about screen).
../bootstrap --build="$TRIPLET" --host="$TRIPLET" \
  --disable-gpl --disable-gnuv3 --disable-sout --disable-disc --enable-ad-clauses
# shellcheck disable=SC2046
make -j"$JOBS" $(printf '.%s ' $CONTRIBS)
unset EXTRA_CFLAGS EXTRA_LDFLAGS
# Proof that FFmpeg was configured as LGPL-2.1+ (it writes its license to config.h).
grep -q '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' ffmpeg/vlc_build/config.h \
  || die "FFmpeg is not configured as LGPL-2.1-or-later"
#
log "Configuring VLC"
mkdir -p "$BUILD"
cd "$BUILD"
export CC="$CC $TARGET_FLAGS" CXX="$CXX $TARGET_FLAGS -stdlib=libc++"
export OBJC="$OBJC $TARGET_FLAGS" OBJCXX="$OBJCXX $TARGET_FLAGS -stdlib=libc++"
# -Werror=partial-availability (as VLC's own macOS build): calling an API newer than
# MIN_MACOS without a runtime check fails the build instead of crashing on old systems.
AVAIL="-O2 -Werror=partial-availability"
export CFLAGS="$AVAIL" CXXFLAGS="$AVAIL" OBJCFLAGS="$AVAIL"
# --disable-nls                no gettext; the app shows its own strings
# --disable-lua                Lua interfaces/scripts are GPL and unused
# --disable-sout/--disable-vlm no streaming output or server features
# --disable-macosx ... --disable-ncurses   no VLC user interface of any kind (GPL)
# --disable-sparkle/--disable-update-check  the app store updates the app
# --enable-dependency-tracking writes the .Plo files audit_sources() reads
# --enable-merge-ffmpeg        the avcodec plugin also holds the avformat demuxer and
#                              parsers, so static FFmpeg is linked once, not three times
# --enable-<lib>               fail at configure time if a needed contrib is missing
# --disable-<gpl lib>          never pick up a GPL library, even if one is installed
# configure finds functions by linking against the SDK, which also has the ones added
# after MIN_MACOS. Tell it they are missing so VLC uses its own fallback.
export ac_cv_func_pipe2=no
[ -f Makefile ] || "$SRC/configure" \
  --build="$TRIPLET" --host="$TRIPLET" \
  --with-contrib="$PREFIX" \
  --with-macosx-version-min="$MIN_MACOS" --with-macosx-sdk="$SDKROOT" \
  --disable-nls --disable-debug --enable-dependency-tracking \
  --disable-lua --disable-sout --disable-vlm --disable-addonmanagermodules \
  --disable-macosx --disable-minimal-macosx --disable-qt --disable-skins2 \
  --disable-ncurses --disable-sparkle --disable-update-check \
  --disable-osx-notifications --disable-macosx-avfoundation --disable-dbus \
  --enable-merge-ffmpeg --enable-avcodec --enable-avformat --enable-swscale \
  --enable-libass --enable-freetype --enable-fribidi --enable-harfbuzz \
  --enable-libxml2 --enable-dvbpsi --enable-matroska --enable-libgcrypt \
  --enable-telx --enable-soxr \
  --disable-postproc --disable-a52 --disable-dca --disable-faad \
  --disable-libmpeg2 --disable-mad --disable-x264 --disable-x26410b \
  --disable-x262 --disable-x265 --disable-samplerate --disable-zvbi \
  --disable-dvdread --disable-dvdnav --disable-bluray --disable-live555 \
  --disable-realrtsp --disable-gnutls --disable-sid --disable-goom \
  --disable-projectm --disable-aribsub --disable-vcd --disable-libcddb \
  --disable-taglib --disable-chromecast --disable-screen
#
log "Building libvlccore, libvlc and $(echo $PLUGINS | wc -w | tr -d ' ') plugins"
make -C compat -j"$JOBS"
make -C src -j"$JOBS"
make -C lib -j"$JOBS"
# shellcheck disable=SC2046
make -C modules -j"$JOBS" $(printf 'lib%s_plugin.la ' $PLUGINS)
make -C bin -j"$JOBS" vlc-cache-gen
#
log "Collecting output"
rm -rf "$OUT/lib" "$OUT/plugins" "$OUT/MANIFEST.txt"
mkdir -p "$OUT/lib" "$OUT/plugins"
# -L: libtool leaves versioned files plus symlinks; ship one real file per library.
cp -L src/.libs/libvlccore.dylib lib/.libs/libvlc.dylib "$OUT/lib/"
for p in $PLUGINS; do
  cp "$(find modules -path "*/.libs/lib${p}_plugin.dylib")" "$OUT/plugins/"
done
# Make the binaries relocatable. The libraries get @rpath install names; libvlc finds
# libvlccore next to itself, plugins find it in ../lib relative to plugins/.
relocate() {
  local file=$1 rpath=$2 dep
  install_name_tool -id "@rpath/$(basename "$file")" "$file"
  for dep in $(otool -L "$file" | awk 'NR>1 {print $1}' | grep 'libvlccore' || true); do
    install_name_tool -change "$dep" "@rpath/libvlccore.dylib" "$file"
  done
  install_name_tool -add_rpath "$rpath" "$file"
  # Drop local symbols, then re-sign: arm64 macOS refuses unsigned or modified code.
  "$STRIP" -x "$file"
  codesign --force --sign - "$file" 2>/dev/null
}
relocate "$OUT/lib/libvlccore.dylib" "@loader_path"
relocate "$OUT/lib/libvlc.dylib" "@loader_path"
for f in "$OUT"/plugins/*.dylib; do relocate "$f" "@loader_path/../lib"; done
#
log "License and dependency checks"
# 1. Deny-list: no GPL plugin by name.
for p in $GPL_DENYLIST; do
  [ ! -e "$OUT/plugins/lib${p}_plugin.dylib" ] || die "GPL plugin in output: $p"
done
# 2. Source audit: the compiler's dependency files name every VLC source and header
#    that went into this build tree (only the targets above were built). None may
#    carry a GPL header without the word "Lesser". Bison-generated parsers are GPL
#    "with a special exception" that allows any license for the output, so they pass.
#    bin/ is not scanned: vlc-cache-gen (GPL) only runs at build time and is not shipped.
audit_sources() {
  find "$BUILD/compat" "$BUILD/src" "$BUILD/lib" "$BUILD/modules" \
    \( -name '*.Plo' -o -name '*.Po' \) -exec cat {} + \
    | tr ' ' '\n' | grep "^$SRC/" | sed 's/:$//' | sort -u | while read -r f; do
      [ -f "$f" ] || continue
      grep -q "GNU General Public License" "$f" || continue
      grep -q "Lesser\|special exception" "$f" || echo "$f"
    done
}
GPL_SOURCES=$(audit_sources)
[ -z "$GPL_SOURCES" ] || die "GPL-only sources were compiled: $GPL_SOURCES"
# 3. Self-contained: only system libraries and libvlccore may be linked dynamically.
#    Contribs are static, so anything else means a library leaked in from the host.
for f in "$OUT"/lib/*.dylib "$OUT"/plugins/*.dylib; do
  BAD=$(otool -L "$f" | awk 'NR>1 {print $1}' \
    | grep -v -e '^/usr/lib/' -e '^/System/Library/' -e '^@rpath/libvlc' || true)
  [ -z "$BAD" ] || die "$(basename "$f") links a non-system library: $BAD"
done
# 4. Every downloaded contrib tarball has a license row.
contrib_row() {
  local name=$1 row
  for row in $(echo "$CONTRIB_LICENSES" | tr ' ' '~'); do
    case "$name" in "${row%%|*}"[-_]*) echo "$row" | tr '~' ' '; return 0 ;; esac
  done
  return 1
}
for t in "$SRC"/contrib/tarballs/*; do
  contrib_row "$(basename "$t")" >/dev/null || die "no license recorded for $(basename "$t")"
done
#
log "Generating the plugin cache"
"$BUILD/bin/vlc-cache-gen" "$OUT/plugins"
#
log "Writing MANIFEST.txt"
{
  echo "libVLC $VLC_VERSION for macOS $ARCH, minimum macOS $MIN_MACOS"
  echo "VLC source: $VLC_URL"
  echo "VLC source sha256: $VLC_SHA256"
  echo "Toolchain: $(xcodebuild -version | tr '\n' ' ')SDK $(xcrun --sdk macosx --show-sdk-version)"
  echo
  echo "== VLC =="
  echo "libvlc.dylib, libvlccore.dylib and every plugin below: LGPL-2.1-or-later"
  echo "(VLC $VLC_VERSION; GPL-only modules are excluded, see the build script)"
  echo
  echo "== Third-party libraries, statically linked (source tarball | license | needed by) =="
  for t in "$SRC"/contrib/tarballs/*; do
    row=$(contrib_row "$(basename "$t")")
    echo "$(basename "$t") | $(echo "$row" | cut -d'|' -f2) | $(echo "$row" | cut -d'|' -f3)"
  done
  echo
  echo "== System frameworks (not redistributed) =="
  echo "TLS: Security.framework (SecureTransport). Decoding: VideoToolbox. Audio: CoreAudio."
  echo
  echo "== Plugins ($(ls "$OUT/plugins" | grep -c '_plugin.dylib$')) =="
  for f in "$OUT"/plugins/*.dylib; do basename "$f" | sed 's/^lib//;s/_plugin.dylib$//'; done
  echo
  echo "== sha256 =="
  (cd "$OUT" && shasum -a 256 lib/* plugins/*)
} > "$OUT/MANIFEST.txt"
#
log "Done in $((SECONDS / 60)) min $((SECONDS % 60)) s"
du -sh "$OUT/lib" "$OUT/plugins"
