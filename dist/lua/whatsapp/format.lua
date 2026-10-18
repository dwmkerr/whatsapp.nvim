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

-- Chat list: "● Name              12:40". Returns lines, jids per line, and
-- which lines are unread.
function M.chat_list(chats, width)
  local lines, jids, unread = {}, {}, {}
  for i, c in ipairs(chats) do
    local mark = c.unread > 0 and "●" or " "
    local time = M.short_time(c.last_ts)
    local name_width = math.max(4, width - 2 - #time - 1)
    lines[i] = mark .. " " .. pad_right(text.name(c.name ~= "" and c.name or c.jid), name_width) .. " " .. time
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
  -- A voice note's filename is always a generic audio.ogg; the duration and
  -- waveform say more.
  if m.media_type ~= "voice" and m.filename and m.filename ~= "" then
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
function M.bubbles(messages, is_group, width)
  local lines, owners, spans = {}, {}, {}
  local last_day = nil
  local max_box = math.max(24, math.floor(width * 0.7))
  local inner_max = max_box - 4
  local function add(text, owner, group)
    lines[#lines + 1] = text
    owners[#lines] = owner
    if group then
      spans[#spans + 1] = { #lines - 1, 0, -1, group }
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
    local time = os.date("%H:%M", m.ts)
    local body = m.text or ""
    local tag = media_tag(m)
    if tag then
      body = body ~= "" and (tag .. " " .. body) or tag
    end
    local content = {}
    local quote_lines = 0
    if m.quoted_text and m.quoted_text ~= "" then
      local q = m.quoted_text:gsub("\n", " ")
      content[1] = "↳ " .. vim.fn.strcharpart(q, 0, inner_max - 2)
      quote_lines = 1
    end
    for _, l in ipairs(wrap(body, inner_max)) do
      content[#content + 1] = l
    end
    local inner = math.min(inner_max, math.max(dw(who) + 2, #time + 2, 8))
    for _, l in ipairs(content) do
      inner = math.max(inner, dw(l))
    end
    inner = math.min(inner, inner_max)
    local box_w = inner + 4
    local indent = m.from_me and string.rep(" ", math.max(0, width - box_w - 1)) or ""
    local bubble = m.from_me and "WhatsAppBubbleMe" or "WhatsAppBubble"

    add("", nil)
    local head = indent .. "╭─ " .. who .. " " .. string.rep("─", inner - dw(who) - 1) .. "╮"
    local n = add(head, m, bubble)
    spans[#spans + 1] = { n - 1, #indent + #"╭─ ", #indent + #"╭─ " + #who, m.from_me and "WhatsAppMe" or "WhatsAppSender" }
    for i, l in ipairs(content) do
      local padded = l .. string.rep(" ", inner - dw(l))
      local n2 = add(indent .. "│ " .. padded .. " │", m, bubble)
      if i <= quote_lines then
        spans[#spans + 1] = { n2 - 1, #indent + #"│ ", #indent + #"│ " + #l, "WhatsAppQuote" }
      elseif tag and i == quote_lines + 1 then
        spans[#spans + 1] = { n2 - 1, #indent + #"│ ", #indent + #"│ " + #tag, "WhatsAppMedia" }
      end
    end
    local foot_prefix = indent .. "╰" .. string.rep("─", inner - #time - 1) .. " "
    local n3 = add(foot_prefix .. time .. " ─╯", m, bubble)
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
    if m.quoted_text and m.quoted_text ~= "" then
      local q = m.quoted_text:gsub("\n", " ")
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
    local first = true
    for part in (body .. "\n"):gmatch("(.-)\n") do
      if first then
        local n = add(prefix .. part, m)
        spans[#spans + 1] = { n - 1, 0, #time, "WhatsAppTime" }
        spans[#spans + 1] = { n - 1, #time + 1, #time + 1 + #who + 1, m.from_me and "WhatsAppMe" or "WhatsAppSender" }
        if tag then
          spans[#spans + 1] = { n - 1, #prefix, #prefix + #tag, "WhatsAppMedia" }
        end
        first = false
      else
        add(string.rep(" ", #prefix) .. part, m)
      end
    end
  end
  return lines, owners, spans
end

return M
