-- Works on goals (goals.lua): their research, power, and machines. Each machine is a "cell": an assembler
-- set to its recipe with a pole, in one column per goal beside the power network, so it grows by adding
-- cells at its open end. Beside the main bus (bus.lua) a feeder belt brings plates to the assemblers, and
-- neighboring cells pass parts by inserter; the engineer carries the rest by hand. The goal's last cell has
-- an inserter into a chest, where its product collects. It's simple, works for any
-- recipe without fluids, and the output is real machine output, which is what a goal is checked against.
--
-- Keep-busy's helpers (gathering, crafting, routes, steam power, the lab) come from autopilot.lua as `h`.
local util = require("scripts.util")
local goals = require("scripts.goals")
local plan = require("scripts.plan")
local power = require("scripts.power")
local bus = require("scripts.bus")
local frame = require("scripts.frame")
local M = {}

local POLE, INSERTER, CHEST, LONG = "small-electric-pole", "inserter", "wooden-chest", "long-handed-inserter"
local CELL_STEP = 4 -- tiles between cells in a column
-- An assembler is topped up to FEED crafts' worth of each ingredient once it's below LOW crafts' worth.
local FEED_CRAFTS, LOW_CRAFTS = 30, 10
-- Free cell slots kept past a column's end, so it can grow there.
local GROWTH_CELLS = 2
local LAB_LOW, PACK_BATCH = 5, 10
local MAX_STEPS = 20
-- Stacks of each item the mall's chests hold.
local MALL_STACKS = 2

local function wire_reach()
  local p = prototypes.entity[POLE]
  local ok, v = pcall(function() return p.get_max_wire_distance() end)
  return (ok and v) or p.max_wire_distance or 7.5
end

local function box(l, t, r, b) return {left_top = {x = l, y = t}, right_bottom = {x = r, y = b}} end
local function overlaps(a, b)
  return a.left_top.x < b.right_bottom.x and b.left_top.x < a.right_bottom.x and a.left_top.y < b.right_bottom.y
    and b.left_top.y < a.right_bottom.y
end

