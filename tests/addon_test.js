// Runs the real addon Lua (Codec.lua + WoWWhatsApp.lua) in a Lua VM with a stub
// WoW API (wow_stub.lua) and drives it through a session: login, hello, a sent
// message read back off the pixel strip, delivery by ack file or slot reply,
// incoming WhatsApp messages, the chat list, and a restore.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const fengari = require('fengari');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;

const ADDON = path.join(__dirname, '..', 'addon', 'WoWWhatsApp');
const CELLS_PER_ROW = 200;
const ANA = '34600112233@c.us';

function newVM() {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const run = (code, arg) => {
    if (lauxlib.luaL_loadstring(L, to_luastring(code)) !== lua.LUA_OK) throw new Error('Lua load: ' + to_jsstring(lua.lua_tostring(L, -1)));
    let nargs = 0;
    if (arg !== undefined) { lua.lua_pushstring(L, to_luastring(arg)); nargs = 1; }
    if (lua.lua_pcall(L, nargs, 0, 0) !== lua.LUA_OK) throw new Error('Lua error: ' + to_jsstring(lua.lua_tostring(L, -1)));
  };
  // Evaluate an expression and bring it back as a string (or nil).
  const evaluate = (expr) => {
    run(`local v = (${expr}); if v == nil then RESULT = nil else RESULT = tostring(v) end`);
    lua.lua_getglobal(L, to_luastring('RESULT'));
    const isNil = lua.lua_isnil(L, -1);
    const s = isNil ? null : to_jsstring(lua.lua_tolstring(L, -1));
    lua.lua_pop(L, 1);
    return s;
  };
  const num = (expr) => Number(evaluate(expr));
  run(fs.readFileSync(path.join(__dirname, 'wow_stub.lua'), 'utf8'));
  for (const f of ['Codec.lua', 'Inbox.lua', 'WoWWhatsApp.lua']) run(fs.readFileSync(path.join(ADDON, f), 'utf8'), 'WoWWhatsApp');
  return { run, evaluate, num };
}

// Read the strip the addon drew, exactly like capture.ps1: 3 bits per cell,
// [C7 1A] [id] [len] [payload] [fletcher]. Returns { id, text } or null.
function decodeStrip(vm) {
  if (vm.evaluate('WoWWhatsAppStrip and WoWWhatsAppStrip.shown') !== 'true') return null;
  vm.run(`
    local parts = {}
    for _, t in ipairs(WoWWhatsAppStrip.textures) do
      if t.shown and t.color then
        local c, r = math.floor(t.x / 4), math.floor(-t.y / 4)
        local v = (t.color[1] >= 0.5 and 4 or 0) + (t.color[2] >= 0.5 and 2 or 0) + (t.color[3] >= 0.5 and 1 or 0)
        parts[#parts + 1] = (r * ${CELLS_PER_ROW} + c) .. ":" .. v
      end
    end
    RESULT = table.concat(parts, ",")`);
  const cells = [];
  for (const p of vm.evaluate('RESULT').split(',')) { const [i, v] = p.split(':').map(Number); cells[i] = v; }
  const bytes = [];
  let acc = 0, nbits = 0;
  for (let i = 0; i < cells.length; i++) {
    acc = (acc << 3) | (cells[i] || 0); nbits += 3;
    while (nbits >= 8) { bytes.push((acc >> (nbits - 8)) & 0xff); nbits -= 8; acc &= (1 << nbits) - 1; }
  }
  assert.equal(bytes[0], 0xc7); assert.equal(bytes[1], 0x1a);
  const id = bytes[2] * 256 + bytes[3];
  const len = bytes[4] * 256 + bytes[5];
  let s1 = 0, s2 = 0;
  for (let k = 2; k < 6 + len; k++) { s1 = (s1 + bytes[k]) % 255; s2 = (s2 + s1) % 255; }
  assert.equal(bytes[6 + len], s1, 'fletcher s1'); assert.equal(bytes[7 + len], s2, 'fletcher s2');
  return { id, text: Buffer.from(bytes.slice(6, 6 + len)).toString('utf8') };
}

// Records on the strip: session, chat, id, (unused), flags, name, text.
function stripRecords(vm) {
  const frame = decodeStrip(vm);
  if (!frame) return [];
  return frame.text.split('\x1E').map(r => {
    const p = r.split('\x1F');
    return { session: p[0], chat: p[1], id: Number(p[2]), flags: p[4], name: p[5], text: p.slice(6).join('\x1F') };
  });
}

