import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Agent } from "../src/agent";
import { AUTO_TURNS, IDLE_NUDGE_MAX_TICKS, IDLE_NUDGE_TICKS, RESUME_TICKS, Runner, type RunnerState } from "../src/runner";
import { FakeAPI, FakeGame, call, text } from "./fakes";

function setup(responses: ConstructorParameters<typeof FakeAPI>[0]) {
  const dir = mkdtempSync(join(tmpdir(), "aie-runner-"));
  const api = new FakeAPI(responses);
  const game = new FakeGame();
  const runner = new Runner(game.asGame(), new Agent(api.asAPI(), { model: "opus", effort: "medium" }, dir, "s"));
  return { api, game, runner, cleanup: () => rmSync(dir, { recursive: true }) };
}

test("old history is skipped; an owner message starts a turn with the current view", async () => {
  const t = setup([{ stop_reason: "end_turn", content: [text("Hello!")] }]);
  try {
    t.game.push("message", { text: "from before the app started" });
    await t.runner.tick(); // the first poll only records where to start
    expect(t.runner.busy).toBe(false);
    t.game.push("message", { text: "hi" });
    await t.runner.tick();
    await t.runner.idle();
    const input = t.api.requests[0]!.messages[0].content[0].text as string;
    expect(input).toContain("[Your owner says] hi");
    expect(input).not.toContain("from before");
    expect(input).toContain("[What you see now]");
    expect(t.game.said).toEqual([{ text: "Hello!", progress: false }]);
    expect(t.game.statuses).toEqual(["Thinking... · $0.00", "$0.00 spent"]); // the cost shows even at $0
  } finally {
    t.cleanup();
  }
});

