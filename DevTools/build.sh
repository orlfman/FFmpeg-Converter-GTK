#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_TESTS=0
DEV_BUILD=0
CLEAN_BUILD=-1   # -1 = use the per-mode default chosen below

usage() {
    cat <<'EOF'
Usage: build.sh [--dev] [--clean] [--help]

  (no flags)  Release build into builddir, installed to /usr (skipped when the
              package manager already owns the installed binary). Always starts
              from a clean build directory.

  --dev       Development build into builddir-dev, installed to ~/.local.
              Uses its own application ID, config directory, binary name and
              desktop entry, so it runs alongside an installed release build
              instead of replacing it. Never needs sudo and never touches /usr.

              Rebuilds incrementally, because the point of this mode is a
              short edit-build-run loop. Pass --clean to start fresh.

              Binary:   ffmpeg-converter-gtk-devel
              Settings: ~/.config/FFmpeg-Converter-GTK-Devel

  --clean     Force a from-scratch build directory (the default without --dev).
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dev)   DEV_BUILD=1 ;;
        --clean) CLEAN_BUILD=1 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "❌ Unknown option: $arg"; echo; usage; exit 1 ;;
    esac
done

if [ "$DEV_BUILD" -eq 1 ]; then
    BUILD_DIR="$PROJECT_DIR/builddir-dev"
    BINARY_NAME="ffmpeg-converter-gtk-devel"
    PREFIX="$HOME/.local"
    MESON_PROFILE="development"
    # A dev build that recompiles every file on every run is not a loop
    # anyone will use. Release builds keep their clean-room guarantee.
    [ "$CLEAN_BUILD" -eq -1 ] && CLEAN_BUILD=0
else
    BUILD_DIR="$PROJECT_DIR/builddir"
    BINARY_NAME="ffmpeg-converter-gtk"
    PREFIX="/usr"
    MESON_PROFILE="default"
    [ "$CLEAN_BUILD" -eq -1 ] && CLEAN_BUILD=1
fi

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

if [ "$DEV_BUILD" -eq 1 ]; then
    echo "=== FFmpeg Converter GTK - Development Build (alongside release) ==="
else
    echo "=== FFmpeg Converter GTK - Clean Fresh Build & Install ==="
fi
echo "Detected project directory: $PROJECT_DIR"
echo "Build directory:            $BUILD_DIR"
echo "Prefix:                     $PREFIX"
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
check_pkg_config_dependency mpv libmpv
check_dependency ffmpeg
check_dependency ffprobe
# Preview playback is libmpv, not GStreamer. The old per-codec gst-inspect
# probes are gone: they would now reject a working install, since mpv decodes
# through the FFmpeg libraries it links rather than through GStreamer plugins.
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
# Skipped for dev builds: bumping the release version is a step towards
# cutting a release, not something a throwaway test build should edit into
# tracked files.
MESON_FILE="$PROJECT_DIR/meson.build"
CONSTANTS_FILE="$PROJECT_DIR/src/util/constants.vala"

CURRENT_VERSION=$(grep -oP "^\s*version\s*:\s*'\K[^']+" "$MESON_FILE")
if [ "$DEV_BUILD" -eq 1 ]; then
    echo "→ Building version $CURRENT_VERSION (dev builds do not bump the version)"
    NEW_VERSION=""
else
    echo "Current version: $CURRENT_VERSION"
    read -p "Enter new version (or press Enter to keep $CURRENT_VERSION): " NEW_VERSION
fi

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

# --- Build directory ---
if [ "$CLEAN_BUILD" -eq 1 ] && [ -d "$BUILD_DIR" ]; then
    echo "🧹 Removing old build directory..."
    rm -rf "$BUILD_DIR"
fi

# --reconfigure is required on an existing directory, and rejected on a new
# one. The profile and prefix are passed either way so a reused directory can
# never keep stale values from a previous invocation.
echo "🔧 Running meson setup..."
if [ -d "$BUILD_DIR" ]; then
    echo "   (reusing $BUILD_DIR — pass --clean to rebuild from scratch)"
    MESON_SETUP_MODE="--reconfigure"
else
    MESON_SETUP_MODE=""
fi

if ! meson setup "$BUILD_DIR" "$PROJECT_DIR" ${MESON_SETUP_MODE:+"$MESON_SETUP_MODE"} \
        --prefix="$PREFIX" \
        -Dprofile="$MESON_PROFILE"; then
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

# --- Development installation ---
# Nothing here can collide with a packaged release: different prefix, binary
# name, application ID, config directory and desktop entry. So it skips both
# the pacman guard and sudo entirely.
if [ "$DEV_BUILD" -eq 1 ]; then
    echo "Installing to $PREFIX (no sudo needed)..."
    if ! meson install -C "$BUILD_DIR"; then
        echo "❌ Installation failed"
        exit 1
    fi

    gtk-update-icon-cache "$PREFIX/share/icons/hicolor" -q 2>/dev/null || true
    update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true

    echo
    echo "========================================"
    echo "✅ Development build installed to $PREFIX"
    echo
    echo "Search for 'FFmpeg Converter GTK (Development)' in your menu,"
    echo "or run: $PREFIX/bin/$BINARY_NAME"
    echo
    echo "It runs alongside the release build — separate process, separate"
    echo "settings in ~/.config/FFmpeg-Converter-GTK-Devel."
    # The desktop entry uses an absolute Exec=, so the menu always works. This
    # only reports whether the short command is usable from this shell.
    case ":$PATH:" in
        *":$PREFIX/bin:"*)
           echo
           echo "'$BINARY_NAME' also works from this shell ($PREFIX/bin is on your PATH)." ;;
        *) echo
           echo "Note: $PREFIX/bin is not on this shell's PATH, so use the full"
           echo "path above. The menu entry is unaffected." ;;
    esac
    echo
    echo "To remove it:"
    echo "    ./DevTools/uninstall.sh --dev"
    echo "========================================"
    exit 0
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
    echo "   Install alongside it instead: ./DevTools/build.sh --dev"
    echo "   Run this build directly:      $BUILD_DIR/$BINARY_NAME"
    echo "   Release installs/updates:     yay -S ffmpeg-converter-gtk"
    echo "   To install manually instead:  sudo pacman -R ffmpeg-converter-gtk  (then re-run this script)"
    echo
    echo "   Note: run directly and it shares the release app's ID and settings —"
    echo "   if the release app is already open, launching this one just raises it."
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
