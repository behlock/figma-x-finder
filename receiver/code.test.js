const { test } = require('node:test');
const assert = require('node:assert/strict');
const { importImage, resolveDestination, validateContainer, boundsInContainer, occupiedBounds, overlaps, IMAGE_GAP } = require('./code');

let counter;
class Node {
  constructor(type, id) {
    this.type = type; this.id = id || `test:${++counter}`; this.name = type;
    this.children = []; this.data = {}; this.x = 0; this.y = 0;
    this.width = 100; this.height = 100; this.rotation = 0;
    this.layoutMode = 'NONE'; this.locked = false; this.visible = true;
    this.clipsContent = false;
  }
  get relativeTransform() {
    const angle = this.rotation * Math.PI / 180;
    return [[Math.cos(angle), -Math.sin(angle), this.x], [Math.sin(angle), Math.cos(angle), this.y]];
  }
  get absoluteTransform() {
    const a = this.parent ? this.parent.absoluteTransform : [[1, 0, 0], [0, 1, 0]];
    const b = this.relativeTransform;
    return [0, 1].map(row => [
      a[row][0] * b[0][0] + a[row][1] * b[1][0],
      a[row][0] * b[0][1] + a[row][1] * b[1][1],
      a[row][0] * b[0][2] + a[row][1] * b[1][2] + a[row][2]
    ]);
  }
  resize(width, height) { this.width = width; this.height = height; }
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
    createRectangle() { const node = new Node('RECTANGLE'); this.currentPage.appendChild(node); return node; },
    createImage() { return { hash: 'image-hash', async getSizeAsync() { return { width: 200, height: 100 }; } }; },
    commitUndo() {}
  };
  const job = { id: 'batch1', destination: { fileKey: 'file123', pageID: '0:1', nodeID: '1:2' },
    images: Array.from({ length: 10 }, (_, index) => ({ id: `image${index}`, name: `reference ${index}.png` })) };
  return { page, frame, old, job };
}

function assertSeparated(container) {
  const bounds = occupiedBounds(container);
  for (let i = 0; i < bounds.length; i++) {
    for (let j = i + 1; j < bounds.length; j++) {
      assert.equal(overlaps(bounds[i], bounds[j], IMAGE_GAP), false, `overlap between ${i} and ${j}`);
    }
  }
}

test('mixed proportions spread into open space without moving existing content', async () => {
  const { frame, old, job } = setup();
  frame.resize(2400, 2000);
  old.x = 900; old.y = 800;
  const originalSize = [frame.width, frame.height];
  const sizes = [{ width: 200, height: 100 }, { width: 100, height: 200 }, { width: 200, height: 200 }];
  figma.createImage = bytes => ({ hash: 'image-hash', async getSizeAsync() { return sizes[bytes[0] % sizes.length]; } });
  for (let index = 0; index < job.images.length; index++) await importImage(job, job.images[index].id, [index]);
  const images = frame.children.filter(node => node.getPluginData('finderImage').startsWith(`${job.id}.`));
  assert.equal(images.length, 10);
  assert.equal(old.x, 900); assert.equal(old.y, 800);
  assert.deepEqual([frame.width, frame.height], originalSize);
  assert.ok(new Set(images.map(n => n.x)).size > 1);
  assert.ok(new Set(images.map(n => n.y)).size > 1);
  for (let i = 0; i < images.length; i++) {
    assert.equal(images[i].width / images[i].height, sizes[i % sizes.length].width / sizes[i % sizes.length].height);
    assert.equal(images[i].fills[0].scaleMode, 'FIT');
    assert.ok(images[i].x >= IMAGE_GAP && images[i].y >= IMAGE_GAP);
    assert.ok(images[i].x + images[i].width + IMAGE_GAP <= frame.width);
    assert.ok(images[i].y + images[i].height + IMAGE_GAP <= frame.height);
  }
  assertSeparated(frame);
  const previous = images.map(n => [n.x, n.y]);
  const nextJob = { ...job, id: 'batch2', images: [{ id: 'next', name: 'new.png' }] };
  await importImage(nextJob, 'next', [1]);
  assertSeparated(frame);
  assert.deepEqual(images.map(n => [n.x, n.y]), previous);
});

