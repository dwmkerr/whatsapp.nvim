package main

import (
	"path/filepath"
	"testing"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := OpenStore(filepath.Join(t.TempDir(), "m.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestChatListOrderAndUnread(t *testing.T) {
	s := newTestStore(t)
	must(t, s.UpsertChat("a@s.whatsapp.net", "Alice", false, 100))
	must(t, s.UpsertChat("b@s.whatsapp.net", "Bob", false, 200))
	must(t, s.IncrementUnread("a@s.whatsapp.net"))
	_, err := s.InsertMessage(Message{ID: "1", ChatJID: "b@s.whatsapp.net", Text: "latest", TS: 200})
	must(t, err)

	chats, err := s.ListChats()
	must(t, err)
	if len(chats) != 2 || chats[0].Name != "Bob" || chats[1].Unread != 1 || chats[0].LastText != "latest" {
		t.Fatalf("got %+v", chats)
	}

	must(t, s.ClearUnread("a@s.whatsapp.net"))
	c, _ := s.GetChat("a@s.whatsapp.net")
	if c.Unread != 0 {
		t.Fatalf("unread not cleared: %+v", c)
	}
}

func TestUpsertChatKeepsNameAndNewestTS(t *testing.T) {
	s := newTestStore(t)
	must(t, s.UpsertChat("a@s.whatsapp.net", "Alice", false, 300))
	must(t, s.UpsertChat("a@s.whatsapp.net", "", false, 100))
	c, _ := s.GetChat("a@s.whatsapp.net")
	if c.Name != "Alice" || c.LastTS != 300 {
		t.Fatalf("got %+v", c)
	}
}

func TestMessagesOldestFirstAndDedup(t *testing.T) {
	s := newTestStore(t)
	for i, ts := range []int64{30, 10, 20} {
		_, err := s.InsertMessage(Message{ID: string(rune('a' + i)), ChatJID: "x", Text: "t", TS: ts})
		must(t, err)
	}
	fresh, err := s.InsertMessage(Message{ID: "a", ChatJID: "x", Text: "dup", TS: 30})
	must(t, err)
	if fresh {
		t.Fatal("duplicate insert reported as new")
	}
	msgs, err := s.ListMessages("x", 10, 0)
	must(t, err)
	if len(msgs) != 3 || msgs[0].TS != 10 || msgs[2].TS != 30 {
		t.Fatalf("got %+v", msgs)
	}
	page, _ := s.ListMessages("x", 1, 30)
	if len(page) != 1 || page[0].TS != 20 {
		t.Fatalf("pagination got %+v", page)
	}
}

func TestRenameChatFixesHistory(t *testing.T) {
	s := newTestStore(t)
	must(t, s.UpsertChat("447@s.whatsapp.net", "447", false, 10))
	must(t, s.UpsertChat("448@s.whatsapp.net", "Named", false, 10))
	_, _ = s.InsertMessage(Message{ID: "1", ChatJID: "447@s.whatsapp.net", Sender: "447@s.whatsapp.net", SenderName: "447", Text: "x", TS: 10})
	unnamed, err := s.UnnamedChats()
	must(t, err)
	if len(unnamed) != 1 || unnamed[0].JID != "447@s.whatsapp.net" {
		t.Fatalf("got %+v", unnamed)
	}
	must(t, s.RenameChat("447@s.whatsapp.net", "Alice"))
	msgs, _ := s.ListMessages("447@s.whatsapp.net", 10, 0)
	c, _ := s.GetChat("447@s.whatsapp.net")
	if c.Name != "Alice" || msgs[0].SenderName != "Alice" {
		t.Fatalf("rename not applied: %+v %+v", c, msgs[0])
	}
}

func TestQuotedTextResolved(t *testing.T) {
	s := newTestStore(t)
	_, _ = s.InsertMessage(Message{ID: "q", ChatJID: "x", Text: "original", TS: 1})
	_, _ = s.InsertMessage(Message{ID: "r", ChatJID: "x", Text: "reply", TS: 2, QuotedID: "q"})
	msgs, _ := s.ListMessages("x", 10, 0)
	if msgs[1].QuotedText != "original" {
		t.Fatalf("got %+v", msgs)
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestReadUpToLowersButNeverRaises(t *testing.T) {
	s := newTestStore(t)
	const jid = "a@s.whatsapp.net"
	must(t, s.UpsertChat(jid, "Alice", false, 300))
	for i, ts := range []int64{100, 200, 300} {
		_, err := s.InsertMessage(Message{ID: string(rune('1' + i)), ChatJID: jid, TS: ts})
		must(t, err)
	}
	must(t, s.SetUnread(jid, 3))

	must(t, s.ReadUpTo(jid, 200))
	if c, _ := s.GetChat(jid); c.Unread != 1 {
		t.Fatalf("want 1 unread after reading up to 200, got %d", c.Unread)
	}
	must(t, s.ReadUpTo(jid, 0))
	if c, _ := s.GetChat(jid); c.Unread != 1 {
		t.Fatalf("an older receipt raised the count to %d", c.Unread)
	}
	must(t, s.ReadUpTo(jid, 300))
	if c, _ := s.GetChat(jid); c.Unread != 0 {
		t.Fatalf("want 0 unread after reading everything, got %d", c.Unread)
	}
}

func TestCapUnreadAtOwnReply(t *testing.T) {
	s := newTestStore(t)
	const replied, silent = "a@s.whatsapp.net", "b@s.whatsapp.net"
	must(t, s.UpsertChat(replied, "Alice", false, 300))
	must(t, s.UpsertChat(silent, "Bob", false, 300))
	msgs := []Message{
		{ID: "1", ChatJID: replied, TS: 100},
		{ID: "2", ChatJID: replied, TS: 200, FromMe: true},
		{ID: "3", ChatJID: replied, TS: 300},
		{ID: "4", ChatJID: silent, TS: 300},
	}
	for _, m := range msgs {
		_, err := s.InsertMessage(m)
		must(t, err)
	}
	must(t, s.SetUnread(replied, 19))
	must(t, s.SetUnread(silent, 5))

	must(t, s.CapUnreadAtOwnReply())
	if c, _ := s.GetChat(replied); c.Unread != 1 {
		t.Fatalf("want 1 unread after the reply, got %d", c.Unread)
	}
	// Nothing sent from this account, so nothing says the count is wrong.
	if c, _ := s.GetChat(silent); c.Unread != 5 {
		t.Fatalf("chat without a reply changed to %d", c.Unread)
	}
}
