local S = require("whatsapp.state")
local format = require("whatsapp.format")

local M = {}
local ns = vim.api.nvim_create_namespace("whatsapp_chat")
local line_owner = {}

function M.ensure_buf()
  if S.bufs.chat and vim.api.nvim_buf_is_valid(S.bufs.chat) then
    return S.bufs.chat
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "wa://chat")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "whatsapp"
  vim.bo[buf].modifiable = false
  S.bufs.chat = buf

  local wa = require("whatsapp")
  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  for _, k in ipairs({ "i", "a", "o", "A", "I" }) do
    map(k, wa.focus_compose, "Compose message")
  end
  map("R", function() wa.reply_to(M.message_under_cursor()) end, "Reply to message")
  map("r", function() wa.react_to(M.message_under_cursor()) end, "React to message")
  map("<CR>", function() wa.open_media(M.message_under_cursor()) end, "Open media")
  map("gf", function() wa.open_media(M.message_under_cursor()) end, "Open media")
  map("K", wa.load_older, "Load older messages")
  map("U", function() wa.toggle_unread(S.current) end, "Mark chat unread")
  map("q", wa.close, "Close WhatsApp")
  map("g?", function() require("whatsapp.ui.help").show("chat") end, "Keys")
  map("L", function()
    S.opts.layout = S.opts.layout == "bubbles" and "lines" or "bubbles"
    M.render()
  end, "Toggle bubble/line layout")
  map("<C-l>", function()
    if S.win_valid("list") then
      vim.api.nvim_set_current_win(S.wins.list)
    end
  end, "Focus chat list")
  return buf
end

function M.message_under_cursor()
  if not S.win_valid("chat") then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(S.wins.chat)[1]
  return line_owner[row]
end

-- Text for the chat window when nothing is open: a short centred block
-- that reflects what the bridge is doing.
local function splash(width, height)
  local client = require("whatsapp.client")
  -- Each row: { text = ..., hl = line highlight } or { key = ..., text = ... }.
  local rows = { { text = "WhatsApp", hl = "Title" }, {} }
  local function note(text)
    rows[#rows + 1] = { text = text, hl = "Comment" }
  end
  local function key(k, text)
    rows[#rows + 1] = { key = k, text = text }
  end
  if not client.running() then
    note("bridge not running")
    key(":WhatsApp", "restarts it")
  elseif S.status.paired == false then
    note("not paired")
    key(":WhatsApp pair", "links this device")
  elseif not S.status.connected then
    note("connecting…")
  elseif S.sync and not S.synced then
    note("syncing history · " .. (S.sync.chats or 0) .. " chats")
  else
    local unread = 0
    for _, c in ipairs(S.chats) do
      if c.unread > 0 then
        unread = unread + 1
      end
    end
    key("<CR>", "open chat")
    key("i", "open and compose")
    key("u", "next unread")
    key("g?", "all keys")
    rows[#rows + 1] = {}
    note("connected · " .. #S.chats .. " chats · " .. unread .. " unread")
  end

  local keyw = 0
  for _, r in ipairs(rows) do
    if r.key then
      keyw = math.max(keyw, #r.key + 2)
    end
  end
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

-- Re-render the current conversation. Keeps the view pinned to the bottom
-- unless the user has scrolled up to read history.
function M.render()
  local buf = M.ensure_buf()
  local msgs = S.current and S.messages[S.current] or {}
  local chat = S.current and S.chat_by_jid[S.current]
  local width = S.text_width("chat", 80)
  local height = S.win_valid("chat") and vim.api.nvim_win_get_height(S.wins.chat) or 20
  local lines, owners, spans
  if not S.current then
    lines, spans = splash(width, height)
    owners = {}
  elseif S.opts.layout == "bubbles" then
    lines, owners, spans = format.bubbles(msgs, chat and chat.is_group, width)
  else
    lines, owners, spans = format.conversation(msgs, chat and chat.is_group)
  end
  if #lines == 0 then
    local text = "no messages yet · i to write"
    lines = { string.rep(" ", math.max(0, math.floor((width - #text) / 2))) .. text }
    spans = { { 0, 0, -1, "Comment" } }
    owners = {}
  end
  line_owner = owners

  local follow = true
  local old_count = vim.api.nvim_buf_line_count(buf)
  if S.win_valid("chat") then
    local row = vim.api.nvim_win_get_cursor(S.wins.chat)[1]
    follow = row >= old_count - 1
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, s in ipairs(spans) do
    local line, cs, ce, group = s[1], s[2], s[3], s[4]
    if ce == -1 then
      vim.api.nvim_buf_set_extmark(buf, ns, line, 0, { line_hl_group = group })
    else
      vim.api.nvim_buf_set_extmark(buf, ns, line, cs, { end_col = math.min(ce, #lines[line + 1]), hl_group = group })
    end
  end

  if S.win_valid("chat") then
    local name = S.current and S.chat_title(S.current) or "WhatsApp"
    vim.wo[S.wins.chat].winbar = " " .. S.bar_text(name)
    if follow then
      vim.api.nvim_win_set_cursor(S.wins.chat, { #lines, 0 })
    end
  end
end

return M
