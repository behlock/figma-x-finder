const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function receiver() {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, { value: '', textContent: '', disabled: true, open: false });
    return elements.get(id);
  };
  const storage = new Map();
  const calls = [];
  const page = { id: '0:1', name: 'Page 1', type: 'PAGE', selection: [] };
  const frame = { id: '29:3', name: 'Inspo', type: 'FRAME', layoutMode: 'NONE', rotation: 0, parent: page };
  page.selection = [frame];
  const root = { type: 'DOCUMENT' }; page.parent = root;
  const plugin = {
    fileKey: 'file123', root, currentPage: page,
    clientStorage: { async getAsync(key) { return storage.get(key); }, async setAsync(key, value) { storage.set(key, value); } },
    ui: { resize() {}, postMessage(message) { ui.window.onmessage({ source: null, data: { pluginMessage: message } }); } },
    showUI() {}
  };
  const ui = {
    document: { getElementById: element }, window: {},
    parent: { postMessage(message) { plugin.ui.onmessage(message.pluginMessage); } },
    setTimeout, clearTimeout, setInterval() {}, AbortSignal, Uint8Array,
    async fetch(url, options) {
      calls.push({ url, options });
      return { ok: true, status: url.includes('/v1/jobs?') ? 204 : 200 };
    }
  };
  vm.runInNewContext(fs.readFileSync(`${__dirname}/code.js`, 'utf8'), { figma: plugin, __html__: '' });
  const script = fs.readFileSync(`${__dirname}/ui.html`, 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
  vm.runInNewContext(script, ui);
  return { element, storage, calls };
}

async function flush() { for (let index = 0; index < 5; index++) await new Promise(setImmediate); }

test('receiver requests bootstrap and accepts replies relayed with a null source', async () => {
  const { element } = receiver();
  await flush();
  assert.equal(element('name').value, 'Inspo');
  assert.equal(element('status').textContent, 'Copy the connection key from the macOS app.');
  assert.equal(element('connection').open, true);
});

test('pairing enables registration of the selected frame through authenticated localhost requests', async () => {
  const { element, calls, storage } = receiver();
  await flush();
  const token = 'A'.repeat(64);
  element('key').value = token;
  await element('connect').onclick();
  assert.equal(storage.get('connectionKey'), token);
  assert.equal(element('save').disabled, false);
  await element('save').onclick();
  const registration = calls.find(call => call.url.endsWith('/v1/destinations'));
  assert.equal(registration.url, 'http://localhost:17847/v1/destinations');
  assert.equal(registration.options.headers.Authorization, `Bearer ${token}`);
  assert.deepEqual(JSON.parse(registration.options.body), { name: 'Inspo', fileKey: 'file123', pageID: '0:1', nodeID: '29:3' });
  assert.equal(element('status').textContent, 'Saved Inspo. Ready for images from Finder.');
});
