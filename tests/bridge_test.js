// Unit tests for the bridge's pure protocol code (bridge/protocol.js).
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const os = require('os');
const P = require('../bridge/protocol');

test('luaStr escapes everything Lua 5.1 needs', () => {
  assert.equal(P.luaStr('a"b\\c\nd\re\x01'), '"a\\"b\\\\c\\nde\\001"');
  assert.equal(P.luaStr(null), '""');
  assert.equal(P.luaStr(42), '"42"');
});

test('parseFlags reads new-session, hello, forget and allow lists', () => {
  assert.deepEqual(P.parseFlags(''), { newSession: false, hello: false, forget: false, allow: [] });
  assert.deepEqual(P.parseFlags('n'), { newSession: true, hello: false, forget: false, allow: [] });
  assert.deepEqual(P.parseFlags('h'), { newSession: false, hello: true, forget: false, allow: [] });
  assert.deepEqual(P.parseFlags('d'), { newSession: false, hello: false, forget: true, allow: [] });
  assert.deepEqual(P.parseFlags('n;allow=WebSearch, Bash(git:*),'), { newSession: true, hello: false, forget: false, allow: ['WebSearch', 'Bash(git:*)'] });
});

test('jobsFromStrip parses the current record format and keeps separators inside text', () => {
  const rec = ['sess', 'chat1', '12', 'realms', 'allow=WebSearch', 'My chat', 'hello\x1Fworld'].join('\x1F');
  const jobs = P.jobsFromStrip(12, rec);
  assert.equal(jobs.length, 1);
  assert.deepEqual(jobs[0], { session: 'sess', chat: 'chat1', id: 12, cwd: 'realms', newSession: false, hello: false, forget: false, allow: ['WebSearch'], name: 'My chat', text: 'hello\x1Fworld', via: 'pixel' });
});

test('jobsFromStrip handles several records per frame and older formats', () => {
  const a = ['s', 'c1', '3', '', '', 'A', 'first'].join('\x1F');
  const b = ['s', 'c2', '4', 'C:\\x', 'n', 'second'].join('\x1F'); // no-name format
  const c = ['s', 'C:\\y', '', 'third'].join('\x1F'); // pre-chat format
  const jobs = P.jobsFromStrip(9, [a, b, c].join('\x1E'));
  assert.deepEqual(jobs.map(j => [j.id, j.chat, j.text, j.newSession]), [[3, 'c1', 'first', false], [4, 'c2', 'second', true], [9, '', 'third', false]]);
  assert.deepEqual(P.jobsFromStrip(1, 'garbage'), []);
  assert.deepEqual(P.jobsFromStrip(1, ['s', 'c', 'notanumber', '', '', '', 'x'].join('\x1F')), []);
});

test('parseOutbox decodes the SavedVariables fallback', () => {
  const hex = s => Buffer.from(s, 'utf8').toString('hex');
  const src = `WoWClaudeDB = {\n["outbox"] = {\n["id"] = 7,\n["session"] = "abc123",\n["chat"] = "c1",\n["text"] = "${hex('héllo')}",\n["cwd"] = "${hex('realms')}",\n["newSession"] = true,\n},\n["settings"] = {},\n}`;
  assert.deepEqual(P.parseOutbox(src), { id: 7, session: 'abc123', chat: 'c1', text: 'héllo', cwd: 'realms', newSession: true, via: 'reload' });
  assert.equal(P.parseOutbox('WoWClaudeDB = {}'), null);
  assert.equal(P.parseOutbox('["outbox"] = { ["text"] = "" }'), null);
});

