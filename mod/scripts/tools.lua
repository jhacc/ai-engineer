-- Tools the helper app (and so the AI) can call for one owner's engineer. The app validates
-- argument types against the same schemas; handlers still fail cleanly on bad values.
local util = require("scripts.util")
local engineer = require("scripts.engineer")
local jobs = require("scripts.jobs")
local triggers = require("scripts.triggers")
local autopilot = require("scripts.autopilot")
local power = require("scripts.power")
local plan = require("scripts.plan")
local goals = require("scripts.goals")
local pollution = require("scripts.pollution")
local M = {}
local tools = {}

local function number_arg(args, key)
  local value = args[key]
  if type(value) ~= "number" or value ~= value then util.fail(key .. " must be a number") end
  return value
end

---------------------------------------------------------------------------
-- Looking around

local nearest_water, shore_next_to, power_spot = power.nearest_water, power.shore_next_to, power.spot

local function machine_details(entity)
  local d = {name = entity.name, position = util.pos(entity.position), status = util.status_name(entity.status)}
  if entity.type == "assembling-machine" or entity.type == "furnace" then
    local recipe = entity.get_recipe()
    d.recipe = recipe and recipe.name
    -- Small models wait for a furnace to smelt the ore in their own inventory.
    local input = entity.get_inventory(defines.inventory.crafter_input)
    if input and input.is_empty() and not entity.is_crafting() then
      d.input = entity.type == "furnace"
        and "empty: it smelts only what's inserted into it (insert ore; your inventory isn't shared with it)"
        or "empty: insert its ingredients into it (your inventory isn't shared with it)"
    end
  end
  local fuel = entity.get_fuel_inventory()
  if fuel then d.fuel = util.contents(fuel) end
  if entity.type == "mining-drill" then
    local target = util.drill_target(entity)
    d.feeds = target and (target.name .. " at " .. serpent.line(util.pos(target.position))) or "nothing (drops on the ground)"
  end
  if entity.type == "container" or entity.type == "logistic-container" then
    d.contents = util.contents(entity.get_inventory(defines.inventory.chest))
  elseif entity.type == "lab" then
    d.science = util.contents(entity.get_inventory(defines.inventory.lab_input))
  elseif entity.type ~= "mining-drill" then -- a burner drill's "output" is its fuel again
    local output = entity.get_output_inventory()
    if output then d.output = util.contents(output) end
  end
  return d
end

local OUTPUT_TYPES = {"furnace", "assembling-machine"}

-- Finished items waiting in machines' outputs near the engineer, by item: {item = {count, at = {positions}}}.
-- Small models smelt more plates while 100 sit in a furnace, so observe and craft point these out.
local function waiting_output(e, radius)
  local found = {}
  for _, entity in ipairs(e.surface.find_entities_filtered{position = e.position, radius = radius, force = e.force, type = OUTPUT_TYPES}) do
    local output = entity.get_output_inventory()
    for _, stack in ipairs(output and util.contents(output) or {}) do
      local f = found[stack.name] or {count = 0, at = {}}
      f.count = f.count + stack.count
      if #f.at < 5 then f.at[#f.at + 1] = util.pos(entity.position) end
      found[stack.name] = f
    end
  end
  return found
end

-- Enemy-force entities that are a threat. Others on that force aren't: fire (the crash site's flames)
-- and projectiles are enemy-force too.
local ENEMY_KINDS = {["unit"] = "biters", ["spider-unit"] = "biters", ["segmented-unit"] = "biters",
  ["unit-spawner"] = "nests", ["turret"] = "worms"}

