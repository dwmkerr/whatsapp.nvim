return function(check, events)
  local wa = require("whatsapp")
  local S = require("whatsapp.state")
  local client = require("whatsapp.client")
  local compose = require("whatsapp.ui.compose")
  local format = require("whatsapp.format")
  local display = require("whatsapp.text")
  local request, notify, confirm, open = client.request, vim.notify, vim.fn.confirm, vim.ui.open
  local sends, opened, prompts, notifications = {}, {}, {}, {}
  local notify_enabled, synced = S.opts.notify, S.synced
  local choice, download_error = 2, nil
  vim.notify = function(message) notifications[#notifications + 1] = message end
  vim.fn.confirm = function(_, _, default)
    prompts[#prompts + 1] = default
    return choice
  end
  vim.ui.open = function(path) opened[#opened + 1] = path end
  client.request = function(method, params, cb)
    if method == "messages.list" then cb(nil, {})
    elseif method == "chats.list" then cb(nil, S.chats)
    elseif method == "message.send" then sends[#sends + 1] = { params = params, cb = cb }
    elseif method == "media.download" then cb(download_error, { path = "/synthetic/image.xls" }) end
  end

  local ok, err = xpcall(function()
    local hostile = "Élodie\n\t👩‍💻\0\27\194\133\226\128\174"
    check(display.name(hostile) == "Élodie  👩‍💻", "names lose controls but keep accents and emoji joiners")
    S.opts.notify, S.synced = true, true
    local function incoming(name)
      events.message({ chat_name = name, message = { chat_jid = "outside@g.us", from_me = false, text = "private body" } })
    end
    incoming(hostile)
    incoming(hostile)
    check(vim.wait(2000, function() return #notifications > 0 end, 20), "batched notification arrives")
    check(#notifications == 1 and notifications[1] == "WhatsApp ● 2 new · Élodie  👩‍💻", "notifications coalesce and sanitise remote names")
    incoming(hostile .. string.rep("界", vim.o.columns))
    check(vim.wait(2000, function() return #notifications > 1 end, 20), "wide-name notification arrives")
    check(#notifications == 2 and vim.fn.strdisplaywidth(notifications[2]) <= math.max(20, vim.o.columns - 12), "Unicode notification fits the display width")
    S.opts.notify, S.synced = notify_enabled, synced
    local name = S.chat_by_jid["111@s.whatsapp.net"].name
    S.chat_by_jid["111@s.whatsapp.net"].name = hostile
    check(pcall(require("whatsapp.ui.list").render), "hostile name renders in the chat list")
    S.chat_by_jid["111@s.whatsapp.net"].name = name
    local msg = { id = "hostile", sender_name = hostile .. string.rep("界", 100), sender = "x", ts = 1760390000,
      text = "hello", media_type = "document", filename = "file\nname.pdf", from_me = false }
    for _, layout in ipairs({ "lines", "bubbles" }) do
      local lines = layout == "lines" and format.conversation({ msg }, true) or format.bubbles({ msg }, true, 40)
      local buf = vim.api.nvim_create_buf(false, true)
      check(pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines), "hostile sender/filename render in " .. layout)
      if layout == "bubbles" then
        local fits = true
        for _, line in ipairs(lines) do fits = fits and vim.fn.strdisplaywidth(line) <= 40 end
        check(fits, "long Unicode sender fits the bubble")
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end

    local alice, bob = "111@s.whatsapp.net", "222@g.us"
    wa.open_chat(alice)
    local alice_buf = S.bufs.compose
    vim.api.nvim_buf_set_lines(alice_buf, 0, -1, false, { "private for Alice" })
    local alice_reply = { id = "alice-reply", chat_jid = alice, text = "original", sender_name = "Alice" }
    wa.reply_to(alice_reply)
    wa.open_chat(bob)
    local bob_buf = S.bufs.compose
    check(alice_buf ~= bob_buf and compose.text() == "" and not compose.draft().reply_to, "new recipient has an independent empty draft and reply")
    wa.reply_to(alice_reply)
    check(not compose.draft().reply_to, "stale message cannot attach a reply to another recipient")
    vim.api.nvim_buf_set_lines(bob_buf, 0, -1, false, { "private for Bob" })
    wa.open_chat(alice)
    check(compose.text() == "private for Alice" and compose.draft().reply_to.id == "alice-reply", "returning restores the recipient's draft and reply")
    wa.open_chat(bob)
    -- Writing a hidden buffer must use its owner, not the selected chat.
    vim.api.nvim_buf_call(alice_buf, function() vim.cmd("write") end)
    check(sends[1].params.jid == alice and sends[1].params.reply_to == "alice-reply", "hidden draft sends only to its owner")
    wa.send_compose(alice)
    check(#sends == 1, "repeat save cannot send an in-flight draft twice")
    local function finish(send, error)
      send.cb(error, { id = "sent", chat_jid = send.params.jid, text = send.params.text, from_me = true, sender_name = "me", ts = 1760400200 })
    end
    finish(sends[1])
    check(compose.text(bob) == "private for Bob" and compose.text(alice) == "", "late send response clears only the original draft")
    wa.send_compose(bob)
    vim.api.nvim_buf_set_lines(bob_buf, 0, -1, false, { "newer draft" })
    finish(sends[2])
    check(compose.text(bob) == "newer draft", "late send response preserves subsequent edits")
    wa.send_compose(bob)
    finish(sends[3], "offline")
    check(compose.text(bob) == "newer draft" and not compose.draft(bob).sending, "failed sends retain the draft for retry")
    wa.close()
    wa.open()
    check(S.bufs.compose == bob_buf and compose.text() == "newer draft", "closing and reopening preserves the draft")
    S.chat_by_jid[bob].unread = 0
    wa.toggle_unread(bob)
    wa.open_chat(bob)
    check(compose.text() == "newer draft", "marking unread preserves the draft")

    for _, kind in ipairs({ "image", "video", "audio", "voice", "sticker", "document" }) do
      local media = { media_type = kind, chat_jid = alice, id = "attachment" }
      local before = #prompts
      wa.download_media(media)
      check(#prompts == before and #opened == 0, kind .. " download does not open an application")
      wa.open_media(media)
      check(#prompts == before + 1 and prompts[#prompts] == 2 and #opened == 0, kind .. " open defaults to cancel")
    end
    choice = 1
    wa.open_media({ media_type = "image", chat_jid = alice, id = "attachment" })
    check(#opened == 1, "explicit confirmation opens the attachment")
    download_error = "too large"
    local before = #prompts
    wa.open_media({ media_type = "document", chat_jid = alice, id = "attachment" })
    check(#prompts == before and #opened == 1, "failed download cannot open a cached/partial path")
  end, debug.traceback)

  client.request, vim.notify, vim.fn.confirm, vim.ui.open = request, notify, confirm, open
  S.opts.notify, S.synced = notify_enabled, synced
  check(ok, "security regression suite" .. (ok and "" or (": " .. err)))
end
