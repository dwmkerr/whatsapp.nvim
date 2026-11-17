default: help

.PHONY: help
help: # Show help for each of the Makefile recipes.
	@grep -E '^[a-zA-Z0-9 -]+:.*#'  Makefile | sort | while read -r l; do printf "\033[1;32m$$(echo $$l | cut -f 1 -d':')\033[00m:$$(echo $$l | cut -f 2- -d'#')\n"; done

.PHONY: build
build: # Build the Go bridge into dist/bin/wa-bridge.
	$(MAKE) -C dist build

.PHONY: dev
dev: build # Build the bridge, then open Neovim with WhatsApp from this checkout.
	nvim --cmd "set runtimepath^=$(CURDIR)/dist" +WhatsApp

# The checkout goes first on the runtimepath so it wins over an installed
# copy, and works when the user's config does not install the plugin at all.
FIXTURE ?= $(CURDIR)/dist/test/fixtures/synthetic.json
PACE ?= 1
.PHONY: demo
demo: build # Open the plugin from this checkout against a synthetic account (FIXTURE=path, PACE=delay multiplier).
	WHATSAPP_FIXTURE=$(FIXTURE) WHATSAPP_FIXTURE_PACE=$(PACE) nvim --clean -u $(CURDIR)/dist/test/demo.lua +WhatsApp

.PHONY: test
test: # Run the Go and Lua test suites.
	$(MAKE) -C dist test

.PHONY: clean
clean: # Remove the built bridge.
	$(MAKE) -C dist clean
