import type { Rcon } from "./rcon";

export type PollItem = {
  id: number;
  kind:
    | "message"
    | "job_done"
    | "job_failed"
    | "crafting_done"
    | "engineer_died"
    | "engineer_respawned"
    | "paired"
    | "stop"
    | "reset"
    | "reminder"
    | "goal_done"
    | "goal_blocked"
    | "research_finished"
    | "owner_died";
  data?: Record<string, unknown>;
  tick: number;
};
export type Poll = {
  paired: boolean;
  owner?: string;
  owner_online?: boolean;
  seq?: number;
  tick?: number;
  items?: PollItem[];
  alive?: boolean;
  busy?: boolean;
  crafting?: boolean;
  keep_busy?: boolean;
  /** Keep-busy's build order (run by the mod) still has work to do. */
  autopilot?: boolean;
  /** The build order's log lines after `buildAfter` (numbered), for the terminal. */
  build_log?: Array<{ n: number; text: string }>;
};
export type ToolResult = { ok: true; result: unknown } | { ok: false; error: string };

/** The mod's `/aie` protocol, for one helper app identified by `app`. */
export class Game {
  constructor(
    readonly rcon: Rcon,
    readonly app: string,
  ) {}

  private async request(op: string, payload: Record<string, unknown> = {}) {
    const text = await this.rcon.command("/aie " + JSON.stringify({ op, app: this.app, ...payload }));
    let response: Record<string, unknown>;
    try {
      response = JSON.parse(text);
    } catch {
      throw new Error(
        text.includes("Unknown command")
          ? "The AI Engineer mod isn't enabled in this game"
          : `Unexpected reply from Factorio: ${text.slice(0, 200)}`,
      );
    }
    return response;
  }

  private async call(op: string, payload: Record<string, unknown> = {}) {
    const response = await this.request(op, payload);
    if (response.ok !== true) throw new Error(String(response.error || "Request failed"));
    return response;
  }

  hello() {
    return this.call("hello") as Promise<{
      mod_version: string;
      session: string;
      tick: number;
      paired: boolean;
      owner?: string;
      owner_online?: boolean;
    }>;
  }
  pair(code: string) {
    return this.call("pair", { code });
  }
  /**
   * `options`: the owner's setup choices the mod enforces (cheat tools, other players talking to the engineer),
   * and whether the AI is in a turn (the build order waits for it).
   */
  poll(after: number, options: { cheats?: boolean; everyone?: boolean; thinking?: boolean; buildAfter?: number } = {}) {
    return this.call("poll", {
      after,
      cheats: options.cheats === true,
      everyone: options.everyone === true,
      thinking: options.thinking === true,
      build_after: options.buildAfter ?? 0,
    }) as Promise<Poll & { ok: true }>;
  }
  testKeepBusy(on: boolean) {
    return this.call("test_keep_busy", { on });
  }
  say(text: string, progress = false) {
    return this.call("say", { text, progress });
  }
  status(text: string) {
    return this.call("status", { text });
  }
  /** A terminal line, shown small and grey in the owner's chat window. */
  log(text: string) {
    return this.call("log", { text });
  }
  /** Tool failures are results for the AI, not exceptions. */
  async tool(name: string, args: unknown): Promise<ToolResult> {
    const response = await this.request("tool", { name, args });
    return response.ok === true
      ? { ok: true, result: response.result }
      : { ok: false, error: String(response.error || "Tool failed") };
  }
  async toolNames() {
    return ((await this.call("tools")).names as string[]) || [];
  }
  testMessage(text: string) {
    return this.call("test_message", { text });
  }
  /** Test-only: the goal planner on a made-up recipe graph. */
  testPlan(payload: { fixture: unknown; item: string; rate?: number; recipe?: string; supplied?: string[] }) {
    return this.call("test_plan", payload) as Promise<{ plan: any }>;
  }
  testSpawn(position?: { x: number; y: number }) {
    return this.call("test_spawn", position ? { position } : {});
  }
}
