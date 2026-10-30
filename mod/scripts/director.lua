-- Filming the engineer: a camera that follows it (/ai-cam) and timelapse screenshots (/ai-timelapse).
-- The camera puts the owner in spectator mode (no body, so nothing to get stuck) and moves the view to the
-- engineer every tick; the owner's character is parked, unkillable, until they come back to it.
-- Timelapse frames are rendered off-screen with game.take_screenshot, so they don't need the camera.
local engineer = require("scripts.engineer")
local M = {}

local EASE = 0.12            -- share of the way to the engineer the camera moves each tick
local SNAP = 64              -- tiles: further than this (a respawn, a teleport) the camera jumps
local FOLLOW_ZOOM = 0.75
local WIDE_ZOOM = 0.25       -- 1920 px at 0.25 is 240 tiles across
local RESOLUTION = {1920, 1080}
local INTERVAL = 3           -- seconds between timelapse frames
local QUALITY = 90           -- JPEG quality: a 1920x1080 frame is a few hundred KB, where a PNG was about 5 MB

local function target(player)
  local rec = engineer.get(player.index)
  return rec and rec.entity
end

-- Saves from before filming existed load without on_configuration_changed when the version is the same.
local function ensure()
  storage.cams = storage.cams or {}
  storage.timelapses = storage.timelapses or {}
end

local function park(cam)
  if cam.body and cam.body.valid then cam.body.destructible = cam.destructible end
end

local function cam_on(player, zoom)
  local body = player.character
  if player.controller_type ~= defines.controllers.character or not body then
    return "Go back to your own character first (close the map or remote view), then /ai-cam."
  end
  local e = target(player)
  if not e then return "Your engineer isn't in the world right now." end
  storage.cams[player.index] = {body = body, destructible = body.destructible, x = e.position.x, y = e.position.y}
  body.destructible = false
  body.walking_state = {walking = false}
  player.set_controller{type = defines.controllers.spectator}
  player.teleport(e.position, e.surface)
  if zoom then player.zoom = zoom end
  player.print("Camera on your engineer. Mouse wheel zooms; /ai-cam again to go back to your character.")
end

local function cam_off(player)
  local cam = storage.cams[player.index]
  if not cam then return end
  storage.cams[player.index] = nil
  park(cam)
  if player.controller_type ~= defines.controllers.spectator then return end
  local body = cam.body
  if not (body and body.valid) then
    -- Someone removed the parked character: a new one at the starting area.
    local surface = game.surfaces.nauvis or player.surface
    local spawn = player.force.get_spawn_position(surface)
    body = surface.create_entity{name = "character", force = player.force,
      position = surface.find_non_colliding_position("character", spawn, 16, 0.5) or spawn}
  end
  player.set_controller{type = defines.controllers.character, character = body}
end

-- /ai-cam toggles the camera; /ai-cam <zoom> turns it on, or changes the zoom while it's on.
function M.cam_command(player, parameter)
  ensure()
  local text = parameter or ""
  local zoom = tonumber(text:match("^%s*([%d%.]+)%s*$") or "")
  if not zoom and not text:match("^%s*$") then return "Usage: /ai-cam [zoom], e.g. /ai-cam 0.6" end
  if zoom then zoom = math.min(math.max(zoom, 0.1), 4) end
  if storage.cams[player.index] then
    if zoom then player.zoom = zoom else cam_off(player) end
    return
  end
  return cam_on(player, zoom)
end

