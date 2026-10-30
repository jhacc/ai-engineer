-- Pollution and the enemy: nests that soak up pollution send attacks, so keep-busy keeps the pollution
-- cloud (what the map's pollution overlay shows) a few chunks away from them. As the cloud comes near a
-- nest it gets gun turrets and ammo ready on that side first; once it's too close it pauses the
-- engineer's drills (disabled_by_script: they stay built, just switched off) and builds nothing new that
-- pollutes, then starts them again one at a time after the cloud has pulled back.
--
-- The cloud is measured, not predicted, so trees (and grass, water) soaking up pollution count by
-- themselves: a forest map runs more drills before it's held back. Sparse land (desert) spreads it
-- fastest, so there the buffer is a chunk wider.
local util = require("scripts.util")
local jobs = require("scripts.jobs")
local M = {}

local CHUNK = 32
-- A chunk counts as polluted, as on the overlay, above this.
local POLLUTED = 1
-- Nests watched, within this far of home.
local NEST_RADIUS = 640
-- Chunks kept clear between the cloud and a nest (steps between chunks: pollution spreads to the four
-- neighbors). Turrets and ammo go up PREPARE chunks before that.
local BUFFER, PREPARE = 2, 2
-- Trees per tile around home below which the land counts as sparse (desert): one chunk more buffer.
local TREE_RADIUS, SPARSE_TREES, TREE_RECOUNT = 160, 0.01, 10 * 3600
local CHECK_TICKS = 30 * 60
-- Pollution takes minutes to settle: wait this long before pausing more (unless the cloud still comes
-- closer), stay clear this long before restarting, then restart one machine per RESUME_STEP.
local PAUSE_WAIT, RESUME_WAIT, RESUME_STEP = 2 * 3600, 5 * 3600, 3 * 3600
-- Drills kept running whatever the cloud does (the base can't do anything without plates).
local KEEP = {["iron-ore"] = 2, ["copper-ore"] = 1}
-- A coal mine drill whose chest holds this much is spare.
local FULL_CHEST = 200
local TURRET = "gun-turret"
-- Turret spots go this far from our building toward the nest.
local GUARD_AHEAD = 10
-- With no nest known: the cloud is kept this many chunks inside the revealed map (polluted chunks checked
-- at most MAX_EDGE_CHUNKS a reading).
local EDGE_BUFFER, MAX_EDGE_CHUNKS = 2, 400

local function chunk_of(p) return math.floor(p.x / CHUNK), math.floor(p.y / CHUNK) end
local function chunk_center(cx, cy) return {x = cx * CHUNK + CHUNK / 2, y = cy * CHUNK + CHUNK / 2} end

-- How many chunks the cloud is kept from nests now: wider on sparse land and before turrets are researched.
local function buffer(p, force)
  local recipe = force.recipes[TURRET]
  return BUFFER + (p.sparse and 1 or 0) + ((recipe and recipe.enabled) and 0 or 1)
end

-- The engineer's building nearest `to` (where biters coming for the cloud would hit first).
local function nearest_built(rec, to)
  local best, best_d
  for _, entity in pairs(rec.built or {}) do
    if entity.valid and entity.type ~= "electric-pole" then
      local d = util.distance(entity.position, to)
      if not best_d or d < best_d then best, best_d = entity, d end
    end
  end
  return best, best_d
end

-- Whether a chunk is on the revealed map. A headless server keeps no map chart (nothing is ever charted
-- there), so when even home's chunk isn't, land generated so far counts as revealed instead.
local function revealer(force, surface, home)
  local hx, hy = chunk_of(home)
  if force.is_chunk_charted(surface, {hx, hy}) then
    return function(cx, cy) return force.is_chunk_charted(surface, {cx, cy}) end
  end
  return function(cx, cy) return surface.is_chunk_generated({cx, cy}) end
end

-- Measure: per chunk of nests, how many chunk steps away the nearest polluted chunk is.
local function measure(rec, home, last)
  local e = rec.entity
  local surface = e.surface
  local p = {next = game.tick + CHECK_TICKS}
  if not (game.map_settings.pollution.enabled and surface.pollutant_type) or surface.peaceful_mode then
    p.off = true
    return p
  end
  if last and last.trees_at and game.tick - last.trees_at < TREE_RECOUNT then
    p.trees, p.trees_at = last.trees, last.trees_at
  else
    local n = surface.count_entities_filtered{type = "tree", position = home, radius = TREE_RADIUS}
    p.trees, p.trees_at = n / (math.pi * TREE_RADIUS * TREE_RADIUS), game.tick
  end
  p.sparse = p.trees < SPARSE_TREES
  p.reduce_at = buffer(p, e.force)
  p.prepare_at = p.reduce_at + PREPARE
  -- Only nests on the revealed map (what a player could know of).
  local nests = {}
  local revealed = revealer(e.force, surface, home)
  for _, nest in ipairs(surface.find_entities_filtered{type = "unit-spawner", force = "enemy", position = home, radius = NEST_RADIUS}) do
    local cx, cy = chunk_of(nest.position)
    local k = cx .. "," .. cy
    if revealed(cx, cy) then nests[k] = nests[k] or {cx = cx, cy = cy, position = nest.position} end
  end
  local seen = {}
  local function amount(cx, cy)
    local k = cx .. "," .. cy
    if seen[k] == nil then seen[k] = surface.get_pollution(chunk_center(cx, cy)) end
    return seen[k]
  end
  p.threats = {}
  for _, nest in pairs(nests) do
    p.nests = (p.nests or 0) + 1
    local d_home = util.distance(nest.position, home)
    if not p.nearest_d or d_home < p.nearest_d then p.nearest, p.nearest_d = nest.position, d_home end
    -- Rings of chunks around the nest's, nearest first.
    for d = 0, p.prepare_at do
      local hit = false
      for dx = -d, d do
        local r = d - math.abs(dx)
        if amount(nest.cx + dx, nest.cy + r) > POLLUTED or (r > 0 and amount(nest.cx + dx, nest.cy - r) > POLLUTED) then
          hit = true
          break
        end
      end
      if hit then
        p.threats[#p.threats + 1] = {position = nest.position, gap = d}
        if not p.gap or d < p.gap then p.gap, p.nest = d, nest.position end
        break
      end
    end
  end
  table.sort(p.threats, function(a, b) return a.gap < b.gap end)
  -- No nest on the revealed map: unrevealed land may hide one, so the cloud stays inside what's revealed,
  -- EDGE_BUFFER chunks from its edge. Before that (prepare_at chunks), the engineer scouts the edge nearest
  -- the cloud (p.scout), revealing more and looking for nests again.
  if not p.nests then
    local checked = 0
    for chunk in surface.get_chunks() do
      if checked >= MAX_EDGE_CHUNKS then break end
      if revealed(chunk.x, chunk.y) and amount(chunk.x, chunk.y) > POLLUTED then
        checked = checked + 1
        for d = 0, p.prepare_at do
          local found
          for dx = -d, d do
            local r = d - math.abs(dx)
            for _, dy in ipairs(r > 0 and {r, -r} or {0}) do
              if not found and not revealed(chunk.x + dx, chunk.y + dy) then found = {chunk.x + dx, chunk.y + dy} end
            end
          end
          if found then
            if not p.edge_gap or d < p.edge_gap then p.edge_gap, p.scout = d, chunk_center(found[1], found[2]) end
            break
          end
        end
      end
    end
    if p.edge_gap then p.edge_level = p.edge_gap <= EDGE_BUFFER and "reduce" or "scout" end
  end
  -- Closing in: a chunk nearer than last time counts one chunk nearer still (the cloud spreads fast here).
  p.closing = last and last.gap and p.gap and p.gap < last.gap or false
  local gap = p.gap and (p.closing and p.gap - 1 or p.gap)
  if not p.gap then p.level = "clear"
  elseif p.gap == 0 then p.level = "reached"
  elseif gap <= p.reduce_at then p.level = "reduce"
  else p.level = "prepare" end
  -- Where turrets go: by the engineer's building nearest each threatened nest, toward it (one spot per building).
  p.guards = {}
  local used = {}
  for _, t in ipairs(p.threats) do
    local b, d = nearest_built(rec, t.position)
    if b and d >= 1 and not used[b.unit_number or 0] and #p.guards < 4 then
      used[b.unit_number or 0] = true
      local ahead = math.max(0, math.min(GUARD_AHEAD, d - util.NEST_CLEARANCE - 4))
      local dx, dy = (t.position.x - b.position.x) / d, (t.position.y - b.position.y) / d
      p.guards[#p.guards + 1] = {x = b.position.x + dx * ahead, y = b.position.y + dy * ahead}
    end
  end
  return p
end

-- The latest measurement (taken again every 30 seconds).
function M.status(rec, home)
  local p = rec.pollution
  if p and game.tick < p.next then return p end
  p = measure(rec, home, p)
  rec.pollution = p
  return p
end

-- Whether keep-busy should prepare for attacks (turrets, ammo, turret research) now.
function M.threatened(rec, home)
  local p = M.status(rec, home)
  return not p.off and p.level ~= "clear", p
end

-- Whether keep-busy holds back on new polluting buildings: the cloud is too close, or machines are still paused.
function M.limited(rec, home)
  local p = M.status(rec, home)
  local c = rec.pollution_control
  return (not p.off and (p.level == "reduce" or p.level == "reached" or p.edge_level == "reduce")) or (c ~= nil and next(c.paused) ~= nil)
end

-- Where to scout (the unrevealed chunk nearest the cloud) while the cloud nears the revealed map's edge
-- with no nest known, or nil.
function M.scout(rec, home)
  local p = M.status(rec, home)
  return not p.off and p.scout or nil
end

local function pause(entity, why)
  entity.disabled_by_script = true
  entity.custom_status = {diode = defines.entity_status_diode.yellow, label = why}
end

local function unpause(entity)
  if not entity.valid then return end
  entity.disabled_by_script = false
  entity.custom_status = nil
end

-- The engineer's drills that can be paused, best first: stone, coal mines with full chests, then iron
-- and copper nearest the nest, keeping KEEP of each running.
local function candidates(rec, toward)
  local running, list = {}, {}
  for _, entity in pairs(rec.built or {}) do
    if entity.valid and entity.type == "mining-drill" and not entity.disabled_by_script then
      local ore = next(jobs.drill_resources(entity.surface, entity.prototype, entity.position))
      local rank
      if ore == "stone" then rank = 0
      elseif ore == "iron-ore" or ore == "copper-ore" then rank = 2
      elseif ore == "coal" and entity.name ~= "burner-mining-drill" then
        local target = util.drill_target(entity)
        if target and target.type == "container" and target.get_item_count("coal") >= FULL_CHEST then rank = 1 end
      end
      if ore then running[ore] = (running[ore] or 0) + 1 end
      if rank then list[#list + 1] = {entity = entity, ore = ore, rank = rank, d = util.distance(entity.position, toward)} end
    end
  end
  table.sort(list, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.d < b.d
  end)
  local out = {}
  for _, c in ipairs(list) do
    if (running[c.ore] or 0) > (KEEP[c.ore] or 0) then
      out[#out + 1] = c
      running[c.ore] = running[c.ore] - 1
    end
  end
  return out
end

local function where(p) return serpent.line(util.pos(p)) end

-- Each keep-busy decision: pause or restart drills by how close the cloud is. `tell` reports to the owner.
function M.manage(rec, home, tell)
  local p = M.status(rec, home)
  local c = rec.pollution_control or {paused = {}, changed = 0}
  rec.pollution_control = c
  for unit, entity in pairs(c.paused) do
    if not entity.valid then c.paused[unit] = nil end
  end
  if p.off then
    if next(c.paused) then M.release(rec, tell) end
    return
  end
  if p.level ~= c.told then
    c.told = p.level
    if p.level == "prepare" then
      local recipe = rec.entity.force.recipes["gun-turret"]
      tell("Pollution is spreading toward the enemy nest at " .. where(p.nest) .. " (" .. p.gap .. " chunks away)" ..
        ((recipe and recipe.enabled) and ": getting gun turrets and ammo ready on that side." or "."))
    elseif p.level == "reached" then
      tell("Pollution has reached the enemy nest at " .. where(p.nest) .. ": attacks will come. Pausing drills and putting up turrets.")
    end
  end
  if p.level == "reduce" or p.level == "reached" then
    c.clear_since = nil
    -- After a pause, wait for the cloud to settle, unless it still comes closer.
    if game.tick - c.changed < PAUSE_WAIT and not (c.gap and p.gap < c.gap) then return end
    local n = p.level == "reached" and 6 or 3
    local paused = {}
    for _, cand in ipairs(candidates(rec, p.nest)) do
      if #paused >= n then break end
      pause(cand.entity, "Paused by the AI engineer: pollution is near an enemy nest")
      c.paused[cand.entity.unit_number] = cand.entity
      paused[#paused + 1] = cand.ore
    end
    c.changed, c.gap = game.tick, p.gap
    if #paused > 0 then
      tell("Pollution is " .. p.gap .. " chunk" .. (p.gap == 1 and "" or "s") .. " from the enemy nest at " .. where(p.nest)
        .. ": paused " .. #paused .. " drill" .. (#paused == 1 and "" or "s") .. " (" .. table.concat(paused, ", ")
        .. "). They stay built and start again once it pulls back.")
    elseif not c.exhausted then
      tell("Pollution is still close to the enemy nest at " .. where(p.nest) .. ", and none of my other drills can stop without"
        .. " stopping the base: the rest of it comes from boilers, coal and your buildings.")
    end
    c.exhausted = #paused == 0
  elseif p.level == "clear" and next(c.paused) then
    c.clear_since = c.clear_since or game.tick
    if game.tick - c.clear_since < RESUME_WAIT or game.tick - c.changed < RESUME_STEP then return end
    -- The paused drill furthest from the nests starts first.
    local best, best_d
    for unit, entity in pairs(c.paused) do
      local d = p.nearest and util.distance(entity.position, p.nearest) or 0
      if not best_d or d > best_d then best, best_d = unit, d end
    end
    unpause(c.paused[best])
    c.paused[best] = nil
    c.changed, c.gap, c.exhausted = game.tick, nil, nil
    local left = table_size(c.paused)
    tell("Pollution has pulled back from the nests: restarted a paused drill" .. (left > 0 and (", " .. left .. " still paused") or "") .. ".")
  else
    c.clear_since = nil
  end
end

-- Keep-busy turned off: every paused drill starts again (nothing would restart them otherwise).
function M.release(rec, tell)
  local c = rec.pollution_control
  if not (c and next(c.paused)) then return end
  local n = 0
  for _, entity in pairs(c.paused) do
    if entity.valid then unpause(entity); n = n + 1 end
  end
  rec.pollution_control = nil
  if n > 0 and tell then tell("Restarted the " .. n .. " drill" .. (n == 1 and "" or "s") .. " paused for pollution.") end
end

-- For observe: how close the cloud is to nests, in words; nil with no nests near or pollution off.
function M.summary(rec, home)
  local p = M.status(rec, home)
  if p.off then return nil end
  if not p.nests then
    if not p.edge_gap then return nil end
    return {status = p.edge_level == "reduce"
      and "no nest known, but the cloud is at the edge of the revealed map: holding back until more is scouted"
      or "no nest known: scouting the edge of the revealed map the cloud is spreading toward", chunks_from_edge = p.edge_gap}
  end
  -- Before turrets are researched there's nothing to build yet: small models chased research in circles.
  local recipe = rec.entity.force.recipes["gun-turret"]
  local words = {
    clear = "clear: the cloud is more than " .. p.prepare_at .. " chunks from every nest",
    prepare = (recipe and recipe.enabled) and "spreading toward a nest: get gun turrets and ammo ready on that side"
      or "spreading toward a nest, but not close yet: nothing to do about it now (gun turrets come with the gun-turret research, once labs run)",
    reduce = "too close: pause machines or attacks start",
    reached = "reached a nest: attacks are coming",
  }
  local c = rec.pollution_control
  local paused = c and next(c.paused) and table_size(c.paused) or nil
  -- (Observe results are resent with every request: the details only when they matter.)
  if p.level == "clear" then return {status = words.clear, paused_drills = paused} end
  return {status = words[p.level], chunks_from_nest = p.gap, nest = p.nest and util.pos(p.nest),
    nests_watched = p.nests, kept_clear_chunks = p.reduce_at, land = p.sparse and "sparse trees: spreads fast" or nil,
    paused_drills = paused}
end

return M
