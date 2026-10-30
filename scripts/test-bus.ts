// Real-game test of the main bus: with a smelting area's plate belts in place (as the ore lines leave them,
// each ending in an inserter and chest, fed here from infinity chests by loaders), the owner's goal is built as a
// sub-factory beside the bus: the old belt ends cleared, the belts turned in and carried on as the bus,
// splitters and an underground belt bringing both plates onto one feeder belt, and inserters from it into
// the assemblers. Done once the goal's output is measured, with plates having come by belt.
// Usage: bun run test:bus
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";
import { Game } from "../app/src/game";

const SPEED = Number(process.env.SPEED ?? 10);
const MAX_MINUTES = Number(process.env.MAX_MINUTES ?? 25);
// The smelting area's top left tile, and its rows' furnace counts (copper on top, iron below).
const X0 = -40, Y0 = -20, TOP = 3, BOTTOM = 6;

const server = await startServer({ port: 34430 });
const game = new Game(server.rcon, "test-app");
const lua = (code: string) => server.rcon.command("/sc " + code);
const modLua = (code: string) => server.rcon.command("/sc __ai-engineer__ " + code);
const tool = async (name: string, args: Record<string, unknown> = {}) => {
  const r = await game.tool(name, args);
  if (!r.ok) throw new Error(`${name} failed: ${r.error}`);
  return r.result as any;
};
const gameMinutes = async () => Number(await lua("rcon.print(game.tick)")) / 3600;

