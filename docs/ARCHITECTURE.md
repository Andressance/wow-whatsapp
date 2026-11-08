# WhatsApp bridge architecture

> **Responsibility notice:** this community project is unaffiliated with
> Blizzard and WhatsApp. The addon/bridge may interact with protections or
> restrictions imposed by those services. Use it at your own risk and review
> their current policies.

The project is a WoW addon client for WhatsApp Web. WhatsApp connectivity lives
outside the game in Node.js; the addon only renders chats and uses the existing
pixel/Lua transport.

```text
WhatsApp Web
    <-> whatsapp-web.js
        <-> bridge/bridge.js
            <-> pixel strip / capture.ps1
            <-> WoWWhatsApp_S###/Inbox.lua + WAV signals
                <-> WoW WhatsApp addon
```

## Incoming messages

`bridge/whatsapp.js` resolves the contact, group title, group sender, mentions,
quoted-message author and media type. The bridge stores only text-safe display
values. Media is not downloaded or exposed to WoW; it becomes a compact label.

Incoming records contain the WhatsApp chat ID, display name, `isGroup`, sender,
optional `replyTo` author and text. The addon keeps these fields in history,
shows the sender for groups and renders quoted-message metadata above the
message.

## Outgoing messages

The addon encodes the active chat ID and text into the pixel strip. The bridge
decodes it and calls `whatsapp-web.js` `sendMessage`. Clicking a green WhatsApp
message in the WoW chat targets that exact chat in the normal WoW mini-chat.

## Persistence and safety

The QR session is stored in `.wwebjs_auth/`. Bridge state, transcripts,
configuration and logs are local ignored files. Do not copy them into commits.
The addon has no socket, process, filesystem or network access.

## Delivery marks

A message sent from the game goes on the pixel strip. The bridge sends it through
WhatsApp Web, then flips `ack/NNN.wav` (and publishes a `sent` record in the
slots) once WhatsApp has taken it; the addon reads that as "sent". A failure
publishes an `error` record with the reason and flips `sig/NNN.wav` instead. Ids
wrap at the slot count, so the bridge keeps the signal files of the next ids
empty, the same way it does for the presence beats, and a valid file left by an
earlier lap can never look like an answer to a new message.

Messages typed while one is still on its way are stored as queued and go out,
one at a time and in order, as each delivery is confirmed. The bridge also sends
one message at a time per process, so order is kept on the WhatsApp side.

## Messages typed on the phone

The bridge listens to `message_create`, not only `message`. What you write on
your phone arrives as an `incoming` record with `fromMe`, and the addon shows it
as your own message without a notification. Messages sent from WoW are
remembered for a minute so they are not mirrored back a second time.
