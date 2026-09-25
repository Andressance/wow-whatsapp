#!/usr/bin/env node
'use strict';
// WoW WhatsApp bridge: the half of WoWWhatsApp that lives outside the game.
//
//   OUT  capture.ps1 screen-captures the addon's pixel strip -> one or more
//        {session, chat, id, cwd, flags, text} records per frame
//        (fallback: the game's SavedVariables file, written on /reload)
//   RUN  `whatsapp -p` headless in the chat's folder, streaming progress.
//        Each chat is its own WhatsApp session; up to maxParallel run at once.
//   IN   we write the latest reply/status of every chat into every
//        WoWWhatsApp_S### slot addon (the game loads a fresh one from a timer),
//        flip a signal .wav per message, and also write Inbox.lua for the
//        reload path.
//
// Zero npm dependencies. Run with npm start or `node bridge.js`.
//   --once            handle one pending SavedVariables prompt and exit
//   --inject "text"   pretend the strip said this and exit when done
//   --project <dir>   default folder for chats that haven't picked one
//
// Like `whatsapp` itself, the bridge works in the folder it was started from:
// `cd my-project && wow-whatsapp` makes my-project the default for every chat
// that hasn't chosen its own with /wow-whatsapp cd. Started from inside this repo (npm
// start), it falls back to defaultCwd in config.json.

const fs = require('fs');
const os = require('os');
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
  console.log('wow-whatsapp [--project <dir>] [--once] [--inject "text"]\n\n' +
    'Runs the WoW WhatsApp bridge. Chats without a folder of their own work in <dir>,\n' +
    'or in the folder you started it from, or in defaultCwd from bridge/config.json.');
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

// Default folder: --project, else the folder we were started from (unless that is
// this repo, i.e. npm start), else the configured one.
const REPO = path.dirname(HERE);
function insideRepo(dir) {
  const rel = path.relative(REPO, dir);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}
const projectIdx = argv.indexOf('--project');
const DEFAULT_CWD = path.resolve(
  projectIdx >= 0 && argv[projectIdx + 1] ? argv[projectIdx + 1]
    : process.env.WOW_WHATSAPP_PROJECT ? process.env.WOW_WHATSAPP_PROJECT
    : !insideRepo(process.cwd()) ? process.cwd()
    : cfg.defaultCwd || process.cwd());
const DEFAULT_CWD_SOURCE = projectIdx >= 0 ? '--project' : process.env.WOW_WHATSAPP_PROJECT ? 'WOW_WHATSAPP_PROJECT'
  : !insideRepo(process.cwd()) ? 'started here' : 'config.json';

const resolveCwd = raw => P.resolveCwd(raw, DEFAULT_CWD);
const { sameFolder } = P;
// Subfolders of the default folder, for the "folder not found" hint.
function siblingFolders() {
  try {
    return fs.readdirSync(DEFAULT_CWD, { withFileTypes: true })
      .filter(d => d.isDirectory() && !d.name.startsWith('.') && d.name !== 'node_modules')
      .map(d => d.name).sort().slice(0, 30);
  } catch { return []; }
}

const SLOTS = cfg.slots || 200;
const MAX_PARALLEL = cfg.maxParallel || 3;
const cap = Object.assign({ enabled: true, processName: 'WowB', cellPx: 4, cellsPerRow: 200, maxRows: 48, intervalMs: 250 }, cfg.capture || {});
const whatsappConfig = Object.assign({ enabled: true, authPath: path.join(HERE, '.wwebjs_auth'), headless: true }, cfg.whatsapp || {});
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
  try { fs.writeFileSync(TRANSCRIPT_FILE, JSON.stringify(transcripts)); } catch (e) { log('could not save transcripts:', e.message); }
}

// Chats the player deleted in game while a run for them was still going: the
// run's late progress and reply must not recreate the transcript.
const forgotten = new Set();

