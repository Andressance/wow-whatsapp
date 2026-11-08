'use strict';

const path = require('path');

// WhatsApp Web is deliberately isolated from bridge.js so the transport between
// WoW and the bridge remains unchanged. Authentication is persisted by the
// whatsapp-web.js LocalAuth strategy in `authPath`.

const CHAT_ID = /^[\w.-]+@(c\.us|g\.us|lid)$/;
const SENT_ECHO_MS = 60 * 1000; // how long a message sent from WoW is remembered, to not mirror it back
const READY_WAIT_MS = 90 * 1000; // a message sent while WhatsApp Web is still starting waits this long

class WhatsAppProvider {
  constructor(config, handlers = {}) {
    this.config = config || {};
    this.handlers = handlers;
    this.client = null;
    this.ready = false;
    this.groupNames = new Map();
    this.known = new Set(); // chat ids WhatsApp has confirmed (no registration lookup needed)
    this.sent = new Map(); // "chat|text" -> expiry, for messages we sent ourselves
    this.queue = Promise.resolve(); // sends go out one at a time, in order
    this.readyWaiters = [];
  }

  async start() {
    let whatsapp;
    try {
      whatsapp = require('whatsapp-web.js');
    } catch (error) {
      throw new Error('WhatsApp integration requires the whatsapp-web.js package. Run npm install.');
    }
    const { Client, LocalAuth } = whatsapp;
    const client = this.client = new Client({
      authStrategy: new LocalAuth({ dataPath: path.resolve(this.config.authPath || './.wwebjs_auth') }),
      puppeteer: {
        headless: this.config.headless !== false,
        args: ['--no-sandbox', '--disable-setuid-sandbox'],
      },
    });
    client.on('qr', qr => this.handlers.qr?.(qr));
    client.on('ready', () => {
      this.ready = true;
      for (const resolve of this.readyWaiters.splice(0)) resolve();
      this.handlers.ready?.();
    });
    client.on('auth_failure', message => this.handlers.error?.(new Error(`WhatsApp authentication failed: ${message}`)));
    client.on('disconnected', reason => {
      this.ready = false;
      this.handlers.disconnected?.(reason);
    });
    // message_create also fires for what we send ourselves, from the phone or
    // from WoW; `message` only fires for what others send.
    client.on('message_create', message => this.onMessage(message).catch(error => this.handlers.error?.(error)));
    await client.initialize();
  }

  // Tear the browser down (a dropped session is rebuilt from scratch).
  stop() {
    this.ready = false;
    const client = this.client;
    this.client = null;
    client?.destroy().catch(() => {});
  }

  async onMessage(message) {
    const fromMe = !!message.fromMe;
    const peer = fromMe ? message.to : message.from;
    // Not conversations: status updates, broadcast lists and channels.
    if (message.isStatus || /^status@broadcast$|@broadcast$|@newsletter$/.test(String(peer || ''))) return;
    if (fromMe && this.consumeSent(peer, message.body)) return;
    const client = this.client;
    if (!client) return;

    let chat;
    let sender;
    const groupMessage = String(peer || '').endsWith('@g.us');
    try { chat = await message.getChat(); } catch { chat = null; }
    if (groupMessage) {
      try {
        const refreshedChat = await client.getChatById(peer);
        if (refreshedChat) chat = refreshedChat;
      } catch {
        // Keep the chat returned by the message if the metadata refresh fails.
      }
    }
    if (fromMe) {
      sender = 'You';
    } else if (groupMessage && message.author) {
      try {
        const contact = await client.getContactById(message.author);
        sender = contact.pushname || contact.name || contact.shortName || contact.number || message.author;
      } catch { sender = message.author; }
    } else if (!groupMessage) {
      try {
        const contact = await message.getContact();
        sender = contact.pushname || contact.name || contact.shortName || contact.number;
      } catch { sender = undefined; }
    }
    const replyTo = await quotedSender(client, message);
    const text = await formatIncomingMessage(client, message);
    let chatName;
    if (groupMessage) {
      const resolved = chatNameFrom(chat, peer);
      if (resolved) this.groupNames.set(peer, resolved);
      chatName = resolved || this.groupNames.get(peer) || peer;
    } else {
      // The chat title is the contact, even for what we typed ourselves.
      chatName = chatNameFrom(chat, peer) || (fromMe ? undefined : sender) || message._data?.notifyName || String(peer).split('@')[0];
    }
    this.known.add(peer);
    this.handlers.message?.({
      id: message.id?._serialized || `${peer}-${message.timestamp}`,
      chat: peer,
      name: chatName,
      chatName,
      isGroup: groupMessage,
      sender,
      replyTo,
      text,
      fromMe,
      timestamp: message.timestamp,
    });
  }

  consumeSent(chatId, body) {
    const now = Date.now();
    for (const [key, expires] of this.sent) if (expires < now) this.sent.delete(key);
    return this.sent.delete(`${chatId}|${body}`);
  }

