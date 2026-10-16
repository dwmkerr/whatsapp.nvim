package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
)

const (
	maxMediaBytes        = 25 * 1024 * 1024
	mediaDownloadTimeout = 60 * time.Second
	// AES padding and the WhatsApp media MAC are present before decryption.
	maxEncryptedMediaBytes = maxMediaBytes + 16 + 10
)

var errMediaTooLarge = errors.New("attachment exceeds the 25 MiB download limit")

type attachment interface {
	whatsmeow.DownloadableMessage
	GetFileLength() uint64
}

func downloadable(m *waE2E.Message) (attachment, error) {
	switch {
	case m.ImageMessage != nil:
		return m.ImageMessage, nil
	case m.VideoMessage != nil:
		return m.VideoMessage, nil
	case m.AudioMessage != nil:
		return m.AudioMessage, nil
	case m.DocumentMessage != nil:
		return m.DocumentMessage, nil
	case m.StickerMessage != nil:
		return m.StickerMessage, nil
	default:
		return nil, errors.New("not a downloadable attachment")
	}
}

// Keep partial or unverified downloads out of the cache. The library verifies
// the media MAC/hash and decrypts in place before this file is renamed.
func saveMedia(ctx context.Context, path string, media attachment,
	download func(context.Context, whatsmeow.DownloadableMessage, whatsmeow.File) error) error {
	ctx, cancel := context.WithTimeout(ctx, mediaDownloadTimeout)
	defer cancel()
	f, err := os.CreateTemp(filepath.Dir(path), ".download-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	bounded := &mediaFile{file: f, ctx: ctx, limit: maxEncryptedMediaBytes}
	if err := download(ctx, media, bounded); err != nil {
		return fmt.Errorf("download: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		return err
	}
	if info.Size() > maxMediaBytes {
		return errMediaTooLarge
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

// Implement the file interface explicitly: embedding *os.File would promote
// ReadFrom and let io.Copy bypass Write's size limit. This also prevents the
// library from preallocating an arbitrary sender-advertised Content-Length.
type mediaFile struct {
	file  *os.File
	ctx   context.Context
	limit int64
}

func (f *mediaFile) check(offset int64, size int64) error {
	if err := f.ctx.Err(); err != nil {
		return err
	}
	if offset < 0 || size < 0 || offset > f.limit || size > f.limit-offset {
		return errMediaTooLarge
	}
	return nil
}

func (f *mediaFile) Write(p []byte) (int, error) {
	offset, err := f.file.Seek(0, io.SeekCurrent)
	if err != nil {
		return 0, err
	}
	if err := f.check(offset, int64(len(p))); err != nil {
		return 0, err
	}
	return f.file.Write(p)
}

func (f *mediaFile) WriteAt(p []byte, offset int64) (int, error) {
	if err := f.check(offset, int64(len(p))); err != nil {
		return 0, err
	}
	return f.file.WriteAt(p, offset)
}

func (f *mediaFile) Read(p []byte) (int, error) {
	if err := f.ctx.Err(); err != nil {
		return 0, err
	}
	return f.file.Read(p)
}

func (f *mediaFile) ReadAt(p []byte, offset int64) (int, error) {
	if err := f.ctx.Err(); err != nil {
		return 0, err
	}
	return f.file.ReadAt(p, offset)
}

func (f *mediaFile) Seek(offset int64, whence int) (int64, error) {
	if err := f.ctx.Err(); err != nil {
		return 0, err
	}
	return f.file.Seek(offset, whence)
}

func (f *mediaFile) Truncate(size int64) error {
	if err := f.check(0, size); err != nil {
		return err
	}
	return f.file.Truncate(size)
}

func (f *mediaFile) Stat() (os.FileInfo, error) { return f.file.Stat() }
