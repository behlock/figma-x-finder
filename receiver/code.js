function validateContainer(node) {
  if (!node || (node.type !== 'PAGE' && node.type !== 'FRAME')) {
    throw new Error('The saved destination was deleted. Register a new page or frame.');
  }
  for (let ancestor = node; ancestor && ancestor.type !== 'DOCUMENT'; ancestor = ancestor.parent) {
    if (ancestor.locked || ancestor.visible === false || ancestor.type === 'INSTANCE' || ancestor.type === 'COMPONENT') {
      throw new Error('Choose a visible, unlocked page or frame outside a component.');
    }
  }
}

async function resolveDestination(job) {
  if (!figma.fileKey || job.destination.fileKey !== figma.fileKey) {
    throw new Error('This batch belongs to another Figma file.');
  }
  const container = await figma.getNodeByIdAsync(job.destination.nodeID || job.destination.pageID);
  if (container?.type !== (job.destination.nodeID ? 'FRAME' : 'PAGE')) {
    throw new Error('The saved destination was deleted. Register a new page or frame.');
  }
  validateContainer(container);
  let page = container;
  while (page && page.type !== 'PAGE') page = page.parent;
  if (!page || page.parent !== figma.root) {
    throw new Error('The saved page was deleted. Register a new destination.');
  }
  if (figma.currentPage.id !== page.id) await figma.setCurrentPageAsync(page);
  return { page, container };
}

const IMAGE_GAP = 64;

function inverseTransform(container) {
  if (container.type === 'PAGE') return [[1, 0, 0], [0, 1, 0]];
  const t = container.absoluteTransform;
  const determinant = t[0][0] * t[1][1] - t[0][1] * t[1][0];
  return [[t[1][1] / determinant, -t[0][1] / determinant,
    (t[0][1] * t[1][2] - t[1][1] * t[0][2]) / determinant],
  [-t[1][0] / determinant, t[0][0] / determinant,
    (t[1][0] * t[0][2] - t[0][0] * t[1][2]) / determinant]];
}

function boundsInContainer(node, container, inverse = inverseTransform(container)) {
  const world = node.absoluteTransform;
  const width = node.width, height = node.height;
  const a = (inverse[0][0] * world[0][0] + inverse[0][1] * world[1][0]) * width;
  const b = (inverse[1][0] * world[0][0] + inverse[1][1] * world[1][0]) * width;
  const c = (inverse[0][0] * world[0][1] + inverse[0][1] * world[1][1]) * height;
  const d = (inverse[1][0] * world[0][1] + inverse[1][1] * world[1][1]) * height;
  // Affine bounds need two edge vectors, rather than four allocated corners.
  return {
    x: inverse[0][0] * world[0][2] + inverse[0][1] * world[1][2] + inverse[0][2] + Math.min(0, a) + Math.min(0, c),
    y: inverse[1][0] * world[0][2] + inverse[1][1] * world[1][2] + inverse[1][2] + Math.min(0, b) + Math.min(0, d),
    width: Math.abs(a) + Math.abs(c), height: Math.abs(b) + Math.abs(d)
  };
}

function overlaps(a, b, gap = 0) {
  const epsilon = 0.01;
  return a.x < b.x + b.width + gap - epsilon && a.x + a.width + gap > b.x + epsilon &&
    a.y < b.y + b.height + gap - epsilon && a.y + a.height + gap > b.y + epsilon;
}

function occupiedBounds(container, includeOutside = false) {
  const result = [], inverse = inverseTransform(container);
  const board = { x: 0, y: 0, width: container.width, height: container.height };
  function add(node, sibling = false) {
    if (node.visible === false) return;
    const bounds = boundsInContainer(node, container, inverse);
    if (bounds.width > 0 && bounds.height > 0 &&
        (!sibling || includeOutside || overlaps(bounds, board, IMAGE_GAP))) result.push(bounds);
  }
  for (const child of container.children) add(child);
  // References can visually sit on a board while being siblings in the Layers panel.
  if (container.type === 'FRAME') {
    for (let branch = container; branch.parent && branch.parent.type !== 'DOCUMENT'; branch = branch.parent) {
      for (const sibling of branch.parent.children) { if (sibling !== branch) add(sibling, true); }
    }
  }
  return result;
}

