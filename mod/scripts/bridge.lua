-- The helper app talks to the mod over RCON with `/aie <json>`; players can't use that command.
-- Each app is paired with exactly one owner. Only that owner's messages reach it, unless the owner's
-- setup lets every player talk to the engineer (local models only); those messages carry the sender's name.
local util = require("scripts.util")
local engineer = require("scripts.engineer")
local tools = require("scripts.tools")
local jobs = require("scripts.jobs")
local gui = require("scripts.gui")
local autopilot = require("scripts.autopilot")
local goals = require("scripts.goals")
local M = {}

-- The AI is (about to be) in a turn: keep-busy's build order holds off meanwhile (see autopilot.lua).
local function ai_turn(owner)
  storage.ai_turn = storage.ai_turn or {}
  storage.ai_turn[owner] = game.tick
end

local PAIRING_TICKS = 60 * 60 * 10
local MAX_MESSAGE = 2000

-- The app's owner index and player. Index 0 is the player-less test owner (see test_spawn).
local function owner_of(app)
  local owner = type(app) == "string" and storage.apps[app]
  if not owner then return nil end
  local player = owner > 0 and game.get_player(owner) or nil
  return owner, player and player.valid and player or nil
end

-- Owner messages for the app, kept in the same sequence as events.
function M.push_message(owner, text)
  util.emit(owner, "message", {text = text})
end

local STOP_FOLLOWING = {"stop follow", "don't follow", "dont follow", "quit follow", "no more follow", "stay here",
  "stay there", "stay put", "wait here", "wait there", "stand still", "stop moving", "stop walking"}
local function stops_following(lower)
  for _, phrase in ipairs(STOP_FOLLOWING) do
    if lower:find(phrase, 1, true) then return true end
  end
  return false
end

local function options(owner)
  return (storage.options or {})[owner] or {}
end

-- The nearest engineer on the player's surface whose owner lets every player talk to it.
local function open_engineer(player)
  local best, best_d
  for owner, rec in pairs(storage.engineers) do
    if owner ~= player.index and options(owner).everyone and rec.entity and rec.entity.valid
      and rec.entity.surface == player.surface then
      local d = util.distance(rec.entity.position, player.position)
      if not best_d or d < best_d then best, best_d = owner, d end
    end
  end
  return best
end

-- Called from /ai and the chat panel; returns an error message for the player, or nil.
function M.player_says(player, text)
  text = (text or ""):match("^%s*(.-)%s*$")
  if text == "" then return nil end
  if #text > MAX_MESSAGE then return "That message is too long (" .. MAX_MESSAGE .. " characters max)." end
  if not engineer.get(player.index) and not M.owns_app(player.index) then
    -- Another player's engineer may take requests from everyone. Its owner sees them in the chat window;
    -- stop, clear and keep-busy stay the owner's.
    local owner = open_engineer(player)
    if not owner then return "You don't have an AI Engineer yet. Start the AI Engineer app and use /ai-pair <code>." end
    local name = storage.engineers[owner].name or "Engineer"
    local owner_player = owner > 0 and game.get_player(owner) or nil
    if owner_player then gui.log(owner_player, player.name, text) end
    player.print({"", "[" .. name .. "] ", "Got it: " .. text})
    util.emit(owner, "message", {text = text, from = player.name})
    return nil
  end
  local lower = text:lower()
  if lower == "autopilot" or lower == "busy" or lower == "keep busy" then
    M.set_keep_busy(player, not M.keep_busy(player.index))
    return nil
  end
  if text:lower() == "stop" then
    local rec = engineer.get(player.index)
    if rec then jobs.cancel(rec); rec.remind = nil; rec.starter = nil; goals.pause_all(rec) end
    -- Stop means stop: the build order and goals too.
    if M.keep_busy(player.index) then M.set_keep_busy(player, false) end
    gui.log(player, "You", "stop")
    util.emit(player.index, "stop", {})
    return nil
  end
  if text:lower() == "clear" then
    M.clear(player)
    return nil
  end
  -- "stop following me", "stay here": small models often just say they stopped, so stop following here.
  local rec = engineer.get(player.index)
  if rec and rec.job and rec.job.kind == "follow" and stops_following(text:lower()) then jobs.cancel(rec) end
  ai_turn(player.index)
  gui.log(player, "You", text)
  M.push_message(player.index, text)
  return nil
