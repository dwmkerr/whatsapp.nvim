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

func TestAppStateWaitsForThePhoneUntilASyncCompletes(t *testing.T) {
	w := &WA{log: stderrLogger{module: "test"}}
	low := appstate.WAPatchRegularLow
	mismatch := fmt.Errorf("failed to verify snapshot: %w", appstate.ErrMismatchingLTHash)

	if w.appStateRepaired(low) {
		t.Fatal("a collection that never failed was reported repaired")
	}
	w.appStateStep(&events.AppStateSyncError{Name: low, FullSync: true, Error: mismatch})
	if got := w.appStateWaiting(); len(got) != 1 || got[0] != low {
		t.Fatalf("want regular_low waiting on the phone, got %v", got)
	}
	if !w.appStateRepaired(low) {
		t.Fatal("recovery was not reported")
	}
	if got := w.appStateWaiting(); len(got) != 0 {
		t.Fatalf("still waiting after recovery: %v", got)
	}
	if got := w.appStateStep(&events.AppStateSyncError{Name: low, Error: mismatch}); got != "fetch" {
		t.Fatalf("a later mismatch starts over with a fetch, got %q", got)
	}
}
