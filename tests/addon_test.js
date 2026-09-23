// Runs the real addon Lua (Codec.lua + WoWClaude.lua) in a Lua VM with a stub
// WoW API (wow_stub.lua) and drives it through a session: login, hello, a sent
// message read back off the pixel strip, a reply delivered through a slot, the
// bridge's default folder, a permission denial with Allow, and a restore.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const fengari = require('fengari');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;

const ADDON = path.join(__dirname, '..', 'addon', 'WoWClaude');
const CELLS_PER_ROW = 200;

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
  for (const f of ['Codec.lua', 'Inbox.lua', 'WoWClaude.lua']) run(fs.readFileSync(path.join(ADDON, f), 'utf8'), 'WoWClaude');
  return { run, evaluate, num };
}

// Read the strip the addon drew, exactly like capture.ps1: 3 bits per cell,
// [C7 1A] [id] [len] [payload] [fletcher]. Returns { id, text } or null.
function decodeStrip(vm) {
  if (vm.evaluate('WoWClaudeStrip and WoWClaudeStrip.shown') !== 'true') return null;
  vm.run(`
    local parts = {}
    for _, t in ipairs(WoWClaudeStrip.textures) do
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

function stripRecords(vm) {
  const frame = decodeStrip(vm);
  if (!frame) return [];
  return frame.text.split('\x1E').map(r => {
    const p = r.split('\x1F');
    return { session: p[0], chat: p[1], id: Number(p[2]), cwd: p[3], flags: p[4], name: p[5], text: p.slice(6).join('\x1F') };
  });
}

// Make the next LoadAddOn deliver this slot data (a Lua table literal body).
function nextSlot(vm, luaBody) {
  vm.run(`STUB.onLoadAddOn = function(name) WoWClaude_SlotData = ${luaBody} end`);
}

function login(vm) {
  vm.run('STUB.FireEvent("ADDON_LOADED", "WoWClaude")');
  vm.run('STUB.FireEvent("PLAYER_LOGIN")');
}

// Let the bridge answer the login hello: its slot carries a fresh clock, which is
// what makes the addon consider itself connected (Send is gated on that).
function connect(vm) {
  vm.run('STUB.RunTimers()'); // C_Timer.After(3, SayHello)
  nextSlot(vm, '{ now = time(), cwd = "", replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()'); // hello poll 5 s later
  assert.equal(vm.evaluate('WoWClaude.IsConnected()'), 'true', 'connected after the hello slot');
}

test('addon loads, builds its UI and creates a first chat', () => {
  const vm = newVM();
  login(vm);
  assert.equal(vm.num('#WoWClaudeDB.chats'), 1);
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].name'), 'Chat 1');
  assert.equal(vm.evaluate('WoWClaudeFrame ~= nil'), 'true');
  assert.equal(vm.evaluate('WoWClaudeMini ~= nil'), 'true');
  assert.equal(vm.num('#STUB.tickers'), 1);
  assert.equal(vm.evaluate('SlashCmdList.WOWCLAUDE ~= nil'), 'true');
  assert.equal(vm.evaluate('SlashCmdList.CLAUDEASK ~= nil'), 'true');
});

test('hello goes out on the strip after login', () => {
  const vm = newVM();
  login(vm);
  vm.run('STUB.RunTimers()'); // C_Timer.After(3, SayHello)
  const recs = stripRecords(vm);
  assert.equal(recs.length, 1);
  assert.equal(recs[0].flags, 'h');
  assert.equal(recs[0].text, '');
  assert.equal(recs[0].session, vm.evaluate('WoWClaudeDB.session'));
});

test('deleting a chat tells the bridge to forget it, and a restore never brings it back', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('WoWClaude.NewChat("Second")');
  assert.equal(vm.num('#WoWClaudeDB.chats'), 2);
  const gone = vm.evaluate('WoWClaudeDB.chats[2].id');
  vm.run(`WoWClaude.DeleteChat("${gone}")`);
  assert.equal(vm.num('#WoWClaudeDB.chats'), 1);
  // A forget record for that chat is on the strip and remembered until acked.
  const rec = stripRecords(vm).find(r => r.flags === 'd');
  assert.ok(rec, 'forget record on the strip');
  assert.equal(rec.chat, gone);
  assert.equal(rec.text, '');
  assert.equal(vm.evaluate(`WoWClaudeDB.forget["${gone}"] ~= nil`), 'true');
  // A restore that still lists the chat is ignored for it.
  const token = vm.evaluate('WoWClaudeDB.session');
  nextSlot(vm, `{ now = time(), cwd = "", replies = {}, restore = { token = "${token}", chats = { { id = "${gone}", name = "Second", cwd = "", messages = { { role = "user", text = "old", id = 1, t = 1 } } } } } }`);
  vm.run('WoWClaude.Connect(); STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.num('#WoWClaudeDB.chats'), 1, 'deleted chat not restored');
  // The bridge acks the forget record: it leaves the strip and the memory.
  const slot = String(rec.id).padStart(3, '0');
  vm.run(`STUB.sounds["Interface\\\\AddOns\\\\WoWClaude\\\\ack\\\\${slot}.wav"] = true; STUB.Tick()`);
  assert.equal(vm.evaluate(`WoWClaudeDB.forget["${gone}"]`), null, 'forgotten once acked');
  assert.ok(!stripRecords(vm).find(r => r.flags === 'd'), 'forget record left the strip');
});

test('until the bridge answers, Connect replaces Send and a message stays in the box', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWClaude.Toggle(true)');
  assert.equal(vm.evaluate('WoWClaude.IsConnected()'), 'false');
  const texts = () => vm.evaluate('table.concat(STUB.texts, "|")');
  assert.ok(texts().includes('Not connected - start the bridge, then click Connect'));
  // Sending while disconnected puts the text back in the box and starts a connect attempt.
  vm.run('WoWClaudeInput:SetText("fix the bug"); WoWClaude.SendFromInput()');
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].pendingId'), null, 'nothing sent');
  assert.equal(vm.evaluate('WoWClaudeInput:GetText()'), 'fix the bug', 'message kept in the box');
  const hello = stripRecords(vm);
  assert.equal(hello.length, 1);
  assert.equal(hello[0].flags, 'h', 'a hello went out instead');
  assert.ok(texts().includes('Connecting...'));
  assert.ok(texts().includes('your message goes out as soon as it answers'));
  // No answer within CONNECT_WAIT: the attempt is reported as failed, Connect is back.
  vm.run('STUB.now = STUB.now + 20; STUB.Tick()');
  assert.equal(vm.evaluate('WoWClaude.IsConnected()'), 'false');
  assert.ok(texts().includes('No answer from the bridge'));
  assert.equal(vm.evaluate('WoWClaudeInput:GetText()'), 'fix the bug', 'message still in the box after a failed attempt');
  // Click Connect again; this time the bridge answers the hello poll. Nothing was
  // queued by that click, so the message waits for the user.
  vm.run('WoWClaude.Connect()');
  nextSlot(vm, '{ now = time(), cwd = "C:\\\\proj", replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWClaude.IsConnected()'), 'true');
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].pendingId'), null, 'a plain Connect sends nothing by itself');
  vm.run('WoWClaude.SendFromInput()');
  assert.ok(vm.num('WoWClaudeDB.chats[1].pendingId') >= 1, 'the kept message goes out once connected');
  assert.ok(stripRecords(vm).find(r => r.text === 'fix the bug'));
});

test('a message sent while disconnected goes out by itself once the bridge answers', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWClaude.Toggle(true)');
  vm.run('WoWClaudeInput:SetText("fix the bug"); WoWClaude.SendFromInput()');
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].pendingId'), null, 'nothing sent yet');
  // The bridge answers the hello poll: the queued message follows without a second click.
  nextSlot(vm, '{ now = time(), cwd = "C:\\\\proj", replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWClaude.IsConnected()'), 'true');
  assert.ok(vm.num('WoWClaudeDB.chats[1].pendingId') >= 1, 'queued message went out on connect');
  assert.ok(stripRecords(vm).find(r => r.text === 'fix the bug'));
  assert.equal(vm.evaluate('WoWClaudeInput:GetText()'), '', 'box cleared after the auto-send');
  // Only once: a later reconnect sends nothing.
  vm.run('WoWClaude.Connect()');
  nextSlot(vm, '{ now = time(), cwd = "C:\\\\proj", replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(stripRecords(vm).filter(r => r.text === 'fix the bug').length, 1);
});

test('without the sound channel, the light stays green between idle slot polls', () => {
  // The stub has no ctl/valid.wav, so the login self-test disables the sound
  // channel: the addon is in "slot checks only" mode, like a client whose
  // PlaySoundFile reports every file as playable.
  const vm = newVM();
  login(vm);
  connect(vm);
  assert.equal(vm.evaluate('WoWClaude.BridgeState()'), 'ok');
  // 90 s of silence used to mean "stale"; with no beats to hear that is normal.
  vm.run('STUB.now = STUB.now + 200; STUB.Tick()');
  assert.equal(vm.evaluate('WoWClaude.BridgeState()'), 'ok', 'still green after 200 s');
  assert.equal(vm.evaluate('WoWClaude.IsConnected()'), 'true');
  // 10 minutes in, the idle poll spends a slot; the bridge's clock in it keeps the light green.
  vm.run('STUB.loadCount = 0; STUB.onLoadAddOn = function(name) STUB.loadCount = STUB.loadCount + 1; WoWClaude_SlotData = { now = time(), cwd = "", replies = {} } end');
  vm.run('STUB.now = STUB.now + 410; STUB.Tick()');
  assert.equal(vm.num('STUB.loadCount'), 1, 'one idle poll');
  assert.equal(vm.evaluate('WoWClaude.BridgeState()'), 'ok', 'green again after the idle poll');
  // A bridge that really is gone still shows: no slot answers, and the light drops.
  vm.run('STUB.onLoadAddOn = function(name) WoWClaude_SlotData = nil end');
  vm.run('STUB.now = STUB.now + 800; STUB.Tick()');
  assert.equal(vm.evaluate('WoWClaude.BridgeState()'), 'stale');
  vm.run('STUB.now = STUB.now + 700; STUB.Tick()');
  assert.equal(vm.evaluate('WoWClaude.BridgeState()'), 'down');
});

test('the Folder... menu item (right-click a chat) opens a prompt that sets the chat folder like /wow-claude cd', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWClaude.FolderPrompt()');
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWCLAUDE_FOLDER');
  assert.equal(vm.evaluate('STUB.popup.data.cwd'), '');
  // Accept the dialog the way the game would: an edit box holding the new path.
  vm.run(`
    local dialog = { editBox = { GetText = function() return "  ..\\\\realms " end } }
    StaticPopupDialogs.WOWCLAUDE_FOLDER.OnAccept(dialog, STUB.popup.data)`);
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].cwd'), '..\\realms');
  assert.ok(vm.evaluate('WoWClaudeDB.chats[1].history[#WoWClaudeDB.chats[1].history].text').includes('relative to'));
  vm.run('WoWClaude.FolderPrompt()');
  assert.equal(vm.evaluate('STUB.popup.data.cwd'), '..\\realms', 'prompt is prefilled with the current folder');
  // A full path gets no "relative to" note; empty goes back to the default.
  vm.run('WoWClaude.SetFolder("C:\\\\other")');
  assert.ok(!vm.evaluate('WoWClaudeDB.chats[1].history[#WoWClaudeDB.chats[1].history].text').includes('relative to'));
  vm.run('WoWClaude.SetFolder("")');
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].cwd'), '');
});

test('a sent message is encoded on the strip with the chat folder, then a slot reply finishes it', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('SlashCmdList.WOWCLAUDE("cd realms")');
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].cwd'), 'realms');
  vm.run('WoWClaude.Send("hello world")');
  const chatId = vm.evaluate('WoWClaudeDB.chats[1].id');
  const id = vm.num('WoWClaudeDB.chats[1].pendingId');
  assert.ok(id >= 1);
  const rec = stripRecords(vm).find(r => r.text === 'hello world');
  assert.ok(rec, 'message record on the strip');
  assert.equal(rec.chat, chatId);
  assert.equal(rec.id, id);
  assert.equal(rec.cwd, 'realms');
  assert.equal(rec.flags, '');
  // The chat took its title from the first message.
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].name'), 'Hello world');

  nextSlot(vm, `{ now = time(), cwd = "C:\\\\proj", replies = { { chat = "${chatId}", id = ${id}, status = "done", text = "hi back", cwd = "x", session = "s" } } }`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()'); // first scheduled poll is 5 s after sending
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].pendingId'), null);
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].history[#WoWClaudeDB.chats[1].history].role'), 'claude');
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].history[#WoWClaudeDB.chats[1].history].text'), 'hi back');
  assert.ok(vm.evaluate('table.concat(STUB.prints, "\\n")').includes('hi back'), 'reply echoed to the game chat');
  assert.equal(vm.evaluate('WoWClaudeStrip.shown'), 'false', 'strip cleared once nothing is pending');

  // The bridge's default folder arrived with the slot and is what "/wow-claude cd" reports.
  vm.run('SlashCmdList.WOWCLAUDE("cd")');
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].cwd'), '');
  assert.ok(vm.evaluate('WoWClaudeDB.chats[1].history[#WoWClaudeDB.chats[1].history].text').includes('C:\\proj'));
});

test('a denied reply shows Allow, and Allow resends with the rules as flags', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('WoWClaude.Send("search for it")');
  const chatId = vm.evaluate('WoWClaudeDB.chats[1].id');
  const id = vm.num('WoWClaudeDB.chats[1].pendingId');
  nextSlot(vm, `{ now = time(), cwd = "", replies = { { chat = "${chatId}", id = ${id}, status = "done", text = "need permission", denied = { "WebSearch", "Bash(cargo:*)" } } } }`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].history[#WoWClaudeDB.chats[1].history].denied[2]'), 'Bash(cargo:*)');
  vm.run(`WoWClaude.Allow("${chatId}", { "WebSearch", "Bash(cargo:*)" })`);
  const rec = stripRecords(vm).find(r => r.flags.includes('allow='));
  assert.ok(rec, 'allow record on the strip');
  assert.equal(rec.flags, 'allow=WebSearch,Bash(cargo:*)');
  assert.equal(rec.id, id + 1);
});

test('/wow-claude reset marks the next message as a new session', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('SlashCmdList.WOWCLAUDE("reset")');
  vm.run('WoWClaude.Send("start over")');
  const rec = stripRecords(vm).find(r => r.text === 'start over');
  assert.equal(rec.flags, 'n');
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].resetNext'), null);
});

test('a restore bundle addressed to this session adds the missing chats once', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('WoWClaude.Send("hi")');
  const chatId = vm.evaluate('WoWClaudeDB.chats[1].id');
  const id = vm.num('WoWClaudeDB.chats[1].pendingId');
  const token = vm.evaluate('WoWClaudeDB.session');
  const bundle = `restore = { token = "${token}", chats = { { id = "old1", name = "Old work", cwd = "C:\\\\old", messages = { { role = "user", id = 1, t = 1, text = "q" }, { role = "claude", id = 1, t = 2, text = "a" } } } } }`;
  nextSlot(vm, `{ now = time(), cwd = "", replies = { { chat = "${chatId}", id = ${id}, status = "done", text = "ok" } }, ${bundle} }`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.num('#WoWClaudeDB.chats'), 2);
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].id'), 'old1');
  assert.equal(vm.num('#WoWClaudeDB.chats[1].history'), 2);
  assert.equal(vm.evaluate('WoWClaudeDB.restored'), 'true');
  // A second bundle with the same token is ignored.
  vm.run('WoWClaude.Send("again")');
  const id2 = vm.num('WoWClaudeDB.chats[2].pendingId');
  nextSlot(vm, `{ now = time(), cwd = "", replies = { { chat = "${chatId}", id = ${id2}, status = "done", text = "ok" } }, ${bundle.replace('old1', 'old2')} }`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.num('#WoWClaudeDB.chats'), 2);
});

test('chat management commands: new, chat, rename, delete, clear, copy', () => {
  const vm = newVM();
  login(vm);
  vm.run('SlashCmdList.WOWCLAUDE("new Realms")');
  assert.equal(vm.num('#WoWClaudeDB.chats'), 2);
  assert.equal(vm.evaluate('WoWClaudeDB.chats[2].name'), 'Realms');
  assert.equal(vm.evaluate('WoWClaudeDB.activeChat'), vm.evaluate('WoWClaudeDB.chats[2].id'));
  vm.run('SlashCmdList.WOWCLAUDE("chat 1")');
  assert.equal(vm.evaluate('WoWClaudeDB.activeChat'), vm.evaluate('WoWClaudeDB.chats[1].id'));
  vm.run('SlashCmdList.WOWCLAUDE("rename Stuff")');
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].name'), 'Stuff');
  vm.run('SlashCmdList.WOWCLAUDE("help")');
  assert.ok(vm.evaluate('WoWClaudeDB.chats[1].history[1].text').includes('/wow-claude cd'));
  vm.run('SlashCmdList.WOWCLAUDE("clear")');
  assert.equal(vm.num('#WoWClaudeDB.chats[1].history'), 0);
  vm.run('SlashCmdList.WOWCLAUDE("delete")');
  assert.equal(vm.num('#WoWClaudeDB.chats'), 1);
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].name'), 'Realms');
  // The copy box builds with a proper backdrop (the stub fails on SetBackdrop(nil)).
  vm.run('WoWClaude.ShowCopy("some reply")');
  assert.equal(vm.evaluate('WoWClaudeCopy.shown'), 'true');
  assert.equal(vm.evaluate('WoWClaudeCopyBox.text'), 'some reply');
});

test('chat rows: right-click opens a menu that renames or sets the folder of that chat, the trash can asks before deleting', () => {
  const vm = newVM();
  login(vm);
  vm.run('SlashCmdList.WOWCLAUDE("new Realms")');
  const first = vm.evaluate('WoWClaudeDB.chats[1].id');
  const second = vm.evaluate('WoWClaudeDB.chats[2].id');
  assert.equal(vm.evaluate('WoWClaudeDB.activeChat'), second);
  // The menu opens for the row's chat, not the active one, and toggles closed on a second open.
  vm.run(`WoWClaude.ShowChatMenu("${first}", WoWClaudeFrame)`);
  assert.equal(vm.evaluate('WoWClaudeChatMenu.shown'), 'true');
  assert.equal(vm.evaluate('WoWClaudeChatMenu.chatId'), first);
  assert.equal(vm.evaluate('WoWClaudeChatMenu.title.text'), 'Chat 1');
  vm.run(`WoWClaude.ShowChatMenu("${first}", WoWClaudeFrame)`);
  assert.equal(vm.evaluate('WoWClaudeChatMenu.shown'), 'false');
  // Rename and Folder prompts target the chat they were opened for.
  vm.run(`WoWClaude.RenamePrompt("${first}")`);
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWCLAUDE_RENAME');
  assert.equal(vm.evaluate('STUB.popup.data.id'), first);
  vm.run(`
    local dialog = { editBox = { GetText = function() return "Old stuff" end } }
    StaticPopupDialogs.WOWCLAUDE_RENAME.OnAccept(dialog, STUB.popup.data)`);
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].name'), 'Old stuff');
  assert.equal(vm.evaluate('WoWClaudeDB.chats[2].name'), 'Realms');
  vm.run(`WoWClaude.FolderPrompt("${first}")`);
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWCLAUDE_FOLDER');
  assert.equal(vm.evaluate('STUB.popup.data.id'), first);
  // The X asks first: nothing happens until OK, then only that chat goes and the active one stays.
  vm.run(`WoWClaude.ConfirmDelete("${first}")`);
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWCLAUDE_DELETE');
  assert.equal(vm.num('#WoWClaudeDB.chats'), 2);
  vm.run('StaticPopupDialogs.WOWCLAUDE_DELETE.OnAccept({}, STUB.popup.data)');
  assert.equal(vm.num('#WoWClaudeDB.chats'), 1);
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].id'), second);
  assert.equal(vm.evaluate('WoWClaudeDB.activeChat'), second);
  // Deleting the last chat clears it instead of removing it.
  vm.run(`WoWClaude.ConfirmDelete("${second}")`);
  vm.run('StaticPopupDialogs.WOWCLAUDE_DELETE.OnAccept({}, STUB.popup.data)');
  assert.equal(vm.num('#WoWClaudeDB.chats'), 1);
  assert.equal(vm.evaluate('WoWClaudeDB.chats[1].name'), 'Chat 1');
});

test('minimize collapses to the mini bar and back; the mini bar X hides everything', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWClaude.Toggle(true)');
  assert.equal(vm.evaluate('WoWClaudeFrame.shown'), 'true');
  vm.run('WoWClaude.Minimize(true)');
  assert.equal(vm.evaluate('WoWClaudeFrame.shown'), 'false');
  assert.equal(vm.evaluate('WoWClaudeMini.shown'), 'true');
  assert.equal(vm.evaluate('WoWClaudeDB.settings.minimized'), 'true');
  vm.run('WoWClaude.Minimize(false)');
  assert.equal(vm.evaluate('WoWClaudeFrame.shown'), 'true');
  assert.equal(vm.evaluate('WoWClaudeMini.shown'), 'false');
  vm.run('WoWClaude.Toggle(false)');
  assert.equal(vm.evaluate('WoWClaudeFrame.shown'), 'false');
  assert.equal(vm.evaluate('WoWClaudeMini.shown'), 'false');
  assert.equal(vm.evaluate('WoWClaudeDB.settings.shown'), 'false');
});

test('reload mode writes the outbox for the bridge instead of drawing the strip', () => {
  const vm = newVM();
  login(vm);
  vm.run('SlashCmdList.WOWCLAUDE("mode reload")');
  vm.run('SlashCmdList.WOWCLAUDE("reset")');
  vm.run('WoWClaude.Send("via reload")');
  assert.equal(vm.evaluate('STUB.reloaded'), 'true');
  assert.equal(vm.evaluate('WoWClaudeDB.outbox.newSession'), 'true');
  assert.equal(vm.evaluate('WoWClaudeDB.outbox.text'), Buffer.from('via reload').toString('hex'));
  assert.equal(decodeStrip(vm), null);
});
