// Real-game test of the smelting area growing with demand (stage 4 of the layout plan): on flat grass with
// big iron, coal and copper fields, the ore lines are planned and built at once (by script, not by the
// engineer), and everything reaching the end of the bus's plate rows is taken away (loaders into infinity
// chests that delete it). The furnaces then run flat out, so grow_smelting adds two furnaces to a column
// and makes its field longer to match; a copper drill whose ore is used up is picked up and replaced
// further up its line. Its jobs are carried out by script too.
// Usage: bun run test:grow
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";
import { Game } from "../app/src/game";

const server = await startServer({ port: 34438 });
const game = new Game(server.rcon, "test-app");
const lua = (code: string) => server.rcon.command("/sc " + code);
const modLua = (code: string) => server.rcon.command("/sc __ai-engineer__ " + code);
const MODS =
  'local ap, bus for k,v in pairs(package.loaded) do if k:find("scripts.autopilot") then ap=v elseif k:find("scripts.bus") then bus=v end end ' +
  "local rec=storage.engineers[0] local s=rec.entity.surface local st=rec.auto ";
// Carries out a job's steps at once: places what it places (registered as the engineer's), picks up
// what it picks up.
const RUN =
  "local function run(job) local out={} for _,step in ipairs(job.args.steps) do " +
  'if step.action=="place" then local name=prototypes.item[step.item].place_result.name ' +
  'local e=s.create_entity{name=name,position={step.x,step.y},direction=step.direction and step.direction*4 or nil,type=step.belt_type,force="player",raise_built=false} ' +
  'if e then rec.built[e.unit_number]=e rec.entity.remove_item{name=step.item,count=1} else out[#out+1]="couldn\'t place "..step.item.." at "..step.x..","..step.y end ' +
  'elseif step.action=="pick_up" then for _,e in pairs(s.find_entities_filtered{position={step.x,step.y},radius=0.3}) do if e.type~="resource" then e.destroy() end end end end return out end ';
// The ore lines' furnaces and drills, by ore.
const COUNT =
  "local plan=st.ore_plan local c={furnaces={},drills={},working=0} " +
  'for _,e in pairs(rec.built) do if e.valid and plan.parts[math.floor(e.position.x)..","..math.floor(e.position.y)]==e.name then ' +
  'if e.type=="furnace" then local fx=bus.where(plan.frame,e.position) local ore=(fx<plan.frame.hook)==(not plan.layout.flip) and "iron" or "copper" c.furnaces[ore]=(c.furnaces[ore] or 0)+1 if e.status==defines.entity_status.working then c.working=c.working+1 end ' +
  'elseif e.type=="mining-drill" then local r=next(e.surface.find_entities_filtered{type="resource",position=e.position,radius=1.4}) local ore=e.mining_target and e.mining_target.name or "?" c.drills[ore]=(c.drills[ore] or 0)+1 end end end ';

// (An empty Lua table comes back as {}, not [].)
const list = (v: unknown) => (Array.isArray(v) ? v : []);
type Counts = { furnaces: Record<string, number>; drills: Record<string, number>; working: number };
const counts = async () => JSON.parse(await modLua(MODS + COUNT + "rcon.print(helpers.table_to_json(c))")) as Counts;

// Calls grow_smelting until it has nothing more to do, carrying out its jobs; returns what they were.
const grow = async () => {
  const done: string[] = [];
  for (let i = 0; i < 40; i++) {
    const r = JSON.parse(
      await modLua(
        MODS + RUN +
          "local job, why = ap.grow_smelting(rec, ap.survey(rec), false) " +
          'if not job then rcon.print(helpers.table_to_json({why=why or "", growing=st.growing and st.growing.describe or "", blocked=st.grow_blocked, samples=st.grow_samples and st.grow_samples.samples or 0})) return end ' +
          "local fails = run(job) rcon.print(helpers.table_to_json({describe=job.describe, fails=fails}))",
      ),
    ) as { describe?: string; fails?: string[]; why?: string; growing?: string };
    if (!r.describe) {
      console.log("  grow_smelting: nothing more", JSON.stringify(r));
      if (r.growing) throw new Error("growing stopped with " + r.growing + " under way: " + r.why);
      break;
    }
    assert.deepEqual(list(r.fails), [], "every part of '" + r.describe + "' placed");
    if (!done.includes(r.describe)) done.push(r.describe);
  }
  return done;
};

// Runs the game for `seconds` (real time, at the game speed set below), sampling the furnaces as
// keep-busy does.
const run = async (seconds: number) => {
  for (let i = 0; i < seconds; i++) {
    await Bun.sleep(1000);
    await modLua(MODS + "ap.smelting_sample(rec) rcon.print(st.grow_samples and st.grow_samples.samples or 0)");
  }
};

