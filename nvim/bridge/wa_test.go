package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestMediaPathStaysUnderRoot(t *testing.T) {
	root := filepath.Join(t.TempDir(), "media")
	cases := []struct{ chat, id, name string }{
		{"447@s.whatsapp.net", "../../../../.config/nvim/plugin/x", "evil.lua"},
		{"../../etc", "ABC", "passwd"},
		{"447@s.whatsapp.net", "ABC", "../../.zshrc"},
		{"447@s.whatsapp.net", "ABC", "notes.command"},
		{"447@s.whatsapp.net", "ABC", "report.pdf"},
	}
	for _, c := range cases {
		p, err := mediaPath(root, c.chat, c.id, c.name)
		if err != nil {
			continue
		}
		if !strings.HasPrefix(p, root+string(filepath.Separator)) {
			t.Fatalf("%+v escaped root: %s", c, p)
		}
		if strings.Contains(p, "..") {
			t.Fatalf("%+v kept dot-dot: %s", c, p)
		}
		ext := filepath.Ext(p)
		if ext == ".lua" || ext == ".command" {
			t.Fatalf("%+v kept executable extension: %s", c, p)
		}
	}
	p, err := mediaPath(root, "447@s.whatsapp.net", "ABC", "report.pdf")
	if err != nil || filepath.Base(p) != "ABC-report.pdf" {
		t.Fatalf("benign name mangled: %s %v", p, err)
	}
}
