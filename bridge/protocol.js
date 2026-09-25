'use strict';
// The bridge's pure protocol code: strip records in, Lua slot files out, and the
// small rules around folders, permissions and dedup. No I/O, no config, no
// process state, so tests/bridge_test.js can exercise it directly.

const os = require('os');
const path = require('path');

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
// Folders
// ---------------------------------------------------------------------------

// A chat's folder as typed in game: empty = the default, relative = relative to
// the default, ~ = home. Always absolute and normalized on the way out.
function resolveCwd(raw, base) {
  let p = String(raw || '').trim();
  if (!p) return base;
  if (p === '~' || p.startsWith('~/') || p.startsWith('~\\')) p = path.join(os.homedir(), p.slice(1));
  return path.resolve(base, p);
}

function sameFolder(a, b) {
  return path.resolve(a || '').toLowerCase() === path.resolve(b || '').toLowerCase();
}

// ---------------------------------------------------------------------------
// In: what the game sends
// ---------------------------------------------------------------------------

// Flags field: ';'-separated tokens. "n" = fresh WhatsApp session, "h" = hello
// (no prompt), "d" = the player deleted this chat: forget its transcript and
// session (no prompt), "allow=Rule1,Rule2" = add these permission rules before
// running, "c" = the record carries a game-context field before the text (an
// empty one clears the context the bridge keeps).
function parseFlags(flags) {
  const out = { newSession: false, hello: false, forget: false, context: false, allow: [] };
  for (const tok of String(flags || '').split(';')) {
    if (tok === 'n') out.newSession = true;
    else if (tok === 'h') out.hello = true;
    else if (tok === 'd') out.forget = true;
    else if (tok === 'c') out.context = true;
    else if (tok.startsWith('allow=')) out.allow.push(...tok.slice(6).split(',').map(s => s.trim()).filter(Boolean));
  }
  return out;
}

// Strip payload: records separated by \x1E, fields by \x1F:
//   session, chat, id, cwd, flags, name, [ctx,] text
// `cwd` is left as typed; the bridge resolves it against its default folder.
// The ctx field is only there when the flags say "c" (older addons never set
// it), so a separator inside the text can't be mistaken for it.
function jobsFromStrip(headerId, payload) {
  const jobs = [];
  for (const rec of String(payload).split('\x1E')) {
    const p = rec.split('\x1F');
    if (p.length >= 7 && /^\d+$/.test(p[2])) {
      const flags = parseFlags(p[4]);
      const withCtx = flags.context && p.length >= 8;
      const job = { session: p[0], chat: p[1], id: Number(p[2]), cwd: p[3], ...flags, name: p[5], text: p.slice(withCtx ? 7 : 6).join('\x1F'), via: 'pixel' };
      if (withCtx) job.ctx = p[6];
      jobs.push(job);
    } else if (p.length === 6 && /^\d+$/.test(p[2])) { // previous format without the chat name
      jobs.push({ session: p[0], chat: p[1], id: Number(p[2]), cwd: p[3], ...parseFlags(p[4]), name: '', text: p[5], via: 'pixel' });
    } else if (p.length === 4) { // pre-chat format: session, cwd, flags, text
      jobs.push({ session: p[0], chat: '', id: headerId, cwd: p[1], ...parseFlags(p[2]), text: p[3], via: 'pixel' });
    }
  }
  return jobs;
}

// The reload path: the addon's SavedVariables file holds an `outbox` table with
// hex-encoded text and cwd. Returns null when there is no complete outbox.
function parseOutbox(src) {
  const block = String(src || '').match(/\["outbox"\]\s*=\s*\{([^}]*)\}/);
  if (!block) return null;
  const b = block[1];
  const id = Number((b.match(/\["id"\]\s*=\s*(\d+)/) || [])[1]);
  if (!id) return null;
  const text = fromHex((b.match(/\["text"\]\s*=\s*"([0-9a-fA-F]*)"/) || [])[1]);
  const cwd = fromHex((b.match(/\["cwd"\]\s*=\s*"([0-9a-fA-F]*)"/) || [])[1]);
  const session = (b.match(/\["session"\]\s*=\s*"([0-9a-zA-Z]*)"/) || [])[1] || '';
  const chat = (b.match(/\["chat"\]\s*=\s*"([0-9a-zA-Z]*)"/) || [])[1] || '';
  const newSession = /\["newSession"\]\s*=\s*true/.test(b);
  const job = { id, session, chat, text, cwd, newSession, via: 'reload' };
  const ctx = b.match(/\["ctx"\]\s*=\s*"([0-9a-fA-F]*)"/);
  if (ctx) job.ctx = fromHex(ctx[1]);
  return job;
}

