package main

import (
	"database/sql"
	"fmt"
	"os"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// Chat is one row of the chat list as the editor sees it.
type Chat struct {
	JID      string `json:"jid"`
	Name     string `json:"name"`
	IsGroup  bool   `json:"is_group"`
	LastTS   int64  `json:"last_ts"`
	Unread   int    `json:"unread"`
	LastText string `json:"last_text,omitempty"`
}

// Message is one row of a conversation as the editor sees it.
type Message struct {
	ID         string `json:"id"`
	ChatJID    string `json:"chat_jid"`
	Sender     string `json:"sender"`
	SenderName string `json:"sender_name"`
	Text       string `json:"text"`
	TS         int64  `json:"ts"`
	FromMe     bool   `json:"from_me"`
	MediaType  string `json:"media_type,omitempty"`
	Filename   string `json:"filename,omitempty"`
	QuotedID   string `json:"quoted_id,omitempty"`
	QuotedText string `json:"quoted_text,omitempty"`
	Seconds    int    `json:"seconds,omitempty"`
	Waveform   []int  `json:"waveform,omitempty"`
	Cached     bool   `json:"cached,omitempty"`
	raw        []byte
}

type Store struct {
	db *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS chats (
	jid TEXT PRIMARY KEY,
	name TEXT NOT NULL DEFAULT '',
	is_group INTEGER NOT NULL DEFAULT 0,
	last_ts INTEGER NOT NULL DEFAULT 0,
	unread INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
	id TEXT NOT NULL,
	chat_jid TEXT NOT NULL,
	sender TEXT NOT NULL DEFAULT '',
	sender_name TEXT NOT NULL DEFAULT '',
	text TEXT NOT NULL DEFAULT '',
	ts INTEGER NOT NULL,
	from_me INTEGER NOT NULL DEFAULT 0,
	media_type TEXT NOT NULL DEFAULT '',
	filename TEXT NOT NULL DEFAULT '',
	quoted_id TEXT NOT NULL DEFAULT '',
	raw BLOB,
	PRIMARY KEY (id, chat_jid)
);
CREATE INDEX IF NOT EXISTS messages_chat_ts ON messages(chat_jid, ts);
`

func OpenStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite3", "file:"+path+"?_journal_mode=WAL&_busy_timeout=5000")
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("init schema: %w", err)
	}
	restrictFile(path)
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

// UpsertChat keeps the newest timestamp and never overwrites a known name
// with an empty one.
func (s *Store) UpsertChat(jid, name string, isGroup bool, ts int64) error {
	_, err := s.db.Exec(`
		INSERT INTO chats (jid, name, is_group, last_ts) VALUES (?, ?, ?, ?)
		ON CONFLICT(jid) DO UPDATE SET
			name = CASE WHEN excluded.name <> '' THEN excluded.name ELSE chats.name END,
			is_group = excluded.is_group,
			last_ts = MAX(chats.last_ts, excluded.last_ts)`,
		jid, name, boolInt(isGroup), ts)
	return err
}

// InsertMessage returns true when the row is new. Duplicates (history sync
// replaying a live message) are ignored.
func (s *Store) InsertMessage(m Message) (bool, error) {
	res, err := s.db.Exec(`
		INSERT OR IGNORE INTO messages
			(id, chat_jid, sender, sender_name, text, ts, from_me, media_type, filename, quoted_id, raw)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		m.ID, m.ChatJID, m.Sender, m.SenderName, m.Text, m.TS, boolInt(m.FromMe),
		m.MediaType, m.Filename, m.QuotedID, m.raw)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// RenameChat sets a display name and fixes sender names on stored messages
// from that contact, so history rendered before contacts synced catches up.
func (s *Store) RenameChat(jid, name string) error {
	if name == "" {
		return nil
	}
	if _, err := s.db.Exec(`UPDATE chats SET name = ? WHERE jid = ?`, name, jid); err != nil {
		return err
	}
	_, err := s.db.Exec(`UPDATE messages SET sender_name = ? WHERE sender = ? AND from_me = 0`, name, jid)
	return err
}

// UnnamedChats lists chats whose name is still the bare phone number or empty.
func (s *Store) UnnamedChats() ([]Chat, error) {
	rows, err := s.db.Query(`SELECT jid, name, is_group FROM chats WHERE name = '' OR name = substr(jid, 1, instr(jid, '@') - 1)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Chat
	for rows.Next() {
		var c Chat
		var isGroup int
		if err := rows.Scan(&c.JID, &c.Name, &isGroup); err != nil {
			return nil, err
		}
		c.IsGroup = isGroup == 1
		out = append(out, c)
	}
	return out, rows.Err()
}

// Reset drops cached chats and messages, used on logout so a later pair
// starts from the new account's history sync.
func (s *Store) Reset() error {
	_, err := s.db.Exec(`DELETE FROM messages; DELETE FROM chats;`)
	return err
}

func (s *Store) IncrementUnread(jid string) error {
	_, err := s.db.Exec(`UPDATE chats SET unread = unread + 1 WHERE jid = ?`, jid)
	return err
}

func (s *Store) ClearUnread(jid string) error {
	_, err := s.db.Exec(`UPDATE chats SET unread = 0 WHERE jid = ?`, jid)
	return err
}

func (s *Store) SetUnread(jid string, n int) error {
	_, err := s.db.Exec(`UPDATE chats SET unread = ? WHERE jid = ?`, n, jid)
	return err
}

// ReadUpTo lowers a chat's unread count to the incoming messages newer than
// ts, the time of the newest message read on another device. It never
// raises the count: a receipt only ever says that something was read.
func (s *Store) ReadUpTo(jid string, ts int64) error {
	_, err := s.db.Exec(`
		UPDATE chats SET unread = MIN(unread, (
			SELECT COUNT(*) FROM messages WHERE chat_jid = ? AND from_me = 0 AND ts > ?
		)) WHERE jid = ?`, jid, ts, jid)
	return err
}

// CapUnreadAtOwnReply applies the phone's rule that sending in a chat reads
// it, so no chat counts more unread messages than arrived after the last
// one sent from this account. It repairs counts left behind by read
// receipts this store never saw.
func (s *Store) CapUnreadAtOwnReply() error {
	_, err := s.db.Exec(`
		UPDATE chats SET unread = MIN(unread, (
			SELECT COUNT(*) FROM messages m WHERE m.chat_jid = chats.jid AND m.from_me = 0
			AND m.ts > (SELECT MAX(o.ts) FROM messages o WHERE o.chat_jid = chats.jid AND o.from_me = 1)
		)) WHERE unread > 0
		AND EXISTS (SELECT 1 FROM messages o WHERE o.chat_jid = chats.jid AND o.from_me = 1)`)
	return err
}

func (s *Store) ChatName(jid string) string {
	var name string
	_ = s.db.QueryRow(`SELECT name FROM chats WHERE jid = ?`, jid).Scan(&name)
	return name
}

func (s *Store) GetChat(jid string) (Chat, error) {
	var c Chat
	var isGroup int
	err := s.db.QueryRow(`SELECT jid, name, is_group, last_ts, unread FROM chats WHERE jid = ?`, jid).
		Scan(&c.JID, &c.Name, &isGroup, &c.LastTS, &c.Unread)
	c.IsGroup = isGroup == 1
	return c, err
}

func (s *Store) ListChats() ([]Chat, error) {
	rows, err := s.db.Query(`
		SELECT c.jid, c.name, c.is_group, c.last_ts, c.unread,
			COALESCE((SELECT text FROM messages m WHERE m.chat_jid = c.jid ORDER BY ts DESC LIMIT 1), '')
		FROM chats c
		WHERE c.last_ts > 0
		ORDER BY c.last_ts DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Chat{}
	for rows.Next() {
		var c Chat
		var isGroup int
		if err := rows.Scan(&c.JID, &c.Name, &isGroup, &c.LastTS, &c.Unread, &c.LastText); err != nil {
			return nil, err
		}
		c.IsGroup = isGroup == 1
		out = append(out, c)
	}
	return out, rows.Err()
}

// ListMessages returns up to limit messages before beforeTS (0 = newest),
// oldest first so the editor can append in order.
func (s *Store) ListMessages(jid string, limit int, beforeTS int64) ([]Message, error) {
	if limit <= 0 {
		limit = 100
	}
	if beforeTS <= 0 {
		beforeTS = time.Now().Unix() + 86400
	}
	rows, err := s.db.Query(`
		SELECT m.id, m.chat_jid, m.sender, m.sender_name, m.text, m.ts, m.from_me, m.media_type, m.filename, m.quoted_id,
			COALESCE((SELECT q.text FROM messages q WHERE q.id = m.quoted_id AND q.chat_jid = m.chat_jid), ''), m.raw
		FROM messages m
		WHERE m.chat_jid = ? AND m.ts < ?
		ORDER BY m.ts DESC LIMIT ?`, jid, beforeTS, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Message
	for rows.Next() {
		var m Message
		var fromMe int
		if err := rows.Scan(&m.ID, &m.ChatJID, &m.Sender, &m.SenderName, &m.Text, &m.TS, &fromMe,
			&m.MediaType, &m.Filename, &m.QuotedID, &m.QuotedText, &m.raw); err != nil {
			return nil, err
		}
		m.FromMe = fromMe == 1
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	if out == nil {
		out = []Message{}
	}
	return out, nil
}

func (s *Store) GetMessage(jid, id string) (Message, error) {
	var m Message
	var fromMe int
	err := s.db.QueryRow(`
		SELECT id, chat_jid, sender, sender_name, text, ts, from_me, media_type, filename, quoted_id, raw
		FROM messages WHERE chat_jid = ? AND id = ?`, jid, id).
		Scan(&m.ID, &m.ChatJID, &m.Sender, &m.SenderName, &m.Text, &m.TS, &fromMe,
			&m.MediaType, &m.Filename, &m.QuotedID, &m.raw)
	m.FromMe = fromMe == 1
	return m, err
}

// RecentUnreadIDs lists incoming message ids newer than the last outgoing
// one, which is what WhatsApp expects in a read receipt.
func (s *Store) RecentIncoming(jid string, limit int) ([]Message, error) {
	rows, err := s.db.Query(`
		SELECT id, sender FROM messages
		WHERE chat_jid = ? AND from_me = 0
		ORDER BY ts DESC LIMIT ?`, jid, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Message
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.Sender); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// restrictFile makes a database and its WAL/SHM side files owner-only.
// SQLite creates them with the process umask, which is usually 022.
func restrictFile(path string) {
	for _, p := range []string{path, path + "-wal", path + "-shm"} {
		_ = os.Chmod(p, 0o600)
	}
}
