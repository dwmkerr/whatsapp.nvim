package main

import (
	"mime"
	"strings"

	"go.mau.fi/whatsmeow/proto/waE2E"
)

// extracted is the editor-relevant part of a WhatsApp protobuf message.
type extracted struct {
	Text      string
	MediaType string
	Filename  string
	QuotedID  string
	Seconds   int   // media duration
	Waveform  []int // voice note levels, 0-100
	Skip      bool  // protocol noise with nothing to show
}

const unsupportedText = "[unsupported message]"

// extract flattens the many waE2E.Message variants into text plus an
// optional media tag. Unknown types produce a bracketed placeholder so the
// chat never silently drops a message.
func extract(m *waE2E.Message) extracted {
	if m == nil {
		return extracted{Skip: true}
	}
	var e extracted
	switch {
	case m.Conversation != nil:
		e.Text = m.GetConversation()
	case m.ExtendedTextMessage != nil:
		e.Text = m.ExtendedTextMessage.GetText()
	case m.ImageMessage != nil:
		e.MediaType = "image"
		e.Text = m.ImageMessage.GetCaption()
		e.Filename = filenameFor("image", m.ImageMessage.GetMimetype())
	case m.VideoMessage != nil:
		e.MediaType = "video"
		e.Text = m.VideoMessage.GetCaption()
		e.Filename = filenameFor("video", m.VideoMessage.GetMimetype())
		e.Seconds = int(m.VideoMessage.GetSeconds())
	case m.AudioMessage != nil:
		e.MediaType = "audio"
		if m.AudioMessage.GetPTT() {
			e.MediaType = "voice"
		}
		e.Filename = filenameFor("audio", m.AudioMessage.GetMimetype())
		e.Seconds = int(m.AudioMessage.GetSeconds())
		for _, b := range m.AudioMessage.GetWaveform() {
			e.Waveform = append(e.Waveform, int(b))
		}
	case m.DocumentMessage != nil:
		e.MediaType = "document"
		e.Text = m.DocumentMessage.GetCaption()
		e.Filename = m.DocumentMessage.GetFileName()
		if e.Filename == "" {
			e.Filename = filenameFor("document", m.DocumentMessage.GetMimetype())
		}
	case m.StickerMessage != nil:
		e.MediaType = "sticker"
		e.Filename = "sticker.webp"
	case m.ContactMessage != nil:
		e.Text = "[contact] " + m.ContactMessage.GetDisplayName()
	case m.LocationMessage != nil:
		e.Text = "[location] " + m.LocationMessage.GetName()
	case m.PollCreationMessage != nil:
		e.Text = "[poll] " + m.PollCreationMessage.GetName()
	case m.PollCreationMessageV3 != nil:
		e.Text = "[poll] " + m.PollCreationMessageV3.GetName()
	// An album header only announces the photos that follow as ordinary
	// image messages; the phone shows the photos, never the header.
	case m.ReactionMessage != nil, m.ProtocolMessage != nil, m.SenderKeyDistributionMessage != nil,
		m.PollUpdateMessage != nil, m.DeviceSentMessage != nil, m.AlbumMessage != nil:
		e.Skip = true
	default:
		e.Text = unsupportedText
	}
	e.Text = strings.TrimRight(e.Text, "\n")
	e.QuotedID = contextInfo(m).GetStanzaID()
	return e
}

// contextInfo returns the reply context whichever kind of message carries
// it, so a voice note or sticker sent as a reply keeps its quote too.
func contextInfo(m *waE2E.Message) *waE2E.ContextInfo {
	switch {
	case m.ExtendedTextMessage != nil:
		return m.ExtendedTextMessage.GetContextInfo()
	case m.ImageMessage != nil:
		return m.ImageMessage.GetContextInfo()
	case m.VideoMessage != nil:
		return m.VideoMessage.GetContextInfo()
	case m.AudioMessage != nil:
		return m.AudioMessage.GetContextInfo()
	case m.DocumentMessage != nil:
		return m.DocumentMessage.GetContextInfo()
	case m.StickerMessage != nil:
		return m.StickerMessage.GetContextInfo()
	}
	return nil
}

func filenameFor(kind, contentType string) string {
	// MIME labels are sender-controlled. Only known types in the expected
	// family may select an extension; image/xls must never become image.xls.
	types := map[string]string{
		"image/jpeg": "jpg", "image/png": "png", "image/gif": "gif",
		"image/webp": "webp", "image/heic": "heic",
		"video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm",
		"video/x-matroska": "mkv", "video/3gpp": "3gp",
		"audio/mpeg": "mp3", "audio/ogg": "ogg", "audio/opus": "opus",
		"audio/mp4": "m4a", "audio/aac": "aac", "audio/wav": "wav",
		"audio/x-wav": "wav",
	}
	mediaType, _, err := mime.ParseMediaType(contentType)
	ext := types[mediaType]
	if err != nil || ext == "" || !strings.HasPrefix(mediaType, kind+"/") {
		ext = "bin"
	}
	return kind + "." + ext
}
