-- Goals: what the engineer works toward, planned from the game's own recipes and tech tree instead of a
-- hand-written plan. "Automate electronic-circuit at 15/min" becomes tasks: research, supplies,
-- power, machines to build and a check that they really make it. The goals and their tasks are kept in
-- the save with stable ids, so asking again never duplicates them, and their status is read from the
-- world: a task is done when the game shows it (research done, machines placed, output measured), never
-- because a build job ran. cells.lua does the building.
--
-- Who a goal is for decides when it runs: the owner's goals (PLAYER) run whether keep-busy is on or off;
-- keep-busy's own (AUTONOMOUS) only while it's on, and pause when it's turned off.
local util = require("scripts.util")
local plan = require("scripts.plan")
local frame = require("scripts.frame")
local M = {}

local DEFAULT_RATE = 15 -- per minute
local MAX_DEPTH = 12
local EVAL_TICKS = 120
-- Output is measured over a minute, and has to reach this share of the goal's rate.
local VERIFY_TICKS, VERIFY_SHARE = 60 * 60, 0.8
-- Items the cells get from the burner base (or by hand) instead of from machines of their own.
M.SUPPLIED = {["iron-plate"] = true, ["copper-plate"] = true, coal = true, stone = true, wood = true}
-- What a cell is built from (besides its machine), so research for them is planned too.
M.CELL_PARTS = {"small-electric-pole", "inserter", "wooden-chest"}
-- Science packs, in order: keep-busy automates the next one it doesn't make yet.
local LADDER = {"automation-science-pack", "logistic-science-pack", "mall", "military-science-pack", "chemical-science-pack",
  "production-science-pack", "utility-science-pack"}
