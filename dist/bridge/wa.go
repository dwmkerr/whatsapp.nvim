package main

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/mdp/qrterminal/v3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

// WA owns the whatsmeow client and translates its events into editor events.
type WA struct {
	cli       *whatsmeow.Client
	store     *Store
	out       *Writer
	dir       string
	log       waLog.Logger
	pairing   sync.Mutex
	names     sync.Map // jid string -> display name, avoids repeated contact lookups
	syncDone  bool
	downloads chan struct{}
}

func NewWA(ctx context.Context, dir string, out *Writer) (*WA, error) {
	// The store holds the device keys and full message history; keep it
	// private even if a plugin manager or shell created the directory first.
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	log := stderrLogger{module: "wa"}
	container, err := sqlstore.New(ctx, "sqlite3", "file:"+filepath.Join(dir, "session.db")+"?_foreign_keys=on", log.Sub("db"))
	if err != nil {
		return nil, fmt.Errorf("open session store: %w", err)
	}
	restrictFile(filepath.Join(dir, "session.db"))
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			return nil, fmt.Errorf("get device: %w", err)
		}
		device = container.NewDevice()
	}
	st, err := OpenStore(filepath.Join(dir, "messages.db"))
	if err != nil {
		return nil, fmt.Errorf("open message store: %w", err)
	}
	w := &WA{cli: whatsmeow.NewClient(device, log.Sub("client")), store: st, out: out, dir: dir, log: log,
		downloads: make(chan struct{}, 2)}
	w.cli.AddEventHandler(w.handleEvent)
	return w, nil
}

func (w *WA) Paired() bool { return w.cli.Store.ID != nil }

func (w *WA) Status() map[string]interface{} {
	return map[string]interface{}{
		"paired":    w.Paired(),
		"connected": w.cli.IsConnected(),
		"logged_in": w.cli.IsLoggedIn(),
		"synced":    w.syncDone,
		"store":     w.dir,
	}
}

// Connect attaches an already-paired session. Unpaired sessions wait for
// pair.start so the editor controls when the QR code appears.
func (w *WA) Connect(ctx context.Context) error {
	if !w.Paired() {
		w.out.Emit("unpaired", nil)
		return nil
	}
	return w.cli.ConnectContext(ctx)
}

// Pair runs the QR flow in the background, emitting pair.qr with the code
// rendered as terminal half-blocks so the editor can show it in a float.
func (w *WA) Pair(ctx context.Context) error {
	if w.Paired() {
		return errors.New("already paired")
	}
	if !w.pairing.TryLock() {
		return errors.New("pairing already in progress")
	}
	qrChan, err := w.cli.GetQRChannel(ctx)
	if err != nil {
		w.pairing.Unlock()
		return fmt.Errorf("qr channel: %w", err)
	}
	if err := w.cli.ConnectContext(ctx); err != nil {
		w.pairing.Unlock()
		return fmt.Errorf("connect: %w", err)
	}
	go func() {
		defer w.pairing.Unlock()
		for item := range qrChan {
			switch item.Event {
			case "code":
				var buf bytes.Buffer
				qrterminal.GenerateHalfBlock(item.Code, qrterminal.L, &buf)
				w.out.Emit("pair.qr", map[string]interface{}{
					"lines": strings.Split(strings.TrimRight(buf.String(), "\n"), "\n"),
					"code":  item.Code,
				})
			case "success":
				w.out.Emit("pair.ok", nil)
				return
			case "timeout":
				w.out.Emit("pair.timeout", nil)
				return
			default:
				if item.Error != nil {
					w.out.Emit("pair.error", map[string]string{"error": item.Error.Error()})
					return
				}
			}
		}
	}()
	return nil
}

func (w *WA) Disconnect() {
	w.cli.Disconnect()
	_ = w.store.Close()
}

// Logout unlinks this device on the phone and wipes the local session and
// cached messages. If the server request fails (offline, or the phone
// already removed us) the local wipe still happens so the next pair.start
// gets a fresh QR code.
func (w *WA) Logout(ctx context.Context) error {
	if !w.Paired() {
		return errors.New("not paired")
	}
	remoteErr := w.cli.Logout(ctx)
	if remoteErr != nil {
		w.cli.Disconnect()
		if err := w.cli.Store.Delete(ctx); err != nil {
			return fmt.Errorf("logout: %v; delete session: %w", remoteErr, err)
		}
	}
	if err := w.store.Reset(); err != nil {
		return fmt.Errorf("clear messages: %w", err)
	}
	w.syncDone = false
	w.out.Emit("logged_out", map[string]string{"reason": "user"})
	if remoteErr != nil {
		return fmt.Errorf("session cleared locally, but the phone was not told: %w", remoteErr)
	}
	return nil
}

