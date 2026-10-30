-- The main bus (the owner's base plan): past the smelting area's east end its plate belts turn in beside
-- its coal belt and run on east side by side, and each goal's sub-factory branches off it to the south.
--
-- Positions are in a frame (`geometry`): the bus is rows 5 (top plates), 6 (coal) and 7 (bottom plates)
-- from column X + 1 east, with an inserter into a chest (`taps`) on each plate belt by column X, where the
-- engineer collects what it builds with. New smelting areas are turned across the bus (autopilot's
-- smelter_layout): their belts come down its columns and turn east onto those rows, and the frame is
-- stored with the plan. Older saves' areas run east, rows counted from their top: the top ore's plates on
-- row 0, coal on row 6, the bottom ore's on row 12, turned toward the coal belt at column X (one past the
-- widest row).
--
-- Slot k is a sub-factory's place along the bus, SLOT_WIDTH tiles each. Its splitters take part of both
-- plate belts off: the bottom one's straight down onto the west side of a feeder belt running south, the
-- top one's round over row 3 and under the bus by underground belt onto its east side, so each plate has
-- its own lane. The sub-factory's assemblers stand east of the feeder (cells.lua), each with an inserter
-- from it: assemblers take only what their recipe uses, so one belt carries both plates.
--
-- The frame can face any way (frame.lua: `g.m`, nil for east with the sub-factories south): every position
-- and direction here is in its terms.
local frame = require("scripts.frame")
local M = {}

local BELT, SPLITTER, UNDERGROUND = "transport-belt", "splitter", "underground-belt"
local INSERTER, CHEST, POLE = "inserter", "wooden-chest", "small-electric-pole"
local N, E, S, W = 0, 1, 2, 3

