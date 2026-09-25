#!/usr/bin/env node
'use strict';
// One-shot installer.
//
//   node setup.js [--wow "<client folder>"] [--project "<default work folder>"] [--account <name>]
//
// Finds the WoW: Forever client, copies the addon into Interface\AddOns, writes
// bridge/config.json from the example (if missing), and builds the slot pool.
// Re-running is safe: existing config and generated files are kept.

const fs = require('fs');
const os = require('os');
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

function findClient() {
  if (args.wow) {
    if (isClient(args.wow)) return args.wow;
    throw new Error(`--wow "${args.wow}" does not look like a WoW client folder (needs Interface\\ and a Wow*.exe)`);
  }
  const roots = [process.env['ProgramFiles(x86)'], process.env.ProgramFiles, 'D:\\', 'E:\\', 'D:\\Games', 'E:\\Games', 'C:\\Games']
    .filter(Boolean).map(r => path.join(r, 'World of Warcraft'));
  for (const root of roots) {
    for (const flavor of ['_classic_beta_', '_forever_', '_retail_', '_classic_era_', '_classic_']) {
      const dir = path.join(root, flavor);
      if (isClient(dir)) return dir;
    }
  }
  throw new Error('Could not find the WoW client. Pass --wow "C:\\path\\to\\World of Warcraft\\_classic_beta_"');
}

function findAccount(client) {
  const base = path.join(client, 'WTF', 'Account');
  let names = [];
  try { names = fs.readdirSync(base).filter(n => n !== 'SavedVariables' && fs.statSync(path.join(base, n)).isDirectory()); } catch {}
  if (args.account) {
    if (!names.includes(args.account)) throw new Error(`Account "${args.account}" not found under ${base}`);
    return args.account;
  }
  if (!names.length) throw new Error(`No account folder under ${base}. Log into the game once, then run setup again.`);
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

function writeConfig(client, account) {
  if (fs.existsSync(CONFIG)) {
    console.log(`config   : ${CONFIG} already exists, keeping it`);
    return JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
  }
  const cfg = JSON.parse(fs.readFileSync(EXAMPLE, 'utf8'));
  cfg.addonDir = path.join(client, 'Interface', 'AddOns');
  cfg.inboxFile = path.join(cfg.addonDir, 'WoWWhatsApp', 'Inbox.lua');
  cfg.savedVariablesFile = path.join(client, 'WTF', 'Account', account, 'SavedVariables', 'WoWWhatsApp.lua');
  cfg.defaultCwd = args.project ? path.resolve(args.project) : process.cwd();
  const exe = fs.readdirSync(client).find(f => /^Wow.*\.exe$/i.test(f));
  if (exe) cfg.capture.processName = exe.replace(/\.exe$/i, '');
  fs.writeFileSync(CONFIG, JSON.stringify(cfg, null, 2) + '\n');
  console.log(`config   : wrote ${CONFIG}`);
  return cfg;
}

try {
  const client = findClient();
  console.log(`client   : ${client}`);
  const account = findAccount(client);
  console.log(`account  : ${account}`);
  const { dest, copied } = copyAddon(client);
  console.log(`addon    : ${copied} file(s) -> ${dest}`);
  const cfg = writeConfig(client, account);
  console.log(`project  : ${cfg.defaultCwd}  (change with /wow-whatsapp cd in game, or defaultCwd in config.json)`);
  console.log('slots    : building the reply-slot pool and signal files...');
  const r = spawnSync(process.execPath, [path.join(BRIDGE, 'install-slots.js')], { stdio: 'inherit' });
  if (r.status !== 0) throw new Error('install-slots.js failed');
  console.log(`
Done. Next:
  1. Fully quit and relaunch World of Warcraft (it only discovers new addon files at launch).
  2. Enable "WoW WhatsApp" at the character select AddOns screen (the WoW WhatsApp slot ### entries stay enabled).
  3. Start the bridge:  npm start   (in this terminal; bridge\\start-window.cmd opens its own window)
  4. In game:  /wow-whatsapp
`);
} catch (e) {
  console.error('setup failed:', e.message);
  process.exit(1);
}
