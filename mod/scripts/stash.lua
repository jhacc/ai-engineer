-- Keep-busy's storage: when the engineer's inventory runs low on room, what it carries but doesn't use goes
-- into storage chests (iron chests near home, one more as they fill): ore (from picked-up furnaces, or
-- mined for one fed by hand), burner drills once the coal belt runs (electric drills from then on), stone
-- furnaces past a few once the ore lines run, and more stone, wood or coal than it needs. Building and
-- crafting take from them first (autopilot's `get_items`), so nothing put away is lost.
local M = {}

M.CHEST = "iron-chest"
-- Below this many empty slots, things are put away.
local MIN_FREE = 6
-- How many of each to keep on hand (the rest is put away).
local KEEP = {["iron-ore"] = 0, ["copper-ore"] = 0, ["stone"] = 100, ["wood"] = 100, ["coal"] = 200}
local MAX_STEPS = 20

local function box(p, half)
  return {left_top = {x = p.x - half, y = p.y - half}, right_bottom = {x = p.x + half, y = p.y + half}}
end
local function overlaps(a, b)
  return a.left_top.x < b.right_bottom.x and b.left_top.x < a.right_bottom.x and a.left_top.y < b.right_bottom.y
    and b.left_top.y < a.right_bottom.y
end

-- The storage chests still standing.
function M.chests(rec, s)
  local out = {}
  for _, p in ipairs(s.stash or {}) do
    local c = rec.entity.surface.find_entities_filtered{name = M.CHEST, position = p, radius = 0.5}[1]
    if c then out[#out + 1] = c end
  end
  return out
end

-- What to put away: {item, count}, most first.
local function surplus(rec, w, s)
  local e = rec.entity
  local keep = {}
  for item, n in pairs(KEEP) do keep[item] = n end
  if w.count.coal_belt then keep["burner-mining-drill"] = 0 end
  if s.ore_plan and s.ore_plan.done then keep["stone-furnace"] = 10 end
  local out = {}
  for item, n in pairs(keep) do
    local extra = e.get_item_count(item) - n
    if extra > 0 then out[#out + 1] = {item, extra} end
  end
  table.sort(out, function(a, b) return a[2] > b[2] end)
  return out
end

-- A spot for a new storage chest: beside the last one, else near home, out of the areas planned for other
-- things (the power plant's room, the ore lines and bus, goals' columns), with nothing beside it (an
-- inserter there would take from it).
local function spot(rec, s, h, avoid)
  local e = rec.entity
  local surface = e.surface
  local last = s.stash and s.stash[#s.stash]
  local anchor = last or s.home or e.position
  local ax, ay = math.floor(anchor.x), math.floor(anchor.y)
  for _, off in ipairs(h.offsets()) do
    local p = {x = ax + off[1] + 0.5, y = ay + off[2] + 0.5}
    local ok = not (last and p.x == last.x and p.y == last.y)
      and surface.can_place_entity{name = M.CHEST, position = p, force = e.force}
    for _, a in ipairs(ok and avoid or {}) do
      if overlaps(box(p, 1.5), a) then ok = false; break end
    end
    -- Only other storage chests next to it.
    if ok then
      for _, other in ipairs(surface.find_entities_filtered{area = {{p.x - 1.5, p.y - 1.5}, {p.x + 1.5, p.y + 1.5}}}) do
        if other.name ~= M.CHEST and other.type ~= "tree" and other.type ~= "resource" and other.type ~= "character" then ok = false; break end
      end
    end
    if ok then return p end
  end
end

-- A job putting surplus away once there are fewer than MIN_FREE empty slots, or nil.
function M.decide(rec, w, h, avoid)
  local s, e = h.state(rec), rec.entity
  -- (Once started, it goes on until all of it is put away, a chest at a time.)
  if e.get_main_inventory().count_empty_stacks() >= MIN_FREE and not s.stashing then return nil end
  -- Failing over and over (no room for a chest, say): left for 5 minutes.
  if (s.fails.stash or 0) >= 3 then
    s.stash_retry = s.stash_retry or game.tick + 5 * 3600
    if game.tick < s.stash_retry then return nil end
    s.fails.stash, s.stash_retry = nil, nil
  end
  local put = surplus(rec, w, s)
  s.stashing = #put > 0 or nil
  if #put == 0 then return nil end
  local chest
  for _, c in ipairs(M.chests(rec, s)) do
    if c.get_inventory(defines.inventory.chest).count_empty_stacks() > 0 then chest = c; break end
  end
  local steps, at = {}, chest and chest.position
  if not at then
    at = spot(rec, s, h, avoid)
    if not at then s.stashing = nil; return nil end
    local action, waiting, place = h.place_all(rec, w, {{M.CHEST, {position = at}}}, nil, "storage chest")
    if not place then return action, waiting end
    for _, step in ipairs(place) do steps[#steps + 1] = step end
    s.stash = s.stash or {}
    s.stash[#s.stash + 1] = at
  end
  local names = {}
  for _, it in ipairs(put) do
    if #steps < MAX_STEPS then
      steps[#steps + 1] = {action = "insert", item = it[1], count = it[2], x = at.x, y = at.y}
      names[#names + 1] = it[1]
    end
  end
  return {kind = "steps", args = {steps = steps}, fix = "stash",
    describe = "putting " .. table.concat(names, ", ") .. " in a storage chest (the inventory is nearly full)"}
end

return M
