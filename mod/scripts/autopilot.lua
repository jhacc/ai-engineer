-- Keep-busy's build order: the starting base, the way the owner plays it, run by the mod itself with no
-- AI turns. An iron drill and furnace, a coal loop, a copper drill and
-- furnace, a stone drill into a chest (so nothing needs hand-mining after that), then growth to 10 iron
-- and 2 copper pairs with the coal loop grown into a ring of four, then steam power by the water, a lab on
-- a pole, and red science (a gear assembler feeding a science assembler, plates from chests) for
-- automation, logistics and electric mining drills, then coal to the boiler by belt from two electric
-- drills, running straight along the boilers. All along it keeps every machine
-- fueled and its plates collected, gathers and crafts what each step needs, and collects wood for poles
-- while it waits. After that come goals planned from the game's recipes (goals.lua, cells.lua).
--
-- It yields to the AI: it only acts while the engineer has no other job and the AI isn't in a turn, so
-- the owner's requests come first. Every decision looks at the world again, so a step cut short is picked
-- up again.
local util = require("scripts.util")
local jobs = require("scripts.jobs")
local triggers = require("scripts.triggers")
local gui = require("scripts.gui")
local power = require("scripts.power")
local goals = require("scripts.goals")
local cells = require("scripts.cells")
local pollution = require("scripts.pollution")
local bus = require("scripts.bus")
local M = {}

local DRILL, FURNACE, CHEST = "burner-mining-drill", "stone-furnace", "wooden-chest"
local POLE, LAB, PACK = "small-electric-pole", "lab", "automation-science-pack"
local NORTH, EAST, SOUTH, WEST = 0, 1, 2, 3 -- tool direction arguments

local stash = require("scripts.stash")
-- The AI counts as busy for this long after the app last said it was in a turn (it polls twice a second).
M.AI_QUIET_TICKS = 3 * 60
-- A goal that failed this many times is skipped until keep-busy is turned on again.
local MAX_FAILS = 3
-- Refuel when a machine is below LOW coal, then top up every machine below REFUEL to FILL (big top-ups
-- mean fewer trips around the base).
local LOW, REFUEL, FILL = 3, 10, 20
-- Furnace outputs are collected from this many plates (a stone furnace stops at 100).
local COLLECT_AT = 40
-- Plates collected only while holding fewer than this many of them (10 stacks).
local CARRY_MAX = 1000
-- Kept on hand while plates smelt during the base: coal for refueling, stone for the next furnaces.
local COAL_RESERVE, STONE_RESERVE = 30, 20
-- Wood collected while waiting, once the base is up, for power poles (one wood makes two).
local WOOD_RESERVE = 50
-- Science packs kept in the lab, and crafted at a time; what the science assembler is topped up to.
local LAB_LOW, PACK_BATCH = 5, 10
local ASSEMBLER_LOW, ASSEMBLER_FILL = 5, 20
-- Iron gear wheels crafted in free time, up to this many, a batch at a time.
local GEAR, GEAR_TARGET, GEAR_BATCH = "iron-gear-wheel", 100, 10

-- The starting base, in order. Counts are drills, except rings (whole rings of four).
local BASE = {
  {kind = "pair", ore = "iron-ore", target = 1, label = "iron drill and furnace"},
  {kind = "loop", ore = "coal", target = 2, label = "coal loop"},
  {kind = "pair", ore = "copper-ore", target = 1, label = "copper drill and furnace"},
  {kind = "chest", ore = "stone", target = 1, label = "stone drill and chest"},
}
-- Then grow toward these, adding to whichever is furthest behind (in this order on ties). The ring grows
-- from the first loop's pair (grow_ring), or replaces it, so there are four coal drills. With no room for a
-- ring of four on the coal, more coal loops instead.
local GROWTH = {
  {kind = "pair", ore = "iron-ore", target = 10, label = "iron drill and furnace"},
  {kind = "ring", ore = "coal", target = 1, label = "ring of four coal drills"},
  {kind = "pair", ore = "copper-ore", target = 2, label = "copper drill and furnace"},
  {kind = "loop", ore = "coal", target = 6, label = "coal loop", without = "ring:coal"},
}
local STEAM = {count = "steam", label = "steam power plant"}
local POWERED_LAB = {count = "lab", label = "lab on steam power"}
local SCIENCE = {count = "science", label = "red science assembler feeding the lab"}
local SCIENCE_GEARS = {count = "science_gears", label = "gear assembler feeding the red science assembler"}
-- Researched in the lab, in order (prerequisites first). The science assembler goes up once the first is done.
local RESEARCH = {"automation", "logistics", "electric-mining-drill"}
local ASSEMBLER, INSERTER = "assembling-machine-1", "inserter"
local EDRILL, BELT = "electric-mining-drill", "transport-belt"
-- After the research: coal comes to the boiler by belt, so the plant needs no refueling by hand.
local COAL_BELT = {count = "coal_belt", label = "coal belt from electric drills to the boiler"}

-- A goal's name in survey's counts, and for failures and skips.
local function id(goal) return goal.count or (goal.kind .. ":" .. goal.ore) end
local key = id

local function state(rec)
  rec.auto = rec.auto or {fails = {}, skip = {}, skipped = {}}
  return rec.auto
end