function noteMessage(job, role, text) {
  if (!job.chat) return;
  if (role === 'user') forgotten.delete(job.chat);
  else if (forgotten.has(job.chat)) return;
  const c = transcripts.chats[job.chat] = transcripts.chats[job.chat] || { id: job.chat, name: '', cwd: job.cwd, messages: [] };
  if (job.chatName || job.name) c.name = job.chatName || job.name;
  if (job.cwd) c.cwd = job.cwd;
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
    .map(c => ({ id: c.id, name: c.name, cwd: c.cwd, messages: c.messages.slice(-40).map(m => ({ ...m, text: m.text.slice(0, 2000) })) }));
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
const running = new Map(); // chatKey -> { job, child }
const queued = new Map();  // chatKey -> job waiting for that chat (or for a free parallel slot)
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
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

function log(...parts) {
  const line = `[${new Date().toISOString()}] ${parts.join(' ')}`;
  console.log(line);
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch {}
}

const { pad3, chatKey, sessKey, luaStr, SILENT_WAV, jobsFromStrip, ruleFor, describeToolUse } = P;
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
  return P.luaTable(globalName, records, { cwd: DEFAULT_CWD, restore: pendingRestore });
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
  live.set(key, record);
  if (urgent) { if (publishTimer) { clearTimeout(publishTimer); publishTimer = null; } publishNow(); return; }
  const wait = (cfg.progressWriteMs || 3000) - (Date.now() - lastPublish);
  if (wait <= 0) publishNow();
  else if (!publishTimer) publishTimer = setTimeout(() => { publishTimer = null; publishNow(); }, wait);
}

function signal(kind, id, on) {
  const file = path.join(cfg.addonDir, 'WoWWhatsApp', kind, pad3(slotNumber(id)) + '.wav');
  try { atomicWrite(file, on ? SILENT_WAV : Buffer.alloc(0)); } catch {}
}

// Heartbeat: act/NNN/kk.wav flips valid for the k-th action of message NNN. The
// game polls the next one for free, so it can show "12 actions, last one 5 s ago"
// without spending a reply slot.
const ACT_MAX = cfg.actMax || 60;
function actFile(id, k) {
  return path.join(cfg.addonDir, 'WoWWhatsApp', 'act', pad3(slotNumber(id)), String(k).padStart(2, '0') + '.wav');
}
function resetBeats(id) {
  for (let k = 1; k <= ACT_MAX; k++) { try { atomicWrite(actFile(id, k), Buffer.alloc(0)); } catch {} }
}
function beat(job) {
  job.beats = (job.beats || 0) + 1;
  if (job.beats > ACT_MAX) return;
  try { atomicWrite(actFile(job.id, job.beats), SILENT_WAV); } catch {}
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

// The addon sends the player's in-game context (character, location, ...) with
// its hello and again whenever it changes; an empty one means "context off".
// It is kept in state.json so a restarted bridge still has it, and goes into
// WhatsApp's system prompt on every run (see protocol.systemPrompt).
function setContext(job) {
  const text = String(job.ctx || '').replace(/\r/g, '').trim().slice(0, 2000);
  const prev = (state.context && state.context.text) || '';
  if (text === prev) return;
  state.context = text ? { text, at: Date.now(), session: job.session || '' } : null;
  saveState();
  const who = (text.split('\n').find(l => /^Character:/i.test(l)) || text.split('\n')[0] || '').slice(0, 100);
  log(`#${job.id}${job.session ? '@' + job.session : ''} game context ${text ? 'updated: ' + who : 'cleared'}`);
}

function gameContext() {
  if (cfg.gameContext === false) return '';
  return (state.context && state.context.text) || '';
}

// The addon/macro primer that goes into the system prompt with the context.
// Read on every run so edits count without a restart; "" in the config turns
// it off. Relative paths are taken from the repo (docs/WOW-ADDON-PRIMER.md).
const PRIMER_FILE = cfg.primerFile === undefined ? 'docs/WOW-ADDON-PRIMER.md' : cfg.primerFile;
let warnedNoPrimer = false;
function primer() {
  if (!PRIMER_FILE) return '';
  const file = path.resolve(REPO, PRIMER_FILE);
  try { return fs.readFileSync(file, 'utf8'); } catch (e) {
    if (!warnedNoPrimer) { warnedNoPrimer = true; log(`primer: cannot read ${file} (${e.code || e.message}); running without it`); }
    return '';
  }
}

// Persist newly allowed rules so they stick across bridge restarts.
function allowRules(rules) {
  const current = new Set(cfg.allowedTools || []);
  const added = rules.filter(r => r && !current.has(r));
  if (!added.length) return [];
  cfg.allowedTools = [...current, ...added];
  try {
    const onDisk = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
    onDisk.allowedTools = cfg.allowedTools;
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(onDisk, null, 2) + '\n');
  } catch (e) { log('could not save config.json:', e.message); }
  return added;
}

