import { test, expect } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Agent, COMPACT_AT, personality, promptFingerprint, GIVE_NUDGE, giveCountNudge, HAND_OVER_NUDGE, INSERT_NUDGE, localHistory, NUDGE, REQUEST_NUDGE, recentTurns, withoutReasoning, type AgentHooks } from "../src/agent";
import { costOf } from "../src/config";
import { JOB_TOOLS, validate } from "../src/tools";
import { FakeAPI, call, text } from "./fakes";

function setup(responses: ConstructorParameters<typeof FakeAPI>[0], model: "opus" | "haiku" = "opus") {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI(responses);
  const agent = new Agent(api.asAPI(), { model, effort: "medium" }, dir, "save-1");
  const said: Array<[string, boolean]> = [];
  const tools: Array<[string, unknown]> = [];
  const inbox: string[] = [];
  const hooks: AgentHooks = {
    say: (t, p) => void said.push([t, p]),
    tool: async (name, input) => {
      tools.push([name, input]);
      return { ok: true, result: { ok: name } };
    },
    takeMessages: () => inbox.splice(0),
  };
  const saved = () => JSON.parse(readFileSync(join(dir, "save-1.json"), "utf8")).messages;
  return { dir, api, agent, said, tools, hooks, inbox, saved, cleanup: () => rmSync(dir, { recursive: true }) };
}

test("a turn runs tools, speaks progress and final text, and keeps history append-only", async () => {
  const t = setup([
    {
      stop_reason: "tool_use",
      content: [{ type: "thinking", thinking: "Checking the area.", signature: "s" }, call("t1", "observe", { radius: 16 })],
    },
    { stop_reason: "end_turn", content: [text("There's iron to the east.")] },
  ]);
  try {
    t.inbox.push("[Your owner says] also grab wood");
    await t.agent.run("[Your owner says] what's around?", t.hooks, new AbortController().signal);
    expect(t.tools).toEqual([["observe", { radius: 16 }]]);
    expect(t.said).toEqual([
      ["Checking the area.", true],
      ["There's iron to the east.", false],
    ]);
    const [first, second] = t.api.requests;
    expect(first!.model).toBe("claude-opus-5-5");
    expect(first!.thinking).toEqual({ type: "adaptive", display: "updates", block_binding: { prefix_mismatch_behavior: "drop_block" } });
    expect(first!.fallbacks).toBe("default");
    expect(first!.system[0].cache_control).toEqual({ type: "ephemeral", ttl: "1h" });
    expect(first!.cache_control).toEqual({ type: "ephemeral" });
    expect(first!.context_management.edits[0].trigger).toEqual({ type: "input_tokens", value: COMPACT_AT });
    expect(first!.tools.every((tool: any) => tool.eager_input_streaming)).toBe(true);
    expect(second!.messages.slice(0, first!.messages.length)).toEqual(first!.messages);
    const results = second!.messages.at(-1).content;
    expect(results[0]).toMatchObject({ type: "tool_result", tool_use_id: "t1" });
    expect(results[1]).toEqual({ type: "text", text: "[New message] [Your owner says] also grab wood" });
    expect(t.saved()).toHaveLength(4);
  } finally {
    t.cleanup();
  }
});

test("1-hour cache writes cost 2x input, 5-minute writes 1.25x", () => {
  const usage = {
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 2_000_000,
    cache_creation: { ephemeral_1h_input_tokens: 1_000_000, ephemeral_5m_input_tokens: 1_000_000 },
  };
  // Sonnet: 1M * $4 (1 hour) + 1M * $2.50 (5 minutes)
  expect(costOf("claude-sonnet-5-5", "sonnet", usage)).toBeCloseTo(6.5);
});

test("invalid tool input goes back to Claude without running the tool", async () => {
  const t = setup([
    { stop_reason: "tool_use", content: [call("t1", "walk_to", { x: "far" })] },
    { stop_reason: "end_turn", content: [text("ok")] },
  ]);
  try {
    await t.agent.run("go", t.hooks, new AbortController().signal);
    expect(t.tools).toEqual([]);
    expect(t.api.requests[1]!.messages.at(-1).content[0]).toMatchObject({ is_error: true });
  } finally {
    t.cleanup();
  }
});

