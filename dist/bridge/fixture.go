package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"go.mau.fi/whatsmeow/proto/waAdv"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waSyncAction"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// A fixture is a synthetic account: invented people, chats and a timeline of
// the events the WhatsApp servers would send. Replaying it through
// handleEvent exercises the real bridge code without a phone, so a bug in
// how the bridge reads those events shows up the same way it does live.
type fixture struct {
	Me       fixtureMe       `json:"me"`
	Contacts []fixtureName   `json:"contacts"`
	Groups   []fixtureName   `json:"groups"`
	Events   []fixtureEvent  `json:"events"`
	clock    time.Time       // "at" offsets are relative to this
	ids      map[string]bool // generated and declared message ids, to catch clashes
}

type fixtureMe struct {
	Phone string `json:"phone"`
	Name  string `json:"name"`
}

type fixtureName struct {
	JID  string `json:"jid"`
	Name string `json:"name"`
}

// fixtureEvent is one entry in the timeline. Type picks which fields apply:
//
//	history          progress, conversations
//	message          chat, from, id, text, media, caption, reply_to, quoted_text, quoted_from, push_name, at
//	mark_read        chat, read, full_sync, at
//	archive          chat, archived, full_sync, at
//	read_receipt     chat, ids, at
//	offline_preview  messages
//	offline_done     messages
//	group_info       chat, name, members, joined_only: the server answers group
//	                 info requests for chat from here on; before it, they fail,
//	                 as they can live. members: participant JIDs, "me" for us;
//	                 a group without a subject has members and no name.
//	                 joined_only: only the joined-groups list names it, the
//	                 per-group request keeps failing
type fixtureEvent struct {
	Type    string `json:"type"`
	Note    string `json:"note,omitempty"`     // why the event is in the dataset, e.g. the issue it reproduces
	DelayMS int    `json:"delay_ms,omitempty"` // pause before this event, so recordings show progress

	Progress      int           `json:"progress,omitempty"`
	Conversations []fixtureConv `json:"conversations,omitempty"`

	Chat string `json:"chat,omitempty"`
	fixtureMsg

	Read       *bool    `json:"read,omitempty"`
	Archived   *bool    `json:"archived,omitempty"`
	FullSync   bool     `json:"full_sync,omitempty"`
	IDs        []string `json:"ids,omitempty"`
	Name       string   `json:"name,omitempty"`
	Members    []string `json:"members,omitempty"`
	JoinedOnly bool     `json:"joined_only,omitempty"`
	Messages   int      `json:"messages,omitempty"`
}

type fixtureConv struct {
	JID          string       `json:"jid"`
	Name         string       `json:"name,omitempty"`
	Unread       int          `json:"unread,omitempty"`
	MarkedUnread bool         `json:"marked_unread,omitempty"`
	Archived     bool         `json:"archived,omitempty"`
	Messages     []fixtureMsg `json:"messages"`
}

type fixtureMsg struct {
	ID       string `json:"id,omitempty"`
	From     string `json:"from,omitempty"` // "me", a contact jid, or empty for the other side of a direct chat
	Text     string `json:"text,omitempty"`
	Media    string `json:"media,omitempty"` // image, sticker, voice, video, document
	Caption  string `json:"caption,omitempty"`
	Filename string `json:"filename,omitempty"`
	ReplyTo  string `json:"reply_to,omitempty"`
	// QuotedText and QuotedFrom put a copy of the quoted message in the
	// reply, as the phone does, for replies to messages the store never saw.
	QuotedText string `json:"quoted_text,omitempty"`
	QuotedFrom string `json:"quoted_from,omitempty"`
	PushName   string `json:"push_name,omitempty"`
	At         string `json:"at,omitempty"` // Go duration from the replay start ("-26h"), or RFC 3339
}

func loadFixture(path string, clock time.Time) (*fixture, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var fx fixture
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&fx); err != nil {
		return nil, fmt.Errorf("fixture %s: %w", path, err)
	}
	if fx.Me.Phone == "" {
		return nil, fmt.Errorf("fixture %s: me.phone is required", path)
	}
	fx.clock = clock
	fx.ids = map[string]bool{}
	// Build every event up front so a typo fails at startup, not halfway
	// through a recording.
	for i, e := range fx.Events {
		if _, err := fx.build(e, i); err != nil {
			return nil, fmt.Errorf("fixture %s: event %d (%s): %w", path, i, e.Type, err)
		}
	}
	fx.ids = map[string]bool{}
	return &fx, nil
}

