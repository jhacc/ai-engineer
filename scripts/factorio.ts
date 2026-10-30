// Starts a disposable headless Factorio server with this mod, for integration tests.
import { spawn, type ChildProcess } from "node:child_process";
import { cpSync, existsSync, mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { Rcon } from "../app/src/rcon";

export const ROOT = resolve(import.meta.dir, "..");

export function factorioBinary(): string {
  const candidates = [
    process.env.FACTORIO_BINARY,
    "C:/Program Files (x86)/Steam/steamapps/common/Factorio/bin/x64/factorio.exe",
    "C:/Program Files/Factorio/bin/x64/factorio.exe",
    `${process.env.HOME}/.steam/steam/steamapps/common/Factorio/bin/x64/factorio`,
    "/Applications/factorio.app/Contents/MacOS/factorio",
  ];
  const found = candidates.find((path) => path && existsSync(path));
  if (!found) throw new Error("Set FACTORIO_BINARY to your factorio executable");
  return found;
}

// With `save`, a copy of that save is loaded instead of a fresh map.
export async function startServer(options: { spaceAge?: boolean; port?: number; save?: string } = {}) {
  const binary = factorioBinary();
  const root = join(ROOT, ".local", "test-server", String(Date.now()));
  const mods = join(root, "mods");
  mkdirSync(mods, { recursive: true });
  cpSync(join(ROOT, "mod"), join(mods, "ai-engineer"), { recursive: true });
  const dlc = !!options.spaceAge;
  writeFileSync(
    join(mods, "mod-list.json"),
    JSON.stringify({
      mods: [
        { name: "base", enabled: true },
        { name: "elevated-rails", enabled: dlc },
        { name: "quality", enabled: dlc },
        { name: "space-age", enabled: dlc },
        { name: "ai-engineer", enabled: true },
      ],
    }),
  );
  const config = join(root, "config.ini");
  const readData = resolve(dirname(binary), "../../data").replaceAll("\\", "/");
  writeFileSync(config, `[path]\nread-data=${readData}\nwrite-data=${root.replaceAll("\\", "/")}\n`);
  const common = ["--config", config, "--mod-directory", mods];
  let output = "";
  const run = (args: string[]) => {
    const child = spawn(binary, [...common, ...args], { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
    const append = (chunk: Buffer) => (output = (output + chunk.toString()).slice(-40000));
    child.stdout!.on("data", append);
    child.stderr!.on("data", append);
    return child;
  };
  if (options.save) {
    cpSync(options.save, join(root, "test.zip"));
  } else {
    const created = run(["--create", join(root, "test.zip"), "--map-gen-seed", "424242"]);
    const code = await new Promise<number | null>((done) => created.on("exit", done));
    if (code !== 0) throw new Error("Creating the test map failed:\n" + output);
  }

  const port = options.port ?? 34398;
  const password = crypto.randomUUID();
  writeFileSync(
    join(root, "server-settings.json"),
    JSON.stringify({ name: "ai-engineer test", description: "Disposable test world", require_user_verification: false, visibility: { public: false, lan: false }, auto_pause: false, autosave_interval: 0 }),
  );
  const server: ChildProcess = run([
    "--start-server", join(root, "test.zip"), "--server-settings", join(root, "server-settings.json"),
    "--rcon-port", String(port), "--rcon-password", password, "--port", String(port - 1), "--bind", "127.0.0.1",
  ]);
  const rcon = new Rcon({ host: "127.0.0.1", port, password });
  const deadline = Date.now() + 90000;
  while (!rcon.connected) {
    if (server.exitCode !== null || Date.now() > deadline) throw new Error("Factorio server didn't start:\n" + output);
    try {
      await rcon.connect();
    } catch {
      await Bun.sleep(300);
    }
  }
  return {
    rcon,
    log: () => output,
    // Saves the game and copies it to `to` (to load again with `save`, e.g. after a failure).
    async keep(to: string) {
      // (Saved over the map it was started from.)
      const saved = join(root, "test.zip");
      const before = statSync(saved).mtimeMs;
      await rcon.command('/sc game.server_save() rcon.print("ok")');
      const deadline = Date.now() + 60000;
      while (statSync(saved).mtimeMs === before && Date.now() < deadline) await Bun.sleep(300);
      await Bun.sleep(3000);
      cpSync(saved, to);
    },
    async stop() {
      rcon.close();
      server.kill();
      await new Promise((done) => (server.exitCode !== null ? done(null) : server.once("exit", done)));
      rmSync(root, { recursive: true, force: true });
    },
  };
}
