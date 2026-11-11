--!nonstrict
-- sparkDash origin, bearer token, and queue counts from GET /api/sparks.
--
-- Each spark has metrics.llm[] (requestsRunning / requestsWaiting, with
-- slotsActive when the engine does not report requestsRunning) and
-- metrics.comfy (queueRunning / queuePending).

local M = {}

local function trimmed(key)
  local value = noctalia.getConfig(key)
  if type(value) ~= "string" then
    return ""
  end
  return noctalia.string.trim(value)
end

-- Accepts a bare origin or a page URL such as http://host:5555/cost.
function M.origin()
  local raw = trimmed("url"):gsub("/+$", "")
  if raw == "" then
    return nil, "unconfigured"
  end
  local scheme, rest = raw:match("^(https?)://(.+)$")
  if scheme == nil then
    return nil, "bad_url"
  end
  local authority = rest:match("^([^/?#]+)")
  if authority == nil or authority == "" or authority:find("@", 1, true) ~= nil then
    return nil, "bad_url"
  end
  return scheme .. "://" .. authority, nil
end

function M.request(path)
  local base, err = M.origin()
  if base == nil then
    return nil, err
  end
  local token = trimmed("token")
  if token:find("[\r\n]") ~= nil then
    return nil, "bad_token"
  end
  local headers = { "Accept: application/json" }
  if token ~= "" then
    table.insert(headers, "Authorization: Bearer " .. token)
  end
  return { url = base .. path, headers = headers, base = base }, nil
end

function M.machineQuery()
  return trimmed("machine")
end

function M.source()
  local source = noctalia.getConfig("source")
  if source == "llm" or source == "comfy" or source == "both" then
    return source
  end
  return "both"
end

function M.intervalMs()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or 5
  if seconds < 2 then
    seconds = 2
  elseif seconds > 120 then
    seconds = 120
  end
  return math.floor(seconds) * 1000
end

local function norm(value)
  if type(value) ~= "string" then
    return ""
  end
  return noctalia.string.trim(value):lower()
end

local function same(value, query)
  return query ~= "" and norm(value) == query
end

function M.matches(spark, query)
  if type(spark) ~= "table" then
    return false
  end
  local q = norm(query)
  return same(spark.id, q) or same(spark.name, q) or same(spark.lanIp, q)
end

-- sparkDash roles are head, worker, or standalone. Older payloads use workerNode.
function M.role(spark)
  if type(spark) ~= "table" then
    return "standalone"
  end
  local role = spark.role
  if role == "head" or role == "worker" or role == "standalone" then
    return role
  end
  if spark.workerNode == true then
    return "worker"
  end
  return "standalone"
end

function M.workerHeadId(spark)
  if type(spark) ~= "table" or type(spark.workerHeadId) ~= "string" then
    return ""
  end
  return noctalia.string.trim(spark.workerHeadId)
end

-- The head this worker belongs to. A workerHeadId wins. With no id, a worker
-- belongs to the only head in the fleet, which is how the dashboard resolves it.
function M.headOf(spark, sparks)
  if M.role(spark) ~= "worker" or type(sparks) ~= "table" then
    return nil
  end
  local link = norm(M.workerHeadId(spark))
  local heads = {}
  local linked = nil
  for _, other in ipairs(sparks) do
    if type(other) == "table" then
      if M.role(other) == "head" then
        table.insert(heads, other)
      end
      if link ~= "" and norm(other.id) == link then
        linked = other
      end
    end
  end
  if link ~= "" then
    return linked
  end
  if #heads == 1 then
    return heads[1]
  end
  return nil
end

function M.isWorkerOf(spark, head, sparks)
  if type(head) ~= "table" or M.role(head) ~= "head" then
    return false
  end
  local found = M.headOf(spark, sparks)
  if found == nil then
    return false
  end
  if found == head then
    return true
  end
  local foundId = norm(found.id)
  return foundId ~= "" and foundId == norm(head.id)
end

local function asCount(value)
  if type(value) ~= "number" or value ~= value or value < 0 then
    return nil
  end
  return math.floor(value + 0.5)
end

local function add(total, known, value)
  local count = asCount(value)
  if count == nil then
    return total, known
  end
  return total + count, true
end

