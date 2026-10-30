-- Long-running engineer work (walking, mining, building, transfers), advanced every tick.
-- Each engineer runs at most one job; starting a new one replaces the old. When a job ends
-- the helper app is told through an event, so the AI never has to poll.
local util = require("scripts.util")
local engineer = require("scripts.engineer")
local triggers = require("scripts.triggers")
local gui = require("scripts.gui")
local M = {}

local STUCK_TICKS = 120   -- no movement for this long counts as stuck
local REPATHS = 2         -- path requests before giving up / teleporting
local MINE_STALL_TICKS = 90 -- no mining progress for this long: try another target

---------------------------------------------------------------------------
-- Walking

local function request_path(rec, walk)
  local e = rec.entity
  local proto = prototypes.entity.character
  walk.path, walk.index = nil, 1
  walk.request = e.surface.request_path{bounding_box = proto.collision_box, collision_mask = proto.collision_mask,
    start = e.position, goal = walk.target, force = e.force, radius = math.max(walk.radius - 0.5, 0.5),
    entity_to_ignore = e, can_open_gates = true, pathfind_flags = {cache = false}}
  storage.path_requests[walk.request] = rec
end

function M.path_finished(event)
  local rec = storage.path_requests[event.id]
  storage.path_requests[event.id] = nil
  -- A steps job walks inside its current step (a give making its items first runs one), and give or insert
  -- inside the mining they do first.
  local active = rec and rec.job
  if active and active.making then active = active.making end
  active = active and (active.current or active)
  if active and active.gather then active = active.gather end
  local walk = active and active.walk
  if not (walk and walk.request == event.id) then return end
  walk.request = nil
  if event.path then
    walk.path, walk.index = event.path, 1
  elseif event.try_again_later then
    walk.retry_at = game.tick + 30
  else
    -- No path found: head straight there; stuck handling decides what happens next.
    walk.path, walk.index = {{position = walk.target}}, 1
  end
end

local function unstick(rec, walk)
  local e = rec.entity
  if settings.global["ai-engineer-teleport-when-stuck"].value then
    local spot = e.surface.find_non_colliding_position("character", walk.target, walk.radius + 4, 0.5)
    if spot then
      e.teleport(spot)
      e.walking_state = {walking = false}
      return "arrived"
    end
  end
  return "Stuck: couldn't walk to " .. serpent.line(util.pos(walk.target))
end

-- Advances a walk; returns "arrived", a failure reason, or nil while still walking.
local function step_walk(rec, walk)
  local e = rec.entity
  if util.distance(e.position, walk.target) <= walk.radius then
    e.walking_state = {walking = false}
    return "arrived"
  end
  if not walk.path then
    e.walking_state = {walking = false}
    if not walk.request and game.tick >= (walk.retry_at or 0) then request_path(rec, walk) end
    return nil
  end
  local waypoint = walk.path[walk.index]
  while waypoint and util.distance(e.position, waypoint.position) < 0.6 do
    walk.index = walk.index + 1
    waypoint = walk.path[walk.index]
  end
  e.walking_state = {walking = true, direction = util.direction_to(e.position, waypoint and waypoint.position or walk.target)}
  walk.checked = walk.checked or game.tick
  if game.tick - walk.checked >= 30 then
    walk.checked = game.tick
    if walk.last and util.distance(walk.last, e.position) < 0.15 then
      walk.stuck = (walk.stuck or 0) + 30
    else
      walk.stuck = 0
    end
    walk.last = {x = e.position.x, y = e.position.y}
    if walk.stuck >= STUCK_TICKS then
      walk.stuck, walk.repaths = 0, (walk.repaths or 0) + 1
      if walk.repaths > REPATHS then return unstick(rec, walk) end
      walk.path = nil
    end
  end
  return nil
end

-- Walk until within `radius` of `position`; true once there. Failures end the job.
local function approach(rec, job, position, radius)
  local walk = job.walk
  if not walk or walk.target.x ~= position.x or walk.target.y ~= position.y or walk.radius ~= radius then
    walk = {target = {x = position.x, y = position.y}, radius = radius}
    job.walk = walk
  end
  local result = step_walk(rec, walk)
  if result == "arrived" then return true end
  if result then util.fail(result) end
  return false
end

---------------------------------------------------------------------------
-- Finding things to mine

local MINEABLE_TYPES = {"resource", "tree", "simple-entity", "fish"}

