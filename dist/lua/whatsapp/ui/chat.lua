local S = require("whatsapp.state")
local format = require("whatsapp.format")
local help = require("whatsapp.ui.help")
local images = require("whatsapp.ui.images")

local M = {}
local ns = vim.api.nvim_create_namespace("whatsapp_chat")
local ns_hint = vim.api.nvim_create_namespace("whatsapp_chat_hint")
local typing_frame = 0
local typing_start = nil -- 0-based line where the typing rows begin, nil when hidden

-- Rows for the typing indicator in the open chat, nil when there is none.
local function typing_rows(width)
  local t = S.typing
  if not t or not S.current or t.jid ~= S.current or S.qr or S.help then
    return nil
  end
  if S.opts.layout == "bubbles" then
    return format.typing_bubble(t.who, typing_frame, width)
  end
  return { format.typing_line(t.who, typing_frame, t.media) }
end
local line_owner = {}
local media_rows = {} -- { { row = 1-based tag row, m = message }, ... } in chat order
local rendered_jid = nil -- chat shown by the previous render, for scroll follow

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
  map("<CR>", function() wa.media_menu(M.media_target()) end, "Media menu")
  map("gx", function() wa.open_media(M.media_target()) end, "Open media")
  map("]m", function() wa.next_media(1) end, "Next media")
  map("[m", function() wa.next_media(-1) end, "Previous media")
  map("K", wa.load_older, "Load older messages")
  map("~", function() wa.toggle_unread(S.current) end, "Toggle unread")
  map("gU", function() wa.set_unread(S.current, true) end, "Mark chat unread and close it")
  map("gu", function() wa.set_unread(S.current, false) end, "Mark chat read")
  map("<Tab>", function() wa.focus_next(1) end, "Next pane")
  map("<S-Tab>", function() wa.focus_next(-1) end, "Previous pane")
  map("q", function()
    if S.help then
      wa.toggle_help()
    else
      wa.close()
    end
  end, "Close help, or WhatsApp")
  map("<Esc>", function()
    if S.help then
      wa.toggle_help()
    end
  end, "Close help")
  map("g?", wa.toggle_help, "All keys")
  map("L", M.toggle_layout, "Toggle bubble/line layout")
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = M.update_hint })
  return buf
end

function M.media_count()
  return #media_rows
end

-- The attachment that <CR> and gx act on: the media message under the
-- cursor, else the newest one in the chat. Returns message and its tag row.
function M.media_target()
  if #media_rows == 0 then
    return nil
  end
  if S.win_valid("chat") then
    local row = vim.api.nvim_win_get_cursor(S.wins.chat)[1]
    local m = line_owner[row]
    if m and m.media_type and m.media_type ~= "" then
      for _, e in ipairs(media_rows) do
        if e.m == m then
          return m, e.row
        end
      end
    end
  end
  local last = media_rows[#media_rows]
  return last.m, last.row
end

-- ]m / [m: move the cursor to the next or previous attachment, counting
-- from the cursor, or from before the first / after the last row when
-- from_edge is set. Returns false when there is none that way so the
-- caller can fall through.
function M.next_media(dir, from_edge)
  if not S.win_valid("chat") then
    return false
  end
  if #media_rows == 0 then
    vim.notify("WhatsApp: no media in this chat", vim.log.levels.INFO)
    return false
  end
  local row, cur
  if from_edge then
    row = dir > 0 and 0 or vim.api.nvim_buf_line_count(S.bufs.chat) + 1
  else
    row = vim.api.nvim_win_get_cursor(S.wins.chat)[1]
    cur = line_owner[row]
  end
  local target
  if dir > 0 then
    for _, e in ipairs(media_rows) do
      if e.row > row and e.m ~= cur then
        target = e
        break
      end
    end
  else
    for i = #media_rows, 1, -1 do
      local e = media_rows[i]
      if e.row < row and e.m ~= cur then
        target = e
        break
      end
    end
  end
  if not target then
    return false
  end
  vim.api.nvim_win_set_cursor(S.wins.chat, { target.row, 0 })
  M.update_hint()
  return true
end

-- Keys are not discoverable from the tag alone, so the target attachment
-- carries a hint on a virtual line under its message: keys in Special,
-- words in Comment, like the splash. Its own line, so it never wraps into
-- the message text.
function M.update_hint()
  local buf = S.bufs.chat
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_hint, 0, -1)
  local m, row = M.media_target()
  if not m then
    return
  end
  local entry
  for _, e in ipairs(media_rows) do
    if e.m == m then
      entry = e
    end
  end
  local tag_line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local indent = tag_line:match("^%s*") .. "  "
  local anchor = entry and entry.last or row
  vim.api.nvim_buf_set_extmark(buf, ns_hint, anchor - 1, 0, {
    virt_lines = { {
      { indent, "Comment" },
      { "<CR>", "Special" }, { " menu · ", "Comment" },
      { "gx", "Special" }, { " open · ", "Comment" },
      { "[m ]m", "Special" }, { " prev / next", "Comment" },
    } },
  })
  -- Virtual lines under the last buffer line sit below the window edge when
  -- the view was scrolled before they existed; re-anchor the bottom so the
  -- hint is on screen whenever the cursor is at the end of the chat.
  if S.win_valid("chat") and anchor == vim.api.nvim_buf_line_count(buf) then
    vim.api.nvim_win_call(S.wins.chat, function()
      if vim.api.nvim_win_get_cursor(0)[1] == anchor then
        vim.cmd("normal! zb")
      end
    end)
  end