// Make the next LoadAddOn deliver this slot data (a Lua table literal body).
function nextSlot(vm, luaBody) {
  vm.run(`STUB.onLoadAddOn = function(name) WoWWhatsApp_SlotData = ${luaBody} end`);
}

// The bridge hands the game these records through the next slot it reads.
function receive(vm, records) {
  nextSlot(vm, `{ now = time(), replies = { ${records.join(', ')} } }`);
  vm.run('STUB.now = STUB.now + 20; STUB.Tick()');
}

const incoming = o => `{ chat = "${o.chat}", id = ${o.id}, status = "incoming", text = "${o.text}", name = "${o.name || ''}", chatName = "${o.name || ''}", `
  + `isGroup = ${!!o.group}, sender = "${o.sender || ''}", replyTo = "${o.replyTo || ''}", fromMe = ${!!o.fromMe}, timestamp = ${o.ts || 0} }`;

function login(vm, { sound = false } = {}) {
  // With the sound-file channel working (the self-test finds ctl/valid.wav playable)
  // the bridge's ack files are read directly.
  if (sound) vm.run('STUB.sounds["Interface\\\\AddOns\\\\WoWWhatsApp\\\\ctl\\\\valid.wav"] = true');
  vm.run('STUB.FireEvent("ADDON_LOADED", "WoWWhatsApp")');
  vm.run('STUB.FireEvent("PLAYER_LOGIN")');
}

// Let the bridge answer the login hello: its slot carries a fresh clock, which is
// what makes the addon consider itself connected (Send is gated on that).
function connect(vm) {
  vm.run('STUB.RunTimers()'); // C_Timer.After(3, SayHello)
  nextSlot(vm, '{ now = time(), replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()'); // hello poll 5 s later
  assert.equal(vm.evaluate('WoWWhatsApp.IsConnected()'), 'true', 'connected after the hello slot');
}

// Start a chat with a phone number and make it the active one.
function chatWith(vm, number = '34600112233') {
  vm.run(`WoWWhatsApp.NewChat("${number}")`);
  return vm.evaluate('WoWWhatsAppDB.activeChat');
}

// The chat list as drawn: "chatId~name~preview~unread" per row, top to bottom.
function rows(vm) {
  vm.run(`local r = {}
    for _, f in ipairs(STUB.frames) do if f.chatId and f.shown and f.preview then r[#r + 1] = f end end
    table.sort(r, function(a, b) return a.y > b.y end)
    local out = {}
    for _, f in ipairs(r) do out[#out + 1] = f.chatId .. "~" .. tostring(f.name.text) .. "~" .. tostring(f.preview.text) .. "~" .. tostring(f.count.text) end
    RESULT = table.concat(out, ";")`);
  return vm.evaluate('RESULT').split(';').filter(Boolean);
}

// The conversation as drawn: "side:text" per item, top to bottom (side: me, them, mid).
function bubbles(vm) {
  vm.run(`local r = {}
    for _, f in ipairs(STUB.frames) do if f.body and f.when and f.shown and f.y and f.parent == WoWWhatsAppContent then r[#r + 1] = f end end
    table.sort(r, function(a, b) return a.y > b.y end)
    local out = {}
    for _, f in ipairs(r) do out[#out + 1] = (f.x < 0 and "me" or f.x > 0 and "them" or "mid") .. ":" .. tostring(f.body.text) end
    RESULT = table.concat(out, ";")`);
  return vm.evaluate('RESULT').split(';').filter(Boolean);
}

const texts = vm => vm.evaluate('table.concat(STUB.texts, "|")');
const lastMessage = (vm, chat = 1) => vm.evaluate(`WoWWhatsAppDB.chats[${chat}].history[#WoWWhatsAppDB.chats[${chat}].history].text`);

test('addon loads, builds its UI and creates a first chat', () => {
  const vm = newVM();
  login(vm);
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 1);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].name'), 'Chat 1');
  assert.equal(vm.evaluate('WoWWhatsAppFrame ~= nil'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppMini ~= nil'), 'true');
  assert.equal(vm.num('#STUB.tickers'), 1);
  assert.equal(vm.evaluate('SlashCmdList.WOWWHATSAPP ~= nil'), 'true');
  assert.equal(vm.evaluate('SlashCmdList.WHATSAPPASK ~= nil'), 'true');
});

test('hello goes out on the strip after login', () => {
  const vm = newVM();
  login(vm);
  vm.run('STUB.RunTimers()'); // C_Timer.After(3, SayHello)
  const recs = stripRecords(vm);
  assert.equal(recs.length, 1);
  assert.equal(recs[0].flags, 'h');
  assert.equal(recs[0].text, '');
  assert.equal(recs[0].session, vm.evaluate('WoWWhatsAppDB.session'));
});

