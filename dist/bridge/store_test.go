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
