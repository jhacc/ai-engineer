local M = {}

function M.distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- A recipe's crafting category (a recipe or its prototype). Factorio 2.1 gives recipes a list of them
-- (every base recipe has one); 2.0 had a single `category`. Plain tables standing in for recipes (in
-- plans and tests) keep `category`.
function M.category(recipe)
  if type(recipe) == "table" and recipe.category then return recipe.category end
  local list = recipe.categories
  return list and list[1] or "crafting"
end

-- Positions sent to the app, rounded to 0.1 tiles.
function M.pos(p)
  return {x = math.floor(p.x * 10 + 0.5) / 10, y = math.floor(p.y * 10 + 0.5) / 10}
end

-- walking_state takes one of 8 directions; y grows southward.
local DIRECTIONS = {"east", "southeast", "south", "southwest", "west", "northwest", "north", "northeast"}
function M.direction_to(from, to)
  local angle = math.atan2(to.y - from.y, to.x - from.x)
  local index = math.floor(angle / (2 * math.pi) * 8 + 0.5) % 8
  return defines.direction[DIRECTIONS[index + 1]]
end

-- Tool arguments use 0-3 for north/east/south/west.
local FOUR = {[0] = "north", "east", "south", "west"}
function M.direction_arg(value)
  return defines.direction[FOUR[value or 0] or "north"]
end
function M.direction_index(direction)
  for i = 0, 3 do if defines.direction[FOUR[i]] == direction then return i end end
end

-- Inventory contents as a sorted list; nil when empty (an empty Lua table serializes as {}).
function M.contents(inventory)
  if not (inventory and inventory.valid) then return nil end
  local list = inventory.get_contents()
  if #list == 0 then return nil end
  table.sort(list, function(a, b) return a.name < b.name end)
  for _, item in ipairs(list) do if item.quality == "normal" then item.quality = nil end end
  return list
end

-- How worrying an enemy at distance `d` is, in words (the AI misjudges raw tile distances).
function M.threat(d)
  if d <= 20 then return "close: in attack range" end
  if d <= 50 then return "nearby: keep an eye on it" end
  return "far: no threat, ignore unless it comes closer"
end

-- How close the engineer may go to an enemy nest or worm. Defenders attack anyone near their base,
-- and a pistol can't win that fight.
M.NEST_CLEARANCE = 40

