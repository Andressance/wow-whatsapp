#!/usr/bin/env node
'use strict';
// One-shot installer.
//
//   node setup.js [--wow "<client folder>"] [--account <name>]
//
// Finds the WoW: Forever client, copies the addon into Interface\AddOns, writes
// bridge/config.json from the example (if missing), and builds the slot pool.
// Re-running is safe: existing config and generated files are kept. A config
// still on the beta client moves to Forever once Forever is installed.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = __dirname;
const ADDON_SRC = path.join(ROOT, 'addon', 'WoWWhatsApp');
const BRIDGE = path.join(ROOT, 'bridge');
const CONFIG = path.join(BRIDGE, 'config.json');
const EXAMPLE = path.join(BRIDGE, 'config.example.json');

const args = {};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a.startsWith('--')) args[a.slice(2)] = process.argv[i + 1] && !process.argv[i + 1].startsWith('--') ? process.argv[++i] : true;
}

function isClient(dir) {
  try {
    return fs.existsSync(path.join(dir, 'Interface')) && fs.readdirSync(dir).some(f => /^Wow.*\.exe$/i.test(f));
  } catch { return false; }
}

// The client folder an existing config.json points at.
function configuredClient() {
  try { return path.dirname(path.dirname(JSON.parse(fs.readFileSync(CONFIG, 'utf8')).addonDir)); } catch { return null; }
}

function findClient() {
  if (args.wow) {
    if (isClient(args.wow)) return args.wow;
    throw new Error(`--wow "${args.wow}" does not look like a WoW client folder (needs Interface\\ and a Wow*.exe)`);
  }
  // A re-run stays on its client, unless that's the beta: Forever replaced it.
  const current = configuredClient();
  if (current && isClient(current) && path.basename(current) !== '_classic_beta_') return current;
  const roots = [process.env['ProgramFiles(x86)'], process.env.ProgramFiles, 'D:\\', 'E:\\', 'D:\\Games', 'E:\\Games', 'C:\\Games']
    .filter(Boolean).map(r => path.join(r, 'World of Warcraft'));
  if (current) roots.unshift(path.dirname(current));
  for (const root of roots) {
    // The beta folder can outlive the beta: Forever goes first.
    for (const flavor of ['_forever_', '_classic_beta_', '_retail_', '_classic_era_', '_classic_']) {
      const dir = path.join(root, flavor);
      if (isClient(dir)) return dir;
    }
  }
  throw new Error('Could not find the WoW client. Pass --wow "C:\\path\\to\\World of Warcraft\\_forever_"');
}

function findAccount(client) {
  const base = path.join(client, 'WTF', 'Account');
  let names = [];
  try { names = fs.readdirSync(base).filter(n => n !== 'SavedVariables' && fs.statSync(path.join(base, n)).isDirectory()); } catch {}
  if (args.account) {
    if (!names.includes(args.account)) throw new Error(`Account "${args.account}" not found under ${base}`);
    return args.account;
  }
  // The game creates this folder at the first login. Everything else can be
  // installed before that (slots must exist when the game launches).
  if (!names.length) return null;
  if (names.length > 1) console.log(`Several accounts found (${names.join(', ')}); using "${names[0]}". Pass --account to choose another.`);
  return names[0];
}

function copyAddon(client) {
  const dest = path.join(client, 'Interface', 'AddOns', 'WoWWhatsApp');
  fs.mkdirSync(dest, { recursive: true });
  let copied = 0;
  for (const f of fs.readdirSync(ADDON_SRC)) {
    const target = path.join(dest, f);
    if (f === 'Inbox.lua' && fs.existsSync(target)) continue; // the bridge owns it once running
    fs.copyFileSync(path.join(ADDON_SRC, f), target);
    copied++;
  }
  return { dest, copied };
}

// The game exe without .exe, as the capture looks for it.
function processNameOf(client) {
  const exe = fs.readdirSync(client).find(f => /^Wow.*\.exe$/i.test(f));
  return exe ? exe.replace(/\.exe$/i, '') : null;
}

function pointAtClient(cfg, client, account) {
  cfg.addonDir = path.join(client, 'Interface', 'AddOns');
  cfg.inboxFile = path.join(cfg.addonDir, 'WoWWhatsApp', 'Inbox.lua');
  cfg.savedVariablesFile = account ? path.join(client, 'WTF', 'Account', account, 'SavedVariables', 'WoWWhatsApp.lua') : '';
  const processName = processNameOf(client);
  if (processName) cfg.capture = { ...cfg.capture, processName };
}

function writeConfig(client, account) {
  if (fs.existsSync(CONFIG)) {
    const cfg = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
    const moved = path.resolve(cfg.addonDir || '').toLowerCase() !== path.resolve(client, 'Interface', 'AddOns').toLowerCase();
    if (moved) pointAtClient(cfg, client, account);
    else if (account && !cfg.savedVariablesFile) pointAtClient(cfg, client, account);
    else {
      console.log(`config   : ${CONFIG} already exists, keeping it`);
      return cfg;
    }
    fs.writeFileSync(CONFIG, JSON.stringify(cfg, null, 2) + '\n');
    console.log(`config   : ${CONFIG} updated for ${path.basename(client)}; everything else kept`);
    return cfg;
  }
  const cfg = JSON.parse(fs.readFileSync(EXAMPLE, 'utf8'));
  pointAtClient(cfg, client, account);
  fs.writeFileSync(CONFIG, JSON.stringify(cfg, null, 2) + '\n');
  console.log(`config   : wrote ${CONFIG}`);
  return cfg;
}

try {
  const client = findClient();
  console.log(`client   : ${client}`);
  const account = findAccount(client);
  console.log(`account  : ${account || 'none yet (the game creates it at your first login; set savedVariablesFile in config.json later if you use the reload fallback)'}`);
  const { dest, copied } = copyAddon(client);
  console.log(`addon    : ${copied} file(s) -> ${dest}`);
  writeConfig(client, account);
  console.log('slots    : building the reply-slot pool and signal files...');
  const r = spawnSync(process.execPath, [path.join(BRIDGE, 'install-slots.js')], { stdio: 'inherit' });
  if (r.status !== 0) throw new Error('install-slots.js failed');
  console.log(`
Done. Next:
  1. Fully quit and relaunch World of Warcraft (it only discovers new addon files at launch).
  2. Enable "WoW WhatsApp" at the character select AddOns screen (the WoW WhatsApp slot ### entries stay enabled).
  3. Start the bridge:  npm start   (in this terminal; bridge\\start-window.cmd opens its own window)
  4. In game:  /wa
`);
} catch (e) {
  console.error('setup failed:', e.message);
  process.exit(1);
}
