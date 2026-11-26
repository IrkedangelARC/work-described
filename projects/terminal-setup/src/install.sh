#!/bin/bash
# Link these dotfiles into $HOME. Safe to rerun: existing links are left alone, and any real file
# already at a destination is copied to <file>.pre-dotfiles-<date> before it is replaced.
# The swap is atomic (link to a temp name, then rename over), so running tools never see a missing path.
#   ./install.sh            link everything
#   ./install.sh --dry-run  show what would change
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
DRY=${1:-}
STAMP=$(date +%Y-%m-%d)

link() {  # link <repo-relative source> <absolute destination>
  local src="$REPO/$1" dst="$2"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then echo "ok       $dst"; return; fi
  if [ "$DRY" = "--dry-run" ]; then echo "would    $dst -> $src"; return; fi
  mkdir -p "$(dirname "$dst")"
  [ -e "$dst" ] && [ ! -L "$dst" ] && cp -p "$dst" "$dst.pre-dotfiles-$STAMP"
  ln -s "$src" "$dst.dotfiles-tmp" && mv -f "$dst.dotfiles-tmp" "$dst"
  echo "linked   $dst"
}

link tmux/tmux.conf        "$HOME/.tmux.conf"
link tmux/sessions.map     "$HOME/.tmux/sessions.map"
for f in "$REPO"/tmux/scripts/*; do link "tmux/scripts/$(basename "$f")" "$HOME/.tmux/scripts/$(basename "$f")"; done
link ghostty/config        "$HOME/.config/ghostty/config"
link claude/statusline.sh  "$HOME/.claude/statusline.sh"
for f in "$REPO"/claude/hooks/*; do link "claude/hooks/$(basename "$f")" "$HOME/.claude/hooks/$(basename "$f")"; done
link bin/t                 "$HOME/bin/t"

[ "$DRY" = "--dry-run" ] && exit 0
# tmux plugin manager (plugins install on first tmux start with prefix + I)
[ -d "$HOME/.tmux/plugins/tpm" ] || git clone -q https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
cat <<'MSG'

Next on a new machine:
  1. Theme files are generated, not stored here:  python3 ~/projects/arc-style/tools/gen_terminal_theme.py
  2. Claude hooks + status line: merge claude/settings.hooks.reference.json into ~/.claude/settings.json
  3. tmux: start tmux, press prefix + I to install plugins.  Ghostty: cmd+shift+, to reload.
MSG