-- Entity names that drop `item` when mined by hand (iron-ore -> iron ore patches, wood -> trees, ...).
local function sources_of(item)
  local names = {}
  for name, proto in pairs(prototypes.get_entity_filtered({{filter = "type", type = MINEABLE_TYPES}})) do
    local props = proto.mineable_properties
    if props and props.minable and not props.required_fluid then
      for _, product in ipairs(props.products or {}) do
        if product.type == "item" and product.name == item then names[#names + 1] = name; break end
      end
    end
  end
  return names
end

-- What a player would call it: "trees" gives wood, "rocks" gives stone. Without these the AI is told
-- trees can't be mined by hand, and believes it.
local ALIASES = {tree = "wood", trees = "wood", rock = "stone", rocks = "stone"}

-- Resolve a name the AI gave: an entity name (big-rock) or an item it wants (iron-ore, wood, stone).
function M.resolve(name)
  if type(name) == "string" then name = ALIASES[name:lower()] or name end
  if prototypes.item[name] then
    local names = sources_of(name)
    if #names > 0 then return names, name end
  end
  if prototypes.entity[name] then return {name}, nil end
  util.fail("Nothing called '" .. tostring(name) .. "' can be mined by hand. Use the item you want (wood for trees, " ..
    "stone, coal, iron-ore, copper-ore) or an entity name from observe (big-rock)." .. util.did_you_mean(name))
end

-- Nearest matching entity, searching outward; `skip` holds positions to avoid, and `bases` (from
-- util.enemy_bases) rules out anything too close to an enemy nest. With `home` (where the things go
-- afterwards, or where mining started), it's the shortest trip from `from` to it and on to `home`:
-- going for each next rock nearest the engineer drifted further from the base with every one.
function M.nearest(surface, names, from, skip, max_radius, bases, home)
  for _, radius in ipairs({16, 48, 128, max_radius or 256}) do
    local best, best_d
    local function consider(entity)
      local key = entity.position.x .. "," .. entity.position.y
      if not (skip and skip[key]) and not (bases and util.base_near(bases, entity.position)) then
        local d = util.distance(from, entity.position) + (home and util.distance(entity.position, home) or 0)
        if not best_d or d < best_d then best, best_d = entity, d end
      end
    end
    for _, entity in ipairs(surface.find_entities_filtered{name = names, position = from, radius = radius}) do consider(entity) end
    if home then
      for _, entity in ipairs(surface.find_entities_filtered{name = names, position = home, radius = radius}) do consider(entity) end
    end
    if best then return best, util.distance(from, best.position) end
  end
  return nil
end

-- The entity whose footprint covers `position`, else the nearest one within a tile.
local function entity_at(surface, position, filter)
  local function ok(entity) return entity.valid and entity.type ~= "character" and (not filter or filter(entity)) end
  for _, entity in ipairs(surface.find_entities_filtered{position = position}) do
    if ok(entity) then return entity end
  end
  local best, best_d
  for _, entity in ipairs(surface.find_entities_filtered{position = position, radius = 1.2}) do
    local d = util.distance(position, entity.position)
    if ok(entity) and (not best_d or d < best_d) then best, best_d = entity, d end
  end
  return best
end

---------------------------------------------------------------------------
-- Job kinds. start(rec, args) validates and returns the job; tick(rec, job) returns a result
-- table when done (or raises util.fail), nil while working.

local kinds = {}

-- Refuse to send the engineer next to an enemy nest or worm: it would only get killed.
local function check_safe(rec, position)
  local base = util.base_near(util.enemy_bases(rec.entity.surface, position, util.NEST_CLEARANCE), position)
  if base then
    util.fail(serpent.line(util.pos(position)) .. " is " .. math.floor(util.distance(base.position, position)) ..
      " tiles from an enemy " .. base.name .. " at " .. serpent.line(util.pos(base.position)) ..
      "; its defenders would kill the engineer. Pick a spot at least " .. util.NEST_CLEARANCE .. " tiles from it")
  end
end

kinds.walk = {
  start = function(rec, args)
    check_safe(rec, {x = args.x, y = args.y})
    return {target = {x = args.x, y = args.y}, describe = "walking to " .. serpent.line({args.x, args.y})}
  end,
  tick = function(rec, job)
    if approach(rec, job, job.target, 1.5) then return {position = util.pos(rec.entity.position)} end
  end,
}

kinds.follow = {
  start = function(rec)
    return {describe = "following you", owner = rec.owner}
  end,
  tick = function(rec, job)
    local player = job.owner > 0 and game.get_player(job.owner) or nil
    local character = player and player.connected and player.character
    if not (character and character.valid and character.surface == rec.entity.surface) then
      engineer.halt(rec)
      return nil
    end
    -- Re-target only when the owner has moved away from the current goal.
    local goal = job.walk and job.walk.target
    if not goal or util.distance(goal, character.position) > 4 then goal = character.position end
    approach(rec, job, goal, 3)
    return nil
  end,
}

-- What `item` smelts into, when a furnace takes it (iron-ore -> iron-plate).
local function smelts_into(force, item)
  for _, r in pairs(force.recipes) do
    local p = r.prototype.main_product
    if r.enabled and p and util.category(r) == "smelting" and #r.ingredients == 1 and r.ingredients[1].name == item then
      return p.name
    end
  end
end

local BITER_RADIUS = 24 -- biters this close stop a mine job
local ROAMING = {"unit", "spider-unit", "segmented-unit"}

kinds.mine = {
  start = function(rec, args)
    local names, item = M.resolve(args.name)
    -- An entity name (big-rock) counts what it drops, like an item: "mine big-rock 20" for 20 stone once
    -- walked off to mine 20 rocks (400 stone), each further away.
    local props = not item and prototypes.entity[names[1]].mineable_properties
    local drop = props and props.products and props.products[1]
    if drop and drop.type == "item" then item = drop.name end
    -- Sources near enemy nests are left alone (found once: the search covers 256 tiles).
    local job = {names = names, item = item, wanted = args.count or 10, mined = 0, skip = {},
      bases = util.enemy_bases(rec.entity.surface, rec.entity.position, 256 + util.NEST_CLEARANCE),
      home = args.home or util.pos(rec.entity.position),
      describe = "mining " .. args.name}
    job.start_count = item and rec.entity.get_item_count(item) or 0
    return job
  end,
  tick = function(rec, job)
    local e = rec.entity
    local progress = job.item and (e.get_item_count(job.item) - job.start_count) or job.mined
    if progress >= job.wanted then
      engineer.halt(rec)
      -- A small model mined 250 ore and waited for a furnace to smelt it from its inventory.
      local plate = job.item and smelts_into(e.force, job.item)
      return {mined = progress, item = job.item, next = plate and ("It's in your inventory, which no furnace takes from. To get " ..
        plate .. ", insert the " .. job.item .. " into a fueled furnace, then take the " .. plate ..
        " out; or call give or insert with " .. plate .. " and a count, which does all of that") or nil}
    end
    -- Biters roaming close (not just nests): stop and go back before they kill the engineer, which
    -- once died hand-mining a rock far from base.
    if job.fleeing or game.tick % 30 == 0 then
      local biter = not job.fleeing and e.surface.find_entities_filtered{position = e.position, radius = BITER_RADIUS,
        force = "enemy", type = ROAMING, limit = 1}[1]
      if biter then
        job.fleeing, job.walk, job.target = util.pos(biter.position), nil, nil
        e.mining_state = {mining = false}
      end
      if job.fleeing then
        if not approach(rec, job, job.home, 3) then return nil end
        engineer.halt(rec)
        local function at(p) return string.format("{x = %d, y = %d}", math.floor(p.x + 0.5), math.floor(p.y + 0.5)) end
        local why = "biters came within " .. BITER_RADIUS .. " tiles at " .. at(job.fleeing) ..
          ", so the engineer went back to " .. at(job.home)
        if progress > 0 then return {mined = progress, item = job.item, note = "Stopped early: " .. why} end
        util.fail("Stopped mining: " .. why)
      end
    end
    local target = job.target
    if not (target and target.valid) then
      if job.target then job.mined = job.mined + 1 end
      -- Nests, and biters out roaming now, rule out what's near them.
      local danger = {table.unpack(job.bases)}
      for _, unit in ipairs(e.surface.find_entities_filtered{position = e.position, radius = 300, force = "enemy",
          type = ROAMING, limit = 50}) do
        danger[#danger + 1] = {name = unit.name, position = unit.position}
      end
      target = M.nearest(e.surface, job.names, e.position, job.skip, nil, danger, job.home)
      job.target, job.walk, job.stalled_since, job.mining_seen = target, nil, nil, nil
      -- Still "mining" the last target, the character can't select another (after a rock it never mines
      -- again): let go for a tick first.
      e.mining_state = {mining = false}
      job.released = game.tick
      if not target then
        engineer.halt(rec)
        if progress > 0 then return {mined = progress, item = job.item, note = "nothing left nearby"} end
        util.fail("None found within 256 tiles" ..
          (#job.bases > 0 and (" that isn't within " .. util.NEST_CLEARANCE .. " tiles of an enemy nest") or ""))
      end
    end
    if not approach(rec, job, target.position, e.resource_reach_distance - 0.5) then return nil end
    if job.released == game.tick then return nil end
    if job.item and not e.can_insert({name = job.item}) then
      engineer.halt(rec)
      util.fail("Inventory full after mining " .. progress)
    end
    -- Select the target itself: selecting by position can pick an overlapping tree instead, and then
    -- the character doesn't mine at all.
    e.selected = target
    if e.selected ~= target then e.update_selected_entity(target.position) end
    e.mining_state = {mining = true, position = target.position}
    -- Give up on a target that isn't being mined (e.g. something in the way), and try another.
    local mining = e.character_mining_progress
    if not job.stalled_since or job.progress_seen ~= progress or (job.mining_seen or 0) < mining then
      job.progress_seen, job.mining_seen, job.stalled_since = progress, mining, game.tick
    elseif game.tick - job.stalled_since > MINE_STALL_TICKS then
      job.skip[target.position.x .. "," .. target.position.y] = true
      job.target, job.walk, job.stalled_since = nil, nil, nil
      e.mining_state = {mining = false}
    end
    return nil
  end,
}

-- Half the width and height of a building about to be placed, and whether the engineer stands in its way.
local function in_the_way(e, job)
  local box = prototypes.entity[job.entity].collision_box
  local hx, hy = (box.right_bottom.x - box.left_top.x) / 2, (box.right_bottom.y - box.left_top.y) / 2
  if job.direction == defines.direction.east or job.direction == defines.direction.west then hx, hy = hy, hx end
  local p = job.position
  return math.abs(e.position.x - p.x) < hx + 0.5 and math.abs(e.position.y - p.y) < hy + 0.5, hx, hy
end

-- Mines the trees and rocks where a building is about to go, and picks up items lying there (into the
-- inventory); returns how many.
local function clear_nature(e, job)
  local box = prototypes.entity[job.entity].collision_box
  local w, h = box.right_bottom.x, box.right_bottom.y
  if job.direction == defines.direction.east or job.direction == defines.direction.west then w, h = h, w end
  local p = job.position
  local n = 0
  for _, thing in ipairs(e.surface.find_entities_filtered{area = {{p.x - w, p.y - h}, {p.x + w, p.y + h}},
      type = {"tree", "simple-entity", "item-entity"}}) do
    if thing.valid and thing.type == "item-entity" then
      local stack = thing.stack
      if stack.valid_for_read and e.can_insert(stack) then
        e.insert(stack)
        thing.destroy()
        n = n + 1
      end
    elseif thing.valid and thing.minable and thing.mine{inventory = e.get_main_inventory(), raise_destroyed = true} then n = n + 1 end
  end
  return n
end

-- Where the engineer can stand clear of a building about to be placed, or nil if it isn't in the way.
local function clear_spot(e, job)
  local blocking, hx, hy = in_the_way(e, job)
  local p = job.position
  if not blocking then return nil end
  local reach = math.max(hx, hy) + 1.5
  local best, best_d
  for _, step in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) do
    local spot = {x = p.x + step[1] * reach, y = p.y + step[2] * reach}
    if e.surface.can_place_entity{name = "character", position = spot} then
      local d = util.distance(e.position, spot)
      if not best_d or d < best_d then best, best_d = spot, d end
    end
  end
  return best
end

-- Where the game puts a building asked for at `p`: even-sized ones snap to tile corners, odd-sized to centers.
local function snapped(proto, p, direction)
  local w, h = proto.tile_width, proto.tile_height
  if direction == defines.direction.east or direction == defines.direction.west then w, h = h, w end
  local function snap(v, size) return size % 2 == 0 and math.floor(v + 0.5) or math.floor(v) + 0.5 end
  return {x = snap(p.x, w), y = snap(p.y, h)}
end

-- Resource tiles a drill at `center` would mine, by name.
local function drill_resources(surface, proto, center)
  local r = proto.mining_drill_radius
  local counts = {}
  for _, ore in ipairs(surface.find_entities_filtered{type = "resource",
    area = {{center.x - r, center.y - r}, {center.x + r, center.y + r}}}) do
    counts[ore.name] = (counts[ore.name] or 0) + 1
  end
  return counts
end
M.drill_resources = drill_resources

-- The spot closest to `center`, within `range` tiles of `around`, where the drill covers a single resource
-- on every tile (one of `only`, when given) and can be placed. Returns the spot and the resource name.
local function full_drill_spot(e, proto, center, around, direction, range, only)
  local size = math.floor(proto.mining_drill_radius * 2 + 0.5)
  local best, best_d, best_name
  for dx = -range, range do
    for dy = -range, range do
      local p = {x = around.x + dx, y = around.y + dy}
      local d = (p.x - center.x) ^ 2 + (p.y - center.y) ^ 2
      if not best_d or d < best_d then
        local c = drill_resources(e.surface, proto, p)
        local name, n = next(c)
        if n == size * size and next(c, name) == nil and (not only or only[name]) and e.surface.can_place_entity{name = proto.name,
          position = p, direction = direction, force = e.force, build_check_type = defines.build_check_type.manual} then
          best, best_d, best_name = p, d, name
        end
      end
    end
  end
  return best, best_name
end

-- Early drills can't sort what they mine, so a drill must cover only one resource. Returns an error
-- message (with the nearest spot fully on one resource), or a note when only partly on ore.
local function check_drill_spot(e, proto, center, direction)
  local counts = drill_resources(e.surface, proto, center)
  local names = {}
  for name, n in pairs(counts) do names[#names + 1] = name end
  table.sort(names)
  local size = math.floor(proto.mining_drill_radius * 2 + 0.5)
  if #names == 0 then
    -- Say where the nearest ore this drill can mine is, so the next try lands on it.
    local nearest, nearest_d
    for _, ore in ipairs(e.surface.find_entities_filtered{type = "resource", position = center, radius = 32}) do
      local d = (ore.position.x - center.x) ^ 2 + (ore.position.y - center.y) ^ 2
      if proto.resource_categories[ore.prototype.resource_category] and (not nearest_d or d < nearest_d) then
        nearest, nearest_d = ore, d
      end
    end
    local best, best_name
    if nearest then best, best_name = full_drill_spot(e, proto, center, snapped(proto, nearest.position, direction), direction, 4) end
    util.fail("No ore under " .. serpent.line(util.pos(center)) .. " for " .. proto.name .. ". " ..
      (best and ("Nearest spot fully on " .. best_name .. ": " .. serpent.line(util.pos(best)))
        or nearest and ("Nearest ore: " .. nearest.name .. " at " .. serpent.line(util.pos(nearest.position)))
        or "No ore it can mine within 32 tiles; use find to locate some"))
  end
  if #names == 1 then
    local n = counts[names[1]]
    if n < size * size then return nil, "only " .. n .. " of " .. size * size .. " tiles have " .. names[1] end
    return nil
  end
  local best, best_name = full_drill_spot(e, proto, center, center, direction, 8, counts)
  local mixed = {}
  for i, name in ipairs(names) do mixed[i] = name .. " (" .. counts[name] .. " tiles)" end
  return "Not placed: a " .. proto.name .. " at " .. serpent.line(util.pos(center)) .. " would mine " .. table.concat(mixed, " and ") ..
    ", and mixed ore can't be sorted yet. " .. (best and ("Nearest spot fully on " .. best_name .. ": " .. serpent.line(util.pos(best)))
      or "No spot fully on one of them within 8 tiles; pick a spot with only one resource under the drill")
end

local FACING = {[defines.direction.north] = {0, -1}, [defines.direction.east] = {1, 0},
  [defines.direction.south] = {0, 1}, [defines.direction.west] = {-1, 0}}

-- Where a building of `proto` goes for `drill` to drop its output into it: right in front of the drill.
local function feed_spot(drill, proto)
  local v = FACING[drill.direction]
  if not v then return nil end
  local reach = drill.prototype.tile_width / 2 + proto.tile_width / 2
  return snapped(proto, {x = drill.position.x + v[1] * reach, y = drill.position.y + v[2] * reach}, defines.direction.north)
end
M.feed_spot = feed_spot

-- Whether a furnace can smelt what `drill` mines (ores and stone, not coal).
local function smeltable(drill)
  -- mining_target stays empty until the drill has fuel, so look at the ore under it.
  local name = next(drill_resources(drill.surface, drill.prototype, drill.position))
  local ore = name and prototypes.entity[name]
  local product = ore and ore.mineable_properties.products
  product = product and product[1] and product[1].name
  if not product then return false end
  for _, recipe in pairs(prototypes.get_recipe_filtered{{filter = "has-ingredient-item",
    elem_filters = {{filter = "name", name = product}}}}) do
    if util.category(recipe) == "smelting" then return true end
  end
  return false
end

-- How a just-placed drill's output is used: what it feeds, or where a furnace or chest would catch it.
local function drill_output_note(drill)
  local target = util.drill_target(drill)
  if target then return "It feeds the " .. target.name .. " at " .. serpent.line(util.pos(target.position)) end
  local furnace = prototypes.entity["stone-furnace"]
  local spot = furnace and feed_spot(drill, furnace)
  local catch = spot and (smeltable(drill) and "a stone-furnace placed at " or "a chest or another drill placed at ") ..
    serpent.line(util.pos(spot)) .. " would take it"
  return "Its output drops on the ground at " .. serpent.line(util.pos(drill.drop_position)) .. (catch and ("; " .. catch) or "")
end

-- For a just-placed furnace: which drill feeds it, or why a drill next to it doesn't.
local function furnace_input_note(furnace)
  local unfed = {}
  for _, drill in ipairs(furnace.surface.find_entities_filtered{type = "mining-drill", force = furnace.force,
    position = furnace.position, radius = 4}) do
    local target = util.drill_target(drill)
    if target == furnace then
      return "Fed by the " .. drill.name .. " at " .. serpent.line(util.pos(drill.position))
    elseif not target then
      unfed[#unfed + 1] = drill
    end
  end
  local drill = unfed[1]
  if not drill then return nil end
  local spot = feed_spot(drill, furnace.prototype)
  return "Not fed: the " .. drill.name .. " at " .. serpent.line(util.pos(drill.position)) .. " drops its output at " ..
    serpent.line(util.pos(drill.drop_position)) .. ", outside this furnace" ..
    (spot and (". To be fed, the furnace must be at " .. serpent.line(util.pos(spot)) .. " (pick it up and place it there)") or "")
end

-- The owner's rule: no hand-mining more than this many of something that comes from an ore patch (ore,
-- coal, stone). More comes from drills: what machines and storage have, or keep-busy's early base built
-- for it first (autopilot's M.starter). Wood, and the build order's own jobs, are exempt.
local HAND_MAX = 10
M.HAND_MAX = HAND_MAX

-- The build order is starting this job (jobs.start with `auto`) or runs it (a step of its job). While a
-- job starts, rec.job is still the one it replaces, so that's decided by who starts it.
local starting_auto -- nil outside jobs.start
local function by_build_order(rec)
  if starting_auto ~= nil then return starting_auto end
  return rec.job ~= nil and rec.job.auto ~= nil
end

-- Whether `item` comes from an ore patch (which drills mine), not just trees or rocks.
local function from_patch(item)
  for _, name in ipairs(sources_of(item)) do
    if prototypes.entity[name].type == "resource" then return true end
  end
  return false
end
M.from_patch = from_patch

-- Whether hand-mining `count` of `item` breaks the owner's rule above.
local function too_much_by_hand(rec, item, count)
  return count > HAND_MAX and from_patch(item) and not by_build_order(rec)
end
M.too_much_by_hand = too_much_by_hand

-- Short of something that can be mined by hand (wood, stone, coal, ore), place, insert and give mine it
-- first, so "put 10 wood in the chest" or "get me 10 wood" is one job. Returns whether it will.
-- `home`: where the items go (the building, the owner), so it mines what's on the way there.
local function start_gathering(rec, job, item, wanted, home)
  local short = wanted - rec.entity.get_item_count(item)
  if short > 0 and prototypes.item[item] and #sources_of(item) > 0 and not too_much_by_hand(rec, item, short) then
    job.gather = kinds.mine.start(rec, {name = item, count = short, home = home and util.pos(home)})
    return true
  end
  return false
end

-- Advances the gathering; true once it's done (or there was none). Once some items were delivered
-- (job.done), running out of sources ends the gathering (job.exhausted) instead of failing the job.
local function gathered(rec, job)
  if not job.gather then return true end
  local ok, mined = pcall(kinds.mine.tick, rec, job.gather)
  if not ok then
    if (job.done or 0) == 0 then error(mined, 0) end
    job.gather, job.exhausted, job.walk = nil, true, nil
    return true
  end
  if not mined then return false end
  job.gather, job.mined, job.walk = nil, (job.mined or 0) + (mined.mined or 0), nil
  if mined.note then job.exhausted = true end
  return true
end

-- Big inserts ("fill the chest with wood") mine and deliver in batches, so they're one job.
local INSERT_BATCH = 200

-- Said when fewer items moved than were asked for, so the AI doesn't report the full amount.
local function short_note(done, asked, item, why)
  if asked and done < asked then return "Only " .. done .. " of the " .. asked .. " " .. item .. " asked for: " .. why end
end

-- The recipe a furnace or assembler is making `item` with: crafting it now, or (a furnace just given ore
-- starts on its next update) fueled with its ore in.
local function making(machine, item)
  if not (machine.valid and (machine.type == "furnace" or machine.type == "assembling-machine")) then return nil end
  local function makes(recipe)
    for _, p in ipairs(recipe and recipe.products or {}) do
      if p.name == item then return recipe end
    end
  end
  if machine.is_crafting() then return makes(machine.get_recipe()) end
  if machine.type ~= "furnace" then return nil end
  -- Out of fuel: an empty slot with nothing burning (a single coal leaves the slot at once to burn).
  local fuel = machine.get_fuel_inventory()
  if fuel and fuel.is_empty() and not (machine.burner and machine.burner.remaining_burning_fuel > 0) then return nil end
  local input = machine.get_inventory(defines.inventory.crafter_input)
  for _, stack in ipairs(input and input.get_contents() or {}) do
    for _, r in pairs(machine.force.recipes) do
      if r.enabled and util.category(r) == "smelting" and r.ingredients[1] and r.ingredients[1].name == stack.name and makes(r) then return r end
    end
  end
end

-- What a machine or chest holds of `item` that can be taken: a machine's output, a chest's contents.
local function takeable(m, item)
  if m.type == "container" or m.type == "logistic-container" then return m.get_item_count(item) end
  local output = m.get_output_inventory()
  return output and output.get_item_count(item) or 0
end

-- Whether a drill feeds `machine` something that ends up as `item` there: a chest filled with that ore
-- (or coal, stone), or a furnace smelting it. Counts before the first ore has arrived.
local function fed_by_drill(machine, item)
  if machine.type ~= "furnace" and machine.type ~= "container" then return false end
  for _, d in ipairs(machine.surface.find_entities_filtered{type = "mining-drill", force = machine.force,
      position = machine.position, radius = 5}) do
    if util.drill_target(d) == machine then
      local ore = d.mining_target
      if not (ore and ore.valid) then
        ore = machine.surface.find_entities_filtered{type = "resource", position = d.position, radius = 1}[1]
      end
      local drop = ore and ore.prototype.mineable_properties.products
      local product = drop and drop[1] and drop[1].name
      if product == item or (product and machine.type == "furnace" and smelts_into(machine.force, product) == item) then
        return true
      end
    end
  end
  return false
end

-- A player waits at a furnace for the last plates instead of walking off with half. True while
-- `machine` is still making `item` toward `wanted` (or a drill keeps filling it) and keeps finishing
-- them (a furnace out of fuel or with a full output stops counting), for at most WAIT_TICKS.
local WAIT_TICKS = 30 * 60 * 60 -- a burner drill makes a plate every 4 s: 400 take 27 minutes
local function keep_waiting(job, machine, item, wanted)
  local ready = takeable(machine, item)
  if ready >= wanted then return false end
  local recipe = making(machine, item)
  if not recipe and not fed_by_drill(machine, item) then return false end
  -- Progress: crafts finishing, or more ready (a chest a drill fills).
  local mark = ready + (machine.type == "container" and 0 or machine.products_finished)
  if mark ~= job.finished then job.finished, job.progress_at = mark, game.tick end
  job.wait_from = job.wait_from or game.tick
  -- Two crafts' time without one finishing counts as stalled (at least 20 s: a burner drill's ore comes
  -- every 4 s, and the first takes a moment).
  local stall = math.max(recipe and math.ceil(recipe.energy / machine.crafting_speed * 120) + 60 or 0, 20 * 60)
  return game.tick - job.progress_at < stall and game.tick - job.wait_from < WAIT_TICKS
end

-- Moves up to `count` of `item` from a building into the engineer's inventory; returns how many.
local function take_out(e, target, item, count, quality)
  local removed = count > 0 and target.remove_item({name = item, count = count, quality = quality}) or 0
  local kept = removed > 0 and e.insert({name = item, count = removed, quality = quality}) or 0
  if kept < removed then target.insert({name = item, count = removed - kept, quality = quality}) end
  return kept
end

-- How far machines and storage are looked for: the base around the engineer (drills built for an order
-- stand at the ore, maybe some way off).
local SUPPLY_RADIUS = 100

-- The engineer's force's furnaces and assemblers nearby with `item` ready or being made, chests holding
-- it (the crash site's wreck had 8 magazines), and furnaces and chests a drill feeds it to, nearest first,
-- so "give me 10 plates" collects them like a player would instead of handing over what's in hand.
local function machines_with(e, item, radius)
  local found = {}
  for _, m in ipairs(e.surface.find_entities_filtered{position = e.position, radius = radius or SUPPLY_RADIUS, force = e.force,
      type = {"furnace", "assembling-machine", "container", "logistic-container"}}) do
    if takeable(m, item) > 0 or making(m, item) or fed_by_drill(m, item) then found[#found + 1] = m end
  end
  table.sort(found, function(a, b) return util.distance(a.position, e.position) < util.distance(b.position, e.position) end)
  return {table.unpack(found, 1, math.min(#found, 5))}
end

-- Advances collecting from job.collect until the engineer holds job.count; true once done. With several
-- machines making it (an order's three drill-fed furnaces), it goes round them: at each it waits only for
-- that machine's share of what's still needed, takes what's ready, and comes back next round to those
-- still making it, so they all work for the order at once (for at most WAIT_TICKS in all).
local function collected(rec, job)
  local e = rec.entity
  job.collect_since = job.collect_since or game.tick
  while job.collect do
    local need = job.count - e.get_item_count(job.item)
    if need <= 0 then break end
    if #job.collect == 0 then
      if not (job.again and #job.again > 0 and game.tick - job.collect_since < WAIT_TICKS) then break end
      job.collect, job.again = job.again, nil
    end
    local m = job.collect[1]
    if m.valid then
      if not approach(rec, job, m.position, e.reach_distance - 0.5) then return false end
      local share = math.ceil(need / (#job.collect + (job.again and #job.again or 0)))
      if keep_waiting(job, m, job.item, share) then return false end
      job.collected = (job.collected or 0) + take_out(e, m, job.item, math.min(need, takeable(m, job.item)))
      if job.count > e.get_item_count(job.item) and (making(m, job.item) or fed_by_drill(m, job.item)) then
        job.again = job.again or {}
        job.again[#job.again + 1] = m
      end
    end
    table.remove(job.collect, 1)
    job.walk, job.wait_from, job.finished, job.progress_at = nil, nil, nil, nil
  end
  job.collect, job.again = nil, nil
  return true
end

-- Collecting `count` of `item` from the machines and storage that have or make it, inside a steps job
-- (give's or insert's making, for more than is hand-mined): waits on furnaces still smelting it.
kinds.collect = {
  start = function(rec, args)
    local e = rec.entity
    local list = machines_with(e, args.item)
    if #list == 0 then util.fail("Nothing nearby has or makes " .. args.item) end
    return {item = args.item, count = e.get_item_count(args.item) + args.count, wanted = args.count, collect = list,
      describe = "collecting " .. args.count .. " " .. args.item .. " from the base"}
  end,
  tick = function(rec, job)
    if not collected(rec, job) then return nil end
    local got = job.collected or 0
    return {collected = got, item = job.item, note = short_note(got, job.wanted, job.item, "that's all the base had")}
  end,
}

-- Small models write "owner" or "me" as the player to give to: that's the owner.
local OWNER_WORDS = {owner = true, ["my owner"] = true, ["your owner"] = true, me = true, you = true, player = true}
local function player_arg(rec, name)
  if type(name) ~= "string" or OWNER_WORDS[name:lower()] then return nil end
  local owner = rec.owner > 0 and game.get_player(rec.owner)
  if owner and owner.name:lower() == name:lower() then return nil end
  return name
end

-- Hand-craft one of a building, as a player's build would.
local function craft_one(rec, name)
  triggers.update(rec)
  rec.entity.begin_crafting{recipe = name, count = 1, silent = true}
  triggers.update(rec)
  rec.crafting = true
end

kinds.place = {
  start = function(rec, args)
    local item = prototypes.item[args.item]
    if not item then util.fail("No item called " .. tostring(args.item) .. "." .. util.did_you_mean(args.item)) end
    if not item.place_result then util.fail("'" .. tostring(args.item) .. "' can't be placed") end
    -- The same building already there: say so first (before walking all the way), so it's used, not rebuilt.
    local existing = rec.entity.surface.find_entities_filtered{name = item.place_result.name,
      position = {x = args.x, y = args.y}, radius = 0.9}[1]
    if existing then
      util.fail("A " .. existing.name .. " is already at " .. serpent.line(util.pos(existing.position)) ..
        ". Use that one (insert fuel or ingredients, take its output) or pick another spot")
    end
    -- None on hand but craftable from the inventory: craft one first, like a player's build would.
    -- Short of ingredients mined by hand (wood for a chest, stone for a furnace), it mines them first.
    local e = rec.entity
    local craft_first, to_gather = false, nil
    if e.get_item_count(args.item) == 0 then
      local recipe = e.force.recipes[args.item]
      if not (recipe and recipe.enabled and (e.prototype.crafting_categories or {})[util.category(recipe)]) then
        util.fail("No " .. args.item .. " in inventory" .. (recipe and not recipe.enabled and ", and it isn't researched yet" or ""))
      end
      craft_first = true
      if e.get_craftable_count(args.item) == 0 then
        local missing, raw = {}, {}
        for _, i in ipairs(recipe.ingredients) do
          local have = e.get_item_count(i.name)
          if have < i.amount then
            missing[#missing + 1] = i.name .. " (have " .. have .. ", need " .. i.amount .. ")"
            if i.type == "item" and #sources_of(i.name) > 0 then raw[#raw + 1] = {item = i.name, count = i.amount} end
          end
        end
        if #raw < #missing then
          util.fail("No " .. args.item .. " in inventory, and crafting one needs " .. table.concat(missing, ", ") .. " (see recipes)")
        end
        to_gather = raw
      end
    end
    if args.recipe ~= nil then
      local recipe = rec.entity.force.recipes[args.recipe]
      if item.place_result.type ~= "assembling-machine" then util.fail(args.item .. " doesn't take a recipe") end
      if not recipe then util.fail("Unknown recipe " .. tostring(args.recipe)) end
      if not recipe.enabled then util.fail(args.recipe .. " isn't researched yet") end
    end
    local direction = util.direction_arg(args.direction)
    local note
    if item.place_result.type == "mining-drill" then
      local problem
      problem, note = check_drill_spot(rec.entity, item.place_result, snapped(item.place_result, args, direction), direction)
      if problem then util.fail(problem) end
    end
    if craft_first and not to_gather then craft_one(rec, args.item) end
    -- Where the game will really put it, so stepping out of the way checks the right spot.
    return {item = args.item, entity = item.place_result.name, position = snapped(item.place_result, args, direction), recipe = args.recipe,
      direction = direction, belt_type = args.belt_type, note = note, to_gather = to_gather,
      describe = (to_gather and "getting what a " .. args.item .. " needs, then placing it") or "placing " .. args.item}
  end,
  tick = function(rec, job)
    local e = rec.entity
    if job.to_gather then
      if not gathered(rec, job) then return nil end
      local nxt = table.remove(job.to_gather, 1)
      if nxt then
        start_gathering(rec, job, nxt.item, nxt.count, job.position)
        return nil
      end
      job.to_gather = nil
      if e.get_craftable_count(job.item) == 0 then util.fail("Gathered the ingredients but still can't craft " .. job.item) end
      craft_one(rec, job.item)
    end
    if job.step_aside then
      if not approach(rec, job, job.step_aside, 0.5) then return nil end
      job.step_aside = nil
    end
    if not approach(rec, job, job.position, math.max(e.build_distance - 1, 2)) then return nil end
    -- Crafted on the way (see start): wait for it.
    if e.get_item_count(job.item) == 0 then
      if e.crafting_queue_size > 0 then return nil end
      util.fail("No " .. job.item .. " in inventory")
    end
    if job.clear_until then
      if game.tick < job.clear_until then return nil end
      job.clear_until = nil
    end
    local spec = {name = job.entity, position = job.position, direction = job.direction, force = e.force,
      build_check_type = defines.build_check_type.manual}
    if not e.surface.can_place_entity(spec) and not job.cleared then
      -- Trees and rocks in the way are chopped first (taking about as long as by hand), like a player would.
      job.cleared = true
      local n = clear_nature(e, job)
      if n > 0 then
        job.clear_until = game.tick + 30 * n
        return nil
      end
    end
    if not e.surface.can_place_entity(spec) then
      -- Standing on the spot blocks placement: step to a clear spot beside it once and retry.
      local spot = not job.stepped and clear_spot(e, job)
      if spot then
        job.step_aside, job.stepped, job.walk = spot, true, nil
        return nil
      end
      local blockers = {}
      for _, other in ipairs(e.surface.find_entities_filtered{position = job.position, radius = 2}) do
        -- Ore under it never blocks; naming it would only send the AI looking for another patch.
        if other.type ~= "resource" and (other ~= e or in_the_way(e, job)) then
          local what = other == e and "you (the engineer is standing there)"
            or (other.type == "character" and other.player and ("player " .. other.player.name .. " standing there"))
            or (other.type == "item-entity" and "items on the ground") or other.name
          blockers[#blockers + 1] = what .. " at " .. serpent.line(util.pos(other.position))
        end
      end
      util.fail("Can't place " .. job.item .. " there" .. (#blockers > 0 and (": blocked by " .. table.concat(blockers, ", ", 1, math.min(#blockers, 5))) or " (terrain or water)"))
    end
    local placed = e.surface.create_entity{name = job.entity, position = job.position, direction = job.direction,
      force = e.force, type = job.belt_type, raise_built = true, create_build_effect_smoke = false}
    if not placed then
      -- Allowed because it replaces what's there, like a splitter put into a belt (a bus row laid through
      -- a slot before that slot was taken): replaced the way a player would, the belt back in the inventory.
      local group = prototypes.entity[job.entity].fast_replaceable_group
      for _, other in ipairs(group and e.surface.find_entities_filtered{position = job.position, radius = 1, force = e.force} or {}) do
        if other.prototype.fast_replaceable_group == group then
          placed = e.surface.create_entity{name = job.entity, position = job.position, direction = job.direction,
            force = e.force, type = job.belt_type, raise_built = true, create_build_effect_smoke = false,
            fast_replace = true, character = e, spill = false}
          break
        end
      end
    end
    if not placed then
      -- (Allowed by the check but not created: usually something it could only fast-replace is there.)
      local there = {}
      for _, other in ipairs(e.surface.find_entities_filtered{position = job.position, radius = 1}) do
        if other.type ~= "resource" then there[#there + 1] = other.name .. " at " .. serpent.line(util.pos(other.position)) end
      end
      util.fail("Placing " .. job.item .. " at " .. serpent.line(util.pos(job.position)) .. " failed"
        .. (#there > 0 and (": " .. table.concat(there, ", ", 1, math.min(#there, 5)) .. " there") or ""))
    end
    e.remove_item({name = job.item, count = 1})
    -- What the engineer built, for keep-busy's build order (the owner's buildings are left alone).
    if placed.unit_number then
      rec.built = rec.built or {}
      rec.built[placed.unit_number] = placed
    end
    local note = job.note
    if job.recipe and not pcall(placed.set_recipe, job.recipe) then note = "Couldn't set recipe " .. job.recipe end
    -- Drills and furnaces only connect when the furnace is right in front of the drill: say whether they do.
    local link = (placed.type == "mining-drill" and drill_output_note(placed))
      or (placed.type == "furnace" and furnace_input_note(placed)) or nil
    if link then note = note and (note .. ". " .. link) or link end
    local fuel = placed.get_fuel_inventory()
    if fuel and fuel.is_empty() then note = (note and (note .. ". ") or "") .. "It needs fuel (coal or wood) to run" end
    return {placed = placed.name, position = util.pos(placed.position), recipe = job.recipe and not note and job.recipe or nil, note = note}
  end,
}

local PICKUP_TICKS = 10 * 60

kinds.pickup = {
  start = function(rec, args)
    -- Not wreckage: a destroyed building's remnants are a corpse, which a character can't mine.
    local target = entity_at(rec.entity.surface, {x = args.x, y = args.y}, function(entity)
      return entity.type ~= "resource" and entity.type ~= "corpse" and entity.minable
    end)
    if not target then util.fail("Nothing to pick up at " .. serpent.line({args.x, args.y})) end
    return {target = target, name = target.name, describe = "picking up " .. target.name}
  end,
  tick = function(rec, job)
    local e = rec.entity
    if not job.target.valid then
      engineer.halt(rec)
      return {picked_up = job.name}
    end
    if not approach(rec, job, job.target.position, e.reach_distance - 0.5) then return nil end
    -- Picking up takes a second or two; one that never finishes would hold up everything else.
    job.since = job.since or game.tick
    if game.tick - job.since > PICKUP_TICKS then
      -- Say what actually went wrong, so a pickup that keeps failing can be told apart from a full inventory.
      local free = e.get_main_inventory().count_empty_stacks()
      local selected = e.selected
      local why = free == 0 and "the inventory is full"
        or (selected ~= job.target and ("the engineer was selecting " .. (selected and selected.name or "nothing") .. " instead"))
        or ("mining got " .. math.floor((e.character_mining_progress or 0) * 100) .. "% of the way, with " .. free .. " empty slots")
      engineer.halt(rec)
      util.fail("Couldn't pick up " .. job.name .. ": " .. why)
    end
    -- Select the target itself: by position, a tree overlapping it can be selected instead (and mined).
    e.selected = job.target
    if e.selected ~= job.target then e.update_selected_entity(job.target.position) end
    e.mining_state = {mining = true, position = job.target.position}
    return nil
  end,
}

local function container_at(rec, args)
  local target = entity_at(rec.entity.surface, {x = args.x, y = args.y}, function(entity)
    return entity.force == rec.entity.force and entity.get_max_inventory_index() > 0
  end)
  if not target then util.fail("No building with an inventory at " .. serpent.line({args.x, args.y})) end
  return target
end


kinds.insert = {
  start = function(rec, args)
    if not prototypes.item[args.item] then util.fail("No item called " .. tostring(args.item) .. "." .. util.did_you_mean(args.item)) end
    local target = container_at(rec, args)
    -- A coal drill fueled with wood can't take the coal it mines, and wood is for poles: drills burn coal.
    if target.type == "mining-drill" and args.item ~= "coal" and prototypes.item[args.item].fuel_value > 0 then
      util.fail("Fuel burner drills with coal only, not " .. args.item ..
        " (a drill holding it can't store the coal it mines, and wood is for power poles). Mine a few coal by hand if you have none")
    end
    local job = {target = target, item = args.item, count = args.count, describe = "putting " .. args.item .. " into " .. target.name}
    local have = rec.entity.get_item_count(args.item)
    if args.count and start_gathering(rec, job, args.item, math.min(args.count, INSERT_BATCH), target.position) then
      job.describe = "getting " .. args.item .. " for the " .. target.name
    elseif args.count and have < args.count then
      -- Plates, bricks or anything hand-crafted: made as give makes them ("put 100 plates in a chest").
      local steps, why, ores = M.make_steps(rec, args.item, math.min(args.count, INSERT_BATCH), nil, args.drills_ready)
      if steps then
        table.remove(steps) -- the give: these go into the building instead
        job.making = kinds.steps.start(rec, {steps = steps})
        job.making.label = "Making " .. args.count .. " " .. args.item .. " for the " .. target.name
        job.describe = "making " .. args.item .. " for the " .. target.name
      elseif ores then
        M.wait_for_drills(rec, why, ores, {kind = "insert", args = {x = args.x, y = args.y, item = args.item, count = args.count}})
      elseif have == 0 then
        util.fail("No " .. args.item .. " in inventory, and you can't make it here: " .. why)
      end
    elseif have == 0 then
      util.fail("No " .. args.item .. " in inventory")
    end
    return job
  end,
  tick = function(rec, job)
    local e = rec.entity
    if not job.target.valid then util.fail("The building is gone") end
    if job.making then
      if not kinds.steps.tick(rec, job.making) then return nil end
      job.making, job.walk = nil, nil
    end
    if not gathered(rec, job) then return nil end
    if not approach(rec, job, job.target.position, e.reach_distance - 0.5) then return nil end
    local done = job.done or 0
    local have = e.get_item_count(job.item)
    local count = math.min(job.count and (job.count - done) or have, have)
    local inserted = count > 0 and job.target.insert({name = job.item, count = count}) or 0
    if inserted > 0 then e.remove_item({name = job.item, count = inserted}) end
    -- A furnace still smelting with no room left: wait for room, as a player feeding it would (a batch of
    -- ore for one furnace can arrive before the last batch is smelted).
    if inserted > 0 or not job.progress_at then job.progress_at = game.tick end
    if inserted < count and job.target.type == "furnace" and job.target.is_crafting()
      and game.tick - job.progress_at < 30 * 60 then
      job.done = done + inserted
      return nil
    end
    if done + inserted == 0 then
      util.fail(count == 0 and ("No " .. job.item .. " in inventory") or (job.target.name .. " won't accept " .. job.item))
    end
    job.done = done + inserted
    local full = not job.target.can_insert({name = job.item})
    -- More to go: mine the next batch and come back.
    if job.count and job.done < job.count and not full and not job.exhausted and inserted == count
      and start_gathering(rec, job, job.item, math.min(job.count - job.done, INSERT_BATCH), job.target.position) then
      job.walk = nil
      return nil
    end
    local note = short_note(job.done, job.count, job.item,
      full and "it's full" or job.exhausted and "none left nearby to mine" or "that's all you had")
    -- A burner machine given ore but no fuel just sits there.
    local fuel = job.target.get_fuel_inventory()
    if fuel and fuel.is_empty() then
      note = (note and (note .. ". ") or "") .. "It has no fuel, so it won't run: insert coal too"
    end
    return {inserted = job.done, item = job.item, into = job.target.name, mined_first = job.mined,
      now_holds = job.target.get_item_count(job.item), full = full or nil, note = note}
  end,
}

-- Hand items to the owner, or to another player by name when the owner lets everyone talk to the
-- engineer: walk up to them (they may be moving) and put the items in their inventory.
local function receiver(rec, name)
  local player
  if name then
    player = game.get_player(name)
    if not player then util.fail("No player called " .. tostring(name)) end
    if player.index ~= rec.owner and not ((storage.options or {})[rec.owner] or {}).everyone then
      util.fail("You can only give items to your owner")
    end
  else
    player = rec.owner > 0 and game.get_player(rec.owner) or nil
  end
  local character = player and player.connected and player.character
  if character and character.valid and character.surface == rec.entity.surface then return character end
end

-- The smelting recipe making `item` from something mined by hand (iron-plate from iron-ore), if any.
local function smelted_from(e, item)
  for _, r in pairs(e.force.recipes) do
    local p = r.prototype.main_product
    if r.enabled and p and p.name == item and util.category(r) == "smelting" and #r.ingredients == 1
      and #sources_of(r.ingredients[1].name) > 0 then return r end
  end
end

-- The raw materials (name -> count) missing to have `count` of `item`, counted as hand-crafting would use
-- them (intermediates in the inventory first), and how many times `item` itself is hand-crafted (0 when it
-- isn't: then it's one of the raw materials).
local function raw_for(e, item, count)
  local avail, raw, times = {}, {}, 0
  local handcraft = e.prototype.crafting_categories or {}
  local function need(name, n, top)
    if avail[name] == nil then avail[name] = e.get_item_count(name) end
    local use = math.min(avail[name], n)
    avail[name], n = avail[name] - use, n - use
    if n <= 0 then return end
    local recipe = e.force.recipes[name]
    if recipe and recipe.enabled and handcraft[util.category(recipe)] then
      local makes = recipe.products[1].amount or 1
      local t = math.ceil(n / makes)
      if top then times = t end
      for _, i in ipairs(recipe.ingredients) do need(i.name, i.amount * t) end
      avail[name] = avail[name] + t * makes - n
    else
      raw[name] = (raw[name] or 0) + n
    end
  end
  need(item, count, true)
  return raw, times
end

-- "Give me 10 iron plates" or "make me 10 magazines" with none to be had: the steps a player would take.
-- Hand-mined materials are mined; plates are smelted in furnaces of ours nearby that are free (or new ones
-- beside the engineer), two for big orders, with just the coal they burn, each plate's ore in turn fed in
-- batches as it's mined and the plates taken out as they come; then the item is hand-crafted, and a give
-- hands it over. Returns nil and why when something needed can't be mined, smelted or hand-crafted.
local SMELT_BATCH = 50 -- ore per insert: a stone furnace's input slot holds one stack of 50

-- Whether the base can supply `n` of `item`: machines and storage have that many ready, or a furnace or
-- assembler is making it, or a drill feeds a furnace or chest with it.
local function supplied(e, item, n)
  local ready, busy = 0, false
  for _, m in ipairs(machines_with(e, item)) do
    ready = ready + takeable(m, item)
    busy = busy or making(m, item) ~= nil or fed_by_drill(m, item)
  end
  return ready >= n or busy
end

-- The owner's rule: an order for more than BIG_ORDER of something gets a few drills making it, at least
-- BIG_DRILLS drill-and-furnace pairs (or drills filling chests), so it isn't one burner drill's trickle.
local BIG_ORDER, BIG_DRILLS = 50, 3

-- Furnaces and chests within SUPPLY_RADIUS that a drill feeds `item` to (one per drill pair).
local function drill_fed(e, item)
  local n = 0
  for _, m in ipairs(e.surface.find_entities_filtered{position = e.position, radius = SUPPLY_RADIUS, force = e.force,
      type = {"furnace", "container"}}) do
    if fed_by_drill(m, item) then n = n + 1 end
  end
  return n
end

-- Returns the steps, or nil, why and (when the base needs drills for it first) the ores to build them for.
-- `drills_ready`: the order's drills were just built for it (autopilot's M.starter), so it doesn't ask again.
local function make_steps(rec, item, count, player, drills_ready)
  local e = rec.entity
  local raw, times = raw_for(e, item, count)
  local steps, smelts, missing, starter = {}, {}, {}, {}
  for name, n in pairs(raw) do
    local recipe = smelted_from(e, name)
    local runs = recipe and math.ceil(n / (recipe.prototype.main_product.amount or 1))
    -- What would be mined by hand for it: the ore for plates, else the item itself.
    local ore, ore_n = name, n
    if recipe then ore, ore_n = recipe.ingredients[1].name, runs * recipe.ingredients[1].amount end
    -- A big order with fewer than a few drills making it: more drills first, even if the base has some.
    local drills = n > BIG_ORDER and from_patch(ore) and not by_build_order(rec) and BIG_DRILLS or 1
    local short_of_drills = drills > 1 and not drills_ready and drill_fed(e, name) < drills
    if supplied(e, name, n) and not short_of_drills then
      steps[#steps + 1] = {action = "collect", item = name, count = n}
    elseif (recipe or #sources_of(name) > 0) and (short_of_drills or too_much_by_hand(rec, ore, ore_n)) then
      -- Plates come from a drill feeding a furnace, raw ore (or coal, stone) from a drill filling a chest.
      starter[#starter + 1] = {ore = ore, kind = recipe and "pair" or "chest", target = drills, count = ore_n}
    elseif recipe then
      smelts[#smelts + 1] = {recipe = recipe, plate = name, count = n, runs = runs}
    elseif #sources_of(name) > 0 then
      steps[#steps + 1] = {action = "mine", name = name, count = n}
    else
      missing[#missing + 1] = name
    end
  end
  if #missing > 0 then
    return nil, "it needs " .. table.concat(missing, ", ") .. ", which can't be mined, smelted or hand-crafted here"
  end
  if #starter > 0 then
    local names = {}
    for _, s in ipairs(starter) do names[#names + 1] = s.ore end
    return nil, "it takes more " .. table.concat(names, " and ") .. " than is mined by hand (over " .. HAND_MAX ..
      "), and not enough drills make it yet (a big order gets at least " .. BIG_DRILLS .. ")", starter
  end
  if #smelts > 0 then
    local plates, runs = {}, 0
    for _, s in ipairs(smelts) do
      plates[s.plate] = true
      runs = runs + s.runs
    end
    -- Hand-mining is the slow part (about 2 s an ore): a big order gets a second furnace, fed a batch at a
    -- time as the ore is mined, so the smelting keeps up instead of starting once it's all mined.
    local wanted = runs > SMELT_BATCH and 2 or 1
    local furnaces = {} -- {at, proto, stored}
    local candidates = e.surface.find_entities_filtered{position = e.position, radius = 32, force = e.force, type = "furnace"}
    table.sort(candidates, function(a, b) return util.distance(a.position, e.position) < util.distance(b.position, e.position) end)
    for _, f in ipairs(candidates) do
      local input, output = f.get_inventory(defines.inventory.crafter_input), f.get_output_inventory()
      local free = output.is_empty()
      for _, stack in ipairs(output.get_contents()) do free = free or plates[stack.name] end
      if input.is_empty() and free and #furnaces < wanted then
        -- Fuel energy already in it: the burning item's rest and what's in its fuel slot.
        local stored = f.burner and f.burner.remaining_burning_fuel or 0
        local fuel = f.get_fuel_inventory()
        for _, stack in ipairs(fuel and fuel.get_contents() or {}) do
          stored = stored + stack.count * prototypes.item[stack.name].fuel_value
        end
        furnaces[#furnaces + 1] = {at = util.pos(f.position), proto = f.prototype, stored = stored}
      end
    end
    local name = e.get_item_count("steel-furnace") > 0 and "steel-furnace" or "stone-furnace"
    local proto = prototypes.entity[name]
    -- New ones a few tiles off (so the engineer isn't standing there), side by side.
    for dx = 3, 15, 2 do
      for _, dy in ipairs({0, 3, -3}) do
        local p = snapped(proto, {x = e.position.x + dx, y = e.position.y + dy}, defines.direction.north)
        local clear = #furnaces < wanted and e.surface.can_place_entity{name = name, position = p, force = e.force}
        for _, f in ipairs(furnaces) do
          if math.abs(f.at.x - p.x) < 2.5 and math.abs(f.at.y - p.y) < 2.5 then clear = false end
        end
        if clear then
          furnaces[#furnaces + 1] = {at = p, proto = proto, stored = 0}
          steps[#steps + 1] = {action = "place", item = name, x = p.x, y = p.y}
        end
      end
    end
    if #furnaces == 0 then return nil, "there's no room nearby for a furnace" end
    -- Just the coal the smelting burns (a stone furnace: 288 kJ a plate, 4 MJ a coal, so 13.9 plates each),
    -- shared between the furnaces like the ore.
    for _, f in ipairs(furnaces) do
      local burner = f.proto.burner_prototype
      if burner then
        local energy = 0
        for _, s in ipairs(smelts) do energy = energy + s.runs * s.recipe.energy / #furnaces end
        local per_tick = f.proto.energy_usage or f.proto.get_max_energy_usage()
        local needed = energy / f.proto.get_crafting_speed() * 60 * per_tick / (burner.effectivity or 1)
        local coal = math.ceil((needed - f.stored) / prototypes.item.coal.fuel_value)
        if coal > 0 then steps[#steps + 1] = {action = "insert", x = f.at.x, y = f.at.y, item = "coal", count = coal} end
      end
    end
    -- Each plate in turn (a furnace holds one kind of ore): its ore in batches across the furnaces, then
    -- each furnace's plates taken out as they come.
    for _, s in ipairs(smelts) do
      local ore = s.recipe.ingredients[1]
      local each = s.recipe.prototype.main_product.amount or 1
      local share = {}
      local left, i = s.runs, 0
      while left > 0 do
        local batch = math.min(left, SMELT_BATCH)
        local f = furnaces[i % #furnaces + 1]
        steps[#steps + 1] = {action = "insert", x = f.at.x, y = f.at.y, item = ore.name, count = batch * ore.amount}
        share[f] = (share[f] or 0) + batch
        left, i = left - batch, i + 1
      end
      local due = s.count
      for _, f in ipairs(furnaces) do
        local n = math.min(due, (share[f] or 0) * each)
        if n > 0 then steps[#steps + 1] = {action = "take", x = f.at.x, y = f.at.y, item = s.plate, count = n} end
        due = due - n
      end
    end
  end
  if times > 0 then steps[#steps + 1] = {action = "craft", recipe = item, count = times} end
  steps[#steps + 1] = {action = "give", item = item, count = count, player = player, made = true}
  return steps
end
M.make_steps = make_steps -- for test-game (give needs a player, which a headless test has none of)

-- An order (give or insert) that needs drills first: the build order builds keep-busy's early base for it
-- (autopilot's M.starter: a drill and furnace or chest per ore, fueled for the order, and a coal loop
-- for a big one), then starts the order itself. Fails, so the AI is told now and doesn't start anything
-- else meanwhile.
local function wait_for_drills(rec, why, ores, order)
  rec.starter = {ores = ores, order = order, since = game.tick}
  local parts, big = {}, false
  for _, s in ipairs(ores) do
    local n = s.target or 1
    big = big or n > 1
    parts[#parts + 1] = (n > 1 and (n .. " drills, each with a ") or "a drill and ") .. (s.kind == "pair" and "furnace" or "chest") .. ", for " .. s.ore
  end
  util.fail("Not started yet: " .. why .. ". You're building the drills for it now (" ..
    table.concat(parts, ", ") .. (big and ", and a coal loop to fuel them" or "") .. ") with no more tool calls, then you do this " ..
    order.kind .. "; you'll get its job_done. Tell your owner in a sentence what you're building (\"I'm building a drill...\", " ..
    "never that the game or anyone else builds it) and start nothing else meanwhile")
end
M.wait_for_drills = wait_for_drills

-- Starts making the rest of a give's items as a steps job inside it; false (and job.why, and job.ores when
-- it needs drills first) when it can't.
local function start_making(rec, job)
  local steps, why, ores = make_steps(rec, job.item, job.count, job.player, job.drills_ready)
  if not steps then
    job.why, job.ores = why, ores
    return false
  end
  job.making, job.walk = kinds.steps.start(rec, {steps = steps}), nil
  job.making.label = "Making " .. job.count .. " " .. job.item
  return true
end

-- Hand-crafting inside a steps job (give's making): queued, then done once the queue is empty.
kinds.craft = {
  start = function(rec, args)
    local e = rec.entity
    -- Collecting may have come up short (the base ran dry): as many as it can, and the give says how many.
    local count = math.min(args.count, e.get_craftable_count(args.recipe))
    if count == 0 then
      util.fail("Can't hand-craft " .. args.count .. " " .. args.recipe .. " from what's in the inventory")
    end
    triggers.update(rec)
    e.begin_crafting{recipe = args.recipe, count = count, silent = true}
    triggers.update(rec)
    return {item = args.recipe, count = count, describe = "crafting " .. count .. " " .. args.recipe}
  end,
  tick = function(rec, job)
    if rec.entity.crafting_queue_size > 0 then return nil end
    return {crafted = job.count, item = job.item}
  end,
}

kinds.give = {
  start = function(rec, args)
    if not prototypes.item[args.item] then util.fail("No item called " .. tostring(args.item) .. "." .. util.did_you_mean(args.item)) end
    local player = player_arg(rec, args.player)
    local who = player or "Your owner"
    if not receiver(rec, player) then util.fail(who .. " isn't here to take it (not in the game, or on another surface)") end
    local have = rec.entity.get_item_count(args.item)
    local job = {item = args.item, count = args.count, player = player,
      describe = "giving " .. args.item .. " to " .. (player or "you")}
    -- In order: what machines and chests nearby have, mining what's mined by hand, else making it.
    job.made, job.drills_ready = args.made, args.drills_ready
    local short = args.count and have < args.count
    -- A big order of plates or ore that too few drills make: planned (drills first), not collected now.
    local e = rec.entity
    local big = short and not args.drills_ready and not args.made and args.count - have > BIG_ORDER
      and (smelted_from(e, args.item) or from_patch(args.item)) and drill_fed(e, args.item) < BIG_DRILLS
    local collect = short and not big and machines_with(e, args.item) or {}
    if #collect > 0 then
      job.collect = collect
      job.describe = "collecting " .. args.item .. " for " .. (player or "you")
    elseif start_gathering(rec, job, args.item, args.count or (have > 0 and have or 10), receiver(rec, player).position) then
      job.count = job.count or 10
      job.describe = "getting " .. args.item .. " for " .. (player or "you")
    elseif short and not job.made and start_making(rec, job) then
      job.describe = "making " .. args.item .. " for " .. (player or "you")
    elseif job.ores then
      wait_for_drills(rec, job.why, job.ores, {kind = "give", args = {item = args.item, count = args.count, player = player}})
    elseif have == 0 then
      util.fail("No " .. args.item .. " in inventory or nearby, and you can't make it here: " ..
        (job.why or "there's no recipe you can hand-craft"))
    end
    return job
  end,
  tick = function(rec, job)
    local e = rec.entity
    if job.making then
      local done = kinds.steps.tick(rec, job.making)
      if not done then return nil end
      local result = done.results[#done.results]
      result.made_first = true
      return result
    end
    if not gathered(rec, job) then return nil end
    if not collected(rec, job) then return nil end
    -- Collected what there was and still short: make the rest.
    if job.count and e.get_item_count(job.item) < job.count and not job.made and not job.tried_making then
      job.tried_making = true
      if start_making(rec, job) then
        job.describe = "making the rest of the " .. job.item
        return nil
      end
      if job.ores then
        wait_for_drills(rec, job.why, job.ores, {kind = "give", args = {item = job.item, count = job.count, player = job.player}})
      end
    end
    local character = receiver(rec, job.player)
    if not character then util.fail((job.player or "Your owner") .. " left before the items could be handed over") end
    -- Re-target only when the owner has moved away from the current goal, as follow_me does.
    local goal = job.walk and job.walk.target
    if not goal or util.distance(goal, character.position) > 3 then goal = character.position end
    if not approach(rec, job, goal, 3) then return nil end
    if util.distance(e.position, character.position) > e.reach_distance then return nil end
    local have = e.get_item_count(job.item)
    local count = math.min(job.count or have, have)
    if count == 0 then util.fail("No " .. job.item .. " in inventory") end
    local given = character.insert({name = job.item, count = count})
    if given > 0 then e.remove_item({name = job.item, count = given}) end
    if given == 0 then util.fail((job.player and (job.player .. "'s") or "Your owner's") .. " inventory is full") end
    return {given = given, item = job.item, mined_first = job.mined, collected_first = job.collected,
      note = short_note(given, job.count, job.item, given < have and "their inventory is full" or "that's all you had and all that was ready nearby")}
  end,
}

-- Walk over to the owner (or a named player) and stop there, unlike follow, which never ends.
kinds.come = {
  start = function(rec, args)
    local player = player_arg(rec, args.player)
    if not receiver(rec, player) then
      util.fail((player or "Your owner") .. " isn't here (not in the game, or on another surface)")
    end
    return {player = player, describe = "coming to " .. (player or "you")}
  end,
  tick = function(rec, job)
    local character = receiver(rec, job.player)
    if not character then util.fail((job.player or "Your owner") .. " left") end
    -- Re-target only when they've moved away from the current goal, as follow does.
    local goal = job.walk and job.walk.target
    if not goal or util.distance(goal, character.position) > 3 then goal = character.position end
    if not approach(rec, job, goal, 3) then return nil end
    if util.distance(rec.entity.position, character.position) > 4 then return nil end
    return {position = util.pos(rec.entity.position)}
  end,
}

-- Up to `count` of `item` off the belts in reach (a belt tile holds 8), as much as fits.
local function take_off_belts(e, item, count)
  local inv = e.get_main_inventory()
  local got = 0
  for _, belt in ipairs(e.surface.find_entities_filtered{type = "transport-belt", position = e.position, radius = e.reach_distance - 0.5, force = e.force}) do
    for l = 1, belt.get_max_transport_line_index() do
      local line = belt.get_transport_line(l)
      local n = math.min(line.get_item_count(item), count - got)
      if n > 0 and inv.can_insert{name = item, count = n} then
        local removed = line.remove_item{name = item, count = n}
        local kept = removed > 0 and e.insert{name = item, count = removed} or 0
        if kept < removed then line.insert_at_back({name = item, count = removed - kept}) end
        got = got + kept
      end
    end
    if got >= count then break end
  end
  return got
end

kinds.take = {
  start = function(rec, args)
    local belt = args.item and rec.entity.surface.find_entities_filtered{position = {x = args.x, y = args.y}, type = "transport-belt"}[1]
    local target = belt or container_at(rec, args)
    return {target = target, item = args.item, count = args.count, describe = "taking from " .. target.name}
  end,
  tick = function(rec, job)
    local e = rec.entity
    if not job.target.valid then util.fail("The building is gone") end
    if not approach(rec, job, job.target.position, e.reach_distance - 0.5) then return nil end
    if job.target.type == "transport-belt" then
      local got = take_off_belts(e, job.item, job.count or 50)
      if got == 0 then util.fail("No " .. job.item .. " on the belts here") end
      return {taken = {{name = job.item, count = got}}, from = "belts"}
    end
    -- Asked for more than is ready: wait while the machine is still making them.
    if job.item and job.count then
      if keep_waiting(job, job.target, job.item, job.count) then
        job.describe = "waiting for " .. job.item .. " from the " .. job.target.name
        return nil
      end
    end
    local wanted = {}
    if job.item then
      wanted[1] = {name = job.item, count = math.min(job.count or math.huge, job.target.get_item_count(job.item))}
    else
      local output = job.target.get_output_inventory() or job.target.get_inventory(defines.inventory.chest)
      for _, stack in ipairs(output and output.get_contents() or {}) do wanted[#wanted + 1] = {name = stack.name, count = stack.count, quality = stack.quality} end
    end
    local taken = {}
    for _, stack in ipairs(wanted) do
      local kept = take_out(e, job.target, stack.name, stack.count, stack.quality)
      if kept > 0 then taken[#taken + 1] = {name = stack.name, count = kept} end
    end
    if #taken == 0 then
      util.fail("Nothing to take" .. (job.item and (" (" .. job.item .. ")") or "") .. " from the " .. job.target.name ..
        (job.item and making(job.target, job.item) and " yet: it's still making the first one" or
        ". take moves items out of a building; to put items in, use insert"))
    end
    local you_have = job.item and e.get_item_count(job.item) or nil
    local note = job.item and short_note(taken[1].count, job.count, job.item,
      making(job.target, job.item) and "the rest are still being made there, but too slowly to wait for (check its fuel); take them later" or "that's all it had")
    -- How many it holds now: a model that took 5 bricks twice told its owner it only had 5.
    return {taken = taken, from = job.target.name, you_now_have = you_have, note = note}
  end,
}

-- Several jobs in a row, reported as one: the AI is woken once at the end, or at the first failure.
-- Each step starts only when the one before it is done, so it sees the inventory as it is then.
local STEP_KINDS = {walk_to = "walk", mine = "mine", place = "place", pick_up = "pickup", insert = "insert", take = "take", give = "give"}
M.STEP_ACTIONS = STEP_KINDS

local STEP_TICKS = 3 * 60 * 60 -- a step still going after this long is stuck somewhere: end it, saying where

local function step_failure(job, result)
  local message = type(result) == "table" and result.message or tostring(result)
  local current = job.current and job.current.describe or job.steps[math.max(job.index, 1)].action
  local done = job.index - 1
  util.fail("Step " .. job.index .. " of " .. #job.steps .. " failed (" .. current .. "): " .. message ..
    (done > 0 and (". The " .. (done == 1 and "first step is" or ("first " .. done .. " steps are")) .. " done.") or ""))
end

kinds.steps = {
  start = function(_, args)
    return {steps = args.steps, index = 0, results = {}, describe = #args.steps .. " steps"}
  end,
  tick = function(rec, job)
    local e = rec.entity
    if job.watched ~= job.index then
      job.watched, job.watched_since = job.index, game.tick
    elseif job.current and job.current.progress_at and game.tick - job.current.progress_at < 600 then
      -- Waiting on a machine that keeps finishing items (40 plates take a stone furnace over 2 minutes).
      job.watched_since = game.tick
    elseif game.tick - job.watched_since > STEP_TICKS then
      local walk = job.current and (job.current.gather or job.current).walk
      step_failure(job, "it took over 3 minutes (the engineer at " .. serpent.line(util.pos(e.position)) ..
        (walk and (", walking to " .. serpent.line(util.pos(walk.target))) or "") ..
        (e.crafting_queue_size > 0 and (", " .. e.crafting_queue_size .. " crafts queued") or "") .. ")")
    end
    if not job.current then
      local step = job.steps[job.index + 1]
      if not step then return {steps_done = #job.steps, results = job.results} end
      -- "craft" and "collect" only come from give's and insert's own plans (make_steps), not the steps tool.
      local kind = STEP_KINDS[step.action] or ((step.action == "craft" or step.action == "collect") and step.action)
      -- An item still being hand-crafted: wait for it instead of failing.
      if (kind == "place" or kind == "insert" or kind == "give") and type(step.item) == "string" and prototypes.item[step.item]
        and e.get_item_count(step.item) == 0 and e.crafting_queue_size > 0 then return nil end
      job.index = job.index + 1
      local ok, sub = pcall(kinds[kind].start, rec, step)
      if not ok then step_failure(job, sub) end
      sub.kind = kind
      job.current = sub
      -- A long make (give's or insert's) says how it's going in the chat window, so it doesn't look stuck.
      local player = job.label and rec.owner > 0 and game.get_player(rec.owner)
      if player and player.connected then
        gui.note(player, job.label .. ": step " .. job.index .. " of " .. #job.steps .. ", " .. sub.describe)
      end
    end
    local ok, result = pcall(kinds[job.current.kind].tick, rec, job.current)
    if not ok then step_failure(job, result) end
    if result then
      job.results[#job.results + 1] = result
      job.current = nil
      engineer.halt(rec)
    end
    return nil
  end,
}

---------------------------------------------------------------------------

-- `auto`: keep-busy's build order started it (see autopilot.lua); its end doesn't wake the AI.
function M.start(rec, kind, args, auto)
  starting_auto = auto ~= nil
  local ok, job = pcall(kinds[kind].start, rec, args)
  starting_auto = nil
  if not ok then error(job, 0) end
  local replaced = rec.job and rec.job.describe
  engineer.halt(rec)
  job.kind = kind
  if auto then
    job.auto = auto
    job.describe = "build order: " .. job.describe
  end
  rec.job = job
  return {started = job.describe, replaced = replaced}
end

function M.cancel(rec)
  local had = rec.job and rec.job.describe
  rec.job = nil
  engineer.halt(rec)
  return had
end

-- Picks up a job that was set aside (an order, for autopilot's refueling trip): its walks start over from
-- where the engineer is now, and the trip doesn't count as a machine or step stalling.
function M.resume(rec, job)
  local seen = {}
  local function reset(t)
    if seen[t] then return end
    seen[t] = true
    t.walk = nil
    if t.progress_at then t.progress_at = game.tick end
    if t.watched_since then t.watched_since = game.tick end
    for _, v in pairs(t) do
      if type(v) == "table" then reset(v) end
    end
  end
  reset(job)
  engineer.halt(rec)
  rec.job = job
end

function M.describe(rec)
  local job = rec.job
  if not job then return nil end
  local d = {kind = job.kind, doing = job.describe}
  if job.kind == "steps" then
    d.doing = "step " .. math.max(job.index, 1) .. " of " .. #job.steps .. (job.current and (": " .. job.current.describe) or "")
    job = job.current or {}
  end
  if job.kind == "mine" then
    d.wanted = job.wanted
    d.done = job.item and (rec.entity.get_item_count(job.item) - job.start_count) or job.mined
  end
  return d
end

local function finish(rec, job, ok, result)
  if rec.job ~= job then return end
  rec.job = nil
  engineer.halt(rec)
  if job.auto then
    if M.on_auto_finished then M.on_auto_finished(rec, job, ok, result) end
    return
  end
  util.emit(rec.owner, ok and "job_done" or "job_failed",
    {job = job.describe, result = ok and result or nil, reason = (not ok) and result or nil})
end

function M.tick()
  for _, rec in pairs(storage.engineers) do
    local job, e = rec.job, rec.entity
    if e and e.valid and game.tick % 15 == 0 then
      engineer.defend(rec)
      engineer.care(rec)
    end
    if job and e and e.valid then
      local ok, result = pcall(kinds[job.kind].tick, rec, job)
      if not ok then
        finish(rec, job, false, type(result) == "table" and result.message or tostring(result))
      elseif result then
        finish(rec, job, true, result)
      end
    end
    if (rec.crafting or rec.queued) and e and e.valid then triggers.update(rec) end
    if rec.crafting and e and e.valid and e.crafting_queue_size == 0 then
      rec.crafting = false
      util.emit(rec.owner, "crafting_done", {inventory = util.contents(e.get_main_inventory()), unlocked = rec.unlocked})
      rec.unlocked = nil
    end
    if rec.remind and game.tick >= rec.remind.tick then
      util.emit(rec.owner, "reminder", {note = rec.remind.note})
      rec.remind = nil
    end
  end
end

return M
