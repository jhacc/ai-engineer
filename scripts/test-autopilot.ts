// Real-game test of keep-busy's build order: on a normal generated map, the engineer works through the
// starting base by itself (no AI): the burner base, its growth, steam power, a lab and red science research.
// Runs the game sped up. Usage: bun run test:autopilot
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";
import { Game } from "../app/src/game";

const SPEED = Number(process.env.SPEED ?? 10);
/** Game minutes the whole build order may take. */
const MAX_MINUTES = Number(process.env.MAX_MINUTES ?? 150);
/** Game minutes the build order may say the same thing before the test counts it as stuck. */
const STALL_MINUTES = 20;
// The engineer's character when stuck: where it is, what it's mining, and how full its inventory is.
const CHARACTER =
  'local ch=game.surfaces[1].find_entities_filtered{type="character"}[1] if not ch then rcon.print("none") return end ' +
  'local inv=ch.get_main_inventory() local items={} for _,it in pairs(inv.get_contents()) do items[#items+1]=it.name.."="..it.count end ' +
  'local m=ch.mining_state rcon.print(helpers.table_to_json({position=ch.position,free_slots=inv.count_empty_stacks(),' +
  'mining=m.mining,mining_at=m.position,selected=ch.selected and ch.selected.name or "",walking=ch.walking_state.walking,items=table.concat(items," ")}))';

const server = await startServer();
const game = new Game(server.rcon, "test-app");
const lua = (code: string) => server.rcon.command("/sc " + code);