-- Positions of enemy nests and worms within `radius` of `position`.
function M.enemy_bases(surface, position, radius)
  local bases = {}
  for _, entity in ipairs(surface.find_entities_filtered{position = position, radius = radius, force = "enemy",
    type = {"unit-spawner", "turret"}}) do
    bases[#bases + 1] = {name = entity.name, position = entity.position}
  end
  return bases
end

-- The base from `bases` within NEST_CLEARANCE of `position`, if any.
function M.base_near(bases, position)
  for _, base in ipairs(bases) do
    if M.distance(base.position, position) < M.NEST_CLEARANCE then return base end
  end
end

-- The building a drill drops its output into, or nil when it drops on the ground. drop_target isn't
-- always set yet for a building placed after the drill, so look at the drop position too.
function M.drill_target(drill)
  local target = drill.drop_target
  if target and target.valid then return target end
  local p = drill.drop_position
  for _, entity in ipairs(drill.surface.find_entities_filtered{area = {{p.x - 0.01, p.y - 0.01}, {p.x + 0.01, p.y + 0.01}},
    force = drill.force}) do
    if entity ~= drill and entity.type ~= "character" and (entity.get_fuel_inventory() or entity.get_output_inventory()
      or entity.type == "container") then
      drill.drop_target = entity
      return entity
    end
  end
end

-- Whatever else is on a tile, these don't stop building there (trees and rocks are chopped when placing).
M.PASSABLE = {"resource", "tree", "simple-entity", "character", "item-entity", "corpse", "fire", "projectile",
  "explosion", "sticker"}

-- Whether `name` can go at p facing dir (0-3) once the trees and rocks there are chopped (the place job
-- does that first, like a player would). Trees never make a spot unusable: in a forest every spot has some.
-- `removable` (unit numbers as keys) is what gets picked up first, so it doesn't count either.
function M.can_build(surface, force, name, p, dir, removable)
  if surface.can_place_entity{name = name, position = p, direction = M.direction_arg(dir), force = force,
    build_check_type = defines.build_check_type.manual} then return true end
  local box = prototypes.entity[name].collision_box
  local hx, hy = box.right_bottom.x - 0.05, box.right_bottom.y - 0.05
  if dir == 1 or dir == 3 then hx, hy = hy, hx end
  local area = {{p.x - hx, p.y - hy}, {p.x + hx, p.y + hy}}
  if surface.count_tiles_filtered{area = area, collision_mask = "water_tile"} > 0 then return false end
  if not removable then return surface.count_entities_filtered{area = area, type = M.PASSABLE, invert = true} == 0 end
  for _, other in ipairs(surface.find_entities_filtered{area = area, type = M.PASSABLE, invert = true}) do
    if not (other.unit_number and removable[other.unit_number]) then return false end
  end
  return true
end

local status_names
function M.status_name(status)
  if not status then return nil end
  if not status_names then
    status_names = {}
    for name, value in pairs(defines.entity_status) do status_names[value] = name end
  end
  return status_names[status]
end

-- Queue an event for the owner's helper app (job finished, engineer died, ...).
function M.emit(owner, kind, data)
  storage.seq = storage.seq + 1
  local events = storage.events
  events[#events + 1] = {id = storage.seq, owner = owner, kind = kind, data = data, tick = game.tick}
  while #events > 200 do table.remove(events, 1) end
end

function M.fail(message)
  error({expected = true, message = message}, 0)
end

-- What players call things, for guessing the item an unknown name meant ("wooden-box" -> wooden-chest).
local SYNONYMS = {box = "chest", crate = "chest", storage = "chest", plank = "wood", planks = "wood", log = "wood",
  logs = "wood", plate = "plate", plates = "plate", gear = "gear", gears = "gear", cog = "gear", miner = "drill",
  smelter = "furnace", oven = "furnace", rock = "stone", rocks = "stone", ore = "ore", wire = "cable", cables = "cable",
  pole = "pole", poles = "pole", belt = "belt", belts = "belt", conveyor = "belt", arm = "inserter", pipes = "pipe",
  assembler = "assembling", science = "science", pack = "pack"}

local ITEM_ALIASES = {ammo = "firearm-magazine", bullets = "firearm-magazine", magazine = "firearm-magazine",
  magazines = "firearm-magazine", ["iron-plates"] = "iron-plate", ["copper-plates"] = "copper-plate", gun = "pistol"}

local function words(name)
  local out = {}
  for word in name:lower():gmatch("[%a%d]+") do out[SYNONYMS[word] or word] = true end
  return out
end

-- "Did you mean ...": the item name sharing the most words with `name` (after synonyms), or nil.
function M.suggest(name)
  if type(name) ~= "string" then return nil end
  -- Player words for one item ("make 100 ammo" found flamethrower ammo by word overlap).
  local alias = ITEM_ALIASES[name:lower()]
  if alias and prototypes.item[alias] then return alias end
  local wanted = words(name)
  local best, best_score = nil, 0
  for item_name, proto in pairs(prototypes.item) do
    if not proto.hidden then
      local score, extra = 0, 0
      for word in pairs(words(item_name)) do
        if wanted[word] then score = score + 1 else extra = extra + 1 end
      end
      score = score - extra * 0.1 -- prefer the plainer name: wooden-chest over a longer one
      if score > best_score then best, best_score = item_name, score end
    end
  end
  return best
end

-- " Did you mean wooden-chest?" or "".
function M.did_you_mean(name)
  local guess = M.suggest(name)
  return guess and guess ~= name and (" Did you mean " .. guess .. "?") or ""
end

return M
