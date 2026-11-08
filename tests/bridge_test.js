// Unit tests for the bridge's pure protocol code (bridge/protocol.js) and the
// WhatsApp provider (bridge/whatsapp.js) against a fake WhatsApp Web client.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const P = require('../bridge/protocol');
const WhatsAppProvider = require('../bridge/whatsapp');

test('WhatsApp media messages use compact safe display labels', async () => {
  const format = WhatsAppProvider.formatIncomingMessage;
  assert.equal(await format({}, { type: 'location', body: 'encoded location payload' }), '[L]');
  assert.equal(await format({}, { type: 'image', caption: 'vacaciones' }), '[P] vacaciones');
  assert.equal(await format({}, { type: 'contact', body: 'BEGIN:VCARD...' }), '[C]');
  assert.equal(await format({}, { type: 'sticker', body: 'binary data' }), '[S]');
  assert.equal(await format({}, { type: 'chat', body: '😀😀' }), '[E]');
  assert.equal(await format({}, { type: 'unsupported_type', body: 'opaque data' }), '[U]');
});

test('luaStr escapes everything Lua 5.1 needs', () => {
  assert.equal(P.luaStr('a"b\\c\nd\re\x01'), '"a\\"b\\\\c\\nde\\001"');
  assert.equal(P.luaStr(null), '""');
  assert.equal(P.luaStr(42), '"42"');
});

test('parseFlags reads hello and forget', () => {
  const none = { hello: false, forget: false };
  assert.deepEqual(P.parseFlags(''), none);
  assert.deepEqual(P.parseFlags('h'), { ...none, hello: true });
  assert.deepEqual(P.parseFlags('d'), { ...none, forget: true });
  assert.deepEqual(P.parseFlags('n;h;x'), { ...none, hello: true }); // unknown tokens are ignored
});

test('jobsFromStrip parses records, keeps separators inside text, and handles several per frame', () => {
  const rec = ['sess', '34600112233@c.us', '12', '', '', 'My chat', 'hello\x1Fworld'].join('\x1F');
  const jobs = P.jobsFromStrip(rec);
  assert.equal(jobs.length, 1);
  assert.deepEqual(jobs[0], { session: 'sess', chat: '34600112233@c.us', id: 12, hello: false, forget: false, name: 'My chat', text: 'hello\x1Fworld', via: 'pixel' });
  const a = ['s', 'c1@c.us', '3', '', '', 'A', 'first'].join('\x1F');
  const b = ['s', 'c2@g.us', '4', '', 'd', 'B', ''].join('\x1F');
  const hello = ['s', '', '5', '', 'h', '', ''].join('\x1F');
  const many = P.jobsFromStrip([a, b, hello].join('\x1E'));
  assert.deepEqual(many.map(j => [j.id, j.chat, j.text, j.forget, j.hello]), [[3, 'c1@c.us', 'first', false, false], [4, 'c2@g.us', '', true, false], [5, '', '', false, true]]);
  assert.deepEqual(P.jobsFromStrip('garbage'), []);
  assert.deepEqual(P.jobsFromStrip(['s', 'c', 'notanumber', '', '', '', 'x'].join('\x1F')), []);
});

test('parseOutbox decodes the SavedVariables fallback, chat id included', () => {
  const hex = s => Buffer.from(s, 'utf8').toString('hex');
  const src = `WoWWhatsAppDB = {\n["outbox"] = {\n["id"] = 7,\n["session"] = "abc123",\n["chat"] = "${hex('34600112233@c.us')}",\n["text"] = "${hex('héllo')}",\n},\n["settings"] = {},\n}`;
  assert.deepEqual(P.parseOutbox(src), { id: 7, session: 'abc123', chat: '34600112233@c.us', text: 'héllo', via: 'reload' });
  assert.equal(P.parseOutbox('WoWWhatsAppDB = {}'), null);
  assert.equal(P.parseOutbox('["outbox"] = { ["text"] = "" }'), null);
});

test('handled ids are tracked per session token and capped', () => {
  const state = { lastId: 0, handled: {}, sessions: {} };
  const job = { session: 's1', id: 5 };
  assert.equal(P.alreadyHandled(state, job), false);
  P.markHandled(state, job, 1000);
  assert.equal(P.alreadyHandled(state, job), true);
  assert.equal(P.alreadyHandled(state, { session: 's2', id: 5 }), false);
  assert.equal(state.lastId, 5);
  assert.equal(state.seen.s1, 1000);
  for (let i = 1; i <= 1200; i++) P.markHandled(state, { session: 's1', id: i });
  assert.ok(Object.keys(state.handled.s1).length <= 1000);
  // Sessionless (inject / very old addon) jobs fall back to the high-water mark.
  assert.equal(P.alreadyHandled(state, { session: '', id: 3 }), true);
  assert.equal(P.alreadyHandled(state, { session: '', id: 5000 }), false);
});

test('pruneStale forgets session tokens not seen for a month', () => {
  const day = 24 * 3600 * 1000;
  const now = 100 * day;
  const state = { lastId: 0, handled: { old: { 1: 1 }, fresh: { 1: 1 }, unknown: { 1: 1 }, '': { 1: 1 } }, seen: { old: now - 40 * day, fresh: now - day } };
  const transcripts = { chats: {}, tokens: { old: now - 40 * day, fresh: now } };
  const removed = P.pruneStale(state, transcripts, now);
  assert.equal(removed, 2);
  assert.deepEqual(Object.keys(state.handled).sort(), ['', 'fresh', 'unknown']);
  assert.equal(state.seen.unknown, now); // grace period starts when first seen by the pruner
  assert.deepEqual(Object.keys(transcripts.tokens), ['fresh']);
});

