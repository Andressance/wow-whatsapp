#!/usr/bin/env node
'use strict';
// Creates the reply-slot addons and signal files that the no-reload transport needs.
// WoW only indexes addon folders and files at launch, so run this once, then restart
// the game. Safe to re-run: existing files are left alone.

const fs = require('fs');
const path = require('path');

const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, 'config.json'), 'utf8'));
const addons = cfg.addonDir;
const N = cfg.slots || 200;
const ACT = cfg.actMax || 60;
const PRESENCE = cfg.presenceMax || 2000;
const iface = cfg.tocInterface || '16001';

if (!fs.existsSync(path.join(addons, 'WoWClaude', 'WoWClaude.toc'))) {
  console.error('WoWClaude addon not found under ' + addons);
  process.exit(1);
}

let made = 0, kept = 0;
function ensure(file, content) {
  if (fs.existsSync(file)) { kept++; return; }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
  made++;
}

for (let i = 1; i <= N; i++) {
  const name = 'WoWClaude_S' + String(i).padStart(3, '0');
  const dir = path.join(addons, name);
  ensure(path.join(dir, name + '.toc'), [
    '## Interface: ' + iface,
    '## Title: WoW Claude slot ' + String(i).padStart(3, '0'),
    '## Notes: Reply slot for WoW Claude. Load-on-demand; leave it enabled.',
    '## LoadOnDemand: 1',
    '## Dependencies: WoWClaude',
    '',
    'Inbox.lua',
    '',
  ].join('\n'));
  ensure(path.join(dir, 'Inbox.lua'), 'WoWClaude_SlotData = nil\n');
  ensure(path.join(addons, 'WoWClaude', 'sig', String(i).padStart(3, '0') + '.wav'), '');
  ensure(path.join(addons, 'WoWClaude', 'ack', String(i).padStart(3, '0') + '.wav'), '');
  // Heartbeat files: one per Claude action, flipped valid by the bridge as it works.
  for (let k = 1; k <= ACT; k++) {
    ensure(path.join(addons, 'WoWClaude', 'act', String(i).padStart(3, '0'), String(k).padStart(2, '0') + '.wav'), '');
  }
}

// Presence files: the bridge flips one every 30 s so the game can show "connected".
for (let k = 1; k <= PRESENCE; k++) {
  ensure(path.join(addons, 'WoWClaude', 'presence', String(k).padStart(4, '0') + '.wav'), '');
}

// Control files for the addon's self-test: one always empty, one always valid.
ensure(path.join(addons, 'WoWClaude', 'ctl', 'empty.wav'), '');
ensure(path.join(addons, 'WoWClaude', 'ctl', 'valid.wav'), require('./protocol').SILENT_WAV);

console.log(`slots: ${N}  files created: ${made}  already present: ${kept}`);
if (made > 0) console.log('Now fully quit and relaunch WoW so it sees the new files.');
