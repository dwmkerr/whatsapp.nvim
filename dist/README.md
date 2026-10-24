# whatsapp.nvim

> [!CAUTION]
> This is 100% vibe-coded as a (not very good) joke about the nature of software engineering in the world of AI, and also as an actual tool that I use daily but do not have the time to properly analyse and architect. Use at your own risk - I have attempted some security reviews but this is simply whatever Astra and Fable have dealt with.
>
> The only hand-written code is the root level README.md (i.e. not this one) and the whatsapp.nvim.sh script. Everything from here on onwards is the usual exhausting AI noise.

WhatsApp inside Neovim. Chat list on the left, conversation on the right, a compose buffer underneath. `:w` sends.

Built on [whatsmeow](https://github.com/tulir/whatsmeow), which speaks the WhatsApp Web multi-device protocol. The plugin shows up on your phone as a linked device. This is an unofficial client and may violate WhatsApp's terms of service. Use at your own risk.

## How it works

```
Neovim ──stdio (JSON lines)──▶ bin/wa-bridge (Go, whatsmeow) ──▶ WhatsApp
  lua/whatsapp/*                 stores session + messages in SQLite
```

The bridge runs as a child process of Neovim, like a language server. Incoming messages are pushed to the editor as events, so the open chat updates live and other chats raise a notification.

## Install

Requires Go 1.26.9+ and a C compiler (SQLite is cgo).

The plugin lives in the `dist/` directory of the repo, so point your plugin manager at that subdirectory.

vim-plug:

```vim
Plug 'dwmkerr/whatsapp.nvim', { 'rtp': 'dist', 'do': 'make -C dist' }
```

lazy.nvim:

```lua
{
  "dwmkerr/whatsapp.nvim",
  build = "make -C dist",
  config = function()
    vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/whatsapp.nvim/nvim")
    require("whatsapp").setup()
  end,
}
```

Then pair once:

```
:WhatsApp pair
```

Scan the QR code from your phone: WhatsApp > Settings > Linked Devices > Link a Device. History syncs in the background.

If the splash shows "read marks out of sync", open WhatsApp on your phone. On some accounts WhatsApp's server copy of read marks, pins and mutes cannot be verified, and only the phone can send a good copy. It answers while the app is open. Pairing again does not help.

## Use

While a chat is open and the terminal has focus the device is marked online, so WhatsApp sends typing notifications and contacts can see you as online, just like the phone with a chat on screen. The indicator shows as a bubble under the last message.

| Command | What |
|---|---|
| `:WhatsApp` | Open (or jump to) the WhatsApp tab |
| `:WhatsApp toggle` | Open or close |
| `:WhatsApp Alice` | Open and jump to the chat matching "Alice" |
| `:WhatsApp pair` | Show the pairing QR code in the chat pane |
| `:WhatsApp logout` | Unlink this device from your phone and forget the local session |
| `:WhatsApp status` | Bridge status |
| `:WhatsApp stop` | Close and kill the bridge |

Chat list (left):

| Key | What |
|---|---|
| `<CR>` `l` | Open chat |
| `i` | Open chat and start composing |
| `u` | Jump to next unread chat |
| `gU` `gu` `~` | Mark unread / read / toggle, mirrored to your phone |
| `R` | Refresh |
| `gx` `]m` `[m` | Open / next / previous media in the open chat |
| `K` `L` | Older messages / toggle layout in the open chat |
| `<Tab>` `<S-Tab>` | Cycle panes |
| `g?` | Keys |
| `q` | Close WhatsApp |

Conversation keys that do not clash with list keys also work from the list, so a shortcut never depends on which pane has focus.

Conversation (right):

| Key | What |
|---|---|
| `i` `a` `o` | Jump to compose buffer in insert mode |
| `R` | Reply to the message under the cursor |
| `r` | React to the message under the cursor |
| `<CR>` | Media menu: download, open, copy path |
| `gx` | Download if needed, then confirm before opening in its default application |
| `]m` `[m` | Next / previous media |
| `K` | Load older messages |
| `gU` `gu` `~` | Mark chat unread (closes it) / read / toggle |
| `L` | Toggle bubbles / lines |
| `<Tab>` `<S-Tab>` | Cycle panes |
| `g?` | All keys and commands |
| `/` `n` `gg` `G` | Native search and movement |

Compose (bottom):

| Key | What |
|---|---|
| `:w` | Send |
| `q` | Cancel reply |
| `<CR>` `gx` | Media menu / open media, in normal mode |
| `]m` `[m` | Next / previous media |
| `<Tab>` `<S-Tab>` | Cycle panes |
| `g?` | All keys and commands |

The compose pane appears once a chat is open. With no chat open the right pane shows bridge status and the main keys. `g?` from any pane shows every key and command in that same pane; `q`, `<Esc>` or `g?` returns to where you were.

Multi-line messages work: write several lines, then `:w`.

Each chat keeps its own draft and reply target in memory until Neovim exits. Switching chats or closing the WhatsApp tab preserves unsent drafts. A send response only clears the original draft if it has not been edited while sending.

Media shows as a tag in the message: `[image photo.jpg]`, `[video clip.mp4 0:12]`, and voice notes as duration plus waveform, `[voice 0:42 ▁▃▇▂▅▁▇▃▂▁▅▂]`. `⇣` means not downloaded yet, `✓` means the file is in the cache. `<CR>` and `gx` act on the media under the cursor, or on the newest media in the chat when the cursor is elsewhere; that target carries a key hint on a line under it, and `]m` `[m` move between attachments. The compose pane counts as the slot after the last attachment: `]m` past the end returns to compose, `[m` from compose lands on the newest attachment.

Attachments download without opening an application. Use `gx` to open one, with confirmation for every file type. Downloads stream to a temporary file and are checked before entering the cache. Each attachment is limited to 25 MiB and 60 seconds, with at most two downloads at once. Larger attachments can be opened in the official WhatsApp client.

## Configure

```lua
require("whatsapp").setup({
  store = vim.fn.stdpath("data") .. "/whatsapp", -- session and message databases
  list_width = 32,
  compose_height = 3,
  page_size = 100,          -- messages per page
  notify = true,            -- vim.notify for messages in chats you are not viewing
  mark_read_on_view = true, -- send read receipts when you open a chat
  default_reaction = "👍",
  images = { mode = "auto" }, -- "tag" or "kitty"; auto picks kitty when the terminal supports it
})
```

Every option, the image modes and what they need, and the highlight groups are in [`docs/configuration.md`](../docs/configuration.md).

## Develop

```
make build     # compile the bridge
make test      # Go unit tests + headless Neovim test against test/fake-bridge.sh
```

Run the bridge by hand to poke the protocol:

```
printf '{"id":1,"method":"status"}\n' | ./bin/wa-bridge -store /tmp/wa
```

### Bridge protocol

One JSON object per line. Requests carry an `id` and `method`; responses echo the `id` with `result` or `error`; events have no `id`.

Methods: `status`, `pair.start`, `logout`, `chats.list`, `messages.list {jid, limit, before}`, `message.send {jid, text, reply_to}`, `message.react {jid, id, emoji}`, `chat.read {jid}`, `chat.unread {jid}`, `presence {available}`, `media.download {jid, id}`, `contacts.search {query}`.

Events: `ready`, `unpaired`, `connected`, `disconnected`, `logged_out`, `pair.qr {lines}`, `pair.ok`, `pair.timeout`, `pair.error`, `typing {chat, sender, sender_name, state, media}`, `message {chat_name, message}`, `chats.changed`, `sync.progress`, `sync.done`, `appstate.waiting {name}`, `appstate.synced {name}`, `fatal`.

## Privacy

Everything stays on your machine in the store directory: the session keys, the message database, and downloaded media. Nothing is encrypted at rest. Keep the directory out of cloud-synced folders and backups.

The store is created owner-only (`0700`, databases `0600`). Display names have control characters removed and line breaks replaced with spaces; winbar text is also escaped. Media paths are sanitised, and image, video and audio extensions come from a small list of recognised MIME types for that media family. Unknown types become `.bin`. A recognised extension does not establish that a file is safe: opening any attachment requires confirmation.
