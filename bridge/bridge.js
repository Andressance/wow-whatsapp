#!/usr/bin/env node
'use strict';
// WoW WhatsApp bridge: the half of WoWWhatsApp that lives outside the game.
//
//   OUT  capture.ps1 screen-captures the addon's pixel strip -> one or more
//        {session, chat, id, flags, text} records per frame
//        (fallback: the game's SavedVariables file, written on /reload);
//        each one is sent through WhatsApp Web (whatsapp.js).
//   IN   WhatsApp messages become records that we write into every
//        WoWWhatsApp_S### slot addon (the game loads a fresh one from a timer),
//        flip a signal .wav per message, and also write Inbox.lua for the
//        reload path.
//
// Run with npm start or `node bridge.js`.
//   --once            handle one pending SavedVariables message and exit
//   --inject "text"   pretend the strip said this and exit when done

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { spawn } = require('child_process');
const P = require('./protocol'); // the pure protocol code, unit-tested in tests/bridge_test.js
const WhatsAppProvider = require('./whatsapp');

const HERE = __dirname;
const CONFIG_FILE = path.join(HERE, 'config.json');
const STATE_FILE = path.join(HERE, 'state.json');
const LOG_FILE = path.join(HERE, 'bridge.log');

const argv = process.argv.slice(2);
if (argv.includes('--help') || argv.includes('-h')) {
  console.log('wow-whatsapp [--once] [--inject "text"]\n\nRuns the WoW WhatsApp bridge (see bridge/config.json).');
  process.exit(0);
}
let cfg;
try { cfg = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')); }
catch (e) {
  console.error(`Cannot read ${CONFIG_FILE} (${e.message}).\nRun "node setup.js" in the wow-whatsapp folder first.`);
  process.exit(2); // the supervisor doesn't restart on 2
}
const once = argv.includes('--once');
const injectIdx = argv.indexOf('--inject');
const inject = injectIdx >= 0 ? argv[injectIdx + 1] : null;
const exitWhenIdle = once || inject !== null;

const REPO = path.dirname(HERE);
// The client folder (_forever_, ...) the addon is installed in: tells the screen
// capture which game window is ours when several Wow.exe run.
const CLIENT_DIR = path.dirname(path.dirname(cfg.addonDir || ''));

const SLOTS = cfg.slots || 200;
const cap = Object.assign({ enabled: true, processName: 'Wow', cellPx: 4, cellsPerRow: 200, maxRows: 48, intervalMs: 250 }, cfg.capture || {});
const whatsappConfig = Object.assign({ enabled: true, headless: true }, cfg.whatsapp || {});
// Relative to the repo, not to wherever the bridge was started: a different folder would mean a new QR scan.
whatsappConfig.authPath = path.resolve(REPO, whatsappConfig.authPath || '.wwebjs_auth');
let whatsapp = null;
const whatsappPending = new Set();

let state = readJson(STATE_FILE, { lastId: 0, sessions: {}, handled: {} });
if (!state.handled) state.handled = {};
if (!state.sessions) state.sessions = {};
// Older versions stored handled[session] as "highest id so far"; expand to a map.
for (const [k, v] of Object.entries(state.handled)) {
  if (typeof v === 'number') {
    const m = {};
    for (let i = 1; i <= v; i++) m[i] = 1;
    state.handled[k] = m;
  }
}

// Bridge-side transcripts. The beta client sometimes wipes addon saved data; since
// every prompt and reply passes through here, this copy lets the addon recover.
const TRANSCRIPT_FILE = path.join(HERE, 'transcripts.json');
let transcripts = readJson(TRANSCRIPT_FILE, { chats: {}, tokens: {} });
if (!transcripts.chats) transcripts.chats = {};
if (!transcripts.tokens) transcripts.tokens = {};
if (P.pruneStale(state, transcripts)) { saveState(); saveTranscripts(); }
let pendingRestore = null;

function saveTranscripts() {
  try { atomicWrite(TRANSCRIPT_FILE, JSON.stringify(transcripts)); } catch (e) { log('could not save transcripts:', e.message); }
}

// Chats the player deleted in game while a run for them was still going: the
// run's late progress and reply must not recreate the transcript.
const forgotten = new Set();

function noteMessage(job, role, text) {
  if (!job.chat) return;
  if (role === 'user') forgotten.delete(job.chat);
  else if (forgotten.has(job.chat)) return;
  const c = transcripts.chats[job.chat] = transcripts.chats[job.chat] || { id: job.chat, name: '', messages: [] };
  if (job.chatName || job.name) c.name = job.chatName || job.name;
  c.messages.push({
    role,
    text: String(text ?? '').slice(0, 4000),
    id: job.id,
    t: Math.floor(Date.now() / 1000),
    ...(job.sender ? { sender: String(job.sender).slice(0, 120) } : {}),
    ...(job.replyTo ? { replyTo: String(job.replyTo).slice(0, 120) } : {}),
  });
  while (c.messages.length > 200) c.messages.shift();
  c.updated = Date.now();
  saveTranscripts();
}

// First message from an addon session token we haven't seen: its saved data is
// fresh (or reset), so offer everything we know once, in the next publish.
function maybeOfferRestore(job) {
  if (!job.session || transcripts.tokens[job.session]) return;
  transcripts.tokens[job.session] = Date.now();
  const chats = Object.values(transcripts.chats)
    .filter(c => c.id !== job.chat && c.messages.length)
    .sort((a, b) => (b.updated || 0) - (a.updated || 0))
    .slice(0, 16)
    .map(c => ({ id: c.id, name: c.name, messages: c.messages.slice(-40).map(m => ({ ...m, text: m.text.slice(0, 2000) })) }));
  saveTranscripts();
  if (chats.length) {
    pendingRestore = { token: job.session, chats };
    log(`new addon session ${job.session}: offering ${chats.length} chat(s) to restore`);
  }
}

// The player deleted a chat in game. Drop everything we keep for it, so the next
// restore doesn't bring it back and its id can't resume the old WhatsApp session.
function forgetChat(job) {
  if (!job.chat) return;
  const had = !!transcripts.chats[job.chat];
  delete transcripts.chats[job.chat];
  forgotten.add(job.chat);
  delete state.sessions[sessKey(job)];
  delete state.sessions[chatKey(job)];
  if (state.sessionCwd) delete state.sessionCwd[sessKey(job)];
  if (pendingRestore) pendingRestore.chats = pendingRestore.chats.filter(c => c.id !== job.chat);
  saveTranscripts();
  log(`#${job.id}${job.session ? '@' + job.session : ''} forgot chat ${job.chat}${had ? '' : ' (nothing stored)'}`);
}

let lastMtime = 0;
const live = new Map();    // chatKey -> latest record shown to the game
let lastPublish = 0;
let publishTimer = null;

// ---------------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------------

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function saveState() {
  atomicWrite(STATE_FILE, JSON.stringify(state, null, 2));
}

function log(...parts) {
  const line = `[${new Date().toISOString()}] ${parts.join(' ')}`;
  console.log(line);
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch {}
}

const { pad3, chatKey, sessKey, luaStr, SILENT_WAV, jobsFromStrip } = P;
const slotNumber = id => P.slotNumber(id, SLOTS);
const alreadyHandled = job => P.alreadyHandled(state, job);
const markHandled = job => P.markHandled(state, job);

function atomicWrite(file, content) {
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, content);
  fs.renameSync(tmp, file);
}