test('saved data from the assistant-era addon is cleaned up on load', () => {
  const vm = newVM();
  vm.run(`WoWWhatsAppDB = { settings = { context = true, cwd = "C:\\\\x" }, chats = { { id = "a", name = "Old", cwd = "C:\\\\x", progress = "x",
    history = { { role = "claude", text = "hi", denied = { "WebSearch" } }, { role = "whatsapp", text = "yo" }, { role = "user", text = "q" } } } },
    activeChat = "a", outbox = { id = 1 } }`);
  login(vm);
  assert.equal(vm.evaluate('WoWWhatsAppDB.settings.context'), null);
  assert.equal(vm.evaluate('WoWWhatsAppDB.outbox'), null);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].cwd'), null);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].history[1].role'), 'contact');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].history[1].denied'), null);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].history[2].role'), 'contact');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].history[3].role'), 'user');
});

test('a shift-clicked link lands in the focused input and is sent as its plain name', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  chatWith(vm);
  const link = '|cff1eff00|Hitem:2140:0:0:0:0:0:0:0:60:0:0|h[Fine Longsword]|h|r';
  // Without focus the link is left alone (shift-click keeps its normal meaning).
  vm.run(`WoWWhatsAppInput:SetText("is this good for me? "); WoWWhatsAppInput:ClearFocus(); ChatFrameUtil.InsertLink("${link}")`);
  assert.equal(vm.evaluate('WoWWhatsAppInput:GetText()'), 'is this good for me? ');
  // The client's own path (bags, spellbook, quest log all end here): ChatFrameUtil.InsertLink.
  vm.run(`WoWWhatsAppInput:SetFocus(); ChatFrameUtil.InsertLink("${link}")`);
  assert.equal(vm.evaluate('WoWWhatsAppInput:GetText()'), 'is this good for me? ' + link);
  // The old global name is not hooked as well, so nothing is inserted twice.
  vm.run(`ChatEdit_InsertLink("${link}")`);
  assert.equal(vm.evaluate('WoWWhatsAppInput:GetText()'), 'is this good for me? ' + link + link, 'the alias reaches the one hook exactly once');
  vm.run(`WoWWhatsAppInput:SetText("is this good for me? ${link}")`);
  vm.run('WoWWhatsApp.SendFromInput()');
  const rec = stripRecords(vm).find(r => r.text.startsWith('is this good'));
  assert.equal(rec.text, 'is this good for me? [Fine Longsword]');
  assert.equal(lastMessage(vm, 2), 'is this good for me? [Fine Longsword]', 'the history shows what was sent');
  // Bare links, repeated links and plain text with a pipe.
  assert.equal(vm.evaluate('WoWWhatsApp.ExpandLinks("x |Hspell:1978|h[Serpent Sting]|h y |Hspell:1978|h[Serpent Sting]|h")'), 'x [Serpent Sting] y [Serpent Sting]');
  assert.equal(vm.evaluate('WoWWhatsApp.ExpandLinks("plain text | with a pipe")'), 'plain text | with a pipe');
});

test('record separators typed into a message cannot split the strip record', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  chatWith(vm);
  vm.run('WoWWhatsApp.Send("one\\30two\\31three")');
  const recs = stripRecords(vm);
  const rec = recs.find(r => r.text.startsWith('one'));
  assert.equal(recs.length, 1);
  assert.equal(rec.text, 'one two three');
});

test('deleting a chat tells the bridge to forget it, and a restore never brings it back', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  chatWith(vm, '34600000001');
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 2);
  const gone = vm.evaluate('WoWWhatsAppDB.chats[2].id');
  vm.run(`WoWWhatsApp.DeleteChat("${gone}")`);
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 1);
  // A forget record for that chat is on the strip and remembered until acked.
  const rec = stripRecords(vm).find(r => r.flags === 'd');
  assert.ok(rec, 'forget record on the strip');
  assert.equal(rec.chat, gone);
  assert.equal(rec.text, '');
  assert.equal(vm.evaluate(`WoWWhatsAppDB.forget["${gone}"] ~= nil`), 'true');
  // A restore that still lists the chat is ignored for it.
  const token = vm.evaluate('WoWWhatsAppDB.session');
  nextSlot(vm, `{ now = time(), replies = {}, restore = { token = "${token}", chats = { { id = "${gone}", name = "Second", messages = { { role = "user", text = "old", id = 1, t = 1 } } } } } }`);
  vm.run('WoWWhatsApp.Connect(); STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 1, 'deleted chat not restored');
  // The bridge acks the forget record: it leaves the strip and the memory.
  const slot = String(rec.id).padStart(3, '0');
  vm.run(`STUB.sounds["Interface\\\\AddOns\\\\WoWWhatsApp\\\\ack\\\\${slot}.wav"] = true; STUB.Tick()`);
  assert.equal(vm.evaluate(`WoWWhatsAppDB.forget["${gone}"]`), null, 'forgotten once acked');
  assert.ok(!stripRecords(vm).find(r => r.flags === 'd'), 'forget record left the strip');
});

