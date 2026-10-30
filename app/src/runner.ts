import { readFileSync, renameSync, writeFileSync } from "node:fs";
import Anthropic from "@anthropic-ai/sdk";
import { isGreeting, type Agent } from "./agent";
import type { Game, PollItem } from "./game";
import { CHEAT_NAMES, JOB_TOOLS } from "./tools";

/** Turns the AI may take on its own (reacting to finished jobs) per owner message. */
export const AUTO_TURNS = 12;
/** After a restart, messages and events newer than this (5 game minutes) are still handled; older ones are skipped. */
export const RESUME_TICKS = 5 * 60 * 60;
/**
 * Keep-busy: once the mod's build order is done, game ticks with nothing running before the AI is woken
 * to pick its next job (3 s).
 */
export const IDLE_NUDGE_TICKS = 3 * 60;
/** The wait doubles each time a wake-up starts nothing, up to this (2 game minutes). */
export const IDLE_NUDGE_MAX_TICKS = 2 * 60 * 60;

/** Where the runner got to, kept per save so a restarted app carries on instead of dropping the task. */
export type RunnerState = {
  after: number;
  autoTurns: number;
  /** Estimated dollars spent on this save. */
  spent?: number;
  /** The keep-busy setting the AI was last told about. */
  keepBusy?: boolean;
};

/** Hours of play between the AI being told how long its owner has been playing (so it can suggest a break). */
export const PLAY_HOURS = 2;

/** Events that are routine progress: the AI gets them, but without a fresh look around (it can observe itself). */
const ROUTINE = new Set(["job_done", "crafting_done"]);

const BUSY_ON =
  "Autopilot mode is now ON: between your owner's requests, the game's build order runs your engineer by itself: the starting base up to the coal belt to the power plant, keeping everything fueled, then the tech tree (automating the next science packs as goals, researching what they pay for, and swapping burner drills for electric ones). Its goals show in observe as engineer.goals. Don't start work on your own; just handle your owner's requests. Its jobs show in observe as \"build order: ...\".";
const IDLE =
  "idle: autopilot mode is on, but the game's own build order, research and goals (engineer.goals) have nothing left they can do, and nothing is running. Never redo what they built (engineer.build_order.base_progress lists the starting base). Call plan now and start what its next says, instead of waiting. Build nothing but power inside engineer.build_order.keep_clear: that's the power plant's room to grow, and poles are cheap, so run a line of poles out of it instead. If you asked your owner something, answer it yourself and act on it.";
const BUSY_OFF = "Autopilot mode is now OFF: finish your current task, then stop and wait for your owner.";
/** Small local models start working on a mere "hello"; they get this reminder with every message while keep-busy is off. */
const REQUESTS_ONLY =
  "Autopilot mode is off: do what was asked (start it now with a tool), then stop. Only a greeting, thanks or chat gets just a short reply and no work.";

const dollars = (n: number) => "$" + (n < 10 ? n.toFixed(2) : n.toFixed(1));
export type StateStore = { load(): RunnerState | null; save(state: RunnerState): void };

export function fileStore(path: string): StateStore {
  return {
    load() {
      try {
        const state = JSON.parse(readFileSync(path, "utf8"));
        return typeof state.after === "number" && typeof state.autoTurns === "number" ? state : null;
      } catch {
        return null;
      }
    },
    save(state) {
      writeFileSync(path + ".tmp", JSON.stringify(state));
      renameSync(path + ".tmp", path);
    },
  };
}

