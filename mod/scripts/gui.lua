-- The owner's chat panel: a small movable window with the conversation and an input.
-- Only the owner ever gets one; nothing here is visible to other players.
local M = {}
local PANEL = "aie_panel"
local LAYOUT = 9-- bump when the element tree changes; panels from older versions are rebuilt
local LOG_LIMIT = 100
local NOTE_MAX = 300 -- characters of an app log line (tool calls carry their whole JSON input)
local ROW_HEIGHT = 28
local BUTTON_WIDTH = 72
-- Hovering the log holds its scrolling only this long: a mouse parked over the window while the player
-- types or plays never sends a leave event, and the log stopped following new lines.
local HOVER_HOLD = 600
local ALERT_TICKS = 1800 -- an attack on the base keeps the light red this long
-- The status light: entity status diodes, with what each means as its tooltip.
local LIGHTS = {
  alert = {"utility/status_not_working", "Under attack"},
  thinking = {"utility/status_yellow", "Thinking"},
  working = {"utility/status_working", "Working"},
  idle = {"utility/status_blue", "Idle"},
}
-- Factorio windows can't be resized by dragging, so the title bar has bigger/smaller buttons.
local SIZES = {{width = 400, log = 84}, {width = 520, log = 200}, {width = 680, log = 360}, {width = 860, log = 520}}

local function log_of(player)
  storage.chat_log[player.index] = storage.chat_log[player.index] or {}
  return storage.chat_log[player.index]
end

local function size_of(player)
  storage.chat_size = storage.chat_size or {}
  return SIZES[storage.chat_size[player.index] or 1] or SIZES[1]
end

-- New lines only get their height on the next layout, so scrolling to them waits a tick (see M.tick),
-- and scrolls again the tick after in case wrapped lines took another layout.
local function scroll_soon(player)
  storage.chat_scroll = storage.chat_scroll or {}
  storage.chat_scroll[player.index] = 2
end

-- The cost part of the app's status ("Thinking... · $0.12", "$0.12 spent"), or "".
local function cost_of(text)
  return (text or ""):match("%$[%d%.]+") or ""
end

local function field_of(frame)
  return frame.content.input.row.aie_message
end

local build

-- The open panel, or nil. A panel saved open by an older mod version is rebuilt in place.
local function panel(player)
  local frame = player.gui.screen[PANEL]
  if frame and frame.tags.layout ~= LAYOUT then
    local location = frame.location
    frame.destroy()
    return build(player, location)
  end
  return frame
end

local function add_line(list, entry, width)
  -- Ignored by the mouse, so hovering the text counts as hovering the log (which holds the scrolling).
  -- Log lines (the app's terminal, the build order's notes) are small grey text without a name.
  local caption = entry.log and entry.text
    or {"", "[font=default-semibold][color=" .. entry.color .. "]" .. entry.who .. ":[/color][/font] ", entry.text}
  local line = list.add{type = "label", caption = caption, ignored_by_interaction = true}
  line.style.single_line = false
  line.style.maximal_width = width - 60
  -- Tight lines: a little more room above a chat message than between log lines.
  line.style.top_margin = entry.log and 0 or 2
  line.style.bottom_margin = 0
  if entry.log then
    line.style.font = "default-small"
    line.style.font_color = {0.55, 0.55, 0.55}
  elseif entry.progress then
    line.style.font_color = {0.7, 0.7, 0.7}
  end
end

local function size_button(button)
  button.style.minimal_width = 0
  button.style.width = BUTTON_WIDTH
  button.style.height = ROW_HEIGHT
  button.style.margin = 0
end

