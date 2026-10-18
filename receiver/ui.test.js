const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const token = 'A'.repeat(64);
const response = (body = {}, status = 200) => ({ ok: status >= 200 && status < 300, status, async json() { return body; } });

function receiver({ storedToken, fetch: customFetch } = {}) {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, { value: '', textContent: '', disabled: false, hidden: true, dataset: {} });
    return elements.get(id);
  };
  const storage = new Map(storedToken ? [['connectionKey', storedToken]] : []);
  const calls = [];
  const destinations = new Map();
  let destinationSequence = 0;
  const target = destination => `${destination.fileKey}/${destination.nodeID ? `frame/${destination.nodeID}` : `page/${destination.pageID}`}`;
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
    parent: { postMessage({ pluginMessage: message }) {
      if (message.type === 'prepare') plugin.ui.postMessage({ type: 'reply', requestID: message.requestID, result: { existing: message.job.images.map(image => image.id) } });
      else plugin.ui.onmessage(message);
    } },
    setTimeout, clearTimeout, setInterval() {}, AbortSignal, Uint8Array, TypeError,
    async fetch(url, options) {
      calls.push({ url, options });
      if (customFetch) {
        const result = await customFetch(url, options);
        if (result) return result;
      }
      if (url.endsWith('/v1/pairing/start')) return response({ id: 'random-request-id', code: '123456' });
      if (url.endsWith('/v1/pairing/status')) return response({ state: 'connected', token });
      if (url.endsWith('/v1/destinations')) {
        const destination = JSON.parse(options.body);
        const key = target(destination);
        const previous = destinations.get(key);
        destination.id = previous?.id || `destination-${++destinationSequence}`;
        destinations.set(key, destination);
        return response({ destination, previousName: previous?.name });
      }
      if (url.endsWith('/v1/destinations/undo')) {
        const { destination, previousName } = JSON.parse(options.body);
        const key = target(destination);
        if (previousName === undefined) destinations.delete(key);
        else destinations.set(key, { ...destination, name: previousName });
        return response({}, 204);
      }
      return response({}, url.includes('/v1/jobs?') ? 204 : 200);
    }
  };
  vm.runInNewContext(fs.readFileSync(`${__dirname}/code.js`, 'utf8'), { figma: plugin, __html__: '' });
  const script = fs.readFileSync(`${__dirname}/ui.html`, 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
  vm.runInNewContext(script, ui);
  return { element, storage, calls, destinations, frame, poll: ui.poll };
}

async function flush() { for (let index = 0; index < 5; index++) await new Promise(setImmediate); }

test('first launch offers Connect without a key field or authenticated requests', async () => {
  const { element, calls } = receiver();
  await flush();
  assert.equal(element('name').value, 'Inspo');
  assert.equal(element('status').textContent, '');
  assert.equal(element('connection').hidden, false);
  assert.equal(element('destination').hidden, true);
  assert.equal(element('save').disabled, true);
  assert.equal(calls.length, 0);
  assert.doesNotMatch(fs.readFileSync(`${__dirname}/ui.html`, 'utf8'), /id="key"/);
});

