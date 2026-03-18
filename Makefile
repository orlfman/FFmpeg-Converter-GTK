# FFmpeg Converter GTK - Makefile
# Wrapper around Meson for building from source with make

BUILDDIR    := builddir
BINARY      := ffmpeg-converter-gtk
PREFIX      := /usr/local
BINDIR      := $(PREFIX)/bin
DATADIR     := /usr/share
ICONDIR     := $(DATADIR)/icons/hicolor/scalable/apps
DESKTOPDIR  := $(DATADIR)/applications

.PHONY: all setup build test install install-binary install-icon install-desktop uninstall clean rebuild help

all: build

setup:
	@command -v meson >/dev/null  || { echo "Error: meson is not installed";    exit 1; }
	@command -v ninja >/dev/null  || { echo "Error: ninja is not installed";    exit 1; }
	@command -v valac >/dev/null  || { echo "Error: valac is not installed";    exit 1; }
	@command -v pkg-config >/dev/null || { echo "Error: pkg-config is not installed"; exit 1; }
	@if [ ! -d $(BUILDDIR) ]; then meson setup $(BUILDDIR); else echo "Build directory already exists, skipping setup"; fi

build: setup
	meson compile -C $(BUILDDIR)

test: build
	meson test -C $(BUILDDIR)

install: install-binary install-icon install-desktop

install-binary: build
	sudo install -Dm 755 $(BUILDDIR)/$(BINARY) $(BINDIR)/$(BINARY)
	@echo "Binary installed to $(BINDIR)/$(BINARY)"

install-icon:
	sudo install -Dm 644 Resources/ffmpeg-converter-gtk.svg $(ICONDIR)/ffmpeg-converter-gtk.svg
	sudo gtk-update-icon-cache $(DATADIR)/icons/hicolor -q 2>/dev/null || true
	@echo "Icon installed to $(ICONDIR)/ffmpeg-converter-gtk.svg"

install-desktop:
	sudo install -Dm 644 Resources/FFmpegConverterGTK.desktop $(DESKTOPDIR)/ffmpeg-converter-gtk.desktop
	sudo update-desktop-database $(DESKTOPDIR) 2>/dev/null || true
	@echo "Desktop entry installed to $(DESKTOPDIR)/ffmpeg-converter-gtk.desktop"

uninstall:
	sudo rm -f $(BINDIR)/$(BINARY)
	sudo rm -f $(ICONDIR)/ffmpeg-converter-gtk.svg
	sudo rm -f $(DESKTOPDIR)/ffmpeg-converter-gtk.desktop
	rm -rf $(HOME)/.config/FFmpeg-Converter-GTK
	sudo gtk-update-icon-cache $(DATADIR)/icons/hicolor -q 2>/dev/null || true
	sudo update-desktop-database $(DESKTOPDIR) 2>/dev/null || true
	@echo "FFmpeg Converter GTK has been uninstalled"

clean:
	rm -rf $(BUILDDIR)

rebuild: clean build

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all              Build the project (default)"
	@echo "  setup            Check dependencies and run meson setup"
	@echo "  build            Compile the project"
	@echo "  test             Build and run tests"
	@echo "  install          Install binary, icon, and desktop file"
	@echo "  install-binary   Install only the binary to $(BINDIR)"
	@echo "  install-icon     Install the application icon"
	@echo "  install-desktop  Install the desktop entry"
	@echo "  uninstall        Remove installed files"
	@echo "  clean            Remove the build directory"
	@echo "  rebuild          Clean and rebuild"
	@echo "  help             Show this help message"