try {
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  await lua(
    'local s=game.surfaces[1] s.peaceful_mode=true for _,e in pairs(s.find_entities_filtered{area={{-250,-250},{250,250}}}) do e.destroy() end ' +
      'local t={} for x=-250,250 do for y=-250,250 do t[#t+1]={name="grass-1",position={x,y}} end end s.set_tiles(t) ' +
      'for _,f in pairs({{"iron-ore",-60},{"coal",-14},{"copper-ore",32}}) do for x=-110,-71 do for y=f[2],f[2]+39 do ' +
      's.create_entity{name=f[1],position={x+0.5,y+0.5},amount=20000} end end end ' +
      'local eei=s.create_entity{name="electric-energy-interface",position={-45,-70},force="player"} eei.power_production=50000000/60 eei.electric_buffer_size=500000000 ' +
      // (Growing waits for spare engine power: an idle engine, unconnected, reads as plenty.)
      's.create_entity{name="steam-engine",position={-40,80},force="player"} ' +
      's.create_entity{name="small-electric-pole",position={-42.5,-70.5},force="player"} ' +
      'game.forces.player.research_all_technologies() rcon.print("ok")',
  );
  await game.testSpawn({ x: -60, y: 90 });

  // Plan the ore lines a step at a time.
  const started = await modLua(
    MODS +
      'rec.auto=rec.auto or {fails={},skip={},skipped={}} st=rec.auto st.home={x=-60,y=15} rec.pollution=nil ' +
      'st.lines_work=ap.lines_plan(rec, ap.survey(rec)) rcon.print(st.lines_work.done and ("done early: "..tostring(st.lines_work.why)) or "ok")',
  );
  assert.equal(started.trim(), "ok", started);
  for (let i = 0; i < 2000; i++) {
    const r = await modLua(MODS + "local w=st.lines_work for i=1,10 do if w.done then break end ap.lines_step(rec) end rcon.print(w.done and \"done\" or w.stage)");
    if (r.trim() === "done") break;
  }
  // Built at once, and the plates taken off the end of the bus as fast as they come.
  const built = JSON.parse(
    await modLua(
      MODS +
        'local w=st.lines_work st.lines_work=nil if not w.plan then rcon.print(helpers.table_to_json({why=w.why})) return end ' +
        "local plan=w.plan st.ore_plan=plan rec.built=rec.built or {} local failed={} " +
        "for _,pl in ipairs(plan.places) do local name=prototypes.item[pl[1]].place_result.name local at=pl[2] " +
        'local e=s.create_entity{name=name,position=at.position,direction=at.direction and at.direction*4 or nil,type=at.belt_type,force="player",raise_built=false} ' +
        'if e then rec.built[e.unit_number]=e else failed[#failed+1]=name.."@"..serpent.line(at.position) end end ' +
        "plan.done=true local g=plan.frame " +
        'for _,row in ipairs({5,7}) do local p=bus.tile(g,g.X+1,row) local l=s.create_entity{name="loader-1x1",position=p,direction=bus.dir(g,1)*4,type="input",force="player"} ' +
        'local q=bus.tile(g,g.X+2,row) local c=s.create_entity{name="infinity-chest",position=q,force="player"} c.remove_unfiltered_items=true end ' +
        'for _,item in ipairs({"stone-furnace","inserter","long-handed-inserter","transport-belt","small-electric-pole","electric-mining-drill","wooden-chest","splitter","underground-belt"}) do rec.entity.insert{name=item,count=200} end ' +
        "game.speed=20 rcon.print(helpers.table_to_json({failed=failed, layout=plan.layout, fields=plan.fields}))",
    ),
  ) as { why?: string; failed?: string[]; layout?: unknown };
  assert.ok(built.layout, "the ore lines were planned, with their layout kept: " + built.why);
  assert.deepEqual(list(built.failed), [], "every part of the ore lines placed");
  const before = await counts();
  console.log("built:", JSON.stringify(before));

  // Once ore and coal reach every furnace, flat out for 5 game minutes: the iron and copper columns get
  // longer, their fields too.
  await run(12);
  await modLua(MODS + "st.grow_samples=nil rcon.print('ok')");
  await run(40);
  console.log("samples:", await modLua(MODS + "rcon.print(helpers.table_to_json(st.grow_samples or {}))"), "game tick", await lua("rcon.print(game.tick)"));
  const grown = await grow();
  console.log("grew:", JSON.stringify(grown));
  const after = await counts();
  console.log("after:", JSON.stringify(after));
  assert.ok(after.furnaces.iron! > before.furnaces.iron!, "the iron column got longer");
  assert.ok(after.drills["iron-ore"]! > before.drills["iron-ore"]!, "the iron field got more drills to match");
  // The new furnaces get ore and coal and work.
  await run(15);
  const running = await counts();
  console.log("running:", JSON.stringify(running));
  const total = Object.values(running.furnaces).reduce((a, b) => a + b, 0);
  assert.ok(running.working >= total - 2, `nearly every furnace works (${running.working} of ${total})`);

  // A copper drill runs out: it's picked up, and the copper line gets one further up.
  const dried = await modLua(
    MODS +
      'local plan=st.ore_plan for _,e in pairs(rec.built) do if e.valid and e.name=="electric-mining-drill" and e.mining_target and e.mining_target.name=="copper-ore" then ' +
      'for _,r in pairs(s.find_entities_filtered{type="resource",area={{e.position.x-2.5,e.position.y-2.5},{e.position.x+2.5,e.position.y+2.5}}}) do r.destroy() end ' +
      'rcon.print(e.position.x..","..e.position.y) return end end rcon.print("none")',
  );
  assert.notEqual(dried.trim(), "none", "found a copper drill to run dry");
  const copper = (await counts()).drills["copper-ore"] ?? 0;
  await run(3);
  const replaced = await grow();
  console.log("after the copper ran out:", JSON.stringify(replaced));
  assert.ok(replaced.some((d) => /ran out/.test(d)), "the dry drill was picked up");
  assert.ok(replaced.some((d) => /copper-ore line longer/.test(d)), "the copper line got longer to make up for it");
  const last = await counts();
  console.log("last:", JSON.stringify(last));
  assert.ok((last.drills["copper-ore"] ?? 0) >= copper, "the copper line has as many drills as before");
  const gone = await modLua(MODS + `rcon.print(s.count_entities_filtered{name="electric-mining-drill",position={${dried.trim()}},radius=0.5})`);
  assert.equal(gone.trim(), "0", "the dry drill is gone");
  console.log("GROW TEST PASSED");
} finally {
  await server.stop();
}
