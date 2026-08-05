#!/bin/bash
set -uo pipefail

DEV_BUILD=0

usage() {
    cat <<'EOF'
Usage: uninstall.sh [--dev] [--help]

  (no flags)  Remove a manual release install from /usr (refuses when the
              package manager owns it).

  --dev       Remove the development build installed by 'build.sh --dev'
              from ~/.local, along with its own config directory. Needs no
              sudo and cannot touch the release install.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dev) DEV_BUILD=1 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "❌ Unknown option: $arg"; echo; usage; exit 1 ;;
    esac
done

if [ "$DEV_BUILD" -eq 1 ]; then
    BINARY_NAME="ffmpeg-converter-gtk-devel"
    PREFIX="${PREFIX:-$HOME/.local}"
    CONFIG_DIR="$HOME/.config/FFmpeg-Converter-GTK-Devel"
else
    BINARY_NAME="ffmpeg-converter-gtk"
    PREFIX="${PREFIX:-/usr}"
    CONFIG_DIR="$HOME/.config/FFmpeg-Converter-GTK"
fi

INSTALL_DIR="$PREFIX/bin"
LEGACY_INSTALL_DIR="/usr/local/bin"
DESKTOP_DEST="$PREFIX/share/applications/$BINARY_NAME.desktop"
ICON_DEST="$PREFIX/share/icons/hicolor/scalable/apps/$BINARY_NAME.svg"

# Track results
declare -a removed_items=()
declare -a failed_items=()
found_any=0

if [ "$DEV_BUILD" -eq 1 ]; then
    echo "=== FFmpeg Converter GTK - Uninstaller (development build) ==="
else
    echo "=== FFmpeg Converter GTK - Uninstaller ==="
fi
echo "Prefix: $PREFIX"
echo

# --- Pacman ownership guard ---
# This uninstaller is for manual (make/meson) installs only. If the app
# was installed through pacman/the AUR, removing its files here would
# corrupt the package — pacman is the right tool for that.
#
# A dev install lives under $HOME with its own binary name, so no package can
# own it and there is nothing to guard.
if [ "$DEV_BUILD" -eq 0 ] \
        && command -v pacman &> /dev/null \
        && pacman -Qo "$INSTALL_DIR/$BINARY_NAME" &> /dev/null; then
    echo "ℹ️  $(pacman -Qo "$INSTALL_DIR/$BINARY_NAME")"
    echo "   This copy is managed by pacman — uninstall it with:"
    echo "       sudo pacman -R ffmpeg-converter-gtk"
    exit 0
fi

# The legacy /usr/local/bin path only ever held release installs.
if [ "$DEV_BUILD" -eq 1 ]; then
    CHECK_PATHS=("$INSTALL_DIR/$BINARY_NAME" "$DESKTOP_DEST" "$ICON_DEST" "$CONFIG_DIR")
else
    CHECK_PATHS=("$INSTALL_DIR/$BINARY_NAME" "$LEGACY_INSTALL_DIR/$BINARY_NAME" \
                 "$DESKTOP_DEST" "$ICON_DEST" "$CONFIG_DIR")
fi

# Check what's installed first
echo "Checking installed files..."
for path in "${CHECK_PATHS[@]}"; do
    if [ -e "$path" ]; then
        echo "  Found: $path"
        found_any=1
    fi
done

if [ "$found_any" -eq 0 ]; then
    echo
    echo "========================================"
    echo "ℹ️  Nothing to uninstall — no files were found."
    echo "========================================"
    exit 0
fi

# Confirmation prompt
echo
read -p "Proceed with uninstallation? [y/N] " -n 1 -r REPLY
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Everything a dev install owns is under $HOME, so it needs no elevation.
if [ "$DEV_BUILD" -eq 1 ]; then
    SUDO=""
else
    SUDO="sudo"
    if ! sudo -v 2>/dev/null; then
        echo "❌ Error: sudo access is required for uninstallation."
        exit 1
    fi
fi

remove_file() {
    local path="$1"
    local label="$2"

    if [ ! -e "$path" ]; then
        echo "→ $label not found — skipping"
        return
    fi

    echo "→ Removing $label: $path"
    if $SUDO rm -f "$path"; then
        echo "  ✅ Done"
        removed_items+=("$label")
    else
        echo "  ❌ Failed to remove $path"
        failed_items+=("$label")
    fi
}

remove_file "$INSTALL_DIR/$BINARY_NAME" "binary"
if [ "$DEV_BUILD" -eq 0 ]; then
    remove_file "$LEGACY_INSTALL_DIR/$BINARY_NAME" "legacy binary (/usr/local/bin)"
fi
remove_file "$DESKTOP_DEST" ".desktop entry"
remove_file "$ICON_DEST" "application icon"

# Remove user config directory (no sudo needed)
if [ -d "$CONFIG_DIR" ]; then
    echo "→ Removing config directory: $CONFIG_DIR"
    if rm -rf "$CONFIG_DIR"; then
        echo "  ✅ Done"
        removed_items+=("config directory")
    else
        echo "  ❌ Failed to remove $CONFIG_DIR"
        failed_items+=("config directory")
    fi
else
    echo "→ Config directory not found — skipping"
fi

# Refresh caches only if we actually removed something
if [ ${#removed_items[@]} -gt 0 ]; then
    echo
    echo "Refreshing icon cache and desktop database..."
    $SUDO gtk-update-icon-cache "$PREFIX/share/icons/hicolor" -q 2>/dev/null || true
    $SUDO update-desktop-database "$PREFIX/share/applications/" 2>/dev/null || true
fi

# Summary
echo
echo "========================================"
if [ ${#removed_items[@]} -gt 0 ]; then
    echo "✅ Removed: ${removed_items[*]}"
fi
if [ ${#failed_items[@]} -gt 0 ]; then
    echo "❌ Failed:  ${failed_items[*]}"
    echo "========================================"
    exit 1
fi
echo "✅ Uninstallation complete!"
echo "========================================"
