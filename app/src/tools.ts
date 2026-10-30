import type Anthropic from "@anthropic-ai/sdk";

type Schema = {
  type: "object";
  properties: Record<string, Record<string, unknown>>;
  required?: string[];
  additionalProperties: false;
};
type Tool = { name: string; description: string; input_schema: Schema };

const object = (properties: Schema["properties"] = {}, required: string[] = []): Schema => ({
  type: "object",
  properties,
  ...(required.length ? { required } : {}),
  additionalProperties: false,
});
const coordinate = { type: "number", minimum: -1000000, maximum: 1000000 };
const itemName = { type: "string", minLength: 1, maxLength: 100 };
const JOB = " Runs over time: you'll get a job_done or job_failed event. Starting a job replaces the current one.";
/** Jobs a `steps` job can chain (follow_me never finishes, so it can't be a step). */
const STEP_ACTIONS = ["walk_to", "mine", "place", "pick_up", "insert", "take", "give"];

/** Every tool the mod implements (mod/scripts/tools.lua); the game test checks both lists match. */
export const TOOLS: Tool[] = [
  {
    name: "observe",
    description:
      "Look around the engineer: its position, health, inventory (with free slots) and current job, your position, nearby resources (with tile counts and nearest position), trees and rocks, your machines (status, recipe, fuel, contents; nearest 30), finished items waiting in machines (ready_to_take, with where to take them from), machines further away, other structures such as belts and poles (counts with the nearest one), enemies (nests, worms and biters, with the nearest one's distance and threat) and the nearest water.",
    input_schema: object({ radius: { type: "integer", minimum: 8, maximum: 64, description: "Default 24" } }),
  },
  {
    name: "find",
    description:
      "Find the nearest sources of something within 512 tiles: an item to mine (iron-ore, copper-ore, coal, stone, wood) or an entity name. An item with several kinds of source lists the nearest of each (stone: patches and rocks). With name water: the nearest water, a shore tile to stand on, and positions and directions for an offshore_pump, boiler and steam_engine that connect when placed exactly there.",
    input_schema: object({ name: itemName, limit: { type: "integer", minimum: 1, maximum: 10 } }, ["name"]),
  },
  {
    name: "recipes",
    description:
      "Recipes that make an item: ingredients, whether it's researched, whether it can be crafted by hand, and how many can be crafted now.",
    input_schema: object({ item: itemName }, ["item"]),
  },
  {
    name: "items",
    description:
      "Look up the game's items (including every mod's), to get exact names. No arguments: the item groups (combat, logistics, production, intermediate-products...) with their subgroups and item counts. group: every item in that group, by subgroup. search: items whose name, type, subgroup or group contains one of the words (\"weapon\" finds guns, ammo, grenades and armor).",
    input_schema: object({ group: itemName, search: itemName }),
  },
  { name: "inventory", description: "The engineer's inventory, free and total slots, and crafting queue length.", input_schema: object() },
  {
    name: "craft",
    description:
      "Queue hand-crafting from the engineer's inventory (crafts intermediates automatically, like a player). Returns at once; a crafting_done event comes when the queue empties. It can walk and mine while crafting.",
    input_schema: object({ recipe: itemName, count: { type: "integer", minimum: 1, maximum: 200 } }, ["recipe"]),
  },
  {
    name: "research",
    description:
      "Show current research, technologies available in labs and those unlocked by doing something (Factorio 2.0 trigger techs). With technology, start researching it.",
    input_schema: object({ technology: itemName }),
  },
  {
    name: "plan",
    description:
      "Work out from the game's tech tree and recipes how to reach a goal: the next thing to do, the technologies to research in order (prerequisites first), the science packs they take, and the machines and drills to build for them. goal: a technology (\"oil-processing\") or an item (\"steel-plate\"); without it, the next science pack you can't make yet, then the rocket silo. per_minute: how many of each science pack (and the goal item) to plan machines for, default 10. Use it when autopilot has nothing left it can do.",
    input_schema: object({ goal: itemName, per_minute: { type: "integer", minimum: 1, maximum: 1000 } }),
  },
  {
    name: "goal",
    description:
      "Have the engineer automate an item by itself. The game plans it from its own recipes and tech tree, does the research, builds assemblers and furnaces for each step beside the power network, keeps them fed between your jobs (also with autopilot off) and measures the real output. You get a goal_done event once it's measured, or goal_blocked with the reason. Use it when your owner asks to automate something or to keep making it; don't build those machines yourself. action add (the default with item): item, per_minute (default 15), recipe (only one listed in other_recipes). item mall: assemblers making belts, inserters, poles, drills, furnaces and assemblers into chests, which the engineer then builds from instead of hand-crafting. status: all goals, or one by id with its tasks. pause, resume, cancel: a goal by id.",
    input_schema: object({
      action: { type: "string", enum: ["add", "status", "pause", "resume", "cancel"] },
      item: itemName,
      per_minute: { type: "integer", minimum: 1, maximum: 600 },
      recipe: itemName,
      id: { type: "string", minLength: 1, maxLength: 20 },
    }),
  },
  {
    name: "stop",
    description: "Stop the current job (and the crafting queue if crafting is true).",
    input_schema: object({ crafting: { type: "boolean" } }),
  },
  {
    name: "remind_me",
    description:
      "Get woken with a reminder event after some seconds (game time), e.g. to check furnaces once they've had time to smelt. It runs alongside your jobs: set it, then go do something else useful. One reminder at a time; a new one replaces it.",
    input_schema: object(
      {
        seconds: { type: "integer", minimum: 10, maximum: 600 },
        note: { type: "string", maxLength: 200, description: "What to do when woken" },
      },
      ["seconds"],
    ),
  },
  {
    name: "walk_to",
    description: "Walk to a position (pathfinding around obstacles)." + JOB,
    input_schema: object({ x: coordinate, y: coordinate }, ["x", "y"]),
  },
  {
    name: "come_to_me",
    description:
      "Walk over to your owner and stop next to them (\"come here\", \"come to me\"). player: go to another player by name instead (only when all players may talk to you)." +
      JOB,
    input_schema: object({ player: itemName }),
  },
  {
    name: "follow_me",
    description:
      "Keep following the owner until given another job or stopped. Never finishes on its own: use only when asked to follow. To just come over, use come_to_me.",
    input_schema: object(),
  },
  {
    name: "mine",
    description:
      "Mine by hand until the engineer has gained `count` of an item (iron-ore, copper-ore, coal, stone, wood; wood means chopping trees). An entity name (e.g. big-rock) mines those only, and count is still the items gained (one big-rock gives about 20 stone). Mines the closest sources first, staying near where it started. At most 10 ore, coal or stone by hand: for more, call give or insert with what you need (they use the base's drills, furnaces and chests, building them first if there are none)." +
      JOB,
    input_schema: object(
      { name: itemName, count: { type: "integer", minimum: 1, maximum: 1000, description: "Default 10" } },
      ["name"],
    ),
  },
  {
    name: "place",
    description:
      "Place a building from the inventory at a position, walking into range first. With none in the inventory it hand-crafts one, first mining any wood or stone the recipe is short of (so \"place a wooden chest\" is one call). direction: 0 north, 1 east, 2 south, 3 west. recipe: what an assembling machine makes. Fails with what's blocking the spot." +
      JOB,
    input_schema: object(
      { item: itemName, x: coordinate, y: coordinate, direction: { type: "integer", minimum: 0, maximum: 3 }, recipe: itemName },
      ["item", "x", "y"],
    ),
  },
  {
    name: "pick_up",
    description: "Mine a building (or tree/rock) at a position back into the inventory." + JOB,
    input_schema: object({ x: coordinate, y: coordinate }, ["x", "y"]),
  },
  {
    name: "insert",
    description:
      "Put items from the inventory into a building at a position (fuel, ore, ingredients, chest), walking there first. Short of something mined by hand (wood, stone, coal, ore), it mines the rest first, so one insert fulfils \"put 10 wood in the chest\"; with a big count it keeps mining and inserting in batches until done, full, or nothing's left nearby. Short of plates, bricks or something hand-craftable, it gets or makes them first like give does (drills built first when there are none and it's more than 10 ore's worth), so one insert fulfils \"put 100 iron plates in the chest\"." +
      JOB,
    input_schema: object(
      { x: coordinate, y: coordinate, item: itemName, count: { type: "integer", minimum: 1, maximum: 10000 } },
      ["x", "y", "item"],
    ),
  },
  {
    name: "take",
    description:
      "Take items out of a building at a position: a given item, or everything from its output/chest if item is omitted. With item and count, it waits while a furnace or assembler is still making the rest." +
      JOB,
    input_schema: object(
      { x: coordinate, y: coordinate, item: itemName, count: { type: "integer", minimum: 1, maximum: 10000 } },
      ["x", "y"],
    ),
  },
  {
    name: "give",
    description:
      "Hand items from the inventory to your owner: walks up to them (following if they move) and puts the items in their inventory. All of that item if count is omitted. Short of something mined by hand (wood, stone, coal, ore), it mines the rest first, so one give fulfils \"get me 10 wood\". Short of something furnaces or assemblers nearby have ready or are making (plates, gears), it takes them from there first, waiting for ones still being made. Short of something else it makes it: hand-craftable items crafted, their plates taken from the base's furnaces and chests, or smelted from a few hand-mined ore. More than 10 ore's worth is never hand-mined: with no drills making it, you first build a drill with a furnace or chest for each ore (plus a coal loop for a big order), then do the give, all without more tool calls (the call returns \"Not started yet\": just tell your owner what you're building). One give fulfils \"give me 100 iron plates\" or \"make me 10 firearm magazines\". Chests nearby (like the crash site's) are taken from first. player: give to another player by name instead (only when all players may talk to you)." +
      JOB,
    input_schema: object(
      { item: itemName, count: { type: "integer", minimum: 1, maximum: 10000 }, player: itemName },
      ["item"],
    ),
  },
  {
    name: "steps",
    description:
      "Do several jobs in a row as one job, e.g. place four drills and then put coal in each, or take plates from every furnace. Each step has an action (walk_to, mine, place, pick_up, insert, take, give) plus that tool's arguments. You're woken once: job_done when all steps are done (with each step's result), or job_failed at the first step that fails (earlier steps stay done). A place or insert step waits for hand-crafting if its item is still being crafted, so you can craft and then build in one go. Prefer this over single jobs whenever you know the next few actions." +
      JOB,
    input_schema: object(
      {
        steps: {
          type: "array",
          minItems: 1,
          maxItems: 20,
          items: {
            type: "object",
            properties: {
              action: { type: "string", enum: STEP_ACTIONS },
              x: coordinate,
              y: coordinate,
              item: itemName,
              name: itemName,
              direction: { type: "integer", minimum: 0, maximum: 3 },
              recipe: itemName,
              count: { type: "integer", minimum: 1, maximum: 10000 },
            },
            required: ["action"],
            additionalProperties: false,
          },
        },
      },
      ["steps"],
    ),
  },
];

