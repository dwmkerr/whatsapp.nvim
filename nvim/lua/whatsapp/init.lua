local client = require("whatsapp.client")
local S = require("whatsapp.state")
local list = require("whatsapp.ui.list")
local chat = require("whatsapp.ui.chat")
local compose = require("whatsapp.ui.compose")
local pair = require("whatsapp.ui.pair")

local M = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local defaults = {
  bin = nil, -- defaults to <plugin>/bin/wa-bridge
  store = vim.fn.stdpath("data") .. "/whatsapp",
  list_width = 32,
  compose_height = 3,
  page_size = 100,
  notify = true,
  mark_read_on_view = true,
  default_reaction = "👍",
  layout = "bubbles", -- or "lines"
}

local function define_highlights()
  local hl = function(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end
  hl("WhatsAppUnread", { bold = true })
  hl("WhatsAppCurrent", { link = "Visual" })
  hl("WhatsAppTime", { link = "Comment" })
  hl("WhatsAppSender", { link = "Identifier" })
  hl("WhatsAppMe", { link = "String" })
  hl("WhatsAppMedia", { link = "Special" })
  hl("WhatsAppSeparator", { link = "Comment" })
  hl("WhatsAppQuote", { link = "Comment" })
  hl("WhatsAppBubble", { link = "Normal" })
  hl("WhatsAppBubbleMe", { link = "DiffAdd" })
end

local function notify(msg, level)
  vim.notify("WhatsApp: " .. msg, level or vim.log.levels.INFO)
end

-- Incoming-message notifications are coalesced into one line: several
-- echoes in one redraw would stack into a hit-enter prompt.
local pending = { count = 0, names = {}, seen = {}, timer = nil }

local function flush_notifications()
  pending.timer = nil
  local line = "WhatsApp ● " .. pending.count .. " new · " .. table.concat(pending.names, ", ")
  local max = math.max(20, vim.o.columns - 12)
  if vim.fn.strdisplaywidth(line) > max then
    line = vim.fn.strcharpart(line, 0, max - 1) .. "…"
  end
  pending.count, pending.names, pending.seen = 0, {}, {}
  vim.notify(line, vim.log.levels.INFO, { title = "WhatsApp" })
end

local function queue_notification(chat_name)
  pending.count = pending.count + 1
  if not pending.seen[chat_name] then
    pending.seen[chat_name] = true
    table.insert(pending.names, chat_name)
  end
  if not pending.timer then
    pending.timer = vim.defer_fn(flush_notifications, 300)
  end
end

-- Bridge events ------------------------------------------------------------

local function wire_events()
  client.clear_listeners()
  client.on("ready", function(data)
    S.status = data
  end)
  client.on("unpaired", function()
    notify("not paired yet, run :WhatsApp pair", vim.log.levels.WARN)
  end)
  client.on("connected", function()
    S.status.connected = true
    chat.render()
    M.refresh_chats()
    -- Contacts may have synced after history on a previous run.
    client.request("names.refresh", nil, function() end)
  end)
  client.on("disconnected", function()
    S.status.connected = false
    chat.render()
  end)
  client.on("logged_out", function(d)
    notify("logged out (" .. (d and d.reason or "?") .. "), run :WhatsApp pair", vim.log.levels.ERROR)
  end)
  client.on("pair.qr", function(d)
    pair.show(d.lines)
  end)
  client.on("pair.ok", function()
    pair.close()
    S.status.paired = true
    S.just_paired = true
    notify("paired, syncing history")
  end)
  client.on("pair.timeout", function()
    pair.close()
    notify("pairing timed out, run :WhatsApp pair again", vim.log.levels.WARN)
  end)
  client.on("pair.error", function(d)
    pair.close()
    notify("pairing failed: " .. d.error, vim.log.levels.ERROR)
  end)
  client.on("sync.progress", function(d)
    S.sync = d
    if not S.current then
      chat.render()
    end
  end)
  client.on("sync.done", function()
    S.synced = true
    S.sync = nil
    if S.just_paired then
      S.just_paired = false
      notify("history synced")
    end
    chat.render()
  end)
  client.on("chats.changed", function()
    M.refresh_chats()
  end)
  client.on("message", function(d)
    local m = d.message
    if S.messages[m.chat_jid] then
      table.insert(S.messages[m.chat_jid], m)
    end
    local visible = S.current == m.chat_jid
      and S.layout_valid()
      and vim.api.nvim_get_current_tabpage() == S.tab
    if visible then
      chat.render()
      if S.opts.mark_read_on_view and not m.from_me then
        client.request("chat.read", { jid = m.chat_jid })
      end
    elseif S.opts.notify and S.synced and not m.from_me then
      -- Messages replayed at startup are already marked unread in the list.
      queue_notification(d.chat_name)
    end
    M.refresh_chats()
  end)
  client.on("fatal", function(d)
    notify("bridge failed: " .. d.error, vim.log.levels.ERROR)
  end)
  client.on("exit", function(d)
    if d.code ~= 0 then
      notify("bridge exited with code " .. d.code .. "\n" .. table.concat(d.stderr, "\n"), vim.log.levels.ERROR)
    end
    chat.render()
  end)
end

-- Data ---------------------------------------------------------------------

function M.refresh_names()
  client.request("names.refresh", nil, function(err, res)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    notify("renamed " .. res.renamed .. " chats")
    M.refresh_chats()
    if S.current then
      M.open_chat(S.current)
    end
  end)
end

-- Flip the unread flag on a chat, mirrored to the phone like the app's
-- "Mark as unread". Marking the open chat unread also closes it, otherwise
-- the next incoming message would read it again.
function M.toggle_unread(jid)
  local c = jid and S.chat_by_jid[jid]
  if not c then
    return
  end
  if c.unread > 0 then
    c.unread = 0
    client.request("chat.read", { jid = jid })
  else
    c.unread = 1
    client.request("chat.unread", { jid = jid })
    if S.current == jid then
      S.current = nil
      S.reply_to = nil
      chat.render()
      compose.update_winbar()
      if S.win_valid("list") then
        vim.api.nvim_set_current_win(S.wins.list)
      end
    end
  end
  list.render()
end

function M.refresh_chats()
  client.request("chats.list", nil, function(err, chats)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    S.set_chats(chats)
    if S.layout_valid() then
      list.render()
    end
  end)
end

function M.open_chat(jid)
  if not jid then
    return
  end
  S.current = jid
  S.reply_to = nil
  M.ensure_compose()
  client.request("messages.list", { jid = jid, limit = S.opts.page_size }, function(err, msgs)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    -- A live message can land while this request is in flight; keep any
    -- the snapshot does not already contain.
    local seen = {}
    for _, m in ipairs(msgs) do
      seen[m.id] = true
    end
    for _, m in ipairs(S.messages[jid] or {}) do
      if not seen[m.id] and m.ts >= (msgs[#msgs] and msgs[#msgs].ts or 0) then
        table.insert(msgs, m)
      end
    end
    S.messages[jid] = msgs
    if S.current == jid then
      chat.render()
      list.render()
      compose.update_winbar()
    end
  end)
  local c = S.chat_by_jid[jid]
  if S.opts.mark_read_on_view and c and c.unread > 0 then
    c.unread = 0
    client.request("chat.read", { jid = jid })
  end
end

function M.load_older()
  local jid = S.current
  local msgs = jid and S.messages[jid]
  if not msgs or #msgs == 0 then
    return
  end
  client.request("messages.list", { jid = jid, limit = S.opts.page_size, before = msgs[1].ts }, function(err, older)
    if err or not older or #older == 0 then
      notify("no older messages")
      return
    end
    for i = #older, 1, -1 do
      table.insert(msgs, 1, older[i])
    end
    local before = vim.api.nvim_buf_line_count(S.bufs.chat)
    chat.render()
    if S.win_valid("chat") then
      local after = vim.api.nvim_buf_line_count(S.bufs.chat)
      vim.api.nvim_win_set_cursor(S.wins.chat, { math.max(1, after - before), 0 })
    end
  end)
end

-- Actions ------------------------------------------------------------------

function M.send_compose()
  if not S.current then
    notify("no chat open", vim.log.levels.WARN)
    return
  end
  local text = compose.text()
  if text == "" then
    vim.bo[S.bufs.compose].modified = false
    return
  end
  local params = { jid = S.current, text = text }
  if S.reply_to then
    params.reply_to = S.reply_to.id
  end
  client.request("message.send", params, function(err, sent)
    if err then
      notify("send failed: " .. err, vim.log.levels.ERROR)
      return
    end
    compose.clear()
    S.reply_to = nil
    compose.update_winbar()
    if S.messages[sent.chat_jid] then
      table.insert(S.messages[sent.chat_jid], sent)
    end
    chat.render()
    M.refresh_chats()
  end)
end

function M.reply_to(m)
  if not m then
    return
  end
  S.reply_to = m
  compose.update_winbar()
  M.focus_compose()
end

function M.cancel_reply()
  S.reply_to = nil
  compose.update_winbar()
end

function M.react_to(m)
  if not m then
    return
  end
  vim.ui.input({ prompt = "Reaction (empty = " .. S.opts.default_reaction .. "): " }, function(emoji)
    if emoji == nil then
      return
    end
    if emoji == "" then
      emoji = S.opts.default_reaction
    end
    client.request("message.react", { jid = m.chat_jid, id = m.id, emoji = emoji }, function(err)
      if err then
        notify("reaction failed: " .. err, vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.open_media(m)
  if not m or not m.media_type or m.media_type == "" then
    return
  end
  notify("downloading " .. m.media_type .. "…")
  client.request("media.download", { jid = m.chat_jid, id = m.id }, function(err, res)
    if err then
      notify("download failed: " .. err, vim.log.levels.ERROR)
      return
    end
    -- Documents carry a sender-chosen name; images and friends are stored
    -- under a known extension, so only documents need a look before opening.
    if m.media_type == "document" then
      local choice = vim.fn.confirm("Open " .. res.path .. "?", "&Open\n&Cancel", 2)
      if choice ~= 1 then
        notify("saved to " .. res.path)
        return
      end
    end
    vim.ui.open(res.path)
  end)
end

function M.focus_compose()
  M.ensure_compose()
  if not S.win_valid("compose") then
    return
  end
  vim.api.nvim_set_current_win(S.wins.compose)
  vim.cmd("startinsert")
end

-- Layout -------------------------------------------------------------------

-- Window-local options for each pane. Applied when the pane is created and
-- again after the events user configs commonly hook to toggle number
-- options (window switch, insert mode, terminal focus). Plugin autocmds are
-- defined after the user's, so they run last and win.
local common = { number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0" }
local WIN_OPTS = {
  list = vim.tbl_extend("force", common, { cursorline = true, wrap = false, winfixwidth = true }),
  chat = vim.tbl_extend("force", common, { wrap = true, linebreak = true, cursorline = false }),
  compose = vim.tbl_extend("force", common, { winfixheight = true }),
}

local function apply_win_opts(name)
  if not S.win_valid(name) then
    return
  end
  for k, v in pairs(WIN_OPTS[name]) do
    vim.wo[S.wins[name]][k] = v
  end
end

-- The compose pane only exists once a chat is open; nothing to write to
-- before that.
function M.ensure_compose()
  if S.win_valid("compose") or not S.win_valid("chat") then
    return
  end
  S.wins.compose = vim.api.nvim_open_win(compose.ensure_buf(), false, {
    split = "below",
    win = S.wins.chat,
    height = S.opts.compose_height,
  })
  apply_win_opts("compose")
  compose.update_winbar()
end

local function build_layout()
  vim.cmd("tabnew")
  S.tab = vim.api.nvim_get_current_tabpage()
  S.wins.chat = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(S.wins.chat, chat.ensure_buf())
  apply_win_opts("chat")

  vim.cmd("topleft " .. S.opts.list_width .. "vsplit")
  S.wins.list = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(S.wins.list, list.ensure_buf())
  apply_win_opts("list")

  vim.api.nvim_create_autocmd({ "WinEnter", "InsertEnter", "InsertLeave", "FocusGained", "FocusLost" }, {
    callback = function()
      local w = vim.api.nvim_get_current_win()
      for name, win in pairs(S.wins) do
        if win == w then
          apply_win_opts(name)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    callback = function()
      if S.layout_valid() then
        chat.render()
        list.render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    once = true,
    callback = function()
      if not S.layout_valid() then
        S.reset_layout()
      end
    end,
  })
  list.render()
  chat.render()
end

function M.open()
  if not client.running() then
    wire_events()
    S.synced = false
    S.sync = nil
    if not client.start(S.opts.bin, S.opts.store) then
      return
    end
  end
  if S.layout_valid() then
    vim.api.nvim_set_current_tabpage(S.tab)
  else
    build_layout()
  end
  M.refresh_chats()
end

function M.toggle()
  if S.layout_valid() and vim.api.nvim_get_current_tabpage() == S.tab then
    M.close()
  else
    M.open()
  end
end

function M.close()
  if S.layout_valid() then
    pcall(vim.api.nvim_set_current_tabpage, S.tab)
    pcall(vim.cmd, "tabclose")
  end
  S.reset_layout()
end

function M.stop()
  M.close()
  client.stop()
  notify("bridge stopped")
end

function M.pair()
  if not client.running() then
    wire_events()
    if not client.start(S.opts.bin, S.opts.store) then
      return
    end
  end
  client.request("pair.start", nil, function(err)
    if err then
      notify(err, vim.log.levels.WARN)
    else
      notify("waiting for QR code…")
    end
  end)
end

function M.status()
  if not client.running() then
    notify("bridge not running")
    return
  end
  client.request("status", nil, function(err, st)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    notify(vim.inspect(st))
  end)
end

function M.open_by_name(name)
  M.open()
  local needle = name:lower()
  local function try()
    for _, c in ipairs(S.chats) do
      if c.name:lower():find(needle, 1, true) then
        M.open_chat(c.jid)
        return true
      end
    end
    return false
  end
  if not try() then
    client.request("chats.list", nil, function(_, chats)
      if chats then
        S.set_chats(chats)
        list.render()
        if not try() then
          notify("no chat matching " .. name, vim.log.levels.WARN)
        end
      end
    end)
  end
end

function M.setup(opts)
  S.opts = vim.tbl_deep_extend("force", defaults, opts or {})
  S.opts.bin = S.opts.bin or (plugin_root() .. "/bin/wa-bridge")
  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })
  vim.api.nvim_create_autocmd("VimLeavePre", { callback = client.stop })
end

return M
