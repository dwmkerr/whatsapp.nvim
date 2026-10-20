-- g? cheatsheet: every key and command, drawn in the chat pane like the
-- splash so help always appears in the same place. q or g? returns.
local M = {}

local commands = {
  { ":WhatsApp", "open, or jump to the WhatsApp tab" },
  { ":WhatsApp Alice", "open the chat matching Alice" },
  { ":WhatsApp pair", "link this device (shows the QR code)" },
  { ":WhatsApp logout", "unlink this device" },
  { ":WhatsApp stop", "close and stop the bridge" },
}

local keys = {
  list = {
    { "<CR> l", "open chat" },
    { "i", "open chat and compose" },
    { "u", "next unread chat" },
    { "f", "filter: all / unread / groups" },
    { "gU gu ~", "mark unread / read / toggle" },
    { "R", "refresh chats and contact names" },
    { "gx ]m [m", "open / next / previous media in the open chat" },
    { "K L", "older messages / toggle layout in the open chat" },
    { "<Tab>", "next pane" },
    { "g?", "all keys" },
    { "q", "close WhatsApp" },
  },
  chat = {
    { "i a o", "compose" },
    { "R", "reply to message under cursor" },
    { "r", "react to message under cursor" },
    { "<CR>", "media menu: download, open, copy path" },
    { "gx", "open media (downloads first, asks before opening)" },
    { "]m [m", "next / previous media" },
    { "K", "load older messages" },
    { "gU gu ~", "mark unread (closes chat) / read / toggle" },
    { "L", "toggle bubbles / lines" },
    { "<Tab>", "next pane" },
    { "q", "close WhatsApp" },
  },
  compose = {
    { ":w", "send" },
    { "q", "cancel reply" },
    { "<CR> gx", "media menu / open media (normal mode)" },
    { "]m [m", "next / previous media" },
    { "<Tab>", "next pane" },
  },
}


local sections = {
  { "commands", commands },
  { "chat list", keys.list },
  { "conversation", keys.chat },
  { "compose", keys.compose },
}

-- Lines and highlight spans for the chat pane, centred like the splash.
function M.layout(width, height)
  local rows = { { text = "WhatsApp keys", hl = "Title" }, {} }
  local keyw = 0
  for _, sec in ipairs(sections) do
    for _, k in ipairs(sec[2]) do
      keyw = math.max(keyw, #k[1] + 2)
    end
  end
  for i, sec in ipairs(sections) do
    if i > 1 then
      rows[#rows + 1] = {}
    end
    rows[#rows + 1] = { text = sec[1], hl = "Comment" }
    for _, k in ipairs(sec[2]) do
      rows[#rows + 1] = { key = k[1], text = k[2] }
    end
  end
  rows[#rows + 1] = {}
  rows[#rows + 1] = { text = "q or g? returns", hl = "Comment" }

  local block = 0
  for _, r in ipairs(rows) do
    r.line = r.key and (r.key .. string.rep(" ", keyw - #r.key) .. r.text) or (r.text or "")
    block = math.max(block, vim.fn.strdisplaywidth(r.line))
  end
  local pad = string.rep(" ", math.max(0, math.floor((width - block) / 2)))
  local lines, spans = {}, {}
  for _ = 1, math.max(0, math.floor((height - #rows) / 2)) do
    lines[#lines + 1] = ""
  end
  for _, r in ipairs(rows) do
    local line = #lines
    lines[#lines + 1] = r.line ~= "" and (pad .. r.line) or ""
    if r.hl then
      spans[#spans + 1] = { line, 0, -1, r.hl }
    elseif r.key then
      spans[#spans + 1] = { line, #pad, #pad + #r.key, "Special" }
    end
  end
  return lines, spans
end

return M