/**
 * Cheats, offered only to a local model whose owner allowed them in setup. The runner refuses them unless
 * the latest request came from the owner. The mod refuses them unless the app turned cheats on.
 */
export const CHEAT_TOOLS: Tool[] = [
  {
    name: "cheat_items",
    description: "Cheat: put items straight into the engineer's inventory, no gathering or crafting needed.",
    input_schema: object({ item: itemName, count: { type: "integer", minimum: 1, maximum: 10000, description: "Default 1" } }, ["item"]),
  },
  {
    name: "run_lua",
    description:
      "Cheat: run Factorio 2.0 Lua in the game (like /c) and get back what it returns and prints. `engineer` is the engineer's character, `owner` your owner's player. Return plain values (numbers, strings, tables of them), not game objects. E.g. `game.forces.player.research_all_technologies()`, `engineer.character_running_speed_modifier = 2`.",
    input_schema: object({ code: { type: "string", minLength: 1, maxLength: 4000 } }, ["code"]),
  },
];
export const CHEAT_NAMES = new Set(CHEAT_TOOLS.map((t) => t.name));

/** Tools that start a job in the game. Only one job runs at a time. */
export const JOB_TOOLS = new Set([...TOOLS.filter((t) => t.description.includes(JOB)).map((t) => t.name), "follow_me"]);