// ---------------------------------------------------------------------------
// Running WhatsApp
// ---------------------------------------------------------------------------

function submitWhatsApp(job) {
  if (!whatsapp) {
    finish(job, 'error', 'WhatsApp is not initialized.');
    return;
  }
  if (whatsappPending.has(job.id)) return;
  whatsappPending.add(job.id);
  const key = chatKey(job);
  const cwd = job.cwd || '';
  noteMessage(job, 'user', job.text);
  whatsapp.send(job.chat, job.text).then(() => {
    markHandled(job);
    saveState();
    signal('ack', job.id, true);
    publish(key, { chat: job.chat, id: job.id, status: 'sent', text: '', cwd, name: job.name || job.chat }, true);
    log(`#${job.id}${job.session ? '@' + job.session : ''} sent WhatsApp message to ${job.chat}`);
  }).catch(error => {
    finish(job, 'error', error.message);
  }).finally(() => {
    whatsappPending.delete(job.id);
  });
}

function submit(job) {
  if (alreadyHandled(job)) return;
  if (job.ctx !== undefined) setContext(job);
  if (job.forget) {
    // A deleted chat: forget it and ack. No WhatsApp run.
    markHandled(job);
    forgetChat(job);
    saveState();
    signal('ack', job.id, true);
    return;
  }

  if (job.hello) {
    // The addon announcing itself: ack, offer a restore if its data is fresh,
    // and refresh the slots so it can read our clock. No WhatsApp run.
    markHandled(job);
    saveState();
    signal('ack', job.id, true);
    maybeOfferRestore(job);
    publishNow();
    log(`hello from session ${job.session}${pendingRestore ? ' (restore offered)' : ''}`);
    return;
  }
  const key = chatKey(job);
  const cur = running.get(key);
  if (cur && cur.job.id === job.id) return;
  const q = queued.get(key);
  if (q && q.id === job.id) return;
  if (cur || running.size >= MAX_PARALLEL) {
    queued.set(key, job);
    log(`#${job.id}${job.session ? '@' + job.session : ''} queued (${cur ? 'chat busy' : running.size + ' running'})`);
    return;
  }
  runJob(job);
}

function drainQueue() {
  for (const [key, job] of queued) {
    if (running.size >= MAX_PARALLEL) break;
    if (running.has(key)) continue;
    queued.delete(key);
    runJob(job);
  }
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
    cwd: '',
    text: message.text,
    sender: message.sender,
    replyTo: message.replyTo,
    via: 'whatsapp',
  };
  state.lastId = id;
  noteMessage(job, 'contact', message.text);
  // Incoming messages need distinct live keys. Using only the chat id would
  // replace a previous message when several arrive before WoW polls a slot.
  publish(`${chatKey(job)}:incoming:${id}`, {
    chat: message.chat,
    id,
    status: 'incoming',
    text: message.text,
    cwd: '',
    name: message.name,
    chatName: message.chatName || message.name,
    isGroup: message.isGroup,
    sender: message.sender,
    replyTo: message.replyTo,
    timestamp: message.timestamp,
  }, true);
  signal('sig', id, true);
  incomingBeat();
  log(`WhatsApp message from ${message.name} (${message.chat})`);
}

function startWhatsApp() {
  if (!whatsappConfig.enabled) return;
  whatsapp = new WhatsAppProvider(whatsappConfig, {
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
    disconnected: reason => log('WhatsApp disconnected:', String(reason)),
    message: receiveWhatsApp,
  });
  whatsapp.start().catch(error => {
    log('WhatsApp startup failed:', error.message);
    if (!exitWhenIdle) setTimeout(startWhatsApp, 10000);
  });
}

function runJob(job) {
  if (!whatsappConfig.enabled) {
    finish(job, 'error', 'WhatsApp integration is disabled. Enable whatsapp.enabled in bridge/config.json.');
    return;
  }
  submitWhatsApp(job);
}

