local client = require("whatsapp.client")
local S = require("whatsapp.state")
local list = require("whatsapp.ui.list")
local chat = require("whatsapp.ui.chat")
local compose = require("whatsapp.ui.compose")
local display = require("whatsapp.text")

local M = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local defaults = {
  bin = nil, -- defaults to <plugin>/bin/wa-bridge
  store = vim.fn.stdpath("data") .. "/whatsapp",
  list_width = 32,
  unread_count = false, -- show how many messages are unread, left of the time
  compose_height = 3,
  page_size = 100,
  notify = true,
  mark_read_on_view = true,
  default_reaction = "👍",
  layout = "bubbles", -- or "lines"
  images = {
    mode = "auto", -- "auto" | "tag" | "kitty", see docs/configuration.md
    max_width = 60, -- cells; pictures fill the bubble up to this
    max_height = 20, -- rows, also capped at half the pane
    crop = true, -- centre-crop pictures taller than max_height rather than shrink them
  },
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
  -- Underlined like a link: the tag responds to keys.
  local special = vim.api.nvim_get_hl(0, { name = "Special", link = false })
  hl("WhatsAppMedia", { fg = special.fg, underline = true })
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
    line = display.fit(line, max - 1) .. "…"
  end
  pending.count, pending.names, pending.seen = 0, {}, {}
  vim.notify(line, vim.log.levels.INFO, { title = "WhatsApp" })
end

local function queue_notification(chat_name)
  chat_name = display.name(chat_name)
  pending.count = pending.count + 1
  if not pending.seen[chat_name] then
    pending.seen[chat_name] = true
    table.insert(pending.names, chat_name)
  end
  if not pending.timer then
    pending.timer = vim.defer_fn(flush_notifications, 300)
  end
end

-- Presence and typing -------------------------------------------------------

-- Online while a chat is open and the terminal is focused, like the phone
-- with a chat on screen. WhatsApp only sends typing notifications to
-- devices that are online.
local function set_presence(available)
  if S.available == available or not client.running() then
    return
  end
  S.available = available
  client.request("presence", { available = available }, function() end)
end

local typing_timer = nil

local function stop_typing()
  if typing_timer then
    typing_timer:stop()
    typing_timer:close()
    typing_timer = nil
  end
  S.typing = nil
  chat.render_typing(false)
end

local function start_typing(d)
  S.typing = { jid = d.chat, sender = d.sender, who = d.sender_name, media = d.media, since = vim.uv.now() }
  chat.render_typing(true)
  if not typing_timer then
    typing_timer = vim.uv.new_timer()
    typing_timer:start(0, 400, vim.schedule_wrap(function()
      -- WhatsApp sometimes never sends "paused"; drop a stale indicator.
      if not S.typing or vim.uv.now() - S.typing.since > 15000 then
        stop_typing()
        return
      end
      chat.render_typing(true)
    end))
  end
end

-- Bridge events ------------------------------------------------------------

local function wire_events()
  client.clear_listeners()
  client.on("ready", function(data)
    S.status = data
    chat.render()
  end)
  client.on("unpaired", function()
    S.status.paired = false
    chat.render()
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
    S.status.paired = false
    S.status.connected = false
    S.synced = false
    if d and d.reason == "user" then
      return
    end
    notify("logged out (" .. (d and d.reason or "?") .. "), run :WhatsApp pair", vim.log.levels.ERROR)
  end)
  client.on("pair.qr", function(d)
    S.pairing = false
    S.qr = d.lines
    if not S.layout_valid() then
      M.open()
    end
    chat.render()
  end)
  local function end_pairing()
    S.pairing = false
    S.qr = nil
    chat.render()
  end
  client.on("pair.ok", function()
    end_pairing()
    S.status.paired = true
    S.just_paired = true
    notify("paired, syncing history")
  end)
  client.on("pair.timeout", function()
    end_pairing()
    notify("pairing timed out, run :WhatsApp pair again", vim.log.levels.WARN)
  end)
  client.on("pair.error", function(d)
    end_pairing()
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
  client.on("typing", function(d)
    if d.chat ~= S.current then
      return
    end
    if d.state == "composing" then
      start_typing(d)
    else
      stop_typing()
    end
  end)
  client.on("message", function(d)
    local m = d.message
    if S.messages[m.chat_jid] then
      table.insert(S.messages[m.chat_jid], m)
    end
    if S.typing and S.typing.jid == m.chat_jid and S.typing.sender == m.sender then
      stop_typing()
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

-- Set the unread flag on a chat, mirrored to the phone like the app's
-- "Mark as unread". Marking the open chat unread also closes it, otherwise
-- the next incoming message would read it again.
function M.set_unread(jid, unread)
  local c = jid and S.chat_by_jid[jid]
  if not c then
    return
  end
  if not unread then
    c.unread = 0
    client.request("chat.read", { jid = jid })
  else
    c.unread = 1
    client.request("chat.unread", { jid = jid })
    if S.current == jid then
      S.current = nil
      stop_typing()
      set_presence(false)
      if S.win_valid("compose") then
        vim.api.nvim_win_close(S.wins.compose, true)
        S.wins.compose = nil
      end
      chat.render()
      compose.update_winbar()
      if S.win_valid("list") then
        vim.api.nvim_set_current_win(S.wins.list)
      end
    end
  end
  list.render()
end

function M.toggle_unread(jid)
  local c = jid and S.chat_by_jid[jid]
  if c then
    M.set_unread(jid, c.unread == 0)
  end
end

-- Cycle focus list, chat, compose (when open), like Tab in diffview or
-- lazygit. dir is 1 or -1.
function M.focus_next(dir)
  local order = {}
  for _, name in ipairs({ "list", "chat", "compose" }) do
    if S.win_valid(name) then
      order[#order + 1] = name
    end
  end
  if #order == 0 then
    return
  end
  local cur = vim.api.nvim_get_current_win()
  local idx = 0
  for i, name in ipairs(order) do
    if S.wins[name] == cur then
      idx = i
    end
  end
  local nxt = order[((idx - 1 + dir) % #order) + 1]
  vim.api.nvim_set_current_win(S.wins[nxt])
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
      -- The splash quotes chat and unread counts, so it is stale until the
      -- first list arrives.
      if not S.current then
        chat.render()
      end
    end
  end)
end

function M.open_chat(jid)
  if not jid then
    return
  end
  S.view = nil
  if S.current ~= jid then
    stop_typing()
  end
  S.current = jid
  set_presence(true)
  M.ensure_compose()
  -- Drop the previous chat's view immediately, even if loading this one is slow.
  chat.render()
  list.render()
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

function M.send_compose(jid)
  jid = jid or S.current
  if not jid then
    notify("no chat open", vim.log.levels.WARN)
    return
  end
  local draft = compose.draft(jid)
  if draft.sending then
    notify("this draft is already sending", vim.log.levels.WARN)
    return
  end
  local text = compose.text(jid)
  local buf = draft.buf
  if text == "" then
    vim.bo[buf].modified = false
    return
  end
  local params = { jid = jid, text = text }
  local reply = draft.reply_to
  if reply then
    params.reply_to = reply.id
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  draft.sending = true
  client.request("message.send", params, function(err, sent)
    draft.sending = false
    if err then
      notify("send failed: " .. err, vim.log.levels.ERROR)
      return
    end
    -- Clear only the draft that was sent, and only if it has not been edited
    -- while awaiting the response. Other chats have independent buffers.
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_changedtick(buf) == tick then
      compose.clear(jid)
      if draft.reply_to == reply then draft.reply_to = nil end
    end
    if S.current == jid then compose.update_winbar() end
    if S.messages[sent.chat_jid] then
      table.insert(S.messages[sent.chat_jid], sent)
    end
    chat.render()
    M.refresh_chats()
  end)
end

function M.reply_to(m)
  if not m or not S.current or m.chat_jid ~= S.current then
    return
  end
  compose.draft().reply_to = m
  compose.update_winbar()
  M.focus_compose()
end

function M.cancel_reply()
  local draft = compose.draft()
  if draft then draft.reply_to = nil end
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

local function fetch_media(m, then_do)
  if not m or not m.media_type or m.media_type == "" then
    return
  end
  notify((m.cached and "fetching " or "downloading ") .. m.media_type .. "…")
  client.request("media.download", { jid = m.chat_jid, id = m.id }, function(err, res)
    if err then
      notify("download failed: " .. err, vim.log.levels.ERROR)
      return
    end
    notify("saved to " .. res.path)
    m.path = res.path
    if not m.cached then
      m.cached = true
      if S.current == m.chat_jid then
        chat.render()
      end
    end
    if then_do then
      then_do(res.path)
    end
  end)
end

local function confirm_open(path)
  local choice = vim.fn.confirm("Open attachment in its default application?\n" .. path, "&Open\n&Cancel", 2)
  if choice == 1 then
    vim.ui.open(path)
  end
end

local function copy_path(path)
  vim.fn.setreg("+", path)
  vim.fn.setreg('"', path)
  notify("copied " .. path)
end

function M.download_media(m)
  fetch_media(m)
end

function M.open_media(m)
  if not m then
    return
  end
  if m.path then
    confirm_open(m.path)
  else
    fetch_media(m, confirm_open)
  end
end

-- Zoom: the picture takes over the chat pane, like help does, so nothing
-- is drawn twice. q, <Esc> or <CR> bring the conversation back.
function M.view_image(m)
  if not (m and m.path) or not S.win_valid("chat") then
    return
  end
  S.help = false
  S.view = m
  vim.api.nvim_set_current_win(S.wins.chat)
  chat.render()
end

function M.close_view()
  local m = S.view
  S.view = nil
  chat.render()
  local images = require("whatsapp.ui.images")
  images.release_full(m)
  images.repaint()
end

-- g? from any pane: the cheatsheet takes over the chat pane and focus
-- moves there so q closes it; closing returns focus to where you were.
function M.toggle_help()
  if S.help then
    S.help = false
    chat.render()
    if S.help_return and vim.api.nvim_win_is_valid(S.help_return) then
      vim.api.nvim_set_current_win(S.help_return)
    end
    S.help_return = nil
    require("whatsapp.ui.images").repaint()
    return
  end
  if not S.win_valid("chat") then
    return
  end
  S.help_return = vim.api.nvim_get_current_win()
  S.help = true
  S.view = nil
  vim.api.nvim_set_current_win(S.wins.chat)
  chat.render()
end

-- ]m / [m from any pane: focus the chat and move to the attachment. The
-- compose pane counts as the slot after the last one, so ]m past the end
-- returns you to writing and [m from compose lands on the newest media.
function M.next_media(dir)
  if not S.win_valid("chat") then
    return
  end
  local from_compose = S.win_valid("compose") and vim.api.nvim_get_current_win() == S.wins.compose
  vim.api.nvim_set_current_win(S.wins.chat)
  if chat.next_media(dir, from_compose) then
    return
  end
  if dir > 0 and S.win_valid("compose") then
    vim.api.nvim_set_current_win(S.wins.compose)
    if not from_compose then
      return
    end
  end
  notify("no more media")
end

-- <CR> on media: one menu, so the only thing to learn is that <CR> acts on
-- the attachment. The target is the media under the cursor, else the
-- newest in the chat.
function M.media_menu(m)
  if not m then
    return
  end
  local items = {}
  local images = require("whatsapp.ui.images")
  -- Zoom first, so <CR><CR> on a picture is the quick look.
  if m.media_type == "image" and images.mode() == "kitty" then
    items[#items + 1] = { "View", function()
      if m.path then
        M.view_image(m)
      else
        fetch_media(m, function() M.view_image(m) end)
      end
    end }
  end
  if not m.cached then
    items[#items + 1] = { "Download", function() fetch_media(m) end }
  end
  items[#items + 1] = { "Open  gx", function() M.open_media(m) end }
  items[#items + 1] = { "Copy path", function()
    if m.path then
      copy_path(m.path)
    else
      fetch_media(m, copy_path)
    end
  end }
  -- Navigation lives in the menu too, so the first <CR> teaches ]m [m.
  if chat.media_count() > 1 then
    items[#items + 1] = { "Next media  ]m", function() M.next_media(1) end }
    items[#items + 1] = { "Previous media  [m", function() M.next_media(-1) end }
  end
  vim.ui.select(items, {
    prompt = (m.media_type or "media") .. (m.filename and m.filename ~= "" and (" " .. m.filename) or ""),
    format_item = function(item) return item[1] end,
  }, function(item)
    if item then
      item[2]()
    end
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
  -- A wrapped QR code cannot be scanned; let it run off the edge instead.
  if name == "chat" and S.qr then
    vim.wo[S.wins.chat].wrap = false
  end
end

-- The compose pane only exists once a chat is open; nothing to write to
-- before that.
function M.ensure_compose()
  if not S.current or not S.win_valid("chat") then
    return
  end
  local buf = compose.ensure_buf()
  S.bufs.compose = buf
  if S.win_valid("compose") then
    vim.api.nvim_win_set_buf(S.wins.compose, buf)
  else
    S.wins.compose = vim.api.nvim_open_win(buf, false, {
      split = "below",
      win = S.wins.chat,
      height = S.opts.compose_height,
    })
  end
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
    callback = function(ev)
      local w = vim.api.nvim_get_current_win()
      for name, win in pairs(S.wins) do
        if win == w then
          apply_win_opts(name)
        end
      end
      if ev.event == "FocusLost" then
        set_presence(false)
      elseif ev.event == "FocusGained" and S.current and S.layout_valid() then
        set_presence(true)
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
  M.ensure_compose()
end

function M.open()
  if not client.running() then
    wire_events()
    -- Fresh bridge, fresh status: a stale "connected" would skip the
    -- connecting splash.
    S.status = { paired = nil, connected = false }
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
  S.help = false
  S.help_return = nil
  S.view = nil
  require("whatsapp.ui.images").reset()
  stop_typing()
  set_presence(false)
  if S.layout_valid() then
    pcall(vim.api.nvim_set_current_tabpage, S.tab)
    pcall(vim.cmd, "tabclose")
  end
  S.reset_layout()
end

function M.stop()
  M.close()
  S.available = false
  client.stop()
  notify("bridge stopped")
end

-- The QR code renders in the chat pane, so pairing opens the view first.
function M.pair()
  M.open()
  if not client.running() then
    return
  end
  S.pairing = true
  chat.render()
  client.request("pair.start", nil, function(err)
    if err then
      S.pairing = false
      chat.render()
      notify(err, vim.log.levels.WARN)
    end
  end)
end

-- Unlink this device from the phone and forget the local session. Stops the
-- bridge so the next :WhatsApp pair starts with a clean device store.
function M.logout()
  if not client.running() then
    notify("bridge not running")
    return
  end
  client.request("logout", nil, function(err)
    M.close()
    client.stop()
    if err then
      notify(err, vim.log.levels.WARN)
    end
    notify("logged out, run :WhatsApp pair to link again")
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
