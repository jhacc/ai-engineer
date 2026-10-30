# AI Engineer

A second engineer for Factorio 2.0 that plays alongside you, powered by Claude or your local AI engine. See the bottom of this page for local AI setup. Talk to it in game ("mine some iron and build a furnace") and it walks, mines, crafts and builds like a player, using only what's in its own inventory (or you can enable cheats). 

It has two parts:

- **The mod** (`ai-engineer`), installed like any Factorio mod.
- **The helper app** (`ai-engineer.exe`), which runs on your computer while you play and talks to Claude using **your own Anthropic API key**. Mods can't reach the internet, so this small app does it for the game.

## Setup

1. Install the mod and the helper app from the [releases page](https://github.com/jhacc/ai-engineer/releases): `ai-engineer.exe` on Windows, or on a Mac `ai-engineer-mac-arm64.zip` (M1 or newer) or `ai-engineer-mac-intel.zip`. The app isn't signed: on Windows click "More info" → "Run anyway" if SmartScreen appears; on a Mac unzip it, then right-click `ai-engineer` → Open → Open (or System Settings → Privacy & Security → "Open Anyway").
2. Get an Anthropic API key at [console.anthropic.com](https://console.anthropic.com/settings/keys). Usage is billed to your Anthropic account. Creating the key in its own workspace with a spend limit keeps costs predictable.
3. Run the helper app. It asks for your key and which Claude model to use. It can also turn on Factorio's RCON setting for you (close Factorio first). Each time you start it, it goes through the settings again with your last answers filled in, so press Enter to keep each one.
4. In Factorio, **host a multiplayer game**. It can be private, with just you. Single-player games don't open RCON, which the app needs.
5. The app shows a code. Type `/ai-pair <code>` in the game chat. Your engineer appears next to you.

## Playing

- `/ai <message>`, or the chat window (`/ai` on its own opens it), talks to your engineer.
- `/ai stop`, or the Stop button, stops whatever it's doing.
- `/ai clear`, or the trash button in the chat window, starts a new chat. Your engineer stops and forgets the earlier conversation, but nothing in your game changes. Every request resends the whole conversation, so starting fresh when you switch tasks keeps costs down.
- For the lowest cost, choose Claude Haiku when the app starts. It costs about 1/20th of Sonnet, but it's less capable.
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

Your engineer only listens to you. Other players can't talk to it or see its replies, and nothing they type is ever sent to Claude under your key.

### Filming your engineer

- `/ai-cam` follows your engineer with the camera. You switch to spectator mode while your character waits where you left it (it can't be hurt meanwhile). Scroll to zoom, or type `/ai-cam 0.6`. Type `/ai-cam` again to go back to your character.
- The chat window also shows what the helper app prints in its terminal (the actions it takes, how long its turns take, the cost) as small grey lines, so viewers can follow along.
- `/ai-timelapse` saves a screenshot following your engineer every 3 seconds, with your screen's windows (keep the chat window open). `/ai-timelapse wide` takes a wide shot centered where you're standing instead, and `/ai-timelapse both` takes both. A number sets the seconds between frames, and a second one the wide shot's zoom: `/ai-timelapse both 5 0.2`. Type it again to stop. Frames are JPEGs of a few hundred KB each. The screenshots go into `%APPDATA%\Factorio\script-output\ai-engineer-timelapse` (on a Mac, `~/Library/Application Support/factorio/script-output/ai-engineer-timelapse`), always at midday so night doesn't flicker. To turn them into a video, use ffmpeg (the game prints the command when you stop).

Mod setting (Settings → Mod settings → Map): **Teleport the engineer when it's stuck** (on by default). When a path can't be found, the engineer jumps to its destination instead of giving up.

To change your key, model, connection or your engineer's sense of humor, restart the app and type a new answer at that question. Humor goes from 0 (all business) to 3 (jokes, puns and banter); the default, 2, is a good-humored companion for being stranded on an alien planet together. It never jokes instead of working.

## Using a local model instead (optional, experimental)

If you don't want to pay for API usage, the engineer can use a free model running on your own computer through [Ollama](https://ollama.com). Local models play much worse than Claude: expect more mistakes and forgotten tasks. Without a graphics card, turns are also slow.

1. Install Ollama and download a model, for example `ollama pull qwen3:4b`. The model shares your graphics card with Factorio, so pick one that leaves room for the game: about 2.5 GB for 4B models, 5 GB for 8B ones.
2. Raise Ollama's context length to at least 16K (Ollama app: Settings → Context length, or the `OLLAMA_CONTEXT_LENGTH` environment variable). The default 4K is too small, and the engineer forgets what it's doing. Setting `OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0` as well roughly halves the memory that context takes.
3. Start the helper app, choose the local model option, pick the model and choose whether it thinks before acting. Thinking makes far fewer mistakes, but each action takes longer (about 35 seconds for `qwen3:4b` on a laptop RTX 4070). Without it the engineer acts in a few seconds but gets more wrong. `qwen3:4b` always thinks; `qwen3:4b-instruct` never does.

Older parts of the conversation are left out once it no longer fits in the context length. Your API key and Claude settings are kept, so you can switch back the next time you start the app.

## License

[MIT](LICENSE) © Xvv