-- /ai-timelapse [follow|wide|both] [seconds] [wide zoom] starts, /ai-timelapse (or stop) while running stops.
-- The follow shot is centered on the engineer; the wide shot is fixed where the owner stood when it started.
local USAGE = "Usage: /ai-timelapse [follow|wide|both] [seconds between frames] [wide shot zoom], e.g. /ai-timelapse both 3 0.25"
local SHOTS = {follow = {follow = true}, wide = {wide = true}, both = {follow = true, wide = true}}
function M.timelapse_command(player, parameter)
  ensure()
  local text = parameter or ""
  local running = storage.timelapses[player.index]
  if running then
    storage.timelapses[player.index] = nil
    local ext = running.ext or "png"
    -- The game can't tell which OS it's on, so both folders are named.
    player.print(string.format("Timelapse stopped: %d follow and %d wide frames in Factorio's script-output/%s folder (Windows: %%APPDATA%%\\Factorio, Mac: ~/Library/Application Support/factorio)",
      running.follows, running.wides, running.folder))
    local name = running.follows > 0 and "follow" or "wide"
    player.print(string.format("To make a video there: ffmpeg -framerate 30 -i %s-%%05d.%s -c:v libx264 -pix_fmt yuv420p %s.mp4%s",
      name, ext, name, running.follows > 0 and running.wides > 0 and string.format(" (and the same for wide-%%05d.%s)", ext) or ""))
    return
  end
  if text:match("^%s*stop%s*$") then return "No timelapse is running." end
  local shots, numbers = nil, {}
  for word in text:gmatch("%S+") do
    if SHOTS[word:lower()] and not shots then shots = SHOTS[word:lower()]
    elseif tonumber(word) and #numbers < 2 then numbers[#numbers + 1] = tonumber(word)
    else return USAGE end
  end
  shots = shots or SHOTS.follow
  local seconds = math.max(numbers[1] or INTERVAL, 0.5)
  local zoom = math.min(math.max(numbers[2] or WIDE_ZOOM, 0.05), 4)
  local folder = string.format("ai-engineer-timelapse/%s-%d", storage.session, game.tick)
  -- From spectator mode the camera's position is the engineer's, so the wide shot centers on the parked body.
  local cam = storage.cams[player.index]
  local anchor = cam and cam.body and cam.body.valid and cam.body or player
  storage.timelapses[player.index] = {folder = folder, interval = math.floor(seconds * 60), next = game.tick,
    zoom = zoom, surface = anchor.surface.index, center = {x = anchor.position.x, y = anchor.position.y},
    follows = 0, wides = 0, follow = shots.follow, wide = shots.wide, ext = "jpg"}
  player.print(string.format("Timelapse: %s, a frame every %g s. /ai-timelapse again to stop.",
    shots.follow and shots.wide and "following your engineer plus a wide shot centered here"
      or shots.wide and "a wide shot centered here" or "following your engineer", seconds))
end

local function shoot(player, tl)
  local shot = {player = player, by_player = player, resolution = RESOLUTION, daytime = 0, show_gui = false, quality = QUALITY}
  -- Timelapses started before the choice existed take both shots, as PNG.
  local both, ext = tl.follow == nil and tl.wide == nil, tl.ext or "png"
  local e = (tl.follow or both) and target(player)
  if e then
    tl.follows = tl.follows + 1
    -- The follow shot shows the screen's GUI too, chat window included, so viewers see what it's doing.
    shot.surface, shot.position, shot.zoom, shot.show_gui = e.surface, e.position, FOLLOW_ZOOM, true
    shot.path = string.format("%s/follow-%05d.%s", tl.folder, tl.follows, ext)
    game.take_screenshot(shot)
  end
  local surface = (tl.wide or both) and game.surfaces[tl.surface]
  if surface then
    shot.show_gui = false
    tl.wides = tl.wides + 1
    shot.surface, shot.position, shot.zoom = surface, tl.center, tl.zoom
    shot.path = string.format("%s/wide-%05d.%s", tl.folder, tl.wides, ext)
    game.take_screenshot(shot)
  end
end

function M.tick(event)
  ensure()
  for index, cam in pairs(storage.cams) do
    local player = game.get_player(index)
    if not (player and player.controller_type == defines.controllers.spectator) then
      park(cam)
      storage.cams[index] = nil
    else
      local e = target(player)
      if e then
        local p = e.position
        local dx, dy = p.x - cam.x, p.y - cam.y
        if e.surface.index ~= player.surface.index or dx * dx + dy * dy > SNAP * SNAP then
          cam.x, cam.y = p.x, p.y
        else
          cam.x, cam.y = cam.x + dx * EASE, cam.y + dy * EASE
        end
        player.teleport({cam.x, cam.y}, e.surface)
      end
    end
  end
  for index, tl in pairs(storage.timelapses) do
    if event.tick >= tl.next then
      tl.next = event.tick + tl.interval
      local player = game.get_player(index)
      if player and player.connected then shoot(player, tl) end
    end
  end
end

-- A player leaving while filming gets their character back, so they rejoin in it.
function M.player_left(player)
  ensure()
  cam_off(player)
end

return M