test('until the bridge answers, Connect replaces Send and a message stays in the box', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWWhatsApp.Toggle(true)');
  assert.equal(vm.evaluate('WoWWhatsApp.IsConnected()'), 'false');
  assert.ok(texts(vm).includes('Not connected - start the bridge, then click Connect'));
  // Sending while disconnected puts the text back in the box and starts a connect attempt.
  vm.run('WoWWhatsAppInput:SetText("hello there"); WoWWhatsApp.SendFromInput()');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].pendingId'), null, 'nothing sent');
  assert.equal(vm.evaluate('WoWWhatsAppInput:GetText()'), 'hello there', 'message kept in the box');
  const hello = stripRecords(vm);
  assert.equal(hello.length, 1);
  assert.equal(hello[0].flags, 'h', 'a hello went out instead');
  assert.ok(texts(vm).includes('Connecting to the bridge...'));
  assert.ok(texts(vm).includes('your message goes out as soon as it answers'));
  // No answer within CONNECT_WAIT: the attempt is reported as failed, Connect is back.
  vm.run('STUB.now = STUB.now + 20; STUB.Tick()');
  assert.equal(vm.evaluate('WoWWhatsApp.IsConnected()'), 'false');
  assert.ok(texts(vm).includes('No answer from the bridge'));
  assert.equal(vm.evaluate('WoWWhatsAppInput:GetText()'), 'hello there', 'message still in the box after a failed attempt');
  // Click Connect again; this time the bridge answers the hello poll. Nothing was
  // queued by that click, so the message waits for the user.
  vm.run('WoWWhatsApp.Connect()');
  nextSlot(vm, '{ now = time(), replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWWhatsApp.IsConnected()'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].pendingId'), null, 'a plain Connect sends nothing by itself');
  vm.run('WoWWhatsApp.SendFromInput()');
  assert.ok(vm.num('WoWWhatsAppDB.chats[1].pendingId') >= 1, 'the kept message goes out once connected');
  assert.ok(stripRecords(vm).find(r => r.text === 'hello there'));
});

test('a message sent while disconnected goes out by itself once the bridge answers', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWWhatsApp.Toggle(true)');
  vm.run('WoWWhatsAppInput:SetText("hello there"); WoWWhatsApp.SendFromInput()');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].pendingId'), null, 'nothing sent yet');
  // The bridge answers the hello poll: the queued message follows without a second click.
  nextSlot(vm, '{ now = time(), replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWWhatsApp.IsConnected()'), 'true');
  assert.ok(vm.num('WoWWhatsAppDB.chats[1].pendingId') >= 1, 'queued message went out on connect');
  assert.ok(stripRecords(vm).find(r => r.text === 'hello there'));
  assert.equal(vm.evaluate('WoWWhatsAppInput:GetText()'), '', 'box cleared after the auto-send');
  // Only once: a later reconnect sends nothing.
  vm.run('WoWWhatsApp.Connect()');
  nextSlot(vm, '{ now = time(), replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(stripRecords(vm).filter(r => r.text === 'hello there').length, 1);
});

test('without the sound channel, the light stays green between idle slot polls', () => {
  // The stub has no ctl/valid.wav, so the login self-test disables the sound
  // channel: the addon is in "slot checks only" mode, like a client whose
  // PlaySoundFile reports every file as playable.
  const vm = newVM();
  login(vm);
  connect(vm);
  assert.equal(vm.evaluate('WoWWhatsApp.BridgeState()'), 'ok');
  // 90 s of silence used to mean "stale"; with no beats to hear that is normal.
  vm.run('STUB.now = STUB.now + 200; STUB.Tick()');
  assert.equal(vm.evaluate('WoWWhatsApp.BridgeState()'), 'ok', 'still green after 200 s');
  assert.equal(vm.evaluate('WoWWhatsApp.IsConnected()'), 'true');
  // 10 minutes in, the idle poll spends a slot; the bridge's clock in it keeps the light green.
  vm.run('STUB.loadCount = 0; STUB.onLoadAddOn = function(name) STUB.loadCount = STUB.loadCount + 1; WoWWhatsApp_SlotData = { now = time(), replies = {} } end');
  vm.run('STUB.now = STUB.now + 410; STUB.Tick()');
  assert.ok(vm.num('STUB.loadCount') >= 1, 'an idle poll');
  assert.equal(vm.evaluate('WoWWhatsApp.BridgeState()'), 'ok', 'green again after the idle poll');
  // A bridge that really is gone still shows: no slot answers, and the light drops.
  vm.run('STUB.onLoadAddOn = function(name) WoWWhatsApp_SlotData = nil end');
  vm.run('STUB.now = STUB.now + 800; STUB.Tick()');
  assert.equal(vm.evaluate('WoWWhatsApp.BridgeState()'), 'stale');
  vm.run('STUB.now = STUB.now + 700; STUB.Tick()');
  assert.equal(vm.evaluate('WoWWhatsApp.BridgeState()'), 'down');
});