func (fx *fixture) meJID() types.JID {
	return types.NewJID(fx.Me.Phone, types.DefaultUserServer)
}

func (fx *fixture) at(s string) (time.Time, error) {
	if s == "" {
		return fx.clock, nil
	}
	if d, err := time.ParseDuration(s); err == nil {
		return fx.clock.Add(d), nil
	}
	return time.Parse(time.RFC3339, s)
}

func (fx *fixture) id(declared string, n int) string {
	if declared != "" {
		return declared
	}
	return fmt.Sprintf("FX%04d", n)
}

func parseFixtureJID(s string) (types.JID, error) {
	if s == "" {
		return types.EmptyJID, fmt.Errorf("missing jid")
	}
	return types.ParseJID(s)
}

// message turns a fixture message into the protobuf the phone would send.
// Media carries no downloadable payload, only enough for the bubble and tag.
func (fx *fixture) message(m fixtureMsg) *waE2E.Message {
	var ctxInfo *waE2E.ContextInfo
	if m.ReplyTo != "" {
		ctxInfo = &waE2E.ContextInfo{StanzaID: proto.String(m.ReplyTo)}
		if m.QuotedText != "" {
			ctxInfo.QuotedMessage = &waE2E.Message{Conversation: proto.String(m.QuotedText)}
		}
		if m.QuotedFrom != "" {
			ctxInfo.Participant = proto.String(m.QuotedFrom)
		}
	}
	switch m.Media {
	case "image":
		return &waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: strOrNil(m.Caption), Mimetype: proto.String("image/jpeg"), ContextInfo: ctxInfo}}
	case "sticker":
		return &waE2E.Message{StickerMessage: &waE2E.StickerMessage{Mimetype: proto.String("image/webp")}}
	case "voice":
		return &waE2E.Message{AudioMessage: &waE2E.AudioMessage{PTT: proto.Bool(true), Seconds: proto.Uint32(7), Mimetype: proto.String("audio/ogg; codecs=opus")}}
	case "video":
		return &waE2E.Message{VideoMessage: &waE2E.VideoMessage{Caption: strOrNil(m.Caption), Seconds: proto.Uint32(12), Mimetype: proto.String("video/mp4"), ContextInfo: ctxInfo}}
	case "document":
		return &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{FileName: strOrNil(m.Filename), Caption: strOrNil(m.Caption), Mimetype: proto.String("application/pdf"), ContextInfo: ctxInfo}}
	}
	if ctxInfo != nil {
		return &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(m.Text), ContextInfo: ctxInfo}}
	}
	return &waE2E.Message{Conversation: proto.String(m.Text)}
}

func strOrNil(s string) *string {
	if s == "" {
		return nil
	}
	return proto.String(s)
}

func (fx *fixture) checkMsg(chat types.JID, m fixtureMsg, id string) error {
	if fx.ids[chat.String()+"/"+id] {
		return fmt.Errorf("duplicate message id %s in %s", id, chat)
	}
	fx.ids[chat.String()+"/"+id] = true
	switch m.Media {
	case "", "image", "sticker", "voice", "video", "document":
	default:
		return fmt.Errorf("unknown media %q", m.Media)
	}
	if chat.Server == types.GroupServer && m.From == "" {
		return fmt.Errorf("group message %s needs from", id)
	}
	return nil
}

// sender resolves "from" to whether the message is ours and who sent it.
func (fx *fixture) sender(chat types.JID, from string) (types.JID, bool, error) {
	switch from {
	case "me":
		return fx.meJID(), true, nil
	case "":
		return chat, false, nil
	}
	j, err := types.ParseJID(from)
	return j, false, err
}