function finish(job, status, text, session, denied) {
  if (job.finished) return; // spawn failures fire both 'error' and 'close'
  job.finished = true;
  running.delete(chatKey(job));
  markHandled(job);
  saveState();
  noteMessage(job, status === 'done' ? 'whatsapp' : 'system', status === 'done' ? text : 'Bridge error: ' + text);
  publish(chatKey(job), { chat: job.chat, id: job.id, status, text, cwd: job.cwd, session, denied }, true);
  signal('sig', job.id, true);
  log(`#${job.id}${job.session ? '@' + job.session : ''} ${status} (${text.length} chars)`);
  drainQueue();
  if (exitWhenIdle && running.size === 0) process.exit(status === 'done' ? 0 : 1);
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
    '-IntervalMs', String(cap.intervalMs), '-ProcessName', cap.processName];
  const ps = spawn('powershell.exe', args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  const rl = readline.createInterface({ input: ps.stdout });
  rl.on('line', (line) => {
    let ev;
    try { ev = JSON.parse(line); } catch { return; }
    if (ev.info) { log('capture:', ev.info); return; }
    if (ev.warn) { log('capture:', ev.warn); return; }
    if (ev.error) { log('capture error:', ev.error); return; }
    if (typeof ev.id === 'number') {
      const jobs = jobsFromStrip(ev.id, ev.text);
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
  console.log(`  folder   : ${DEFAULT_CWD}  (${DEFAULT_CWD_SOURCE}; chats can override with /wow-whatsapp cd)`);
  console.log(`  addons   : ${cfg.addonDir}`);
  console.log(`  addon    : ${addonInstalled() ? 'installed' : 'NOT INSTALLED - run: node setup.js, then restart WoW'}`);
  console.log(`  slots    : ${slotsInstalled() ? SLOTS + ' installed' : 'NOT INSTALLED - run: node setup.js (or node bridge/install-slots.js), then restart WoW'}`);
  console.log(`  capture  : ${cap.enabled ? 'on (' + cap.processName + ', ' + cap.cellsPerRow + 'x' + cap.maxRows + ' cells of ' + cap.cellPx + 'px)' : 'off'}`);
  console.log(`  whatsapp : ${whatsappConfig.enabled ? 'on (scan the QR code in the bridge output)' : 'off'}`);
  console.log(`  parallel : up to ${MAX_PARALLEL} chats at once`);
  console.log(`  fallback : ${cfg.savedVariablesFile}`);
  console.log(`  whatsapp   : ${whatsappConfig.enabled ? 'enabled' : 'disabled'}`);
  console.log(`  mode     : ${cfg.permissionMode}, ${(cfg.allowedTools || []).length} allowed tool rules`);
  console.log(`  sessions : ${Object.keys(state.sessions).length} saved`);
  const ctx = gameContext();
  console.log(`  context  : ${cfg.gameContext === false ? 'off (gameContext in config.json)' : ctx ? (ctx.split('\n').find(l => /^Character:/i.test(l)) || ctx.split('\n')[0]).slice(0, 100) : 'none yet (the addon sends it with its hello; /wow-whatsapp context in game)'}`);
  console.log(`  primer   : ${!PRIMER_FILE ? 'off (primerFile in config.json)' : primer() ? path.resolve(REPO, PRIMER_FILE) + ' (' + primer().length + ' chars, with the context)' : 'NOT FOUND: ' + path.resolve(REPO, PRIMER_FILE)}`);
  console.log('Leave this window open while you play. Ctrl+C to stop.\n');
}

banner();
if (inject !== null) {
  submit({ id: state.lastId + 1, session: '', chat: '', text: inject, cwd: '', newSession: false, via: 'inject' });
} else {
  startWhatsApp();
  pollSavedVariables();
  if (once) {
    if (running.size === 0) { console.log('nothing pending'); process.exit(0); }
  } else {
    setInterval(pollSavedVariables, cfg.pollMs || 750);
    presenceBeat();
    setInterval(presenceBeat, cfg.presenceIntervalMs || 30000);
    if (cap.enabled) startCapture();
  }
}
