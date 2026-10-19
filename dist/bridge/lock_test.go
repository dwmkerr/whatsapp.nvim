package main

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

func TestLockStoreRejectsSecondBridge(t *testing.T) {
	dir := t.TempDir()
	first, err := lockStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	_, err = lockStore(dir)
	if err == nil || !strings.Contains(err.Error(), "pid "+strconv.Itoa(os.Getpid())) {
		t.Fatalf("second lock should name the holder, got %v", err)
	}
	first.Close()
	again, err := lockStore(dir)
	if err != nil {
		t.Fatalf("lock after release: %v", err)
	}
	again.Close()
}
