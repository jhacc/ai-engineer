// Real-game integration test: drives the mod's tools in a disposable headless world.
// Usage: bun run test:game   (TEST_SPACE_AGE=1 to include Space Age)
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";
import { Game } from "../app/src/game";
import { CHEAT_TOOLS, TOOLS } from "../app/src/tools";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Agent } from "../app/src/agent";
import { Runner } from "../app/src/runner";
import { FakeAPI, call, text } from "../app/test/fakes";

const server = await startServer({ spaceAge: !!process.env.TEST_SPACE_AGE });
const game = new Game(server.rcon, "test-app");
const lua = (code: string) => server.rcon.command("/sc " + code);
const tool = async (name: string, args: Record<string, unknown> = {}) => {
  const r = await game.tool(name, args);
  if (!r.ok) throw new Error(`${name} failed: ${r.error}`);
  return r.result as any;
};
let after = 0;
async function waitFor(kinds: string[], timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const poll = await game.poll(after);
    for (const item of poll.items ?? []) {
      after = Math.max(after, item.id);
      if (kinds.includes(item.kind)) return item;
    }
    await Bun.sleep(250);
  }
  throw new Error(`Timed out waiting for ${kinds.join("/")}`);
}

try {
  // Console commands need confirming once per save.
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  // A flat test area: grass, an iron patch, trees, a chest with coal.
  await lua(
    'local s=game.surfaces[1]; for _,e in pairs(s.find_entities_filtered{area={{-60,-60},{60,60}}}) do e.destroy() end; ' +
      'local t={} for x=-60,60 do for y=-60,60 do t[#t+1]={name="grass-1",position={x,y}} end end s.set_tiles(t); ' +
      'for x=20,24 do for y=0,4 do s.create_entity{name="iron-ore",position={x,y},amount=500} end end; ' +
      'for i=0,4 do s.create_entity{name="tree-01",position={-20,i*3}} end; ' +
      'local c=s.create_entity{name="wooden-chest",position={0,10},force="player"}; c.insert{name="coal",count=25}; ' +
      'local w={} for x=40,50 do for y=-50,-40 do w[#w+1]={name="water",position={x,y}} end end s.set_tiles(w); ' +
      'for x=-44,-36 do for y=-44,-36 do s.create_entity{name="stone",position={x,y},amount=500} end end; ' +
      'for i=0,3 do s.create_entity{name="big-rock",position={-12-i*4,-14}} end; ' +
      'game.forces.player.chart(s,{{-64,-64},{64,64}}); rcon.print("ready")',
  );

  // The chat window isn't built in headless tests; at least check the sprites it uses exist.
  for (const sprite of ["utility/trash", "utility/close"])
    assert.equal(await lua(`rcon.print(helpers.is_valid_sprite_path("${sprite}"))`).then((s) => s.trim()), "true", `sprite ${sprite}`);

  const hello = await game.hello();
  assert.ok(hello.session && hello.mod_version, "hello");
  assert.equal(hello.paired, false);
  await game.testSpawn({ x: 0, y: 0 });
  // Already wearing armor, so it doesn't craft some from plates the tests below count (test-order covers that).
  await lua('game.surfaces[1].find_entities_filtered{type="character"}[1].get_inventory(defines.inventory.character_armor).insert{name="light-armor"}');
  const modTools = await game.toolNames();
  assert.deepEqual(modTools, [...TOOLS, ...CHEAT_TOOLS].map((t) => t.name).sort(), "the app and the mod define the same tools");
  // Cheats are refused unless the app's poll turned them on.
  const cheatOff = await game.tool("cheat_items", { item: "iron-plate" });
  assert.ok(!cheatOff.ok && /Cheats are off/.test(cheatOff.error), "cheats are off by default");
  await game.poll(0, { cheats: true });
  const ran = await game.tool("run_lua", { code: "print('hi') return engineer.name, 1 + 1" });
  assert.ok(ran.ok && (ran.result as any).returned === "\"character\"" && (ran.result as any).printed[0] === "hi", "run_lua runs code");
  const items = await game.tool("cheat_items", { item: "iron-plate", count: 5 });
  assert.ok(items.ok && (items.result as any).added === 5, "cheat_items adds items");
  await game.tool("run_lua", { code: "engineer.remove_item{name = 'iron-plate', count = 5}" });
  await game.poll(0);

  // The item lookup: groups, one group by subgroup, and a search by what players call things.
  const groups = (await tool("items")).groups as Array<{ name: string; count: number }>;
  console.log("item groups:", groups.map((g) => `${g.name} ${g.count}`).join(", "));
  assert.ok(groups.some((g) => g.name === "combat" && g.count > 5), "item groups are listed");
  const combat = (await tool("items", { group: "combat" })).subgroups as Array<{ subgroup: string; items: string[] }>;
  assert.ok(combat.some((s) => s.items.includes("pistol")), "a group lists its items by subgroup");
  const weapons = (await tool("items", { search: "weapon" })).found as Array<{ name: string }>;
  console.log("weapons:", weapons.map((i) => i.name).join(", "));
  assert.ok(["pistol", "submachine-gun", "firearm-magazine", "grenade"].every((n) => weapons.some((i) => i.name === n)), "weapon search finds guns, ammo and grenades");

  // The goal planner on made-up recipes: OR between recipes, AND of ingredients, research in order, cycles,
  // missing producers, machines and surfaces.
  const list = <T>(x: T[] | Record<string, never> | undefined): T[] => (Array.isArray(x) ? x : []);
  const fixture = {
    recipes: [
      { name: "gear-a", ingredients: [["plate", 2]], products: [["gear", 1]], enabled: true },
      { name: "gear-b", ingredients: [["plate", 1]], products: [["gear", 1]] },
      { name: "plate-a", ingredients: [["unobtainium", 1]], products: [["plate", 1]], enabled: true },
      { name: "plate-b", ingredients: [["ore", 1]], products: [["plate", 1]], enabled: true },
      { name: "a-from-b", ingredients: [["b", 1]], products: [["a", 1]], enabled: true },
      { name: "b-from-a", ingredients: [["a", 1]], products: [["b", 1]], enabled: true },
      { name: "b-from-ore", ingredients: [["ore", 1]], products: [["b", 1]], enabled: true },
      { name: "x-from-y", ingredients: [["y", 1]], products: [["x", 1]], enabled: true },
      { name: "y-from-x", ingredients: [["x", 1]], products: [["y", 1]], enabled: true },
      { name: "widget", ingredients: [["nothing", 1]], products: [["widget", 1]], enabled: true },
      { name: "chip", ingredients: [["gear", 1]], products: [["chip", 1]] },
      { name: "goo", ingredients: [["ore", 1]], products: [["goo", 1]], category: "chemistry", enabled: true },
      { name: "moon-dust", ingredients: [["ore", 1]], products: [["dust", 1]], enabled: true },
      { name: "z-dust-slow", ingredients: [["ore", 5]], products: [["dust", 1]], enabled: true },
    ],
    technologies: [
      { name: "t1" },
      { name: "t2", prerequisites: ["t1"] },
      { name: "t3", prerequisites: ["t2"], unlocks: ["chip"] },
      { name: "t-gear", unlocks: ["gear-b"] },
    ],
    sources: ["ore"],
    wrong_surface: ["moon-dust"],
  };
  const resolve = async (item: string, more: Record<string, unknown> = {}) =>
    (await game.testPlan({ fixture, item, ...more })).plan;
  const codes = (p: any) => list<any>(p.blockers).map((b) => b.code);
  const gear = await resolve("gear");
  assert.equal(gear.recipe, "gear-a", "an unlocked recipe beats one that needs research");
  assert.deepEqual(gear.alternatives, ["gear-a", "gear-b"], "the other recipes are listed");
  assert.equal(list<any>(gear.recipes).find((r) => r.item === "plate")?.recipe, "plate-b", "a recipe with an ingredient nothing makes is passed over");
  assert.deepEqual(codes(gear), [], "gear is feasible");
  assert.equal((await resolve("gear", { recipe: "gear-b" })).research[0], "t-gear", "a chosen recipe brings its research");
  const a = await resolve("a");
  assert.deepEqual(codes(a), [], "a cycle is avoided when another recipe breaks it");
  assert.ok(list<any>(a.recipes).some((r) => r.recipe === "b-from-ore"), "b comes from ore, not from a");
  assert.ok(codes(await resolve("x")).includes("CYCLE"), "a pure cycle is blocked, not expanded forever");
  assert.ok(codes(await resolve("widget")).includes("NO_SOURCE"), "an ingredient nothing makes blocks");
  assert.deepEqual(list((await resolve("chip")).research), ["t1", "t2", "t3"], "research comes prerequisites first");
  assert.ok(codes(await resolve("goo")).includes("UNKNOWN_CAPABILITY"), "a recipe no machine can make blocks");
  assert.equal((await resolve("dust")).recipe, "z-dust-slow","a recipe that can't be made on this surface is passed over");
  assert.ok(codes(await resolve("dust", { recipe: "moon-dust" })).includes("NO_VALID_SURFACE"), "and blocks when chosen");
  const rate = await resolve("gear", { rate: 120 });
  assert.equal(list<any>(rate.recipes).find((r) => r.recipe === "gear-a")?.count, 2, "machine counts follow the rate");
  assert.equal(list<any>((await resolve("gear", { supplied: ["plate"] })).raw)[0]?.supplied, true, "supplied items aren't expanded");
  // The machine is made of what it makes (assemblers and circuits): it only needs its research, it's hand-crafted.
  const boot = {
    recipes: [
      { name: "assembler", ingredients: [["chip", 2]], products: [["assembler", 1]] },
      { name: "chip", ingredients: [["ore", 1]], products: [["chip", 1]], enabled: true },
    ],
    technologies: [{ name: "automation", unlocks: ["assembler"] }],
    sources: ["ore"],
    machines: { crafting: { name: "assembler", unlocked: false, item: "assembler" } },
  };
  const chip = (await game.testPlan({ fixture: boot, item: "chip" })).plan;
  assert.deepEqual(codes(chip), [], "a machine made of its own product isn't a cycle");
  assert.deepEqual(list(chip.research), ["automation"], "it needs the machine's research");

  // Goals from the real game data: electronic circuits plan research, two kinds of assemblers and an output
  // check; asking again gives the same goal; fluids, plates and invented recipes are refused with reasons.
  const circuits = await tool("goal", { item: "electronic-circuit", per_minute: 15 });
  console.log("goal circuits:", JSON.stringify(circuits, null, 1));
  assert.equal(circuits.status, "ACTIVE");
  assert.ok(circuits.tasks.some((t: string) => /research automation/.test(t)), "assemblers need automation research");
  assert.ok(circuits.tasks.some((t: string) => /making copper-cable/.test(t)) && circuits.tasks.some((t: string) => /making electronic-circuit/.test(t)));
  assert.match(circuits.tasks.at(-1), /check 15\/min of electronic-circuit/, "done only when the output is measured");
  const again = await tool("goal", { item: "electronic-circuit", per_minute: 15 });
  assert.ok(again.id === circuits.id && again.already_planned, "asking again doesn't duplicate the goal");
  assert.equal((await tool("goal", { action: "cancel", id: circuits.id })).status, "CANCELLED");
  const chem = await tool("goal", { item: "chemical-science-pack" });
  console.log("goal chemical science:", JSON.stringify(chem));
  assert.ok(chem.status === "BLOCKED" && /UNKNOWN_CAPABILITY/.test(chem.reason), "fluid recipes are blocked with a reason");
  const plates = await tool("goal", { item: "iron-plate" });
  assert.ok(plates.status === "BLOCKED" && /furnaces/.test(plates.reason), "plates come from the base");
  const invented = await game.tool("goal", { item: "iron-gear-wheel", recipe: "gear-from-air" });
  assert.ok(!invented.ok && /recipes for it are: iron-gear-wheel/.test(invented.error), "an invented recipe is refused");
  for (const g of [chem, plates]) await tool("goal", { action: "cancel", id: g.id });

  // The plan: from a fresh start, the next science pack; a technology goal; an item goal; a fuzzy goal.
  const start = await tool("plan");
  console.log("plan:", JSON.stringify(start, null, 1));
  assert.equal(start.goal, "automation-science-pack", "the default goal is the first science pack");
  assert.ok(start.build.some((l: string) => /stone-furnace making iron-plate/.test(l)), "the plan builds furnaces for plates");
  assert.ok(start.build.some((l: string) => /on iron-ore/.test(l)), "the plan puts drills on iron ore");
  const logistics = await tool("plan", { goal: "logistics", per_minute: 30 });
  console.log("plan logistics:", JSON.stringify(logistics, null, 1));
  assert.ok(logistics.research.at(-1).startsWith("logistics:"), "the goal is researched last");
  assert.ok(logistics.science_packs.some((l: string) => l.startsWith("automation-science-pack:")), "logistics takes red science");
  assert.ok(logistics.build.some((l: string) => /assembling-machine-1 .*making automation-science-pack/.test(l)), "red science is made in assemblers");
  const steel = await tool("plan", { goal: "steel-plate" });
  console.log("plan steel:", JSON.stringify(steel, null, 1));
  assert.ok(steel.research.at(-1).startsWith("steel-processing:"), "an item goal researches the technology that unlocks it");
  const blue = await tool("plan", { goal: "chemical-science-pack" });
  console.log("plan blue:", JSON.stringify(blue, null, 1));
  assert.ok(blue.build.some((l: string) => /oil-refinery/.test(l)) && blue.build.some((l: string) => /pumpjack/.test(l)), "blue science plans oil");
  const silo = await tool("plan", { goal: "rocket-silo" });
  console.log("plan silo:", JSON.stringify(silo, null, 1));
  assert.ok(silo.research.length <= 26 && silo.research.at(-1).startsWith("..."), "a long research path is cut short");
  assert.ok(!silo.build.some((l: string) => /barrel|making rocket-silo/.test(l)), "no barrel loops, and a goal building isn't mass-produced");
  const fuzzy = await game.tool("plan", { goal: "oil" });
  console.log("plan oil:", JSON.stringify(fuzzy));
  assert.ok(!fuzzy.ok && /oil-processing/.test(fuzzy.error), "an unknown goal lists technologies with that in the name");

  // Fire is enemy-force (like the crash site's flames) but isn't an enemy.
  await lua('game.surfaces[1].create_entity{name="fire-flame",position={4,4}}');
  const seen = await tool("observe", { radius: 32 });
  assert.equal(seen.resources?.[0]?.name, "iron-ore");
  assert.ok(seen.nature?.some((n: any) => n.name === "trees"));
  assert.equal(seen.enemies, undefined, "fire isn't reported as enemies");
  assert.deepEqual(seen.engineer.weapons, ["pistol with 2 firearm-magazine"], "observe shows the gun");
  console.log("observe ok:", JSON.stringify(seen.engineer));
  // It starts with a burner drill, a furnace and one wood (no plates), armed with a pistol and 2 magazines.
  const kit = (await tool("inventory")).inventory as Array<{ name: string; count: number }>;
  console.log("starting kit:", JSON.stringify(kit));
  for (const name of ["burner-mining-drill", "stone-furnace", "wood"])
    assert.ok(kit.some((i) => i.name === name && i.count === 1), `starts with one ${name}`);
  assert.ok(!kit.some((i) => i.name === "iron-plate"), "starts without plates");
  assert.equal(
    await lua('for _,e in pairs(game.surfaces[1].find_entities_filtered{type="character"}) do rcon.print(e.get_item_count("pistol").." "..e.get_item_count("firearm-magazine")) end').then((s) => s.trim()),
    "1 2",
  );

  // give needs an owner in the game; the test engineer has none.
  const give = await game.tool("give", { item: "wood" });
  assert.ok(!give.ok && /owner isn't here/.test(give.error), "give without an owner fails clearly");
  const come = await game.tool("come_to_me", {});
  assert.ok(!come.ok && /owner isn't here/.test(come.error), "come_to_me without an owner fails clearly");

  // A drill on grass is refused, pointing at the nearest spot fully on ore.
  const grass = await game.tool("place", { item: "burner-mining-drill", x: 12, y: 2 });
  console.log("drill on grass:", JSON.stringify(grass));
  assert.ok(!grass.ok && /No ore under .*Nearest spot fully on iron-ore: \{x = 2\d, y = [0-4]\}/.test(grass.error), "suggests a spot on the iron");

  // A drill over two resources is refused, with a spot that's only on one; that spot works.
  await lua('for y=0,4 do game.surfaces[1].create_entity{name="copper-ore",position={25,y},amount=500} end');
  const mixed = await game.tool("place", { item: "burner-mining-drill", x: 25, y: 1 });
  console.log("mixed drill:", JSON.stringify(mixed));
  assert.equal(mixed.ok, false);
  const spot = (!mixed.ok && mixed.error.match(/fully on iron-ore: \{x = ([-\d.]+), y = ([-\d.]+)\}/)) || null;
  assert.ok(spot, "suggests a spot on iron only");
  await tool("place", { item: "burner-mining-drill", x: Number(spot[1]), y: Number(spot[2]) });
  const clean = await waitFor(["job_done", "job_failed"], 60000);
  assert.equal(clean.kind, "job_done", JSON.stringify(clean.data));
  // The result says where a furnace has to go to be fed; a furnace beside the drill is told it isn't fed and
  // where to move it; there it is fed.
  const drillNote = (clean.data as any).result.note as string;
  console.log("drill output:", drillNote);
  const feedAt = drillNote.match(/a stone-furnace placed at \{x = ([-\d.]+), y = ([-\d.]+)\}/);
  assert.ok(feedAt, "says where a furnace would be fed");
  await tool("place", { item: "stone-furnace", x: Number(spot[1]) - 2, y: Number(spot[2]) });
  const beside = await waitFor(["job_done", "job_failed"], 60000);
  console.log("furnace beside the drill:", JSON.stringify(beside.data));
  const moveTo = ((beside.data as any).result?.note ?? "").match(/Not fed: .*must be at \{x = ([-\d.]+), y = ([-\d.]+)\}/);
  assert.ok(moveTo && moveTo[1] === feedAt[1] && moveTo[2] === feedAt[2], "a furnace beside the drill is told where to go");
  await tool("pick_up", { x: Number(spot[1]) - 2, y: Number(spot[2]) });
  assert.equal((await waitFor(["job_done", "job_failed"], 60000)).kind, "job_done");
  await tool("place", { item: "stone-furnace", x: Number(feedAt[1]), y: Number(feedAt[2]) });
  const fed = await waitFor(["job_done", "job_failed"], 60000);
  assert.match((fed.data as any).result?.note ?? "", /Fed by the burner-mining-drill/, JSON.stringify(fed.data));
  const feeds = (await tool("observe", { radius: 32 })).buildings.find((b: any) => b.name === "burner-mining-drill")?.feeds;
  assert.match(feeds, /^stone-furnace at/, "observe shows what the drill feeds");
  // Fueled, the drill really does fill the furnace.
  await lua('for _,e in pairs(game.surfaces[1].find_entities_filtered{name="burner-mining-drill"}) do e.insert{name="coal",count=2} end');
  let smelting = 0;
  for (let i = 0; i < 40 && smelting === 0; i++) {
    await new Promise((r) => setTimeout(r, 500));
    smelting = Number(await lua('local n=0 for _,f in pairs(game.surfaces[1].find_entities_filtered{name="stone-furnace"}) do n=n+f.get_item_count("iron-ore")+f.get_item_count("iron-plate") end rcon.print(n)'));
  }
  assert.ok(smelting > 0, "the drill feeds ore into the furnace");
  // Plates waiting in a furnace are pointed out by observe, and by a craft that needs them.
  await lua('game.surfaces[1].find_entities_filtered{name="stone-furnace"}[1].get_output_inventory().insert{name="iron-plate",count=50}');
  const ready = (await tool("observe", { radius: 32 })).ready_to_take?.find((r: any) => r.item === "iron-plate");
  assert.ok(ready && ready.count >= 50 && ready.take_from.length > 0, "observe lists plates ready to take");
  const chest = await game.tool("craft", { recipe: "iron-chest" });
  console.log("craft with plates in a furnace:", JSON.stringify(chest));
  assert.ok(!chest.ok && /ready in machines: take them from/.test(chest.error), "a craft points to plates waiting in a furnace");
  const woodFuel = await game.tool("insert", { x: Number(spot[1]), y: Number(spot[2]), item: "wood", count: 1 });
  assert.ok(!woodFuel.ok && /coal only/.test(woodFuel.error), "drills aren't fueled with wood");
  await tool("pick_up", { x: Number(feedAt[1]), y: Number(feedAt[2]) });
  assert.equal((await waitFor(["job_done", "job_failed"], 60000)).kind, "job_done");
  await tool("pick_up", { x: Number(spot[1]), y: Number(spot[2]) });
  assert.equal((await waitFor(["job_done", "job_failed"], 60000)).kind, "job_done");
  await lua('for _,e in pairs(game.surfaces[1].find_entities_filtered{name="copper-ore"}) do e.destroy() end');

  const found = await tool("find", { name: "iron-ore", limit: 2 });
  assert.equal(found.found.length, 2);
  // Four rocks are nearer than the stone patch, but the patch is still listed.
  const stone = (await tool("find", { name: "stone", limit: 2 })).found;
  console.log("stone:", JSON.stringify(stone));
  assert.ok(stone.some((f: any) => f.name === "stone") && stone.some((f: any) => f.name === "big-rock"));

  // Mining walks to the ore and stops at the requested amount.
  await tool("mine", { name: "iron-ore", count: 8 });
  const mined = await waitFor(["job_done", "job_failed"], 90000);
  console.log("mine:", JSON.stringify(mined.data));
  assert.equal(mined.kind, "job_done");
  assert.ok((mined.data as any).result.mined >= 8);
  assert.match(String((mined.data as any).result.next), /insert the iron-ore into a fueled furnace/, "says how ore becomes plates");

  // Wood from trees, asked for as a player would say it.
  await tool("mine", { name: "trees", count: 4 });
  const wood = await waitFor(["job_done", "job_failed"], 90000);
  console.log("wood:", JSON.stringify(wood.data));
  assert.equal(wood.kind, "job_done");
  assert.equal((wood.data as any).result.item, "wood");

  // A rock's name counts the stone it gives: 5 stone is one rock, not five.
  const rocksBefore = Number(await lua('rcon.print(game.surfaces[1].count_entities_filtered{name="big-rock"})'));
  await tool("mine", { name: "big-rock", count: 5 });
  const rock = await waitFor(["job_done", "job_failed"], 90000);
  console.log("rock:", JSON.stringify(rock.data));
  assert.equal((rock.data as any).result?.item, "stone", JSON.stringify(rock.data));
  const rocksAfter = Number(await lua('rcon.print(game.surfaces[1].count_entities_filtered{name="big-rock"})'));
  assert.equal(rocksBefore - rocksAfter, 1, "mined one rock");

  // Take coal from the chest, then craft and place a furnace (needs stone: give some).
  await tool("take", { x: 0, y: 10, item: "coal" });
  const took = await waitFor(["job_done", "job_failed"]);
  assert.equal(took.kind, "job_done", JSON.stringify(took.data));
  await lua('for _,e in pairs(game.surfaces[1].find_entities_filtered{type="character"}) do e.insert{name="stone",count=10} end');
  const crafted = await tool("craft", { recipe: "stone-furnace", count: 2 });
  assert.equal(crafted.crafting, 2);
  await waitFor(["crafting_done"]);
  const bad = await game.tool("craft", { recipe: "assembling-machine-1", count: 1 });
  assert.equal(bad.ok, false);
  console.log("craft refusal:", !bad.ok && bad.error);

  // Standing right on the spot: it steps aside and places.
  await lua('game.surfaces[1].find_entities_filtered{type="character"}[1].teleport({6,-6})');
  await tool("place", { item: "stone-furnace", x: 6, y: -6 });
  const placed = await waitFor(["job_done", "job_failed"]);
  assert.equal(placed.kind, "job_done", JSON.stringify(placed.data));
  await tool("insert", { x: 6, y: -6, item: "coal", count: 5 });
  const fueled = await waitFor(["job_done", "job_failed"]);
  assert.equal(fueled.kind, "job_done", JSON.stringify(fueled.data));
  await tool("insert", { x: 6, y: -6, item: "iron-ore", count: 8 });
  assert.equal((await waitFor(["job_done", "job_failed"])).kind, "job_done");
  const furnace = (await tool("observe", { radius: 16 })).buildings.find((b: any) => b.name === "stone-furnace");
  console.log("furnace:", JSON.stringify(furnace));
  assert.ok(furnace.fuel, "furnace has fuel");
  // Taking all 8 plates right away waits for the furnace to smelt them (3.2 s each), not just the first.
  await tool("take", { x: 6, y: -6, item: "iron-plate", count: 8 });
  const smelted = await waitFor(["job_done", "job_failed"], 60000);
  assert.equal((smelted.data as any).result?.taken?.[0]?.count, 8, `take waits for the rest: ${JSON.stringify(smelted.data)}`);

  // insert mines what it's short of first (for things mined by hand), and says so.
  const woodHave = (await tool("inventory")).inventory.find((i: any) => i.name === "wood")?.count ?? 0;
  await tool("insert", { x: 0, y: 10, item: "wood", count: woodHave + 2 });
  const stocked = await waitFor(["job_done", "job_failed"], 90000);
  console.log("insert after mining:", JSON.stringify(stocked.data));
  assert.equal(stocked.kind, "job_done", JSON.stringify(stocked.data));
  assert.equal((stocked.data as any).result.inserted, woodHave + 2, "inserts the full count");
  assert.ok((stocked.data as any).result.mined_first >= 2, "mined the missing wood first");
  // A wrong name gets a suggestion; place crafts the building when there's none but the ingredients are there.
  const misnamed = await game.tool("craft", { recipe: "wooden-box" });
  assert.ok(!misnamed.ok && /Did you mean wooden-chest\?/.test(misnamed.error), `suggests a name: ${!misnamed.ok && misnamed.error}`);
  await lua('game.surfaces[1].find_entities_filtered{type="character"}[1].insert{name="wood",count=2}');
  await tool("place", { item: "wooden-chest", x: 3, y: 12 });
  const crafted1 = await waitFor(["job_done", "job_failed"], 30000);
  assert.equal(crafted1.kind, "job_done", `place crafts it first: ${JSON.stringify(crafted1.data)}`);
  // With no wood at all, place mines what the chest needs, crafts it and places it, as one job.
  await lua('local e = game.surfaces[1].find_entities_filtered{type="character"}[1] e.remove_item{name="wood", count=1000}');
  await tool("place", { item: "wooden-chest", x: 5, y: 12 });
  const gatheredChest = await waitFor(["job_done", "job_failed"], 90000);
  console.log("place after mining:", JSON.stringify(gatheredChest.data));
  assert.equal(gatheredChest.kind, "job_done", `place mines and crafts first: ${JSON.stringify(gatheredChest.data)}`);
  // insert says how much the chest now holds.
  // (Counts over 200 mine and insert in batches; checked by hand with 230, which takes a few minutes.)
  await tool("insert", { x: 5, y: 12, item: "wood", count: 12 });
  const filled = await waitFor(["job_done", "job_failed"], 90000);
  assert.equal((filled.data as any).result?.now_holds, 12, `insert reports the chest's total: ${JSON.stringify(filled.data)}`);
  const wrongWay = await tool("take", { x: 0, y: 10, item: "stone" });
  assert.ok(wrongWay.started);
  const noStone = await waitFor(["job_done", "job_failed"]);
  assert.match(String((noStone.data as any).reason), /to put items in, use insert/, "take explains insert");

  // Walking across the map, and a refused placement explains why.
  await tool("walk_to", { x: -30, y: 30 });
  const walked = await waitFor(["job_done", "job_failed"], 90000);
  assert.equal(walked.kind, "job_done", JSON.stringify(walked.data));

  // give's making plan, run as a steps job without its last step (the give needs a player).
  const jobsLua = `local jobs for k,v in pairs(package.loaded) do if k:find("scripts.jobs") then jobs=v end end local rec for _,r in pairs(storage.engineers) do rec=r end `;
  const makePlan = async (item: string, more: number) => {
    const out = await server.rcon.command(
      `/sc __ai-engineer__ ${jobsLua} local s, why = jobs.make_steps(rec, "${item}", rec.entity.get_item_count("${item}") + ${more}) ` +
        `rcon.print(s and helpers.table_to_json(s) or ("no plan: " .. tostring(why)))`,
    );
    if (out.startsWith("no plan")) throw new Error(`${item}: ${out}`);
    return JSON.parse(out);
  };
  const runPlan = async (plan: any[], timeoutMs = 180000) => {
    assert.equal(plan.pop().action, "give");
    await server.rcon.command(`/sc __ai-engineer__ ${jobsLua} jobs.start(rec, "steps", helpers.json_to_table('${JSON.stringify({ steps: plan })}'))`);
    return waitFor(["job_done", "job_failed"], timeoutMs);
  };
  // "Give me 5 stone bricks" (10 stone, few enough to mine by hand) with no furnace nearby: place one, fuel
  // it with just the coal it burns, mine and insert the stone, take the bricks.
  const plan = await makePlan("stone-brick", 5);
  console.log("smelt plan:", JSON.stringify(plan));
  assert.equal(plan[0].action, "place", "places a furnace when none is near");
  assert.equal(plan.find((s: any) => s.item === "coal")?.count, 1, "one coal for 5 bricks");
  const bricks = await runPlan(plan);
  console.log("smelted:", JSON.stringify(bricks.data));
  assert.equal((bricks.data as any).result?.results?.at(-1)?.taken?.[0]?.count, 5, "smelts all 5");
  // The emptied furnace tells the AI it only smelts what's inserted into it.
  const emptyFurnace = (await tool("observe", { radius: 16 })).buildings.find((b: any) => b.name === "stone-furnace");
  assert.match(String(emptyFurnace?.input), /only what's inserted/, JSON.stringify(emptyFurnace));
  // More than 10 ore's worth of iron plates isn't hand-mined: the base's storage supplies them.
  await lua('game.surfaces[1].find_entities_filtered{name="wooden-chest", position={0.5, 10.5}}[1].insert{name="iron-plate", count=20}');
  const ironPlan = await makePlan("iron-plate", 13);
  console.log("iron plan:", JSON.stringify(ironPlan));
  assert.equal(ironPlan[0].action, "collect", "collects from the base");
  const collectedIron = await runPlan(ironPlan);
  assert.equal((collectedIron.data as any).result?.results?.[0]?.collected, 13, JSON.stringify(collectedIron.data));
  const handMine = await game.tool("mine", { name: "iron-ore", count: 50 });
  assert.ok(!handMine.ok && /Not more than 10 iron-ore by hand/.test(handMine.error), "the mine tool refuses more than 10 ore");
  // "Make me 3 firearm magazines" (4 iron plates each, here in the inventory): a hand-craft, then the give.
  const ammoPlan = await makePlan("firearm-magazine", 3);
  console.log("ammo plan:", JSON.stringify(ammoPlan));
  assert.deepEqual(ammoPlan.map((s: any) => s.action), ["craft", "give"]);
  const ammo = await runPlan(ammoPlan);
  assert.equal((ammo.data as any).result?.results?.at(-1)?.crafted, 3, JSON.stringify(ammo.data));
  // "Put plates in the chest" with too few: insert smelts the rest first, then puts them all in.
  const platesHave = (await tool("inventory")).inventory.find((i: any) => i.name === "iron-plate")?.count ?? 0;
  await tool("insert", { x: 5, y: 12, item: "iron-plate", count: platesHave + 3 });
  const chestPlates = await waitFor(["job_done", "job_failed"], 180000);
  console.log("insert after making:", JSON.stringify(chestPlates.data));
  assert.equal((chestPlates.data as any).result?.inserted, platesHave + 3, JSON.stringify(chestPlates.data));
  // A big order (over 50) gets at least 3 drills, even with plates in storage: 60 iron plates asks for 3
  // iron drill and furnace pairs first.
  const bigOres = await server.rcon.command(
    `/sc __ai-engineer__ ${jobsLua} local s, why, ores = jobs.make_steps(rec, "iron-plate", rec.entity.get_item_count("iron-plate") + 60) rcon.print(helpers.table_to_json(ores or {}))`,
  );
  assert.deepEqual(
    JSON.parse(bigOres).map(({ ore, kind, target }: any) => ({ ore, kind, target })),
    [{ ore: "iron-ore", kind: "pair", target: 3 }],
    bigOres,
  );
  // 60 stone with nothing making it: not hand-mined. A big order, so the game builds the early base for it (the coal loop,
  // 3 stone drills filling chests), keep-busy off, then runs the insert by itself, collecting from all three
  // in rounds. (This map's copper is too near a nest for copper drills and furnaces.)
  await lua(
    'local e = game.surfaces[1].find_entities_filtered{type="character"}[1] ' +
      'e.insert{name="burner-mining-drill", count=6} e.insert{name="wooden-chest", count=3} e.insert{name="coal", count=50}',
  );
  // Research names that aren't technologies say what to do instead.
  const notTech = await game.tool("research", { technology: "red-science" });
  assert.ok(!notTech.ok && /automation-science-pack/.test(notTech.error), JSON.stringify(notTech));
  const labTech = await game.tool("research", { technology: "lab" });
  assert.ok(!labTech.ok && /isn't a technology/.test(labTech.error), JSON.stringify(labTech));
  // A small order (20 stone) is quicker: one stone drill and chest, fueled for it, and no coal loop.
  const smallHave = (await tool("inventory")).inventory.find((i: any) => i.name === "stone")?.count ?? 0;
  const smallWait = await game.tool("insert", { x: 5, y: 12, item: "stone", count: smallHave + 20 });
  console.log("small insert needing a drill:", JSON.stringify(smallWait));
  assert.ok(!smallWait.ok && /a drill and chest, for stone/.test(smallWait.error) && !/coal loop/.test(smallWait.error), "one drill, no coal loop");
  // Meanwhile the AI can't help by hand (small models placed drills and hand-smelted, undoing it).
  const meddle = await game.tool("mine", { name: "stone", count: 5 });
  assert.ok(!meddle.ok && /still building the drills for your insert/.test(meddle.error), JSON.stringify(meddle));
  const smallDone = await waitFor(["job_done", "job_failed"], 300000);
  console.log("small order after its drill:", JSON.stringify(smallDone.data));
  assert.equal((smallDone.data as any).result?.inserted, smallHave + 20, JSON.stringify(smallDone.data));
  const coalDrills = await lua(
    'local n = 0 for _, d in pairs(game.surfaces[1].find_entities_filtered{name="burner-mining-drill"}) do ' +
      'if d.mining_target and d.mining_target.name == "coal" then n = n + 1 end end rcon.print(n)',
  );
  assert.equal(Number(coalDrills), 0, "no coal loop for a small order");
  const stoneHave = (await tool("inventory")).inventory.find((i: any) => i.name === "stone")?.count ?? 0;
  const waiting = await game.tool("insert", { x: 5, y: 12, item: "stone", count: stoneHave + 60 });
  console.log("insert needing drills:", JSON.stringify(waiting));
  assert.ok(!waiting.ok && /3 drills, each with a chest, for stone/.test(waiting.error), "says it builds 3 drills first");
  const ordered = await waitFor(["job_done", "job_failed"], 540000);
  console.log("order after drills:", JSON.stringify(ordered.data));
  assert.equal((ordered.data as any).result?.inserted, stoneHave + 60, JSON.stringify(ordered.data));
  const stoneDrills = await lua(
    'local n = 0 for _, d in pairs(game.surfaces[1].find_entities_filtered{name="burner-mining-drill"}) do ' +
      'local t = d.drop_target if t and t.type == "container" and d.mining_target and d.mining_target.name == "stone" then n = n + 1 end end rcon.print(n)',
  );
  console.log("stone drills into chests:", stoneDrills);
  assert.ok(Number(stoneDrills) >= 3, "3 stone drills");

  const blocked = await tool("place", { item: "stone-furnace", x: 0, y: 10 });
  assert.ok(blocked.started);
  const refusal = await waitFor(["job_done", "job_failed"], 90000);
  console.log("blocked place:", JSON.stringify(refusal.data));
  assert.equal(refusal.kind, "job_failed");

  // Pick the furnace back up; research can be set.
  await tool("pick_up", { x: 6, y: -6 });
  assert.equal((await waitFor(["job_done", "job_failed"], 60000)).kind, "job_done");
  const research = await tool("research");
  console.log("research:", JSON.stringify(research));
  assert.ok(research.unlock_by_doing?.length, "2.0 trigger technologies are listed");
  const early = await game.tool("research", { technology: "automation" });
  assert.ok(!early.ok && /needs|unlocks when/.test(early.error), JSON.stringify(early));

  // The engineer's hand-crafting counts for "craft an item" research triggers (crafting a lab).
  await lua(
    'local f=game.forces.player f.technologies["steam-power"].researched=true f.technologies["electronics"].researched=true ' +
      'for _,e in pairs(game.surfaces[1].find_entities_filtered{type="character"}) do e.insert{name="iron-plate",count=100} e.insert{name="copper-plate",count=100} end',
  );
  assert.equal((await tool("craft", { recipe: "lab" })).crafting, 1);
  const lab = await waitFor(["crafting_done"]);
  console.log("lab crafted:", JSON.stringify(lab.data));
  assert.deepEqual((lab.data as any).unlocked, ["automation-science-pack"]);
  assert.equal(await lua('rcon.print(game.forces.player.technologies["automation-science-pack"].researched)').then((s) => s.trim()), "true");

  // Steam power from find water: pump, boiler and engine placed exactly as returned, a pole, and the lab researching.
  const water = (await tool("find", { name: "water" })).found[0];
  console.log("water:", JSON.stringify(water));
  assert.ok(water.shore && water.offshore_pump && water.boiler && water.steam_engine, "shore and a power layout");
  await lua(
    'for _,e in pairs(game.surfaces[1].find_entities_filtered{type="character"}) do for _,i in pairs({{"offshore-pump",1},{"boiler",1},{"steam-engine",1},' +
      '{"small-electric-pole",1},{"automation-science-pack",10},{"coal",10}}) do e.insert{name=i[1],count=i[2]} end end',
  );
  const engine = water.steam_engine.position;
  const vertical = water.steam_engine.direction % 2 === 0; // the pole and lab go beside the engine's long side
  const pole = vertical ? { x: engine.x - 3, y: engine.y } : { x: engine.x, y: engine.y - 3 };
  const labAt = vertical ? { x: engine.x - 6, y: engine.y } : { x: engine.x, y: engine.y - 6 };
  const at = (s: any) => ({ ...s.position, direction: s.direction });
  await tool("steps", {
    steps: [
      { action: "place", item: "offshore-pump", ...at(water.offshore_pump) },
      { action: "place", item: "boiler", ...at(water.boiler) },
      { action: "place", item: "steam-engine", ...at(water.steam_engine) },
      { action: "place", item: "small-electric-pole", ...pole },
      { action: "place", item: "lab", ...labAt },
      { action: "insert", item: "coal", count: 5, ...water.boiler.position },
      { action: "insert", item: "automation-science-pack", ...labAt },
    ],
  });
  const power = await waitFor(["job_done", "job_failed"], 90000);
  assert.equal(power.kind, "job_done", JSON.stringify(power.data));
  assert.equal((await tool("research", { technology: "automation" })).current, "automation");
  await Bun.sleep(3000);
  const labStatus = (await tool("observe", { radius: 24 })).buildings.find((b: any) => b.name === "lab");
  console.log("lab:", JSON.stringify(labStatus));
  assert.equal(labStatus.status, "working", "the lab runs on steam power");
  assert.ok(labStatus.science && !labStatus.output, "the lab's packs are listed as science");

  // An assembling machine can be placed with its recipe.
  await lua(
    'game.forces.player.technologies["automation"].researched=true ' +
      'for _,e in pairs(game.surfaces[1].find_entities_filtered{type="character"}) do e.insert{name="assembling-machine-1",count=1} end',
  );
  await tool("place", { item: "assembling-machine-1", x: engine.x - 3, y: engine.y - 3, recipe: "iron-gear-wheel" });
  const assembler = await waitFor(["job_done", "job_failed"], 90000);
  console.log("assembler:", JSON.stringify(assembler.data));
  assert.equal((assembler.data as any).result?.recipe, "iron-gear-wheel", JSON.stringify(assembler.data));

  // Several jobs as one: a place step waits for the furnace still being crafted.
  await lua('for _,e in pairs(game.surfaces[1].find_entities_filtered{type="character"}) do e.insert{name="stone",count=5} end');
  const furnaces = (await tool("inventory")).inventory.find((i: any) => i.name === "stone-furnace")?.count ?? 0;
  await tool("craft", { recipe: "stone-furnace", count: 1 });
  const spots = Array.from({ length: furnaces + 1 }, (_, i) => ({ x: 10 + i * 2, y: -6 }));
  await tool("steps", {
    steps: [
      ...spots.map((p) => ({ action: "place", item: "stone-furnace", ...p })),
      ...spots.map((p) => ({ action: "insert", item: "coal", count: 1, ...p })),
    ],
  });
  const multi = await waitFor(["job_done", "job_failed"], 90000);
  console.log("steps:", JSON.stringify(multi.data));
  assert.equal(multi.kind, "job_done", JSON.stringify(multi.data));
  assert.equal((multi.data as any).result.steps_done, spots.length * 2);
  await tool("steps", { steps: [{ action: "walk_to", x: 8, y: -9 }, { action: "place", item: "stone-furnace", x: 10, y: -6 }] });
  const partial = await waitFor(["job_done", "job_failed"], 90000);
  assert.equal(partial.kind, "job_failed");
  assert.match(String((partial.data as any).reason), /^Step 2 of 2 failed .*first step is done/);

  // Stopping cancels a job.
  await tool("walk_to", { x: 50, y: 50 });
  const stopped = await tool("stop");
  assert.ok(stopped.stopped);
  // A reminder wakes the AI later without being a job.
  assert.equal((await tool("remind_me", { seconds: 10, note: "check furnaces" })).remind_in_seconds, 10);
  const reminder = await waitFor(["reminder"], 30000);
  assert.equal(reminder.data?.note, "check furnaces");
  assert.ok((await tool("inventory")).free_slots > 0);

  // Enemies: observe gives the nearest one's distance, and the engineer shoots a biter in range by itself.
  await lua(
    'local c=game.surfaces[1].find_entities_filtered{type="character"}[1] ' +
      'storage.test_biter=game.surfaces[1].create_entity{name="small-biter",position={c.position.x+8,c.position.y},force="enemy"}',
  );
  const enemies = (await tool("observe", { radius: 16 })).enemies;
  console.log("enemies:", JSON.stringify(enemies));
  assert.equal(enemies.biters, 1);
  assert.ok(enemies.distance >= 6 && enemies.distance <= 9, "distance from the engineer");
  assert.match(enemies.threat, /^close/);
  await lua(
    'local c=game.surfaces[1].find_entities_filtered{type="character"}[1] ' +
      'storage.test_nest=game.surfaces[1].create_entity{name="biter-spawner",position={c.position.x-100,c.position.y},force="enemy"}',
  );
  const nest = (await tool("find", { name: "biter-spawner", limit: 1 })).found[0];
  // Walking up to a nest is refused (its defenders would kill the engineer).
  const toNest = await game.tool("walk_to", { x: nest.position.x + 10, y: nest.position.y });
  console.log("walk to nest:", JSON.stringify(toNest));
  assert.ok(!toNest.ok && /from an enemy biter-spawner/.test(toNest.error), "won't walk next to a nest");
  await lua("storage.test_nest.destroy()");
  console.log("nest:", JSON.stringify(nest));
  assert.match(nest.threat, /^far/, "find labels enemies, and 100 tiles is far");
  const biterDeadline = Date.now() + 20000;
  while ((await lua("rcon.print(storage.test_biter.valid)")).trim() === "true" && Date.now() < biterDeadline) await Bun.sleep(250);
  assert.equal((await lua("rcon.print(storage.test_biter.valid)")).trim(), "false", "the engineer killed the biter");
  // A biter coming close while mining stops the job and sends the engineer back where it started.
  await tool("mine", { name: "wood", count: 200 });
  await Bun.sleep(1000);
  await lua(
    'local c=game.surfaces[1].find_entities_filtered{type="character"}[1] ' +
      'storage.test_biter=game.surfaces[1].create_entity{name="small-biter",position={c.position.x+20,c.position.y},force="enemy"} ' +
      "storage.test_biter.disabled_by_script=true",
  );
  const fled = await waitFor(["job_done", "job_failed"], 30000);
  console.log("fled:", JSON.stringify(fled.data));
  assert.match(JSON.stringify(fled.data), /biters came within/, "mining stops for a biter nearby");
  await lua("if storage.test_biter.valid then storage.test_biter.destroy() end");
  // End to end: an owner message runs a (scripted) Claude turn through the real runner,
  // the job runs in the game, and its job_done event wakes the AI again.
  const api = new FakeAPI([
    // Starting the job ends the turn; the next request is the job_done wake-up.
    { stop_reason: "tool_use", content: [text("Mining 5 iron ore."), call("t1", "mine", { name: "iron-ore", count: 5 })] },
    { stop_reason: "end_turn", content: [text("Done, I have the iron.")] },
  ]);
  const agent = new Agent(api.asAPI(), { model: "opus", effort: "medium" }, mkdtempSync(join(tmpdir(), "aie-e2e-")), "e2e");
  const runner = new Runner(game, agent, (line) => console.log("  runner:", line));
  await runner.tick();
  await game.testMessage("mine 5 iron ore please");
  const deadline = Date.now() + 90000;
  while (api.requests.length < 2 && Date.now() < deadline) {
    await runner.tick();
    await Bun.sleep(300);
  }
  await runner.idle();
  assert.equal(api.requests.length, 2, "the job_done event woke the AI");
  const wake = api.requests[1]!.messages.at(-1).content[0].text as string;
  assert.match(wake, /job_done: mining iron-ore/);
  const inv = await tool("inventory");
  console.log("after e2e:", JSON.stringify(inv.inventory));
  console.log("ALL GAME TESTS PASSED");
} catch (error) {
  console.error(server.log().slice(-3000));
  throw error;
} finally {
  await server.stop();
}
