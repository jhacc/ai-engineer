// Builds dist/ai-engineer_<version>.zip in the layout the Factorio mod portal expects.
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { zipSync } from "fflate";
import { ROOT } from "./factorio";
import pkg from "../package.json";

const info = JSON.parse(readFileSync(join(ROOT, "mod", "info.json"), "utf8"));
if (info.version !== pkg.version) throw new Error(`mod/info.json is ${info.version} but package.json is ${pkg.version}`);
const folder = `ai-engineer_${info.version}`;
const files: Record<string, Uint8Array> = {};
const walk = (dir: string) => {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path);
    else files[`${folder}/${relative(join(ROOT, "mod"), path).replaceAll("\\", "/")}`] = readFileSync(path);
  }
};
walk(join(ROOT, "mod"));
files[`${folder}/LICENSE`] = readFileSync(join(ROOT, "LICENSE"));
mkdirSync(join(ROOT, "dist"), { recursive: true });
const out = join(ROOT, "dist", `${folder}.zip`);
writeFileSync(out, zipSync(files));
console.log(`Wrote ${out} (${Object.keys(files).length} files)`);
