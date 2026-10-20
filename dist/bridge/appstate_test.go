package main

import (
	"errors"
	"fmt"
	"testing"

	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/types/events"
)

func TestAppStateStepEscalatesOnceAndOnlyOnMismatch(t *testing.T) {
	w := &WA{log: stderrLogger{module: "test"}}
	low := appstate.WAPatchRegularLow
	mismatch := fmt.Errorf("failed to decode: %w", appstate.ErrMismatchingLTHash)
	step := func(name appstate.WAPatchName, full bool, err error) string {
		return w.appStateStep(&events.AppStateSyncError{Name: name, FullSync: full, Error: err})
	}

	if got := step(low, false, errors.New("network")); got != "" {
		t.Fatalf("other errors are whatsmeow's business, got %q", got)
	}
	if got := step(low, false, mismatch); got != "fetch" {
		t.Fatalf("first mismatch pulls a snapshot, got %q", got)
	}
	if got := step(low, true, mismatch); got != "recover" {
		t.Fatalf("a snapshot that does not verify asks the phone, got %q", got)
	}
	if got := step(low, false, mismatch); got != "" {
		t.Fatalf("no third step, got %q", got)
	}
	if got := step(appstate.WAPatchRegular, true, mismatch); got != "recover" {
		t.Fatalf("a failed full sync on a fresh collection goes straight to the phone, got %q", got)
	}
	if got := step(appstate.WAPatchRegularHigh, false, mismatch); got != "fetch" {
		t.Fatalf("collections are tracked separately, got %q", got)
	}
}