M.SLOTS, M.SLOT_WIDTH = 8, 13
-- The eight ways a bus can face: running each way, its sub-factories on either side. (Running east with
-- them to the south, the old fixed layout, first.)
M.FRAMES = {}
for _, d in ipairs({1, 2, 3, 0}) do
  for _, mirror in ipairs({false, true}) do M.FRAMES[#M.FRAMES + 1] = frame.make(d, mirror) end
end
-- What the feeder belts carry (the smelting area's two plates).
M.PLATES = {["iron-plate"] = true, ["copper-plate"] = true}
-- Rows south of the bus kept for sub-factories (in planned areas), from the feeder's first row.
local DEPTH = 28

-- The inserter direction (0-3) that drops toward (vx, vy).
local function inserter_toward(vx, vy)
  local drop = prototypes.entity[INSERTER].inserter_drop_position
  local x, y = drop.x or drop[1], drop.y or drop[2]
  for d = 0, 3 do
    if x * vx + y * vy > 0.5 then return d end
    x, y = -y, x
  end
  return 0
end
-- The same for a vector in g's terms.
local function toward(g, vx, vy) return inserter_toward(frame.vec(g.m, vx, vy)) end

-- The bus's frame from the ore lines' plan, once they're built: the smelting area's top left tile, its rows'
-- furnace counts (from where their plate chests were planned) and the turn column X. Nil before (unless
-- `planned`: for keeping its area clear).
-- A smelting area turned across the bus (autopilot's smelter_layout) stores its frame (`turned`).
function M.geometry(plan, planned)
  if plan and plan.frame then return (plan.done or planned) and plan.frame or nil end
  if not (plan and (plan.done or planned) and plan.site and plan.chests and #plan.chests == 2) then return nil end
  local x0, y0 = plan.site.x, plan.site.y
  local n = {}
  for _, c in ipairs(plan.chests) do
    n[math.floor(c.y - y0)] = math.floor((c.x - x0 - 1.5) / 3 + 0.5)
  end
  if not (n[0] and n[12]) then return nil end
  local width = 3 * math.max(n[0], n[12])
  return {x0 = x0, y0 = y0, top = n[0], bottom = n[12], width = width, X = width + 1}
end

-- The point (x, y) in g's terms (its tiles' corners are whole numbers), and tile (tx, ty)'s center.
function M.at(g, x, y) return frame.at(g.m, {x = g.x0, y = g.y0}, x, y) end
function M.tile(g, tx, ty) return M.at(g, tx + 0.5, ty + 0.5) end
-- A direction (0-3) in g's terms, on the map.
function M.dir(g, d) return frame.dir(g.m, d) end
M.toward = toward
-- The box with corners (x0, y0) and (x1, y1) in g's terms, on the map.
function M.box(g, x0, y0, x1, y1) return frame.box(g.m, {x = g.x0, y = g.y0}, x0, y0, x1, y1) end
-- A map point in g's terms.
function M.where(g, p) return frame.unvec(g.m, p.x - g.x0, p.y - g.y0) end

-- Slot k's feeder column (tiles from the smelting area's left).
function M.feeder_x(g, k) return g.X + 5 + M.SLOT_WIDTH * k end

-- Where the bus's belts, every slot's splitters, branches, riser and sub-factory go, from its start on: no
-- pole goes there. Poles stand between them (wires cross the bus there).
function M.corridor(g)
  local out = {}
  local function add(tx0, ty0, tx1, ty1)
    out[#out + 1] = frame.box(g.m, {x = g.x0, y = g.y0}, tx0, ty0, tx1 + 1, ty1 + 1)
  end
  add(g.X + 1, 5, M.feeder_x(g, M.SLOTS) + 8, 7)
  for k = 0, M.SLOTS - 1 do
    local A = M.feeder_x(g, k)
    add(A - 4, 2, A + 1, 10)
    add(A + 6, -1, A + 7, 10)
    add(A - 1, 9, A + 7, 9 + DEPTH)
  end
  return out
end

-- The area kept for the bus, its sub-factories, and the labs and science belt north of it.
function M.area(g)
  return frame.box(g.m, {x = g.x0, y = g.y0}, g.X + 1, -4, M.feeder_x(g, M.SLOTS - 1) + 9, 9 + DEPTH)
end

local function belt(g, tx, ty, dir) return {BELT, {position = M.tile(g, tx, ty), direction = M.dir(g, dir)}} end

-- The bus's start: each plate belt carried on east to X and turned in beside the coal belt, the coal belt
-- carried on to X, and the taps. `old`: what stood at the plate belts' ends before (an inserter into a
-- chest), taken away first.
function M.base(g)
  local places, old, taps = {}, {}, {}
  -- Smelting columns (autopilot's smelter_layout) build the bus's start and taps themselves: the top plates'
  -- tap above row 5, the bottom plates' below row 7. So did the turned block before them (its east plates'
  -- tap off column X).
  if g.columns then return places, old, {M.tile(g, g.X - 1, 3), M.tile(g, g.X - 1, 9)} end
  if g.turned then return places, old, {M.tile(g, g.X + 2, 2), M.tile(g, g.X - 1, 9)} end
  -- (The taps' poles 6 tiles apart, so they're wired to each other.)
  for _, row in ipairs({{ty = 0, n = g.top, step = 1, bus = 5, tap = 2, pole = 3}, {ty = 12, n = g.bottom, step = -1, bus = 7, tap = 10, pole = 9}}) do
    old[#old + 1] = {inserter = M.tile(g, 3 * row.n, row.ty), chest = M.tile(g, 3 * row.n + 1, row.ty)}
    for tx = 3 * row.n, g.X - 1 do places[#places + 1] = belt(g, tx, row.ty, E) end
    local down = row.step == 1 and S or N
    for ty = row.ty, row.bus - row.step, row.step do places[#places + 1] = belt(g, g.X, ty, down) end
    places[#places + 1] = belt(g, g.X, row.bus, E)
    -- The tap: an inserter off the turned belt into a chest, with a pole.
    places[#places + 1] = {POLE, {position = M.tile(g, g.X + 1, row.pole)}}
    places[#places + 1] = {INSERTER, {position = M.tile(g, g.X + 1, row.tap), direction = toward(g, 1, 0)}}
    places[#places + 1] = {CHEST, {position = M.tile(g, g.X + 2, row.tap)}}
    taps[#taps + 1] = M.tile(g, g.X + 2, row.tap)
  end
  for tx = g.width, g.X do places[#places + 1] = belt(g, tx, 6, E) end
  return places, old, taps
end

-- Slot k's parts: the bus through it (past earlier slots' splitters: `taken` lists the slots that have
-- them), its splitters, the branches and the feeder belt down to row `last`.
function M.slot(g, k, taken, last)
  local A = M.feeder_x(g, k)
  local sx = A - 4
  local places = {}
  for tx = g.X + 1, A + 8 do
    local j = (tx - g.X - 1) % M.SLOT_WIDTH == 0 and math.floor((tx - g.X - 1) / M.SLOT_WIDTH) or nil
    local split = j and (j == k or taken[j])
    for _, ty in ipairs({5, 6, 7}) do
      if not (split and ty ~= 6) then places[#places + 1] = belt(g, tx, ty, E) end
    end
  end
  -- A splitter facing east is two tiles tall: its center lies on the line between its rows.
  places[#places + 1] = {SPLITTER, {position = M.at(g, sx + 0.5, 5), direction = M.dir(g, E)}}
  places[#places + 1] = {SPLITTER, {position = M.at(g, sx + 0.5, 8), direction = M.dir(g, E)}}
  -- The top plates: up a row, east along row 3, under the bus one column past the feeder, and onto the
  -- feeder's east side.
  places[#places + 1] = belt(g, sx + 1, 4, N)
  for tx = sx + 1, A do places[#places + 1] = belt(g, tx, 3, E) end
  places[#places + 1] = belt(g, A + 1, 3, S)
  places[#places + 1] = {UNDERGROUND, {position = M.tile(g, A + 1, 4), direction = M.dir(g, S), belt_type = "input"}}
  places[#places + 1] = {UNDERGROUND, {position = M.tile(g, A + 1, 8), direction = M.dir(g, S), belt_type = "output"}}
  places[#places + 1] = belt(g, A + 1, 9, W)
  -- The bottom plates: east along row 8, then onto the feeder's west side. Fed from both sides and not
  -- from behind, the feeder's first tile puts each side's items on its own lane, whatever lanes they came on.
  for tx = sx + 1, A - 2 do places[#places + 1] = belt(g, tx, 8, E) end
  places[#places + 1] = belt(g, A - 1, 8, S)
  places[#places + 1] = belt(g, A - 1, 9, E)
  for ty = 9, last do places[#places + 1] = belt(g, A, ty, S) end
  return places, A
end

-- Power along the bus: a line of poles on row 8, from the bottom tap's pole to slot k, two to a slot (two
-- tiles past its feeder, and in the column between its riser and the next slot's splitters), at most 7
-- tiles apart. So a slot gets power whether or not the ones before it are built.
function M.power(g, k)
  local places = {}
  for j = 0, k do
    local A = M.feeder_x(g, j)
    places[#places + 1] = {POLE, {position = M.tile(g, A + 2, 8)}}
    if j < k then places[#places + 1] = {POLE, {position = M.tile(g, A + 8, 8)}} end
  end
  return places
end

-- Science packs go up to the labs north of the bus: a riser belt from slot k's bottom product cell (row
-- `last`) up the column 7 tiles east of the feeder (where the cells' long-handed inserters drop them),
-- under the bus by underground belt, and onto the science belt's `lane`. It joins the belt from the side
-- where the belt goes on past it, so it's a sideload: everything goes onto the lane on that side, a kind
-- of pack each, and a lane that fills up only stops its own packs. The north lane goes under the science
-- belt and back down onto it. Returns the places and the riser's column.
function M.riser(g, k, lane, last)
  local x = M.feeder_x(g, k) + 7
  local places = {}
  for ty = last, 10, -1 do places[#places + 1] = belt(g, x, ty, N) end
  places[#places + 1] = {UNDERGROUND, {position = M.tile(g, x, 9), direction = M.dir(g, N), belt_type = "input"}}
  places[#places + 1] = {UNDERGROUND, {position = M.tile(g, x, 4), direction = M.dir(g, N), belt_type = "output"}}
  places[#places + 1] = belt(g, x, 3, N)
  if lane == "south" then
    places[#places + 1] = belt(g, x, 2, N)
  else
    places[#places + 1] = {UNDERGROUND, {position = M.tile(g, x, 2), direction = M.dir(g, N), belt_type = "input"}}
    places[#places + 1] = {UNDERGROUND, {position = M.tile(g, x, 0), direction = M.dir(g, N), belt_type = "output"}}
    places[#places + 1] = belt(g, x, -1, W)
    places[#places + 1] = belt(g, x - 1, -1, S)
    places[#places + 1] = belt(g, x - 1, 0, S)
  end
  return places, x
end

-- The labs: LABS in a row north of the bus's start (rows -3 to -1), each with an inserter off the science
-- belt, which runs west along row 1 from `head` (a tile past the last riser) to the first lab.
M.LABS = 3
function M.lab_positions(g)
  local out = {}
  for i = 0, M.LABS - 1 do out[#out + 1] = M.tile(g, g.X + 2 + 4 * i, -2) end
  return out
end

function M.labs(g, head)
  local places = {}
  for i = 0, M.LABS - 1 do
    local tx = g.X + 2 + 4 * i
    places[#places + 1] = {"lab", {position = M.tile(g, tx, -2)}}
    places[#places + 1] = {INSERTER, {position = M.tile(g, tx, 0), direction = toward(g, 0, -1)}}
    if i < M.LABS - 1 then places[#places + 1] = {POLE, {position = M.tile(g, tx + 2, -2)}} end
  end
  for tx = g.X + 2, head do places[#places + 1] = belt(g, tx, 1, W) end
  return places
end

M.ITEMS = {SPLITTER, UNDERGROUND}

return M
