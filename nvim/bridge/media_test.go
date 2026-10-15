package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/util/cbcutil"
	"go.mau.fi/whatsmeow/util/hkdfutil"
	"google.golang.org/protobuf/proto"
)

type mediaRoundTrip func(*http.Request) (*http.Response, error)

func (f mediaRoundTrip) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

func TestStreamingDownloadDecryptsAndVerifiesWithWhatsmeow(t *testing.T) {
	// Exercise the real library's streaming, MAC validation and in-place
	// decryption without pairing a device or making any network connection.
	plain := bytes.Repeat([]byte("synthetic media"), 4000)
	key := bytes.Repeat([]byte{1}, 32)
	keys := hkdfutil.SHA256(key, nil, []byte(whatsmeow.MediaImage), 112)
	iv, cipherKey, macKey := keys[:16], keys[16:48], keys[48:80]
	encrypted, err := cbcutil.Encrypt(cipherKey, iv, plain)
	if err != nil {
		t.Fatal(err)
	}
	mac := hmac.New(sha256.New, macKey)
	mac.Write(iv)
	mac.Write(encrypted)
	payload := append(encrypted, mac.Sum(nil)[:10]...)
	plainHash, encryptedHash := sha256.Sum256(plain), sha256.Sum256(payload)
	w, err := NewWA(context.Background(), t.TempDir(), NewWriter(io.Discard))
	if err != nil {
		t.Fatal(err)
	}
	defer w.Disconnect()
	for _, corrupt := range []bool{false, true} {
		dir := t.TempDir()
		path := filepath.Join(dir, "image.jpg")
		body := append([]byte(nil), payload...)
		if corrupt {
			body[0] ^= 1
		}
		w.cli.SetMediaHTTPClient(&http.Client{Transport: mediaRoundTrip(func(req *http.Request) (*http.Response, error) {
			// An inflated header must not trigger disk preallocation.
			return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(body)), ContentLength: 1 << 40, Request: req}, nil
		})})
		err := saveMedia(context.Background(), path, &waE2E.ImageMessage{}, func(ctx context.Context, _ whatsmeow.DownloadableMessage, file whatsmeow.File) error {
			return w.cli.DangerousInternals().DownloadAndDecryptToFile(ctx, "https://media.invalid/fixture", key, whatsmeow.MediaImage, encryptedHash[:], plainHash[:], file)
		})
		if corrupt {
			files, _ := os.ReadDir(dir)
			if err == nil || len(files) != 0 {
				t.Fatalf("corrupt media cached: %v", err)
			}
		} else {
			data, readErr := os.ReadFile(path)
			if err != nil || readErr != nil || !bytes.Equal(data, plain) {
				t.Fatalf("streaming decryption failed: %v %v", err, readErr)
			}
		}
	}
}

func TestMediaFileLimitsAllWritePaths(t *testing.T) {
	f, err := os.CreateTemp(t.TempDir(), "media")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	bounded := &mediaFile{file: f, ctx: context.Background(), limit: 8}
	if _, err := io.Copy(bounded, strings.NewReader("12345678")); err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(bounded, io.LimitReader(strings.NewReader("9"), 1)); !errors.Is(err, errMediaTooLarge) {
		t.Fatalf("io.Copy bypassed size limit: %v", err)
	}
	if _, err := bounded.WriteAt([]byte("xx"), 7); !errors.Is(err, errMediaTooLarge) {
		t.Fatalf("WriteAt bypassed size limit: %v", err)
	}
	if err := bounded.Truncate(9); !errors.Is(err, errMediaTooLarge) {
		t.Fatalf("Truncate bypassed size limit: %v", err)
	}
	if _, err := bounded.Seek(100, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	if _, err := bounded.Write([]byte("x")); !errors.Is(err, errMediaTooLarge) {
		t.Fatalf("seek then write bypassed size limit: %v", err)
	}
	info, _ := f.Stat()
	if info.Size() != 8 {
		t.Fatalf("file grew to %d bytes", info.Size())
	}
}

func TestSaveMediaOnlyCachesCompletedVerifiedDownloads(t *testing.T) {
	for _, mode := range []string{"success", "failed verification", "oversized", "decrypted oversize", "cancelled"} {
		t.Run(mode, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "attachment.bin")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			err := saveMedia(ctx, path, &waE2E.DocumentMessage{}, func(ctx context.Context, _ whatsmeow.DownloadableMessage, f whatsmeow.File) error {
				deadline, ok := ctx.Deadline()
				if !ok || time.Until(deadline) > mediaDownloadTimeout {
					t.Fatal("missing download deadline")
				}
				if _, err := f.Write([]byte("verified payload")); err != nil {
					return err
				}
				switch mode {
				case "failed verification":
					return errors.New("invalid media hash")
				case "oversized":
					return f.Truncate(maxEncryptedMediaBytes + 1)
				case "decrypted oversize":
					return f.Truncate(maxMediaBytes + 1)
				case "cancelled":
					cancel()
					return nil
				}
				return nil
			})
			files, _ := os.ReadDir(dir)
			if mode != "success" {
				if err == nil || len(files) != 0 {
					t.Fatalf("failed download left cache/partial file: %v %v", err, files)
				}
				return
			}
			if err != nil || len(files) != 1 {
				t.Fatalf("successful download failed: %v %v", err, files)
			}
			data, _ := os.ReadFile(path)
			info, _ := os.Stat(path)
			if string(data) != "verified payload" || info.Mode().Perm() != 0o600 {
				t.Fatalf("bad cache contents or permissions")
			}
		})
	}
}

