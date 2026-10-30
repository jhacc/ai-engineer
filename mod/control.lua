-- AI Engineer: a second engineer driven by Claude through the helper app.
local util = require("scripts.util")
local engineer = require("scripts.engineer")
local jobs = require("scripts.jobs")
local gui = require("scripts.gui")
local bridge = require("scripts.bridge")
local autopilot = require("scripts.autopilot")
local director = require("scripts.director")

local function init_storage()
  storage.seq = storage.seq or 0
  storage.events = storage.events or {}
  storage.apps = storage.apps or {}            -- app id -> owner player index
  storage.pairing = storage.pairing or {}      -- code -> {app, tick}
  storage.engineers = storage.engineers or {}  -- owner player index -> {entity, owner, name, job, ...}
  storage.path_requests = storage.path_requests or {}
  storage.chat_log = storage.chat_log or {}
  storage.status = storage.status or {}
  storage.keep_busy = storage.keep_busy or {} -- owner index -> true
  storage.options = storage.options or {}     -- owner index -> {cheats, everyone}, from the app's setup
  storage.ai_turn = storage.ai_turn or {}     -- owner index -> tick the AI was last seen in a turn
  storage.cams = storage.cams or {}           -- player index -> {body, ...} while /ai-cam follows the engineer
  storage.timelapses = storage.timelapses or {} -- player index -> {folder, interval, ...} while /ai-timelapse runs
  -- Identifies this save to the app, which keeps one conversation per save.
  storage.session = storage.session or string.format("%x-%x", game.surfaces[1].map_gen_settings.seed, game.tick)
end

script.on_init(init_storage)
script.on_configuration_changed(function()
  init_storage()
  -- Engineers from before they started with the kit and armed; labels redrawn in the current style.
  for owner, rec in pairs(storage.engineers) do engineer.give_kit(rec); engineer.arm(rec); engineer.decorate(owner) end
end)

-- RCON only: the helper app's channel. Players (cmd.player_index set) are refused.
commands.add_command("aie", {"command-help.aie"}, function(cmd)
  if cmd.player_index then return end
  local ok, request = pcall(helpers.json_to_table, cmd.parameter or "")
  local response = bridge.handle(ok and request or nil)
  rcon.print(helpers.table_to_json(response))
end)

commands.add_command("ai", {"command-help.ai"}, function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if not player then return end
  local text = cmd.parameter or ""
  if text:match("^%s*$") then
    if engineer.get(player.index) or bridge.owns_app(player.index) then gui.toggle(player)
    else player.print({"ai-engineer.not-paired"}) end
    return
  end
  local err = bridge.player_says(player, text)
  if err then player.print(err) end
end)

commands.add_command("ai-pair", {"command-help.ai-pair"}, function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if not player then return end
  local err = bridge.pair(player, (cmd.parameter or ""):match("^%s*(%d+)%s*$"))
  if err then player.print(err) end
end)

-- Filming: a camera following the engineer, and timelapse screenshots.
for name, handler in pairs({["ai-cam"] = director.cam_command, ["ai-timelapse"] = director.timelapse_command}) do
  commands.add_command(name, {"command-help." .. name}, function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index)
    if not player then return end
    local err = handler(player, cmd.parameter)
    if err then player.print(err) end
  end)
end

script.on_event(defines.events.on_tick, function(event)
  jobs.tick(event)
  gui.tick()
  director.tick(event)
end)
script.on_event(defines.events.on_pre_player_left_game, function(event)
  director.player_left(game.get_player(event.player_index))
end)
script.on_event(defines.events.on_script_path_request_finished, jobs.path_finished)
-- Keep-busy's build order picks the next job when the engineer is free.
script.on_nth_tick(30, autopilot.tick)

script.on_event(defines.events.on_gui_click, function(event)
  local element = event.element
  if not (element and element.valid) then return end
  local player = game.get_player(event.player_index)
  gui.clicked(player, element)
  if element.name == "aie_close" then
    gui.toggle(player)
  elseif element.name == "aie_send" then
    local err = bridge.player_says(player, gui.take_input(player))
    if err then player.print(err) end
  elseif element.name == "aie_stop" then
    bridge.player_says(player, "stop")
  elseif element.name == "aie_clear" then
    bridge.player_says(player, "clear")
  elseif element.name == "aie_bigger" then
    gui.resize(player, 1)
  elseif element.name == "aie_smaller" then
    gui.resize(player, -1)
  end
end)

script.on_event(defines.events.on_gui_hover, function(event)
  if event.element.valid then gui.hover(game.get_player(event.player_index), event.element, true) end
end)
script.on_event(defines.events.on_gui_leave, function(event)
  if event.element.valid then gui.hover(game.get_player(event.player_index), event.element, false) end
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
  if event.element.valid and event.element.name == "aie_keep_busy" then
    bridge.set_keep_busy(game.get_player(event.player_index), event.element.state)
  end
end)

script.on_event(defines.events.on_gui_confirmed, function(event)
  if event.element.valid and event.element.name == "aie_message" then
    local player = game.get_player(event.player_index)
    local err = bridge.player_says(player, gui.take_input(player))
    if err then player.print(err) end
  end
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  gui.refresh(game.get_player(event.player_index))
end)

-- Buildings biters destroy (keep-busy puts turrets there), and the engineer dying.
local ATTACKED_TYPES = {"character", "mining-drill", "furnace", "assembling-machine", "electric-pole", "boiler", "generator",
  "offshore-pump", "lab", "inserter", "container", "transport-belt", "pipe", "ammo-turret"}
local died_filters = {}
for _, t in ipairs(ATTACKED_TYPES) do died_filters[#died_filters + 1] = {filter = "type", type = t} end

script.on_event(defines.events.on_entity_died, function(event)
  local entity = event.entity
  if event.force and event.force.name == "enemy" then autopilot.attacked(entity) end
  if entity.type ~= "character" then return end
  for owner, rec in pairs(storage.engineers) do
    if rec.entity == entity then
      rec.job, rec.crafting, rec.died_on = nil, false, entity.surface.name
      util.emit(owner, "engineer_died", {position = util.pos(entity.position),
        cause = event.cause and event.cause.valid and event.cause.name or nil,
        note = "Its inventory is in the corpse at that position. It respawns at the starting area."})
    end
  end
end, died_filters)

-- Milestones and setbacks for the engineer to keep its owner's spirits up about: research finished (told on
-- the AI's next turn, not waking it) and the owner dying.
script.on_event(defines.events.on_research_finished, function(event)
  -- by_script too: the engineer's hand-crafting completes trigger research by script (triggers.lua).
  local research = event.research
  for owner, rec in pairs(storage.engineers) do
    if rec.entity and rec.entity.valid and rec.entity.force == research.force then
      util.emit(owner, "research_finished", {name = research.name})
    end
  end
end)

script.on_event(defines.events.on_player_died, function(event)
  if not storage.engineers[event.player_index] then return end
  util.emit(event.player_index, "owner_died", {cause = event.cause and event.cause.valid and event.cause.name or nil})
end)

-- A dead engineer comes back at the starting area once its owner is online.
script.on_nth_tick(120, function()
  for owner, rec in pairs(storage.engineers) do
    if not (rec.entity and rec.entity.valid) then
      local player = game.get_player(owner)
      if player and player.connected and (player.character or player.controller_type == defines.controllers.remote) then
        engineer.respawn(player, rec)
        util.emit(owner, "engineer_respawned", {position = util.pos(storage.engineers[owner].entity.position)})
      end
    end
  end
end)
