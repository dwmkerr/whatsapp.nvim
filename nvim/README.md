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

The plugin lives in the `nvim/` directory of the repo, so point your plugin manager at that subdirectory.

vim-plug:

```vim
Plug 'dwmkerr/whatsapp.nvim', { 'rtp': 'nvim', 'do': 'make -C nvim' }
```

lazy.nvim:

```lua
{
  "dwmkerr/whatsapp.nvim",
  build = "make -C nvim",
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

## Use

| Command | What |
|---|---|
| `:WhatsApp` | Open (or jump to) the WhatsApp tab |
| `:WhatsApp toggle` | Open or close |
| `:WhatsApp Alice` | Open and jump to the chat matching "Alice" |
| `:WhatsApp pair` | Show the pairing QR code |
| `:WhatsApp status` | Bridge status |
| `:WhatsApp stop` | Close and kill the bridge |

Chat list (left):

| Key | What |
|---|---|
| `<CR>` `l` | Open chat |
| `i` | Open chat and start composing |
| `u` | Jump to next unread chat |
| `U` | Toggle unread, mirrored to your phone |
| `R` | Refresh |
| `g?` | Keys |
| `q` | Close WhatsApp |

Conversation (right):

| Key | What |
|---|---|
| `i` `a` `o` | Jump to compose buffer in insert mode |
| `R` | Reply to the message under the cursor |
| `r` | React to the message under the cursor |
| `<CR>` `gf` | Download media under the cursor |
| `gx` | Download if needed, then confirm before opening in its default application |
| `K` | Load older messages |
| `U` | Mark chat unread and close it |
| `L` | Toggle bubbles / lines |
| `g?` | Keys |
| `/` `n` `gg` `G` | Native search and movement |

Compose (bottom):

| Key | What |
|---|---|
| `:w` | Send |
| `q` | Cancel reply |
| `g?` | Keys |

The compose pane appears once a chat is open. With no chat open the right pane shows bridge status and the main keys.

Multi-line messages work: write several lines, then `:w`.

Each chat keeps its own draft and reply target in memory until Neovim exits. Switching chats or closing the WhatsApp tab preserves unsent drafts. A send response only clears the original draft if it has not been edited while sending.

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
})
```

Highlight groups: `WhatsAppUnread`, `WhatsAppCurrent`, `WhatsAppTime`, `WhatsAppSender`, `WhatsAppMe`, `WhatsAppMedia`, `WhatsAppSeparator`, `WhatsAppQuote`.

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

Methods: `status`, `pair.start`, `chats.list`, `messages.list {jid, limit, before}`, `message.send {jid, text, reply_to}`, `message.react {jid, id, emoji}`, `chat.read {jid}`, `chat.unread {jid}`, `media.download {jid, id}`, `contacts.search {query}`.

Events: `ready`, `unpaired`, `connected`, `disconnected`, `logged_out`, `pair.qr {lines}`, `pair.ok`, `pair.timeout`, `pair.error`, `message {chat_name, message}`, `chats.changed`, `sync.progress`, `sync.done`, `fatal`.

## Privacy

Everything stays on your machine in the store directory: the session keys, the message database, and downloaded media. Nothing is encrypted at rest. Keep the directory out of cloud-synced folders and backups.

The store is created owner-only (`0700`, databases `0600`). Display names have control characters removed and line breaks replaced with spaces; winbar text is also escaped. Media paths are sanitised, and image, video and audio extensions come from a small list of recognised MIME types for that media family. Unknown types become `.bin`. A recognised extension does not establish that a file is safe: opening any attachment requires confirmation.
