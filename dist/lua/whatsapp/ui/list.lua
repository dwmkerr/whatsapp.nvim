local S = require("whatsapp.state")
local format = require("whatsapp.format")

local M = {}
local ns = vim.api.nvim_create_namespace("whatsapp_list")
local line_jids = {}
-- The row of the Archived entry, and the first chat row below the header
-- lines. Both move as the Archived entry comes and goes.
local archived_row, first_row = nil, 2

-- Filters in the order f cycles them, matching the chips on the phone.
-- Archived is not one of them: the phone keeps archived chats behind a row
-- at the top of the list, and S.filter == "archived" is that opened view.
local filters = {
  { id = "all", label = "All", empty = "no chats yet" },
  { id = "unread", label = "Unread", empty = "no unread chats" },
  { id = "groups", label = "Groups", empty = "no groups" },
}

local function filter_index()
  for i, f in ipairs(filters) do
    if f.id == S.filter then
      return i
    end
  end
  return 1
end

local function keep_chat(c)
  -- Archived chats only show in their own view, as on the phone, so the
  -- chats the user put away never crowd the others.
  if S.filter == "archived" then
    return c.archived == true
  elseif c.archived then
    return false
  elseif S.filter == "unread" then
    -- Opening a chat reads it. Keep the open one listed, as the phone does,
    -- so the row just picked does not vanish from under the cursor.
    return c.unread > 0 or c.jid == S.current
  elseif S.filter == "groups" then
    return c.is_group == true
  end
  return true
end

