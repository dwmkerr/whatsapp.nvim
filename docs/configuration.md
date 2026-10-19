# Configuration

Everything is set through `require("whatsapp").setup({ ... })`. Every key is optional; the values below are the defaults.

```lua
require("whatsapp").setup({
  bin = nil,                                     -- bridge binary, defaults to <plugin>/bin/wa-bridge
  store = vim.fn.stdpath("data") .. "/whatsapp", -- session, message database and media cache
  list_width = 32,                               -- columns for the chat list
  compose_height = 3,                            -- rows for the compose pane
  page_size = 100,                               -- messages loaded per page (K loads another)
  notify = true,                                 -- vim.notify for messages in chats you are not viewing
  mark_read_on_view = true,                      -- send read receipts when you open a chat
  default_reaction = "👍",                       -- what r sends when you accept the default
  layout = "bubbles",                            -- "bubbles" or "lines", L toggles at runtime
  images = {
    mode = "auto",                               -- "auto", "tag" or "kitty"
    max_width = 60,                              -- cells
    max_height = 12,                             -- rows
  },
})
```

## Images

An image message always has a tag line, `[image photo.jpg ✓]`, which is what `<CR>`, `gx` and `]m` act on. `images.mode` decides what hangs under it.

| Mode | What you see | Needs |
|---|---|---|
| `tag` | the tag line only | nothing |
| `kitty` | the picture itself | a terminal that speaks the Kitty graphics protocol (Ghostty, kitty, WezTerm, Konsole), and ImageMagick (`magick` or `convert`) or macOS `sips` to turn JPEG into PNG |

`auto`, the default, is `kitty` when the environment supports it and `tag` otherwise. Pin `kitty` to force it; if its requirements are missing it falls back to `tag` with a warning.

Only files already on disk are drawn: pictures you have downloaded, or that arrived earlier and are in the cache. Nothing is fetched from the network to render a chat.

`max_width` and `max_height` bound the picture in cells. The aspect ratio is kept, so one of the two is usually the limit.

### tmux

The Kitty protocol has to reach the terminal through tmux. tmux forwards it when `allow-passthrough` is on; the plugin sets it for its own pane at runtime, so no `.tmux.conf` change is needed, though `set -g allow-passthrough on` there makes it permanent. Needs tmux 3.3 or later.

### Known limits

- Pictures are rendered after a conversion step, so the first view of each one takes a moment.
- The picture is sent to the terminal by file path. Over `ssh` the terminal cannot read the file, so you get the tag there.
- Stickers, video previews and thumbnails of images not yet downloaded are not drawn yet.

## Highlight groups

Override any of these after `setup()` to restyle the panes.

| Group | Used for | Default |
|---|---|---|
| `WhatsAppUnread` | chats with unread messages in the list | bold |
| `WhatsAppFilter` | the active chat-list filter | bold |
| `WhatsAppCurrent` | the open chat in the list | `Visual` |
| `WhatsAppTime` | timestamps | `Comment` |
| `WhatsAppSender` | sender names | `Identifier` |
| `WhatsAppMe` | your own name | `String` |
| `WhatsAppMedia` | attachment tags | `Special` foreground, underlined |
| `WhatsAppSeparator` | day separators | `Comment` |
| `WhatsAppQuote` | quoted replies | `Comment` |
| `WhatsAppBubble` | other people's bubbles | `Normal` |
| `WhatsAppBubbleMe` | your bubbles | `DiffAdd` |

Keys are shown in `Special` and their descriptions in `Comment` wherever a hint appears.
