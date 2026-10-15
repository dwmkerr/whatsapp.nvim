local M = {}

-- Preserve Unicode names (including emoji joiners), but keep remote labels on
-- one line and remove terminal controls and directional override characters.
function M.single_line(value)
  local text = tostring(value or ""):gsub("[\r\n\t]", " "):gsub("%c", "")
  text = text:gsub("\194[\128-\159]", "")
    :gsub("\226\128[\168\169]", " ")
    :gsub("\226\128[\142\143\170-\174]", "")
    :gsub("\226\129[\166-\169]", "")
    :gsub("\216\156", "")
  return text
end

function M.name(value)
  return vim.fn.strcharpart(M.single_line(value), 0, 256)
end

-- Truncate by display cells, not bytes, so wide names fit their pane.
function M.fit(value, width)
  local text = vim.fn.strcharpart(value, 0, width)
  while vim.fn.strdisplaywidth(text) > width do
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  end
  return text
end

return M
