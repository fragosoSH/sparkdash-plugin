--!nonstrict
-- The selected machine (and its workers): meters, history graphs, engine stats, and
-- every machine sparkDash knows. Click a machine row to copy the name to use as Machine.

local client = require("./client.luau")

-- sparkDash dark-theme --color-warning / --color-danger, as on the bar.
local ALERT = { warning = "#ff914d", danger = "#ff5d62" }
local CARD = "on_surface/0.05"
-- Second graph series: neutral, so it reads apart from primary in any palette.
local SECOND = "on_surface/0.6"

local function openUrl(href)
  noctalia.runAsync({ "xdg-open", href }, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("open_failed"))
    end
  end)
end

local function copyName(name)
  if name == "" or not noctalia.copyToClipboard(name, "text/plain") then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("copy_failed"))
    return
  end
  noctalia.notify(noctalia.tr("title"), noctalia.tr("copied", { name = name }))
end

local function displayName(row)
  return row.name ~= "" and row.name or row.id
end

local function roleText(row)
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

local function machineLabel(row)
  local base = row.id
  if row.name ~= "" and row.id ~= "" and row.name ~= row.id then
    base = row.name .. "  ·  " .. row.id
  elseif row.name ~= "" then
    base = row.name
  end
  local role = roleText(row)
  if role == "" then
    return base
  end
  return base .. "  ·  " .. role
end

local function reading(row, id)
  local item = type(row.readings) == "table" and row.readings[id] or nil
  if type(item) == "table" and item.known == true and type(item.value) == "number" then
    return item
  end
  return nil
end

local function round(value)
  return math.floor(value + 0.5)
end

local function clamp01(value)
  return math.max(0, math.min(1, value))
end

local function dot(key, color)
  return ui.box({ key = key, width = 8, height = 8, radius = 4, fill = color })
end

local function sectionTitle(key, text)
  return ui.label({ key = key, text = text, fontSize = 13, fontWeight = "semibold", color = "on_surface_variant" })
end

-- Meters -------------------------------------------------------------------------

