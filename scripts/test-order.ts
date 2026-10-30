// Real-game test of a long order: 100 magazines into a chest (400 iron plates) with nothing making iron.
// The engineer builds 3 iron drill and furnace pairs and a coal loop, then collects for many minutes,
// longer than their first coal lasts: it has to stop to refuel them on the way, then carry on.
// Usage: bun run test:order
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";
import { Game } from "../app/src/game";

const server = await startServer({ port: 34460 });
const game = new Game(server.rcon, "test-app");
const lua = (code: string) => server.rcon.command("/sc " + code);
let after = 0;

try {
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  await lua(
    'local s=game.surfaces[1] s.peaceful_mode=true for _,e in pairs(s.find_entities_filtered{area={{-60,-60},{60,60}}}) do e.destroy() end ' +
      'local t={} for x=-60,60 do for y=-60,60 do t[#t+1]={name="grass-1",position={x,y}} end end s.set_tiles(t) ' +
      'for x=20,34 do for y=0,14 do s.create_entity{name="iron-ore",position={x,y},amount=2000} end end ' +
      'for x=-34,-24 do for y=10,20 do s.create_entity{name="coal",position={x,y},amount=2000} end end ' +
      'for x=-34,-26 do for y=-30,-22 do s.create_entity{name="stone",position={x,y},amount=2000} end end ' +
      's.create_entity{name="wooden-chest",position={5,12},force="player"} rcon.print("ok")',
  );
  await game.testSpawn({ x: 0, y: 0 });
  await lua(
    'local e=game.surfaces[1].find_entities_filtered{type="character"}[1] e.insert{name="burner-mining-drill",count=8} ' +
      'e.insert{name="stone-furnace",count=6} e.insert{name="wooden-chest",count=4} e.insert{name="coal",count=20} rcon.print("ok")',
  );
  await lua("game.speed=8");
  const waiting = await game.tool("insert", { x: 5, y: 12, item: "firearm-magazine", count: 100 });
  assert.ok(!waiting.ok && /3 drills, each with a furnace, for iron-ore/.test(waiting.error), JSON.stringify(waiting));
  let held = false;
  let end: { kind: string; data?: unknown } | undefined;
  const deadline = Date.now() + 600000;
  while (!end && Date.now() < deadline) {
    const poll = await game.poll(after);
    for (const item of poll.items ?? []) {
      after = Math.max(after, item.id);
      if (item.kind === "job_done" || item.kind === "job_failed") end = item;
    }
    held ||= (await lua('__ai-engineer__ for _,r in pairs(storage.engineers) do rcon.print(tostring(r.held_order ~= nil)) end')).trim() === "true";
    await Bun.sleep(1000);
  }
  console.log("order:", JSON.stringify(end));
  assert.equal(end?.kind, "job_done", JSON.stringify(end));
  assert.equal((end?.data as any).result?.inserted, 100, JSON.stringify(end));
  assert.ok(held, "it stopped to refuel the drills and furnaces on the way");

  // Looking after itself: idle with 40 iron plates, it crafts light armor and wears it.
  const engineer = 'local e=game.surfaces[1].find_entities_filtered{type="character"}[1] ';
  await lua(engineer + 'e.insert{name="iron-plate",count=40}');
  await Bun.sleep(3000);
  const armor = await lua(engineer + 'local a=e.get_inventory(defines.inventory.character_armor)[1] rcon.print(a.valid_for_read and a.name or "none")');
  assert.equal(armor.trim(), "light-armor", "crafts and wears light armor");
  // Walking past water with fish, it catches some; hurt, it eats one.
  await lua(
    'local s=game.surfaces[1] local w={} for x=-12,-6 do for y=30,36 do w[#w+1]={name="water",position={x,y}} end end s.set_tiles(w) ' +
      's.create_entity{name="fish",position={-9.5,33.5}}',
  );
  await game.tool("walk_to", { x: -3, y: 33 });
  for (let i = 0; i < 20; i++) {
    const poll = await game.poll(after);
    for (const item of poll.items ?? []) after = Math.max(after, item.id);
    if ((poll.items ?? []).some((item) => item.kind === "job_done" || item.kind === "job_failed")) break;
    await Bun.sleep(500);
  }
  const fish = Number(await lua(engineer + 'rcon.print(e.get_item_count("raw-fish"))'));
  assert.ok(fish >= 2, `catches fish near water (has ${fish})`);
  await lua(engineer + "e.health = 50");
  await Bun.sleep(500);
  const healed = JSON.parse(await lua(engineer + 'rcon.print(helpers.table_to_json({health=e.health, fish=e.get_item_count("raw-fish")}))'));
  assert.ok(healed.health > 100 && healed.fish === fish - 1, `eats a fish when hurt: ${JSON.stringify(healed)}`);
  // The AI can fish too ("mine 2 raw-fish" before going somewhere dangerous).
  await lua(engineer + 'e.remove_item{name="raw-fish",count=100} game.surfaces[1].create_entity{name="fish",position={-10.5,31.5}} e.teleport({0,0})');
  const fishing = await game.tool("mine", { name: "raw-fish", count: 2 });
  assert.ok(fishing.ok, JSON.stringify(fishing));
  let fished: any;
  for (let i = 0; i < 60 && !fished; i++) {
    const poll = await game.poll(after);
    for (const item of poll.items ?? []) {
      after = Math.max(after, item.id);
      if (item.kind === "job_done" || item.kind === "job_failed") fished = item;
    }
    await Bun.sleep(500);
  }
  assert.equal(fished?.kind, "job_done", JSON.stringify(fished));
  console.log("ORDER TEST PASSED");
} catch (error) {
  console.error(server.log().slice(-3000));
  throw error;
} finally {
  await server.stop();
}
