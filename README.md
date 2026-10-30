# AI Engineer

A second engineer for Factorio 2.0 that plays alongside you. Talk to it in game ("mine some iron and build a furnace") and it walks, mines, crafts and builds like a player, using only what's in its own inventory (or you can enable cheats).

It runs on a **free AI model on your own computer** (through [Ollama](https://ollama.com)), on **Claude** with your own Anthropic API key, or on **any OpenAI-compatible server**.

It has two parts:

- **The mod** (`ai-engineer`), installed like any Factorio mod.
- **The helper app**, which runs on your computer while you play and connects the game to the AI model. Mods can't reach the internet or other programs, so this small app does it for the game.

## Setup

1. **Install the mod** from the Factorio mod portal (in game: Mods → Install → search "AI Engineer").
2. **Download the helper app** from the [releases page](https://github.com/jhacc/ai-engineer/releases): `ai-engineer.exe` on Windows, or on a Mac `ai-engineer-mac-arm64.zip` (M1 or newer) or `ai-engineer-mac-intel.zip`. The app isn't signed: on Windows click "More info" → "Run anyway" if SmartScreen appears; on a Mac unzip it, then right-click `ai-engineer` → Open → Open (or System Settings → Privacy & Security → "Open Anyway").
3. **Choose your AI**: set up a [local model](#option-a-a-free-local-model-ollama), a [Claude API key](#option-b-claude) or an [OpenAI-compatible server](#option-c-an-openai-compatible-server) (below).
4. **Run the helper app** and answer its questions. It can turn on Factorio's RCON setting for you (close Factorio first). Each time you start it, it goes through the settings again with your last answers filled in, so press Enter to keep each one.
5. In Factorio, **host a multiplayer game**. It can be private, with just you. Single-player games don't open RCON, which the app needs.
6. The app shows a code. Type `/ai-pair <code>` in the game chat. Your engineer appears next to you.

### Option A: a free local model (Ollama)

The engineer can use a free model running on your own computer, with no account and no costs. Local models play worse than Claude: expect more mistakes and forgotten tasks. A graphics card (GPU) makes them much faster; without one, every action is slow.

1. **Install Ollama.** Download it from [ollama.com/download](https://ollama.com/download) and run the installer (on a Mac, move Ollama to Applications and open it). Ollama then runs in the background: look for its llama icon in the system tray (Windows) or menu bar (Mac). It starts by itself when you log in.
2. **Download a model.** Open a terminal (Windows: PowerShell, from the Start menu; Mac: Terminal) and run one of:
   - `ollama pull qwen3:4b-instruct`: fast, acts in a few seconds, but makes more mistakes.
   - `ollama pull qwen3:4b`: thinks before every action, so it makes far fewer mistakes, but each action takes longer (about 35 seconds on a laptop RTX 4070).

   Each is about a 2.5 GB download. The model shares your graphics card's memory with Factorio, so pick one that leaves room for the game: about 2.5 GB for 4B models like these, 5 GB for 8B ones (`qwen3:8b`). Run `ollama list` to see what you've downloaded.
3. **Raise the context length to at least 16K.** This is how much of the conversation the model can keep in mind. Ollama's default of 4K is too small, and the engineer forgets what it's doing. Either:
   - open the Ollama app's **Settings** and drag **Context length** to 16K (or more if your graphics card has the memory), or
   - set the `OLLAMA_CONTEXT_LENGTH` environment variable, then quit Ollama (right-click its icon → Quit) and open it again. Windows: run `setx OLLAMA_CONTEXT_LENGTH 16384` in PowerShell. Mac: run `launchctl setenv OLLAMA_CONTEXT_LENGTH 16384` in Terminal.

   Optional: setting `OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0` the same way roughly halves the memory that context takes.
4. **In the helper app**, choose the local model option. Press Enter to keep Ollama's usual address, pick your model from the list, enter the context length you set, and choose whether it may think before acting (`qwen3:4b` always thinks; `qwen3:4b-instruct` never does).

Older parts of the conversation are left out once it no longer fits in the context length. You can switch to Claude, or back, the next time you start the app; the settings for both are kept.

### Option B: Claude

Claude plays much better than a small local model, but usage is billed to your own Anthropic account.

1. Get an Anthropic API key at [console.anthropic.com](https://console.anthropic.com/settings/keys). Creating the key in its own workspace with a spend limit keeps costs predictable.
2. In the helper app, choose Claude, paste your key, and pick a model. Haiku is the cheapest (about 1/20th of Sonnet), but less capable. Your key is saved as `ANTHROPIC_API_KEY` in a `.env` file in the folder you run the app from.

### Option C: an OpenAI-compatible server

The engineer can also use any server with an OpenAI-compatible chat completions API (LiteLLM, vLLM, OpenAI and others). It's played like a local model. Its settings live in `.env`, in the folder you run the app from:

```
LLM_BASE_URL=https://your-server/v1
LLM_MODEL=your-model
LLM_API_KEY=your-key
LLM_CONTEXT=128000
```

`LLM_API_KEY` can be empty for servers without keys, and `LLM_CONTEXT` defaults to 128000. In the helper app, choose the OpenAI-compatible option: it suggests what's in `.env`, lists the server's models and saves your answers back to `.env`.

## Playing

- `/ai <message>`, or the chat window (`/ai` on its own opens it), talks to your engineer.
- `/ai stop`, or the Stop button, stops whatever it's doing.
- `/ai clear`, or the trash button in the chat window, starts a new chat. Your engineer stops and forgets the earlier conversation, but nothing in your game changes. Every request resends the whole conversation, so starting fresh when you switch tasks keeps a local model quick and Claude's costs down.
- It reports back when its jobs finish. Its replies appear in the chat window, visible only to you.

### Autopilot

Tick **Autopilot** in the chat window (or type `/ai autopilot`) and your engineer builds the early game by itself between your requests. The mod runs these steps on its own, with no AI requests, so they cost nothing and work with any model:

1. Burner drills and furnaces for iron and copper, coal drill loops, and a stone drill into a chest.
2. Growth to 10 iron and 2 copper drill/furnace pairs, plus a ring of four coal drills.
3. Steam power, piped inland to a spot with room to add more boilers and engines.
4. A lab on a line of poles, kept out of the power plant's area.
5. Red science for automation, then an assembler that makes red science for logistics and electric mining drills.
6. A belt that brings coal from two electric drills to the boiler.

7. Then it works through the tech tree. It automates the next science pack (green science first) as a goal (see below), and researches whatever the science it makes can pay for, cheapest first. It also swaps the burner drills for electric drills, and adds boilers and steam engines when power runs short.

While it waits, it collects wood for poles and crafts iron gear wheels, up to 100. Your requests always come first. With Claude, once there's nothing left it can build on its own, the AI takes over. A local model isn't woken for that: small models improvise badly, so autopilot just keeps the base running and tells you what it's blocked on.

### Automating things

Ask your engineer to automate something ("automate electronic circuits", "set up gear production") and it sets a goal. The mod works out from the game's own recipes and tech tree what that takes: the research, the machines and how many of them. Then the engineer does the research, builds the assemblers next to your power network, and keeps them fed with plates from your furnaces. A goal only counts as done once the machines have really made enough for a whole minute. Like the build order, this runs in the mod with no AI requests, so it works the same with a small local model. It works whether autopilot is on or off. Saying stop pauses it.

For now it builds assemblers and furnaces (steel, stone bricks) that it feeds and fuels by hand, which covers red, green and military science. Anything that needs fluids or oil is reported as blocked, with the reason.

Your engineer only listens to you. Other players can't talk to it or see its replies, and nothing they type is ever sent to Claude under your key. With a local model, the app can let every player talk to it instead.

### Filming your engineer

- `/ai-cam` follows your engineer with the camera. You switch to spectator mode while your character waits where you left it (it can't be hurt meanwhile). Scroll to zoom, or type `/ai-cam 0.6`. Type `/ai-cam` again to go back to your character.
- The chat window also shows what the helper app prints in its terminal (the actions it takes, how long its turns take, the cost) as small grey lines, so viewers can follow along.
- `/ai-timelapse` saves a screenshot following your engineer every 3 seconds, with your screen's windows (keep the chat window open). `/ai-timelapse wide` takes a wide shot centered where you're standing instead, and `/ai-timelapse both` takes both. A number sets the seconds between frames, and a second one the wide shot's zoom: `/ai-timelapse both 5 0.2`. Type it again to stop. Frames are JPEGs of a few hundred KB each. The screenshots go into `%APPDATA%\Factorio\script-output\ai-engineer-timelapse` (on a Mac, `~/Library/Application Support/factorio/script-output/ai-engineer-timelapse`), always at midday so night doesn't flicker. To turn them into a video, use ffmpeg (the game prints the command when you stop).

Mod setting (Settings → Mod settings → Map): **Teleport the engineer when it's stuck** (on by default). When a path can't be found, the engineer jumps to its destination instead of giving up.

To change your model, key, connection or your engineer's sense of humor, restart the app and type a new answer at that question. Humor goes from 0 (all business) to 3 (jokes, puns and banter); the default, 2, is a good-humored companion for being stranded on an alien planet together. It never jokes instead of working.

## License

[MIT](LICENSE) © Xvv