test('a sent message goes on the strip and the bridge ack file marks it delivered', () => {
  const vm = newVM();
  login(vm, { sound: true });
  connect(vm);
  const chatId = chatWith(vm);
  assert.equal(chatId, ANA);
  vm.run('WoWWhatsApp.Send("hello world")');
  const id = vm.num('WoWWhatsAppDB.chats[2].pendingId');
  assert.ok(id >= 1);
  const rec = stripRecords(vm).find(r => r.text === 'hello world');
  assert.ok(rec, 'message record on the strip');
  assert.equal(rec.chat, ANA);
  assert.equal(rec.id, id);
  assert.equal(rec.flags, '');
  assert.ok(texts(vm).includes('Sending #' + id));
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[1].sent'), null, 'not delivered yet');
  // The bridge sent it to WhatsApp and flips ack/NNN.wav.
  vm.run(`STUB.sounds["Interface\\\\AddOns\\\\WoWWhatsApp\\\\ack\\\\${String(id).padStart(3, '0')}.wav"] = true; STUB.Tick()`);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].pendingId'), null, 'chat is free again');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[1].sent'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppStrip.shown'), 'false', 'strip cleared once nothing is pending');
});

test('a "sent" slot reply delivers the message, an "error" reply marks it failed with the reason', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  chatWith(vm);
  vm.run('WoWWhatsApp.Send("first")');
  const id = vm.num('WoWWhatsAppDB.chats[2].pendingId');
  receive(vm, [`{ chat = "${ANA}", id = ${id}, status = "sent", text = "" }`]);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].pendingId'), null);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[1].sent'), 'true');
  vm.run('WoWWhatsApp.Send("second")');
  const id2 = vm.num('WoWWhatsAppDB.chats[2].pendingId');
  assert.equal(id2, id + 1);
  receive(vm, [`{ chat = "${ANA}", id = ${id2}, status = "error", text = "34600112233 is not on WhatsApp." }`]);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].pendingId'), null);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[2].failed'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[2].sent'), null);
  assert.equal(lastMessage(vm, 2), 'Not sent: 34600112233 is not on WhatsApp.');
});

test('messages typed while one is on its way are queued and go out in order', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  chatWith(vm);
  vm.run('WoWWhatsApp.Send("one"); WoWWhatsApp.Send("two"); WoWWhatsApp.Send("three")');
  const first = vm.num('WoWWhatsAppDB.chats[2].pendingId');
  assert.deepEqual(stripRecords(vm).map(r => r.text), ['one'], 'only the first is on the strip');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[2].queued'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[3].queued'), 'true');
  receive(vm, [`{ chat = "${ANA}", id = ${first}, status = "sent", text = "" }`]);
  assert.deepEqual(stripRecords(vm).map(r => r.text), ['two'], 'the next one follows the delivery');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[2].queued'), null);
  const second = vm.num('WoWWhatsAppDB.chats[2].pendingId');
  receive(vm, [`{ chat = "${ANA}", id = ${second}, status = "sent", text = "" }`]);
  assert.deepEqual(stripRecords(vm).map(r => r.text), ['three']);
});

