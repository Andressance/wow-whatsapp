# Changelog

All notable changes to this project are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [0.4.0] - 2026-11-08

Brings the fork up to date with the parts of [chelinho139/wow-ai](https://github.com/chelinho139/wow-ai) 0.4.0 and 0.5.0 that a WhatsApp client needs, redesigns the window, and removes what was left of the AI-assistant version. Existing installs: `git pull`, `npm install`, `node setup.js`, then quit and relaunch the game.

### Added

- **A messenger window** in the style of the whisper messenger addons: flat dark panels, a chat list with avatar, last message, time, unread badge and a search box, sorted by latest activity; a conversation with bubbles on the right for you and on the left for them, date separators, quoted replies, sender names in groups and a delivery mark (sending, sent, failed); a composer that grows with what you type, with a Send button; a mini bar that shows how many messages are unread.
- Messages typed on the phone are mirrored into the window as your own (the bridge listens to `message_create`), without a notification. Messages sent from WoW are not mirrored twice.
- **New chat with a phone number**: the **+** button or `/wa new 34600112233` (country code, digits only). The bridge checks the number is on WhatsApp before sending. `/wa chat <number>` finds it again.
- Messages typed while one is still on its way are queued and go out one at a time, in order.
- When the chat list (now 50) is full, the quietest chat makes room for a new contact instead of dropping the incoming message.
- Right-click menu on a chat: Rename, Mark as read, Clear history, Delete.
- The WhatsApp timestamp of each message is kept; a message that arrives while the window is closed counts as unread.
- Replying from the game marks the chat as read on the phone.
- A dropped WhatsApp Web session is rebuilt by the bridge; messages sent while it starts wait up to 90 seconds instead of failing.
- Wow.exe / `_forever_` support from upstream: `setup.js` looks for `_forever_` first, moves a config still on `_classic_beta_` to it and keeps the other settings, no longer needs a first login, and the bridge warns about a beta config. The Windows capture only attaches to a game running from the same client folder as `addonDir`.
- `tests/inject_test.js` now runs offline against a fake provider and is part of `npm test`.

### Changed

- The slash command is `/wa` first (`/wow-whatsapp`, `/whatsapp`, `/ai` and `/ask` still work).
- Shift-clicked items, spells and quests are sent as their plain `[Name]`; the tooltip block that was appended for the AI assistant is gone.
- `whatsapp.authPath` is resolved against the repository, not the folder the bridge was started from (starting it elsewhere meant scanning the QR code again).
- State and transcript files are written atomically.
- Default capture process name is `Wow`; `bridge/config.example.json` points at `_forever_` and lost the AI-assistant keys.

### Removed

- Everything left from the AI-assistant version: working folders (`/wa cd`, the Folder prompt), game context sent to the bridge, the Allow & retry button, the "working" progress bubble and its heartbeat files (12 000 fewer files in the slot install), `/wa reset`, the system prompt and addon primer (`docs/WOW-ADDON-PRIMER.md`), permission rules and tool-call descriptions in the bridge.
- Not taken from upstream because they only make sense for an AI assistant: agents, map layers, macro buttons, TL;DR echo, Linux/macOS capture.

### Fixed

- **"New chat" could not send**: it created a local random id that was not a WhatsApp recipient. Chats now come from a phone number or an incoming message.
- A message could not be sent twice in a row: the chat stayed locked until a slot reply arrived. It is now delivered as soon as the bridge acks it.
- Signal files (`ack`, `sig`) were never reset, so after 200 messages a stale valid file looked like an answer to a new message. The bridge keeps the files of the next ids empty.
- Incoming messages flipped `sig/NNN.wav` with the bridge's own counter, which could be read as the answer to an unrelated message of the player and switch the sound channel off for the session.
- `--once` and `--inject` exited before the message was sent, or never. They now wait for the send (and for WhatsApp Web to be ready).
- The bridge's in-memory list of recent records grew without bound.
- The reload-mode outbox lost chat ids containing `@` or `.`, which is every WhatsApp id; they are now hex-encoded like the text.
- Record separators typed into a message could split the pixel-strip record; every field is cleaned now.
- Incoming messages from a contact when 16 chats existed were silently dropped.
- Status updates, broadcast lists and channels are ignored instead of creating chats.

## [0.3.0] - 2026-09-22

First public release (as wow-claude, a client for Claude Code sessions; transformed into a WhatsApp client afterwards).

[0.4.0]: https://github.com/Andressance/wow-whatsapp/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/chelinho139/wow-whatsapp/releases/tag/v0.3.0