build = function(player, location)
  local size = size_of(player)
  local WIDTH = size.width
  -- A destroyed log never sends its leave event: start out not hovered.
  if storage.chat_hover then storage.chat_hover[player.index] = nil end
  local frame = player.gui.screen.add{type = "frame", name = PANEL, direction = "vertical", tags = {layout = LAYOUT}}
  frame.style.width = WIDTH

  -- Everything in the title bar is centred on one line: light, title, grip, the autopilot box and buttons.
  local titlebar = frame.add{type = "flow", name = "titlebar", direction = "horizontal", style = "frame_header_flow"}
  titlebar.drag_target = frame
  titlebar.style.vertical_align = "center"
  local light = LIGHTS[(storage.chat_light or {})[player.index] or "idle"]
  -- (A sprite can't be a drag target.)
  local lamp = titlebar.add{type = "sprite", name = "light", sprite = light[1], tooltip = light[2], style = "status_image"}
  lamp.style.right_margin = 4
  local title = titlebar.add{type = "label", caption = "AI Engineer", style = "frame_title"}
  title.drag_target = frame
  title.style.margin = 0
  local grip = titlebar.add{type = "empty-widget", style = "draggable_space_header", tooltip = "Drag to move"}
  grip.drag_target = frame
  grip.style.height = 24
  grip.style.horizontally_stretchable = true
  -- The grip gives way first, so the smallest window still fits the close button.
  grip.style.minimal_width = 8
  -- Autopilot in a box of its own, set off from the grip and the buttons.
  local autopilot = titlebar.add{type = "frame", name = "autopilot", style = "inside_shallow_frame"}
  autopilot.style.padding = {0, 4}
  autopilot.style.height = 24
  autopilot.style.left_margin = 2
  autopilot.style.right_margin = 2
  autopilot.add{type = "checkbox", name = "aie_keep_busy", caption = "Autopilot",
    state = (storage.keep_busy or {})[player.index] == true,
    tooltip = "Between your requests, the engineer builds and grows a burner base by itself (iron, a coal loop, stone, copper, then more of each), keeps it fueled and crafts basic parts into a chest. Your requests always come first."}
  local cost = titlebar.add{type = "label", name = "cost", caption = cost_of(storage.status[player.index]),
    tooltip = "Estimated API cost for this save"}
  cost.drag_target = frame
  cost.style.font = "default-small"
  cost.style.font_color = {0.75, 0.75, 0.75}
  -- Free local models have no cost: hidden, it takes no room.
  cost.visible = cost.caption ~= ""
  titlebar.add{type = "sprite-button", name = "aie_smaller", sprite = "utility/collapse", style = "frame_action_button",
    tooltip = "Make the window smaller"}
  titlebar.add{type = "sprite-button", name = "aie_bigger", sprite = "utility/expand", style = "frame_action_button",
    tooltip = "Make the window bigger"}
  titlebar.add{type = "sprite-button", name = "aie_clear", sprite = "utility/trash", style = "frame_action_button",
    tooltip = "New chat: stop, and start a fresh conversation (also /ai clear). The engineer forgets this chat, which makes later requests cheaper. Nothing in the game changes."}
  titlebar.add{type = "sprite-button", name = "aie_close", sprite = "utility/close", style = "frame_action_button",
    tooltip = "Close (reopen with /ai)"}

  -- The log and, under it, a footer bar with the input, inside one inset panel like the game's own windows.
  local content = frame.add{type = "frame", name = "content", direction = "vertical", style = "inside_shallow_frame"}
  local log = content.add{type = "scroll-pane", name = "log", style = "scroll_pane_in_shallow_frame",
    vertical_scroll_policy = "auto-and-reserve-space", horizontal_scroll_policy = "never"}
  log.style.height = size.log
  log.style.horizontally_stretchable = true
  log.style.padding = {4, 8}
  -- The pane's own spacing left a big gap between lines. (pcall: in case a game version doesn't allow it here.)
  pcall(function() log.style.vertical_spacing = 0 end)
  -- While the mouse is over the log, new lines don't scroll it for a while: the player may have scrolled up to read.
  log.raise_hover_events = true
  for _, entry in ipairs(log_of(player)) do add_line(log, entry, WIDTH) end
  scroll_soon(player)

  local footer = content.add{type = "frame", name = "input", direction = "horizontal", style = "subfooter_frame"}
  footer.style.horizontally_stretchable = true
  local row = footer.add{type = "flow", name = "row", direction = "horizontal"}
  row.style.horizontal_spacing = 8
  row.style.vertical_align = "center"
  row.style.horizontally_stretchable = true
  local field = row.add{type = "textfield", name = "aie_message", tooltip = "Enter to send. Type 'stop' to stop."}
  field.style.horizontally_stretchable = true
  field.style.minimal_width = 0
  field.style.maximal_width = 10000
  field.style.height = ROW_HEIGHT
  field.style.margin = 0
  size_button(row.add{type = "button", name = "aie_send", caption = "Send", style = "green_button",
    tooltip = "Send (or press Enter)"})
  size_button(row.add{type = "button", name = "aie_stop", caption = "Stop", style = "red_button",
    tooltip = "Stop what the engineer is doing"})

  local res, scale = player.display_resolution, player.display_scale
  frame.location = location or {x = math.floor(res.width - (WIDTH + 24) * scale), y = math.floor(res.height * 0.55)}
  field.focus()
  return frame
end

function M.open(player)
  local frame = panel(player)
  if frame then frame.bring_to_front(); return frame end
  return build(player)
end

-- Rebuilds a panel saved open by an older mod version (call when a player joins).
function M.refresh(player)
  panel(player)
end

function M.toggle(player)
  local frame = panel(player)
  if frame then frame.destroy() else M.open(player) end
end

