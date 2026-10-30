#!/usr/bin/env bun
// AI Engineer helper app: connects your Factorio game to Claude or a local model. Each start asks
// every setting (the model, its options, humor, RCON), defaulting to the last answers.
import { join } from "node:path";
import Anthropic from "@anthropic-ai/sdk";
import { Agent, warmUp } from "./agent";
import { configPath, dataDir, DEFAULT_HUMOR, HUMOR_LABELS, loadConfig, MODELS } from "./config";
import { Game } from "./game";
import { claimInstance } from "./instance";
import { Rcon } from "./rcon";
import { fileStore, Runner } from "./runner";
import { runSetup } from "./setup";
import pkg from "../../package.json";

const time = () => new Date().toLocaleTimeString();
const log = (line: string) => console.log(`[${time()}] ${line}`);

if (!(await claimInstance())) {
  console.log("AI Engineer is already running in another window. Use that one, or close it first.");
  prompt("Press Enter to close.");
  process.exit(1);
}

const config = await runSetup(loadConfig());
const local = config.provider === "local" ? config.local : undefined;
const label =
  (local ? `local model ${local.model} (${local.context} tokens of context)` : MODELS[config.model].label) +
  ` · humor: ${HUMOR_LABELS[config.humor ?? DEFAULT_HUMOR].split(":")[0]}`;
log(`AI Engineer ${pkg.version} · ${label} · settings in ${configPath()}`);

// Ollama serves the same Messages API on the user's computer and ignores the key.
const api = local
  ? new Anthropic({ apiKey: "ollama", baseURL: local.url, maxRetries: 1, timeout: 10 * 60 * 1000 })
  : new Anthropic({ apiKey: config.apiKey, maxRetries: 3 });

/** Gets the local model loaded and its prompt cached while the owner starts the game, not on their first message. */
function warm(when: string) {
  if (!local) return;
  const started = performance.now();
  warmUp(api, local, config!.humor).then(
    () => log(`Local model ready${when} (${((performance.now() - started) / 1000).toFixed(1)}s)`),
    () => {}, // Ollama not running yet: the first request says so.
  );
}
warm("");

async function connect(): Promise<Rcon> {
  let warned = false;
  while (true) {
    const rcon = new Rcon(config!.rcon);
    try {
      await rcon.connect();
      log(`Connected to Factorio at ${config!.rcon.host}:${config!.rcon.port}`);
      return rcon;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (/password/i.test(message)) {
        log("Factorio rejected the RCON password. Restart the app and enter the right one.");
        process.exit(1);
      }
      if (!warned) log("Waiting for Factorio... host a multiplayer game (it can be private) so RCON is open.");
      warned = true;
      await Bun.sleep(3000);
    }
  }
}

async function pair(game: Game) {
  let code = "";
  let issued = 0;
  while (true) {
    const hello = await game.hello();
    if (hello.paired) return hello;
    if (Date.now() - issued > 9 * 60 * 1000) {
      code = String(Math.floor(100000 + Math.random() * 900000));
      await game.pair(code);
      issued = Date.now();
      console.log(`\n  In Factorio, type:   /ai-pair ${code}\n`);
    }
    await Bun.sleep(1000);
  }
}

async function session(rcon: Rcon) {
  const game = new Game(rcon, config!.appId);
  const hello = await pair(game);
  log(`Paired with ${hello.owner ?? "the owner"} (save ${hello.session}). Say hi with /ai in game.`);
  // Ollama unloads an idle model after 5 minutes, and the game may have taken a while to start.
  warm(" for the game");
  const conversations = join(dataDir(), "conversations");
  const agent = new Agent(api, config!, conversations, hello.session);
  const store = fileStore(join(conversations, `${hello.session.replace(/[^\w-]/g, "")}.state`));
  const runner = new Runner(game, agent, log, store);
  while (true) {
    await runner.tick();
    await Bun.sleep(500);
  }
}

while (true) {
  const rcon = await connect();
  try {
    await session(rcon);
  } catch (error) {
    log(`Lost the game connection: ${error instanceof Error ? error.message : String(error)}`);
    rcon.close();
    await Bun.sleep(2000);
  }
}