-- What the build order did, for the app's terminal (it gets the last lines with each poll) and as a log
-- line in the owner's chat window (unless `told`: tell shows it as a progress line instead).
local LOG_KEEP = 20
local function note(rec, text, told)
  local s = state(rec)
  s.log = s.log or {}
  if #s.log > 0 and s.log[#s.log].text == text then return end
  s.log_n = (s.log_n or 0) + 1
  s.log[#s.log + 1] = {n = s.log_n, text = text}
  if #s.log > LOG_KEEP then table.remove(s.log, 1) end
  local player = not told and rec.owner > 0 and game.get_player(rec.owner) or nil
  if player then gui.note(player, "build order: " .. text) end
end

-- Tell the owner in the chat window (as a grey progress line), and keep it for observe.
local function tell(rec, text)
  local s = state(rec)
  s.news = text
  note(rec, text, true)
  local player = rec.owner > 0 and game.get_player(rec.owner) or nil
  if player then gui.log(player, rec.name or "Engineer", text, true) end
end

---------------------------------------------------------------------------
-- What's built

local TRACKED = {"mining-drill", "furnace", "container", "boiler", "generator", "lab", "offshore-pump", "electric-pole",
  "pipe", "assembling-machine", "inserter"}

-- Saves from before the engineer's buildings were tracked: adopt the buildings near it that no player
-- built. Only with a single engineer, since otherwise there's no telling whose they are.
local function adopt(rec)
  rec.adopted = true
  rec.built = rec.built or {}
  if table_size(storage.engineers) > 1 then return end
  local e = rec.entity
  for _, entity in ipairs(e.surface.find_entities_filtered{position = e.position, radius = 128, force = e.force, type = TRACKED}) do
    if not entity.last_user and entity.unit_number and not entity.name:find("^crash%-site") then
      rec.built[entity.unit_number] = entity
    end
  end
end

local function fuel(entity)
  local inventory = entity.get_fuel_inventory()
  return inventory and inventory.get_item_count() or 0
end

local function ore_under(drill)
  return next(jobs.drill_resources(drill.surface, drill.prototype, drill.position))
end

local function add(w, k, entity)
  w.count[k] = (w.count[k] or 0) + 1
  w.first[k] = w.first[k] or entity
end

-- The engineer's buildings by role. count["pair:iron-ore"] is the number of iron drills feeding a furnace,
-- count["loop:coal"] the coal drills in loops (drills feeding each other round in a circle),
-- count["ring:coal"] the loops of four, count["chest:stone"] stone drills into a chest, count.steam the
-- steam engines, count.lab the labs with power and count.science the assemblers making science for a lab.
-- Drills feeding drills that don't come round in a circle (a ring built wrong) are `broken`.
local function key_of(p) return math.floor(p.x) .. "," .. math.floor(p.y) end

local function survey(rec)
  local w = {count = {}, first = {}, burners = {}, loop_drills = {}, loop_pairs = {}, furnaces = {}, chests = {}, unfed = {}, orphans = {},
    labs = {}, broken = {}, poles = {}, inserters = {}, burner_pairs = {}, turrets = {}, packs = {}, science = {},
    electric_pairs = {}, plate_chests = {}, line_furnaces = {}}
  local fed, links = {}, {}
  -- The ore lines' own parts (ore_lines below): their drills, furnaces and plate chests.
  local lines = (rec.auto and rec.auto.ore_plan) or {}
  local line_at = lines.parts or {}
  for id, entity in pairs(rec.built or {}) do
    if not entity.valid then
      rec.built[id] = nil
    elseif line_at[key_of(entity.position)] == entity.name then
      if entity.type == "furnace" then w.line_furnaces[#w.line_furnaces + 1] = entity
      elseif entity.type == "container" then w.plate_chests[#w.plate_chests + 1] = entity
      elseif entity.type == "electric-pole" then w.poles[#w.poles + 1] = entity
      elseif entity.type == "inserter" then w.inserters[#w.inserters + 1] = entity end
    elseif entity.type == "mining-drill" and entity.name ~= DRILL then
      -- Electric drills feed a belt (the coal line) or a furnace (a pair that replaced a burner one, which
      -- counts toward the pairs the same way).
      local target = util.drill_target(entity)
      local belt = entity.surface.find_entities_filtered{position = entity.drop_position, radius = 0.3, type = "transport-belt"}[1]
      if belt and entity.is_connected_to_electric_network() then
        w.belt_drills = (w.belt_drills or 0) + 1
      elseif target and target.type == "furnace" then
        local ore = ore_under(entity)
        fed[target.unit_number] = true
        if ore then add(w, "pair:" .. ore, entity) end
        w.electric_pairs[#w.electric_pairs + 1] = {drill = entity, furnace = target, ore = ore}
      elseif target and target.type == "container" and ore_under(entity) == "coal" then
        -- The coal mine: electric drills filling chests the engineer takes coal from.
        w.mine_drills = (w.mine_drills or 0) + 1
        w.mine_chests = w.mine_chests or {}
        w.mine_chests[#w.mine_chests + 1] = target
        -- (And its parts, which the coal belt growing over the coal may move: mine_parts' pole beside it.)
        w.mine_parts = w.mine_parts or {}
        w.mine_parts[#w.mine_parts + 1] = entity
        w.mine_parts[#w.mine_parts + 1] = target
        local pole = entity.surface.find_entities_filtered{type = "electric-pole", position = {entity.position.x + 2, entity.position.y}, radius = 0.3}[1]
        if pole then w.mine_parts[#w.mine_parts + 1] = pole end
      elseif target and target.type == "container" then
        -- The stone drill's electric replacement.
        local ore = ore_under(entity)
        if ore then add(w, "chest:" .. ore, entity) end
      end
    elseif entity.type == "mining-drill" then
      local ore = ore_under(entity)
      local target = util.drill_target(entity)
      local kind = target and ((target.type == "furnace" and "pair") or (target.type == "container" and "chest")) or nil
      if target and target.unit_number then fed[target.unit_number] = true end
      if ore and target and target.type == "mining-drill" then
        links[entity.unit_number] = {drill = entity, target = target, ore = ore}
      elseif ore and kind then
        add(w, kind .. ":" .. ore, entity)
        if kind == "pair" then w.burner_pairs[#w.burner_pairs + 1] = {drill = entity, furnace = target, ore = ore, kind = "pair"}
        else w.burner_pairs[#w.burner_pairs + 1] = {drill = entity, chest = target, ore = ore, kind = "chest"} end
      elseif ore then
        w.unfed[#w.unfed + 1] = {drill = entity, ore = ore}
      end
      -- Loop drills fuel each other (below); a drill with its ore used up needs nothing.
      if ore and not links[entity.unit_number] then w.burners[#w.burners + 1] = entity end
    elseif entity.type == "electric-pole" then
      w.poles[#w.poles + 1] = entity
    elseif entity.type == "ammo-turret" then
      w.turrets[#w.turrets + 1] = entity
    elseif entity.type == "assembling-machine" then
      local recipe = entity.get_recipe()
      if recipe and recipe.name == PACK then w.packs[#w.packs + 1] = entity end
    elseif entity.type == "inserter" then
      w.inserters[#w.inserters + 1] = entity
    elseif entity.type == "furnace" and goals.cell_recipe(rec, entity) then
      -- A goal's furnace (steel, bricks): fueled here, fed and emptied by its goal, never given a drill.
      if entity.get_fuel_inventory() then w.burners[#w.burners + 1] = entity end
    elseif entity.type == "furnace" then
      w.burners[#w.burners + 1] = entity
      w.furnaces[#w.furnaces + 1] = entity
    elseif entity.type == "container" then
      w.chests[#w.chests + 1] = entity
    elseif entity.type == "boiler" then
      w.burners[#w.burners + 1] = entity
    elseif entity.type == "generator" then
      w.engine = w.engine or entity
      w.count.steam = (w.count.steam or 0) + 1
    elseif entity.type == "lab" then
      if entity.is_connected_to_electric_network() then
        w.labs[#w.labs + 1] = entity
        w.count.lab = (w.count.lab or 0) + 1
      end
    end
  end
  for _, furnace in ipairs(w.furnaces) do
    if not fed[furnace.unit_number] then w.orphans[#w.orphans + 1] = furnace end
  end
  -- Follow each drill's output round: back to itself means a loop (of that many drills).
  for unit, link in pairs(links) do
    local cur, len = link.target, 1
    while cur and cur ~= link.drill and len <= 8 do
      local nxt = cur.unit_number and links[cur.unit_number]
      cur, len = nxt and nxt.target, len + 1
    end
    if cur == link.drill then
      add(w, "loop:" .. link.ore, link.drill)
      w.loop_drills[#w.loop_drills + 1] = link.drill
      -- A pair facing each other side by side (the first loop), by its west drill: a ring grows from it.
      local t = link.target
      if len == 2 and t.position.y == link.drill.position.y and t.position.x == link.drill.position.x + 2 then
        w.loop_pairs[#w.loop_pairs + 1] = {west = link.drill, east = t, ore = link.ore}
      end
      if len == 4 then
        w.ring_drills = (w.ring_drills or 0) + 1
        w.first["ring:" .. link.ore] = w.first["ring:" .. link.ore] or link.drill
        w.count["ring:" .. link.ore] = math.floor(w.ring_drills / 4)
      end
    else
      w.broken[#w.broken + 1] = link.drill
    end
  end
  -- Red science: each science assembler an inserter takes from into a lab, all on power, is a unit
  -- (w.science), with what feeds it: a gear assembler by inserter, and a chest of copper plates by inserter
  -- (the gear assembler has its own chest of iron plates). count.science once there's one, count.science_gears
  -- once the first gets gears from an assembler, and science_units how many there are.
  local by_unit = {}
  for _, inserter in ipairs(w.inserters) do
    local from, drop = inserter.pickup_target, inserter.drop_target
    if from and from.type == "assembling-machine" and drop and drop.type == "lab" and from.is_connected_to_electric_network() then
      local recipe = from.get_recipe()
      if recipe and recipe.name == PACK and not by_unit[from.unit_number] then
        local unit = {asm = from}
        by_unit[from.unit_number] = unit
        w.science[#w.science + 1] = unit
      end
    end
  end
  local gear_chests = {}
  for _, inserter in ipairs(w.inserters) do
    local from, drop = inserter.pickup_target, inserter.drop_target
    local unit = drop and drop.unit_number and by_unit[drop.unit_number]
    if unit and from and from.type == "container" then unit.chest = from end
    if unit and from and from.type == "assembling-machine" then
      local recipe = from.get_recipe()
      if recipe and recipe.name == GEAR and from.is_connected_to_electric_network() and inserter.is_connected_to_electric_network() then
        unit.gear = from
      end
    end
    if from and from.type == "container" and drop and drop.type == "assembling-machine" then
      local recipe = drop.get_recipe()
      if recipe and recipe.name == GEAR then gear_chests[drop.unit_number] = from end
    end
  end
  for _, unit in ipairs(w.science) do
    unit.gear_chest = unit.gear and gear_chests[unit.gear.unit_number]
  end
  local first = w.science[1]
  w.assembler = first and first.asm or w.packs[1]
  if first then w.count.science = 1 end
  if first and first.gear then w.count.science_gears = 1 end
  w.count.science_units = #w.science
  -- The coal belt counts once a powered inserter takes from a belt into a boiler, with powered electric
  -- drills feeding a belt; belt_boilers is how many boilers it feeds.
  local belt_fed = {}
  for _, inserter in ipairs(w.belt_drills and w.inserters or {}) do
    local from, drop = inserter.pickup_target, inserter.drop_target
    if from and from.type == "transport-belt" and drop and drop.type == "boiler" and inserter.is_connected_to_electric_network() then
      w.count.coal_belt = 1
      if not belt_fed[drop.unit_number] then
        belt_fed[drop.unit_number] = true
        w.belt_boilers = (w.belt_boilers or 0) + 1
      end
    end
  end
  -- An inserter keeps only a few coal in a boiler, always under BOILER_LOW, so a boiler on the belt was
  -- topped up by hand over and over. It's refueled by hand only once it's empty (the belt ran dry).
  if next(belt_fed) then
    local kept = {}
    for _, b in ipairs(w.burners) do
      if not (belt_fed[b.unit_number] and fuel(b) > 0) then kept[#kept + 1] = b end
    end
    w.burners = kept
  end
  return w
end

---------------------------------------------------------------------------
-- Actions: a job for jobs.start, with what it's for

local function xy(entity) return entity.position.x, entity.position.y end

local function insert(entity, item, count)
  local x, y = xy(entity)
  return {pos = entity.position, step = {action = "insert", item = item, count = count, x = x, y = y}}
end
local function take(entity, item, count)
  local x, y = xy(entity)
  return {pos = entity.position, step = {action = "take", item = item, count = count, x = x, y = y}}
end

-- Visits in nearest-first order from the engineer, as one steps job (at most 20).
local function route(rec, todo, describe)
  local out, here = {}, rec.entity.position
  while #todo > 0 and #out < 20 do
    local best, best_d
    for i, visit in ipairs(todo) do
      local d = util.distance(here, visit.pos)
      if not best_d or d < best_d then best, best_d = i, d end
    end
    local visit = table.remove(todo, best)
    out[#out + 1] = visit.step
    here = visit.pos
  end
  return {kind = "steps", args = {steps = out}, describe = describe}
end

local function mine(name, count, describe)
  return {kind = "mine", args = {name = name, count = count}, describe = describe}
end

-- Coal from the loops (each drill keeps 5 to stay running). A trip to the loops takes all they have, since
-- refueling the base uses a lot. Coal is mined by hand only until the base is up, or when there's none at
-- all to get things going again.
local function get_coal(rec, w, amount)
  local todo, got = {}, 0
  -- The coal belt first: coal backs up on it by its drills (the boilers take what they need further on).
  local line = state(rec).coal_line
  if w.count.coal_belt and line and line.drills then
    local e = rec.entity
    local best, best_n
    for _, belt in ipairs(e.surface.find_entities_filtered{type = "transport-belt", force = e.force, position = line.drills[1].position, radius = 12}) do
      local n = belt.get_transport_line(1).get_item_count("coal") + belt.get_transport_line(2).get_item_count("coal")
      if not best_n or n > best_n then best, best_n = belt, n end
    end
    if best and best_n >= 4 then
      return {kind = "steps", args = {steps = {{action = "take", item = "coal", count = math.max(amount, 50), x = best.position.x, y = best.position.y}}},
        describe = "taking coal off the coal belt"}
    end
  end
  -- The coal mine's chests first: electric drills fill them much faster than loops make spare coal.
  for _, chest in ipairs(w.mine_chests or {}) do
    local n = chest.valid and chest.get_item_count("coal") or 0
    if n >= 10 and got < amount then
      todo[#todo + 1] = take(chest, "coal", math.min(n, amount - got + 50))
      got = got + n
    end
  end
  for _, drill in ipairs(w.loop_drills) do
    local spare = fuel(drill) - 5
    if spare >= 5 then
      todo[#todo + 1] = take(drill, "coal", spare)
      got = got + spare
    end
  end
  if got >= math.min(amount, 10) then return route(rec, todo, "collecting coal from the loops") end
  if state(rec).base_done then
    local running = false
    for _, drill in ipairs(w.loop_drills) do
      if fuel(drill) > 0 then running = true; break end
    end
    if running then
      if got > 0 then return route(rec, todo, "collecting coal from the loops") end
      return nil, "waiting for the coal loops"
    end
  end
  return mine("coal", math.min(amount, 50), "mining coal")
end

---------------------------------------------------------------------------
-- Refueling and collecting

-- Boilers burn coal far faster than drills and furnaces (one at full load takes about 27 a minute), so
-- they're topped up sooner and fuller, or the power goes out between trips.
local BOILER_LOW, BOILER_REFUEL, BOILER_FILL = 15, 30, 50
local function low_at(b) return b.type == "boiler" and BOILER_LOW or LOW end
local function refuel_at(b) return b.type == "boiler" and BOILER_REFUEL or REFUEL end
local function fill_to(b) return b.type == "boiler" and BOILER_FILL or FILL end

-- `refuel_only`: just the refueling (during an order of the owner's, whose plates aren't taken here).
local function maintenance(rec, w, refuel_only)
  local e = rec.entity
  local coal = e.get_item_count("coal")
  local todo = {}
  local urgent = false
  for _, b in ipairs(w.burners) do
    if fuel(b) < low_at(b) then urgent = true; break end
  end
  -- A loop that went out (all its drills empty) restarts with one coal.
  local dead, seen = {}, {}
  for _, drill in ipairs(w.loop_drills) do
    local partner = util.drill_target(drill)
    if not seen[drill.unit_number] and partner and fuel(drill) == 0 and fuel(partner) == 0 then
      dead[#dead + 1] = drill
      seen[partner.unit_number] = true
      urgent = true
    end
  end
  if urgent then
    local spare = coal
    for _, drill in ipairs(dead) do
      if spare > 0 then todo[#todo + 1] = insert(drill, "coal", 1); spare = spare - 1 end
    end
    local low = {}
    for _, b in ipairs(w.burners) do
      local f = fuel(b)
      if f < refuel_at(b) then low[#low + 1] = {entity = b, fuel = f, fill = fill_to(b)} end
    end
    -- Boilers first (everything electric stops without them), then the emptiest.
    table.sort(low, function(a, b)
      local ab, bb = a.entity.type == "boiler", b.entity.type == "boiler"
      if ab ~= bb then return ab end
      return a.fuel < b.fuel
    end)
    for _, l in ipairs(low) do
      local n = math.min(l.fill - l.fuel, spare)
      if n > 0 then todo[#todo + 1] = insert(l.entity, "coal", n); spare = spare - n end
    end
    if #todo == 0 then
      local need = 0
      for _, l in ipairs(low) do need = need + l.fill - l.fuel end
      local action = get_coal(rec, w, math.max(need, COAL_RESERVE))
      if action then return action end
    end
  end
  -- Plates the engineer already holds plenty of stay in the furnaces (taken when something needs them):
  -- a full inventory can't take coal, and then nothing gets refueled.
  if not refuel_only and e.get_main_inventory().count_empty_stacks() >= 3 then
    for _, furnace in ipairs(w.furnaces) do
      local output = furnace.get_output_inventory()
      local item = output and not output.is_empty() and output[1].valid_for_read and output[1].name
      if item and output.get_item_count() >= COLLECT_AT and e.get_item_count(item) < CARRY_MAX then todo[#todo + 1] = take(furnace) end
    end
    for _, chest in ipairs(w.plate_chests) do
      for _, plate in ipairs({"iron-plate", "copper-plate"}) do
        local n = chest.get_item_count(plate)
        if n >= COLLECT_AT and e.get_item_count(plate) < CARRY_MAX then todo[#todo + 1] = take(chest, plate, math.min(n, CARRY_MAX)) end
      end
    end
  end
  if #todo == 0 then return nil end
  return route(rec, todo, urgent and "refueling machines" or "collecting plates")
end

---------------------------------------------------------------------------
-- Where to build

-- Every spot check counts trees and rocks as cleared (placing chops them): a power plant row or a pole that
-- only trees are in the way of still fits.
local PASSABLE = util.PASSABLE
local can_place = util.can_build

-- A drill at `p` covers only `ore` on every tile and can be placed.
local function drill_fits(surface, force, ore, p, dir)
  local proto = prototypes.entity[DRILL]
  local counts = jobs.drill_resources(surface, proto, p)
  local size = math.floor(proto.mining_drill_radius * 2 + 0.5)
  local name, n = next(counts)
  return name == ore and n == size * size and next(counts, name) == nil and can_place(surface, force, DRILL, p, dir)
end

-- Where a drill at `p` facing south drops its output, as the center of a 1x1 chest.
local function chest_spot(p)
  local v = prototypes.entity[DRILL].vector_to_place_result or {0.5, -1.3}
  local vx, vy = v.x or v[1], v.y or v[2]
  return {x = math.floor(p.x - vx) + 0.5, y = math.floor(p.y - vy) + 0.5}
end

-- No player-built entity close by: the owner's space is left alone.
local function owner_clear(surface, force, p)
  for _, entity in ipairs(surface.find_entities_filtered{area = {{p.x - 3, p.y - 3}, {p.x + 5, p.y + 5}}, force = force}) do
    if entity.last_user then return false end
  end
  return true
end

-- A ring of four coal drills, each feeding the next: offsets and directions from the first.
local RING = {{0, 0, EAST}, {2, 0, SOUTH}, {2, 2, WEST}, {0, 2, NORTH}}

local function fits(surface, force, goal, p)
  if goal.kind == "pair" then
    return drill_fits(surface, force, goal.ore, p, SOUTH) and can_place(surface, force, FURNACE, {x = p.x, y = p.y + 2}, NORTH)
  elseif goal.kind == "loop" then
    return drill_fits(surface, force, goal.ore, p, EAST) and drill_fits(surface, force, goal.ore, {x = p.x + 2, y = p.y}, WEST)
  elseif goal.kind == "ring" then
    for _, r in ipairs(RING) do
      if not drill_fits(surface, force, goal.ore, {x = p.x + r[1], y = p.y + r[2]}, r[3]) then return false end
    end
    return true
  end
  return drill_fits(surface, force, goal.ore, p, SOUTH) and can_place(surface, force, CHEST, chest_spot(p), NORTH)
end

-- Offsets around an anchor, nearest first, preferring the same row so buildings line up.
local OFFSETS
local function offsets()
  if OFFSETS then return OFFSETS end
  OFFSETS = {}
  for dx = -20, 20 do
    for dy = -20, 20 do OFFSETS[#OFFSETS + 1] = {dx, dy} end
  end
  local function cost(o) return math.abs(o[1]) + 2 * math.abs(o[2]) end
  table.sort(OFFSETS, function(a, b)
    if cost(a) ~= cost(b) then return cost(a) < cost(b) end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  return OFFSETS
end

-- A spot for `goal`'s drill (whole-number coordinates): next to the first one like it, else on the patch
-- nearest home. Returns nil and why when there's none.
local function find_spot(rec, w, goal)
  local s, e = state(rec), rec.entity
  local first = w.first[key(goal)] or w.first["loop:" .. goal.ore]
  local anchor = first and first.position
  if not anchor then
    local bases = util.enemy_bases(e.surface, s.home, 256 + util.NEST_CLEARANCE)
    local ore = jobs.nearest(e.surface, {goal.ore}, s.home, nil, 256, bases)
    if not ore then return nil, "there's no " .. goal.ore .. " within 256 tiles that's safe from enemy nests" end
    anchor = ore.position
  end
  local bases = util.enemy_bases(e.surface, anchor, 30 + util.NEST_CLEARANCE)
  local ax, ay = math.floor(anchor.x + 0.5), math.floor(anchor.y + 0.5)
  for _, o in ipairs(offsets()) do
    local p = {x = ax + o[1], y = ay + o[2]}
    if not s.skip[p.x .. "," .. p.y] and not util.base_near(bases, p) and fits(e.surface, e.force, goal, p)
      and owner_clear(e.surface, e.force, p) then
      return p
    end
  end
  return nil, "there's no free spot fully on " .. goal.ore .. " near " .. serpent.line(util.pos(anchor))
end

---------------------------------------------------------------------------
-- Getting what a step needs

-- What's missing to have `list` ({{item, count}, ...}) in the inventory: raw materials to gather (item ->
-- count) and the crafts to queue ({recipe, times}), in order. Crafting uses intermediates from the
-- inventory first, as a player's does (a drill takes a furnace you hold), so they're counted in the same order.
local function plan_crafts(e, list)
  local avail, raw, crafts = {}, {}, {}
  local handcraft = e.prototype.crafting_categories or {}
  local function need(name, n, top)
    if avail[name] == nil then avail[name] = e.get_item_count(name) end
    local use = math.min(avail[name], n)
    avail[name], n = avail[name] - use, n - use
    if n <= 0 then return end
    local recipe = e.force.recipes[name]
    if recipe and recipe.enabled and handcraft[util.category(recipe)] then
      local makes = recipe.products[1].amount or 1
      local times = math.ceil(n / makes)
      for _, i in ipairs(recipe.ingredients) do need(i.name, i.amount * times) end
      avail[name] = avail[name] + times * makes - n
      if top then crafts[#crafts + 1] = {name, times} end
    else
      raw[name] = (raw[name] or 0) + n
    end
  end
  for _, item in ipairs(list) do need(item[1], item[2], true) end
  return raw, crafts
end

local function craft(rec, recipe, count)
  if count <= 0 then return end
  triggers.update(rec)
  rec.entity.begin_crafting{recipe = recipe, count = count, silent = true}
  triggers.update(rec)
end

local function queue(rec, crafts)
  for _, c in ipairs(crafts) do craft(rec, c[1], c[2]) end
end

local ORE_OF = {["iron-plate"] = "iron-ore", ["copper-plate"] = "copper-ore"}

-- Whether any furnace is making (or holds) these plates.
local function producing(w, plate)
  if (w.count["pair:" .. ORE_OF[plate]] or 0) > 0 or #w.line_furnaces > 0 then return true end
  for _, furnace in ipairs(w.furnaces) do
    if furnace.get_item_count(plate) > 0 or furnace.get_item_count(ORE_OF[plate]) > 0 then return true end
  end
  return false
end

-- No furnace makes these plates (the starting drill is gone): a furnace fed by hand, where the pair's
-- furnace goes, so a drill joins it once there are plates for one.
local function bootstrap(rec, w, plate, wanted)
  local e = rec.entity
  local goal = {kind = "pair", ore = ORE_OF[plate]}
  if e.get_item_count(FURNACE) == 0 and e.crafting_queue_size == 0 then
    if e.get_item_count("stone") < 5 then return mine("stone", 10, "mining stone for a furnace") end
    craft(rec, FURNACE, 1)
  end
  if e.get_item_count("coal") < 5 then return get_coal(rec, w, 15) end
  local p, why = find_spot(rec, w, goal)
  if not p then return nil, why end
  local x, y = p.x, p.y + 2
  return {kind = "steps", describe = "smelting hand-mined " .. goal.ore, spot = p, args = {steps = {
    {action = "place", item = FURNACE, x = x, y = y},
    {action = "insert", item = "coal", count = 5, x = x, y = y},
    {action = "insert", item = goal.ore, count = math.min(math.max(wanted, 10), 50), x = x, y = y},
  }}}
end

-- One job toward the missing raw materials, or nil and what it's waiting for.
local function acquire(rec, w, raw)
  local s, e = state(rec), rec.entity
  if raw.coal then
    local action, why = get_coal(rec, w, raw.coal + 10)
    if action or why then return action, why end
  end
  if raw.stone then
    local todo, got = {}, 0
    for _, chest in ipairs(w.chests) do
      local n = chest.get_item_count("stone")
      if n > 0 and got < raw.stone then todo[#todo + 1] = take(chest, "stone"); got = got + n end
    end
    if got >= raw.stone then return route(rec, todo, "collecting stone") end
    -- After the base, stone comes from the stone drill (hand-mined only if there's none).
    if s.base_done and (w.count["chest:stone"] or 0) > 0 then return nil, "waiting for stone from the stone drill" end
    return mine("stone", math.max(raw.stone, 10), "mining stone")
  end
  if raw.wood then return mine("wood", raw.wood, "getting wood") end
  for _, plate in ipairs({"iron-plate", "copper-plate"}) do
    local wanted = raw[plate]
    if wanted then
      if not producing(w, plate) then return bootstrap(rec, w, plate, wanted) end
      local todo, ready = {}, 0
      -- The ore lines' plate chests first.
      for _, chest in ipairs(w.plate_chests) do
        local n = chest.get_item_count(plate)
        if n > 0 and ready < wanted then todo[#todo + 1] = take(chest, plate, n); ready = ready + n end
      end
      for _, furnace in ipairs(w.furnaces) do
        local n = furnace.get_output_inventory().get_item_count(plate)
        if n > 0 then todo[#todo + 1] = take(furnace); ready = ready + n end
      end
      if ready >= wanted then return route(rec, todo, "collecting " .. plate) end
      -- Still smelting: stock up meanwhile (while the base goes up; after that, wood is collected instead).
      if not s.base_done then
        if e.get_item_count("coal") < COAL_RESERVE then return get_coal(rec, w, COAL_RESERVE) end
        if e.get_item_count("stone") < STONE_RESERVE then return mine("stone", STONE_RESERVE, "mining stone") end
      end
      return nil, "waiting for " .. (wanted - ready) .. " more " .. plate .. " to smelt"
    end
  end
  local other = next(raw)
  if other then return nil, "needs " .. other .. ", which can't be made yet" end
end

-- Gather for and queue the crafts of `list`; returns nil, nil once it's all in the inventory. What the
-- mall's chests (goals.add_mall) and the storage chests (stash.lua) hold is taken from there first
-- instead of being hand-crafted or mined.
local function get_items(rec, w, list, label)
  local e = rec.entity
  local todo, taking = {}, {}
  local sources = stash.chests(rec, state(rec))
  for _, goal in ipairs(goals.list(rec.owner)) do
    for _, out in ipairs(goal.products and goal.block and goal.block.outputs or {}) do
      local chest = out.chest and e.surface.find_entities_filtered{name = CHEST, position = out.chest, radius = 0.5}[1]
      if chest then sources[#sources + 1] = chest end
    end
  end
  for _, chest in ipairs(sources) do
    for _, item in ipairs(list) do
      local n = math.min(chest.get_item_count(item[1]), item[2] - e.get_item_count(item[1]) - (taking[item[1]] or 0))
      if n > 0 then
        todo[#todo + 1] = take(chest, item[1], n)
        taking[item[1]] = (taking[item[1]] or 0) + n
      end
    end
  end
  if #todo > 0 then
    local job = route(rec, todo, "taking what's needed from the mall and storage")
    job.describe = label .. ": " .. job.describe
    return job, nil, true
  end
  local raw, crafts = plan_crafts(rec.entity, list)
  if next(raw) then
    local action, why = acquire(rec, w, raw)
    if action then action.describe = label .. ": " .. action.describe end
    return action, why and (label .. ": " .. why) or nil, true
  end
  if #crafts > 0 then
    if rec.entity.crafting_queue_size > 0 then return nil, label .. ": waiting for crafting", true end
    queue(rec, crafts)
  end
  return nil, nil, false
end

---------------------------------------------------------------------------
-- Building drills

-- The ring of four grown from the first loop's pair, so there are four coal drills, not six: the pair's
-- east drill turned to face down the ring, and two more drills beside the pair (below it, else above).
local function grow_ring(rec, w, goal)
  local e = rec.entity
  local pair = w.loop_pairs[1]
  if not pair or pair.ore ~= goal.ore then return end
  local a, b = pair.west.position, pair.east.position
  for _, dy in ipairs({2, -2}) do
    local turn, close = dy > 0 and SOUTH or NORTH, dy > 0 and NORTH or SOUTH
    local c, d = {x = b.x, y = b.y + dy}, {x = a.x, y = a.y + dy}
    if drill_fits(e.surface, e.force, goal.ore, c, WEST) and drill_fits(e.surface, e.force, goal.ore, d, close)
      and owner_clear(e.surface, e.force, d) then
      local action, waiting, busy = get_items(rec, w, {{DRILL, 2}, {"coal", 1}}, goal.label)
      if busy then return action, waiting end
      return {kind = "steps", describe = "growing the coal loop into a " .. goal.label, goal = goal, spot = a, args = {steps = {
        {action = "pick_up", x = b.x, y = b.y},
        {action = "place", item = DRILL, x = b.x, y = b.y, direction = turn},
        {action = "place", item = DRILL, x = c.x, y = c.y, direction = WEST},
        {action = "place", item = DRILL, x = d.x, y = d.y, direction = close},
        {action = "insert", item = "coal", count = 1, x = c.x, y = c.y},
      }}}
    end
  end
end

local build_electric -- (below, with the electric drills)

local function build(rec, w, goal)
  local e = rec.entity
  -- No more burner drills once the coal belt runs (electric drills are in by then).
  if (goal.kind == "pair" or goal.kind == "chest") and w.count.coal_belt then return build_electric(rec, w, goal) end
  if goal.kind == "ring" then
    local action, waiting = grow_ring(rec, w, goal)
    if action or waiting then return action, waiting end
  end
  -- A furnace left without its drill (or the hand-fed one from bootstrap) gets the drill behind it.
  local reuse
  if goal.kind == "pair" then
    for _, furnace in ipairs(w.orphans) do
      local p = {x = furnace.position.x, y = furnace.position.y - 2}
      if drill_fits(e.surface, e.force, goal.ore, p, SOUTH) then reuse = p; break end
    end
  end
  local p, why = reuse, nil
  if not p then
    p, why = find_spot(rec, w, goal)
    if not p then return nil, why, true end
  end
  -- Coal for the drill and its furnace: goal.fuel when an order sized it (M.starter), else 5 each.
  local fuel = goal.fuel or {drill = 5, furnace = 5}
  local list
  if goal.kind == "pair" then list = {{DRILL, 1}, {FURNACE, reuse and 0 or 1}, {"coal", fuel.drill + fuel.furnace}}
  elseif goal.kind == "loop" then list = {{DRILL, 2}, {"coal", 1}}
  elseif goal.kind == "ring" then list = {{DRILL, 4}, {"coal", 1}}
  else list = {{DRILL, 1}, {CHEST, 1}, {"coal", fuel.drill}} end
  local action, waiting, busy = get_items(rec, w, list, goal.label)
  if busy then return action, waiting end
  local steps = {}
  if goal.kind == "pair" then
    steps[#steps + 1] = {action = "place", item = DRILL, x = p.x, y = p.y, direction = SOUTH}
    if not reuse then steps[#steps + 1] = {action = "place", item = FURNACE, x = p.x, y = p.y + 2} end
    steps[#steps + 1] = {action = "insert", item = "coal", count = fuel.drill, x = p.x, y = p.y}
    steps[#steps + 1] = {action = "insert", item = "coal", count = fuel.furnace, x = p.x, y = p.y + 2}
  elseif goal.kind == "loop" then
    steps[1] = {action = "place", item = DRILL, x = p.x, y = p.y, direction = EAST}
    steps[2] = {action = "place", item = DRILL, x = p.x + 2, y = p.y, direction = WEST}
    steps[3] = {action = "insert", item = "coal", count = 1, x = p.x, y = p.y}
  elseif goal.kind == "ring" then
    for _, r in ipairs(RING) do
      steps[#steps + 1] = {action = "place", item = DRILL, x = p.x + r[1], y = p.y + r[2], direction = r[3]}
    end
    steps[#steps + 1] = {action = "insert", item = "coal", count = 1, x = p.x, y = p.y}
  else
    local c = chest_spot(p)
    steps[1] = {action = "place", item = DRILL, x = p.x, y = p.y, direction = SOUTH}
    steps[2] = {action = "place", item = CHEST, x = c.x, y = c.y}
    steps[3] = {action = "insert", item = "coal", count = fuel.drill, x = p.x, y = p.y}
  end
  return {kind = "steps", args = {steps = steps}, describe = "building a " .. goal.label, goal = goal, spot = p}
end

-- Coal drills that don't come round in a loop (a ring or loop built wrong or cut short) are picked up, so
-- the goal builds them again properly. A drill that feeds nothing else (its furnace or chest is gone, or
-- wasn't placed) gets one, or is picked up after two failed tries.
local function repair(rec, w)
  local s, e = state(rec), rec.entity
  -- Once the coal belt runs, the burner coal drills come out (less pollution, more room): coal for the
  -- furnaces comes off the belt.
  if w.count.coal_belt and #w.loop_drills > 0 and (s.fails["pick:burners"] or 0) < MAX_FAILS then
    local steps = {}
    for i = 1, math.min(#w.loop_drills, 8) do
      local x, y = xy(w.loop_drills[i])
      steps[#steps + 1] = {action = "pick_up", x = x, y = y}
    end
    return {kind = "steps", args = {steps = steps}, describe = "picking up the burner coal drills: coal comes off the coal belt now", fix = "pick:burners"}
  end
  -- A ring that couldn't grow from the first loop's pair replaces it: four coal drills, not six.
  local pair = w.loop_pairs[1]
  if pair and (w.count["ring:" .. pair.ore] or 0) > 0 then
    local a, b = pair.west.position, pair.east.position
    return {kind = "steps", describe = "picking up the first coal loop, now that the ring of four is up", args = {steps = {
      {action = "pick_up", x = a.x, y = a.y}, {action = "pick_up", x = b.x, y = b.y}}}}
  end
  -- A pickup that keeps failing (a full inventory, a drill out of reach) is given up on after a few
  -- tries, so it can't hold up everything else.
  local function can_pick(drill) return (s.fails["pick:" .. drill.unit_number] or 0) < MAX_FAILS end
  local stray
  for _, drill in ipairs(w.broken) do
    if can_pick(drill) then stray = drill; break end
  end
  if not stray then
    for _, u in ipairs(w.unfed) do
      if u.ore == "coal" and can_pick(u.drill) then stray = u.drill; break end
    end
  end
  if stray then
    local x, y = xy(stray)
    return {kind = "pickup", args = {x = x, y = y}, describe = "picking up a coal drill that isn't in a loop, to rebuild it",
      fix = "pick:" .. stray.unit_number}
  end
  for _, u in ipairs(w.unfed) do
    local drill = u.drill
    local fix = "fix:" .. drill.unit_number
    local x, y = xy(drill)
    if (s.fails[fix] or 0) >= 2 then
      if can_pick(drill) then
        return {kind = "pickup", args = {x = x, y = y}, describe = "picking up a drill that feeds nothing", fix = "pick:" .. drill.unit_number}
      end
    else
      local item, spot
      if u.ore == "stone" then
        item = CHEST
        local p = drill.drop_position
        spot = {x = math.floor(p.x) + 0.5, y = math.floor(p.y) + 0.5}
      else
        item, spot = FURNACE, jobs.feed_spot(drill, prototypes.entity[FURNACE])
      end
      if not spot then
        s.fails[fix] = 2
      elseif e.get_item_count(item) > 0 or (e.crafting_queue_size == 0 and e.get_craftable_count(item) > 0) then
        -- A steps job waits for the crafting.
        if e.get_item_count(item) == 0 then craft(rec, item, 1) end
        return {kind = "steps", args = {steps = {{action = "place", item = item, x = spot.x, y = spot.y}}},
          describe = "fixing a drill that feeds nothing", fix = fix}
      end
      -- Can't make the missing piece yet: the goals below gather for it, so leave it for now.
    end
  end
end

---------------------------------------------------------------------------
-- Steam power, the lab and research

local function unlocked(force, items)
  for _, name in ipairs(items) do
    local recipe = force.recipes[name]
    if not (recipe and recipe.enabled) then return false, name end
  end
  return true
end

-- What unlocks an item's recipe, in words ("smelt 50 iron-plate"), for the status.
local function unlock_hint(force, item)
  for _, tech in pairs(force.technologies) do
    if not tech.researched then
      for _, effect in ipairs(tech.prototype.effects or {}) do
        if effect.type == "unlock-recipe" and effect.recipe == item then
          local t = tech.prototype.research_trigger
          local what = t and t.item and (t.item.name or t.item)
          return tech.name .. (what and (", which unlocks by making " .. (t.count or 1) .. " " .. tostring(what)) or "")
        end
      end
    end
  end
  return "research"
end

local function present(surface, name, p)
  return surface.find_entities_filtered{name = name, position = p, radius = 0.6}[1]
end

-- Place steps for `places` ({item, {position, direction, recipe}}), leaving out what's already there (a
-- build cut short carries on), once the items (and `extra`) are gathered and crafted. Returns the steps,
-- or nil and the action or why it waits while gathering.
local function place_all(rec, w, places, extra, label)
  local e = rec.entity
  local counts, order, steps = {}, {}, {}
  for _, pl in ipairs(places) do
    local item, at = pl[1], pl[2]
    if not present(e.surface, prototypes.item[item].place_result.name, at.position) then
      if not counts[item] then counts[item] = 0; order[#order + 1] = item end
      counts[item] = counts[item] + 1
      steps[#steps + 1] = {action = "place", item = item, x = at.position.x, y = at.position.y, direction = at.direction, recipe = at.recipe,
        belt_type = at.belt_type}
    end
  end
  local list = {}
  for _, item in ipairs(order) do list[#list + 1] = {item, counts[item]} end
  for _, x in ipairs(extra or {}) do list[#list + 1] = x end
  local action, waiting, busy = get_items(rec, w, list, label)
  if busy then return action, waiting end
  return nil, nil, steps
end

-- An offshore pump at the water nearest home, piped inland to a boiler and steam engine where there's room
-- to add more later (right by the water when there's no such room), the boiler fueled.
local function steam(rec, w)
  local s, e = state(rec), rec.entity
  local items = {"offshore-pump", "boiler", "steam-engine"}
  local ok, missing = unlocked(e.force, items)
  if not ok then return nil, "steam power: waiting for " .. unlock_hint(e.force, missing) end
  local water = power.nearest_water(e.surface, s.home, 512)
  if not water then return nil, "there's no water within 512 tiles", true end
  -- Plan once: the layout is kept (also while it's half built), so gathering for its pipes doesn't change it.
  local spot = s.plant
  if not (spot and (present(e.surface, "boiler", spot.boiler.position)
      or can_place(e.surface, e.force, "boiler", spot.boiler.position, spot.boiler.direction))) then
    spot = power.plant(e.surface, e.force, water, s.home, (unlocked(e.force, {"pipe"})))
    s.plant = spot
  end
  if not (spot and spot.boiler) then return nil, "there's no room by the water near " .. serpent.line(util.pos(water)), true end
  local places = {{items[1], spot.offshore_pump}}
  for _, p in ipairs(spot.pipes) do places[#places + 1] = {"pipe", {position = p}} end
  places[#places + 1] = {items[2], spot.boiler}
  places[#places + 1] = {items[3], spot.steam_engine}
  local action, waiting, steps = place_all(rec, w, places, {{"coal", 20}}, STEAM.label)
  if not steps then return action, waiting end
  steps[#steps + 1] = {action = "insert", item = "coal", count = 20, x = spot.boiler.position.x, y = spot.boiler.position.y}
  return {kind = "steps", describe = "building a " .. STEAM.label, goal = STEAM, args = {steps = steps}}
end

local function overlaps(a, b)
  return a.left_top.x < b.right_bottom.x and b.left_top.x < a.right_bottom.x and a.left_top.y < b.right_bottom.y
    and b.left_top.y < a.right_bottom.y
end
local function box_at(p, half) return {left_top = {x = p.x - half, y = p.y - half}, right_bottom = {x = p.x + half, y = p.y + half}} end

-- A vector turned clockwise `dir` quarter turns (directions 0-3 from north; y grows southward).
local function rotate(v, dir)
  local x, y = v.x or v[1], v.y or v[2]
  for _ = 1, dir do x, y = -y, x end
  return x, y
end

local function wire_reach()
  local p = prototypes.entity[POLE]
  local ok, v = pcall(function() return p.get_max_wire_distance() end)
  if ok and v then return v end
  return p.max_wire_distance or 7.5
end

local SIDES = {[0] = {0, -1}, {1, 0}, {0, 1}, {-1, 0}}
local function grow(box, by)
  return {left_top = {x = box.left_top.x - by, y = box.left_top.y - by},
    right_bottom = {x = box.right_bottom.x + by, y = box.right_bottom.y + by}}
end

-- The area the power plant grows into (from its plan; else around the steam engine), which nothing else
-- is built in: poles are cheap, so the lab and its assembler go outside it, on a line of poles.
local function plant_room(s, engine)
  if s.plant and s.plant.room and engine.valid and util.distance(s.plant.steam_engine.position, engine.position) < 1 then
    return s.plant.room
  end
  return grow(engine.bounding_box, 8)
end

-- The plant's room and the strip it grows into (power.growth_area): what the lab and science stay out of.
local function keep_clear(s, engine)
  local room = plant_room(s, engine)
  if s.plant and room == s.plant.room then return power.growth_area(s.plant) end
  return room
end

-- The box around a list of places ({item, {position}}), assemblers and labs 3x3.
local function places_box(places)
  local box
  for _, pl in ipairs(places) do
    local half = (pl[1] == ASSEMBLER or pl[1] == LAB) and 1.5 or 0.5
    local p = pl[2].position
    if not box then
      box = {left_top = {x = p.x - half, y = p.y - half}, right_bottom = {x = p.x + half, y = p.y + half}}
    else
      box.left_top.x, box.left_top.y = math.min(box.left_top.x, p.x - half), math.min(box.left_top.y, p.y - half)
      box.right_bottom.x, box.right_bottom.y = math.max(box.right_bottom.x, p.x + half), math.max(box.right_bottom.y, p.y + half)
    end
  end
  return box
end

-- Areas planned but maybe not built yet, kept clear of other building: the science units, the smelting
-- area, and the main bus with its sub-factories (unless `without_bus`: they're what's built there). Until
-- the ore lines are built, also each of their parts outside the smelting area (field belts, drills, poles
-- and the belts to the trunk), or a goal's column can go up across a planned belt.
local function planned_areas(s, without_bus)
  local out = {}
  if s.science_spot and s.science_spot.places then out[#out + 1] = places_box(s.science_spot.places) end
  if s.ore_plan and s.ore_plan.box then out[#out + 1] = s.ore_plan.box end
  local plan = s.ore_plan
  for _, pl in ipairs(plan and not plan.done and plan.box and plan.places or {}) do
    local p, sb = pl[2].position, plan.box
    if not (p.x > sb.left_top.x and p.x < sb.right_bottom.x and p.y > sb.left_top.y and p.y < sb.right_bottom.y) then
      local half = (prototypes.entity[prototypes.item[pl[1]].place_result.name].tile_width or 1) / 2
      out[#out + 1] = {left_top = {x = p.x - half, y = p.y - half}, right_bottom = {x = p.x + half, y = p.y + half}}
    end
  end
  local g = not without_bus and bus.geometry(s.ore_plan, true)
  if g then out[#out + 1] = bus.area(g) end
  return out
end

-- A straight line of poles from the steam engine, along one of the map's axes, and a lab by the last pole,
-- beside the line and clear of the plant's room and the strip it grows into (`room` is both), with space
-- beside it for the science assemblers. Out to the sides of the way the plant grows first (toward home
-- first), then along it, and toward the water last.
local MAX_LAB_POLES = 12
local function lab_spot(e, engine, room, home, growth)
  local reach, wire = prototypes.entity[POLE].get_supply_area_distance(), wire_reach()
  local lab_half = prototypes.entity[LAB].collision_box.right_bottom.x
  local engine_box, keep = engine.bounding_box, grow(room, 1)
  local c = engine.position
  local hx, hy = home.x - c.x, home.y - c.y
  local function rank(v)
    if growth and v[1] == growth[1] and v[2] == growth[2] then return 1 end
    if growth and v[1] == -growth[1] and v[2] == -growth[2] then return 2 end
    return 0
  end
  local ways = {}
  for side = 0, 3 do ways[#ways + 1] = SIDES[side] end
  table.sort(ways, function(a, b)
    if rank(a) ~= rank(b) then return rank(a) < rank(b) end
    return a[1] * hx + a[2] * hy > b[1] * hx + b[2] * hy
  end)
  local function free(p, poles)
    local box = box_at(p, 0.5)
    for _, q in ipairs(poles) do
      if overlaps(box, box_at(q, 0.5)) then return false end
    end
    return can_place(e.surface, e.force, POLE, p, NORTH)
  end
  local function lab_by(pole, poles)
    local area = box_at(pole, reach)
    for lx = -4, 4 do
      for ly = -4, 4 do
        local lab = {x = pole.x + lx, y = pole.y + ly}
        local box = box_at(lab, lab_half)
        local clear = overlaps(box, area) and not overlaps(box, keep) and not overlaps(box, engine_box)
        for _, q in ipairs(poles) do
          if overlaps(box, box_at(q, 0.5)) then clear = false end
        end
        if clear and can_place(e.surface, e.force, LAB, lab, NORTH) then return lab end
      end
    end
  end
  for _, way in ipairs(ways) do
    -- The first pole powers the engine, as far along the way as it can be.
    local first, best
    local cx, cy = math.floor(c.x), math.floor(c.y)
    for _, o in ipairs(offsets()) do
      if math.abs(o[1]) <= 6 and math.abs(o[2]) <= 6 then
        local p = {x = cx + o[1] + 0.5, y = cy + o[2] + 0.5}
        local along = (p.x - c.x) * way[1] + (p.y - c.y) * way[2]
        if (not best or along > best) and overlaps(box_at(p, reach), engine_box) and free(p, {}) then first, best = p, along end
      end
    end
    local poles = {first}
    while first and #poles <= MAX_LAB_POLES do
      local last = poles[#poles]
      local lab = lab_by(last, poles)
      if lab then return poles, lab end
      -- The next pole a wire's length on, or as near that as there's room for, keeping in line.
      local tx, ty = last.x + (wire - 0.5) * way[1], last.y + (wire - 0.5) * way[2]
      local next_pole, next_d
      for dx = -2, 2 do
        for dy = -2, 2 do
          local p = {x = math.floor(tx) + dx + 0.5, y = math.floor(ty) + dy + 0.5}
          local off = math.abs((p.x - poles[1].x) * way[2] - (p.y - poles[1].y) * way[1])
          local d = util.distance(p, {x = tx, y = ty}) + 10 * off
          if util.distance(p, last) <= wire and util.distance(p, last) > 2 and (not next_d or d < next_d) and free(p, poles) then
            next_pole, next_d = p, d
          end
        end
      end
      if not next_pole then break end
      poles[#poles + 1] = next_pole
    end
  end
end

local function powered_lab(rec, w)
  local s, e = state(rec), rec.entity
  local ok, missing = unlocked(e.force, {LAB, POLE})
  if not ok then return nil, "lab: waiting for " .. unlock_hint(e.force, missing) end
  -- Planned once (kept while half built), like the power plant.
  local spot = s.lab_spot
  if not (spot and (present(e.surface, LAB, spot.lab) or can_place(e.surface, e.force, LAB, spot.lab, NORTH))) then
    local poles, lab = lab_spot(e, w.engine, keep_clear(s, w.engine), s.home, power.growth_dir(s.plant))
    if not poles then return nil, "there's no room for a lab outside the power plant's area", true end
    spot = {poles = poles, lab = lab}
    s.lab_spot = spot
  end
  local places = {}
  for _, p in ipairs(spot.poles) do places[#places + 1] = {POLE, {position = p}} end
  places[#places + 1] = {LAB, {position = spot.lab}}
  local action, waiting, steps = place_all(rec, w, places, nil, POWERED_LAB.label)
  if not steps then return action, waiting end
  if #steps == 0 then
    s.lab_spot = nil
    return nil, "the lab and its poles are placed but the lab has no power", true
  end
  return {kind = "steps", describe = "building a " .. POWERED_LAB.label, goal = POWERED_LAB, args = {steps = steps}}
end

-- The direction an inserter faces to drop toward `u` (a unit vector).
local function inserter_toward(u)
  local drop = prototypes.entity[INSERTER].inserter_drop_position
  for d = 0, 3 do
    local dx, dy = rotate(drop, d)
    if dx * u[1] + dy * u[2] > 0.5 then return d end
  end
end

-- Red science made from plates (the owner's layout), on one side of the lab outside the power plant's
-- room. A unit is, in a line out from a lab: an inserter into it, a science assembler 4 tiles from its
-- center, an inserter into that from a chest of copper plates. Units stand side by side 8 tiles apart (a
-- lab each), with a gear assembler in each other gap between them, its own inserter from a chest of iron
-- plates, and inserters passing gears to the science assemblers either side; the first unit's gear
-- assembler is beside it. Poles in the gaps, either side of the inserters there, power it all; the first is
-- within wire reach of a pole already there, or of one more pole placed between. Places past the first
-- unit are `extra` (built later, by more_science). Science already by the lab (an older save's) keeps its
-- side; what's already in place counts as fitting, so the rest is added around it.
local SCIENCE_UNITS = 3
local function science_spot(e, lab, poles, room, built, units)
  local wire = wire_reach()
  local L = lab.position
  local sides = {}
  if built and util.distance(built.position, L) < 4.5 then
    local dx, dy = built.position.x - L.x, built.position.y - L.y
    sides[1] = math.abs(dx) >= math.abs(dy) and {dx > 0 and 1 or -1, 0} or {0, dy > 0 and 1 or -1}
  else
    for side = 0, 3 do sides[#sides + 1] = SIDES[side] end
  end
  local function at(p, v, n) return {x = p.x + n * v[1], y = p.y + n * v[2]} end
  local function wired(p)
    for _, pole in ipairs(poles) do
      if pole.valid and util.distance(p, pole.position) <= wire then return true end
    end
  end
  local blocked
  for _, v in ipairs(sides) do
    local back = {-v[1], -v[2]}
    local asm = at(L, v, 4)
    -- The side a gear assembler already stands on first.
    local perps = {{v[2], -v[1]}, {-v[2], v[1]}}
    if present(e.surface, ASSEMBLER, at(asm, perps[2], 4)) then perps = {perps[2], perps[1]} end
    for _, p in ipairs(perps) do
      local places = {}
      local function put(item, where, extra) places[#places + 1] = {item, where, extra = extra or nil} end
      local back_p = {-p[1], -p[2]}
      for g = 2, 8 * (units - 1) + 2, 4 do
        if g == 2 or g < 8 * (units - 1) then
          put(POLE, {position = at(at(asm, p, g), back, 1)}, g > 2)
          put(POLE, {position = at(at(asm, p, g), v, 1)}, g > 2)
        end
      end
      for k = 0, units - 1 do
        local a, l = at(asm, p, 8 * k), at(L, p, 8 * k)
        if k > 0 then put(LAB, {position = l}, true) end
        put(ASSEMBLER, {position = a, recipe = PACK}, k > 0)
        put(INSERTER, {position = at(l, v, 2), direction = inserter_toward(back)}, k > 0)
        put(INSERTER, {position = at(a, v, 2), direction = inserter_toward(back)}, k > 0)
        put(CHEST, {position = at(a, v, 3)}, k > 0)
      end
      -- Gear assembler j stands between science assemblers j and j + 1, passing gears to both.
      for j = 0, math.max(0, units - 2) do
        local gear = at(asm, p, 8 * j + 4)
        put(ASSEMBLER, {position = gear, recipe = GEAR}, j > 0)
        put(INSERTER, {position = at(gear, v, 2), direction = inserter_toward(back)}, j > 0)
        put(CHEST, {position = at(gear, v, 3)}, j > 0)
        put(INSERTER, {position = at(gear, back_p, 2), direction = inserter_toward(back_p)}, j > 0)
        if j + 1 < units then put(INSERTER, {position = at(gear, p, 2), direction = inserter_toward(p)}, true) end
      end
      local fits = true
      for _, pl in ipairs(places) do
        local name, where = pl[1], pl[2]
        local half = (name == ASSEMBLER or name == LAB) and 1.5 or 0.5
        local in_room = room and overlaps(box_at(where.position, half), room)
        if in_room or not (present(e.surface, name, where.position)
            or can_place(e.surface, e.force, name, where.position, where.direction or NORTH)) then
          fits = false
          blocked = blocked or (name .. " at " .. serpent.line(util.pos(where.position)) .. (in_room and " would be in the power plant's room" or " is blocked"))
          break
        end
      end
      if fits then
        local first = places[1][2].position
        if present(e.surface, POLE, first) or wired(first) then return {places = places, units = units} end
        -- One more pole to reach the network.
        for _, o in ipairs(offsets()) do
          if math.abs(o[1]) <= 6 and math.abs(o[2]) <= 6 then
            local q = {x = math.floor(first.x) + o[1] + 0.5, y = math.floor(first.y) + o[2] + 0.5}
            local free = util.distance(q, first) <= wire and wired(q) and can_place(e.surface, e.force, POLE, q, NORTH)
            for _, pl in ipairs(free and places or {}) do
              local half = (pl[1] == ASSEMBLER or pl[1] == LAB) and 1.5 or 0.5
              if overlaps(box_at(q, 0.5), box_at(pl[2].position, half)) then free = false end
            end
            if free then
              table.insert(places, 1, {POLE, {position = q}})
              return {places = places, units = units}
            end
          end
        end
        blocked = blocked or "no pole reaches it from the network"
      end
    end
  end
  return nil, blocked
end

-- The science layout by the first lab: planned once for SCIENCE_UNITS units, else just one.
local function science_plan(rec, w)
  local s, e = state(rec), rec.entity
  local lab = w.labs[1]
  local spot = s.science_spot
  if spot and spot.lab == lab.unit_number and spot.places and spot.units then return spot end
  local room = w.engine and keep_clear(s, w.engine)
  local why
  spot, why = science_spot(e, lab, w.poles, room, w.assembler, SCIENCE_UNITS)
  if not spot then
    note(rec, "red science: no room by the lab for " .. SCIENCE_UNITS .. " units (" .. tostring(why) .. "), planning one")
    spot = science_spot(e, lab, w.poles, room, w.assembler, 1)
  end
  if not spot then return nil end
  spot.lab = lab.unit_number
  s.science_spot = spot
  return spot
end

-- Red science on power: the first unit's science and gear assemblers, their inserters and chests
-- (science_spot). Goal is SCIENCE (the science assembler feeding the lab) or SCIENCE_GEARS (the gear
-- assembler feeding it, for a save from before that was part of it); one build does both.
local function science(rec, w, goal)
  local s, e = state(rec), rec.entity
  goal = goal or SCIENCE
  local ok, missing = unlocked(e.force, {ASSEMBLER, INSERTER, POLE, CHEST})
  if not ok then return nil, "science assembler: waiting for " .. unlock_hint(e.force, missing) end
  local spot = science_plan(rec, w)
  if not spot then
    return nil, "there's no room by the lab for the science and gear assemblers with their inserters, chests and poles", true
  end
  local places = {}
  for _, pl in ipairs(spot.places) do
    if not pl.extra then places[#places + 1] = pl end
  end
  local action, waiting, steps = place_all(rec, w, places, nil, goal.label)
  if not steps then return action, waiting end
  if #steps == 0 then
    s.science_spot = nil
    return nil, "the science assemblers are placed but don't feed the lab", true
  end
  return {kind = "steps", describe = "building a " .. goal.label, goal = goal, args = {steps = steps}}
end

-- Once the starting base is up: the rest of the science units (three times the red science, with a lab
-- each to use it).
local function more_science(rec, w)
  local s, e = state(rec), rec.entity
  -- (Not once the ore lines are planned: the main bus's red science, fed by belt, takes over.)
  if s.skipped.more_science or s.ore_plan or (s.fails.more_science or 0) >= MAX_FAILS or not w.count.science_gears or #w.labs == 0 then return nil end
  local spot = science_plan(rec, w)
  -- Planned again (twice at most) when it was one unit (three may fit by now, around what's built) or
  -- something has since taken one of its spots.
  local stale = spot and spot.units <= 1
  for _, pl in ipairs(spot and not stale and spot.places or {}) do
    local name, at = prototypes.item[pl[1]].place_result.name, pl[2]
    if not (present(e.surface, name, at.position) or can_place(e.surface, e.force, name, at.position, at.direction or NORTH)) then
      stale = true
      break
    end
  end
  if stale and (s.science_replans or 0) < 2 then
    s.science_replans = (s.science_replans or 0) + 1
    s.science_spot = nil
    spot = science_plan(rec, w)
  end
  if not spot or spot.units <= 1 or (w.count.science_units or 0) >= spot.units then return nil end
  local action, waiting, steps = place_all(rec, w, spot.places, nil, "more red science")
  if not steps then return action, waiting end
  if #steps == 0 then
    s.skipped.more_science = true
    return nil
  end
  local partial = #steps > 20
  while #steps > 20 do table.remove(steps) end
  return {kind = "steps", args = {steps = steps}, describe = "adding red science assemblers and labs (three times the science)",
    fix = "more_science", partial = partial}
end

-- Keeps red science supplied: copper plates into each science assembler's chest and iron plates into each
-- gear assembler's (straight into the assemblers when they have no chest, and gears by hand when there's
-- no gear assembler).
local CHEST_LOW, CHEST_FILL = 20, 100
local function feed_science(rec, w)
  local e = rec.entity
  local function fill(entity, inventory, item, low, full)
    return {entity = entity, inv = entity.get_inventory(inventory), item = item, low = low, full = full}
  end
  local asm_in = defines.inventory.crafter_input
  local fills, seen = {}, {}
  local units = #w.science > 0 and w.science or {{asm = w.assembler}}
  for _, unit in ipairs(units) do
    if unit.chest then fills[#fills + 1] = fill(unit.chest, defines.inventory.chest, "copper-plate", CHEST_LOW, CHEST_FILL)
    else fills[#fills + 1] = fill(unit.asm, asm_in, "copper-plate", ASSEMBLER_LOW, ASSEMBLER_FILL) end
    if unit.gear then
      if not seen[unit.gear.unit_number] then
        seen[unit.gear.unit_number] = true
        if unit.gear_chest then fills[#fills + 1] = fill(unit.gear_chest, defines.inventory.chest, "iron-plate", CHEST_LOW, CHEST_FILL)
        else fills[#fills + 1] = fill(unit.gear, asm_in, "iron-plate", ASSEMBLER_LOW, ASSEMBLER_FILL) end
      end
    else
      fills[#fills + 1] = fill(unit.asm, asm_in, GEAR, ASSEMBLER_LOW, ASSEMBLER_FILL)
    end
  end
  local todo, list, used = {}, {}, {}
  for _, f in ipairs(fills) do
    local n = f.inv.get_item_count(f.item)
    if n < f.low then
      local want, have = f.full - n, e.get_item_count(f.item) - (used[f.item] or 0)
      if have >= math.min(want, 5) then
        local give = math.min(have, want)
        todo[#todo + 1] = insert(f.entity, f.item, give)
        used[f.item] = (used[f.item] or 0) + give
      else
        list[#list + 1] = {f.item, want}
      end
    end
  end
  if #todo > 0 then return route(rec, todo, "filling the science assembler") end
  if #list > 0 then
    local action, waiting, busy = get_items(rec, w, list, "science assembler")
    if busy then return action, waiting end
  end
end

---------------------------------------------------------------------------
-- Coal by belt: two electric drills on the coal, a belt from them to the boiler and an inserter into it,
-- with poles along the belt. The belt ends beside the boiler on the side away from the engine, a tile out
-- (belt, inserter, boiler in a line), and in the fuel lane it runs straight along the line more boilers go
-- in, so each later boiler gets an inserter off it.

local function axis(v)
  if math.abs(v.x) >= math.abs(v.y) then return {v.x > 0 and 1 or -1, 0} end
  return {0, v.y > 0 and 1 or -1}
end

-- Belts it may lay, and how many coal tiles a drill's mining area needs.
-- (Belts are cheap: coming in along the plant's growth strip can take a long way round.)
local MAX_BELTS, MIN_COAL = 300, 12
-- What a turn costs a belt route, in belts: worth a few more belts to run straight.
local TURN = 4

local function coal_line_plan(e, w, room, lane, avoid)
  local surface, force = e.surface, e.force
  local engine = w.engine
  local boiler
  for _, b in ipairs(surface.find_entities_filtered{type = "boiler", position = engine.position, radius = 6, force = force}) do
    boiler = boiler or b
  end
  if not boiler then return nil, "there's no boiler by the steam engine" end
  local side = axis({x = engine.position.x - boiler.position.x, y = engine.position.y - boiler.position.y})
  local along = {side[2], -side[1]}
  local drop = prototypes.entity[INSERTER].inserter_drop_position
  local ins_dir
  for d = 0, 3 do
    local dx, dy = rotate(drop, d)
    if dx * side[1] + dy * side[2] > 0.5 then ins_dir = d end
  end
  local bases = util.enemy_bases(surface, boiler.position, 200 + util.NEST_CLEARANCE)
  local coal = jobs.nearest(surface, {"coal"}, boiler.position, nil, 200, bases)
  if not coal then return nil, "there's no coal within 200 tiles that's safe from enemy nests" end

  -- A grid of the tiles a belt can go on, around the boiler and the coal.
  local bp, cp = boiler.position, coal.position
  local x0, y0 = math.floor(math.min(bp.x, cp.x)) - 30, math.floor(math.min(bp.y, cp.y)) - 30
  local x1, y1 = math.floor(math.max(bp.x, cp.x)) + 30, math.floor(math.max(bp.y, cp.y)) + 30
  -- (With the whole room and its growth strip in it, and room to go round them.)
  if room then
    x0, y0 = math.min(x0, math.floor(room.left_top.x) - 8), math.min(y0, math.floor(room.left_top.y) - 8)
    x1, y1 = math.max(x1, math.ceil(room.right_bottom.x) + 8), math.max(y1, math.ceil(room.right_bottom.y) + 8)
  end
  local H = y1 - y0 + 1
  local function idx(x, y) return (x - x0) * H + (y - y0) end
  local function inside(x, y) return x >= x0 and x <= x1 and y >= y0 and y <= y1 end
  local blocked = {}
  local function block(box)
    for x = math.floor(box.left_top.x + 0.01), math.ceil(box.right_bottom.x - 0.01) - 1 do
      for y = math.floor(box.left_top.y + 0.01), math.ceil(box.right_bottom.y - 0.01) - 1 do
        if inside(x, y) then blocked[idx(x, y)] = true end
      end
    end
  end
  local area = {{x0, y0}, {x1 + 1, y1 + 1}}
  for _, t in ipairs(surface.find_tiles_filtered{area = area, collision_mask = "water_tile"}) do
    blocked[idx(t.position.x, t.position.y)] = true
  end
  for _, thing in ipairs(surface.find_entities_filtered{area = area, type = PASSABLE, invert = true}) do block(thing.bounding_box) end
  for _, box in ipairs(avoid or {}) do block(box) end
  -- The belt stays out of the plant's room but for its fuel lane (poles may go in it: that's power).
  local function within(box, x, y)
    return box and x + 1 > box.left_top.x and x < box.right_bottom.x and y + 1 > box.left_top.y and y < box.right_bottom.y
  end
  local function in_room(x, y) return within(room, x, y) and not within(lane, x, y) end
  -- In the lane, the belt only runs straight along it (`straight`, worked out below), never in the column
  -- next to the boilers, which is for their inserters.
  local straight, straight_way = {}, nil
  local function open(x, y)
    return inside(x, y) and not blocked[idx(x, y)] and not in_room(x, y) and not (#straight > 0 and within(lane, x, y))
  end

  -- The inserter beside the boiler (any of the three tiles along it), and the belt's end beside that.
  if not ins_dir then return nil, "can't work out which way an inserter drops" end
  local ins, last
  local tried = {}
  for _, o in ipairs({0, 1, -1}) do
    local ix = math.floor(bp.x - 1.5 * side[1] + o * along[1]) + 0.5
    local iy = math.floor(bp.y - 1.5 * side[2] + o * along[2]) + 0.5
    local ex, ey = math.floor(ix - side[1]), math.floor(iy - side[2])
    local ins_box = box_at({x = ix, y = iy}, 0.5)
    if ins_dir and not overlaps(ins_box, boiler.bounding_box) and inside(math.floor(ix), math.floor(iy))
      and not blocked[idx(math.floor(ix), math.floor(iy))] and not in_room(math.floor(ix), math.floor(iy)) and open(ex, ey) then
      ins, last = {x = ix, y = iy}, {x = ex, y = ey}
      break
    end
    local here = {}
    for _, thing in ipairs(surface.find_entities_filtered{area = {{math.min(ix - 0.5, ex), math.min(iy - 0.5, ey)},
        {math.max(ix + 0.5, ex + 1), math.max(iy + 0.5, ey + 1)}}}) do
      here[#here + 1] = thing.name
    end
    tried[#tried + 1] = serpent.line({ix, iy}) .. (#here > 0 and (" has " .. table.concat(here, "/")) or "")
  end
  if not ins then
    return nil, "there's no room for an inserter beside the boiler at " .. serpent.line(util.pos(bp)) .. " (tried " ..
      table.concat(tried, ", ") .. ")"
  end
  blocked[idx(math.floor(ins.x), math.floor(ins.y))] = true
  -- The line's poles stay out of the plant's room but for its lane too: boilers and engines go there.
  if room then
    for x = math.floor(room.left_top.x), math.ceil(room.right_bottom.x) - 1 do
      for y = math.floor(room.left_top.y), math.ceil(room.right_bottom.y) - 1 do
        if inside(x, y) and in_room(x, y) then blocked[idx(x, y)] = true end
      end
    end
  end

  -- Power plants have to be right the first time (fixing one means shutting it down). In the fuel lane the
  -- belt's last stretch runs straight along the boilers to its end beside the inserter (belt, inserter,
  -- boiler in a line), coming in from the lane's far end, the way the plant grows: the boilers added later
  -- each get an inserter off the same belt, and the belt never crosses the next boiler's spot.
  if lane then
    local function reach(v) return math.max((lane.left_top.x - bp.x) * v[1] + (lane.left_top.y - bp.y) * v[2],
      (lane.right_bottom.x - bp.x) * v[1] + (lane.right_bottom.y - bp.y) * v[2]) end
    local back = {-along[1], -along[2]}
    local grow = reach(along) >= reach(back) and along or back
    local x, y = last.x, last.y
    local run = {}
    while within(lane, x, y) and inside(x, y) and not blocked[idx(x, y)] do
      run[#run + 1] = {x = x, y = y}
      x, y = x + grow[1], y + grow[2]
    end
    straight, straight_way = run, grow
    -- The inserters' column beside it stays clear of the line's poles too.
    for _, t in ipairs(run) do
      local cx, cy = t.x + side[1], t.y + side[2]
      if inside(cx, cy) then blocked[idx(cx, cy)] = true end
    end
  end

  -- What a belt costs from each tile to its end, over open tiles, by the way the belt flows on that tile
  -- (state idx * 4 + direction): a tile each, plus TURN for each turn, so belts run straight, in an L
  -- rather than a staircase or a jog. From the lane's far end, along it, when there is a lane.
  local cost = {}
  local heap = {}
  local function push(c, st)
    heap[#heap + 1] = {c, st}
    local i = #heap
    while i > 1 do
      local p = math.floor(i / 2)
      if heap[p][1] <= heap[i][1] then break end
      heap[p], heap[i] = heap[i], heap[p]
      i = p
    end
  end
  local function pop()
    local top, n = heap[1], #heap
    local tail = heap[n]
    heap[n] = nil
    n = n - 1
    if n == 0 then return top end
    heap[1] = tail
    local i = 1
    while true do
      local l, r, m = 2 * i, 2 * i + 1, i
      if l <= n and heap[l][1] < heap[m][1] then m = l end
      if r <= n and heap[r][1] < heap[m][1] then m = r end
      if m == i then break end
      heap[m], heap[i] = heap[i], heap[m]
      i = m
    end
    return top
  end
  local function dir_of(v)
    for k = 0, 3 do
      if SIDES[k][1] == v[1] and SIDES[k][2] == v[2] then return k end
    end
  end
  if #straight > 0 then
    local flow = dir_of({-straight_way[1], -straight_way[2]})
    for k, t in ipairs(straight) do cost[idx(t.x, t.y) * 4 + flow] = k - 1 end
    local tail = straight[#straight]
    push(#straight - 1, idx(tail.x, tail.y) * 4 + flow)
  else
    for h = 0, 3 do
      cost[idx(last.x, last.y) * 4 + h] = 0
      push(0, idx(last.x, last.y) * 4 + h)
    end
  end
  local MAX_COST = MAX_BELTS + 8 * TURN
  while #heap > 0 do
    local top = pop()
    local c, st = top[1], top[2]
    if c == cost[st] and c < MAX_COST then
      local i, h2 = math.floor(st / 4), st % 4
      local x, y = math.floor(i / H) + x0, i % H + y0
      for h = 0, 3 do
        if h ~= (h2 + 2) % 4 then
          local px, py = x - SIDES[h][1], y - SIDES[h][2]
          if open(px, py) then
            local nc = c + 1 + (h ~= h2 and TURN or 0)
            local ps = idx(px, py) * 4 + h
            if not cost[ps] or nc < cost[ps] then
              cost[ps] = nc
              push(nc, ps)
            end
          end
        end
      end
    end
  end
  -- The cheapest way on from tile (x, y) for a belt coming in heading `heading`: cost and direction.
  local function entry(x, y, heading)
    local best, best_h
    local hd = dir_of(heading)
    for h = 0, 3 do
      local c = h ~= (hd + 2) % 4 and cost[idx(x, y) * 4 + h]
      if c then
        c = c + (h ~= hd and TURN or 0)
        if not best or c < best then best, best_h = c, h end
      end
    end
    return best, best_h
  end

  -- Two drills side by side on the coal, both facing the belt's start, nearest the boiler by belt.
  local proto = prototypes.entity[EDRILL]
  local v = proto.vector_to_place_result or {0, -2.3}
  local candidates = {}
  for _, res in ipairs(surface.find_entities_filtered{area = area, type = "resource", name = "coal"}) do
    local c = res.position
    for dir = 0, 3 do
      local vx, vy = rotate(v, dir)
      local ox, oy = math.floor(c.x + vx), math.floor(c.y + vy)
      for _, turn in ipairs({1, 3}) do
        local perp = SIDES[(dir + turn) % 4]
        local bx, by = ox + 3 * perp[1], oy + 3 * perp[2]
        local d = inside(bx, by) and entry(bx, by, perp)
        if d then
          local ok = true
          for k = 0, 2 do
            if not open(ox + k * perp[1], oy + k * perp[2]) then ok = false end
          end
          if ok then candidates[#candidates + 1] = {d = d, a = c, dir = dir, perp = perp, out = {x = ox, y = oy}} end
        end
      end
    end
  end
  table.sort(candidates, function(p, q) return p.d < q.d end)
  local function coal_under(p)
    local counts = jobs.drill_resources(surface, proto, p)
    return (counts.coal or 0) >= MIN_COAL and table_size(counts) == 1
  end
  -- A drill's 3x3 on open tiles (trees and rocks there are chopped when placing).
  local function footprint_open(p)
    for x = math.floor(p.x) - 1, math.floor(p.x) + 1 do
      for y = math.floor(p.y) - 1, math.floor(p.y) + 1 do
        if not open(x, y) then return false end
      end
    end
    return true
  end
  local fitting = 0
  for _, cand in ipairs(candidates) do
    local a = cand.a
    local b = {x = a.x + 3 * cand.perp[1], y = a.y + 3 * cand.perp[2]}
    local fits_here = footprint_open(a) and footprint_open(b) and coal_under(a) and coal_under(b)
      and owner_clear(surface, force, a) and owner_clear(surface, force, b)
    if fits_here then fitting = fitting + 1 end
    if fits_here then
      -- The belt: along the drills' fronts, then down the distances to the boiler, keeping straight where it can.
      local avoid = {}
      for _, box in ipairs({box_at(a, 1.5), box_at(b, 1.5)}) do
        for x = math.floor(box.left_top.x), math.ceil(box.right_bottom.x) - 1 do
          for y = math.floor(box.left_top.y), math.ceil(box.right_bottom.y) - 1 do avoid[x .. "," .. y] = true end
        end
      end
      local tiles = {}
      for k = 0, 3 do
        local t = {x = cand.out.x + k * cand.perp[1], y = cand.out.y + k * cand.perp[2]}
        tiles[#tiles + 1] = t
        avoid[t.x .. "," .. t.y] = true
      end
      -- Then the cheapest way on, tile by tile, to the end (cost 0).
      local x, y, ok = tiles[4].x, tiles[4].y, true
      local _, h = entry(x, y, cand.perp)
      local heading = SIDES[h]
      while cost[idx(x, y) * 4 + h] > 0 do
        local c = cost[idx(x, y) * 4 + h]
        local nx, ny = x + SIDES[h][1], y + SIDES[h][2]
        local nh
        for h2 = 0, 3 do
          local want = c - 1 - (h2 ~= h and TURN or 0)
          if inside(nx, ny) and cost[idx(nx, ny) * 4 + h2] == want and (not nh or h2 == h) then nh = h2 end
        end
        if not nh or avoid[nx .. "," .. ny] then ok = false; break end
        x, y, h = nx, ny, nh
        heading = SIDES[h]
        tiles[#tiles + 1] = {x = x, y = y}
        avoid[x .. "," .. y] = true
      end
      if ok then
        local belts = {}
        for k, t in ipairs(tiles) do
          local nxt = tiles[k + 1]
          local step = nxt and {nxt.x - t.x, nxt.y - t.y} or heading
          local dir
          for s = 0, 3 do
            if SIDES[s][1] == step[1] and SIDES[s][2] == step[2] then dir = s end
          end
          belts[k] = {position = {x = t.x + 0.5, y = t.y + 0.5}, direction = dir}
        end
        return {boiler = boiler.unit_number, inserter = ins, inserter_dir = ins_dir, belts = belts,
          drills = {{position = a, direction = cand.dir}, {position = b, direction = cand.dir}},
          taken = avoid, blocked = blocked, area = {x0 = x0, y0 = y0, x1 = x1, y1 = y1}}
      end
    end
  end
  return nil, "there's no belt route from the coal to the boiler (within " .. MAX_BELTS .. " belts; " .. #candidates ..
    " drill spots in reach, " .. fitting .. " with room, coal at " .. serpent.line(util.pos(cp)) .. ")"
end

-- Poles for the coal line: from the nearest pole on the network to the inserter, then along the belt to
-- the drills, at most a wire's length apart.
local function coal_line_poles(e, w, plan)
  local reach, wire = prototypes.entity[POLE].get_supply_area_distance(), wire_reach()
  local a = plan.area
  local H = a.y1 - a.y0 + 1
  local taken = plan.taken
  taken[math.floor(plan.inserter.x) .. "," .. math.floor(plan.inserter.y)] = true
  local function free(p)
    local x, y = math.floor(p.x), math.floor(p.y)
    if taken[x .. "," .. y] then return false end
    if x < a.x0 or x > a.x1 or y < a.y0 or y > a.y1 then return can_place(e.surface, e.force, POLE, p, NORTH) end
    return not plan.blocked[(x - a.x0) * H + (y - a.y0)]
  end
  local function around(last, fn)
    local r = math.floor(wire)
    local lx, ly = math.floor(last.x), math.floor(last.y)
    for dx = -r, r do
      for dy = -r, r do
        local p = {x = lx + dx + 0.5, y = ly + dy + 0.5}
        if util.distance(p, last) <= wire and util.distance(p, last) >= 1 and free(p) then fn(p) end
      end
    end
  end
  local poles = {}
  local function add(p)
    poles[#poles + 1] = p
    taken[math.floor(p.x) .. "," .. math.floor(p.y)] = true
  end
  local function covers(p, box) return overlaps(box_at(p, reach), box) end
  -- To the inserter.
  local ins_box = box_at(plan.inserter, 0.5)
  local last
  for _, pole in ipairs(w.poles) do
    if covers(pole.position, ins_box) then last = pole.position end
  end
  if not last then
    local start, start_d
    for _, pole in ipairs(w.poles) do
      local d = util.distance(pole.position, plan.inserter)
      if pole.valid and (not start_d or d < start_d) then start, start_d = pole.position, d end
    end
    if not start then return nil end
    last = start
    for _ = 1, 10 do
      local best, best_d, done
      around(last, function(p)
        if not done and covers(p, ins_box) then done = p end
        local d = util.distance(p, plan.inserter)
        if not best_d or d < best_d then best, best_d = p, d end
      end)
      if done then add(done); last = done; break end
      if not best or best_d >= util.distance(last, plan.inserter) - 0.5 then return nil end
      add(best)
      last = best
    end
    if not covers(last, ins_box) then return nil end
  end
  -- Along the belt, back to the drills.
  local order = {}
  local n = #plan.belts
  for k, b in ipairs(plan.belts) do order[math.floor(b.position.x) .. "," .. math.floor(b.position.y)] = n - k + 1 end
  local function progress(p)
    local best = 0
    for dx = -1, 1 do
      for dy = -1, 1 do
        local i = order[(math.floor(p.x) + dx) .. "," .. (math.floor(p.y) + dy)]
        if i and i > best then best = i end
      end
    end
    return best
  end
  local d1, d2 = box_at(plan.drills[1].position, 1.5), box_at(plan.drills[2].position, 1.5)
  local at = 0
  -- In line with the last pole where that costs little progress, so the poles run straight beside the belt.
  for _ = 1, 60 do
    local best, best_p, best_s, done
    around(last, function(p)
      if not done and covers(p, d1) and covers(p, d2) then done = p end
      local pr = progress(p)
      local inline = math.abs(p.x - last.x) < 0.1 or math.abs(p.y - last.y) < 0.1
      local score = pr - (inline and 0 or 2)
      if pr > at and (not best_s or score > best_s) then best, best_p, best_s = p, pr, score end
    end)
    if done then add(done); return poles end
    if not best then return nil end
    add(best)
    last, at = best, best_p
  end
end

local function coal_belt(rec, w)
  local s, e = state(rec), rec.entity
  local ok, missing = unlocked(e.force, {EDRILL, BELT, INSERTER, POLE})
  if not ok then return nil, "coal belt: waiting for " .. unlock_hint(e.force, missing) end
  if not w.engine then return nil, "there's no steam engine", true end
  local plan = s.coal_line
  local first = plan and plan.drills[1]
  if not (plan and (present(e.surface, EDRILL, first.position) or can_place(e.surface, e.force, EDRILL, first.position, first.direction))) then
    local why
    -- Without a planned room (an older save, or the plant had to go at the shore) the belt goes wherever.
    -- The plant's room and the strip it grows into, with the fuel lane running on through that strip.
    local room = plant_room(s, w.engine)
    local lane = s.plant and s.plant.room == room and s.plant.fuel_lane or nil
    -- (Water or ore in that strip: just the room.)
    local avoid = planned_areas(s)
    plan, why = coal_line_plan(e, w, lane and power.grown(s.plant, room), lane and power.grown(s.plant, lane), avoid)
    if not plan and lane then
      note(rec, "coal belt: no way in along the plant's growth strip (" .. tostring(why) .. "); planning it with just the room")
      plan, why = coal_line_plan(e, w, room, lane, avoid)
    end
    if not plan then return nil, why, true end
    plan.poles = coal_line_poles(e, w, plan)
    if not plan.poles then return nil, "there's no way to run poles along the coal belt", true end
    plan.taken, plan.blocked = nil, nil
    s.coal_line = plan
  end
  local places = {}
  for _, p in ipairs(plan.poles) do places[#places + 1] = {POLE, {position = p}} end
  places[#places + 1] = {INSERTER, {position = plan.inserter, direction = plan.inserter_dir}}
  for k = #plan.belts, 1, -1 do places[#places + 1] = {BELT, plan.belts[k]} end
  for _, d in ipairs(plan.drills) do places[#places + 1] = {EDRILL, d} end
  local action, waiting, steps = place_all(rec, w, places, nil, COAL_BELT.label)
  if not steps then return action, waiting end
  if #steps == 0 then
    s.coal_line = nil
    return nil, "the coal belt is built but no coal reaches the boiler", true
  end
  -- A steps job holds at most 20; the rest follow in the next one.
  local partial = #steps > 20
  for k = #steps, 21, -1 do steps[k] = nil end
  return {kind = "steps", describe = "building a " .. COAL_BELT.label, goal = COAL_BELT, args = {steps = steps}, partial = partial}
end

-- The first technology of RESEARCH (or a prerequisite of it) still to research.
local function next_research(force)
  local function open(tech)
    for _, pre in pairs(tech.prerequisites) do
      if not pre.researched then return open(pre) end
    end
    return tech
  end
  for _, name in ipairs(RESEARCH) do
    local tech = force.technologies[name]
    if tech and not tech.researched then return open(tech) end
  end
end

-- Researches RESEARCH in the lab, crafting red science and keeping the lab stocked. Nil when all done.
local function research(rec, w)
  local s, e = state(rec), rec.entity
  local force = e.force
  local tech = next_research(force)
  if not tech then return nil end
  if tech.prototype.research_trigger then return nil, "waiting for " .. tech.name .. " to unlock" end
  -- The owner's own research choice stands; packs go into the lab either way.
  if not force.current_research then force.add_research(tech) end
  if s.researching ~= tech.name then
    s.researching = tech.name
    tell(rec, "Researching " .. tech.name .. ".")
  end
  local progress = "researching " .. tech.name .. " (" .. math.floor(force.research_progress * 100) .. "%)"
  -- The science assembler makes the packs once it's up; it only needs feeding.
  if w.count.science then
    local action, waiting = feed_science(rec, w)
    return action, waiting or progress
  end
  local lab = w.labs[1]
  local in_lab = lab.get_inventory(defines.inventory.lab_input).get_item_count(PACK)
  local have = e.get_item_count(PACK)
  if in_lab < LAB_LOW and have > 0 then return route(rec, {insert(lab, PACK, have)}, "filling the lab with science") end
  if in_lab + have < PACK_BATCH then
    local action, waiting, busy = get_items(rec, w, {{PACK, PACK_BATCH}}, "science packs")
    if busy then return action, waiting end
    return nil, "crafting science packs for " .. tech.name
  end
  return nil, progress
end

---------------------------------------------------------------------------

local function next_goal(rec, w, limited)
  local s = state(rec)
  local base = true
  -- Burner coal drills are done with once the coal belt runs (repair picks them up).
  local function met(goal)
    return (w.count[key(goal)] or 0) >= goal.target or (goal.ore == "coal" and w.count.coal_belt ~= nil)
      -- Iron and copper pairs are done with once ore lines are planned, or being planned (they replace them,
      -- on the same fields).
      or (goal.kind == "pair" and (s.ore_plan ~= nil or s.lines_work ~= nil))
  end
  for _, goal in ipairs(BASE) do
    if not met(goal) then
      base = false
      if not s.skipped[id(goal)] then return goal end
    end
  end
  -- "Stop hand mining": once the base is up, coal and stone come from the drills.
  if base and not s.base_done then
    s.base_done = true
    tell(rec, "The base is up: no more hand mining, coal and stone come from the drills now.")
  end
  -- No more drills while pollution is held back from the nests.
  if limited then return nil end
  local best, best_r
  for _, goal in ipairs(GROWTH) do
    local r = met(goal) and 1 or (w.count[key(goal)] or 0) / goal.target
    if r < 1 and not s.skipped[id(goal)] and (not goal.without or s.skipped[goal.without]) and (not best_r or r < best_r) then
      best, best_r = goal, r
    end
  end
  return best
end

-- After the drills: steam power, the lab, then research, with a science assembler once automation is in.
-- Returns the action or why it waits; done is true once all of it is.
local function later_steps(rec, w)
  local s = state(rec)
  local automation = rec.entity.force.technologies[RESEARCH[1]]
  local steps = {{STEAM, steam}, {POWERED_LAB, powered_lab}}
  if automation and automation.researched then
    steps[3] = {SCIENCE, science}
    steps[4] = {SCIENCE_GEARS, science}
  end
  for _, step in ipairs(steps) do
    local goal, run_step = step[1], step[2]
    local optional = goal == SCIENCE or goal == SCIENCE_GEARS
    -- The gear assembler goes with a science assembler.
    local skip = optional and (s.skipped[goal.count] or (goal == SCIENCE_GEARS and not w.count.science))
    if (w.count[goal.count] or 0) == 0 and not skip then
      if s.skipped[goal.count] then return nil, "skipped the " .. goal.label end
      local action, why, stuck = run_step(rec, w, goal)
      if stuck then
        s.skipped[goal.count] = true
        tell(rec, "Skipping the " .. goal.label .. ": " .. why .. ".")
      end
      -- Without the assemblers, research carries on with hand-crafted packs (or gears).
      if not (stuck and optional) then return action, why end
    end
  end
  local action, why = research(rec, w)
  if action or why then return action, why end
  if (w.count.coal_belt or 0) == 0 and not s.skipped.coal_belt then
    local stuck
    action, why, stuck = coal_belt(rec, w)
    if not stuck then return action, why end
    s.skipped.coal_belt = true
    tell(rec, "Skipping the " .. COAL_BELT.label .. ": " .. why .. ".")
  end
  return nil, nil, true
end

-- The build order's steps, and whether each is done, for observe (so the AI knows
-- not to start them over).
local function progress(rec, w)
  local e = rec.entity
  local c = w.count
  local function of(n, target) return (n or 0) .. " of " .. target .. ((n or 0) >= target and " (done)" or "") end
  -- What's really built on each ore, by kind of drill (counted from the map, so it's never a plan).
  local drills = {}
  for _, entity in pairs(rec.built or {}) do
    if entity.valid and entity.type == "mining-drill" then
      local ore = ore_under(entity)
      if ore then
        drills[ore] = drills[ore] or {burner = 0, electric = 0}
        local kind = entity.name == DRILL and "burner" or "electric"
        drills[ore][kind] = drills[ore][kind] + 1
      end
    end
  end
  local built = {}
  for _, ore in ipairs({"iron-ore", "copper-ore", "coal", "stone"}) do
    local d = drills[ore] or {burner = 0, electric = 0}
    built[#built + 1] = ore .. " " .. d.burner .. " burner/" .. d.electric .. " electric"
  end
  local plan = state(rec).ore_plan
  local lines = {
    "drills on each ore now: " .. table.concat(built, ", "),
    "iron drill/furnace pairs: " .. of(c["pair:iron-ore"], 10) .. (plan and " (being replaced by ore lines)" or ""),
    "coal drills in loops: " .. (c["loop:coal"] or 0) .. ((c["ring:coal"] or 0) > 0 and ", with a ring of four (done)" or ", no ring of four yet"),
    "copper drill/furnace pairs: " .. of(c["pair:copper-ore"], 2) .. (plan and " (being replaced by ore lines)" or ""),
    "stone drill into a chest: " .. of(c["chest:stone"], 1),
    "iron gear wheels: " .. of(e.get_item_count(GEAR), GEAR_TARGET),
    "steam power: " .. ((c.steam or 0) > 0 and (c.steam .. " steam engines") or "not yet"),
    "lab on power: " .. ((c.lab or 0) > 0 and (c.lab .. " labs") or "not yet"),
    "red science assemblers feeding labs: " .. (c.science_units or 0),
    "gear assembler feeding them, plates from chests: " .. ((c.science_gears or 0) > 0 and "done" or "not yet"),
    "ore lines (electric drills, belts, smelting area): " .. (not plan and "not yet" or plan.done and "built" or "being built"),
  }
  local done = {}
  for _, name in ipairs(RESEARCH) do
    local tech = e.force.technologies[name]
    done[#done + 1] = name .. (tech and tech.researched and " (done)" or " (not yet)")
  end
  lines[#lines + 1] = "research: " .. table.concat(done, ", ")
  lines[#lines + 1] = COAL_BELT.label .. ": " .. ((c.coal_belt or 0) > 0 and "done" or "not yet")
  return lines
end

-- Free time: hand-craft iron gear wheels from spare plates, up to 100 (drills and the
-- science assembler use them).
local function gears(rec, why)
  local e = rec.entity
  if e.crafting_queue_size > 0 or (why and why:find("iron-plate", 1, true)) then return end
  local have = e.get_item_count(GEAR)
  if have >= GEAR_TARGET then return end
  local n = math.min(GEAR_BATCH, GEAR_TARGET - have, e.get_craftable_count(GEAR))
  if n > 0 and e.get_item_count("iron-plate") >= 2 * n + 10 then craft(rec, GEAR, n) end
end

---------------------------------------------------------------------------
-- Electric drills: once they're researched and there's power, each burner drill and furnace pair on iron
-- or copper is replaced by an electric drill feeding a stone furnace, with a pole on the power network:
-- the new pair is built first and the old one picked up after, so the base never has fewer pairs (and
-- the growth goals don't build burner ones again). Electric drills need no coal, so most refueling ends.

-- An electric pair at p (the drill's center): the drill faces south into a furnace below it (or, for a
-- `chest` pair like the stone drill's, a chest where it drops), with a pole beside the drill.
local function epair_parts(p, kind)
  if kind == "chest" then
    local v = prototypes.entity[EDRILL].vector_to_place_result or {0, -2.3}
    local vx, vy = rotate(v, SOUTH)
    return {drill = p, chest = {x = math.floor(p.x + vx) + 0.5, y = math.floor(p.y + vy) + 0.5}, pole = {x = p.x + 2, y = p.y}}
  end
  return {drill = p, furnace = {x = p.x - 0.5, y = p.y + 2.5}, pole = {x = p.x + 2, y = p.y}}
end

-- Whether an electric pair fits at p: one kind of ore under the drill (enough of it), all three placeable.
local function epair_fits(surface, force, ore, p, kind)
  local parts = epair_parts(p, kind)
  local counts = jobs.drill_resources(surface, prototypes.entity[EDRILL], p)
  local name, n = next(counts)
  local out = parts.chest and can_place(surface, force, CHEST, parts.chest, NORTH) or (parts.furnace and can_place(surface, force, FURNACE, parts.furnace, NORTH))
  return name == ore and next(counts, name) == nil and n >= 12 and can_place(surface, force, EDRILL, p, SOUTH)
    and out and can_place(surface, force, POLE, parts.pole, NORTH)
end

-- A spot for the electric pair replacing `pair`, near it, and the poles that connect it to the network.
local function epair_spot(rec, w, pair)
  local s, e = state(rec), rec.entity
  local wire = cells.wire_reach() - 0.5
  local network = cells.network_poles(e, pair.drill.position)
  if #network == 0 then return nil end
  local avoid = planned_areas(s)
  if s.plant then avoid[#avoid + 1] = power.growth_area(s.plant) end
  local bases = util.enemy_bases(e.surface, pair.drill.position, 30 + util.NEST_CLEARANCE)
  local ax, ay = math.floor(pair.drill.position.x), math.floor(pair.drill.position.y)
  for _, o in ipairs(offsets()) do
    local p = {x = ax + o[1] + 0.5, y = ay + o[2] + 0.5}
    if not s.skip[p.x .. "," .. p.y] and not util.base_near(bases, p) and epair_fits(e.surface, e.force, pair.ore, p, pair.kind)
      and owner_clear(e.surface, e.force, p) then
      local parts = epair_parts(p, pair.kind)
      local nearest = network[1]
      for _, pole in ipairs(network) do
        if util.distance(pole.position, parts.pole) < util.distance(nearest.position, parts.pole) then nearest = pole end
      end
      local line = cells.pole_line(e, nearest.position, parts.pole, wire, avoid)
      if line then
        parts.line = line
        return parts
      end
    end
  end
end

-- How much of the steam engines' power is in use (0 to 1), or nil without engines.
local function power_load(e, home)
  local made, max = 0, 0
  for _, engine in ipairs(e.surface.find_entities_filtered{type = "generator", force = e.force, position = home, radius = 256}) do
    made = made + engine.energy_generated_last_tick
    max = max + engine.prototype.get_max_power_output()
  end
  if max == 0 then return nil end
  return made / max
end

-- More drills only while the engines have room for them (each electric drill takes 90 kW).
local MAX_LOAD = 0.6
-- The power plant grows once its engines run above this.
local GROW_LOAD = 0.75

---------------------------------------------------------------------------
-- Ore lines: once electric drills are researched, iron and copper come from electric drills in the ore
-- fields, a gap between them for poles, putting ore on a belt out of the field (never two ores on one belt),
-- to a smelting area: a row of stone furnaces per ore, inserters putting that ore in from its belt and
-- coal from a coal belt between the two rows (fed by a coal drill of its own), long-handed inserters taking
-- the plates out across the ore belt onto a plate belt, which ends in a chest. Built while the burner pairs
-- keep making plates; they're picked up once the lines run. The smelting area goes on the side with the
-- fewest obstacles, away from nests. Four iron drills, two copper, one coal (the stone drill is upgrade's).

local LONG = "long-handed-inserter"
local ORE_LINES = {{ore = "iron-ore", drills = 4, furnaces = 6}, {ore = "copper-ore", drills = 2, furnaces = 3}}
local LINE_COAL_DRILLS = 1

-- A min-heap of states by priority, each with its cost: push(priority, state, cost), pop() -> state, cost.
-- (Parallel arrays: a table per entry is much of a search's time.)
local function make_heap()
  local pr, sts, gs, n = {}, {}, {}, 0
  local function push(c, st, g)
    n = n + 1
    local i = n
    while i > 1 do
      local p = (i - i % 2) / 2
      if pr[p] <= c then break end
      pr[i], sts[i], gs[i] = pr[p], sts[p], gs[p]
      i = p
    end
    pr[i], sts[i], gs[i] = c, st, g
  end
  local function pop()
    local st, g = sts[1], gs[1]
    local c, tst, tg = pr[n], sts[n], gs[n]
    pr[n], sts[n], gs[n] = nil, nil, nil
    n = n - 1
    if n > 0 then
      local i = 1
      while true do
        local l = 2 * i
        if l > n then break end
        if l < n and pr[l + 1] < pr[l] then l = l + 1 end
        if pr[l] >= c then break end
        pr[i], sts[i], gs[i] = pr[l], sts[l], gs[l]
        i = l
      end
      pr[i], sts[i], gs[i] = c, tst, tg
    end
    return st, g
  end
  return push, pop, function() return n end
end

local function dir_index(v)
  for k = 0, 3 do
    if SIDES[k][1] == v[1] and SIDES[k][2] == v[2] then return k end
  end
end

-- What a belt can't go on or under in `area` ({{x0, y0}, {x1, y1}}, tiles): water and everything in the way
-- (`solid`) and the underground belts (`under`), as sets of tiles keyed x * 100000 + y, and the tiles only
-- `removable` things (unit numbers as keys: picked up first) are on (`clear`). Scanned once for many routes.
-- (On M: this file is at Lua's limit of local names.)
function M.belt_world(surface, area, removable)
  local solid, under, clear = {}, {}, {}
  for _, t in ipairs(surface.find_tiles_filtered{area = area, collision_mask = "water_tile"}) do solid[t.position.x * 100000 + t.position.y] = true end
  for _, thing in ipairs(surface.find_entities_filtered{area = area, type = PASSABLE, invert = true}) do
    local set = removable and thing.unit_number and removable[thing.unit_number] and clear or solid
    local lt, rb = thing.bounding_box.left_top, thing.bounding_box.right_bottom
    for x = math.floor(lt.x + 0.01), math.ceil(rb.x - 0.01) - 1 do
      for y = math.floor(lt.y + 0.01), math.ceil(rb.y - 0.01) - 1 do set[x * 100000 + y] = true end
    end
  end
  for _, u in ipairs(surface.find_entities_filtered{area = area, type = "underground-belt"}) do
    under[math.floor(u.position.x) * 100000 + math.floor(u.position.y)] = true
  end
  for k in pairs(solid) do clear[k] = nil end
  return {area = area, solid = solid, under = under, clear = clear, removable = removable}
end

-- A belt over open ground from tile `from` (items coming in heading from_dir) to tile `to` (going on heading
-- to_dir), as straight as it goes (TURN belts per turn), staying out of the `keep_out` boxes and `reserved`
-- tiles ("x,y"): a list of {position, direction} from `from` to `to`, or nil and why. With `ug` (underground
-- belts are researched) it can also go under whatever is in its way, a pair of underground belts at a time
-- (those entries carry item and belt_type). `world` (belt_world) saves scanning the map again when it covers
-- the search area. The engineer's own buildings in `removable` (unit numbers as keys) don't block it: they
-- get picked up (CLEAR_COST more per tile), since a straight, short belt is worth more than where they stand.
local function belt_route(e, from, from_dir, to, to_dir, keep_out, reserved, ug, world, removable)
  local surface = e.surface
  -- States are tile * 8 + heading, plus 4 for an underground entrance (fed straight from behind).
  local UG_GAP = ug and (prototypes.entity["underground-belt"].max_underground_distance - 1) or 0
  local UG_COST = 6
  local CLEAR_COST = 2
  local x0, y0 = math.min(from.x, to.x) - 30, math.min(from.y, to.y) - 30
  local x1, y1 = math.max(from.x, to.x) + 30, math.max(from.y, to.y) + 30
  local H = y1 - y0 + 1
  local function idx(x, y) return (x - x0) * H + (y - y0) end
  local function inside(x, y) return x >= x0 and x <= x1 and y >= y0 and y <= y1 end
  local area = {{x0, y0}, {x1 + 1, y1 + 1}}
  if not (world and world.removable == removable and world.area[1][1] <= x0 and world.area[1][2] <= y0
      and world.area[2][1] >= x1 + 1 and world.area[2][2] >= y1 + 1) then
    world = M.belt_world(surface, area, removable)
  end
  local blocked, under, clear = {}, {}, {}
  local solid = world.solid
  for x = x0, x1 do
    for y = y0, y1 do
      local k = x * 100000 + y
      if solid[k] then blocked[idx(x, y)] = true end
      if world.under[k] then under[idx(x, y)] = true end
      if world.clear[k] then clear[idx(x, y)] = true end
    end
  end
  local function block(lt, rb)
    for x = math.floor(lt.x + 0.01), math.ceil(rb.x - 0.01) - 1 do
      for y = math.floor(lt.y + 0.01), math.ceil(rb.y - 0.01) - 1 do
        if inside(x, y) then blocked[idx(x, y)] = true end
      end
    end
  end
  for _, box in ipairs(keep_out) do block(box.left_top, box.right_bottom) end
  -- (Reserved tiles go into the grid once: a string per tile looked at is most of the search's time.)
  for k in pairs(reserved) do
    local x, y = k:match("^(-?%d+),(-?%d+)$")
    x, y = tonumber(x), tonumber(y)
    if x and inside(x, y) then blocked[idx(x, y)] = true end
  end
  local function open(x, y)
    return inside(x, y) and not blocked[idx(x, y)]
  end
  if not open(to.x, to.y) then return nil, "the belt's end at " .. to.x .. "," .. to.y .. " is blocked" end
  if not open(from.x, from.y) then return nil, "the field's belt start at " .. from.x .. "," .. from.y .. " is blocked" end
  local no_route = "there's no belt route from " .. from.x .. "," .. from.y .. " to " .. to.x .. "," .. to.y
  local from_i = idx(from.x, from.y)
  -- First, cheaply, the tiles a belt from the start could get to at all, tile to tile any way round (under
  -- things too): without the end among them there's no route, and the search below doesn't look at every
  -- state in the area to find that out (or at any tile not among them). (Going under something only
  -- matters where the next tile is blocked: to the first open one past it.)
  local reach = {[from_i] = true}
  do
    local queue, head, tail = {from_i}, 1, 1
    while head <= tail do
      local ti = queue[head]
      head = head + 1
      local x, y = (ti - ti % H) / H + x0, ti % H + y0
      for h = 0, 3 do
        local dx, dy = SIDES[h][1], SIDES[h][2]
        for jump = 1, UG_GAP + 1 do
          local nx, ny = x + jump * dx, y + jump * dy
          if not inside(nx, ny) then break end
          local ni = idx(nx, ny)
          if not blocked[ni] then
            if not reach[ni] then
              reach[ni] = true
              tail = tail + 1
              queue[tail] = ni
            end
            break
          end
          if under[ni] then break end
        end
      end
    end
    if not reach[idx(to.x, to.y)] then return nil, no_route end
  end
  -- Searched back from the end (A*, toward the start): nxt[state] is the state the belt goes on to from
  -- there. The distance in tiles to the start, weighed over (EST_WEIGHT: twice, a fifth of the time for
  -- routes as good on a crowded base; more puts in underground belts all over), leads it straight there;
  -- ties go to the state furthest along, so a straight way runs straight on.
  local EST_WEIGHT = 2
  local cost, nxt = {}, {}
  local push, pop, size = make_heap()
  local fx, fy = from.x, from.y
  local function est(ti)
    local d = (ti - ti % H) / H + x0 - fx
    local d2 = ti % H + y0 - fy
    return EST_WEIGHT * ((d < 0 and -d or d) + (d2 < 0 and -d2 or d2))
  end
  local start = idx(to.x, to.y) * 8 + to_dir
  cost[start] = 0
  push(est(math.floor(start / 8)), start, 0)
  local MAX_COST = MAX_BELTS + 8 * TURN
  local reached = nil
  -- The states the belt can start in: not heading back into the field, and an underground entrance only
  -- straight on from it.
  local function starts(m)
    local d = m % 4
    return d ~= (from_dir + 2) % 4 and (m < 4 or d == from_dir)
  end
  local function relax(ps, nc, st)
    local ti = (ps - ps % 8) / 8
    if clear[ti] then nc = nc + CLEAR_COST end
    if reach[ti] and (not cost[ps] or nc < cost[ps]) then
      cost[ps], nxt[ps] = nc, st
      push(nc + est(ti) - nc / 4096, ps, nc)
    end
  end
  while size() > 0 do
    local st, c = pop()
    local i = (st - st % 8) / 8
    -- Past the first way to the start (plus a turn there), nothing cheaper is left. (Only a way it can start
    -- in counts: an underground entrance on the start tile, say, often comes first and can't be used.)
    if reached and c + est(i) > reached + TURN then break end
    if i == from_i and starts(st % 8) then reached = reached or c end
    if c == cost[st] and c < MAX_COST then
      local m = st % 8
      local h2, entrance = m % 4, m >= 4
      local x, y = math.floor(i / H) + x0, i % H + y0
      for h = 0, 3 do
        -- (An underground entrance takes its items straight from behind.)
        if h ~= (h2 + 2) % 4 and (not entrance or h == h2) then
          local px, py = x - SIDES[h][1], y - SIDES[h][2]
          if open(px, py) then relax(idx(px, py) * 8 + h, c + 1 + (h ~= h2 and TURN or 0), st) end
        end
      end
      -- Or this belt follows an underground exit right behind it, its entrance up to UG_GAP tiles further.
      if not entrance and UG_GAP > 0 then
        local dx, dy = SIDES[h2][1], SIDES[h2][2]
        local ex, ey = x - dx, y - dy
        if open(ex, ey) then
          local exit_cost = c + 2 + UG_COST + (clear[idx(ex, ey)] and CLEAR_COST or 0)
          for gap = 1, UG_GAP do
            local gx, gy = ex - gap * dx, ey - gap * dy
            if not inside(gx, gy) or under[idx(gx, gy)] then break end
            local ix, iy = gx - dx, gy - dy
            if open(ix, iy) and not under[idx(ix, iy)] then relax(idx(ix, iy) * 8 + 4 + h2, exit_cost + gap, st) end
          end
        end
      end
    end
  end
  if not inside(from.x, from.y) then return nil, "the field is too far from the smelting area" end
  local best, cur
  for m = 0, 7 do
    local d = m % 4
    local c = starts(m) and cost[from_i * 8 + m]
    if c then
      c = c + (d ~= from_dir and TURN or 0)
      if not best or c < best then best, cur = c, from_i * 8 + m end
    end
  end
  if not best then return nil, no_route end
  local belts = {}
  local function tile_of(st)
    local i = math.floor(st / 8)
    return math.floor(i / H) + x0, i % H + y0
  end
  while true do
    local x, y = tile_of(cur)
    local m = cur % 8
    local h = m % 4
    if m >= 4 then
      -- The exit is the tile before where the belt goes on.
      local nx, ny = tile_of(nxt[cur])
      belts[#belts + 1] = {position = {x = x + 0.5, y = y + 0.5}, direction = h, item = "underground-belt", belt_type = "input"}
      belts[#belts + 1] = {position = {x = nx - SIDES[h][1] + 0.5, y = ny - SIDES[h][2] + 0.5}, direction = h, item = "underground-belt", belt_type = "output"}
    else
      belts[#belts + 1] = {position = {x = x + 0.5, y = y + 0.5}, direction = h}
    end
    if cost[cur] == 0 then break end
    cur = nxt[cur]
    if not cur then return nil, "the belt route broke off" end
  end
  return belts
end
M.belt_route = belt_route -- (for test:route)

-- Whether an electric drill at p facing dir mines only `ore` (enough of it) and can go there (once what's
-- `removable` is picked up).
local function edrill_fits(e, ore, p, dir, removable)
  local counts = jobs.drill_resources(e.surface, prototypes.entity[EDRILL], p)
  return (counts[ore] or 0) >= MIN_COAL and table_size(counts) == 1 and can_place(e.surface, e.force, EDRILL, p, dir, removable)
    and owner_clear(e.surface, e.force, p)
end

-- An ore field near `anchor`: `n` electric drills either side of a straight belt, facing it, 4 tiles apart
-- (a tile's gap between drills, with a pole in it). The belt flows toward `toward`. Returns {drills, poles,
-- belts, out (the tile after the belt's end), out_dir} and its score (lower is better), or nil. With `part`
-- of `parts` (an even number) only that share of the lines is looked at: east-west lines first, then
-- north-south, each in bands west to east. The engineer's buildings in `removable` (its burner pairs on
-- the field, say) don't count as in the way: they're picked up first.
local function field_plan(e, ore, n, anchor, toward, part, parts, removable)
  local proto = prototypes.entity[EDRILL]
  local v = proto.vector_to_place_result or {0, -2.3}
  local best, best_score
  local ax, ay = math.floor(anchor.x), math.floor(anchor.y)
  -- (Many lines share drill spots: each is checked once.)
  local fit_cache = {}
  local function fits_here(c, dir)
    local k = c.x .. "," .. c.y .. "," .. dir
    if fit_cache[k] == nil then fit_cache[k] = edrill_fits(e, ore, c, dir, removable) end
    return fit_cache[k]
  end
  local function free(name, p, dir)
    local k = name .. p.x .. "," .. p.y .. "," .. dir
    if fit_cache[k] == nil then fit_cache[k] = can_place(e.surface, e.force, name, p, dir, removable) end
    return fit_cache[k]
  end
  -- (Only belt lines starting on the ore are tried.)
  local on_ore = {}
  for _, r in ipairs(e.surface.find_entities_filtered{area = {{ax - 16, ay - 16}, {ax + 17, ay + 17}}, type = "resource", name = ore}) do
    on_ore[math.floor(r.position.x) .. "," .. math.floor(r.position.y)] = true
  end
  local alongs, dx_lo, dx_hi = {{1, 0}, {0, 1}}, -16, 16
  if part then
    local bands = parts / 2
    local band = (part - 1) % bands
    alongs = {alongs[math.ceil(part / bands)]}
    dx_lo, dx_hi = -16 + math.floor(33 * band / bands), -16 + math.floor(33 * (band + 1) / bands) - 1
  end
  for _, along in ipairs(alongs) do
    local across = {along[2], along[1]}
    for dx = dx_lo, dx_hi do
      for dy = -16, 16 do
        local bx, by = ax + dx, ay + dy -- the belt tile in front of the first drill(s)
        local drills, k = {}, 0
        if not on_ore[bx .. "," .. by] then k = n + 1 end
        while #drills < n and k <= n do
          local placed = false
          for _, sgn in ipairs({-1, 1}) do
            if #drills < n then
              local c = {x = bx + 4 * k * along[1] + 2 * sgn * across[1] + 0.5, y = by + 4 * k * along[2] + 2 * sgn * across[2] + 0.5}
              local dir = dir_index({-sgn * across[1], -sgn * across[2]})
              local vx, vy = rotate(v, dir)
              if math.floor(c.x + vx) == bx + 4 * k * along[1] and math.floor(c.y + vy) == by + 4 * k * along[2] and fits_here(c, dir) then
                drills[#drills + 1] = {position = c, direction = dir, side = sgn, k = k}
                placed = true
              end
            end
          end
          if not placed then break end
          k = k + 1
        end
        if #drills >= n then
          local last = drills[#drills].k
          -- The belt runs past the drills' fronts, one tile either end, toward `toward`.
          local fwd = ((toward.x - bx) * along[1] + (toward.y - by) * along[2]) >= 0 and 1 or -1
          local first_t, last_t = -1, 4 * last + 1
          if fwd < 0 then first_t, last_t = last_t, first_t end
          local belts, ok = {}, true
          local dir = dir_index({fwd * along[1], fwd * along[2]})
          for t = first_t, last_t, fwd do
            local p = {x = bx + t * along[1] + 0.5, y = by + t * along[2] + 0.5}
            if not free(BELT, p, dir) then ok = false; break end
            belts[#belts + 1] = {position = p, direction = dir}
          end
          local poles = {}
          for _, d in ipairs(ok and drills or {}) do
            local p = {x = d.position.x + 2 * along[1], y = d.position.y + 2 * along[2]}
            if not free(POLE, p, NORTH) then ok = false end
            poles[#poles + 1] = p
          end
          -- The belt carries on from the tile past its end, so that has to be free too.
          local endp = ok and belts[#belts].position
          local out = endp and {x = math.floor(endp.x) + fwd * along[1], y = math.floor(endp.y) + fwd * along[2]}
          if out and not free(BELT, {x = out.x + 0.5, y = out.y + 0.5}, dir) then ok = false end
          if ok then
            local score = math.abs(dx) + math.abs(dy) + 2 * last
            if not best_score or score < best_score then
              -- (`line`: where it is, so it can grow longer upstream later, grow_smelting.)
              best, best_score = {drills = drills, poles = poles, belts = belts, out_dir = dir, out = out,
                line = {bx = bx, by = by, along = along, across = across, fwd = fwd, kmin = 0, kmax = last}}, score
            end
          end
        end
      end
    end
  end
  return best, best_score
end

-- Whether a box is clear to build on: no water, ore or buildings (trees and rocks can be cleared, and so
-- can what's `removable`). The second result is how many removable things are in it.
local function area_clear(surface, box, removable)
  local area = {{box.left_top.x, box.left_top.y}, {box.right_bottom.x, box.right_bottom.y}}
  if surface.count_tiles_filtered{area = area, collision_mask = "water_tile"} > 0 then return false end
  if surface.count_entities_filtered{area = area, type = "resource"} > 0 then return false end
  local n = 0
  for _, other in ipairs(surface.find_entities_filtered{area = area, type = PASSABLE, invert = true}) do
    if not (removable and other.unit_number and removable[other.unit_number]) then return false end
    n = n + 1
  end
  return true, n
end

-- The smelting area (the owner's design): a trunk of ore and coal belts, smelting columns hanging off it
-- across the main bus, and the bus starting beside the trunk. In the bus's frame (frame.lua's `m`, origin
-- (x0, y0); x along the bus, y toward the columns):
-- - The trunk: rows -5 (column A's ore), -2 (column B's ore) and 1 (coal), from column 0 east, two rows
--   apart so a branch's underground belts fit between them. Routes end at column -1, going on east.
-- - Each column takes three branches off the trunk (a splitter each, under the trunk rows below and the
--   bus by underground belt): its ore down the middle (both lanes) and a coal belt down each outer edge.
--   Furnaces on both sides of the middle, an inserter from it into each, one onto the plate belt beside
--   each coal belt, and a long-handed one over that plate belt for coal; a gap row with poles after every
--   two furnaces a side. The plate belts flow back up, merge at the head (one side per lane) and rise
--   onto the bus. It grows by getting longer (GROW rows kept past it).
-- - The bus: column A's plates (iron, or copper if `flip`) on row 5, coal on 6 (a U-turn up from under
--   the bus between the columns), column B's plates on 7, each row starting where its source joins so
--   nothing crosses; past X, bus.lua's slots. A tap (an inserter into a chest) on each plate row.
-- Returns the places, the entry tile of each trunk belt, its box (with the growth room), the plate
-- chests (the taps), the bus's frame, the box routes stay out of, the direction routes end going, and the
-- longer column's last row.
M.GROW_ROWS = 24 -- rows kept past the longer column, for more furnaces
local function smelter_layout(x0, y0, n_iron, n_copper, flip, m)
  local GROW = M.GROW_ROWS
  local UG, SPLIT = "underground-belt", "splitter"
  -- Trunk rows (column A's ore, column B's ore, coal), the columns' middles, the coal hook's column, X.
  local LA, LB, LC = -5, -2, 1
  local A, B, HOOK = 8, 25, 16
  local X = B + 8
  local g = {x0 = x0, y0 = y0, m = m}
  local places = {}
  local function put(item, tx, ty, d, belt_type)
    places[#places + 1] = {item, {position = bus.tile(g, tx, ty), direction = d and bus.dir(g, d), belt_type = belt_type}}
  end
  local function ins(item, tx, ty, vx) places[#places + 1] = {item, {position = bus.tile(g, tx, ty), direction = bus.toward(g, vx, 0)}} end
  local function belts(tx, ty0, ty1, d)
    for ty = ty0, ty1, ty1 >= ty0 and 1 or -1 do put(BELT, tx, ty, d) end
  end
  -- The trunk, its belts past every splitter (dead ends: a full one sends everything down its branches).
  local splits = {}
  local function branch(L, bx)
    splits[L .. ":" .. (bx - 1)] = true
    places[#places + 1] = {SPLIT, {position = bus.at(g, bx - 0.5, L + 1), direction = bus.dir(g, EAST)}}
    put(BELT, bx, L + 1, SOUTH)
    local y = L + 2
    for _, L2 in ipairs({LA, LB, LC}) do
      if L2 > L then
        put(UG, bx, L2 - 1, SOUTH, "input")
        put(UG, bx, L2 + 1, SOUTH, "output")
        y = L2 + 2
      end
    end
    belts(bx, y, 3, SOUTH)
    put(UG, bx, 4, SOUTH, "input")
    put(UG, bx, 9, SOUTH, "output")
  end
  -- A column: `n` furnaces a side around its middle ore belt, coal belts on the outer edges, plates back up
  -- between them, merged at the head (row 8) and up onto bus row `row`. Returns its last row.
  local function column(mx, n, L, row)
    branch(L, mx)
    branch(LC, mx - 6)
    branch(LC, mx + 6)
    belts(mx - 5, 8, 8, EAST)
    for tx = mx - 4, mx - 1 do put(BELT, tx, 8, EAST) end
    belts(mx + 5, 8, 8, WEST)
    for tx = mx + 1, mx + 4 do put(BELT, tx, 8, WEST) end
    belts(mx, 8, row + 1, NORTH)
    put(BELT, mx, row, EAST)
    local last = 10
    for k = 0, n - 1 do
      local r = 10 + 2 * k + math.floor((k + 1) / 2)
      for _, sd in ipairs({-1, 1}) do
        places[#places + 1] = {FURNACE, {position = bus.at(g, sd > 0 and mx + 3 or mx - 2, r + 1)}}
        ins(INSERTER, mx + sd, r, sd)
        ins(INSERTER, mx + 4 * sd, r, sd)
        ins(LONG, mx + 4 * sd, r + 1, -sd)
      end
      if k % 2 == 0 then
        local gap = 12 + 5 * (k / 2)
        put(POLE, mx - 3, gap)
        put(POLE, mx + 3, gap)
        last = math.max(last, gap)
      end
      last = math.max(last, r + 1)
    end
    belts(mx, 10, last, SOUTH)
    belts(mx - 5, last, 9, NORTH)
    belts(mx + 5, last, 9, NORTH)
    belts(mx - 6, 10, last, SOUTH)
    belts(mx + 6, 10, last, SOUTH)
    return last
  end
  local a_ore, b_ore, n_a, n_b = "iron-ore", "copper-ore", n_iron, n_copper
  if flip then a_ore, b_ore, n_a, n_b = b_ore, a_ore, n_b, n_a end
  local last = math.max(column(A, math.ceil(n_a / 2), LA, 5), column(B, math.ceil(n_b / 2), LB, 7))
  -- Coal onto the bus's middle row: under the bus, a U-turn, and up onto row 6 (rows 5 and 7 start
  -- elsewhere, so nothing crosses).
  branch(LC, HOOK)
  put(BELT, HOOK, 10, EAST)
  belts(HOOK + 1, 10, 7, NORTH)
  put(BELT, HOOK + 1, 6, EAST)
  for tx = 0, B + 6 do
    for _, L in ipairs({LA, LB, LC}) do
      if not splits[L .. ":" .. tx] then put(BELT, tx, L, EAST) end
    end
  end
  for tx = A + 1, X do put(BELT, tx, 5, EAST) end
  for tx = HOOK + 2, X do put(BELT, tx, 6, EAST) end
  for tx = B + 1, X do put(BELT, tx, 7, EAST) end
  -- A pole between the columns (their poles are 11 apart), and the taps: the top plates' above row 5,
  -- the bottom plates' below row 7, where the bus expects them.
  put(POLE, A + 10, 12)
  local chests = {bus.tile(g, X - 1, 3), bus.tile(g, X - 1, 9)}
  places[#places + 1] = {INSERTER, {position = bus.tile(g, X - 1, 4), direction = bus.toward(g, 0, -1)}}
  places[#places + 1] = {CHEST, {position = chests[1]}}
  places[#places + 1] = {INSERTER, {position = bus.tile(g, X - 1, 8), direction = bus.toward(g, 0, 1)}}
  places[#places + 1] = {CHEST, {position = chests[2]}}
  put(POLE, X + 1, 3)
  put(POLE, X + 1, 9)
  local function entry(L)
    local c = bus.tile(g, -1, L)
    return {x = math.floor(c.x), y = math.floor(c.y)}
  end
  -- (The bus's own area starts past X: its slots and labs.)
  local box = bus.box(g, -1, LA - 1, X, last + 1 + GROW)
  local inner = bus.box(g, 0, LA - 1, X, last + 1 + GROW)
  -- (`hook`: the column between the two smelting columns.)
  local frame = {x0 = x0, y0 = y0, X = X, width = X - 1, turned = true, columns = true, m = m, hook = HOOK}
  return places, {[a_ore] = entry(LA), [b_ore] = entry(LB), coal = entry(LC)}, box, chests, frame, inner, bus.dir(g, EAST), last
end

local function tile_box(p, half)
  return {left_top = {x = p.x - half, y = p.y - half}, right_bottom = {x = p.x + half, y = p.y + half}}
end

-- Planning the ore lines takes the game too long for one tick (seconds on a big base), so it's done a step
-- at a time, one step per autopilot tick whatever the engineer is doing (M.lines_step), in a table kept in
-- storage (s.lines_work): the fields one ore at a time, the smelting area's site one column of places at a
-- time, the belts one site and order at a time, then pole lines from the network. lines_plan starts it;
-- it ends with work.done, and work.plan ({places, parts, ...}) or work.why. (In a block: this file is at
-- Lua's limit of local names.)
local lines_plan
do
  local SITES_TRIED = 8

  -- The fields, each belt flowing toward the middle of them all: a share of one ore's (work.part of
  -- FIELD_PARTS), the best kept.
  local FIELD_PARTS = 12
  local function field_step(e, work)
    local l = work.lines[work.i]
    work.part = (work.part or 0) + 1
    local field, score = field_plan(e, l.ore, l.drills, l.anchor, work.center, work.part, FIELD_PARTS, work.removable)
    if field and (not l.score or score < l.score) then l.field, l.score = field, score end
    if work.part < FIELD_PARTS then return end
    work.part = nil
    if not l.field then
      work.done, work.why = true, "there's no room for " .. l.drills .. " electric drills in a row on the " .. l.ore .. " near " .. serpent.line(util.pos(l.anchor))
      return
    end
    local reserved, taken = work.reserved, work.taken
    for _, d in ipairs(l.field.drills) do
      taken[#taken + 1] = tile_box(d.position, 1.5)
      for x = -1, 1 do for y = -1, 1 do reserved[math.floor(d.position.x + x) .. "," .. math.floor(d.position.y + y)] = true end end
    end
    for _, p in ipairs(l.field.poles) do reserved[math.floor(p.x) .. "," .. math.floor(p.y)] = true; taken[#taken + 1] = tile_box(p, 0.5) end
    for _, b in ipairs(l.field.belts) do reserved[math.floor(b.position.x) .. "," .. math.floor(b.position.y)] = true end
    work.i = work.i + 1
    if work.i > #work.lines then work.stage, work.i = "sites", -12 end
  end

  -- How bad the ground under the bus (its sub-factory slots and labs, bus.area) is for building on, in
  -- frame g: water, ore and buildings block it, cliffs block it until cliff explosives (much later), dense
  -- trees take time to chop, land not revealed yet is a risk, and an enemy nest near it the worst.
  -- (`charted`: whether this map charts at all; a headless server never does, so there only land not
  -- generated yet counts, as pollution.lua's revealer does.)
  local function bus_ground(surface, force, g, nest, removable, charted)
    local box = bus.area(g)
    local a = {{box.left_top.x, box.left_top.y}, {box.right_bottom.x, box.right_bottom.y}}
    local score = 0.05 * (surface.count_tiles_filtered{area = a, collision_mask = "water_tile"}
      + surface.count_entities_filtered{area = a, type = "resource"})
      + 3 * surface.count_entities_filtered{area = a, type = "cliff"}
      + 0.02 * surface.count_entities_filtered{area = a, type = "tree"}
    for _, other in ipairs(surface.find_entities_filtered{area = a, type = PASSABLE, invert = true}) do
      if other.type ~= "cliff" and not (other.unit_number and removable and removable[other.unit_number]) then score = score + 1 end
    end
    for cx = math.floor(a[1][1] / 32), math.floor(a[2][1] / 32) do
      for cy = math.floor(a[1][2] / 32), math.floor(a[2][2] / 32) do
        local seen = charted and force.is_chunk_charted(surface, {cx, cy}) or (not charted and surface.is_chunk_generated({cx, cy}))
        if not seen then score = score + 8 end
      end
    end
    -- (Heavy, and the nearer the worse: within 300 tiles it outweighs crossing an ore field.)
    if nest then
      local mid = {x = (a[1][1] + a[2][1]) / 2, y = (a[1][2] + a[2][2]) / 2}
      score = score + 2 * math.max(0, 300 - util.distance(mid, nest))
    end
    return score
  end

  -- The smelting area: clear ground near the middle of the fields, away from nests, its trunk's start
  -- toward the fields, facing whichever way has the best ground for the bus (bus_ground): a frame of the
  -- eight (bus.FRAMES) for one column of places (gx = work.i, frame work.f) a step, the best SITES_TRIED
  -- kept.
  local function sites_step(e, work)
    local surface = e.surface
    local lines, center, keep, taken, nest = work.lines, work.center, work.keep, work.taken, work.nest
    local n_iron, n_copper = ORE_LINES[1].furnaces, ORE_LINES[2].furnaces
    local sites, gx = work.sites, work.i
    work.f = work.f or 1
    local m = bus.FRAMES[work.f]
    for gy = -12, 12 do
      local x0, y0 = math.floor(center.x) + 4 * gx, math.floor(center.y) + 4 * gy
      local _, _, box = smelter_layout(x0, y0, n_iron, n_copper, false, m)
      local margin = grow(box, 2)
      local ok = true
      for _, k in ipairs(keep) do if overlaps(margin, k) then ok = false; break end end
      for _, k in ipairs(ok and taken or {}) do if overlaps(margin, k) then ok = false; break end end
      local clear, moved = false, 0
      if ok then clear, moved = area_clear(surface, margin, work.removable) end
      if clear then
        local mid = {x = (box.left_top.x + box.right_bottom.x) / 2, y = (box.left_top.y + box.right_bottom.y) / 2}
        local base = util.distance(mid, center) - (nest and 0.5 * math.min(util.distance(mid, nest), 200) or 0)
          + 0.2 * surface.count_entities_filtered{area = {{box.left_top.x, box.left_top.y}, {box.right_bottom.x, box.right_bottom.y}}, type = {"tree", "simple-entity"}}
          + 2 * moved
        -- (Fields past the trunk's start cost a longer way round to its entries.)
        local _, _, _, _, g = smelter_layout(x0, y0, n_iron, n_copper, false, m)
        for _, l in ipairs(lines) do
          if bus.where(g, l.field.out) > 0 then base = base + 20 end
        end
        local charted = e.force.is_chunk_charted(surface, {math.floor(center.x / 32), math.floor(center.y / 32)})
        base = base + bus_ground(surface, e.force, g, nest, work.removable, charted)
        -- The main bus continues past the trunk's end: better where its first sub-factories have room.
        if g then
          local first = bus.box(g, g.X + 1, 2, bus.feeder_x(g, 2) + 9, 21)
          local blocked = not area_clear(surface, first)
          for _, k in ipairs(blocked and {} or keep) do if overlaps(first, k) then blocked = true; break end end
          if blocked then base = base + 30 end
        end
        -- The trunk's belts all come in at its start, side by side; seen from there, the fields should lie
        -- in that order too, or one belt has to cross another. (In the frame's terms.)
        for _, flip in ipairs({false, true}) do
          local places, entries, _, chests, frame, inner, entry_dir, last = smelter_layout(x0, y0, n_iron, n_copper, flip, m)
          local order = {}
          for _, l in ipairs(lines) do
            local tx, ty = bus.where(frame, {x = entries[l.ore].x + 0.5, y = entries[l.ore].y + 0.5})
            local fx, fy = bus.where(frame, l.field.out)
            order[#order + 1] = {x = ty, angle = math.atan2(fy - ty, tx - fx)}
          end
          table.sort(order, function(a, b) return a.x < b.x end)
          local score = base
          for i = 1, #order do
            for j = i + 1, #order do
              if order[i].angle > order[j].angle then score = score + 40 end
            end
          end
          sites[#sites + 1] = {places = places, entries = entries, box = box, chests = chests, x0 = x0, y0 = y0, score = score,
            frame = frame, inner = inner, entry_dir = entry_dir,
            -- (How it was laid out, so it can be laid out again longer: its columns stay above `room`.)
            layout = {x0 = x0, y0 = y0, n_iron = n_iron, n_copper = n_copper, flip = flip, m = m, room = last + M.GROW_ROWS}}
          work.site_count = work.site_count + 1
        end
      end
    end
    -- The best, at most two (a site's two orders) facing each way: neighboring sites facing the same way
    -- tend to fail for the same reason.
    table.sort(sites, function(a, b) return a.score < b.score end)
    local kept, per = {}, {}
    for _, st in ipairs(sites) do
      local k = serpent.line(st.frame.m)
      if #kept < SITES_TRIED and (per[k] or 0) < 2 then
        kept[#kept + 1] = st
        per[k] = (per[k] or 0) + 1
      end
    end
    for i = 1, math.max(#sites, #kept) do sites[i] = kept[i] end
    work.f = work.f + 1
    if work.f > #bus.FRAMES then work.f, work.i = 1, gx + 1 end
    if work.i > 12 then
      if #sites == 0 then
        work.done, work.why = true, "there's no clear ground for a smelting area near the ore fields"
        return
      end
      work.stage, work.i = "routes", 1
    end
  end

  -- On to the next site and order after one didn't work out (work.why says why the first didn't).
  local function next_try(work, why)
    work.why = work.why or why
    work.try, work.stage, work.i = nil, "routes", work.i + 1
    if work.i > 2 * #work.sites then work.done = true end
  end

  -- Belts from each field to its row's start, the smelting area and other belts kept clear. The best few
  -- sites are tried, each routing the belts in two orders (one belt can wall off another's way in): work.i
  -- is the site ((i + 1) // 2) and order (odd in the fields' order, even the other way round), work.try
  -- the belts so far. One belt.
  local function routes_step(e, work)
    local site = work.sites[math.floor((work.i + 1) / 2)]
    local inner = site.inner
    local try = work.try
    if not try then
      local used = {}
      for k in pairs(work.reserved) do used[k] = true end
      for _, t in pairs(site.entries) do used[t.x .. "," .. t.y] = true end
      try = {k = 1, used = used, routes = {}}
      work.try = try
    end
    local n = #work.lines
    local l = work.lines[work.i % 2 == 1 and try.k or n + 1 - try.k]
    -- (Not across the bus this site leads to either: its slots' splitters go on its rows later.)
    local route_keep = {inner, bus.area(site.frame)}
    for _, k in ipairs(work.keep) do route_keep[#route_keep + 1] = k end
    local to = site.entries[l.ore]
    try.used[to.x .. "," .. to.y] = nil
    local route, why = belt_route(e, l.field.out, l.field.out_dir, to, site.entry_dir, route_keep, try.used, work.ug, nil, work.removable)
    if not route then
      next_try(work, "no belt from the " .. l.ore .. " field to the smelting area (" .. tostring(why) .. ")")
      return
    end
    for _, b in ipairs(route) do try.used[math.floor(b.position.x) .. "," .. math.floor(b.position.y)] = true end
    try.routes[l.ore] = route
    try.k = try.k + 1
    if try.k > n then work.best, work.routes, work.inner, work.stage, work.try = site, try.routes, inner, "poles", nil end
  end

  -- Pole lines: to the smelting area and each field, from the nearest pole on the network or planned here
  -- (with no way, the next site or order is tried). Then the plan.
  local function poles_step(e, work)
    local lines, best, routes, keep = work.lines, work.best, work.routes, work.keep
    local wire = cells.wire_reach() - 0.5
    local network = cells.network_poles(e, work.center)
    if #network == 0 then work.done, work.why = true, "there's no power network to connect to"; return end
    local poles = {}
    for _, pole in ipairs(network) do poles[#poles + 1] = pole.position end
    local avoid = {work.inner}
    for _, k in ipairs(keep) do avoid[#avoid + 1] = k end
    for _, k in ipairs(work.taken) do avoid[#avoid + 1] = k end
    for _, k in ipairs(bus.corridor(best.frame)) do avoid[#avoid + 1] = k end
    for _, l in ipairs(lines) do
      for _, b in ipairs(l.field.belts) do avoid[#avoid + 1] = tile_box(b.position, 0.5) end
      for _, b in ipairs(routes[l.ore]) do avoid[#avoid + 1] = tile_box(b.position, 0.5) end
    end
    local places = {}
    local function connect(to)
      local from, d
      for _, p in ipairs(poles) do
        local pd = util.distance(p, to)
        if not d or pd < d then from, d = p, pd end
      end
      local line = cells.pole_line(e, from, to, wire, avoid)
      if not line then return false end
      for _, p in ipairs(line) do
        places[#places + 1] = {POLE, {position = p}}
        poles[#poles + 1] = p
        avoid[#avoid + 1] = tile_box(p, 0.5)
      end
      return true
    end
    -- (To whichever of the area's poles is nearest the network, tried nearest first: a line only runs
    -- straight or round one corner, so one to a pole on the far side of the area finds no way.)
    local targets = {}
    for _, pl in ipairs(best.places) do
      if pl[1] == POLE then
        local d
        for _, p in ipairs(poles) do d = math.min(d or math.huge, util.distance(p, pl[2].position)) end
        targets[#targets + 1] = {p = pl[2].position, d = d}
      end
    end
    table.sort(targets, function(a, b) return a.d < b.d end)
    local joined = false
    for i = 1, math.min(#targets, 6) do
      if connect(targets[i].p) then joined = true; break end
    end
    if not joined then next_try(work, "no pole line from the power network to the smelting area"); return end
    for _, pl in ipairs(best.places) do
      if pl[1] == POLE then poles[#poles + 1] = pl[2].position end
    end
    for _, l in ipairs(lines) do
      if not connect(l.field.poles[1]) then next_try(work, "no pole line from the power network to the " .. l.ore .. " field"); return end
      for _, p in ipairs(l.field.poles) do poles[#poles + 1] = p end
    end
    -- In order: poles to the smelting area, the area, then each field and its belt.
    local parts = {}
    for _, pl in ipairs(best.places) do
      places[#places + 1] = pl
      if pl[1] == FURNACE or pl[1] == CHEST then parts[key_of(pl[2].position)] = prototypes.item[pl[1]].place_result.name end
    end
    for _, l in ipairs(lines) do
      for _, p in ipairs(l.field.poles) do places[#places + 1] = {POLE, {position = p}} end
      for _, d in ipairs(l.field.drills) do
        places[#places + 1] = {EDRILL, {position = d.position, direction = d.direction}}
        parts[key_of(d.position)] = EDRILL
      end
      for _, b in ipairs(l.field.belts) do places[#places + 1] = {BELT, b} end
      for _, b in ipairs(routes[l.ore]) do places[#places + 1] = {b.item or BELT, b} end
    end
    -- What was built while it was planned (a step at a time) may be in the way now: then it's planned again
    -- (work.stale). The engineer's removable buildings don't count: they're moved when building (clear_way).
    for _, pl in ipairs(places) do
      if not can_place(e.surface, e.force, prototypes.item[pl[1]].place_result.name, pl[2].position, pl[2].direction, work.removable) then
        work.done, work.stale = true, true
        work.why = "something got built where a " .. pl[1] .. " goes (" .. serpent.line(util.pos(pl[2].position)) .. ") while they were planned"
        return
      end
    end
    local fields = {}
    for _, l in ipairs(lines) do fields[l.ore] = l.field.line end
    work.done, work.plan = true, {places = places, parts = parts, chests = best.chests, site = {x = best.x0, y = best.y0}, box = best.box,
      frame = best.frame, layout = best.layout, fields = fields}
  end

  local STEPS = {fields = field_step, sites = sites_step, routes = routes_step, poles = poles_step}

  -- Starts planning the ore lines: where each field is and what to keep clear. Returns the work.
  lines_plan = function(rec, w)
    local s, e = state(rec), rec.entity
    local surface = e.surface
    local work = {stage = "fields", i = 1, steps = 0}
    local bases = util.enemy_bases(surface, s.home, 256 + util.NEST_CLEARANCE)
    local lines = {}
    for _, l in ipairs(ORE_LINES) do lines[#lines + 1] = {ore = l.ore, drills = l.drills} end
    lines[#lines + 1] = {ore = "coal", drills = LINE_COAL_DRILLS}
    local center = {x = 0, y = 0}
    for _, l in ipairs(lines) do
      local first = l.ore ~= "coal" and w.first["pair:" .. l.ore]
      local anchor = first and first.position
      if not anchor then
        local ore = jobs.nearest(surface, {l.ore}, s.home, nil, 256, bases)
        if not ore then
          work.done, work.why = true, "there's no " .. l.ore .. " within 256 tiles that's safe from enemy nests"
          return work
        end
        anchor = ore.position
      end
      l.anchor = {x = anchor.x, y = anchor.y}
      center.x, center.y = center.x + anchor.x / #lines, center.y + anchor.y / #lines
    end
    local keep = {}
    if s.plant and s.plant.room then keep[#keep + 1] = power.growth_area(s.plant) end
    for _, goal in ipairs(goals.list(rec.owner)) do
      if goal.block and goal.status ~= "CANCELLED" then keep[#keep + 1] = goal.block.area end
    end
    for _, pl in ipairs(s.science_spot and s.science_spot.places or {}) do keep[#keep + 1] = tile_box(pl[2].position, 2.5) end
    local nest = rec.pollution and rec.pollution.nearest
    work.lines, work.center, work.keep, work.nest = lines, center, keep, nest and {x = nest.x, y = nest.y}
    work.reserved, work.taken, work.sites, work.site_count = {}, {}, {}, 0
    work.ug = unlocked(e.force, {"underground-belt"})
    -- What can be moved out of their way: the iron and copper drill/furnace pairs (burner and electric; the
    -- ore lines replace them, and they aren't rebuilt once lines are planned), the coal loops once the coal
    -- belt runs, and the engineer's poles (a bypass pole goes in first, clear_way). Not the stone drill,
    -- belts or anything else the base runs on.
    local removable = {}
    for _, pole in ipairs(w.poles) do removable[pole.unit_number] = true end
    for _, list in ipairs({w.burner_pairs, w.electric_pairs}) do
      for _, pair in ipairs(list) do
        if pair.furnace and (pair.ore == "iron-ore" or pair.ore == "copper-ore") then
          removable[pair.drill.unit_number] = true
          if pair.furnace.valid and pair.furnace.unit_number then removable[pair.furnace.unit_number] = true end
        end
      end
    end
    for _, drill in ipairs(w.count.coal_belt and w.loop_drills or {}) do removable[drill.unit_number] = true end
    work.removable = removable
    return work
  end

  -- One step of the ore lines' planning (s.lines_work), if it's under way.
  function M.lines_step(rec)
    local work = state(rec).lines_work
    if not work or work.done then return end
    local stage = work.stage
    local prof = helpers.create_profiler()
    local ok, err = pcall(STEPS[stage], rec.entity, work)
    prof.stop()
    work.steps = work.steps + 1
    if not ok then work.done, work.why = true, "planning failed: " .. tostring(err) end
    log({"", "AI engineer: ore lines, ", stage, " step: ", prof})
  end
end
M.lines_plan = lines_plan -- (for planning on a saved game in tests)
M.smelter_layout = smelter_layout -- (for test:smelter)
M.survey = survey

-- Growing the smelting area with demand (the owner's stage 4: "expansion needs to be as easy as
-- possible"). Every EVERY ticks each column's furnaces are looked at (M.smelting_sample); over SAMPLES of
-- those, a column busy nearly all the time with nothing backing up (its plates taken as fast as they're
-- made) gets two more furnaces: the layout laid out again two longer, into its growth rows, and what's
-- new built. A column short of ore gets another drill. Each field keeps the drills its column needs (and
-- coal enough for every furnace), its line made longer upstream two drills at a time (a pole each and
-- four more belts); drills on ore that ran out come out. Plans from before don't grow (no `layout`).
-- (In a block: this file is at Lua's limit of local names.)
do
  local EVERY, SAMPLES = 600, 30 -- every 10 seconds, decided over 5 minutes
  local BUSY, STARVED, BACKED_UP = 0.85, 0.3, 0.1
  local FIELD_RETRY = 5 * 60 * 60
  local S = defines.entity_status
  local ORES = {"iron-ore", "copper-ore"}

  -- The column (by its ore) a smelting area furnace at p is in.
  local function column_of(plan, p)
    local a, b = "iron-ore", "copper-ore"
    if plan.layout.flip then a, b = b, a end
    return bus.where(plan.frame, p) < (plan.frame.hook or 16) and a or b
  end

  -- Per second: ore a drill mines, plates a furnace makes, coal a furnace burns.
  local function drill_rate(ore)
    return prototypes.entity[EDRILL].mining_speed / prototypes.entity[ore].mineable_properties.mining_time
  end
  local function plate_rate(ore)
    local plate = ore == "iron-ore" and "iron-plate" or "copper-plate"
    return prototypes.entity[FURNACE].get_crafting_speed() / prototypes.recipe[plate].energy
  end
  local function coal_rate()
    return prototypes.entity[FURNACE].get_max_energy_usage() * 60 / prototypes.item.coal.fuel_value
  end

  -- The drills a field needs for its column (coal: for every furnace, with half again to spare). (A
  -- column has its furnaces in pairs: 3 is 4.)
  local function needed(plan, ore)
    local L = plan.layout
    local function built(n) return 2 * math.ceil(n / 2) end
    if ore == "coal" then
      return math.max(LINE_COAL_DRILLS, math.ceil(1.5 * (built(L.n_iron) + built(L.n_copper)) * coal_rate() / drill_rate("coal")))
    end
    return math.ceil(built(ore == "iron-ore" and L.n_iron or L.n_copper) * plate_rate(ore) / drill_rate(ore))
  end

  -- The ore lines' drills still mining, by ore, and those whose ore ran out.
  local function line_drills(rec, plan)
    local have, dry = {}, {}
    for _, d in pairs(rec.built or {}) do
      if d.valid and d.name == EDRILL and plan.parts[key_of(d.position)] == EDRILL then
        if d.status == S.no_minable_resources then
          dry[#dry + 1] = d
        else
          local ore = ore_under(d)
          if ore then have[ore] = (have[ore] or 0) + 1 end
        end
      end
    end
    return have, dry
  end

  -- The belt a field's drills feed, followed downstream through underground belts to the first splitter
  -- (the trunk): each plain belt's {position, direction 0-3}, for drills beside it where it still runs over
  -- the ore (a field at the ore's edge, its route leaving across the rest of it).
  local function line_belts(rec, plan, ore)
    local b
    for _, d in pairs(rec.built or {}) do
      if d.valid and d.name == EDRILL and plan.parts[key_of(d.position)] == EDRILL and ore_under(d) == ore then
        b = d.surface.find_entities_filtered{position = d.drop_position, radius = 0.3, type = "transport-belt"}[1]
        if b then break end
      end
    end
    local out, seen = {}, {}
    while b and b.type ~= "splitter" and not seen[b.unit_number] and table_size(seen) < 200 do
      seen[b.unit_number] = true
      if b.type == "transport-belt" then out[#out + 1] = {position = b.position, direction = b.direction / 4} end
      if b.type == "underground-belt" and b.belt_to_ground_type == "input" then b = b.underground_belt_neighbour
      else b = b.belt_neighbours.outputs[1] end
    end
    return out
  end

  -- A field's line one step longer upstream (where its belt starts): a drill either side that fits, each
  -- with its pole, and the four belts past them. The places and the step, or nil.
  local function field_more(e, line, ore)
    local k = line.fwd > 0 and line.kmin - 1 or line.kmax + 1
    local al, ac = line.along, line.across
    local function at(t, side) return {x = line.bx + t * al[1] + side * ac[1] + 0.5, y = line.by + t * al[2] + side * ac[2] + 0.5} end
    local v = prototypes.entity[EDRILL].vector_to_place_result or {0, -2.3}
    local front = at(4 * k, 0)
    local places = {}
    for _, sgn in ipairs({-1, 1}) do
      local c = at(4 * k, 2 * sgn)
      local dir = dir_index({-sgn * ac[1], -sgn * ac[2]})
      local vx, vy = rotate(v, dir)
      local pole = {x = c.x + 2 * al[1], y = c.y + 2 * al[2]}
      if math.floor(c.x + vx) == math.floor(front.x) and math.floor(c.y + vy) == math.floor(front.y)
          and edrill_fits(e, ore, c, dir) and can_place(e.surface, e.force, POLE, pole, NORTH) then
        places[#places + 1] = {POLE, {position = pole}}
        places[#places + 1] = {EDRILL, {position = c, direction = dir}}
      end
    end
    if #places == 0 then return nil end
    local dir = dir_index({line.fwd * al[1], line.fwd * al[2]})
    local t0 = line.fwd > 0 and 4 * k - 1 or 4 * k + 1
    for i = 0, 3 do
      local p = at(t0 + line.fwd * i, 0)
      if not can_place(e.surface, e.force, BELT, p, dir) then return nil end
      places[#places + 1] = {BELT, {position = p, direction = dir}}
    end
    return places, k
  end

  -- The smelting area laid out again with `ore`'s column two furnaces longer: what's new (all of it
  -- placeable), the new furnace counts; nil if that won't fit in its growth rows or something's in the way.
  local function column_more(e, plan, ore)
    local L = plan.layout
    -- (Counted as built: in pairs.)
    local n_iron = 2 * math.ceil(L.n_iron / 2) + (ore == "iron-ore" and 2 or 0)
    local n_copper = 2 * math.ceil(L.n_copper / 2) + (ore == "copper-ore" and 2 or 0)
    local places, _, _, _, _, _, _, last = smelter_layout(L.x0, L.y0, n_iron, n_copper, L.flip, L.m)
    if last > L.room then return nil end
    local new = {}
    for _, pl in ipairs(places) do
      local name = prototypes.item[pl[1]].place_result.name
      if not present(e.surface, name, pl[2].position) then
        if not can_place(e.surface, e.force, name, pl[2].position, pl[2].direction or NORTH) then return nil end
        new[#new + 1] = pl
      end
    end
    return new, n_iron, n_copper
  end

  function M.smelting_sample(rec)
    local s = state(rec)
    local plan = s.ore_plan
    if not (plan and plan.done and plan.layout) or s.growing or game.tick < (s.grow_sample_at or 0) then return end
    s.grow_sample_at = game.tick + EVERY
    local g = s.grow_samples or {samples = 0}
    s.grow_samples = g
    for _, ore in ipairs(ORES) do g[ore] = g[ore] or {n = 0, working = 0, starved = 0, full = 0} end
    for _, f in pairs(rec.built or {}) do
      if f.valid and f.type == "furnace" and plan.parts[key_of(f.position)] == f.name then
        local c, st = g[column_of(plan, f.position)], f.status
        c.n = c.n + 1
        if st == S.working then c.working = c.working + 1
        elseif st == S.no_ingredients then c.starved = c.starved + 1
        elseif st == S.full_output then c.full = c.full + 1 end
      end
    end
    g.samples = g.samples + 1
  end

  -- What to grow next, or nil.
  local function next_growth(rec, s, plan, have)
    local e = rec.entity
    -- Ore first: each field the drills its column needs (more since the column grew, or one ran dry).
    -- (A field that can't get a drill is tried again every FIELD_RETRY: drills run dry, things move.)
    s.field_retry_at = s.field_retry_at or {}
    for _, ore in ipairs({"iron-ore", "copper-ore", "coal"}) do
      local line = plan.fields[ore]
      if line and game.tick >= (s.field_retry_at[ore] or 0) and (have[ore] or 0) < needed(plan, ore) + (s.want_drills[ore] or 0) then
        local places, k = field_more(e, line, ore)
        if places then
          return {kind = "field", ore = ore, k = k, places = places, describe = "making the " .. ore .. " line longer: more drills"}
        end
        -- Else beside its belt further down, where that still runs over the ore.
        local spot = M.belt_drill_spot(e, line_belts(rec, plan, ore), ore, s.plant and s.plant.room)
        if spot then
          places = {}
          for _, p in ipairs(spot.line) do places[#places + 1] = {POLE, {position = p}} end
          if spot.pole then places[#places + 1] = {POLE, {position = spot.pole}} end
          places[#places + 1] = {EDRILL, {position = spot.drill, direction = spot.dir}}
          return {kind = "beside", ore = ore, places = places, describe = "adding a drill beside the " .. ore .. " line's belt, where it crosses the " .. ore}
        end
        s.field_retry_at[ore] = game.tick + FIELD_RETRY
        if not s.grow_blocked[ore] then
          s.grow_blocked[ore] = true
          tell(rec, "The " .. ore .. " line to the smelting area has no room for more drills (its ore ends there, or something's in the way): more "
            .. ore .. " needs a new field. Trying again every few minutes.")
        end
      end
    end
    local g = s.grow_samples
    if not g or g.samples < SAMPLES then return nil end
    s.grow_samples = nil
    for _, ore in ipairs(ORES) do
      local c = g[ore]
      if c and c.n > 0 and c.full / c.n <= BACKED_UP then
        if c.working / c.n >= BUSY and not s.grow_blocked[ore] and not s.grow_blocked["column:" .. ore] then
          local places, n_iron, n_copper = column_more(e, plan, ore)
          if places then
            return {kind = "column", ore = ore, n_iron = n_iron, n_copper = n_copper, places = places,
              describe = "adding two furnaces to the " .. ore .. " column: its plates are used as fast as they're made"}
          end
          s.grow_blocked["column:" .. ore] = true
          tell(rec, "The " .. ore .. " smelting column is as long as its room allows: more plates need another column.")
        elseif c.starved / c.n >= STARVED then
          -- Short of ore with the drills it should need (thin ore, say): one more.
          s.want_drills[ore] = (s.want_drills[ore] or 0) + 1
        end
      end
    end
    return nil
  end

  -- The next job growing the smelting area, or nil (and why it waits).
  function M.grow_smelting(rec, w, limited)
    local s, e = state(rec), rec.entity
    local plan = s.ore_plan
    if not (plan and plan.done and plan.layout and plan.fields) then return nil end
    s.grow_blocked, s.want_drills = s.grow_blocked or {}, s.want_drills or {}
    local have, dry = line_drills(rec, plan)
    -- (Their poles stay: the other drills' power runs through them.)
    if #dry > 0 then
      local steps = {}
      for i = 1, math.min(#dry, 10) do
        local x, y = xy(dry[i])
        steps[#steps + 1] = {action = "pick_up", x = x, y = y}
      end
      return {kind = "steps", args = {steps = steps}, describe = "picking up ore line drills whose ore ran out", fix = "grow_dry"}
    end
    if limited then return nil end
    -- Something that can't be built is given up on (and that field or column isn't grown again).
    if s.growing and (s.fails.grow or 0) >= MAX_FAILS then
      if s.growing.kind == "column" then s.grow_blocked["column:" .. s.growing.ore] = true
      else s.field_retry_at[s.growing.ore] = game.tick + 3 * FIELD_RETRY end
      tell(rec, "Gave up " .. s.growing.describe .. ".")
      s.growing, s.fails.grow = nil, nil
    end
    s.growing = s.growing or next_growth(rec, s, plan, have)
    local job = s.growing
    if not job then return nil end
    local load = power_load(e, s.home or e.position)
    if not load or load > MAX_LOAD then return nil, "growing the smelting area: waiting for spare power" end
    local action, waiting, steps = place_all(rec, w, job.places, nil, "smelting area")
    if not steps then return action, waiting end
    if #steps > 0 then
      local partial = #steps > 20
      while #steps > 20 do table.remove(steps) end
      return {kind = "steps", args = {steps = steps}, describe = job.describe, fix = "grow", partial = partial}
    end
    -- Built: the plan knows its new parts (survey counts them as the ore lines').
    for _, pl in ipairs(job.places) do
      if pl[1] == FURNACE or pl[1] == CHEST or pl[1] == EDRILL then plan.parts[key_of(pl[2].position)] = prototypes.item[pl[1]].place_result.name end
    end
    if job.kind == "column" then
      plan.layout.n_iron, plan.layout.n_copper = job.n_iron, job.n_copper
      tell(rec, "Added two furnaces to the " .. job.ore .. " smelting column (" .. (job.ore == "iron-ore" and job.n_iron or job.n_copper)
        .. " now): its plates were used as fast as they were made.")
    else
      local line = plan.fields[job.ore]
      if job.k then
        if job.k < line.kmin then line.kmin = job.k else line.kmax = job.k end
      end
      local added = 0
      for _, pl in ipairs(job.places) do if pl[1] == EDRILL then added = added + 1 end end
      tell(rec, (job.k and "Made the " .. job.ore .. " line longer: " or "Added a drill beside the " .. job.ore .. " line's belt: ")
        .. ((have[job.ore] or 0) + added) .. " drills on it now.")
    end
    -- (A longer column is looked at afresh; more drills don't change what the furnaces were doing.)
    if job.kind == "column" then s.grow_samples = nil end
    s.growing = nil
    -- And on to what's next (a column grown wants more drills).
    return M.grow_smelting(rec, w, limited)
  end
end

-- Builds the ore lines (stockpiling everything they need first, while the burner pairs keep making plates),
-- then, once ore reaches their furnaces, picks up the drill/furnace pairs on iron and copper.
local function ore_lines(rec, w, limited)
  local s, e = state(rec), rec.entity
  if (s.fails.ore_lines or 0) >= MAX_FAILS then return nil end
  -- (The trunk's branches take splitters and underground belts.)
  if not unlocked(e.force, {EDRILL, BELT, INSERTER, LONG, POLE, FURNACE, CHEST, "splitter", "underground-belt"}) then return nil end
  local plan = s.ore_plan
  if not plan then
    -- A layout that didn't fit is tried again every few minutes (the base changes, underground belts get
    -- researched), sooner once they are.
    if s.skipped.ore_lines then
      local ug = unlocked(e.force, {"underground-belt"})
      if game.tick < (s.lines_retry_at or 0) and not (ug and not s.lines_tried_ug) then return nil end
    end
    if limited then return nil end
    local load = power_load(e, s.home or e.position)
    if not load or load > MAX_LOAD then return nil, "ore lines: waiting for spare power" end
    -- (Planned a step at a time meanwhile, M.lines_step.)
    if not s.lines_work then s.lines_work = lines_plan(rec, w) end
    local work = s.lines_work
    if not work.done then return nil, "ore lines: planning the layout" end
    s.lines_work = nil
    log("AI engineer: ore lines planned in " .. work.steps .. " steps")
    -- Out of date by the time it was done: planned again (a few times) right away.
    if work.stale and (s.lines_replans or 0) < 3 then
      s.lines_replans = (s.lines_replans or 0) + 1
      log("AI engineer: ore lines planned again: " .. tostring(work.why))
      return nil, "ore lines: planning the layout"
    end
    s.lines_replans = nil
    local why
    plan, why = work.plan, work.why
    if not plan then
      -- (Said the first time and when the reason changes.)
      if s.lines_why ~= tostring(why) then
        tell(rec, "Can't lay out ore lines yet (" .. tostring(why) .. "): keeping the drill and furnace pairs, trying again in a few minutes.")
      end
      s.skipped.ore_lines, s.lines_why = true, tostring(why)
      s.lines_retry_at = game.tick + 5 * 3600
      s.lines_tried_ug = unlocked(e.force, {"underground-belt"})
      s.lines_failures = (s.lines_failures or 0) + 1
      return nil
    end
    s.skipped.ore_lines, s.lines_why = nil, nil
    s.ore_plan = plan
    tell(rec, "Setting up ore lines: electric drills putting iron, copper and coal on belts to a smelting area at "
      .. serpent.line(plan.site) .. ". Gathering what they need first.")
  end
  if not plan.done then
    if limited then return nil, "ore lines: holding back while pollution is near a nest" end
    local action, waiting, steps = place_all(rec, w, plan.places, nil, "ore lines")
    if not steps then return action, waiting end
    -- What of the engineer's is in a part's way is moved right before that part goes in (M.clear_way).
    steps = M.clear_way(rec, steps, plan.places)
    -- (Bypass poles and moved turrets are gathered too, or placing them would craft them on the spot.)
    local counts, order = {}, {}
    for _, step in ipairs(steps) do
      if step.action == "place" then
        if not counts[step.item] then counts[step.item] = 0; order[#order + 1] = step.item end
        counts[step.item] = counts[step.item] + 1
      end
    end
    local list = {}
    for _, item in ipairs(order) do list[#list + 1] = {item, counts[item]} end
    local got, got_why, busy = get_items(rec, w, list, "ore lines")
    if busy then return got, got_why end
    if #steps > 0 then
      local partial = #steps > 20
      while #steps > 20 do table.remove(steps) end
      return {kind = "steps", args = {steps = steps}, describe = "building the ore lines to the smelting area", fix = "ore_lines", partial = partial}
    end
    plan.done = true
    tell(rec, "The ore lines are built: iron, copper and coal come by belt to the smelting area, plates go into its chests.")
  end
  -- Once ore reaches the furnaces, the drill/furnace pairs on iron and copper come out.
  local running = false
  for _, f in ipairs(w.line_furnaces) do
    local src = f.get_inventory(defines.inventory.crafter_input)
    local out = f.get_output_inventory()
    if (src and not src.is_empty()) or (out and not out.is_empty()) then running = true; break end
  end
  if not running then return nil, "ore lines: waiting for ore to reach the furnaces" end
  local steps = {}
  local function out(pair)
    if #steps > 18 or not (pair.ore == "iron-ore" or pair.ore == "copper-ore") then return end
    local x, y = xy(pair.drill)
    steps[#steps + 1] = {action = "pick_up", x = x, y = y}
    if pair.furnace and pair.furnace.valid then
      local fx, fy = xy(pair.furnace)
      steps[#steps + 1] = {action = "pick_up", x = fx, y = fy}
    end
  end
  for _, pair in ipairs(w.burner_pairs) do out(pair) end
  for _, pair in ipairs(w.electric_pairs) do out(pair) end
  if #steps == 0 then return nil end
  return {kind = "steps", args = {steps = steps}, describe = "picking up the drill/furnace pairs: the ore lines make the plates now", fix = "ore_lines_cleanup"}
end
-- chest for stone) next to the goal's others, on a pole line from the network.
build_electric = function(rec, w, goal)
  local s, e = state(rec), rec.entity
  local load = power_load(e, s.home or e.position)
  if not load then return nil, "electric drills: waiting for power" end
  if load > MAX_LOAD then return nil, "electric drills: waiting for spare power (engines at " .. math.floor(load * 100) .. "%)" end
  local anchor = w.first[key(goal)]
  if not anchor then
    local bases = util.enemy_bases(e.surface, s.home, 256 + util.NEST_CLEARANCE)
    anchor = jobs.nearest(e.surface, {goal.ore}, s.home, nil, 256, bases)
    if not anchor then return nil, "there's no " .. goal.ore .. " within 256 tiles that's safe from enemy nests", true end
  end
  local plan = epair_spot(rec, w, {drill = anchor, ore = goal.ore, kind = goal.kind})
  if not plan then return nil, "there's no room for an electric drill on " .. goal.ore .. " near the others", true end
  local places = {}
  for _, p in ipairs(plan.line) do places[#places + 1] = {POLE, {position = p}} end
  places[#places + 1] = {POLE, {position = plan.pole}}
  places[#places + 1] = {EDRILL, {position = plan.drill, direction = SOUTH}}
  if plan.chest then places[#places + 1] = {CHEST, {position = plan.chest}}
  else places[#places + 1] = {FURNACE, {position = plan.furnace}} end
  local action, waiting, steps = place_all(rec, w, places, plan.furnace and {{"coal", 5}} or nil, goal.label)
  if not steps then return action, waiting end
  if plan.furnace then steps[#steps + 1] = {action = "insert", item = "coal", count = 5, x = plan.furnace.x, y = plan.furnace.y} end
  return {kind = "steps", args = {steps = steps}, describe = "building an electric " .. goal.label, goal = goal, spot = plan.drill}
end

---------------------------------------------------------------------------
-- More power: the plant grows into the room planned for it (power.plant). First a second engine on the
-- first boiler (a boiler makes steam for two), then rows further back, each a boiler (piped on from the
-- one before) and two engines, with a row of poles in the gap between rows powering the engines on both
-- sides. The new boilers are fueled by hand like the rest.

local UNIT = {[0] = {0, -1}, {1, 0}, {0, 1}, {-1, 0}}

local function snap(p) return {x = math.floor(p.x) + 0.5, y = math.floor(p.y) + 0.5} end

-- The area an entity takes at p facing dir (0-3); collision boxes are given facing north.
local function footprint(name, p, dir)
  local b = prototypes.entity[name].collision_box
  local l, t, r, bt = b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y
  if dir == EAST or dir == WEST then l, t, r, bt = t, l, bt, r end
  return {{p.x + l, p.y + t}, {p.x + r, p.y + bt}}
end

-- Whether a part fits: placeable once trees and rocks are chopped (placing does that), with someone standing
-- there not counting (placing steps aside; the engineer often stands right where it just built). Also
-- returns what's in the way: why, and the entities.
local function part_fits(surface, force, part)
  local name = prototypes.item[part[1]].place_result.name
  if can_place(surface, force, name, part[2], part[3] or NORTH) then return true end
  local passable = {}
  for _, t in ipairs(PASSABLE) do passable[t] = true end
  local names, blockers = {}, {}
  for _, other in ipairs(surface.find_entities_filtered{area = footprint(name, part[2], part[3] or NORTH)}) do
    if not passable[other.type] then
      names[#names + 1] = other.name .. " at " .. serpent.line(util.pos(other.position))
      blockers[#blockers + 1] = other
    end
  end
  return false, (#names > 0 and table.concat(names, ", ") or "terrain") .. " in the way of a " .. name .. " at " .. serpent.line(util.pos(part[2])), blockers
end

-- A spot for a pole of ours that's in the way, within 2 tiles of it, outside `avoid` (areas as
-- {{x1, y1}, {x2, y2}}): it still powers everything the old one did (or another pole does) and reaches
-- every pole the old one is wired to... or nil.
local function pole_swap(e, old, avoid)
  local surface, force = e.surface, e.force
  local proto = prototypes.entity[POLE]
  local reach, wire = proto.get_supply_area_distance(), wire_reach()
  local o = old.position
  local powered = {}
  for _, x in ipairs(surface.find_entities_filtered{area = {{o.x - reach, o.y - reach}, {o.x + reach, o.y + reach}}, force = force}) do
    if x ~= old and x.prototype.electric_energy_source_prototype and x.type ~= "electric-pole" then powered[#powered + 1] = x end
  end
  local others = {}
  for _, p in ipairs(surface.find_entities_filtered{type = "electric-pole", force = force, position = o, radius = wire + reach * 2}) do
    if p ~= old then others[#others + 1] = p end
  end
  local function inside(box, b)
    return box.left_top.x < b[2][1] and b[1][1] < box.right_bottom.x and box.left_top.y < b[2][2] and b[1][2] < box.right_bottom.y
  end
  local best, best_d
  for dx = -2, 2 do
    for dy = -2, 2 do
      local p = {x = o.x + dx, y = o.y + dy}
      local d = math.abs(dx) + math.abs(dy)
      local pbox = box_at(p, 0.5)
      local ok = d > 0 and (not best_d or d < best_d) and can_place(surface, force, POLE, p, NORTH)
      for _, a in ipairs(ok and avoid or {}) do if inside(pbox, a) then ok = false end end
      for _, x in ipairs(ok and powered or {}) do
        local covered = overlaps(box_at(p, reach), x.bounding_box)
        for _, q in ipairs(others) do
          if not covered and overlaps(box_at(q.position, reach), x.bounding_box) then covered = true end
        end
        if not covered then ok = false end
      end
      for _, q in ipairs(ok and others or {}) do
        if util.distance(q.position, o) <= wire and util.distance(q.position, p) > wire then ok = false end
      end
      if ok then best, best_d = p, d end
    end
  end
  return best
end

-- Place steps with what of the engineer's is in each part's way moved first, right before that part (so
-- drills and furnaces it replaces keep working till then): picked up, and a pole only after a bypass pole
-- that keeps powering what it did (pole_swap) is up, so nothing loses power; with no spot for one it's
-- picked up anyway. What the base runs on stays (the power plant, belts, inserters, assemblers, labs, the
-- radar), as does everything the owner built: those steps fail as before.
function M.clear_way(rec, steps, places)
  local e = rec.entity
  local surface = e.surface
  -- (The plan's own parts, built already, stay.)
  local own = {}
  for _, pl in ipairs(places) do own[prototypes.item[pl[1]].place_result.name .. "@" .. key_of(pl[2].position)] = true end
  local KEEP = {boiler = true, generator = true, ["offshore-pump"] = true, pipe = true, ["pipe-to-ground"] = true, lab = true,
    ["assembling-machine"] = true, radar = true, ["transport-belt"] = true, ["underground-belt"] = true, splitter = true, inserter = true}
  local function box_of(step)
    local name = prototypes.item[step.item].place_result.name
    return footprint(name, {x = step.x, y = step.y}, step.direction or NORTH), name
  end
  local avoid = {}
  for _, step in ipairs(steps) do
    if step.action == "place" then avoid[#avoid + 1] = box_of(step) end
  end
  local out, seen = {}, {}
  for _, step in ipairs(steps) do
    if step.action == "place" then
      -- (Whole tiles: the game snaps a part to the tile grid, so a pole planned on a tile's edge takes the
      -- tiles beside it.)
      local area, name = box_of(step)
      area = {{math.floor(area[1][1] + 0.05) + 0.05, math.floor(area[1][2] + 0.05) + 0.05},
        {math.ceil(area[2][1] - 0.05) - 0.05, math.ceil(area[2][2] - 0.05) - 0.05}}
      -- (No force filter: `invert` would turn that round too. rec.built says what's ours.)
      for _, other in ipairs(surface.find_entities_filtered{area = area, type = PASSABLE, invert = true}) do
        local id = other.unit_number
        local ours = id and (rec.built or {})[id] and not other.last_user
        if ours and not seen[id] and not KEEP[other.type] and not own[other.name .. "@" .. key_of(other.position)]
          and not (other.name == name and util.distance(other.position, step) < 0.1) then
          seen[id] = true
          if other.type == "electric-pole" then
            local to = pole_swap(e, other, avoid)
            local item = other.prototype.items_to_place_this and other.prototype.items_to_place_this[1]
            if to and item then
              out[#out + 1] = {action = "place", item = item.name, x = to.x, y = to.y}
              avoid[#avoid + 1] = {{to.x - 0.5, to.y - 0.5}, {to.x + 0.5, to.y + 0.5}}
            end
          elseif other.type == "ammo-turret" then
            -- A turret goes up again nearby first (the nearest spot clear of the plan); its ammo comes back
            -- with the pickup, and defend loads the new one from what's on hand.
            local o = other.position
            for _, d in ipairs(offsets()) do
              local to = {x = o.x + d[1], y = o.y + d[2]}
              local box = footprint(other.name, to, NORTH)
              local ok = (d[1] ~= 0 or d[2] ~= 0) and math.abs(d[1]) <= 8 and math.abs(d[2]) <= 8 and can_place(surface, e.force, other.name, to, NORTH)
              for _, a in ipairs(ok and avoid or {}) do
                if box[1][1] < a[2][1] and a[1][1] < box[2][1] and box[1][2] < a[2][2] and a[1][2] < box[2][2] then ok = false; break end
              end
              if ok then
                out[#out + 1] = {action = "place", item = other.name, x = to.x, y = to.y}
                avoid[#avoid + 1] = box
                break
              end
            end
          end
          out[#out + 1] = {action = "pick_up", x = other.position.x, y = other.position.y}
        end
      end
    end
    out[#out + 1] = step
  end
  return out
end

-- Positions in the plant's frame: a tiles further back from the water than the first boiler, c to its
-- engines' side.
local function plant_frame(plant)
  local pd = plant.offshore_pump.direction
  local back, side = UNIT[(pd + 2) % 4], UNIT[(pd + 3) % 4]
  local b = plant.boiler.position
  return function(a, c) return {x = b.x + a * back[1] + c * side[1], y = b.y + a * back[2] + c * side[2]} end, plant.boiler.direction
end

-- A boiler row `a` tiles back (pipes from the row at `prev`, water flowing through the boilers), its two
-- engines, and poles past it that power its engines and the next row's.
local function row_parts(at, turned, prev, a)
  local parts = {}
  for k = prev + 2, a - 2 do parts[#parts + 1] = {"pipe", snap(at(k, -0.5))} end
  parts[#parts + 1] = {"boiler", at(a, 0), turned}
  parts[#parts + 1] = {"steam-engine", at(a, 3.5), turned}
  parts[#parts + 1] = {"steam-engine", at(a, 8.5), turned}
  parts[#parts + 1] = {POLE, snap(at(a + 2, 3.5))}
  parts[#parts + 1] = {POLE, snap(at(a + 2, 8.5))}
  return parts
end

local MAX_ROW = 12 -- rows fit in the plan's room, 12 tiles back

-- Every boiler burns coal from the one coal belt: a row's boiler gets an inserter off it where the belt runs
-- past (belt, inserter, boiler in a line, as coal_line_plan lays it), with a pole beside it unless one
-- already reaches it. One yellow belt carries 15 coal a second, enough for about 30 boilers, far more than
-- the plant's room holds, so the plant never needs a second belt here.
-- `built`: only for a row whose boiler is already there (else the inserter would drop coal on the ground).
local function boiler_feed(e, at, a, built)
  local surface = e.surface
  local ins, belt = snap(at(a, -1.5)), snap(at(a, -2.5))
  if a == 0 or not surface.find_entities_filtered{type = "transport-belt", position = belt, radius = 0.3}[1] then return {} end
  if built and not surface.find_entities_filtered{type = "boiler", position = at(a, 0), radius = 0.6}[1] then return {} end
  local origin, out = at(0, 0), at(0, 1)
  local parts = {{INSERTER, ins, inserter_toward({out.x - origin.x, out.y - origin.y})}}
  local r = prototypes.entity[POLE].get_supply_area_distance() + 0.4
  if not surface.find_entities_filtered{type = "electric-pole", force = e.force, area = {{ins.x - r, ins.y - r}, {ins.x + r, ins.y + r}}}[1] then
    parts[2] = {POLE, snap(at(a + 2, -1.5))}
  end
  return parts
end

-- The parts still to build for the next growth step, or nil and why there's none. First a second engine on
-- the first boiler, then rows, each a few tiles further back where it fits (a belt or pole of the coal
-- line may be in the first spot).
local function power_parts(rec, s)
  local e = rec.entity
  local surface, force = e.surface, e.force
  local at, turned = plant_frame(s.plant)
  local function fed(parts, a)
    for _, part in ipairs(boiler_feed(e, at, a)) do parts[#parts + 1] = part end
    return parts
  end
  local function missing(parts)
    local out = {}
    for _, part in ipairs(parts) do
      if not present(surface, prototypes.item[part[1]].place_result.name, part[2]) then out[#out + 1] = part end
    end
    return out
  end
  -- Whether all parts fit; poles of ours in the way are moved (s.pole_moves), which counts as fitting.
  local function check(parts)
    local avoid = {}
    for _, part in ipairs(parts) do
      avoid[#avoid + 1] = footprint(prototypes.item[part[1]].place_result.name, part[2], part[3] or NORTH)
    end
    local moves = {}
    for _, part in ipairs(parts) do
      local ok, why, blockers = part_fits(surface, force, part)
      if not ok then
        if not blockers or #blockers == 0 then return false, why end
        for _, b in ipairs(blockers) do
          -- Only our own poles (the owner's are left alone).
          local ours = b.type == "electric-pole" and b.name == POLE and b.unit_number and (rec.built or {})[b.unit_number]
          local to = ours and pole_swap(e, b, avoid)
          if not to then return false, why end
          moves[#moves + 1] = {from = b.position, to = to}
          avoid[#avoid + 1] = {{to.x - 0.5, to.y - 0.5}, {to.x + 0.5, to.y + 0.5}}
        end
      end
    end
    s.pole_moves = #moves > 0 and moves or nil
    return true
  end
  local first = missing({{"steam-engine", at(0, 8.5), turned}, {POLE, snap(at(2, 3.5))}, {POLE, snap(at(2, 8.5))}})
  if #first > 0 then
    local ok, why = check(first)
    if ok then return first end
    return nil, why
  end
  s.plant.rows = s.plant.rows or {}
  local prev = 0
  for _, a in ipairs(s.plant.rows) do
    local todo = missing(fed(row_parts(at, turned, prev, a), a))
    if #todo > 0 then
      local ok, why = check(todo)
      if ok then return todo end
      return nil, why
    end
    prev = a
  end
  local why = "its room is full"
  for a = prev + 4, math.min(prev + 7, MAX_ROW) do
    local todo = missing(fed(row_parts(at, turned, prev, a), a))
    local ok, blocked = check(todo)
    if ok then
      table.insert(s.plant.rows, a)
      return todo
    end
    why = blocked
  end
  return nil, why
end

-- `limited`: pollution is near a nest, so only steam engines are added (a boiler's second engine), no
-- boilers, which burn coal and pollute.
local function more_power(rec, w, load, limited)
  local s, e = state(rec), rec.entity
  if load < GROW_LOAD or game.tick < (s.power_retry or 0) or (s.fails.power or 0) >= MAX_FAILS or not (s.plant and s.plant.room) or not w.engine then
    return nil
  end
  s.pole_moves = nil
  local parts, why = power_parts(rec, s)
  for _, part in ipairs(limited and parts or {}) do
    if part[1] == "boiler" then
      s.pole_moves = nil
      return nil
    end
  end
  if not parts or #parts == 0 then
    -- Tried again later: a belt or pole may move.
    tell(rec, "The power plant can't grow yet: " .. tostring(why) .. ".")
    s.power_retry = game.tick + 5 * 3600
    return nil
  end
  -- Our poles in the way move first: the new one goes up before the old one comes down, so nothing loses power.
  if s.pole_moves then
    local places = {}
    for _, m in ipairs(s.pole_moves) do places[#places + 1] = {POLE, {position = m.to}} end
    local action, waiting, steps = place_all(rec, w, places, nil, "moving a pole for the power plant")
    if not steps then return action, waiting end
    for _, m in ipairs(s.pole_moves) do steps[#steps + 1] = {action = "pick_up", x = m.from.x, y = m.from.y} end
    return {kind = "steps", args = {steps = steps}, describe = "moving a pole out of the power plant's way", fix = "power"}
  end
  local places = {}
  -- The step's first pole joins the network (the plant's own poles, or the line to the lab).
  for _, part in ipairs(parts) do
    if part[1] == POLE then
      local network = cells.network_poles(e, part[2])
      local line = network[1] and cells.pole_line(e, network[1].position, part[2], cells.wire_reach() - 0.5, {})
      for _, p in ipairs(line or {}) do places[#places + 1] = {POLE, {position = p}} end
      break
    end
  end
  local boiler
  for _, part in ipairs(parts) do
    places[#places + 1] = {part[1], {position = part[2], direction = part[3]}}
    if part[1] == "boiler" then boiler = part[2] end
  end
  local action, waiting, steps = place_all(rec, w, places, boiler and {{"coal", 20}} or nil, "more steam power")
  if not steps then return action, waiting end
  if boiler then steps[#steps + 1] = {action = "insert", item = "coal", count = 20, x = boiler.x, y = boiler.y} end
  return {kind = "steps", args = {steps = steps}, describe = "adding to the power plant (engines at " .. math.floor(load * 100) .. "%)",
    fix = "power", grow_power = true}
end

local function upgrade(rec, w)
  local s, e = state(rec), rec.entity
  local recipe = e.force.recipes[EDRILL]
  if not (recipe and recipe.enabled) or s.skipped.upgrade or #w.burner_pairs == 0 then return nil end
  local load = power_load(e, s.home or e.position)
  if not load then return nil end
  if load > MAX_LOAD then return nil, "electric drills: waiting for spare power (engines at " .. math.floor(load * 100) .. "%)" end
  s.upgrades = s.upgrades or {}
  for _, pair in ipairs(w.burner_pairs) do
    local unit = pair.drill.unit_number
    local fix = "upgrade:" .. unit
    -- A drill paused for pollution stays as it is (its electric replacement would run). Iron and copper
    -- get ore lines instead, unless those couldn't be laid out.
    local metal = pair.ore == "iron-ore" or pair.ore == "copper-ore"
    if ((metal and s.skipped.ore_lines) or pair.kind == "chest") and (s.fails[fix] or 0) < 2 and not pair.drill.disabled_by_script then
      -- Planned once per pair (kept while half built, so a build cut short carries on).
      local plan = s.upgrades[unit]
      if not (plan and (present(e.surface, EDRILL, plan.drill) or can_place(e.surface, e.force, EDRILL, plan.drill, SOUTH))) then
        plan = epair_spot(rec, w, pair)
        s.upgrades[unit] = plan
      end
      if plan then
        local places = {}
        for _, p in ipairs(plan.line) do places[#places + 1] = {POLE, {position = p}} end
        places[#places + 1] = {POLE, {position = plan.pole}}
        places[#places + 1] = {EDRILL, {position = plan.drill, direction = SOUTH}}
        if plan.chest then places[#places + 1] = {CHEST, {position = plan.chest}}
        else places[#places + 1] = {FURNACE, {position = plan.furnace}} end
        local action, waiting, steps = place_all(rec, w, places, plan.furnace and {{"coal", 5}} or nil, "electric drill on " .. pair.ore)
        if not steps then return action, waiting end
        if plan.furnace then steps[#steps + 1] = {action = "insert", item = "coal", count = 5, x = plan.furnace.x, y = plan.furnace.y} end
        local dx, dy = xy(pair.drill)
        steps[#steps + 1] = {action = "pick_up", x = dx, y = dy}
        local out = pair.furnace or pair.chest
        if out and out.valid then
          local fx, fy = xy(out)
          steps[#steps + 1] = {action = "pick_up", x = fx, y = fy}
        end
        return {kind = "steps", args = {steps = steps}, describe = "replacing a burner drill on " .. pair.ore .. " with an electric drill",
          fix = fix, upgrade = pair.ore}
      end
      s.fails[fix] = 2 -- no room for one near it: leave this pair
    end
  end
end

---------------------------------------------------------------------------
-- Every boiler on the coal belt: rows built before the belt get their inserter (boiler_feed), and the belt
-- gets an electric drill per boiler it feeds (a boiler burns about 0.45 coal a second at full load, an
-- electric drill mines 0.5), each beside the belt where it runs over coal, facing it, with a pole.

local BELT_DRILLS_PER_BOILER = 1

-- A spot for one more drill on `ore` onto a belt (`belts`: {position, direction 0-3}, in the order they flow),
-- nearest its start: beside a belt tile over the ore, else (with `extend`) beside the belt made up to that
-- many tiles longer, straight back from its start (it often starts at the ore's edge, with the field behind
-- it). {drill, dir, pole, line, belts (the new ones, furthest first)}, or nil. `removable`: the engineer's
-- things that count as clear (clear_way moves them first). (On M: this file is at Lua's limit of local names.)
function M.belt_drill_spot(e, belts, ore, room, extend, removable)
  local surface, force = e.surface, e.force
  local proto = prototypes.entity[EDRILL]
  local v = proto.vector_to_place_result or {0, -2.3}
  local reach, wire = prototypes.entity[POLE].get_supply_area_distance(), cells.wire_reach() - 0.5
  if not belts[1] then return nil end
  local on_belt = {}
  for _, b in ipairs(belts) do on_belt[math.floor(b.position.x) .. "," .. math.floor(b.position.y)] = true end
  local tiles = {}
  for _, b in ipairs(belts) do tiles[#tiles + 1] = {position = b.position, direction = b.direction, new = 0} end
  local first = belts[1]
  local back = SIDES[(first.direction + 2) % 4]
  local added = {}
  for j = 1, extend or 0 do
    local p = {x = first.position.x + j * back[1], y = first.position.y + j * back[2]}
    if (room and overlaps(box_at(p, 0.5), room)) or not can_place(surface, force, BELT, p, first.direction, removable) then break end
    added[j] = {position = p, direction = first.direction}
    on_belt[math.floor(p.x) .. "," .. math.floor(p.y)] = true
    tiles[#tiles + 1] = {position = p, direction = first.direction, new = j}
  end
  local function new_belts(n)
    local out = {}
    for j = n, 1, -1 do out[#out + 1] = added[j] end
    return out
  end
  local network = cells.network_poles(e, first.position)
  for _, b in ipairs(tiles) do
    local t = b.position
    for _, turn in ipairs({1, 3}) do
      local side = SIDES[(b.direction + turn) % 4]
      local dir = (b.direction + turn + 2) % 4
      local c = {x = t.x + 2 * side[1], y = t.y + 2 * side[2]}
      local vx, vy = rotate(v, dir)
      local counts = jobs.drill_resources(surface, proto, c)
      local drill_box = box_at(c, 1.5)
      if math.floor(c.x + vx) == math.floor(t.x) and math.floor(c.y + vy) == math.floor(t.y)
        and (counts[ore] or 0) >= MIN_COAL and table_size(counts) == 1 and not (room and overlaps(drill_box, room))
        -- (can_place allows a drill where one stands: it would only be turned.)
        and not present(surface, EDRILL, c) and can_place(surface, force, EDRILL, c, dir, removable) and owner_clear(surface, force, c) then
        local r = reach + 1.5
        for _, pole in ipairs(surface.find_entities_filtered{type = "electric-pole", force = force, area = {{c.x - r, c.y - r}, {c.x + r, c.y + r}}}) do
          -- (Not one that's moved out of the way.)
          if not (removable and removable[pole.unit_number]) then return {drill = c, dir = dir, line = {}, belts = new_belts(b.new)} end
        end
        for _, o in ipairs(offsets()) do
          if math.abs(o[1]) <= 3 and math.abs(o[2]) <= 3 then
            local p = {x = math.floor(c.x) + o[1] + 0.5, y = math.floor(c.y) + o[2] + 0.5}
            local pbox = box_at(p, 0.5)
            if not overlaps(pbox, drill_box) and overlaps(box_at(p, reach), drill_box) and not on_belt[math.floor(p.x) .. "," .. math.floor(p.y)]
              and not (room and overlaps(pbox, room)) and can_place(surface, force, POLE, p, NORTH) then
              local nearest = network[1]
              for _, pole in ipairs(network) do
                if util.distance(pole.position, p) < util.distance(nearest.position, p) then nearest = pole end
              end
              local line = nearest and cells.pole_line(e, nearest.position, p, wire, {room})
              if line then return {drill = c, dir = dir, pole = p, line = line, belts = new_belts(b.new)} end
            end
          end
        end
      end
    end
  end
end

-- `limited`: pollution is near a nest, so no more drills (inserters still go in).
local function feed_boilers(rec, w, limited)
  local s, e = state(rec), rec.entity
  if not (w.count.coal_belt and s.plant and s.plant.room and s.coal_line) or (s.fails.feed_boilers or 0) >= MAX_FAILS then return nil end
  local places = {}
  -- Boiler rows the belt runs past without an inserter off it.
  local at = plant_frame(s.plant)
  for _, a in ipairs(s.plant.rows or {}) do
    for _, part in ipairs(boiler_feed(e, at, a, true)) do
      if not present(e.surface, part[1], part[2]) then places[#places + 1] = {part[1], {position = part[2], direction = part[3]}} end
    end
  end
  local describe = "putting the boilers on the coal belt"
  -- Then a drill onto the belt per boiler it feeds.
  local wanted = math.max(2, math.ceil((w.belt_boilers or 0) * BELT_DRILLS_PER_BOILER))
  -- (The coal mine's drills, chests and poles count as clear: a longer belt over the coal replaces them.
  -- Tried again every 5 minutes: what's in the way may go.)
  local removable = {}
  for _, pole in ipairs(w.poles) do removable[pole.unit_number] = true end
  for _, part in ipairs(w.mine_parts or {}) do if part.unit_number then removable[part.unit_number] = true end end
  -- A drill planned before and now built: its belts are the coal belt's start now.
  local plan = s.belt_drill
  if plan and plan.belts and present(e.surface, EDRILL, plan.drill) then
    for i = #plan.belts, 1, -1 do table.insert(s.coal_line.belts, 1, plan.belts[i]) end
    plan.belts = nil
  end
  if #places == 0 and not limited and (w.belt_drills or 0) < wanted and game.tick >= (s.belt_drills_retry_at or 0) then
    if not (plan and (present(e.surface, EDRILL, plan.drill) or can_place(e.surface, e.force, EDRILL, plan.drill, plan.dir, removable))) then
      plan = M.belt_drill_spot(e, s.coal_line.belts, "coal", s.plant.room, 12, removable)
      if not plan then
        s.belt_drills_retry_at = game.tick + 5 * 60 * 60
        if not s.belt_drills_told then
          s.belt_drills_told = true
          tell(rec, "There's no room for more electric drills on the coal belt to the boilers: the coal mine fills chests for the boilers it can't keep up with.")
        end
        return nil
      end
      s.belt_drill = plan
    end
    for _, b in ipairs(plan.belts or {}) do places[#places + 1] = {BELT, b} end
    for _, p in ipairs(plan.line) do places[#places + 1] = {POLE, {position = p}} end
    if plan.pole then places[#places + 1] = {POLE, {position = plan.pole}} end
    places[#places + 1] = {EDRILL, {position = plan.drill, direction = plan.dir}}
    describe = (plan.belts and #plan.belts > 0 and "making the coal belt to the boilers longer over the coal, for another drill"
      or "adding an electric drill to the coal belt") .. " (" .. (w.belt_boilers or 0) .. " boilers on it)"
  end
  if #places == 0 then return nil end
  local action, waiting, steps = place_all(rec, w, places, nil, describe)
  if not steps then return action, waiting end
  if #steps == 0 then
    s.belt_drill = nil
    return nil
  end
  steps = M.clear_way(rec, steps, places)
  -- (Bypass poles are gathered too, as for the ore lines.)
  local counts, list = {}, {}
  for _, step in ipairs(steps) do
    if step.action == "place" then counts[step.item] = (counts[step.item] or 0) + 1 end
  end
  for item, n in pairs(counts) do list[#list + 1] = {item, n} end
  local got, got_why, busy = get_items(rec, w, list, describe)
  if busy then return got, got_why end
  while #steps > 20 do table.remove(steps) end
  return {kind = "steps", args = {steps = steps}, describe = describe, fix = "feed_boilers"}
end

---------------------------------------------------------------------------
-- The coal mine: electric drills on the coal, each filling a chest, on a pole line from the network. The
-- engineer carries coal from the chests to the boilers (get_coal takes from them first). Built when the
-- coal belt can't reach the boiler, and for the boilers the belt doesn't feed: two drills per boiler.

local MINE_DRILLS_PER_BOILER, MAX_MINE_DRILLS = 2, 8

-- A mine drill at p (its center) facing south into a chest, with a pole beside it.
local function mine_parts(p)
  local v = prototypes.entity[EDRILL].vector_to_place_result or {0, -2.3}
  local vx, vy = rotate(v, SOUTH)
  return {drill = p, chest = {x = math.floor(p.x + vx) + 0.5, y = math.floor(p.y + vy) + 0.5}, pole = {x = p.x + 2, y = p.y}}
end

local function mine_fits(surface, force, p)
  local parts = mine_parts(p)
  local counts = jobs.drill_resources(surface, prototypes.entity[EDRILL], p)
  local name, n = next(counts)
  return name == "coal" and next(counts, name) == nil and n >= 12 and can_place(surface, force, EDRILL, p, SOUTH)
    and can_place(surface, force, CHEST, parts.chest, NORTH) and can_place(surface, force, POLE, parts.pole, NORTH)
end

local function coal_mine(rec, w)
  local s, e = state(rec), rec.entity
  local recipe = e.force.recipes[EDRILL]
  if not (recipe and recipe.enabled) or s.skipped.coal_mine or (s.fails.coal_mine or 0) >= MAX_FAILS or not w.engine then return nil end
  local boilers = e.surface.count_entities_filtered{type = "boiler", force = e.force, position = s.home or e.position, radius = 256}
  -- Boilers the belt feeds and has drills enough for.
  local fed = math.min(w.belt_boilers or 0, math.floor((w.belt_drills or 0) / BELT_DRILLS_PER_BOILER))
  local wanted = math.min(MINE_DRILLS_PER_BOILER * math.max(boilers - fed, 0), MAX_MINE_DRILLS)
  if (w.mine_drills or 0) >= wanted then return nil end
  -- Next to the mine's last drill, else on the coal nearest home.
  local plan = s.mine_plan
  if not (plan and (present(e.surface, EDRILL, plan.drill) or mine_fits(e.surface, e.force, plan.drill))) or present(e.surface, EDRILL, plan.drill) then
    plan = nil
    local anchor = s.mine_anchor
    if not anchor then
      local bases = util.enemy_bases(e.surface, s.home or e.position, 256 + util.NEST_CLEARANCE)
      local coal = jobs.nearest(e.surface, {"coal"}, s.home or e.position, nil, 256, bases)
      if not coal then
        s.skipped.coal_mine = true
        tell(rec, "No coal within 256 tiles that's safe from nests: the boilers get coal from the loops only.")
        return nil
      end
      anchor = coal.position
    end
    local network = cells.network_poles(e, anchor)
    local wire = cells.wire_reach() - 0.5
    local ax, ay = math.floor(anchor.x), math.floor(anchor.y)
    for _, o in ipairs(offsets()) do
      local p = {x = ax + o[1] + 0.5, y = ay + o[2] + 0.5}
      if not s.skip[p.x .. "," .. p.y] and mine_fits(e.surface, e.force, p) and owner_clear(e.surface, e.force, p) then
        local parts = mine_parts(p)
        local nearest = network[1]
        for _, pole in ipairs(network) do
          if util.distance(pole.position, parts.pole) < util.distance(nearest.position, parts.pole) then nearest = pole end
        end
        parts.line = nearest and cells.pole_line(e, nearest.position, parts.pole, wire, {s.plant and s.plant.room})
        if parts.line then
          plan = parts
          break
        end
      end
    end
    if not plan then
      s.skipped.coal_mine = true
      tell(rec, "There's no room for electric drills on the coal near " .. serpent.line(util.pos(anchor)) .. " with power to them.")
      return nil
    end
    s.mine_plan, s.mine_anchor = plan, plan.drill
  end
  local places = {}
  for _, p in ipairs(plan.line) do places[#places + 1] = {POLE, {position = p}} end
  places[#places + 1] = {POLE, {position = plan.pole}}
  places[#places + 1] = {EDRILL, {position = plan.drill, direction = SOUTH}}
  places[#places + 1] = {CHEST, {position = plan.chest}}
  local action, waiting, steps = place_all(rec, w, places, nil, "coal mine")
  if not steps then return action, waiting end
  if #steps == 0 then
    s.mine_plan = nil
    return nil
  end
  local partial = #steps > 20
  while #steps > 20 do table.remove(steps) end
  return {kind = "steps", args = {steps = steps}, describe = "building an electric coal drill into a chest for the boilers",
    fix = "coal_mine", partial = partial, mine = true}
end

---------------------------------------------------------------------------
-- Defense: where biters destroy something of ours near the base (or kill the engineer), two gun turrets
-- go up, and every turret of ours is kept loaded. Before that, while pollution spreads toward a nest
-- (pollution.lua), turrets go up on that side and ammo is kept on hand.

local TURRET, AMMO = "gun-turret", "firearm-magazine"
local AMMO_LOW, AMMO_FILL, TURRET_COVER, ATTACK_MEMORY = 10, 25, 15, 60 * 60 * 60
-- New turrets go up as soon as they can, with this many magazines each; they're filled up afterwards, a
-- batch of magazines at a time, so making ammo never holds the turrets (or anything else) up for long.
local AMMO_START, AMMO_BATCH = 2, 10
-- Magazines carried while pollution nears a nest, for the turrets and the engineer's pistol.
local AMMO_RESERVE = 30
-- Turret spots for pollution that failed: left alone this long.
local GUARD_RETRY = 10 * 3600

-- control.lua calls this when biters destroy something of the player force.
function M.attacked(entity)
  for owner, rec in pairs(storage.engineers) do
    local s = rec.auto
    if s and rec.entity and rec.entity.valid and entity.force == rec.entity.force and entity.surface == rec.entity.surface
      and util.distance(entity.position, s.home or rec.entity.position) < 200 then
      s.attacks = s.attacks or {}
      for _, a in ipairs(s.attacks) do
        if util.distance(a.position, entity.position) < TURRET_COVER then a.tick = game.tick; return end
      end
      s.attacks[#s.attacks + 1] = {position = {x = entity.position.x, y = entity.position.y}, tick = game.tick}
      while #s.attacks > 10 do table.remove(s.attacks, 1) end
    end
  end
end

-- Two turret spots near `near`, off the tiles in `planned` ("x,y": the ore lines' parts not built yet).
local function turret_spot(e, near, planned)
  local cx, cy = math.floor(near.x), math.floor(near.y)
  local function free(p)
    for x = p.x - 1, p.x do
      for y = p.y - 1, p.y do if planned[x .. "," .. y] then return false end end
    end
    return can_place(e.surface, e.force, TURRET, p, NORTH)
  end
  for _, o in ipairs(offsets()) do
    if math.abs(o[1]) <= 8 and math.abs(o[2]) <= 8 then
      local a, b = {x = cx + o[1], y = cy + o[2]}, {x = cx + o[1] + 3, y = cy + o[2]}
      if free(a) and free(b) then return a, b end
    end
  end
end

-- The tiles of the ore lines' parts while they're still to be built ("x,y"). (On M: this file is at Lua's
-- limit of local names.)
function M.planned_tiles(s)
  local out = {}
  local plan = s.ore_plan
  for _, pl in ipairs(plan and not plan.done and plan.places or {}) do
    local box = footprint(prototypes.item[pl[1]].place_result.name, pl[2].position, pl[2].direction or NORTH)
    for x = math.floor(box[1][1] + 0.05), math.ceil(box[2][1] - 0.05) - 1 do
      for y = math.floor(box[1][2] + 0.05), math.ceil(box[2][2] - 0.05) - 1 do out[x .. "," .. y] = true end
    end
  end
  return out
end

-- Under attack, or pollution nearing a nest, without turrets: research them first (in labs; the build
-- order's lab may not be up yet). A switch, not a job, so it's done while the engineer is busy too. 2.0
-- keeps the progress of what was being researched.
local function turrets_first(rec)
  local s, e = state(rec), rec.entity
  local force = e.force
  local tech = force.technologies[TURRET]
  if not tech or tech.researched or (force.current_research and force.current_research.name == TURRET) then return end
  local threatened = pollution.threatened(rec, s.home or e.position)
  if not (threatened or (s.attacks and #s.attacks > 0)) then return end
  for _, pre in pairs(tech.prerequisites) do
    if not pre.researched then return end
  end
  local queue = {TURRET}
  for _, t in ipairs(force.research_queue or {}) do
    if t.name ~= TURRET then queue[#queue + 1] = t.name end
  end
  force.research_queue = queue
  -- (The queue drops what can't be researched, so this is said once.)
  if force.current_research and force.current_research.name == TURRET then
    tell(rec, "Researching gun turrets first: " .. (threatened and "pollution is nearing an enemy nest." or "biters attacked."))
  end
end

local function defend(rec, w)
  local s, e = state(rec), rec.entity
  local force = e.force
  local threatened, p = pollution.threatened(rec, s.home or e.position)
  -- Turrets that keep failing to go up (biters still there, no room): give up on those spots for now.
  if (s.fails.turrets or 0) >= MAX_FAILS then
    s.attacks, s.fails.turrets = nil, nil
    if threatened then s.guard_retry = game.tick + GUARD_RETRY end
  end
  local recipe = force.recipes[TURRET]
  if not (recipe and recipe.enabled) then
    -- Meanwhile ammo for the pistol.
    if threatened and e.get_item_count(AMMO) < AMMO_RESERVE then
      local action, waiting, busy = get_items(rec, w, {{AMMO, AMMO_RESERVE}}, "ammo")
      if busy then return action, waiting end
    end
    return nil
  end
  -- Two turrets with a few magazines each.
  local function turrets_at(a, b, describe, flag)
    local action, waiting, steps = place_all(rec, w, {{TURRET, {position = a}}, {TURRET, {position = b}}}, {{AMMO, 2 * AMMO_START}}, "turrets")
    if not steps then return action, waiting end
    steps[#steps + 1] = {action = "insert", item = AMMO, count = AMMO_START, x = a.x, y = a.y}
    steps[#steps + 1] = {action = "insert", item = AMMO, count = AMMO_START, x = b.x, y = b.y}
    local out = {kind = "steps", args = {steps = steps}, describe = describe, fix = "turrets"}
    out[flag] = true
    return out
  end
  -- Turrets where we were attacked.
  for i = #(s.attacks or {}), 1, -1 do
    local a = s.attacks[i]
    local covered = e.surface.count_entities_filtered{type = "ammo-turret", force = force, position = a.position, radius = TURRET_COVER} > 0
    if covered or game.tick - a.tick > ATTACK_MEMORY then
      table.remove(s.attacks, i)
    else
      local p, q = turret_spot(e, a.position, M.planned_tiles(s))
      if not p then
        table.remove(s.attacks, i)
      else
        return turrets_at(p, q, "putting up gun turrets where biters attacked", "turrets")
      end
    end
  end
  -- Pollution nearing a nest: turrets by our buildings on that side, before any attack.
  for _, guard in ipairs(threatened and game.tick >= (s.guard_retry or 0) and p.guards or {}) do
    local a, b
    if e.surface.count_entities_filtered{type = "ammo-turret", force = force, position = guard, radius = TURRET_COVER} == 0 then
      a, b = turret_spot(e, guard, M.planned_tiles(s))
    end
    if a then return turrets_at(a, b, "putting up gun turrets toward the nest pollution is spreading to", "guard_turrets") end
  end
  -- Then keep every turret loaded: what's on hand goes in first, and more is made a batch at a time.
  local todo, short, have = {}, 0, e.get_item_count(AMMO)
  for _, t in ipairs(w.turrets) do
    local n = t.get_item_count(AMMO)
    if n < AMMO_LOW then
      local want = AMMO_FILL - n
      local give = math.min(want, have)
      if give > 0 then
        todo[#todo + 1] = insert(t, AMMO, give)
        have = have - give
      end
      short = short + want - give
    end
  end
  if #todo > 0 then return route(rec, todo, "loading the gun turrets") end
  if short > 0 then
    local action, waiting, busy = get_items(rec, w, {{AMMO, math.min(short, AMMO_BATCH)}}, "turret ammo")
    if busy then return action, waiting end
  end
  if not threatened then return nil end
  -- And spare ammo on hand.
  if e.get_item_count(AMMO) < AMMO_RESERVE then
    local action, waiting, busy = get_items(rec, w, {{AMMO, AMMO_RESERVE}}, "spare ammo")
    if busy then return action, waiting end
  end
end

---------------------------------------------------------------------------
-- A radar once one can be made: in the middle of the base, by the power pole nearest the middle (outside
-- the power plant's growth and the goals' columns), so the map around the base keeps being revealed.

local RADAR = "radar"
local function radar(rec, w)
  local s, e = state(rec), rec.entity
  local recipe = e.force.recipes[RADAR]
  if not (recipe and recipe.enabled) or s.skipped.radar or (s.fails.radar or 0) >= MAX_FAILS then return nil end
  for _, entity in pairs(rec.built or {}) do
    if entity.valid and entity.type == "radar" then return nil end
  end
  local spot = s.radar_spot
  if not (spot and (present(e.surface, RADAR, spot) or can_place(e.surface, e.force, RADAR, spot, NORTH))) then
    spot = nil
    local sx, sy, n = 0, 0, 0
    for _, entity in pairs(rec.built or {}) do
      if entity.valid then sx, sy, n = sx + entity.position.x, sy + entity.position.y, n + 1 end
    end
    if n == 0 then return nil end
    local middle = {x = sx / n, y = sy / n}
    local keep = planned_areas(s)
    if s.plant and s.plant.room then keep[#keep + 1] = power.growth_area(s.plant) end
    for _, goal in ipairs(goals.list(rec.owner)) do
      if goal.block and goal.status ~= "CANCELLED" then keep[#keep + 1] = goal.block.area end
    end
    local reach = prototypes.entity[POLE].get_supply_area_distance()
    for _, pole in ipairs(cells.network_poles(e, middle)) do
      local c = pole.position
      for _, o in ipairs(offsets()) do
        if math.abs(o[1]) <= 4 and math.abs(o[2]) <= 4 then
          local p = {x = math.floor(c.x) + o[1] + 0.5, y = math.floor(c.y) + o[2] + 0.5}
          local box = box_at(p, 1.5)
          local ok = overlaps(box, box_at(c, reach)) and can_place(e.surface, e.force, RADAR, p, NORTH)
          for _, k in ipairs(ok and keep or {}) do
            if overlaps(box, k) then ok = false end
          end
          if ok then spot = p; break end
        end
      end
      if spot then break end
    end
    if not spot then
      s.skipped.radar = true
      tell(rec, "There's no room for a radar by a power pole in the middle of the base.")
      return nil
    end
    s.radar_spot = spot
  end
  local action, waiting, steps = place_all(rec, w, {{RADAR, {position = spot}}}, nil, "radar")
  if not steps then return action, waiting end
  if #steps == 0 then
    s.radar_spot = nil
    return nil
  end
  return {kind = "steps", args = {steps = steps}, describe = "putting up a radar in the middle of the base", fix = "radar"}
end

---------------------------------------------------------------------------
-- Scouting: with no nest known and the pollution cloud nearing the edge of the revealed map, walk to that
-- edge (the engineer reveals the map around it as it goes, `run`), so the cloud can grow once there's
-- nothing there, or the nest that is gets watched.

local SIGHT = 64
local function scout(rec)
  -- A chunk is scouted at most SCOUT_TRIES times; trips go at most every SCOUT_EVERY ticks (unless the
  -- cloud is already held back at the edge), and are announced at most every SCOUT_TELL_EVERY. (Not at the
  -- top: this file is at Lua's limit of local names.)
  local SCOUT_TRIES, SCOUT_EVERY, SCOUT_TELL_EVERY = 2, 2 * 3600, 10 * 3600
  local s, e = state(rec), rec.entity
  local target = pollution.scout(rec, s.home or e.position)
  if not target then return nil end
  local urgent = rec.pollution and rec.pollution.edge_level == "reduce"
  if not urgent and s.scouted_at and game.tick < s.scouted_at + SCOUT_EVERY then return nil end
  s.scouted = s.scouted or {}
  local k = math.floor(target.x / 32) .. "," .. math.floor(target.y / 32)
  if (s.scouted[k] or 0) >= SCOUT_TRIES then return nil end
  s.scouted[k] = (s.scouted[k] or 0) + 1
  s.scouted_at = game.tick
  -- Stopping a chunk short of it reveals it.
  local d = util.distance(e.position, target)
  local stop = math.max(0, d - 32) / math.max(d, 1)
  local to = {x = e.position.x + (target.x - e.position.x) * stop, y = e.position.y + (target.y - e.position.y) * stop}
  if game.tick >= (s.scout_told_at or -SCOUT_TELL_EVERY) + SCOUT_TELL_EVERY then
    s.scout_told_at = game.tick
    tell(rec, "No enemy nest is known and the pollution is nearing the edge of the revealed map: scouting it.")
  end
  return {kind = "walk", args = {x = to.x, y = to.y}, describe = "scouting the edge of the map the pollution is spreading toward"}
end

-- What cells.lua uses to work on goals.
local H = {state = state, tell = tell, offsets = offsets, get_items = get_items, route = route, insert = insert, take = take,
  place_all = place_all, craft = craft, steam = steam, powered_lab = powered_lab, feed_science = feed_science,
  planned_areas = planned_areas}

-- Science packs keep-busy automates by itself once the build order is done, per minute.
local AUTO_RATE = 10

-- The next job for goals from `origin`, or nil and what the first of them waits for.
local function goal_work(rec, w, origin, keep_busy)
  local why
  for _, goal in ipairs(goals.runnable(rec, keep_busy)) do
    if goal.origin == origin then
      local action, waiting = cells.decide(rec, w, goal, H)
      if action then return action end
      why = why or waiting
    end
  end
  return nil, why
end

-- After the build order: keep-busy picks the next science pack to automate (nothing while one is under way).
local function autonomous(rec, w)
  local s = state(rec)
  local on_bus = bus.geometry(s.ore_plan) ~= nil and unlocked(rec.entity.force, bus.ITEMS)
  -- Hand-fed machines don't scale: past the first, goals wait for the bus while it's still to come (ore
  -- lines planned or still being retried, for half an hour at most).
  local wait = not on_bus and (s.fails.ore_lines or 0) < MAX_FAILS and (s.lines_failures or 0) < 6
  local item, for_bus, again = goals.next_autonomous(rec, on_bus, wait)
  if again then tell(rec, "Trying the " .. again.item .. " machines again (" .. again.retries .. " of 3).") end
  if for_bus then
    local action, why = goal_work(rec, w, "AUTONOMOUS", true)
    return action, why or "waiting for the main bus before automating more (machines fed by hand don't keep up)"
  end
  if item then
    local ok, goal
    if item == "mall" then ok, goal = pcall(goals.add_mall, rec, "AUTONOMOUS")
    else ok, goal = pcall(goals.add, rec, item, AUTO_RATE, "AUTONOMOUS") end
    if ok and goal.status == "ACTIVE" then tell(rec, "Next: automating " .. item .. " (" .. AUTO_RATE .. "/min).")
    elseif ok then tell(rec, "Can't automate " .. item .. " yet: " .. tostring(goal.reason) .. ".") end
  end
  return goal_work(rec, w, "AUTONOMOUS", true)
end

-- The next job, or nil and what it's waiting for. With keep-busy off it only works on the owner's goals.
local function decide(rec, w, keep_busy)
  local s, e = state(rec), rec.entity
  local action = maintenance(rec, w) or (keep_busy and (defend(rec, w) or scout(rec) or repair(rec, w)) or nil)
  if action then return action end
  -- A nearly full inventory can't take what jobs pick up or craft: what isn't needed goes into storage,
  -- kept out of the room planned for other things.
  if keep_busy then
    local avoid = planned_areas(s)
    if s.plant and s.plant.room then avoid[#avoid + 1] = power.growth_area(s.plant) end
    for _, goal in ipairs(goals.list(rec.owner)) do
      if goal.block and goal.block.area then avoid[#avoid + 1] = goal.block.area end
    end
    action = stash.decide(rec, w, H, avoid)
    if action then return action end
  end
  -- With the bus up, what was built before it (fed by hand) moves onto it, before anything new.
  if bus.geometry(s.ore_plan) ~= nil and unlocked(e.force, bus.ITEMS) then
    action = cells.move_to_bus(rec, w, H, keep_busy)
    if action then return action end
  end
  -- The owner's goals come first; while they wait for something, the build order carries on.
  local why_player
  action, why_player = goal_work(rec, w, "PLAYER", keep_busy)
  if action then return action end
  -- An order of the owner's waiting for drills (more than is hand-mined): its early base comes next.
  if rec.starter then
    local why_starter
    action, why_starter = M.starter(rec, w)
    if action or why_starter then return action, why_starter end
  end
  if not keep_busy then return nil, why_player end
  -- While pollution is held back from nests: no new drills, boilers or production (the owner's goals still run).
  local limited = pollution.limited(rec, s.home or e.position)
  local goal = next_goal(rec, w, limited)
  local why, stuck, done
  if goal then
    action, why, stuck = build(rec, w, goal)
    if stuck then
      s.skipped[id(goal)] = true
      tell(rec, "Skipping the " .. goal.label .. ": " .. why .. ".")
    end
  end
  -- Once the coal belt runs, a drill waiting (for power, say) doesn't hold up the rest, which may be what
  -- it's waiting for.
  if not goal or (not action and w.count.coal_belt) then
    action, why, done = later_steps(rec, w)
    if done then
      -- Said once per keep-busy session (a rebuilt drill makes the base "done" again).
      if not s.done_told then
        s.done_told = true
        tell(rec, "The starting base is up (through the coal belt to the power plant). Now working through the tech tree.")
      end
      s.complete = true
      -- Still at work (for M.active) unless it gets to the end below with nothing left to do.
      s.researching_more = true
      -- Fuel for the boilers, then more power: everything after this runs on it.
      local feed_action, feed_why = feed_boilers(rec, w, limited)
      if feed_action then return feed_action end
      local mine_action = not limited and not feed_why and coal_mine(rec, w)
      if mine_action then return mine_action end
      local load = power_load(e, s.home or e.position)
      local power_action = load and more_power(rec, w, load, limited)
      if power_action then return power_action end
      -- Burner drills out of the ore fields early: ore lines for iron and copper, electric ones pollute less
      -- and need no coal (the swap goes on while pollution holds new buildings back; new lines don't).
      local lines_action, lines_why = ore_lines(rec, w, limited)
      if lines_action then return lines_action end
      local upgrade_action, upgrade_why = upgrade(rec, w)
      if upgrade_action then return upgrade_action end
      -- More plates as they're wanted: the smelting columns longer, the fields with them.
      local grow_action, grow_why = M.grow_smelting(rec, w, limited)
      if grow_action then return grow_action end
      upgrade_why = upgrade_why or grow_why
      local radar_action = not limited and radar(rec, w)
      if radar_action then return radar_action end
      local science_action = not limited and more_science(rec, w)
      if science_action then return science_action end
      local next_action, next_why
      if limited then next_why = "holding back on new buildings: pollution is near an enemy nest"
      else next_action, next_why = autonomous(rec, w) end
      if next_action then return next_action end
      -- Meanwhile the lab works through the tech tree with the science the base makes.
      local research_action, research_why = cells.keep_researching(rec, w, H)
      if research_action then return research_action end
      gears(rec)
      s.researching_more = research_why ~= nil
      return nil, lines_why or upgrade_why or next_why or research_why or why_player or "nothing left it can build or research yet; keeping everything fueled"
    end
  end
  s.complete = false
  -- Waiting: craft gears and collect wood for poles meanwhile (once the base is up).
  if not action and s.base_done then
    gears(rec, why)
    if e.get_item_count("wood") < WOOD_RESERVE then return mine("wood", 10, "collecting wood for poles") end
  end
  return action, why
end

-- The owner's give or insert can wait many minutes on its drills and furnaces (400 plates for 100
-- magazines take 3 burner pairs about 9), longer than their coal lasts. Every few seconds, when something
-- the engineer built is about to run out, the order is set aside (rec.held_order) for a refueling trip,
-- and picked up again when the trip ends (M.finished), keep-busy on or off. (On M: this file is at Lua's
-- limit of 200 locals.)
M.ORDER_KINDS = {give = true, insert = true}
function M.fuel_order(rec, s)
  local job = rec.job
  if not M.ORDER_KINDS[job.kind] or rec.crafting or game.tick < (s.order_check or 0) then return end
  s.order_check = game.tick + 300
  local action = maintenance(rec, survey(rec), true)
  if not action then return end
  rec.job, rec.held_order = nil, job
  action.describe = action.describe .. " for your " .. job.kind
  note(rec, action.describe)
  -- (origin: kept when keep-busy is turned off, like the owner's goals' jobs.)
  local info = {held_order = true, origin = "PLAYER"}
  local ok = pcall(jobs.start, rec, action.kind, action.args, info)
  if not ok then jobs.resume(rec, job) end
end

local function run(owner, rec, keep_busy)
  local s = state(rec)
  -- Pollution is watched while the engineer is busy too (pausing a drill is a switch, not a job).
  if keep_busy then
    pollution.manage(rec, s.home or rec.entity.position, function(text) tell(rec, text) end)
    turrets_first(rec)
    -- The engineer reveals the map around it as it goes, like a player.
    local e = rec.entity
    local moved = not s.charted_at or util.distance(s.charted_at, e.position) > SIGHT / 2
    -- Land that wasn't generated yet can't be charted: it's generated where the engineer is and charted
    -- again a couple of seconds later, until it stays put (or a scouting trip reveals nothing new at its
    -- end, where it stops between one chart and the next).
    if moved or (s.chart_again_at and game.tick >= s.chart_again_at) then
      -- (A headless server charts nothing; there the land generated around it is what's revealed.)
      local here = not s.generated_at or util.distance(s.generated_at, e.position) > 1
      if here then
        e.surface.request_to_generate_chunks(e.position, math.ceil(SIGHT / 32))
        s.generated_at = {x = e.position.x, y = e.position.y}
      end
      e.force.chart(e.surface, {{e.position.x - SIGHT, e.position.y - SIGHT}, {e.position.x + SIGHT, e.position.y + SIGHT}})
      if moved then s.charted_at = {x = e.position.x, y = e.position.y} end
      s.chart_again_at = here and game.tick + 120 or nil
    end
    M.lines_step(rec)
    M.smelting_sample(rec)
  end
  if rec.job and not rec.job.auto then return M.fuel_order(rec, s) end
  if rec.job or rec.crafting or game.tick < (s.pause_until or 0) then return end
  local ai = (storage.ai_turn or {})[owner]
  if ai and game.tick - ai < M.AI_QUIET_TICKS then return end
  if not rec.adopted then adopt(rec) end
  if not s.home then
    local _, first = next(rec.built or {})
    s.home = first and first.valid and first.position or rec.entity.position
  end
  local w = survey(rec)
  s.progress = progress(rec, w)
  local action, why = decide(rec, w, keep_busy)
  if not action then
    if why and not why:find("%d") then note(rec, why) end
    s.status = why
    return
  end
  s.status = action.describe
  note(rec, action.describe)
  local info = action.info or {goal = action.goal and id(action.goal), label = action.goal and action.goal.label, spot = action.spot, fix = action.fix,
    partial = action.partial, upgrade = action.upgrade, grow_power = action.grow_power, mine = action.mine, turrets = action.turrets,
    guard_turrets = action.guard_turrets}
  local ok, err = pcall(jobs.start, rec, action.kind, action.args, info)
  if not ok then M.finished(rec, {auto = info, describe = action.describe}, false, type(err) == "table" and err.message or tostring(err)) end
end

-- jobs calls this when a build order job ends (it doesn't wake the AI).
function M.finished(rec, job, ok, result)
  local s, info = state(rec), job.auto
  -- A refueling trip during an order: the order carries on (unless the owner stopped it meanwhile).
  if info.held_order then
    local held = rec.held_order
    rec.held_order = nil
    if held and not rec.job then jobs.resume(rec, held) end
    return
  end
  -- A step that hung (jobs.lua's STEP_TICKS) is worth saying every time: it's the only sign of where.
  if not ok and tostring(result):find("it took over", 1, true) then tell(rec, "Stopped a job that seemed stuck: " .. tostring(result)) end
  if info.goal_id then
    local key = "goal:" .. info.goal_id
    if ok then
      s.streak, s.fails[key] = 0, nil
      if info.label ~= "feeding" and not info.partial then tell(rec, "Built the " .. info.label .. ".") end
      return
    end
    local reason = tostring(result)
    s.status = job.describe .. " failed: " .. reason
    s.fails[key] = (s.fails[key] or 0) + 1
    local goal = goals.get(rec.owner, info.goal_id)
    if goal and s.fails[key] >= MAX_FAILS and goal.status == "COMPLETE" then
      -- (Filling in a finished goal's missing parts: it still works, so it isn't blocked, only left till the
      -- next check.)
      s.fails[key], goal.parts_checked = nil, game.tick
    elseif goal and s.fails[key] >= MAX_FAILS then
      s.fails[key] = nil
      goals.block(rec, goal, "EXECUTOR_ERROR", job.describe .. " failed " .. MAX_FAILS .. " times: " .. reason)
    end
    s.streak = (s.streak or 0) + 1
    s.pause_until = game.tick + math.min(60 * 2 ^ s.streak, 3600)
    return
  end
  if ok then
    s.streak = 0
    if info.goal then
      s.fails[info.goal] = nil
      if not info.partial then tell(rec, "Built a " .. info.label .. ".") end
    end
    if info.fix then s.fails[info.fix] = nil end
    if info.upgrade then tell(rec, "Replaced a burner drill on " .. info.upgrade .. " with an electric drill.") end
    if info.grow_power then tell(rec, "Added steam engines to the power plant.") end
    if info.mine and not info.partial then tell(rec, "Built an electric coal drill filling a chest for the boilers.") end
    if info.turrets then tell(rec, "Put up two gun turrets where biters attacked.") end
    if info.guard_turrets then tell(rec, "Put up two gun turrets on the side pollution is spreading toward a nest.") end
    return
  end
  local reason = tostring(result)
  s.status = job.describe .. " failed: " .. reason
  if info.spot then s.skip[info.spot.x .. "," .. info.spot.y] = true end
  if info.fix then
    s.fails[info.fix] = (s.fails[info.fix] or 0) + 1
    if s.fails[info.fix] == MAX_FAILS then tell(rec, "Giving up on " .. job.describe .. " after " .. MAX_FAILS .. " failed tries: " .. reason) end
  end
  if info.goal then
    s.fails[info.goal] = (s.fails[info.goal] or 0) + 1
    if s.fails[info.goal] >= MAX_FAILS then
      s.skipped[info.goal] = true
      tell(rec, "Skipping the " .. info.label .. " after " .. MAX_FAILS .. " failed tries: " .. reason)
    end
  end
  -- Failures in a row wait longer each time (up to a minute), so something impossible doesn't spin.
  s.streak = (s.streak or 0) + 1
  s.pause_until = game.tick + math.min(60 * 2 ^ s.streak, 3600)
end
jobs.on_auto_finished = M.finished

-- Goals tell the owner when they're done or blocked; the owner's own goals also wake the AI to report.
goals.on_change = function(rec, goal, text)
  tell(rec, text:sub(1, 1):upper() .. text:sub(2) .. ".")
  if goal.origin == "PLAYER" then
    util.emit(rec.owner, goal.status == "COMPLETE" and "goal_done" or "goal_blocked", {goal = goal.id, item = goal.item, result = text})
  end
end

function M.tick()
  for owner, rec in pairs(storage.engineers) do
    local keep_busy = (storage.keep_busy or {})[owner] == true
    local order = rec.job and M.ORDER_KINDS[rec.job.kind] and not rec.job.auto
    if (keep_busy or rec.starter or order or rec.held_order or goals.any_player_goal(rec)) and rec.entity and rec.entity.valid then
      local ok, err = pcall(run, owner, rec, keep_busy)
      if not ok then
        local s = state(rec)
        s.status = "error: " .. (type(err) == "table" and tostring(err.message) or tostring(err))
        s.pause_until = game.tick + 600
        log("AI Engineer build order: " .. s.status)
      end
    end
  end
end

-- Keep-busy turned on or off: start over on skipped goals, and stop a build order job when it's off (but
-- not one for the owner's goals, which run either way). Keep-busy's own goals pause while it's off.
function M.reset(rec, on)
  local s = state(rec)
  s.fails, s.skip, s.skipped, s.pause_until, s.complete, s.streak, s.status = {}, {}, {}, nil, nil, 0, nil
  goals.keep_busy_changed(rec, on)
  if on then goals.retry_blocked(rec) end
  if not on and rec.job and rec.job.auto and rec.job.auto.origin ~= "PLAYER" then jobs.cancel(rec) end
  -- Nothing restarts drills paused for pollution while it's off.
  if not on then pollution.release(rec, function(text) tell(rec, text) end) end
end

-- For the app's poll: whether the build order or a goal still has work to do (so the AI isn't woken to pick some).
function M.active(owner, rec)
  if not rec then return false end
  if rec.starter or rec.held_order then return true end
  local keep_busy = (storage.keep_busy or {})[owner] == true
  if rec.entity and rec.entity.valid and goals.has_work(rec, keep_busy) then return true end
  if not keep_busy then return false end
  -- Holding back for pollution is work too: the AI isn't woken to build more.
  if rec.entity and rec.entity.valid and pollution.limited(rec, (rec.auto and rec.auto.home) or rec.entity.position) then return true end
  return not (rec.auto and rec.auto.complete) or rec.auto.researching_more == true
end

-- For observe: what the build order is doing.
function M.describe(owner, rec)
  if not (storage.keep_busy or {})[owner] then return nil end
  local s = rec.auto or {}
  local room = s.plant and s.plant.room and power.growth_area(s.plant)
  return {who = "the game's own build order does all of this by itself, not you: report it as it is here, never guess",
    doing = s.status or "starting", last = s.news, base_progress = s.progress,
    keep_clear = room and {power_plant_room = {util.pos(room.left_top), util.pos(room.right_bottom)}}}
end

-- Coal that runs a burner drill (and its furnace, for a pair) through `count` ore, with one spare each:
-- a burner drill takes 600 kJ an ore (150 kW, 0.25 ore/s), a stone furnace 288 kJ a plate; coal is 4 MJ.
local function order_fuel(ore, kind, count)
  local drill, coal = prototypes.entity[DRILL], prototypes.item.coal.fuel_value
  local resource = prototypes.entity[ore]
  local per_ore = drill.energy_usage * 60 * ((resource and resource.mineable_properties.mining_time) or 1) / drill.mining_speed
  local fuel = {drill = math.min(math.ceil(count * per_ore / coal) + 1, 50), furnace = 0}
  if kind == "pair" then
    local furnace = prototypes.entity[FURNACE]
    local per_plate = furnace.energy_usage * 60 * 3.2 / furnace.get_crafting_speed()
    fuel.furnace = math.min(math.ceil(count * per_plate / coal) + 1, 50)
  end
  return fuel
end

-- An order (give or insert) that needs more than is mined by hand, with nothing in the base making it
-- (jobs.wait_for_drills sets rec.starter): just what the order needs, keep-busy on or off, the quickest
-- way. A small order gets one drill and furnace (plates) or drill and chest (ore, coal, stone) per ore,
-- fueled with hand-mined coal for the whole order: no coal loop, which costs two more drills' iron. A
-- big order (o.target drills) is keep-busy's early base: the iron drill and furnace first when iron is
-- wanted (the other drills are made of iron), the coal loop (fuel for them all), then the rest. Then the
-- order starts as an ordinary job, so its end wakes the AI.
function M.starter(rec, w)
  local st, s = rec.starter, state(rec)
  local big = false
  for _, o in ipairs(st.ores) do big = big or (o.target or 1) > 1 end
  local wanted = {}
  -- A big order wants a few drills (o.target): the first goes up before the coal loop, the rest after.
  local later = {}
  for _, o in ipairs(st.ores) do
    local label = o.ore:gsub("%-ore$", "") .. " drill and " .. (o.kind == "pair" and "furnace" or "chest")
    local first = {kind = o.kind, ore = o.ore, target = 1, label = label}
    if not big then first.fuel = order_fuel(o.ore, o.kind, o.count or jobs.HAND_MAX) end
    if o.ore == "iron-ore" and o.kind == "pair" then wanted[1] = first else later[#later + 1] = first end
    if (o.target or 1) > 1 then later[#later + 1] = {kind = o.kind, ore = o.ore, target = o.target, label = label} end
  end
  if big then wanted[#wanted + 1] = {kind = "loop", ore = "coal", target = 2, label = "coal loop"} end
  for _, goal in ipairs(later) do wanted[#wanted + 1] = goal end
  local function give_up(why)
    rec.starter = nil
    tell(rec, "Couldn't build the drills for your " .. st.order.kind .. ": " .. why .. ".")
    util.emit(rec.owner, "job_failed", {job = st.order.kind .. " " .. tostring(st.order.args.item),
      reason = "couldn't build the drills it needs first: " .. why})
    return nil, why
  end
  for _, goal in ipairs(wanted) do
    local met = (w.count[key(goal)] or 0) >= goal.target or (goal.ore == "coal" and goal.kind == "loop" and w.count.coal_belt ~= nil)
    if not met then
      if s.skipped[id(goal)] then return give_up("the " .. goal.label .. " failed too often") end
      local action, why, stuck = build(rec, w, goal)
      if stuck then return give_up(why) end
      if action then action.describe = "for your " .. st.order.kind .. ": " .. action.describe end
      return action, why and ("for your " .. st.order.kind .. ": " .. why) or nil
    end
  end
  rec.starter = nil
  tell(rec, "The drills for your order are up. Starting the " .. st.order.kind .. " of " .. tostring(st.order.args.count) ..
    " " .. tostring(st.order.args.item) .. ".")
  st.order.args.drills_ready = true -- (so it collects from them instead of asking for more)
  local ok, err = pcall(jobs.start, rec, st.order.kind, st.order.args)
  if not ok then
    util.emit(rec.owner, "job_failed", {job = st.order.kind .. " " .. tostring(st.order.args.item),
      reason = type(err) == "table" and err.message or tostring(err)})
  end
  return nil, "started the " .. st.order.kind .. " it was building for"
end

-- For the app's poll: the build order's log lines after `after` (the app prints them in its terminal).
function M.log(rec, after)
  local s = rec and rec.auto
  if not (s and s.log) then return nil end
  local out = {}
  for _, line in ipairs(s.log) do
    if line.n > after then out[#out + 1] = line end
  end
  return #out > 0 and out or nil
end

return M