end

function M.toggle_layout()
  S.opts.layout = S.opts.layout == "bubbles" and "lines" or "bubbles"
  M.render()
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
  elseif S.qr then
    note("scan with WhatsApp > Linked Devices > Link a Device")
    if height < #S.qr + 4 or width < vim.fn.strdisplaywidth(S.qr[1]) then
      note("code is " .. #S.qr .. " rows · zoom out or enlarge the window to see it all")
    end
    rows[#rows + 1] = {}
    for _, l in ipairs(S.qr) do
      rows[#rows + 1] = { text = l, hl = "Normal" }
    end
    rows[#rows + 1] = {}
    note("waiting for scan · q closes")
  elseif S.pairing then
    note("connecting… waiting for a QR code")
  elseif S.status.paired == false then
    note("not paired")
    rows[#rows + 1] = {}
    key(":WhatsApp pair", "links this device")
    rows[#rows + 1] = {}
    note("then scan the code with WhatsApp > Linked Devices")
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
    key("gU gu ~", "mark unread / read / toggle")
    key("<Tab>", "next pane")
    key("g?", "all keys")
    key("q", "close")
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
  -- A pending QR code takes the pane over even with a chat open: you can
  -- only be pairing because there is no session to read from anyway.
  if S.help then
    lines, spans = help.layout(width, height)
    owners = {}
  elseif not S.current or S.qr then
    lines, spans = splash(width, height)
    owners = {}
    -- A wrapped QR code cannot be scanned; let it run off the edge instead.
    if S.win_valid("chat") then
      vim.wo[S.wins.chat].wrap = S.qr == nil
    end
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
  -- Tag row per media message: the first of its lines that holds the tag.
  media_rows = {}
  local seen = {}
  for i, m in pairs(owners) do
    if m.media_type and m.media_type ~= "" then
      if not seen[m] and lines[i]:find("[" .. m.media_type, 1, true) then
        seen[m] = { row = i, m = m, last = i }
        media_rows[#media_rows + 1] = seen[m]
      end
      if seen[m] and i > seen[m].last then
        seen[m].last = i
      end
    end
  end
  table.sort(media_rows, function(a, b) return a.row < b.row end)

  -- The indicator is real buffer text below the last message so following
  -- the bottom keeps it on screen; the timer rewrites just those rows.
  typing_start = nil
  local trows = typing_rows(width)
  if trows then
    if S.opts.layout == "bubbles" then
      lines[#lines + 1] = ""
    end
    typing_start = #lines
    for _, r in ipairs(trows) do
      lines[#lines + 1] = r
      spans[#spans + 1] = { #lines - 1, 0, -1, "WhatsAppBubble" }
    end
  end

  -- Follow the bottom unless the user scrolled up in this same chat; a
  -- newly opened chat always starts at its latest message.
  local follow = true
  local old_count = vim.api.nvim_buf_line_count(buf)
  if S.win_valid("chat") and S.current == rendered_jid then
    local row = vim.api.nvim_win_get_cursor(S.wins.chat)[1]
    follow = row >= old_count - 1
  end
  -- Help and the QR code park the cursor at the top; forget the chat so the
  -- next conversation render follows the bottom again.
  if S.help or S.qr then
    rendered_jid = nil
  else
    rendered_jid = S.current
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  -- Pictures hang under the last line of their message, at the tag's
  -- indent, so they sit inside the bubble's column and above the hint.
  images.clear(buf)
  for _, e in ipairs(media_rows) do
    if e.m.media_type == "image" then
      local indent = (lines[e.row] or ""):match("^%s*") .. "  "
      images.place(buf, e.last, indent, e.m)
    end
  end
  for _, s in ipairs(spans) do
    local line, cs, ce, group = s[1], s[2], s[3], s[4]
    if ce == -1 then
      vim.api.nvim_buf_set_extmark(buf, ns, line, 0, { line_hl_group = group })
    else
      vim.api.nvim_buf_set_extmark(buf, ns, line, cs, { end_col = math.min(ce, #lines[line + 1]), hl_group = group })
    end
  end

  if S.win_valid("chat") then
    local name = S.help and "WhatsApp keys" or (S.current and S.chat_title(S.current) or "WhatsApp")
    vim.wo[S.wins.chat].winbar = " " .. S.bar_text(name)
    -- The chat window is often not the current one (the list or compose
    -- pane has focus), and Neovim leaves a non-current window's topline
    -- alone when its buffer changes. Scroll explicitly inside the window so
    -- the view matches the cursor.
    vim.api.nvim_win_call(S.wins.chat, function()
      if S.help or not S.current or S.qr then
        -- Help, splash and QR code read from the top.
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd("normal! zt")
      elseif follow then
        vim.api.nvim_win_set_cursor(0, { #lines, 0 })
        vim.cmd("normal! zb")
      end
    end)
  end
  M.update_hint()
end

-- Update the typing indicator. Appearing or disappearing re-renders the
-- chat; a frame change rewrites the indicator rows in place.
function M.render_typing(advance)
  if advance then
    typing_frame = typing_frame + 1
  end
  local buf = S.bufs.chat
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local trows = typing_rows(S.text_width("chat", 80))
  if trows == nil and typing_start == nil then
    return
  end
  if trows == nil or typing_start == nil then
    M.render()
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, typing_start, -1, false, trows)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, typing_start, -1)
  for i = typing_start, typing_start + #trows - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns, i, 0, { line_hl_group = "WhatsAppBubble" })
  end
end

return M