func (fx *fixture) webMessage(chat types.JID, m fixtureMsg, n int) (*waWeb.WebMessageInfo, error) {
	id := fx.id(m.ID, n)
	if err := fx.checkMsg(chat, m, id); err != nil {
		return nil, err
	}
	ts, err := fx.at(m.At)
	if err != nil {
		return nil, err
	}
	sender, fromMe, err := fx.sender(chat, m.From)
	if err != nil {
		return nil, err
	}
	key := &waCommon.MessageKey{RemoteJID: proto.String(chat.String()), FromMe: proto.Bool(fromMe), ID: proto.String(id)}
	if chat.Server == types.GroupServer && !fromMe {
		key.Participant = proto.String(sender.String())
	}
	return &waWeb.WebMessageInfo{
		Key:              key,
		Message:          fx.message(m),
		MessageTimestamp: proto.Uint64(uint64(ts.Unix())),
		PushName:         strOrNil(m.PushName),
	}, nil
}

// build makes the whatsmeow event for one timeline entry. n numbers
// generated message ids so they stay stable between runs.
func (fx *fixture) build(e fixtureEvent, n int) (interface{}, error) {
	switch e.Type {
	case "history":
		hs := &waHistorySync.HistorySync{
			SyncType: waHistorySync.HistorySync_INITIAL_BOOTSTRAP.Enum(),
			Progress: proto.Uint32(uint32(e.Progress)),
		}
		for ci, c := range e.Conversations {
			chat, err := parseFixtureJID(c.JID)
			if err != nil {
				return nil, err
			}
			conv := &waHistorySync.Conversation{
				ID:             proto.String(chat.String()),
				UnreadCount:    proto.Uint32(uint32(c.Unread)),
				MarkedAsUnread: proto.Bool(c.MarkedUnread),
				Archived:       proto.Bool(c.Archived),
				DisplayName:    strOrNil(c.Name),
			}
			// The phone sends history newest first.
			for mi := len(c.Messages) - 1; mi >= 0; mi-- {
				wm, err := fx.webMessage(chat, c.Messages[mi], n*10000+ci*100+mi)
				if err != nil {
					return nil, err
				}
				conv.Messages = append(conv.Messages, &waHistorySync.HistorySyncMsg{Message: wm})
			}
			hs.Conversations = append(hs.Conversations, conv)
		}
		return &events.HistorySync{Data: hs}, nil
	case "message":
		chat, err := parseFixtureJID(e.Chat)
		if err != nil {
			return nil, err
		}
		id := fx.id(e.ID, n*10000)
		if err := fx.checkMsg(chat, e.fixtureMsg, id); err != nil {
			return nil, err
		}
		ts, err := fx.at(e.At)
		if err != nil {
			return nil, err
		}
		sender, fromMe, err := fx.sender(chat, e.From)
		if err != nil {
			return nil, err
		}
		return &events.Message{
			Info: types.MessageInfo{
				MessageSource: types.MessageSource{Chat: chat, Sender: sender, IsFromMe: fromMe, IsGroup: chat.Server == types.GroupServer},
				ID:            id,
				PushName:      e.PushName,
				Timestamp:     ts,
			},
			Message: fx.message(e.fixtureMsg),
		}, nil
	case "mark_read":
		chat, err := parseFixtureJID(e.Chat)
		if err != nil {
			return nil, err
		}
		if e.Read == nil {
			return nil, fmt.Errorf("mark_read needs read")
		}
		ts, err := fx.at(e.At)
		if err != nil {
			return nil, err
		}
		return &events.MarkChatAsRead{JID: chat, Timestamp: ts, FromFullSync: e.FullSync,
			Action: &waSyncAction.MarkChatAsReadAction{Read: proto.Bool(*e.Read)}}, nil
	case "archive":
		chat, err := parseFixtureJID(e.Chat)
		if err != nil {
			return nil, err
		}
		if e.Archived == nil {
			return nil, fmt.Errorf("archive needs archived")
		}
		ts, err := fx.at(e.At)
		if err != nil {
			return nil, err
		}
		return &events.Archive{JID: chat, Timestamp: ts, FromFullSync: e.FullSync,
			Action: &waSyncAction.ArchiveChatAction{Archived: proto.Bool(*e.Archived)}}, nil
	case "read_receipt":
		chat, err := parseFixtureJID(e.Chat)
		if err != nil {
			return nil, err
		}
		ts, err := fx.at(e.At)
		if err != nil {
			return nil, err
		}
		ids := make([]types.MessageID, len(e.IDs))
		for i, id := range e.IDs {
			ids[i] = types.MessageID(id)
		}
		return &events.Receipt{
			MessageSource: types.MessageSource{Chat: chat, Sender: fx.meJID(), IsFromMe: true, IsGroup: chat.Server == types.GroupServer},
			MessageIDs:    ids,
			Timestamp:     ts,
			Type:          types.ReceiptTypeRead,
		}, nil
	case "offline_preview":
		return &events.OfflineSyncPreview{Messages: e.Messages, Total: e.Messages}, nil
	case "offline_done":
		return &events.OfflineSyncCompleted{Count: e.Messages}, nil
	case "group_info":
		chat, err := parseFixtureJID(e.Chat)
		if err != nil {
			return nil, err
		}
		if chat.Server != types.GroupServer || (e.Name == "" && len(e.Members) == 0) {
			return nil, fmt.Errorf("group_info needs a group chat and a name or members")
		}
		members := make([]types.JID, 0, len(e.Members))
		for _, m := range e.Members {
			if m == "me" {
				members = append(members, fx.meJID())
				continue
			}
			j, err := parseFixtureJID(m)
			if err != nil {
				return nil, fmt.Errorf("member %q: %w", m, err)
			}
			members = append(members, j)
		}
		return &fixtureGroupInfo{JID: chat, Name: e.Name, Members: members, JoinedOnly: e.JoinedOnly}, nil
	}
	return nil, fmt.Errorf("unknown event type %q", e.Type)
}