test('an empty board starts in the centre and a full board grows to show new images', async () => {
  const { frame, old, job } = setup();
  frame.children = [];
  frame.resize(2000, 1600);
  await importImage(job, 'image0', [1]);
  assert.equal(frame.children[0].x, 840);
  assert.equal(frame.children[0].y, 720);
  frame.children = [old];
  frame.resize(200, 200);
  old.x = 0; old.y = 0; old.resize(200, 200);
  await importImage(job, 'image1', [1]);
  const image = frame.children[1];
  assert.ok(image.y >= old.height + IMAGE_GAP);
  assert.ok(frame.height >= image.y + image.height + IMAGE_GAP);
  assertSeparated(frame);
});

test('visually overlapping sibling references are avoided, including rotated ones', async () => {
  const { page, frame, job } = setup();
  frame.x = 1000; frame.y = 2000; frame.resize(2000, 1600);
  const sibling = new Node('RECTANGLE', 'sibling');
  sibling.x = 1800; sibling.y = 2600; sibling.rotation = 30; sibling.resize(400, 300);
  page.appendChild(sibling);
  const distant = new Node('RECTANGLE', 'distant');
  distant.x = 10000; distant.y = 10000; page.appendChild(distant);
  const hidden = new Node('RECTANGLE', 'hidden');
  hidden.x = 1500; hidden.y = 2500; hidden.visible = false; page.appendChild(hidden);
  assert.equal(occupiedBounds(frame).length, 2);
  const rotatedBounds = boundsInContainer(sibling, frame);
  assert.ok(rotatedBounds.x < 800);
  assert.ok(rotatedBounds.width > sibling.width);
  await importImage(job, 'image0', [1]);
  assertSeparated(frame);
  assert.equal(sibling.x, 1800); assert.equal(sibling.y, 2600);
});

test('a growing board also avoids references just outside its current bounds', async () => {
  const { page, frame, old, job } = setup();
  frame.resize(200, 200);
  old.x = 0; old.y = 0; old.resize(200, 200);
  const sibling = new Node('RECTANGLE');
  sibling.x = 64; sibling.y = 300; sibling.resize(200, 200); page.appendChild(sibling);
  await importImage(job, 'image0', [1]);
  const image = frame.children[1];
  assert.ok(image.y >= 564);
  assert.equal(overlaps(boundsInContainer(image, frame), boundsInContainer(sibling, frame), IMAGE_GAP), false);
  assert.ok(frame.height >= image.y + image.height + IMAGE_GAP);
});

test('replaying an image after a lost acknowledgement creates no duplicate, even in an older batch', async () => {
  const { frame, job } = setup();
  const first = await importImage(job, 'image0', [1]);
  const image = frame.children.find(n => n.id === first.nodeID);
  const oldBatch = new Node('FRAME'); frame.appendChild(oldBatch); oldBatch.appendChild(image);
  const position = [image.x, image.y];
  const retry = await importImage(job, 'image0', [1]);
  assert.equal(first.nodeID, retry.nodeID);
  assert.equal(retry.reused, true);
  assert.equal(oldBatch.children.length, 1);
  assert.deepEqual([image.x, image.y], position);
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

test('page destinations fill space beside existing content and use the viewport on an empty page', async () => {
  const { page, frame, job } = setup();
  job.destination.nodeID = null;
  await importImage(job, 'image0', [1]);
  const image = page.children.find(node => node.getPluginData('finderImage'));
  assert.equal(image.parent, page);
  assert.equal(overlaps(boundsInContainer(image, page), boundsInContainer(frame, page), IMAGE_GAP), false);
  page.children = [];
  figma.viewport = { center: { x: 5000, y: -3000 } };
  await importImage(job, 'image1', [1]);
  assert.equal(page.children[0].x, 4840);
  assert.equal(page.children[0].y, -3080);
});
