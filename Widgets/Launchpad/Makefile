#
#  Makefile
#  Launchpad
#

PRODUCT := Launchpad
WIDGETS_DIR := $(HOME)/Library/Application Support/Pock/Widgets
BUILD_DIR := build
BUNDLE := $(BUILD_DIR)/$(PRODUCT).pock
SOURCES := $(wildcard $(PRODUCT)/Sources/*.swift)
ARCHS := arm64 x86_64

# The widget is one Swift file that needs nothing but PockKit, so it is compiled
# directly instead of through an Xcode project. PockKit's Swift interface comes
# from the SystemMonitor widget's Release build, which is where CocoaPods checks
# the framework source out; override this to build somewhere else.
POCKKIT_DIR ?= ../SystemMonitor/build/Build/Products/Release/PockKit

.PHONY: build install clean

## Compile the widget and assemble the .pock bundle
build: $(BUNDLE)

$(BUNDLE): $(SOURCES) $(PRODUCT)/Info.plist
	@test -d "$(POCKKIT_DIR)/PockKit.framework" || { \
		echo "PockKit.framework is missing from $(POCKKIT_DIR)."; \
		echo "Build the SystemMonitor widget once first (make -C ../SystemMonitor build)."; \
		exit 1; }
	@mkdir -p $(BUILD_DIR)
	@for arch in $(ARCHS); do \
		mkdir -p $(BUILD_DIR)/$$arch; \
		swiftc -O -module-name $(PRODUCT) -target $$arch-apple-macos11.0 \
			-emit-library -Xlinker -bundle \
			-F $(abspath $(POCKKIT_DIR)) \
			-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
			-o $(BUILD_DIR)/$$arch/$(PRODUCT) $(SOURCES) || exit 1; \
	done
	@mkdir -p $(BUNDLE)/Contents/MacOS
	lipo -create $(foreach arch,$(ARCHS),$(BUILD_DIR)/$(arch)/$(PRODUCT)) \
		-output $(BUNDLE)/Contents/MacOS/$(PRODUCT)
	cp $(PRODUCT)/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)

## Build and copy the widget into Pock's widgets folder
install: build
	rm -rf "$(WIDGETS_DIR)/$(PRODUCT).pock"
	cp -R $(BUNDLE) "$(WIDGETS_DIR)/"
	@echo "Installed to $(WIDGETS_DIR)/$(PRODUCT).pock — reload Pock to load it."

clean:
	rm -rf $(BUILD_DIR)
