#!/bin/bash
#
# Optional helper for the Agent Launcher. `omarchy plugin add` already installs
# the plugin; this script only offers the three extras a plugin cannot ship,
# each behind its own confirmation and each idempotent:
#
#   1. symlink bin/omarchy-agent-launcher into ~/.local/bin
#   2. append a SUPER + ALT + A keybinding to ~/.config/hypr/bindings.lua
#   3. append an "Agents" submenu to ~/.config/omarchy/extensions/omarchy-menu.jsonc
#
# Nothing is overwritten: existing lines are detected and skipped, and a
# timestamped backup is taken before either config file is appended to.
set -euo pipefail
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN="$REPO/bin/omarchy-agent-launcher"
MARK="fans.omarchy.agent-launcher"
YES=0; [[ ${1:-} == --yes ]] && YES=1
ask() { (( YES )) && return 0; read -rp "$1 [y/N] " a; [[ $a == [yY]* ]]; }

chmod +x "$BIN" 2>/dev/null || true

# 1. CLI on PATH
if ask "Symlink omarchy-agent-launcher into ~/.local/bin?"; then
  mkdir -p "$HOME/.local/bin"; ln -sfn "$BIN" "$HOME/.local/bin/omarchy-agent-launcher"
  echo "  linked ~/.local/bin/omarchy-agent-launcher"
fi

# 2. Keybinding
B="$HOME/.config/hypr/bindings.lua"
if [[ -f $B ]] && grep -q "$MARK" "$B"; then
  echo "  keybinding already present in $B"
elif ask "Add keybinding SUPER + ALT + A -> Agent launcher to $B?"; then
  [[ -f $B ]] && cp -a "$B" "$B.bak.$(date +%s)"
  cat >>"$B" <<LUA

-- Omarchy Agent Launcher ($MARK). SUPER + ALT + A was unbound by default.
o.bind("SUPER + ALT + A", "Agent launcher", "$BIN --popup")
LUA
  echo "  appended; run 'hyprctl reload && hyprctl configerrors' to verify"
fi

# 3. Menu entry
M="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [[ -f $M ]] && grep -q '"agents"' "$M"; then
  echo "  menu entry already present in $M"
elif ask "Add an Agents submenu to the Omarchy menu ($M)?"; then
  mkdir -p "$(dirname "$M")"
  if [[ -f $M ]]; then
    cp -a "$M" "$M.bak.$(date +%s)"
    # Insert before the final closing brace so the file stays valid JSONC.
    python3 - "$M" "$REPO/extensions/omarchy-menu.snippet.jsonc" <<'PY'
import sys, re
path, snippet = sys.argv[1], open(sys.argv[2]).read().rstrip() + "\n"
s = open(path).read()
i = s.rstrip().rfind("}")
if i < 0: sys.exit("no closing brace in " + path)
open(path, "w").write(s[:i] + snippet + s[i:])
PY
  else
    { echo "{"; cat "$REPO/extensions/omarchy-menu.snippet.jsonc"; echo "}"; } >"$M"
  fi
  echo "  appended; the menu hot-reloads"
fi
echo "Done."
