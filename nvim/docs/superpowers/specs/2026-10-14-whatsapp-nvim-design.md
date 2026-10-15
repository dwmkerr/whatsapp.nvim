# whatsapp.nvim design

Date: 2026-10-14

## Goal

WhatsApp inside Neovim with the layout of a mail client: chat list on the left, conversation on the right, compose buffer at the bottom. Saving the compose buffer sends. Vim movement and search work unchanged because every pane is an ordinary buffer.

## Non-goals

- Replacing the phone app. No calls, status, communities, newsletters.
- Running when Neovim is closed. History syncs only while the bridge runs.
- Sharing a session with other clients. The plugin is its own linked device.

## Architecture

Two parts, one repo.

**Bridge** (`bridge/`, Go). Wraps whatsmeow. Spawned by Neovim as a child process, speaks newline-delimited JSON on stdin and stdout, logs to stderr. Owns two SQLite files under the store directory: `session.db` (whatsmeow's device store) and `messages.db` (chats, messages, raw protobuf for media). Dies with the editor.

**Plugin** (`lua/whatsapp/`). Owns all UI. `client.lua` spawns the bridge and multiplexes requests by id and events by name. `state.lua` holds chats, cached messages, and window handles. `format.lua` is pure and turns rows into lines plus highlight spans. `ui/list.lua`, `ui/chat.lua`, `ui/compose.lua`, `ui/pair.lua` each own one buffer. `init.lua` wires events to UI and exposes commands.

Why stdio and not HTTP: no ports, no auth, no daemon management, the same shape as a language server. Why a child process and not a daemon: simplest lifecycle for v1. A unix-socket `serve` mode can be added later without changing the Lua side.

## Protocol

Request: `{"id": n, "method": "...", "params": {...}}`. Response: `{"id": n, "result": ...}` or `{"id": n, "error": "..."}`. Event: `{"event": "...", "data": ...}`.

The bridge answers each request on its own goroutine so a slow send never blocks a list call. Writes to stdout go through one mutex so lines never interleave.

## Data model

`chats(jid, name, is_group, last_ts, unread)`. `messages(id, chat_jid, sender, sender_name, text, ts, from_me, media_type, filename, quoted_id, raw)`. `raw` is the marshalled protobuf; media downloads unmarshal it and hand it to whatsmeow, which avoids copying media keys into columns.

Unread is counted in the bridge: incremented on a live incoming message, cleared by `chat.read`, which also sends read receipts for the last 20 incoming messages.

JIDs are canonicalised to the phone-number form. LID addressing is resolved through whatsmeow's LID map so one contact never splits into two chats.

## UI

`:WhatsApp` opens a new tab: list on the left (`topleft 32vsplit`), chat on the right, compose below the chat (`belowright 3split`). The tab is reused on later calls. `q` closes the tab and leaves the bridge running so notifications keep arriving.

The compose buffer is `buftype=acwrite`. `BufWriteCmd` sends the trimmed content, clears the buffer, and appends the sent message locally. Reply state lives in `state.reply_to` and shows in the compose winbar.

The chat buffer re-renders on every change. It follows the bottom unless the cursor was moved up. Each buffer line maps to a message so `R`, `r`, and `<CR>` act on the message under the cursor.

Pairing renders the QR code as half-block text in a floating window. No browser.

## Errors

Bridge not built: one error notification pointing at `make`. Bridge exits non-zero: notification with the stderr tail. Not paired: notification pointing at `:WhatsApp pair`. Logged out by the phone: same.

## Tests

Go: `store_test.go` (ordering, dedup, pagination, unread), `extract_test.go` (message variants). Lua: `test/run.lua` runs headless against `test/fake-bridge.sh` and asserts on buffer contents for load, live push, send, and teardown. Pairing and real traffic are manual.

## Later

- `wa-bridge serve` on a unix socket for always-on history.
- Media send from a file path.
- Typing indicators and presence.
- Contact picker via `vim.ui.select` for starting new chats.
