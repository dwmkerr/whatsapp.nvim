# Configuration

All keys are optional. These are the defaults.

```lua
require("whatsapp").setup({
  bin = nil,                                     -- bridge binary, default <plugin>/bin/wa-bridge
  store = vim.fn.stdpath("data") .. "/whatsapp", -- session, messages and media cache
  list_width = 32,
  compose_height = 3,
  page_size = 100,                               -- messages per page, K loads more
  notify = true,                                 -- vim.notify for chats you are not viewing
  mark_read_on_view = true,                      -- send read receipts when you open a chat
  default_reaction = "👍",
  layout = "bubbles",                            -- or "lines", L toggles
  images = {
    mode = "auto",                               -- "auto", "tag" or "kitty"
    max_width = 60,                              -- cells
    max_height = 20,                             -- rows, at most half the pane
    crop = true,                                 -- crop tall pictures rather than shrink them
  },
})
```

## Images

`kitty` draws pictures inside their bubble and needs a Kitty graphics terminal (Ghostty, kitty, WezTerm, Konsole) plus ImageMagick or macOS `sips`; `tag` shows the `[image ✓]` line and `gx` opens the file. `auto` picks `kitty` when both are found. Inside tmux the plugin enables `allow-passthrough` for its pane.

## Highlight groups

`WhatsAppUnread`, `WhatsAppFilter`, `WhatsAppCurrent`, `WhatsAppTime`, `WhatsAppSender`, `WhatsAppMe`, `WhatsAppMedia`, `WhatsAppSeparator`, `WhatsAppQuote`, `WhatsAppBubble`, `WhatsAppBubbleMe`. Override them after `setup()`.
