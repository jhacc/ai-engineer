// Copies the mod into your Factorio mods folder and enables it. Restart Factorio afterwards.
import { cpSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { ROOT } from "./factorio";

const mods =
  process.env.FACTORIO_MODS ||
  (process.platform === "win32"
    ? join(process.env.APPDATA || join(homedir(), "AppData", "Roaming"), "Factorio", "mods")
    : process.platform === "darwin"
      ? join(homedir(), "Library", "Application Support", "factorio", "mods")
      : join(homedir(), ".factorio", "mods"));
if (!existsSync(mods)) throw new Error(`No Factorio mods folder at ${mods} (set FACTORIO_MODS)`);
const target = join(mods, "ai-engineer");
rmSync(target, { recursive: true, force: true });
cpSync(join(ROOT, "mod"), target, { recursive: true });
const listPath = join(mods, "mod-list.json");
const list = existsSync(listPath) ? JSON.parse(readFileSync(listPath, "utf8")) : { mods: [{ name: "base", enabled: true }] };
const entry = list.mods.find((m: { name: string }) => m.name === "ai-engineer");
if (entry) entry.enabled = true;
else list.mods.push({ name: "ai-engineer", enabled: true });
writeFileSync(listPath, JSON.stringify(list, null, 2));
console.log(`Installed AI Engineer into ${target}. Restart Factorio to load it.`);
