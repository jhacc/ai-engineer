// Real-game test of the main bus facing another way (frame.lua): the bus's start (two plate belts and the
// coal belt, fed by loaders from infinity chests) laid out in a turned or mirrored frame, then the owner's
// electronic-circuit goal and red and green science built beside it, packs reaching the labs by belt.
// Checked by counts, not map positions, so it holds for any frame.
// Usage: bun run test:bus-turned (BUS_DIR 0-3, the way the bus runs, default 2; BUS_MIRROR=1 puts the
// sub-factories on its other side)
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";
import { Game } from "../app/src/game";

const SPEED = Number(process.env.SPEED ?? 10);
const MAX_MINUTES = Number(process.env.MAX_MINUTES ?? 25);
const DIR = Number(process.env.BUS_DIR ?? 2);
const MIRROR = process.env.BUS_MIRROR === "1";

const server = await startServer({ port: 34432 });
const game = new Game(server.rcon, "test-app");
const lua = (code: string) => server.rcon.command("/sc " + code);
const modLua = (code: string) => server.rcon.command("/sc __ai-engineer__ " + code);
const tool = async (name: string, args: Record<string, unknown> = {}) => {
  const r = await game.tool(name, args);
  if (!r.ok) throw new Error(`${name} failed: ${r.error}`);
  return r.result as any;
};
const gameMinutes = async () => Number(await lua("rcon.print(game.tick)")) / 3600;
// The mod's frame and bus modules, inside a mod-side command.
const MODS =
  'local bus, frame for k,v in pairs(package.loaded) do if k:find("scripts.bus") then bus=v elseif k:find("scripts.frame") then frame=v end end ';