func TestDownloadDeadlineCancelsWorkAndRemovesPartial(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	err := saveMedia(ctx, filepath.Join(dir, "media.bin"), &waE2E.DocumentMessage{}, func(ctx context.Context, _ whatsmeow.DownloadableMessage, f whatsmeow.File) error {
		<-ctx.Done()
		_, err := f.Write([]byte("late data"))
		return err
	})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("deadline not enforced: %v", err)
	}
	files, _ := os.ReadDir(dir)
	if len(files) != 0 {
		t.Fatalf("left partial files: %v", files)
	}
}

func TestDownloadChecksDeclaredSizeAndConcurrencyBeforeNetwork(t *testing.T) {
	w, err := NewWA(context.Background(), t.TempDir(), NewWriter(io.Discard))
	if err != nil {
		t.Fatal(err)
	}
	defer w.Disconnect()
	raw, _ := proto.Marshal(&waE2E.Message{ImageMessage: &waE2E.ImageMessage{
		FileLength: proto.Uint64(maxMediaBytes + 1), Mimetype: proto.String("image/jpeg"),
	}})
	_, err = w.store.InsertMessage(Message{ID: "large", ChatJID: "111@s.whatsapp.net", MediaType: "image", raw: raw})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Download(context.Background(), "111@s.whatsapp.net", "large"); !errors.Is(err, errMediaTooLarge) {
		t.Fatalf("advertised size did not stop download: %v", err)
	}
	w.downloads <- struct{}{}
	w.downloads <- struct{}{}
	if _, err := w.Download(context.Background(), "111@s.whatsapp.net", "large"); err == nil || !strings.Contains(err.Error(), "already in progress") {
		t.Fatalf("concurrency limit not enforced: %v", err)
	}
}

func TestDownloadRevalidatesLegacyFilename(t *testing.T) {
	w, err := NewWA(context.Background(), t.TempDir(), NewWriter(io.Discard))
	if err != nil {
		t.Fatal(err)
	}
	defer w.Disconnect()
	jid := "111@s.whatsapp.net"
	raw, _ := proto.Marshal(&waE2E.Message{ImageMessage: &waE2E.ImageMessage{Mimetype: proto.String("image/xls")}})
	_, err = w.store.InsertMessage(Message{ID: "old", ChatJID: jid, MediaType: "image", Filename: "image.xls", raw: raw})
	if err != nil {
		t.Fatal(err)
	}
	safePath, _ := mediaPath(filepath.Join(w.dir, "media"), jid, "old", "image.bin")
	legacyPath, _ := mediaPath(filepath.Join(w.dir, "media"), jid, "old", "image.xls")
	if err := os.MkdirAll(filepath.Dir(safePath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(safePath, []byte("safe path"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyPath, []byte("legacy path"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := w.Download(context.Background(), jid, "old")
	if err != nil || got != safePath {
		t.Fatalf("legacy extension reused: %s %v", got, err)
	}
}
