default: help

.PHONY: help
help: # Show help for each of the Makefile recipes.
	@grep -E '^[a-zA-Z0-9 -]+:.*#'  Makefile | sort | while read -r l; do printf "\033[1;32m$$(echo $$l | cut -f 1 -d':')\033[00m:$$(echo $$l | cut -f 2- -d'#')\n"; done

.PHONY: build
build: bin/wa-bridge # Build the Go bridge into bin/wa-bridge.

bin/wa-bridge: $(wildcard bridge/*.go) bridge/go.mod bridge/go.sum
	cd bridge && CGO_ENABLED=1 go build -ldflags "-s -w" -o ../bin/wa-bridge .

.PHONY: dev
dev: build # Build the bridge and open Neovim on this checkout with WhatsApp.
	nvim --cmd "set rtp^=$(CURDIR)" +WhatsApp

.PHONY: test
test: test-go test-lua # Run the Go and Lua test suites.

.PHONY: test-go
test-go: # Run the bridge's Go tests.
	cd bridge && go test ./...

.PHONY: test-lua
test-lua: # Run the headless Neovim tests against the fake bridge.
	nvim --headless --clean -u test/init.lua -c 'lua local ok, err = pcall(require("test.run")); if not ok then io.stderr:write(tostring(err), "\n"); vim.cmd("cquit 1") end' -c "qa!"

.PHONY: clean
clean: # Remove the built bridge.
	rm -rf bin
