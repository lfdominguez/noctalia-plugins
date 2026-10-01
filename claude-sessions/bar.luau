--!nonstrict
local sessions = noctalia.state.get("sessions") or {}
local accounts = noctalia.state.get("accounts") or {}
local style = noctalia.getConfig("bar_style") or "dots"
local COLOR = { waiting = "error", busy = "primary", idle = "on_surface_variant/0.45" }
local MAX_DOTS = 8

local function resetsIn(ms)
  local left = ms and ms > noctalia.nowMs() and math.floor((ms - noctalia.nowMs()) / 60000) or nil
  if not left then return nil end
  return left >= 1440 and `{left // 1440}d {left % 1440 // 60}h` or `{left // 60}h {left % 60}m`
end

local function render()
  local multi = #accounts > 1
  local labels = {}
  for _, a in ipairs(accounts) do labels[a.dir] = a.label end

  local busy, waiting, rows = 0, 0, {}
  for _, s in ipairs(sessions) do
    if s.status == "busy" then busy += 1 elseif s.status == "waiting" then waiting += 1 end
    local d = s.d or {}
    local what = s.status == "waiting" and (s.waitingFor ~= "" and s.waitingFor or "needs input")
      or s.status == "busy" and (d.tool or "working") or "idle"
    local title = d.title or s.name
    rows[#rows + 1] = { multi and `[{labels[s.account] or "?"}] {title}` or title, what }
  end

  local vertical = barWidget.isVertical()
  local children = {
    ui.glyph({ name = waiting > 0 and "bell-ringing" or "brain", size = 15,
      color = waiting > 0 and "error" or busy > 0 and "primary" or "on_surface_variant" }),
  }
  if style == "counts" or #sessions > MAX_DOTS then
    if waiting > 0 then children[#children + 1] = ui.label({ text = tostring(waiting), fontSize = 11, fontWeight = "bold", color = "error" }) end
    if #sessions > 0 then
      children[#children + 1] = ui.label({ text = `{busy}/{#sessions}`, fontSize = 11, color = busy > 0 and "primary" or "on_surface_variant" })
    end
  else
    -- One dot per session (sessions arrive sorted waiting > busy > idle); with several accounts,
    -- one group of dots per account separated by a thin divider.
    local groups = {}
    if multi then
      for _, a in ipairs(accounts) do groups[#groups + 1] = a.dir end
    else
      groups[1] = false
    end
    for _, account in ipairs(groups) do
      local dots = {}
      for _, s in ipairs(sessions) do
        if not account or s.account == account then
          dots[#dots + 1] = ui.box({ width = 7, height = 7, radius = 4, fill = COLOR[s.status] or COLOR.idle })
        end
      end
      if #dots > 0 then
        if #children > 1 then
          children[#children + 1] = ui.box({ width = vertical and 10 or 1, height = vertical and 1 or 10, fill = "outline/0.6" })
        end
        for _, d in ipairs(dots) do children[#children + 1] = d end
      end
    end
  end
  local props = { gap = 4, align = "center" }
  barWidget.render(vertical and ui.column(props, children) or ui.row(props, children))

  if #rows == 0 then rows[1] = { "Claude", "no sessions" } end
  for _, a in ipairs(accounts) do
    for _, w in ipairs(a.limits and a.limits.windows or {}) do
      local resets = resetsIn(w.resetsAt)
      rows[#rows + 1] = { multi and `{a.label} · {w.label} limit` or `{w.label} limit`,
        `{math.floor(w.percent + 0.5)}%` .. (resets and ` · resets in {resets}` or "") }
    end
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("sessions", function(v) sessions = v or {}; render() end)
noctalia.state.watch("accounts", function(v) accounts = v or {}; render() end)
function onClick() noctalia.togglePanel("lfdominguez/claude-sessions:panel") end
-- `noctalia msg plugin lfdominguez/claude-sessions:bar focused click` toggles the panel (e.g. from a keybind)
function onIpc(ev) if ev == "click" then onClick() end end
render()