-- Chats the current filter lets through, in list order.
function M.visible_chats()
  local out = {}
  for _, c in ipairs(S.chats) do
    if keep_chat(c) then
      out[#out + 1] = c
    end
  end
  return out
end

local function set_filter(id)
  S.filter = id
  M.render()
  -- The old cursor row rarely means anything under a new filter; start at
  -- the first chat so <CR> does something useful straight away.
  if S.win_valid("list") then
    vim.api.nvim_win_set_cursor(S.wins.list, { math.min(first_row, vim.api.nvim_buf_line_count(S.bufs.list)), 0 })
  end
end

function M.cycle_filter()
  if S.filter == "archived" then
    set_filter("all")
  else
    set_filter(filters[filter_index() % #filters + 1].id)
  end
end

function M.open_archived()
  set_filter("archived")
end

-- Returns false outside the archived view, so q can fall back to closing.
function M.close_archived()
  if S.filter ~= "archived" then
    return false
  end
  set_filter("all")
  return true
end

local function cursor_row()
  return vim.api.nvim_win_get_cursor(S.wins.list)[1]
end

-- <CR> and l act on whatever the row is: a chat, the Archived entry, or
-- the header line.
local function activate(wa)
  local row = cursor_row()
  if row == archived_row then
    M.open_archived()
  elseif row == 1 and not M.close_archived() then
    M.cycle_filter()
  elseif row > 1 then
    wa.open_chat(M.jid_under_cursor())
  end
end

function M.ensure_buf()
  if S.bufs.list and vim.api.nvim_buf_is_valid(S.bufs.list) then
    return S.bufs.list
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "wa://chats")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "whatsapp-chats"
  vim.bo[buf].modifiable = false
  S.bufs.list = buf

  local wa = require("whatsapp")
  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("<CR>", function() activate(wa) end, "Open chat or archived chats, or cycle the filter")
  map("f", M.cycle_filter, "Filter: all / unread / groups")
  map("l", function()
    if cursor_row() == archived_row then
      M.open_archived()
    else
      wa.open_chat(M.jid_under_cursor())
    end
  end, "Open chat")
  map("<BS>", M.close_archived, "Leave archived chats")
  map("i", function()
    wa.open_chat(M.jid_under_cursor())
    wa.focus_compose()
  end, "Open chat and compose")
  map("u", M.next_unread, "Next unread chat")
  map("~", function() wa.toggle_unread(M.jid_under_cursor()) end, "Toggle unread")
  map("gU", function() wa.set_unread(M.jid_under_cursor(), true) end, "Mark unread")
  map("gu", function() wa.set_unread(M.jid_under_cursor(), false) end, "Mark read")
  map("<Tab>", function() wa.focus_next(1) end, "Next pane")
  map("<S-Tab>", function() wa.focus_next(-1) end, "Previous pane")
  -- Chat-pane keys that do not clash with list keys work from here too,
  -- so focus never decides whether a shortcut exists.
  map("gx", function() wa.open_media(require("whatsapp.ui.chat").media_target()) end, "Open media in the open chat")
  map("]m", function() wa.next_media(1) end, "Next media in the open chat")
  map("[m", function() wa.next_media(-1) end, "Previous media in the open chat")
  map("K", wa.load_older, "Load older messages in the open chat")
  map("L", function() require("whatsapp.ui.chat").toggle_layout() end, "Toggle bubbles / lines")
  map("q", function()
    if not M.close_archived() then
      wa.close()
    end
  end, "Leave archived chats, or close WhatsApp")
  map("g?", wa.toggle_help, "All keys")
  return buf
end

function M.jid_under_cursor()
  if not S.win_valid("list") then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(S.wins.list)[1]
  return line_jids[row] or nil
end

-- The winbar alone, so sync progress can tick without redrawing the rows.
function M.update_bar()
  if not S.win_valid("list") then
    return
  end
  local bar = " WhatsApp"
  local p = S.sync_percent()
  if p then
    -- Replaces the title so the bar fits the default 32-column list; with
    -- the title as well it overflowed and Neovim cut it from the left.
    -- The winbar is a statusline format, where a bare % starts an item.
    bar = " Syncing " .. p .. "%%"
  else
    local n = 0
    for _, c in ipairs(S.inbox()) do
      if c.unread > 0 then
        n = n + 1
      end
    end
    if n > 0 then
      bar = bar .. " · " .. n .. " unread"
    end
  end
  vim.wo[S.wins.list].winbar = bar .. " · g? help"
end

function M.render()
  if not S.visible() then
    S.stale.list = true
    return
  end
  S.stale.list = nil
  local buf = M.ensure_buf()
  local width = S.text_width("list", S.opts.list_width)
  local chats = M.visible_chats()
  local lines, jids, unread = format.chat_list(chats, width, S.opts.unread_count)

  -- Row 1 is the filter line, or the way back out of the archived view.
  -- The key leads in Special like every other hint; the active chip is bold
  -- rather than coloured so it never reads as a key.
  local header, spans, col, empty
  if S.filter == "archived" then
    header = "q ← Archived"
    spans = { { 0, 1, "Special" }, { 2, #header, "WhatsAppFilter" } }
    empty = "no archived chats"
  else
    header, spans, col = "f ", { { 0, 1, "Special" } }, 2
    for i, f in ipairs(filters) do
      if i > 1 then
        header = header .. "  "
        col = col + 2
      end
      spans[#spans + 1] = { col, col + #f.label, f.id == S.filter and "WhatsAppFilter" or "Comment" }
      header = header .. f.label
      col = col + #f.label
    end
    empty = filters[filter_index()].empty
  end
  table.insert(lines, 1, header)
  table.insert(jids, 1, false)
  table.insert(unread, 1, false)

  -- Under All the archived chats sit behind one row at the top, as on the
  -- phone. It never looks unread: archived chats stay quiet until opened.
  local was_archived_row = archived_row
  archived_row = nil
  local archived = 0
  for _, c in ipairs(S.chats) do
    if c.archived then
      archived = archived + 1
    end
  end
  if S.filter == "all" and archived > 0 then
    local count = tostring(archived)
    table.insert(lines, 2, "  " .. string.format("%-" .. math.max(4, width - 3 - #count) .. "s", "Archived") .. " " .. count)
    table.insert(jids, 2, false)
    table.insert(unread, 2, false)
    archived_row = 2
  end
  first_row = (archived_row or 1) + 1
  if #chats == 0 then
    lines[first_row] = "  " .. empty
  end

  M.update_bar()
  -- Read the cursor's chat before line_jids changes; afterwards the same row
  -- names whichever chat moved into it.
  -- Someone who moved onto the Archived row keeps it; jumping back to the
  -- open chat on every redraw would make it hard to reach.
  local on_archived = S.win_valid("list") and was_archived_row ~= nil and cursor_row() == was_archived_row
  local keep = M.jid_under_cursor() or (not on_archived and S.current)
  line_jids = jids

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, sp in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, ns, 0, sp[1], { end_col = sp[2], hl_group = sp[3] })
  end
  if archived_row then
    vim.api.nvim_buf_set_extmark(buf, ns, archived_row - 1, 0, { line_hl_group = "Comment" })
  end
  if #chats == 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, first_row - 1, 0, { line_hl_group = "Comment" })
  end
  for i, jid in ipairs(jids) do
    if unread[i] then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = "WhatsAppUnread" })
    elseif jid == S.current then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = "WhatsAppCurrent" })
    end
  end

  if keep and S.win_valid("list") then
    for i, jid in ipairs(jids) do
      if jid == keep then
        vim.api.nvim_win_set_cursor(S.wins.list, { i, 0 })
        break
      end
    end
  elseif S.win_valid("list") and #chats > 0 and cursor_row() == 1 then
    -- A fresh window opens on row 1, which would hide the f under the
    -- cursor and make <CR> cycle the filter instead of opening a chat.
    vim.api.nvim_win_set_cursor(S.wins.list, { first_row, 0 })
  end
end

function M.next_unread()
  if not S.win_valid("list") then
    return
  end
  -- Walk the visible rows after the cursor, wrapping past the filter line.
  local row = vim.api.nvim_win_get_cursor(S.wins.list)[1]
  local n = #line_jids
  for step = 1, n do
    local i = ((row - 1 + step) % n) + 1
    local c = line_jids[i] and S.chat_by_jid[line_jids[i]]
    if c and c.unread > 0 then
      vim.api.nvim_win_set_cursor(S.wins.list, { i, 0 })
      require("whatsapp").open_chat(c.jid)
      return
    end
  end
  vim.notify("WhatsApp: no unread chats", vim.log.levels.INFO)
end

return M