end

-- New chat: stops the engineer and has the app start a fresh Claude conversation. Every request
-- resends the whole conversation, so a short one is cheaper. The game itself is untouched.
function M.clear(player)
  local rec = engineer.get(player.index)
  if rec then jobs.cancel(rec); rec.remind = nil; rec.starter = nil end
  gui.clear(player)
  gui.log(player, "AI Engineer", "New chat started. Your engineer has forgotten the earlier conversation.")
  util.emit(player.index, "reset", {})
end

-- Keep-busy mode: between requests the engineer follows the build order in autopilot.lua.
function M.keep_busy(owner)
  return (storage.keep_busy or {})[owner] == true
end

local function set_keep_busy(owner, on)
  storage.keep_busy = storage.keep_busy or {}
  storage.keep_busy[owner] = on or nil
  local rec = engineer.get(owner)
  if rec then autopilot.reset(rec, on) end
end

function M.set_keep_busy(player, on)
  set_keep_busy(player.index, on)
  gui.set_keep_busy(player, on)
  gui.log(player, "AI Engineer", on and "Autopilot is on: between your requests your engineer builds and grows a burner base (iron, a coal loop, stone, copper, then more of each) and keeps it fueled."
    or "Autopilot is off: your engineer stops after each task.")
end

function M.owns_app(owner)
  for _, index in pairs(storage.apps) do if index == owner then return true end end
  return false
end

function M.pair(player, code)
  local pending = storage.pairing[code or ""]
  if not pending or game.tick - pending.tick > PAIRING_TICKS then
    return "That pairing code isn't valid. Start the AI Engineer app to get a new one."
  end
  storage.pairing[code] = nil
  -- One app per owner: drop any older pairing for this player.
  for app, index in pairs(storage.apps) do if index == player.index then storage.apps[app] = nil end end
  storage.apps[pending.app] = player.index
  if not engineer.get(player.index) then engineer.spawn(player) end
  gui.open(player)
  gui.log(player, "AI Engineer", "Paired! Talk to your engineer here or with /ai <message>. Here's what I can do:\n"
    .. "- Tick Autopilot (top of this window) and I'll build up the base on my own between your requests.\n"
    .. "- Tell me what to do, like \"mine 50 iron ore\", \"build a furnace by the iron\" or \"follow me\", and I'll do it.\n"
    .. "- Ask me questions, like \"how do I get started?\" or \"what should I research next?\", and I'll give you tips.\n"
    .. "Say \"stop\" any time to stop me.")
  util.emit(player.index, "paired", {})
  return nil
end

local ops = {}

ops.hello = function(req)
  local owner, player = owner_of(req.app)
  return {mod_version = script.active_mods["ai-engineer"], session = storage.session, tick = game.tick,
    paired = owner ~= nil, owner = player and player.name or nil, owner_online = player and player.connected or nil}
end

ops.pair = function(req)
  if type(req.code) ~= "string" or not req.code:match("^%d%d%d%d%d%d$") then util.fail("Bad pairing code") end
  storage.pairing[req.code] = {app = req.app, tick = game.tick}
  return {waiting = true}
end

