-- The engineer is a normal character entity (not a player) owned by one player.
local util = require("scripts.util")
local triggers = require("scripts.triggers")
local gui = require("scripts.gui")
local M = {}

function M.get(owner)
  local rec = storage.engineers[owner]
  if rec and rec.entity and rec.entity.valid then return rec end
  return nil
end

function M.require(owner)
  local rec = M.get(owner)
  if not rec then util.fail("Your engineer isn't in the world right now (it respawns when you're online)") end
  return rec
end

-- Name labels are drawn only for the owner: above its head and on the map.
function M.decorate(owner)
  local rec, player = storage.engineers[owner], owner > 0 and game.get_player(owner) or nil
  if not (rec and rec.entity and rec.entity.valid and player) then return end
  for _, key in ipairs({"label", "marker", "marker_name"}) do
    if rec[key] and rec[key].valid then rec[key].destroy() end
  end
  local e = rec.entity
  rec.label = rendering.draw_text{text = rec.name, surface = e.surface, target = {entity = e, offset = {0, -2.6}},
    color = player.color, players = {player}, alignment = "center", scale = 1.1}
  -- On the map: an icon on the engineer, with the name to its right like a player's. Both keep their
  -- screen size at any zoom, so the leading spaces keep the name clear of the icon.
  local chart = {surface = e.surface, target = e, color = player.color, players = {player}, render_mode = "chart",
    scale_with_zoom = true, scale = 1.1, vertical_alignment = "middle", use_rich_text = true}
  chart.text, chart.alignment = "[img=entity/character]", "center"
  rec.marker = rendering.draw_text(chart)
  chart.text, chart.alignment = "    " .. rec.name, "left"
  rec.marker_name = rendering.draw_text(chart)
end

-- Start armed like a player: a pistol and two magazines (skipped if it already has a gun).
function M.arm(rec)
  local e = rec.entity
  if not (e and e.valid) then return end
  local guns, ammo = e.get_inventory(defines.inventory.character_guns), e.get_inventory(defines.inventory.character_ammo)
  if not (guns and ammo and guns.is_empty()) then return end
  if prototypes.item["pistol"] then guns.insert{name = "pistol", count = 1} end
  if prototypes.item["firearm-magazine"] then ammo.insert{name = "firearm-magazine", count = 2} end
end

-- The engineer's starting items, once per engineer: a burner drill, a furnace and a piece of wood, with no
-- plates (freeplay's 8 iron plates are the player's head start, not the engineer's). Guns are left to arm().
local KIT = {["burner-mining-drill"] = 1, ["stone-furnace"] = 1, ["wood"] = 1}
function M.give_kit(rec)
  local e = rec.entity
  if rec.kit_given or not (e and e.valid) then return end
  rec.kit_given = true
  for name, count in pairs(KIT) do
    if prototypes.item[name] then e.insert{name = name, count = count} end
  end
end

-- A character without a player never shoots by itself: aim at the nearest biter within gun range.
-- Nests and worms are left alone (shooting them with a pistol only starts a fight it can't win).
function M.defend(rec)
  local e = rec.entity
  local index = e.selected_gun_index
  local gun = index and e.get_inventory(defines.inventory.character_guns)[index]
  local ammo = index and e.get_inventory(defines.inventory.character_ammo)[index]
  local target
  if gun and gun.valid_for_read and ammo and ammo.valid_for_read then
    local range = gun.prototype.attack_parameters.range
    local best_d
    for _, enemy in ipairs(e.surface.find_entities_filtered{position = e.position, radius = range, force = "enemy", type = "unit"}) do
      local d = util.distance(e.position, enemy.position)
      if not best_d or d < best_d then target, best_d = enemy, d end
    end
  end
  if target then
    e.shooting_state = {state = defines.shooting.shooting_enemies, position = target.position}
    rec.shooting = true
  elseif rec.shooting then
    e.shooting_state = {state = defines.shooting.not_shooting}
    rec.shooting = nil
  end
end

-- Looking after itself like a player early on, keep-busy on or off (jobs.tick calls this every 15 ticks):
-- light armor crafted as soon as it has the plates while idle, and worn; a couple of fish caught whenever
-- it passes within reach of them; and a fish eaten when its health is low.
local FISH_KEEP = 2
local FISH_HEAL = 80 -- what raw-fish's capsule heals
local FISH_COOLDOWN = 30 -- ticks between fish, as for a player
function M.care(rec)
  local e = rec.entity
  local armor = e.get_inventory(defines.inventory.character_armor)
  if armor and armor.is_empty() and prototypes.item["light-armor"] then
    if e.get_item_count("light-armor") > 0 then
      local stack = e.get_main_inventory().find_item_stack("light-armor")
      if stack and armor[1].transfer_stack(stack) then
        local player = rec.owner > 0 and game.get_player(rec.owner)
        if player and player.connected then gui.note(player, "Put on light armor.") end
      end
    elseif not rec.job and not rec.crafting and e.crafting_queue_size == 0 then
      local recipe = e.force.recipes["light-armor"]
      if recipe and recipe.enabled and e.get_craftable_count("light-armor") > 0 then
        -- Queued quietly (not rec.crafting): its end doesn't wake the AI.
        triggers.update(rec)
        e.begin_crafting{recipe = "light-armor", count = 1, silent = true}
        triggers.update(rec)
      end
    end
  end
  local fish = e.get_item_count("raw-fish")
  if fish > 0 and e.health < e.max_health / 2 and game.tick >= (rec.ate_at or 0) + FISH_COOLDOWN then
    e.remove_item{name = "raw-fish", count = 1}
    e.health = e.health + FISH_HEAL
    rec.ate_at = game.tick
  end
  if fish < FISH_KEEP then
    local near = e.surface.find_entities_filtered{type = "fish", position = e.position, radius = e.reach_distance, limit = 1}[1]
    if near then e.mine_entity(near) end
  end
end

-- Create the engineer for owner index `owner` near `near`.
function M.spawn_at(owner, surface, force, near, color, name)
  local position = surface.find_non_colliding_position("character", {x = near.x + 2, y = near.y}, 16, 0.5) or near
  local entity = surface.create_entity{name = "character", position = position, force = force}
  if not entity then util.fail("Could not create the engineer near " .. serpent.line(util.pos(near))) end
  entity.color = color
  local rec = storage.engineers[owner] or {name = name}
  rec.entity, rec.owner, rec.job, rec.crafting, rec.queued = entity, owner, nil, false, nil
  storage.engineers[owner] = rec
  M.give_kit(rec)
  M.arm(rec)
  M.decorate(owner)
  return rec
end

function M.spawn(player)
  local character = player.character
  local surface = (character and character.surface) or player.surface
  local near = (character and character.position) or player.position
  return M.spawn_at(player.index, surface, player.force, near, player.color, player.name .. "'s engineer")
end

-- After dying, the engineer comes back at the starting area (the force's spawn point) of the surface it
-- died on, like a player, never next to the owner (who may be somewhere dangerous).
function M.respawn(player, rec)
  local surface = rec.died_on and game.surfaces[rec.died_on] or game.surfaces.nauvis or player.surface
  return M.spawn_at(player.index, surface, player.force, player.force.get_spawn_position(surface), player.color,
    player.name .. "'s engineer")
end

function M.halt(rec)
  local e = rec.entity
  if not (e and e.valid) then return end
  e.walking_state = {walking = false}
  e.mining_state = {mining = false}
end

return M