test('incoming WhatsApp messages create the chat, take the contact name, count as unread and echo to the game chat', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  const first = incoming({ chat: ANA, id: 1, text: 'hola', name: 'Ana', sender: 'Ana', ts: 1700000100 });
  receive(vm, [first]);
  receive(vm, [first]); // the same slot data again must not duplicate it
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 2);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].id'), ANA);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].name'), 'Ana');
  assert.equal(vm.num('#WoWWhatsAppDB.chats[2].history'), 1);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[1].role'), 'contact');
  assert.equal(vm.num('WoWWhatsAppDB.chats[2].history[1].t'), 1700000100, 'the WhatsApp timestamp is kept');
  assert.equal(vm.num('WoWWhatsAppDB.chats[2].unread'), 1);
  const echoed = vm.evaluate('table.concat(STUB.prints, "\\n")');
  assert.ok(echoed.includes('[Ana]') && echoed.includes('hola'), 'whisper-style echo: ' + echoed);
  // A reply to us and a message in a group.
  receive(vm, [
    incoming({ chat: ANA, id: 2, text: 'dime', name: 'Ana', sender: 'Ana', replyTo: 'You' }),
    incoming({ chat: '555@g.us', id: 3, text: 'quien viene', name: 'Raid night', sender: 'Bruno', group: true }),
  ]);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[2].replyTo'), 'You');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[3].name'), 'Raid night');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[3].isGroup'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[3].history[1].sender'), 'Bruno');
  // Opening a chat clears its unread count.
  vm.run(`WoWWhatsApp.SwitchChat("${ANA}")`);
  assert.equal(vm.num('WoWWhatsAppDB.chats[2].unread'), 0);
  // Opening a custom-named chat keeps the name it was given.
  vm.run(`WoWWhatsAppDB.chats[2].name = "Mi Ana"; WoWWhatsAppDB.chats[2].customName = true`);
  receive(vm, [incoming({ chat: ANA, id: 4, text: 'otra', name: 'Ana', sender: 'Ana' })]);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].name'), 'Mi Ana');
});

test('what you type on the phone shows up as your own message, without a notification', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('STUB.prints = {}');
  receive(vm, [incoming({ chat: ANA, id: 1, text: 'sent from my phone', name: 'Ana', fromMe: true })]);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[1].role'), 'user');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].history[1].sent'), 'true');
  assert.equal(vm.num('WoWWhatsAppDB.chats[2].unread'), 0);
  assert.equal(vm.num('#STUB.prints'), 0);
});

test('when the chat list is full the quietest chat makes room for a new contact', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  // 50 chats, each with one message, the first contact's the oldest (Chat 1 was created later).
  for (let i = 1; i <= 49; i++) {
    vm.run(`WoWWhatsApp.NewChat("3460000${String(i).padStart(4, '0')}")`);
    vm.run(`WoWWhatsAppDB.chats[#WoWWhatsAppDB.chats].history = { { role = "contact", text = "m${i}", t = ${1700000000 + i} } }`);
  }
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 50);
  const quietest = vm.evaluate('WoWWhatsAppDB.chats[2].id'); // the first contact: oldest message
  receive(vm, [incoming({ chat: '999@c.us', id: 1, text: 'hola nuevo', name: 'Nuevo' })]);
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 50);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[50].name'), 'Nuevo', 'the new contact got in');
  assert.equal(vm.evaluate(`(function() for _, c in ipairs(WoWWhatsAppDB.chats) do if c.id == "${quietest}" then return "kept" end end return "gone" end)()`), 'gone');
});

test('the chat list is sorted by latest activity, with preview, unread badge and search', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  receive(vm, [
    incoming({ chat: ANA, id: 1, text: 'primero', name: 'Ana', sender: 'Ana', ts: 1700001010 }),
    incoming({ chat: '555@g.us', id: 2, text: 'segundo', name: 'Raid night', sender: 'Bruno', group: true, ts: 1700001020 }),
  ]);
  let list = rows(vm);
  assert.deepEqual(list.map(r => r.split('~').slice(1)), [
    ['Raid night', 'Bruno: segundo', '1'],
    ['Ana', 'primero', '1'],
    ['Chat 1', '', ''],
  ]);
  // A newer message moves its chat to the top.
  receive(vm, [incoming({ chat: ANA, id: 3, text: 'tercero', name: 'Ana', sender: 'Ana', ts: 1700001030 })]);
  assert.deepEqual(rows(vm).map(r => r.split('~')[1]), ['Ana', 'Raid night', 'Chat 1']);
  // Our own message shows as "You: ..." and Sending... while it is on its way.
  vm.run(`WoWWhatsApp.SwitchChat("${ANA}"); WoWWhatsApp.Send("vale")`);
  assert.equal(rows(vm)[0].split('~')[2], '|cffd0d0d0Sending...|r');
  // The search box filters by name.
  vm.run('WoWWhatsAppSearch:SetText("raid"); WoWWhatsAppSearch.scripts.OnTextChanged(WoWWhatsAppSearch)');
  assert.deepEqual(rows(vm).map(r => r.split('~')[1]), ['Raid night']);
});