func (w *WA) handleEvent(evt interface{}) {
	switch v := evt.(type) {
	case *events.Connected:
		w.out.Emit("connected", nil)
	case *events.Disconnected:
		w.out.Emit("disconnected", nil)
	case *events.LoggedOut:
		w.out.Emit("logged_out", map[string]string{"reason": v.Reason.String()})
	case *events.Message:
		w.handleMessage(v, true)
	case *events.HistorySync:
		w.handleHistorySync(v)
	case *events.OfflineSyncCompleted:
		w.syncDone = true
		w.out.Emit("sync.done", map[string]int{"count": v.Count})
		w.RefreshNames(context.Background())
	case *events.AppStateSyncComplete:
		// Contact names arrive here, usually after history has already been
		// stored under bare phone numbers.
		w.RefreshNames(context.Background())
	case *events.MarkChatAsRead:
		// Toggled from the phone or another linked device.
		jid := v.JID.ToNonAD().String()
		if v.Action.GetRead() {
			_ = w.store.ClearUnread(jid)
		} else {
			_ = w.store.SetUnread(jid, 1)
		}
		w.out.Emit("chats.changed", nil)
	case *events.Contact:
		jid := v.JID.ToNonAD().String()
		name := v.Action.GetFullName()
		if name == "" {
			name = v.Action.GetFirstName()
		}
		if name != "" {
			w.names.Store(jid, name)
			_ = w.store.RenameChat(jid, name)
			w.out.Emit("chats.changed", nil)
		}
	case *events.PushName:
		jid := v.JID.ToNonAD().String()
		if _, known := w.names.Load(jid); !known && v.NewPushName != "" {
			w.names.Store(jid, v.NewPushName)
			if w.store.ChatName(jid) == v.JID.User {
				_ = w.store.RenameChat(jid, v.NewPushName)
				w.out.Emit("chats.changed", nil)
			}
		}
	}
}

// RefreshNames replaces bare phone numbers with contact or group names now
// that the contact store has caught up. Returns how many chats changed.
func (w *WA) RefreshNames(ctx context.Context) int {
	chats, err := w.store.UnnamedChats()
	if err != nil {
		return 0
	}
	changed := 0
	for _, c := range chats {
		jid, err := types.ParseJID(c.JID)
		if err != nil {
			continue
		}
		var name string
		if c.IsGroup {
			if gi, err := w.cli.GetGroupInfo(ctx, jid); err == nil {
				name = gi.Name
			}
		} else {
			name = w.contactName(ctx, jid)
		}
		if name != "" && name != jid.User {
			w.names.Store(c.JID, name)
			if w.store.RenameChat(c.JID, name) == nil {
				changed++
			}
		}
	}
	if changed > 0 {
		w.out.Emit("chats.changed", nil)
	}
	return changed
}

func (w *WA) contactName(ctx context.Context, jid types.JID) string {
	c, err := w.cli.Store.Contacts.GetContact(ctx, jid)
	if err != nil {
		return ""
	}
	switch {
	case c.FullName != "":
		return c.FullName
	case c.PushName != "":
		return c.PushName
	case c.BusinessName != "":
		return c.BusinessName
	}
	return ""
}