test('resolveCwd: empty is the default, relative joins it, ~ is home, absolute wins', () => {
  const base = path.resolve('C:\\work\\proj');
  assert.equal(P.resolveCwd('', base), base);
  assert.equal(P.resolveCwd('  ', base), base);
  assert.equal(P.resolveCwd('realms', base), path.join(base, 'realms'));
  assert.equal(P.resolveCwd('./realms/', base), path.join(base, 'realms'));
  assert.equal(P.resolveCwd('../other', base), path.resolve(base, '..', 'other'));
  assert.equal(P.resolveCwd('~/x', base), path.join(os.homedir(), 'x'));
  assert.equal(P.resolveCwd('D:\\elsewhere', base), path.resolve('D:\\elsewhere'));
  assert.ok(P.sameFolder('C:\\A\\b\\', 'c:/a/B'));
  assert.ok(!P.sameFolder('C:\\a', 'C:\\a\\b'));
});

test('ruleFor turns denials into prefix rules', () => {
  assert.equal(P.ruleFor({ tool_name: 'WebSearch' }), 'WebSearch');
  assert.equal(P.ruleFor({ tool_name: 'Bash', tool_input: { command: 'cargo build --release' } }), 'Bash(cargo:*)');
  assert.equal(P.ruleFor({ tool_name: 'Bash', tool_input: { command: '"C:\\weird path\\x.exe" arg' } }), 'Bash');
  assert.equal(P.ruleFor({}), 'Unknown');
});

test('describeToolUse gives one short line per tool call', () => {
  assert.equal(P.describeToolUse({ name: 'Bash', input: { command: 'npm test\nsecond line' } }), '$ npm test');
  assert.equal(P.describeToolUse({ name: 'Edit', input: { file_path: 'C:\\x\\player.gd' } }), 'edit player.gd');
  assert.equal(P.describeToolUse({ name: 'Mystery' }), 'Mystery');
});

test('handled ids are tracked per session token and capped', () => {
  const state = { lastId: 0, handled: {}, sessions: {} };
  const job = { session: 's1', id: 5 };
  assert.equal(P.alreadyHandled(state, job), false);
  P.markHandled(state, job, 1000);
  assert.equal(P.alreadyHandled(state, job), true);
  assert.equal(P.alreadyHandled(state, { session: 's2', id: 5 }), false);
  assert.equal(state.lastId, 5);
  assert.equal(state.seen.s1, 1000);
  for (let i = 1; i <= 1200; i++) P.markHandled(state, { session: 's1', id: i });
  assert.ok(Object.keys(state.handled.s1).length <= 1000);
  // Sessionless (inject / very old addon) jobs fall back to the high-water mark.
  assert.equal(P.alreadyHandled(state, { session: '', id: 3 }), true);
  assert.equal(P.alreadyHandled(state, { session: '', id: 5000 }), false);
});

test('pruneStale forgets session tokens not seen for a month', () => {
  const day = 24 * 3600 * 1000;
  const now = 100 * day;
  const state = { lastId: 0, handled: { old: { 1: 1 }, fresh: { 1: 1 }, unknown: { 1: 1 }, '': { 1: 1 } }, seen: { old: now - 40 * day, fresh: now - day } };
  const transcripts = { chats: {}, tokens: { old: now - 40 * day, fresh: now } };
  const removed = P.pruneStale(state, transcripts, now);
  assert.equal(removed, 2);
  assert.deepEqual(Object.keys(state.handled).sort(), ['', 'fresh', 'unknown']);
  assert.equal(state.seen.unknown, now); // grace period starts when first seen by the pruner
  assert.deepEqual(Object.keys(transcripts.tokens), ['fresh']);
});

test('slotNumber wraps and SILENT_WAV is a valid RIFF header', () => {
  assert.equal(P.slotNumber(1, 200), 1);
  assert.equal(P.slotNumber(200, 200), 200);
  assert.equal(P.slotNumber(201, 200), 1);
  assert.equal(P.SILENT_WAV.toString('ascii', 0, 4), 'RIFF');
  assert.equal(P.SILENT_WAV.readUInt32LE(4), P.SILENT_WAV.length - 8);
  assert.equal(P.chatKey({ session: 's', chat: 'c' }), 's:c');
  assert.equal(P.sessKey({ session: 's', chat: 'c' }), 'chat:c');
  assert.equal(P.sessKey({ session: 's', chat: '' }), 's:default');
});
