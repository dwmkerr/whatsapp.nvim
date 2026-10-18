-- Headless smoke test: drives the plugin against test/fake-bridge.sh and
-- asserts on buffer contents. Exits non-zero on the first failure.
local root = vim.g.whatsapp_test_root
local failures = 0

local function check(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. msg .. "\n")
  else
    io.stderr:write("ok: " .. msg .. "\n")
  end
end

local function wait_for(pred, ms)
  return vim.wait(ms or 2000, pred, 20)
end

return function()
  -- format.lua is pure, test it directly.
  local format = require("whatsapp.format")
  local lines, jids, unread = format.chat_list({
    { jid = "a", name = "Alice", last_ts = 0, unread = 3 },
    { jid = "b", name = "Bob", last_ts = 0, unread = 0 },
  }, 20)
  check(vim.startswith(lines[1], "●") and unread[1] and jids[2] == "b", "chat_list marks unread and maps jids")

  local clines, owners, spans = format.conversation({
    { id = "1", text = "hi\nthere", ts = 1760390000, from_me = false, sender_name = "Alice", sender = "x" },
    { id = "2", text = "", ts = 1760390060, from_me = true, sender_name = "me", media_type = "image", filename = "image.jpg" },
  }, false)
  check(clines[1]:match("^── ") ~= nil, "conversation starts with a day separator")
  check(clines[2]:match("Alice: hi$") ~= nil and clines[3]:match("there$") ~= nil, "multi-line text continues indented")
  check(owners[3] and owners[3].id == "1", "continuation line maps to its message")
  check(clines[4]:find("[image image.jpg ⇣]", 1, true) ~= nil, "media renders as a tag")
  check(#spans > 0, "spans emitted")

  check(format.waveform({ 0, 100, 50, 0 }, 4) == "▁█▄▁", "waveform maps levels to blocks")
  check(format.waveform({ 10, 10 }, 2) == "██", "waveform scales to the loudest sample")
  check(format.waveform({}, 8) == "", "empty waveform renders nothing")
  local vlines = format.conversation({
    { id = "3", text = "", ts = 1760390000, from_me = false, sender_name = "Edward", sender = "x",
      media_type = "voice", filename = "audio.ogg", seconds = 62, waveform = { 0, 100, 50, 0 }, cached = true },
    { id = "4", text = "", ts = 1760390060, from_me = false, sender_name = "Edward", sender = "x",
      media_type = "video", filename = "clip.mp4", seconds = 5 },
  }, false)
  check(vlines[2]:find("[voice 1:02 ▁█▄▁ ✓]", 1, true) ~= nil, "voice note shows duration, waveform and cached tick: " .. vlines[2])
  check(vlines[3]:find("[video clip.mp4 0:05 ⇣]", 1, true) ~= nil, "video keeps its filename and shows duration")

  local blines, bowners = format.bubbles({
    { id = "1", text = "a fairly long message that needs wrapping across lines", ts = 1760390000, from_me = false, sender_name = "Alice", sender = "x" },
    { id = "2", text = "ok", ts = 1760390060, from_me = true, sender_name = "me" },
  }, false, 40)
  local joined_b = table.concat(blines, "\n")
  check(joined_b:find("╭─ Alice", 1, true) ~= nil, "bubble header carries sender")
  check(joined_b:find("│ that needs wrapping", 1, true) ~= nil, "long text wraps inside the box")
  local head_w, foot_w
  for _, l in ipairs(blines) do
    if l:find("╭─ Alice", 1, true) then head_w = vim.fn.strdisplaywidth(l) end
    if l:find("22:13", 1, true) then foot_w = vim.fn.strdisplaywidth(l) end
  end
  check(head_w == foot_w, "box header and footer have equal width")
  local me_head
  for i, l in ipairs(blines) do
    if l:find("╭─ me", 1, true) then
      me_head = i
    end
  end
  check(me_head and blines[me_head]:match("^%s+╭") ~= nil, "own bubble is right-aligned")
  check(me_head and bowners[me_head] and bowners[me_head].id == "2", "bubble lines map to their message")
  for _, l in ipairs(blines) do
    check(vim.fn.strdisplaywidth(l) <= 40, "bubble line fits width: " .. l)
  end

  -- Now the real UI against the fake bridge.
  local wa = require("whatsapp")
  wa.setup({ bin = root .. "/test/fake-bridge.sh", store = vim.fn.tempname(), notify = false, layout = "lines" })
  local S = require("whatsapp.state")
  local client = require("whatsapp.client")
  local events, on = {}, client.on
  client.on = function(event, callback)
    events[event] = callback
    on(event, callback)
  end

  -- User configs toggle number options on insert, defined before the plugin
  -- builds its layout as a vimrc would be; the panes must reset them.
  vim.api.nvim_create_autocmd("InsertEnter", { callback = function() vim.cmd("set number norelativenumber") end })
  wa.open()
  client.on = on
  check(wait_for(function() return #S.chats == 2 end), "chats loaded from bridge")
  check(S.layout_valid() and S.win_valid("list") and S.win_valid("chat"), "list and chat windows built")
  check(not S.win_valid("compose"), "compose hidden until a chat opens")
  local splash = table.concat(vim.api.nvim_buf_get_lines(S.bufs.chat, 0, -1, false), "\n")
  check(splash:find("WhatsApp", 1, true) ~= nil and splash:find("next unread", 1, true) ~= nil, "splash shows keys")

  local list_lines = vim.api.nvim_buf_get_lines(S.bufs.list, 0, -1, false)
  check(#list_lines == 2 and list_lines[1]:find("Alice", 1, true) ~= nil, "list buffer shows Alice first")

  wa.open_chat("111@s.whatsapp.net")
  check(wait_for(function() return S.messages["111@s.whatsapp.net"] ~= nil end), "messages loaded")
  check(vim.api.nvim_win_get_cursor(S.wins.chat)[1] == vim.api.nvim_buf_line_count(S.bufs.chat), "opened chat starts at the bottom")
  check(S.win_valid("compose"), "compose window created on open")
  vim.api.nvim_set_current_win(S.wins.compose)
  vim.cmd("startinsert")
  vim.api.nvim_exec_autocmds("InsertEnter", {})
  vim.cmd("stopinsert")
  check(vim.wo[S.wins.compose].number == false, "compose pane keeps number off after InsertEnter")
  local chat_lines = vim.api.nvim_buf_get_lines(S.bufs.chat, 0, -1, false)
  local joined = table.concat(chat_lines, "\n")
  check(joined:find("Alice: hello", 1, true) ~= nil, "chat shows incoming text")
  check(joined:find("↳ hello", 1, true) ~= nil, "chat shows quoted reply context")
  check(joined:find("me: see you", 1, true) ~= nil, "chat shows own message")

  -- Remote names land in winbar, which evaluates %{} unless escaped.
  local marker = vim.fn.tempname()
  S.chat_by_jid["111@s.whatsapp.net"].name = '%{system("touch ' .. marker .. '")}'
  require("whatsapp.ui.chat").render()
  require("whatsapp.ui.compose").update_winbar()
  local rendered = vim.api.nvim_eval_statusline(vim.wo[S.wins.chat].winbar, { winid = S.wins.chat, maxwidth = 1000 }).str
  check(vim.fn.filereadable(marker) == 0, "winbar does not evaluate remote names")
  check(rendered:find("%{system", 1, true) ~= nil, "winbar shows remote name literally")
  check(rendered:find("+111", 1, true) ~= nil, "winbar shows phone number for direct chats")
  S.chat_by_jid["111@s.whatsapp.net"].name = "Alice"

  -- The fake pushes a live message after the first messages.list.
  check(wait_for(function()
    local l = table.concat(vim.api.nvim_buf_get_lines(S.bufs.chat, 0, -1, false), "\n")
    return l:find("pushed live", 1, true) ~= nil
  end), "pushed message appears in open chat")

  -- Compose and send via :w.
  vim.api.nvim_buf_set_lines(S.bufs.compose, 0, -1, false, { "from nvim" })
  vim.api.nvim_set_current_win(S.wins.compose)
  vim.cmd("write")
  check(wait_for(function()
    local l = table.concat(vim.api.nvim_buf_get_lines(S.bufs.chat, 0, -1, false), "\n")
    return l:find("me: from nvim", 1, true) ~= nil
  end), ":w sends and echoes into the chat")
  check(vim.api.nvim_buf_get_lines(S.bufs.compose, 0, -1, false)[1] == "", "compose cleared after send")

  -- Media hint sits on the target attachment: under the cursor, else the
  -- newest one. ]m / [m move between attachments.
  local chat = require("whatsapp.ui.chat")
  local hint_ns = vim.api.nvim_create_namespace("whatsapp_chat_hint")
  local function hint()
    local marks = vim.api.nvim_buf_get_extmarks(S.bufs.chat, hint_ns, 0, -1, { details = true })
    if not marks[1] then return nil end
    local parts = {}
    for _, c in ipairs(marks[1][4].virt_text) do parts[#parts + 1] = c[1] end
    return table.concat(parts), marks[1][2] + 1
  end
  local msgs = S.messages["111@s.whatsapp.net"]
  check(hint() == nil, "no hint without media")
  table.insert(msgs, { id = "v1", chat_jid = "111@s.whatsapp.net", sender = "111@s.whatsapp.net",
    sender_name = "Alice", text = "", ts = 1760400300, from_me = false, media_type = "voice", filename = "audio.ogg", seconds = 3 })
  chat.render()
  vim.api.nvim_set_current_win(S.wins.chat)
  vim.cmd("normal! gg")
  chat.update_hint()
  local h, hrow = hint()
  check(h == "  <CR> menu · gx open · ]m [m media", "newest media carries the hint when the cursor is elsewhere: " .. tostring(h))
  check(hrow == vim.api.nvim_buf_line_count(S.bufs.chat), "hint sits on the media row")
  local target = chat.media_target()
  check(target and target.id == "v1", "<CR> target falls back to the newest media")
  table.insert(msgs, { id = "t1", chat_jid = "111@s.whatsapp.net", sender = "111@s.whatsapp.net",
    sender_name = "Alice", text = "after", ts = 1760400400, from_me = false })
  table.insert(msgs, { id = "v2", chat_jid = "111@s.whatsapp.net", sender = "111@s.whatsapp.net",
    sender_name = "Alice", text = "", ts = 1760400500, from_me = false, media_type = "image", filename = "image.jpg", cached = true })
  chat.render()
  vim.cmd("normal! gg")
  chat.update_hint()
  check(select(1, hint()) == "  <CR> menu · gx open · ]m [m media", "hint keeps the same keys with several attachments")
  chat.next_media(1)
  check(chat.media_target().id == "v1", "]m from the top lands on the first attachment")
  chat.next_media(1)
  check(chat.media_target().id == "v2", "]m again lands on the second")
  chat.next_media(-1)
  check(chat.media_target().id == "v1", "[m goes back")
  wa.ensure_compose()
  vim.api.nvim_set_current_win(S.wins.compose)
  wa.next_media(1)
  check(vim.api.nvim_get_current_win() == S.wins.chat and chat.media_target().id == "v2", "]m from compose focuses the chat and moves")
  check(vim.fn.maparg("<CR>", "n", false, true).buffer == 1 and vim.fn.maparg("gx", "n", false, true).buffer == 1,
    "chat has buffer-local <CR> and gx")
  local tag_line = vim.api.nvim_buf_get_lines(S.bufs.chat, 0, -1, false)
  check(table.concat(tag_line, "\n"):find("[voice 0:03 ⇣]", 1, true) ~= nil, "undownloaded media shows ⇣")
  check(table.concat(tag_line, "\n"):find("[image image.jpg ✓]", 1, true) ~= nil, "cached media shows ✓")
  for _ = 1, 3 do table.remove(msgs) end
  chat.render()

  -- Typing indicator: rows under the last message for the open chat only,
  -- cleared on pause.
  local function typing_shown()
    local last = vim.api.nvim_buf_get_lines(S.bufs.chat, -2, -1, false)[1] or ""
    return last:find("is typing", 1, true) ~= nil
  end
  events["typing"]({ chat = "222@g.us", sender = "333@s.whatsapp.net", sender_name = "Bob", state = "composing", media = "" })
  check(not typing_shown(), "typing in another chat is ignored")
  events["typing"]({ chat = "111@s.whatsapp.net", sender = "111@s.whatsapp.net", sender_name = "Alice", state = "composing", media = "" })
  check(typing_shown(), "typing shows under the open chat")
  check(vim.api.nvim_win_get_cursor(S.wins.chat)[1] == vim.api.nvim_buf_line_count(S.bufs.chat), "view follows the indicator")
  events["typing"]({ chat = "111@s.whatsapp.net", sender = "111@s.whatsapp.net", sender_name = "Alice", state = "paused", media = "" })
  check(not typing_shown() and S.typing == nil, "paused clears the indicator")
  check(S.available == true, "open chat marks the device online")

  -- ~ on the open chat flags it unread, mirrors to the bridge, and closes it.
  -- The fake's chats.list always reports Alice unread, so pin the local
  -- state first; the real bridge persists the flag.
  S.chat_by_jid["111@s.whatsapp.net"].unread = 0
  wa.toggle_unread("111@s.whatsapp.net")
  check(S.current == nil and S.chat_by_jid["111@s.whatsapp.net"].unread == 1, "toggle_unread flags and closes the open chat")
  check(vim.startswith(vim.api.nvim_buf_get_lines(S.bufs.list, 0, 1, false)[1], "●"), "list shows the unread mark")
  wa.toggle_unread("111@s.whatsapp.net")
  check(S.chat_by_jid["111@s.whatsapp.net"].unread == 0, "toggle_unread clears again")
  wa.set_unread("111@s.whatsapp.net", true)
  wa.set_unread("111@s.whatsapp.net", false)
  check(S.chat_by_jid["111@s.whatsapp.net"].unread == 0, "set_unread round-trips")
  vim.api.nvim_set_current_win(S.wins.list)
  wa.focus_next(1)
  check(vim.api.nvim_get_current_win() == S.wins.chat, "Tab moves list to chat")
  wa.focus_next(-1)
  check(vim.api.nvim_get_current_win() == S.wins.list, "S-Tab moves back")

  require("test.security")(check, events)

  -- pair.qr renders the code in the chat pane splash, pair.ok clears it.
  wa.pair()
  check(S.pairing == true, "pair shows the connecting state until the code arrives")
  check(wait_for(function()
    for _, l in ipairs(vim.api.nvim_buf_get_lines(S.bufs.chat, 0, -1, false)) do
      if l:find("█▀▀▀█ ▄ █▀▀▀█", 1, true) then return true end
    end
    return false
  end), "QR code renders in the chat pane")
  check(vim.api.nvim_win_get_cursor(S.wins.chat)[1] == 1, "QR view starts at the top")
  events["pair.ok"]()
  check(S.qr == nil and not S.pairing and S.status.paired == true, "pair.ok clears the QR code")

  -- logout closes the view, forgets the session and stops the bridge.
  wa.logout()
  check(wait_for(function() return not client.running() end), "logout stops the bridge")
  check(not S.layout_valid() and S.status.paired == false, "logout closes the tab and clears paired state")

  wa.close()
  check(not S.layout_valid(), "close tears down the tab")
  client.stop()

  if failures > 0 then
    io.stderr:write(failures .. " failure(s)\n")
    vim.cmd("cquit 1")
  end
  io.stderr:write("all passed\n")
end
