--!nonstrict
local sessions = noctalia.state.get("sessions") or {}
local limits = noctalia.state.get("limits")
local style = noctalia.getConfig("bar_style") or "dots"
local COLOR = { waiting = "error", busy = "primary", idle = "on_surface_variant/0.45" }
local MAX_DOTS = 8

local function render()
  local busy, waiting, rows = 0, 0, {}
  for _, s in ipairs(sessions) do
    if s.status == "busy" then busy += 1 elseif s.status == "waiting" then waiting += 1 end
    local d = s.d or {}
    local what = s.status == "waiting" and (s.waitingFor ~= "" and s.waitingFor or "needs input")
      or s.status == "busy" and (d.tool or "working") or "idle"
    rows[#rows + 1] = { d.title or s.name, what }
  end

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
    -- one dot per session, sessions arrive sorted waiting > busy > idle
    for _, s in ipairs(sessions) do
      children[#children + 1] = ui.box({ width = 7, height = 7, radius = 4, fill = COLOR[s.status] or COLOR.idle })
    end
  end
  local props = { gap = 4, align = "center" }
  barWidget.render(barWidget.isVertical() and ui.column(props, children) or ui.row(props, children))
  if #rows == 0 then rows[1] = { "Claude", "no sessions" } end
  for _, w in ipairs(limits and limits.windows or {}) do
    local left = w.resetsAt and w.resetsAt > noctalia.nowMs() and math.floor((w.resetsAt - noctalia.nowMs()) / 60000) or nil
    local resets = left and (left >= 1440 and `{left // 1440}d {left % 1440 // 60}h` or `{left // 60}h {left % 60}m`) or nil
    rows[#rows + 1] = { `{w.label} limit`, `{math.floor(w.percent + 0.5)}%` .. (resets and ` · resets in {resets}` or "") }
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("sessions", function(v) sessions = v or {}; render() end)
noctalia.state.watch("limits", function(v) limits = v; render() end)
function onClick() noctalia.togglePanel("lfdominguez/claude-sessions:panel") end
-- `noctalia msg plugin lfdominguez/claude-sessions:bar focused click` toggles the panel (e.g. from a keybind)
function onIpc(ev) if ev == "click" then onClick() end end
render()
