import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Dollars per million tokens. `cacheWrite` is the 5-minute rate; 1-hour writes cost 2x input (`HOUR_WRITE`). */
type Price = { input: number; output: number; cacheRead: number; cacheWrite: number };
const HOUR_WRITE = 2;

// The first model is the default.
export const MODELS = {
  sonnet: {
    id: "claude-sonnet-5-5",
    label: "Claude Sonnet 5.5 (recommended)",
    updates: true,
    fallback: true,
    price: { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5 } as Price,
  },
  haiku: {
    id: "claude-haiku-5-5",
    label: "Claude Haiku 5.5 (by far the cheapest, less capable)",
    updates: false,
    fallback: false,
    // Prompts over 100K tokens cost 5x as much (longPrompt).
    price: { input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125 } as Price,
    longPrompt: { input: 0.5, output: 2.5, cacheRead: 0.05, cacheWrite: 0.625 } as Price,
  },
  opus: {
    id: "claude-opus-5-5",
    label: "Claude Opus 5.5 (smartest, about twice Sonnet's price)",
    updates: true,
    fallback: true,
    price: { input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5 } as Price,
  },
} as const;
export type ModelKey = keyof typeof MODELS;
export const DEFAULT_MODEL: ModelKey = "sonnet";

export type Usage = {
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens?: number | null;
  cache_creation_input_tokens?: number | null;
  /** The cache writes split by lifetime. */
  cache_creation?: { ephemeral_5m_input_tokens?: number; ephemeral_1h_input_tokens?: number } | null;
};

/** Estimated dollars for one response. `model` is the id that answered (it can differ after a fallback). */
export function costOf(model: string, fallback: ModelKey, usage: Usage | undefined): number {
  if (!usage) return 0;
  const entry: (typeof MODELS)[ModelKey] = Object.values(MODELS).find((m) => m.id === model) ?? MODELS[fallback];
  const cacheRead = usage.cache_read_input_tokens ?? 0;
  const cacheWrite = usage.cache_creation_input_tokens ?? 0;
  const prompt = usage.input_tokens + cacheRead + cacheWrite;
  const price = "longPrompt" in entry && prompt > 100_000 ? entry.longPrompt : entry.price;
  const hourWrite = Math.min(usage.cache_creation?.ephemeral_1h_input_tokens ?? 0, cacheWrite);
  return (
    (usage.input_tokens * price.input +
      usage.output_tokens * price.output +
      cacheRead * price.cacheRead +
      (cacheWrite - hourWrite) * price.cacheWrite +
      hourWrite * price.input * HOUR_WRITE) /
    1_000_000
  );
}

/**
 * A model served on this computer by Ollama (its Anthropic-compatible `/v1/messages`). No caching,
 * compaction or fallback there, so the agent sends a plain request and trims old turns itself.
 */
export type LocalModel = {
  url: string;
  model: string;
  /** The context length Ollama runs the model with (`OLLAMA_CONTEXT_LENGTH` or the app's slider). */
  context: number;
  /** Let the model reason before acting: fewer mistakes, much slower. Some models always reason. */
  think: boolean;
  /** Cheat tools (spawn items, run any Lua in the game), used only on the owner's requests. */
  cheats?: boolean;
  /** Every player can talk to the engineer with /ai and be given items, not just the owner. */
  everyone?: boolean;
};
export const LOCAL_DEFAULTS: LocalModel = { url: "http://localhost:11434", model: "qwen3:4b", context: 16384, think: true };

/**
 * A model on any OpenAI-compatible chat completions server, played like a local model. Its address, model,
 * key and context length come from .env (`ENV_KEYS`); only `cheats` and `everyone` are saved in config.json.
 */
export type EndpointModel = LocalModel & { apiKey: string };
export const DEFAULT_CONTEXT = 128000;

/** How much humor the engineer talks with: 0 none (all business) to 3 (constant banter). */
export type Humor = 0 | 1 | 2 | 3;
export const HUMOR_LABELS: Record<Humor, string> = {
  0: "None: all business",
  1: "Dry: the odd understated remark",
  2: "Witty: a good-humored companion (recommended)",
  3: "Comedian: jokes, puns and banter",
};
export const DEFAULT_HUMOR: Humor = 2;

