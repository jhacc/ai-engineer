// Real-game test of choosing which way the smelting columns and main bus face (stage 3 of the layout
// plan): on flat grass, iron, copper and coal fields in a row with a lake over all the land east of them,
// so a bus running east (the old fixed layout) would run into water. The ore lines are planned (not
// built) and the frame they chose must keep the bus's whole area dry; then, with an enemy nest placed on
// the dry side the first plan used, the second plan's bus must be further from it.
// Usage: bun run test:layout-dir
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";
import { Game } from "../app/src/game";

const server = await startServer({ port: 34436 });
const game = new Game(server.rcon, "test-app");
const lua = (code: string) => server.rcon.command("/sc " + code);
const modLua = (code: string) => server.rcon.command("/sc __ai-engineer__ " + code);
const MODS =
  'local ap, bus, frame for k,v in pairs(package.loaded) do if k:find("scripts.autopilot") then ap=v elseif k:find("scripts.bus") then bus=v elseif k:find("scripts.frame") then frame=v end end ';

// Plans the ore lines a step at a time and returns where the bus went and what's under it.
const planLines = async (nest: { x: number; y: number } | null) => {
  const started = await modLua(
    MODS +
      'local rec=storage.engineers[0] rec.auto=rec.auto or {fails={},skip={},skipped={}} rec.auto.home={x=-60,y=15} ' +
      (nest ? `rec.pollution={nearest={x=${nest.x},y=${nest.y}}} ` : "rec.pollution=nil ") +
      'rec.auto.lines_work=ap.lines_plan(rec, ap.survey(rec)) rcon.print(rec.auto.lines_work.done and ("done early: "..tostring(rec.auto.lines_work.why)) or "ok")',
  );
  if (started.trim() !== "ok") throw new Error(started);
  for (let i = 0; i < 2000; i++) {
    const r = await modLua(MODS + 'local rec=storage.engineers[0] local w=rec.auto.lines_work for i=1,10 do if w.done then break end ap.lines_step(rec) end rcon.print(w.done and "done" or w.stage)');
    if (r.trim() === "done") break;
  }
  return JSON.parse(
    await modLua(
      MODS +
        'local rec=storage.engineers[0] local w=rec.auto.lines_work local out={why=w.why} ' +
        'if w.plan then local g=w.plan.frame local m=g.m or frame.IDENTITY ' +
        'local ux,uy=frame.vec(m,1,0) local sx,sy=frame.vec(m,0,1) out.run=({[0]="north","east","south","west"})[frame.dir(m,1)] out.side={sx,sy} ' +
        'local a=bus.area(g) local box={{a.left_top.x,a.left_top.y},{a.right_bottom.x,a.right_bottom.y}} ' +
        'local s=game.surfaces[1] out.water=s.count_tiles_filtered{area=box,collision_mask="water_tile"} ' +
        'out.bus_mid={x=(box[1][1]+box[2][1])/2,y=(box[1][2]+box[2][2])/2} ' +
        // Planned parts other than the layout's own and poles inside the bus's area (ore belts crossing it).
        'out.crossing=0 ' +
        'for _,pl in ipairs(w.plan.places) do local p=pl[2].position local sb=w.plan.box ' +
        'local in_bus=p.x>box[1][1] and p.x<box[2][1] and p.y>box[1][2] and p.y<box[2][2] ' +
        'local in_smelter=p.x>sb.left_top.x and p.x<sb.right_bottom.x and p.y>sb.left_top.y and p.y<sb.right_bottom.y ' +
        'if in_bus and not in_smelter and pl[1]~="small-electric-pole" then out.crossing=out.crossing+1 end end ' +
        'local sb=w.plan.box out.smelter_mid={x=(sb.left_top.x+sb.right_bottom.x)/2,y=(sb.left_top.y+sb.right_bottom.y)/2} end ' +
        'out.sites={} for _,st in ipairs(w.sites or {}) do out.sites[#out.sites+1]=string.format("%s %d,%d score %.0f",({[0]="N","E","S","W"})[frame.dir(st.frame.m or frame.IDENTITY,1)],st.x0,st.y0,st.score) end ' +
        'rec.auto.lines_work=nil rcon.print(helpers.table_to_json(out))',
    ),
  ) as { why?: string; run?: string; side?: number[]; water?: number; crossing?: number; bus_mid?: { x: number; y: number }; smelter_mid?: { x: number; y: number } };
};

try {
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  // Flat grass; three fields side by side west of the middle; water over everything from x = -20 east.
  await lua(
    'local s=game.surfaces[1] s.peaceful_mode=true for _,e in pairs(s.find_entities_filtered{area={{-200,-200},{200,200}}}) do e.destroy() end ' +
      'local t={} for x=-200,200 do for y=-200,200 do t[#t+1]={name=x>=-20 and "water" or "grass-1",position={x,y}} end end s.set_tiles(t) ' +
      'for _,f in pairs({{"iron-ore",-25},{"coal",5},{"copper-ore",35}}) do for x=-80,-61 do for y=f[2],f[2]+19 do ' +
      's.create_entity{name=f[1],position={x+0.5,y+0.5},amount=5000} end end end ' +
      // A power network near the middle (an energy interface counts as a power source).
      's.create_entity{name="electric-energy-interface",position={-45,-40},force="player"} ' +
      's.create_entity{name="small-electric-pole",position={-42.5,-40.5},force="player"} ' +
      'local f=game.forces.player f.research_all_technologies() rcon.print("ok")',
  );
  await game.testSpawn({ x: -60, y: 60 });

  const first = await planLines(null);
  console.log("planned:", JSON.stringify(first));
  assert.ok(first.run, "the ore lines were planned: " + first.why);
  assert.equal(first.water, 0, "the bus's area keeps clear of the lake");
  assert.notEqual(first.run, "east", "the bus doesn't run east into the lake");
  assert.equal(first.crossing, 0, "no ore belt crosses the bus's area");

  // A nest out past where that bus went: planned again, the bus keeps further from it.
  const away = { x: first.bus_mid!.x + (first.bus_mid!.x - first.smelter_mid!.x) * 2, y: first.bus_mid!.y + (first.bus_mid!.y - first.smelter_mid!.y) * 2 };
  const second = await planLines(away);
  console.log("with a nest at", JSON.stringify(away), "planned:", JSON.stringify(second));
  assert.ok(second.run, "planned again with the nest: " + second.why);
  assert.equal(second.water, 0, "still clear of the lake");
  assert.equal(second.crossing, 0, "nothing crosses the bus's area");
  const d = (p: { x: number; y: number }) => Math.hypot(p.x - away.x, p.y - away.y);
  assert.ok(d(second.bus_mid!) > d(first.bus_mid!), "the bus moved away from the nest");
  console.log("LAYOUT DIRECTION TEST PASSED");
} finally {
  await server.stop();
}
