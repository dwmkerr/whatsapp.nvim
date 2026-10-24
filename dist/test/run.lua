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
  check(lines[1]:match(" 3 ") == nil, "chat_list hides counts by default")
  local counted = format.chat_list({
    { jid = "a", name = "Alice", last_ts = 0, unread = 3 },
    { jid = "b", name = "Bob", last_ts = 0, unread = 0 },
  }, 20, true)
  check(counted[1]:match(" 3 $") ~= nil and vim.fn.strdisplaywidth(counted[1]) == 20, "chat_list shows the count left of the time")
  check(counted[2] == lines[2], "chat_list leaves read chats unchanged with counts on")

  local clines, owners, spans = format.conversation({
    { id = "1", text = "hi\nthere", ts = 1760390000, from_me = false, sender_name = "Alice", sender = "x" },
    { id = "2", text = "", ts = 1760390060, from_me = true, sender_name = "me", media_type = "image", filename = "image.jpg" },
  }, false)
  check(clines[1]:match("^── ") ~= nil, "conversation starts with a day separator")
  check(clines[2]:match("Alice: hi$") ~= nil and clines[3]:match("there$") ~= nil, "multi-line text continues indented")
  check(owners[3] and owners[3].id == "1", "continuation line maps to its message")
  check(clines[4]:find("[image ⇣]", 1, true) ~= nil, "media renders as a tag, generic image.jpg name dropped: " .. clines[4])
  local nlines = format.conversation({
    { id = "5", text = "", ts = 1760390060, from_me = true, sender_name = "me", media_type = "image", filename = "holiday.jpg" },
  }, false)
  check(nlines[2]:find("[image holiday.jpg ⇣]", 1, true) ~= nil, "a real filename stays in the tag")
  local wide = format.bubbles({
    { id = "6", text = "", ts = 1760390060, from_me = false, sender_name = "Alice", sender = "x", media_type = "image", filename = "image.jpg" },
  }, false, 80, function() return 30 end)
  local head_line
  for _, l in ipairs(wide) do
    if l:find("╭", 1, true) then head_line = l end
  end
  check(head_line and vim.fn.strdisplaywidth(head_line) == 34, "bubble widens to frame a picture: " .. tostring(head_line))
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
    for _, c in ipairs(marks[1][4].virt_lines[1]) do parts[#parts + 1] = c[1] end
    return vim.trim(table.concat(parts)), marks[1][2] + 1
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
  check(h == "<CR> menu · gx open · [m ]m prev / next", "newest media carries the hint when the cursor is elsewhere: " .. tostring(h))
  check(hrow == vim.api.nvim_buf_line_count(S.bufs.chat), "hint hangs under the media message")
  local target = chat.media_target()
  check(target and target.id == "v1", "<CR> target falls back to the newest media")
  table.insert(msgs, { id = "t1", chat_jid = "111@s.whatsapp.net", sender = "111@s.whatsapp.net",
    sender_name = "Alice", text = "after", ts = 1760400400, from_me = false })
  table.insert(msgs, { id = "v2", chat_jid = "111@s.whatsapp.net", sender = "111@s.whatsapp.net",
    sender_name = "Alice", text = "", ts = 1760400500, from_me = false, media_type = "image", filename = "image.jpg", cached = true })
  chat.render()
  vim.cmd("normal! gg")
  chat.update_hint()
  check(select(1, hint()) == "<CR> menu · gx open · [m ]m prev / next", "hint keeps the same keys with several attachments")
  chat.next_media(1)
  check(chat.media_target().id == "v1", "]m from the top lands on the first attachment")
  chat.next_media(1)
  check(chat.media_target().id == "v2", "]m again lands on the second")
  chat.next_media(-1)
  check(chat.media_target().id == "v1", "[m goes back")
  vim.api.nvim_set_current_win(S.wins.chat)
  vim.cmd("normal! G")
  check(chat.message_under_cursor() and chat.message_under_cursor().id == "v2", "message_under_cursor maps the row to its message")
  vim.cmd("normal! gg")
  vim.api.nvim_set_current_win(S.wins.list)
  wa.next_media(1)
  check(vim.api.nvim_get_current_win() == S.wins.chat and chat.media_target().id == "v1", "]m from the list focuses the chat and moves")
  wa.ensure_compose()
  vim.api.nvim_set_current_win(S.wins.compose)
  wa.next_media(-1)
  check(vim.api.nvim_get_current_win() == S.wins.chat and chat.media_target().id == "v2", "[m from compose lands on the newest media")
  wa.next_media(1)
  check(vim.api.nvim_get_current_win() == S.wins.compose, "]m past the last media returns to compose")
  wa.next_media(1)
  check(vim.api.nvim_get_current_win() == S.wins.chat and chat.media_target().id == "v1", "]m from compose starts at the first media")
  check(vim.fn.maparg("<CR>", "n", false, true).buffer == 1 and vim.fn.maparg("gx", "n", false, true).buffer == 1,
    "chat has buffer-local <CR> and gx")
  local tag_line = vim.api.nvim_buf_get_lines(S.bufs.chat, 0, -1, false)
  check(table.concat(tag_line, "\n"):find("[voice 0:03 ⇣]", 1, true) ~= nil, "undownloaded media shows ⇣")
  check(table.concat(tag_line, "\n"):find("[image ✓]", 1, true) ~= nil, "cached media shows ✓")

  -- Inline images: pure helpers first, then the kitty pipeline end to end
  -- against a two-pixel BMP, then tag mode leaves nothing behind.
  local images = require("whatsapp.ui.images")
  local img_ns = vim.api.nvim_create_namespace("whatsapp_images")
  local cols, rows = images.fit(800, 600, 60, 12, 9, 18)
  check(cols == 32 and rows == 12, "fit keeps the aspect inside the box: " .. cols .. "x" .. rows)
  check(select(1, images.fit(600, 800, 60, 12, 9, 18)) == 18, "fit narrows a tall image to the row limit")
  local fc, fr, crop = images.fit_fill(800, 600, 60, 20, 9, 18)
  check(fc == 60 and fr == 20 and crop and crop.h == 533 and crop.y == 33 and crop.w == 800, "fit_fill fills the width and centre-crops the overflow: " .. vim.inspect({ fc, fr, crop }))
  fc, fr, crop = images.fit_fill(600, 800, 60, 20, 9, 18)
  check(fc == 60 and fr == 20 and crop.h == 400 and crop.y == 200, "fit_fill crops a portrait to the row cap")
  fc, fr, crop = images.fit_fill(800, 100, 60, 20, 9, 18)
  check(fc == 60 and fr == 4 and crop == nil, "fit_fill leaves a wide image uncropped")
  fc, fr, crop = images.fit_fill(100, 50, 60, 20, 9, 18)
  check(fc == 12 and fr == 3 and crop == nil, "fit_fill does not blow up a small image")
  local png = "\137PNG\r\n\26\n" .. "\0\0\0\13IHDR" .. "\0\0\3\32" .. "\0\0\2\88"
  local pw, ph = images.png_size(png)
  check(pw == 800 and ph == 600, "png_size reads IHDR")
  check(images.png_size("not a png") == nil, "png_size rejects other data")
  local function bmp(w, h, pixels)
    local stride = math.ceil(w * 3 / 4) * 4
    local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
    local body = {}
    for y = h - 1, 0, -1 do
      local row = {}
      for x = 0, w - 1 do
        local r, g, b = unpack(pixels[y * w + x + 1])
        row[#row + 1] = string.char(b, g, r)
      end
      body[#body + 1] = table.concat(row) .. string.rep("\0", stride - w * 3)
    end
    local data = table.concat(body)
    return "BM" .. u32(54 + #data) .. u32(0) .. u32(54) .. u32(40) .. u32(w) .. u32(h) .. string.char(1, 0, 24, 0) .. string.rep("\0", 24) .. data
  end
  local pl = images.placeholder_lines(7, 3, 2, "  ")
  check(#pl == 2 and pl[1][2][2] == "WhatsAppImage7" and vim.fn.strchars(pl[1][2][1]) == 9, "placeholder_lines builds a cells x rows grid")
  check(vim.fn.hlexists("WhatsAppImage7") == 1, "placeholder highlight carries the image id")
  check(images.kitty_cmd({ a = "T", i = 5 }, "x") == "\27_Ga=T,i=5;x\27\\", "kitty_cmd formats an APC command")
  check(images.wrap_tmux("\27_Ga=T\27\\") == "\27Ptmux;\27\27_Ga=T\27\27\\\27\\", "wrap_tmux doubles inner escapes")
  check(images.terminal_supports_kitty({ TERM_PROGRAM = "ghostty" }) and images.terminal_supports_kitty({ KITTY_WINDOW_ID = "1" })
    and not images.terminal_supports_kitty({ TERM_PROGRAM = "iTerm.app", TERM = "xterm-256color" }), "terminal detection reads the environment")
  check(images.terminal_supports_kitty({ TERM_PROGRAM = "tmux", TERM = "xterm-256color", TMUX = "x" }, "ghostty 1.3.1 xterm-256color")
    and images.terminal_supports_kitty({ TERM_PROGRAM = "tmux", TERM = "xterm-256color", TMUX = "x" }, " xterm-kitty")
    and not images.terminal_supports_kitty({ TERM_PROGRAM = "tmux", TERM = "xterm-256color", TMUX = "x" }, "iTerm2 3.6.11 xterm-256color"),
    "inside tmux the outer client's reported terminal decides")

  local function image_marks()
    return vim.api.nvim_buf_get_extmarks(S.bufs.chat, img_ns, 0, -1, { details = true })
  end
  images._set_mode("tag")
  chat.render()
  check(#image_marks() == 0, "tag mode hangs nothing under the tag")
  local has_converter = vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1 or vim.fn.executable("sips") == 1
  if has_converter then
    local fixture = vim.fn.tempname() .. ".bmp"
    local f = assert(io.open(fixture, "wb"))
    f:write(bmp(2, 2, { { 0, 0, 0 }, { 255, 255, 255 }, { 128, 128, 128 }, { 255, 0, 0 } }))
    f:close()
    msgs[#msgs].path = fixture
    images._set_mode("kitty")
    chat.render()
    check(wait_for(function()
      local ms = image_marks()
      return ms[1] and ms[1][4].virt_lines[1][2][2]:match("^WhatsAppImage%d+$") ~= nil
    end, 5000), "kitty mode converts to PNG and hangs a placeholder grid")
    local marks = image_marks()
    local kvl = marks[1][4].virt_lines
    check(#kvl >= 1 and #kvl <= 20 and vim.fn.strchars(kvl[1][2][1]) % 3 == 0, "placeholder rows are cell triplets")
    check(marks[1][2] + 1 == vim.api.nvim_buf_line_count(S.bufs.chat) and not marks[1][4].virt_lines_above, "lines layout hangs the rows under the message")
    S.opts.layout = "bubbles"
    chat.render()
    check(wait_for(function()
      local ms = image_marks()
      return ms[1] and ms[1][4].virt_lines_above == true
    end, 5000), "bubbles layout puts the rows above the footer")
    local bvl = image_marks()[1][4].virt_lines[1]
    local footer = vim.api.nvim_buf_get_lines(S.bufs.chat, image_marks()[1][2], image_marks()[1][2] + 1, false)[1]
    check(bvl[1][1]:match("│ $") ~= nil and bvl[3][1]:match(" │$") ~= nil and bvl[1][2] == "WhatsAppBubble", "picture rows carry the bubble's borders")
    check(vim.fn.strdisplaywidth(bvl[1][1] .. bvl[3][1]) + vim.fn.strchars(bvl[2][1]) / 3 == vim.fn.strdisplaywidth(footer), "picture rows are as wide as the box")
    S.opts.layout = "lines"
    -- Reopening a chat rebuilds its message objects without the path; the
    -- picture must survive that.
    local old_m = msgs[#msgs]
    msgs[#msgs] = { id = old_m.id, chat_jid = old_m.chat_jid, sender = old_m.sender, sender_name = old_m.sender_name,
      text = "", ts = old_m.ts, from_me = false, media_type = "image", filename = "image.jpg", cached = true }
    chat.render()
    check(wait_for(function() return #image_marks() > 0 end, 5000) and msgs[#msgs].path == fixture, "a rebuilt message without a path still shows its picture")
    -- View: the picture takes over the chat pane, q brings the chat back.
    vim.api.nvim_set_current_win(S.wins.list)
    wa.view_image(msgs[#msgs])
    check(S.view == msgs[#msgs] and vim.api.nvim_get_current_win() == S.wins.chat, "view takes the chat pane and focus")
    local placeholder = vim.fn.nr2char(0x10EEEE)
    check(wait_for(function()
      return table.concat(vim.api.nvim_buf_get_lines(S.bufs.chat, 0, -1, false), "\n"):find(placeholder, 1, true) ~= nil
    end, 5000), "view fills the pane with the placeholder grid")
    check(vim.wo[S.wins.chat].winbar:find("q closes", 1, true) ~= nil, "view names its exit in the title")
    check(#image_marks() == 0, "no inline picture while viewing")
    vim.api.nvim_feedkeys("q", "x", false)
    check(S.view == nil and table.concat(vim.api.nvim_buf_get_lines(S.bufs.chat, 0, -1, false), "\n"):find("hello", 1, true) ~= nil, "q restores the conversation")
    msgs[#msgs].path = nil
    images._set_mode("tag")
    chat.render()
    check(#image_marks() == 0, "back to tag mode clears the rows")
    check(images.full(msgs[#msgs], 40, 20) == nil, "full is a no-op in tag mode")
  else
    io.stderr:write("skip: no image converter on this machine\n")
  end
  for _ = 1, 3 do table.remove(msgs) end
  chat.render()

  -- g? takes over the chat pane from any pane and hands focus back on close.
  vim.api.nvim_set_current_win(S.wins.list)
  wa.toggle_help()
  local help_text = table.concat(vim.api.nvim_buf_get_lines(S.bufs.chat, 0, -1, false), "\n")
  check(S.help and vim.api.nvim_get_current_win() == S.wins.chat, "g? shows help in the chat pane and focuses it")
  check(help_text:find("conversation", 1, true) ~= nil and help_text:find(":WhatsApp pair", 1, true) ~= nil, "help lists panes and commands")
  wa.toggle_help()
  local back_text = table.concat(vim.api.nvim_buf_get_lines(S.bufs.chat, 0, -1, false), "\n")
  check(not S.help and vim.api.nvim_get_current_win() == S.wins.list, "closing help returns focus to the list")
  check(back_text:find("hello", 1, true) ~= nil, "closing help restores the conversation")
  vim.api.nvim_set_current_win(S.wins.chat)

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
