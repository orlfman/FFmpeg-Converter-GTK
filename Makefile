# FFmpeg Converter GTK - Makefile
# Wrapper around Meson for release-oriented app builds.
# Tests are opt-in via `make test` and are not compiled by default.

BUILDDIR    := builddir
BINARY      := ffmpeg-converter-gtk
PREFIX      := /usr
DATADIR     := $(PREFIX)/share
ICONDIR     := $(DATADIR)/icons/hicolor/scalable/apps
DESKTOPDIR  := $(DATADIR)/applications

.PHONY: all setup build test install uninstall clean rebuild help

all: build

setup:
	@command -v meson >/dev/null  || { echo "Error: meson is not installed";    exit 1; }
	@command -v ninja >/dev/null  || { echo "Error: ninja is not installed";    exit 1; }
	@command -v valac >/dev/null  || { echo "Error: valac is not installed";    exit 1; }
	@command -v pkg-config >/dev/null || { echo "Error: pkg-config is not installed"; exit 1; }
	@if [ ! -d $(BUILDDIR) ]; then \
		meson setup $(BUILDDIR) --prefix=$(PREFIX); \
	else \
		meson setup $(BUILDDIR) --reconfigure --prefix=$(PREFIX); \
	fi

build: setup
	meson compile -C $(BUILDDIR)

test: build
	meson test -C $(BUILDDIR)

install: build
	sudo meson install -C $(BUILDDIR)
	@if [ -f /usr/local/bin/$(BINARY) ]; then \
		echo "Warning: legacy binary found at /usr/local/bin/$(BINARY)"; \
		echo "Removing to avoid conflicts..."; \
		sudo rm -f /usr/local/bin/$(BINARY); \
	fi
	sudo gtk-update-icon-cache $(DATADIR)/icons/hicolor -q 2>/dev/null || true
	sudo update-desktop-database $(DESKTOPDIR) 2>/dev/null || true
	@echo "FFmpeg Converter GTK installed to $(PREFIX)"

uninstall:
	sudo rm -f $(PREFIX)/bin/$(BINARY)
	sudo rm -f /usr/local/bin/$(BINARY)
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
	@echo "  all              Build the application only (default)"
	@echo "  setup            Check dependencies and run meson setup"
	@echo "  build            Compile the application for release-style builds"
	@echo "  test             Build and run the optional Meson test targets"
	@echo "  install          Build and install via meson install"
	@echo "  uninstall        Remove installed files"
	@echo "  clean            Remove the build directory"
	@echo "  rebuild          Clean and rebuild"
	@echo "  help             Show this help message"