test("Haiku skips betas it doesn't support, and a refusal gets a polite reply", async () => {
  const t = setup([{ stop_reason: "refusal", content: [] }], "haiku");
  try {
    await t.agent.run("hi", t.hooks, new AbortController().signal);
    expect(t.api.requests[0]!.thinking).toEqual({ type: "adaptive", block_binding: { prefix_mismatch_behavior: "drop_block" } });
    expect(t.api.requests[0]!.betas).toEqual(["compact-2026-01-12", "thinking-binding-controls-2026-08-01"]);
    expect(t.said[0]![0]).toContain("can't help");
  } finally {
    t.cleanup();
  }
});

test("stopping mid-turn answers every pending tool call so the conversation stays valid", async () => {
  const t = setup([
    {
      stop_reason: "tool_use",
      content: [call("a", "mine", { name: "iron-ore" }), call("b", "craft", { recipe: "iron-gear-wheel" })],
    },
  ]);
  try {
    const abort = new AbortController();
    t.hooks.tool = async (name) => {
      abort.abort();
      return { ok: true, result: { started: name } };
    };
    await t.agent.run("go", t.hooks, abort.signal);
    const results = t.saved().at(-1).content;
    expect(results.map((r: any) => r.tool_use_id)).toEqual(["a", "b"]);
    expect(results[1].content).toContain("Stopped");
  } finally {
    t.cleanup();
  }
});

test("only one job starts per response; other tools still run", async () => {
  const t = setup([
    {
      stop_reason: "tool_use",
      content: [call("a", "take", { x: 1, y: 1 }), call("b", "inventory"), call("c", "take", { x: 2, y: 2 })],
    },
    { stop_reason: "end_turn", content: [] },
  ]);
  try {
    await t.agent.run("go", t.hooks, new AbortController().signal);
    expect(t.tools.map(([name]) => name)).toEqual(["take", "inventory"]);
    const results = t.saved()[2].content;
    expect(results[2]).toMatchObject({ tool_use_id: "c", is_error: true });
    expect(results[2].content).toContain("already started a job");
  } finally {
    t.cleanup();
  }
});

test("a research that failed isn't run again in the same turn, and repeating it ends the turn", async () => {
  const again = { stop_reason: "tool_use" as const, content: [call("r", "research", { technology: "red-science" })] };
  const t = setup([
    { stop_reason: "tool_use", content: [call("a", "research", { technology: "red-science" })] },
    again,
    again,
    again,
    { stop_reason: "end_turn", content: [text("never asked for")] },
  ]);
  try {
    t.hooks.tool = async (name, input) => {
      t.tools.push([name, input]);
      return { ok: false, error: "Unknown technology red-science." };
    };
    await t.agent.run("research red science", t.hooks, new AbortController().signal);
    expect(t.tools).toHaveLength(1);
    expect(t.api.requests).toHaveLength(4);
    const repeated = t.saved()[4].content[0];
    expect(repeated).toMatchObject({ is_error: true });
    expect(repeated.content).toContain("You already tried exactly this");
  } finally {
    t.cleanup();
  }
});

test("asked to bring more ore than is mined by hand, a refused mine runs give instead", async () => {
  const t = setup([
    { stop_reason: "tool_use", content: [call("a", "mine", { name: "iron-ore", count: 20 })] },
    { stop_reason: "end_turn", content: [text("I'm building a drill for it.")] },
  ]);
  try {
    t.hooks.tool = async (name, input) => {
      t.tools.push([name, input]);
      if (name === "mine") return { ok: false, error: "Not more than 10 iron-ore by hand: call give or insert instead" };
      return { ok: false, error: "Not started yet: you're building a drill and chest for iron-ore" };
    };
    await t.agent.run("[Your owner says] bring me 20 iron ore", t.hooks, new AbortController().signal);
    expect(t.tools).toEqual([
      ["mine", { name: "iron-ore", count: 20 }],
      ["give", { item: "iron-ore", count: 20 }],
    ]);
    expect(t.saved()[2].content[0].content).toContain("you called give instead: Not started yet");
  } finally {
    t.cleanup();
  }
});

