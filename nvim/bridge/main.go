// wa-bridge speaks newline-delimited JSON on stdin/stdout. The Neovim plugin
// spawns it as a child process; whatsmeow logs go to stderr.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
)

var version = "dev"

func main() {
	defaultDir, _ := os.UserHomeDir()
	defaultDir = filepath.Join(defaultDir, ".local", "share", "nvim", "whatsapp")
	dir := flag.String("store", defaultDir, "directory for session and message databases")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	// Everything this process creates holds private data (keys, messages, media).
	syscall.Umask(0o077)
	if *showVersion {
		fmt.Println("wa-bridge", version)
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	out := NewWriter(os.Stdout)
	wa, err := NewWA(ctx, *dir, out)
	if err != nil {
		out.Emit("fatal", map[string]string{"error": err.Error()})
		os.Exit(1)
	}
	defer wa.Disconnect()

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		cancel()
		wa.Disconnect()
		os.Exit(0)
	}()

	out.Emit("ready", wa.Status())
	if err := wa.Connect(ctx); err != nil {
		out.Emit("error", map[string]string{"error": err.Error()})
	}

	// Each request runs on its own goroutine so a slow send or download
	// never blocks the next list call. The store is a single SQLite handle
	// and serialises writes itself.
	var inflight sync.WaitGroup
	_ = ReadRequests(os.Stdin, func(req Request) {
		inflight.Add(1)
		go func() {
			defer inflight.Done()
			result, err := dispatch(ctx, wa, req)
			if err != nil {
				out.Fail(req.ID, err)
				return
			}
			out.Respond(req.ID, result)
		}()
	})
	// stdin closed: the editor is gone, but answer what it already asked.
	inflight.Wait()
}

func dispatch(ctx context.Context, wa *WA, req Request) (interface{}, error) {
	switch req.Method {
	case "status":
		return wa.Status(), nil
	case "pair.start":
		return nil, wa.Pair(ctx)
	case "chats.list":
		return wa.store.ListChats()
	case "messages.list":
		var p struct {
			JID    string `json:"jid"`
			Limit  int    `json:"limit"`
			Before int64  `json:"before"`
		}
		if err := params(req, &p); err != nil {
			return nil, err
		}
		return wa.store.ListMessages(p.JID, p.Limit, p.Before)
	case "message.send":
		var p struct {
			JID     string `json:"jid"`
			Text    string `json:"text"`
			ReplyTo string `json:"reply_to"`
		}
		if err := params(req, &p); err != nil {
			return nil, err
		}
		if p.Text == "" {
			return nil, errors.New("empty message")
		}
		return wa.SendText(ctx, p.JID, p.Text, p.ReplyTo)
	case "message.react":
		var p struct {
			JID   string `json:"jid"`
			ID    string `json:"id"`
			Emoji string `json:"emoji"`
		}
		if err := params(req, &p); err != nil {
			return nil, err
		}
		return nil, wa.React(ctx, p.JID, p.ID, p.Emoji)
	case "chat.read":
		var p struct {
			JID string `json:"jid"`
		}
		if err := params(req, &p); err != nil {
			return nil, err
		}
		return nil, wa.MarkRead(ctx, p.JID)
	case "chat.unread":
		var p struct {
			JID string `json:"jid"`
		}
		if err := params(req, &p); err != nil {
			return nil, err
		}
		return nil, wa.MarkUnread(ctx, p.JID)
	case "media.download":
		var p struct {
			JID string `json:"jid"`
			ID  string `json:"id"`
		}
		if err := params(req, &p); err != nil {
			return nil, err
		}
		path, err := wa.Download(ctx, p.JID, p.ID)
		if err != nil {
			return nil, err
		}
		return map[string]string{"path": path}, nil
	case "names.refresh":
		return map[string]int{"renamed": wa.RefreshNames(ctx)}, nil
	case "contacts.search":
		var p struct {
			Query string `json:"query"`
		}
		if err := params(req, &p); err != nil {
			return nil, err
		}
		return wa.SearchContacts(ctx, p.Query)
	default:
		return nil, fmt.Errorf("unknown method %q", req.Method)
	}
}

func params(req Request, v interface{}) error {
	if len(req.Params) == 0 {
		return errors.New("missing params")
	}
	return json.Unmarshal(req.Params, v)
}
