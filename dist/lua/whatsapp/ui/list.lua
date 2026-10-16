local S = require("whatsapp.state")
local format = require("whatsapp.format")

local M = {}
local ns = vim.api.nvim_create_namespace("whatsapp_list")
local line_jids = {}

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
  map("<CR>", function() wa.open_chat(M.jid_under_cursor()) end, "Open chat")
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
  map("q", wa.close, "Close WhatsApp")
  map("g?", function() require("whatsapp.ui.help").show("list") end, "Keys")
  return buf
end

function M.jid_under_cursor()
  if not S.win_valid("list") then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(S.wins.list)[1]
  return line_jids[row]
end

function M.render()
  local buf = M.ensure_buf()
  local width = S.text_width("list", S.opts.list_width)
  local lines, jids, unread = format.chat_list(S.chats, width)
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
  local row = vim.api.nvim_win_get_cursor(S.wins.list)[1]
  local n = #S.chats
  for step = 1, n do
    local i = ((row - 1 + step) % n) + 1
    if S.chats[i].unread > 0 then
      vim.api.nvim_win_set_cursor(S.wins.list, { i, 0 })
      require("whatsapp").open_chat(S.chats[i].jid)
      return
    end
  end
  vim.notify("WhatsApp: no unread chats", vim.log.levels.INFO)
end

return M
