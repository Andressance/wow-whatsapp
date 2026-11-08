// A slot file carrying messages, an error and a restore bundle must be valid Lua
// that the addon can read back field by field.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const luaparse = require('luaparse');
const P = require('../bridge/protocol');

// Undo luaStr's escapes: \\ \" \n and \ddd (a raw tab is legal in a Lua literal).
function luaUnescape(s) {
  return s.replace(/\\(\d{1,3}|.)/g, (_, e) => /^\d/.test(e) ? String.fromCharCode(Number(e)) : e === 'n' ? '\n' : e);
}

// Walk a luaparse table AST into plain JS values.
function value(node) {
  if (node.type === 'TableConstructorExpression') {
    const out = {};
    const arr = [];
    for (const f of node.fields) {
      if (f.type === 'TableKeyString') out[f.key.name] = value(f.value);
      else arr.push(value(f.value));
    }
    return arr.length ? arr : out;
  }
  if (node.type === 'StringLiteral') return luaUnescape(node.raw.slice(1, -1));
  if (node.type === 'NumericLiteral') return node.value;
  if (node.type === 'BooleanLiteral') return node.value;
  return null;
}

function readSlot(src, globalName) {
  const ast = luaparse.parse(src, { luaVersion: '5.1' });
  const assign = ast.body.find(n => n.type === 'AssignmentStatement' && n.variables[0].name === globalName);
  assert.ok(assign, globalName + ' assignment present');
  return value(assign.init[0]);
}

test('slot file round-trips messages, flags and a restore bundle', () => {
  const restore = {
    token: 'tok1',
    chats: [{ id: 'c1@c.us', name: 'realms', messages: [
      { role: 'user', id: 1, t: 1, text: 'hi "there"\nnew line' },
      { role: 'contact', id: 1, t: 2, sender: 'Ana', replyTo: 'You', text: 'hello | pipe \\ backslash' },
    ] }],
  };
  const lua = P.luaTable('WoWWhatsApp_SlotData',
    [
      { chat: 'c9@g.us', id: 3, status: 'incoming', text: 'ok\ttab', isGroup: true, sender: 'Ana', timestamp: 1700000099 },
      { chat: 'c9@g.us', id: 4, status: 'incoming', text: 'from my phone', fromMe: true },
      { chat: 'c9@g.us', id: 5, status: 'error', text: 'WhatsApp is not connected' },
    ],
    { restore, now: 1700000000123 });
  const d = readSlot(lua, 'WoWWhatsApp_SlotData');
  assert.equal(d.now, 1700000000);
  assert.equal(d.replies.length, 3);
  assert.equal(d.replies[0].text, 'ok\ttab');
  assert.equal(d.replies[0].isGroup, true);
  assert.equal(d.replies[0].timestamp, 1700000099);
  assert.equal(d.replies[0].fromMe, undefined);
  assert.equal(d.replies[1].fromMe, true);
  assert.equal(d.replies[1].timestamp, undefined);
  assert.equal(d.replies[2].status, 'error');
  assert.equal(d.restore.token, 'tok1');
  assert.equal(d.restore.chats.length, 1);
  assert.equal(d.restore.chats[0].messages[0].text, 'hi "there"\nnew line');
  assert.equal(d.restore.chats[0].messages[1].text, 'hello | pipe \\ backslash');
  assert.equal(d.restore.chats[0].messages[1].sender, 'Ana');
});

test('slot file without a restore has no restore field and tolerates empty records', () => {
  const d = readSlot(P.luaTable('WoWWhatsApp_Inbox', []), 'WoWWhatsApp_Inbox');
  assert.equal(d.restore, undefined);
  assert.deepEqual(d.replies, {}); // an empty Lua table
});