local function push(player, entry)
  local frame = panel(player) -- before the entry is stored, so a rebuilt panel doesn't show it twice
  local list = log_of(player)
  list[#list + 1] = entry
  while #list > LOG_LIMIT do table.remove(list, 1) end
  if frame then
    local log = frame.content.log
    add_line(log, entry, size_of(player).width)
    while #log.children > LOG_LIMIT do log.children[1].destroy() end
    scroll_soon(player)
  end
end

local COLORS = {You = "0.6,1,0.6"}
function M.log(player, who, text, progress)
  push(player, {who = who, text = text, progress = progress or nil, color = COLORS[who] or "0.6,0.85,1"})
end

-- A log line: what the app prints in its terminal, or a build order note, so viewers of a recording
-- can follow what's going on.
function M.note(player, text)
  if #text > NOTE_MAX then text = text:sub(1, NOTE_MAX - 3) .. "..." end
  push(player, {text = text, log = true})
end

-- Bigger (+1) or smaller (-1): rebuilds the window in place, keeping any text being typed.
function M.resize(player, step)
  storage.chat_size = storage.chat_size or {}
  local before = size_of(player)
  local index = math.max(1, math.min(#SIZES, (storage.chat_size[player.index] or 1) + step))
  if index == (storage.chat_size[player.index] or 1) then return end
  storage.chat_size[player.index] = index
  local frame = panel(player)
  if not frame then return end
  -- Grow toward the top left, keeping the bottom right corner where it was (the window starts at the right edge).
  local after, scale = SIZES[index], player.display_scale
  local location = {x = math.max(0, math.floor(frame.location.x - (after.width - before.width) * scale)),
    y = math.max(0, math.floor(frame.location.y - (after.log - before.log) * scale))}
  local typed = field_of(frame).text
  frame.destroy()
  field_of(build(player, location)).text = typed
end

-- Hovering the log holds its scrolling (from the tick the mouse came in, for HOVER_HOLD).
function M.hover(player, element, over)
  if element.name ~= "log" or element.get_mod() ~= "ai-engineer" then return end
  storage.chat_hover = storage.chat_hover or {}
  storage.chat_hover[player.index] = over and game.tick or nil
end

-- A click on the window's other elements (the input, buttons) means the player is done reading.
function M.clicked(player, element)
  if element.name == "log" or element.get_mod() ~= "ai-engineer" then return end
  if storage.chat_hover then storage.chat_hover[player.index] = nil end
  scroll_soon(player)
end

-- red: fighting, dead or the base attacked; yellow: the app's turn is running; green: a job or crafting;
-- blue: idle.
local function light_of(index)
  local rec = storage.engineers[index]
  local status = storage.status[index] or ""
  if rec then
    if rec.shooting or not (rec.entity and rec.entity.valid) then return "alert" end
    for _, a in ipairs(rec.auto and rec.auto.attacks or {}) do
      if game.tick - a.tick < ALERT_TICKS then return "alert" end
    end
  end
  if status:find("^Thinking") then return "thinking" end
  if status:find("^Working") or (rec and (rec.job or rec.crafting)) then return "working" end
  return "idle"
end

-- Scrolls requested by scroll_soon, a tick later once the new lines have their height. A hovered log keeps
-- its request until the mouse leaves or the hold runs out. Every 15 ticks, the status lights.
function M.tick()
  if game.tick % 15 == 0 then
    storage.chat_light = storage.chat_light or {}
    for _, player in pairs(game.connected_players) do
      local frame = player.gui.screen[PANEL]
      if frame and frame.valid and frame.tags.layout == LAYOUT then
        local light = light_of(player.index)
        if storage.chat_light[player.index] ~= light then
          storage.chat_light[player.index] = light
          frame.titlebar.light.sprite, frame.titlebar.light.tooltip = LIGHTS[light][1], LIGHTS[light][2]
        end
      end
    end
  end
  if not (storage.chat_scroll and next(storage.chat_scroll)) then return end
  for index, left in pairs(storage.chat_scroll) do
    local player = game.get_player(index)
    local frame = player and player.gui.screen[PANEL]
    local since = (storage.chat_hover or {})[index]
    if not (frame and frame.valid) then
      storage.chat_scroll[index] = nil
    elseif not (type(since) == "number" and game.tick - since < HOVER_HOLD) then -- older saves stored true
      if frame.tags.layout == LAYOUT then frame.content.log.scroll_to_bottom() end
      storage.chat_scroll[index] = left ~= true and left > 1 and left - 1 or nil
    end
  end
end

-- Empties the chat window (the owner started a new conversation).
function M.clear(player)
  storage.chat_log[player.index] = {}
  local frame = panel(player)
  if frame then frame.content.log.clear() end
end

function M.set_keep_busy(player, on)
  local frame = panel(player)
  if frame then frame.titlebar.autopilot.aie_keep_busy.state = on end
end

function M.status(player, text)
  storage.status[player.index] = text
  local frame = panel(player)
  if frame then
    local cost = frame.titlebar.cost
    cost.caption = cost_of(text)
    cost.visible = cost.caption ~= ""
  end
end

-- Returns the text to send, or nil.
-- Reads the field before any rebuild (older panels kept it in `input` straight under the frame),
-- so text typed into an older panel isn't lost.
function M.take_input(player)
  local old = player.gui.screen[PANEL]
  local field = old and (old.input and old.input.aie_message
    or old.content and old.content.input and old.content.input.row and old.content.input.row.aie_message)
  if not field then return nil end
  local text = field.text
  field.text = ""
  local frame = panel(player)
  if frame then field_of(frame).focus() end
  if storage.chat_hover then storage.chat_hover[player.index] = nil end
  scroll_soon(player)
  return text
end

return M
