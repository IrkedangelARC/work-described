#!/bin/zsh
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

# Build the bundled engine: static arm64 ffmpeg + ffprobe (videotoolbox,
# audiotoolbox, securetransport, libdav1d for AV1) and the standalone yt-dlp.
# Everything the fleet Macs need ships inside ARC Grab.app; nothing from
# Homebrew or pip is required on the laptop.
#
#   tools/build_engine.sh            # ffmpeg 8.1.1 + dav1d + yt-dlp latest into engine/
#
# Outputs: engine/ffmpeg engine/ffprobe engine/whisper-cli engine/yt-dlp/ (onedir + VERSION) engine/VERSIONS
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC="$ROOT/engine-src"
PREFIX="$SRC/prefix"
FFVER="8.1.1"
WHISPERVER="v1.8.4"
OUT="$ROOT/engine"
mkdir -p "$SRC" "$OUT"
export PATH="/opt/homebrew/bin:$PATH"
JOBS=$(sysctl -n hw.ncpu)

# --- dav1d (static)
if [ ! -f "$PREFIX/lib/libdav1d.a" ]; then
  [ -d "$SRC/dav1d" ] || git clone -q --depth 1 https://code.videolan.org/videolan/dav1d.git "$SRC/dav1d"
  ( cd "$SRC/dav1d" && rm -rf build && meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release \
      --default-library=static -Denable_tools=false -Denable_tests=false >/dev/null && ninja -C build -j"$JOBS" >/dev/null && ninja -C build install >/dev/null )
fi

# --- LAME (static): ffmpeg has no native MP3 encoder, and without it every MP3 delivery failed with
# "Encoder not found" (found 2026-09-26; MP3 had never worked in a shipped build).
LAMEVER="3.100"
if [ ! -f "$PREFIX/lib/libmp3lame.a" ]; then
  [ -f "$SRC/lame-$LAMEVER.tar.gz" ] || curl -sSL -o "$SRC/lame-$LAMEVER.tar.gz" "https://downloads.sourceforge.net/project/lame/lame/$LAMEVER/lame-$LAMEVER.tar.gz"
  rm -rf "$SRC/lame-$LAMEVER" && tar xf "$SRC/lame-$LAMEVER.tar.gz" -C "$SRC"
  # 3.100 exports a symbol it no longer defines; the macOS linker rejects it.
  sed -i '' '/lame_init_old/d' "$SRC/lame-$LAMEVER/include/libmp3lame.sym"
  ( cd "$SRC/lame-$LAMEVER" && ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-frontend \
      --disable-decoder --host=aarch64-apple-darwin >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null )
fi

# --- ffmpeg (static, native codecs + videotoolbox + LAME)
if [ ! -d "$SRC/ffmpeg-$FFVER" ]; then
  curl -sSL -o "$SRC/ffmpeg-$FFVER.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FFVER.tar.xz"
  tar xf "$SRC/ffmpeg-$FFVER.tar.xz" -C "$SRC"
fi
( cd "$SRC/ffmpeg-$FFVER" && PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" ./configure --prefix="$PREFIX" \
    --arch=arm64 --disable-shared --enable-static --pkg-config-flags=--static \
    --disable-doc --disable-ffplay --disable-debug --disable-autodetect \
    --enable-videotoolbox --enable-audiotoolbox --enable-securetransport --enable-zlib \
    --enable-libdav1d --enable-libmp3lame --enable-pthreads --enable-neon \
    --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" >"$SRC/configure.log" 2>&1 \
  && make -j"$JOBS" >"$SRC/make.log" 2>&1 && make install >/dev/null )
cp "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe" "$OUT/"
strip "$OUT/ffmpeg" "$OUT/ffprobe"

# --- whisper.cpp CLI (static, Metal library embedded so no .metallib ships
# beside it; GGML_NATIVE off so the binary runs on any Apple silicon, not
# only the build box). Models are NOT bundled: the app fetches them on the
# first transcript (Engine/ModelFetcher.swift).
if [ ! -d "$SRC/whisper.cpp" ]; then
  git clone -q --depth 1 --branch "$WHISPERVER" https://github.com/ggml-org/whisper.cpp.git "$SRC/whisper.cpp"
fi
( cd "$SRC/whisper.cpp" && rm -rf build && cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_CPU_ALL_VARIANTS=OFF -DGGML_BLAS=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_EXAMPLES=ON \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 >"$SRC/whisper-cmake.log" 2>&1 \
  && cmake --build build --config Release -j"$JOBS" --target whisper-cli >"$SRC/whisper-make.log" 2>&1 )
cp "$SRC/whisper.cpp/build/bin/whisper-cli" "$OUT/whisper-cli"
strip "$OUT/whisper-cli"

# --- yt-dlp onedir (PyInstaller directory build: 0.2 s start after the
# one-time Gatekeeper scan; the single-file build re-extracts and re-scans
# on EVERY run, 8-13 s each, measured 2026-09-12). No -U in this variant;
# the app updates it by fetching this same zip (Engine/EngineUpdater.swift).
YTV=$(gh release view --repo yt-dlp/yt-dlp --json tagName -q .tagName)
TMPZ="$(mktemp -d)"
( cd "$TMPZ" && gh release download "$YTV" --repo yt-dlp/yt-dlp --pattern yt-dlp_macos.zip && ditto -x -k yt-dlp_macos.zip . )
[ -x "$TMPZ/yt-dlp_macos" ] && [ -d "$TMPZ/_internal" ] || { echo "unexpected yt-dlp_macos.zip layout" >&2; exit 1; }
rm -rf "$OUT/yt-dlp"; mkdir -p "$OUT/yt-dlp"
ditto "$TMPZ/yt-dlp_macos" "$OUT/yt-dlp/yt-dlp_macos"; ditto "$TMPZ/_internal" "$OUT/yt-dlp/_internal"
chmod +x "$OUT/yt-dlp/yt-dlp_macos"
echo "$YTV" > "$OUT/yt-dlp/VERSION"
rm -rf "$TMPZ"

{
  echo "ffmpeg $FFVER static arm64 (dav1d $(cd "$SRC/dav1d" && git describe --tags --always), lame $LAMEVER)"
  echo "whisper.cpp $WHISPERVER static arm64 (Metal embedded)"
  echo "yt-dlp $YTV onedir universal2"
  echo "built $(date +%F) on $(hostname -s)"
} > "$OUT/VERSIONS"
echo "--- engine/"; ls -la "$OUT"; cat "$OUT/VERSIONS"
echo "--- dynamic deps (must be system only):"; otool -L "$OUT/ffmpeg" "$OUT/whisper-cli" | grep -v "^/usr/lib\|^\s*/System\|^\s*/usr/lib" | grep -v ":$" || true
"$OUT/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -E "prores_videotoolbox|h264_videotoolbox|dnxhd|libmp3lame"
"$OUT/ffmpeg" -hide_banner -decoders 2>/dev/null | grep -E "libdav1d|^ V.*vp9|^ V.*h264 "