// ---------------------------------------------------------------------------
// What the game reads
// ---------------------------------------------------------------------------

// Slot file / Inbox.lua body: see protocol.luaTable.
function slotFile(globalName, records) {
  return P.luaTable(globalName, records, { restore: pendingRestore });
}

function addonInstalled() {
  return fs.existsSync(path.join(cfg.addonDir, 'WoWWhatsApp', 'WoWWhatsApp.toc'));
}

function slotsInstalled() {
  return fs.existsSync(path.join(cfg.addonDir, 'WoWWhatsApp_S001', 'Inbox.lua'));
}

// The game will load *some* unused slot next, so every slot gets the full picture.
// A missing addon folder (not installed yet, or the game folder moved) must not
// take the bridge down: capture and WhatsApp runs keep working, and the game just
// won't see replies until `node setup.js` has run and WoW was restarted.
let warnedNoAddon = false;
function publishNow() {
  lastPublish = Date.now();
  const records = [...live.values()].slice(-100);
  try {
    atomicWrite(cfg.inboxFile, slotFile('WoWWhatsApp_Inbox', records));
  } catch (e) {
    if (!warnedNoAddon) {
      warnedNoAddon = true;
      log(`publish: cannot write ${cfg.inboxFile} (${e.code || e.message}); addon not installed? run: node setup.js, then restart WoW`);
    }
    return;
  }
  if (!slotsInstalled()) return;
  const body = slotFile('WoWWhatsApp_SlotData', records);
  for (let i = 1; i <= SLOTS; i++) {
    try { atomicWrite(path.join(cfg.addonDir, 'WoWWhatsApp_S' + pad3(i), 'Inbox.lua'), body); } catch {}
  }
  // The restore bundle is large; it rides along once and is then dropped.
  // (The game keeps loading fresh slots until it has read one carrying it.)
  if (pendingRestore) { pendingRestore.published = (pendingRestore.published || 0) + 1; if (pendingRestore.published >= 3) pendingRestore = null; }
}

