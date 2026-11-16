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

func TestOfflineProgressReportsEachPercentOnce(t *testing.T) {
	var o offlineProgress
	if _, ok := o.step(); ok {
		t.Fatal("no replay announced, no progress")
	}
	o.start(200)
	var got []int
	for i := 0; i < 250; i++ {
		if p, ok := o.step(); ok {
			got = append(got, p)
		}
	}
	if len(got) != 100 || got[0] != 1 || got[99] != 100 {
		t.Fatalf("want 1..100 once each, got %d values %v..", len(got), got[:3])
	}
}