  waitReady() {
    if (this.ready) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.readyWaiters = this.readyWaiters.filter(r => r !== done);
        reject(new Error('WhatsApp is not connected. Scan the QR code shown by the bridge.'));
      }, READY_WAIT_MS);
      const done = () => { clearTimeout(timer); resolve(); };
      this.readyWaiters.push(done);
    });
  }

  send(chatId, text) {
    const job = this.queue.then(() => this.sendNow(chatId, text));
    this.queue = job.catch(() => {}); // one failure must not block the messages behind it
    return job;
  }

  async sendNow(chatId, text) {
    if (!chatId) throw new Error('This chat has no WhatsApp recipient id. Create chats with /wa new <phone number>.');
    if (!CHAT_ID.test(chatId)) throw new Error(`"${chatId}" is not a WhatsApp chat id. Create chats with /wa new <phone number>.`);
    await this.waitReady();
    const client = this.client;
    if (!client) throw new Error('WhatsApp is reconnecting. Try again in a few seconds.');
    let target = chatId;
    if (chatId.endsWith('@c.us') && !this.known.has(chatId)) {
      // A number typed in game: check it is on WhatsApp, and use the id WhatsApp gives it.
      const wid = await client.getNumberId(chatId.split('@')[0]);
      if (!wid) throw new Error(`${chatId.split('@')[0]} is not on WhatsApp.`);
      target = wid._serialized;
    }
    this.sent.set(`${target}|${text}`, Date.now() + SENT_ECHO_MS);
    try {
      await client.sendMessage(target, text);
    } catch (error) {
      this.sent.delete(`${target}|${text}`);
      throw error;
    }
    this.known.add(target);
    // Replying from the game also clears the unread badge on the phone.
    client.getChatById(target).then(chat => chat.sendSeen()).catch(() => {});
  }
}

async function quotedSender(client, message) {
  if (!message?.hasQuotedMsg) return undefined;
  try {
    const quoted = await message.getQuotedMessage();
    if (quoted?.fromMe) return 'You';
    const id = quoted?.author || quoted?.from;
    if (!id) return 'Unknown';
    const contact = await client.getContactById(id);
    return contact.pushname || contact.name || contact.shortName || contact.number || id;
  } catch {
    return 'Unknown';
  }
}

function chatNameFrom(chat, chatId) {
  const candidates = [
    chat?.groupMetadata?.subject,
    chat?._data?.subject,
    chat?._data?.groupMetadata?.subject,
    chat?._data?.groupMetadata?.topic,
    chat?._data?.name,
    chat?._data?.formattedTitle,
    chat?.name,
    chat?.formattedTitle,
    chat?._data?.chat?.name,
    chat?._data?.chat?.formattedTitle,
  ];
  return candidates.find(value => {
    const name = String(value || '').trim();
    return name && name !== String(chatId || '') && !/@(g|c)\.us$|@lid$/.test(name);
  })?.trim();
}

function isEmojiOnly(text) {
  const chars = Array.from(String(text));
  if (!chars.length) return false;
  return chars.every(char => {
    const code = char.codePointAt(0);
    return /\s/u.test(char) || (code >= 0x1f000 && code <= 0x1faff)
      || (code >= 0x2600 && code <= 0x27bf) || code === 0xfe0f || code === 0x200d
      || (code >= 0x1f3fb && code <= 0x1f3ff);
  });
}

async function formatIncomingMessage(client, message) {
  const type = String(message?.type || '').toLowerCase();
  const body = String(message?.body || '');
  const caption = String(message?.caption || '').trim();
  const withCaption = label => caption ? `${label} ${caption}` : label;
  if (type === 'sticker') return '[S]';
  if (type === 'location' || message?.location || message?._data?.lat != null) return '[L]';
  if (type === 'contact' || type === 'vcard' || type === 'contacts_array' || type === 'multi_vcard') return '[C]';
  if (type === 'image' || type === 'photo') return withCaption('[P]');
  if (type === 'video') return withCaption('[V]');
  if (type === 'audio' || type === 'ptt') return '[A]';
  if (type === 'document') return withCaption('[D]');
  if (type === 'poll_creation' || type === 'poll_vote') return '[O]';
  if (type === 'reaction') return '[R]';
  if (type === 'chat' || type === 'text' || !type) {
    return isEmojiOnly(body) ? '[E]' : await replaceMentions(client, message, body);
  }
  return '[U]';
}

WhatsAppProvider.formatIncomingMessage = formatIncomingMessage;

async function replaceMentions(client, message, text) {
  if (!text.includes('@') || !message?.mentionedIds?.length) return text;
  let result = text;
  for (const id of message.mentionedIds) {
    try {
      const contact = await client.getContactById(id);
      const name = contact.pushname || contact.name || contact.shortName || contact.number;
      const number = String(id).split('@')[0];
      if (name) result = result.replace(new RegExp(`@${escapeRegExp(number)}\\b`, 'g'), `@${name}`);
    } catch {}
  }
  return result;
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

module.exports = WhatsAppProvider;
