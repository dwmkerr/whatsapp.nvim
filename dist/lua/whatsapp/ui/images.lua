-- Pictures under image tags. Two modes, picked once per session:
--   tag    the [image photo.jpg ✓] line only, what every terminal gets
--   kitty  the real picture through the Kitty graphics protocol, needs a
--          terminal that speaks it plus magick or sips for JPEG to PNG
-- The tag line stays in every mode because <CR>, gx and ]m act on it; the
-- picture hangs under it as virtual lines, so buffer rows never move.
local S = require("whatsapp.state")
local client = require("whatsapp.client")

local M = {}
local ns = vim.api.nvim_create_namespace("whatsapp_images")

-- Kitty draws a virtual placement wherever this character appears with the
-- image id as foreground colour; the diacritics encode the cell's row and
-- column so the terminal can tile the picture across the grid.
local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)
local diacritics = vim.split(
  "0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1,1CD2,1CDA,1CDB,1CE0,1DC0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1,1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1,1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7,20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA,2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA,2DFB,2DFC,2DFD,2DFE,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5,A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7,AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187,1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244",
  ",")
local positions = {}
for i, hex in ipairs(diacritics) do
  positions[i] = vim.fn.nr2char(tonumber(hex, 16))
end

local resolved -- mode in use, nil until the first image asks
local converter -- { name, png = fn(src, dst) }
local cache = {} -- source path -> { state, max_cols, max_rows, cols, rows, crop, png, id }
local sent = {} -- kitty id -> true once the terminal holds the image
local passthrough_set = false
local asked = {} -- message id -> true once its cached path was requested
-- Ids are per terminal, not per Neovim, so start from the pid to keep two
-- editors in one window apart. Kept under 2^24 to fit a 24-bit colour.
local next_id = (vim.fn.getpid() % 4096) * 4096

-- Pure helpers, exposed for tests ------------------------------------------

-- Cells for a w x h pixel image inside max_cols x max_rows, keeping the
-- aspect. cell_w / cell_h are pixels per cell.
function M.fit(w, h, max_cols, max_rows, cell_w, cell_h)
  if w <= 0 or h <= 0 then
    return 0, 0
  end
  local cols = math.min(max_cols, math.max(1, math.ceil(w / cell_w)))
  local rows = math.max(1, math.ceil(cols * cell_w * h / w / cell_h))
  if rows > max_rows then
    rows = max_rows
    cols = math.max(1, math.ceil(rows * cell_h * w / h / cell_w))
  end
  return cols, rows
end

-- WhatsApp's rule: fill the width, let the height follow the aspect up to
-- a cap, then centre-crop the rest. Returns cols, rows and a source
-- rectangle {x, y, w, h} in pixels when a crop is needed. Small pictures
-- are not blown up past their own size.
function M.fit_fill(w, h, cols, max_rows, cell_w, cell_h)
  if w <= 0 or h <= 0 then
    return 0, 0
  end
  cols = math.max(1, math.min(cols, math.ceil(w / cell_w)))
  local rows = math.max(1, math.ceil(cols * cell_w * h / w / cell_h))
  if rows <= max_rows then
    return cols, rows
  end
  rows = max_rows
  local crop_h = math.min(h, math.floor(rows * cell_h * w / (cols * cell_w)))
  return cols, rows, { x = 0, y = math.floor((h - crop_h) / 2), w = w, h = crop_h }
end

