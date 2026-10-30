// Diagnostic: plans the ore lines on a copy of a save and prints why they fail.
// Usage: bun scripts/diag-lines.ts <save.zip>
import { startServer } from "./factorio";

const save = process.argv[2]!;
const server = await startServer({ port: 34450, save });
const lua = (code: string) => server.rcon.command("/sc " + code);
const modLua = (code: string) => server.rcon.command("/sc __ai-engineer__ " + code);
const AP = 'local ap for k,v in pairs(package.loaded) do if k:find("autopilot") then ap=v end end local rec for _,r in pairs(storage.engineers) do rec=r end ';

try {
  await lua('rcon.print("ok")');
  await lua("game.tick_paused=true rcon.print('paused')");
  console.log(await modLua(AP + 'local w=ap.survey(rec) storage.diag_work=ap.lines_plan(rec,w) rec.auto.lines_work=storage.diag_work rcon.print(helpers.table_to_json({lines=storage.diag_work.lines, keep=storage.diag_work.keep, center=storage.diag_work.center, ug=storage.diag_work.ug, nest=storage.diag_work.nest, why=storage.diag_work.why}))'));
  for (let i = 0; i < 400; i++) {
    const r = await modLua(AP + 'local work=rec.auto.lines_work for i=1,20 do if work.done then break end ap.lines_step(rec) end rcon.print(work.done and "done" or work.stage)');
    if (r.trim() === "done") break;
  }
  console.log(await modLua(AP + 'local work=rec.auto.lines_work local out={why=work.why, stale=work.stale, steps=work.steps, site_count=work.site_count, plan=work.plan and work.plan.site, clear=work.plan and work.plan.clear, removable=table_size(work.removable or {}), lines={}} for _,l in ipairs(work.lines) do out.lines[#out.lines+1]={ore=l.ore, anchor=l.anchor, out=l.field and l.field.out, out_dir=l.field and l.field.out_dir} end out.sites={} for _,s in ipairs(work.sites or {}) do out.sites[#out.sites+1]={x0=s.x0,y0=s.y0,score=s.score,entries=s.entries} end rcon.print(helpers.table_to_json(out))'));
} finally {
  await server.stop();
}
