// Diagnostic: what the engineer's drills, furnaces and plate chests are doing in a save.
// Usage: bun scripts/diag-base.ts <save.zip>
import { startServer } from "./factorio";

const save = process.argv[2]!;
const server = await startServer({ port: 34456, save });
const lua = (code: string) => server.rcon.command("/sc " + code);
const modLua = (code: string) => server.rcon.command("/sc __ai-engineer__ " + code);

try {
  await lua('rcon.print("ok")');
  await lua("game.tick_paused=true rcon.print('paused')");
  console.log(
    await modLua(
      `local rec for _,r in pairs(storage.engineers) do rec=r end local s=rec.entity.surface local out={} ` +
        `local names={} for k,v in pairs(defines.entity_status) do names[v]=k end ` +
        `local drills={} for _,d in pairs(rec.built) do if d.valid and d.type=="mining-drill" then ` +
        `local left=0 for _,r in ipairs(s.find_entities_filtered{type="resource",area={{d.position.x-2.5,d.position.y-2.5},{d.position.x+2.5,d.position.y+2.5}}}) do left=left+r.amount end ` +
        `drills[#drills+1]=d.name.." @"..math.floor(d.position.x)..","..math.floor(d.position.y).." "..tostring(names[d.status]).." ore left "..left end end ` +
        `out[#out+1]="DRILLS ("..#drills.."):\\n  "..table.concat(drills,"\\n  ") ` +
        `local fs={} for _,f in pairs(rec.built) do if f.valid and f.type=="furnace" then local src=f.get_inventory(defines.inventory.crafter_input) ` +
        `fs[#fs+1]=f.name.." @"..math.floor(f.position.x)..","..math.floor(f.position.y).." "..tostring(names[f.status]).." in:"..(src and src.get_item_count() or 0) end end ` +
        `out[#out+1]="FURNACES ("..#fs.."):\\n  "..table.concat(fs,"\\n  ") ` +
        `local g=rec.auto and rec.auto.ore_plan out[#out+1]="ore plan site "..serpent.line(g and g.site).." done "..tostring(g and g.done) ` +
        `out[#out+1]="research: "..tostring(rec.entity.force.current_research and rec.entity.force.current_research.name) ` +
        `out[#out+1]="engineer inv: "..serpent.line(rec.entity.get_main_inventory().get_contents()) ` +
        `local plan for k,v in pairs(package.loaded) do if k:find("scripts.plan") then plan=v end end ` +
        `local m = plan and plan.machine_for(plan.context(rec.entity.force), "smelting") out[#out+1]="smelting machine: "..tostring(m and m.proto.name).." built "..tostring(m and m.built) ` +
        `rcon.print(table.concat(out,"\\n"))`,
    ),
  );
} finally {
  await server.stop();
}
