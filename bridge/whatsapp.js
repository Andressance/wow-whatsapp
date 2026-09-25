'use strict';

const path = require('path');

// WhatsApp Web is deliberately isolated from bridge.js so the transport between
// WoW and the bridge remains unchanged. Authentication is persisted by the
// whatsapp-web.js LocalAuth strategy in `authPath`.

class WhatsAppProvider {
  constructor(config, handlers = {}) {
    this.config = config || {};
    this.handlers = handlers;
    this.client = null;
    this.ready = false;
    this.groupNames = new Map();
  }

  async start() {
    let whatsapp;
    try {
      whatsapp = require('whatsapp-web.js');
    } catch (error) {
      throw new Error('WhatsApp integration requires the whatsapp-web.js package. Run npm install.');
    }
    const { Client, LocalAuth } = whatsapp;
    this.client = new Client({
      authStrategy: new LocalAuth({ dataPath: path.resolve(this.config.authPath || './.wwebjs_auth') }),
      puppeteer: {
        headless: this.config.headless !== false,
        args: ['--no-sandbox', '--disable-setuid-sandbox'],
      },
    });
    this.client.on('qr', qr => this.handlers.qr?.(qr));
    this.client.on('ready', () => {
      this.ready = true;
      this.handlers.ready?.();
    });
    this.client.on('auth_failure', message => this.handlers.error?.(new Error(`WhatsApp authentication failed: ${message}`)));
    this.client.on('disconnected', reason => {
      this.ready = false;
      this.handlers.disconnected?.(reason);
    });
    this.client.on('message', async message => {
      if (message.fromMe) return;
      let chat;
      let sender;
      const groupId = String(message.from || '').endsWith('@g.us');
      try { chat = await message.getChat(); } catch { chat = null; }
      const groupMessage = groupId || chat?.isGroup === true;
      if (groupMessage) {
        try {
          const refreshedChat = await this.client.getChatById(message.from);
          if (refreshedChat) chat = refreshedChat;
        } catch {
          // Keep the chat returned by the message if the metadata refresh fails.
        }
      }
      if (groupMessage && message.author) {
        try {
          const contact = await this.client.getContactById(message.author);
          sender = contact.pushname || contact.name || contact.shortName || contact.number || message.author;
        } catch { sender = message.author; }
      } else if (!groupMessage) {
        try {
          const contact = await message.getContact();
          sender = contact.pushname || contact.name || contact.shortName || contact.number;
        } catch { sender = undefined; }
      }
      const replyTo = await quotedSender(this.client, message);
      const text = await formatIncomingMessage(this.client, message);
      const isGroup = groupMessage;
      const contactName = sender || message._data?.notifyName || message.author || message.from;
      const resolvedGroupName = isGroup && chatNameFrom(chat, message.from);
      if (resolvedGroupName) this.groupNames.set(message.from, resolvedGroupName);
      const chatName = isGroup
        ? (resolvedGroupName || this.groupNames.get(message.from) || message.from)
        : contactName;
      this.handlers.message?.({
        id: message.id?._serialized || `${message.from}-${message.timestamp}`,
        chat: message.from,
        name: chatName,
        chatName,
        isGroup,
        sender,
        replyTo,
        text,
        timestamp: message.timestamp,
      });
    });
    await this.client.initialize();
  }

  async send(chatId, text) {
    if (!this.client || !this.ready) throw new Error('WhatsApp is not connected. Scan the QR code shown by the bridge.');
    if (!chatId) throw new Error('This chat has no WhatsApp recipient id.');
    await this.client.sendMessage(chatId, text);
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
    return name && name !== String(chatId || '') && !name.endsWith('@g.us');
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
