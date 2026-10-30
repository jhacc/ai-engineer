**Beta.** Expect bugs, and please report them in the discussion tab.

A second engineer that plays alongside you. Tell it what you want ("mine some iron and build a furnace", "automate green science") and it walks, mines, crafts and builds like a player, using only what's in its own inventory. Turn on **Autopilot** and it builds the early game by itself: drills, smelting, steam power, labs and research.

It runs on either a **free local model** (through [Ollama](https://ollama.com)) or **Claude** with your own Anthropic API key. Mods can't reach the internet, so a small helper app on your computer connects the game to the model.

## Install

1. Install this mod.
2. Download the helper app from [GitHub Releases](https://github.com/jhacc/ai-engineer/releases). It isn't signed, so your computer may warn you about it. It's open source: [see what it does and how to build it yourself](https://github.com/jhacc/ai-engineer#is-the-helper-app-safe).
   - **Windows:** `ai-engineer.exe`. If SmartScreen appears, click "More info" → "Run anyway".
   - **Mac:** `ai-engineer-mac-arm64.zip` (M1 or newer) or `ai-engineer-mac-intel.zip`. Unzip it, then right-click `ai-engineer` → Open → Open. If macOS still refuses, go to System Settings → Privacy & Security and click "Open Anyway".
3. Run it and choose your model:
   - **Local (free):** install Ollama, run `ollama pull qwen3:4b`, and set Ollama's context length to at least 16K.
   - **Claude:** paste an API key from [console.anthropic.com](https://console.anthropic.com/settings/keys). Usage is billed to your account.
4. Let the app turn on RCON for you (close Factorio first).
5. In Factorio, **host a multiplayer game** (a private one is fine; single player doesn't open RCON).
6. Type `/ai-pair <code>` using the code the app shows. Your engineer appears next to you.

## Commands

- `/ai <message>`: talk to it (`/ai` alone opens the chat window)
- `/ai stop`: stop what it's doing
- `/ai autopilot`: toggle autopilot
- `/ai clear`: start a new chat
- `/ai-cam`: follow your engineer with the camera

It only listens to the player who paired it. Other players can't control it.

Full guide and source: [github.com/jhacc/ai-engineer](https://github.com/jhacc/ai-engineer)