function describeEvent(item: PollItem): string {
  const data = item.data ?? {};
  switch (item.kind) {
    case "job_done":
      return `job_done: ${data.job} -> ${JSON.stringify(data.result ?? {})}`;
    case "job_failed":
      return `job_failed: ${data.job} -> ${data.reason}`;
    case "crafting_done":
      return `crafting_done: inventory now ${JSON.stringify(data.inventory ?? [])}${Array.isArray(data.unlocked) ? `. Research unlocked: ${data.unlocked.join(", ")}` : ""}`;
    case "engineer_died":
      return `engineer_died at ${JSON.stringify(data.position)}${data.cause ? ` (killed by ${data.cause})` : ""}. ${data.note ?? ""}`;
    case "reminder":
      return `reminder${data.note ? `: ${data.note}` : ""}`;
    case "engineer_respawned":
      return `engineer_respawned at ${JSON.stringify(data.position)} with an empty inventory`;
    case "research_finished":
      // Small models said "steam power is now active" when nothing was built yet.
      return `research_finished: ${data.name}. A step closer to getting off this planet: mention it in a few words next time you speak. Say only that it's researched (its recipes are unlocked); nothing is built or running because of it.`;
    case "owner_died":
      return `owner_died: your owner was killed${data.cause ? ` by ${data.cause}` : ""}. They respawn at the start, their items in their corpse. Say something kind and steadying in a sentence.`;
    case "goal_done":
      return `goal_done: ${data.goal} (${data.item}): ${data.result}. Tell your owner in a sentence.`;
    case "goal_blocked":
      return `goal_blocked: ${data.goal} (${data.item}): ${data.result}. Tell your owner what's blocking it in a sentence.`;
    default:
      return `${item.kind}: ${JSON.stringify(data)}`;
  }
}

function friendly(error: unknown): string {
  if (error instanceof Anthropic.AuthenticationError)
    return "My Anthropic API key was rejected. Restart the AI Engineer app and enter a new one.";
  if (error instanceof Anthropic.PermissionDeniedError) return "My API key isn't allowed to use this model.";
  if (error instanceof Anthropic.RateLimitError) return "I'm being rate limited by Anthropic. Try again in a minute.";
  if (error instanceof Anthropic.APIConnectionError)
    return "I can't reach my AI model. If you use a local model, check that Ollama is running.";
  if (error instanceof Anthropic.NotFoundError)
    return "My AI model wasn't found. For a local model, download it in Ollama or restart the app and pick another.";
  if (error instanceof Anthropic.APIError) return `Claude API error (${error.status ?? "?"}). Try again shortly.`;
  return `Something went wrong: ${error instanceof Error ? error.message : String(error)}`;
}

/** Connects one paired game to the agent: polls for messages and events, runs turns. */
export class Runner {
  private after = 0;
  private started = false;
  private messages: string[] = [];
  /** `wake`: whether the event starts a turn on its own (others wait for the next turn). */
  private events: Array<{ text: string; wake: boolean; routine: boolean }> = [];
  private spent = 0;
  /** Cheats only serve the owner: they're refused while the latest request is another player's. */
  private ownerAskedLast = true;
  private keepBusy = false;
  /** Told on the next turn: turning keep-busy on starts the mod's build order, not a turn. */
  private busyNotice: string | null = null;
  /** The owner cleared the chat: start a new conversation once the current turn has stopped. */
  private resetPending = false;
  private autoTurns = 0;
  private turn: Promise<void> | null = null;
  private abort: AbortController | null = null;
  // Unknown at start: the game may still show a status left by an app that stopped mid-turn.
  private lastStatus: string | null = null;
  private pausedNotice = false;
  /** Keep-busy: the game tick when the engineer was first seen with nothing running. */
  private idleSince: number | null = null;
  /** Keep-busy wake-ups in a row that started nothing. */
  private idleNudges = 0;
  private savedState = "";
  /** When this app run started, and the hours of play after which the AI is next told how long it's been. */
  private readonly playStart = Date.now();
  private nextPlayHours = PLAY_HOURS;
  /** The last build order log line printed (null until the first poll, which only catches up). */
  private buildSeen: number | null = null;

  constructor(
    private readonly game: Game,
    private readonly agent: Agent,
    private readonly log: (line: string) => void = () => {},
    private readonly store?: StateStore,
  ) {}

  /**
   * A terminal line that's also shown in the owner's chat window (small and grey), so a recording shows what
   * the engineer is doing. Lines the window already has (owner messages, replies) use `log` alone.
   */
  private note(line: string) {
    this.log(line);
    void this.game.log(line).catch(() => {});
  }

  get busy() {
    return this.turn !== null;
  }

