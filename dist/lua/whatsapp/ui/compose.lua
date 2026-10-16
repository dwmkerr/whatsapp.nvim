local S = require("whatsapp.state")

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
  vim.keymap.set("n", "g?", function() require("whatsapp.ui.help").show("compose") end, { buffer = buf, silent = true, desc = "Keys" })
  vim.keymap.set("n", "<Tab>", function() wa.focus_next(1) end, { buffer = buf, silent = true, desc = "Next pane" })
  vim.keymap.set("n", "<S-Tab>", function() wa.focus_next(-1) end, { buffer = buf, silent = true, desc = "Previous pane" })
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

function M.update_winbar()
  if not S.win_valid("compose") then
    return
  end
  local target = S.current and S.chat_title(S.current) or "nobody"
  local bar = " → " .. S.bar_text(target)
  local draft = M.draft()
  local reply = draft and draft.reply_to
  if reply then
    local who = reply.from_me and "me" or reply.sender_name
    local snippet = (reply.text or ""):gsub("\n", " ")
    if #snippet > 40 then
      snippet = snippet:sub(1, 40) .. "…"
    end
    bar = bar .. "  ·  ↳ " .. S.bar_text(who) .. ": " .. S.bar_text(snippet) .. "  ·  q cancel"
  end
  vim.wo[S.wins.compose].winbar = bar .. "  ·  :w send  ·  g? help"
end

return M
