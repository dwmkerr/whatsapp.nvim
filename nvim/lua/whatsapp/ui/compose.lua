local S = require("whatsapp.state")

local M = {}

function M.ensure_buf()
  if S.bufs.compose and vim.api.nvim_buf_is_valid(S.bufs.compose) then
    return S.bufs.compose
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "wa://compose")
  -- acwrite makes :w fire BufWriteCmd instead of touching disk, so saving
  -- the buffer is the send action.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "whatsapp-compose"
  S.bufs.compose = buf

  local wa = require("whatsapp")
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      wa.send_compose()
    end,
  })
  vim.keymap.set("n", "q", wa.cancel_reply, { buffer = buf, silent = true, desc = "Cancel reply" })
  vim.keymap.set("n", "g?", function() require("whatsapp.ui.help").show("compose") end, { buffer = buf, silent = true, desc = "Keys" })
  vim.keymap.set("n", "<C-k>", function()
    if S.win_valid("chat") then
      vim.api.nvim_set_current_win(S.wins.chat)
    end
  end, { buffer = buf, silent = true, desc = "Focus chat" })
  return buf
end

function M.text()
  local buf = M.ensure_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

function M.clear()
  local buf = M.ensure_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.bo[buf].modified = false
end

function M.update_winbar()
  if not S.win_valid("compose") then
    return
  end
  local target = S.current and S.chat_title(S.current) or "nobody"
  local bar = " → " .. S.bar_text(target)
  if S.reply_to then
    local who = S.reply_to.from_me and "me" or S.reply_to.sender_name
    local snippet = (S.reply_to.text or ""):gsub("\n", " ")
    if #snippet > 40 then
      snippet = snippet:sub(1, 40) .. "…"
    end
    bar = bar .. "  ·  ↳ " .. S.bar_text(who) .. ": " .. S.bar_text(snippet) .. "  ·  q cancel"
  end
  vim.wo[S.wins.compose].winbar = bar .. "  ·  :w send  ·  g? help"
end

return M
