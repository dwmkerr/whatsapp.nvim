-- Shared mutable state for the open WhatsApp session. One tab, one chat.
local text = require("whatsapp.text")
local M = {
  opts = nil,
  chats = {},        -- array of chat rows from the bridge, newest first
  chat_by_jid = {},
  filter = "all",    -- chat list filter: all, unread or groups
  current = nil,     -- jid of the open conversation
  messages = {},     -- jid -> array of messages, oldest first
  drafts = {},      -- jid -> session-only compose buffer, reply and pending send
  tab = nil,
  wins = { list = nil, chat = nil, compose = nil },
  bufs = { list = nil, chat = nil, compose = nil },
  status = { paired = nil, connected = false }, -- paired unknown until "ready"
  synced = false,    -- offline sync finished for this bridge run
  sync = nil,        -- last sync.progress payload while history loads
  just_paired = false,
  help = false,      -- g? cheatsheet shown in the chat pane
  help_return = nil, -- window to focus again when the cheatsheet closes
  qr = nil,          -- pairing QR lines while a pair.start is waiting for a scan
  pairing = false,   -- pair.start sent, QR code not here yet
  typing = nil,      -- { jid, sender, who, media } while the other party types in the open chat
  available = false, -- bridge asked to show this device online
}

-- Columns available for text in a window, after number/sign columns the
-- user's config may force on.
function M.text_width(name, fallback)
  if not M.win_valid(name) then
    return fallback
  end
  local w = M.wins[name]
  local info = vim.fn.getwininfo(w)[1]
  return vim.api.nvim_win_get_width(w) - (info and info.textoff or 0)
end

function M.set_chats(chats)
  M.chats = chats
  M.chat_by_jid = {}
  for _, c in ipairs(chats) do
    M.chat_by_jid[c.jid] = c
  end
end

function M.chat_name(jid)
  local c = M.chat_by_jid[jid]
  return text.name(c and c.name or jid)
end

-- Chat and sender names come from remote users. Anything placed in a
-- statusline-style option must have "%" doubled, else "%{...}" would evaluate.
function M.bar_text(value)
  return (text.single_line(value):gsub("%%", "%%%%"))
end

-- Name plus phone number for direct chats, so a stranger whose push name
-- matches a contact is still distinguishable.
function M.chat_title(jid)
  local c = M.chat_by_jid[jid]
  local name = M.chat_name(jid)
  local user = jid:match("^([^@]+)@s%.whatsapp%.net$")
  if c and not c.is_group and user and user ~= name then
    return name .. "  +" .. user
  end
  return name
end

function M.layout_valid()
  return M.tab and vim.api.nvim_tabpage_is_valid(M.tab)
end

function M.win_valid(name)
  local w = M.wins[name]
  return w and vim.api.nvim_win_is_valid(w)
end

function M.reset_layout()
  M.tab = nil
  M.wins = { list = nil, chat = nil, compose = nil }
  -- Hidden buffers and per-chat drafts survive closing the tab.
end

return M