test('the conversation shows a date pill, bubbles on the right for you and on the left for them, and notes in the middle', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  chatWith(vm);
  receive(vm, [incoming({ chat: ANA, id: 1, text: 'hola', name: 'Ana', sender: 'Ana' })]);
  vm.run('WoWWhatsApp.Send("hola ana")');
  vm.run('WoWWhatsApp.Toggle(true)');
  assert.deepEqual(bubbles(vm), ['mid:Today', 'them:hola', 'me:hola ana']);
  vm.run('SlashCmdList.WOWWHATSAPP("diag")');
  assert.equal(bubbles(vm)[3].split(':')[0], 'mid', 'a system note is centred');
});

test('a restore bundle addressed to this session adds the missing chats once', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  const token = vm.evaluate('WoWWhatsAppDB.session');
  const bundle = `restore = { token = "${token}", chats = { { id = "old1@c.us", name = "Old work", messages = { { role = "user", id = 1, t = 1, text = "q" }, { role = "contact", id = 1, t = 2, sender = "Ana", text = "a" } } } } }`;
  nextSlot(vm, `{ now = time(), replies = {}, ${bundle} }`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 2);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].id'), 'old1@c.us');
  assert.equal(vm.num('#WoWWhatsAppDB.chats[1].history'), 2);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].history[1].role'), 'user');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].history[1].sent'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].history[2].role'), 'contact');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].history[2].sender'), 'Ana');
  assert.equal(vm.evaluate('WoWWhatsAppDB.restored'), 'true');
  // A second bundle with the same token is ignored.
  nextSlot(vm, `{ now = time(), replies = {}, ${bundle.replace('old1', 'old2')} }`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 2);
});

test('chat commands: new <number>, chat, rename, delete, clear, copy', () => {
  const vm = newVM();
  login(vm);
  // A chat is started with a phone number (spaces, dashes and a leading + are fine).
  vm.run('SlashCmdList.WOWWHATSAPP("new +34 600-11 22 33")');
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 2);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].id'), ANA);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].name'), '34600112233');
  assert.equal(vm.evaluate('WoWWhatsAppDB.activeChat'), ANA);
  // The same number again goes to the existing chat.
  vm.run('SlashCmdList.WOWWHATSAPP("chat 1")');
  vm.run('SlashCmdList.WOWWHATSAPP("new 34600112233")');
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 2);
  assert.equal(vm.evaluate('WoWWhatsAppDB.activeChat'), ANA);
  // Anything else is explained, not created.
  vm.run('SlashCmdList.WOWWHATSAPP("new Realms")');
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 2);
  assert.ok(lastMessage(vm, 2).includes('phone number with its country code'));
  vm.run('SlashCmdList.WOWWHATSAPP("chat 1")');
  assert.equal(vm.evaluate('WoWWhatsAppDB.activeChat'), vm.evaluate('WoWWhatsAppDB.chats[1].id'));
  vm.run('SlashCmdList.WOWWHATSAPP("chat 34600112233")');
  assert.equal(vm.evaluate('WoWWhatsAppDB.activeChat'), ANA);
  vm.run('SlashCmdList.WOWWHATSAPP("rename Stuff")');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[2].name'), 'Stuff');
  vm.run('SlashCmdList.WOWWHATSAPP("help")');
  assert.ok(lastMessage(vm, 2).includes('/wa new <phone number>'));
  vm.run('SlashCmdList.WOWWHATSAPP("clear")');
  assert.equal(vm.num('#WoWWhatsAppDB.chats[2].history'), 0);
  vm.run('SlashCmdList.WOWWHATSAPP("delete")');
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 1);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].name'), 'Chat 1');
  // The copy box builds with a proper backdrop (the stub fails on SetBackdrop(nil)).
  vm.run('WoWWhatsApp.ShowCopy("some message")');
  assert.equal(vm.evaluate('WoWWhatsAppCopy.shown'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppCopyBox.text'), 'some message');
});