export type Config = {
  /** "local" uses `local` and "openai" uses `endpoint` instead of Claude; absent means Claude. */
  provider?: "anthropic" | "local" | "openai";
  local?: LocalModel;
  endpoint?: EndpointModel;
  /** From ANTHROPIC_API_KEY in .env; empty when only another model has been set up. */
  apiKey: string;
  model: ModelKey;
  effort: "low" | "medium" | "high";
  /** The engineer's sense of humor, for either model. */
  humor?: Humor;
  rcon: { host: string; port: number; password: string };
  /** Identifies this app install to the mod; pairing binds it to one player per save. */
  appId: string;
};

/** Per-user data folder: config, conversations. */
export function dataDir(): string {
  const base =
    process.env.AI_ENGINEER_HOME ||
    (process.platform === "win32"
      ? join(process.env.APPDATA || join(homedir(), "AppData", "Roaming"), "ai-engineer")
      : process.platform === "darwin"
        ? join(homedir(), "Library", "Application Support", "ai-engineer")
        : join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), "ai-engineer"));
  mkdirSync(base, { recursive: true });
  return base;
}

const file = () => join(dataDir(), "config.json");

/** The LLM settings' variables in `.env` (Bun loads it into process.env at start), never in config.json. */
export const ENV_KEYS = {
  anthropic: "ANTHROPIC_API_KEY",
  url: "LLM_BASE_URL",
  model: "LLM_MODEL",
  key: "LLM_API_KEY",
  context: "LLM_CONTEXT",
} as const;
export const envPath = () => join(process.cwd(), ".env");

/** The OpenAI-compatible model set in .env, or undefined while its address or model is missing. */
export function endpointFromEnv(options?: Pick<LocalModel, "cheats" | "everyone">): EndpointModel | undefined {
  const url = process.env[ENV_KEYS.url]?.trim().replace(/\/+$/, "");
  const model = process.env[ENV_KEYS.model]?.trim();
  if (!url || !model) return undefined;
  const context = Number(process.env[ENV_KEYS.context]);
  return {
    url,
    model,
    apiKey: process.env[ENV_KEYS.key]?.trim() ?? "",
    context: Number.isInteger(context) && context >= 8192 ? context : DEFAULT_CONTEXT,
    think: false,
    cheats: options?.cheats,
    everyone: options?.everyone,
  };
}

/** Sets one variable in `.env`, keeping the rest of the file. */
export function saveEnv(name: string, value: string) {
  const path = envPath();
  const lines = existsSync(path) ? readFileSync(path, "utf8").split(/\r?\n/) : [];
  // Single quotes: Bun would expand a `$` in the key otherwise.
  const line = `${name}='${value}'`;
  const at = lines.findIndex((l) => l.startsWith(`${name}=`));
  if (at >= 0) lines[at] = line;
  else {
    if (lines.at(-1) === "") lines.pop();
    lines.push(line, "");
  }
  writeFileSync(path, lines.join("\n"), { mode: 0o600 });
  process.env[name] = value;
}

export function loadConfig(): Config | null {
  if (!existsSync(file())) return null;
  try {
    const config = JSON.parse(readFileSync(file(), "utf8")) as Config;
    if (!config.rcon?.password || !config.appId) return null;
    // Older versions kept the key in config.json: move it to .env.
    if (config.apiKey) {
      if (!process.env[ENV_KEYS.anthropic]) saveEnv(ENV_KEYS.anthropic, config.apiKey);
      saveConfig(config);
    }
    config.apiKey = process.env[ENV_KEYS.anthropic] ?? "";
    // Without the server in .env, the saved options are kept for when it's set up again.
    config.endpoint = endpointFromEnv(config.endpoint) ?? config.endpoint;
    if (
      config.provider === "local" ? !config.local?.model
      : config.provider === "openai" ? !config.endpoint
      : !config.apiKey
    )
      return null;
    if (config.local) config.local = { ...LOCAL_DEFAULTS, ...config.local };
    if (!(config.model in MODELS)) config.model = DEFAULT_MODEL;
    config.effort ??= "medium";
    if (!(config.humor !== undefined && config.humor in HUMOR_LABELS)) config.humor = DEFAULT_HUMOR;
    return config;
  } catch {
    return null;
  }
}

export function saveConfig(config: Config) {
  // Keys and the endpoint's server settings are in .env.
  const { endpoint } = config;
  const saved = { ...config, apiKey: undefined, endpoint: endpoint && { cheats: endpoint.cheats, everyone: endpoint.everyone } };
  writeFileSync(file() + ".tmp", JSON.stringify(saved, null, 2), { mode: 0o600 });
  renameSync(file() + ".tmp", file());
}

export function configPath() {
  return file();
}