function median(values) {
  const sorted = values.slice().sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function findPlacement(container, width, height) {
  const occupied = occupiedBounds(container, true);
  const nearby = container.type === 'PAGE' ? occupied : occupied.filter(b =>
    overlaps(b, { x: 0, y: 0, width: container.width, height: container.height }));
  const anchor = nearby.length ? {
    x: median(nearby.map(b => b.x + b.width / 2)),
    y: median(nearby.map(b => b.y + b.height / 2))
  } : container.type === 'FRAME' ? { x: container.width / 2, y: container.height / 2 } : figma.viewport.center;
  const candidates = [];
  const seen = new Set();
  function add(x, y) {
    if (container.type === 'FRAME') {
      x = Math.max(IMAGE_GAP, Math.min(x, container.width - width - IMAGE_GAP));
      y = Math.max(IMAGE_GAP, Math.min(y, container.height - height - IMAGE_GAP));
    }
    const key = `${x},${y}`;
    if (!seen.has(key)) { seen.add(key); candidates.push({ x, y, width, height }); }
  }
  add(anchor.x - width / 2, anchor.y - height / 2);
  // Bound the search independently of page size. All layers still participate
  // in collision checks; only the nearest neighbours generate candidates.
  const neighbours = nearby.slice().sort((a, b) =>
    (a.x + a.width / 2 - anchor.x) ** 2 + (a.y + a.height / 2 - anchor.y) ** 2 -
    ((b.x + b.width / 2 - anchor.x) ** 2 + (b.y + b.height / 2 - anchor.y) ** 2)).slice(0, 32);
  for (const b of neighbours) {
    for (const y of [b.y, b.y + (b.height - height) / 2, b.y + b.height - height]) {
      add(b.x + b.width + IMAGE_GAP, y);
      add(b.x - width - IMAGE_GAP, y);
    }
    for (const x of [b.x, b.x + (b.width - width) / 2, b.x + b.width - width]) {
      add(x, b.y + b.height + IMAGE_GAP);
      add(x, b.y - height - IMAGE_GAP);
    }
  }
  if (container.type === 'FRAME') {
    for (const x of [IMAGE_GAP, container.width - width - IMAGE_GAP]) {
      for (const y of [IMAGE_GAP, container.height - height - IMAGE_GAP]) add(x, y);
    }
  }
  const distance = b => (b.x + width / 2 - anchor.x) ** 2 + (b.y + height / 2 - anchor.y) ** 2;
  candidates.sort((a, b) => distance(a) - distance(b) || a.y - b.y || a.x - b.x);
  const valid = candidates.find(b => (container.type === 'PAGE' ||
    (b.x + width + IMAGE_GAP <= container.width && b.y + height + IMAGE_GAP <= container.height)) &&
    occupied.every(other => !overlaps(b, other, IMAGE_GAP)));
  // A full board expands downward; existing references always stay where they are.
  if (valid) return valid;
  const fallback = { x: container.type === 'FRAME'
    ? Math.max(IMAGE_GAP, Math.min(anchor.x - width / 2, container.width - width - IMAGE_GAP))
    : anchor.x - width / 2,
    y: nearby.reduce((bottom, b) => Math.max(bottom, b.y + b.height),
      container.type === 'FRAME' ? container.height : anchor.y) + IMAGE_GAP, width, height };
  // Expansion must also avoid page layers just beyond the board's current edge.
  // Sweep once from top to bottom instead of rescanning after each blocker.
  const blockers = occupied.filter(b => b.x < fallback.x + width + IMAGE_GAP &&
    b.x + b.width + IMAGE_GAP > fallback.x).sort((a, b) => a.y - b.y);
  for (const blocker of blockers) {
    if (overlaps(fallback, blocker, IMAGE_GAP)) fallback.y = blocker.y + blocker.height + IMAGE_GAP;
  }
  return fallback;
}

function itemKey(job, imageID) { return `${job.id}.${imageID}`; }
const batchIndexes = new WeakMap();
function imageIndex(page, job, refresh = false) {
  let batch = batchIndexes.get(page);
  if (refresh || !batch || batch.id !== job.id) {
    const index = new Map();
    // Native filtering avoids a JavaScript callback and plugin-data read for
    // every node on the page, including unrelated component descendants.
    for (const node of page.findAllWithCriteria({ types: ['RECTANGLE'], pluginData: { keys: ['finderImage'] } })) {
      const key = node.getPluginData('finderImage');
      if (key.startsWith(`${job.id}.`) && !index.has(key)) index.set(key, node);
    }
    batch = { id: job.id, index };
    batchIndexes.set(page, batch);
  }
  return batch.index;
}

function existingImage(page, job, imageID) {
  const node = imageIndex(page, job).get(itemKey(job, imageID));
  if (!node || node.removed || node.getPluginData('finderImage') !== itemKey(job, imageID)) return null;
  let ancestor = node;
  while (ancestor && ancestor.type !== 'PAGE') ancestor = ancestor.parent;
  return ancestor?.id === page.id ? node : null;
}

function growFrame(frame, width, height) {
  if (width <= frame.width && height <= frame.height) return;
  const horizontal = frame.layoutSizingHorizontal, vertical = frame.layoutSizingVertical;
  frame.resizeWithoutConstraints(Math.max(frame.width, width), Math.max(frame.height, height));
  frame.layoutSizingHorizontal = horizontal;
  frame.layoutSizingVertical = vertical;
}

async function importImage(job, imageID, bytes) {
  const { page, container } = await resolveDestination(job);
  const existing = existingImage(page, job, imageID);
  if (existing) return { nodeID: existing.id, reused: true };
  const metadata = job.images.find(image => image.id === imageID);
  if (!metadata) throw new Error('Image not found in this batch.');
  const image = figma.createImage(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes));
  // The bridge already knows the normalized pixel dimensions. Avoid a second
  // asynchronous decode in Figma; retain the fallback for older queued jobs.
  const dimensions = Number.isFinite(metadata.width) && metadata.width > 0 &&
    Number.isFinite(metadata.height) && metadata.height > 0
    ? { width: metadata.width, height: metadata.height } : await image.getSizeAsync();
  // Validate again after asynchronous decoding: the user may have changed the frame.
  validateContainer(container);
  const autoLayout = container.type === 'FRAME' && container.layoutMode !== 'NONE';
  const inset = autoLayout ? container.paddingLeft + container.paddingRight : 2 * IMAGE_GAP;
  const availableWidth = container.type === 'FRAME' ? Math.max(40, container.width - inset) : 320;
  const displayWidth = Math.min(320, availableWidth);
  const displayHeight = Math.max(1, displayWidth * dimensions.height / dimensions.width);
  const placement = autoLayout ? null : findPlacement(container, displayWidth, displayHeight);
  const rectangle = figma.createRectangle();
  try {
    rectangle.name = metadata.name;
    rectangle.resize(displayWidth, displayHeight);
    rectangle.fills = [{ type: 'IMAGE', imageHash: image.hash, scaleMode: 'FIT' }];
    container.appendChild(rectangle);
    rectangle.rotation = 0;
    if (placement) { rectangle.x = placement.x; rectangle.y = placement.y; }
    if (autoLayout) {
      const inverse = inverseTransform(container);
      let left = container.paddingLeft, top = container.paddingTop, right = -Infinity, bottom = -Infinity;
      for (const node of container.children) {
        if (!node.visible || node.layoutPositioning === 'ABSOLUTE') continue;
        const b = boundsInContainer(node, container, inverse);
        left = Math.min(left, b.x); top = Math.min(top, b.y);
        right = Math.max(right, b.x + b.width); bottom = Math.max(bottom, b.y + b.height);
      }
      growFrame(container, right - left + container.paddingLeft + container.paddingRight,
        bottom - top + container.paddingTop + container.paddingBottom);
    } else if (container.type === 'FRAME') {
      growFrame(container, rectangle.x + rectangle.width + IMAGE_GAP, rectangle.y + rectangle.height + IMAGE_GAP);
    }
    rectangle.setPluginData('finderImage', itemKey(job, imageID));
  } catch (error) { rectangle.remove(); throw error; }
  imageIndex(page, job).set(itemKey(job, imageID), rectangle);
  figma.commitUndo();
  return { nodeID: rectangle.id, reused: false };
}

