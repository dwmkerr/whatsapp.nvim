package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// lockStore holds an exclusive lock on the store for the life of the process.
// A WhatsApp session accepts one socket: the server lets a second bridge in
// and silently drops the first, which leaves that editor with a frozen chat
// list and no error. The kernel releases the lock when the process dies, so
// a crash never leaves a stale lock behind.
func lockStore(dir string) (*os.File, error) {
	f, err := os.OpenFile(filepath.Join(dir, "bridge.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		pid, _ := os.ReadFile(f.Name())
		f.Close()
		holder := strings.TrimSpace(string(pid))
		if holder == "" {
			holder = "another process"
		} else {
			holder = "pid " + holder
		}
		return nil, fmt.Errorf("WhatsApp client already connected on %s", holder)
	}
	_ = f.Truncate(0)
	_, _ = f.WriteAt([]byte(strconv.Itoa(os.Getpid())), 0)
	return f, nil
}