export function claudeTools(): Anthropic.Messages.Tool[] {
  return TOOLS.map((tool) => ({ ...tool, eager_input_streaming: true }));
}

/** Check tool input against its schema (types, required, bounds). Returns an error or null. */
export function validate(name: string, input: unknown): string | null {
  const tool = TOOLS.find((t) => t.name === name) ?? CHEAT_TOOLS.find((t) => t.name === name);
  if (!tool) return `Unknown tool ${name}`;
  if (typeof input !== "object" || input === null || Array.isArray(input)) return "Input must be an object";
  const values = input as Record<string, unknown>;
  const schema = tool.input_schema;
  for (const key of schema.required ?? []) if (values[key] === undefined) return `Missing ${key}`;
  for (const [key, value] of Object.entries(values)) {
    const field = schema.properties[key];
    if (!field) return `Unknown argument ${key}`;
    const type = field.type;
    if (type === "array") {
      if (!Array.isArray(value)) return `${key} must be a list`;
      if (value.length < (field.minItems as number) || value.length > (field.maxItems as number))
        return `${key} must have ${field.minItems} to ${field.maxItems} entries`;
      // Each step is checked against the schema of the tool it names.
      for (const [i, step] of value.entries()) {
        if (typeof step !== "object" || step === null || Array.isArray(step)) return `step ${i + 1} must be an object`;
        const { action, ...rest } = step as Record<string, unknown>;
        if (!STEP_ACTIONS.includes(action as string)) return `step ${i + 1}: action must be one of ${STEP_ACTIONS.join(", ")}`;
        const invalid = validate(action as string, rest);
        if (invalid) return `step ${i + 1} (${action}): ${invalid}`;
      }
    } else if (type === "string") {
      const max = (field.maxLength as number | undefined) ?? 100;
      if (typeof value !== "string" || value.length < 1) return `${key} must be a text`;
      if (value.length > max) return `${key} must be at most ${max} characters`;
    } else if (type === "boolean") {
      if (typeof value !== "boolean") return `${key} must be true or false`;
    } else {
      if (typeof value !== "number" || !Number.isFinite(value)) return `${key} must be a number`;
      if (type === "integer" && !Number.isInteger(value)) return `${key} must be a whole number`;
      if (field.minimum !== undefined && value < (field.minimum as number)) return `${key} is too small`;
      if (field.maximum !== undefined && value > (field.maximum as number)) return `${key} is too large`;
    }
  }
  return null;
}
