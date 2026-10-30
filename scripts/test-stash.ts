// Real-game test of keep-busy's storage: with the engineer's inventory nearly full of ore, it builds an iron
// chest near home and puts the ore in it.
// Usage: bun run test:stash
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";
import { Game } from "../app/src/game";

const server = await startServer({ port: 34450 });
const game = new Game(server.rcon, "test-app");
const lua = (code: string) => server.rcon.command("/sc " + code);

try {
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  // Flat grass with no ore, so the build order has nothing to start on.
  await lua(
    'local s=game.surfaces[1] s.peaceful_mode=true for _,e in pairs(s.find_entities_filtered{area={{-60,-60},{60,60}}}) do e.destroy() end ' +
      'local t={} for x=-60,60 do for y=-60,60 do t[#t+1]={name="grass-1",position={x,y}} end end s.set_tiles(t) rcon.print("ok")',
  );
  await game.testSpawn({ x: 0, y: 0 });
  // Iron plates for the chest, then ore filling all but 3 slots.
  const inventory = () =>
    lua(
      'local e=game.surfaces[1].find_entities_filtered{type="character"}[1] local inv=e.get_main_inventory() ' +
        'rcon.print(helpers.table_to_json({free=inv.count_empty_stacks(),ore=e.get_item_count("iron-ore")+e.get_item_count("copper-ore")}))',
    ).then((s) => JSON.parse(s) as { free: number; ore: number });
  await lua(
    'local e=game.surfaces[1].find_entities_filtered{type="character"}[1] e.insert{name="iron-plate",count=20} ' +
      'local inv=e.get_main_inventory() local i=0 while inv.count_empty_stacks()>3 do ' +
      'e.insert{name=(i%2==0) and "iron-ore" or "copper-ore",count=50} i=i+1 end rcon.print("ok")',
  );
  console.log("before:", JSON.stringify(await inventory()));
  await lua("game.speed=10");
  await game.testKeepBusy(true);
  // Once started it puts all of the ore away, a chest at a time (3650 ore fills two and a bit).
  let chest: { n: number; ore: number } = { n: 0, ore: 0 };
  // (The build order may smelt a few itself, in a furnace fed by hand.)
  for (let i = 0; i < 90 && chest.ore < 3600; i++) {
    await Bun.sleep(1000);
    chest = JSON.parse(
      await lua(
        'local c={n=0,ore=0} for _,ch in pairs(game.surfaces[1].find_entities_filtered{name="iron-chest"}) do c.n=c.n+1 ' +
          'c.ore=c.ore+ch.get_item_count("iron-ore")+ch.get_item_count("copper-ore") end rcon.print(helpers.table_to_json(c))',
      ),
    );
  }
  const after = await inventory();
  console.log("chest:", JSON.stringify(chest), "after:", JSON.stringify(after));
  assert.ok(chest.n >= 3 && chest.ore >= 3600, "iron chests were built and all the ore put in them");
  assert.ok(after.free >= 6 && after.ore === 0, "the inventory has room again, with no ore in it");
  console.log("STASH TEST PASSED");
} catch (error) {
  console.error(server.log().slice(-3000));
  throw error;
} finally {
  await server.stop();
}
