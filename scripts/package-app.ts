// Builds the helper app for Windows and both kinds of Mac, ready to attach to a GitHub release:
// dist/ai-engineer.exe, and dist/ai-engineer-mac-<arm64|intel>.zip each holding `ai-engineer`,
// plus dist/SHA256SUMS.txt.
// The Mac builds are zipped because a downloaded bare file loses its executable bit; the zip
// stores it as a Unix mode, which macOS's Archive Utility restores.
import { createHash } from "node:crypto";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { zipSync } from "fflate";
import { ROOT } from "./factorio";

const MACS = { arm64: "bun-darwin-arm64", intel: "bun-darwin-x64" } as const;

const compile = (target: string, outfile: string) => {
  const result = Bun.spawnSync(["bun", "build", "app/src/main.ts", "--compile", `--target=${target}`, "--outfile", outfile], {
    cwd: ROOT,
    stdout: "inherit",
    stderr: "inherit",
  });
  if (result.exitCode !== 0) throw new Error(`Building ${outfile} failed (is ai-engineer.exe still running?)`);
};

compile("bun-windows-x64", join(ROOT, "dist", "ai-engineer.exe"));
for (const [name, target] of Object.entries(MACS)) {
  const binary = join(ROOT, "dist", `ai-engineer-mac-${name}`);
  compile(target, binary);
  const zip = zipSync({ "ai-engineer": [readFileSync(binary), { os: 3, attrs: 0o100755 << 16 }] });
  writeFileSync(`${binary}.zip`, zip);
  rmSync(binary);
  console.log(`Wrote ${binary}.zip`);
}

// Checksums for the release notes, so players can check their download matches what was published.
const files = ["ai-engineer.exe", ...Object.keys(MACS).map((name) => `ai-engineer-mac-${name}.zip`)];
const sums = files.map((name) => `${createHash("sha256").update(readFileSync(join(ROOT, "dist", name))).digest("hex")}  ${name}`);
writeFileSync(join(ROOT, "dist", "SHA256SUMS.txt"), sums.join("\n") + "\n");
console.log(`\nSHA-256 (also in dist/SHA256SUMS.txt):\n${sums.join("\n")}`);
