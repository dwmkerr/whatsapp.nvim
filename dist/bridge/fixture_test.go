package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
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

	if len(by) != 15 {
		t.Fatalf("want 15 chats, got %d: %v", len(by), by)
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
	if _, ok := by["Elin Ward"]; !ok {
		t.Errorf("a saved contact whose history arrives named by number keeps the contact name: %+v", by)
	}
	if _, ok := by["Iris Novak"]; !ok {
		t.Errorf("a saved contact whose history arrives named by a masked number keeps the contact name: %+v", by)
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

func TestGroupWithoutSubjectNamedAfterItsMembers(t *testing.T) {
	w, _ := replayFixture(t, syntheticFixture)
	jid := "120363400000000007@g.us"
	c, err := w.store.GetChat(jid)
	if err != nil {
		t.Fatal(err)
	}
	if c.Name != "Ada, Bram & Gus" {
		t.Errorf("a group without a subject shows the other members' first names, as the phone does: %+v", c)
	}
	if n := w.store.ChatName(jid); n != "" {
		t.Errorf("the members' names are not stored as the subject: %q", n)
	}
	unnamed, _ := w.store.UnnamedChats()
	retried := false
	for _, u := range unnamed {
		retried = retried || u.JID == jid
	}
	if !retried {
		t.Error("a group named after its members is still asked for a subject")
	}
	if err := w.store.RenameChat(jid, "Van Share"); err != nil {
		t.Fatal(err)
	}
	if c, _ := w.store.GetChat(jid); c.Name != "Van Share" {
		t.Errorf("a subject set later replaces the members' names: %+v", c)
	}
}

func TestMembersNameReplacesAStoredPlaceholder(t *testing.T) {
	s := newTestStore(t)
	jid := "120363400000000011@g.us"
	if err := s.UpsertChat(jid, "Group 120363400000000011", true, 100); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetMembersName(jid, "Ada & Bram"); err != nil {
		t.Fatal(err)
	}
	if c, _ := s.GetChat(jid); c.Name != "Ada & Bram" {
		t.Errorf("a placeholder saved by an older bridge gives way to the members' names: %+v", c)
	}
}

func TestJoinNamesLikeThePhone(t *testing.T) {
	for _, tc := range []struct {
		in   []string
		want string
	}{
		{nil, ""},
		{[]string{"Ada"}, "Ada"},
		{[]string{"Ada", "Bram"}, "Ada & Bram"},
		{[]string{"Ada", "Bram", "Gus", "Elin"}, "Ada, Bram, Gus & Elin"},
	} {
		if got := joinNames(tc.in); got != tc.want {
			t.Errorf("joinNames(%v) = %q, want %q", tc.in, got, tc.want)
		}
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

func TestEditsChangeTheOriginalMessage(t *testing.T) {
	w, out := replayFixture(t, syntheticFixture)
	for _, tc := range []struct{ chat, id, text, form string }{
		{"120363400000000001@g.us", "BW07", "Running 20 late, sorry", "an encrypted group edit"},
		{"447700900101@s.whatsapp.net", "ADA04", "Also, the café opens at 8:30 now", "a plain protocol edit"},
	} {
		m, err := w.store.GetMessage(tc.chat, tc.id)
		if err != nil {
			t.Fatal(err)
		}
		if m.Text != tc.text || !m.Edited {
			t.Errorf("%s changes the original's text and marks it edited: %+v", tc.form, m)
		}
	}
	if _, err := w.store.GetMessage("120363400000000001@g.us", "BW08"); err == nil {
		t.Error("an edit is not stored as a message of its own")
	}
	if !strings.Contains(out.String(), `"event":"message.edited"`) {
		t.Error("a live edit tells the editor")
	}
}

func TestHDCopyAndNewPollsReadLikeThePhone(t *testing.T) {
	w, _ := replayFixture(t, syntheticFixture)
	chat := "120363400000000001@g.us"
	if _, err := w.store.GetMessage(chat, "BW15"); err == nil {
		t.Error("the HD copy of a photo is not stored as a second photo")
	}
	if _, err := w.store.GetMessage(chat, "BW19"); err == nil {
		t.Error("the HD copy of a video is not stored as a second video")
	}
	if m, err := w.store.GetMessage(chat, "BW18"); err != nil || m.MediaType != "video" {
		t.Errorf("the video sent in HD shows once, as a video: %+v %v", m, err)
	}
	if m, _ := w.store.GetMessage(chat, "BW16"); m.Text != "[poll] Pub after?" {
		t.Errorf("a poll in the newest format shows its question: %+v", m)
	}
}

func TestRepairUnsupportedRowsFromOlderBridges(t *testing.T) {
	w, _ := replayFixture(t, syntheticFixture)
	fx, err := loadFixture(syntheticFixture, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	chat := types.NewJID("120363400000000001", types.GroupServer)
	dev := types.NewJID("447700900104", types.DefaultUserServer)
	key := func(id string) *waCommon.MessageKey {
		return &waCommon.MessageKey{RemoteJID: proto.String(chat.String()), FromMe: proto.Bool(false), Participant: proto.String(dev.String()), ID: proto.String(id)}
	}
	// Rows as an older bridge stored them: unsupported text with the raw
	// message kept.
	for id, m := range map[string]*waE2E.Message{
		"OLD-EDIT": fx.message(fixtureMsg{EditOf: "BW03", Text: "I'm in, 7:30?"}, key("OLD-EDIT")),
		"OLD-HD":   fx.message(fixtureMsg{Media: "image", HDOf: "BW02"}, key("OLD-HD")),
		"OLD-POLL": fx.message(fixtureMsg{Poll: "Same time next week?"}, key("OLD-POLL")),
	} {
		raw, _ := proto.Marshal(m)
		if _, err := w.store.InsertMessage(Message{ID: id, ChatJID: chat.String(), Sender: dev.String(), Text: unsupportedText, TS: 100, raw: raw}); err != nil {
			t.Fatal(err)
		}
	}
	if n := w.RepairUnsupported(context.Background()); n != 3 {
		t.Errorf("all three rows are repaired, got %d", n)
	}
	if m, _ := w.store.GetMessage(chat.String(), "BW03"); m.Text != "I'm in, 7:30?" || !m.Edited {
		t.Errorf("a stored edit is applied to the message it changes: %+v", m)
	}
	for _, id := range []string{"OLD-EDIT", "OLD-HD"} {
		if _, err := w.store.GetMessage(chat.String(), id); err == nil {
			t.Errorf("%s is removed once read", id)
		}
	}
	if m, _ := w.store.GetMessage(chat.String(), "OLD-POLL"); m.Text != "[poll] Same time next week?" {
		t.Errorf("a stored poll gets its question: %+v", m)
	}
}

func TestHistoryNoticeSaysWhatWasShared(t *testing.T) {
	w, _ := replayFixture(t, syntheticFixture)
	m, _ := w.store.GetMessage("120363400000000001@g.us", "BW17")
	if want := "[history] sent Hana Iqbal & +447700900199 message history that starts on "; !strings.HasPrefix(m.Text, want) {
		t.Errorf("a shared history notice names who it went to, a stranger by number: got %q, want %q...", m.Text, want)
	}
	since := time.Date(2026, 11, 17, 21, 9, 0, 0, time.Local)
	if got := historyText([]string{"Laura"}, since); got != "[history] sent Laura message history that starts on 17 Nov at 21:09" {
		t.Errorf("worded as the phone words it: %q", got)
	}
	if got := extract(&waE2E.Message{MessageHistoryNotice: &waE2E.MessageHistoryNotice{}}).Text; got != "[history] sent new members message history" {
		t.Errorf("a notice with nothing in it still reads: %q", got)
	}
}