// Final results publish immediately; progress is throttled. `key` is the chat
// (record.session is WhatsApp's session id, a different thing).
function publish(key, record, urgent) {
  live.delete(key); // re-insert so Map order stays oldest-first
  live.set(key, record);
  while (live.size > 100) live.delete(live.keys().next().value); // publishNow ships the last 100 only
  if (urgent) { if (publishTimer) { clearTimeout(publishTimer); publishTimer = null; } publishNow(); return; }
  const wait = (cfg.progressWriteMs || 3000) - (Date.now() - lastPublish);
  if (wait <= 0) publishNow();
  else if (!publishTimer) publishTimer = setTimeout(() => { publishTimer = null; publishNow(); }, wait);
}

// ack/NNN.wav = the bridge has the message with that id (and has sent it), sig/NNN.wav =
// "read a slot now". The game polls them for free. Slot numbers wrap, so a file left
// valid by an earlier lap would look like an answer to a new message: the next ids
// are kept empty, the same way the presence beats are.
function signal(kind, id, on) {
  const dir = path.join(cfg.addonDir, "WoWWhatsApp", kind);
  const write = (n, valid) => { try { atomicWrite(path.join(dir, pad3(n) + ".wav"), valid ? SILENT_WAV : Buffer.alloc(0)); } catch {} };
  write(slotNumber(id), on);
  for (let j = 1; j <= Math.min(30, SLOTS - 1); j++) write(slotNumber(id + j), false);
}

// Presence: every 30 s flip the next presence/NNNN.wav valid so the game can tell
// the bridge is alive without spending a slot. The counter persists across
// restarts so a filename is never reused while the game is still running; the
// files just ahead of the counter are kept empty so the game can't run ahead.
const PRESENCE_MAX = cfg.presenceMax || 2000;
const INCOMING_MAX = cfg.incomingMax || 2000;
function presenceFile(k) {
  return path.join(cfg.addonDir, 'WoWWhatsApp', 'presence', String(k).padStart(4, '0') + '.wav');
}
function presenceBeat() {
  if (!fs.existsSync(path.join(cfg.addonDir, 'WoWWhatsApp', 'presence'))) return;
  state.presence = ((state.presence || 0) % PRESENCE_MAX) + 1;
  const k = state.presence;
  try { atomicWrite(presenceFile(k), SILENT_WAV); } catch {}
  for (let j = 1; j <= 50; j++) {
    const n = ((k - 1 + j) % PRESENCE_MAX) + 1;
    try { atomicWrite(presenceFile(n), Buffer.alloc(0)); } catch {}
  }

  saveState();
}

function incomingBeat() {
  if (!fs.existsSync(path.join(cfg.addonDir, 'WoWWhatsApp', 'incoming'))) return;
  state.incoming = ((state.incoming || 0) % INCOMING_MAX) + 1;
  const k = state.incoming;
  try { atomicWrite(path.join(cfg.addonDir, 'WoWWhatsApp', 'incoming', String(k).padStart(4, '0') + '.wav'), SILENT_WAV); } catch {}
  for (let j = 1; j <= 50; j++) {
    const n = ((k - 1 + j) % INCOMING_MAX) + 1;
    try { atomicWrite(path.join(cfg.addonDir, 'WoWWhatsApp', 'incoming', String(n).padStart(4, '0') + '.wav'), Buffer.alloc(0)); } catch {}
  }
  saveState();
}

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

// The reload path: the addon writes its outbox into SavedVariables on /reload.
function readOutbox() {
  let src;
  try { src = fs.readFileSync(cfg.savedVariablesFile, 'utf8'); } catch { return null; }
  return P.parseOutbox(src);
}

