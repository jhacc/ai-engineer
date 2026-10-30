import { EventEmitter } from "node:events";
import type { MessagesAPI } from "../src/agent";
import type { Game, Poll, PollItem, ToolResult } from "../src/game";

type Scripted = { content: Array<Record<string, unknown>>; stop_reason: string; stop_details?: unknown };

/** Scripted Messages API: each stream() call returns the next response and records the request. */
export class FakeAPI {
  requests: Array<Record<string, any>> = [];
  constructor(public responses: Scripted[]) {}
  beta = {
    messages: {
      stream: (params: Record<string, any>, options?: { signal?: AbortSignal }) => {
        this.requests.push(structuredClone(params));
        const response = this.responses.shift();
        const emitter = new EventEmitter();
        return {
          on: (event: string, fn: (...args: any[]) => void) => emitter.on(event, fn),
          finalMessage: async () => {
            await Bun.sleep(1);
            if (options?.signal?.aborted) throw new Error("aborted");
            if (!response) throw new Error("No scripted response left");
            return { id: `msg_${this.requests.length}`, ...response };
          },
        };
      },
    },
  };
  asAPI() {
    return this as unknown as MessagesAPI;
  }
}

export const text = (t: string) => ({ type: "text", text: t });
export const call = (id: string, name: string, input: Record<string, unknown> = {}) => ({
  type: "tool_use",
  id,
  name,
  input,
});

/** In-memory stand-in for the mod's /aie protocol. */
export class FakeGame {
  said: Array<{ text: string; progress: boolean }> = [];
  statuses: string[] = [];
  calls: Array<{ name: string; args: unknown }> = [];
  queue: PollItem[] = [];
  seq = 0;
  tick = 0;
  busy = false;
  keepBusy = false;
  autopilot = false;
  /** Whether each poll said the AI was in a turn. */
  thinking: boolean[] = [];
  /** Optional per-tool behavior; defaults to success. */
  handlers: Record<string, (args: unknown) => Promise<ToolResult>> = {};
  /** The build order's log, as the mod keeps it. */
  buildLog: Array<{ n: number; text: string }> = [];
  async poll(after: number, options: { thinking?: boolean; buildAfter?: number } = {}): Promise<Poll & { ok: true }> {
    this.thinking.push(options.thinking === true);
    const lines = this.buildLog.filter((l) => l.n > (options.buildAfter ?? 0));
    return {
      build_log: lines.length ? lines : undefined,
      ok: true,
      paired: true,
      seq: this.seq,
      tick: this.tick,
      items: this.queue.filter((i) => i.id > after),
      busy: this.busy,
      keep_busy: this.keepBusy,
      autopilot: this.autopilot,
    };
  }
  push(kind: PollItem["kind"], data: Record<string, unknown> = {}) {
    this.seq++;
    this.queue.push({ id: this.seq, kind, data, tick: this.tick });
  }
  async say(text: string, progress = false) {
    this.said.push({ text, progress });
    return {};
  }
  async status(text: string) {
    this.statuses.push(text);
    return {};
  }
  logged: string[] = [];
  async log(text: string) {
    this.logged.push(text);
    return {};
  }
  async tool(name: string, args: unknown): Promise<ToolResult> {
    this.calls.push({ name, args });
    const handler = this.handlers[name];
    return handler ? handler(args) : { ok: true, result: { done: name } };
  }
  asGame() {
    return this as unknown as Game;
  }
}
