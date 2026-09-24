# Architecture

Two processes that can't talk to each other directly, and how they do anyway.

```
   WoW client (Lua sandbox)                        bridge.js (Node, same machine)
   ┌──────────────────────────┐                    ┌─────────────────────────────┐
   │ WoWClaude addon         │  pixels on screen  │ capture.ps1 (PowerShell)    │
   │  draws message strip ────┼───────────────────▶│  screen-captures the corner │
   │                          │                    │  decodes → {session,chat,id,│
   │                          │                    │            cwd,flags,name,  │
   │                          │                    │            text}            │
   │                          │                    │        │                    │
   │                          │                    │        ▼                    │
   │                          │                    │  claude -p (per chat,       │
   │                          │                    │   parallel, --resume)       │
   │                          │                    │        │                    │
   │  LoadAddOn(WoWClaude_S…)│  files on disk     │        ▼                    │
   │  ◀───────────────────────┼────────────────────┤  writes 200 slot Inbox.lua  │
   │  PlaySoundFile(sig/…)    │                    │  flips signal/heartbeat wav │
   └──────────────────────────┘                    └─────────────────────────────┘
```

## The sandbox

WoW addons cannot open sockets, read files, run programs or receive input from other processes. What they *can* do that reaches outside:

1. Draw pixels. Anything on screen can be captured by another process.
2. Load files that already existed when the client launched, the first time each is used. Files created after launch are not discovered. A file that was already loaded keeps returning the cached content for the rest of the process, even across `/reload` (fonts, sounds, textures) — except addon **Lua code**, which is re-read on `/reload`. These rules were measured on a live Forever client by [wow-forever-codex](https://github.com/0xinuarashi/wow-forever-codex) and match what this project observes.
3. Write SavedVariables — but only on `/reload` or logout, and `ReloadUI()` can only be called from a hardware event (a key or click), never from a timer.

Everything below follows from those three facts.

## Outbound: the pixel strip

`Codec.lua` turns a message into a byte stream and packs it into 3-bit cells:

```
[0xC7 0x1A] [id hi, lo] [len hi, lo] [payload…] [Fletcher-16 s1, s2]
```

Each cell is a 4×4-pixel square drawn with `SetColorTexture`, each channel fully on or off (8 colors). Pure primaries survive any gamma/contrast setting, unlike intermediate levels (a first version used 4 levels per channel and misread under some display settings). 200 cells per row, up to 48 rows, anchored at the top-left of `UIParent` with the frame scaled to `768 / physicalScreenHeight` so one UI unit is exactly one pixel. Capacity ≈ 3.2 KB per frame.

The payload is one or more records separated by `\x1E`, fields by `\x1F`:

```
session \x1F chat \x1F id \x1F cwd \x1F flags \x1F name \x1F [context \x1F] text
```

- `session` — a random token generated when the addon's saved data is created. Message ids restart if the client wipes saved data; the bridge dedups on `(session, id)`.
- `flags` — `n` = start a fresh Claude session; `h` = hello (announce the session token, no prompt); `d` = the chat was deleted in game: drop its transcript and Claude session, no prompt (the addon keeps the id in `db.forget` and resends it with each hello until the bridge acks); `c` = a game-context field sits between `name` and `text`; `allow=Rule1,Rule2` = add permission rules before running.
- `context` — only present with the `c` flag (so a separator inside the text can't be mistaken for it): a few lines about the game, character, zone, map coordinates, money, talents and professions (`WoWClaude.GameContext()`, capped at 700 bytes; since coordinates change as you move, most messages sent after walking somewhere carry a fresh copy). Every hello carries it (empty when `/wow-claude context off`); a message carries it only when it differs from the last version the bridge acknowledged, and only if it fits next to the text.
- `text` — the message. Item, spell and quest links the player shift-clicked in (`|Hitem:2140:…|h[Fine Longsword]|h`) are expanded before sending: `[Fine Longsword]` stays in the text and the link's tooltip, read off a hidden `GameTooltip` via `SetHyperlink`, is appended in a `--- Linked from the game ---` block.

The strip stays up until the bridge acknowledges the message (see signals) or 40 s pass, then it is re-shown up to three times before the addon gives up on pixels and arms the reload fallback for that message.

`capture.ps1` finds the game window by process name, captures the client area's top-left 800×192 px with GDI (`CopyFromScreen`, DPI-aware), samples the center pixel of each cell, and validates magic, length and checksum. It prints one JSON line per new message and rate-limited warnings when a frame is seen but rejected. `bridge.js` restarts it if it exits.

Exclusive fullscreen blocks GDI capture; borderless/windowed works. HDR was not tested.

## Inbound: load-on-demand slots

`install-slots.js` creates `WoWClaude_S001` … `WoWClaude_S200`, each a `## LoadOnDemand: 1` addon with a single `Inbox.lua`. `C_AddOns.LoadAddOn` reads that file from disk at load time; each slot can be loaded once per UI session, and `/reload` unloads them all.

The bridge doesn't know which slot the game will load next, so every publish writes the same content to all 200 (atomic rename per file, ~1 MB total, cheap). The content is the latest status of every chat:

```lua
WoWClaude_SlotData = {
  ts = "...", now = <bridge epoch seconds>,
  replies = { { chat = "...", id = 12, status = "working"|"done"|"error", text = "...", cwd = "...", session = "<claude session id>", denied = { "WebSearch" } }, … },
  restore = { token = "...", chats = { … } },   -- only right after a saved-data reset
}
```

The addon loads a fresh slot on a schedule after each send (5, 10, 16, 24, 34, 46, 60, 80, 100, 130, 160, 200, 240, 300 s, then every 60 s) or immediately when the readiness signal fires. A slot poll matches replies by `(chat, id)` against each chat's pending message. `now` lets the addon know when the bridge last wrote anything (the two clocks are the same machine).

The same content is written to `WoWClaude/Inbox.lua`, which the game reads on `/reload` — the fallback path and the only path in `mode reload`.

## Signals: the empty-wav trick

`PlaySoundFile(path)` returns whether the file will play. An empty file won't; a valid one will; a file that has never been loaded is read fresh. So a pre-made empty `.wav` is a one-shot flag the bridge can raise at any time and the addon can poll for free:

| Files | Raised when |
|---|---|
| `sig/NNN.wav` | reply NNN is ready → load a slot now instead of waiting for the schedule |
| `ack/NNN.wav` | the bridge received message NNN → take it off the strip |
| `act/NNN/kk.wav` | Claude's k-th action on message NNN → live "14 actions, last 6 s ago" without spending a slot |
| `presence/kkkk.wav` | every 30 s while the bridge runs → the status light; the bridge keeps the 50 files ahead of its counter empty so the addon can't run ahead |
| `ctl/empty.wav`, `ctl/valid.wav` | never change; at login the addon checks that empty reads as unplayable and valid as playable, and disables the whole mechanism if not |

`NNN = ((id − 1) mod 200) + 1`. A raised file stays playable for the rest of the client process even if the bridge empties it again, so every consumer treats an unexpected "already valid" as unreliable and falls back to slot polling. With the sound channel off, the addon still works: replies come from the scheduled slot polls, and while idle it spends one slot every 10 minutes to keep the status light honest. The light's timing follows the mode: with beats the bridge is heard from every 30 s, so 90 s of silence is "stale" and 5 minutes is "down"; without them the only evidence is that 10-minute idle poll, so the windows are 12 and 22 minutes instead (`/wow-claude diag` shows which mode is active). Some clients report an empty file as playable — the self-test catches that and the addon runs in this slot-only mode for the whole session.

## Bridge

`bridge.js` (zero dependencies), with the pure protocol code in `protocol.js` (strip records, slot files, folders, dedup; unit-tested in `tests/bridge_test.js`):

- **Inputs:** capture lines; the SavedVariables outbox (fallback, written on `/reload`); `--inject` for tests.
- **Dedup:** `state.handled[session]` is a set of ids; older single-number state is migrated.
- **Folders:** the default folder is `--project`, else the folder the bridge was started from (the `wow-claude` command, see README), else `defaultCwd` in the config; it is reported to the addon as `cwd` in every slot file. A chat's folder is resolved against it (`realms` → `<default>\realms`; empty = the default). Claude keeps sessions per project folder, so `state.json` remembers the folder each session ran in and a chat that changed folder starts a new session.
- **Jobs:** one Claude process per chat, up to `maxParallel` at once, queued per chat beyond that. `claude -p --output-format stream-json --verbose --permission-mode … --allowedTools … [--resume <id>]`, prompt on stdin. Tool-use events become progress lines (`edit player.gd`, `$ npm test`) and heartbeat files; the final `result` becomes the reply. Claude session ids are stored per chat id in `state.json`, so `--resume` survives an addon data reset.
- **Permissions:** `permission_denials` in the result are turned into allowlist rules (`Bash(<first word>:*)` or the tool name) and sent along as `denied`; an `allow=` flag on a later message merges them into `config.json`.
- **Game context:** the latest context field received is kept in `state.json` (`context`), an empty one clears it. While one is held and `gameContext` in the config isn't `false`, every run gets `--append-system-prompt` with `protocol.systemPrompt(context, primer)`: a short note that the user is in WoW talking through the addon, the context lines, what the `[Name]` links and the "Linked from the game" block mean, and the addon/macro primer (`primerFile`, default `docs/WOW-ADDON-PRIMER.md`, read fresh each run). No context, nothing appended, primer included.
- **Transcripts:** every prompt and reply is appended to `transcripts.json` per chat. The first message from an unknown session token means the addon's saved data is fresh, so the next three publishes carry a `restore` bundle (up to 16 chats, 40 messages each) addressed to that token; the addon imports chats it doesn't have.
- **Publishing:** final results immediately; progress throttled to one write per 3 s.

`supervisor.js` restarts the bridge 3 s after any exit. `npm start` / `start.ps1` run it in the current terminal; `start-window.cmd` opens its own console window (a `.cmd` running inline would make Ctrl+C trigger cmd's "Terminate batch job?" prompt).

## Addon

`WoWClaude.lua` is a single file; sections in order: helpers, reload fallback, pixel strip, signals and slots, game context and links, sending, chats, rendering, UI, slash commands, events. `tests/addon_test.js` runs it in a Lua VM with a stub client (`tests/wow_stub.lua`) through a whole session: login, hello, a message decoded off the strip, a slot reply, Allow, restore.

- **Chats:** `db.chats[]` with id, name, cwd, history, pendingId, unread, draft. A chat named `Chat N` takes its title from the first message. Deleting the last chat resets it instead.
- **Transcript:** a scroll frame of message bubbles (accent bar + colored label per role, timestamp, wrapped body); clicking a message opens a copy box, since FontStrings can't be selected. The working bubble shows elapsed time, heartbeat counts and the latest progress lines.
- **Windows:** main frame (a minimize button and Esc collapse it to the mini bar; Esc is caught in `OnHide` unless the whole UI is hiding), a mini bar with the status light and unread/working badge, a rename `StaticPopup`.
- **Game context and links:** `GameContext()` asks the client about the build, character, zone, money, talents and skill lines, each call wrapped so a missing API just leaves its line out. `ExpandLinks()` rewrites `|H…|h[Name]|h` links in a message before it is sent (see the record format above). Shift-clicked links reach the addon's input box through a `hooksecurefunc` on `ChatFrameUtil.InsertLink` (the Forever client uses the modern chat code; every shift-click, from bags, spellbook or quest log, ends there; the old `ChatEdit_InsertLink` global is hooked instead only where the new one is missing), which only inserts when that box has keyboard focus, so shift-click elsewhere keeps its normal meaning.
- **Game chat:** replies are printed line by line under `[Claude · name]` with `[reply]`/`[open]` hyperlinks (`|Hclaude:…|h`, handled via `hooksecurefunc("SetItemRef")`). `/ai` sends from the chat box. `/r` is handled by wrapping `ProcessChatType`, `SendMessage` and `SendText` on each chat edit box: when Claude was the last messenger, the box shows a repainted "To Claude [name]:" header and Enter routes to Claude with the box cleared first, so the game never sends anything; the underlying chat type is untouched, and `UpdateHeader`/`ClearChat` hooks end Claude mode on Tab, `/s`, Esc or a real incoming whisper.
- **Reload fallback:** `ReloadUI()` needs a hardware event, so "auto" reload is a hidden keyboard-capturing frame with `SetPropagateKeyboardInput(true)` that reloads on the player's next keypress once the interval has elapsed. Only armed when pixels or slots can't work.

## Limits and known issues

- The client's saved-data wipe (observed on the beta) is outside the addon's control; recovery depends on the bridge having been running.
- 200 slots per UI session. Each reply costs one slot when the readiness signal works, about four otherwise; `/wow-claude reload` resets the pool.
- A raised signal file stays "valid" in the client until a full restart, so slot numbers that wrap around (every 200 messages) lose the cheap signals until then. Self-detected.
- Message capacity ≈ 3.2 KB per send; longer text is refused with a hint.
- Replies are published in full (a ~3 KB message can produce a 60 KB reply; that is fine for a slot file). The bridge-side transcript keeps the first 4000 characters of each message, and a restore sends back the last 40 messages per chat at 2000 characters each.
- Windows only (PowerShell capture, NTFS).
