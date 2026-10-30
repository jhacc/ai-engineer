// Real-game test of keep-busy's pollution watch: a row of iron drills and a (switched-off) biter nest six
// chunks east. Pollution is set by hand, chunk by chunk, to stand in for the cloud spreading toward the
// nest: first gun turret research and turrets on that side, then drills paused (kept built), restarted
// once the cloud pulls back, and all restarted when keep-busy is turned off.
// Usage: bun run test:pollution
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";
import { Game } from "../app/src/game";

const SPEED = Number(process.env.SPEED ?? 10);

const server = await startServer({ port: 34430 });
const game = new Game(server.rcon, "test-app");
const lua = (code: string) => server.rcon.command("/sc " + code);
const tool = async (name: string, args: Record<string, unknown> = {}) => {
  const r = await game.tool(name, args);
  if (!r.ok) throw new Error(`${name} failed: ${r.error}`);
  return r.result as any;
};
// The cloud: chunks 0..k along y=0 (centers at 16 + 32i), below the 15 at which pollution spreads further.
const cloud = (k: number) =>
  lua(`local s=game.surfaces[1] s.clear_pollution() for i=0,${k} do s.set_pollution({16+32*i,16},10) end rcon.print("ok")`);
const paused = async () => Number(await lua(
  'local n=0 for _,d in pairs(game.surfaces[1].find_entities_filtered{type="mining-drill"}) do if d.disabled_by_script then n=n+1 end end rcon.print(n)'));
async function until<T>(what: string, minutes: number, check: () => Promise<T | false | undefined | null>): Promise<T> {
  const start = Date.now();
  while (Date.now() - start < (minutes * 60 * 1000) / SPEED + 5000) {
    await cloudKeep?.();
    const r = await check();
    if (r) return r;
    await Bun.sleep(1000);
  }
  throw new Error(`Timed out waiting for ${what}`);
}
// Set pollution decays and spreads a little; it's set again while waiting.
let cloudKeep: (() => Promise<unknown>) | undefined;