-- Width and height from a PNG's IHDR chunk, which always follows the
-- 8-byte signature and 8 bytes of chunk length and type.
function M.png_size(bytes)
  if #bytes < 24 or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil
  end
  local function u32(at)
    local a, b, c, d = bytes:byte(at, at + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

-- Placeholder grid as virt_lines rows, each prefixed with the indent.
function M.placeholder_lines(id, cols, rows, indent)
  local hl = "WhatsAppImage" .. id
  vim.api.nvim_set_hl(0, hl, { fg = id, nocombine = true })
  cols = math.min(cols, #positions)
  rows = math.min(rows, #positions)
  local out = {}
  for r = 1, rows do
    local cells = {}
    for c = 1, cols do
      cells[#cells + 1] = PLACEHOLDER .. positions[r] .. positions[c]
    end
    out[r] = { { indent, "Comment" }, { table.concat(cells), hl } }
  end
  return out
end

-- One graphics command: APC G, key=value pairs, optional payload.
function M.kitty_cmd(opts, payload)
  local parts = {}
  for k, v in pairs(opts) do
    parts[#parts + 1] = k .. "=" .. tostring(v)
  end
  table.sort(parts)
  return "\27_G" .. table.concat(parts, ",") .. (payload and (";" .. payload) or "") .. "\27\\"
end

-- tmux only forwards escapes it is told to ignore; the wrapper doubles the
-- inner escapes so tmux's own parser skips them.
function M.wrap_tmux(data)
  return "\27Ptmux;" .. data:gsub("\27", "\27\27") .. "\27\\"
end

-- Environment ---------------------------------------------------------------

-- Inside tmux the environment describes tmux, not the terminal it sits
-- in. tmux has already asked that terminal its name (XTVERSION), which
-- survives shells that force TERM=xterm-256color; fall back to TERM.
local function outer_term(env)
  if not env.TMUX then
    return env.TERM or ""
  end
  local ok, out = pcall(vim.fn.system, { "tmux", "display", "-p", "#{client_termtype} #{client_termname}" })
  return ok and vim.trim(out) or (env.TERM or "")
end

function M.terminal_supports_kitty(env, term)
  env = env or vim.fn.environ()
  term = (term or outer_term(env)):lower()
  return env.TERM_PROGRAM == "ghostty"
    or env.GHOSTTY_RESOURCES_DIR ~= nil
    or env.KITTY_WINDOW_ID ~= nil
    or env.WEZTERM_EXECUTABLE ~= nil
    or term:find("ghostty", 1, true) ~= nil
    or term:find("kitty", 1, true) ~= nil
    or term:find("wezterm", 1, true) ~= nil
end

local function find_converter()
  if vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1 then
    local bin = vim.fn.executable("magick") == 1 and "magick" or "convert"
    return {
      name = bin,
      png = function(src, dst) return { bin, src, "png:" .. dst } end,
    }
  end
  if vim.fn.executable("sips") == 1 then
    return {
      name = "sips",
      png = function(src, dst) return { "sips", "-s", "format", "png", src, "--out", dst } end,
    }
  end
  return nil
end

-- Pixels per cell from the terminal, falling back to a common size when
-- it does not say (tmux usually reports zero).
local function cell_size()
  local ok, ffi = pcall(require, "ffi")
  if ok then
    pcall(ffi.cdef, [[
      typedef struct { unsigned short row, col, xpixel, ypixel; } wa_winsize;
      int ioctl(int, unsigned long, ...);
    ]])
    local ws = ffi.new("wa_winsize")
    local req = vim.fn.has("linux") == 1 and 0x5413 or 0x40087468
    if ffi.C.ioctl(1, req, ws) == 0 and ws.xpixel > 0 and ws.col > 0 and ws.ypixel > 0 and ws.row > 0 then
      return ws.xpixel / ws.col, ws.ypixel / ws.row
    end
  end
  return 9, 18
end

-- The mode in use. "auto" takes the best the environment offers.
function M.mode()
  if resolved then
    return resolved
  end
  local want = (S.opts.images or {}).mode or "auto"
  converter = find_converter()
  local kitty = M.terminal_supports_kitty() and #vim.api.nvim_list_uis() > 0
  if want == "tag" then
    resolved = "tag"
  elseif want == "kitty" then
    -- Pinned means the user knows the terminal; only the converter is a
    -- hard requirement.
    if converter then
      resolved = "kitty"
    else
      vim.notify("WhatsApp: images.mode kitty needs magick or sips to convert images; showing tags", vim.log.levels.WARN)
      resolved = "tag"
    end
  elseif want == "auto" then
    resolved = (kitty and converter) and "kitty" or "tag"
  else
    vim.notify("WhatsApp: unknown images.mode " .. tostring(want) .. "; showing tags", vim.log.levels.WARN)
    resolved = "tag"
  end
  return resolved
end

-- Terminal output -----------------------------------------------------------

local function write(data)
  if vim.env.TMUX then
    if not passthrough_set then
      passthrough_set = true
      pcall(vim.fn.system, { "tmux", "set", "-p", "allow-passthrough", "on" })
    end
    data = M.wrap_tmux(data)
  end
  -- Headless Neovim has no UI to send to; the placeholders still render.
  if vim.api.nvim_ui_send then
    pcall(vim.api.nvim_ui_send, data)
  else
    io.stdout:write(data)
  end
end

local function transmit(entry)
  if sent[entry.id] then
    return
  end
  sent[entry.id] = true
  -- t=f hands the terminal a path, so no chunking and no base64 of pixels.
  local opts = { a = "T", f = 100, t = "f", U = 1, q = 2, i = entry.id, c = entry.cols, r = entry.rows }
  if entry.crop then
    opts.x, opts.y, opts.w, opts.h = entry.crop.x, entry.crop.y, entry.crop.w, entry.crop.h
  end
  write(M.kitty_cmd(opts, vim.base64.encode(entry.png)))
end

-- Conversion -----------------------------------------------------------------

local function cache_dir()
  local dir = vim.fn.stdpath("cache") .. "/whatsapp/images"
  vim.fn.mkdir(dir, "p")
  return dir
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

-- PNG for src, converting once into the cache dir. cb(png, w, h), or
-- cb(nil) when the file cannot be read or converted.
local function to_png(src, cb)
  local dst, cmd
  if src:lower():match("%.png$") then
    dst = src
  else
    dst = cache_dir() .. "/" .. vim.fn.sha256(src):sub(1, 16) .. ".png"
    if not read_file(dst) then
      cmd = converter.png(src, dst)
    end
  end
  local function finish()
    local data = read_file(dst)
    local w, h
    if data then
      w, h = M.png_size(data)
    end
    if not w then
      cb(nil)
    else
      cb(dst, w, h)
    end
  end
  if not cmd then
    finish()
    return
  end
  vim.system(cmd, { text = false }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        cb(nil)
      else
        finish()
      end
    end)
  end)
end

-- Start preparing an image for the chat; re-render when it is ready.
local function prepare(src, jid, max_cols, max_rows)
  local entry = { state = "pending", max_cols = max_cols, max_rows = max_rows }
  cache[src] = entry
  to_png(src, function(png, w, h)
    if not png then
      entry.state = "failed"
      return
    end
    local cw, ch = cell_size()
    if S.opts.images.crop == false then
      entry.cols, entry.rows = M.fit(w, h, max_cols, max_rows, cw, ch)
    else
      entry.cols, entry.rows, entry.crop = M.fit_fill(w, h, max_cols, max_rows, cw, ch)
    end
    entry.png = png
    next_id = next_id + 1
    entry.id = next_id
    entry.state = "ready"
    if S.current == jid then
      require("whatsapp.ui.chat").render()
    end
  end)
end

-- Rendering ------------------------------------------------------------------

function M.clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

-- The converted entry for m fitted to max_cols, starting conversion (or a
-- refit after a resize) when there is none. nil until it is ready.
local function entry_for(m, max_cols, max_rows)
  if M.mode() == "tag" or m.media_type ~= "image" then
    return nil
  end
  if not m.path then
    -- History arrives with the cached flag but no path; the bridge answers
    -- for cached files without touching the network.
    if m.cached and not asked[m.id] then
      asked[m.id] = true
      client.request("media.download", { jid = m.chat_jid, id = m.id }, function(err, res)
        if err or not res or not res.path then
          return
        end
        m.path = res.path
        if S.current == m.chat_jid then
          require("whatsapp.ui.chat").render()
        end
      end)
    end
    return nil
  end
  max_cols = math.max(1, math.min(S.opts.images.max_width, max_cols))
  max_rows = math.max(1, math.min(S.opts.images.max_height, max_rows))
  local entry = cache[m.path]
  if not entry or (entry.state ~= "pending" and (entry.max_cols ~= max_cols or entry.max_rows ~= max_rows)) then
    prepare(m.path, m.chat_jid, max_cols, max_rows)
    return nil
  end
  return entry.state == "ready" and entry or nil
end

-- Cells the picture for m takes when fitted to the box, nil until known.
function M.size(m, max_cols, max_rows)
  local entry = entry_for(m, max_cols, max_rows)
  if entry then
    return entry.cols, entry.rows
  end
  return nil
end

-- Hang the picture for message m as virtual lines. `box` frames it inside
-- a bubble: rows get the bubble's side borders and padding and sit above
-- the footer row (anchor); without it rows hang below anchor at indent.
function M.place(buf, anchor, indent, m, max_cols, max_rows, box)
  local entry = entry_for(m, max_cols, max_rows)
  if not entry then
    return
  end
  transmit(entry)
  local rows = M.placeholder_lines(entry.id, entry.cols, entry.rows, indent)
  if box then
    local pad = string.rep(" ", math.max(0, box.inner - entry.cols))
    for _, r in ipairs(rows) do
      r[1] = { indent .. "│ ", box.hl }
      r[3] = { pad .. " │", box.hl }
    end
  end
  vim.api.nvim_buf_set_extmark(buf, ns, anchor - 1, 0, { virt_lines = rows, virt_lines_above = box ~= nil })
end

-- Zoom: the whole picture, uncropped, in a float over the editor. q,
-- <Esc> or <CR> closes. Only meaningful in kitty mode.
local view_win
function M.view(m)
  if M.mode() ~= "kitty" or not m or not m.path then
    return false
  end
  if view_win and vim.api.nvim_win_is_valid(view_win) then
    vim.api.nvim_win_close(view_win, true)
  end
  to_png(m.path, function(png, w, h)
    if not png then
      vim.notify("WhatsApp: could not read " .. m.path, vim.log.levels.WARN)
      return
    end
    local cw, ch = cell_size()
    local cols, rows = M.fit(w, h, vim.o.columns - 4, vim.o.lines - 4, cw, ch)
    next_id = next_id + 1
    local entry = { id = next_id, cols = cols, rows = rows, png = png }
    transmit(entry)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local grid = M.placeholder_lines(entry.id, cols, rows, "")
    local lines = {}
    for i, r in ipairs(grid) do
      lines[i] = r[2][1]
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    for i = 1, #lines do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #lines[i], hl_group = grid[i][2][2] })
    end
    vim.bo[buf].modifiable = false
    view_win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = cols,
      height = rows,
      row = math.floor((vim.o.lines - rows) / 2) - 1,
      col = math.floor((vim.o.columns - cols) / 2),
      style = "minimal",
      border = "rounded",
      title = " " .. (m.filename and m.filename ~= "" and m.filename or "image") .. " · q closes ",
      title_pos = "center",
    })
    local function close()
      if view_win and vim.api.nvim_win_is_valid(view_win) then
        vim.api.nvim_win_close(view_win, true)
      end
      view_win = nil
      write(M.kitty_cmd({ a = "d", d = "i", i = entry.id, q = 2 }))
    end
    for _, key in ipairs({ "q", "<Esc>", "<CR>" }) do
      vim.keymap.set("n", key, close, { buffer = buf, nowait = true, silent = true })
    end
    vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
  end)
  return true
end

function M.viewing()
  return view_win ~= nil and vim.api.nvim_win_is_valid(view_win)
end

-- Forget transmitted images so a new session starts clean; the terminal
-- drops them too.
function M.reset()
  for id in pairs(sent) do
    write(M.kitty_cmd({ a = "d", d = "i", i = id, q = 2 }))
  end
  sent = {}
  cache = {}
  asked = {}
end

-- Tests run headless and need a known mode.
function M._set_mode(mode)
  resolved = mode
end

return M
