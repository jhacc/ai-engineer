-- The plan tool: works out from the game's own tech tree and recipes what to research next for a
-- goal, which science packs that takes, and how many machines make them, so the progression comes from
-- the game itself rather than a hand-written plan.
local util = require("scripts.util")
local M = {}

-- The default goals, in order: the next science pack the force can't make yet, then the rocket silo.
local LADDER = {"automation-science-pack", "logistic-science-pack", "chemical-science-pack",
  "production-science-pack", "utility-science-pack", "space-science-pack"}
local FINAL = "rocket-silo"
local DEFAULT_RATE = 10 -- per minute, of each science pack (and the goal item)
local RESEARCH_LIMIT = 25
local MAX_DEPTH = 15

-- 2.0 unlocks early technologies by doing things (crafting, mining, building), not in labs.
function M.trigger_text(trigger)
  local function name(x) return type(x) == "table" and (x.name or x[1]) or x end
  local what = name(trigger.item) or name(trigger.entity)
  local verbs = {["craft-item"] = "craft", ["mine-entity"] = "mine", ["build-entity"] = "build",
    ["craft-fluid"] = "produce", ["send-item-to-orbit"] = "launch", ["capture-spawner"] = "capture"}
  return (verbs[trigger.type] or trigger.type) .. " " .. ((trigger.count or 1) > 1 and (trigger.count .. " ") or "") .. tostring(what or "")
end

local function round(x) return math.floor(x * 10 + 0.5) / 10 end

-- Recipes that are real ways to make things: not hidden, not recycling, not blueprint parameters,
-- and not filling or emptying barrels (water and crude oil come from pumps).
local NOT_MAKING = {["fill-barrel"] = true, ["empty-barrel"] = true}
local function usable(recipe)
  return not recipe.hidden and util.category(recipe) ~= "recycling" and not recipe.name:find("parameter", 1, true) and
    not NOT_MAKING[recipe.subgroup.name]
end

local function makes(recipe, item)
  local total = 0
  for _, p in ipairs(recipe.products) do
    if p.name == item then
      total = total + (p.amount or ((p.amount_min or 0) + (p.amount_max or 0)) / 2) * (p.probability or 1)
    end
  end
  return total
end

local function uses(recipe, item)
  for _, i in ipairs(recipe.ingredients) do if i.name == item then return true end end
  return false
end

-- item or fluid name -> recipe prototypes that make it (without using it, so no catalyst loops).
local function product_index()
  local index = {}
  for name, recipe in pairs(prototypes.recipe) do
    if usable(recipe) then
      for _, p in ipairs(recipe.products) do
        if not uses(recipe, p.name) then
          index[p.name] = index[p.name] or {}
          table.insert(index[p.name], recipe)
        end
      end
    end
  end
  return index
end

-- The recipe to plan with: one the force has, then the one named after the item, then the main product.
local function recipe_for(ctx, item)
  local best, best_score
  for _, recipe in ipairs(ctx.index[item] or {}) do
    local score = (ctx.force.recipes[recipe.name].enabled and 4 or 0) + (recipe.name == item and 2 or 0) +
      (recipe.main_product and recipe.main_product.name == item and 1 or 0) - #recipe.ingredients * 0.01
    if not best_score or score > best_score then best, best_score = recipe, score end
  end
  return best
end

local function have_recipe_for(ctx, item)
  for _, recipe in ipairs(ctx.index[item] or {}) do
    if ctx.force.recipes[recipe.name].enabled then return true end
  end
  return false
end

local function crafting_speed(p)
  local ok, v = pcall(function() return p.get_crafting_speed() end)
  if ok and v then return v end
  return p.crafting_speed or 1
end

-- Pick from machines (entity prototypes): the fastest the force can build, else the slowest it can't yet.
-- `bootstrap(item)`: true for a machine that can't be built before there's one already (a steel furnace
-- needs steel and bricks, which only furnaces make): passed over while another can be built.
local function pick(ctx, machines, speed, bootstrap)
  local now, later
  for _, p in ipairs(machines) do
    local item = p.items_to_place_this and p.items_to_place_this[1]
    if item then
      if have_recipe_for(ctx, item.name) and not (bootstrap and bootstrap(item.name)) then
        if not now or speed(p) > speed(now) then now = p end
      elseif not later or speed(p) < speed(later) then later = p end
    end
  end
  return now or later, now ~= nil