-- Poles on a network that has a power source, near `near`.
local function network_poles(e, near)
  local nets = {}
  for _, source in ipairs(goals.power_sources(e.surface, e.force, near)) do
    local id = source.electric_network_id
    if id then nets[id] = true end
  end
  local out = {}
  for _, pole in ipairs(e.surface.find_entities_filtered{type = "electric-pole", force = e.force, position = near, radius = 200}) do
    if pole.electric_network_id and nets[pole.electric_network_id] then out[#out + 1] = pole end
  end
  table.sort(out, function(a, b) return util.distance(a.position, near) < util.distance(b.position, near) end)
  return out
end

-- The direction (0-3) whose inserter drops toward (vx, vy): east is (1, 0), south (0, 1).
local function inserter_toward(vx, vy)
  local drop = prototypes.entity[INSERTER].inserter_drop_position
  local x, y = drop.x or drop[1], drop.y or drop[2]
  for d = 0, 3 do
    if x * vx + y * vy > 0.5 then return d end
    x, y = -y, x
  end
  return 0
end
-- A column can face any way (frame.lua: b.m; nil grows south with its outputs east, as the comments
-- here say): the point (dx, dy) from p in its terms, and the inserter direction dropping toward (vx, vy).
local function off(b, p, dx, dy) return frame.at(b.m, p, dx, dy) end
local function toward(b, vx, vy) return inserter_toward(frame.vec(b.m, vx, vy)) end

local function recipe_uses(recipe, item)
  for _, i in ipairs(recipe.ingredients) do if i.name == item then return true end end
  return false
end

-- Whether point p is on cell i's machine (a 2x2 furnace covers only part of its cell).
local function on_machine(b, i, p)
  local at = goals.machine_pos(b, i)
  local proto = prototypes.entity[b.machines and b.machines[i] or "assembling-machine-1"]
  local w, h = (proto and proto.tile_width or 3) / 2, (proto and proto.tile_height or 3) / 2
  return math.abs(p.x - at.x) < w and math.abs(p.y - at.y) < h
end

-- Inserters in the gap between neighboring cells where one makes what the other uses (cable into
-- circuits, gears into inserters, bricks into walls), so those go across by themselves and not by hand.
local function links(b)
  local out = {}
  for i = 1, #b.recipes - 1 do
    local a, z = prototypes.recipe[b.recipes[i]], prototypes.recipe[b.recipes[i + 1]]
    local at = off(b, b.cells[i], 0, CELL_STEP / 2)
    local above, below = off(b, at, 0, -1), off(b, at, 0, 1)
    local made_a, made_z = a and a.main_product, z and z.main_product
    if made_a and z and recipe_uses(z, made_a.name) and on_machine(b, i, above) and on_machine(b, i + 1, below) then
      out[#out + 1] = {position = at, direction = toward(b, 0, 1), to = i + 1, item = made_a.name}
    elseif made_z and a and recipe_uses(a, made_z.name) and on_machine(b, i + 1, below) and on_machine(b, i, above) then
      out[#out + 1] = {position = at, direction = toward(b, 0, -1), to = i, item = made_z.name}
    end
  end
  return out
end

-- A column of cells with its top machine at o, one per recipe in `recipes` (made in `machines`), facing
-- as m says: positions of machines and poles, an inserter and chest beside each cell making `product` (a
-- recipe, or a set of them for the mall), and the area it takes (with growth room; `left` and `top` tiles
-- of it before the machines' centers, 2.5 by default).
local function column(o, recipes, product, machines, m, left, top)
  local n = #recipes
  local cells, poles, outputs = {}, {}, {}
  for i = 1, n do
    local y = CELL_STEP * (i - 1)
    cells[i] = frame.at(m, o, 0, y)
    poles[i] = frame.at(m, o, 2, y + 2)
    if recipes[i] == product or (type(product) == "table" and product[recipes[i]]) then
      outputs[#outputs + 1] = {inserter = frame.at(m, o, 2, y), chest = frame.at(m, o, 3, y), cell = i}
    end
  end
  local area = frame.box(m, o, -(left or 2.5), -(top or 2.5), 4.5, CELL_STEP * (n - 1 + GROWTH_CELLS) + 3.5)
  return {cells = cells, poles = poles, outputs = outputs, recipes = recipes, machines = machines, area = area, growth = "south", m = m}
end

---------------------------------------------------------------------------
-- Parts that aren't passed between neighbors go down a parts belt on the column's east side (3 tiles
-- east of the machines' centers, flowing south and ending at the last cell that takes from it): an
-- inserter from each cell making the item onto it (in the cell's bottom row) and one from it into each
-- cell using it (in the top row, powered by the pole above). One item per belt: a belt that ends holds one
-- kind of item without jamming, filling up until its makers stop. Assemblers take only what they use.

-- Which cells make each item.
local function makers(recipes)
  local out = {}
  for i, name in ipairs(recipes) do
    local r = prototypes.recipe[name]
    local p = r and r.main_product
    if p then
      out[p.name] = out[p.name] or {}
      table.insert(out[p.name], i)
    end
  end
  return out
end

-- The item for a column's parts belt (the one the most cells get from it), with the cells making it above
-- the last that uses it and the cells taking it; and what the links pass ("cell:item" -> true).
local function parts_for(b)
  local linked = {}
  for _, l in ipairs(links(b)) do linked[l.to .. ":" .. l.item] = true end
  local best
  for item, producers in pairs(makers(b.recipes)) do
    local consumers = {}
    for j, name in ipairs(b.recipes) do
      local r = prototypes.recipe[name]
      local proto = b.machines and b.machines[j] and prototypes.entity[b.machines[j]]
      if j > producers[1] and r and recipe_uses(r, item) and not linked[j .. ":" .. item]
          and (not proto or proto.type == "assembling-machine") then
        consumers[#consumers + 1] = j
      end
    end
    if #consumers > 0 and (not best or #consumers > #best.consumers or (#consumers == #best.consumers and item < best.item)) then
      local above = {}
      for _, i in ipairs(producers) do
        if i < consumers[#consumers] then above[#above + 1] = i end
      end
      best = {item = item, producers = above, consumers = consumers}
    end
  end
  return best, linked
end

-- How many of the cells' needs from other cells come by inserter (links, the parts belt).
local function covered(b)
  local p, linked = parts_for(b)
  local n = p and #p.consumers or 0
  for _ in pairs(linked) do n = n + 1 end
  return n
end

-- The order of a column's cells (indices into `recipes`) that covers the most: swaps of two cells while
-- one covers more.
local function arrange(recipes, machines)
  local order = {}
  for i = 1, #recipes do order[i] = i end
  local function score()
    local rs, ms = {}, {}
    for k, i in ipairs(order) do rs[k], ms[k] = recipes[i], machines[i] end
    return covered(column({x = 0.5, y = 0.5}, rs, nil, ms))
  end
  local best, improved, rounds = score(), #order > 2, 0
  while improved and rounds < 10 do
    improved, rounds = false, rounds + 1
    for i = 1, #order - 1 do
      for j = i + 1, #order do
        order[i], order[j] = order[j], order[i]
        local s = score()
        if s > best then best, improved = s, true
        else order[i], order[j] = order[j], order[i] end
      end
    end
  end
  return order
end

-- Settles a column's parts belt and outputs: an output where the parts belt runs past (or that goes up to
-- the bus's labs, `rise`) uses a long-handed inserter reaching over it, into a chest 4 tiles out (or onto the
-- riser belt there). Without long-handed inserters such a column gets no parts belt.
-- (The span is in tiles down the column from its first cell, `along`; older saves' are map y.)
local function settle(c, rise, can_long)
  c.parts = parts_for(c)
  local span
  if c.parts then
    span = {top = CELL_STEP * (c.parts.producers[1] - 1) + 1, bottom = CELL_STEP * (c.parts.consumers[#c.parts.consumers] - 1) - 1,
      along = true}
  end
  for _, out in ipairs(c.outputs) do
    local y = CELL_STEP * (out.cell - 1)
    local cell = c.cells[out.cell]
    out.long, out.chest = nil, off(c, cell, 3, 0)
    if rise or (span and y >= span.top and y <= span.bottom) then
      if not can_long then
        c.parts, span = nil, nil
      else
        out.long = true
        out.chest = not rise and off(c, cell, 4, 0) or nil
      end
    end
  end
  c.span = span
end

-- The parts belt's places: the belt, and the inserters onto it and off it.
local function parts_places(b)
  local p, span = b.parts, b.span
  if not (p and span) then return {} end
  local out = {}
  local first = b.cells[1]
  local top, bottom = span.top, span.bottom
  if not span.along then top, bottom = top - first.y, bottom - first.y end
  for t = top, bottom do out[#out + 1] = {"transport-belt", {position = off(b, first, 3, t), direction = frame.dir(b.m, 2)}} end
  for _, i in ipairs(p.producers) do
    out[#out + 1] = {INSERTER, {position = off(b, b.cells[i], 2, 1), direction = toward(b, 1, 0)}}
  end
  for _, j in ipairs(p.consumers) do
    out[#out + 1] = {INSERTER, {position = off(b, b.cells[j], 2, -1), direction = toward(b, -1, 0)}}
  end
  return out
end

-- Whatever else is in an area, these don't stop building (trees and rocks are chopped when placing).
local PASSABLE = {tree = true, ["simple-entity"] = true, character = true, corpse = true, ["character-corpse"] = true,
  fire = true, ["item-entity"] = false}

local function clear(e, area, keep_out)
  for _, k in ipairs(keep_out) do if overlaps(area, k) then return false end end
  local surface = e.surface
  if surface.count_entities_filtered{area = area, type = "resource"} > 0 then return false end
  for _, entity in ipairs(surface.find_entities_filtered{area = area}) do
    if not PASSABLE[entity.type] then return false end
  end
  local ok, water = pcall(surface.count_tiles_filtered, {area = area, collision_mask = "water_tile"})
  if ok and water > 0 then return false end
  return true
end

-- Areas a new column must stay out of: the power plant's room and other goals' columns (with their growth
-- room), and the bus's area unless `without_bus` (columns on the bus go there).
local function keep_out(rec, s, h, without_bus)
  local out = {}
  if s.plant and s.plant.room then out[#out + 1] = power.growth_area(s.plant) end
  for _, goal in ipairs(goals.list(rec.owner)) do
    if goal.block and goal.status ~= "CANCELLED" then out[#out + 1] = goal.block.area end
  end
  -- (Keep-busy's planned science units and smelting area.)
  for _, box in ipairs(h and h.planned_areas and h.planned_areas(s, without_bus) or {}) do out[#out + 1] = box end
  return out
end

-- Poles from `from` (a powered pole) to `to`, each in wire reach of the last and placeable, outside the
-- keep-out areas; nil if there's no such line.
local function segment(e, from, to, wire, avoid)
  local d = util.distance(from, to)
  if d <= wire then return {} end
  local n = math.ceil(d / (wire - 0.5)) - 1
  local line, last = {}, from
  for i = 1, n do
    local tx, ty = from.x + (to.x - from.x) * i / (n + 1), from.y + (to.y - from.y) * i / (n + 1)
    local best
    for dx = -1, 1 do
      for dy = -1, 1 do
        local p = {x = math.floor(tx) + dx + 0.5, y = math.floor(ty) + dy + 0.5}
        local inside = false
        for _, k in ipairs(avoid) do if overlaps(box(p.x - 0.5, p.y - 0.5, p.x + 0.5, p.y + 0.5), k) then inside = true end end
        if not inside and util.distance(p, last) <= wire and util.can_build(e.surface, e.force, POLE, p, 0) then
          if not best or util.distance(p, {x = tx, y = ty}) < util.distance(best, {x = tx, y = ty}) then best = p end
        end
      end
    end
    if not best then return nil end
    line[#line + 1] = best
    last = best
  end
  if util.distance(last, to) > wire then return nil end
  return line
end

-- The same, run straight along the map's axes: one straight line, or two meeting at a corner pole (an
-- L), and only a slanted line when neither fits.
local function pole_line(e, from, to, wire, avoid)
  if math.abs(from.x - to.x) < 1 or math.abs(from.y - to.y) < 1 or util.distance(from, to) <= wire then
    return segment(e, from, to, wire, avoid)
  end
  for _, corner in ipairs({{x = to.x, y = from.y}, {x = from.x, y = to.y}}) do
    local c = {x = math.floor(corner.x) + 0.5, y = math.floor(corner.y) + 0.5}
    local inside = false
    for _, k in ipairs(avoid) do if overlaps(box(c.x - 0.5, c.y - 0.5, c.x + 0.5, c.y + 0.5), k) then inside = true end end
    if not inside and util.can_build(e.surface, e.force, POLE, c, 0) then
      local a = segment(e, from, c, wire, avoid)
      local b = a and segment(e, c, to, wire, avoid)
      if b then
        a[#a + 1] = c
        for _, p in ipairs(b) do a[#a + 1] = p end
        return a
      end
    end
  end
  return segment(e, from, to, wire, avoid)
end

M.network_poles, M.pole_line, M.wire_reach = network_poles, pole_line, wire_reach

local function present(surface, name, p)
  return surface.find_entities_filtered{name = name, position = p, radius = 0.6}[1]
end

local function key(p) return math.floor(p.x) .. "," .. math.floor(p.y) end

-- A column on the main bus (bus.lua), in the first free slot where it and its bus parts fit: a feeder belt
-- runs down its west side with an inserter from it into each assembler, so plates come by belt. Nil when
-- there's no bus yet (no ore lines, or no splitters researched) or no slot fits.
local function can_long(force)
  local r = force.recipes[LONG]
  return r ~= nil and r.enabled
end

-- The science belt's lane for a column making `product` in slot k: science packs the labs use go up to
-- the labs on the bus, one kind per lane. The south lane first; the north lane's way round is in the
-- third lab's place for slot 0. Nil when it isn't a pack, or no lane is free.
local LAB_PACKS = {["automation-science-pack"] = true, ["logistic-science-pack"] = true, ["military-science-pack"] = true}
local function science_lane(s, product, k, force)
  local r = type(product) == "string" and prototypes.recipe[product]
  local pack = r and r.main_product and r.main_product.name
  local lab = force.recipes["lab"]
  if not (pack and LAB_PACKS[pack] and can_long(force) and lab and lab.enabled) then return nil end
  local used = {}
  for p, lane in pairs(s.science_lanes or {}) do
    if p == pack then return nil end
    used[lane] = true
  end
  if not used.south then return "south", pack end
  if not used.north and k >= 1 then return "north", pack end
end

local function on_bus(rec, s, recipes, product, machines, h)
  local e = rec.entity
  local surface, force = e.surface, e.force
  local g = bus.geometry(s.ore_plan)
  if not g then return nil end
  for _, item in ipairs(bus.ITEMS) do
    local r = force.recipes[item]
    if not (r and r.enabled) then return nil end
  end
  local avoid = keep_out(rec, s, h, true)
  local base, old = bus.base(g)
  -- Where the plate belts used to end (an inserter and chest): cleared before the bus is built.
  local skip = {}
  for _, o in ipairs(old) do skip[key(o.inserter)], skip[key(o.chest)] = true, true end
  s.bus_slots = s.bus_slots or {}
  local taken = {}
  for k in pairs(s.bus_slots) do taken[tonumber(k)] = true end
  local wire = wire_reach() - 0.5
  -- A science column tries every slot with its way up to the labs first, then without (packs into a
  -- chest): a slot without a lane (slot 0 once the south lane is taken) would leave it never reaching the
  -- labs, and the build order's red science never retired.
  for pass = 1, 2 do
  for k = 0, bus.SLOTS - 1 do
    local science, pack = science_lane(s, product, k, force)
    local lanes = pass == 1 and {science} or {false}
    for _, lane in ipairs(not taken[k] and lanes or {}) do
      local A = bus.feeder_x(g, k)
      local o = bus.tile(g, A + 3, 10)
      local c = column(o, recipes, product, machines, g.m, 4.5, 1.5)
      settle(c, lane ~= false, can_long(force))
      local places = bus.slot(g, k, taken, 10 + CELL_STEP * (#recipes - 1) + 1)
      for _, pl in ipairs(base) do places[#places + 1] = pl end
      for _, pl in ipairs(bus.power(g, k)) do places[#places + 1] = pl end
      if lane and #c.outputs > 0 then
        -- Up to the labs: a riser from the bottom product cell, and the labs with the science belt.
        local riser, x = bus.riser(g, k, lane, 10 + CELL_STEP * (c.outputs[#c.outputs].cell - 1))
        for _, pl in ipairs(riser) do places[#places + 1] = pl end
        local head = math.max(s.science_head or 0, x + 1)
        for _, pl in ipairs(bus.labs(g, head)) do places[#places + 1] = pl end
        c.science = {lane = lane, pack = pack, head = head}
      end
      local fits = clear(e, c.area, avoid)
      local tiles = {c.area}
      for _, pl in ipairs(fits and places or {}) do
        local name, p = prototypes.item[pl[1]].place_result.name, pl[2].position
        if not (skip[key(p)] or present(surface, name, p) or util.can_build(surface, force, name, p, pl[2].direction or 0)) then
          fits = false
          break
        end
        -- (Its whole footprint: a lab's, not just its middle tile, or a pole line can run through its edge.)
        local proto = prototypes.entity[name]
        -- (The longer side both ways: a splitter turns with the frame.)
        local half = math.max(proto.tile_width or 1, proto.tile_height or 1) / 2
        tiles[#tiles + 1] = box(p.x - half, p.y - half, p.x + half, p.y + half)
      end
      if fits then
        c.feeds, c.west = {}, {}
        for i, cell in ipairs(c.cells) do
          local proto = machines[i] and prototypes.entity[machines[i]]
          if proto and proto.type == "assembling-machine" and proto.tile_width == 3 then
            c.feeds[#c.feeds + 1] = {position = off(c, cell, -2, 0), direction = toward(c, 1, 0)}
          end
          c.west[i] = off(c, cell, -2, 2)
        end
        -- Pole lines to the taps' poles and the column, from the network or a pole planned before.
        for _, a in ipairs(avoid) do tiles[#tiles + 1] = a end
        local known = {}
        for _, p in ipairs(network_poles(e, o)) do known[#known + 1] = p.position end
        local targets = {}
        for _, pl in ipairs(places) do
          if pl[1] == POLE and not present(surface, POLE, pl[2].position) then targets[#targets + 1] = pl[2].position end
        end
        targets[#targets + 1] = c.west[1]
        for _, b in ipairs(bus.corridor(g)) do tiles[#tiles + 1] = b end
        c.line = {}
        -- The target nearest a pole first, so later ones can start from it.
        while fits and #targets > 0 do
          local from, to, at, d
          for t, target in ipairs(targets) do
            for _, p in ipairs(known) do
              local pd = util.distance(p, target)
              if not d or pd < d then from, to, at, d = p, target, t, pd end
            end
          end
          table.remove(targets, at or 1)
          local line = from and pole_line(e, from, to, wire, tiles)
          if not line then
            fits = false
            break
          end
          for _, p in ipairs(line) do
            c.line[#c.line + 1] = p
            known[#known + 1] = p
          end
          known[#known + 1] = to
        end
        if fits then
          c.bus = {slot = k, places = places}
          return c
        end
      end
    end
  end
  end
end

-- Where a goal's column goes: on the main bus when there is one, else as near home as possible with its
-- first pole in wire reach of a powered pole, else further out with a line of poles to it.
local function find_column(rec, s, recipes, product, machines, h)
  local e = rec.entity
  local n = #recipes
  local c = on_bus(rec, s, recipes, product, machines, h)
  if c then return c end
  local home = s.home or e.position
  local poles = network_poles(e, home)
  if #poles == 0 then return nil, "there's no powered pole to connect to" end
  local wire = wire_reach() - 0.5
  local avoid = keep_out(rec, s, h)
  -- First right by a pole (any of the 25 nearest home), then up to 20 tiles from one of the 5 nearest,
  -- every third tile (each try searches an area, so this is kept to about a thousand).
  for pass, reach in ipairs({wire, 40}) do
    for i = 1, math.min(#poles, pass == 1 and 25 or 5) do
      local anchor = poles[i].position
      local ax, ay = math.floor(anchor.x), math.floor(anchor.y)
      for _, off in ipairs(h.offsets()) do
        local o = {x = ax + off[1] + 0.5, y = ay + off[2] + 0.5}
        local try = (pass == 1 or (off[1] % 3 == 0 and off[2] % 3 == 0)) and util.distance({x = o.x + 2, y = o.y + 2}, anchor) <= reach
        local c = try and column(o, recipes, product, machines)
        if c and clear(e, c.area, avoid) then
          local line = pole_line(e, anchor, c.poles[1], wire, {c.area, table.unpack(avoid)})
          if line then
            c.line = line
            settle(c, false, can_long(e.force))
            return c
          end
        end
      end
    end
  end
  return nil, "there's no clear 7x" .. (CELL_STEP * (n + GROWTH_CELLS)) .. " area near the power network"
end

-- The goal's cells, upstream first, from its BUILD tasks.
local function cell_tasks(goal)
  local out = {}
  for _, t in ipairs(goal.tasks) do
    if t.kind == "BUILD" then
      for _ = 1, t.count or 1 do out[#out + 1] = t end
    end
  end
  return out
end

-- Everything in a goal's column ({item, {position, direction, recipe}}), in the order it goes up.
local function block_places(b, list)
  local places = {}
  for _, p in ipairs(b.line or {}) do places[#places + 1] = {POLE, {position = p}} end
  for _, pl in ipairs(b.bus and b.bus.places or {}) do places[#places + 1] = pl end
  for _, p in ipairs(b.west or {}) do places[#places + 1] = {POLE, {position = p}} end
  for i, recipe in ipairs(b.recipes) do
    places[#places + 1] = {POLE, {position = b.poles[i]}}
    -- The machine each task was planned with (the best unlocked assembler or furnace). A furnace takes no
    -- recipe: it smelts whatever it's fed.
    local machine = b.machines and b.machines[i] or (list[i] and list[i].machine)
    local proto = machine and prototypes.entity[machine]
    local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
    local furnace = proto and proto.type == "furnace"
    places[#places + 1] = {item and item.name or "assembling-machine-1",
      {position = goals.machine_pos(b, i), recipe = not furnace and recipe or nil}}
  end
  -- Inserters into machines only once the machines (with their recipes) are there: one placed before would
  -- pick up whatever passes and hold it, waiting for a machine that doesn't take it.
  for _, f in ipairs(b.feeds or {}) do places[#places + 1] = {INSERTER, f} end
  for _, out in ipairs(b.outputs) do
    places[#places + 1] = {out.long and LONG or INSERTER, {position = out.inserter, direction = toward(b, 1, 0)}}
    if out.chest then places[#places + 1] = {CHEST, {position = out.chest}} end
  end
  for _, link in ipairs(links(b)) do places[#places + 1] = {INSERTER, link} end
  for _, pl in ipairs(parts_places(b)) do places[#places + 1] = pl end
  return places
end

-- Places the goal's column (what's missing of it).
local function build(rec, w, goal, h)
  local s, e = h.state(rec), rec.entity
  local list = cell_tasks(goal)
  if not goal.block then
    local recipes, machines = {}, {}
    for i, t in ipairs(list) do recipes[i], machines[i] = t.target, t.machine end
    -- Cells in the order that passes the most between them by inserter.
    local order = arrange(recipes, machines)
    local rs, ms = {}, {}
    for k, i in ipairs(order) do rs[k], ms[k] = recipes[i], machines[i] end
    local product = goal.recipe
    if goal.products then
      product = {}
      for _, r in ipairs(goal.products) do product[r] = true end
    end
    local c, why = find_column(rec, s, rs, product, ms, h)
    if not c then return nil, why, true end
    goal.block = c
    if c.science then
      s.science_lanes = s.science_lanes or {}
      s.science_lanes[c.science.pack] = c.science.lane
      s.science_head = c.science.head
    end
    if c.bus then
      -- The slot stays taken (its splitters stay in the bus), and the taps are where plates are collected.
      s.bus_slots[tostring(c.bus.slot)] = goal.id
      local _, _, taps = bus.base(bus.geometry(s.ore_plan))
      for _, t in ipairs(taps) do s.ore_plan.parts[key(t)] = CHEST end
      h.tell(rec, "Building the " .. goal.item .. " machines beside the main bus: plates come to them by belt.")
    end
  end
  local b = goal.block
  local surface = e.surface
  -- (Columns planned before plan.machine_for passed over furnaces that need furnaces' products to build: a
  -- steel furnace not built yet becomes the furnace that can be, once.)
  if not b.furnaces_checked then
    b.furnaces_checked = true
    local best = plan.machine_for(plan.context(e.force), "smelting")
    for i, name in ipairs(b.machines or {}) do
      local proto = prototypes.entity[name]
      if best and proto and proto.type == "furnace" and name ~= best.proto.name
          and not surface.find_entities_filtered{name = name, position = goals.machine_pos(b, i), radius = 0.6}[1] then
        b.machines[i] = best.proto.name
      end
    end
  end
  local action, waiting, steps = h.place_all(rec, w, block_places(b, list), nil, "machines for " .. goal.item)
  if b.bus then
    -- The inserter and chest where the plate belts used to end come out (the chest emptied first), but
    -- only once everything is gathered: until the bus's taps are there, they're where plates come from.
    local g = bus.geometry(s.ore_plan)
    local _, old = bus.base(g)
    local room, back, need = {}, {}, {}
    for _, o in ipairs(old) do
      local inserter, chest = present(surface, INSERTER, o.inserter), present(surface, CHEST, o.chest)
      if inserter then room[#room + 1] = {action = "pick_up", x = o.inserter.x, y = o.inserter.y} end
      if chest then
        if not chest.get_inventory(defines.inventory.chest).is_empty() then room[#room + 1] = {action = "take", x = o.chest.x, y = o.chest.y} end
        room[#room + 1] = {action = "pick_up", x = o.chest.x, y = o.chest.y}
      end
      -- (Taken away too early, and the bus's belt not there yet: put back, or no plates come out at all.
      -- The chest first: an inserter with nothing to drop into drops onto the ground.)
      if not steps and not present(surface, "transport-belt", o.inserter) then
        if not chest then
          back[#back + 1] = {action = "place", item = CHEST, x = o.chest.x, y = o.chest.y}
          need[CHEST] = (need[CHEST] or 0) + 1
        end
        if not inserter then
          back[#back + 1] = {action = "place", item = INSERTER, x = o.inserter.x, y = o.inserter.y, direction = bus.toward(g, 1, 0)}
          need[INSERTER] = (need[INSERTER] or 0) + 1
        end
      end
    end
    if #back > 0 then
      local list = {}
      for _, item in ipairs({CHEST, INSERTER}) do if need[item] then list[#list + 1] = {item, need[item]} end end
      local get, get_why, busy = h.get_items(rec, w, list, "plate chests")
      if busy then return get, get_why end
      return {kind = "steps", describe = "putting the plate chests back at the smelting area's end until the bus is built",
        args = {steps = back}, info = {label = "main bus for " .. goal.item, partial = true}}
    end
    if steps and #room > 0 then
      return {kind = "steps", describe = "making room for the main bus at the smelting area's end", args = {steps = room},
        info = {label = "main bus for " .. goal.item}}
    end
  end
  if not steps then
    -- Waiting for plates to build with: the other goals' machines aren't fed plates meanwhile, or they'd
    -- take them as fast as they're smelted and this would never be built.
    if not action and waiting and waiting:find("to smelt", 1, true) then s.saving_plates = {goal = goal.id, till = game.tick + 1200} end
    return action, waiting
  end
  if s.saving_plates and s.saving_plates.goal == goal.id then s.saving_plates = nil end
  if #steps == 0 then
    -- All placed: an electric cell without power means the column isn't on the network.
    for i in ipairs(b.cells) do
      local m = e.surface.find_entities_filtered{type = {"assembling-machine", "furnace"}, position = goals.machine_pos(b, i), radius = 0.6}[1]
      if m and not goals.hooked_up(m) then return nil, "the machines for " .. goal.item .. " have no power", true end
    end
    b.placed = true
    -- The mall keeps only a couple of stacks of each thing: its machines stop there instead of using up plates.
    for _, out in ipairs(goal.products and b.outputs or {}) do
      local chest = out.chest and present(e.surface, CHEST, out.chest)
      if chest then chest.get_inventory(defines.inventory.chest).set_bar(MALL_STACKS + 1) end
    end
    return nil
  end
  local partial = #steps > MAX_STEPS
  while #steps > MAX_STEPS do table.remove(steps) end
  return {kind = "steps", describe = "building machines for " .. goal.item, args = {steps = steps},
    info = {label = "machines for " .. goal.item, partial = partial}}
end

local function input_inventory(m)
  return m.get_inventory(defines.inventory.crafter_input)
end

local function input_count(m, item)
  local inv = input_inventory(m)
  return inv and inv.get_item_count(item) or 0
end

local function output_count(m, item)
  local inv = m.get_output_inventory()
  return inv and inv.get_item_count(item) or 0
end

-- Keeps the goal's cells fed: what one cell makes is taken from it and put into the next, and plates,
-- coal, stone and wood come from the base (gathered like everything else keep-busy needs). Burner
-- furnaces are fueled by maintenance, like the base's.
local function feed(rec, w, goal, h)
  local e = rec.entity
  local b = goal.block
  if not b then return nil end
  local machines, makes = {}, {}
  for i in ipairs(b.cells) do
    local m = e.surface.find_entities_filtered{type = {"assembling-machine", "furnace"}, position = goals.machine_pos(b, i),
      radius = 0.6, force = e.force}[1]
    local r = m and (m.type == "furnace" and prototypes.recipe[b.recipes[i]] or (m.get_recipe() and m.get_recipe().prototype))
    if r then
      machines[#machines + 1] = {entity = m, recipe = r, cell = i}
      local product = r.main_product
      if product then makes[product.name] = makes[product.name] or {}; table.insert(makes[product.name], m) end
    end
  end
  -- What each machine is short of. An input slot holds one stack (10 coal a grenade is 5 crafts a stack),
  -- so a machine is filled to that at most, and topped up once it's half empty.
  local short, order, need = {}, {}, {}
  -- What comes by inserter from the cell next to it: not carried by hand while that inserter is there.
  local linked = {}
  for _, link in ipairs(links(b)) do
    if present(e.surface, INSERTER, link.position) then linked[link.to .. ":" .. link.item] = true end
  end
  -- (And what comes down the parts belt, once the inserter off it is there.)
  for _, j in ipairs(b.parts and b.span and b.parts.consumers or {}) do
    local c = b.cells[j]
    if present(e.surface, INSERTER, off(b, c, 2, -1)) then linked[j .. ":" .. b.parts.item] = true end
  end
  -- (No plates while another goal saves them up to build with: see build.)
  local saving = h.state(rec).saving_plates
  saving = saving and saving.goal ~= goal.id and game.tick < saving.till
  for _, c in ipairs(machines) do
    local m = c.entity
    for _, i in ipairs(c.recipe.ingredients) do
      -- On the bus, plates come to assemblers by belt.
      local by_belt = (b.bus and m.type == "assembling-machine" and bus.PLATES[i.name]) or linked[c.cell .. ":" .. i.name]
        or (saving and bus.PLATES[i.name])
      local have = input_count(m, i.name)
      local full = math.min(i.amount * FEED_CRAFTS,
        prototypes.item[i.name].stack_size * (m.type == "furnace" and #input_inventory(m) or 1))
      if not by_belt and have < math.min(i.amount * LOW_CRAFTS, full / 2) then
        local want = full - have
        if want > 0 then
          short[#short + 1] = {machine = m, item = i.name, want = want}
          if not need[i.name] then need[i.name] = 0; order[#order + 1] = i.name end
          need[i.name] = need[i.name] + want
        end
      end
    end
  end
  if #short == 0 then return nil end
  -- Take what other cells made first.
  local takes, available, gather, stopped = {}, {}, {}, {}
  for _, item in ipairs(order) do
    available[item] = e.get_item_count(item)
    if makes[item] then
      for _, m in ipairs(makes[item]) do
        local n = output_count(m, item)
        -- (A machine with its output full makes no more until it's taken: whatever is there is worth taking.)
        if n > 0 and m.status == defines.entity_status.full_output then stopped[item] = true end
        if n > 0 and available[item] < need[item] then
          takes[#takes + 1] = h.take(m, nil, nil)
          available[item] = available[item] + n
        end
      end
      -- Its maker here may pass all it makes on by inserter: then another goal's chest of it (the circuits
      -- goal's, for the mall's inserters).
      for _, chest in ipairs(available[item] < need[item] and M.holding(rec, item) or {}) do
        if available[item] < need[item] then
          local n = math.min(chest.get_item_count(item), need[item] - available[item])
          takes[#takes + 1] = h.take(chest, item, n)
          available[item] = available[item] + n
        end
      end
    elseif available[item] < need[item] then
      gather[#gather + 1] = {item, need[item]}
    end
  end
  local inserts = {}
  for _, sh in ipairs(short) do
    local n = math.min(sh.want, available[sh.item])
    -- Worth a trip: a fair share of what it wants, or all that's left.
    if n > 0 and (n >= math.min(sh.want, 5) or not makes[sh.item] or stopped[sh.item]) then
      inserts[#inserts + 1] = h.insert(sh.machine, sh.item, n)
      available[sh.item] = available[sh.item] - n
    end
  end
  if #inserts == 0 then
    -- Nothing on hand to bring: gather the base's materials, or wait for the cells upstream.
    if #gather > 0 then
      -- A trip's worth at a time: gathering waits until all of it is ready in the furnaces.
      for _, x in ipairs(gather) do x[2] = math.min(x[2], 50) end
      local action, waiting, busy = h.get_items(rec, w, gather, goal.item .. " machines")
      if busy then return action, waiting end
    end
    return nil, "waiting for " .. table.concat(order, ", ") .. " for the " .. goal.item .. " machines"
  end
  local job = h.route(rec, takes, "feeding the " .. goal.item .. " machines")
  local rest = h.route(rec, inserts, "")
  for _, step in ipairs(rest.args.steps) do
    if #job.args.steps < MAX_STEPS then job.args.steps[#job.args.steps + 1] = step end
  end
  return job
end

-- The engineer's chests holding `item` (science packs collect in goals' chests).
function M.holding(rec, item)
  local out = {}
  for _, entity in pairs(rec.built or {}) do
    if entity.valid and entity.type == "container" and entity.get_item_count(item) > 0 then out[#out + 1] = entity end
  end
  return out
end

-- The goal's next research: the first unresearched technology on its list whose prerequisites are done.
local function next_research(goal, force)
  for _, t in ipairs(goal.tasks) do
    if t.kind == "RESEARCH" and t.status ~= "COMPLETE" then
      local tech = force.technologies[t.target]
      if tech and not tech.researched then
        local ready = true
        for _, pre in pairs(tech.prerequisites) do if not pre.researched then ready = false end end
        if ready then return tech end
      end
    end
  end
end

-- The lab the engineer fills by hand, and the packs that come to it by belt: the bus's first lab once it's
-- up with a science belt, else the first lab (red science comes to it from the build order's assembler).
local function hand_lab(rec, w, h)
  local s = h.state(rec)
  local g = bus.geometry(s.ore_plan)
  if g and s.science_lanes then
    local lab = rec.entity.surface.find_entities_filtered{name = "lab", position = bus.lab_positions(g)[1], radius = 0.6}[1]
    if lab and lab.is_connected_to_electric_network() then return lab, s.science_lanes end
  end
  return w.labs[1], nil
end

-- Whether a pack reaches the lab hand_lab chose without the engineer.
local function by_itself(w, belted, pack)
  if belted then return belted[pack] ~= nil end
  return pack == "automation-science-pack" and w.count.science ~= nil
end

local function research(rec, w, goal, h)
  local e = rec.entity
  local force = e.force
  local tech = next_research(goal, force)
  if not tech then return nil end
  local trigger = tech.prototype.research_trigger
  if trigger then
    local item = trigger.type == "craft-item" and trigger.item
    item = type(item) == "table" and (item.name or item[1]) or item
    local recipe = item and force.recipes[item]
    if recipe and recipe.enabled and (e.prototype.crafting_categories or {})[util.category(recipe)] then
      local count = trigger.count or 1
      local action, waiting, busy = h.get_items(rec, w, {{item, count}}, "unlocking " .. tech.name)
      if busy then return action, waiting end
      if e.crafting_queue_size == 0 then h.craft(rec, item, count) end
      return nil, "crafting " .. item .. " to unlock " .. tech.name
    end
    return nil, "waiting for " .. tech.name .. " to unlock (" .. plan.trigger_text(trigger) .. ")"
  end
  if (w.count.lab or 0) == 0 then
    local action, why, stuck = h.powered_lab(rec, w)
    if stuck then goals.block(rec, goal, "NO_PLACEMENT", why) end
    return action, why
  end
  if not force.current_research then force.add_research(tech) end
  local progress = "researching " .. tech.name .. " for " .. goal.item
  -- Red science comes from the build order's science assembler, when there is one; other packs from the
  -- chests other goals fill, else by hand.
  local takes, todo, list = {}, {}, {}
  local lab, belted = hand_lab(rec, w, h)
  for _, i in ipairs(tech.research_unit_ingredients) do
    local in_lab = lab.get_inventory(defines.inventory.lab_input).get_item_count(i.name)
    if not by_itself(w, belted, i.name) and in_lab < LAB_LOW then
      local have = e.get_item_count(i.name)
      if have < PACK_BATCH then
        for _, chest in ipairs(M.holding(rec, i.name)) do
          local n = math.min(chest.get_item_count(i.name), 50)
          takes[#takes + 1] = h.take(chest, i.name, n)
          have = have + n
        end
      end
      if have > 0 then todo[#todo + 1] = h.insert(lab, i.name, math.min(have, 50))
      else list[#list + 1] = {i.name, PACK_BATCH} end
    end
  end
  if #todo > 0 then
    local job = h.route(rec, takes, "filling the lab with science")
    for _, step in ipairs(h.route(rec, todo, "").args.steps) do job.args.steps[#job.args.steps + 1] = step end
    return job
  end
  if w.count.science then
    local action, waiting = h.feed_science(rec, w)
    if action then return action, waiting end
  end
  if #list > 0 then
    local action, waiting, busy = h.get_items(rec, w, list, "science packs for " .. tech.name)
    if busy then return action, waiting end
  end
  return nil, progress
end

---------------------------------------------------------------------------
-- Keep researching: the tech tree in order, with the science the base makes by itself.

-- Science packs in tier order: research goes tier by tier, cheapest first within one.
local TIER = {["automation-science-pack"] = 1, ["logistic-science-pack"] = 2, ["military-science-pack"] = 3,
  ["chemical-science-pack"] = 4, ["production-science-pack"] = 5, ["utility-science-pack"] = 6, ["space-science-pack"] = 7}

-- Recipes the engineer's assemblers make.
local function made_by_machines(rec)
  local out = {}
  for _, entity in pairs(rec.built or {}) do
    if entity.valid and entity.type == "assembling-machine" then
      local r = entity.get_recipe()
      if r then out[r.name] = true end
    end
  end
  return out
end

-- The next technology to research: ready (prerequisites done, researched in labs, not an endless one) and
-- paid for only with packs the base's machines make. Lowest tier first, then cheapest, then by name.
local function next_tech(force, made)
  local best, best_key
  for name, tech in pairs(force.technologies) do
    local p = tech.prototype
    if tech.enabled and not tech.researched and not p.research_trigger and not (p.max_level and p.max_level > 1000) then
      local ok = true
      for _, pre in pairs(tech.prerequisites) do if not pre.researched then ok = false; break end end
      local tier = 0
      for _, i in ipairs(ok and tech.research_unit_ingredients or {}) do
        if not made[i.name] then ok = false; break end
        tier = math.max(tier, TIER[i.name] or 99)
      end
      if ok then
        local cost = tech.research_unit_count * tech.research_unit_energy
        if not best_key or tier < best_key[1] or (tier == best_key[1] and (cost < best_key[2] or (cost == best_key[2] and name < best_key[3]))) then
          best, best_key = tech, {tier, cost, name}
        end
      end
    end
  end
  return best
end


-- Keeps the lab researching the next technology the base's science can pay for, and keeps it stocked
-- (red science comes by inserter from the build order's science assembler, other packs from the chests
-- the goals fill). Returns a job, or nil and what it's doing; nil, nil when there's nothing to research.
function M.keep_researching(rec, w, h)
  local e = rec.entity
  local force = e.force
  local lab, belted = hand_lab(rec, w, h)
  if not lab then return nil end
  local tech = force.current_research
  if not tech then
    tech = next_tech(force, made_by_machines(rec))
    if not tech then return nil end
    force.add_research(tech)
    h.tell(rec, "Researching " .. tech.name .. ".")
  end
  local takes, inserts = {}, {}
  local inv = lab.get_inventory(defines.inventory.lab_input)
  for _, i in ipairs(tech.research_unit_ingredients) do
    if not by_itself(w, belted, i.name) and inv.get_item_count(i.name) < LAB_LOW then
      local have = e.get_item_count(i.name)
      if have < PACK_BATCH then
        for _, chest in ipairs(M.holding(rec, i.name)) do
          local n = math.min(chest.get_item_count(i.name), 50)
          takes[#takes + 1] = h.take(chest, i.name, n)
          have = have + n
        end
      end
      if have > 0 then inserts[#inserts + 1] = h.insert(lab, i.name, math.min(have, 50)) end
    end
  end
  if #inserts > 0 then
    local job = h.route(rec, takes, "filling the lab with science for " .. tech.name)
    for _, step in ipairs(h.route(rec, inserts, "").args.steps) do job.args.steps[#job.args.steps + 1] = step end
    return job
  end
  if w.count.science then
    local action, waiting = h.feed_science(rec, w)
    if action then return action, waiting end
  end
  return nil, "researching " .. tech.name .. " (" .. math.floor(force.research_progress * 100) .. "%)"
end

-- Machines fed by hand (built before the bus) move onto the main bus: each goal column that isn't on it,
-- one at a time (picked up, then built again there), and with keep-busy, once the bus's red science reaches
-- its labs, the build order's red science units and their labs. Nil when there's nothing to move, or (but
-- for the red science) while a goal is being built.
function M.move_to_bus(rec, w, h, keep_busy)
  local s, e = h.state(rec), rec.entity
  local surface = e.surface
  local runnable = goals.runnable(rec, keep_busy)
  local red, building
  for _, goal in ipairs(runnable) do
    building = building or goal.status == "ACTIVE"
    if goal.item == "automation-science-pack" and goal.block and goal.block.bus then red = goal end
  end
  -- Inserters come out first (so they don't grab anything meanwhile), a chest emptied before it's picked up.
  local function pick(entities, describe, fix)
    local steps = {}
    for pass = 1, 2 do
      for _, ent in ipairs(entities) do
        if (ent.type == "inserter") == (pass == 1) then
          local p = ent.position
          if ent.type == "container" and not ent.get_inventory(defines.inventory.chest).is_empty() then
            steps[#steps + 1] = {action = "take", x = p.x, y = p.y}
          end
          steps[#steps + 1] = {action = "pick_up", x = p.x, y = p.y}
        end
      end
    end
    return {kind = "steps", describe = describe, args = {steps = steps}, info = {label = describe, partial = true, fix = fix}}
  end
  -- The old red science: its packs don't reach the bus's labs, and its plates come by hand. (Only once the
  -- bus's red science reaches labs by belt, or research would stop; but while another goal is being built
  -- too, since that can take a long time and the old one keeps the engineer fetching plates for it.)
  local belted = s.science_lanes and s.science_lanes["automation-science-pack"]
  if keep_busy and red and red.status == "COMPLETE" and belted and #w.science > 0 and (s.fails["move:science"] or 0) < 3 then
    s.skipped.science, s.skipped.science_gears, s.skipped.more_science = true, true, true
    local set, entities = {}, {}
    local function add(ent)
      if ent and ent.valid and ent.unit_number and not set[ent.unit_number] and (rec.built or {})[ent.unit_number] then
        set[ent.unit_number] = true
        entities[#entities + 1] = ent
      end
    end
    for _, unit in ipairs(w.science) do
      add(unit.asm); add(unit.gear); add(unit.chest); add(unit.gear_chest)
    end
    for _, inserter in ipairs(w.inserters) do
      local from, to = inserter.pickup_target, inserter.drop_target
      if (from and from.unit_number and set[from.unit_number]) or (to and to.unit_number and set[to.unit_number]) then
        add(inserter)
        if to and to.type == "lab" then add(to) end
      end
    end
    return pick(entities, "picking up the old red science by the first lab: red science comes from the main bus now", "move:science")
  end
  if building or table_size(s.bus_slots or {}) >= bus.SLOTS then return nil end
  for _, goal in ipairs(runnable) do
    local fix = "move:" .. goal.id
    -- (Moved once at most: one the bus has no room for is built off it again, and stays there.)
    s.moved = s.moved or {}
    if goal.status == "COMPLETE" and goal.block and not goal.block.bus and not s.moved[goal.id] and (s.fails[fix] or 0) < 3 then
      local entities = {}
      for _, pl in ipairs(block_places(goal.block, cell_tasks(goal))) do
        if pl[1] ~= POLE then
          local ent = present(surface, prototypes.item[pl[1]].place_result.name, pl[2].position)
          if ent and (rec.built or {})[ent.unit_number] then entities[#entities + 1] = ent end
        end
      end
      if #entities > 0 then
        return pick(entities, "picking up the " .. goal.item .. " machines, to build them again on the main bus", fix)
      end
      -- All picked up: the goal is built again from scratch, where the bus finds it room.
      s.moved[goal.id] = true
      goal.block, goal.parts_checked, goal.evaluated = nil, nil, nil
      goal.status, goal.reason, goal.samples = "ACTIVE", nil, {}
      for _, t in ipairs(goal.tasks) do
        if t.kind == "VERIFY" then t.status, t.measured = "BLOCKED", nil end
      end
      h.tell(rec, "Moving the " .. goal.item .. " machines to the main bus: plates come to them by belt there instead of by hand.")
      return nil
    end
  end
end

-- The next job for a goal, or nil and what it's waiting for.
function M.decide(rec, w, goal, h)
  goals.evaluate(rec, goal)
  if goal.status ~= "ACTIVE" and goal.status ~= "COMPLETE" then return nil end
  local building_why
  if goal.status == "ACTIVE" then
    for _, t in ipairs(goal.tasks) do
      if t.kind == "POWER" and t.status ~= "COMPLETE" then
        local action, why, stuck = h.steam(rec, w)
        if stuck then goals.block(rec, goal, "INSUFFICIENT_POWER", why) end
        return action, why
      end
    end
    local action, why = research(rec, w, goal, h)
    if action or why then return action, why end
    -- Building goes on past the machines (BUILD's measure) to everything around them: the inserters
    -- into them go up last.
    local building = not (goal.block and goal.block.placed)
    for _, t in ipairs(goal.tasks) do
      if t.kind == "BUILD" and t.status ~= "COMPLETE" then building = true end
    end
    if building then
      local stuck
      action, why, stuck = build(rec, w, goal, h)
      if stuck then
        goal.block = nil
        goals.block(rec, goal, "NO_PLACEMENT", why)
        return nil, why
      end
      if action then
        -- (A job gathering for the machines has no info of its own.)
        action.info = action.info or {label = "feeding"}
        action.info.goal_id, action.info.origin = goal.id, goal.origin
        return action
      end
      building_why = why
    end
  end
  -- A finished column gets what's missing from it (a part destroyed, or one added since it was built,
  -- like the inserters between cells), but nothing is torn down if that can't be done.
  -- Checked every 10 minutes (it looks at every part).
  if goal.status == "COMPLETE" and goal.block and game.tick - (goal.parts_checked or -36000) >= 36000 then
    local fill, waiting = build(rec, w, goal, h)
    if fill then
      fill.info = fill.info or {label = "feeding"}
      fill.info.goal_id, fill.info.origin = goal.id, goal.origin
      return fill
    end
    -- Still gathering the parts: try again next time; otherwise done (or can't be done) for now.
    if not waiting then goal.parts_checked = game.tick end
  end
  local action, why = feed(rec, w, goal, h)
  if action then
    action.info = {goal_id = goal.id, origin = goal.origin, label = "feeding"}
    return action
  end
  return nil, building_why or why or (goal.status == "ACTIVE" and ("checking the " .. goal.item .. " output") or nil)
end

return M