test('local approval persists the credential and enables authenticated frame registration', async () => {
  let approve;
  const { element, calls, storage, frame, poll } = receiver({ fetch(url) {
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
  frame.layoutMode = 'HORIZONTAL';
  await element('save').onclick();
  const registration = calls.find(call => call.url.endsWith('/v1/destinations'));
  assert.equal(registration.url, 'http://localhost:17847/v1/destinations');
  assert.equal(registration.options.headers.Authorization, `Bearer ${token}`);
  assert.deepEqual(JSON.parse(registration.options.body), { name: 'Inspo', fileKey: 'file123', pageID: '0:1', nodeID: '29:3' });
  assert.equal(element('status').textContent, '');
  assert.equal(element('save').dataset.phase, 'saved');
  await poll();
  assert.equal(element('status').textContent, '');
  element('name').value = 'References';
  element('name').oninput();
  assert.equal(element('save').dataset.phase, 'ready');
  assert.equal(element('save').disabled, false);
  element('name').onkeydown({ key: 'Enter', preventDefault() {} });
  await flush();
  assert.equal(element('save').dataset.phase, 'saved');
  assert.equal(element('status').textContent, '');
  assert.equal(JSON.parse(calls.filter(call => call.url.endsWith('/v1/destinations')).at(-1).options.body).name, 'References');
});

test('previously paired receivers resume without reconnecting or changing their key', async () => {
  const { element, storage, calls } = receiver({ storedToken: token });
  await flush();
  assert.equal(element('connection').hidden, true);
  assert.equal(element('save').disabled, false);
  assert.equal(element('status').textContent, '');
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
  assert.match(element('status').textContent, /Open Figma x Finder on your Mac/);
  assert.equal(element('status').dataset.warning, 'true');
  assert.equal(element('save').dataset.phase, 'warning');
  assert.equal(element('pairing-help').hidden, true);
  offline = false;
  await element('connect').onclick();
  assert.match(element('status').textContent, /expired/);
  assert.equal(element('status').dataset.warning, 'false');
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


test('delivery finishes without a status caption or an activity log', async () => {
  let queued = true;
  let acknowledge;
  const { element, calls, poll } = receiver({ storedToken: token, fetch(url) {
    if (queued && url.includes('/v1/jobs?')) {
      queued = false;
      return response({ id: 'batch1', destination: { name: 'Inspo' }, images: [{ id: 'image1', name: 'reference.png' }], completed: [] });
    }
    if (url.endsWith('/v1/ack')) return new Promise(resolve => { acknowledge = () => resolve(response({}, 204)); });
  } });
  await flush();
  assert.equal(element('save').dataset.phase, 'busy');
  assert.equal(element('save').disabled, true);
  acknowledge();
  await flush();
  assert.equal(element('status').textContent, '');
  assert.equal(element('save').dataset.phase, 'ready');
  assert.ok(calls.some(call => call.url.endsWith('/v1/ack')));
  await poll();
  assert.equal(element('status').textContent, '');
  await poll();
  assert.equal(element('status').textContent, '');
});

test('destination errors stay in the icon and tooltip until a successful save', async () => {
  const { element, frame, poll } = receiver({ storedToken: token });
  await flush();
  frame.locked = true;
  await element('save').onclick();
  assert.match(element('status').textContent, /unlocked/);
  assert.equal(element('save').dataset.phase, 'error');
  assert.match(element('save').title, /unlocked/);
  await poll();
  assert.match(element('status').textContent, /unlocked/);
  element('name').oninput();
  assert.equal(element('save').dataset.phase, 'ready');
  assert.equal(element('status').textContent, '');
  frame.locked = false;
  await element('save').onclick();
  assert.equal(element('status').textContent, '');
  assert.equal(element('save').dataset.phase, 'saved');
});

test('saving locks the name until completion and recovers cleanly from a failed request', async () => {
  let finishSave;
  let fail = false;
  const { element, calls } = receiver({ storedToken: token, fetch(url, options) {
    if (url.endsWith('/v1/destinations')) {
      if (fail) throw new TypeError('Failed to fetch');
      return new Promise(resolve => { finishSave = () => resolve(response({ destination: { ...JSON.parse(options.body), id: 'saved' } })); });
    }
  } });
  await flush();
  const saving = element('save').onclick();
  await flush();
  assert.equal(element('name').disabled, true);
  assert.equal(element('save').dataset.phase, 'busy');
  await element('save').onclick();
  assert.equal(calls.filter(call => call.url.endsWith('/v1/destinations')).length, 1);
  finishSave();
  await saving;
  assert.equal(element('name').disabled, false);
  assert.equal(element('save').disabled, false);
  assert.equal(element('save').dataset.phase, 'saved');
  element('name').oninput();
  fail = true;
  await element('save').onclick();
  assert.equal(element('name').disabled, false);
  assert.equal(element('save').dataset.phase, 'warning');
  assert.equal(element('save').title, 'Open Figma x Finder on your Mac.');
});

test('the tick undoes creation or renaming and can be retried after failure', async () => {
  let failUndo = false;
  const { element, destinations } = receiver({ storedToken: token, fetch(url) {
    if (failUndo && url.endsWith('/v1/destinations/undo')) return response({ error: 'Try again.' }, 409);
  } });
  await flush();
  const save = element('save');
  await save.onclick();
  assert.equal(save.ariaLabel, 'Undo save');
  assert.equal(destinations.size, 1);
  failUndo = true;
  await save.onclick();
  assert.equal(save.dataset.phase, 'error');
  assert.equal(save.ariaLabel, 'Undo save');
  assert.equal(element('status').textContent, 'Try again.');
  assert.equal(destinations.size, 1);
  failUndo = false;
  await save.onclick();
  assert.equal(save.dataset.phase, 'ready');
  assert.equal(save.ariaLabel, 'Save destination');
  assert.equal(element('status').textContent, '');
  assert.equal(destinations.size, 0);
  await save.onclick();
  element('name').value = 'References';
  element('name').oninput();
  await save.onclick();
  assert.equal([...destinations.values()][0].name, 'References');
  await save.onclick();
  assert.equal([...destinations.values()][0].name, 'Inspo');
  assert.equal(element('name').value, 'Inspo');
  assert.equal(save.dataset.phase, 'ready');
});
