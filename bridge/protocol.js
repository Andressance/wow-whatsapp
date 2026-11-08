'use strict';
// The bridge's pure protocol code: strip records in, Lua slot files out, and the
// small rules around dedup. No I/O, no config, no process state, so
// tests/bridge_test.js can exercise it directly.

function fromHex(hex) {
  return Buffer.from(hex || '', 'hex').toString('utf8');
}

function pad3(n) { return String(n).padStart(3, '0'); }

// Reply slot / signal file number for a message id (1-based, wraps at `slots`).
function slotNumber(id, slots) { return ((id - 1) % slots) + 1; }

// A chat as the bridge tracks it: the addon's session token plus the chat id.
function chatKey(job) { return `${job.session || ''}:${job.chat || 'default'}`; }
// WhatsApp sessions are keyed by chat id alone, which survives an addon data reset.
function sessKey(job) { return job.chat ? 'chat:' + job.chat : chatKey(job); }

// ---------------------------------------------------------------------------
// Dedup: message ids restart whenever the addon's saved data is reset, so they
// are only unique within the addon's session token.
// ---------------------------------------------------------------------------

function alreadyHandled(state, job) {
  const key = job.session || '';
  const h = state.handled[key];
  if (!h) return key === '' && job.id <= state.lastId;
  return !!h[job.id];
}

function markHandled(state, job, now = Date.now()) {
  const key = job.session || '';
  const h = (state.handled[key] = state.handled[key] || {});
  h[job.id] = 1;
  const ids = Object.keys(h);
  if (ids.length > 1000) for (const k of ids.slice(0, ids.length - 1000)) delete h[k];
  state.lastId = Math.max(state.lastId, job.id);
  (state.seen = state.seen || {})[key] = now;
}

// Every saved-data reset in the game mints a new session token; forget the ones
// not heard from in a month so state.json and transcripts.json stop growing.
const MONTH_MS = 30 * 24 * 3600 * 1000;
function pruneStale(state, transcripts, now = Date.now(), maxAgeMs = MONTH_MS) {
  let removed = 0;
  state.seen = state.seen || {};
  for (const key of Object.keys(state.handled || {})) {
    if (key === '') continue;
    if (!state.seen[key]) { state.seen[key] = now; continue; } // grace period starts now
    if (now - state.seen[key] > maxAgeMs) { delete state.handled[key]; delete state.seen[key]; removed++; }
  }
  for (const key of Object.keys(state.seen)) {
    if (!(state.handled || {})[key] && now - state.seen[key] > maxAgeMs) { delete state.seen[key]; }
  }
  for (const [tok, t] of Object.entries((transcripts && transcripts.tokens) || {})) {
    if (now - t > maxAgeMs) { delete transcripts.tokens[tok]; removed++; }
  }
  return removed;
}

// ---------------------------------------------------------------------------
// In: what the game sends
// ---------------------------------------------------------------------------

// Flags field: ';'-separated tokens. "h" = hello (nothing to send), "d" = the
// player deleted this chat: forget its transcript (nothing to send).
function parseFlags(flags) {
  const out = { hello: false, forget: false };
  for (const tok of String(flags || '').split(';')) {
    if (tok === 'h') out.hello = true;
    else if (tok === 'd') out.forget = true;
  }
  return out;
}

// Strip payload: records separated by \x1E, fields by \x1F:
//   session, chat, id, (unused, kept for the wire format), flags, name, text
// The text is the rest of the record, so it may contain separators.
function jobsFromStrip(payload) {
  const jobs = [];
  for (const rec of String(payload).split('\x1E')) {
    const p = rec.split('\x1F');
    if (p.length >= 7 && /^\d+$/.test(p[2])) {
      jobs.push({ session: p[0], chat: p[1], id: Number(p[2]), ...parseFlags(p[4]), name: p[5], text: p.slice(6).join('\x1F'), via: 'pixel' });
    }
  }
  return jobs;
}

