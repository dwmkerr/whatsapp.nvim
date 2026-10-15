-- Talks to wa-bridge over stdio with newline-delimited JSON.
-- Requests get a numeric id and a callback; events fan out to listeners.
local M = {}

local proc = nil
local next_id = 0
local pending = {}
local listeners = {}
local partial = ""

local function dispatch_line(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    return
  end
  if msg.id then
    local cb = pending[msg.id]
    pending[msg.id] = nil
    if cb then
      cb(msg.error, msg.result)
    end
  elseif msg.event then
    for _, fn in ipairs(listeners[msg.event] or {}) do
      fn(msg.data)
    end
    for _, fn in ipairs(listeners["*"] or {}) do
      fn(msg.event, msg.data)
    end
  end
end

-- libuv callbacks cannot touch the editor, so each line is scheduled.
local function on_stdout(_, data)
  if not data then
    return
  end
  partial = partial .. data
  while true do
    local nl = partial:find("\n", 1, true)
    if not nl then
      break
    end
    local line = partial:sub(1, nl - 1)
    partial = partial:sub(nl + 1)
    if line ~= "" then
      vim.schedule(function()
        dispatch_line(line)
      end)
    end
  end
end

local stderr_tail = {}
local function on_stderr(_, data)
  if not data then
    return
  end
  for line in data:gmatch("[^\n]+") do
    table.insert(stderr_tail, line)
    if #stderr_tail > 50 then
      table.remove(stderr_tail, 1)
    end
  end
end

function M.running()
  return proc ~= nil
end

function M.start(bin, store_dir)
  if proc then
    return true
  end
  if vim.fn.executable(bin) ~= 1 then
    vim.notify("whatsapp.nvim: bridge not found at " .. bin .. " (run make)", vim.log.levels.ERROR)
    return false
  end
  proc = vim.system({ bin, "-store", store_dir }, {
    stdin = true,
    text = true,
    stdout = on_stdout,
    stderr = on_stderr,
  }, function(res)
    vim.schedule(function()
      proc = nil
      for id, cb in pairs(pending) do
        pending[id] = nil
        cb("bridge exited", nil)
      end
      for _, fn in ipairs(listeners["exit"] or {}) do
        fn({ code = res.code, stderr = stderr_tail })
      end
    end)
  end)
  return true
end

function M.stop()
  if proc then
    proc:kill("sigterm")
    proc = nil
  end
end

function M.request(method, params, cb)
  if not proc then
    if cb then
      cb("bridge not running", nil)
    end
    return
  end
  next_id = next_id + 1
  pending[next_id] = cb or function() end
  proc:write(vim.json.encode({ id = next_id, method = method, params = params or vim.empty_dict() }) .. "\n")
end

function M.on(event, fn)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end

function M.clear_listeners()
  listeners = {}
end

function M.stderr()
  return stderr_tail
end

return M