  /** Wait for the running turn (tests, shutdown). */
  async idle() {
    while (this.turn) await this.turn;
  }

  async tick(): Promise<void> {
    const saved = this.started ? null : this.store?.load();
    if (saved) this.after = saved.after;
    const local = this.agent.local;
    const poll = await this.game.poll(this.after, {
      cheats: local?.cheats,
      everyone: local?.everyone,
      thinking: this.turn !== null,
      buildAfter: this.buildSeen ?? 0,
    });
    if (!poll.paired) throw new Error("This game isn't paired with the app anymore");
    // The mod's build order works without AI turns: show what it does in the terminal too.
    for (const line of poll.build_log ?? []) {
      if (this.buildSeen !== null && line.n > this.buildSeen) this.log(`build order: ${line.text}`);
    }
    const lastLine = poll.build_log?.at(-1)?.n;
    if (lastLine !== undefined) this.buildSeen = Math.max(this.buildSeen ?? 0, lastLine);
    else this.buildSeen ??= 0;
    let items = poll.items ?? [];
    if (!this.started) {
      this.started = true;
      // A save loaded from before the saved point reuses event ids: start fresh then.
      if (!saved || saved.after > (poll.seq ?? 0)) {
        // First run for this save: don't replay anything from before the app started.
        this.after = poll.seq ?? 0;
        this.saveState();
        return;
      }
      // Restarted: carry on from where the last run stopped, skipping anything stale.
      this.after = saved.after;
      this.autoTurns = saved.autoTurns;
      this.spent = saved.spent ?? 0;
      this.keepBusy = saved.keepBusy ?? false;
      const recent = (poll.tick ?? 0) - RESUME_TICKS;
      items = items.filter((item) => item.id > saved.after && item.tick >= recent);
      if (this.agent.interrupted && this.autoTurns > 0)
        this.events.push({
          text: "app_restarted: the AI Engineer app restarted in the middle of your turn. Check where things stand and carry on.",
          wake: true,
          routine: false,
        });
    }
    for (const item of items) {
      if (item.kind === "message") {
        // Other players' messages (when the owner lets everyone talk to the engineer) carry their name.
        const from = typeof item.data?.from === "string" ? item.data.from : null;
        this.messages.push(`${from ? `[Player ${from} says]` : "[Your owner says]"} ${String(item.data?.text ?? "")}`);
        this.ownerAskedLast = from === null;
        this.autoTurns = AUTO_TURNS;
      } else if (item.kind === "stop") {
        this.stop();
      } else if (item.kind === "reset") {
        this.abort?.abort();
        this.messages = [];
        this.events = [];
        this.autoTurns = 0;
        this.resetPending = true;
      } else if (item.kind !== "paired") {
        // Crafting finishing while a job still runs can wait for that job's event; finished research
        // (many of them in keep-busy) rides along with the next turn.
        const wake = !(item.kind === "crafting_done" && poll.busy) && item.kind !== "research_finished";
        this.events.push({ text: describeEvent(item), wake, routine: ROUTINE.has(item.kind) });
        // Hours of keep-busy research between owner messages: only the latest few are news.
        const research = this.events.filter((e) => e.text.startsWith("research_finished"));
        if (research.length > 3) this.events.splice(this.events.indexOf(research[0]!), 1);
      }
    }
    // Keep-busy mode: tell the AI when it changes, on its next turn. The mod runs the build order itself.
    const keepBusy = poll.keep_busy === true;
    if (keepBusy !== this.keepBusy) {
      this.keepBusy = keepBusy;
      this.busyNotice = keepBusy ? BUSY_ON : BUSY_OFF;
      if (keepBusy) this.pausedNotice = false;
    }
    for (const item of poll.items ?? []) this.after = Math.max(this.after, item.id); // skipped ones too
    if (this.messages.length > 0) this.pausedNotice = false;
    if (this.resetPending && !this.turn) {
      this.resetPending = false;
      this.agent.reset();
      this.log("chat cleared: new conversation");
      // The new conversation hasn't heard about keep-busy; tell it on its first turn without starting one.
      if (this.keepBusy && !this.busyNotice) this.busyNotice = BUSY_ON;
    }
    // Keep-busy: the game keeps progressing. While the mod's build order has work, it picks the jobs. After
    // that, nothing running for a while wakes the AI to pick the next job; the wait grows while those
    // wake-ups start nothing, so an AI with nothing to do doesn't loop.
    // A pending reminder alone doesn't count: it means the AI is waiting, and keep-busy shouldn't wait.
    const running = poll.busy || poll.crafting || poll.autopilot;
    const pending = this.messages.length > 0 || this.events.some((e) => e.wake);
    if (running || pending) this.idleNudges = 0;
    // A small local model woken with nothing to do improvises (a second power plant, stray furnaces), so
    // only Claude is: with a local model, the mod's build order, goals and research are all keep-busy does.
    if (!this.keepBusy || this.agent.local || this.turn || this.resetPending || running || pending || poll.alive === false) {
      this.idleSince = null;
    } else {
      const now = poll.tick ?? 0;
      this.idleSince ??= now;
      if (now - this.idleSince >= Math.min(IDLE_NUDGE_TICKS * 2 ** this.idleNudges, IDLE_NUDGE_MAX_TICKS)) {
        this.events.push({ text: IDLE, wake: true, routine: false });
        this.idleNudges++;
        this.idleSince = null;
      }
    }
    const waking = this.events.some((e) => e.wake);
    if (!this.turn && !this.resetPending) {
      const asked = this.messages.length > 0;
      // Automatic turns are limited per owner message to bound API costs, except for Claude in keep-busy mode,
      // which the owner chose. A local model is free, and the owner wants it to keep at a task until it's done
      // or they say stop (12 turns cut "make 100 ammo" off again and again). It's still only woken by its own
      // jobs and reminders, never by idle nudges, so it stops once it stops starting things.
      const unlimited = (this.keepBusy && !this.agent.local) || this.agent.local !== undefined;
      if (asked || (waking && (unlimited || this.autoTurns > 0))) {
        if (!asked && !unlimited) this.autoTurns--;
        this.startTurn();
      } else {
        if (waking && !this.pausedNotice) {
          // Out of automatic turns: say so once instead of going quiet. The events wait for the next message.
          this.pausedNotice = true;
          this.events = this.events.slice(-20);
          await this.game.say(
            this.agent.local
              ? "I've stopped here. Send me a message to keep going."
              : "I've paused to keep API costs in check. Send me a message to keep going.",
            false,
          );
        }
        await this.setStatus(poll.busy ? "Working..." : "");
      }
    }
    this.saveState();
  }

