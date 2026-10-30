-- Finding water and laying out steam power by it (find water and the build order both use this).
local util = require("scripts.util")
local M = {}

-- Water is tiles, not entities. Search outward in thin rings so a big lake can't return
-- hundreds of thousands of tiles in one go; returns the nearest water tile's center.
local WATER_RADII = {8, 16, 32, 64, 128, 192, 256, 384, 512}
function M.nearest_water(surface, from, max_radius)
  for _, radius in ipairs(WATER_RADII) do
    radius = math.min(radius, max_radius)
    local best, best_d
    for _, tile in ipairs(surface.find_tiles_filtered{position = from, radius = radius, collision_mask = "water_tile"}) do
      local p = {x = tile.position.x + 0.5, y = tile.position.y + 0.5}
      local d = util.distance(from, p)
      if not best_d or d < best_d then best, best_d = p, d end
    end
    if best or radius >= max_radius then return best, best_d end
  end
end

-- A land tile next to `water` (the one closest to `from`): somewhere to stand at the shore.
function M.shore_next_to(surface, water, from)
  local best, best_d
  for _, offset in ipairs({{0, -1}, {1, 0}, {0, 1}, {-1, 0}}) do
    local p = {x = water.x + offset[1], y = water.y + offset[2]}
    if not surface.get_tile(p.x, p.y).collides_with("water_tile") then
      local d = util.distance(from, p)
      if not best_d or d < best_d then best, best_d = p, d end
    end
  end
  return best
end

-- Trees and rocks don't count (placing chops them), except for the pump, which needs the shore as it is.
local function can_place(surface, force, name, position, dir)
  if name ~= "offshore-pump" then return util.can_build(surface, force, name, position, dir) end
  return surface.can_place_entity{name = name, position = position, direction = util.direction_arg(dir),
    force = force, build_check_type = defines.build_check_type.manual}
end

-- Unit steps for directions 0-3 (north, east, south, west); y grows southward.
local STEP = {[0] = {0, -1}, {1, 0}, {0, 1}, {-1, 0}}