test("any call that failed isn't run again in the same turn", async () => {
  const again = { stop_reason: "tool_use" as const, content: [call("g", "goal", { action: "add", item: "copper-ore", per_minute: 15 })] };
  const t = setup([again, again, again, again, { stop_reason: "end_turn", content: [text("never asked for")] }]);
  try {
    t.hooks.tool = async (name, input) => {
      t.tools.push([name, input]);
      return { ok: false, error: "copper-ore is mined, not made" };
    };
    await t.agent.run("automate copper", t.hooks, new AbortController().signal);
    expect(t.tools).toHaveLength(1);
    expect(t.api.requests).toHaveLength(4);
  } finally {
    t.cleanup();
  }
});

test("steps are validated against the schema of each step's tool", () => {
  expect(validate("steps", { steps: [{ action: "place", item: "stone-furnace", x: 1, y: 2 }, { action: "insert", x: 1, y: 2, item: "coal" }] })).toBeNull();
  expect(validate("steps", { steps: [] })).toContain("1 to 20");
  expect(validate("steps", { steps: [{ action: "follow_me" }] })).toContain("action must be one of");
  expect(validate("steps", { steps: [{ action: "place", item: "stone-furnace", x: 1 }] })).toBe("step 1 (place): Missing y");
  expect(validate("steps", { steps: [{ action: "take", x: 1, y: 2, radius: 3 }] })).toContain("Unknown argument radius");
  expect(JOB_TOOLS.has("steps")).toBe(true);
});

test("a conversation left with unanswered tool calls is repaired on load by appending", () => {
  const t = setup([]);
  try {
    writeFileSync(
      join(t.dir, "save-1.json"),
      JSON.stringify([
        { role: "user", content: [{ type: "text", text: "hi" }] },
        { role: "assistant", content: [call("x", "observe")] },
      ]),
    );
    const agent = new Agent(t.api.asAPI(), { model: "opus", effort: "medium" }, t.dir, "save-1");
    expect(agent.history).toHaveLength(3);
    expect((agent.history[2]!.content as any)[0]).toMatchObject({ tool_use_id: "x", is_error: true });
  } finally {
    t.cleanup();
  }
});

test("thinking saved under an older system prompt is removed once; the conversation is kept", async () => {
  const t = setup([{ stop_reason: "end_turn", content: [text("Still here.")] }]);
  try {
    const thinking = { type: "thinking" as const, thinking: "", signature: "old" };
    writeFileSync(
      join(t.dir, "save-1.json"),
      JSON.stringify([
        { role: "user", content: [{ type: "text", text: "hi" }] },
        { role: "assistant", content: [thinking, text("Hello!")] },
        { role: "user", content: [{ type: "text", text: "again" }] },
        { role: "assistant", content: [thinking] },
      ]),
    );
    const agent = new Agent(t.api.asAPI(), { model: "opus", effort: "medium" }, t.dir, "save-1");
    expect(agent.history[1]!.content as unknown).toEqual([text("Hello!")]);
    expect(agent.history[3]!.content as unknown).toEqual([thinking]); // never left empty
    expect(JSON.parse(readFileSync(join(t.dir, "save-1.json"), "utf8")).fingerprint).toBeString();

    await agent.run("[Your owner says] hi", t.hooks, new AbortController().signal);
    const request = t.api.requests[0]!;
    expect(request.thinking.block_binding).toEqual({ prefix_mismatch_behavior: "drop_block" });
    expect(request.betas).toContain("thinking-binding-controls-2026-08-01");

    // Loading again with the same prompt changes nothing.
    const again = new Agent(t.api.asAPI(), { model: "opus", effort: "medium" }, t.dir, "save-1");
    expect(again.history).toEqual(agent.history);
  } finally {
    t.cleanup();
  }
});