// handleMessage stores a message and, for live traffic, emits it. History
// replay goes through the same path with live=false so names and dedup
// behave identically.
func (w *WA) handleMessage(evt *events.Message, live bool) {
	e := extract(evt.Message)
	if e.Skip {
		return
	}
	// Status posts and other broadcasts are not conversations.
	if evt.Info.Chat.Server == types.BroadcastServer {
		return
	}
	ctx := context.Background()
	chat := w.canonical(ctx, evt.Info.Chat, evt.Info.RecipientAlt)
	sender := w.canonical(ctx, evt.Info.Sender, evt.Info.SenderAlt)
	if evt.Info.IsFromMe {
		sender = w.cli.Store.ID.ToNonAD()
	}
	raw, _ := proto.Marshal(evt.Message)
	m := Message{
		ID:         evt.Info.ID,
		ChatJID:    chat.String(),
		Sender:     sender.String(),
		SenderName: w.senderName(ctx, sender, evt.Info.PushName, evt.Info.IsFromMe),
		Text:       e.Text,
		TS:         evt.Info.Timestamp.Unix(),
		FromMe:     evt.Info.IsFromMe,
		MediaType:  e.MediaType,
		Filename:   e.Filename,
		QuotedID:   e.QuotedID,
		raw:        raw,
	}
	name := w.chatName(ctx, chat, evt.Info.PushName, evt.Info.IsGroup)
	if err := w.store.UpsertChat(chat.String(), name, evt.Info.IsGroup, m.TS); err != nil {
		w.log.Warnf("upsert chat: %v", err)
	}
	fresh, err := w.store.InsertMessage(m)
	if err != nil {
		w.log.Warnf("insert message: %v", err)
		return
	}
	if !fresh || !live {
		return
	}
	if !m.FromMe {
		_ = w.store.IncrementUnread(chat.String())
	}
	if m.QuotedID != "" {
		if q, err := w.store.GetMessage(chat.String(), m.QuotedID); err == nil {
			m.QuotedText = q.Text
		}
	}
	w.out.Emit("message", map[string]interface{}{"chat_name": name, "message": m})
}

func (w *WA) handleHistorySync(evt *events.HistorySync) {
	count := 0
	for _, conv := range evt.Data.GetConversations() {
		jid, err := types.ParseJID(conv.GetID())
		if err != nil {
			continue
		}
		if n := conv.GetDisplayName(); n != "" {
			w.names.Store(jid.String(), n)
		} else if n := conv.GetName(); n != "" {
			w.names.Store(jid.String(), n)
		}
		for _, hm := range conv.GetMessages() {
			parsed, err := w.cli.ParseWebMessage(jid, hm.GetMessage())
			if err != nil {
				continue
			}
			w.handleMessage(parsed, false)
			count++
		}
	}
	w.out.Emit("sync.progress", map[string]int{"messages": count})
	w.out.Emit("chats.changed", nil)
}

// canonical prefers the phone-number form of a JID so one contact never
// splits into a @lid chat and a @s.whatsapp.net chat.
func (w *WA) canonical(ctx context.Context, jid, alt types.JID) types.JID {
	jid = jid.ToNonAD()
	if jid.Server != types.HiddenUserServer {
		return jid
	}
	if !alt.IsEmpty() && alt.Server == types.DefaultUserServer {
		return alt.ToNonAD()
	}
	if pn, err := w.cli.Store.LIDs.GetPNForLID(ctx, jid); err == nil && !pn.IsEmpty() {
		return pn.ToNonAD()
	}
	return jid
}

func (w *WA) chatName(ctx context.Context, jid types.JID, pushName string, isGroup bool) string {
	if n := w.store.ChatName(jid.String()); n != "" {
		return n
	}
	if n, ok := w.names.Load(jid.String()); ok {
		return n.(string)
	}
	if isGroup {
		if gi, err := w.cli.GetGroupInfo(ctx, jid); err == nil && gi.Name != "" {
			w.names.Store(jid.String(), gi.Name)
			return gi.Name
		}
		return "Group " + jid.User
	}
	return w.senderName(ctx, jid, pushName, false)
}

func (w *WA) senderName(ctx context.Context, jid types.JID, pushName string, fromMe bool) string {
	if fromMe {
		return "me"
	}
	if n, ok := w.names.Load(jid.String()); ok {
		return n.(string)
	}
	if n := w.contactName(ctx, jid); n != "" {
		w.names.Store(jid.String(), n)
		return n
	}
	if pushName != "" {
		return pushName
	}
	return jid.User
}

