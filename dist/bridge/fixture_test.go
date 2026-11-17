package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/proto/waSyncAction"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
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
	w.replay(fx, 0)
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

	if len(by) != 13 {
		t.Fatalf("want 13 chats, got %d: %v", len(by), by)
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

func TestArchivedChatsFollowThePhone(t *testing.T) {
	w, _ := replayFixture(t, syntheticFixture)
	by := chatsByName(t, w)
	for name, want := range map[string]bool{
		"Five-a-side Fridays": true,  // history sync, and a new message does not unarchive it
		"Allotment Society":   true,  // history sync
		"Book Club":           true,  // app state full sync only
		"Cleo Marsh":          true,  // live archive after connecting
		"Ada Fenwick":         false, // never archived
		"Boulder Wednesdays":  false,
	} {
		if c, ok := by[name]; !ok || c.Archived != want {
			t.Errorf("%s archived = %v, want %v: %+v", name, c.Archived, want, c)
		}
	}
	if c := by["Five-a-side Fridays"]; c.Unread != 40 {
		t.Errorf("archived chats keep counting unread for the Archived filter: %+v", c)
	}
	if w.store.ArchiveUnknown {
		t.Error("a fresh store never asks the phone for the archive again")
	}
}

func TestRepliesAlwaysCarryTheirQuote(t *testing.T) {
	w, _ := replayFixture(t, syntheticFixture)
	group := "120363400000000001@g.us"
	msgs, err := w.ListMessages(group, 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	by := map[string]Message{}
	for _, m := range msgs {
		by[m.ID] = m
	}
	if m := by["BW11"]; m.QuotedMedia != "document" || m.QuotedFilename != "route-plan.pdf" || m.QuotedSender != "Dev Patel-Ruiz" {
		t.Errorf("a reply to a document names its sender and file: %+v", m)
	}
	if m := by["BW12"]; m.QuotedText != "Who's helping with the reset on Sunday?" || m.QuotedSender != "Dev Patel-Ruiz" {
		t.Errorf("a reply to a message older than the store uses the copy it carries: %+v", m)
	}
	sent, err := w.SendText(context.Background(), group, "Bringing chalk", "BW05")
	if err != nil {
		t.Fatal(err)
	}
	if sent.QuotedMedia != "voice" || sent.QuotedSender != "Bram Okafor" {
		t.Errorf("our own reply comes back with its quote: %+v", sent)
	}
	if mine, err := w.SendText(context.Background(), group, "Again", sent.ID); err != nil || mine.QuotedSender != "me" || mine.QuotedText != "Bringing chalk" {
		t.Errorf("a reply to our own message quotes \"me\": %+v %v", mine, err)
	}
}

func TestGroupNamedOnceTheServerAnswers(t *testing.T) {
	w, _ := replayFixture(t, syntheticFixture)
	c, err := w.store.GetChat("120363400000000005@g.us")
	if err != nil {
		t.Fatal(err)
	}
	if c.Name != "Ridge Walkers" {
		t.Errorf("a group whose first lookup failed is named after the next sync: %+v", c)
	}
}

func TestGroupNamedFromTheJoinedListWhenItsLookupFails(t *testing.T) {
	w, _ := replayFixture(t, syntheticFixture)
	c, err := w.store.GetChat("120363400000000006@g.us")
	if err != nil {
		t.Fatal(err)
	}
	if c.Name != "Harbour Swimmers" {
		t.Errorf("a group whose own lookup keeps failing takes its name from the joined-groups list: %+v", c)
	}
}

func TestStoredGroupPlaceholderIsRetried(t *testing.T) {
	s := newTestStore(t)
	jid := "120363400000000009@g.us"
	if err := s.UpsertChat(jid, "Group 120363400000000009", true, 100); err != nil {
		t.Fatal(err)
	}
	unnamed, err := s.UnnamedChats()
	if err != nil {
		t.Fatal(err)
	}
	if len(unnamed) != 1 || unnamed[0].JID != jid {
		t.Errorf("a placeholder saved by an older bridge is retried: %+v", unnamed)
	}
	if err := s.UpsertChat("120363400000000010@g.us", "", true, 100); err != nil {
		t.Fatal(err)
	}
	if c, _ := s.GetChat("120363400000000010@g.us"); c.Name != "Group 120363400000000010" {
		t.Errorf("an unnamed group still shows a placeholder: %+v", c)
	}
	if n := s.ChatName("120363400000000010@g.us"); n != "" {
		t.Errorf("the placeholder is never stored: %q", n)
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

func TestFullSyncAppliesUnreadMarksButNotOldReadMarks(t *testing.T) {
	w, _ := replayFixture(t, syntheticFixture)
	by := chatsByName(t, w)
	if c := by["Dev Patel-Ruiz"]; c.Unread != 1 {
		t.Errorf("a full-sync unread mark shows the chat unread: %+v", c)
	}

	group := by["Boulder Wednesdays"]
	jid, _ := types.ParseJID(group.JID)
	w.handleEvent(&events.MarkChatAsRead{JID: jid, FromFullSync: true,
		Action: &waSyncAction.MarkChatAsReadAction{Read: proto.Bool(true)}})
	w.handleEvent(&events.MarkChatAsRead{JID: jid,
		Action: &waSyncAction.MarkChatAsReadAction{Read: proto.Bool(false)}})
	if c := chatsByName(t, w)["Boulder Wednesdays"]; c.Unread != group.Unread {
		t.Errorf("an old full-sync read mark and a live unread mark keep the real count %d: %+v", group.Unread, c)
	}
}
