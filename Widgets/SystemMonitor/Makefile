#
#  Makefile
#  SystemMonitor
#

PRODUCT := SystemMonitor
WIDGETS_DIR := $(HOME)/Library/Application Support/Pock/Widgets
DERIVED_DATA := build

.PHONY: build install clean

## Resolve dependencies and build the .pock bundle
build:
	pod install
	xcodebuild -workspace $(PRODUCT).xcworkspace \
	           -scheme $(PRODUCT) \
	           -configuration Release \
	           -derivedDataPath $(DERIVED_DATA) \
	           build

## Build and copy the widget into Pock's widgets folder
install: build
	rm -rf "$(WIDGETS_DIR)/$(PRODUCT).pock"
	cp -R $(DERIVED_DATA)/Build/Products/Release/$(PRODUCT).pock "$(WIDGETS_DIR)/"
	@echo "Installed to $(WIDGETS_DIR)/$(PRODUCT).pock — reload Pock to load it."

clean:
	rm -rf $(DERIVED_DATA)
