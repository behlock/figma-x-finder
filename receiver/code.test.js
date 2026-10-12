const { test } = require('node:test');
const assert = require('node:assert/strict');
const { importImage, resolveDestination, validateContainer } = require('./code');

let counter;
class Node {
  constructor(type, id) {
    this.type = type; this.id = id || `test:${++counter}`; this.name = type;
    this.children = []; this.data = {}; this.x = 0; this.y = 0;
    this._width = 100; this._height = 100; this.rotation = 0;
    this.layoutMode = 'NONE'; this.locked = false; this.visible = true;
    this.clipsContent = false; this.itemSpacing = 0;
  }
  get width() {
    if (this.layoutMode === 'HORIZONTAL') return this.children.reduce((sum, node) => sum + node.width, 0) + Math.max(0, this.children.length - 1) * this.itemSpacing;
    if (this.layoutMode === 'VERTICAL') return Math.max(0, ...this.children.map(node => node.width));
    return this._width;
  }
  get height() {
    if (this.layoutMode === 'VERTICAL') return this.children.reduce((sum, node) => sum + node.height, 0) + Math.max(0, this.children.length - 1) * this.itemSpacing;
    if (this.layoutMode === 'HORIZONTAL') return Math.max(0, ...this.children.map(node => node.height));
    return this._height;
  }
  get relativeTransform() { return [[1, 0, this.x], [0, 1, this.y]]; }
  resize(width, height) { this._width = width; this._height = height; }
  appendChild(node) {
    if (node.parent) node.parent.children = node.parent.children.filter(child => child !== node);
    node.parent = this; this.children.push(node);
  }
  setPluginData(key, value) { this.data[key] = value; }
  getPluginData(key) { return this.data[key] || ''; }
  findOne(predicate) {
    for (const node of this.children) {
      if (predicate(node)) return node;
      const found = node.findOne(predicate);
      if (found) return found;
    }
    return null;
  }
}

function setup() {
  counter = 0;
  const root = new Node('DOCUMENT', 'root');
  const page = new Node('PAGE', '0:1'); root.appendChild(page);
  const frame = new Node('FRAME', '1:2'); page.appendChild(frame); frame.resize(1000, 200);
  const old = new Node('RECTANGLE', 'old'); old.y = 100; old.resize(200, 80); frame.appendChild(old);
  global.figma = {
    root, currentPage: page, fileKey: 'file123',
    async getNodeByIdAsync(id) { return root.findOne(node => node.id === id); },
    async setCurrentPageAsync(value) { this.currentPage = value; },
    createFrame() { const node = new Node('FRAME'); this.currentPage.appendChild(node); return node; },
    createRectangle() { const node = new Node('RECTANGLE'); this.currentPage.appendChild(node); return node; },
    createImage() { return { hash: 'image-hash', async getSizeAsync() { return { width: 200, height: 100 }; } }; },
    commitUndo() {}
  };
  const job = { id: 'batch1', destination: { fileKey: 'file123', pageID: '0:1', nodeID: '1:2' },
    images: Array.from({ length: 10 }, (_, index) => ({ id: `image${index}`, name: `reference ${index}.png` })) };
  return { page, frame, old, job };
}

test('ten images preserve proportions, wrap, and append without moving existing content', async () => {
  const { frame, old, job } = setup();
  for (const image of job.images) await importImage(job, image.id, [1, 2, 3]);
  const batch = frame.children.find(node => node.getPluginData('finderBatch') === job.id);
  assert.equal(batch.y, 204);
  assert.equal(old.y, 100);
  assert.equal(batch.children.length, 5); // two columns within the 1000px frame
  assert.equal(batch.children.flatMap(row => row.children).length, 10);
  for (const image of batch.children.flatMap(row => row.children)) {
    assert.equal(image.width / image.height, 2);
    assert.equal(image.fills[0].scaleMode, 'FIT');
  }
  assert.ok(frame.height >= batch.y + batch.height + 24);
  const nextJob = { ...job, id: 'batch2', images: [{ id: 'next', name: 'new.png' }] };
  await importImage(nextJob, 'next', [1]);
  const next = frame.children.find(node => node.getPluginData('finderBatch') === 'batch2');
  assert.ok(next.y >= batch.y + batch.height + 24);
});

test('replaying an image after a lost acknowledgement creates no duplicate', async () => {
  const { frame, job } = setup();
  const first = await importImage(job, 'image0', [1]);
  const retry = await importImage(job, 'image0', [1]);
  assert.equal(first.nodeID, retry.nodeID);
  assert.equal(retry.reused, true);
  assert.equal(frame.findOne(node => node.getPluginData('finderBatch') === job.id).children[0].children.length, 1);
});

test('wrong file, missing page, and unsafe frames are rejected before importing', async () => {
  const { frame, job } = setup();
  await assert.rejects(resolveDestination({ ...job, destination: { ...job.destination, fileKey: 'different' } }), /another Figma file/);
  await assert.rejects(resolveDestination({ ...job, destination: { ...job.destination, pageID: '9:9' } }), /deleted/);
  frame.locked = true;
  assert.throws(() => validateContainer(frame), /unlocked/);
  frame.locked = false; frame.layoutMode = 'HORIZONTAL';
  assert.throws(() => validateContainer(frame), /freeform/);
});

test('page destinations work without a selected frame', async () => {
  const { page, job } = setup();
  job.destination.nodeID = null;
  await importImage(job, 'image0', [1]);
  const batch = page.children.find(node => node.getPluginData('finderBatch') === job.id);
  assert.equal(batch.parent, page);
  assert.equal(batch.y, 224);
});
