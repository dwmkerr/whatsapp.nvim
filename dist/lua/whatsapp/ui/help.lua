-- g? cheatsheet: a small float over the current window, closed by any of
-- q, <Esc> or g? again, or by leaving it.
local M = {}

local keys = {
  list = {
    { "<CR> l", "open chat" },
    { "i", "open chat and compose" },
    { "u", "next unread chat" },
    { "gU gu ~", "mark unread / read / toggle" },
    { "R", "refresh chats and contact names" },
    { "<Tab>", "next pane" },
    { "q", "close WhatsApp" },
  },
  chat = {
    { "i a o", "compose" },
    { "R", "reply to message under cursor" },
    { "r", "react to message under cursor" },
    { "<CR> gf", "download media" },
    { "gx", "open media (downloads first, asks before opening)" },
    { "K", "load older messages" },
    { "gU gu ~", "mark unread (closes chat) / read / toggle" },
    { "L", "toggle bubbles / lines" },
    { "<Tab>", "next pane" },
    { "q", "close WhatsApp" },
  },
  compose = {
    { ":w", "send" },
    { "q", "cancel reply" },
    { "<Tab>", "next pane" },
  },
}

function M.show(kind)
  local lines = {}
  local width = 0
  for _, k in ipairs(keys[kind] or {}) do
    local line = string.format(" %-8s %s ", k[1], k[2])
    lines[#lines + 1] = line
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = vim.api.nvim_get_current_win(),
    row = 0,
    col = 1,
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " keys ",
    title_pos = "center",
  })
  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

return M