ops.poll = function(req)
  local owner, player = owner_of(req.app)
  if not owner then return {paired = false} end
  storage.options = storage.options or {}
  storage.options[owner] = {cheats = req.cheats == true or nil, everyone = req.everyone == true or nil}
  local after = tonumber(req.after) or 0
  local items = {}
  for _, ev in ipairs(storage.events) do
    if ev.owner == owner and ev.id > after then
      items[#items + 1] = {id = ev.id, kind = ev.kind, data = ev.data, tick = ev.tick}
    end
  end
  -- Events start a turn, and a running one keeps saying so: the build order waits for it.
  if req.thinking == true or #items > 0 then ai_turn(owner) end
  local rec = engineer.get(owner)
  return {paired = true, owner = player and player.name or nil, owner_online = player and player.connected or false, seq = storage.seq, tick = game.tick,
    items = #items > 0 and items or nil, alive = rec ~= nil, busy = (rec and rec.job ~= nil) or nil,
    crafting = (rec and rec.crafting) or nil, keep_busy = M.keep_busy(owner) or nil,
    autopilot = autopilot.active(owner, rec) or nil, build_log = autopilot.log(rec, tonumber(req.build_after) or 0)}
end

ops.say = function(req)
  local owner, player = owner_of(req.app)
  if not owner then util.fail("Not paired") end
  if not player then return {} end
  local text = tostring(req.text or "")
  local name = (storage.engineers[player.index] or {}).name or "Engineer"
  gui.log(player, name, text, req.progress)
  -- Replies (not progress notes) also go to the game chat in the owner's chat color: shown only to the
  -- owner, or to everyone when every player may talk to the engineer.
  if not req.progress then
    local c = player.chat_color
    local color = string.format("%.2f,%.2f,%.2f", c.r, c.g, c.b)
    local line = {"", "[color=" .. color .. "]" .. name .. ":[/color] ", text}
    if options(owner).everyone then game.print(line) else player.print(line) end
  end
  return {}
end

-- The app's terminal lines (tool calls, timings, cost, errors), as small grey lines in the chat window.
ops.log = function(req)
  local _, player = owner_of(req.app)
  if player then gui.note(player, tostring(req.text or "")) end
  return {}
end

ops.status = function(req)
  local _, player = owner_of(req.app)
  if player then gui.status(player, tostring(req.text or "")) end
  return {}
end

ops.tool = function(req)
  local owner = owner_of(req.app)
  if not owner then util.fail("Not paired") end
  return {result = tools.run(owner, req.name, req.args)}
end

-- Automated tests run on a headless server that no player has ever joined. There, an app may
-- own a player-less engineer (owner 0). RCON access already allows any console command, so
-- this grants nothing new; on a server with players it is refused.
ops.test_spawn = function(req)
  if #game.players > 0 then util.fail("test_spawn only works on a server no player has joined") end
  local surface = game.surfaces[1]
  local near = req.position or game.forces.player.get_spawn_position(surface)
  storage.apps[req.app] = 0
  engineer.spawn_at(0, surface, game.forces.player, near, {1, 1, 1}, "Test engineer")
  return {}
end

ops.tools = function() return {names = tools.names()} end

-- Test-only stand-in for the owner typing /ai (see test_spawn).
ops.test_message = function(req)
  if #game.players > 0 then util.fail("test_message only works on a server no player has joined") end
  local owner = owner_of(req.app)
  if owner ~= 0 then util.fail("Not a test pairing") end
  ai_turn(0)
  M.push_message(0, tostring(req.text or ""))
  return {}
end

-- Test-only: the goal planner on a made-up recipe graph (goals.fixture_graph), so its choices can be
-- checked without depending on the game's data.
ops.test_plan = function(req)
  if #game.players > 0 then util.fail("test_plan only works on a server no player has joined") end
  local supplied = {}
  for _, item in ipairs(req.supplied or {}) do supplied[item] = true end
  return {plan = goals.resolve(goals.fixture_graph(req.fixture or {}), req.item, req.rate or 60, {recipe = req.recipe, supplied = supplied})}
end

-- Test-only stand-in for the owner's keep-busy checkbox (see test_spawn).
ops.test_keep_busy = function(req)
  if #game.players > 0 then util.fail("test_keep_busy only works on a server no player has joined") end
  if owner_of(req.app) ~= 0 then util.fail("Not a test pairing") end
  set_keep_busy(0, req.on == true)
  return {}
end

function M.handle(req)
  local op = type(req) == "table" and ops[req.op]
  if not op then return {ok = false, error = "Unknown request"} end
  local ok, result = pcall(op, req)
  if not ok then
    local message = type(result) == "table" and result.message or tostring(result)
    return {ok = false, error = message}
  end
  result.ok = true
  return result
end

return M
