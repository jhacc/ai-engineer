-- Factorio only counts "craft an item" research triggers (2.0 trigger technologies) for crafting
-- done by a player. The engineer is a character without one, so its hand-crafting is counted here:
-- finished crafts are read off its crafting queue, and a trigger technology whose prerequisites are
-- done is completed once the engineer has crafted enough of the item.
local M = {}

-- Queued crafts per recipe. Intermediates are their own entries; an entry's count drops as crafts finish.
local function queued(e)
  local counts = {}
  if e.crafting_queue_size > 0 then
    for _, item in ipairs(e.crafting_queue) do counts[item.recipe] = (counts[item.recipe] or 0) + item.count end
  end
  return counts
end

local function prerequisites_done(tech)
  for _, pre in pairs(tech.prerequisites) do if not pre.researched then return false end end
  return true
end

local function credit(rec, item, amount)
  local force = rec.entity.force
  storage.trigger_progress = storage.trigger_progress or {}
  for name, tech in pairs(force.technologies) do
    local trigger = tech.prototype.research_trigger
    if trigger and trigger.type == "craft-item" and tech.enabled and not tech.researched then
      local wanted = type(trigger.item) == "table" and trigger.item.name or trigger.item
      if wanted == item and prerequisites_done(tech) then
        local key = force.name .. "/" .. name
        local progress = (storage.trigger_progress[key] or 0) + amount
        if progress >= (trigger.count or 1) then
          storage.trigger_progress[key] = nil
          tech.researched = true
          force.print({"", "[technology=" .. name .. "] researched: ", rec.name, " crafted ", item, "."})
          rec.unlocked = rec.unlocked or {}
          rec.unlocked[#rec.unlocked + 1] = name
        else
          storage.trigger_progress[key] = progress
        end
      end
    end
  end
end

-- Credits crafts finished since the last call. Call before and after changing the queue by script.
function M.update(rec)
  local now = queued(rec.entity)
  for recipe, count in pairs(rec.queued or {}) do
    local done = count - (now[recipe] or 0)
    local proto = done > 0 and prototypes.recipe[recipe]
    if proto then
      for _, product in ipairs(proto.products) do
        if product.type == "item" then credit(rec, product.name, done * (product.amount or product.amount_max or 1)) end
      end
    end
  end
  rec.queued = next(now) and now or nil
end

-- Forget the snapshot after crafts were cancelled, so they aren't counted as finished.
function M.reset(rec)
  rec.queued = nil
  M.update(rec)
end

return M