func (w *WA) SendText(ctx context.Context, chatJID, text, replyTo string) (Message, error) {
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return Message{}, fmt.Errorf("bad jid: %w", err)
	}
	if !w.cli.IsConnected() {
		return Message{}, errors.New("not connected")
	}
	msg := &waE2E.Message{}
	if replyTo == "" {
		msg.Conversation = proto.String(text)
	} else {
		ctxInfo := &waE2E.ContextInfo{StanzaID: proto.String(replyTo)}
		if q, err := w.store.GetMessage(chatJID, replyTo); err == nil {
			ctxInfo.Participant = proto.String(q.Sender)
			if q.raw != nil {
				var qm waE2E.Message
				if proto.Unmarshal(q.raw, &qm) == nil {
					ctxInfo.QuotedMessage = &qm
				}
			}
		}
		msg.ExtendedTextMessage = &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: ctxInfo}
	}
	resp, err := w.cli.SendMessage(ctx, chat, msg)
	if err != nil {
		return Message{}, err
	}
	// whatsmeow does not echo our own sends as events, so persist here.
	raw, _ := proto.Marshal(msg)
	m := Message{
		ID: resp.ID, ChatJID: chatJID, Sender: w.cli.Store.ID.ToNonAD().String(), SenderName: "me",
		Text: text, TS: resp.Timestamp.Unix(), FromMe: true, QuotedID: replyTo, raw: raw,
	}
	_ = w.store.UpsertChat(chatJID, "", chat.Server == types.GroupServer, m.TS)
	_, _ = w.store.InsertMessage(m)
	return m, nil
}

func (w *WA) React(ctx context.Context, chatJID, msgID, emoji string) error {
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return err
	}
	target, err := w.store.GetMessage(chatJID, msgID)
	if err != nil {
		return fmt.Errorf("unknown message %s", msgID)
	}
	sender, _ := types.ParseJID(target.Sender)
	_, err = w.cli.SendMessage(ctx, chat, w.cli.BuildReaction(chat, sender, types.MessageID(msgID), emoji))
	return err
}

// MarkRead clears the local counter and sends read receipts for recent
// incoming messages so the phone stops showing them as unread too.
func (w *WA) MarkRead(ctx context.Context, chatJID string) error {
	if err := w.store.ClearUnread(chatJID); err != nil {
		return err
	}
	chat, err := types.ParseJID(chatJID)
	if err != nil || !w.cli.IsConnected() {
		return nil
	}
	recent, err := w.store.RecentIncoming(chatJID, 20)
	if err != nil || len(recent) == 0 {
		return nil
	}
	bySender := map[string][]types.MessageID{}
	for _, m := range recent {
		bySender[m.Sender] = append(bySender[m.Sender], types.MessageID(m.ID))
	}
	for s, ids := range bySender {
		sender := types.EmptyJID
		if chat.Server == types.GroupServer {
			sender, _ = types.ParseJID(s)
		}
		if err := w.cli.MarkRead(ctx, ids, time.Now(), chat, sender); err != nil {
			w.log.Warnf("mark read: %v", err)
		}
	}
	// Receipts do not clear a chat the phone flagged as unread; the app
	// state patch does.
	w.sendReadState(ctx, chatJID, true)
	return nil
}

// MarkUnread flags a chat unread locally and on the phone, the same as
// "Mark as unread" in the app.
func (w *WA) MarkUnread(ctx context.Context, chatJID string) error {
	if err := w.store.SetUnread(chatJID, 1); err != nil {
		return err
	}
	w.sendReadState(ctx, chatJID, false)
	return nil
}

func (w *WA) sendReadState(ctx context.Context, chatJID string, read bool) {
	chat, err := types.ParseJID(chatJID)
	if err != nil || !w.cli.IsConnected() {
		return
	}
	last, err := w.store.ListMessages(chatJID, 1, 0)
	if err != nil || len(last) == 0 {
		return
	}
	m := last[0]
	key := &waCommon.MessageKey{
		RemoteJID: proto.String(chatJID),
		FromMe:    proto.Bool(m.FromMe),
		ID:        proto.String(m.ID),
	}
	patch := appstate.BuildMarkChatAsRead(chat, read, time.Unix(m.TS, 0), key)
	if err := w.cli.SendAppState(ctx, patch); err != nil {
		w.log.Warnf("mark chat read=%v: %v", read, err)
	}
}

