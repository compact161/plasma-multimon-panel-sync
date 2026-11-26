#!/usr/bin/env bash
# Install plasma-panel-sync for the current user (no root needed).
#   ./install.sh              install or update (idempotent)
#   ./install.sh --uninstall  remove what install.sh created
set -euo pipefail

SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN="$HOME/.local/bin"
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
SCRIPTS=(plasma-panel-sync plasma-panel-tray plasma-panel-ui)
ICON_FILES=(plasma-panel-sync.svg plasma-panel-sync-attention.svg)
MENU_ENTRY="$APPS/plasma-panel-sync.desktop"
AUTOSTART_ENTRY="$AUTOSTART/plasma-panel-sync.desktop"

refresh_menu() {
    command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 >/dev/null 2>&1 || true
}

do_uninstall() {
    for s in "${SCRIPTS[@]}"; do
        # only remove symlinks that point into this checkout
        if [[ -L "$BIN/$s" && "$(readlink -f "$BIN/$s")" == "$SRC/$s" ]]; then
            rm -f "$BIN/$s"
        fi
    done
    for i in "${ICON_FILES[@]}"; do rm -f "$ICONS/$i"; done
    rm -f "$MENU_ENTRY" "$AUTOSTART_ENTRY"
    refresh_menu
    echo "Uninstalled. Settings, snapshots and profiles in ~/.local/state and ~/.local/share/plasma-panel-sync are kept."
}

do_install() {
    mkdir -p "$BIN" "$ICONS" "$APPS" "$AUTOSTART"
    for s in "${SCRIPTS[@]}"; do
        chmod +x "$SRC/$s"
        ln -sfn "$SRC/$s" "$BIN/$s"
    done
    for i in "${ICON_FILES[@]}"; do install -m 644 "$SRC/$i" "$ICONS/$i"; done
    local icon="$ICONS/plasma-panel-sync.svg"
    # Exec points at the symlinks in ~/.local/bin; the scripts resolve their real location themselves.
    # Remove first: an older install may have left symlinks here, and writing through them
    # would overwrite the files they point to.
    rm -f "$MENU_ENTRY" "$AUTOSTART_ENTRY"
    sed -e "s|@BIN@|$BIN|g" -e "s|@ICON@|$icon|g" "$SRC/plasma-panel-sync.desktop" >"$MENU_ENTRY"
    sed -e "s|@BIN@|$BIN|g" -e "s|@ICON@|$icon|g" "$SRC/plasma-panel-sync-autostart.desktop" >"$AUTOSTART_ENTRY"
    refresh_menu
    echo "Installed to $BIN. The tray icon starts at next login, or run: plasma-panel-tray &"
}

case "${1:-}" in
    "") do_install ;;
    --uninstall) do_uninstall ;;
    -h | --help) sed -n '2,4p' "$0" ;;
    *)
        echo "Unknown option: $1" >&2
        exit 2
        ;;
esac
