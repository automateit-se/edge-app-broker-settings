-- Broker settings: sets the edge client's Mosquitto queue and persistence limits from the app's settings.
--
-- The edge client's bridge to IoT Open queues messages while the internet is down. How many is decided by
-- Mosquitto's max_queued_messages (default 1000), max_queued_bytes (default no limit) and queue_qos0_messages;
-- how often the queue is saved to disk by autosave_interval (default 1800 s). This app writes them to one file
-- of its own, /etc/mosquitto/conf.d/zz-edge-broker-settings.conf, and restarts Mosquitto when it changed.
-- Mosquitto reads conf.d alphabetically and takes the last value of a number or on/off option, so "zz-" makes these
-- values win over the same options in IoT Open's iotopen.conf (the Docker edge client sets autosave_interval 3600).
--
-- Safety, since edge apps run as root:
--   - the only file written or removed is FILE; the configuration comes from validated integers and a boolean
--   - the only commands run are fixed strings that restart Mosquitto or ask whether it runs
--   - after a restart the broker must answer on 127.0.0.1:1883, otherwise the previous file is put back
-- The file is written again at every start, so the settings survive a recreated Docker edge client, where
-- /etc/mosquitto is not kept. Settings equal to Mosquitto's defaults remove the file.

local VERSION = "0.1.0"
local FILE = "/etc/mosquitto/conf.d/zz-edge-broker-settings.conf"
local PORT = 1883
local WAIT = 15 -- seconds the broker may take to answer after a restart

-- Mosquitto's own defaults: these values need no line in the file
local DEFAULTS = { max_queued_messages = 1000, max_queued_bytes = 0, autosave_interval = 1800, queue_qos0_messages = false }
local LIMITS = {
  max_queued_messages = { 0, 10000000 },
  max_queued_mb = { 0, 4096 },
  autosave_interval = { 10, 86400 },
}

-- ---- settings ------------------------------------------------------------------------------------------------

local M = {}

--- An integer within [lo, hi], or nil when the value is missing or not a number.
local function int(v, lo, hi)
  local n = tonumber(v)
  if n == nil or n ~= n then return nil end
  n = math.floor(n)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

local function bool(v, d)
  if v == nil or (json and v == json.null) then return d end
  return v == true or v == "true" or v == 1 or v == "1"
end

--- The settings from the app's configuration, each one checked and limited.
function M.settings(c)
  c = c or {}
  local mb = int(c.max_queued_mb, table.unpack(LIMITS.max_queued_mb))
  return {
    max_queued_messages = int(c.max_queued_messages, table.unpack(LIMITS.max_queued_messages)) or DEFAULTS.max_queued_messages,
    max_queued_bytes = mb and mb * 1024 * 1024 or DEFAULTS.max_queued_bytes,
    autosave_interval = int(c.autosave_interval, table.unpack(LIMITS.autosave_interval)) or DEFAULTS.autosave_interval,
    queue_qos0_messages = bool(c.queue_qos0_messages, DEFAULTS.queue_qos0_messages),
  }
end

local ORDER = { "max_queued_messages", "max_queued_bytes", "queue_qos0_messages", "autosave_interval" }

--- The file's content, or nil when every setting is Mosquitto's default (then no file is needed).
function M.render(s, instance)
  local lines = {}
  for _, key in ipairs(ORDER) do
    local v = s[key]
    if v ~= DEFAULTS[key] then
      if type(v) == "boolean" then v = v and "true" or "false" end
      lines[#lines + 1] = key .. " " .. tostring(v)
    end
  end
  if #lines == 0 then return nil end
  return table.concat({
    "# Written by the IoT Open edge app \"Broker settings\" " .. VERSION .. " (instance " .. tostring(instance) .. ").",
    "# Change the app's settings instead of this file: the app writes it again at every start.",
    table.concat(lines, "\n"),
    "",
  }, "\n")
end

--- A short text of the settings for the log.
function M.describe(s)
  return string.format("max_queued_messages %d, max_queued_bytes %s, queue_qos0_messages %s, autosave_interval %d s",
    s.max_queued_messages, s.max_queued_bytes == 0 and "no limit" or string.format("%d MB", s.max_queued_bytes // 1048576),
    tostring(s.queue_qos0_messages), s.autosave_interval)
end

-- ---- files and commands --------------------------------------------------------------------------------------

local function readfile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("a")
  f:close()
  return data
end

local function writefile(path, data)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return os.rename(tmp, path)
end

--- Puts ``data`` in FILE, or removes FILE when ``data`` is nil.
local function apply(data)
  if data == nil then
    if readfile(FILE) == nil then return true end
    return os.remove(FILE)
  end
  return writefile(FILE, data)
end

local function run(cmd)
  local ok = os.execute(cmd .. " > /dev/null 2>&1")
  return ok == true or ok == 0
end

-- how Mosquitto is run: systemd on an edge client installed in Linux, supervisord in IoT Open's Docker edge client
local function service()
  if run("command -v systemctl") and run("systemctl is-enabled mosquitto") then
    return { name = "systemd", restart = "systemctl restart mosquitto" }
  end
  if run("command -v supervisorctl") and run("supervisorctl status mosquitto") then
    return { name = "supervisord", restart = "supervisorctl restart mosquitto" }
  end
  return nil
end

--- True when the broker accepts a TCP connection on 127.0.0.1:PORT.
local function answers()
  local ok, socket = pcall(require, "cqueues.socket")
  if not ok then return nil end
  local done, connected = pcall(function()
    local s = socket.connect({ host = "127.0.0.1", port = PORT })
    local up = s:connect(1)
    s:close()
    return up ~= nil
  end)
  return done and connected
end

--- Restarts the broker and waits until it answers. True when it does (nil when it cannot be checked).
local function restart(svc)
  if not run(svc.restart) then return false end
  for _ = 1, WAIT do
    os.execute("sleep 1")
    local up = answers()
    if up == nil then return run(svc.name == "systemd" and "systemctl is-active mosquitto" or "supervisorctl status mosquitto") end
    if up then return true end
  end
  return false
end

-- ---- the app -------------------------------------------------------------------------------------------------

function onStart()
  local instance = app and app.id or "?"
  local s = M.settings(cfg)
  local wanted = M.render(s, instance)
  local current = readfile(FILE)
  log.i("broker settings %s: %s", VERSION, M.describe(s))
  if wanted == current then
    log.i("Mosquitto already uses these settings")
    return
  end
  local svc = service()
  if svc == nil then
    log.e("found neither systemd nor supervisord running mosquitto: nothing changed")
    return
  end
  local ok, err = apply(wanted)
  if not ok then
    log.e("could not write %s: %s", FILE, tostring(err))
    return
  end
  if restart(svc) then
    log.i("Mosquitto restarted with the new settings (%s)", svc.name)
    return
  end
  -- the broker did not come back: put the previous file back so the edge client is not left without a broker
  log.e("Mosquitto did not answer on port %d after the restart: the previous settings are restored", PORT)
  apply(current)
  if restart(svc) then
    log.e("Mosquitto runs again with the previous settings. Check the values, e.g. a setting also made in another file")
  else
    log.e("Mosquitto does not answer with the previous settings either: check the edge client")
  end
end

function onExit() end

-- iotopen-rt treats anything the app's code returns as an error, so the functions are only handed out to the tests
if BROKER_SETTINGS_TEST then return M end
