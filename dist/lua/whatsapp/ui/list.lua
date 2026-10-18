local S = require("whatsapp.state")
local format = require("whatsapp.format")

local M = {}
local ns = vim.api.nvim_create_namespace("whatsapp_list")
local line_jids = {}

-- Filters in the order f cycles them, matching the chips on the phone.
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
  if S.filter == "unread" then
    return c.unread > 0
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

function M.cycle_filter()
  S.filter = filters[filter_index() % #filters + 1].id
  M.render()
  -- The old cursor row rarely means anything under a new filter; start at
  -- the first chat so <CR> does something useful straight away.
  if S.win_valid("list") then
    vim.api.nvim_win_set_cursor(S.wins.list, { math.min(2, vim.api.nvim_buf_line_count(S.bufs.list)), 0 })
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
  map("<CR>", function()
    if vim.api.nvim_win_get_cursor(0)[1] == 1 then
      M.cycle_filter()
    else
      wa.open_chat(M.jid_under_cursor())
    end
  end, "Open chat, or cycle the filter")
  map("f", M.cycle_filter, "Filter: all / unread / groups")
  map("l", function() wa.open_chat(M.jid_under_cursor()) end, "Open chat")
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
  map("R", wa.refresh_names, "Refresh chats and contact names")
  -- Chat-pane keys that do not clash with list keys work from here too,
  -- so focus never decides whether a shortcut exists.
  map("gx", function() wa.open_media(require("whatsapp.ui.chat").media_target()) end, "Open media in the open chat")
  map("]m", function() wa.next_media(1) end, "Next media in the open chat")
  map("[m", function() wa.next_media(-1) end, "Previous media in the open chat")
  map("K", wa.load_older, "Load older messages in the open chat")
  map("L", function() require("whatsapp.ui.chat").toggle_layout() end, "Toggle bubbles / lines")
  map("q", wa.close, "Close WhatsApp")
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

function M.render()
  local buf = M.ensure_buf()
  local width = S.text_width("list", S.opts.list_width)
  local chats = M.visible_chats()
  local lines, jids, unread = format.chat_list(chats, width)

  -- Row 1 is the filter line, so every chat row sits one below its index.
  -- Two leading spaces line the labels up with chat names after the mark.
  local header, spans, col = "  ", {}, 2
  for i, f in ipairs(filters) do
    if i > 1 then
      header = header .. "  "
      col = col + 2
    end
    spans[#spans + 1] = { col, col + #f.label, f.id == S.filter and "Special" or "Comment" }
    header = header .. f.label
    col = col + #f.label
  end
  table.insert(lines, 1, header)
  table.insert(jids, 1, false)
  table.insert(unread, 1, false)
  if #chats == 0 then
    lines[2] = "  " .. filters[filter_index()].empty
  end

  if S.win_valid("list") then
    local n = 0
    for _, c in ipairs(S.chats) do
      if c.unread > 0 then
        n = n + 1
      end
    end
    local bar = " WhatsApp"
    if n > 0 then
      bar = bar .. " · " .. n .. " unread"
    end
    vim.wo[S.wins.list].winbar = bar .. " · g? help"
  end
  line_jids = jids
  local keep = M.jid_under_cursor() or S.current

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, sp in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, ns, 0, sp[1], { end_col = sp[2], hl_group = sp[3] })
  end
  if #chats == 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { line_hl_group = "Comment" })
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