// useFixture turns this bridge into a replay of fx: the device looks paired
// as fx.Me, contacts and groups have names, and nothing touches the network.
func (w *WA) useFixture(ctx context.Context, fx *fixture) error {
	me := fx.meJID()
	w.cli.Store.ID = &me
	w.cli.Store.PushName = fx.Me.Name
	// Saving the device wires up its contact and LID stores. The store is
	// the throwaway one main made, so these placeholder keys go nowhere.
	if w.cli.Store.Account == nil {
		w.cli.Store.Account = &waAdv.ADVSignedDeviceIdentity{
			Details: []byte{}, AccountSignature: make([]byte, 64), AccountSignatureKey: make([]byte, 32), DeviceSignature: make([]byte, 64),
		}
	}
	if err := w.cli.Store.Save(ctx); err != nil {
		return fmt.Errorf("fixture device: %w", err)
	}
	w.fixture = true
	for _, c := range fx.Contacts {
		j, err := parseFixtureJID(c.JID)
		if err != nil {
			return fmt.Errorf("contact %q: %w", c.JID, err)
		}
		w.names.Store(j.String(), c.Name)
		if err := w.cli.Store.Contacts.PutContactName(ctx, j, c.Name, strings.Fields(c.Name)[0]); err != nil {
			return err
		}
	}
	for _, g := range fx.Groups {
		j, err := parseFixtureJID(g.JID)
		if err != nil {
			return fmt.Errorf("group %q: %w", g.JID, err)
		}
		w.names.Store(j.String(), g.Name)
	}
	return nil
}

// replay sends the timeline through handleEvent in order, as the servers
// would after connecting. A pace of 0 skips the delays, for tests; recordings
// raise it so slow screen captures still catch states that pass in a second.
// fixtureGroupInfo is not a whatsmeow event: replay keeps it as the answer
// groupName gives from then on.
type fixtureGroupInfo struct {
	JID        types.JID
	Name       string
	Members    []types.JID
	JoinedOnly bool
}

func (w *WA) replay(fx *fixture, pace float64) {
	w.handleEvent(&events.Connected{})
	for i, e := range fx.Events {
		if pace > 0 && e.DelayMS > 0 {
			time.Sleep(time.Duration(float64(e.DelayMS)*pace) * time.Millisecond)
		}
		evt, err := fx.build(e, i)
		if err != nil {
			w.log.Errorf("fixture event %d: %v", i, err)
			continue
		}
		if gi, ok := evt.(*fixtureGroupInfo); ok {
			w.joinedNames.Store(gi.JID.String(), gi.Name)
			if !gi.JoinedOnly {
				w.groupNames.Store(gi.JID.String(), gi.Name)
			}
			continue
		}
		w.handleEvent(evt)
	}
}
