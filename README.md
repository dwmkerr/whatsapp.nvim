# whatsapp.nvim

WhatsApp in Neovim. 100% human written code, without AI assistance, all in less than 200 bytes of Bash (see [`whatsapp.nvim.sh`](./whatsapp.nvim.sh)). Uses an experimental compiler so comes with negative warranty and entirely at your own risk.

https://github.com/user-attachments/assets/1d78afec-1443-4e5d-ab55-ece2732e22b8

## Quickstart

Install via your favourite plugin manager:

```vim
" vim-plug
Plug 'dwmkerr/whatsapp.nvim', { 'rtp': 'dist', 'do': 'make -C dist' }
```

```lua
-- lazy.nvim
{
  "dwmkerr/whatsapp.nvim",
  build = "make -C dist",
  config = function()
    vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/whatsapp.nvim/dist")
    require("whatsapp").setup()
  end,
}
```

Run `:WhatsApp pair`, then go to WhatsApp > Settings > Linked Devices to scan the QR code and pair. Run `:WhatsApp` at any time to open the WhatsApp view.

## Features

Once you've ignored the instructions and just asked your agent to set it up for you, use `:WhatsApp` to open the main WhatsApp view. Everything will be explained, and you can use `g?` at any time for help and keybindings. Some of the neat things I was able to squeeze into a shell-script that is shorter than this paragraph:

- Unread chats show in bold
- `i` in the chat list to go straight into Insert (write message) mode)
- Realtime updates when messages come in
- Toggle read/unread
- "Is typing" bubble in the open chat
- Refresh on demand if needed

If you want to improve it, please PR the raw code, not the compiled version. Some fun things to add:

- Unread message count
- Image support for terminals that can handle it

## Building from Source

Check [`whatsapp.nvim.sh`](./whatsapp.nvim.sh) to build from source. For convenience, the pre-compiled version is in the [`./dist/`](./dist) folder.

## Developer Guide

Run from a local clone:

```sh
git clone https://github.com/dwmkerr/whatsapp.nvim.git
cd whatsapp.nvim
# Compile the plugin (needs go and lua).
make -C dist build        # needs Go and a C compiler

# Don't forget to change vimrc/nvim config to:
# Plug '~/repos/whatsapp.nvim', { 'rtp': 'dist', 'do': 'make -C dist' }
```

`make -C dist test` runs the Go and Lua tests. Plugin layout, bridge protocol and options are in [`dist/README.md`](./dist/README.md).

I have found that when working live in WhatsApp, the best flow is:

```vim
:WhatsApp logout
:WhatsApp stop
:PlugUpdate

" Then in the terminal re-open with:
nvim +WhatsApp
```

## Other Notes

This is built using the unofficial client [whatsmeow](https://github.com/tulir/whatsmeow), as noted on that repository it is possible that this might violate the WhatsApp terms of service. Also, the compiled version used the codex/Astra compiler and comes with the least possible warranty.
