# wow-whatsapp

Chat with WhatsApp contacts and groups from inside World of Warcraft: Forever.
Messages travel through the existing WoW addon transport, so the game needs no
network access and no `/reload` for normal messages.

> **Responsibility and compatibility notice:** this is an independent,
> community-made project. It uses a third-party WhatsApp Web client and an
> external addon/bridge integration that may not be permitted by Blizzard or
> WhatsApp terms. Use it only if you accept those risks. You are responsible
> for your account, device, data and any consequences of using it. The authors
> provide no guarantee against warnings, restrictions, suspension, data loss or
> service changes.

## Features

- Individual and group WhatsApp chats in the addon window.
- Group messages show the actual sender.
- Replies show who was quoted (`Reply to You`, or the contact name).
- Click a WhatsApp message in the WoW chat to open that exact conversation.
- Type replies in the normal WoW mini-chat and press Enter to send them.
- Emoji, stickers, media, locations, contacts, documents and unsupported content
  use safe labels such as `[E]`, `[S]`, `[P]`, `[L]`, `[C]`, `[D]` and `[U]`.
- Custom chat names are preserved.
- QR authentication is stored locally in `.wwebjs_auth/` and is ignored by Git.

## Requirements

- Windows and World of Warcraft: Forever, windowed or borderless.
- Node.js 22.2 or newer.
- WhatsApp on a phone with permission to link a WhatsApp Web device.

## Install

From this repository:

```powershell
npm install
node setup.js --project "C:\path\to\your\project"
```

The setup script copies the addon into the detected WoW client, creates the
load-on-demand slot pool and writes the local ignored configuration.
Fully restart WoW after the first installation so it discovers the slot addons.
Enable **WoW WhatsApp** in the AddOns list.

Start the bridge:

```powershell
npm start
```

On first start, scan the QR code shown in the terminal from WhatsApp >
Linked devices. Later starts reuse the local session.

In game, use:

```text
/wow-whatsapp
```

The legacy `/wow-whatsapp` and `/whatsapp` aliases remain available for existing
installations.

## Commands

| Command | Action |
|---|---|
| `/wow-whatsapp` or `/wa` | Open or hide the WhatsApp window |
| `/ai <text>` | Send text to the active WhatsApp chat |
| `/r <text>` | Reply to the last WhatsApp message when WhatsApp was last active |
| `/wow-whatsapp new [name]` | Create a chat |
| `/wow-whatsapp chat <name or number>` | Select a chat |
| `/wow-whatsapp rename [name]` | Rename the selected chat |
| `/wow-whatsapp delete` | Delete the selected chat |
| `/wow-whatsapp clear` | Clear its local history |
| `/wow-whatsapp echo full\|short\|off` | Control messages echoed to WoW chat |
| `/wow-whatsapp reload` | Reload the UI and free consumed slots |
| `/wow-whatsapp diag` | Show transport diagnostics |
| `/wow-whatsapp help` | Show the complete in-game help |

Right-click a chat for **Rename**, **Folder** and delete actions. Clicking the
green WhatsApp message header in the WoW chat activates the normal WoW mini-chat
for that contact or group; `[open]` opens the full addon conversation.

## Transport

WoW cannot open sockets or read files. Outbound messages are encoded into a
pixel strip captured by `bridge/capture.ps1`. Inbound records are written into
load-on-demand `WoWWhatsApp_S###` slot addons and signalled with small WAV files.
When the sound channel is unavailable, the addon polls the incoming slots.
`/reload` and `Inbox.lua` remain as a fallback.

## Configuration and troubleshooting

- [Windows installation](docs/INSTALL-WINDOWS.md)
- [Configuration](docs/CONFIGURATION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [WoW addon reference](docs/WOW-ADDON-PRIMER.md)

Local files that must never be committed include `bridge/config.json`,
`bridge/state.json`, `bridge/transcripts.json`, logs and `.wwebjs_auth/`.
They are ignored by `.gitignore`.
