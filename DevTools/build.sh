#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/builddir"
BINARY_NAME="ffmpeg-converter-gtk"
PREFIX="/usr"
RUN_TESTS=0

check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ Error: '$1' is not installed. Please install it and try again."
        exit 1
    fi
}

check_pkg_config_dependency() {
    local dep="$1"
    local label="$2"

    if ! pkg-config --exists "$dep"; then
        echo "❌ Error: '$label' development files are not installed. Please install them and try again."
        exit 1
    fi
}

check_gstreamer_element() {
    local label="$1"
    shift

    local element
    for element in "$@"; do
        if gst-inspect-1.0 "$element" &> /dev/null; then
            return
        fi
    done

    echo "❌ Error: GStreamer is missing $label support."
    echo "   Install the appropriate base/good/bad/libav plugin package and try again."
    exit 1
}

echo "=== FFmpeg Converter GTK - Clean Fresh Build & Install ==="
echo "Detected project directory: $PROJECT_DIR"
echo

# --- Dependency checks ---
echo "Checking required tools..."
check_dependency meson
check_dependency ninja
check_dependency valac
check_dependency pkg-config
check_dependency cc
check_pkg_config_dependency glib-2.0 GLib
check_pkg_config_dependency gobject-2.0 GObject
check_pkg_config_dependency gio-2.0 GIO
check_pkg_config_dependency gtk4 GTK4
check_pkg_config_dependency cairo Cairo
check_pkg_config_dependency pango Pango
check_pkg_config_dependency libadwaita-1 libadwaita
check_pkg_config_dependency json-glib-1.0 json-glib
check_pkg_config_dependency libsoup-3.0 "libsoup 3"
check_dependency ffmpeg
check_dependency ffprobe
check_dependency gst-inspect-1.0
check_gstreamer_element "playback" playbin playbin3
check_gstreamer_element "Matroska/WebM container" matroskademux
check_gstreamer_element "MP4/QuickTime container" qtdemux
check_gstreamer_element "Opus audio" opusdec
check_gstreamer_element "Vorbis audio" vorbisdec
check_gstreamer_element "AAC audio" avdec_aac faad
check_gstreamer_element "H.264 video" avdec_h264 openh264dec
check_gstreamer_element "H.265/HEVC video" avdec_h265 libde265dec
check_gstreamer_element "VP9 video" vp9dec avdec_vp9
check_gstreamer_element "AV1 video" av1dec dav1ddec avdec_av1
echo "✅ All dependencies found"

if ! ffmpeg -hide_banner -filters 2>/dev/null \
        | awk '$2 == "libvmaf" { found=1 } END { exit !found }'; then
    echo "⚠️  Optional: this FFmpeg build has no libvmaf filter; Quality Target mode will be unavailable."
fi
if ! command -v ffplay &> /dev/null; then
    echo "⚠️  Optional: ffplay was not found; the ffplay playback preference will use its fallback."
fi
echo

# --- Optional test run prompt ---
read -p "Run Meson tests after building? [y/N] " -n 1 -r REPLY
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    RUN_TESTS=1
    echo "→ Tests will run after the build completes"
else
    echo "→ Skipping tests"
fi
echo

# --- Version bump prompt ---
MESON_FILE="$PROJECT_DIR/meson.build"
CONSTANTS_FILE="$PROJECT_DIR/src/util/constants.vala"

CURRENT_VERSION=$(grep -oP "^\s*version\s*:\s*'\K[^']+" "$MESON_FILE")
echo "Current version: $CURRENT_VERSION"
read -p "Enter new version (or press Enter to keep $CURRENT_VERSION): " NEW_VERSION

if [ -n "$NEW_VERSION" ] && [ "$NEW_VERSION" != "$CURRENT_VERSION" ]; then
    # Update meson.build
    sed -i "s/version : '$CURRENT_VERSION'/version : '$NEW_VERSION'/" "$MESON_FILE"
    # Update constants.vala
    sed -i "s/public const string VERSION = \"$CURRENT_VERSION\"/public const string VERSION = \"$NEW_VERSION\"/" "$CONSTANTS_FILE"
    echo "✅ Version updated: $CURRENT_VERSION → $NEW_VERSION"
else
    echo "→ Keeping version $CURRENT_VERSION"
fi
echo

# --- Clean build ---
if [ -d "$BUILD_DIR" ]; then
    echo "🧹 Removing old build directory..."
    rm -rf "$BUILD_DIR"
fi

echo "🔧 Running meson setup..."
if ! meson setup "$BUILD_DIR" "$PROJECT_DIR" --prefix="$PREFIX"; then
    echo "❌ Meson setup failed"
    exit 1
fi

echo "⚙️  Compiling..."
if ! meson compile -C "$BUILD_DIR"; then
    echo "❌ Build failed"
    exit 1
fi

if [ ! -f "$BUILD_DIR/$BINARY_NAME" ]; then
    echo "❌ Error: Binary '$BINARY_NAME' was not created in $BUILD_DIR"
    exit 1
fi
echo "✅ Build successful!"
echo

# --- Optional tests ---
if [ "$RUN_TESTS" -eq 1 ]; then
    echo "🧪 Running tests..."
    if ! meson test -C "$BUILD_DIR"; then
        echo "❌ Tests failed"
        exit 1
    fi
    echo "✅ Tests passed!"
    echo
fi

# --- Pacman ownership guard ---
# Never overwrite package-manager-owned files: a dev install into /usr
# would corrupt the AUR package (pacman -Qkk failures, the next upgrade
# silently reverting this build, pacman -R deleting it).
if command -v pacman &> /dev/null \
        && pacman -Qo "$PREFIX/bin/$BINARY_NAME" &> /dev/null; then
    echo "⚠️  $(pacman -Qo "$PREFIX/bin/$BINARY_NAME")"
    echo "   Skipping installation — dev builds must not overwrite package-managed files."
    echo
    echo "   Run this build directly:      $BUILD_DIR/$BINARY_NAME"
    echo "   Release installs/updates:     yay -S ffmpeg-converter-gtk"
    echo "   To install manually instead:  sudo pacman -R ffmpeg-converter-gtk  (then re-run this script)"
    echo
    echo "========================================"
    echo "✅ Build complete (not installed)"
    echo "   Binary: $BUILD_DIR/$BINARY_NAME"
    echo "========================================"
    exit 0
fi

# --- Installation ---
echo "Installing (sudo required)..."
if ! sudo -v 2>/dev/null; then
    echo "❌ Error: sudo access is required for installation."
    exit 1
fi

if ! sudo meson install -C "$BUILD_DIR"; then
    echo "❌ Installation failed"
    exit 1
fi

if [ -f /usr/local/bin/"$BINARY_NAME" ]; then
    echo "⚠️  Legacy binary found at /usr/local/bin/$BINARY_NAME"
    echo "   Removing to avoid conflicts..."
    sudo rm -f /usr/local/bin/"$BINARY_NAME"
fi

sudo gtk-update-icon-cache "$PREFIX/share/icons/hicolor" -q 2>/dev/null || true
sudo update-desktop-database "$PREFIX/share/applications/" 2>/dev/null || true

# --- Summary ---
echo
echo "========================================"
echo "✅ Installed to $PREFIX"
echo
echo "Run with: $BINARY_NAME"
echo "or search for 'FFmpeg Converter GTK' in your menu."
echo "========================================"
