# Contributing

Thanks for looking at this. Bug reports, questions and pull requests are all welcome. This page covers how the repo is laid out, how to run the tests, and what a good change looks like.

## Layout

```
addon/WoWWhatsApp/     the in-game addon (Lua 5.1, WoW API)
  WoWWhatsApp.lua        everything: strip, slots, chats, UI, slash commands
  Codec.lua             pixel-strip encoder, pure Lua, no WoW calls
  Inbox.lua             placeholder the bridge overwrites at runtime
  WoWWhatsApp.toc
bridge/               the companion process (Node.js, no runtime dependencies)
  bridge.js             I/O, processes, publishing
  protocol.js           pure functions: strip records, slot files, folders, dedup
  capture.ps1           screen capture and strip decoder (PowerShell)
  install-slots.js      creates the slot addons and signal files
  supervisor.js         restarts bridge.js on crash; the `wow-whatsapp` command
  config.example.json   template setup.js copies to config.json
setup.js              one-shot installer
tests/                see below
docs/                 ARCHITECTURE.md, CONFIGURATION.md, INSTALL-WINDOWS.md
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first. The two transports (pixels out, load-on-demand slots in) follow from three facts about the WoW sandbox, and most design choices make sense only in that light.

## Setting up for development

```powershell
git clone https://github.com/chelinho139/wow-whatsapp
cd wow-whatsapp
npm install          # test tooling only: fengari (Lua VM) and luaparse
npm test
```

`npm test` needs Windows, because the codec round-trip runs the real `capture.ps1` decoder in PowerShell. Everything else in the suite is portable. CI runs the same command on `windows-latest` (`.github/workflows/test.yml`).

To try changes in the game, run `node setup.js` (it re-copies the addon into `Interface\AddOns\WoWWhatsApp`) and `/reload`. Bridge changes take effect on the next `npm start`.

## Tests

| Command | What it checks |
|---|---|
| `node tests/order_check.js` | The addon parses as Lua 5.1 and no top-level `local` is used before it is declared. |
| `node --test tests/addon_test.js` | The real addon in a Lua VM with a stub client (`tests/wow_stub.lua`): login, hello, a message decoded off the strip, a slot reply, Allow, `/wow-whatsapp reset`, restore, chat commands, minimize, reload mode. |
| `node --test tests/bridge_test.js` | `bridge/protocol.js`: strip records, flags, the SavedVariables outbox, folder resolution, permission rules, dedup and pruning. |
| `node --test tests/restore_test.js` | Slot files are valid Lua and read back field by field, including a restore bundle. |
| `node tests/codec_test.js` | `Codec.lua` in a Lua VM, rendered to PNG with noise and gamma, decoded by `capture.ps1`. Writes scratch images to `tests/tmp/` (gitignored). |
| `npm run test:live` | Not part of `npm test`. Builds a sandbox under `tests/tmp/inject/` with a 5-slot pool and runs the bridge with `--inject` against a real `whatsapp` CLI. Needs WhatsApp installed and logged in. |

When you change behaviour, add or extend a test in the matching file. Pure logic belongs in `protocol.js` where `bridge_test.js` can reach it without spawning anything.

## Conventions

- **Lua** uses tabs, `local` everything, and only APIs present in the Forever client. Check against the `forever` branch of [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source) before using a new API.
- **JavaScript** uses two-space indent, single quotes, `'use strict'`, CommonJS. The bridge must stay dependency-free: it is installed with `npm link` on machines that may never run `npm install`.
- **Transport constants** (`slots`, `actMax`, `presenceMax`, strip cell size and row counts) live in three places that must agree: `config.example.json`, the top of `WoWWhatsApp.lua`, and `Codec.lua`. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md).
- **Compatibility:** the bridge accepts older strip record formats and older `state.json` layouts. Keep that when changing a format, and note it in `CHANGELOG.md`.
- Comments explain why, not what. Keep the section banners in `WoWWhatsApp.lua` and `bridge.js` in order.

## Pull requests

1. Open an issue first for anything larger than a fix, so the approach can be discussed before you spend time on it.
2. One change per PR. Include the test that shows it works.
3. `npm test` must pass. Say in the PR whether you tried it in the game and on which client build.
4. Update `README.md`, `docs/`, and `CHANGELOG.md` when user-visible behaviour changes.

## Reporting bugs

Use the bug-report template. The useful details are the client build (shown on the login screen), the last lines of `bridge/bridge.log`, and the output of `/wow-whatsapp diag` in game.
