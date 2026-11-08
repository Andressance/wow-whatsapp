# wow-whatsapp

Chat with WhatsApp contacts and groups from inside World of Warcraft: Forever,
in a messenger window in the style of the whisper messenger addons: chat list on
the left, bubbles on the right. Messages travel through the existing WoW addon
transport, so the game needs no network access and no `/reload` for normal
messages.

> **Responsibility and compatibility notice:** this is an independent,
> community-made project. It uses a third-party WhatsApp Web client and an
> external addon/bridge integration that may not be permitted by Blizzard or
> WhatsApp terms. Use it only if you accept those risks. You are responsible
> for your account, device, data and any consequences of using it. The authors
> provide no guarantee against warnings, restrictions, suspension, data loss or
> service changes.

## Features

- **Messenger window:** a chat list sorted by latest activity (avatar, last
  message, time, unread badge, search box), and a conversation with right-aligned
  bubbles for you, left-aligned for them, date separators, quoted replies,
  group sender names and delivery marks (sending, sent, failed).
- Messages you type on your phone show up in the window too.
- Several messages can be typed in a row: they queue and go out in order.
- Start a chat with the **+** button (or `/wa new 34600112233`): a phone number
  with its country code. Incoming messages create their chat by themselves.
- Group messages show the actual sender; replies show who was quoted.
- Whisper-style echo of incoming messages in the WoW chat. Click the name to
  reply from the normal chat box (`/r` works too), or `[open]` for the window.
- Shift-click an item, spell or quest into the message box to link it by name.
- Emoji, stickers, media, locations, contacts, documents and unsupported content
  use safe labels such as `[E]`, `[S]`, `[P]`, `[L]`, `[C]`, `[D]` and `[U]`.
- Collapses to a small bar that shows unread messages; right-click a chat to
  rename it, mark it as read, clear it or delete it.
- QR authentication is stored locally in `.wwebjs_auth/` and is ignored by Git.

## Requirements

- Windows and World of Warcraft: Forever (`_forever_`), windowed or borderless.
- Node.js 22.2 or newer.
- WhatsApp on a phone with permission to link a WhatsApp Web device.

## Install

From this repository:

```powershell
npm install
node setup.js
```

The setup script copies the addon into the detected WoW client (it looks for
`_forever_` first), creates the load-on-demand slot pool and writes the local
ignored configuration. Fully restart WoW after the first installation so it
discovers the slot addons. Enable **WoW WhatsApp** in the AddOns list.

Start the bridge:

```powershell
npm start
```

On first start, scan the QR code shown in the terminal from WhatsApp >
Linked devices. Later starts reuse the local session, and a dropped WhatsApp Web
session is rebuilt by the bridge on its own.

In game, use `/wa` (or `/wow-whatsapp`) to open the window.

## Commands

| Command | Action |
|---|---|
| `/wa` | Open or hide the WhatsApp window |
| `/wa <text>` or `/ai <text>` | Send text to the active chat |
| `/r <text>` | Reply to the last WhatsApp message when WhatsApp was last active |
| `/wa new <phone number>` | Start a chat (country code, digits only) |
| `/wa chat <n, name or number>` | Select a chat |
| `/wa rename [name]` | Rename the selected chat |
| `/wa delete` | Delete the selected chat |
| `/wa clear` | Clear its local history |
| `/wa echo full\|short\|off` | Control incoming messages echoed to WoW chat |
| `/wa mini` / `/wa hide` | Collapse to the small bar / hide everything |
| `/wa reload` | Reload the UI and free consumed slots |
| `/wa diag` | Show transport diagnostics |
| `/wa help` | Show the complete in-game help |

Chats are kept for each WhatsApp conversation; the list holds up to 50 and the
quietest one makes room for a new contact.

## Transport

WoW cannot open sockets or read files. Outbound messages are encoded into a
pixel strip captured by `bridge/capture.ps1`; the bridge sends them and flips an
`ack` signal file when WhatsApp has taken them. Inbound records are written into
load-on-demand `WoWWhatsApp_S###` slot addons and signalled with small WAV files.
When the sound channel is unavailable, the addon polls the incoming slots.
`/reload` and `Inbox.lua` remain as a fallback.

## Configuration and troubleshooting

- [Windows installation](docs/INSTALL-WINDOWS.md)
- [Configuration](docs/CONFIGURATION.md)
- [Architecture](docs/ARCHITECTURE.md)

Local files that must never be committed include `bridge/config.json`,
`bridge/state.json`, `bridge/transcripts.json`, logs and `.wwebjs_auth/`.
They are ignored by `.gitignore`.

This project started as a fork of [chelinho139/wow-ai](https://github.com/chelinho139/wow-ai)
and keeps its transport.
