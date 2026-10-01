--!nonstrict
-- Helpers shared by the panel and the launcher provider.
local M = {}
local PLUGIN = noctalia.pluginDir()
local HOME = noctalia.getenv("HOME") or ""

local rootSetting = noctalia.string.trim(tostring(noctalia.getConfig("work_root") or ""))
local WORK = rootSetting ~= "" and (string.gsub(noctalia.expandPath(rootSetting), "/+$", "") .. "/") or nil

-- Projects under the projects root (if set) show relative to it; anything else shows its full path.
function M.projectPath(p)
  if WORK and string.sub(p, 1, #WORK) == WORK then return string.sub(p, #WORK + 1) end
  return p
end

function M.workRoot() return WORK and string.sub(WORK, 1, -2) or HOME end

local function quote(s) return "'" .. string.gsub(s, "'", "'\\''") .. "'" end

function M.dur(s)
  s = math.max(0, math.floor(s))
  if s < 60 then return `{s}s` elseif s < 3600 then return `{s // 60}m` elseif s < 86400 then return `{s // 3600}h` end
  return `{s // 86400}d`
end

function M.ago(ms) return M.dur((noctalia.nowMs() - ms) / 1000) end

function M.transcript(cwd, sid)
  return `{HOME}/.claude/projects/{(string.gsub(cwd, "[^%w]", "-"))}/{sid}.jsonl`
end

function M.focus(pid) noctalia.runAsync({ PLUGIN .. "/focus.sh", tostring(pid) }) end

-- Runs argv (or a shell when empty) in dir: a new tab in the most recently focused kitty when
-- kitty remote control is available, otherwise Noctalia's configured terminal.
function M.launch(dir, argv)
  argv = argv or {}
  local cmd = { PLUGIN .. "/launch.sh", dir }
  for _, a in ipairs(argv) do cmd[#cmd + 1] = a end
  local function fallback()
    local words = {}
    for _, a in ipairs(argv) do words[#words + 1] = quote(a) end
    local run = #words > 0 and table.concat(words, " ") or "exec \"${SHELL:-sh}\""
    noctalia.runInTerminal(`cd {quote(dir)} && {run}`)
  end
  if not noctalia.runAsync(cmd, function(r) if r.exitCode ~= 0 then fallback() end end, 15000) then fallback() end
end

function M.resume(cwd, sid) M.launch(cwd, { "claude", "--resume", sid }) end

function M.resumeCommand(cwd, sid) return `cd '{cwd}' && claude --resume {sid}` end

return M
