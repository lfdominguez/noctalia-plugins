--!nonstrict
-- Claude Code writes ~/.claude/sessions/<pid>.json with status busy|idle|waiting (+ waitingFor).
-- Files of crashed sessions linger, so keep only those whose pid is still alive.
-- Per-session details (title, current tool, cost, ...) come from the transcript via details.sh,
-- re-read only when the transcript's mtime changes. Recently closed sessions come from recent.sh.
local DIR = noctalia.expandPath("~/.claude/sessions")
local PROJECTS = noctalia.expandPath("~/.claude/projects")
local PLUGIN = noctalia.pluginDir()
local RANK = { waiting = 0, busy = 1, idle = 2 }
local RECENT_EVERY = 30 -- polls (~1 min)
-- Plan limits. If the claude-dashboard plugin is installed, its statusline caches Anthropic's
-- oauth/usage response here whenever a session redraws, and we just read it. When that cache is
-- missing or stale we call the API ourselves via limits.sh (Claude Code's OAuth token, read-only).
local FRESH_MS = 5 * 60000 -- dashboard cache counts as fresh / min gap between our own API calls
local LIMITS_DIR = noctalia.expandPath("~/.cache/claude-dashboard")
local LIMITS = { { key = "five_hour", label = "5h" }, { key = "seven_day", label = "7d" },
  { key = "seven_day_fable", label = "Fable 7d" }, { key = "seven_day_sonnet", label = "Sonnet 7d" } }

local details = {} -- pid -> { mtime, data, pending }
local terminals = {} -- pid -> { kind = "kitty" | TERM_PROGRAM | "terminal" }; a process's env never changes

-- Which terminal hosts the session: kitty sessions get exact tab focusing (see focus.sh).
local function terminalOf(pid)
  local t = terminals[pid]
  if t then return t end
  local env = noctalia.readFile("/proc/" .. tostring(pid) .. "/environ") or ""
  if string.find(env, "KITTY_WINDOW_ID=", 1, true) then
    t = { kind = "kitty" }
  else
    t = { kind = string.match(env, "TERM_PROGRAM=([^%z]+)") or "terminal" }
  end
  terminals[pid] = t
  return t
end
local tracked = {} -- pid -> { status, busySince }
local current = {}
local ticks = 0
local recentPending = false

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then return fallback end
  return v
end

local function publish()
  for _, s in ipairs(current) do
    local d = details[s.pid]
    s.d = d and d.data or nil
  end
  noctalia.state.set("sessions", current)
end

local function refreshDetails(s)
  local path = `{PROJECTS}/{(string.gsub(s.cwd, "[^%w]", "-"))}/{s.sessionId}.jsonl`
  local info = noctalia.fileInfo(path)
  if not info then return end
  local d = details[s.pid] or {}
  details[s.pid] = d
  if d.pending or d.mtime == info.mtime then return end
  d.pending = true
  local started = noctalia.runAsync({ PLUGIN .. "/details.sh", path, s.sessionId }, function(r)
    d.pending = false
    local data = r.exitCode == 0 and noctalia.json.decode(r.stdout) or nil
    if type(data) == "table" then
      d.mtime = info.mtime
      d.data = data
      publish()
    end
  end, 15000)
  if not started then d.pending = false end
end

local function refreshRecent()
  local count = tonumber(cfg("recent_count", 8)) or 8
  if count <= 0 then noctalia.state.set("recent", {}) return end
  if recentPending then return end
  recentPending = true
  local started = noctalia.runAsync({ PLUGIN .. "/recent.sh", tostring(count + 10) }, function(r)
    recentPending = false
    local list = r.exitCode == 0 and noctalia.json.decode(r.stdout) or nil
    if type(list) ~= "table" then return end
    local live = {}
    for _, s in ipairs(current) do live[s.sessionId] = true end
    local out = {}
    for _, x in ipairs(list) do
      if not live[x.sessionId] and #out < count then out[#out + 1] = x end
    end
    noctalia.state.set("recent", out)
  end, 15000)
  if not started then recentPending = false end
end

-- "2026-10-01T20:29:59.766+00:00" -> epoch ms (UTC; honours the offset).
local function isoToMs(iso)
  local y, mo, d, h, mi, sec, sign, oh, om = string.match(iso or "",
    "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[%.%d]*([%+%-]?)(%d*):?(%d*)")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- days since epoch (Howard Hinnant's days_from_civil)
  if mo <= 2 then y -= 1 end
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * ((mo + 9) % 12) + 2) // 5 + d - 1
  local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
  local secs = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
  if sign ~= "" and oh ~= "" then
    local off = tonumber(oh) * 3600 + (tonumber(om) or 0) * 60
    secs = sign == "+" and secs - off or secs + off
  end
  return secs * 1000
end

local api = { windows = nil, at = 0, lastTry = -math.huge, pending = false }

local function publishLimits(windows, updated, source)
  local out = { updated = updated, source = source, windows = {} }
  for _, w in ipairs(windows) do
    if w.percent then
      out.windows[#out.windows + 1] = { label = w.label, percent = w.percent, resetsAt = isoToMs(w.resets_at) }
    end
  end
  noctalia.state.set("limits", out)
end

-- Newest claude-dashboard cache as { windows, timestamp }, or nil.
local function dashboardLimits()
  local best
  for _, name in ipairs(noctalia.listDir(LIMITS_DIR) or {}) do
    local path = string.find(name, "/") and name or LIMITS_DIR .. "/" .. name
    if string.match(path, "/cache%-[^/]*%.json$") then
      local c = noctalia.json.decode(noctalia.readFile(path) or "")
      if type(c) == "table" and type(c.data) == "table" and (not best or (c.timestamp or 0) > (best.timestamp or 0)) then
        best = c
      end
    end
  end
  if not best then return nil end
  local windows = {}
  for _, l in ipairs(LIMITS) do
    local w = best.data[l.key]
    if type(w) == "table" then windows[#windows + 1] = { label = l.label, percent = w.utilization, resets_at = w.resets_at } end
  end
  return { windows = windows, timestamp = best.timestamp or 0 }
end

local function fetchApiLimits()
  if api.pending then return end
  api.pending, api.lastTry = true, noctalia.nowMs()
  local started = noctalia.runAsync({ PLUGIN .. "/limits.sh" }, function(r)
    api.pending = false
    local list = r.exitCode == 0 and noctalia.json.decode(r.stdout) or nil
    if type(list) == "table" then
      api.windows, api.at = list, noctalia.nowMs()
      publishLimits(list, api.at, "api")
    elseif (r.stderr or "") ~= "" then
      noctalia.log("claude-sessions: limits API: " .. noctalia.string.trim(r.stderr))
    end
  end, 20000)
  if not started then api.pending = false end
end

local function readLimits()
  local now = noctalia.nowMs()
  local dash = dashboardLimits()
  if dash and now - dash.timestamp < FRESH_MS then
    publishLimits(dash.windows, dash.timestamp, "claude-dashboard")
    return
  end
  -- Dashboard absent or stale: show the newest data we have, and refresh from the API.
  if api.windows and (not dash or api.at > dash.timestamp) then
    publishLimits(api.windows, api.at, "api")
  elseif dash then
    publishLimits(dash.windows, dash.timestamp, "claude-dashboard")
  end
  if now - api.lastTry >= FRESH_MS then fetchApiLimits() end
end

local function label(s)
  local d = details[s.pid]
  return d and d.data and d.data.title or s.name
end

local function dur(ms)
  local m = math.floor(ms / 60000)
  if m < 60 then return `{m}m` end
  return `{m // 60}h {m % 60}m`
end

-- Notifications + bookkeeping. Returns true when a session disappeared (so Recent should refresh).
local function track(sessions)
  local alive, gone = {}, false
  for _, s in ipairs(sessions) do
    alive[s.pid] = true
    local t = tracked[s.pid]
    if t then
      if t.status ~= "waiting" and s.status == "waiting" and cfg("notify_waiting", true) then
        noctalia.notify("Claude needs you", label(s) .. (s.waitingFor ~= "" and (": " .. s.waitingFor) or ""))
      elseif t.status == "busy" and s.status == "idle" and cfg("notify_finished", true) and t.busySince then
        local took = s.since - t.busySince
        if took >= (tonumber(cfg("finished_min_minutes", 2)) or 2) * 60000 then
          noctalia.notify("Claude finished", `{label(s)} · {dur(took)}`)
        end
      end
    else
      t = {}
      tracked[s.pid] = t
    end
    if s.status == "busy" and t.status ~= "busy" and t.status ~= "waiting" then t.busySince = s.since end
    t.status = s.status
  end
  for pid in pairs(tracked) do
    if not alive[pid] then tracked[pid] = nil; details[pid] = nil; terminals[pid] = nil; gone = true end
  end
  return gone
end

local function poll()
  local hideMs = (tonumber(cfg("hide_idle_hours", 0)) or 0) * 3600000
  local now = noctalia.nowMs()
  local sessions = {}
  for _, name in ipairs(noctalia.listDir(DIR) or {}) do
    local path = string.find(name, "/") and name or DIR .. "/" .. name
    if string.sub(path, -5) == ".json" then
      local s = noctalia.json.decode(noctalia.readFile(path) or "")
      if type(s) == "table" and s.pid and noctalia.fileExists("/proc/" .. tostring(s.pid)) then
        sessions[#sessions + 1] = {
          pid = s.pid,
          sessionId = s.sessionId or "",
          name = s.name or tostring(s.pid),
          cwd = s.cwd or "",
          status = s.status or "idle",
          waitingFor = s.waitingFor or "",
          since = s.statusUpdatedAt or s.updatedAt or 0,
          bridge = s.bridgeSessionId,
          terminal = terminalOf(s.pid).kind,
        }
      end
    end
  end
  local gone = track(sessions)
  local shown = {}
  for _, s in ipairs(sessions) do
    if not (hideMs > 0 and s.status == "idle" and now - s.since > hideMs) then shown[#shown + 1] = s end
  end
  table.sort(shown, function(a, b)
    local ra, rb = RANK[a.status] or 3, RANK[b.status] or 3
    if ra ~= rb then return ra < rb end
    return a.since > b.since
  end)
  current = shown
  for _, s in ipairs(sessions) do refreshDetails(s) end
  publish()
  readLimits()
  ticks += 1
  if gone or ticks % RECENT_EVERY == 1 then refreshRecent() end
end

noctalia.state.watch("command", function(v)
  if type(v) == "table" and v.action == "refresh" then ticks = 0; poll() end
end)
function update() poll() end
function onIpc(event) if event == "refresh" then ticks = 0; poll() end end
function onConfigChanged() ticks = 0; poll() end
noctalia.setUpdateInterval(2000)
poll()
