-- Tests for app.lua without an edge client: run with `lua5.3 tests/test_app.lua` from the repository root.
-- The edge client's globals (cfg, app, log, json) and the file system, commands and broker are faked.

local FILE = "/etc/mosquitto/conf.d/zz-edge-broker-settings.conf"
local failures, count = 0, 0

local function check(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then print("ok   " .. name) else failures = failures + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end

local function eq(a, b, what)
  if a ~= b then error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2) end
end

--- Loads app.lua in a fake edge client. opts: files, service ("systemd" | "supervisord" | nil), up (function
--- returning whether the broker answers after the n-th restart), cfg.
local function load_app(opts)
  local fake = { files = opts.files or {}, commands = {}, logs = {}, restarts = 0 }
  local function fopen(path, mode)
    if mode:sub(1, 1) == "r" then
      local data = fake.files[path]
      if data == nil then return nil, "no such file" end
      return { read = function() return data end, close = function() end }
    end
    local buf = {}
    return {
      write = function(_, s) buf[#buf + 1] = s end,
      close = function() fake.files[path] = table.concat(buf) end,
    }
  end
  local fos = {
    execute = function(cmd)
      fake.commands[#fake.commands + 1] = cmd
      if cmd:match("^sleep") then return true end
      if cmd:match("command %-v systemctl") or cmd:match("systemctl is%-enabled") then return opts.service == "systemd" end
      if cmd:match("command %-v supervisorctl") or cmd:match("supervisorctl status") then return opts.service == "supervisord" end
      if cmd:match("restart mosquitto") then fake.restarts = fake.restarts + 1 return true end
      return false
    end,
    rename = function(a, b) fake.files[b] = fake.files[a] fake.files[a] = nil return true end,
    remove = function(p) fake.files[p] = nil return true end,
  }
  local socket = {
    connect = function()
      return { connect = function() return (opts.up or function() return true end)(fake.restarts, fake.files[FILE]) and true or nil end, close = function() end }
    end,
  }
  local env = setmetatable({
    io = { open = fopen },
    os = setmetatable(fos, { __index = os }),
    require = function(m) if m == "cqueues.socket" then return socket end return require(m) end,
    cfg = opts.cfg or {},
    app = { id = 7 },
    BROKER_SETTINGS_TEST = true,
    json = { null = {} },
    log = {
      i = function(f, ...) fake.logs[#fake.logs + 1] = "I " .. string.format(f, ...) end,
      e = function(f, ...) fake.logs[#fake.logs + 1] = "E " .. string.format(f, ...) end,
    },
  }, { __index = _G })
  local chunk = assert(loadfile("app.lua", "t", env))
  local M = chunk()
  return M, env, fake
end

-- ---- settings and rendering ----------------------------------------------------------------------------------

check("defaults need no file", function()
  local M = load_app({})
  eq(M.render(M.settings({}), 7), nil, "render")
  eq(M.render(M.settings({ max_queued_messages = 1000, max_queued_mb = 0, autosave_interval = 1800 }), 7), nil, "render")
end)

check("changed values are written, defaults left out", function()
  local M = load_app({})
  local text = M.render(M.settings({ max_queued_messages = "100000", max_queued_mb = 50, autosave_interval = 1800 }), 7)
  assert(text:find("\nmax_queued_messages 100000\n", 1, true), text)
  assert(text:find("\nmax_queued_bytes 52428800\n", 1, true), text)
  assert(not text:find("autosave_interval", 1, true), text)
  assert(not text:find("queue_qos0_messages", 1, true), text)
  assert(text:find("instance 7", 1, true), text)
end)

check("values are limited and cleaned", function()
  local M = load_app({})
  local s = M.settings({ max_queued_messages = -5, max_queued_mb = 99999, autosave_interval = 1, queue_qos0_messages = "true" })
  eq(s.max_queued_messages, 0, "messages")
  eq(s.max_queued_bytes, 4096 * 1024 * 1024, "bytes")
  eq(s.autosave_interval, 10, "autosave")
  eq(s.queue_qos0_messages, true, "qos0")
  s = M.settings({ max_queued_messages = "12.9", autosave_interval = "x" })
  eq(s.max_queued_messages, 12, "rounded down")
  eq(s.autosave_interval, 1800, "not a number gives the default")
end)

check("nothing but integers and booleans reach the file", function()
  local M = load_app({})
  local text = M.render(M.settings({ max_queued_messages = "5\ninclude_dir /tmp", queue_qos0_messages = "yes\nx" }), 7)
  eq(text, nil, "an injected value is not a number, so the default applies and no file is written")
end)

-- ---- onStart -------------------------------------------------------------------------------------------------

check("writes the file and restarts with systemd", function()
  local _, env, fake = load_app({ service = "systemd", cfg = { max_queued_messages = 50000 } })
  env.onStart()
  assert(fake.files[FILE]:find("max_queued_messages 50000", 1, true))
  eq(fake.restarts, 1, "restarts")
  local restarted = false
  for _, c in ipairs(fake.commands) do if c:match("^systemctl restart mosquitto") then restarted = true end end
  assert(restarted, "systemctl restart")
end)

check("supervisord in the Docker edge client", function()
  local _, env, fake = load_app({ service = "supervisord", cfg = { max_queued_messages = 50000 } })
  env.onStart()
  local restarted = false
  for _, c in ipairs(fake.commands) do if c:match("^supervisorctl restart mosquitto") then restarted = true end end
  assert(restarted, "supervisorctl restart")
end)

check("unchanged settings do not restart the broker", function()
  local M = load_app({})
  local text = M.render(M.settings({ max_queued_messages = 50000 }), 7)
  local _, env, fake = load_app({ service = "systemd", cfg = { max_queued_messages = 50000 }, files = { [FILE] = text } })
  env.onStart()
  eq(fake.restarts, 0, "restarts")
end)

check("back to the defaults removes the file", function()
  local _, env, fake = load_app({ service = "systemd", cfg = {}, files = { [FILE] = "max_queued_messages 5\n" } })
  env.onStart()
  eq(fake.files[FILE], nil, "file")
  eq(fake.restarts, 1, "restarts")
end)

check("a broker that does not come back gets the previous file", function()
  local previous = "max_queued_messages 2000\n"
  local _, env, fake = load_app({
    service = "systemd",
    cfg = { autosave_interval = 60 },
    files = { [FILE] = previous },
    up = function(_, content) return content == previous end, -- the new file breaks the broker
  })
  env.onStart()
  eq(fake.files[FILE], previous, "restored")
  eq(fake.restarts, 2, "restarts")
  local logged = false
  for _, l in ipairs(fake.logs) do if l:match("^E .*previous settings are restored") then logged = true end end
  assert(logged, "error logged")
end)

check("without systemd or supervisord nothing changes", function()
  local _, env, fake = load_app({ service = nil, cfg = { max_queued_messages = 50000 } })
  env.onStart()
  eq(fake.files[FILE], nil, "file")
  eq(fake.restarts, 0, "restarts")
end)

check("the code returns nothing in the edge client", function()
  -- iotopen-rt reports anything the app's code returns as "error running app code"
  local env = setmetatable({ cfg = {}, app = { id = 1 }, log = { i = print, e = print }, json = { null = {} } }, { __index = _G })
  local chunk = assert(loadfile("app.lua", "t", env))
  eq(select("#", chunk()), 0, "returned values")
end)

print(string.format("%d of %d passed", count - failures, count))
os.exit(failures == 0 and 0 or 1)