try {
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  // Flat grass with no ore or biters; the smelting area's belts with plates coming from infinity chests by
  // fast inserters, powered by an energy interface.
  await lua(
    'local s=game.surfaces[1] s.peaceful_mode=true for _,e in pairs(s.find_entities_filtered{area={{-100,-100},{100,100}}}) do e.destroy() end ' +
      'local t={} for x=-100,100 do for y=-100,100 do t[#t+1]={name="grass-1",position={x,y}} end end s.set_tiles(t) ' +
      `local x0,y0=${X0},${Y0} local function at(tx,ty) return {x0+tx+0.5,y0+ty+0.5} end ` +
      'local function put(name,tx,ty,dir) return s.create_entity{name=name,position=at(tx,ty),direction=dir,force="player"} end ' +
      'local E=defines.direction.east ' +
      `for tx=0,${3 * TOP - 1} do put("transport-belt",tx,0,E) end put("inserter",${3 * TOP},0,defines.direction.west) put("wooden-chest",${3 * TOP + 1},0) ` +
      `for tx=0,${3 * BOTTOM - 1} do put("transport-belt",tx,12,E) put("transport-belt",tx,6,E) end ` +
      `put("inserter",${3 * BOTTOM},12,defines.direction.west) local old=put("wooden-chest",${3 * BOTTOM + 1},12) old.insert{name="iron-plate",count=50} ` +
      'for _,r in pairs({{0,"copper-plate"},{12,"iron-plate"}}) do local c=put("infinity-chest",-2,r[1]) c.set_infinity_container_filter(1,{name=r[2],count=100}) ' +
      // A loader (a full belt's worth; with five sub-factories an inserter's trickle starves the last ones).
      's.create_entity{name="loader-1x1",position=at(-1,r[1]),direction=E,type="output",force="player"} end ' +
      'local eei=s.create_entity{name="electric-energy-interface",position={x0-2,y0+7},force="player"} eei.power_production=10000000/60 eei.electric_buffer_size=100000000 ' +
      'for _,ty in pairs({1,6,11}) do put("small-electric-pole",-1,ty) end ' +
      `for tx=2,${3 * BOTTOM},6 do put("small-electric-pole",tx,8) end put("small-electric-pole",${3 * BOTTOM},11) ` +
      'local f=game.forces.player for _,n in pairs({"steam-power","electronics","automation-science-pack","automation","logistics"}) do f.technologies[n].researched=true end ' +
      'f.chart(s,{{-128,-128},{128,128}}) rcon.print("ready")',
  );
  await game.testSpawn({ x: X0 + 20, y: Y0 + 20 });
  // The ore lines' plan as it's stored once they're built: its site and the chests its plate belts end in.
  await modLua(
    'local rec=storage.engineers[0] rec.auto=rec.auto or {fails={},skip={},skipped={}} ' +
      `rec.auto.ore_plan={done=true,site={x=${X0},y=${Y0}},chests={{x=${X0 + 3 * TOP + 1.5},y=${Y0 + 0.5}},{x=${X0 + 3 * BOTTOM + 1.5},y=${Y0 + 12.5}}},` +
      `parts={},places={},box={left_top={x=${X0 - 1},y=${Y0}},right_bottom={x=${X0 + 3 * BOTTOM + 2},y=${Y0 + 13}}}} rcon.print("ok")`,
  );
  await lua(
    'local e=game.surfaces[1].find_entities_filtered{type="character"}[1] ' +
      'for _,i in pairs({{"iron-plate",1200},{"copper-plate",400},{"wood",60}}) do e.insert{name=i[1],count=i[2]} end',
  );
  let after = (await game.poll(0)).seq ?? 0;
  await lua(`game.speed=${SPEED}`);

  let last = "";
  let buildAfter = 0;
  // Adds a goal and waits for its goal_done (or goal_blocked) event.
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

  // Built before the bus could be (no splitters yet), a goal's machines are fed by hand; once the bus can
  // be built, they're picked up and built again beside it.
  await lua('game.forces.player.recipes["splitter"].enabled=false rcon.print("ok")');
  await runGoal({ item: "iron-gear-wheel", per_minute: 10 });
  const gearsAt = async () =>
    JSON.parse(
      await lua(
        `local x0=${X0} local out={} for _,a in pairs(game.surfaces[1].find_entities_filtered{type="assembling-machine"}) do ` +
          'local r=a.get_recipe() if r and r.name=="iron-gear-wheel" then out[#out+1]={x=a.position.x-x0,made=a.products_finished} end end ' +
          'rcon.print(helpers.table_to_json(out))',
      ),
    ) as { x: number; made: number }[];
  const before = await gearsAt();
  console.log("gears before the bus:", JSON.stringify(before));
  assert.ok(before.length > 0 && before.every((g) => g.x <= 3 * BOTTOM + 5), "without splitters the gears are made off the bus");
  await lua('game.forces.player.recipes["splitter"].enabled=true rcon.print("ok")');
  {
    const started = await gameMinutes();
    let moved = false;
    while (!moved) {
      await Bun.sleep(2000);
      const poll = await game.poll(after, { buildAfter });
      for (const item of poll.items ?? []) after = Math.max(after, item.id);
      for (const l of poll.build_log ?? []) {
        console.log("    " + l.text);
        buildAfter = Math.max(buildAfter, l.n);
      }
      const now = await gearsAt();
      moved = now.length > 0 && now.every((g) => g.x > 3 * BOTTOM + 5) && now.some((g) => g.made > 0);
      if ((await gameMinutes()) - started > MAX_MINUTES) throw new Error("The gear machines weren't moved onto the bus");
    }
    console.log("gears on the bus:", JSON.stringify(await gearsAt()));
  }

  await runGoal({ item: "electronic-circuit", per_minute: 15 });
  const built = JSON.parse(
    await lua(
      `local s=game.surfaces[1] local x0,y0=${X0},${Y0} local c={} ` +
        'c.splitters=#s.find_entities_filtered{name="splitter"} c.undergrounds=#s.find_entities_filtered{name="underground-belt"} ' +
        'c.paired=0 for _,u in pairs(s.find_entities_filtered{name="underground-belt"}) do if u.underground_belt_neighbour then c.paired=c.paired+1 end end ' +
        'c.belt_fed=0 for _,i in pairs(s.find_entities_filtered{name="inserter"}) do local p,d=i.pickup_target,i.drop_target ' +
        'if p and d and p.type=="transport-belt" and d.type=="assembling-machine" then c.belt_fed=c.belt_fed+1 end end ' +
        'c.assemblers={} for _,a in pairs(s.find_entities_filtered{type="assembling-machine"}) do c.assemblers[#c.assemblers+1]=a.position.x-x0 end ' +
        // The feeder belt, a few tiles down: copper on one lane, iron on the other.
        'c.lanes={} for _,b in pairs(s.find_entities_filtered{name="transport-belt",area={{x0,y0+11},{x0+60,y0+12}}}) do if b.direction==defines.direction.south then ' +
        'for l=1,2 do local line=b.get_transport_line(l) c.lanes[#c.lanes+1]=l..":"..line.get_item_count("iron-plate").."i/"..line.get_item_count("copper-plate").."c" end end end ' +
        'c.old_chests=0 for _,ch in pairs(s.find_entities_filtered{name="wooden-chest",area={{x0,y0},{x0+20,y0+13}}}) do c.old_chests=c.old_chests+1 end ' +
        'c.taps=0 for _,ch in pairs(s.find_entities_filtered{name="wooden-chest",area={{x0+20,y0},{x0+23,y0+13}}}) do c.taps=c.taps+ch.get_item_count("iron-plate")+ch.get_item_count("copper-plate") end ' +
        'rcon.print(helpers.table_to_json(c))',
    ),
  );
  console.log("built:", JSON.stringify(built));
  assert.ok(built.splitters >= 2, "a splitter on each plate belt of the bus");
  assert.ok(built.paired >= 2, "the top plates go under the bus by a paired underground belt");
  assert.ok(built.belt_fed >= 2, "inserters feed the assemblers from the feeder belt");
  assert.ok(built.assemblers.every((x: number) => x > 3 * BOTTOM + 5), "the assemblers stand beside the bus, past the smelting area");
  assert.ok(
    built.lanes.length > 0 && built.lanes.every((l: string) => !/[1-9]\d*i\/[1-9]/.test(l)),
    "the feeder carries iron and copper on separate lanes",
  );
  assert.equal(built.old_chests, 0, "the plate belts' old end chests are gone");
  assert.ok(built.taps > 0, "the taps collect plates");

  // Science: red and then green beside the bus, their packs going up under it to the labs by belt, each on
  // its own lane of the science belt, and green's gears coming down its parts belt.
  await lua(
    'local f=game.forces.player f.technologies["logistic-science-pack"].researched=true ' +
      'local e=game.surfaces[1].find_entities_filtered{type="character"}[1] ' +
      'for _,i in pairs({{"iron-plate",1500},{"copper-plate",600}}) do e.insert{name=i[1],count=i[2]} end rcon.print("ok")',
  );
  await runGoal({ item: "automation-science-pack", per_minute: 5 });
  await runGoal({ item: "logistic-science-pack", per_minute: 5 });
  await Bun.sleep(5000);
  const science = JSON.parse(
    await lua(
      `local s=game.surfaces[1] local x0,y0=${X0},${Y0} local c={labs=0,red=0,green=0,lab_fed=0,parts=0,mixed=0} ` +
        'for _,l in pairs(s.find_entities_filtered{name="lab",area={{x0,y0-6},{x0+60,y0}}}) do c.labs=c.labs+1 ' +
        'local inv=l.get_inventory(defines.inventory.lab_input) c.red=c.red+inv.get_item_count("automation-science-pack") c.green=c.green+inv.get_item_count("logistic-science-pack") end ' +
        'for _,i in pairs(s.find_entities_filtered{name="inserter"}) do local p,d=i.pickup_target,i.drop_target ' +
        'if p and d and p.type=="transport-belt" and d.type=="lab" then c.lab_fed=c.lab_fed+1 end ' +
        // Off the parts belt: east of the assembler it feeds.
        'if p and d and p.type=="transport-belt" and d.type=="assembling-machine" and i.position.x>d.position.x then c.parts=c.parts+1 end end ' +
        'for _,b in pairs(s.find_entities_filtered{name="transport-belt",area={{x0,y0+1},{x0+80,y0+2}}}) do for l=1,2 do local line=b.get_transport_line(l) ' +
        'if line.get_item_count("automation-science-pack")>0 and line.get_item_count("logistic-science-pack")>0 then c.mixed=c.mixed+1 end end end ' +
        'rcon.print(helpers.table_to_json(c))',
    ),
  );
  console.log("science:", JSON.stringify(science));
  assert.equal(science.labs, 3, "three labs north of the bus");
  assert.ok(science.lab_fed >= 3, "each lab has an inserter off the science belt");
  assert.ok(science.red > 0 && science.green > 0, "red and green packs reach the labs by belt");
  assert.equal(science.mixed, 0, "red and green ride on separate lanes of the science belt");
  assert.ok(science.parts >= 1, "a parts belt brings what neighbors don't pass");

  // The mall: assemblers filling chests with what the engineer builds with.
  await runGoal({ item: "mall" });
  const mall = JSON.parse(
    await lua(
      `local s=game.surfaces[1] local x0,y0=${X0},${Y0} local c={} ` +
        'for _,ch in pairs(s.find_entities_filtered{name="wooden-chest",area={{x0+20,y0+9},{x0+140,y0+120}}}) do ' +
        'for _,it in pairs(ch.get_inventory(defines.inventory.chest).get_contents()) do c[it.name]=(c[it.name] or 0)+it.count end end ' +
        'rcon.print(helpers.table_to_json(c))',
    ),
  );
  console.log("mall chests:", JSON.stringify(mall));
  for (const item of ["transport-belt", "inserter", "underground-belt", "assembling-machine-1"]) {
    assert.ok((mall[item] ?? 0) > 0, `the mall makes ${item}`);
  }
  console.log("BUS TEST PASSED");
} catch (error) {
  // What the bus holds: each belt, splitter and underground east of the smelting area, by tile, with the
  // items on it, and each assembler and inserter there with its status.
  console.error(
    await lua(
      `local s=game.surfaces[1] local x0,y0=${X0},${Y0} local out={} ` +
        'for _,b in pairs(s.find_entities_filtered{type={"transport-belt","splitter","underground-belt","inserter","assembling-machine","container","electric-pole","lab"},area={{x0+15,y0-5},{x0+80,y0+60}}}) do ' +
        'local belty=b.type=="transport-belt" or b.type=="splitter" or b.type=="underground-belt" ' +
        'local items={} for l=1,(belty and b.get_max_transport_line_index() or 0) do ' +
        'local c=b.get_transport_line(l).get_contents() for _,it in pairs(c) do items[#items+1]=l..it.name:sub(1,4)..it.count end end ' +
        'local names={} for k,v in pairs(defines.entity_status) do names[v]=k end ' +
        'local st=b.status and names[b.status] or "" ' +
        'if b.type=="assembling-machine" then local r=b.get_recipe() st=st.." "..(r and r.name or "-") for _,it in pairs(b.get_inventory(defines.inventory.crafter_input).get_contents()) do st=st.." "..it.name..it.count end end ' +
        'if b.type=="inserter" and b.held_stack.valid_for_read then st=st.." holds "..b.held_stack.name end ' +
        'out[#out+1]=string.format("%s@%g,%g d%s%s %s %s",b.name:sub(1,8),b.position.x-x0,b.position.y-y0,tostring(b.direction),' +
        'b.type=="underground-belt" and b.belt_to_ground_type or "",st,table.concat(items,",")) end ' +
        'table.sort(out) rcon.print(table.concat(out,"\\n"))',
    ),
  );
  console.error(server.log().slice(-3000));
  throw error;
} finally {
  await server.stop();
}
