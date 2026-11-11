--!nonstrict
-- Polls GET /api/sparks and publishes the selected machine on "status".

local client = require("./client.luau")

noctalia.setUpdateInterval(client.intervalMs())

local busy = false
local dirty = false

-- Recent readings per machine id, oldest first, for the panel graphs.
local HISTORY_SIZE = 90
local SERIES = { "tps", "prefill", "temp", "cpu", "gpu", "power", "vram", "memory" }
local history = {}

local function record(row)
  if row.id == "" or row.online ~= true then
    return
  end
  local h = history[row.id] or {}
  history[row.id] = h
  for _, key in ipairs(SERIES) do
    local item = row.readings[key]
    local series = h[key] or {}
    h[key] = series
    if item ~= nil and item.known == true then
      table.insert(series, item.value)
      if #series > HISTORY_SIZE then
        table.remove(series, 1)
      end
    end
  end
end

local function publish(snapshot)
  noctalia.state.set("status", snapshot)
end

local function fail(key, args, extra)
  local snapshot = extra or {}
  snapshot.error = key
  snapshot.errorArgs = args
  snapshot.selected = nil
  if snapshot.machines == nil then
    snapshot.machines = {}
  end
  if snapshot.base == nil then
    snapshot.base = ""
  end
  if snapshot.machine == nil then
    snapshot.machine = client.machineQuery()
  end
  publish(snapshot)
end

local function identity(spark)
  local name = type(spark.name) == "string" and spark.name or ""
  local id = type(spark.id) == "string" and spark.id or ""
  if name == "" then
    name = id
  end
  return id, name
end

-- /api/sparks is the directory. Reachability and queue counts arrive on
-- /api/sparks/<id>/metrics, whose `online` field is a JSON boolean.
local function isOnline(spark)
  return type(spark) == "table" and spark.online == true
end

local function displayName(spark, fallback)
  local name = type(spark) == "table" and type(spark.name) == "string" and noctalia.string.trim(spark.name) or ""
  if name ~= "" then
    return name
  end
  local id = type(spark) == "table" and type(spark.id) == "string" and noctalia.string.trim(spark.id) or ""
  if id ~= "" then
    return id
  end
  return fallback or ""
end

local function machineRow(spark, source, selected, sparks)
  local id, name = identity(spark)
  local counts = client.counts(spark, source)
  local head = client.headOf(spark, sparks)
  return {
    id = id,
    name = name,
    online = isOnline(spark),
    known = counts.known,
    running = counts.running,
    queued = counts.queued,
    runningKnown = counts.runningKnown,
    queuedKnown = counts.queuedKnown,
    selected = selected,
    role = client.role(spark),
    workerHeadId = client.workerHeadId(spark),
    headName = displayName(head, ""),
    lines = counts.lines,
    readings = client.readings(spark, source),
    details = client.details(spark),
    history = history[id],
  }
end

local function choose(sparks, query)
  local idHit, nameHit, ipHit = nil, nil, nil
  local q = noctalia.string.trim(query):lower()
  for _, spark in ipairs(sparks) do
    if type(spark) == "table" then
      local id = type(spark.id) == "string" and noctalia.string.trim(spark.id):lower() or ""
      local name = type(spark.name) == "string" and noctalia.string.trim(spark.name):lower() or ""
      local ip = type(spark.lanIp) == "string" and noctalia.string.trim(spark.lanIp):lower() or ""
      if id ~= "" and id == q and idHit == nil then
        idHit = spark
      elseif name ~= "" and name == q and nameHit == nil then
        nameHit = spark
      elseif ip ~= "" and ip == q and ipHit == nil then
        ipHit = spark
      end
    end
  end
  return idHit or nameHit or ipHit
end

local function parse(sparks, base, query, source)
  if type(sparks) ~= "table" then
    fail("bad_json", nil, { base = base, machine = query })
    return
  end
  local picked = choose(sparks, query)
  local machines = {}
  local selected = nil
  for _, spark in ipairs(sparks) do
    if type(spark) == "table" then
      local row = machineRow(spark, source, spark == picked, sparks)
      record(row)
      row.history = history[row.id]
      table.insert(machines, {
        id = row.id,
        name = row.name,
        online = row.online,
        known = row.known,
        running = row.running,
        queued = row.queued,
        runningKnown = row.runningKnown,
        queuedKnown = row.queuedKnown,
        selected = row.selected,
        role = row.role,
        headName = row.headName,
        readings = row.readings,
      })
      if spark == picked then
        local href = base .. "/cost"
        if row.id ~= "" then
          href = base .. "/spark/" .. noctalia.string.urlEncode(row.id)
        end
        selected = row
        selected.href = href
      end
    end
  end
  if selected ~= nil and selected.role == "head" then
    local workers = {}
    for _, spark in ipairs(sparks) do
      if type(spark) == "table" and client.isWorkerOf(spark, picked, sparks) then
        table.insert(workers, machineRow(spark, source, false, sparks))
      end
    end
    selected.workers = workers
  end
  if query == "" then
    fail("no_machine", nil, { base = base, machine = "", machines = machines })
    return
  end
  if selected == nil then
    fail("not_found", { machine = query }, { base = base, machine = query, machines = machines })
    return
  end
  publish({
    error = nil,
    errorArgs = nil,
    base = base,
    machine = query,
    selected = selected,
    machines = machines,
    updated = os.time(),
  })