test('slotNumber wraps and SILENT_WAV is a valid RIFF header', () => {
  assert.equal(P.slotNumber(1, 200), 1);
  assert.equal(P.slotNumber(200, 200), 200);
  assert.equal(P.slotNumber(201, 200), 1);
  assert.equal(P.SILENT_WAV.toString('ascii', 0, 4), 'RIFF');
  assert.equal(P.SILENT_WAV.readUInt32LE(4), P.SILENT_WAV.length - 8);
  assert.equal(P.chatKey({ session: 's', chat: 'c' }), 's:c');
  assert.equal(P.sessKey({ session: 's', chat: 'c' }), 'chat:c');
  assert.equal(P.sessKey({ session: 's', chat: '' }), 's:default');
});

// ---------------------------------------------------------------------------
// The provider, with a fake WhatsApp Web client
// ---------------------------------------------------------------------------

function fakeClient(opts = {}) {
  const calls = [];
  return {
    calls,
    getNumberId: async number => { calls.push(['getNumberId', number]); return opts.registered === false ? null : { _serialized: number + '@c.us' }; },
    sendMessage: async (id, text) => { calls.push(['send', id, text]); if (opts.delay) await new Promise(r => setTimeout(r, opts.delay(text))); },
    getChatById: async id => ({ sendSeen: async () => calls.push(['seen', id]), name: 'Ana' }),
    getContactById: async id => ({ pushname: 'Ana', number: id.split('@')[0] }),
    destroy: async () => {},
  };
}

function provider(client, handlers = {}) {
  const p = new WhatsAppProvider({}, handlers);
  p.client = client;
  p.ready = true;
  return p;
}

test('send refuses a chat id that is not a WhatsApp id, with a hint', async () => {
  const p = provider(fakeClient());
  await assert.rejects(p.send('abc123', 'hi'), /not a WhatsApp chat id/);
  await assert.rejects(p.send('', 'hi'), /no WhatsApp recipient/);
});

test('send to a typed phone number looks it up once and uses the id WhatsApp gives', async () => {
  const client = fakeClient();
  const p = provider(client);
  await p.send('34600112233@c.us', 'hola');
  await p.send('34600112233@c.us', 'otra vez');
  assert.deepEqual(client.calls.filter(c => c[0] !== 'seen'), [
    ['getNumberId', '34600112233'], ['send', '34600112233@c.us', 'hola'], ['send', '34600112233@c.us', 'otra vez'],
  ]);
  const unknown = provider(fakeClient({ registered: false }));
  await assert.rejects(unknown.send('34000000000@c.us', 'hi'), /is not on WhatsApp/);
});

test('sends go out one at a time, in order, and one failure does not block the next', async () => {
  const client = fakeClient({ delay: text => text === 'slow' ? 40 : 0 });
  const p = provider(client);
  const results = await Promise.allSettled([p.send('1234567@g.us', 'slow'), p.send('bad', 'x'), p.send('1234567@g.us', 'fast')]);
  assert.deepEqual(results.map(r => r.status), ['fulfilled', 'rejected', 'fulfilled']);
  assert.deepEqual(client.calls.filter(c => c[0] === 'send').map(c => c[2]), ['slow', 'fast']);
});

test('messages typed on the phone are mirrored, the ones sent from WoW are not, and status updates are ignored', async () => {
  const client = fakeClient();
  const got = [];
  const p = provider(client, { message: m => got.push(m) });
  const base = { fromMe: true, type: 'chat', timestamp: 1700000000, getChat: async () => ({ name: 'Ana' }) };
  // Sent from WoW: remembered by send(), so its message_create echo is dropped.
  await p.send('34600112233@c.us', 'from wow');
  await p.onMessage({ ...base, to: '34600112233@c.us', body: 'from wow', id: { _serialized: 'a' } });
  // Typed on the phone: shown as ours.
  await p.onMessage({ ...base, to: '34600112233@c.us', body: 'from phone', id: { _serialized: 'b' } });
  // The same text typed again on the phone is not swallowed by the earlier echo.
  await p.onMessage({ ...base, to: '34600112233@c.us', body: 'from wow', id: { _serialized: 'c' } });
  // Status updates and channels are not conversations.
  await p.onMessage({ ...base, fromMe: false, from: 'status@broadcast', body: 'status', id: { _serialized: 'd' } });
  await p.onMessage({ ...base, fromMe: false, from: '1@newsletter', body: 'news', id: { _serialized: 'e' } });
  // A message from a contact.
  await p.onMessage({ type: 'chat', from: '34600112233@c.us', body: 'hello', timestamp: 1700000001, id: { _serialized: 'f' },
    getChat: async () => ({ name: 'Ana' }), getContact: async () => ({ pushname: 'Ana' }) });
  assert.deepEqual(got.map(m => [m.text, m.fromMe, m.chat, m.chatName]), [
    ['from phone', true, '34600112233@c.us', 'Ana'],
    ['from wow', true, '34600112233@c.us', 'Ana'],
    ['hello', false, '34600112233@c.us', 'Ana'],
  ]);
});

test('a message sent while WhatsApp Web is still starting waits for it, then goes out', async () => {
  const client = fakeClient();
  const p = provider(client);
  p.ready = false;
  const sending = p.send('1234567@g.us', 'early');
  await new Promise(r => setTimeout(r, 20));
  assert.equal(client.calls.length, 0);
  p.ready = true;
  for (const resolve of p.readyWaiters.splice(0)) resolve();
  await sending;
  assert.equal(client.calls[0][2], 'early');
});
