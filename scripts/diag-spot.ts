// Diagnostic: what stands around a spot in a save, who built it, and which goal's planned parts and the
// ore plan's parts are there, with the bus frame and its slots.
// Usage: bun scripts/diag-spot.ts <save.zip> <x> <y> [radius]
import { startServer } from "./factorio";

const [save, x, y, r] = [process.argv[2]!, Number(process.argv[3]), Number(process.argv[4]), Number(process.argv[5] ?? 3)];
const server = await startServer({ port: 34460, save });
const lua = (code: string) => server.rcon.command("/sc " + code);
const modLua = (code: string) => server.rcon.command("/sc __ai-engineer__ " + code);

try {
  await lua('rcon.print("ok")');
  await lua("game.tick_paused=true rcon.print('paused')");
  console.log(
    await modLua(
      `local goals for k,v in pairs(package.loaded) do if k:find("scripts.goals") then goals=v end end ` +
        `local owner, rec for o,r in pairs(storage.engineers) do owner, rec=o, r end local s=rec.auto local out={} local P={x=${x},y=${y}} local R=${r} ` +
        `local near=function(p) return math.abs(p.x-P.x)<=R and math.abs(p.y-P.y)<=R end ` +
        `for _,e in pairs(rec.entity.surface.find_entities_filtered{position=P,radius=R}) do if e.type~="resource" then ` +
        `out[#out+1]="ENTITY "..e.name.." @"..e.position.x..","..e.position.y.." dir "..e.direction.." ours "..tostring((rec.built or {})[e.unit_number or -1]~=nil) end end ` +
        `local fr=s.ore_plan and s.ore_plan.frame out[#out+1]="frame "..serpent.line(fr and {x0=fr.x0,y0=fr.y0,X=fr.X,m=fr.m}).." slots "..serpent.line(s.bus_slots) ` +
        `for _,pl in ipairs(s.ore_plan and s.ore_plan.places or {}) do if near(pl[2].position) then out[#out+1]="ORE PLAN "..pl[1].." @"..serpent.line(pl[2].position) end end ` +
        `for _,g in ipairs(goals.list(owner)) do local b=g.block out[#out+1]="GOAL "..g.id.." "..tostring(g.item).." "..g.status.." slot "..tostring(b and b.bus and b.bus.slot) ` +
        `for _,pl in ipairs(b and b.bus and b.bus.places or {}) do if near(pl[2].position) then out[#out+1]="  bus part "..pl[1].." @"..serpent.line(pl[2].position) end end ` +
        `if b and b.area then out[#out+1]="  area "..serpent.line(b.area) end end ` +
        `rcon.print(table.concat(out,"\\n"))`,
    ),
  );
} finally {
  await server.stop();
}
