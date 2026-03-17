PROJECT_DIR   := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD_DIR     := $(PROJECT_DIR)builddir
BINARY_NAME   := ffmpeg-converter-gtk
INSTALL_DIR   := /usr/local/bin

DESKTOP_SOURCE := $(PROJECT_DIR)Resources/FFmpegConverterGTK.desktop
DESKTOP_DEST   := /usr/share/applications/ffmpeg-converter-gtk.desktop
ICON_SOURCE    := $(PROJECT_DIR)Resources/ffmpeg-converter-gtk.svg
ICON_DEST      := /usr/share/icons/hicolor/scalable/apps/ffmpeg-converter-gtk.svg

.PHONY: all setup build install install-binary install-icon install-desktop uninstall clean test rebuild help

all: build

setup:
	meson setup $(BUILD_DIR)

build: setup
	meson compile -C $(BUILD_DIR)

test: build
	meson test -C $(BUILD_DIR)

install: install-binary install-icon install-desktop

install-binary: build
	sudo install -m 755 $(BUILD_DIR)/$(BINARY_NAME) $(INSTALL_DIR)/$(BINARY_NAME)

install-icon:
	sudo mkdir -p $(dir $(ICON_DEST))
	sudo install -m 644 $(ICON_SOURCE) $(ICON_DEST)
	sudo gtk-update-icon-cache /usr/share/icons/hicolor -q 2>/dev/null || true

install-desktop:
	sudo install -m 644 $(DESKTOP_SOURCE) $(DESKTOP_DEST)
	sudo update-desktop-database /usr/share/applications/ 2>/dev/null || true

uninstall:
	sudo rm -f $(INSTALL_DIR)/$(BINARY_NAME)
	sudo rm -f $(ICON_DEST)
	sudo rm -f $(DESKTOP_DEST)
	sudo update-desktop-database /usr/share/applications/ 2>/dev/null || true
	sudo gtk-update-icon-cache /usr/share/icons/hicolor -q 2>/dev/null || true

clean:
	rm -rf $(BUILD_DIR)

rebuild: clean build

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all              Build the project (default)"
	@echo "  setup            Run meson setup"
	@echo "  build            Compile the project"
	@echo "  test             Build and run tests"
	@echo "  install          Install binary, icon, and desktop file"
	@echo "  install-binary   Install only the binary to $(INSTALL_DIR)"
	@echo "  install-icon     Install the application icon"
	@echo "  install-desktop  Install the desktop entry"
	@echo "  uninstall        Remove installed files"
	@echo "  clean            Remove the build directory"
	@echo "  rebuild          Clean and rebuild"
	@echo "  help             Show this help message"
