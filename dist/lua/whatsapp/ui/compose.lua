local S = require("whatsapp.state")
local format = require("whatsapp.format")
local text = require("whatsapp.text")

local M = {}

function M.draft(jid)
  jid = jid or S.current
  if not jid then
    return nil
  end
  S.drafts[jid] = S.drafts[jid] or {}
  return S.drafts[jid]
end

function M.ensure_buf(jid)
  jid = jid or S.current
  local draft = M.draft(jid)
  if not draft then return nil end
  if draft.buf and vim.api.nvim_buf_is_valid(draft.buf) then
    return draft.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "wa://compose/" .. buf)
  -- acwrite makes :w fire BufWriteCmd instead of touching disk, so saving
  -- the buffer is the send action.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "whatsapp-compose"
  draft.buf = buf

  local wa = require("whatsapp")
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      wa.send_compose(jid)
    end,
  })
  vim.keymap.set("n", "q", wa.cancel_reply, { buffer = buf, silent = true, desc = "Cancel reply" })
  vim.keymap.set("n", "g?", wa.toggle_help, { buffer = buf, silent = true, desc = "All keys" })
  vim.keymap.set("n", "<Tab>", function() wa.focus_next(1) end, { buffer = buf, silent = true, desc = "Next pane" })
  vim.keymap.set("n", "<S-Tab>", function() wa.focus_next(-1) end, { buffer = buf, silent = true, desc = "Previous pane" })
  -- Media keys work from here too; in normal mode <CR> and gx have no other
  -- job in a compose buffer, and the chat pane is the obvious target.
  local chat = require("whatsapp.ui.chat")
  vim.keymap.set("n", "<CR>", function() wa.media_menu(chat.media_target()) end, { buffer = buf, silent = true, desc = "Media menu" })
  vim.keymap.set("n", "gx", function() wa.open_media(chat.media_target()) end, { buffer = buf, silent = true, desc = "Open media" })
  vim.keymap.set("n", "]m", function() wa.next_media(1) end, { buffer = buf, silent = true, desc = "Next media" })
  vim.keymap.set("n", "[m", function() wa.next_media(-1) end, { buffer = buf, silent = true, desc = "Previous media" })
  return buf
end

function M.text(jid)
  local buf = M.ensure_buf(jid)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

function M.clear(jid)
  local buf = M.ensure_buf(jid)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.bo[buf].modified = false
end

-- Cut s to at most width display cells, marking the cut with an ellipsis.
local function clip(s, width)
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  return text.fit(s, math.max(0, width - 1)) .. "…"
end

-- The recipient by name; the number only when there is no name, since the
-- chat pane's winbar already shows it.
local function recipient(jid)
  local name = S.chat_name(jid)
  local user = jid:match("^([^@]+)@s%.whatsapp%.net$")
  if user and name == user then
    return "+" .. user
  end
  return name
end

-- One line: what this message is (to whom, or what it replies to) on the
-- left, keys pinned right. Replying replaces the recipient, which the chat
-- pane already names, so the quote gets the room. The left side is cut to
-- fit; Neovim would otherwise cut the whole bar from the left.
function M.update_winbar()
  if not S.win_valid("compose") then
    return
  end
  local draft = M.draft()
  local reply = draft and draft.reply_to
  local keys = { { ":w", "send" }, { "g?", "help" } }
  local left
  if reply then
    table.insert(keys, 1, { "q", "cancel" })
    local who, snippet = format.quote_parts(reply.from_me and "me" or reply.sender_name,
      reply.text, reply.media_type, reply.filename)
    left = "↳ " .. (who or "") .. ((who and snippet) and ": " or "") .. (snippet or "")
  else
    left = "→ " .. (S.current and recipient(S.current) or "nobody")
  end
  local right, plain = {}, {}
  for _, k in ipairs(keys) do
    right[#right + 1] = "%#Special#" .. k[1] .. "%#Comment# " .. k[2]
    plain[#plain + 1] = k[1] .. " " .. k[2]
  end
  local room = vim.api.nvim_win_get_width(S.wins.compose) - vim.fn.strdisplaywidth(table.concat(plain, "  ")) - 4
  left = clip(text.single_line(left), room)
  vim.wo[S.wins.compose].winbar = " " .. S.bar_text(left) .. "%=" .. table.concat(right, "  ") .. "%* "
end

return M
