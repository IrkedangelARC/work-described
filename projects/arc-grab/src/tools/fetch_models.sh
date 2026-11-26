#!/bin/zsh
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

# Pre-fetch the whisper models the app would otherwise download on the first
# transcript, into the same managed folder (build machines, test runs, a
# laptop being staged before a show). Same sources and size gates as
# Engine/ModelFetcher.swift.
set -euo pipefail
DIR="$HOME/Library/Application Support/ARC Grab/models"
mkdir -p "$DIR"
fetch() {  # file repo min_bytes
  local f="$1" repo="$2" min="$3" dst="$DIR/$1"
  if [[ -f "$dst" ]] && [[ $(stat -f %z "$dst") -ge $min ]]; then echo "present  $f"; return; fi
  echo "fetching $f from $repo"
  curl -sSL -o "$dst.part" "https://huggingface.co/$repo/resolve/main/$f"
  [[ $(stat -f %z "$dst.part") -ge $min ]] || { echo "$f came back short: $(head -c 80 "$dst.part")" >&2; rm -f "$dst.part"; exit 1; }
  mv "$dst.part" "$dst"
}
fetch ggml-large-v3-turbo-q5_0.bin ggerganov/whisper.cpp 500000000
fetch ggml-silero-v5.1.2.bin       ggml-org/whisper-vad   500000
ls -la "$DIR"
