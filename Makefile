PREFIX ?= /usr/local

.PHONY: build test app dmg install install-cli uninstall clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

dmg:
	scripts/build-app.sh --dmg

## Installs MacItFree.app into /Applications and the `mif` CLI into $(PREFIX)/bin.
install: app
	rm -rf /Applications/MacItFree.app
	cp -R build/MacItFree.app /Applications/
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MacItFree.app
	$(MAKE) install-cli CLI=/Applications/MacItFree.app/Contents/Resources/bin/mif

CLI ?= .build/release/mif
install-cli:
	@if [ "$(CLI)" = ".build/release/mif" ]; then swift build -c release --product mif; fi
	mkdir -p $(PREFIX)/bin
	ln -sf "$(abspath $(CLI))" $(PREFIX)/bin/mif
	@echo "Installed mif -> $(PREFIX)/bin/mif"

uninstall:
	rm -rf /Applications/MacItFree.app
	rm -f $(PREFIX)/bin/mif

clean:
	rm -rf .build build