test("a local model gets a plain request, no cost and no raw thinking in the chat", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "end_turn", content: [{ type: "thinking", thinking: "Long raw reasoning...", signature: "" }, text("Hi!")] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:8b", context: 16384, think: true };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const said: string[] = [];
  let spent = 0;
  try {
    await agent.run(
      "[Your owner says] hello",
      { say: (s) => void said.push(s), tool: async () => ({ ok: true, result: {} }), takeMessages: () => [], cost: (d) => void (spent += d) },
      new AbortController().signal,
    );
    const [request] = api.requests;
    expect(request!.model).toBe("qwen3:8b");
    expect(typeof request!.system).toBe("string");
    expect(request!.thinking).toEqual({ type: "enabled", budget_tokens: 5120 });
    for (const key of ["betas", "cache_control", "context_management", "fallbacks", "output_config"])
      expect(request![key]).toBeUndefined();
    expect(request!.tools.some((tool: any) => "eager_input_streaming" in tool)).toBe(false);
    expect(request!.max_tokens).toBe(6144);
    expect(said).toEqual(["Hi!"]);
    expect(spent).toBe(0);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("a local model's turn ends once a job starts, so the next job doesn't replace it", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "tool_use", content: [call("t1", "walk_to", { x: 5, y: 5 })] },
    { stop_reason: "tool_use", content: [call("t2", "mine", { name: "coal" })] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:8b", context: 16384, think: true };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const tools: string[] = [];
  try {
    const hooks: AgentHooks = { say: () => {}, tool: async (name) => (tools.push(name), { ok: true, result: {} }), takeMessages: () => [] };
    await agent.run("[Your owner says] go", hooks, new AbortController().signal);
    expect(tools).toEqual(["walk_to"]);
    expect(api.requests).toHaveLength(1);
    expect(agent.history.at(-1)!.content[0]).toMatchObject({ type: "tool_result", tool_use_id: "t1" });
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("a local model that only announces an action is reminded once to call the tool", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "end_turn", content: [text("I'll mine coal to fuel the drill.")] },
    { stop_reason: "tool_use", content: [call("t1", "mine", { name: "coal" })] },
    { stop_reason: "end_turn", content: [text("I will now place the drill.")] },
    { stop_reason: "end_turn", content: [text("I will place it now.")] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const tools: string[] = [];
  try {
    const hooks: AgentHooks = { say: () => {}, tool: async (name) => (tools.push(name), { ok: true, result: {} }), takeMessages: () => [] };
    await agent.run("[Your owner says] get coal", hooks, new AbortController().signal);
    expect(tools).toEqual(["mine"]);
    expect(agent.history[2]!.content).toEqual([{ type: "text", text: NUDGE }]);
    // The nudge isn't a new turn, so trimming the context never cuts the owner's request off it.
    expect(recentTurns(agent.history, 1)[0]!.content).toEqual([{ type: "text", text: "[Your owner says] get coal" }]);
    // At most once per turn: the second announcement ends the turn.
    await agent.run("[Event] job_done", hooks, new AbortController().signal);
    expect(api.requests).toHaveLength(4);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("a local model that says it handed items over without calling give is reminded to give them", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "end_turn", content: [text("Gave you 6 wood.")] },
    { stop_reason: "tool_use", content: [call("t1", "give", { item: "wood" })] },
    { stop_reason: "end_turn", content: [text("Gave you 6 wood.")] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const tools: string[] = [];
  try {
    const hooks: AgentHooks = { say: () => {}, tool: async (name) => (tools.push(name), { ok: true, result: {} }), takeMessages: () => [] };
    await agent.run('[Game events]\njob_done: mining wood -> {"mined":6,"item":"wood"}', hooks, new AbortController().signal);
    expect(tools).toEqual(["give"]);
    expect(agent.history[2]!.content).toEqual([{ type: "text", text: GIVE_NUDGE }]);
    // Once the give job is done, saying so is just the truth.
    await agent.run('[Game events]\njob_done: giving wood to you -> {"given":6,"item":"wood"}', hooks, new AbortController().signal);
    expect(api.requests).toHaveLength(3);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("a local model claiming more than its give handed over is told the real number; thanks aren't nudged", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "end_turn", content: [text("I've made 10 iron plates and given them to you.")] },
    { stop_reason: "end_turn", content: [text("Sorry, I gave you only 1 iron plate.")] },
    // Thanks for earlier: no give this turn, but no nudge either.
    { stop_reason: "end_turn", content: [text("You're welcome, I have given you the plates.")] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  try {
    const hooks: AgentHooks = { say: () => {}, tool: async () => ({ ok: true, result: {} }), takeMessages: () => [] };
    await agent.run(
      '[Game events]\njob_done: giving iron-plate to you -> {"item":"iron-plate","given":1,"note":"Only 1 of the 10 iron-plate asked for"}',
      hooks,
      new AbortController().signal,
    );
    expect(agent.history[2]!.content).toEqual([{ type: "text", text: giveCountNudge(1, "iron-plate") }]);
    expect(api.requests).toHaveLength(2);
    await agent.run("[Your owner says] thank you", hooks, new AbortController().signal);
    expect(api.requests).toHaveLength(3);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("the humor setting adds a personality to the system prompt, for Claude and local models", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const done = { stop_reason: "end_turn", content: [text("Hi!")] };
  try {
    const claudeApi = new FakeAPI([done]);
    const claude = new Agent(claudeApi.asAPI(), { model: "sonnet", effort: "medium", humor: 3 }, dir, "a");
    await claude.run("[Your owner says] hi", { say: () => {}, tool: async () => ({ ok: true, result: {} }), takeMessages: () => [] }, new AbortController().signal);
    expect(claudeApi.requests[0]!.system[0].text).toEndWith(personality(3));
    expect(personality(3)).toContain("stranded");
    const localApi = new FakeAPI([done]);
    const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
    const agent = new Agent(localApi.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local, humor: 0 }, dir, "b");
    await agent.run("[Your owner says] hi", { say: () => {}, tool: async () => ({ ok: true, result: {} }), takeMessages: () => [] }, new AbortController().signal);
    expect(localApi.requests[0]!.system).toContain(personality(0));
    expect(promptFingerprint(2)).not.toBe(promptFingerprint(3));
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("a local model that made the items another way is reminded to hand them over, turns later", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "tool_use", content: [call("t1", "insert", { x: 1, y: 1, item: "stone", count: 20 })] },
    { stop_reason: "tool_use", content: [call("t2", "take", { x: 1, y: 1, item: "stone-brick", count: 10 })] },
    { stop_reason: "end_turn", content: [text("Took 10 stone bricks from the furnace.")] },
    { stop_reason: "tool_use", content: [call("t3", "give", { item: "stone-brick", count: 10 })] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const tools: string[] = [];
  try {
    const hooks: AgentHooks = { say: () => {}, tool: async (name) => (tools.push(name), { ok: true, result: {} }), takeMessages: () => [] };
    await agent.run("[Your owner says] give me 10 stone bricks", hooks, new AbortController().signal);
    await agent.run('[Game events]\njob_done: putting stone -> {"inserted":20}', hooks, new AbortController().signal);
    await agent.run('[Game events]\njob_done: taking -> {"taken":[{"name":"stone-brick","count":10}]}', hooks, new AbortController().signal);
    expect(tools).toEqual(["insert", "take", "give"]);
    expect(JSON.stringify(agent.history)).toContain(HAND_OVER_NUDGE);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("'I still don't have them' keeps an unfinished give request open; a new request closes it", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "tool_use", content: [call("t1", "craft", { recipe: "firearm-magazine", count: 10 })] },
    { stop_reason: "end_turn", content: [text("Crafting them now.")] },
    // Nudged, it still only talks: the turn ends without the magazines handed over.
    { stop_reason: "end_turn", content: [text("They're queued.")] },
    // The owner complains: the request is still open, so talk gets the nudge again.
    { stop_reason: "end_turn", content: [text("Sorry about that!")] },
    { stop_reason: "tool_use", content: [call("t2", "give", { item: "firearm-magazine", count: 10 })] },
    // A new request closes it: talk only gets the usual request nudge, not the hand-over one.
    { stop_reason: "end_turn", content: [text("On it.")] },
    { stop_reason: "tool_use", content: [call("t3", "mine", { name: "wood" })] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const tools: string[] = [];
  try {
    const hooks: AgentHooks = { say: () => {}, tool: async (name) => (tools.push(name), { ok: true, result: {} }), takeMessages: () => [] };
    await agent.run("[Your owner says] make 10 firearm magazine and give to me", hooks, new AbortController().signal);
    await agent.run("[Your owner says] i still dont have the firearm magazines", hooks, new AbortController().signal);
    expect(tools).toEqual(["craft", "give"]);
    await agent.run("[Your owner says] chop some trees", hooks, new AbortController().signal);
    expect(JSON.stringify(agent.history).split(HAND_OVER_NUDGE).length - 1).toBe(2);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("a local model's repeated lines are kept once; saying it'll wait after setting a reminder isn't nudged", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const loop = "I'll mine 3 trees.\n\nI'll then give the wood.\n\n".repeat(20);
  const api = new FakeAPI([
    { stop_reason: "tool_use", content: [text(loop), call("t1", "remind_me", { seconds: 30, note: "check" })] },
    { stop_reason: "end_turn", content: [text("I'll wait for the reminder.")] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const said: string[] = [];
  try {
    const hooks: AgentHooks = { say: (s) => void said.push(s), tool: async () => ({ ok: true, result: {} }), takeMessages: () => [] };
    await agent.run("[Your owner says] get wood", hooks, new AbortController().signal);
    expect(said[0]).toBe("I'll mine 3 trees.\n\nI'll then give the wood.");
    expect(api.requests).toHaveLength(2);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("a local model that answers a request with chat only is told to start it; chat isn't", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "end_turn", content: [text("Thanks for asking! I'm doing well.")] },
    { stop_reason: "tool_use", content: [call("t1", "mine", { name: "wood", count: 10 })] },
    { stop_reason: "end_turn", content: [text("Glad you like it!")] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const tools: string[] = [];
  try {
    const hooks: AgentHooks = { say: () => {}, tool: async (name) => (tools.push(name), { ok: true, result: {} }), takeMessages: () => [] };
    await agent.run("[Your owner says] collect 10 wood and put it in a chest", hooks, new AbortController().signal);
    expect(agent.history[2]!.content).toEqual([{ type: "text", text: REQUEST_NUDGE }]);
    expect(tools).toEqual(["mine"]);
    await agent.run("[Your owner says] i see the wood now", hooks, new AbortController().signal);
    expect(api.requests).toHaveLength(3); // no nudge for chat
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("a local model saying 'Following you.' is nudged, and a bare tool name as the reply is run as that tool", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "end_turn", content: [text("Following you.")] },
    { stop_reason: "end_turn", content: [text("follow_me")] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const tools: string[] = [];
  try {
    const hooks: AgentHooks = { say: () => {}, tool: async (name) => (tools.push(name), { ok: true, result: {} }), takeMessages: () => [] };
    await agent.run("[Your owner says] come over here", hooks, new AbortController().signal);
    expect(agent.history[2]!.content).toEqual([{ type: "text", text: NUDGE }]);
    expect(tools).toEqual(["follow_me"]);
    expect((agent.history[3]!.content as any)[0].type).toBe("tool_use");
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("a local model claiming it filled a chest without calling insert is told to insert", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "end_turn", content: [text("I've filled the wooden chest with wood from the trees.")] },
    { stop_reason: "tool_use", content: [call("t1", "insert", { x: 1, y: 2, item: "wood", count: 20 })] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const tools: string[] = [];
  try {
    const hooks: AgentHooks = { say: () => {}, tool: async (name) => (tools.push(name), { ok: true, result: {} }), takeMessages: () => [] };
    await agent.run('[Game events]\njob_done: mining wood -> {"mined":19,"item":"wood"}', hooks, new AbortController().signal);
    expect(agent.history[2]!.content).toEqual([{ type: "text", text: INSERT_NUDGE }]);
    expect(tools).toEqual(["insert"]);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("'I’ll' with a curly apostrophe counts as announcing, and 'keep filling it' counts as a request", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "end_turn", content: [text("Thanks! I’ll start filling the chest with wood right away.")] },
    { stop_reason: "tool_use", content: [call("t1", "insert", { x: 1, y: 2, item: "wood", count: 1000 })] },
    { stop_reason: "end_turn", content: [text("On it, filling now")] },
    { stop_reason: "tool_use", content: [call("t2", "insert", { x: 1, y: 2, item: "wood", count: 1000 })] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const tools: string[] = [];
  try {
    const hooks: AgentHooks = { say: () => {}, tool: async (name) => (tools.push(name), { ok: true, result: {} }), takeMessages: () => [] };
    await agent.run("[Your owner says] keep filling it with wood", hooks, new AbortController().signal);
    expect(agent.history[2]!.content).toEqual([{ type: "text", text: NUDGE }]);
    await agent.run("[Your owner says] you're not doing anything", hooks, new AbortController().signal);
    expect(tools).toEqual(["insert", "insert"]);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("without cheats a local model isn't offered them, and a call to one is refused", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "tool_use", content: [call("c", "run_lua", { code: "return 1" })] },
    { stop_reason: "end_turn", content: [text("ok")] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b-instruct", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const tools: string[] = [];
  try {
    const hooks: AgentHooks = { say: () => {}, tool: async (name) => (tools.push(name), { ok: true, result: {} }), takeMessages: () => [] };
    await agent.run("[Your owner says] hi", hooks, new AbortController().signal);
    expect(api.requests[0]!.tools.map((t: { name: string }) => t.name)).not.toContain("run_lua");
    expect(api.requests[0]!.system).not.toContain("Options your owner turned on");
    expect(tools).toEqual([]);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("a local model is sent the turns since its owner's last two requests, without earlier talk-only replies", () => {
  const user = (t: string) => ({ role: "user" as const, content: [{ type: "text" as const, text: t }] });
  const reply = (t: string) => ({ role: "assistant" as const, content: [{ type: "text" as const, text: t }] });
  const messages = [
    user("[Your owner says] hi"), reply("Hello."),
    user("[Your owner says] get wood"), reply("I'll get wood."), user(NUDGE), reply("I will now chop trees."),
    user("[Your owner says] do it"), { role: "assistant" as const, content: [call("t1", "mine", { name: "wood" }) as any] },
    { role: "user" as const, content: [{ type: "tool_result" as const, tool_use_id: "t1", content: "{}" }] },
    user("[Game events]\njob_done: mining wood"), reply("I'll give it to you."), user(NUDGE),
  ];
  expect(localHistory(messages, 100_000)).toEqual([
    { role: "user", content: [{ type: "text", text: "[Your owner says] get wood" }, { type: "text", text: "[Your owner says] do it" }] },
    messages[7]!,
    { role: "user", content: [...messages[8]!.content, { type: "text", text: "[Game events]\njob_done: mining wood" }] as any },
    // The current turn is sent whole, nudge included.
    messages[10]!,
    messages[11]!,
  ]);
});

test("reasoning a local model returns as reply text is left out of the chat and the history", async () => {
  const dir = mkdtempSync(join(tmpdir(), "aie-agent-"));
  const api = new FakeAPI([
    { stop_reason: "tool_use", content: [text("Okay, let's see. The owner wants coal...\n</think>\n\n"), call("t1", "mine", { name: "coal" })] },
  ]);
  const local = { url: "http://localhost:11434", model: "qwen3:4b", context: 16384, think: false };
  const agent = new Agent(api.asAPI(), { model: "sonnet", effort: "medium", provider: "local", local }, dir, "save-1");
  const said: string[] = [];
  try {
    const hooks: AgentHooks = { say: (s) => void said.push(s), tool: async () => ({ ok: true, result: {} }), takeMessages: () => [] };
    await agent.run("[Your owner says] get coal", hooks, new AbortController().signal);
    expect(api.requests[0]!.thinking).toEqual({ type: "disabled" });
    expect(api.requests[0]!.max_tokens).toBe(2048);
    expect(said).toEqual([]);
    expect(agent.history[1]!.content).toEqual([call("t1", "mine", { name: "coal" }) as any]);
    expect(withoutReasoning([text("thinking...</think>\nOn it.") as any])).toEqual([text("On it.") as any]);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test("a reply cut off before any text or tool call is reported instead of ending silently", async () => {
  const t = setup([{ stop_reason: "max_tokens", content: [{ type: "thinking", thinking: "", signature: "s" }] }]);
  try {
    await t.agent.run("[Your owner says] build a base", t.hooks, new AbortController().signal);
    expect(t.said).toEqual([["I ran out of room while thinking and didn't get to act. Try a simpler request.", false]]);
  } finally {
    t.cleanup();
  }
});

test("recentTurns keeps the newest whole turns that fit, and always the current one", () => {
  const input = (s: string) => ({ role: "user" as const, content: [{ type: "text" as const, text: s }] });
  const reply = (id: string) => ({ role: "assistant" as const, content: [{ type: "tool_use" as const, id, name: "observe", input: {} }] });
  const result = (id: string) => ({ role: "user" as const, content: [{ type: "tool_result" as const, tool_use_id: id, content: "x".repeat(300) }] });
  const messages = [input("one"), reply("a"), result("a"), input("two"), reply("b"), result("b"), input("three")];
  expect(recentTurns(messages, 1_000_000)).toEqual(messages);
  // Room for turns two and three but not one: the cut lands on an input, never on tool results.
  expect(recentTurns(messages, 200)).toEqual(messages.slice(3));
  // Too small for anything: the current turn is still sent.
  expect(recentTurns(messages, 1)).toEqual(messages.slice(6));
});