test("a local model is free: the status shows no cost", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-runner-"));
  const api = new FakeAPI([{ stop_reason: "end_turn", content: [text("Hello!")] }]);
  const game = new FakeGame();
  const local = { url: "http://localhost:11434", model: "qwen3:4b", context: 16384, think: true };
  const agent = new Agent(api.asAPI(), { model: "opus", effort: "medium", provider: "local", local }, dir, "s");
  const runner = new Runner(game.asGame(), agent);
  try {
    await runner.tick();
    game.push("message", { text: "hi" });
    await runner.tick();
    await runner.idle();
    expect(game.statuses).toEqual(["Thinking...", ""]);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("job events wake the AI, but only a limited number of times per owner message", async () => {
  const replies = Array.from({ length: AUTO_TURNS + 1 }, () => ({ stop_reason: "end_turn", content: [text("ok")] }));
  const t = setup(replies);
  try {
    await t.runner.tick();
    t.game.push("job_done", { job: "mining iron-ore", result: { mined: 10 } });
    await t.runner.tick();
    expect(t.runner.busy).toBe(false); // events alone, before any owner message, start nothing
    t.game.push("message", { text: "mine iron" });
    await t.runner.tick();
    await t.runner.idle();
    expect(t.api.requests).toHaveLength(1);
    for (let i = 0; i < AUTO_TURNS + 3; i++) {
      t.game.push("job_done", { job: "x", result: {} });
      await t.runner.tick();
      await t.runner.idle();
    }
    expect(t.api.requests).toHaveLength(1 + AUTO_TURNS);
    expect(t.api.requests[1]!.messages.at(-1).content[0].text).toContain("job_done: x");
  } finally {
    t.cleanup();
  }
});

test("a restarted app carries on with recent events and skips stale ones", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-runner-"));
  const api = new FakeAPI([
    { stop_reason: "end_turn", content: [text("Mining.")] },
    { stop_reason: "end_turn", content: [text("Iron is mined.")] },
  ]);
  const game = new FakeGame();
  let state: RunnerState | null = null;
  const store = { load: () => state, save: (s: RunnerState) => void (state = s) };
  const agent = () => new Agent(api.asAPI(), { model: "opus", effort: "medium" }, dir, "s");
  try {
    const first = new Runner(game.asGame(), agent(), undefined, store);
    await first.tick();
    game.push("message", { text: "mine iron" });
    await first.tick();
    await first.idle();
    await first.tick();

    // The app is closed; jobs keep finishing in the game.
    game.push("job_done", { job: "old job" });
    game.tick = RESUME_TICKS + 100;
    game.push("job_done", { job: "mining iron-ore" });

    const second = new Runner(game.asGame(), agent(), undefined, store);
    await second.tick();
    await second.idle();
    expect(api.requests).toHaveLength(2);
    const input = api.requests[1]!.messages.at(-1).content[0].text as string;
    expect(input).toContain("job_done: mining iron-ore");
    expect(input).not.toContain("old job");

    // A status left over from an app that stopped mid-turn is cleared on start.
    const before = game.statuses.length;
    await new Runner(game.asGame(), agent(), undefined, store).tick();
    expect(game.statuses.slice(before)).toEqual(["$0.00 spent"]);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("event turns that just start the next step stay out of the game chat; running out of turns is announced once", async () => {
  const replies = [
    { stop_reason: "end_turn", content: [text("On it.")] },
    // Starting the job ends each turn, so the note comes in the same response.
    ...Array.from({ length: AUTO_TURNS }, (_, i) => ({
      stop_reason: "tool_use",
      content: [text("Collecting coal."), call(`m${i}`, "mine", { name: "coal" })],
    })),
  ];
  const t = setup(replies);
  try {
    await t.runner.tick();
    t.game.push("message", { text: "get coal" });
    await t.runner.tick();
    await t.runner.idle();
    for (let i = 0; i < AUTO_TURNS + 2; i++) {
      t.game.push("job_done", { job: "x", result: {} });
      await t.runner.tick();
      await t.runner.idle();
    }
    expect(t.game.said.filter((s) => !s.progress).map((s) => s.text)).toEqual([
      "On it.",
      "I've paused to keep API costs in check. Send me a message to keep going.",
    ]);
    expect(t.game.said.filter((s) => s.text === "Collecting coal." && s.progress)).toHaveLength(AUTO_TURNS);
  } finally {
    t.cleanup();
  }
});

test("stop aborts the running turn", async () => {
  const t = setup([{ stop_reason: "tool_use", content: [call("t", "mine", { name: "coal" })] }]);
  try {
    let release: () => void = () => {};
    t.game.handlers.mine = () =>
      new Promise((resolve) => (release = () => resolve({ ok: true, result: { started: "mining coal" } })));
    await t.runner.tick();
    t.game.push("message", { text: "mine coal" });
    await t.runner.tick();
    await Bun.sleep(20); // the turn is now waiting on the mine tool
    t.game.push("stop");
    await t.runner.tick();
    release();
    await t.runner.idle();
    expect(t.game.said.some((s) => s.text === "Stopped.")).toBe(true);
    expect(t.api.requests).toHaveLength(1); // no further model calls after stop
  } finally {
    t.cleanup();
  }
});

test("clearing the chat stops the turn and starts a new conversation", async () => {
  const t = setup([
    { stop_reason: "tool_use", content: [call("t", "mine", { name: "coal" })] },
    { stop_reason: "end_turn", content: [text("Hi again.")] },
  ]);
  try {
    let release: () => void = () => {};
    t.game.handlers.mine = () =>
      new Promise((resolve) => (release = () => resolve({ ok: true, result: { started: "mining coal" } })));
    await t.runner.tick(); // the first poll only records where to start
    t.game.push("message", { text: "mine coal" });
    await t.runner.tick();
    await Bun.sleep(20); // the turn is now waiting on the mine tool
    t.game.push("reset");
    t.game.keepBusy = true;
    await t.runner.tick();
    expect(t.runner.busy).toBe(true); // keep-busy turning on waits for the reset
    release();
    await t.runner.idle();
    t.game.push("message", { text: "hello" });
    await t.runner.tick();
    await t.runner.idle();
    expect(t.api.requests).toHaveLength(2);
    const messages = t.api.requests[1]!.messages;
    expect(messages).toHaveLength(1); // nothing from before the reset
    expect(messages[0].content[0].text).toContain("[Your owner says] hello");
    expect(messages[0].content[0].text).toContain("Autopilot mode is now ON");
  } finally {
    t.cleanup();
  }
});

test("keep-busy mode: turning it on or off costs no turn; the AI is told on the next one", async () => {
  const t = setup([
    { stop_reason: "end_turn", content: [text("ok")] },
    { stop_reason: "end_turn", content: [text("ok")] },
  ]);
  try {
    await t.runner.tick();
    t.game.keepBusy = true;
    t.game.autopilot = true; // the mod's build order takes it from here
    await t.runner.tick();
    expect(t.runner.busy).toBe(false);
    t.game.push("message", { text: "hi" });
    await t.runner.tick();
    await t.runner.idle();
    expect(t.api.requests).toHaveLength(1);
    expect(t.api.requests[0]!.messages.at(-1).content[0].text).toContain("Autopilot mode is now ON");
    t.game.keepBusy = false;
    await t.runner.tick();
    expect(t.runner.busy).toBe(false); // turning it off doesn't cost a turn
    t.game.push("message", { text: "hi again" });
    await t.runner.tick();
    await t.runner.idle();
    expect(t.api.requests[1]!.messages.at(-1).content[0].text).toContain("Autopilot mode is now OFF");
  } finally {
    t.cleanup();
  }
});

test("a local model's automatic turns aren't limited (it's free): it keeps going until told to stop", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-runner-"));
  const api = new FakeAPI(Array.from({ length: AUTO_TURNS + 4 }, () => ({ stop_reason: "end_turn", content: [text("ok")] })));
  const game = new FakeGame();
  const local = { url: "http://localhost:11434", model: "qwen3:4b", context: 16384, think: true };
  const runner = new Runner(game.asGame(), new Agent(api.asAPI(), { model: "opus", effort: "medium", provider: "local", local }, dir, "s"));
  try {
    await runner.tick();
    game.push("message", { text: "what's the plan?" }); // not a request, so the "ok" replies aren't nudged
    await runner.tick();
    await runner.idle();
    game.keepBusy = true;
    for (let i = 0; i < AUTO_TURNS + 3; i++) {
      game.push("job_done", { job: "x", result: {} });
      await runner.tick();
      await runner.idle();
    }
    expect(api.requests).toHaveLength(AUTO_TURNS + 4);
    expect(game.said.some((s) => s.text.includes("I've stopped here"))).toBe(false);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("finished research waits for the next turn; the owner dying wakes the engineer", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-runner-"));
  const done = { stop_reason: "end_turn", content: [text("Nice work!")] };
  const api = new FakeAPI([done, done]);
  const game = new FakeGame();
  const runner = new Runner(game.asGame(), new Agent(api.asAPI(), { model: "opus", effort: "medium" }, dir, "s"));
  try {
    await runner.tick();
    game.push("research_finished", { name: "automation" });
    await runner.tick();
    await runner.idle();
    expect(api.requests).toHaveLength(0);
    game.push("message", { text: "how's it going" });
    await runner.tick();
    await runner.idle();
    expect(api.requests[0]!.messages[0].content[0].text).toContain("research_finished: automation");
    game.push("owner_died", { cause: "small-biter" });
    await runner.tick();
    await runner.idle();
    expect(api.requests).toHaveLength(2);
    expect(JSON.stringify(api.requests[1]!.messages.at(-1))).toContain("owner_died: your owner was killed by small-biter");
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("other players' messages are labelled, and cheats only run on the owner's requests", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-runner-"));
  const cheat = { stop_reason: "tool_use", content: [call("c", "cheat_items", { item: "iron-plate", count: 10 })] };
  const done = { stop_reason: "end_turn", content: [text("ok")] };
  const api = new FakeAPI([cheat, done, cheat, done]);
  const game = new FakeGame();
  const local = { url: "http://localhost:11434", model: "qwen3:4b", context: 16384, think: true, cheats: true, everyone: true };
  const runner = new Runner(game.asGame(), new Agent(api.asAPI(), { model: "opus", effort: "medium", provider: "local", local }, dir, "s"));
  const turn = async (data: Record<string, unknown>) => {
    game.push("message", data);
    await runner.tick();
    await runner.idle();
  };
  try {
    await runner.tick();
    await turn({ text: "make plates", from: "Bob" });
    expect(api.requests[0]!.messages[0].content[0].text).toContain("[Player Bob says] make plates");
    expect(api.requests[0]!.tools.map((t: { name: string }) => t.name)).toContain("run_lua");
    expect(api.requests[0]!.system).toContain("All players can talk to you");
    expect(game.calls.some((c) => c.name === "cheat_items")).toBe(false); // refused: Bob asked
    await turn({ text: "make plates" });
    expect(game.calls.filter((c) => c.name === "cheat_items")).toHaveLength(1); // the owner asked
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("with keep-busy off, a local model told only hello is reminded to just reply and can't start work", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-runner-"));
  const api = new FakeAPI([
    { stop_reason: "tool_use", content: [text("Hello! Starting the early-game plan."), call("m", "mine", { name: "wood" })] },
    { stop_reason: "end_turn", content: [text("Hello!")] },
    { stop_reason: "tool_use", content: [call("m1b", "mine", { name: "wood" })] },
    { stop_reason: "end_turn", content: [text("You're welcome!")] },
    { stop_reason: "tool_use", content: [call("m2", "mine", { name: "wood" })] },
  ]);
  const game = new FakeGame();
  const local = { url: "http://localhost:11434", model: "qwen3:4b", context: 16384, think: true };
  const runner = new Runner(game.asGame(), new Agent(api.asAPI(), { model: "opus", effort: "medium", provider: "local", local }, dir, "s"));
  try {
    await runner.tick();
    game.push("message", { text: "Hello!" });
    await runner.tick();
    await runner.idle();
    expect(api.requests[0]!.messages[0].content[0].text).toContain("Autopilot mode is off: do what was asked");
    expect(game.calls.some((c) => c.name === "mine")).toBe(false);
    game.push("message", { text: "okay thanks again" }); // thanks is chat too
    await runner.tick();
    await runner.idle();
    expect(game.calls.some((c) => c.name === "mine")).toBe(false);
    game.push("message", { text: "get me wood" });
    await runner.tick();
    await runner.idle();
    expect(game.calls.some((c) => c.name === "mine")).toBe(true); // a real request works
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("keep-busy mode: a local model isn't woken when there's nothing to do (it would improvise)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-runner-"));
  const api = new FakeAPI([{ stop_reason: "end_turn", content: [text("ok")] }]);
  const game = new FakeGame();
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const runner = new Runner(game.asGame(), new Agent(api.asAPI(), { model: "opus", effort: "medium", provider: "local", local }, dir, "s"));
  try {
    await runner.tick();
    game.keepBusy = true;
    game.autopilot = false;
    for (const tick of [10, 10 + IDLE_NUDGE_TICKS, 10 + IDLE_NUDGE_MAX_TICKS * 3]) {
      game.tick = tick;
      await runner.tick();
      await runner.idle();
    }
    expect(api.requests).toHaveLength(0);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("keep-busy mode: automatic turns aren't limited", async () => {
  const replies = Array.from({ length: AUTO_TURNS + 4 }, () => ({ stop_reason: "end_turn", content: [text("ok")] }));
  const t = setup(replies);
  try {
    await t.runner.tick();
    t.game.keepBusy = true;
    t.game.busy = true; // a job is running, so idle wake-ups stay out of this
    t.game.push("message", { text: "what are you up to" });
    await t.runner.tick();
    await t.runner.idle();
    for (let i = 0; i < AUTO_TURNS + 3; i++) {
      t.game.push("job_done", { job: "x", result: {} });
      await t.runner.tick();
      await t.runner.idle();
    }
    expect(t.api.requests).toHaveLength(AUTO_TURNS + 4);
    expect(t.game.said.some((s) => s.text.includes("paused"))).toBe(false);
  } finally {
    t.cleanup();
  }
});

test("keep-busy mode: once the build order is done, nothing running wakes the AI, waiting longer while wake-ups start nothing", async () => {
  const replies = Array.from({ length: 4 }, () => ({ stop_reason: "end_turn", content: [text("ok")] }));
  const t = setup(replies);
  const at = async (tick: number) => {
    t.game.tick = tick;
    await t.runner.tick();
    await t.runner.idle();
    return t.api.requests.length;
  };
  try {
    await t.runner.tick();
    t.game.keepBusy = true;
    t.game.autopilot = true;
    expect(await at(0)).toBe(0); // the build order runs: no turns
    expect(await at(IDLE_NUDGE_MAX_TICKS * 2)).toBe(0);
    t.game.autopilot = false; // done
    expect(await at(10)).toBe(0); // idle from here
    expect(await at(10 + IDLE_NUDGE_TICKS - 1)).toBe(0);
    expect(await at(10 + IDLE_NUDGE_TICKS)).toBe(1);
    const woken = t.api.requests[0]!.messages.at(-1).content[0].text as string;
    expect(woken).toContain("idle: autopilot mode is on, but the game's own build order");
    expect(woken).toContain("Autopilot mode is now ON"); // told on its first turn
    const start = 10 + IDLE_NUDGE_TICKS + 1; // that wake-up started nothing: the next one waits twice as long
    expect(await at(start)).toBe(1);
    expect(await at(start + IDLE_NUDGE_TICKS)).toBe(1);
    expect(await at(start + 2 * IDLE_NUDGE_TICKS)).toBe(2);
    // A running job resets the wait; nothing is woken while it runs.
    t.game.busy = true;
    expect(await at(100_000)).toBe(2);
    t.game.busy = false;
    expect(await at(100_001)).toBe(2);
    expect(await at(100_001 + IDLE_NUDGE_TICKS)).toBe(3);
    // Turned off: no more wake-ups.
    t.game.keepBusy = false;
    expect(await at(200_000)).toBe(3);
    expect(await at(200_000 + IDLE_NUDGE_MAX_TICKS)).toBe(3);
  } finally {
    t.cleanup();
  }
});

test("the build order's new log lines are printed in the terminal, not old ones", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-runner-"));
  const game = new FakeGame();
  const lines: string[] = [];
  const runner = new Runner(game.asGame(), new Agent(new FakeAPI([]).asAPI(), { model: "opus", effort: "medium" }, dir, "s"), (l) => lines.push(l));
  try {
    game.buildLog = [{ n: 1, text: "from before the app started" }];
    await runner.tick();
    game.buildLog.push({ n: 2, text: "building a coal loop" }, { n: 3, text: "refueling machines" });
    await runner.tick();
    await runner.tick();
    expect(lines.filter((l) => l.startsWith("build order:"))).toEqual(["build order: building a coal loop", "build order: refueling machines"]);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("terminal lines the chat window doesn't already show go to it too", async () => {
  const t = setup([
    { stop_reason: "tool_use", content: [call("t", "mine", { name: "coal" })] },
    { stop_reason: "end_turn", content: [text("Mining.")] },
  ]);
  try {
    await t.runner.tick();
    t.game.push("message", { text: "mine coal" });
    await t.runner.tick();
    await t.runner.idle();
    expect(t.game.logged.some((l) => l.includes('tool mine {"name":"coal"}'))).toBe(true);
    expect(t.game.logged.some((l) => l.includes("turn took"))).toBe(true);
    // The owner's message and the reply are already in the window.
    expect(t.game.logged.some((l) => l.includes("mine coal") || l.includes("Mining."))).toBe(false);
  } finally {
    t.cleanup();
  }
});

test("crafting finishing during a job waits for the job; routine events skip the automatic look around", async () => {
  const t = setup([
    { stop_reason: "end_turn", content: [text("On it.")] },
    { stop_reason: "end_turn", content: [text("Done.")] },
  ]);
  try {
    await t.runner.tick();
    t.game.push("message", { text: "build drills" });
    await t.runner.tick();
    await t.runner.idle();
    t.game.busy = true;
    t.game.push("crafting_done", { inventory: [] });
    await t.runner.tick();
    expect(t.runner.busy).toBe(false);
    t.game.busy = false;
    t.game.push("job_done", { job: "4 steps", result: {} });
    await t.runner.tick();
    await t.runner.idle();
    expect(t.api.requests).toHaveLength(2);
    const input = t.api.requests[1]!.messages.at(-1).content[0].text as string;
    expect(input).toContain("crafting_done");
    expect(input).toContain("job_done: 4 steps");
    expect(input).not.toContain("[What you see now]");
  } finally {
    t.cleanup();
  }
});

test("polls tell the mod while a turn runs, so the build order waits for it", async () => {
  const t = setup([{ stop_reason: "tool_use", content: [call("t", "mine", { name: "coal" })] }]);
  try {
    let release: () => void = () => {};
    t.game.handlers.mine = () => new Promise((resolve) => (release = () => resolve({ ok: true, result: { started: "mining coal" } })));
    await t.runner.tick();
    t.game.push("message", { text: "mine coal" });
    await t.runner.tick();
    await Bun.sleep(20); // the turn is now waiting on the mine tool
    await t.runner.tick();
    release();
    await t.runner.idle();
    await t.runner.tick();
    expect(t.game.thinking).toEqual([false, false, true, false]);
  } finally {
    t.cleanup();
  }
});

test("the estimated cost is added up and shown in the status", async () => {
  const t = setup([
    {
      stop_reason: "end_turn",
      content: [text("Hi")],
      model: "claude-sonnet-5-5",
      usage: { input_tokens: 1000, output_tokens: 1000, cache_read_input_tokens: 1_000_000, cache_creation_input_tokens: 0 },
    } as any,
  ]);
  try {
    await t.runner.tick();
    t.game.push("message", { text: "hi" });
    await t.runner.tick();
    await t.runner.idle();
    // 1000 * $2 + 1000 * $10 + 1M * $0.20, per million tokens = $0.212
    expect(t.game.statuses.at(-1)).toBe("$0.21 spent");
  } finally {
    t.cleanup();
  }
});