// The reload path: the addon's SavedVariables file holds an `outbox` table with
// the hex-encoded text and chat. Returns null when there is no complete outbox.
function parseOutbox(src) {
  const block = String(src || '').match(/\["outbox"\]\s*=\s*\{([^}]*)\}/);
  if (!block) return null;
  const b = block[1];
  const id = Number((b.match(/\["id"\]\s*=\s*(\d+)/) || [])[1]);
  if (!id) return null;
  const text = fromHex((b.match(/\["text"\]\s*=\s*"([0-9a-fA-F]*)"/) || [])[1]);
  const session = (b.match(/\["session"\]\s*=\s*"([0-9a-zA-Z]*)"/) || [])[1] || '';
  // WhatsApp chat ids contain "@" and ".", so they travel hex-encoded like the text.
  const chat = fromHex((b.match(/\["chat"\]\s*=\s*"([0-9a-fA-F]*)"/) || [])[1]);
  return { id, session, chat, text, via: 'reload' };
}

// ---------------------------------------------------------------------------
// Out: what the game reads
// ---------------------------------------------------------------------------

// Escape for a double-quoted Lua 5.1 string literal.
function luaStr(s) {
  return '"' + String(s ?? '')
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\r/g, '')
    .replace(/\n/g, '\\n')
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, c => '\\' + String(c.charCodeAt(0)).padStart(3, '0'))
    + '"';
}

// The slot file / Inbox.lua body: the latest record of every chat, the bridge's
// clock and (right after a saved-data reset) a restore bundle.
function luaTable(globalName, records, opts = {}) {
  const now = opts.now || Date.now();
  const lines = [
    '-- Written by the wow-whatsapp bridge (bridge/bridge.js). Do not edit by hand.',
    `${globalName} = {`,
    `\tts = ${luaStr(new Date(now).toISOString())},`,
    `\tnow = ${Math.floor(now / 1000)},`,
    '\treplies = {',
  ];
  for (const r of records) {
    lines.push('\t\t{');
    lines.push(`\t\t\tchat = ${luaStr(r.chat || '')},`);
    lines.push(`\t\t\tid = ${Number(r.id) || 0},`);
    lines.push(`\t\t\tstatus = ${luaStr(r.status)},`);
    lines.push(`\t\t\ttext = ${luaStr(r.text)},`);
    lines.push(`\t\t\tname = ${luaStr(r.name || '')},`);
    lines.push(`\t\t\tchatName = ${luaStr(r.chatName || r.name || '')},`);
    lines.push(`\t\t\tisGroup = ${r.isGroup ? 'true' : 'false'},`);
    lines.push(`\t\t\tsender = ${luaStr(r.sender || '')},`);
    lines.push(`\t\t\treplyTo = ${luaStr(r.replyTo || '')},`);
    if (r.fromMe) lines.push('\t\t\tfromMe = true,');
    if (Number(r.timestamp) > 0) lines.push(`\t\t\ttimestamp = ${Math.floor(Number(r.timestamp))},`);
    lines.push('\t\t},');
  }
  lines.push('\t},');
  const restore = opts.restore;
  if (restore) {
    lines.push('\trestore = {', `\t\ttoken = ${luaStr(restore.token)},`, '\t\tchats = {');
    for (const c of restore.chats) {
      lines.push('\t\t\t{', `\t\t\t\tid = ${luaStr(c.id)},`, `\t\t\t\tname = ${luaStr(c.name)},`, '\t\t\t\tmessages = {');
      for (const m of c.messages) {
        lines.push(`\t\t\t\t\t{ role = ${luaStr(m.role)}, id = ${Number(m.id) || 0}, t = ${Number(m.t) || 0}, sender = ${luaStr(m.sender || '')}, replyTo = ${luaStr(m.replyTo || '')}, text = ${luaStr(m.text)} },`);
      }
      lines.push('\t\t\t\t},', '\t\t\t},');
    }
    lines.push('\t\t},', '\t},');
  }
  lines.push('}', '');
  return lines.join('\n');
}

// A valid, silent 10 ms WAV. An empty file "won't play"; this one will.
const SILENT_WAV = (() => {
  const rate = 8000, samples = 80;
  const b = Buffer.alloc(44 + samples);
  b.write('RIFF', 0); b.writeUInt32LE(36 + samples, 4); b.write('WAVE', 8);
  b.write('fmt ', 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate, 28); b.writeUInt16LE(1, 32); b.writeUInt16LE(8, 34);
  b.write('data', 36); b.writeUInt32LE(samples, 40);
  b.fill(128, 44);
  return b;
})();

module.exports = {
  fromHex, pad3, slotNumber, chatKey, sessKey,
  alreadyHandled, markHandled, pruneStale, MONTH_MS,
  parseFlags, jobsFromStrip, parseOutbox,
  luaStr, luaTable, SILENT_WAV,
};
