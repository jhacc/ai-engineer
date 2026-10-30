// Diagnostic: why the build order's old red science isn't picked up once the bus's red science runs
// (what cells.move_to_bus checks), in a save.
// Usage: bun scripts/diag-red.ts <save.zip>
import { startServer } from "./factorio";

const save = process.argv[2]!;
const server = await startServer({ port: 34458, save });
const lua = (code: string) => server.rcon.command("/sc " + code);
const modLua = (code: string) => server.rcon.command("/sc __ai-engineer__ " + code);

try {
  await lua('rcon.print("ok")');
  await lua("game.tick_paused=true rcon.print('paused')");
  console.log(
    await modLua(
      `local ap, goals for k,v in pairs(package.loaded) do if k:find("scripts.autopilot") then ap=v elseif k:find("scripts.goals") then goals=v end end ` +
        `local owner, rec for o,r in pairs(storage.engineers) do owner, rec=o, r end local s=rec.auto local out={} ` +
        `out[#out+1]="keep_busy "..tostring((storage.keep_busy or {})[owner]).." science_lanes "..serpent.line(s.science_lanes).." fails move:science "..tostring(s.fails["move:science"]) ` +
        `for _,g in ipairs(goals.runnable(rec, true)) do out[#out+1]=g.id.." "..tostring(g.item).." "..g.status.." block "..tostring(g.block~=nil).." bus "..serpent.line(g.block and g.block.bus).." science "..serpent.line(g.block and g.block.science).." slot keys "..serpent.line(s.bus_slots) end ` +
        `local fr=s.ore_plan and s.ore_plan.frame out[#out+1]="frame "..serpent.line(fr and {x0=fr.x0,y0=fr.y0,X=fr.X,m=fr.m}) ` +
        `local w=ap.survey(rec) out[#out+1]="w.science "..#(w.science or {}).." labs "..#(w.labs or {}).." inserters "..#(w.inserters or {}) ` +
        `out[#out+1]="skipped "..serpent.line(s.skipped) ` +
        `rcon.print(table.concat(out,"\\n"))`,
    ),
  );
} finally {
  await server.stop();
}
