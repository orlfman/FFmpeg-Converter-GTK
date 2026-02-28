#!/bin/bash
set -uo pipefail

BINARY_NAME="ffmpeg-converter-gtk"
INSTALL_DIR="/usr/local/bin"
DESKTOP_DEST="/usr/share/applications/ffmpeg-converter-gtk.desktop"
ICON_DEST="/usr/share/icons/hicolor/scalable/apps/ffmpeg-converter-gtk.svg"

# Track results
declare -a removed_items=()
declare -a failed_items=()
found_any=0

echo "=== FFmpeg Converter GTK - Uninstaller ==="
echo

# Check what's installed first
echo "Checking installed files..."
for path in "$INSTALL_DIR/$BINARY_NAME" "$DESKTOP_DEST" "$ICON_DEST"; do
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

# Verify sudo access
if ! sudo -v 2>/dev/null; then
    echo "❌ Error: sudo access is required for uninstallation."
    exit 1
fi

remove_file() {
    local path="$1"
    local label="$2"

    if [ ! -e "$path" ]; then
        echo "→ $label not found — skipping"
        return
    fi

    echo "→ Removing $label: $path"
    if sudo rm -f "$path"; then
        echo "  ✅ Done"
        removed_items+=("$label")
    else
        echo "  ❌ Failed to remove $path"
        failed_items+=("$label")
    fi
}

remove_file "$INSTALL_DIR/$BINARY_NAME" "binary"
remove_file "$DESKTOP_DEST" ".desktop entry"
remove_file "$ICON_DEST" "application icon"

# Refresh caches only if we actually removed something
if [ ${#removed_items[@]} -gt 0 ]; then
    echo
    echo "Refreshing icon cache and desktop database..."
    sudo gtk-update-icon-cache /usr/share/icons/hicolor -q 2>/dev/null || true
    sudo update-desktop-database /usr/share/applications/ 2>/dev/null || true
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