// Download fetches media into <store>/media/<chat>/<id>-<filename> and
// returns the path. Cached files are returned without a network call.
func (w *WA) Download(ctx context.Context, chatJID, msgID string) (string, error) {
	select {
	case w.downloads <- struct{}{}:
		defer func() { <-w.downloads }()
	default:
		return "", errors.New("two downloads already in progress; try again when one finishes")
	}
	m, err := w.store.GetMessage(chatJID, msgID)
	if err != nil {
		return "", fmt.Errorf("unknown message %s", msgID)
	}
	if m.MediaType == "" || m.raw == nil {
		return "", errors.New("not a media message")
	}
	var pm waE2E.Message
	if err := proto.Unmarshal(m.raw, &pm); err != nil {
		return "", err
	}
	media, err := downloadable(&pm)
	if err != nil {
		return "", err
	}
	if media.GetFileLength() > maxMediaBytes {
		return "", errMediaTooLarge
	}
	// Recompute the filename so messages cached before MIME validation was
	// introduced cannot retain a misleading extension.
	path, err := mediaPath(filepath.Join(w.dir, "media"), chatJID, msgID, extract(&pm).Filename)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	if info, err := os.Lstat(path); err == nil {
		if !info.Mode().IsRegular() {
			return "", errors.New("cached media is not a regular file")
		}
		if info.Size() > maxMediaBytes {
			return "", errMediaTooLarge
		}
		return path, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if err := saveMedia(ctx, path, media, w.cli.DownloadToFile); err != nil {
		return "", err
	}
	return path, nil
}

func (w *WA) SearchContacts(ctx context.Context, q string) ([]map[string]string, error) {
	all, err := w.cli.Store.Contacts.GetAllContacts(ctx)
	if err != nil {
		return nil, err
	}
	q = strings.ToLower(q)
	out := []map[string]string{}
	for jid, c := range all {
		name := c.FullName
		if name == "" {
			name = c.PushName
		}
		if q != "" && !strings.Contains(strings.ToLower(name), q) && !strings.Contains(jid.User, q) {
			continue
		}
		out = append(out, map[string]string{"jid": jid.ToNonAD().String(), "name": name, "phone": jid.User})
	}
	return out, nil
}

// stderrLogger keeps whatsmeow chatter off stdout, which carries the protocol.
type stderrLogger struct{ module string }

func (l stderrLogger) logf(level, msg string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "%s [%s] %s\n", level, l.module, fmt.Sprintf(msg, args...))
}
func (l stderrLogger) Warnf(msg string, args ...interface{})  { l.logf("WARN", msg, args...) }
func (l stderrLogger) Errorf(msg string, args ...interface{}) { l.logf("ERROR", msg, args...) }
func (l stderrLogger) Infof(msg string, args ...interface{})  { l.logf("INFO", msg, args...) }
func (l stderrLogger) Debugf(msg string, args ...interface{}) {}
func (l stderrLogger) Sub(module string) waLog.Logger {
	return stderrLogger{module: l.module + "/" + module}
}

var (
	unsafePathChars = regexp.MustCompile(`[^A-Za-z0-9._-]+|\.{2,}`)
	// Recognised document/media extensions, not a guarantee of safe content.
	// Unknown types are stored as .bin. Every open requires confirmation.
	openableExt = map[string]bool{
		"jpg": true, "jpeg": true, "png": true, "gif": true, "webp": true, "heic": true,
		"mp4": true, "mov": true, "webm": true, "mkv": true, "3gp": true,
		"mp3": true, "ogg": true, "opus": true, "m4a": true, "aac": true, "wav": true,
		"pdf": true, "txt": true, "md": true, "csv": true, "json": true,
		"doc": true, "docx": true, "xls": true, "xlsx": true, "ppt": true, "pptx": true,
		"odt": true, "ods": true, "odp": true, "zip": true, "vcf": true, "ics": true,
	}
)

// mediaPath builds <root>/<chat>/<id>-<name> from remote-controlled parts.
// The chat JID, message ID and filename all come from the sender, so each is
// reduced to a safe character set and the result must stay under root.
func mediaPath(root, chatJID, msgID, filename string) (string, error) {
	chat := unsafePathChars.ReplaceAllString(chatJID, "_")
	id := unsafePathChars.ReplaceAllString(msgID, "_")
	base := filepath.Base(filename)
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(base), "."))
	stem := strings.TrimSuffix(base, filepath.Ext(base))
	stem = strings.Trim(unsafePathChars.ReplaceAllString(stem, "_"), "._")
	if stem == "" {
		stem = "file"
	}
	if !openableExt[ext] {
		ext = "bin"
	}
	if len(stem) > 80 {
		stem = stem[:80]
	}
	if chat == "" || id == "" || strings.Trim(chat, ".") == "" || strings.Trim(id, ".") == "" {
		return "", errors.New("invalid media reference")
	}
	path := filepath.Join(root, chat, id+"-"+stem+"."+ext)
	if !strings.HasPrefix(filepath.Clean(path), filepath.Clean(root)+string(os.PathSeparator)) {
		return "", errors.New("invalid media path")
	}
	return path, nil
}