// ---------------------------------------------------------------------------
// WhatsApp
// ---------------------------------------------------------------------------

// Set once a message has been handed to WhatsApp (or has failed): --once and
// --inject exit when nothing is in flight any more.
let exitCode = 0;
function maybeExit() {
  if (exitWhenIdle && whatsappPending.size === 0) process.exit(exitCode);
}

function sendWhatsApp(job) {
  if (!whatsappConfig.enabled) {
    finish(job, 'error', 'WhatsApp integration is disabled. Enable whatsapp.enabled in bridge/config.json.');
    maybeExit();
    return;
  }
  if (!whatsapp) {
    finish(job, 'error', 'WhatsApp is not initialized.');
    maybeExit();
    return;
  }
  if (whatsappPending.has(job.id)) return;
  whatsappPending.add(job.id);
  noteMessage(job, 'user', job.text);
  whatsapp.send(job.chat, job.text).then(() => {
    markHandled(job);
    saveState();
    signal('ack', job.id, true);
    publish(chatKey(job), { chat: job.chat, id: job.id, status: 'sent', text: '', name: job.name || job.chat }, true);
    log(`#${job.id}${job.session ? '@' + job.session : ''} sent WhatsApp message to ${job.chat}`);
  }).catch(error => {
    finish(job, 'error', error.message);
  }).finally(() => {
    whatsappPending.delete(job.id);
    maybeExit();
  });
}

function submit(job) {
  if (alreadyHandled(job)) return;
  if (job.forget) {
    // A deleted chat: forget it and ack. Nothing is sent.
    markHandled(job);
    forgetChat(job);
    saveState();
    signal('ack', job.id, true);
    return;
  }
  if (job.hello) {
    // The addon announcing itself: ack, offer a restore if its data is fresh,
    // and refresh the slots so it can read our clock. Nothing is sent.
    markHandled(job);
    saveState();
    signal('ack', job.id, true);
    maybeOfferRestore(job);
    publishNow();
    log(`hello from session ${job.session}${pendingRestore ? ' (restore offered)' : ''}`);
    return;
  }
  sendWhatsApp(job);
}

function receiveWhatsApp(message) {
  if (!message.text.trim()) return;
  const id = state.lastId + 1;
  const job = {
    id,
    session: '',
    chat: message.chat,
    name: message.name,
    chatName: message.chatName || message.name,
    isGroup: message.isGroup,
    text: message.text,
    sender: message.sender,
    replyTo: message.replyTo,
    via: 'whatsapp',
  };
  state.lastId = id;
  // A message typed on the phone is shown as ours, like in WhatsApp Web.
  noteMessage(job, message.fromMe ? 'user' : 'contact', message.text);
  // Incoming messages need distinct live keys. Using only the chat id would
  // replace a previous message when several arrive before WoW polls a slot.
  publish(`${chatKey(job)}:incoming:${id}`, {
    chat: message.chat,
    id,
    status: 'incoming',
    fromMe: message.fromMe ? true : undefined,
    text: message.text,
    name: message.name,
    chatName: message.chatName || message.name,
    isGroup: message.isGroup,
    sender: message.sender,
    replyTo: message.replyTo,
    timestamp: message.timestamp,
  }, true);
  incomingBeat();
  log(`WhatsApp message ${message.fromMe ? 'to' : 'from'} ${message.name} (${message.chat})`);
}

let restartTimer = null;
function startWhatsApp() {
  if (!whatsappConfig.enabled) return;
  restartTimer = null;
  const provider = whatsapp = new WhatsAppProvider(whatsappConfig, {
    qr: qr => {
      log('WhatsApp QR received. Scan it from WhatsApp > Linked devices.');
      try {
        require('qrcode-terminal').generate(qr, { small: true });
      } catch (error) {
        log('Could not render WhatsApp QR:', error.message);
      }
    },
    ready: () => log('WhatsApp connected and ready'),
    error: error => log('WhatsApp error:', error.message),
    disconnected: reason => {
      log('WhatsApp disconnected:', String(reason));
      restartWhatsApp(provider);
    },
    message: receiveWhatsApp,
  });
  provider.start().catch(error => {
    log('WhatsApp startup failed:', error.message);
    restartWhatsApp(provider);
  });
}