local function llmLine(engine, index, ports)
  if type(engine) ~= "table" or engine.available ~= true or engine.measurementValid == false then
    return nil
  end
  local running, runningKnown = nil, false
  running, runningKnown = add(0, false, engine.requestsRunning)
  if not runningKnown then
    running, runningKnown = add(0, false, engine.slotsActive)
  end
  local queued, queuedKnown = add(0, false, engine.requestsWaiting)
  if not runningKnown and not queuedKnown then
    return nil
  end
  local port = type(ports) == "table" and ports[index] or nil
  local label = "LLM"
  if type(port) == "number" then
    label = "LLM :" .. tostring(math.floor(port))
  elseif type(port) == "string" and port ~= "" then
    label = "LLM :" .. port
  elseif index ~= nil then
    label = "LLM " .. tostring(index)
  end
  return {
    label = label,
    running = runningKnown and running or 0,
    queued = queuedKnown and queued or 0,
    runningKnown = runningKnown,
    queuedKnown = queuedKnown,
  }
end

local function comfyLine(comfy)
  if type(comfy) ~= "table" or comfy.available ~= true then
    return nil
  end
  local running, runningKnown = add(0, false, comfy.queueRunning)
  local queued, queuedKnown = add(0, false, comfy.queuePending)
  if not runningKnown and not queuedKnown then
    return nil
  end
  return {
    label = "ComfyUI",
    running = runningKnown and running or 0,
    queued = queuedKnown and queued or 0,
    runningKnown = runningKnown,
    queuedKnown = queuedKnown,
  }
end

function M.counts(spark, source)
  local lines = {}
  local metrics = type(spark) == "table" and spark.metrics or nil
  if source ~= "comfy" and type(metrics) == "table" then
    local ports = spark.llmPorts
    if type(metrics.llm) == "table" then
      for index, engine in ipairs(metrics.llm) do
        local line = llmLine(engine, index, ports)
        if line ~= nil then
          table.insert(lines, line)
        end
      end
    end
  end
  if source ~= "llm" and type(metrics) == "table" then
    local line = comfyLine(metrics.comfy)
    if line ~= nil then
      table.insert(lines, line)
    end
  end

  local running, queued = 0, 0
  local runningKnown, queuedKnown = false, false
  for _, line in ipairs(lines) do
    if line.runningKnown then
      running = running + line.running
      runningKnown = true
    end
    if line.queuedKnown then
      queued = queued + line.queued
      queuedKnown = true
    end
  end
  return {
    known = runningKnown or queuedKnown,
    running = running,
    queued = queued,
    runningKnown = runningKnown,
    queuedKnown = queuedKnown,
    lines = lines,
  }
end

function M.counterText(item)
  if type(item) ~= "table" or item.known ~= true then
    return "—"
  end
  local running = item.runningKnown and tostring(item.running) or "—"
  local queued = item.queuedKnown and tostring(item.queued) or "—"
  return running .. "/" .. queued
end

-- Bar counters. Several may be on at once; order here is the bar order.
local COUNTERS = {
  { id = "queue", setting = "show_queue", default = true },
  { id = "tps", setting = "show_tps", default = true },
  { id = "prefill", setting = "show_prefill", default = false },
  { id = "temp", setting = "show_temp", default = true },
  { id = "cpu", setting = "show_cpu", default = false },
  { id = "gpu", setting = "show_gpu", default = false },
  { id = "power", setting = "show_power", default = false },
  { id = "vram", setting = "show_vram", default = false },
  { id = "memory", setting = "show_memory", default = false },
}

function M.enabledCounters()
  local ids = {}
  for _, counter in ipairs(COUNTERS) do
    local value = noctalia.getConfig(counter.setting)
    if value == nil then
      value = counter.default
    end
    if value == true then
      table.insert(ids, counter.id)
    end
  end
  return ids
end

local function finite(value)
  return type(value) == "number" and value == value
end

local function reported(group, key)
  local availability = type(group) == "table" and group.metricAvailability or nil
  return type(availability) ~= "table" or availability[key] ~= false
end

local function formatRate(value, suffix)
  local text
  if value >= 100 then
    text = string.format("%d", math.floor(value + 0.5))
  elseif value >= 10 then
    text = string.format("%.0f", value)
  else
    text = string.format("%.1f", value)
  end
  return text .. " " .. suffix
end

local function formatDegrees(value)
  return string.format("%d°", math.floor(value + 0.5))
end

local function formatPercent(value, suffix)
  local text = string.format("%d%%", math.floor(value + 0.5))
  if suffix ~= nil and suffix ~= "" then
    return text .. " " .. suffix
  end
  return text
end

