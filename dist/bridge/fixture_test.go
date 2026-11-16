package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const syntheticFixture = "../test/fixtures/synthetic.json"

func replayFixture(t *testing.T, path string) (*WA, *bytes.Buffer) {
	t.Helper()
	fx, err := loadFixture(path, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	w, err := NewWA(context.Background(), t.TempDir(), NewWriter(&out))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(w.Disconnect)
	if err := w.useFixture(context.Background(), fx); err != nil {
		t.Fatal(err)
	}
	w.replay(fx, false)
	return w, &out
}

func chatsByName(t *testing.T, w *WA) map[string]Chat {
	t.Helper()
	chats, err := w.store.ListChats()
	if err != nil {
		t.Fatal(err)
	}
	by := map[string]Chat{}
	for _, c := range chats {
		by[c.Name] = c
	}
	return by
}

func TestSyntheticFixtureReplaysThroughTheBridge(t *testing.T) {
	w, out := replayFixture(t, syntheticFixture)
	by := chatsByName(t, w)

	if len(by) != 10 {
		t.Fatalf("want 10 chats, got %d: %v", len(by), by)
	}
	if c := by["Boulder Wednesdays"]; !c.IsGroup || c.Unread != 4 {
		t.Errorf("group keeps its name and counts the offline message: %+v", c)
	}
	if c := by["Ada Fenwick"]; c.Unread != 0 {
		t.Errorf("read receipt from the phone clears Ada: %+v", c)
	}
	if c := by["Bram Okafor"]; c.Unread != 1 {
		t.Errorf("history marked_unread shows as one unread: %+v", c)
	}
	if c, ok := by["Fitz Horne"]; !ok || c.Unread != 1 {
		t.Errorf("live message from a contact uses the contact name: %+v", by)
	}

	msgs, err := w.store.ListMessages(by["Ada Fenwick"].JID, 10, 0)
	if err != nil {
		t.Fatal(err)
	}
	var mine, reply int
	for _, m := range msgs {
		if m.FromMe {
			mine++
		}
		if m.QuotedID == "ADA01" {
			reply++
		}
	}
	if mine != 1 || reply != 1 {
		t.Errorf("Ada's chat has one message from me and one reply: %+v", msgs)
	}

	log := out.String()
	for _, want := range []string{`"event":"connected"`, `"percent":35`, `"percent":100`, `"event":"sync.done"`, `"event":"message"`} {
		if !strings.Contains(log, want) {
			t.Errorf("replay emits %s", want)
		}
	}
	if st := w.Status(); st["paired"] != true || st["connected"] != true {
		t.Errorf("fixture looks paired and connected: %v", st)
	}
}

func TestFixtureSendsStayLocal(t *testing.T) {
	w, _ := replayFixture(t, syntheticFixture)
	jid := "447700900105@s.whatsapp.net"
	m, err := w.SendText(context.Background(), jid, "On my way", "ELIN03")
	if err != nil {
		t.Fatal(err)
	}
	if !m.FromMe || m.ID == "" || m.QuotedID != "ELIN03" {
		t.Fatalf("send returns our message: %+v", m)
	}
	if _, err := w.store.GetMessage(jid, m.ID); err != nil {
		t.Fatalf("sent message is stored: %v", err)
	}
	if err := w.MarkUnread(context.Background(), jid); err != nil {
		t.Fatal(err)
	}
	if err := w.MarkRead(context.Background(), jid); err != nil {
		t.Fatal(err)
	}
}

func TestFixtureRejectsMistakesAtLoad(t *testing.T) {
	cases := map[string]string{
		"unknown type":    `{"me":{"phone":"447700900000"},"events":[{"type":"nope"}]}`,
		"unknown field":   `{"me":{"phone":"447700900000"},"events":[{"type":"message","chat":"1@s.whatsapp.net","colour":"red"}]}`,
		"group no sender": `{"me":{"phone":"447700900000"},"events":[{"type":"message","chat":"1@g.us","text":"hi"}]}`,
		"duplicate id":    `{"me":{"phone":"447700900000"},"events":[{"type":"message","chat":"1@s.whatsapp.net","id":"A"},{"type":"message","chat":"1@s.whatsapp.net","id":"A"}]}`,
		"bad time":        `{"me":{"phone":"447700900000"},"events":[{"type":"message","chat":"1@s.whatsapp.net","at":"yesterday"}]}`,
		"no me":           `{"events":[]}`,
	}
	for name, body := range cases {
		path := filepath.Join(t.TempDir(), "fx.json")
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadFixture(path, time.Now()); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}
