.PHONY: build test test-go test-lua clean

build: bin/wa-bridge

bin/wa-bridge: $(wildcard bridge/*.go) bridge/go.mod bridge/go.sum
	cd bridge && CGO_ENABLED=1 go build -ldflags "-s -w" -o ../bin/wa-bridge .

test: test-go test-lua

test-go:
	cd bridge && go test ./...

test-lua:
	nvim --headless --clean -u test/init.lua -c 'lua local ok, err = pcall(require("test.run")); if not ok then io.stderr:write(tostring(err), "\n"); vim.cmd("cquit 1") end' -c "qa!"

clean:
	rm -rf bin