// What the engineer has built, by role (read from the game, not from the build order's own notes).
const COUNT =
  'local s=game.surfaces[1] local c={pair_iron=0,pair_copper=0,coal=0,stone=0,drills=0,furnaces=0,fuel_low=0} ' +
  'for _,d in pairs(s.find_entities_filtered{name="burner-mining-drill"}) do c.drills=c.drills+1 ' +
  'local t=d.drop_target local r=d.mining_target and d.mining_target.name or "" ' +
  'if (d.get_fuel_inventory().get_item_count()) < 1 then c.fuel_low=c.fuel_low+1 end ' +
  'if t and t.type=="furnace" then if r=="iron-ore" then c.pair_iron=c.pair_iron+1 elseif r=="copper-ore" then c.pair_copper=c.pair_copper+1 end ' +
  'elseif t and t.type=="mining-drill" then c.coal=c.coal+1 elseif t and t.type=="container" then c.stone=c.stone+1 end end ' +
  'c.furnaces=#s.find_entities_filtered{name="stone-furnace"} c.engines=#s.find_entities_filtered{name="steam-engine"} c.steamed=0 c.engines_on=0 ' +
  'for _,g in pairs(s.find_entities_filtered{name="steam-engine"}) do local f=g.get_fluid(1) if f and f.amount>0 then c.steamed=c.steamed+1 end ' +
  'if g.is_connected_to_electric_network() then c.engines_on=c.engines_on+1 end end ' +
  'local labs=s.find_entities_filtered{name="lab"} c.labs=#labs c.powered=labs[1] and labs[1].is_connected_to_electric_network() or false ' +
  'local f=game.forces.player c.researched={} for _,n in pairs({"automation","logistics","electric-mining-drill"}) do if f.technologies[n].researched then c.researched[#c.researched+1]=n end end ' +
  'c.research=f.current_research and f.current_research.name or "" ' +
  // Coal drills that come round in a loop, those in loops of four, and drills feeding drills that don't.
  'local function nx(d) local t=d.drop_target return t and t.valid and t.type=="mining-drill" and t or nil end c.looped=0 c.ring=0 c.broken=0 ' +
  'for _,d in pairs(s.find_entities_filtered{name="burner-mining-drill"}) do if nx(d) then local cur,len=nx(d),1 ' +
  'while cur and cur~=d and len<=8 do cur=nx(cur) len=len+1 end ' +
  'if cur==d then c.looped=c.looped+1 if len==4 then c.ring=c.ring+1 end else c.broken=c.broken+1 end end end ' +
  'c.pipes=#s.find_entities_filtered{name="pipe"} c.science=false ' +
  'for _,i in pairs(s.find_entities_filtered{name="inserter"}) do local p,t=i.pickup_target,i.drop_target ' +
  'if p and p.name=="assembling-machine-1" and t and t.type=="lab" and p.is_connected_to_electric_network() then c.science=true end end ' +
  // Red science from plates: a gear assembler passing gears to the science one, and chests feeding both.
  'c.science_gears=false c.science_chests=0 for _,i in pairs(s.find_entities_filtered{name="inserter"}) do local p,t=i.pickup_target,i.drop_target ' +
  'local tr=t and t.type=="assembling-machine" and t.get_recipe() if tr and tr.name=="automation-science-pack" then ' +
  'local pr=p and p.type=="assembling-machine" and p.get_recipe() if pr and pr.name=="iron-gear-wheel" and i.is_connected_to_electric_network() then c.science_gears=true end ' +
  'if p and p.type=="container" then c.science_chests=c.science_chests+1 end ' +
  'elseif tr and tr.name=="iron-gear-wheel" and p and p.type=="container" then c.science_chests=c.science_chests+1 end end ' +
  'local ch=s.find_entities_filtered{type="character"}[1] c.gears=ch and ch.get_item_count("iron-gear-wheel") or 0 ' +
  // Coal by belt: a powered inserter from a belt into a boiler, electric drills, and coal on the belts.
  'c.coal_belt=false for _,i in pairs(s.find_entities_filtered{name="inserter"}) do local p,t=i.pickup_target,i.drop_target ' +
  'if p and p.type=="transport-belt" and t and t.type=="boiler" and i.is_connected_to_electric_network() then c.coal_belt=true end end ' +
  'c.turrets=0 c.turret_ammo=0 for _,t in pairs(s.find_entities_filtered{name="gun-turret"}) do c.turrets=c.turrets+1 c.turret_ammo=c.turret_ammo+t.get_item_count("firearm-magazine") end ' +
  // Electric drills filling chests: on coal (the coal mine) and on stone (the stone drill's replacement).
  'c.mine=0 c.estone=0 for _,d in pairs(s.find_entities_filtered{name="electric-mining-drill"}) do local t=d.drop_target local r=d.mining_target and d.mining_target.name ' +
  'if t and t.type=="container" then if r=="stone" then c.estone=c.estone+1 else c.mine=c.mine+1 end end end ' +
  'c.boilers=#s.find_entities_filtered{name="boiler"} ' +
  // Boilers an inserter feeds off a belt, and electric drills dropping onto a belt.
  'local fedb={} c.belt_boilers=0 for _,i in pairs(s.find_entities_filtered{name="inserter"}) do local p,t=i.pickup_target,i.drop_target ' +
  'if p and p.type=="transport-belt" and t and t.type=="boiler" and not fedb[t.unit_number] then fedb[t.unit_number]=true c.belt_boilers=c.belt_boilers+1 end end ' +
  // Ore lines: furnaces an inserter feeds from a belt, plates in chests fed from a belt, electric drills on
  // iron or copper putting ore on a belt; and red science units (science assemblers feeding labs).
  'local lf={} c.line_furnaces=0 c.line_plates=0 c.science_units=0 for _,i in pairs(s.find_entities_filtered{type="inserter"}) do local p,t=i.pickup_target,i.drop_target ' +
  'if p and p.type=="transport-belt" and t and t.type=="furnace" and not lf[t.unit_number] then lf[t.unit_number]=true c.line_furnaces=c.line_furnaces+1 end ' +
  'if p and p.type=="transport-belt" and t and t.type=="container" then c.line_plates=c.line_plates+t.get_item_count("iron-plate")+t.get_item_count("copper-plate") end ' +
  'if p and p.type=="assembling-machine" and t and t.type=="lab" then c.science_units=c.science_units+1 end ' +
  'if p and p.type=="transport-belt" and t and t.type=="lab" then c.belt_labs=(c.belt_labs or 0)+1 end end ' +
  'c.line_drills=0 for _,d in pairs(s.find_entities_filtered{name="electric-mining-drill"}) do local r=d.mining_target and d.mining_target.name ' +
  'if (r=="iron-ore" or r=="copper-ore") and s.find_entities_filtered{position=d.drop_position,radius=0.3,type="transport-belt"}[1] then c.line_drills=c.line_drills+1 end end ' +
  'c.belt_drills=0 for _,d in pairs(s.find_entities_filtered{name="electric-mining-drill"}) do ' +
  'if s.find_entities_filtered{position=d.drop_position,radius=0.3,type="transport-belt"}[1] then c.belt_drills=c.belt_drills+1 end end ' +
  'c.edrills=#s.find_entities_filtered{name="electric-mining-drill"} c.belts=0 c.belt_coal=0 c.epairs=0 ' +
  'for _,d in pairs(s.find_entities_filtered{name="electric-mining-drill"}) do local t=d.drop_target if t and t.type=="furnace" and d.is_connected_to_electric_network() then c.epairs=c.epairs+1 end end ' +
  'for _,b in pairs(s.find_entities_filtered{name="transport-belt"}) do c.belts=c.belts+1 ' +
  'for l=1,2 do c.belt_coal=c.belt_coal+b.get_transport_line(l).get_item_count("coal") end end ' +
  'rcon.print(helpers.table_to_json(c))';
