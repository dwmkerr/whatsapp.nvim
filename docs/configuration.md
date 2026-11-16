# Configuration

All keys are optional. These are the defaults.

```lua
require("whatsapp").setup({
  bin = nil,                                     -- bridge binary, default <plugin>/bin/wa-bridge
  store = vim.fn.stdpath("data") .. "/whatsapp", -- session, messages and media cache
  list_width = 32,
  unread_count = false,                          -- unread message count left of the time
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
    auto_download = true,                        -- fetch pictures and stickers as they show
  },
})
```

## Images

`kitty` draws pictures inside their bubble and needs a Kitty graphics terminal (Ghostty, kitty, WezTerm, Konsole) plus ImageMagick or macOS `sips`; `tag` shows the `[image ✓]` line and `gx` opens the file. `auto` picks `kitty` when both are found. Stickers draw too, smaller than photos.

`auto_download` fetches the pictures and stickers in the chat you open, newest first, one at a time, as the phone does. It works in any terminal, so a chat read in tag mode already has its pictures when you come back in a Kitty graphics terminal. Video, voice notes and documents stay manual. Set it to `false` on a metered connection. Inside tmux the plugin enables `allow-passthrough` for its pane.

### Remote and tmux

Pictures work over SSH. Run Neovim and the plugin on the remote machine; the picture data travels through the terminal connection, so your local terminal only needs to speak the Kitty graphics protocol. ImageMagick or `sips` must be installed on the remote machine, because conversion happens where Neovim runs.

kitty sends `TERM=xterm-kitty` over SSH, so `auto` finds it. Ghostty and WezTerm identify themselves through variables SSH does not forward; set `images = { mode = "kitty" }` on the remote machine.

tmux must run on the same machine as Neovim. With tmux on your local machine and SSH inside it, the plugin cannot tell tmux is there and pictures stay blank; set `images = { mode = "tag" }` for that setup.

## Highlight groups

`WhatsAppUnread`, `WhatsAppFilter`, `WhatsAppCurrent`, `WhatsAppTime`, `WhatsAppSender`, `WhatsAppMe`, `WhatsAppMedia`, `WhatsAppSeparator`, `WhatsAppQuote`, `WhatsAppBubble`, `WhatsAppBubbleMe`. Override them after `setup()`.
