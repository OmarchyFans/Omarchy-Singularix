#!/bin/bash
# Reverses install.sh: removes the symlink, the keybinding block, and the menu
# entries. Saved agents, secrets, and the plugin itself are left alone
# (`omarchy plugin remove fans.omarchy.agent-launcher` removes the plugin).
set -euo pipefail
MARK="fans.omarchy.agent-launcher"
L="$HOME/.local/bin/omarchy-agent-launcher"; [[ -L $L ]] && { rm -f "$L"; echo "  removed $L"; }
B="$HOME/.config/hypr/bindings.lua"
if [[ -f $B ]] && grep -q "$MARK" "$B"; then
  cp -a "$B" "$B.bak.$(date +%s)"
  sed -i "/-- Omarchy Agent Launcher ($MARK)/,+1d" "$B"; echo "  keybinding removed from $B"
fi
LF="$HOME/.config/hypr/looknfeel.lua"
if [[ -f $LF ]] && grep -q "$MARK) dashboard" "$LF"; then
  cp -a "$LF" "$LF.bak.$(date +%s)"
  sed -i "/-- Omarchy Agent Launcher ($MARK) dashboard/,+1d" "$LF"; echo "  dashboard window rule removed from $LF"
fi
M="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [[ -f $M ]] && grep -q "$MARK" "$M"; then
  cp -a "$M" "$M.bak.$(date +%s)"
  sed -i '/Omarchy Agent Launcher — append/d; /^  "agents\(\.[a-z]*\)\?": {/d' "$M"; echo "  menu entries removed from $M"
fi
echo "Done."
