-- Floating window that shows the pairing QR code as half-block text.
local M = {}
local win, buf = nil, nil

function M.show(lines)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
  end
  local body = { " Scan with WhatsApp > Linked Devices > Link a Device ", "" }
  vim.list_extend(body, lines)
  table.insert(body, "")
  table.insert(body, " Press q to dismiss ")
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  vim.bo[buf].modifiable = false

  local width = 0
  for _, l in ipairs(body) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local height = #body
  local cfg = {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " WhatsApp pairing ",
  }
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, cfg)
  else
    win = vim.api.nvim_open_win(buf, true, cfg)
    vim.keymap.set("n", "q", M.close, { buffer = buf, silent = true })
  end
end

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

return M
