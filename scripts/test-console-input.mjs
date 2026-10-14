import assert from 'node:assert/strict';
import test from 'node:test';
import { trackConsoleKeys } from '../web/src/views/vm/consoleInput.ts';

test('navigation releases all held physical keys before view-only, once', () => {
  const events = [];
  const client = { viewOnly: false, sendKey(key, code, down) { if (!this.viewOnly) events.push([key, code, down]); } };
  const release = trackConsoleKeys(client);
  client.sendKey(0xffe9, 'AltLeft', true);
  client.sendKey(0x61, 'KeyA', true);
  client.sendKey(0x61, 'KeyA', false);
  release(); client.viewOnly = true; release();
  assert.deepEqual(events.at(-1), [0xffe9, 'AltLeft', false]);
  assert.equal(events.length, 4);
});
test('view-only input is not retained and clipboard keys can be released', () => {
  const events = [];
  const client = { viewOnly: true, sendKey(key, code, down) { if (!this.viewOnly) events.push([key, code, down]); } };
  const release = trackConsoleKeys(client);
  client.sendKey(0x61, 'KeyA', true);
  client.viewOnly = false;
  release(); assert.deepEqual(events, []);
  client.sendKey(0x62, undefined, true); release();
  assert.deepEqual(events, [[0x62, undefined, true], [0x62, undefined, false]]);
});