type Counts = {
  pair_iron: number;
  pair_copper: number;
  coal: number;
  stone: number;
  drills: number;
  furnaces: number;
  fuel_low: number;
  engines: number;
  labs: number;
  powered: boolean;
  researched: string[] | Record<string, never>;
  research: string;
  looped: number;
  ring: number;
  broken: number;
  pipes: number;
  science: boolean;
  science_gears: boolean;
  science_chests: number;
  gears: number;
  coal_belt: boolean;
  edrills: number;
  belts: number;
  belt_coal: number;
  epairs: number;
  steamed: number;
  engines_on: number;
  turrets: number;
  turret_ammo: number;
  mine: number;
  boilers: number;
  estone: number;
  belt_boilers: number;
  belt_drills: number;
  line_furnaces: number;
  line_plates: number;
  line_drills: number;
  science_units: number;
  belt_labs?: number;
};
const counts = async () => JSON.parse(await lua(COUNT)) as Counts;
/** Technologies researched in labs (not unlocked by doing things). */
const LAB_TECHS =
  "local n=0 for _,t in pairs(game.forces.player.technologies) do if t.researched and not t.prototype.research_trigger then n=n+1 end end rcon.print(n)";
const gameMinutes = async () => Number(await lua("rcon.print(game.tick)")) / 3600;
// An empty Lua table serializes as {}.
const researched = (c: Counts) => (Array.isArray(c.researched) ? c.researched : []);

