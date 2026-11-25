-- Pure functions that turn bridge rows into buffer lines plus highlight
-- spans. Kept free of editor calls so they are easy to test.
local M = {}
local text = require("whatsapp.text")

local function pad_right(s, width)
  local len = vim.fn.strdisplaywidth(s)
  if len >= width then
    return text.fit(s, width)
  end
  return s .. string.rep(" ", width - len)
end

local function day_of(ts)
  return os.date("%Y-%m-%d", ts)
end

function M.short_time(ts)
  if ts == 0 then
    return ""
  end
  if day_of(ts) == day_of(os.time()) then
    return os.date("%H:%M", ts)
  end
  return os.date("%d %b", ts)
end

-- Chat list: "● Name              12:40", or "● Name           3 12:40" with
-- show_counts. Returns lines, jids per line, and which lines are unread.
function M.chat_list(chats, width, show_counts)
  local lines, jids, unread = {}, {}, {}
  for i, c in ipairs(chats) do
    local mark = c.unread > 0 and "●" or " "
    local right = M.short_time(c.last_ts)
    if show_counts and c.unread > 0 then
      right = c.unread .. " " .. right
    end
    local name_width = math.max(4, width - 2 - #right - 1)
    lines[i] = mark .. " " .. pad_right(text.name(c.name ~= "" and c.name or c.jid), name_width) .. " " .. right
    jids[i] = c.jid
    unread[i] = c.unread > 0
  end
  return lines, jids, unread
end

local function duration(seconds)
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Voice note levels (0-100) as a row of block characters. Buckets take the
-- loudest sample so the shape stays spiky, and levels are scaled to the
-- loudest point in the clip so quiet notes still show a shape.
function M.waveform(levels, cols)
  local blocks = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
  if not levels or #levels == 0 then
    return ""
  end
  cols = math.min(cols, #levels)
  local peak = 1
  for _, v in ipairs(levels) do
    peak = math.max(peak, v)
  end
  local out = {}
  for i = 1, cols do
    local lo = math.floor((i - 1) * #levels / cols) + 1
    local hi = math.floor(i * #levels / cols)
    local v = 0
    for j = lo, math.max(lo, hi) do
      v = math.max(v, levels[j] or 0)
    end
    out[i] = blocks[math.max(1, math.ceil(v / peak * #blocks))]
  end
  return table.concat(out)
end

local function media_tag(m)
  if m.media_type == nil or m.media_type == "" then
    return nil
  end
  local parts = { m.media_type }
  -- Generic names say nothing: voice notes are always audio.ogg and phone
  -- photos arrive as image.jpg. A real filename is worth the space.
  local generic = m.media_type == "voice" or (m.filename or ""):match("^image%.%w+$") ~= nil
  if not generic and m.filename and m.filename ~= "" then
    parts[#parts + 1] = text.name(m.filename)
  end
  if m.seconds and m.seconds > 0 then
    parts[#parts + 1] = duration(m.seconds)
  end
  if m.media_type == "voice" then
    local wave = M.waveform(m.waveform, 12)
    if wave ~= "" then
      parts[#parts + 1] = wave
    end
  end
  parts[#parts + 1] = m.cached and "✓" or "⇣"
  return "[" .. table.concat(parts, " ") .. "]"
end

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

local generic_names = { image = true, audio = true, video = true, sticker = true, document = true }

-- What a reply quotes, as the phone's quote strip shows it: the sender's
-- first name, and the text or, when there is none, a media tag, so a reply
-- to a voice note or document still says what it answered. Returns
-- who, snippet; who is nil when the bridge did not say.
function M.quote_parts(sender, body, media, filename)
  local snippet = (text.single_line(body or ""):gsub("%s+", " "))
  if snippet == "" and media and media ~= "" then
    -- Generic names (audio.ogg, image.jpg, sticker.webp) say nothing.
    local name = filename or ""
    local kind = name:match("^(%a+)%.%w+$")
    if media == "voice" or (kind and generic_names[kind]) then
      name = ""
    end
    snippet = "[" .. media .. (name ~= "" and (" " .. text.name(name)) or "") .. "]"
  end
  if snippet == "" then
    return nil, nil
  end
  local who
  if sender == "me" then
    who = "You"
  elseif sender and sender ~= "" then
    who = text.name(sender):match("^%S+")
  end
  return who, snippet
end

-- The quote line inside a reply's bubble, or nil when there is nothing to
-- quote.
function M.quote(m)
  if not m.quoted_id or m.quoted_id == "" then
    return nil
  end
  local who, snippet = M.quote_parts(m.quoted_sender, m.quoted_text, m.quoted_media_type, m.quoted_filename)
  if not snippet then
    return nil
  end
  return who and (who .. " · " .. snippet) or snippet
end

-- Word-wrap one paragraph to a display width. Words longer than the width
-- are split by character.
local function wrap(text, width)
  local out = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      while dw(word) > width do
        if line ~= "" then
          out[#out + 1] = line
          line = ""
        end
        out[#out + 1] = vim.fn.strcharpart(word, 0, width)
        word = vim.fn.strcharpart(word, width)
      end
      if line == "" then
        line = word
      elseif dw(line) + 1 + dw(word) <= width then
        line = line .. " " .. word
      else
        out[#out + 1] = line
        line = word
      end
    end
    out[#out + 1] = line
  end
  return out
end

local function centered(text, width)
  local pad = math.max(0, math.floor((width - dw(text)) / 2))
  return string.rep(" ", pad) .. text
end

-- Bubble layout: each message in a box, incoming on the left, own messages
-- on the right. Returns the same triple as M.conversation.
-- image_cols(m) may return the width in cells of a picture that will hang
-- inside m's bubble, so the box is drawn wide enough to frame it.
function M.bubbles(messages, is_group, width, image_cols)
  local lines, owners, spans = {}, {}, {}
  local last_day = nil
  local max_box = math.max(24, math.floor(width * 0.7))
  local inner_max = max_box - 4
  -- from: first byte of the bubble. Its fill stops at the box so own
  -- messages read as bubbles rather than full-width bands.
  local function add(text, owner, group, from)
    lines[#lines + 1] = text
    owners[#lines] = owner
    if group then
      spans[#spans + 1] = from and { #lines - 1, from, #text, group } or { #lines - 1, 0, -1, group }
    end
    return #lines
  end
  for _, m in ipairs(messages) do
    local day = day_of(m.ts)
    if day ~= last_day then
      if #lines > 0 then
        add("", nil)
      end
      add(centered("── " .. os.date("%a %d %b %Y", m.ts) .. " ──", width), nil, "WhatsAppSeparator")
      last_day = day
    end
    local who = text.fit(text.name(m.from_me and "me" or (m.sender_name ~= "" and m.sender_name or m.sender)), inner_max - 1)
    -- The phone marks an edited message beside its time.
    local time = (m.edited and "edited " or "") .. os.date("%H:%M", m.ts)
    local body = m.text or ""
    local tag = media_tag(m)
    if tag then
      body = body ~= "" and (tag .. " " .. body) or tag
    end
    local content = {}
    local quote_lines = 0
    local q = M.quote(m)
    if q then
      content[1] = text.fit("↳ " .. q, inner_max)
      quote_lines = 1
    end
    for _, l in ipairs(wrap(body, inner_max)) do
      content[#content + 1] = l
    end
    local inner = math.min(inner_max, math.max(dw(who) + 2, #time + 2, 8))
    for _, l in ipairs(content) do
      inner = math.max(inner, dw(l))
    end
    local pic = image_cols and image_cols(m)
    if pic then
      inner = math.max(inner, pic)
    end
    inner = math.min(inner, inner_max)
    local box_w = inner + 4
    local indent = m.from_me and string.rep(" ", math.max(0, width - box_w - 1)) or ""
    local bubble = m.from_me and "WhatsAppBubbleMe" or "WhatsAppBubble"

    add("", nil)
    local head = indent .. "╭─ " .. who .. " " .. string.rep("─", inner - dw(who) - 1) .. "╮"
    local n = add(head, m, bubble, #indent)
    spans[#spans + 1] = { n - 1, #indent + #"╭─ ", #indent + #"╭─ " + #who, m.from_me and "WhatsAppMe" or "WhatsAppSender" }
    for i, l in ipairs(content) do
      local padded = l .. string.rep(" ", inner - dw(l))
      local n2 = add(indent .. "│ " .. padded .. " │", m, bubble, #indent)
      if i <= quote_lines then
        spans[#spans + 1] = { n2 - 1, #indent + #"│ ", #indent + #"│ " + #l, "WhatsAppQuote" }
      elseif tag and i == quote_lines + 1 then
        spans[#spans + 1] = { n2 - 1, #indent + #"│ ", #indent + #"│ " + #tag, "WhatsAppMedia" }
      end
    end
    local foot_prefix = indent .. "╰" .. string.rep("─", inner - #time - 1) .. " "
    local n3 = add(foot_prefix .. time .. " ─╯", m, bubble, #indent)
    spans[#spans + 1] = { n3 - 1, #foot_prefix, #foot_prefix + #time, "WhatsAppTime" }
  end
  return lines, owners, spans
end

-- Typing indicator as an incoming bubble whose body is one to three dots,
-- frame cycling 1..3. Same box rules as M.bubbles so it lines up.
function M.typing_bubble(who, frame, width)
  local max_box = math.max(24, math.floor(width * 0.7))
  local inner_max = max_box - 4
  who = text.fit(text.name(who), inner_max - 1)
  local dots = string.rep("·", ((frame - 1) % 3) + 1)
  local inner = math.min(inner_max, math.max(dw(who) + 2, 8))
  return {
    "╭─ " .. who .. " " .. string.rep("─", inner - dw(who) - 1) .. "╮",
    "│ " .. dots .. string.rep(" ", inner - dw(dots)) .. " │",
    "╰" .. string.rep("─", inner + 2) .. "╯",
  }
end

-- Typing indicator for the lines layout: "Alice is typing..".
function M.typing_line(who, frame, media)
  local verb = media == "audio" and "is recording audio" or "is typing"
  return text.name(who) .. " " .. verb .. string.rep(".", ((frame - 1) % 3) + 1)
end

-- Conversation: returns lines, a message per line (nil for separators), and
-- highlight spans {line, col_start, col_end, group}.
function M.conversation(messages, is_group)
  local lines, owners, spans = {}, {}, {}
  local last_day = nil
  local function add(text, owner)
    lines[#lines + 1] = text
    owners[#lines] = owner
    return #lines
  end
  for _, m in ipairs(messages) do
    local day = day_of(m.ts)
    if day ~= last_day then
      local label = os.date("%a %d %b %Y", m.ts)
      local n = add("── " .. label .. " ──", nil)
      spans[#spans + 1] = { n - 1, 0, -1, "WhatsAppSeparator" }
      last_day = day
    end
    local q = M.quote(m)
    if q then
      local n = add("      ↳ " .. q, m)
      spans[#spans + 1] = { n - 1, 0, -1, "WhatsAppQuote" }
    end
    local time = os.date("%H:%M", m.ts)
    local who = m.from_me and "me" or (m.sender_name ~= "" and m.sender_name or m.sender)
    if not is_group and not m.from_me then
      who = m.sender_name ~= "" and m.sender_name or who
    end
    who = text.name(who)
    local prefix = time .. " " .. who .. ": "
    local body = m.text or ""
    local tag = media_tag(m)
    if tag then
      body = body ~= "" and (tag .. " " .. body) or tag
    end
    local first, last = true, nil
    for part in (body .. "\n"):gmatch("(.-)\n") do
      if first then
        local n = add(prefix .. part, m)
        spans[#spans + 1] = { n - 1, 0, #time, "WhatsAppTime" }
        spans[#spans + 1] = { n - 1, #time + 1, #time + 1 + #who + 1, m.from_me and "WhatsAppMe" or "WhatsAppSender" }
        if tag then
          spans[#spans + 1] = { n - 1, #prefix, #prefix + #tag, "WhatsAppMedia" }
        end
        first = false
        last = n
      else
        last = add(string.rep(" ", #prefix) .. part, m)
      end
    end
    if m.edited then
      local from = #lines[last] + 1
      lines[last] = lines[last] .. " edited"
      spans[#spans + 1] = { last - 1, from, -1, "WhatsAppTime" }
    end
  end
  return lines, owners, spans
end

-- Web links in message text. Punctuation that ends the sentence stays out,
-- as the phone does, and so does a closing bracket the link never opened.
function M.urls(text)
  local out = {}
  for u in (text or ""):gmatch("https?://[^%s<>\"]+") do
    while true do
      local last = u:sub(-1)
      local _, opens = u:gsub("%(", "")
      local _, closes = u:gsub("%)", "")
      if last:match("[%.,;:!?'\"]") or (last == ")" and closes > opens) then
        u = u:sub(1, -2)
      else
        break
      end
    end
    if #u > #"https://" then
      out[#out + 1] = u
    end
  end
  return out
end

-- Where each link sits in the rendered lines, as { row, start, end, url }
-- with 0-based rows and byte columns. Wrapping cuts a long link into pieces
-- on consecutive rows; every piece carries the whole URL, so any of them
-- opens it.
function M.link_spans(lines, owners)
  local rows_of, order = {}, {}
  for i, m in pairs(owners) do
    if not rows_of[m] then
      rows_of[m] = {}
      order[#order + 1] = m
    end
    table.insert(rows_of[m], i)
  end
  local out = {}
  for _, m in ipairs(order) do
    local rows = rows_of[m]
    table.sort(rows)
    local idx, col = 1, 1
    for _, u in ipairs(M.urls(m.text)) do
      local pos, prev = 1, nil
      local from_idx, from_col = idx, col
      while idx <= #rows and pos <= #u do
        local r = rows[idx]
        local line = lines[r] or ""
        -- A piece after the first can only be the start of the next row.
        if prev and r ~= prev + 1 then
          break
        end
        local want = u:sub(pos, pos + math.min(#u - pos, prev and 7 or 11))
        local s = line:find(want, prev and 1 or col, true)
        if s then
          local k = 0
          while pos + k <= #u and line:byte(s + k) == u:byte(pos + k) do
            k = k + 1
          end
          out[#out + 1] = { r - 1, s - 1, s - 1 + k, u }
          pos, prev, col = pos + k, r, s + k
          if pos > #u then
            break
          end
        elseif prev then
          break
        end
        idx, col = idx + 1, 1
      end
      -- Not drawn (cut from a quote, say): the next link starts where this
      -- one would have.
      if not prev then
        idx, col = from_idx, from_col
      end
    end
  end
  return out
end

return M
