// Real-game test of the ore lines' belt routing: a belt from one side of a wall of belts (like the coal belt
// to the boilers, crossing the way) to the other. Without underground belts there's no way through; with
// them the route goes under the wall, and ore put on its start comes out at its end.
// Usage: bun run test:route
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";

const server = await startServer({ port: 34440 });
const lua = (code: string) => server.rcon.command("/sc " + code);
const modLua = (code: string) => server.rcon.command("/sc __ai-engineer__ " + code);

try {
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  // Flat grass; a wall of belts running north along x=0 the whole height of the search area, and a row of
  // chests beside it (something solid, three tiles thick with the belt).
  await lua(
    'local s=game.surfaces[1] s.peaceful_mode=true for _,e in pairs(s.find_entities_filtered{area={{-80,-80},{80,80}}}) do e.destroy() end ' +
      'local t={} for x=-80,80 do for y=-80,80 do t[#t+1]={name="grass-1",position={x,y}} end end s.set_tiles(t) ' +
      'for y=-45,45 do s.create_entity{name="transport-belt",position={0.5,y+0.5},direction=defines.direction.north,force="player"} ' +
      'for _,x in pairs({1.5,2.5}) do s.create_entity{name="wooden-chest",position={x,y+0.5},force="player"} end end rcon.print("ok")',
  );
  // belt_route(e, from, from_dir, to, to_dir, keep_out, reserved, ug): directions 0-3 are N, E, S, W.
  const route = (ug: boolean) =>
    modLua(
      'local m for k,v in pairs(package.loaded) do if k:find("autopilot") then m=v end end local r, why = m.belt_route({surface=game.surfaces[1]}, {x=-10,y=0}, 1, {x=12,y=0}, 1, {}, {}, ' +
        ug + ') rcon.print(helpers.table_to_json({route=r, why=why}))',
    ).then((s) => {
      if (!s.startsWith("{")) throw new Error(s);
      return JSON.parse(s);
    }) as Promise< { route?: { position: { x: number; y: number }; direction: number; item?: string; belt_type?: string }[]; why?: string }>;

  const without = await route(false);
  console.log("without underground belts:", without.why);
  assert.ok(!without.route, "no way over the wall without underground belts");

  const withUg = await route(true);
  assert.ok(withUg.route, String(withUg.why));
  const unders = withUg.route!.filter((b) => b.item === "underground-belt");
  console.log("route:", withUg.route!.length, "pieces,", JSON.stringify(unders));
  assert.equal(unders.length, 2, "one pair of underground belts");
  assert.deepEqual(unders.map((b) => b.belt_type), ["input", "output"]);
  assert.ok(unders[0]!.position.x < 0.5 && unders[1]!.position.x > 2.5, "the pair goes under the wall");

  // Built as planned, it carries ore from start to end.
  await lua(
    `local s=game.surfaces[1] for _,b in pairs(helpers.json_to_table('${JSON.stringify(withUg.route)}')) do ` +
      's.create_entity{name=b.item or "transport-belt",position=b.position,direction=b.direction*4,type=b.belt_type,force="player"} end ' +
      's.find_entities_filtered{position={-9.5,0.5},type="transport-belt"}[1].get_transport_line(1).insert_at_back({name="iron-ore",count=1}) ' +
      'game.speed=10 rcon.print("ok")',
  );
  let arrived = 0;
  for (let i = 0; i < 20 && arrived === 0; i++) {
    await Bun.sleep(500);
    arrived = Number(
      await lua(
        'local b=game.surfaces[1].find_entities_filtered{position={12.5,0.5},type="transport-belt"}[1] ' +
          'rcon.print(b.get_transport_line(1).get_item_count()+b.get_transport_line(2).get_item_count())',
      ),
    );
  }
  assert.ok(arrived > 0, "the ore reached the end of the belt");
  console.log("ROUTE TEST PASSED");
} catch (error) {
  console.error(server.log().slice(-3000));
  throw error;
} finally {
  await server.stop();
}
