import { copyFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import Anthropic from "@anthropic-ai/sdk";
import {
  DEFAULT_CONTEXT,
  DEFAULT_HUMOR,
  DEFAULT_MODEL,
  endpointFromEnv,
  ENV_KEYS,
  envPath,
  HUMOR_LABELS,
  LOCAL_DEFAULTS,
  MODELS,
  saveConfig,
  saveEnv,
  type Config,
  type EndpointModel,
  type Humor,
  type LocalModel,
  type ModelKey,
} from "./config";
import { listModels } from "./endpoint";

const ask = (question: string, fallback = "") => (prompt(question) ?? "").trim() || fallback;

/** Factorio's config.ini for this user, if it exists. */
export function factorioConfigPath(): string | null {
  const candidates =
    process.platform === "win32"
      ? [join(process.env.APPDATA || join(homedir(), "AppData", "Roaming"), "Factorio", "config", "config.ini")]
      : process.platform === "darwin"
        ? [join(homedir(), "Library", "Application Support", "factorio", "config", "config.ini")]
        : [join(homedir(), ".factorio", "config", "config.ini")];
  return candidates.find((path) => existsSync(path)) ?? null;
}

function factorioRunning(): boolean {
  if (process.platform === "win32") {
    const result = spawnSync("tasklist", ["/FI", "IMAGENAME eq factorio.exe", "/NH"], { encoding: "utf8" });
    return (result.stdout || "").toLowerCase().includes("factorio.exe");
  }
  const result = spawnSync("pgrep", ["-x", "factorio"], { encoding: "utf8" });
  return result.status === 0;
}

/** Read or set the [other] local-rcon-* keys in Factorio's config.ini text. */
export function readRcon(ini: string): { host: string; port: number; password: string } | null {
  const socket = ini.match(/^local-rcon-socket=(.+)$/m)?.[1]?.trim();
  const password = ini.match(/^local-rcon-password=(.+)$/m)?.[1]?.trim();
  if (!socket || !password) return null;
  const at = socket.lastIndexOf(":");
  const port = Number(socket.slice(at + 1));
  return Number.isInteger(port) ? { host: socket.slice(0, at) || "127.0.0.1", port, password } : null;
}

export function writeRcon(ini: string, socket: string, password: string): string {
  const lines = ini.split(/\r?\n/);
  const set = (key: string, value: string) => {
    const index = lines.findIndex((line) => new RegExp(`^;?\\s*${key}=`).test(line));
    if (index >= 0) {
      lines[index] = `${key}=${value}`;
      return;
    }
    let section = lines.findIndex((line) => line.trim() === "[other]");
    if (section < 0) {
      lines.push("", "[other]");
      section = lines.length - 1;
    }
    lines.splice(section + 1, 0, `${key}=${value}`);
  };
  set("local-rcon-socket", socket);
  set("local-rcon-password", password);
  return lines.join(ini.includes("\r\n") ? "\r\n" : "\n");
}

/** Prints an option's explanation the first time it's asked; after that, its question is enough. */
const explain = (first: boolean, ...lines: string[]) => {
  if (first) for (const line of lines) console.log(line);
};

const yesNo = (question: string, current: boolean | undefined) =>
  ask(`${question} [${current ? "Y/n" : "y/N"}] `, current ? "y" : "n").toLowerCase().startsWith("y");

async function askApiKey(previous: string | undefined): Promise<string> {
  explain(
    !previous,
    "\nYour engineer uses Claude through your own Anthropic API key (usage is billed to your account).",
    "Create one at https://console.anthropic.com/settings/keys",
    "Tip: make it in a workspace with a spend limit, just for this app.",
    `It's kept in ${envPath()} as ${ENV_KEYS.anthropic}.\n`,
  );
  while (true) {
    // The saved key was checked when it was entered, so keeping it needs no request.
    const key = ask(previous ? `Anthropic API key [keep ...${previous.slice(-4)}]: ` : "Anthropic API key: ", previous);
    if (key === previous) return key;
    if (!/^sk-ant-[\w-]{20,}$/.test(key)) {
      console.log("That doesn't look like an Anthropic API key (they start with sk-ant-).");
      continue;
    }
    try {
      await new Anthropic({ apiKey: key, maxRetries: 1 }).models.list({ limit: 1 });
      saveEnv(ENV_KEYS.anthropic, key);
      return key;
    } catch (error) {
      console.log(
        error instanceof Anthropic.AuthenticationError
          ? "Anthropic rejected that key. Check it and try again."
          : `Couldn't check the key (${error instanceof Error ? error.message : error}). Try again.`,
      );
    }
  }
}

function askModel(previous: ModelKey | undefined): ModelKey {
  const keys = Object.keys(MODELS) as ModelKey[];
  const start = String(keys.indexOf(previous ?? DEFAULT_MODEL) + 1);
  console.log("\nWhich Claude model should play? Everything the engineer does is paid for with your API key.");
  keys.forEach((key, i) => console.log(`  ${i + 1}. ${MODELS[key].label}`));
  const choice = Number(ask(`Choose 1-${keys.length} [${start}]: `, start));
  return keys[choice - 1] ?? previous ?? DEFAULT_MODEL;
}

function askEffort(previous: Config["effort"] | undefined): Config["effort"] {
  const levels: Config["effort"][] = ["low", "medium", "high"];
  const start = String(levels.indexOf(previous ?? "medium") + 1);
  console.log("\nHow hard should Claude think before acting?");
  explain(!previous, "More effort makes fewer mistakes but each action costs more and takes longer.");
  console.log("  1. Low  2. Medium (recommended)  3. High");
  return levels[Number(ask(`Choose 1-3 [${start}]: `, start)) - 1] ?? previous ?? "medium";
}

function askProvider(previous: Config | null): NonNullable<Config["provider"]> {
  console.log("\nWho should play your engineer?");
  console.log("  1. Claude, through your Anthropic API key (recommended)");
  console.log("  2. A local model on this computer, through Ollama (free, much less capable)");
  console.log("  3. Any OpenAI-compatible server (LiteLLM, vLLM, OpenAI...; address, model and key in .env)");
  const fallback = previous?.provider === "local" ? "2" : previous?.provider === "openai" ? "3" : "1";
  const choice = ask(`Choose 1-3 [${fallback}]: `, fallback);
  return choice === "2" ? "local" : choice === "3" ? "openai" : "anthropic";
}

/** Options for a non-Claude model: cheats and talking to every player. */
function askExtras(previous: Pick<LocalModel, "cheats" | "everyone"> | undefined) {
  explain(
    previous?.cheats === undefined,
    "\nCheats let the engineer spawn items and run any Lua command in your game, which makes up for a",
    "small model's mistakes. Only your own requests can use them; other players' requests can't.",
  );
  const cheats = yesNo("Allow cheats?", previous?.cheats);
  explain(
    previous?.everyone === undefined,
    "\nThe engineer normally only talks to you. It can also take requests from every player in the game",
    "(they type /ai <message>) and hand them items.",
  );
  const everyone = yesNo("Let all players talk to it?", previous?.everyone);
  return { cheats, everyone };
}

async function askEndpoint(previous: EndpointModel | undefined): Promise<EndpointModel> {
  const env = (name: string) => process.env[name]?.trim() ?? "";
  explain(
    !previous,
    "\nAny server with an OpenAI-compatible chat completions API. Its settings are kept in",
    `${envPath()} (${Object.values(ENV_KEYS).slice(1).join(", ")}).`,
  );
  console.log("");
  let url: string;
  let apiKey: string;
  let served: string[] = [];
  while (true) {
    url = ask(env(ENV_KEYS.url) ? `Server address [${env(ENV_KEYS.url)}]: ` : "Server address (e.g. https://host/v1): ", env(ENV_KEYS.url));
    url = url.replace(/\/+$/, "");
    if (!url) continue;
    apiKey = ask(env(ENV_KEYS.key) ? "API key [keep the one in .env]: " : "API key (Enter for none): ", env(ENV_KEYS.key));
    try {
      served = await listModels(url, apiKey);
      break;
    } catch (error) {
      console.log(`Couldn't list the server's models: ${error instanceof Error ? error.message : error}.`);
      if (ask("Use it anyway? [y/N] ", "n").toLowerCase().startsWith("y")) break;
    }
  }
  if (served.length) {
    console.log("Models on the server:");
    served.forEach((name, i) => console.log(`  ${i + 1}. ${name}`));
  }
  let model = "";
  while (!model) {
    const current = env(ENV_KEYS.model);
    const answer = ask(current ? `Model (number or name) [${current}]: ` : "Model (number or name): ", current);
    model = served[Number(answer) - 1] ?? answer;
  }
  const start = env(ENV_KEYS.context) || String(DEFAULT_CONTEXT);
  const context = Number(ask(`Model's context length in tokens [${start}]: `, start));
  saveEnv(ENV_KEYS.url, url);
  saveEnv(ENV_KEYS.key, apiKey);
  saveEnv(ENV_KEYS.model, model);
  saveEnv(ENV_KEYS.context, String(Number.isInteger(context) && context >= 8192 ? context : DEFAULT_CONTEXT));
  return endpointFromEnv(askExtras(previous))!;
}

async function askLocal(previous: LocalModel | undefined): Promise<LocalModel> {
  const start = previous ?? LOCAL_DEFAULTS;
  explain(
    !previous,
    "\nA local model runs free on your own computer, using Ollama (https://ollama.com).",
    "It plays far worse than Claude: expect more mistakes, and slow turns without a graphics card.",
  );
  console.log("");
  const url = ask(`Ollama address [${start.url}]: `, start.url).replace(/\/+$/, "");
  let installed: string[];
  while (true) {
    try {
      const response = await fetch(`${url}/api/tags`);
      installed = ((await response.json()) as { models?: { name: string }[] }).models?.map((m) => m.name) ?? [];
      break;
    } catch {
      ask(`Couldn't reach Ollama at ${url}. Install or start Ollama, then press Enter to try again.`);
    }
  }
  if (installed.length) {
    console.log("Installed models:");
    installed.forEach((name, i) => console.log(`  ${i + 1}. ${name}`));
  } else console.log("No models installed yet.");
  let model: string;
  while (true) {
    const answer = ask(`Model (number or name) [${start.model}]: `, start.model);
    model = installed[Number(answer) - 1] ?? answer;
    if (installed.includes(model) || installed.includes(`${model}:latest`)) break;
    console.log(`${model} isn't installed in Ollama. To download it, open a terminal and run   ollama pull ${model}`);
    if (ask("Use it anyway (after downloading)? [y/N] ", "n").toLowerCase().startsWith("y")) break;
  }
  explain(
    !previous,
    "\nOllama gives models only 4K tokens of context by default, too little for the engineer.",
    "Raise it in the Ollama app (Settings > Context length), or set the OLLAMA_CONTEXT_LENGTH",
    "environment variable and restart Ollama. 16K suits an 8 GB graphics card; more needs more VRAM.",
  );
  const context = Number(ask(`Context length you set in Ollama [${start.context}]: `, String(start.context)));
  explain(
    !previous,
    "\nThinking lets the model reason before each action. It makes far fewer mistakes, but each action",
    "can take a minute or more. Without it, the engineer acts in seconds but often gets things wrong.",
    "(Some models, like qwen3:4b, always think.)",
  );
  const think = !ask(`Let the model think? [${start.think ? "Y/n" : "y/N"}] `, start.think ? "y" : "n").toLowerCase().startsWith("n");
  return { url, model, context: Number.isInteger(context) && context >= 8192 ? context : start.context, think, ...askExtras(previous) };
}

function askHumor(previous: Humor | undefined): Humor {
  const start = previous ?? DEFAULT_HUMOR;
  console.log("\nHow much of a sense of humor should your engineer have?");
  explain(
    previous === undefined,
    "(Stranded on an alien planet, a little company helps. It never jokes instead of working, and replies stay short.)",
  );
  for (const level of [0, 1, 2, 3] as Humor[]) console.log(`  ${level}. ${HUMOR_LABELS[level]}`);
  const choice = Number(ask(`Choose 0-3 [${start}]: `, String(start)));
  return choice in HUMOR_LABELS ? (choice as Humor) : start;
}

async function askRcon(previous: Config["rcon"] | undefined): Promise<Config["rcon"]> {
  explain(
    !previous,
    "\nThe app talks to Factorio over RCON, which Factorio opens when you host a multiplayer game",
    "(Multiplayer > Host new game, or Host saved game; it can be private and just you).",
  );
  const path = factorioConfigPath();
  const ini = path ? readFileSync(path, "utf8") : null;
  const existing = ini ? readRcon(ini) : null;
  if (existing) {
    console.log(`Found RCON settings in ${path} (${existing.host}:${existing.port}).`);
    return existing;
  }
  if (path && ini && ask("Turn on RCON in Factorio's settings for you? [Y/n] ", "y").toLowerCase().startsWith("y")) {
    while (factorioRunning()) ask("Close Factorio completely first (it overwrites its settings when it exits), then press Enter.");
    const rcon = { host: "127.0.0.1", port: 27015, password: crypto.randomUUID().replaceAll("-", "") };
    copyFileSync(path, path + ".ai-engineer-backup");
    writeFileSync(path, writeRcon(ini, `${rcon.host}:${rcon.port}`, rcon.password));
    console.log(`Done (backup saved as ${path}.ai-engineer-backup).`);
    return rcon;
  }
  const start = previous ?? { host: "127.0.0.1", port: 27015, password: "" };
  console.log("\nEnter your RCON details (for a server: its --rcon-port and --rcon-password).");
  const host = ask(`Host [${start.host}]: `, start.host);
  const port = Number(ask(`Port [${start.port}]: `, String(start.port)));
  const password = ask(start.password ? "Password [keep]: " : "Password: ", start.password);
  return { host, port: Number.isInteger(port) ? port : start.port, password };
}

/**
 * Asks every setting, run at each start: the first time with explanations, after that with the
 * last answers as defaults, so Enter through them keeps everything.
 */
export async function runSetup(previous: Config | null): Promise<Config> {
  console.log(previous ? "=== AI Engineer settings (press Enter to keep each one) ===" : "=== AI Engineer setup ===");
  const provider = askProvider(previous);
  const claude = provider === "anthropic";
  const config: Config = {
    provider,
    // Settings for the option not chosen are kept, so switching back doesn't ask again.
    local: provider === "local" ? await askLocal(previous?.local) : previous?.local,
    endpoint: provider === "openai" ? await askEndpoint(previous?.endpoint) : previous?.endpoint,
    apiKey: claude ? await askApiKey(previous?.apiKey || process.env[ENV_KEYS.anthropic] || undefined) : (previous?.apiKey ?? ""),
    model: claude ? askModel(previous?.model) : (previous?.model ?? DEFAULT_MODEL),
    effort: claude ? askEffort(previous?.effort) : (previous?.effort ?? "medium"),
    humor: askHumor(previous?.humor),
    rcon: await askRcon(previous?.rcon),
    appId: previous?.appId ?? crypto.randomUUID(),
  };
  saveConfig(config);
  console.log(previous ? "\nSettings saved.\n" : "\nSettings saved. Start or host your game, then keep this app running while you play.\n");
  return config;
}
