package main

import (
	"testing"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

func TestExtractConversation(t *testing.T) {
	e := extract(&waE2E.Message{Conversation: proto.String("hi\n")})
	if e.Text != "hi" || e.MediaType != "" || e.Skip {
		t.Fatalf("got %+v", e)
	}
}

func TestExtractReplyCarriesQuotedID(t *testing.T) {
	e := extract(&waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
		Text:        proto.String("yes"),
		ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String("ABC")},
	}})
	if e.Text != "yes" || e.QuotedID != "ABC" {
		t.Fatalf("got %+v", e)
	}
}

func TestExtractImage(t *testing.T) {
	e := extract(&waE2E.Message{ImageMessage: &waE2E.ImageMessage{
		Caption:  proto.String("look"),
		Mimetype: proto.String("image/jpeg"),
	}})
	if e.MediaType != "image" || e.Filename != "image.jpg" || e.Text != "look" {
		t.Fatalf("got %+v", e)
	}
}

func TestExtractVoiceNote(t *testing.T) {
	e := extract(&waE2E.Message{AudioMessage: &waE2E.AudioMessage{PTT: proto.Bool(true), Mimetype: proto.String("audio/ogg; codecs=opus")}})
	if e.MediaType != "voice" || e.Filename != "audio.ogg" {
		t.Fatalf("got %+v", e)
	}
}

func TestExtractSkipsProtocolNoise(t *testing.T) {
	if !extract(&waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{}}).Skip {
		t.Fatal("protocol message should be skipped")
	}
	if !extract(nil).Skip {
		t.Fatal("nil should be skipped")
	}
}

func TestMediaMIMECannotChooseAnotherFileType(t *testing.T) {
	for _, tc := range []struct{ kind, mime, want string }{
		{"image", "image/xls", "image.bin"},
		{"image", "application/pdf", "image.bin"},
		{"image", "image/../../evil.doc", "image.bin"},
		{"video", "image/jpeg", "video.bin"},
		{"audio", "audio/command", "audio.bin"},
		{"image", "IMAGE/JPEG", "image.jpg"},
		{"image", "image/jpeg; broken", "image.bin"},
		{"audio", "audio/ogg; codecs=opus", "audio.ogg"},
		{"video", "video/mp4", "video.mp4"},
	} {
		t.Run(tc.kind+"_"+tc.mime, func(t *testing.T) {
			if got := filenameFor(tc.kind, tc.mime); got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}