local function formatWatts(value)
  if value >= 10 then
    return string.format("%dW", math.floor(value + 0.5))
  end
  return string.format("%.1fW", value)
end

local function reading(value, text, alert)
  if value == nil then
    return { known = false, text = "—", value = 0 }
  end
  return { known = true, text = text, value = value, alert = alert }
end

-- Alert levels match the sparkDash overview card: warning, then danger.
local function tempAlert(celsius)
  if celsius == nil then
    return nil
  end
  if celsius > 80 then
    return "danger"
  end
  return celsius >= 75 and "warning" or nil
end

local function memoryAlert(percent)
  if percent == nil then
    return nil
  end
  if percent >= 90 then
    return "danger"
  end
  return percent >= 85 and "warning" or nil
end

local function sumEngines(metrics, field)
  local llm = type(metrics) == "table" and metrics.llm or nil
  if type(llm) ~= "table" then
    return nil
  end
  local total, known = 0, false
  for _, engine in ipairs(llm) do
    if type(engine) == "table" and engine.available == true and engine.measurementValid ~= false and finite(engine[field]) then
      total = total + engine[field]
      known = true
    end
  end
  if not known then
    return nil
  end
  return total
end

local function percentOf(used, total)
  if not finite(used) or not finite(total) or total <= 0 then
    return nil
  end
  return used / total * 100
end

function M.readings(spark, source)
  local metrics = type(spark) == "table" and spark.metrics or nil
  local gpu = type(metrics) == "table" and metrics.gpu or nil
  local cpu = type(metrics) == "table" and metrics.cpu or nil
  local counts = M.counts(spark, source)

  local temp = nil
  if reported(gpu, "temperature") and finite(gpu and gpu.temperature) then
    temp = gpu.temperature
  end

  local gpuUse = nil
  if reported(gpu, "usage") and finite(gpu and gpu.usage) then
    gpuUse = gpu.usage
  end

  local watts = nil
  local power = type(gpu) == "table" and gpu.power or nil
  if reported(gpu, "powerDraw") and finite(power and power.draw) then
    watts = power.draw
  end

  local vram = nil
  local vramGroup = type(gpu) == "table" and gpu.vram or nil
  if reported(gpu, "vramUsed") and type(vramGroup) == "table" then
    if finite(vramGroup.percentage) then
      vram = vramGroup.percentage
    else
      vram = percentOf(vramGroup.used, vramGroup.total)
    end
  end

  -- sparkDash alerts on unified memory (its VRAM bar), never on host RAM.
  local memory, memoryLevel = nil, nil
  local unified = type(metrics) == "table" and metrics.unifiedMemory or nil
  local ram = type(metrics) == "table" and metrics.ram or nil
  if type(unified) == "table" and finite(unified.percentage) then
    memory = unified.percentage
    memoryLevel = memoryAlert(memory)
  elseif type(ram) == "table" and finite(ram.percentage) then
    memory = ram.percentage
  end

  -- sparkDash flags GPU usage when the GPU throttles or runs at 80° or hotter.
  local throttle = type(gpu) == "table" and gpu.throttle or nil
  local throttled = type(throttle) == "table" and (throttle.thermal == true or throttle.hwSlowdown == true)
  local gpuLevel = (throttled or (temp ~= nil and temp >= 80)) and "warning" or nil

  local cpuTemp = nil
  if type(cpu) == "table" and finite(cpu.temperature) then
    cpuTemp = cpu.temperature
  end

  local tps = sumEngines(metrics, "generationTps")
  local prefill = sumEngines(metrics, "prefillTps")

  return {
    queue = {
      known = counts.known == true,
      text = M.counterText(counts),
      value = counts.running,
    },
    tps = reading(tps, tps ~= nil and formatRate(tps, "tok/s") or "—"),
    prefill = reading(prefill, prefill ~= nil and formatRate(prefill, "pf/s") or "—"),
    temp = reading(temp, temp ~= nil and formatDegrees(temp) or "—", tempAlert(temp)),
    cpu = reading(cpuTemp, cpuTemp ~= nil and (formatDegrees(cpuTemp) .. " cpu") or "—", tempAlert(cpuTemp)),
    gpu = reading(gpuUse, gpuUse ~= nil and formatPercent(gpuUse, "gpu") or "—", gpuLevel),
    power = reading(watts, watts ~= nil and formatWatts(watts) or "—"),
    vram = reading(vram, vram ~= nil and formatPercent(vram, "vram") or "—", memoryAlert(vram)),
    memory = reading(memory, memory ~= nil and formatPercent(memory, "mem") or "—", memoryLevel),
  }