-- Where to build by `water`, closest to `from`: an offshore pump (facing the water), and when there's room
-- a boiler on the pump's output and a steam engine on the boiler's steam output, which connect as placed.
function M.spot(surface, force, water, from)
  if not prototypes.entity["offshore-pump"] then return nil end
  local pumps = {}
  for dx = -5, 5 do
    for dy = -5, 5 do
      local p = {x = water.x + dx, y = water.y + dy}
      for dir = 0, 3 do
        if can_place(surface, force, "offshore-pump", p, dir) then
          pumps[#pumps + 1] = {position = p, direction = dir, d = util.distance(from, p)}
        end
      end
    end
  end
  if #pumps == 0 then return nil end
  table.sort(pumps, function(a, b) return a.d < b.d end)
  local function spot(p, dir) return {position = util.pos(p), direction = dir} end
  if prototypes.entity["boiler"] and prototypes.entity["steam-engine"] then
    for _, pump in ipairs(pumps) do
      -- Pump-relative layout (checked in game for every direction): the boiler lies across the pump's
      -- output, 2 tiles back from it, and the engine continues from the boiler's steam side.
      local back, side = STEP[(pump.direction + 2) % 4], STEP[(pump.direction + 3) % 4]
      local turned = (pump.direction + 3) % 4
      local p = pump.position
      local boiler = {x = p.x + 2 * back[1] + 0.5 * side[1], y = p.y + 2 * back[2] + 0.5 * side[2]}
      local engine = {x = boiler.x + 3.5 * side[1], y = boiler.y + 3.5 * side[2]}
      if can_place(surface, force, "boiler", boiler, turned) and can_place(surface, force, "steam-engine", engine, turned) then
        return {offshore_pump = spot(p, pump.direction), boiler = spot(boiler, turned), steam_engine = spot(engine, turned)}
      end
    end
  end
  return {offshore_pump = spot(pumps[1].position, pumps[1].direction)}
end

-- A power plant needs room to grow: more boiler and engine rows beside the first one.
local MAX_PIPES, ROOM_ROWS, ROOM_LENGTH, FUEL_LANE = 14, 12, 12, 3

local function bounds(corners)
  local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
  for _, c in ipairs(corners) do
    x1, y1, x2, y2 = math.min(x1, c.x), math.min(y1, c.y), math.max(x2, c.x), math.max(y2, c.y)
  end
  return {left_top = {x = x1, y = y1}, right_bottom = {x = x2, y = y2}}
end

-- Clear for building and growing: no water, cliffs, ore or buildings (trees and rocks can be cleared).
local function roomy(surface, force, box)
  local area = {{box.left_top.x, box.left_top.y}, {box.right_bottom.x, box.right_bottom.y}}
  if surface.count_tiles_filtered{area = area, collision_mask = "water_tile"} > 0 then return false end
  if surface.count_entities_filtered{area = area, type = {"cliff", "resource"}} > 0 then return false end
  for _, entity in ipairs(surface.find_entities_filtered{area = area, force = force}) do
    if entity.type ~= "character" then return false end
  end
  return true
end

-- Steam power with room to expand: an offshore pump, a straight pipe inland from it, and a boiler and steam
-- engine at its end where there's room for more of them; the same layout as M.spot, moved back along the
-- pipe. Falls back to the closest layout that fits without the room (M.spot's when pipes can't be used).
-- pipes is the list of pipe positions, room the area kept clear for the plant to grow into, and fuel_lane
-- the strip of it beside the boilers (away from the engines) where the coal belt and inserters go.
function M.plant(surface, force, water, from, can_pipe)
  local base = M.spot(surface, force, water, from)
  local fallback = base and base.boiler and
    {offshore_pump = base.offshore_pump, boiler = base.boiler, steam_engine = base.steam_engine, pipes = {}} or nil
  if not can_pipe then return fallback end
  local pumps = {}
  for dx = -6, 6 do
    for dy = -6, 6 do
      local p = {x = water.x + dx, y = water.y + dy}
      for dir = 0, 3 do
        if can_place(surface, force, "offshore-pump", p, dir) then
          pumps[#pumps + 1] = {position = p, direction = dir, d = util.distance(from, p)}
        end
      end
    end
  end
  table.sort(pumps, function(a, b) return a.d < b.d end)
  local function spot(p, dir) return {position = util.pos(p), direction = dir} end
  for i = 1, math.min(#pumps, 12) do
    local pump = pumps[i]
    local back, side = STEP[(pump.direction + 2) % 4], STEP[(pump.direction + 3) % 4]
    local turned = (pump.direction + 3) % 4
    local p = pump.position
    local pipes = {}
    for k = 0, MAX_PIPES do
      if k > 0 then
        local pipe = {x = p.x + k * back[1], y = p.y + k * back[2]}
        if not can_place(surface, force, "pipe", pipe, 0) then break end
        pipes[k] = util.pos(pipe)
      end
      local boiler = {x = p.x + (2 + k) * back[1] + 0.5 * side[1], y = p.y + (2 + k) * back[2] + 0.5 * side[2]}
      local engine = {x = boiler.x + 3.5 * side[1], y = boiler.y + 3.5 * side[2]}
      if k >= 3 and can_place(surface, force, "boiler", boiler, turned) and can_place(surface, force, "steam-engine", engine, turned) then
        -- Room for more rows further back, each a boiler and two engines long, and a lane on the boilers'
        -- far side for the fuel belt and its inserters.
        local function box(from, to)
          local corners = {}
          for _, a in ipairs({-1.5, 1.5 + ROOM_ROWS}) do
            for _, c in ipairs({from, to}) do
              corners[#corners + 1] = {x = boiler.x + a * back[1] + c * side[1], y = boiler.y + a * back[2] + c * side[2]}
            end
          end
          return bounds(corners)
        end
        local room, lane = box(-1 - FUEL_LANE, 1 + ROOM_LENGTH), box(-1 - FUEL_LANE, -1)
        if roomy(surface, force, room) then
          local copy = {}
          for j = 1, k do copy[j] = pipes[j] end
          return {offshore_pump = spot(p, pump.direction), boiler = spot(boiler, turned), steam_engine = spot(engine, turned),
            pipes = copy, room = room, fuel_lane = lane}
        end
      end
    end
  end
  return fallback
end

-- The plant's room and a strip beyond it the way the plant grows (away from the water), as wide as the
-- room: nothing but power (and the poles running through) goes there, so the plant can keep growing.
local GROWTH = 24
-- `box` (the room, or its fuel lane) with that strip added.
function M.grown(plant, box)
  if not (box and plant and plant.offshore_pump) then return box end
  local back = STEP[(plant.offshore_pump.direction + 2) % 4]
  local lt, rb = box.left_top, box.right_bottom
  return bounds({lt, rb, {x = lt.x + GROWTH * back[1], y = lt.y + GROWTH * back[2]},
    {x = rb.x + GROWTH * back[1], y = rb.y + GROWTH * back[2]}})
end
function M.growth_area(plant) return M.grown(plant, plant and plant.room) end

-- The way the plant grows (a unit vector), or nil.
function M.growth_dir(plant)
  return plant and plant.offshore_pump and STEP[(plant.offshore_pump.direction + 2) % 4]
end

return M