end

local function machine_for(ctx, category)
  if ctx.machines[category] == nil then
    local list = {}
    for _, p in pairs(prototypes.entity) do
      if p.crafting_categories and p.crafting_categories[category] and p.type ~= "character" and not p.hidden then
        list[#list + 1] = p
      end
    end
    -- (The base's iron and copper plates don't count: they come from its own furnaces. Nor does what the
    -- engineer can craft by hand: gears for an assembler.)
    local SUPPLIED = {["iron-plate"] = true, ["copper-plate"] = true}
    local hand = prototypes.entity["character"]
    local by_hand = hand and hand.crafting_categories and hand.crafting_categories[category]
    local function bootstrap(item)
      if by_hand then return false end
      local recipe = recipe_for(ctx, item)
      for _, i in ipairs(recipe and recipe.ingredients or {}) do
        if not SUPPLIED[i.name] then
          local only_here = ctx.index[i.name] ~= nil
          for _, r in ipairs(ctx.index[i.name] or {}) do
            if util.category(r) ~= category then only_here = false end
          end
          if only_here then return true end
        end
      end
      return false
    end
    local machine, built = pick(ctx, list, crafting_speed, bootstrap)
    if not built then machine, built = pick(ctx, list, crafting_speed) end
    ctx.machines[category] = machine and {proto = machine, built = built} or false
  end
  return ctx.machines[category] or nil
end

local function miner_for(ctx, category)
  local list = {}
  for _, p in pairs(prototypes.entity) do
    if p.type == "mining-drill" and p.resource_categories and p.resource_categories[category] and not p.hidden then
      list[#list + 1] = p
    end
  end
  local miner, built = pick(ctx, list, function(p) return p.mining_speed or 0 end)
  return miner, built
end

local function resource_for(item)
  for _, p in pairs(prototypes.entity) do
    if p.type == "resource" and p.mineable_properties and p.mineable_properties.minable then
      for _, product in ipairs(p.mineable_properties.products or {}) do
        if product.name == item then return p end
      end
    end
  end
end

-- Adds what it takes to make `rate` per minute of item to ctx.made (recipes) and ctx.raw.
local function expand(ctx, item, rate, depth, stack)
  local recipe = not stack[item] and depth < MAX_DEPTH and recipe_for(ctx, item)
  if not recipe then
    if not ctx.raw[item] then ctx.raw[item] = 0; ctx.raw_order[#ctx.raw_order + 1] = item end
    ctx.raw[item] = ctx.raw[item] + rate
    return
  end
  local crafts = rate / math.max(makes(recipe, item), 0.001)
  local entry = ctx.made[recipe.name]
  if not entry then
    entry = {item = item, recipe = recipe, rate = 0, crafts = 0}
    ctx.made[recipe.name] = entry
    ctx.made_order[#ctx.made_order + 1] = recipe.name
  end
  entry.rate, entry.crafts = entry.rate + rate, entry.crafts + crafts
  stack[item] = true
  for _, i in ipairs(recipe.ingredients) do expand(ctx, i.name, crafts * i.amount, depth + 1, stack) end
  stack[item] = nil
end

local function build_lines(ctx)
  local lines = {}
  for _, name in ipairs(ctx.made_order) do
    local entry = ctx.made[name]
    local recipe = entry.recipe
    local machine = machine_for(ctx, util.category(recipe))
    local text
    if machine then
      local count = math.max(1, math.ceil(entry.crafts * recipe.energy / (60 * crafting_speed(machine.proto)) - 0.001))
      text = count .. " " .. machine.proto.name .. (machine.built and "" or " (not unlocked yet)")
    else
      text = "a " .. util.category(recipe) .. " machine"
    end
    text = text .. " making " .. entry.item .. " (" .. round(entry.rate) .. "/min" .. (recipe.name ~= entry.item and (", recipe " .. recipe.name) or "") ..
      (ctx.force.recipes[name].enabled and "" or ", recipe not unlocked yet") .. ")"
    lines[#lines + 1] = text
  end
  for _, item in ipairs(ctx.raw_order) do
    local rate = ctx.raw[item]
    local text = round(rate) .. "/min " .. item .. ": "
    local resource = resource_for(item)
    if item == "water" then
      text = text .. "an offshore pump on water"
    elseif item == "wood" then
      text = text .. "chop trees"
    elseif resource then
      local miner, built = miner_for(ctx, resource.resource_category)
      local props = resource.mineable_properties
      if not miner then
        text = text .. "mine " .. resource.name
      elseif resource.infinite_resource then
        text = text .. miner.name .. "s on " .. resource.name .. " (output depends on the field)"
      else
        local per_drill = (miner.mining_speed or 0) / math.max(props.mining_time or 1, 0.001) * 60 * math.max(makes(props, item), 0.001)
        local count = per_drill > 0 and math.max(1, math.ceil(rate / per_drill - 0.001)) or 1
        text = text .. count .. " " .. miner.name .. (built and "" or " (not unlocked yet)") .. " on " .. resource.name
      end
    else
      text = text .. "no recipe or ore makes it"
    end
    lines[#lines + 1] = text
  end
  return lines
end

-- Unresearched technologies up to and including tech, prerequisites first.
local function research_path(tech)
  local order, seen = {}, {}
  local function visit(t)
    if t.researched or seen[t.name] then return end
    seen[t.name] = true
    local names = {}
    for name in pairs(t.prerequisites) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do visit(t.prerequisites[name]) end
    order[#order + 1] = t
  end
  visit(tech)
  return order
end

local function ready(tech)
  for _, pre in pairs(tech.prerequisites) do if not pre.researched then return false end end
  return true
end

-- The unresearched technology that unlocks a recipe for item (with the fewest steps to it).
local function unlocking_tech(ctx, item)
  local best, best_len
  for _, tech in pairs(ctx.force.technologies) do
    if not tech.researched and tech.enabled then
      for _, effect in ipairs(tech.prototype.effects or {}) do
        local recipe = effect.type == "unlock-recipe" and prototypes.recipe[effect.recipe]
        if recipe and usable(recipe) and makes(recipe, item) > 0 and not uses(recipe, item) then
          local len = #research_path(tech)
          if not best_len or len < best_len then best, best_len = tech, len end
          break
        end
      end
    end
  end
  return best
end

local function tech_suggestions(force, goal)
  local found = {}
  local wanted = tostring(goal):lower():gsub("[%s_]", "-")
  for name, tech in pairs(force.technologies) do
    if tech.enabled and not tech.researched and name:find(wanted, 1, true) then found[#found + 1] = name end
  end
  table.sort(found)
  while #found > 8 do table.remove(found) end
  return found
end

-- goal -> technology to reach (or nil when nothing needs researching) and the item to plan making (or nil).
local function resolve(ctx, goal)
  local force = ctx.force
  if goal == nil then
    for _, pack in ipairs(LADDER) do
      if prototypes.item[pack] and ctx.index[pack] and not have_recipe_for(ctx, pack) then return resolve(ctx, pack) end
    end
    local silo = force.technologies[FINAL]
    if silo and not silo.researched then return silo, nil, FINAL end
    util.fail("Every science pack and the rocket silo are unlocked; call plan with a goal (a technology or an item)")
  end
  -- Some names are both a technology and an item (automation-science-pack, rocket-silo): plan both.
  local tech = force.technologies[goal]
  local is_item = (prototypes.item[goal] or prototypes.fluid[goal]) and ctx.index[goal] and true
  if tech and not tech.researched then return tech, is_item and goal or nil, goal end
  if tech and not is_item then util.fail(goal .. " is already researched") end
  if prototypes.item[goal] or prototypes.fluid[goal] then
    if have_recipe_for(ctx, goal) or not ctx.index[goal] then return nil, goal, goal end
    local unlock = unlocking_tech(ctx, goal)
    if not unlock then util.fail("No technology left to research unlocks a recipe for " .. goal) end
    return unlock, goal, goal
  end
  local close = tech_suggestions(force, goal)
  util.fail("No technology or item called " .. tostring(goal) .. "." ..
    (#close > 0 and (" Technologies with that in the name: " .. table.concat(close, ", ") .. ".") or util.did_you_mean(goal)))
end

local function lab_count(entity)
  return entity.surface.count_entities_filtered{type = "lab", force = entity.force}
end

local function research_line(tech)
  local trigger = tech.prototype.research_trigger
  local text
  if trigger then
    text = tech.name .. ": unlocks when you " .. M.trigger_text(trigger)
  else
    local parts = {}
    for _, i in ipairs(tech.research_unit_ingredients) do parts[#parts + 1] = i.name end
    local minutes = tech.research_unit_count * tech.research_unit_energy / 3600
    text = tech.name .. ": " .. tech.research_unit_count .. " x (" .. table.concat(parts, " + ") .. ") in labs, about " ..
      math.max(1, math.ceil(minutes)) .. " lab-minutes"
  end
  return text .. (ready(tech) and " (ready now)" or "")
end

-- For goals.lua, which plans from the same recipes.
M.usable, M.makes, M.uses, M.crafting_speed, M.resource_for = usable, makes, uses, crafting_speed, resource_for
M.machine_for, M.miner_for, M.have_recipe_for = machine_for, miner_for, have_recipe_for
function M.context(force) return {force = force, index = product_index(), machines = {}} end

function M.run(rec, args)
  local e = rec.entity
  local force = e.force
  local ctx = {force = force, index = product_index(), machines = {}, made = {}, made_order = {}, raw = {}, raw_order = {}}
  local tech, item, goal = resolve(ctx, args.goal)
  local rate = args.per_minute or DEFAULT_RATE
  local path = tech and research_path(tech) or {}

  -- Science packs the path needs, in total.
  local packs, pack_order = {}, {}
  for _, t in ipairs(path) do
    if not t.prototype.research_trigger then
      for _, i in ipairs(t.research_unit_ingredients) do
        if not packs[i.name] then packs[i.name] = 0; pack_order[#pack_order + 1] = i.name end
        packs[i.name] = packs[i.name] + i.amount * t.research_unit_count
      end
    end
  end
  local pack_lines = {}
  for _, pack in ipairs(pack_order) do
    local can = have_recipe_for(ctx, pack)
    local unlock = not can and unlocking_tech(ctx, pack)
    pack_lines[#pack_lines + 1] = pack .. ": " .. packs[pack] .. " needed" ..
      (can and "" or (", recipe unlocked by " .. (unlock and unlock.name or "nothing left to research"))) ..
      ", have " .. e.get_item_count(pack)
    expand(ctx, pack, rate, 0, {})
  end
  -- A goal material gets a production line too; a goal building is just crafted when it's unlocked.
  local proto = item and prototypes.item[item]
  if item and not packs[item] and not (proto and proto.place_result) then expand(ctx, item, rate, 0, {}) end

  -- The one next thing to do.
  local current = force.current_research
  local next_text
  local first
  for _, t in ipairs(path) do if ready(t) then first = t; break end end
  if not first then
    next_text = "Nothing to research: build the machines below to make " .. tostring(item or goal)
  elseif first.prototype.research_trigger then
    next_text = "Unlock " .. first.name .. ": " .. M.trigger_text(first.prototype.research_trigger)
  elseif current and current.name == first.name then
    next_text = "The labs are researching " .. first.name .. " (" .. math.floor(force.research_progress * 100) ..
      "%): keep them stocked with science packs, and build the machines below meanwhile"
  else
    local missing = {}
    for _, i in ipairs(first.research_unit_ingredients) do
      if not have_recipe_for(ctx, i.name) then missing[#missing + 1] = i.name end
    end
    if #missing > 0 then
      next_text = "Unlock the recipe for " .. table.concat(missing, ", ") .. " first"
    elseif lab_count(e) == 0 then
      next_text = "Build a lab, power it, put science packs in it, then research " .. first.name
    else
      next_text = "Research " .. first.name .. " (research tool with technology " .. first.name .. "), and keep the labs stocked" ..
        (current and (" (the labs are on " .. current.name .. ", which isn't on the way)") or "")
    end
  end

  local research = {}
  for i, t in ipairs(path) do
    if i > RESEARCH_LIMIT then
      research[#research + 1] = "... and " .. (#path - RESEARCH_LIMIT) .. " more"
      break
    end
    research[#research + 1] = research_line(t)
  end
  return {goal = goal, next = next_text, research = #research > 0 and research or nil,
    science_packs = #pack_lines > 0 and pack_lines or nil, per_minute = rate,
    build = build_lines(ctx), labs = lab_count(e)}
end

return M