  private saveState() {
    const state = JSON.stringify({
      after: this.after,
      autoTurns: this.autoTurns,
      spent: this.spent,
      keepBusy: this.keepBusy,
    } satisfies RunnerState);
    if (state === this.savedState) return;
    this.savedState = state;
    this.store?.save(JSON.parse(state));
  }

  private stop() {
    this.abort?.abort();
    this.messages = [];
    this.events = [];
    this.autoTurns = 0;
    this.saveState();
    void this.game.say("Stopped.", false).catch(() => {});
  }

  private startTurn() {
    const messages = this.messages.splice(0);
    const events = this.events.splice(0);
    const busyNotice = this.busyNotice;
    this.busyNotice = null;
    this.idleSince = null;
    const abort = new AbortController();
    this.abort = abort;
    const run = async () => {
      await this.setStatus("Thinking...");
      const parts: string[] = [];
      if (messages.length) parts.push(...messages);
      if (busyNotice) parts.push(`[Setting] ${busyNotice}`);
      else if (messages.length && !this.keepBusy && this.agent.local) parts.push(`[Setting] ${REQUESTS_ONLY}`);
      // A companion notices when its human has been at it a long time.
      const hours = Math.floor((Date.now() - this.playStart) / 3_600_000);
      if (messages.length && hours >= this.nextPlayHours) {
        this.nextPlayHours = hours + PLAY_HOURS;
        parts.push(`[Setting] Your owner has been playing for about ${hours} hours. If it fits, suggest a stretch or a drink of water, once, in a few words.`);
      }
      if (events.length) parts.push(`[Game events]\n${events.map((e) => e.text).join("\n")}`);
      // A fresh look around for requests and surprises; routine progress events carry their own results.
      if (messages.length || busyNotice || events.some((e) => !e.routine)) {
        const seen = await this.game.tool("observe", { radius: 16 }).catch(() => null);
        if (seen?.ok) parts.push(`[What you see now]\n${JSON.stringify(seen.result)}`);
      }
      if (messages.length) this.log(messages.join(" / "));
      else if (busyNotice) this.log(busyNotice);
      else this.note(`woken by ${events.map((e) => e.text.split(/[:\s]/)[0]).join(", ")}`);
      // Why a job failed, so a log the owner sends shows it (the model's reply often doesn't).
      for (const e of events) if (e.text.startsWith("job_failed")) this.note(`  ${e.text.slice(0, 300)}`);
      let turnCost = 0;
      let turnSeconds = 0;
      const turnStarted = performance.now();
      // A turn woken by events that only starts the next step ("Collecting coal.") stays out of the game
      // chat: its text shows as a progress note in the chat window. Replies to the owner always show.
      let ownerSpoke = messages.length > 0;
      // A local model told only "hello" with keep-busy off isn't allowed to start work (it tends to).
      let greetedOnly =
        this.agent.local !== undefined && !this.keepBusy && !busyNotice && messages.length > 0 && messages.every(isGreeting);
      let continuing = false;
      await this.agent.run(
        parts.join("\n\n"),
        {
          say: (text, progress) => {
            const quiet = progress || (!ownerSpoke && continuing);
            this.log(`${quiet ? "  ..." : "engineer:"} ${text}`);
            return this.game.say(text, quiet);
          },
          tool: async (name, input) => {
            this.note(`  tool ${name} ${JSON.stringify(input)}`);
            if (greetedOnly && (JOB_TOOLS.has(name) || name === "craft" || CHEAT_NAMES.has(name)))
              return { ok: false as const, error: "Not started: that was only a greeting or thanks, not a request. Just reply briefly." };
            if (CHEAT_NAMES.has(name) && !this.ownerAskedLast)
              return {
                ok: false as const,
                error: "Cheats only work on your owner's requests, and the latest request is from another player. Do it the normal way.",
              };
            const result = await this.game.tool(name, input);
            if (result.ok && (JOB_TOOLS.has(name) || name === "remind_me")) continuing = true;
            return result;
          },
          takeMessages: () => {
            const taken = this.messages.splice(0);
            if (taken.length) ownerSpoke = true;
            if (!taken.every(isGreeting)) greetedOnly = false;
            return taken;
          },
          cost: (amount) => {
            turnCost += amount;
            this.spent += amount;
          },
          timing: (seconds, tokens) => {
            turnSeconds += seconds;
            this.note(`  reply took ${seconds.toFixed(1)}s (${tokens} tokens, ${(tokens / Math.max(seconds, 0.1)).toFixed(1)}/s)`);
          },
        },
        abort.signal,
      ).finally(() => {
        this.note(`  turn took ${((performance.now() - turnStarted) / 1000).toFixed(1)}s, ${turnSeconds.toFixed(1)}s of it waiting for the model`);
        if (turnCost > 0) this.note(`  cost about ${dollars(turnCost)} (${dollars(this.spent)} so far on this save)`);
        this.saveState();
      });
    };
    this.turn = run()
      .catch(async (error) => {
        if (abort.signal.aborted) return;
        this.note(`error: ${error instanceof Error ? error.message : String(error)}`);
        await this.game.say(friendly(error), false).catch(() => {});
      })
      .finally(async () => {
        this.turn = null;
        this.abort = null;
        await this.setStatus("").catch(() => {});
      });
  }

  /** The chat window's status, with the estimated spend for this save (local models are free: no spend shown). */
  private async setStatus(base: string) {
    const text = this.agent.local ? base : base ? `${base} · ${dollars(this.spent)}` : `${dollars(this.spent)} spent`;
    if (text === this.lastStatus) return;
    this.lastStatus = text;
    await this.game.status(text);
  }
}