end

-- Panel detail ------------------------------------------------------------------

function M.formatDuration(seconds)
  if not finite(seconds) or seconds < 60 then
    return "<1m"
  end
  local mins = math.floor(seconds / 60)
  if mins < 60 then
    return string.format("%dm", mins)
  end
  local hours = math.floor(mins / 60)
  if hours < 24 then
    return string.format("%dh %dm", hours, mins % 60)
  end
  return string.format("%dd %dh", math.floor(hours / 24), hours % 24)
end

-- sparkDash reports memory and disk in MB and divides by 1024. One unit, kept short
-- to fit a half-width meter: "115.7/121.6 GB", disks in whole GB.
local function usedOf(used, total, pattern)
  if not finite(used) or not finite(total) or total <= 0 then
    return nil
  end
  if total < 1024 then
    return string.format("%d/%d MB", math.floor(used + 0.5), math.floor(total + 0.5))
  end
  return string.format(pattern or "%.1f/%.1f GB", used / 1024, total / 1024)
end

local function compact(n)
  if n >= 1e9 then
    return string.format("%.1fB", n / 1e9)
  elseif n >= 1e6 then
    return string.format("%.1fM", n / 1e6)
  elseif n >= 1e4 then
    return string.format("%.1fk", n / 1e3)
  end
  return tostring(math.floor(n + 0.5))
end

local function seconds(s)
  if s < 1 then
    return string.format("%d ms", math.floor(s * 1000 + 0.5))
  elseif s < 10 then
    return string.format("%.1f s", s)
  end
  return string.format("%d s", math.floor(s + 0.5))
end

local function text(value)
  if type(value) ~= "string" then
    return ""
  end
  return noctalia.string.trim(value)
end

-- Stats are { key, value } pairs; the panel translates "stats.<key>".
local function stat(stats, key, value)
  if value ~= nil and value ~= "" then
    table.insert(stats, { key = key, value = value })
  end
end

local function engineCard(engine, index, ports)
  local line = llmLine(engine, index, ports)
  local stats = {}
  if finite(engine.slotsTotal) and engine.slotsTotal > 0 then
    local active = finite(engine.slotsActive) and engine.slotsActive or 0
    stat(stats, "slots", string.format("%d / %d", math.floor(active), math.floor(engine.slotsTotal)))
  end
  if line ~= nil then
    stat(stats, "queue", M.counterText({ known = true, running = line.running, queued = line.queued,
      runningKnown = line.runningKnown, queuedKnown = line.queuedKnown }))
  end
  local valid = engine.measurementValid ~= false
  if valid and finite(engine.generationTps) then
    stat(stats, "decode", formatRate(engine.generationTps, "tok/s"))
  end
  if valid and finite(engine.perStreamTps) then
    stat(stats, "per_stream", formatRate(engine.perStreamTps, "tok/s"))
  end
  if valid and finite(engine.prefillTps) then
    stat(stats, "prefill", formatRate(engine.prefillTps, "tok/s"))
  end
  if finite(engine.contextLength) and engine.contextLength > 0 then
    stat(stats, "context", compact(engine.contextLength))
  end
  if finite(engine.kvCacheUsage) then
    stat(stats, "kv_cache", formatPercent(engine.kvCacheUsage * 100))
  end
  if finite(engine.prefixCacheHitRate) then
    stat(stats, "prefix_hit", formatPercent(engine.prefixCacheHitRate * 100))
  end
  if finite(engine.ttftSeconds) then
    local ttft = seconds(engine.ttftSeconds)
    if finite(engine.ttftP95Seconds) then
      ttft = ttft .. " · p95 " .. seconds(engine.ttftP95Seconds)
    end
    stat(stats, "ttft", ttft)
  end
  if finite(engine.itlP95Seconds) then
    stat(stats, "itl", seconds(engine.itlP95Seconds))
  end
  if finite(engine.e2eP95Seconds) then
    stat(stats, "e2e", seconds(engine.e2eP95Seconds))
  end
  if finite(engine.totalPromptTokens) or finite(engine.totalOutputTokens) then
    stat(stats, "tokens", compact(engine.totalPromptTokens or 0) .. " in · " .. compact(engine.totalOutputTokens or 0) .. " out")
  end
  local title = line ~= nil and line.label or ("LLM " .. tostring(index))
  if type(engine.port) == "number" then
    title = "LLM :" .. tostring(math.floor(engine.port))
  end
  local backend = text(engine.backend)
  if backend ~= "" then
    title = title .. " · " .. backend
  end
  return { title = title, subtitle = text(engine.modelId), stats = stats }