try {
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  await lua(
    'local s=game.surfaces[1] s.peaceful_mode=true for _,e in pairs(s.find_entities_filtered{area={{-130,-130},{130,130}}}) do e.destroy() end ' +
      'local t={} for x=-130,130 do for y=-130,130 do t[#t+1]={name="grass-1",position={x,y}} end end s.set_tiles(t) ' +
      'local f=game.forces.player for _,n in pairs({"steam-power","electronics","automation-science-pack","automation","logistics","logistic-science-pack"}) do f.technologies[n].researched=true end ' +
      'f.chart(s,{{-160,-160},{160,160}}) rcon.print("ok")',
  );
  // The frame's origin is placed so the bus and its sub-factories run across the cleared square.
  const FRAME =
    MODS +
    `local m=frame.make(${DIR}, ${MIRROR}) local o=frame.at(m,{x=0,y=0},-60,-20) ` +
    'local g={x0=o.x,y0=o.y,X=12,width=11,turned=true,m=m} local s=game.surfaces[1] ' +
    'local taps={bus.tile(g,g.X+2,2),bus.tile(g,g.X-1,9)} ';
  const setup = await modLua(
    FRAME +
      'local function put(name,tx,ty,d,typ) return s.create_entity{name=name,position=bus.tile(g,tx,ty),direction=d and bus.dir(g,d)*4 or nil,type=typ,force="player"} end ' +
      // The bus's start: the top plates (iron) on row 5, coal on 6, the bottom plates (copper) on 7.
      'for _,r in pairs({{5,"iron-plate"},{7,"copper-plate"}}) do local c=put("infinity-chest",g.X-2,r[1]) c.set_infinity_container_filter(1,{name=r[2],count=100}) ' +
      'put("loader-1x1",g.X-1,r[1],1,"output") put("transport-belt",g.X,r[1],1) end put("transport-belt",g.X,6,1) ' +
      'for _,p in pairs(taps) do s.create_entity{name="wooden-chest",position=p,force="player"} end ' +
      'local eei=s.create_entity{name="electric-energy-interface",position=bus.tile(g,g.X-4,8),force="player"} eei.power_production=10000000/60 eei.electric_buffer_size=100000000 ' +
      'put("small-electric-pole",g.X-2,9) ' +
      'local spawn=bus.tile(g,g.X+6,-6) rcon.print(helpers.table_to_json(spawn))',
  );
  if (!setup.startsWith("{")) throw new Error(setup);
  const spawn = JSON.parse(setup);
  console.log(`bus running ${["north", "east", "south", "west"][DIR]}${MIRROR ? ", mirrored" : ""}`);
  await game.testSpawn(spawn);
  // The ore lines' plan as it's stored once they're built (the spawn made the engineer's record).
  const planned = await modLua(
    FRAME +
      'local rec=storage.engineers[0] rec.auto=rec.auto or {fails={},skip={},skipped={}} ' +
      'rec.auto.ore_plan={done=true,frame=g,site={x=g.x0,y=g.y0},chests=taps,parts={},places={},box=bus.box(g,-3,-12,g.X+1,11)} rcon.print("ok")',
  );
  if (planned.trim() !== "ok") throw new Error(planned);
  await lua(
    'local e=game.surfaces[1].find_entities_filtered{type="character"}[1] ' +
      'for _,i in pairs({{"iron-plate",2500},{"copper-plate",1000},{"wood",60}}) do e.insert{name=i[1],count=i[2]} end rcon.print("ok")',
  );
  let after = (await game.poll(0)).seq ?? 0;
  await lua(`game.speed=${SPEED}`);

  let last = "";
  let buildAfter = 0;
  const runGoal = async (args: Record<string, unknown>) => {
    const goal = await tool("goal", args);
    assert.equal(goal.status, "ACTIVE", String(goal.reason));
    const started = await gameMinutes();
    let done: any = null;
    while (!done) {
      await Bun.sleep(2000);
      const poll = await game.poll(after, { buildAfter });
      for (const item of poll.items ?? []) {
        after = Math.max(after, item.id);
        if ((item.kind === "goal_done" || item.kind === "goal_blocked") && item.data?.goal === goal.id) done = item;
      }
      for (const l of poll.build_log ?? []) {
        console.log("    " + l.text);
        buildAfter = Math.max(buildAfter, l.n);
      }
      const seen = await tool("observe", { radius: 32 });
      const line = `${seen.engineer.job?.doing ?? "-"} | ${(seen.engineer.goals ?? []).join(" / ")}`;
      const minutes = (await gameMinutes()) - started;
      if (line !== last) console.log(`[${minutes.toFixed(1)} min] ${line}`);
      last = line;
      if (minutes > MAX_MINUTES) throw new Error(`The ${args.item} goal wasn't done within ${MAX_MINUTES} game minutes`);
    }
    console.log("event:", JSON.stringify(done));
    assert.equal(done.kind, "goal_done", JSON.stringify(done.data));
  };

  await runGoal({ item: "electronic-circuit", per_minute: 15 });
  await runGoal({ item: "automation-science-pack", per_minute: 5 });
  await runGoal({ item: "logistic-science-pack", per_minute: 5 });
  await Bun.sleep(5000);
  const c = JSON.parse(
    await lua(
      'local s=game.surfaces[1] local c={splitters=0,paired=0,belt_fed=0,labs=0,lab_fed=0,red=0,green=0,mixed=0} ' +
        'c.splitters=#s.find_entities_filtered{name="splitter"} ' +
        'for _,u in pairs(s.find_entities_filtered{name="underground-belt"}) do if u.underground_belt_neighbour then c.paired=c.paired+1 end end ' +
        'for _,i in pairs(s.find_entities_filtered{name="inserter"}) do local p,d=i.pickup_target,i.drop_target ' +
        'if p and d and p.type=="transport-belt" and d.type=="assembling-machine" then c.belt_fed=c.belt_fed+1 end ' +
        'if p and d and p.type=="transport-belt" and d.type=="lab" then c.lab_fed=c.lab_fed+1 end end ' +
        'for _,l in pairs(s.find_entities_filtered{name="lab"}) do c.labs=c.labs+1 local inv=l.get_inventory(defines.inventory.lab_input) ' +
        'c.red=c.red+inv.get_item_count("automation-science-pack") c.green=c.green+inv.get_item_count("logistic-science-pack") end ' +
        'for _,b in pairs(s.find_entities_filtered{type="transport-belt"}) do for l=1,2 do local line=b.get_transport_line(l) ' +
        'if line.get_item_count("automation-science-pack")>0 and line.get_item_count("logistic-science-pack")>0 then c.mixed=c.mixed+1 end end end ' +
        'rcon.print(helpers.table_to_json(c))',
    ),
  );
  console.log("built:", JSON.stringify(c));
  assert.ok(c.splitters >= 4, "a splitter on each plate belt for each slot used");
  assert.ok(c.paired >= 2, "the top plates go under the bus by paired underground belts");
  assert.ok(c.belt_fed >= 3, "inserters feed the assemblers from the feeder belts");
  assert.equal(c.labs, 3, "three labs beside the bus's start");
  assert.ok(c.lab_fed >= 3, "each lab has an inserter off the science belt");
  assert.ok(c.red > 0 && c.green > 0, "red and green packs reach the labs by belt");
  assert.equal(c.mixed, 0, "red and green ride on separate lanes of the science belt");
  console.log("TURNED BUS TEST PASSED");
} catch (error) {
  console.error(server.log().slice(-3000));
  throw error;
} finally {
  await server.stop();
}