// ---------------------------------------------------------------------------
// Game context
// ---------------------------------------------------------------------------

// What WhatsApp is told about where the message comes from, appended to its
// system prompt on every run while the addon has sent a context (the player's
// character, location and so on; see GameContext in WoWWhatsApp.lua), plus the
// addon/macro primer (docs/WOW-ADDON-PRIMER.md) so it can write for this
// client whatever folder the chat works in. Empty context = nothing appended,
// primer included, so a bridge used for unrelated projects, or an addon with
// `/wow-whatsapp context off`, leaves WhatsApp exactly as it was.
function systemPrompt(ctx, primer) {
  const text = String(ctx || '').trim();
  if (!text) return '';
  const lines = [
    'The user is talking to you from inside World of Warcraft through the wow-whatsapp addon. They type in a small in-game window and your reply is shown there as plain text (markdown is not rendered), so keep replies compact and formatting simple.',
    '',
    'Their in-game situation when the message was written, as reported by the addon:',
    text,
    '',
    'Use this when the request is about the game or the character (questions, macros, addon code, gear advice); ignore it when the task is unrelated. Items, spells or quests the player shift-clicked into a message appear as [Name] in the text, with their tooltip in a "Linked from the game" block at the end of the message.',
  ];
  const ref = String(primer || '').trim();
  if (ref) {
    lines.push('', 'Reference for writing addons and macros for this client. Follow it when the task is about WoW, and check anything it marks as uncertain against the Blizzard UI source it names:', '', ref);
  }
  return lines.join('\n');
}

// ---------------------------------------------------------------------------
// Permissions and progress
// ---------------------------------------------------------------------------

// Turn a permission denial into an allowlist rule the user can accept.
function ruleFor(d) {
  const name = d.tool_name || 'Unknown';
  if (name === 'Bash') {
    const cmd = String((d.tool_input && d.tool_input.command) || '').trim();
    const word = cmd.split(/\s+/)[0];
    if (word && /^[\w.\-]+$/.test(word)) return `Bash(${word}:*)`;
    return 'Bash';
  }
  return name;
}

// One progress line per tool call, as shown in the game's "working" bubble.
function describeToolUse(block) {
  const inp = block.input || {};
  switch (block.name) {
    case 'Bash': return `$ ${String(inp.command || '').split('\n')[0].slice(0, 110)}`;
    case 'Read': return `read ${path.basename(inp.file_path || '')}`;
    case 'Edit': return `edit ${path.basename(inp.file_path || '')}`;
    case 'Write': return `write ${path.basename(inp.file_path || '')}`;
    case 'Grep': return `grep ${inp.pattern || ''}`;
    case 'Glob': return `glob ${inp.pattern || ''}`;
    case 'Agent': return `agent: ${inp.description || ''}`;
    case 'WebSearch': return `search: ${inp.query || ''}`;
    case 'WebFetch': return `fetch ${inp.url || ''}`;
    default: return block.name;
  }
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
// clock and default folder, and (right after a saved-data reset) a restore bundle.
function luaTable(globalName, records, opts = {}) {
  const now = opts.now || Date.now();
  const lines = [
    '-- Written by the wow-whatsapp bridge (bridge/bridge.js). Do not edit by hand.',
    `${globalName} = {`,
    `\tts = ${luaStr(new Date(now).toISOString())},`,
    `\tnow = ${Math.floor(now / 1000)},`,
    `\tcwd = ${luaStr(opts.cwd || '')},`,
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
    lines.push(`\t\t\tcwd = ${luaStr(r.cwd || '')},`);
    lines.push(`\t\t\tsession = ${luaStr(r.session || '')},`);
    if (Array.isArray(r.denied) && r.denied.length) {
      lines.push(`\t\t\tdenied = { ${r.denied.map(luaStr).join(', ')} },`);
    }
    lines.push('\t\t},');
  }
  lines.push('\t},');
  const restore = opts.restore;
  if (restore) {
    lines.push('\trestore = {', `\t\ttoken = ${luaStr(restore.token)},`, '\t\tchats = {');
    for (const c of restore.chats) {
      lines.push('\t\t\t{', `\t\t\t\tid = ${luaStr(c.id)},`, `\t\t\t\tname = ${luaStr(c.name)},`, `\t\t\t\tcwd = ${luaStr(c.cwd)},`, '\t\t\t\tmessages = {');
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
  resolveCwd, sameFolder,
  parseFlags, jobsFromStrip, parseOutbox, systemPrompt,
  ruleFor, describeToolUse,
  luaStr, luaTable, SILENT_WAV,
};
