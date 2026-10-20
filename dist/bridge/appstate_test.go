package main

import (
	"errors"
	"fmt"
	"testing"

	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/types/events"
)

func TestResyncAppStateOnlyOnMismatchAndOnce(t *testing.T) {
	w := &WA{log: stderrLogger{module: "test"}}
	mismatch := fmt.Errorf("failed to decode: %w", appstate.ErrMismatchingLTHash)

	w.resyncAppState(&events.AppStateSyncError{Name: appstate.WAPatchRegularLow, FullSync: true, Error: mismatch})
	if _, ok := w.resynced.Load(appstate.WAPatchRegularLow); ok {
		t.Fatal("a failed full sync must not trigger another full sync")
	}
	w.resyncAppState(&events.AppStateSyncError{Name: appstate.WAPatchRegularLow, Error: errors.New("network")})
	if _, ok := w.resynced.Load(appstate.WAPatchRegularLow); ok {
		t.Fatal("only a hash mismatch warrants a resync")
	}
	w.resyncAppState(&events.AppStateSyncError{Name: appstate.WAPatchRegularLow, Error: mismatch})
	if _, ok := w.resynced.Load(appstate.WAPatchRegularLow); !ok {
		t.Fatal("mismatch should schedule a resync")
	}
	w.resyncAppState(&events.AppStateSyncError{Name: appstate.WAPatchRegularLow, Error: mismatch})
	if _, ok := w.resynced.Load(appstate.WAPatchCriticalBlock); ok {
		t.Fatal("other collections stay untouched")
	}
}
