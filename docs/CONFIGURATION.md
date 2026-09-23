# Configuration reference

Everything the bridge reads: `bridge/config.json`, command-line flags, environment variables, and the files it writes next to itself. `node setup.js` writes a working `config.json` from `bridge/config.example.json`; this page explains each key so you can tune it by hand.

The bridge reads `config.json` once at start. Restart it after editing, except for `allowedTools`, which the **Allow & retry** button updates live.

## Paths

| Key | Default (from `config.example.json`) | Meaning |
|---|---|---|
| `addonDir` | `…\World of Warcraft\_classic_beta_\Interface\AddOns` | The game's AddOns folder. The bridge writes the slot addons, `Inbox.lua` and every signal file under it. `setup.js` fills this in from the client it finds. |
| `inboxFile` | `<addonDir>\WoWClaude\Inbox.lua` | The file the game reads on `/reload` (fallback path). Normally derived from `addonDir`; only change it if you moved the addon. |
| `savedVariablesFile` | `…\WTF\Account\<account>\SavedVariables\WoWClaude.lua` | The addon's saved data. The bridge polls it for the reload-path outbox. `setup.js` picks the first account under `WTF\Account`; pass `--account <name>` to choose another. |
| `defaultCwd` | `C:\path\to\your\project` | Folder for chats that have not chosen one with `/wow-claude cd`, when the bridge is started from inside this repo (`npm start`). See [Which folder Claude works in](#which-folder-claude-works-in). |
| `claudePath` | `""` | Full path to the `claude` executable. Empty means: look in `%UserProfile%\.local\bin\claude.exe`, then on `PATH`. |

## Running Claude

| Key | Default | Meaning |
|---|---|---|
| `permissionMode` | `"acceptEdits"` | Passed to `claude -p --permission-mode`. `acceptEdits` auto-approves file edits inside the working folder; `bypassPermissions` approves everything; `default` denies anything not in `allowedTools`. |
| `allowedTools` | git, npm, npx, node, python, pip, pytest, ls, dir, WebSearch, WebFetch | Rules passed to `claude -p --allowedTools`. `Bash(git:*)` allows any command starting with `git`. The **Allow & retry** button in game appends rules here permanently. |
| `model` | `""` | Passed to `claude -p --model` when non-empty. Empty uses Claude Code's default. |
| `maxParallel` | `3` | How many chats may run Claude at the same time. Further messages queue per chat. |
| `timeoutMs` | `1800000` (30 min) | A Claude run longer than this is killed and reported as an error in game. |
| `progressWriteMs` | `3000` | Minimum gap between progress writes to the slot files. Final replies are written immediately. |
| `pollMs` | `750` | How often the bridge checks the SavedVariables file for a reload-path message. |

## Screen capture

Keys under `capture`:

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Run `capture.ps1`. With `false` only the reload path works (`/wow-claude mode reload` in game). |
| `processName` | `"WowB"` | The game executable without `.exe`. `setup.js` sets it from the `Wow*.exe` it finds in the client folder. |
| `cellPx` | `4` | Pixel size of one strip cell. Must match `CELL` in `addon/WoWClaude/Codec.lua`. |
| `cellsPerRow` | `200` | Cells per strip row. Must match the addon. |
| `maxRows` | `48` | Maximum strip rows captured. Must match the addon. |
| `intervalMs` | `250` | Capture period. Lower is more responsive and costs a little more CPU. |

The capture region is `cellsPerRow × cellPx` by `maxRows × cellPx` pixels (800 × 192 by default) at the top-left of the game's client area.

## Slot pool and signal files

These sizes are baked into the files `install-slots.js` creates, and the addon has matching constants at the top of `addon/WoWClaude/WoWClaude.lua` (`SLOT_COUNT`, `ACT_MAX`, `PRESENCE_MAX`). Change all three places together, re-run `node bridge/install-slots.js`, and restart the game.

| Key | Default | Meaning |
|---|---|---|
| `slots` | `200` | Reply-slot addons `WoWClaude_S001` … `WoWClaude_S200`. Each slot can be loaded once per UI session; `/reload` frees them all. |
| `actMax` | `60` | Heartbeat files per message (`act/NNN/01..60.wav`). One flips per Claude action. |
| `presenceMax` | `2000` | Presence files (`presence/0001..2000.wav`). One flips per `presenceIntervalMs`. |
| `presenceIntervalMs` | `30000` | How often the bridge flips a presence file so the in-game light stays green. |
| `tocInterface` | `"16001"` | `## Interface:` version written into every slot addon's `.toc`. Bump it when the client's TOC version changes. |

## Command line

`wow-claude` (after `npm link`) and `node bridge/bridge.js` take the same flags. `npm start` runs `bridge/supervisor.js`, which restarts the bridge on crash and passes flags through.

| Flag | Meaning |
|---|---|
| `--project <dir>` | Default working folder for this run. Overrides everything else. |
| `--once` | Handle one pending reload-path message and exit. |
| `--inject "<text>"` | Pretend the strip said this, run Claude, publish the result, exit. Handy for checking a setup without the game. |
| `--help`, `-h` | Print usage. |

Exit codes: `0` normal, `1` the injected or one-shot job failed, `2` config missing or unreadable. The supervisor only restarts on codes other than `0` and `2`.

## Environment

| Variable | Meaning |
|---|---|
| `WOW_CLAUDE_PROJECT` | Default working folder, below `--project` and above the start folder in precedence. |
| `CLAUDECODE` | Removed from the child's environment so a bridge started from inside a Claude Code session can still launch `claude -p`. |

## Which folder Claude works in

Each chat can pick its own folder with `/wow-claude cd` or **Folder...** in the menu that opens when you right-click the chat in the left panel. Chats that have not are given the bridge's default folder, chosen in this order:

1. `--project <dir>`
2. `WOW_CLAUDE_PROJECT`
3. The folder the bridge was started from, unless that is inside this repo
4. `defaultCwd` in `config.json`
5. The current folder

A relative `/wow-claude cd` path is resolved against that default. `~` expands to your home folder. Claude Code keeps sessions per folder, so a chat that changes folder starts a fresh session there.

## Files the bridge writes next to itself

All of these are gitignored.

| File | Contents |
|---|---|
| `bridge/config.json` | Your configuration. |
| `bridge/state.json` | Claude session ids per chat, the folder each session ran in, handled message ids per addon session token, and the presence counter. Delete it to forget all sessions. |
| `bridge/transcripts.json` | The last 200 messages of every chat, so the addon can recover its chats after the client wipes saved data. |
| `bridge/bridge.log` | Everything printed to the console, with timestamps. Grows without bound; delete it whenever you like. |

## `setup.js` flags

| Flag | Meaning |
|---|---|
| `--wow "<client folder>"` | The folder containing `Wow*.exe` and `Interface\`, when auto-detection fails. |
| `--project "<dir>"` | Written to `defaultCwd`. Defaults to the folder you ran setup from. |
| `--account <name>` | Which `WTF\Account\<name>` to use when there are several. |

Re-running `setup.js` re-copies the addon (except `Inbox.lua`, which the bridge owns once running), keeps an existing `config.json`, and only creates slot and signal files that are missing.