test('chat rows: right-click opens a menu, rename and delete target the row, delete asks first', () => {
  const vm = newVM();
  login(vm);
  chatWith(vm, '34600000001');
  const first = vm.evaluate('WoWWhatsAppDB.chats[1].id');
  const second = vm.evaluate('WoWWhatsAppDB.chats[2].id');
  assert.equal(vm.evaluate('WoWWhatsAppDB.activeChat'), second);
  // The menu opens for the row's chat, not the active one, and toggles closed on a second open.
  vm.run(`WoWWhatsApp.ShowChatMenu("${first}", WoWWhatsAppFrame)`);
  assert.equal(vm.evaluate('WoWWhatsAppChatMenu.shown'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppChatMenu.chatId'), first);
  assert.equal(vm.evaluate('WoWWhatsAppChatMenu.title.text'), 'Chat 1');
  vm.run(`WoWWhatsApp.ShowChatMenu("${first}", WoWWhatsAppFrame)`);
  assert.equal(vm.evaluate('WoWWhatsAppChatMenu.shown'), 'false');
  // The rename prompt targets the chat it was opened for and marks the name as chosen.
  vm.run(`WoWWhatsApp.RenamePrompt("${first}")`);
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWWHATSAPP_RENAME');
  assert.equal(vm.evaluate('STUB.popup.data.id'), first);
  vm.run(`
    local dialog = { editBox = { GetText = function() return "Old stuff" end } }
    StaticPopupDialogs.WOWWHATSAPP_RENAME.OnAccept(dialog, STUB.popup.data)`);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].name'), 'Old stuff');
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].customName'), 'true');
  // Delete asks first: nothing happens until OK, then only that chat goes and the active one stays.
  vm.run(`WoWWhatsApp.ConfirmDelete("${first}")`);
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWWHATSAPP_DELETE');
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 2);
  vm.run('StaticPopupDialogs.WOWWHATSAPP_DELETE.OnAccept({}, STUB.popup.data)');
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 1);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].id'), second);
  assert.equal(vm.evaluate('WoWWhatsAppDB.activeChat'), second);
  // Deleting the last chat clears it instead of removing it.
  vm.run(`WoWWhatsApp.ConfirmDelete("${second}")`);
  vm.run('StaticPopupDialogs.WOWWHATSAPP_DELETE.OnAccept({}, STUB.popup.data)');
  assert.equal(vm.num('#WoWWhatsAppDB.chats'), 1);
  assert.equal(vm.evaluate('WoWWhatsAppDB.chats[1].name'), 'Chat 1');
});

test('the + button asks for a number and starts that chat', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWWhatsApp.NewChatPrompt()');
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWWHATSAPP_NEW');
  vm.run(`
    local dialog = { editBox = { GetText = function() return "34 600 11 22 33" end } }
    StaticPopupDialogs.WOWWHATSAPP_NEW.OnAccept(dialog)`);
  assert.equal(vm.evaluate('WoWWhatsAppDB.activeChat'), ANA);
});

test('minimize collapses to the mini bar and back; the mini bar X hides everything', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWWhatsApp.Toggle(true)');
  assert.equal(vm.evaluate('WoWWhatsAppFrame.shown'), 'true');
  vm.run('WoWWhatsApp.Minimize(true)');
  assert.equal(vm.evaluate('WoWWhatsAppFrame.shown'), 'false');
  assert.equal(vm.evaluate('WoWWhatsAppMini.shown'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppDB.settings.minimized'), 'true');
  vm.run('WoWWhatsApp.Minimize(false)');
  assert.equal(vm.evaluate('WoWWhatsAppFrame.shown'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppMini.shown'), 'false');
  vm.run('WoWWhatsApp.Toggle(false)');
  assert.equal(vm.evaluate('WoWWhatsAppFrame.shown'), 'false');
  assert.equal(vm.evaluate('WoWWhatsAppMini.shown'), 'false');
  assert.equal(vm.evaluate('WoWWhatsAppDB.settings.shown'), 'false');
});

test('a message that arrives while the window is minimized counts as unread on the mini bar', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('WoWWhatsApp.Toggle(true); WoWWhatsApp.Minimize(true)');
  receive(vm, [incoming({ chat: ANA, id: 1, text: 'hola', name: 'Ana', sender: 'Ana' })]);
  assert.equal(vm.num('WoWWhatsAppDB.chats[2].unread'), 1);
  assert.ok(texts(vm).includes('1 new message'));
  assert.equal(vm.evaluate('WoWWhatsAppMini.shown'), 'true');
});

test('reload mode writes the outbox for the bridge, chat id included, instead of drawing the strip', () => {
  const vm = newVM();
  login(vm);
  chatWith(vm);
  vm.run('SlashCmdList.WOWWHATSAPP("mode reload")');
  vm.run('WoWWhatsApp.Send("via reload")');
  assert.equal(vm.evaluate('STUB.reloaded'), 'true');
  assert.equal(vm.evaluate('WoWWhatsAppDB.outbox.text'), Buffer.from('via reload').toString('hex'));
  assert.equal(vm.evaluate('WoWWhatsAppDB.outbox.chat'), Buffer.from(ANA).toString('hex'));
  assert.equal(decodeStrip(vm), null);
});
