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

**Setup and Pairing**

When you run `:WhatsApp` you'll get a splash screen showing the most essential shortcuts:

TODO Screenshot splash

Use the `:WhatsApp pair` command to connect. On your mobile scan the QR code or go to Settings > Linked Devices and scan from there.

TODO Screenshot QR code

**Chats and Messages**

The list of chats is shown on the left. Threads with unread messages are shown in bold. There are a few convenient helpers:

- `i` compose message:
- todo remind me pls
- toggle read unread (as a reminder, think of read as lowercase and unread as uppercase)

TODO Screenshot of main screen

**Images**

Images are shown inline if you have a terminal that supports them (XX such as). Download them with XX and download and open with YY:

TODO screenshot

**Attachments**

With any attachment focused, use `XX` to download or `XX` to download and open. Please be careful, if someone has sent something malicious then in the worst case it could lead to code execution, I've made some best effort[^1 footnote on how I avoid code exection] attempts to block the most obvious risks but be mindful:

TODO screenshot of voice attachment

**Other Bits & Pieces**

- When new messages come in, a notification is shown in the XX [remind me what the notification bar is]
- The '...is typing' activity bubble is shown if you have a chat open and someone is typing, just like the app this only appears if the chat is focused and for a few seconds

HEADING: Contributing

Please feel free to share updates. If possible, also update the original instructions [TODO link to the shell script].

There are open issues for ideas I've not got around to, here are some suggestions:

- Unread message count TODO link to GH issue (best 3x?)
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

```bash
" Close vim, rebuild, run:
make -C ~/repos/whatsapp.nvim/dist build && nvim +WhatsApp
```

## Other Notes

This is built using the unofficial client [whatsmeow](https://github.com/tulir/whatsmeow), as noted on that repository it is possible that this might violate the WhatsApp terms of service. Also, the compiled version used the codex/Astra compiler and comes with the least possible warranty.