end

-- Everything the panel shows beyond the bar readings. Preformatted, so the panel
-- only lays it out.
function M.details(spark)
  local metrics = type(spark) == "table" and type(spark.metrics) == "table" and spark.metrics or {}
  local hw = type(spark) == "table" and type(spark.hardware) == "table" and spark.hardware or {}
  local gpu = type(metrics.gpu) == "table" and metrics.gpu or {}
  local out = { health = {}, services = {} }

  local parts = {}
  local device, chip, cpuModel = text(hw.device), text(hw.gpuChip), text(hw.cpuModel)
  for _, part in ipairs({ device, chip, cpuModel ~= chip and cpuModel or "" }) do
    if part ~= "" then
      table.insert(parts, part)
    end
  end
  if finite(hw.cpuCores) then
    table.insert(parts, string.format("%d cores", math.floor(hw.cpuCores)))
  end
  if finite(hw.totalMemoryGB) then
    table.insert(parts, string.format("%d GB", math.floor(hw.totalMemoryGB + 0.5)))
  end
  out.hardware = table.concat(parts, " · ")

  if type(spark) == "table" and finite(spark.uptime) then
    out.uptime = M.formatDuration(spark.uptime)
  end
  out.offlineReason = type(spark) == "table" and text(spark.offlineReason) or ""

  local power = type(gpu.power) == "table" and gpu.power or {}
  if reported(gpu, "powerLimit") and finite(power.limit) and power.limit > 0 then
    out.powerLimit = power.limit
  end
  local vram = type(gpu.vram) == "table" and gpu.vram or {}
  out.vramText = usedOf(vram.used, vram.total)

  local unified = type(metrics.unifiedMemory) == "table" and metrics.unifiedMemory or nil
  local ram = type(metrics.ram) == "table" and metrics.ram or {}
  if unified ~= nil and finite(unified.percentage) then
    out.memoryText = usedOf(unified.used, unified.total)
    out.memoryUnified = true
  else
    out.memoryText = usedOf(ram.used, ram.total)
  end

  -- The root mount, or the first disk sparkDash polls.
  local disks = type(metrics.storage) == "table" and metrics.storage or {}
  for _, disk in ipairs(disks) do
    if type(disk) == "table" and disk.disabled ~= true and finite(disk.percentage) then
      if out.disk == nil or disk.label == "/" then
        out.disk = { percent = disk.percentage, text = usedOf(disk.used, disk.total, "%.0f/%.0f GB"), label = text(disk.label) }
      end
    end
  end

  if type(spark) == "table" and type(spark.health) == "table" then
    for _, finding in ipairs(spark.health) do
      if type(finding) == "table" and (text(finding.title) ~= "" or text(finding.detail) ~= "") then
        table.insert(out.health, {
          title = text(finding.title),
          detail = text(finding.detail),
          level = finding.severity == "critical" and "danger" or "warning",
        })
      end
    end
  end
  local throttle = type(gpu.throttle) == "table" and gpu.throttle or {}
  if throttle.active == true then
    table.insert(out.health, { title = "GPU throttled", detail = text(throttle.detail), level = "warning" })
  end

  if type(metrics.llm) == "table" then
    for index, engine in ipairs(metrics.llm) do
      if type(engine) == "table" and engine.available == true then
        table.insert(out.services, engineCard(engine, index, type(spark) == "table" and spark.llmPorts or nil))
      end
    end
  end
  local comfy = comfyLine(metrics.comfy)
  if comfy ~= nil then
    local stats = {}
    stat(stats, "queue", M.counterText({ known = true, running = comfy.running, queued = comfy.queued,
      runningKnown = comfy.runningKnown, queuedKnown = comfy.queuedKnown }))
    table.insert(out.services, { title = "ComfyUI", subtitle = "", stats = stats })
  end
  return out
end

function M.summary(readings, knownOnly)
  local parts = {}
  for _, id in ipairs(M.enabledCounters()) do
    local item = type(readings) == "table" and readings[id] or nil
    if type(item) == "table" and type(item.text) == "string" and item.text ~= "" then
      if not knownOnly or item.known == true then
        table.insert(parts, item.text)
      end
    end
  end
  if #parts == 0 then
    return "—"
  end
  return table.concat(parts, " · ")
end

return M