local function meter(key, label, value, ratio, alert)
  local color = ALERT[alert]
  return ui.column({ key = key, flexGrow = 1, gap = 6, padding = 10, radius = 8, fill = CARD }, {
    ui.row({ align = "center", justify = "space_between", gap = 6 }, {
      ui.label({ text = label, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
      ui.label({ text = value, fontSize = 13, fontWeight = "semibold", color = color or "on_surface", maxLines = 1 }),
    }),
    ui.progress({ height = 4, radius = 2, progress = clamp01(ratio), fill = color or "primary", track = "on_surface/0.12" }),
  })
end

local function withDetail(main, detail)
  if detail == nil or detail == "" then
    return main
  end
  return main .. "  ·  " .. detail
end

local function meters(row, prefix)
  local details = row.details or {}
  local tiles = {}
  local function add(id, label, value, ratio, alert)
    table.insert(tiles, meter(prefix .. "meter:" .. id, label, value, ratio, alert))
  end

  local temp = reading(row, "temp")
  if temp then
    add("temp", noctalia.tr("counters.temp"), round(temp.value) .. "°C", temp.value / 100, temp.alert)
  end
  local cpu = reading(row, "cpu")
  if cpu then
    add("cpu", noctalia.tr("counters.cpu"), round(cpu.value) .. "°C", cpu.value / 100, cpu.alert)
  end
  local gpu = reading(row, "gpu")
  if gpu then
    add("gpu", noctalia.tr("counters.gpu"), round(gpu.value) .. "%", gpu.value / 100, gpu.alert)
  end
  local power = reading(row, "power")
  if power then
    local limit = details.powerLimit
    local value = round(power.value) .. "W"
    if limit then
      value = value .. " / " .. round(limit) .. "W"
    end
    add("power", noctalia.tr("counters.power"), value, limit and power.value / limit or 0, nil)
  end
  local vram = reading(row, "vram")
  if vram then
    add("vram", noctalia.tr("counters.vram"), withDetail(round(vram.value) .. "%", details.vramText), vram.value / 100, vram.alert)
  end
  local memory = reading(row, "memory")
  if memory then
    local label = details.memoryUnified and noctalia.tr("unified_memory") or noctalia.tr("counters.memory")
    add("memory", label, withDetail(round(memory.value) .. "%", details.memoryText), memory.value / 100, memory.alert)
  end
  local disk = details.disk
  if disk then
    local alert = disk.percent >= 90 and "danger" or (disk.percent >= 85 and "warning" or nil)
    local label = noctalia.tr("disk") .. (disk.label ~= "" and (" " .. disk.label) or "")
    add("disk", label, withDetail(round(disk.percent) .. "%", disk.text), disk.percent / 100, alert)
  end

  local rows = {}
  for index = 1, #tiles, 2 do
    table.insert(rows, ui.row({ key = prefix .. "meters:" .. index, gap = 8 }, { tiles[index], tiles[index + 1] }))
  end
  return rows
end

-- Graphs -------------------------------------------------------------------------

local function peak(values)
  local top = 0
  for _, value in ipairs(values) do
    if value > top then
      top = value
    end
  end
  return top
end

-- Graph points are 0..1. Fixed-scale series divide by `scale`; rates scale to their own peak.
local function normalized(values, scale)
  local divisor = scale or peak(values)
  local out = {}
  for index, value in ipairs(values) do
    out[index] = divisor > 0 and clamp01(value / divisor) or 0
  end
  return out
end

local function series(row, id, label, color, scale, format)
  local values = type(row.history) == "table" and row.history[id] or nil
  if type(values) ~= "table" or #values < 2 then
    return nil
  end
  return {
    label = label,
    color = color,
    values = normalized(values, scale),
    text = format(values[#values]),
    peak = format(peak(values)),
  }
end

local function legend(key, item)
  return ui.row({ key = key, gap = 5, align = "center" }, {
    dot(key .. ":dot", item.color),
    ui.label({ text = item.label, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    ui.label({ text = item.text, fontSize = 12, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
  })
end

local function chart(key, title, a, b, caption)
  if a == nil then
    a, b = b, nil
  end
  if a == nil then
    return nil
  end
  local head = { ui.label({ text = title, fontSize = 13, fontWeight = "semibold", color = "on_surface", flexGrow = 1, maxLines = 1 }) }
  table.insert(head, legend(key .. ":a", a))
  if b ~= nil then
    table.insert(head, legend(key .. ":b", b))
  end
  local children = {
    ui.row({ align = "center", gap = 10 }, head),
    ui.graph({
      key = key .. ":graph",
      height = 56,
      values = a.values,
      values2 = b ~= nil and b.values or nil,
      color = a.color,
      color2 = b ~= nil and b.color or nil,
      lineWidth = 2,
      fillOpacity = 0.18,
    }),
  }
  if caption ~= nil and caption ~= "" then
    table.insert(children, ui.label({ text = caption, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
  end
  return ui.column({ key = key, gap = 6, padding = 10, radius = 8, fill = CARD }, children)
end

local function rate(suffix)
  return function(value)
    if value >= 100 then
      return string.format("%d %s", round(value), suffix)
    end
    return string.format("%.1f %s", value, suffix)
  end
end

local function degrees(value)
  return round(value) .. "°C"
end

local function percent(value)
  return round(value) .. "%"
end

local function watts(value)
  return round(value) .. "W"
end

local function charts(row, prefix)
  local limit = type(row.details) == "table" and row.details.powerLimit or nil
  local out = {}
  local function add(node)
    if node ~= nil then
      table.insert(out, node)
    end
  end

  local tps = series(row, "tps", noctalia.tr("graph.decode"), "primary", nil, rate("tok/s"))
  local prefill = series(row, "prefill", noctalia.tr("graph.prefill"), SECOND, nil, rate("tok/s"))
  local caption = nil
  if tps or prefill then
    local peaks = {}
    for _, item in ipairs({ tps or false, prefill or false }) do
      if item then
        table.insert(peaks, item.label .. " " .. item.peak)
      end
    end
    caption = noctalia.tr("graph.peak", { values = table.concat(peaks, " · ") })
  end
  add(chart(prefix .. "chart:rate", noctalia.tr("graph.throughput"), tps, prefill, caption))
  add(chart(prefix .. "chart:temp", noctalia.tr("graph.temperature"),
    series(row, "temp", noctalia.tr("graph.gpu"), "primary", 100, degrees),
    series(row, "cpu", noctalia.tr("graph.cpu"), SECOND, 100, degrees)))
  add(chart(prefix .. "chart:load", noctalia.tr("graph.gpu_load"),
    series(row, "gpu", noctalia.tr("graph.usage"), "primary", 100, percent),
    series(row, "power", noctalia.tr("graph.power"), SECOND, limit, watts)))
  add(chart(prefix .. "chart:mem", noctalia.tr("graph.memory"),
    series(row, "memory", noctalia.tr("graph.memory_short"), "primary", 100, percent),
    series(row, "vram", noctalia.tr("graph.vram"), SECOND, 100, percent)))
  return out
end

-- Engines -------------------------------------------------------------------------

local function serviceCard(key, service)
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = service.title == "ComfyUI" and "photo" or "message-chatbot", size = 15, color = "primary" }),
      ui.label({ text = service.title, fontSize = 13, fontWeight = "semibold", color = "on_surface", flexGrow = 1, maxLines = 1 }),
    }),
  }
  if service.subtitle ~= "" then
    table.insert(children, ui.label({ text = service.subtitle, fontSize = 13, color = "primary", maxLines = 1 }))
  end
  local stats = service.stats or {}
  for index = 1, #stats, 2 do
    local cells = {}
    for offset = 0, 1 do
      local item = stats[index + offset]
      if item ~= nil then
        table.insert(cells, ui.row({ flexGrow = 1, gap = 6, justify = "space_between" }, {
          ui.label({ text = noctalia.tr("stats." .. item.key), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
          ui.label({ text = item.value, fontSize = 12, color = "on_surface", maxLines = 1 }),
        }))
      else
        table.insert(cells, ui.spacer({ flexGrow = 1 }))
      end
    end
    table.insert(children, ui.row({ key = key .. ":stats:" .. index, gap = 16 }, cells))
  end
  return ui.column({ key = key, gap = 6, padding = 10, radius = 8, fill = CARD }, children)
end

-- One machine ------------------------------------------------------------------------

local function statusChip(row)
  local online = row.online == true
  return ui.row({ gap = 6, align = "center", paddingH = 8, paddingV = 3, radius = 10,
    fill = online and "primary/0.14" or "error/0.14" }, {
    dot("status:dot", online and "primary" or "error"),
    ui.label({
      text = online and noctalia.tr("online") or noctalia.tr("offline"),
      fontSize = 12,
      color = online and "primary" or "error",
    }),
  })
end

local function machineCard(row, prefix, title)
  local details = row.details or {}
  local subtitle = {}
  local role = roleText(row)
  if role ~= "" then
    table.insert(subtitle, role)
  end
  if row.online and details.uptime then
    table.insert(subtitle, noctalia.tr("uptime", { time = details.uptime }))
  end

  local children = {
    ui.row({ align = "center", gap = 10 }, {
      ui.label({ text = displayName(row), fontSize = title and 20 or 16, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      statusChip(row),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = table.concat(subtitle, "  ·  "), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    }),
  }
  if type(details.hardware) == "string" and details.hardware ~= "" then
    table.insert(children, ui.label({ text = details.hardware, fontSize = 12, color = "on_surface_variant", maxLines = 2 }))
  end

  if row.online ~= true then
    local reason = type(details.offlineReason) == "string" and details.offlineReason or ""
    table.insert(children, ui.label({
      text = reason ~= "" and noctalia.tr("offline_reason", { reason = reason }) or noctalia.tr("offline"),
      color = "error",
      maxLines = 3,
    }))
    return ui.column({ key = prefix .. "card", gap = 8 }, children)
  end

  for index, finding in ipairs(details.health or {}) do
    local color = ALERT[finding.level] or ALERT.warning
    table.insert(children, ui.row({ key = prefix .. "health:" .. index, gap = 8, align = "center", padding = 8, radius = 8,
      fill = finding.level == "danger" and "#ff5d6224" or "#ff914d24" }, {
      ui.glyph({ name = "alert-triangle", size = 15, color = color }),
      ui.label({
        text = finding.detail ~= "" and finding.title ~= "" and (finding.title .. ": " .. finding.detail) or (finding.title .. finding.detail),
        fontSize = 12,
        color = color,
        maxLines = 3,
        flexGrow = 1,
      }),
    }))
  end

  for _, node in ipairs(meters(row, prefix)) do
    table.insert(children, node)
  end
  local graphs = charts(row, prefix)
  if #graphs > 0 then
    local samples = 0
    if type(row.history) == "table" then
      for _, values in pairs(row.history) do
        samples = math.max(samples, #values)
      end
    end
    local window = client.formatDuration(samples * client.intervalMs() / 1000)
    table.insert(children, sectionTitle(prefix .. "graphs", noctalia.tr("graph.title", { window = window })))
    for _, node in ipairs(graphs) do
      table.insert(children, node)
    end
  end
  local services = details.services or {}
  if #services > 0 then
    table.insert(children, sectionTitle(prefix .. "services", noctalia.tr("services")))
    for index, service in ipairs(services) do
      table.insert(children, serviceCard(prefix .. "service:" .. index, service))
    end
  end
  return ui.column({ key = prefix .. "card", gap = 8 }, children)
end

-- Panel ------------------------------------------------------------------------------

local function render()
  local snap = noctalia.state.get("status")
  local header = {
    ui.glyph({ name = "bolt", size = 18, color = "primary" }),
    ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
  }
  if snap ~= nil and type(snap.updated) == "number" then
    table.insert(header, ui.label({
      text = noctalia.tr("updated", { time = noctalia.formatTime("{:%H:%M:%S}", snap.updated) }),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end
  if noctalia.getSetting("shell.show_close_buttons") ~= false then
    table.insert(header, ui.button({
      glyph = "close",
      variant = "ghost",
      onClick = function()
        panel.close()
      end,
    }))
  end

  local body = {}
  local function settingsButton()
    table.insert(body, ui.button({
      text = noctalia.tr("open_settings"),
      onClick = function()
        noctalia.openSettings()
      end,
    }))
  end

  if snap == nil then
    table.insert(body, ui.label({ text = noctalia.tr("loading"), color = "on_surface_variant" }))
  elseif snap.error ~= nil then
    table.insert(body, ui.label({
      text = noctalia.tr(snap.error, snap.errorArgs),
      color = "on_surface",
    }))
    settingsButton()
  end

  local selected = snap ~= nil and snap.selected or nil
  if selected ~= nil then
    table.insert(body, machineCard(selected, "sel:", true))
    if selected.role == "head" and type(selected.workers) == "table" and #selected.workers > 0 then
      for index, worker in ipairs(selected.workers) do
        table.insert(body, ui.separator({ key = "w" .. index .. ":sep", thickness = 1, color = "outline_variant", spacing = 6 }))
        table.insert(body, machineCard(worker, "w" .. index .. ":", false))
      end
    end
    local actions = {}
    if type(selected.href) == "string" and selected.href ~= "" then
      local href = selected.href
      table.insert(actions, ui.button({
        text = noctalia.tr("open_dashboard"),
        glyph = "external-link",
        onClick = function()
          openUrl(href)
        end,
      }))
    end
    table.insert(actions, ui.button({
      text = noctalia.tr("open_settings"),
      variant = "ghost",
      onClick = function()
        noctalia.openSettings()
      end,
    }))
    table.insert(body, ui.row({ align = "center", gap = 8 }, actions))
  elseif snap ~= nil and type(snap.base) == "string" and snap.base ~= "" and snap.error == nil then
    local href = snap.base .. "/cost"
    table.insert(body, ui.button({
      text = noctalia.tr("open_dashboard"),
      glyph = "external-link",
      onClick = function()
        openUrl(href)
      end,
    }))
  end

  local machines = snap ~= nil and snap.machines or nil
  if type(machines) == "table" and #machines > 0 then
    table.insert(body, ui.separator({ key = "machines:sep", thickness = 1, color = "outline_variant", spacing = 6 }))
    table.insert(body, sectionTitle("machines:title", noctalia.tr("machines")))
    table.insert(body, ui.label({
      text = noctalia.tr("machines_hint"),
      fontSize = 12,
      color = "on_surface_variant",
    }))
    for _, row in ipairs(machines) do
      local name = displayName(row)
      local status = row.online and client.summary(row.readings, true) or noctalia.tr("offline_short")
      table.insert(body, ui.row({
        key = "machine-" .. (row.id ~= "" and row.id or name),
        align = "center",
        gap = 8,
        paddingH = 10,
        paddingV = 8,
        radius = 6,
        fill = row.selected and "primary/0.16" or "on_surface/0.06",
        onClick = function()
          copyName(name)
        end,
      }, {
        dot("dot", row.online and "primary" or "error"),
        ui.label({
          text = machineLabel(row),
          flexGrow = 1,
          fontSize = 14,
          maxLines = 1,
          color = "on_surface",
        }),
        ui.label({
          text = status,
          fontSize = 13,
          maxLines = 1,
          color = row.online and "primary" or "error",
        }),
      }))
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", gap = 8 }, header),
    ui.scroll({ flexGrow = 1, gap = 10 }, body),
  }))
end

noctalia.state.watch("status", function()
  render()
end)

function onOpen()
  render()
end

function onConfigChanged()
  render()
end