async function handle(message) {
  switch (message.type) {
    case 'bootstrap':
      return { token: await figma.clientStorage.getAsync('connectionKey') || '', fileKey: figma.fileKey || null, name: figma.currentPage.selection[0]?.name || figma.currentPage.name };
    case 'resize':
      figma.ui.resize(360, Math.max(82, Math.min(640, Number(message.height) || 82)));
      return {};
    case 'configure':
      if (!/^[A-Fa-f0-9]{64}$/.test(message.token)) throw new Error('Connection failed. Click Connect to try again.');
      await figma.clientStorage.setAsync('connectionKey', message.token);
      return { token: message.token };
    case 'registration': {
      if (!figma.fileKey) throw new Error('Figma has not exposed this file’s identity. Run this as a local development plugin in a saved Design file.');
      const selection = figma.currentPage.selection;
      if (selection.length > 1 || (selection.length === 1 && selection[0].type !== 'FRAME')) {
        throw new Error('Select a frame, or deselect everything to use this page.');
      }
      const container = selection[0] || figma.currentPage;
      validateContainer(container);
      return {
        name: message.name.trim() || container.name,
        fileKey: figma.fileKey,
        pageID: figma.currentPage.id,
        nodeID: container.type === 'FRAME' ? container.id : null
      };
    }
    case 'prepare': {
      const { page } = await resolveDestination(message.job);
      imageIndex(page, message.job, true);
      const completed = new Set(message.job.completed || []);
      return { existing: message.job.images.filter(image => !completed.has(image.id) &&
        existingImage(page, message.job, image.id)).map(image => image.id) };
    }
    case 'import': return importImage(message.job, message.imageID, message.bytes);
    default: throw new Error('Unknown receiver action.');
  }
}

if (typeof figma !== 'undefined') {
  figma.skipInvisibleInstanceChildren = true;
  figma.showUI(__html__, { width: 360, height: 82, themeColors: true });
  // Serialize mutations, including registration while a batch is arriving.
  let chain = Promise.resolve();
  figma.ui.onmessage = message => {
    chain = chain.then(async () => {
      try {
        figma.ui.postMessage({ type: 'reply', requestID: message.requestID, result: await handle(message) });
      } catch (error) {
        figma.ui.postMessage({ type: 'reply', requestID: message.requestID, error: error.message || String(error) });
      }
    });
  };
}

if (typeof module !== 'undefined') module.exports = { validateContainer, importImage, resolveDestination, boundsInContainer, occupiedBounds, overlaps, findPlacement, handle, IMAGE_GAP };
