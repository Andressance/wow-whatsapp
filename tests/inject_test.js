// Bridge test in a scratch sandbox, no WhatsApp and no game needed: a fake AddOns
// dir with a 5-slot pool and a fake WhatsApp provider. `node bridge.js --inject "..."`
// must send through the provider, publish the result into every slot and Inbox.lua,
// and flip the ack / sig signal files, for a delivered message and for a failed one.
'use strict';
const fs = require('fs'), path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const luaparse = require('luaparse');

const S = path.join(__dirname, 'tmp', 'inject');
const SRC = path.join(__dirname, '..', 'bridge');
fs.rmSync(S, { recursive: true, force: true });
fs.mkdirSync(path.join(S, 'addons', 'WoWWhatsApp'), { recursive: true });
for (const f of ['bridge.js', 'protocol.js', 'install-slots.js', 'capture.ps1']) fs.copyFileSync(path.join(SRC, f), path.join(S, f));
fs.writeFileSync(path.join(S, 'addons', 'WoWWhatsApp', 'WoWWhatsApp.toc'), '## Interface: 120100\n');
// The real provider needs a browser and a login; this one accepts everything except "fail".
fs.writeFileSync(path.join(S, 'whatsapp.js'), `
module.exports = class FakeWhatsApp {
  constructor(config, handlers) { this.handlers = handlers; }
  async start() { this.ready = true; this.handlers.ready(); }
  async send(chat, text) { if (text === 'fail') throw new Error('boom'); }
  stop() {}
};`);

const cfg = JSON.parse(fs.readFileSync(path.join(SRC, 'config.example.json'), 'utf8'));
cfg.addonDir = path.join(S, 'addons');
cfg.inboxFile = path.join(S, 'addons', 'WoWWhatsApp', 'Inbox.lua');
cfg.savedVariablesFile = path.join(S, 'nope.lua');
cfg.slots = 5;
fs.writeFileSync(path.join(S, 'config.json'), JSON.stringify(cfg, null, 2));

console.log(execFileSync(process.execPath, ['install-slots.js'], { cwd: S, encoding: 'utf8' }).trim());

function inject(text) {
  const r = spawnSync(process.execPath, ['bridge.js', '--inject', text], { cwd: S, encoding: 'utf8', timeout: 60000, env: { ...process.env, WHATSAPP_INJECT_CHAT: '34600112233@c.us' } });
  if (r.stderr.trim()) console.log('stderr:', r.stderr.trim().slice(0, 500));
  return r;
}

function readLua(file, globalName) {
  const src = fs.readFileSync(file, 'utf8');
  const ast = luaparse.parse(src, { luaVersion: '5.1' });
  const assign = ast.body.find(n => n.type === 'AssignmentStatement' && n.variables[0].name === globalName);
  const val = v => v.raw !== undefined ? v.raw.replace(/^"|"$/g, '') : v.value;
  const top = {};
  for (const f of assign.init[0].fields) {
    if (f.key.name === 'replies') {
      top.replies = f.value.fields.map(entry => {
        const rec = {};
        for (const g of entry.value.fields) rec[g.key.name] = val(g.value);
        return rec;
      });
    } else top[f.key.name] = val(f.value);
  }
  return top;
}
const size = f => fs.statSync(path.join(S, 'addons', 'WoWWhatsApp', f)).size;
let ok = true;
function check(name, good, detail) { ok = ok && good; console.log(`${good ? 'ok ' : 'BAD'}  ${name}${detail ? '  ' + detail : ''}`); }

// 1. A delivered message: status "sent" in every slot, the ack file valid.
const sent = inject('hello');
check('delivered message exits 0', sent.status === 0, `(exit ${sent.status})`);
for (let i = 1; i <= 5; i++) {
  const d = readLua(path.join(S, 'addons', 'WoWWhatsApp_S00' + i, 'Inbox.lua'), 'WoWWhatsApp_SlotData');
  const rec = (d.replies || [])[0] || {};
  check(`slot ${i} carries status "sent" for id 1`, d.replies.length === 1 && Number(rec.id) === 1 && rec.status === 'sent', JSON.stringify(rec));
}
check('ack/001.wav valid, ack/002.wav empty', size('ack/001.wav') > 40 && size('ack/002.wav') === 0);

// 2. A failed one: status "error" with the reason, sig valid, ack untouched.
const failed = inject('fail');
check('failed message exits 1', failed.status === 1, `(exit ${failed.status})`);
const inbox = readLua(cfg.inboxFile, 'WoWWhatsApp_Inbox');
const rec = (inbox.replies || []).find(r => r.status === 'error') || {};
check('Inbox.lua carries the error and its reason', rec.text === 'boom', JSON.stringify(rec));
check('sig/002.wav valid for the failed id', size('sig/002.wav') > 40);
check('ack/002.wav stays empty', size('ack/002.wav') === 0);
// The signal files ahead of a used id are kept empty, so a lap-old valid file can't look like an answer.
check('ack/003.wav empty', size('ack/003.wav') === 0);

console.log(ok ? '>>> INJECT TEST PASS' : '>>> INJECT TEST FAIL');
process.exit(ok ? 0 : 1);
