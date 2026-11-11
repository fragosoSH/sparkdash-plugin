--!nonstrict
-- Bar widget: the counters enabled in plugin settings, for one machine.
-- Readings on a 0–100 scale (°C or %) draw as a vertical pill gauge beside their value.

local client = require("./client.luau")

local snapshot = noctalia.state.get("status")

local PILLS = {
  temp = { glyph = "temperature", unit = "°" },
  cpu = { glyph = "cpu", unit = "°" },
  gpu = { glyph = "device-desktop", unit = "%" },
  vram = { glyph = "memory", unit = "%" },
  memory = { glyph = "server-2", unit = "%" },
}

-- sparkDash dark-theme --color-warning / --color-danger.
local ALERT = { warning = "#ff914d", danger = "#ff5d62" }

-- Track with a level pinned to the bottom, sized like the shell's sysmon gauges.
-- Containers do not clip, so the level is rounded and a flat cap squares its top.
local function gauge(key, ratio, color)
  local w, h = 5, 12
  local level = math.max(2, math.floor(h * ratio + 0.5))
  return ui.column({
    key = key,
    width = w,
    height = h,
    minWidth = w,
    minHeight = h,
    radius = w / 2,
    fill = "on_surface/0.25",
    justify = "end",
    align = "stretch",
  }, {
    ui.column({
      key = key .. ":level",
      width = w,
      height = level,
      radius = w / 2,
      fill = color,
      align = "stretch",
      visible = ratio > 0,
    }, {
      ui.box({ key = key .. ":cap", height = math.min(level, w / 2), fill = color }),
    }),
  })
end

local function readingText(readings, id)
  local item = type(readings) == "table" and readings[id] or nil
  if type(item) == "table" and type(item.text) == "string" and item.text ~= "" then
    return item.text
  end
  return "—"
end

local function roleText(row)
  if type(row) ~= "table" then
    return ""
  end
  if row.role == "head" then
    return noctalia.tr("role_head")
  end
  if row.role == "worker" then
    if type(row.headName) == "string" and row.headName ~= "" then
      return noctalia.tr("worker_of", { name = row.headName })
    end
    return noctalia.tr("role_worker")
  end
  return ""
end

-- Running or queued work, or tokens flowing.
local function isBusy(row)
  if row.online ~= true then
    return false
  end
  if (row.runningKnown and row.running > 0) or (row.queuedKnown and row.queued > 0) then
    return true
  end
  local tps = type(row.readings) == "table" and row.readings.tps or nil
  return type(tps) == "table" and tps.known == true and type(tps.value) == "number" and tps.value > 0
end

local function chip(key, id, item, vertical)
  local spec = PILLS[id]
  if spec == nil or type(item.value) ~= "number" then
    return ui.label({ key = key, text = item.text, color = "on_surface", maxLines = 1 })
  end
  local alert = ALERT[item.alert]
  local pill = gauge(key .. ":pill", math.clamp(item.value / 100, 0, 1), alert or "on_surface")
  local label = ui.label({
    key = key .. ":text",
    text = string.format("%d%s", math.floor(item.value + 0.5), spec.unit),
    color = alert or "on_surface",
    maxLines = 1,
  })
  if vertical then
    return ui.column({ key = key, gap = 2, align = "center" }, { pill, label })
  end
  return ui.row({ key = key, gap = 4, align = "center" }, {
    ui.glyph({ key = key .. ":glyph", name = spec.glyph, size = 13, color = alert or "on_surface" }),
    pill,
    label,
  })
end

-- One machine's enabled readings. Unknown readings are left out, as before.
local function appendMachine(children, row, vertical, prefix)
  if row.online ~= true then
    table.insert(children, ui.label({ key = prefix .. "off", text = noctalia.tr("offline_short"), color = "error" }))
    return
  end
  local count = 0
  for _, id in ipairs(client.enabledCounters()) do
    local item = type(row.readings) == "table" and row.readings[id] or nil
    if type(item) == "table" and item.known == true then
      table.insert(children, chip(prefix .. id, id, item, vertical))
      count += 1
    end
  end
  if count == 0 then
    table.insert(children, ui.label({ key = prefix .. "none", text = "—", color = "on_surface_variant" }))
  end
end

local function showState(color, text, tooltip)
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, {
    ui.glyph({ key = "glyph", name = "bolt", color = color }),
    ui.label({ key = "state", text = text, color = color }),
  }))
  barWidget.setTooltip(tooltip)
end

local function render()
  if snapshot == nil then
    showState("on_surface", "…", noctalia.tr("loading"))
    return
  end
  if snapshot.error ~= nil then
    showState("error", "!", noctalia.tr(snapshot.error, snapshot.errorArgs))
    return
  end

  local selected = snapshot.selected
  if selected == nil then
    showState("error", "!", noctalia.tr("not_found", { machine = snapshot.machine or "" }))
    return
  end

  local vertical = barWidget.isVertical()
  local workers = selected.role == "head" and type(selected.workers) == "table" and selected.workers or {}
  local busy = isBusy(selected)
  for _, worker in ipairs(workers) do
    busy = busy or isBusy(worker)
  end
  local glyphColor = selected.online ~= true and "error" or (busy and "primary" or "on_surface")

  local children = { ui.glyph({ key = "glyph", name = "bolt", color = glyphColor }) }
  if not vertical then
    table.insert(children, ui.label({
      key = "head:name",
      text = selected.name ~= "" and selected.name or selected.id,
      color = "on_surface_variant",
      maxLines = 1,
    }))
  end
  appendMachine(children, selected, vertical, "head:")
  for index, worker in ipairs(workers) do
    local prefix = "w" .. index .. ":"
    table.insert(children, ui.box({
      key = prefix .. "divider",
      width = vertical and 14 or 1,
      height = vertical and 1 or 14,
      fill = "outline_variant",
    }))
    if not vertical then
      table.insert(children, ui.label({
        key = prefix .. "name",
        text = worker.name ~= "" and worker.name or worker.id,
        color = "on_surface_variant",
        maxLines = 1,
      }))
    end
    appendMachine(children, worker, vertical, prefix)
  end
  local container = vertical and ui.column or ui.row
  barWidget.render(container({ gap = vertical and 4 or 8, align = "center" }, children))

  local rows = {
    { key = noctalia.tr("machine"), value = selected.name ~= "" and selected.name or selected.id },
    { key = noctalia.tr("status"), value = selected.online and noctalia.tr("online") or noctalia.tr("offline") },
  }
  local role = roleText(selected)
  if role ~= "" then
    table.insert(rows, { key = noctalia.tr("role"), value = role })
  end
  for _, id in ipairs(client.enabledCounters()) do
    table.insert(rows, { key = noctalia.tr("counters." .. id), value = readingText(selected.readings, id) })
  end
  if type(selected.lines) == "table" then
    for _, line in ipairs(selected.lines) do
      table.insert(rows, { key = line.label, value = client.counterText(line) })
    end
  end
  if selected.role == "head" and type(selected.workers) == "table" then
    for _, worker in ipairs(selected.workers) do
      local name = worker.name ~= "" and worker.name or worker.id
      local value = worker.online == true and client.summary(worker.readings, true) or noctalia.tr("offline")
      table.insert(rows, { key = name, value = value })
    end
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("status", function(value)
  snapshot = value
  render()
end)

function update()
  noctalia.setUpdateInterval(2000)
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.togglePanel("fragosoSH/sparkdash:status")
end