try {
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  // No biters: this tests building, not fighting.
  await lua(
    'local s=game.surfaces[1] s.peaceful_mode=true for _,e in pairs(s.find_entities_filtered{force="enemy"}) do e.destroy() end ' +
      'game.forces.player.chart(s,{{-200,-200},{200,200}}) rcon.print("ready")',
  );
  await game.testSpawn({ x: 0, y: 0 });
  let after = (await game.poll(0)).seq ?? 0;
  await lua(`game.speed=${SPEED}`);
  await game.testKeepBusy(true);

  let last = "";
  let baseAt: number | null = null;
  const woke: string[] = [];
  const jobEvents: string[] = [];
  const started = await gameMinutes();
  let buildAfter = 0;
  let maxBroken = 0;
  // Gears on hand after the base is up (the next build may have just used them when the run ends).
  let maxGears = 0;
  let maxRing = 0;
  let maxLooped = 0;
  let maxPairs = 0;
  // The build order's red science, as it was before the main bus's took over (and it was picked up).
  let sawScience = false;
  let sawScienceGears = false;
  let maxScienceChests = 0;
  let room: [{ x: number; y: number }, { x: number; y: number }] | null = null;
  let orderDoneAt: number | null = null;
  let doing: string | undefined;
  let doingSince = 0;
  while (true) {
    await Bun.sleep(2000);
    const poll = await game.poll(after, { buildAfter });
    for (const l of poll.build_log ?? []) {
      console.log(`    build order: ${l.text}`);
      buildAfter = Math.max(buildAfter, l.n);
      if (!orderDoneAt && /The starting base is up/.test(l.text)) {
        orderDoneAt = (await gameMinutes()) - started;
        // Biters destroy one of our drills: turrets should go up there.
        await lua('for _,d in pairs(game.surfaces[1].find_entities_filtered{name="burner-mining-drill"}) do if d.drop_target and d.drop_target.type=="furnace" then d.die(game.forces.enemy) break end end');
      }
    }
    for (const item of poll.items ?? []) {
      after = Math.max(after, item.id);
      woke.push(item.kind);
      if (item.kind === "job_done" || item.kind === "job_failed") jobEvents.push(String(item.data?.job));
    }
    const seen = await game.tool("observe", { radius: 16 });
    const order = seen.ok ? (seen.result as any).engineer.build_order : null;
    room = order?.keep_clear?.power_plant_room ?? room;
    const c = await counts();
    const minutes = (await gameMinutes()) - started;
    const line =
      `${order?.doing} | iron ${c.pair_iron} copper ${c.pair_copper} coal ${c.coal} stone ${c.stone} ` +
      `(unfueled ${c.fuel_low}) engines ${c.engines} labs ${c.labs}${c.powered ? " powered" : ""} ` +
      `research ${c.research || "-"} done [${researched(c).join(",")}] ring ${c.ring / 4} broken ${c.broken} pipes ${c.pipes}` +
      `${c.science ? " science-assembler" : ""} gears ${c.gears} belts ${c.belts} electric-drills ${c.edrills}` +
      `${c.coal_belt ? " coal-belt" : ""}${c.epairs ? ` electric-pairs ${c.epairs}` : ""}` +
      `${c.line_furnaces ? ` line-furnaces ${c.line_furnaces} line-drills ${c.line_drills} plates ${c.line_plates}` : ""} science-units ${c.science_units}` +
      `${seen.ok && (seen.result as any).engineer.goals ? ` | goals: ${(seen.result as any).engineer.goals.join(" / ")}` : ""}`;
    maxBroken = Math.max(maxBroken, c.broken);
    if (orderDoneAt !== null) maxGears = Math.max(maxGears, c.gears);
    maxRing = Math.max(maxRing, c.ring);
    maxPairs = Math.max(maxPairs, c.pair_iron + c.pair_copper + c.epairs);
    maxLooped = Math.max(maxLooped, c.looped);
    sawScience ||= !!c.science;
    sawScienceGears ||= !!c.science_gears;
    maxScienceChests = Math.max(maxScienceChests, c.science_chests);
    if (line !== last) console.log(`[${minutes.toFixed(1)} min] ${line}`);
    last = line;
    if (!baseAt && c.pair_iron >= 1 && c.coal >= 2 && c.pair_copper >= 1 && c.stone >= 1) {
      baseAt = minutes;
      console.log(`BASE BUILT after ${minutes.toFixed(1)} game minutes`);
      // An owner request comes first: the AI's job replaces the build order's, which waits for it.
      await game.testMessage("get some wood");
      const started = await game.tool("mine", { name: "wood", count: 8 });
      assert.ok(started.ok, JSON.stringify(started));
    }
    if (!baseAt && minutes > 15) throw new Error("The base wasn't built within 15 game minutes");
    // Done once keep-busy has nothing left, or once green science is automated and the lab has gone on to
    // research of its own choosing (beyond the build order's three and green science's own).
    const labTechs = Number(await lua(LAB_TECHS));
    const greenDone = ((seen.ok && (seen.result as any).engineer.goals) || []).some((g: string) => /logistic-science-pack 10\/min: complete/.test(g));
    if (!poll.autopilot || (greenDone && labTechs > 4 && c.line_furnaces >= 9 && c.line_plates > 0 && c.pair_iron + c.pair_copper + c.epairs === 0 && (c.belt_labs ?? 0) >= 3 && c.science_units === 0 && c.engines >= 4 && c.turrets >= 2 && c.boilers >= 2 && c.belt_boilers === c.boilers && c.belt_drills >= c.boilers)) {
      console.log(`BUILD ORDER DONE after ${orderDoneAt?.toFixed(1)} game minutes, green science and more research by ${minutes.toFixed(1)}`);
      break;
    }
    // A job that never ends stalls everything (no refueling either): stop early and say what it's stuck on.
    if (order?.doing !== doing) [doing, doingSince] = [order?.doing, minutes];
    const stalled = minutes - doingSince > STALL_MINUTES;
    if (stalled || minutes > MAX_MINUTES) {
      console.log("engineer:", JSON.stringify(seen.ok ? (seen.result as any).engineer : seen));
      console.log("character:", await lua(CHARACTER));
      throw new Error(stalled ? `Stuck on "${doing}" for ${STALL_MINUTES} game minutes` : `The build order wasn't done within ${MAX_MINUTES} game minutes`);
    }
  }
  // Let coal run down the belt for a bit (game time).
  await Bun.sleep(8000);
  const c = await counts();
  console.log("final:", JSON.stringify(c), "most drills seen out of a loop at once (mid-build):", maxBroken);
  // (Burner pairs may have become electric ones by now.)
  assert.ok(maxPairs >= 12 && c.stone + c.estone >= 1, "the base grew to the build order's targets");
  assert.ok(maxRing === 4 && maxLooped === 4 && c.broken === 0, "the first coal loop grew into a ring of four: four coal drills, none built wrong");
  assert.ok(c.coal === 0 && c.looped === 0, "the burner coal drills came out once the coal belt ran");
  assert.ok(c.engines >= 1 && c.powered, "a lab runs on steam power");
  assert.ok(c.pipes >= 3, "the power plant is piped inland, where it has room");
  assert.ok(sawScience, "an assembler made red science into the lab through an inserter");
  // (A copper chest per science assembler, an iron chest per gear assembler.)
  assert.ok(sawScienceGears && maxScienceChests >= 2, `a gear assembler fed the science assembler, both fed plates from chests (chests ${maxScienceChests})`);
  assert.ok(maxGears > 0, "gears are crafted in free time");
  // The lab and its assembler stay out of the power plant's room to grow, on poles.
  assert.ok(room, "the build order says where the power plant grows");
  const [a, b] = room!;
  const inRoom = JSON.parse(
    await lua(
      `local n=0 for _,e in pairs(game.surfaces[1].find_entities_filtered{area={{${a.x},${a.y}},{${b.x},${b.y}}},name={"lab","assembling-machine-1","inserter"}}) do local t=e.type=="inserter" and e.drop_target if not (t and t.type=="boiler") then n=n+1 end end rcon.print(n)`,
    ),
  );
  console.log("power plant room:", JSON.stringify(room), "lab/assembler/inserter inside:", inRoom);
  assert.equal(inRoom, 0, "nothing but power is built in the power plant's room");
  // In the room, the coal belt runs in one straight line along the boilers (belt, inserter, boiler), so
  // boilers added later get an inserter off it.
  const beltLine = JSON.parse(
    await lua(
      `local xs,ys,n,at={}, {}, 0, {} for _,b in pairs(game.surfaces[1].find_entities_filtered{area={{${a.x},${a.y}},{${b.x},${b.y}}},name="transport-belt"}) do ` +
        `local p=b.position if p.x>${a.x} and p.x<${b.x} and p.y>${a.y} and p.y<${b.y} then xs[p.x]=true ys[p.y]=true n=n+1 at[#at+1]=p.x..","..p.y end end ` +
        `rcon.print(helpers.table_to_json({n=n,xs=table_size(xs),ys=table_size(ys),at=table.concat(at," ")}))`,
    ),
  );
  console.log("coal belt in the power plant's room:", JSON.stringify(beltLine));
  assert.ok(beltLine.n > 0 && (beltLine.xs === 1 || beltLine.ys === 1), "the coal belt runs straight along the boilers");
  assert.deepEqual(researched(c), ["automation", "logistics", "electric-mining-drill"], "red science research is done");
  assert.ok(c.coal_belt && c.edrills >= 2 && c.belt_coal > 0, "electric drills belt coal to the boiler through an inserter");
  // After the build order, keep-busy automated green science by itself: researched, built, output measured.
  const status = await game.tool("goal", { action: "status" });
  console.log("goals:", JSON.stringify(status));
  const goals: string[] = (status.ok && (status.result as any).goals) || [];
  assert.ok(goals.some((g) => /logistic-science-pack 10\/min: complete/.test(g)), "keep-busy automated green science");
  assert.ok(await lua('rcon.print(game.forces.player.technologies["logistic-science-pack"].researched)').then((s) => s.trim() === "true"));
  // Then the lab works through the tech tree by itself with the science the base makes.
  const labTechs = Number(await lua(LAB_TECHS));
  console.log("technologies researched in the lab:", labTechs);
  assert.ok(labTechs > 4, "research carries on past what the build order and green science needed");
  // Burner pairs are swapped for electric drills feeding furnaces, without losing any pairs.
  // Ore lines replace the drill/furnace pairs: electric drills belt iron and copper to a smelting area.
  assert.ok(c.line_drills >= 6 && c.line_furnaces >= 9, "electric drills belt ore to a row of furnaces per ore");
  assert.ok(c.line_plates > 0, "the smelting area's plates reach its chests");
  assert.equal(c.pair_iron + c.pair_copper + c.epairs, 0, "the drill/furnace pairs came out once the ore lines ran");
  // Once the main bus's red science reaches its labs by belt, the build order's (fed by hand) comes out.
  assert.ok((c.belt_labs ?? 0) >= 3, "three labs fed off the science belt");
  assert.equal(c.science_units, 0, "the build order's red science was picked up once the bus's took over");
  // The power plant grew once the drills and machines needed more: every engine gets steam and is on the network.
  assert.ok(c.engines >= 4, "a second engine on the first boiler, then a second boiler row");
  assert.equal(c.steamed, c.engines, "every steam engine gets steam");
  assert.equal(c.engines_on, c.engines, "every steam engine is on the network");
  // Biters destroyed a drill: two loaded gun turrets went up there.
  assert.ok(c.turrets >= 2 && c.turret_ammo > 0, "turrets where biters attacked, with ammo");
  // Every boiler burns coal off the one belt, with an electric drill on it per boiler.
  assert.equal(c.belt_boilers, c.boilers, "every boiler has an inserter off the coal belt");
  assert.ok(c.belt_drills >= c.boilers, "an electric drill on the coal belt per boiler");
  assert.equal(c.mine, 0, "no coal carried by hand while the belt feeds every boiler");
  // Only the AI's own job reports back: the build order's jobs never wake the AI.
  assert.deepEqual(jobEvents, ["mining wood"], "only the AI's job reports back (it wasn't replaced)");
  assert.ok(!woke.includes("crafting_done"), "build order crafting doesn't wake the AI");
  console.log("AUTOPILOT TEST PASSED");
} catch (error) {
  console.error(server.log().slice(-3000));
  // The game as it was, to look into with startServer({save}) (bun scripts/diag-base.ts and the like).
  try {
    await server.keep(".local/autopilot-fail.zip");
    console.error("saved the failed game to .local/autopilot-fail.zip");
  } catch (e) {
    console.error("couldn't save the failed game:", e);
  }
  throw error;
} finally {
  await server.stop();
}
