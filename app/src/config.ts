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
  /** "local" uses `local` instead of Claude; absent means Claude. */
  provider?: "anthropic" | "local";
  local?: LocalModel;
  /** Empty when only a local model has been set up. */
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

export function loadConfig(): Config | null {
  if (!existsSync(file())) return null;
  try {
    const config = JSON.parse(readFileSync(file(), "utf8")) as Config;
    if (!config.rcon?.password || !config.appId) return null;
    if (config.provider === "local" ? !config.local?.model : !config.apiKey) return null;
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
  // Owner-only permissions where the OS supports them; the key never leaves this computer
  // except in requests to Anthropic.
  writeFileSync(file() + ".tmp", JSON.stringify(config, null, 2), { mode: 0o600 });
  renameSync(file() + ".tmp", file());
}

export function configPath() {
  return file();
}