-- The mall: what the engineer builds with, each made in an assembler filling a chest it takes them from
-- (the ones whose recipes are unlocked when it's planned), MALL_RATE per minute each.
M.MALL = {"transport-belt", "inserter", "small-electric-pole", "pipe", "underground-belt", "splitter", "long-handed-inserter",
  "electric-mining-drill", "stone-furnace", "assembling-machine-1"}
local MALL_RATE = 2

---------------------------------------------------------------------------
-- Planning: an AND/OR search over a recipe graph. An item can be made by any of its recipes (OR); a
-- recipe needs all of its ingredients, its unlocking research, a machine and a surface it works on (AND).
-- The graph is the loaded game's (game_graph) or a small made-up one for tests (fixture_graph), so the
-- search itself never touches the game.

local function append_unique(list, seen, items)
  for _, x in ipairs(items) do
    if not seen[x] then seen[x] = true; list[#list + 1] = x end
  end
end

-- Unresearched technologies up to and including `name`, prerequisites first.
local function tech_path(g, name, out, seen, stack, blockers)
  local t = g.tech(name)
  if not t then blockers[#blockers + 1] = {code = "UNKNOWN_TECH", what = name, text = "no technology " .. name}; return end
  if t.researched or seen[name] then return end
  if stack[name] then blockers[#blockers + 1] = {code = "CYCLE", what = name, text = name .. " needs itself"}; return end
  stack[name] = true
  for _, pre in ipairs(t.prerequisites) do tech_path(g, pre, out, seen, stack, blockers) end
  stack[name] = nil
  seen[name] = true
  out[#out + 1] = name
end

-- The research that unlocks a recipe: the shortest path among the technologies that unlock it.
local function unlock_research(g, recipe)
  local best
  for _, tech in ipairs(g.unlocks(recipe)) do
    local out, blockers = {}, {}
    tech_path(g, tech, out, {}, {}, blockers)
    if not best or #blockers < #best.blockers or (#blockers == #best.blockers and #out < #best.research) then
      best = {research = out, blockers = blockers, tech = tech}
    end
  end
  return best
end

-- The research that lets the engineer have `item` at all: machines and cell parts are hand-crafted, so
-- they need a recipe unlocked, not a production line (which would be circular: assemblers make the
-- circuits that assemblers are made of).
local function unlock_item(ctx, item)
  local g = ctx.g
  local best
  for _, name in ipairs(g.producers(item)) do
    if g.enabled(name) then return {research = {}, blockers = {}, size = 0} end
    local u = unlock_research(g, name)
    if u and (not best or #u.blockers < #best.blockers or (#u.blockers == #best.blockers and #u.research < #best.research)) then
      best = {research = u.research, blockers = u.blockers, size = 0}
    end
  end
  return best or {research = {}, blockers = {{code = "RECIPE_LOCKED", what = item, text = "no research left unlocks " .. item}}, size = 0}
end

local function score(o) return {#o.blockers, #o.research, o.renamed and 1 or 0, o.size} end
local function better(a, b)
  local sa, sb = score(a), score(b)
  for i = 1, #sa do
    if sa[i] ~= sb[i] then return sa[i] < sb[i] end
  end
  return false
end

local function merge(into, from)
  append_unique(into.research, into.research_seen, from.research)
  into.blocker_seen = into.blocker_seen or {}
  for _, b in ipairs(into.blockers) do into.blocker_seen[b.code .. ":" .. b.what] = true end
  for _, b in ipairs(from.blockers) do
    local k = b.code .. ":" .. b.what
    if not into.blocker_seen[k] then into.blocker_seen[k] = true; into.blockers[#into.blockers + 1] = b end
  end
  into.size = into.size + (from.size or 0)
  if from.cyclic then into.cyclic = true end
end

-- The best way to get `item`: {recipe or source, research, blockers, size}. Memoized unless a cycle
-- shaped it (the same item can be fine when reached another way).
local function choose(ctx, item, stack, depth)
  local g = ctx.g
  if ctx.memo[item] then return ctx.memo[item] end
  if ctx.supplied[item] then return {supplied = true, research = {}, blockers = {}, size = 0} end
  local source = g.source(item)
  if source then
    local o = {source = source, research = {}, blockers = {}, size = 0}
    ctx.memo[item] = o
    return o
  end
  if stack[item] then
    return {research = {}, blockers = {{code = "CYCLE", what = item, text = item .. " is needed to make itself"}}, size = 0, cyclic = true}
  end
  if depth > MAX_DEPTH then
    return {research = {}, blockers = {{code = "TOO_DEEP", what = item, text = item .. " is too many steps away"}}, size = 0}
  end
  stack[item] = true
  local best
  local candidates = ctx.only and ctx.only[item] and {ctx.only[item]} or g.producers(item)
  for _, name in ipairs(candidates) do
    local r = g.recipe(name)
    local o = {recipe = name, research = {}, research_seen = {}, blockers = {}, size = 1, renamed = name ~= item}
    if not g.enabled(name) then
      local unlock = unlock_research(g, name)
      if unlock then
        merge(o, {research = unlock.research, blockers = unlock.blockers})
      else
        o.blockers[#o.blockers + 1] = {code = "RECIPE_LOCKED", what = name, text = "no research left unlocks the recipe " .. name}
      end
    end
    local ok, why = g.surface_ok(name)
    if not ok then o.blockers[#o.blockers + 1] = {code = "NO_VALID_SURFACE", what = name, text = name .. " can't be made here: " .. why} end
    local machine = g.machine(r.category)
    if not machine then
      o.blockers[#o.blockers + 1] = {code = "UNKNOWN_CAPABILITY", what = r.category, text = "no machine makes " .. r.category .. " recipes"}
    elseif not machine.unlocked and machine.item then
      merge(o, unlock_item(ctx, machine.item))
    end
    for _, i in ipairs(r.ingredients) do merge(o, choose(ctx, i.name, stack, depth + 1)) end
    if not best or better(o, best) then best = o end
  end
  stack[item] = nil
  if not best then
    best = {research = {}, blockers = {{code = "NO_SOURCE", what = item, text = "no recipe or resource makes " .. item}}, size = 0}
  end
  best.alternatives = #candidates > 1 and candidates or nil
  if not best.cyclic then ctx.memo[item] = best end
  return best
end

-- Adds what it takes to make `rate` per minute of `item` along the chosen recipes: ctx.made (recipes,
-- upstream first) and ctx.raw (supplies).
local function expand(ctx, item, rate, stack)
  local o = choose(ctx, item, {}, 0)
  if not o.recipe or stack[item] then
    if not ctx.raw[item] then ctx.raw[item] = {item = item, rate = 0, source = o.source, supplied = o.supplied}; ctx.raw_order[#ctx.raw_order + 1] = item end
    ctx.raw[item].rate = ctx.raw[item].rate + rate
    return
  end
  local r = ctx.g.recipe(o.recipe)
  local crafts = rate / math.max(plan.makes(r, item), 0.001)
  stack[item] = true
  for _, i in ipairs(r.ingredients) do expand(ctx, i.name, crafts * i.amount, stack) end
  stack[item] = nil
  local entry = ctx.made[o.recipe]
  if not entry then
    entry = {recipe = o.recipe, item = item, rate = 0, crafts = 0, category = r.category, energy = r.energy,
      fluid = r.fluid, ingredients = #r.ingredients, alternatives = o.alternatives}
    ctx.made[o.recipe] = entry
    ctx.made_order[#ctx.made_order + 1] = o.recipe
  end
  entry.rate, entry.crafts = entry.rate + rate, entry.crafts + crafts
end

local function round(x) return math.floor(x * 10 + 0.5) / 10 end

-- Plans `rate` per minute of `item`: {recipes (upstream first, with machine counts), raw, research
-- (prerequisites first), blockers, trace}. `opts.recipe` picks the target's recipe; `opts.supplied` are
-- items taken as given; `opts.parts` are items to build with (their research is planned too).
function M.resolve(g, item, rate, opts)
  opts = opts or {}
  local ctx = {g = g, memo = {}, made = {}, made_order = {}, raw = {}, raw_order = {}, supplied = opts.supplied or {},
    only = opts.recipe and {[item] = opts.recipe} or nil}
  local top = choose(ctx, item, {}, 0)
  local research, seen = {}, {}
  local blockers = {}
  for _, b in ipairs(top.blockers) do blockers[#blockers + 1] = b end
  append_unique(research, seen, top.research)
  local trace = {}
  if top.recipe then
    expand(ctx, item, rate, {})
  elseif not top.blockers[1] then
    blockers[#blockers + 1] = {code = "NOT_MADE", what = item, text = item .. (top.supplied
      and " comes from drills and furnaces (keep-busy's build order grows those), not assemblers" or " is mined, not made") ..
      ", so it can't be a goal. For some now, call give (or insert) with it and its count: that builds drills for it if it needs them"}
  end
  local recipes = {}
  for _, name in ipairs(ctx.made_order) do
    local e = ctx.made[name]
    local machine = g.machine(e.category)
    if machine then
      e.machine = machine.name
      e.machine_type = machine.type
      e.count = math.max(1, math.ceil(e.crafts * e.energy / (60 * machine.speed) - 0.001))
      if not machine.unlocked and machine.item then append_unique(research, seen, unlock_item(ctx, machine.item).research) end
    end
    recipes[#recipes + 1] = e
    trace[#trace + 1] = e.item .. ": recipe " .. name .. (e.alternatives and (" (of " .. table.concat(e.alternatives, ", ") .. ")") or "") ..
      ", " .. round(e.rate) .. "/min" .. (e.count and (" in " .. e.count .. " " .. e.machine) or "")
  end
  for _, part in ipairs(opts.parts or {}) do
    local o = unlock_item(ctx, part)
    append_unique(research, seen, o.research)
    for _, b in ipairs(o.blockers) do blockers[#blockers + 1] = b end
  end
  local raw = {}
  for _, name in ipairs(ctx.raw_order) do
    local r = ctx.raw[name]
    raw[#raw + 1] = r
    trace[#trace + 1] = name .. ": " .. round(r.rate) .. "/min " .. (r.supplied and "from the base" or
      (r.source and r.source.text) or "with no source")
  end
  for _, t in ipairs(research) do trace[#trace + 1] = "research " .. t end
  -- Items with no way to get them (deeper than the chosen recipe) are blockers too.
  local listed = {}
  for _, b in ipairs(blockers) do listed[b.code .. ":" .. b.what] = true end
  for _, e in ipairs(recipes) do
    local o = ctx.memo[e.item] or choose(ctx, e.item, {}, 0)
    for _, b in ipairs(o.blockers) do
      if not listed[b.code .. ":" .. b.what] then listed[b.code .. ":" .. b.what] = true; blockers[#blockers + 1] = b end
    end
  end
  for _, b in ipairs(blockers) do trace[#trace + 1] = "blocked: " .. b.text end
  return {item = item, rate = rate, recipe = top.recipe, alternatives = top.alternatives, recipes = recipes, raw = raw,
    research = research, blockers = blockers, trace = trace}
end

-- The loaded game's recipes and technologies, for one force on one surface.
function M.game_graph(force, surface)
  local ctx = plan.context(force)
  local unlocks = {}
  for name, tech in pairs(prototypes.technology) do
    for _, effect in ipairs(tech.effects or {}) do
      if effect.type == "unlock-recipe" then
        unlocks[effect.recipe] = unlocks[effect.recipe] or {}
        table.insert(unlocks[effect.recipe], name)
      end
    end
  end
  for _, list in pairs(unlocks) do table.sort(list) end
  local sources, machines = {}, {}
  local g = {}
  g.producers = function(item)
    local out = {}
    for _, r in ipairs(ctx.index[item] or {}) do out[#out + 1] = r.name end
    table.sort(out)
    return out
  end
  g.recipe = function(name)
    local r = prototypes.recipe[name]
    local fluid = false
    for _, x in ipairs(r.ingredients) do if x.type == "fluid" then fluid = true end end
    for _, x in ipairs(r.products) do if x.type == "fluid" then fluid = true end end
    return {name = name, ingredients = r.ingredients, products = r.products, category = util.category(r), energy = r.energy, fluid = fluid}
  end
  g.enabled = function(name)
    local r = force.recipes[name]
    return r ~= nil and r.enabled
  end
  g.surface_ok = function(name)
    for _, c in ipairs(prototypes.recipe[name].surface_conditions or {}) do
      local ok, value = pcall(surface.get_property, c.property)
      if ok and value and ((c.min and value < c.min) or (c.max and value > c.max)) then
        return false, c.property .. " is " .. value .. " on " .. surface.name
      end
    end
    return true
  end
  g.unlocks = function(name)
    local out = {}
    for _, t in ipairs(unlocks[name] or {}) do
      local tech = force.technologies[t]
      if tech and tech.enabled and not tech.researched then out[#out + 1] = t end
    end
    return out
  end
  g.tech = function(name)
    local t = force.technologies[name]
    if not t then return nil end
    local pre = {}
    for n in pairs(t.prerequisites) do pre[#pre + 1] = n end
    table.sort(pre)
    local trigger = t.prototype.research_trigger
    return {name = name, prerequisites = pre, researched = t.researched, trigger = trigger and plan.trigger_text(trigger)}
  end
  g.source = function(item)
    if sources[item] == nil then
      local s = false
      if item == "wood" then s = {kind = "chop", text = "chopped from trees"}
      elseif item == "water" then s = {kind = "pump", text = "an offshore pump"}
      else
        local res = plan.resource_for(item)
        if res then
          local miner = plan.miner_for(ctx, res.resource_category)
          s = {kind = "mine", entity = res.name, miner = miner and miner.name, text = "mined from " .. res.name}
        end
      end
      sources[item] = s
    end
    return sources[item] or nil
  end
  g.machine = function(category)
    if machines[category] == nil then
      local m = plan.machine_for(ctx, category)
      local item = m and m.proto.items_to_place_this and m.proto.items_to_place_this[1]
      machines[category] = m and {name = m.proto.name, type = m.proto.type, speed = plan.crafting_speed(m.proto),
        unlocked = m.built, item = item and item.name} or false
    end
    return machines[category] or nil
  end
  return g
end

-- A made-up graph for tests: {recipes = {{name, ingredients, products, category, energy, enabled}},
-- technologies = {{name, prerequisites, unlocks, researched}}, sources = {item names}, machines =
-- {category = {name, speed, unlocked}}, wrong_surface = {recipe names}}.
function M.fixture_graph(f)
  local recipes, techs, unlocks, producers, sources, wrong = {}, {}, {}, {}, {}, {}
  for _, r in ipairs(f.recipes or {}) do
    local function list(xs)
      local out = {}
      for _, x in ipairs(xs or {}) do out[#out + 1] = {name = x.name or x[1], amount = x.amount or x[2] or 1, type = x.type or "item"} end
      return out
    end
    recipes[r.name] = {name = r.name, ingredients = list(r.ingredients), products = list(r.products), category = r.category or "crafting",
      energy = r.energy or 1, enabled = r.enabled == true}
    for _, p in ipairs(recipes[r.name].products) do
      local uses = false
      for _, i in ipairs(recipes[r.name].ingredients) do if i.name == p.name then uses = true end end
      if not uses then
        producers[p.name] = producers[p.name] or {}
        table.insert(producers[p.name], r.name)
      end
    end
  end
  for _, list in pairs(producers) do table.sort(list) end
  for _, t in ipairs(f.technologies or {}) do
    techs[t.name] = {name = t.name, prerequisites = t.prerequisites or {}, researched = t.researched == true}
    table.sort(techs[t.name].prerequisites)
    for _, r in ipairs(t.unlocks or {}) do
      unlocks[r] = unlocks[r] or {}
      table.insert(unlocks[r], t.name)
    end
  end
  for _, s in ipairs(f.sources or {}) do sources[s] = {kind = "mine", text = "mined"} end
  for _, r in ipairs(f.wrong_surface or {}) do wrong[r] = true end
  local machines = f.machines or {crafting = {name = "assembler", speed = 1, unlocked = true}}
  return {
    producers = function(item) return producers[item] or {} end,
    recipe = function(name) return recipes[name] end,
    enabled = function(name) return recipes[name].enabled end,
    surface_ok = function(name) return not wrong[name], "wrong surface" end,
    unlocks = function(name)
      local out = {}
      for _, t in ipairs(unlocks[name] or {}) do if not techs[t].researched then out[#out + 1] = t end end
      return out
    end,
    tech = function(name) return techs[name] end,
    source = function(item) return sources[item] end,
    machine = function(category)
      local m = machines[category]
      return m and {name = m.name, type = m.type or "assembling-machine", speed = m.speed or 1, unlocked = m.unlocked ~= false, item = m.item} or nil
    end,
  }
end

---------------------------------------------------------------------------
-- The ledger: storage.goals[owner] = {next = n, list = {goal, ...}}

local function ledger(owner)
  storage.goals = storage.goals or {}
  storage.goals[owner] = storage.goals[owner] or {next = 1, list = {}}
  return storage.goals[owner]
end

function M.list(owner) return ledger(owner).list end

function M.get(owner, id)
  for _, goal in ipairs(ledger(owner).list) do
    if goal.id == id then return goal end
  end
end

local function power_sources(surface, force, near)
  return surface.find_entities_filtered{position = near, radius = 256, force = force,
    type = {"generator", "solar-panel", "electric-energy-interface", "burner-generator"}}
end
M.power_sources = power_sources

-- How the engineer can build a recipe's machines: "cell" (an assembler or furnace it places and feeds by
-- hand), or nil and why not. A furnace picks its recipe from what's put in it, so it can only make
-- recipes of one ingredient (steel from iron plates, bricks from stone).
local function executor(entry)
  if entry.fluid then return nil, "can't pipe the fluids " .. entry.recipe .. " uses yet" end
  if entry.machine_type == "furnace" and entry.ingredients ~= 1 then
    return nil, "can't feed a " .. entry.machine .. " the " .. entry.ingredients .. " ingredients of " .. entry.recipe
  end
  if entry.machine_type ~= "assembling-machine" and entry.machine_type ~= "furnace" then
    return nil, "can't build " .. (entry.machine or entry.category) .. "s for " .. entry.item .. " yet"
  end
  return "cell"
end

-- The tasks for a plan. Ids are the goal's plus what the task is for, so the same plan gives the same ids.
local function tasks_for(goal, p)
  local tasks = {}
  local function add(t)
    t.id = goal.id .. "/" .. t.kind:lower() .. ":" .. (t.target or "")
    t.parent = goal.id
    t.status = "AVAILABLE"
    tasks[#tasks + 1] = t
    return t
  end
  local research = {}
  for _, tech in ipairs(p.research) do research[#research + 1] = add({kind = "RESEARCH", target = tech}).id end
  add({kind = "POWER", target = "electric network"})
  for _, r in ipairs(p.raw) do
    add({kind = "SUPPLY", target = r.item, rate = round(r.rate), supplied = r.supplied, text = r.supplied and "from the base" or (r.source and r.source.text)})
  end
  local blockers = {}
  for _, e in ipairs(p.recipes) do
    local how, why = executor(e)
    if not how then blockers[#blockers + 1] = {code = "UNKNOWN_CAPABILITY", what = e.recipe, text = "the engineer " .. why} end
    add({kind = "BUILD", target = e.recipe, item = e.item, rate = round(e.rate), count = e.count, machine = e.machine, executor = how,
      depends = research})
  end
  add({kind = "VERIFY", target = goal.item, rate = goal.rate, recipe = p.recipe})
  return tasks, blockers
end

-- A new goal to automate `item` at `rate` per minute, or the same one if it's already there.
-- origin: "PLAYER" (the owner asked) or "AUTONOMOUS" (keep-busy chose it).
function M.add(rec, item, rate, origin, recipe)
  local e = rec.entity
  rate = rate or DEFAULT_RATE
  local key = "automate:" .. item .. ":" .. rate .. ":" .. e.surface.name .. (recipe and (":" .. recipe) or "")
  local book = ledger(rec.owner)
  for _, goal in ipairs(book.list) do
    -- A blocked goal is planned again: the world may have changed since.
    if goal.key == key and goal.status == "BLOCKED" then goal.status = "CANCELLED" end
    if goal.key == key and goal.status ~= "CANCELLED" then
      if goal.status == "PAUSED" and origin == "PLAYER" then goal.status, goal.reason = "ACTIVE", nil end
      if origin == "PLAYER" then goal.origin = "PLAYER" end
      return goal, true
    end
  end
  local g = M.game_graph(e.force, e.surface)
  if recipe then
    local ok = false
    for _, name in ipairs(g.producers(item)) do if name == recipe then ok = true end end
    if not ok then util.fail("No recipe " .. recipe .. " makes " .. item .. "; the recipes for it are: " .. table.concat(g.producers(item), ", ")) end
  end
  local parts = {}
  for _, part in ipairs(M.CELL_PARTS) do parts[#parts + 1] = part end
  local p = M.resolve(g, item, rate, {recipe = recipe, supplied = M.SUPPLIED, parts = parts})
  for _, entry in ipairs(p.recipes) do
    if entry.machine then
      local machine_item = g.machine(entry.category).item
      if machine_item then parts[#parts + 1] = machine_item end
    end
  end
  p = M.resolve(g, item, rate, {recipe = recipe, supplied = M.SUPPLIED, parts = parts})
  local goal = {id = "g" .. book.next, key = key, kind = "automate", item = item, rate = rate, recipe = p.recipe, origin = origin,
    root_origin = origin, status = "ACTIVE", created = game.tick, surface = e.surface.name, trace = p.trace,
    alternatives = p.alternatives, made = 0, units = {}, samples = {}}
  book.next = book.next + 1
  local tasks, more = tasks_for(goal, p)
  goal.tasks = tasks
  local blockers = p.blockers
  for _, b in ipairs(more) do blockers[#blockers + 1] = b end
  if #blockers > 0 then
    goal.status = "BLOCKED"
    local texts = {}
    for _, b in ipairs(blockers) do texts[#texts + 1] = b.code .. ": " .. b.text end
    goal.reason = table.concat(texts, "; ")
    goal.trace[#goal.trace + 1] = "blocked: " .. goal.reason
  end
  book.list[#book.list + 1] = goal
  return goal, false
end

-- The mall as one goal (item "mall"): every MALL item whose recipe is unlocked, planned together in one
-- column (shared parts made once), each finished item filling its own chest. Done once each has been made.
function M.add_mall(rec, origin)
  local e = rec.entity
  local key = "mall:" .. e.surface.name
  local book = ledger(rec.owner)
  for _, goal in ipairs(book.list) do
    if goal.key == key and goal.status == "BLOCKED" then goal.status = "CANCELLED" end
    if goal.key == key and goal.status ~= "CANCELLED" then
      if goal.status == "PAUSED" and origin == "PLAYER" then goal.status, goal.reason = "ACTIVE", nil end
      if origin == "PLAYER" then goal.origin = "PLAYER" end
      return goal, true
    end
  end
  local g = M.game_graph(e.force, e.surface)
  local merged = {recipes = {}, raw = {}, research = {}, trace = {}}
  local by_recipe, research_seen, raw_at, products = {}, {}, {}, {}
  for _, item in ipairs(M.MALL) do
    local r = e.force.recipes[item]
    if prototypes.item[item] and r and r.enabled then
      local p = M.resolve(g, item, MALL_RATE, {supplied = M.SUPPLIED})
      if #p.blockers == 0 and p.recipe then
        products[#products + 1] = p.recipe
        for _, entry in ipairs(p.recipes) do
          local had = by_recipe[entry.recipe]
          if had then had.count = math.max(had.count or 1, entry.count or 1)
          else by_recipe[entry.recipe] = entry; merged.recipes[#merged.recipes + 1] = entry end
        end
        append_unique(merged.research, research_seen, p.research)
        for _, x in ipairs(p.raw) do
          if raw_at[x.item] then raw_at[x.item].rate = raw_at[x.item].rate + x.rate
          else raw_at[x.item] = {item = x.item, rate = x.rate, source = x.source, supplied = x.supplied}; merged.raw[#merged.raw + 1] = raw_at[x.item] end
        end
        merged.trace[#merged.trace + 1] = item .. ": recipe " .. p.recipe
      end
    end
  end
  if #products == 0 then util.fail("Nothing for a mall can be made yet") end
  local goal = {id = "g" .. book.next, key = key, kind = "mall", item = "mall", rate = MALL_RATE, products = products, origin = origin,
    root_origin = origin, status = "ACTIVE", created = game.tick, surface = e.surface.name, trace = merged.trace, made = 0, units = {}, samples = {}}
  book.next = book.next + 1
  local tasks, blockers = tasks_for(goal, merged)
  goal.tasks = tasks
  if #blockers > 0 then
    local texts = {}
    for _, b in ipairs(blockers) do texts[#texts + 1] = b.code .. ": " .. b.text end
    goal.status, goal.reason = "BLOCKED", table.concat(texts, "; ")
  end
  book.list[#book.list + 1] = goal
  return goal, false
end

---------------------------------------------------------------------------
-- Status from the world

-- Where cell i of a column has its machine: an assembler fills the 3x3 cell; a 2x2 furnace sits in its
-- lower right (in the column's terms, frame.lua's b.m), where the output inserter and the inserter to the
-- next cell pick up from.
function M.machine_pos(b, i)
  local c = b.cells[i]
  local proto = b.machines and prototypes.entity[b.machines[i]]
  if not proto then return c end
  return frame.at(b.m, c, proto.tile_width % 2 == 0 and 0.5 or 0, proto.tile_height % 2 == 0 and 0.5 or 0)
end

-- The recipe a cell's machine is for. A furnace only has one while it smelts, so it's the recipe of the
-- column cell it stands in; any other furnace (the base's plate furnaces) has none.
function M.cell_recipe(rec, entity)
  if entity.type == "assembling-machine" then
    local r = entity.get_recipe()
    return r and r.name
  end
  if entity.type ~= "furnace" then return nil end
  local p = entity.position
  for _, goal in ipairs(ledger(rec.owner).list) do
    local b = goal.block
    for i in ipairs(b and b.machines or {}) do
      local at = M.machine_pos(b, i)
      if math.abs(at.x - p.x) < 0.1 and math.abs(at.y - p.y) < 0.1 then return b.recipes[i] end
    end
  end
end

-- Whether a machine can run where it stands: on power, or burning fuel (that's maintenance's job).
function M.hooked_up(m)
  return not m.prototype.electric_energy_source_prototype or m.is_connected_to_electric_network()
end

local function cells_of(rec, recipe)
  local out = {}
  for _, entity in pairs(rec.built or {}) do
    if entity.valid and (entity.type == "assembling-machine" or entity.type == "furnace") and M.cell_recipe(rec, entity) == recipe then
      out[#out + 1] = entity
    end
  end
  return out
end
M.cells_of = cells_of

local function drills_on(surface, force, resource)
  for _, d in ipairs(surface.find_entities_filtered{type = "mining-drill", force = force}) do
    local t = d.mining_target
    if t and t.valid and t.name == resource then return true end
  end
  return false
end

-- Output of the goal's machines, in crafts (summed over each machine's own count, so a rebuilt one
-- doesn't make it go backwards).
local function sample(rec, goal)
  for _, m in ipairs(cells_of(rec, goal.recipe)) do
    local unit = tostring(m.unit_number)
    local now = m.products_finished
    local last = goal.units[unit]
    if last and now >= last then goal.made = goal.made + (now - last) end
    goal.units[unit] = now
  end
  local s = goal.samples
  s[#s + 1] = {tick = game.tick, made = goal.made}
  while #s > 2 and s[2].tick <= game.tick - VERIFY_TICKS do table.remove(s, 1) end
end

-- Per minute over the last minute (nil until there's a minute of samples).
local function measured(goal, per_craft)
  local s = goal.samples
  local first, last = s[1], s[#s]
  if not (first and last) or last.tick - first.tick < VERIFY_TICKS - EVAL_TICKS then return nil end
  return (last.made - first.made) * per_craft * 3600 / (last.tick - first.tick)
end

local function done(task) return task.status == "COMPLETE" end

local function finish(rec, goal, status, text)
  goal.status, goal.reason = status, text
  goal.finished = game.tick
  if M.on_change then M.on_change(rec, goal, text) end
end

-- Reads each task's status from the world.
function M.evaluate(rec, goal)
  if goal.status ~= "ACTIVE" and goal.status ~= "COMPLETE" then return end
  if goal.evaluated and game.tick - goal.evaluated < EVAL_TICKS then return end
  goal.evaluated = game.tick
  local e = rec.entity
  local force, surface = e.force, e.surface
  local by_id = {}
  for _, t in ipairs(goal.tasks) do by_id[t.id] = t end
  for _, t in ipairs(goal.tasks) do
    local before = t.status
    if t.kind == "RESEARCH" then
      local tech = force.technologies[t.target]
      t.status = tech and tech.researched and "COMPLETE" or "AVAILABLE"
    elseif t.kind == "POWER" then
      t.status = #power_sources(surface, force, e.position) > 0 and "COMPLETE" or "AVAILABLE"
    elseif t.kind == "SUPPLY" then
      -- Informational: the base (or hand-gathering) covers supplies, so they don't hold the goal up.
      local ok = t.supplied or t.target == "wood"
      if not ok then
        local res = plan.resource_for(t.target)
        ok = res ~= nil and drills_on(surface, force, res.name)
      end
      t.status = ok and "COMPLETE" or "AVAILABLE"
    elseif t.kind == "BUILD" then
      local waiting = false
      for _, d in ipairs(t.depends or {}) do if by_id[d] and not done(by_id[d]) then waiting = true end end
      local powered = 0
      for _, m in ipairs(cells_of(rec, t.target)) do
        if M.hooked_up(m) then powered = powered + 1 end
      end
      t.built = powered
      -- Monotonic, except that a machine that's gone (or lost power) is built again.
      t.status = powered >= (t.count or 1) and "COMPLETE" or (waiting and "BLOCKED" or "AVAILABLE")
      t.reason = waiting and "MISSING_RESEARCH" or nil
    elseif t.kind == "VERIFY" and goal.products then
      -- The mall: done once every item has come out of its machine.
      local made = 0
      for _, r in ipairs(goal.products) do
        for _, m in ipairs(cells_of(rec, r)) do
          if m.products_finished > 0 then made = made + 1; break end
        end
      end
      t.measured = made
      if t.status ~= "COMPLETE" then
        local built = true
        for _, other in ipairs(goal.tasks) do if other.kind == "BUILD" and not done(other) then built = false end end
        t.status = not built and "BLOCKED" or (made >= #goal.products and "COMPLETE" or "VERIFYING")
      end
    elseif t.kind == "VERIFY" then
      sample(rec, goal)
      local r = prototypes.recipe[goal.recipe]
      local rate = measured(goal, r and plan.makes(r, goal.item) or 1)
      t.measured = rate and round(rate) or nil
      if t.status ~= "COMPLETE" then
        local built = true
        for _, other in ipairs(goal.tasks) do if other.kind == "BUILD" and not done(other) then built = false end end
        if not built then t.status = "BLOCKED"
        elseif rate and rate >= VERIFY_SHARE * goal.rate then t.status = "COMPLETE"
        else t.status = "VERIFYING" end
        -- Why it's slow: the machines are out of power or fuel.
        t.reason = nil
        if built and rate and rate < VERIFY_SHARE * goal.rate then
          for _, m in ipairs(cells_of(rec, goal.recipe)) do
            local st = m.status
            if st == defines.entity_status.low_power or st == defines.entity_status.no_power then t.reason = "INSUFFICIENT_POWER"
            elseif st == defines.entity_status.no_fuel then t.reason = "NO_FUEL" end
          end
        end
      end
    end
    if t.status ~= before then t.changed = game.tick end
  end
  local verify = goal.tasks[#goal.tasks]
  if goal.status == "ACTIVE" and verify.status == "COMPLETE" and goal.products then
    finish(rec, goal, "COMPLETE", "the mall is running: " .. #goal.products .. " kinds of buildings fill its chests, taken from there instead of hand-crafted")
  elseif goal.status == "ACTIVE" and verify.status == "COMPLETE" then
    finish(rec, goal, "COMPLETE", goal.item .. " is automated: " .. verify.measured .. "/min measured over a minute (goal " .. goal.rate .. "/min)")
  end
end

-- A goal stopped by the executor (e.g. nowhere to build), with a reason code.
function M.block(rec, goal, code, text)
  goal.trace[#goal.trace + 1] = "blocked: " .. code .. ": " .. text
  finish(rec, goal, "BLOCKED", code .. ": " .. text)
end

---------------------------------------------------------------------------
-- Which goals run

-- Goals the engineer works on now: the owner's first, then keep-busy's own while it's on. Complete goals
-- are kept running (their machines fed).
function M.runnable(rec, keep_busy)
  local out = {}
  for _, origin in ipairs({"PLAYER", "AUTONOMOUS"}) do
    for _, goal in ipairs(ledger(rec.owner).list) do
      if goal.origin == origin and (goal.status == "ACTIVE" or goal.status == "COMPLETE")
        and (origin == "PLAYER" or keep_busy) and goal.surface == rec.entity.surface.name then
        out[#out + 1] = goal
      end
    end
  end
  return out
end

-- Whether a goal still has work beyond keeping its machines fed.
function M.has_work(rec, keep_busy)
  for _, goal in ipairs(M.runnable(rec, keep_busy)) do
    if goal.status == "ACTIVE" then return true end
  end
  return false
end

function M.any_player_goal(rec)
  for _, goal in ipairs(ledger(rec.owner).list) do
    if goal.origin == "PLAYER" and (goal.status == "ACTIVE" or goal.status == "COMPLETE") then return true end
  end
  return false
end

-- Keep-busy changed: its own goals pause when it's off and carry on when it's on again.
function M.keep_busy_changed(rec, on)
  for _, goal in ipairs(ledger(rec.owner).list) do
    if goal.origin == "AUTONOMOUS" then
      if not on and (goal.status == "ACTIVE" or goal.status == "COMPLETE") then
        goal.paused_from, goal.status = goal.status, "PAUSED"
      elseif on and goal.status == "PAUSED" then
        goal.status, goal.paused_from = goal.paused_from or "ACTIVE", nil
      end
    end
  end
end

-- The owner said stop: their goals pause too (the goal tool resumes them).
function M.pause_all(rec)
  for _, goal in ipairs(ledger(rec.owner).list) do
    if goal.status == "ACTIVE" or goal.status == "COMPLETE" then goal.paused_from, goal.status = goal.status, "PAUSED" end
  end
end

-- A goal stopped by jobs that kept failing (a tree in the way, say) is picked up again where it was after
-- this long, a few times: it keeps its place (and its slot on the bus) instead of being planned anew.
local RETRY_TICKS, RETRIES = 5 * 3600, 3

-- Keep-busy's next goal: the first science pack in LADDER it has no machine making yet. Nil when there's
-- nothing left it can plan (a blocked goal isn't tried again until keep-busy is turned on again, except
-- one blocked by failing jobs, which carries on after a while).
-- With `on_bus` (the main bus is up), a pack counts as made only by a goal's machines (packs made by the
-- build order's red science don't reach the bus's labs), and the mall comes after green science.
-- With `wait_for_bus` (no bus yet, but one is on its way), only one goal gets machines the engineer feeds
-- by hand: the rest wait for the bus (true as the second result when that's why there's none). The third
-- result is a blocked goal just taken up again.
function M.next_autonomous(rec, on_bus, wait_for_bus)
  local book = ledger(rec.owner)
  -- (Even while another is under way: a blocked bus goal may be what the rest wait on.)
  for _, goal in ipairs(book.list) do
    if goal.origin == "AUTONOMOUS" and goal.status == "BLOCKED" and tostring(goal.reason):find("^EXECUTOR_ERROR")
      and (goal.retries or 0) < RETRIES and game.tick - (goal.finished or 0) >= RETRY_TICKS then
      goal.retries = (goal.retries or 0) + 1
      goal.trace[#goal.trace + 1] = "trying again (" .. goal.retries .. " of " .. RETRIES .. ")"
      goal.status, goal.reason, goal.evaluated = "ACTIVE", nil, nil
      return nil, nil, goal
    end
  end
  for _, goal in ipairs(book.list) do
    if goal.origin == "AUTONOMOUS" and (goal.status == "ACTIVE" or goal.status == "PAUSED") then return nil end
  end
  if wait_for_bus then
    for _, goal in ipairs(book.list) do
      if goal.block and not goal.block.bus and goal.status ~= "CANCELLED" then return nil, true end
    end
  end
  for _, pack in ipairs(LADDER) do
    local made
    if pack == "mall" then made = not on_bus -- (only once plates come by belt)
    elseif on_bus then
      made = false
      for _, goal in ipairs(book.list) do
        if goal.item == pack and goal.block and goal.status ~= "CANCELLED" then made = true end
      end
    else made = #cells_of(rec, pack) > 0 end
    if (pack == "mall" or prototypes.item[pack]) and not made then
      local tried = false
      for _, goal in ipairs(book.list) do
        if goal.item == pack and goal.status ~= "CANCELLED" then tried = true end
      end
      if not tried then return pack end
    end
  end
end

-- Forget keep-busy's blocked goals, so turning it on again tries them again.
function M.retry_blocked(rec)
  for _, goal in ipairs(ledger(rec.owner).list) do
    if goal.origin == "AUTONOMOUS" and goal.status == "BLOCKED" then goal.status = "CANCELLED" end
  end
end

---------------------------------------------------------------------------
-- For the AI

local function task_line(t)
  local what
  if t.kind == "RESEARCH" then what = "research " .. t.target
  elseif t.kind == "POWER" then what = "power: an electric network"
  elseif t.kind == "SUPPLY" then what = "supply " .. t.rate .. "/min " .. t.target .. " (" .. tostring(t.text) .. ")"
  elseif t.kind == "BUILD" then
    what = "build " .. (t.count or "?") .. " " .. tostring(t.machine) .. " making " .. t.item .. " (" .. t.rate .. "/min" ..
      (t.executor and ", fed by the engineer" or ", can't build these yet") .. ")" .. (t.built and t.built > 0 and (", " .. t.built .. " built") or "")
  elseif t.target == "mall" then what = "check every mall item comes out" .. (t.measured and (", " .. t.measured .. " so far") or "")
  else what = "check " .. t.rate .. "/min of " .. t.target .. " for a minute" .. (t.measured and (", now " .. t.measured .. "/min") or "") end
  return "[" .. t.status:lower() .. "] " .. what .. (t.reason and (" (" .. t.reason .. ")") or "")
end

function M.describe(goal, full)
  local d = {id = goal.id, item = goal.item, per_minute = goal.rate, status = goal.status, origin = goal.origin:lower(), reason = goal.reason}
  local nxt
  for _, t in ipairs(goal.tasks) do
    if t.status ~= "COMPLETE" and t.kind ~= "SUPPLY" then nxt = nxt or task_line(t) end
  end
  d.next = goal.status == "ACTIVE" and nxt or nil
  if full then
    d.tasks = {}
    for _, t in ipairs(goal.tasks) do d.tasks[#d.tasks + 1] = task_line(t) end
    d.plan = goal.trace
    d.other_recipes = goal.alternatives
  end
  return d
end

-- Compact lines for observe.
function M.summary(owner)
  local out = {}
  for _, goal in ipairs(ledger(owner).list) do
    if goal.status ~= "CANCELLED" then
      local d = M.describe(goal)
      -- Observe is resent with every request: a long reason is cut short (goal status has all of it).
      local reason = goal.reason and goal.status ~= "COMPLETE" and goal.reason or nil
      if reason and #reason > 150 then reason = reason:sub(1, 150) .. "..." end
      out[#out + 1] = goal.id .. " " .. goal.item .. " " .. goal.rate .. "/min: " .. goal.status:lower() ..
        (d.next and (", next " .. d.next) or "") .. (reason and (" (" .. reason .. ")") or "")
    end
  end
  return #out > 0 and out or nil
end

return M
