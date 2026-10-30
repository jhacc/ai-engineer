// Real-game test of goals: with keep-busy off, the owner's goal to automate electronic circuits is planned,
// built (assemblers on power, fed by the engineer) and only counted done once the circuits really come out.
// Power is an electric energy interface, so this tests goals rather than the steam build order.
// Usage: bun run test:goals
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";
import { Game } from "../app/src/game";

const SPEED = Number(process.env.SPEED ?? 10);

// Its own ports, so it can run alongside test:autopilot.
const server = await startServer({ spaceAge: !!process.env.TEST_SPACE_AGE, port: 34420 });
const game = new Game(server.rcon, "test-app");
const lua = (code: string) => server.rcon.command("/sc " + code);
const tool = async (name: string, args: Record<string, unknown> = {}) => {
  const r = await game.tool(name, args);
  if (!r.ok) throw new Error(`${name} failed: ${r.error}`);
  return r.result as any;
};
const gameMinutes = async () => Number(await lua("rcon.print(game.tick)")) / 3600;

try {
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  // A flat area with no ore or biters, power from an energy interface and one pole, and the research
  // assemblers need (the goal's research is checked in test:game and its plan; here it's about building).
  await lua(
    'local s=game.surfaces[1] s.peaceful_mode=true for _,e in pairs(s.find_entities_filtered{area={{-80,-80},{80,80}}}) do e.destroy() end ' +
      'local t={} for x=-80,80 do for y=-80,80 do t[#t+1]={name="grass-1",position={x,y}} end end s.set_tiles(t) ' +
      'local eei=s.create_entity{name="electric-energy-interface",position={-12,-12},force="player"} ' +
      'eei.power_production=10000000/60 eei.electric_buffer_size=100000000 ' +
      's.create_entity{name="small-electric-pole",position={-10.5,-10.5},force="player"} ' +
      'local f=game.forces.player for _,n in pairs({"steam-power","electronics","automation-science-pack","automation","logistics"}) do f.technologies[n].researched=true end ' +
      'f.chart(s,{{-96,-96},{96,96}}) rcon.print("ready")',
  );
  await game.testSpawn({ x: 0, y: 0 });
  // Materials for the machines and their feed (the base would supply plates; there's none here).
  await lua(
    'local e=game.surfaces[1].find_entities_filtered{type="character"}[1] ' +
      'for _,i in pairs({{"iron-plate",600},{"copper-plate",600},{"wood",40}}) do e.insert{name=i[1],count=i[2]} end',
  );
  let after = (await game.poll(0)).seq ?? 0;
  await lua(`game.speed=${SPEED}`);

  const goal = await tool("goal", { item: "electronic-circuit", per_minute: 15 });
  console.log("goal:", JSON.stringify(goal, null, 1));
  assert.equal(goal.status, "ACTIVE");
  const started = await gameMinutes();
  let done: any = null;
  let last = "";
  while (!done) {
    await Bun.sleep(2000);
    const poll = await game.poll(after);
    for (const item of poll.items ?? []) {
      after = Math.max(after, item.id);
      if (item.kind === "goal_done" || item.kind === "goal_blocked") done = item;
    }
    const seen = await tool("observe", { radius: 32 });
    const line = `${seen.engineer.job?.doing ?? "-"} | ${(seen.engineer.goals ?? []).join(" / ")}`;
    const minutes = (await gameMinutes()) - started;
    if (line !== last) console.log(`[${minutes.toFixed(1)} min] ${line}`);
    last = line;
    if (minutes > 20) throw new Error("The goal wasn't done within 20 game minutes");
  }
  console.log("event:", JSON.stringify(done));
  assert.equal(done.kind, "goal_done", JSON.stringify(done.data));
  const status = await tool("goal", { action: "status", id: goal.id });
  console.log("status:", JSON.stringify(status, null, 1));
  assert.equal(status.status, "COMPLETE");
  const measured = Number(String(status.tasks.at(-1)).match(/now ([\d.]+)\/min/)?.[1]);
  assert.ok(measured >= 12, `measured ${measured}/min`);
  // The machines are the engineer's, on power, and the circuits collect in the chest.
  const built = JSON.parse(
    await lua(
      'local s=game.surfaces[1] local c={assemblers=0,powered=0,chest=0} ' +
        'for _,a in pairs(s.find_entities_filtered{type="assembling-machine"}) do c.assemblers=c.assemblers+1 ' +
        'if a.is_connected_to_electric_network() then c.powered=c.powered+1 end end ' +
        'for _,ch in pairs(s.find_entities_filtered{name="wooden-chest"}) do c.chest=c.chest+ch.get_item_count("electronic-circuit") end ' +
        'c.links=0 for _,i in pairs(s.find_entities_filtered{name="inserter"}) do local p,d=i.pickup_target,i.drop_target ' +
        'if p and d and p.type=="assembling-machine" and d.type=="assembling-machine" and p.get_recipe().name=="copper-cable" then c.links=c.links+1 end end ' +
        'rcon.print(helpers.table_to_json(c))',
    ),
  );
  console.log("built:", JSON.stringify(built));
  assert.ok(built.assemblers >= 2 && built.powered === built.assemblers, "cable and circuit assemblers on power");
  assert.ok(built.chest > 0, "circuits collect in the output chest");
  assert.equal(built.links, 1, "an inserter passes cable from its assembler straight into the circuit assembler");
  // Keep-busy is off: nothing of its own was started.
  const all = await tool("goal", { action: "status" });
  assert.equal(all.goals.length, 1, "no goals besides the owner's");
  // A paused goal stops its work; resumed, it carries on (and stays complete).
  assert.equal((await tool("goal", { action: "pause", id: goal.id })).status, "PAUSED");
  const poll = await game.poll(after);
  assert.ok(!poll.autopilot, "nothing left to do while paused");
  assert.equal((await tool("goal", { action: "resume", id: goal.id })).status, "COMPLETE");

  // Smelting beyond plates: military science needs steel and bricks, made in furnaces the engineer fuels
  // and feeds, with the bricks passed straight to the wall assembler. Its research is done here, and the
  // circuits goal paused so the engineer isn't busy feeding both.
  await tool("goal", { action: "pause", id: goal.id });
  await lua(
    'local f=game.forces.player for _,n in pairs({"logistic-science-pack","steel-processing","military","military-2","stone-wall","military-science-pack"}) do f.technologies[n].researched=true end ' +
      'local e=game.surfaces[1].find_entities_filtered{type="character"}[1] ' +
      'for _,i in pairs({{"iron-plate",600},{"copper-plate",200},{"coal",300},{"stone",400}}) do e.insert{name=i[1],count=i[2]} end rcon.print("ok")',
  );
  const military = await tool("goal", { item: "military-science-pack", per_minute: 5 });
  console.log("goal military:", JSON.stringify(military, null, 1));
  assert.equal(military.status, "ACTIVE", String(military.reason));
  const milStarted = await gameMinutes();
  done = null;
  while (!done) {
    await Bun.sleep(2000);
    const poll = await game.poll(after);
    for (const item of poll.items ?? []) {
      after = Math.max(after, item.id);
      if ((item.kind === "goal_done" || item.kind === "goal_blocked") && item.data?.goal === military.id) done = item;
    }
    const seen = await tool("observe", { radius: 32 });
    const line = `${seen.engineer.job?.doing ?? "-"} | ${(seen.engineer.goals ?? []).join(" / ")}`;
    const minutes = (await gameMinutes()) - milStarted;
    if (line !== last) console.log(`[${minutes.toFixed(1)} min] ${line}`);
    last = line;
    if (minutes > 30) throw new Error("The military science goal wasn't done within 30 game minutes");
  }
  console.log("event:", JSON.stringify(done));
  assert.equal(done.kind, "goal_done", JSON.stringify(done.data));
  const smelted = JSON.parse(
    await lua(
      'local s=game.surfaces[1] local c={steel=0,brick=0,fueled=0,furnaces=0,brick_link=0,packs=0} ' +
        'for _,f in pairs(s.find_entities_filtered{type="furnace"}) do c.furnaces=c.furnaces+1 ' +
        'if f.get_fuel_inventory().get_item_count("coal")>0 then c.fueled=c.fueled+1 end ' +
        'if f.products_finished>0 then local r=f.get_recipe() or f.previous_recipe local n=r and (r.name or (r.prototype and r.prototype.name)) ' +
        'if f.get_item_count("steel-plate")>0 or n=="steel-plate" then c.steel=c.steel+1 end ' +
        'if f.get_item_count("stone-brick")>0 or n=="stone-brick" then c.brick=c.brick+1 end end end ' +
        'for _,i in pairs(s.find_entities_filtered{name="inserter"}) do local p,d=i.pickup_target,i.drop_target ' +
        'if p and d and p.type=="furnace" and d.type=="assembling-machine" and d.get_recipe().name=="stone-wall" then c.brick_link=c.brick_link+1 end end ' +
        'for _,ch in pairs(s.find_entities_filtered{name="wooden-chest"}) do c.packs=c.packs+ch.get_item_count("military-science-pack") end ' +
        'rcon.print(helpers.table_to_json(c))',
    ),
  );
  console.log("smelted:", JSON.stringify(smelted));
  assert.ok(smelted.steel >= 1 && smelted.brick >= 1, "steel and brick furnaces have smelted");
  assert.ok(smelted.fueled === smelted.furnaces, "every furnace has fuel");
  assert.ok(smelted.brick_link >= 1, "an inserter passes bricks from a furnace into the wall assembler");
  assert.ok(smelted.packs > 0, "military science collects in the output chest");
  console.log("GOALS TEST PASSED");
} catch (error) {
  console.error(server.log().slice(-3000));
  throw error;
} finally {
  await server.stop();
}
