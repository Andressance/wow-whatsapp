# Install on Windows

> **Use at your own responsibility.** This project is not affiliated with
> Blizzard or WhatsApp and may bypass or interact with protections and
> restrictions of those services. Review their current rules before using it.

## First installation

1. Install Node.js 22.2 or newer.
2. Open PowerShell in this repository.
3. Run:

```powershell
npm install
node setup.js --project "C:\path\to\your\project"
```

4. Fully exit and restart WoW.
5. Enable **WoW WhatsApp** in the AddOns list.
6. Start the bridge:

```powershell
npm start
```

7. Scan the QR code from WhatsApp > Linked devices.
8. In WoW run `/wow-whatsapp`.

## Updating

Pull or copy the new files, run `npm install` if `package.json` changed, then
run `node setup.js` and restart WoW. A normal code-only update can use `/reload`
after the bridge has restarted.

## Troubleshooting

- **Addon incompatible:** check `select(4, GetBuildInfo())` and set
  `tocInterface` in the example config before reinstalling.
- **No messages until reload:** keep the bridge running and ensure the addon
  `incoming` signal folder exists; the addon falls back to polling.
- **QR appears again:** do not delete `.wwebjs_auth/`; it contains the local
  WhatsApp Web session.
- **No group title:** restart the bridge so it refreshes the group metadata with
  `getChatById(groupId)`.
- **Slots exhausted:** run `/wow-whatsapp reload`, or fully restart WoW.
- **Never commit:** `bridge/config.json`, state, transcripts, logs,
  `.wwebjs_auth/` or `.wwebjs_cache/`.