try {
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  // Flat grass with no trees (sparse land), no other enemies, a row of 8 burner iron drills into furnaces,
  // and one nest at chunk (6, 0), switched off so it sends nothing.
  await lua(
    'local s=game.surfaces[1] game.map_settings.enemy_expansion.enabled=false ' +
      'for _,e in pairs(s.find_entities_filtered{force="enemy"}) do e.destroy() end ' +
      's.request_to_generate_chunks({96,0},5) s.force_generate_chunk_requests() ' +
      'for _,e in pairs(s.find_entities_filtered{area={{-64,-64},{256,64}}}) do if e.type~="character" then e.destroy() end end ' +
      'local t={} for x=-64,256 do for y=-64,64 do t[#t+1]={name="grass-1",position={x,y}} end end s.set_tiles(t) ' +
      'for x=8,26 do for y=-2,1 do s.create_entity{name="iron-ore",position={x+0.5,y+0.5},amount=5000} end end ' +
      'for i=0,7 do local x=10+2*i ' +
      '  local d=s.create_entity{name="burner-mining-drill",position={x,0},direction=defines.direction.south,force="player"} ' +
      '  d.insert{name="coal",count=20} ' +
      '  local f=s.create_entity{name="stone-furnace",position={x,2},force="player"} f.insert{name="coal",count=20} end ' +
      'local n=s.create_entity{name="biter-spawner",position={208,16},force="enemy"} n.disabled_by_script=true ' +
      'local f=game.forces.player f.technologies["automation-science-pack"].researched=true ' +
      'f.chart(s,{{-96,-96},{256,96}}) s.clear_pollution() rcon.print("ready")',
  );
  await game.testSpawn({ x: 0, y: 6 });
  await lua(
    'local e=game.surfaces[1].find_entities_filtered{type="character"}[1] ' +
      'for _,i in pairs({{"iron-plate",400},{"copper-plate",100},{"coal",100},{"wood",20}}) do e.insert{name=i[1],count=i[2]} end',
  );
  await lua(`game.speed=${SPEED}`);
  await game.testKeepBusy(true);

  // No pollution: clear.
  const seen = await until("a clear reading", 2, async () => (await tool("observe", { radius: 16 })).pollution);
  console.log("clear:", JSON.stringify(seen));
  assert.match(seen.status, /^clear/);

  // The cloud 5 chunks from the nest: getting ready (turret research first), nothing paused.
  cloudKeep = () => cloud(1);
  const ready = await until("the prepare level", 3, async () => {
    const p = (await tool("observe", { radius: 16 })).pollution;
    return p?.chunks_from_nest === 5 && p;
  });
  console.log("prepare:", JSON.stringify(ready));
  assert.match(ready.status, /spreading/);
  await until("gun turret research", 1, async () => (await lua('rcon.print(tostring(game.forces.player.current_research and game.forces.player.current_research.name))')).trim() === "gun-turret");
  assert.equal(await paused(), 0, "nothing paused while only getting ready");

  // 3 chunks away (closer than the 4 kept clear on bare land without turrets): drills paused, two kept running.
  cloudKeep = () => cloud(3);
  const n = await until("drills paused", 3, async () => (await paused()) || false);
  console.log("paused:", n, JSON.stringify((await tool("observe", { radius: 16 })).pollution));
  assert.equal(n, 3, "three drills paused at a time");
  const drills = Number(await lua('rcon.print(game.surfaces[1].count_entities_filtered{type="mining-drill"})'));
  assert.ok(drills >= 8, "paused drills stay built");

  // Turrets researched (and on hand): two go up between the drills and the nest.
  await lua(
    'game.forces.player.technologies["gun-turret"].researched=true ' +
      'local e=game.surfaces[1].find_entities_filtered{type="character"}[1] e.insert{name="gun-turret",count=2} e.insert{name="firearm-magazine",count=100}',
  );
  // (Distances from the nest; `nearest` is the engineer's building nearest it.)
  const turrets = await until("guard turrets", 5, async () => {
    const t = JSON.parse(await lua(
      'local s,n=game.surfaces[1],{x=208,y=16} local function d(e) return math.sqrt((e.position.x-n.x)^2+(e.position.y-n.y)^2) end ' +
        'local out={turrets={}} for _,t in pairs(s.find_entities_filtered{name="gun-turret"}) do out.turrets[#out.turrets+1]={d=d(t),ammo=t.get_item_count("firearm-magazine")} end ' +
        'for _,b in pairs(s.find_entities_filtered{force="player",type={"mining-drill","furnace","container"}}) do if not out.nearest or d(b)<out.nearest then out.nearest=d(b) end end ' +
        'rcon.print(helpers.table_to_json(out))'));
    return t.turrets.length >= 2 && t.turrets.every((x: any) => x.ammo > 0) && t;
  });
  console.log("turrets:", JSON.stringify(turrets));
  assert.ok(turrets.turrets.every((t: any) => t.d < turrets.nearest && t.d > 44), "turrets between the base and the nest, outside its clearance");

  // The cloud gone: after 5 clear minutes, drills restart one at a time.
  cloudKeep = () => lua('game.surfaces[1].clear_pollution()');
  await cloudKeep();
  const before = await paused();
  const fewer = await until("a drill restarted", 10, async () => {
    const now = await paused();
    return now < before && now + 1;
  });
  console.log("still paused after the first restart:", fewer - 1);

  // No nest known: the cloud is kept inside the revealed map, and the engineer scouts the edge it nears.
  // (A headless server charts nothing, so generated land is what's revealed: chunks east of 4 are
  // deleted, and the cloud reaches chunk 3, two chunks from the edge.)
  await lua(
    'local s=game.surfaces[1] for _,e in pairs(s.find_entities_filtered{force="enemy"}) do e.destroy() end ' +
      'for c in s.get_chunks() do if c.x>=5 then s.delete_chunk({c.x,c.y}) end end rcon.print("ok")',
  );
  cloudKeep = () => cloud(3);
  const edge = await until("an edge reading", 3, async () => {
    const p = (await tool("observe", { radius: 16 })).pollution;
    return p?.chunks_from_edge !== undefined && p;
  });
  console.log("edge:", JSON.stringify(edge));
  assert.match(edge.status, /revealed map/);
  await until("scouting reveals past the edge", 8, async () =>
    (await lua('rcon.print(tostring(game.surfaces[1].is_chunk_generated({6,0})))')).trim() === "true");
  console.log("scouted past the edge");

  // Keep-busy off: every paused drill restarts.
  await game.testKeepBusy(false);
  assert.equal(await paused(), 0, "keep-busy off restarts all paused drills");
  console.log("Pollution test passed.");
} catch (error) {
  console.error(error);
  const seen = await game.tool("observe", { radius: 16 }).catch(() => null);
  if (seen?.ok) console.error("observe:", JSON.stringify(seen.result).slice(0, 3000));
  console.error(server.log().slice(-1500));
  process.exitCode = 1;
} finally {
  await server.stop();
}
