// Real-game test of the smelting columns' layout (autopilot's smelter_layout) on its own: every part placed
// on flat grass in each frame (four directions, mirrored or not), nothing colliding, every underground belt
// paired, every inserter and furnace powered once a pole connects to an energy interface. Then ore and coal
// fed into the trunk: plates come out on both of the bus's plate rows, and coal on its middle row.
// Usage: bun run test:smelter (SMELTER_FRAMES=all for all eight frames; default east and one turned)
import { strict as assert } from "node:assert";
import { startServer } from "./factorio";

const server = await startServer({ port: 34434 });
const lua = (code: string) => server.rcon.command("/sc " + code);
const modLua = (code: string) => server.rcon.command("/sc __ai-engineer__ " + code);
const MODS =
  'local ap, bus, frame for k,v in pairs(package.loaded) do if k:find("scripts.autopilot") then ap=v elseif k:find("scripts.bus") then bus=v elseif k:find("scripts.frame") then frame=v end end ';
const FRAMES: [number, boolean][] =
  process.env.SMELTER_FRAMES === "all"
    ? [0, 1, 2, 3].flatMap((d) => [[d, false], [d, true]] as [number, boolean][])
    : [[1, false], [2, true]];

try {
  await lua('rcon.print("ok")');
  await lua('rcon.print("ok")');
  for (const [dir, mirror] of FRAMES) {
    await lua(
      'local s=game.surfaces[1] s.peaceful_mode=true for _,e in pairs(s.find_entities_filtered{area={{-100,-100},{100,100}}}) do if e.type~="character" then e.destroy() end end ' +
        'local t={} for x=-100,100 do for y=-100,100 do t[#t+1]={name="grass-1",position={x,y}} end end s.set_tiles(t) ' +
        'local f=game.forces.player f.research_all_technologies() rcon.print("ok")',
    );
    const parse = (raw: string) => {
      try {
        return JSON.parse(raw);
      } catch {
        throw new Error("not JSON: " + raw);
      }
    };
    const r = parse(
      await modLua(
        MODS +
          `local m=frame.make(${dir}, ${mirror}) local o=frame.at(m,{x=0,y=0},-20,-20) ` +
          'local places, entries, box, chests, g = ap.smelter_layout(o.x, o.y, 6, 3, false, m) ' +
          'local s=game.surfaces[1] local out={placed=0,failed={},unpaired=0,unpowered=0} ' +
          'for _,pl in ipairs(places) do local name=prototypes.item[pl[1]].place_result.name local at=pl[2] ' +
          'local e=s.create_entity{name=name,position=at.position,direction=at.direction and at.direction*4 or nil,type=at.belt_type,force="player",raise_built=false} ' +
          'if e then out.placed=out.placed+1 else out.failed[#out.failed+1]=name.."@"..serpent.line(at.position) end end ' +
          'for _,u in pairs(s.find_entities_filtered{name="underground-belt"}) do if not u.underground_belt_neighbour then out.unpaired=out.unpaired+1 end end ' +
          // Power: an energy interface west of the first column, on a pole in wire reach of its first pole.
          's.create_entity{name="small-electric-pole",position=bus.tile(g,-1,12),force="player"} ' +
          'local eei=s.create_entity{name="electric-energy-interface",position=bus.at(g,-3,13),force="player"} ' +
          'eei.power_production=10000000/60 eei.electric_buffer_size=100000000 ' +
          'for _,i in pairs(s.find_entities_filtered{type="inserter"}) do if not i.is_connected_to_electric_network() then out.unpowered=out.unpowered+1 end end ' +
          // Feed the trunk from infinity chests by loaders on its entries, then let it run.
          'out.entries={} for ore,t in pairs(entries) do local item=ore ' +
          'local d=frame.dir(m,1) local lx,ly=frame.vec(m,-1,0) ' +
          'local loader=s.create_entity{name="loader-1x1",position={t.x+0.5,t.y+0.5},direction=d*4,type="output",force="player"} ' +
          'local c=s.create_entity{name="infinity-chest",position={t.x+0.5+lx,t.y+0.5+ly},force="player"} ' +
          'if c then c.set_infinity_container_filter(1,{name=item,count=100}) end out.entries[#out.entries+1]=ore..":"..tostring(loader~=nil)..tostring(c~=nil) end ' +
          'storage.smelter_test={g=g,chests=chests} rcon.print(helpers.table_to_json(out))',
      ),
    );
    console.log(`frame dir ${dir}${mirror ? " mirrored" : ""}:`, JSON.stringify(r));
    // (An empty Lua list comes back as {}.)
    assert.equal(Object.keys(r.failed).length, 0, "every part fits: " + JSON.stringify(r.failed));
    assert.equal(r.unpaired, 0, "every underground belt is paired");
    assert.equal(r.unpowered, 0, "every inserter is powered");
    await lua("game.speed=20");
    await Bun.sleep(25000);
    await lua("game.speed=1");
    const flow = JSON.parse(
      await modLua(
        MODS +
          'local g=storage.smelter_test.g local s=game.surfaces[1] local out={} ' +
          'for _,row in pairs({5,6,7}) do local p=bus.tile(g,g.X,row) local b=s.find_entities_filtered{type="transport-belt",position=p,radius=0.3}[1] ' +
          'local c={} if b then for l=1,2 do for _,it in pairs(b.get_transport_line(l).get_contents()) do c[it.name]=(c[it.name] or 0)+it.count end end end ' +
          'out["row"..row]=c end ' +
          'out.taps={} for _,p in pairs(storage.smelter_test.chests) do local ch=s.find_entities_filtered{name="wooden-chest",position=p,radius=0.3}[1] ' +
          'out.taps[#out.taps+1]=ch and helpers.table_to_json(ch.get_inventory(defines.inventory.chest).get_contents()) or "none" end ' +
          'out.smelting=0 for _,f in pairs(s.find_entities_filtered{name="stone-furnace"}) do if f.status==defines.entity_status.working then out.smelting=out.smelting+1 end end ' +
          'rcon.print(helpers.table_to_json(out))',
      ),
    );
    console.log("  flow:", JSON.stringify(flow));
    assert.ok((flow.row5?.["iron-plate"] ?? 0) > 0 || (flow.row5?.["copper-plate"] ?? 0) > 0, "plates reach the bus's top row");
    assert.ok((flow.row7?.["iron-plate"] ?? 0) > 0 || (flow.row7?.["copper-plate"] ?? 0) > 0, "plates reach the bus's bottom row");
    assert.ok((flow.row6?.coal ?? 0) > 0, "coal reaches the bus's middle row");
    assert.ok(flow.smelting >= 8, "the furnaces are smelting");
  }
  console.log("SMELTER TEST PASSED");
} finally {
  await server.stop();
}
