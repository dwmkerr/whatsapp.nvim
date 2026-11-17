# Development

```bash
make build   # build the Go bridge into dist/bin/wa-bridge
make test    # Go and Lua tests
make dev     # open Neovim with your real account
make demo    # open Neovim with a synthetic account, no phone needed
```

## Synthetic account

`make demo` starts a clean Neovim (no user config) with the plugin from this checkout. The bridge runs with `-fixture`: instead of connecting to WhatsApp it replays a timeline of events from [`dist/test/fixtures/synthetic.json`](../dist/test/fixtures/synthetic.json) through the same handlers that process live traffic. A bug in how the bridge reads history, read state or archive events shows up in the demo the same way it does on a real account.

Use it for screenshots, recordings and reproducing bugs. Everything in it is invented: names, messages, and phone numbers from the UK drama range (`+44 7700 900xxx`). The store is a temporary directory that is deleted on exit; `-store` is ignored.

Point at another file with `make demo FIXTURE=path/to/file.json`, or set `fixture = "path"` in `setup()`.

### Growing the dataset

The dataset is meant to grow. When a bug comes from a real account, add the smallest set of events that reproduces it, with invented people, and say why in the event's `note`. Keep existing chats stable so earlier recordings stay comparable; add new people and chats rather than rewriting old ones.

### Format

```json
{
  "me": { "phone": "447700900000", "name": "Sam" },
  "contacts": [{ "jid": "447700900101@s.whatsapp.net", "name": "Ada Fenwick" }],
  "groups": [{ "jid": "120363400000000001@g.us", "name": "Boulder Wednesdays" }],
  "events": [
    { "type": "history", "progress": 50, "conversations": [
      { "jid": "447700900101@s.whatsapp.net", "unread": 1, "archived": false, "marked_unread": false,
        "messages": [{ "id": "ADA01", "text": "Saturday?", "at": "-26h" }] }
    ] },
    { "type": "message", "chat": "447700900101@s.whatsapp.net", "text": "Café at 10", "at": "-5m", "delay_ms": 400 }
  ]
}
```

Every event takes an optional `note` and `delay_ms`, a pause before the event so recordings show progress. `make demo PACE=4` stretches every pause four times, for screen captures too slow to catch a state that lasts under a second. Message times (`at`) are Go durations from when the replay starts, such as `-26h`, or RFC 3339 timestamps.

| `type` | Fields | Replays as |
| --- | --- | --- |
| `history` | `progress`, `conversations` | `events.HistorySync`, one chunk of the sync after pairing |
| `message` | `chat`, `from`, `id`, `text`, `media`, `caption`, `filename`, `reply_to`, `quoted_text`, `quoted_from`, `push_name`, `at` | `events.Message`, live or replayed from offline |
| `mark_read` | `chat`, `read`, `full_sync`, `at` | `events.MarkChatAsRead`, the phone's mark read or unread |
| `archive` | `chat`, `archived`, `full_sync`, `at` | `events.Archive` |
| `read_receipt` | `chat`, `ids`, `at` | `events.Receipt` of type read from our own phone |
| `offline_preview` | `messages` | `events.OfflineSyncPreview` |
| `offline_done` | `messages` | `events.OfflineSyncCompleted` |

In messages, `from` is `"me"`, a contact's JID, or empty for the other person in a direct chat; group messages need it. `media` is one of `image`, `sticker`, `voice`, `video` or `document`. Media shows as a tag and has nothing to download.

The bridge checks the whole file at startup and refuses unknown fields, event types and media, duplicate message ids and group messages without a sender. `TestSyntheticFixtureReplaysThroughTheBridge` replays the dataset on every `make test`.
