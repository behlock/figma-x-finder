const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const token = 'A'.repeat(64);
const response = (body = {}, status = 200) => ({ ok: status >= 200 && status < 300, status, async json() { return body; } });

function receiver({ storedToken, fetch: customFetch } = {}) {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, { value: '', textContent: '', disabled: false, hidden: true });
    return elements.get(id);
  };
  const storage = new Map(storedToken ? [['connectionKey', storedToken]] : []);
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
    setTimeout, clearTimeout, setInterval() {}, AbortSignal, Uint8Array, TypeError,
    async fetch(url, options) {
      calls.push({ url, options });
      if (customFetch) {
        const result = await customFetch(url, options);
        if (result) return result;
      }
      if (url.endsWith('/v1/pairing/start')) return response({ id: 'random-request-id', code: '123456' });
      if (url.endsWith('/v1/pairing/status')) return response({ state: 'connected', token });
      return response({}, url.includes('/v1/jobs?') ? 204 : 200);
    }
  };
  vm.runInNewContext(fs.readFileSync(`${__dirname}/code.js`, 'utf8'), { figma: plugin, __html__: '' });
  const script = fs.readFileSync(`${__dirname}/ui.html`, 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
  vm.runInNewContext(script, ui);
  return { element, storage, calls };
}

async function flush() { for (let index = 0; index < 5; index++) await new Promise(setImmediate); }

test('first launch offers Connect without a key field or authenticated requests', async () => {
  const { element, calls } = receiver();
  await flush();
  assert.equal(element('name').value, 'Inspo');
  assert.equal(element('status').textContent, 'Connect once to get started.');
  assert.equal(element('connection').hidden, false);
  assert.equal(element('destination').hidden, true);
  assert.equal(element('save').disabled, true);
  assert.equal(calls.length, 0);
  assert.doesNotMatch(fs.readFileSync(`${__dirname}/ui.html`, 'utf8'), /id="key"/);
});

test('local approval persists the credential and enables authenticated frame registration', async () => {
  let approve;
  const { element, calls, storage } = receiver({ fetch(url) {
    if (url.endsWith('/v1/pairing/status')) return new Promise(resolve => { approve = () => resolve(response({ state: 'connected', token })); });
  } });
  await flush();
  const connecting = element('connect').onclick();
  await flush();
  assert.equal(element('pairing-code').textContent, '123456');
  assert.equal(element('pairing-code').hidden, false);
  assert.equal(element('connect').disabled, true);
  assert.equal(storage.has('connectionKey'), false);
  assert.equal(element('save').disabled, true);
  assert.equal(calls.some(call => call.url.includes('/v1/jobs')), false);
  approve();
  await connecting;
  assert.equal(storage.get('connectionKey'), token);
  assert.equal(element('connection').hidden, true);
  assert.equal(element('destination').hidden, false);
  assert.equal(element('save').disabled, false);
  await element('save').onclick();
  const registration = calls.find(call => call.url.endsWith('/v1/destinations'));
  assert.equal(registration.url, 'http://localhost:17847/v1/destinations');
  assert.equal(registration.options.headers.Authorization, `Bearer ${token}`);
  assert.deepEqual(JSON.parse(registration.options.body), { name: 'Inspo', fileKey: 'file123', pageID: '0:1', nodeID: '29:3' });
  assert.equal(element('status').textContent, 'Saved Inspo. Ready for images from Finder.');
});

test('previously paired receivers resume without reconnecting or changing their key', async () => {
  const { element, storage, calls } = receiver({ storedToken: token });
  await flush();
  assert.equal(element('connection').hidden, true);
  assert.equal(element('save').disabled, false);
  assert.equal(storage.get('connectionKey'), token);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.headers.Authorization, `Bearer ${token}`);
});

test('denied approval leaves registration disabled and permits retry', async () => {
  let denied = true;
  const { element, storage } = receiver({ fetch(url) {
    if (denied && url.endsWith('/v1/pairing/status')) return response({ error: 'Connection cancelled. Click Connect to try again.' }, 403);
  } });
  await flush();
  await element('connect').onclick();
  assert.equal(element('status').textContent, 'Connection cancelled. Click Connect to try again.');
  assert.equal(element('save').disabled, true);
  assert.equal(element('connect').disabled, false);
  assert.equal(storage.has('connectionKey'), false);
  denied = false;
  await element('connect').onclick();
  assert.equal(element('save').disabled, false);
});

test('missing app and expired requests give actionable retry messages', async () => {
  let offline = true;
  const { element, storage } = receiver({ fetch(url) {
    if (offline) throw new TypeError('Failed to fetch');
    if (url.endsWith('/v1/pairing/status')) return response({ error: 'Connection request expired. Click Connect to try again.' }, 410);
  } });
  await flush();
  await element('connect').onclick();
  assert.match(element('status').textContent, /Open Figma Finder Bridge on your Mac/);
  offline = false;
  await element('connect').onclick();
  assert.match(element('status').textContent, /expired/);
  assert.equal(storage.has('connectionKey'), false);
  assert.equal(element('connect').disabled, false);
});

test('a stale credential offers reconnection and never permits registration', async () => {
  const { element } = receiver({ storedToken: token, fetch(url) {
    if (url.includes('/v1/jobs')) return response({}, 401);
  } });
  await flush();
  assert.equal(element('connection').hidden, false);
  assert.equal(element('save').disabled, true);
  assert.equal(element('status').textContent, 'Please connect to your Mac again.');
});
