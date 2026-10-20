default: help

.PHONY: help
help: # Show help for each of the Makefile recipes.
	@grep -E '^[a-zA-Z0-9 -]+:.*#'  Makefile | sort | while read -r l; do printf "\033[1;32m$$(echo $$l | cut -f 1 -d':')\033[00m:$$(echo $$l | cut -f 2- -d'#')\n"; done

.PHONY: build
build: # Build the Go bridge into dist/bin/wa-bridge.
	$(MAKE) -C dist build

.PHONY: dev
dev: build # Build the bridge, then open Neovim with WhatsApp.
	nvim +WhatsApp

.PHONY: test
test: # Run the Go and Lua test suites.
	$(MAKE) -C dist test

.PHONY: clean
clean: # Remove the built bridge.
	$(MAKE) -C dist clean