// A dropped WhatsApp Web session is rebuilt from scratch (the saved login is reused).
function restartWhatsApp(provider) {
  if (exitWhenIdle || restartTimer || provider !== whatsapp) return;
  provider.stop();
  restartTimer = setTimeout(startWhatsApp, 10000);
}

function finish(job, status, text) {
  if (job.finished) return;
  job.finished = true;
  markHandled(job);
  saveState();
  noteMessage(job, 'system', 'Bridge error: ' + text);
  publish(chatKey(job), { chat: job.chat, id: job.id, status, text }, true);
  signal('sig', job.id, true);
  log(`#${job.id}${job.session ? '@' + job.session : ''} ${status}: ${text}`);
  exitCode = 1;
}

// ---------------------------------------------------------------------------
// Input loops
// ---------------------------------------------------------------------------

function pollSavedVariables() {
  let st;
  try { st = fs.statSync(cfg.savedVariablesFile); } catch { return; }
  if (st.mtimeMs === lastMtime) return;
  lastMtime = st.mtimeMs;
  const job = readOutbox();
  if (job) submit(job);
}

function startCapture() {
  const script = path.join(HERE, 'capture.ps1');
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script,
    '-Cell', String(cap.cellPx), '-Cells', String(cap.cellsPerRow), '-MaxRows', String(cap.maxRows),
    '-IntervalMs', String(cap.intervalMs), '-ProcessName', cap.processName, '-ClientFolder', path.basename(CLIENT_DIR)];
  const ps = spawn('powershell.exe', args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  const rl = readline.createInterface({ input: ps.stdout });
  rl.on('line', (line) => {
    let ev;
    try { ev = JSON.parse(line); } catch { return; }
    if (ev.info) { log('capture:', ev.info); return; }
    if (ev.warn) { log('capture:', ev.warn); return; }
    if (ev.error) { log('capture error:', ev.error); return; }
    if (typeof ev.id === 'number') {
      const jobs = jobsFromStrip(ev.text);
      log(`strip #${ev.id}: ${jobs.length} message(s)`);
      for (const job of jobs) submit(job);
    }
  });
  ps.stderr.on('data', (d) => log('capture stderr:', String(d).trim().slice(0, 300)));
  ps.on('close', (code) => {
    log(`capture exited (${code}); restarting in 5 s`);
    setTimeout(startCapture, 5000);
  });
}

function banner() {
  console.log('WoW WhatsApp bridge');
  console.log(`  addons   : ${cfg.addonDir}`);
  if (path.basename(CLIENT_DIR) === '_classic_beta_' && fs.existsSync(path.join(path.dirname(CLIENT_DIR), '_forever_'))) {
    console.log('  WARNING  : this config is on the beta client, but _forever_ is installed - run: node setup.js, then restart WoW');
  }
  console.log(`  addon    : ${addonInstalled() ? 'installed' : 'NOT INSTALLED - run: node setup.js, then restart WoW'}`);
  console.log(`  slots    : ${slotsInstalled() ? SLOTS + ' installed' : 'NOT INSTALLED - run: node setup.js (or node bridge/install-slots.js), then restart WoW'}`);
  console.log(`  capture  : ${cap.enabled ? 'on (' + cap.processName + ', ' + cap.cellsPerRow + 'x' + cap.maxRows + ' cells of ' + cap.cellPx + 'px)' : 'off'}`);
  console.log(`  whatsapp : ${whatsappConfig.enabled ? 'on (scan the QR code shown below the first time)' : 'off'}`);
  console.log(`  fallback : ${cfg.savedVariablesFile || 'none yet (the game creates the account folder at your first login)'}`);
  console.log('Leave this window open while you play. Ctrl+C to stop.\n');
}

banner();
if (inject !== null) {
  // A smoke test without the game: WHATSAPP_INJECT_CHAT=<number>@c.us node bridge.js --inject "text"
  startWhatsApp();
  submit({ id: state.lastId + 1, session: '', chat: process.env.WHATSAPP_INJECT_CHAT || '', text: inject, via: 'inject' });
} else {
  startWhatsApp();
  pollSavedVariables();
  if (once) {
    setTimeout(() => { if (whatsappPending.size === 0) { console.log('nothing pending'); process.exit(0); } }, 2000);
  } else {
    setInterval(pollSavedVariables, cfg.pollMs || 750);
    presenceBeat();
    setInterval(presenceBeat, cfg.presenceIntervalMs || 30000);
    if (cap.enabled) startCapture();
  }
}
