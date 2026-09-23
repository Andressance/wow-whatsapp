# wow-claude

<p align="center">
  <img src="docs/screenshot.jpg" alt="The WoW Claude chat window open in Goldshire, with a message on its way to Claude Code" width="900">
</p>

Chat with your local [Claude Code](https://claude.com/claude-code) sessions from inside **World of Warcraft: Forever** — send a task, go back to questing, get pinged in-game when the answer lands. No alt-tabbing, no `/reload` per message.

- Multiple chats, each its own persistent Claude session (like separate terminals), running in parallel
- Live progress while Claude works: action count, elapsed time, the files it's editing and commands it's running
- Replies echoed into the game chat; `/r` replies to Claude when it was the last to message you
- An **Allow & retry** button when Claude needs a command outside your allowlist
- A status light for the bridge, automatic retries, and recovery of your chats if the beta client wipes addon data

Nothing here injects code, reads game memory, or generates input. The addon uses documented addon APIs only; the companion reads your screen and writes ordinary files.

## How it works, in one paragraph

WoW addons are sandboxed: no network, no file reads at runtime. Two doors remain. **Out:** the addon draws your message as a strip of colored 4-pixel squares in the top-left corner of the screen; the bridge screen-captures that corner four times a second and decodes it. **In:** a load-on-demand addon reads its files from disk at the moment it is loaded, so the bridge writes the reply into a pool of 200 pre-made slot addons and the game loads a fresh one from a timer. Cheap "is it ready yet" checks ride on a third trick: an empty `.wav` won't play and a valid one will. Details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Requirements

- Windows, NTFS
- World of Warcraft: Forever (tested on 1.60.1.69913, TOC 16001), **windowed or borderless** — exclusive fullscreen blocks screen capture
- [Node.js](https://nodejs.org) 22.2 or newer
- [Claude Code](https://claude.com/claude-code) installed and logged in (`claude --version` works)

## Install

Step-by-step for a fresh machine, with troubleshooting: [docs/INSTALL-WINDOWS.md](docs/INSTALL-WINDOWS.md). The short version:

```powershell
git clone https://github.com/chelinho139/wow-claude
cd wow-claude
node setup.js --project "C:\path\to\the\project\you\want\to\work\on"
```

`setup.js` finds the client (pass `--wow "<client folder>"` if it can't), copies the addon into `Interface\AddOns\WoWClaude`, writes `bridge/config.json`, and generates the slot pool and signal files (≈15,000 tiny files; that's normal — the client only discovers addon files at launch, so they have to exist up front).

Then **fully quit and relaunch WoW**, enable *WoW Claude* on the AddOns screen, and start the bridge:

```
npm start               # in the current terminal (or: bridge\start.ps1)
bridge\start-window.cmd # double-click version: opens its own window
```

It restarts itself if it ever crashes. Ctrl+C (or closing the window) stops it.

### `wow-claude`: start it from the project folder

Like `claude` itself, the bridge works in the folder you start it from. Install the command once:

```powershell
npm link          # in the wow-claude folder; makes `wow-claude` available everywhere
```

Then, from any project:

```powershell
cd C:\path\to\realms
wow-claude
```

Every chat that hasn't picked its own folder now works in `realms`, and the panel's cwd line shows it. `wow-claude --project <dir>` names the folder explicitly; `npm start` inside this repo falls back to `defaultCwd` in the config. Only one bridge can run at a time (two would fight over the screen and the slot files), so this sets the default folder rather than giving you one bridge per project.

## Use

In game: `/wow-claude` opens the window. Until the bridge has answered, a **Connect** button sits where Send would be: start the bridge, click it, and the light turns green (a message typed before that stays in the box). Then click the input box, type, Enter. The reply arrives with the whisper sound; the window's light shows the bridge state (green/yellow/red, hover for details), and **Reconnect** shows up if the bridge goes quiet.

Right-clicking a chat in the left panel opens a small menu with **Rename...** and **Folder...** (right-click again to close it); the trash can on the row deletes the chat after an OK/Cancel confirm. **Folder...** sets the folder this chat's Claude works in (same as `/wow-claude cd` below); each chat keeps its own, so you can have chats on different projects side by side.

| Command | What it does |
|---|---|
| `/wow-claude` | toggle the window; the minimize button (top right) or Esc collapses it to a small bar, click the bar to expand |
| `/ai <text>` | send from the normal chat box (`/wow-claude <text>` is the same) |
| `/r <text>` | replies to Claude when Claude was the last to message you; otherwise the normal whisper reply |
| `/wow-claude new [name]` | new chat = new Claude session. Unnamed chats take their title from your first message |
| `/wow-claude chat <n\|name>` | switch chats (or click the left panel; right-click a row for Rename and Folder, its trash can deletes it) |
| `/wow-claude cd <folder>` | folder this chat's Claude works in (**Folder...** after right-clicking the chat opens the same thing as a dialog). Relative to the bridge's folder (`/wow-claude cd realms`, `/wow-claude cd ../other`), `~` works, a full path too; `/wow-claude cd` alone goes back to the bridge's default. A chat that changes folder starts a fresh Claude session there |
| `/wow-claude reset` | wipe this chat's Claude memory, keep the transcript |
| `/wow-claude rename`, `/wow-claude delete`, `/wow-claude clear` | manage the current chat |
| `/wow-claude echo full\|short\|off\|<chars>` | how much of each reply to print into the game chat (default 4000 chars) |
| `/wow-claude longchat on` | let the game chat box take 4000 characters, for long `/ai` messages |
| `/wow-claude bind <key>` | hotkey: checks for a reply while waiting, otherwise toggles the window |
| `/wow-claude cancel` | stop waiting on this chat's reply |
| `/wow-claude resend` | show the strip again if the bridge missed it |
| `/wow-claude reload` | reload the UI now (also frees the slot pool) |
| `/wow-claude mode reload` | fallback transport that costs a `/reload` per step, if pixels or slots can't work |
| `/wow-claude diag`, `/wow-claude slots` | transport diagnostics |
| `/wow-claude help` | the full list |

Click any message, or `/wow-claude copy` for the last reply, to open it in a selectable box for Ctrl+C.

### Permissions

Claude runs headless, so it can't ask you to approve a tool. `permissionMode` in `bridge/config.json` is `acceptEdits` by default (file edits inside the project are auto-approved) and `allowedTools` lists the commands it may run. Anything else is denied, and the reply grows an **Allow WebSearch, Bash(cargo:*) & retry** button: click it, the rules are added to your config permanently, and Claude resumes where it stopped. The rule is a prefix (`Bash(rm:*)` allows any `rm`), so read the button before clicking. `bypassPermissions` gives full autonomy; you decide.

## Configuration (`bridge/config.json`)

The keys you are most likely to touch. Every key, flag and environment variable is in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

| Key | Meaning |
|---|---|
| `defaultCwd` | folder for chats that haven't been given one with `/wow-claude cd` |
| `maxParallel` | how many chats may run Claude at once (default 3) |
| `permissionMode`, `allowedTools`, `model` | passed to `claude -p` |
| `capture.processName` | the game exe without `.exe` (`WowB` for Forever); set by `setup.js` |
| `slots`, `actMax`, `presenceMax` | pool sizes; must match the constants at the top of `WoWClaude.lua` if you change them |
| `timeoutMs` | kill a run that takes longer than this (default 30 min) |

## Troubleshooting

- **Connect says "No answer from the bridge" / light stays red** — is the bridge running? Is the game window on screen and not minimized? Exclusive fullscreen blocks capture. `bridge.log` shows `strip #N` when a message is decoded and `strip seen but rejected: ...` when one is misread.
- **Reply never appears but `bridge.log` says `done`** — `/wow-claude slots`; if the pool is empty, `/wow-claude reload` frees it and picks the reply up via the fallback path.
- **"Reply slots not installed"** — `node bridge/install-slots.js`, then restart WoW.
- **Chats vanished after a reload** — the beta client sometimes wipes addon saved data. The bridge keeps `transcripts.json` and sends your chats back automatically on the next message.
- **`/wow-claude diag` says the sound channel is unusable** — the cheap readiness checks and heartbeat are off; everything still works through slot polls, just with coarser progress. If it says a valid file reports as unplayable, WoW hasn't been restarted since the files were created.

## Documentation

- [docs/INSTALL-WINDOWS.md](docs/INSTALL-WINDOWS.md): step-by-step install on a fresh machine, with troubleshooting
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md): every config key, command-line flag and environment variable
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the pixel strip, slot pool and signal files work, and why
- [CONTRIBUTING.md](CONTRIBUTING.md): repo layout, running the tests, conventions
- [CHANGELOG.md](CHANGELOG.md): release notes

## Development

```
npm install
npm test          # everything except the live test; CI runs it on Windows (.github/workflows/test.yml)
npm run test:live # runs the bridge in a sandbox with a real Claude call
```

Layout: `addon/WoWClaude` is the addon, `bridge/` the companion (`bridge.js` does I/O and processes, `protocol.js` is the pure part), `docs/` the design and reference, `tests/` the checks. After editing the addon, copy it into the game folder (`node setup.js` does that too) and `/reload`. What each test covers, and the conventions for changes, are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

- [0xInuarashi's wow-forever-codex](https://github.com/0xinuarashi/wow-forever-codex) measured the client's file-loading rules on a live Forever build (files must exist at launch; a not-yet-loaded file is read fresh on first use) and pioneered the pixel-out channel for Codex, with a font-metrics return channel. This project uses the same rules with load-on-demand addons instead of fonts.
- [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source) — Blizzard's UI code, `forever` branch, used to verify every API this addon calls.

## License

MIT — see [LICENSE](LICENSE).