end

local cycle = 0
local fetch

local function finish(gen)
  if gen ~= cycle then
    return
  end
  busy = false
  if dirty then
    dirty = false
    fetch()
  end
end

local function reject(gen, key, args, extra)
  if gen ~= cycle then
    return
  end
  cycle = cycle + 1
  fail(key, args, extra)
  busy = false
  if dirty then
    dirty = false
    fetch()
  end
end

-- Directory entries have no `online` field. Overlay each one with its metrics
-- document, which is the same spark object the dashboard renders.
local function loadLive(sparks, base, query, source, gen)
  local pending = 0
  local live = {}
  local aborted = false

  local function done()
    if aborted or gen ~= cycle then
      return
    end
    local merged = {}
    for _, spark in ipairs(sparks) do
      local id = type(spark.id) == "string" and spark.id or ""
      table.insert(merged, live[id] or spark)
    end
    parse(merged, base, query, source)
    finish(gen)
  end

  for _, spark in ipairs(sparks) do
    if type(spark.id) == "string" and spark.id ~= "" then
      pending = pending + 1
    end
  end
  if pending == 0 then
    done()
    return
  end

  for _, spark in ipairs(sparks) do
    local id = type(spark.id) == "string" and spark.id or ""
    if id ~= "" then
      local path = "/api/sparks/" .. noctalia.string.urlEncode(id) .. "/metrics"
      local mreq = client.request(path)
      local function settle(sparkLive)
        if aborted or gen ~= cycle then
          return
        end
        if sparkLive ~= nil then
          live[id] = sparkLive
        end
        pending = pending - 1
        if pending == 0 then
          done()
        end
      end
      if mreq == nil then
        settle(nil)
      else
        local started = noctalia.http(mreq, function(res)
          if aborted or gen ~= cycle then
            return
          end
          if res.status == 401 then
            aborted = true
            reject(gen, "unauthorized", nil, { base = base, machine = query })
            return
          end
          if res.ok and res.status == 200 then
            local decoded, decodeErr = noctalia.json.decode(res.body)
            if type(decoded) ~= "table" then
              noctalia.log(decodeErr or "invalid metrics json")
              settle(nil)
            else
              settle(decoded)
            end
          else
            settle(nil)
          end
        end)
        if not started then
          settle(nil)
        end
      end
    end
  end
end

function fetch()
  local query = client.machineQuery()
  local req, err = client.request("/api/sparks")
  if req == nil then
    fail(err)
    return
  end
  if busy then
    dirty = true
    return
  end
  busy = true
  cycle = cycle + 1
  local gen = cycle
  local source = client.source()

  local started = noctalia.http(req, function(res)
    if gen ~= cycle then
      return
    end
    if not res.ok then
      reject(gen, "offline", nil, { base = req.base, machine = query })
    elseif res.status == 401 then
      reject(gen, "unauthorized", nil, { base = req.base, machine = query })
    elseif res.status ~= 200 then
      reject(gen, "http_error", { status = res.status }, { base = req.base, machine = query })
    else
      local decoded, decodeErr = noctalia.json.decode(res.body)
      local sparks = type(decoded) == "table" and decoded.sparks or nil
      if type(sparks) ~= "table" then
        noctalia.log(decodeErr or "invalid json")
        reject(gen, "bad_json", nil, { base = req.base, machine = query })
      else
        loadLive(sparks, req.base, query, source, gen)
      end
    end
  end)

  if not started then
    reject(gen, "offline", nil, { base = req.base, machine = query })
  end
end

function update()
  noctalia.setUpdateInterval(client.intervalMs())
  fetch()
end

function onConfigChanged()
  noctalia.setUpdateInterval(client.intervalMs())
  -- A settings reload can drop the HTTP callback and leave the poller busy.
  cycle = cycle + 1
  busy = false
  dirty = false
  fetch()
end

fetch()