-- Guns with their loaded ammo ("pistol with 10 firearm-magazine"), or nil when unarmed.
local function weapons(e)
  local guns, ammo = e.get_inventory(defines.inventory.character_guns), e.get_inventory(defines.inventory.character_ammo)
  if not (guns and ammo) then return nil end
  local out = {}
  for i = 1, #guns do
    if guns[i].valid_for_read then
      local a = ammo[i]
      out[#out + 1] = guns[i].name .. (a.valid_for_read and (" with " .. a.count .. " " .. a.name) or " (no ammo)")
    end
  end
  return #out > 0 and out or nil
end

-- Machines observe lists even when they're beyond its radius (the nearest 15).
local FURTHER_RADIUS = 256
local FURTHER_TYPES = {"mining-drill", "furnace", "assembling-machine", "lab", "boiler", "generator", "offshore-pump", "container",
  "inserter", "transport-belt", "electric-pole"}

tools.observe = function(rec, args)
  local e = rec.entity
  local radius = math.min(math.max(args.radius or 24, 8), 64)
  local result = {
    engineer = {position = util.pos(e.position), health = math.floor(e.health), surface = e.surface.name,
      weapons = weapons(e),
      inventory = util.contents(e.get_main_inventory()), free_slots = e.get_main_inventory().count_empty_stacks(),
      job = jobs.describe(rec),
      crafting_queue = e.crafting_queue_size > 0 and e.crafting_queue_size or nil,
      build_order = autopilot.describe(rec.owner, rec), goals = goals.summary(rec.owner)},
    radius = radius,
  }
  local owner = rec.owner > 0 and game.get_player(rec.owner) or nil
  if owner and owner.connected then
    local at = owner.character and owner.character.position or owner.position
    result.you = {position = util.pos(at), distance = math.floor(util.distance(at, e.position))}
  end
  -- Machines with something to report are listed in detail; belts, poles, pipes and other plain
  -- structures only as counts (observe results are resent with every later request, so size matters).
  local resources, nature, machines, structures, enemies = {}, {}, {}, {}, {}
  for _, entity in ipairs(e.surface.find_entities_filtered{position = e.position, radius = radius}) do
    local t = entity.type
    if t == "resource" then
      local r = resources[entity.name] or {name = entity.name, tiles = 0, amount = 0}
      r.tiles, r.amount = r.tiles + 1, r.amount + entity.amount
      local d = util.distance(e.position, entity.position)
      if not r.nearest_d or d < r.nearest_d then r.nearest, r.nearest_d = util.pos(entity.position), d end
      resources[entity.name] = r
    elseif t == "tree" or t == "simple-entity" then
      local key = t == "tree" and "trees" or entity.name
      local n = nature[key] or {name = key, count = 0}
      n.count = n.count + 1
      local d = util.distance(e.position, entity.position)
      if not n.nearest_d or d < n.nearest_d then n.nearest, n.nearest_d = util.pos(entity.position), d end
      nature[key] = n
    elseif entity.force == e.force and t ~= "character" and t ~= "character-corpse" then
      local d = machine_details(entity)
      if d.recipe or d.fuel or d.output or d.contents or d.science or (d.status and d.status ~= "working") then
        d.distance = util.distance(e.position, entity.position)
        machines[#machines + 1] = d
      else
        local s = structures[entity.name] or {name = entity.name, count = 0}
        s.count = s.count + 1
        local dist = util.distance(e.position, entity.position)
        if not s.nearest_d or dist < s.nearest_d then s.nearest, s.nearest_d = d.position, dist end
        structures[entity.name] = s
      end
    elseif entity.force.name == "enemy" and ENEMY_KINDS[t] then
      local kind = ENEMY_KINDS[t]
      enemies[kind] = (enemies[kind] or 0) + 1
      local d = util.distance(e.position, entity.position)
      if not enemies.distance or d < enemies.distance then enemies.nearest, enemies.distance = util.pos(entity.position), d end
    end
  end
  local function list(map)
    local out = {}
    for _, v in pairs(map) do v.nearest_d = nil; out[#out + 1] = v end
    table.sort(out, function(a, b) return a.name < b.name end)
    return #out > 0 and out or nil
  end
  result.resources, result.nature, result.structures = list(resources), list(nature), list(structures)
  table.sort(machines, function(a, b) return a.distance < b.distance end)
  local buildings = {}
  for i = 1, math.min(#machines, 30) do machines[i].distance = nil; buildings[i] = machines[i] end
  result.buildings = #buildings > 0 and buildings or nil
  if #machines > 30 then result.more_buildings = #machines - 30 end
  local ready = {}
  -- From every machine within reach of a short walk, not just the ones in view: the AI forgets the rest.
  for item, f in pairs(waiting_output(e, FURTHER_RADIUS)) do ready[#ready + 1] = {item = item, count = f.count, take_from = f.at} end
  table.sort(ready, function(a, b) return a.count > b.count end)
  result.ready_to_take = #ready > 0 and ready or nil
  -- Machines out of sight, so the AI remembers what's already built instead of building it again: every
  -- kind, counted, with the nearest one (a list of the nearest few left a far power plant out).
  local kinds = {}
  for _, entity in ipairs(e.surface.find_entities_filtered{position = e.position, radius = FURTHER_RADIUS,
      force = e.force, type = FURTHER_TYPES}) do
    local d = util.distance(e.position, entity.position)
    if d > radius and not entity.name:find("^crash%-site") then
      local k = kinds[entity.name]
      if not k then
        k = {name = entity.name, count = 0}
        kinds[entity.name] = k
      end
      k.count = k.count + 1
      if not k.distance or d < k.distance then
        k.distance, k.nearest, k.status = d, util.pos(entity.position), util.status_name(entity.status)
      end
    end
  end
  local further = {}
  for _, k in pairs(kinds) do
    k.distance = math.floor(k.distance)
    further[#further + 1] = k
  end
  table.sort(further, function(a, b) return a.distance < b.distance end)
  result.buildings_further_away = #further > 0 and further or nil
  -- The nearest enemy's distance from the engineer, so the AI doesn't have to work it out.
  if enemies.distance then
    enemies.distance = math.floor(enemies.distance)
    enemies.threat = util.threat(enemies.distance)
    result.enemies = enemies
  end
  local water, water_d = nearest_water(e.surface, e.position, radius)
  if water then result.water = {nearest = util.pos(water), distance = math.floor(water_d)} end
  -- How close the pollution cloud is to enemy nests (nests that soak it up send attacks).
  result.pollution = pollution.summary(rec, (rec.auto and rec.auto.home) or e.position)
  return result
end

tools.find = function(rec, args)
  local e = rec.entity
  if args.name == "water" then
    local water, d = nearest_water(e.surface, e.position, 512)
    if not water then util.fail("No water found within 512 tiles") end
    local shore = shore_next_to(e.surface, water, e.position)
    local result = power_spot(e.surface, e.force, water, e.position) or {}
    result.name, result.position, result.distance = "water", util.pos(water), math.floor(d)
    result.shore = shore and util.pos(shore)
    return {found = {result}}
  end
  -- Each kind of source is searched separately, so a stone patch isn't hidden behind nearer rocks.
  local kinds = {}
  for _, name in ipairs(jobs.resolve(args.name)) do
    local t = prototypes.entity[name].type
    kinds[t] = kinds[t] or {}
    table.insert(kinds[t], name)
  end
  local found = {}
  for _, names in pairs(kinds) do
    local skip = {}
    for _ = 1, math.min(args.limit or 3, 10) do
      local entity, d = jobs.nearest(e.surface, names, e.position, skip, 512)
      if not entity then break end
      skip[entity.position.x .. "," .. entity.position.y] = true
      found[#found + 1] = {name = entity.name, position = util.pos(entity.position), distance = math.floor(d),
        threat = entity.force.name == "enemy" and util.threat(d) or nil}
    end
  end
  if #found == 0 then util.fail("No " .. args.name .. " found within 512 tiles of explored land; explore further to look again") end
  table.sort(found, function(a, b) return a.distance < b.distance end)
  return {found = found}
end

tools.recipes = function(rec, args)
  local e = rec.entity
  local handcraft = e.prototype.crafting_categories or {}
  local out = {}
  for name, recipe in pairs(e.force.recipes) do
    if not recipe.hidden and #out < 5 then
      for _, product in ipairs(recipe.products) do
        if product.name == args.item then
          local ingredients = {}
          for _, i in ipairs(recipe.ingredients) do ingredients[#ingredients + 1] = {name = i.name, amount = i.amount} end
          out[#out + 1] = {recipe = name, enabled = recipe.enabled, time = recipe.energy, ingredients = ingredients,
            makes = product.amount, handcraftable = handcraft[util.category(recipe)] == true,
            machine_only = handcraft[util.category(recipe)] ~= true and util.category(recipe) or nil,
            can_craft_now = recipe.enabled and handcraft[util.category(recipe)] and e.get_craftable_count(name) or 0}
          break
        end
      end
    end
  end
  if #out == 0 then util.fail("No recipe makes " .. tostring(args.item) .. "." .. util.did_you_mean(args.item)) end
  return {recipes = out}
end

-- What players call kinds of items, for search ("weapon" -> guns, ammo, grenades, armor).
local ITEM_WORDS = {weapon = {"gun", "ammo", "capsule", "armor"}, weapons = {"gun", "ammo", "capsule", "armor"},
  guns = {"gun"}, ammunition = {"ammo"}, bullets = {"ammo"}, grenade = {"grenade", "capsule"}, grenades = {"grenade", "capsule"},
  armour = {"armor"}, vehicle = {"car", "tank", "locomotive", "wagon", "spidertron"}, vehicles = {"car", "tank", "locomotive", "wagon", "spidertron"},
  turret = {"turret"}, turrets = {"turret"}, belts = {"belt"}, pipes = {"pipe"}, poles = {"pole"}, science = {"science-pack"}}

-- Items players can have: not hidden, and not the blueprint parameter placeholders.
local function listed_items()
  local out = {}
  for name, item in pairs(prototypes.item) do
    if not item.hidden and item.subgroup.name ~= "parameters" then out[#out + 1] = item end
  end
  table.sort(out, function(a, b)
    if a.group.order ~= b.group.order then return a.group.order < b.group.order end
    if a.subgroup.order ~= b.subgroup.order then return a.subgroup.order < b.subgroup.order end
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  return out
end

local ITEMS_LIMIT = 150

tools.items = function(rec, args)
  local items = listed_items()
  if args.group then
    local by_subgroup, subgroups, count = {}, {}, 0
    for _, item in ipairs(items) do
      if item.group.name == args.group and count < ITEMS_LIMIT then
        local sub = item.subgroup.name
        if not by_subgroup[sub] then by_subgroup[sub] = {}; subgroups[#subgroups + 1] = sub end
        table.insert(by_subgroup[sub], item.name)
        count = count + 1
      end
    end
    if count == 0 then util.fail("No item group called " .. tostring(args.group) .. "; call items with no arguments for the groups") end
    local out = {}
    for _, sub in ipairs(subgroups) do out[#out + 1] = {subgroup = sub, items = by_subgroup[sub]} end
    return {group = args.group, subgroups = out}
  end
  if args.search then
    local words = {}
    for word in tostring(args.search):lower():gmatch("[%w%-]+") do
      for _, w in ipairs(ITEM_WORDS[word] or {word}) do words[#words + 1] = w end
    end
    local found = {}
    for _, item in ipairs(items) do
      local text = item.name .. " " .. item.type .. " " .. item.subgroup.name .. " " .. item.group.name
      for _, w in ipairs(words) do
        if text:find(w, 1, true) then
          if #found < ITEMS_LIMIT then found[#found + 1] = {name = item.name, type = item.type, group = item.group.name} end
          break
        end
      end
    end
    if #found == 0 then util.fail("No item matches " .. tostring(args.search) .. "." .. util.did_you_mean(args.search)) end
    return {found = found}
  end
  local groups, order = {}, {}
  for _, item in ipairs(items) do
    local name = item.group.name
    local g = groups[name]
    if not g then
      g = {name = name, count = 0, subgroups = {}, seen = {}}
      groups[name] = g
      order[#order + 1] = g
    end
    g.count = g.count + 1
    if not g.seen[item.subgroup.name] then g.seen[item.subgroup.name] = true; table.insert(g.subgroups, item.subgroup.name) end
  end
  for _, g in ipairs(order) do g.seen = nil end
  return {groups = order}
end

tools.inventory = function(rec)
  local e = rec.entity
  local main = e.get_main_inventory()
  return {inventory = util.contents(main), free_slots = main.count_empty_stacks(), total_slots = #main,
    weapons = weapons(e), crafting_queue = e.crafting_queue_size}
end

---------------------------------------------------------------------------
-- Instant actions

-- How to get a missing ingredient, so the AI doesn't guess (small models think furnaces need bricks).
local function how_to_get(e, item)
  local handcraft = e.prototype.crafting_categories or {}
  local machine
  for _, recipe in pairs(e.force.recipes) do
    local product = recipe.prototype.main_product
    if recipe.enabled and not recipe.hidden and product and product.name == item then
      local parts = {}
      for _, i in ipairs(recipe.ingredients) do parts[#parts + 1] = i.amount .. " " .. i.name end
      local from = table.concat(parts, " + ")
      if handcraft[util.category(recipe)] then return "craft it from " .. from end
      machine = machine or ((util.category(recipe) == "smelting" and "smelt " or ("make it in a " .. util.category(recipe) .. " machine from ")) .. from ..
        (util.category(recipe) == "smelting" and " in a furnace" or ""))
    end
  end
  if machine then return machine end
  local ok, _, mined = pcall(jobs.resolve, item)
  if ok and mined then return "mine it" end
  return "no recipe you can use yet"
end

tools.craft = function(rec, args)
  local e = rec.entity
  local recipe = e.force.recipes[args.recipe]
  if not recipe then util.fail("Unknown recipe " .. tostring(args.recipe) .. "." .. util.did_you_mean(args.recipe)) end
  if not recipe.enabled then util.fail(args.recipe .. " isn't researched yet") end
  if not (e.prototype.crafting_categories or {})[util.category(recipe)] then
    util.fail(args.recipe .. " needs a machine (" .. util.category(recipe) .. "), it can't be crafted by hand" ..
      (util.category(recipe) == "smelting" and ". To get some for your owner, call give with the item and count: it smelts them in a furnace first" or ""))
  end
  local wanted = args.count or 1
  local can = e.get_craftable_count(args.recipe)
  if can == 0 then
    local missing = {}
    local waiting = waiting_output(e, FURTHER_RADIUS)
    for _, i in ipairs(recipe.ingredients) do
      local have = e.get_item_count(i.name)
      if have < i.amount then
        local w = waiting[i.name]
        local how = w and (w.count .. " are ready in machines: take them from " .. serpent.line(w.at[1]) ..
          (#w.at > 1 and (" and " .. (#w.at - 1) .. " more") or "") .. " first") or how_to_get(e, i.name)
        missing[#missing + 1] = i.name .. " (have " .. have .. ", need " .. i.amount .. " each; " .. how .. ")"
      end
    end
    util.fail("Can't craft " .. args.recipe .. ": missing " .. (#missing > 0 and table.concat(missing, ", ") or "intermediate items"))
  end
  triggers.update(rec)
  local started = e.begin_crafting{recipe = args.recipe, count = math.min(wanted, can), silent = true}
  triggers.update(rec)
  rec.crafting = true
  return {crafting = started, recipe = args.recipe, asked = wanted,
    note = started < wanted and "Only had ingredients for " .. started or nil}
end

local trigger_text = plan.trigger_text

local function missing_prerequisites(tech)
  local missing = {}
  for name, pre in pairs(tech.prerequisites) do if not pre.researched then missing[#missing + 1] = name end end
  table.sort(missing)
  return missing
end

-- What an unknown technology name probably meant: small models asked for "red-science" and "lab" in circles.
local function not_a_technology(force, name)
  local recipe = force.recipes[name]
  if recipe and recipe.enabled then
    return name .. " isn't a technology: it's already unlocked, so craft it (or build it) instead"
  end
  if recipe then
    for tech_name, tech in pairs(force.technologies) do
      for _, effect in ipairs(tech.prototype.effects or {}) do
        if effect.type == "unlock-recipe" and effect.recipe == name then
          return name .. " isn't a technology: research " .. tech_name .. " to unlock it"
        end
      end
    end
  end
  return "Unknown technology " .. name .. ". Technologies are named for what they unlock; science packs are items " ..
    "(red science is automation-science-pack, crafted by hand) that labs use up. Call research with no technology to list what's available"
end

-- Why research isn't moving, if it isn't: no lab, none powered, or none with science packs.
local function lab_note(rec)
  local e = rec.entity
  local labs = e.surface.find_entities_filtered{type = "lab", force = e.force, position = e.position, radius = 200}
  if #labs == 0 then return "There's no lab: research only runs in a lab with power and science packs in it" end
  local status = defines.entity_status
  local no_power, no_packs = false, false
  for _, lab in ipairs(labs) do
    if lab.status == status.working then return nil end
    no_power = no_power or lab.status == status.no_power
    no_packs = no_packs or lab.status == status.missing_science_packs
  end
  if no_power then return "Your lab has no power: research needs it powered (steam power, poles to the lab) with science packs in it" end
  if no_packs then return "Your lab has no science packs: insert automation-science-pack into it" end
  return nil
end

tools.research = function(rec, args)
  local force = rec.entity.force
  if args.technology then
    local tech = force.technologies[args.technology]
    if not tech then util.fail(not_a_technology(force, args.technology)) end
    if tech.researched then util.fail(args.technology .. " is already researched") end
    local missing = missing_prerequisites(tech)
    if #missing > 0 then util.fail(args.technology .. " needs " .. table.concat(missing, ", ") .. " first") end
    local trigger = tech.prototype.research_trigger
    if trigger then util.fail(args.technology .. " isn't researched in labs; it unlocks when you " .. trigger_text(trigger)) end
    if not force.add_research(tech) then util.fail("Can't start researching " .. args.technology) end
  end
  local current = force.current_research
  local available, by_doing = {}, {}
  for name, tech in pairs(force.technologies) do
    if tech.enabled and not tech.researched and #missing_prerequisites(tech) == 0 then
      local trigger = tech.prototype.research_trigger
      if trigger then by_doing[#by_doing + 1] = name .. ": " .. trigger_text(trigger)
      elseif #available < 15 then available[#available + 1] = name end
    end
  end
  table.sort(available)
  table.sort(by_doing)
  return {current = current and current.name or nil, progress = current and math.floor(force.research_progress * 100) or nil,
    available_in_labs = #available > 0 and available or nil, unlock_by_doing = #by_doing > 0 and by_doing or nil,
    note = current and lab_note(rec) or nil}
end

tools.plan = function(rec, args) return plan.run(rec, args) end

-- Goals the engineer works on by itself (goals.lua plans them, cells.lua builds and runs them).
local GOAL_ACTIONS = {add = true, status = true, pause = true, resume = true, cancel = true}
tools.goal = function(rec, args)
  local action = args.action or (args.item and "add" or "status")
  if not GOAL_ACTIONS[action] then util.fail("action must be add, status, pause, resume or cancel") end
  if action == "add" then
    if type(args.item) ~= "string" then util.fail("Say which item to automate (item)") end
    if args.item ~= "mall" and not (prototypes.item[args.item] or prototypes.fluid[args.item]) then
      util.fail("No item called " .. args.item .. "." .. util.did_you_mean(args.item))
    end
    local rate = args.per_minute and math.max(1, math.floor(tonumber(args.per_minute) or 0)) or nil
    local goal, existing
    if args.item == "mall" then goal, existing = goals.add_mall(rec, "PLAYER")
    else goal, existing = goals.add(rec, args.item, rate, "PLAYER", args.recipe) end
    goals.evaluate(rec, goal)
    local d = goals.describe(goal, true)
    d.already_planned = existing or nil
    d.note = goal.status == "BLOCKED" and "It can't be done yet: tell your owner why, in a sentence."
      or "Started: the engineer works on it by itself between your jobs (also with keep-busy off), and a goal_done event comes once its output is measured. Don't build it yourself."
    return d
  end
  if not args.id then
    if action ~= "status" then util.fail("Say which goal (id), e.g. g1") end
    return {goals = goals.summary(rec.owner) or "none"}
  end
  local goal = goals.get(rec.owner, args.id)
  if not goal then util.fail("No goal " .. tostring(args.id) .. "; status lists them") end
  if action == "pause" and (goal.status == "ACTIVE" or goal.status == "COMPLETE") then
    goal.paused_from, goal.status = goal.status, "PAUSED"
  elseif action == "resume" and goal.status == "PAUSED" then
    goal.status, goal.paused_from = goal.paused_from or "ACTIVE", nil
  elseif action == "cancel" then
    goal.status = "CANCELLED"
  elseif action ~= "status" then
    util.fail("Goal " .. goal.id .. " is " .. goal.status:lower() .. ", so it can't " .. action)
  end
  if action ~= "status" and rec.job and rec.job.auto and rec.job.auto.goal_id == goal.id then jobs.cancel(rec) end
  return goals.describe(goal, action == "status")
end

tools.stop = function(rec, args)
  local stopped = jobs.cancel(rec)
  if rec.starter then
    stopped = "building the drills for the " .. rec.starter.order.kind .. " of " .. tostring(rec.starter.order.args.item)
    rec.starter = nil
  end
  if rec.held_order then
    stopped = rec.held_order.describe
    rec.held_order = nil
  end
  local cancelled = 0
  if args.crafting then
    local e = rec.entity
    triggers.update(rec)
    while e.crafting_queue_size > 0 do
      local before = e.crafting_queue_size
      e.cancel_crafting{index = 1, count = e.crafting_queue[1].count}
      cancelled = cancelled + 1
      if e.crafting_queue_size >= before then break end
    end
    triggers.reset(rec)
    rec.crafting = false
  end
  return {stopped = stopped, crafting_cancelled = cancelled > 0 or nil}
end

-- One pending reminder per engineer; a new one replaces it. jobs.tick emits the `reminder` event.
tools.remind_me = function(rec, args)
  local seconds = math.min(math.max(tonumber(args.seconds) or 60, 10), 600)
  rec.remind = {tick = game.tick + math.floor(seconds * 60), note = type(args.note) == "string" and args.note:sub(1, 200) or nil}
  return {remind_in_seconds = seconds}
end

---------------------------------------------------------------------------
-- Jobs (finish later with a job_done / job_failed event)

tools.walk_to = function(rec, args)
  number_arg(args, "x"); number_arg(args, "y")
  return jobs.start(rec, "walk", args)
end
tools.follow_me = function(rec) return jobs.start(rec, "follow", {}) end
tools.come_to_me = function(rec, args) return jobs.start(rec, "come", {player = args.player}) end
-- Small models hand-mine ore for plates that are already waiting in furnaces: say so when they do.
local function plates_waiting(e, ore)
  local waiting = waiting_output(e, FURTHER_RADIUS)
  for _, recipe in pairs(e.force.recipes) do
    local i, p = recipe.ingredients[1], recipe.prototype.main_product
    if util.category(recipe) == "smelting" and i and i.name == ore and p and waiting[p.name] then
      local w = waiting[p.name]
      return w.count .. " " .. p.name .. " are already smelted, waiting at " .. serpent.line(w.at[1]) ..
        ": if you need plates, stop this and take those instead"
    end
  end
end

-- The owner's rule: more than jobs.HAND_MAX (10) ore, coal or stone isn't mined by hand; drills make it.
-- Rocks and trees asked for by name are fine (no drill mines those).
local function hand_mining_check(name, count)
  if type(name) ~= "string" or (count or 10) <= jobs.HAND_MAX then return end
  local proto = prototypes.entity[name]
  local item = (proto and proto.type == "resource" and name) or (prototypes.item[name] and name)
  if item and jobs.from_patch(item) then
    util.fail("Not more than " .. jobs.HAND_MAX .. " " .. item .. " by hand: call give or insert with the item you " ..
      "want and its count instead. They take it from the base's drills, furnaces and chests, and if there are none, " ..
      "you build drills for it first, by themselves")
  end
end

tools.mine = function(rec, args)
  hand_mining_check(args.name, args.count)
  local result = jobs.start(rec, "mine", args)
  local proto = prototypes.entity[tostring(args.name)]
  local ore = (proto and proto.type == "resource" and args.name) or (prototypes.item[tostring(args.name)] and args.name)
  local note = ore and type(result) == "table" and plates_waiting(rec.entity, ore)
  if note then result.note = result.note and (result.note .. ". " .. note) or note end
  return result
end
tools.place = function(rec, args)
  number_arg(args, "x"); number_arg(args, "y")
  return jobs.start(rec, "place", args)
end
tools.pick_up = function(rec, args) return jobs.start(rec, "pickup", args) end
tools.insert = function(rec, args) return jobs.start(rec, "insert", args) end
tools.take = function(rec, args) return jobs.start(rec, "take", args) end
tools.give = function(rec, args) return jobs.start(rec, "give", args) end

-- Cheats: only when the owner turned them on in the app's setup (sent with every poll).
local function require_cheats(rec)
  if not ((storage.options or {})[rec.owner] or {}).cheats then util.fail("Cheats are off") end
end

tools.cheat_items = function(rec, args)
  require_cheats(rec)
  local item = type(args.item) == "string" and prototypes.item[args.item]
  if not item then util.fail("Unknown item " .. tostring(args.item)) end
  local added = rec.entity.insert({name = item.name, count = math.max(1, math.floor(tonumber(args.count) or 1))})
  if added == 0 then util.fail("Inventory full") end
  return {added = added, item = item.name}
end

-- Runs in its own environment over the game's globals: `engineer` and `owner` are set, print is
-- captured, and globals it assigns stay out of the mod's.
tools.run_lua = function(rec, args)
  require_cheats(rec)
  if type(args.code) ~= "string" then util.fail("code must be text") end
  local printed = {}
  local env = setmetatable({
    engineer = rec.entity,
    owner = rec.owner > 0 and game.get_player(rec.owner) or nil,
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
      if #printed < 20 then printed[#printed + 1] = table.concat(parts, " "):sub(1, 500) end
    end,
  }, {__index = _ENV})
  local chunk, err = load(args.code, "run_lua", "t", env)
  if not chunk then util.fail("Lua syntax error: " .. tostring(err)) end
  local ok, result = pcall(chunk)
  if not ok then util.fail("Lua error: " .. (type(result) == "table" and tostring(result.message) or tostring(result))) end
  local text = serpent.line(result, {comment = false, nocode = true, maxlevel = 4})
  if #text > 2000 then text = text:sub(1, 2000) .. "..." end
  return {returned = text, printed = #printed > 0 and printed or nil}
end

local POSITIONED = {walk_to = true, place = true, pick_up = true, insert = true, take = true}
tools.steps = function(rec, args)
  local steps = args.steps
  if type(steps) ~= "table" or #steps == 0 or #steps > 20 then util.fail("steps must be a list of 1 to 20 steps") end
  for i, step in ipairs(steps) do
    if type(step) ~= "table" or not jobs.STEP_ACTIONS[step.action] then
      util.fail("Step " .. i .. ": action must be one of walk_to, mine, place, pick_up, insert, take, give")
    end
    if POSITIONED[step.action] then number_arg(step, "x"); number_arg(step, "y") end
    if step.action == "mine" then hand_mining_check(step.name, step.count) end
  end
  return jobs.start(rec, "steps", {steps = steps})
end

---------------------------------------------------------------------------

function M.names()
  local list = {}
  for name in pairs(tools) do list[#list + 1] = name end
  table.sort(list)
  return list
end

-- Tools that move the engineer, use its hands or its inventory: refused while it builds the drills for
-- an order (rec.starter). Small models went on placing drills and hand-smelting meanwhile, undoing it.
local BUSY_WITH_ORDER = {craft = true, walk_to = true, follow_me = true, come_to_me = true, mine = true, place = true,
  pick_up = true, insert = true, take = true, give = true, steps = true}

function M.run(owner, name, args)
  local handler = tools[name]
  if not handler then util.fail("Unknown tool " .. tostring(name)) end
  local rec = engineer.require(owner)
  local st = rec.starter
  if st and BUSY_WITH_ORDER[name] then
    util.fail("You're still building the drills for your " .. st.order.kind .. " of " .. tostring(st.order.args.count) ..
      " " .. tostring(st.order.args.item) .. ", and then you do it; you'll get its job_done. Don't help by hand: wait. " ..
      "Only if your owner asks for something else now, call stop first (that drops the order)")
  end
  if rec.held_order and BUSY_WITH_ORDER[name] then
    util.fail("You're refueling the drills and furnaces your order needs (" .. rec.held_order.describe ..
      "), then it carries on by itself; you'll get its job_done. Don't help by hand: wait. " ..
      "Only if your owner asks for something else now, call stop first (that drops the order)")
  end
  return handler(rec, type(args) == "table" and args or {})
end

return M
