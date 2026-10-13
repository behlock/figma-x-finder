/* Classic development plugin; no MCP-specific API helpers are required. */
function validateContainer(node) {
  if (!node || (node.type !== 'PAGE' && node.type !== 'FRAME')) {
    throw new Error('The saved destination was deleted. Register a new page or frame.');
  }
  if (node.type === 'FRAME' && (node.layoutMode !== 'NONE' || Math.abs(node.rotation) > 0.01)) {
    throw new Error('Choose a freeform, unrotated inspiration frame.');
  }
  for (let ancestor = node; ancestor && ancestor.type !== 'DOCUMENT'; ancestor = ancestor.parent) {
    if (ancestor.locked || ancestor.visible === false || ancestor.type === 'INSTANCE' || ancestor.type === 'COMPONENT') {
      throw new Error('Choose a visible, unlocked page or frame outside a component.');
    }
    if (ancestor !== node && ancestor.type === 'FRAME' && ancestor.clipsContent) {
      throw new Error('Choose a frame outside a clipping parent so new images remain visible.');
    }
    if (ancestor !== node && ancestor.type === 'FRAME' && ancestor.layoutMode !== 'NONE') {
      throw new Error('Choose a frame outside an auto-layout parent so existing content stays in place.');
    }
  }
}

async function resolveDestination(job) {
  if (!figma.fileKey || job.destination.fileKey !== figma.fileKey) {
    throw new Error('This batch belongs to another Figma file.');
  }
  const page = await figma.getNodeByIdAsync(job.destination.pageID);
  if (!page || page.type !== 'PAGE' || page.parent !== figma.root) {
    throw new Error('The saved page was deleted. Register a new destination.');
  }
  await figma.setCurrentPageAsync(page);
  const container = job.destination.nodeID ? await figma.getNodeByIdAsync(job.destination.nodeID) : page;
  validateContainer(container);
  let ancestor = container;
  while (ancestor && ancestor.type !== 'PAGE') ancestor = ancestor.parent;
  if (ancestor !== page) throw new Error('The destination moved to another page. Register it again.');
  return { page, container };
}

const IMAGE_GAP = 64;

function point(transform, x, y) {
  return { x: transform[0][0] * x + transform[0][1] * y + transform[0][2],
    y: transform[1][0] * x + transform[1][1] * y + transform[1][2] };
}

function boundsInContainer(node, container) {
  const world = node.absoluteTransform;
  const t = container.type === 'PAGE' ? [[1, 0, 0], [0, 1, 0]] : container.absoluteTransform;
  const determinant = t[0][0] * t[1][1] - t[0][1] * t[1][0];
  const corners = [[0, 0], [node.width, 0], [0, node.height], [node.width, node.height]].map(([x, y]) => {
    const p = point(world, x, y);
    const dx = p.x - t[0][2], dy = p.y - t[1][2];
    return { x: (t[1][1] * dx - t[0][1] * dy) / determinant,
      y: (-t[1][0] * dx + t[0][0] * dy) / determinant };
  });
  const x = Math.min(...corners.map(p => p.x)), y = Math.min(...corners.map(p => p.y));
  return { x, y, width: Math.max(...corners.map(p => p.x)) - x, height: Math.max(...corners.map(p => p.y)) - y };
}

function overlaps(a, b, gap = 0) {
  const epsilon = 0.01;
  return a.x < b.x + b.width + gap - epsilon && a.x + a.width + gap > b.x + epsilon &&
    a.y < b.y + b.height + gap - epsilon && a.y + a.height + gap > b.y + epsilon;
}

function occupiedBounds(container, includeOutside = false) {
  const children = container.children.filter(node => node.visible !== false).map(node => boundsInContainer(node, container));
  const siblings = [];
  // References can visually sit on a board while being siblings in the Layers panel.
  if (container.type === 'FRAME') {
    for (let branch = container; branch.parent && branch.parent.type !== 'DOCUMENT'; branch = branch.parent) {
      siblings.push(...branch.parent.children.filter(node => node !== branch && node.visible !== false));
    }
  }
  const board = { x: 0, y: 0, width: container.width, height: container.height };
  return children.concat(siblings.map(node => boundsInContainer(node, container))
    .filter(bounds => includeOutside || overlaps(bounds, board, IMAGE_GAP)))
    .filter(bounds => bounds.width > 0 && bounds.height > 0);
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
  function add(x, y) {
    if (container.type === 'FRAME') {
      x = Math.max(IMAGE_GAP, Math.min(x, container.width - width - IMAGE_GAP));
      y = Math.max(IMAGE_GAP, Math.min(y, container.height - height - IMAGE_GAP));
    }
    candidates.push({ x, y, width, height });
  }
  add(anchor.x - width / 2, anchor.y - height / 2);
  for (const b of nearby) {
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
  const valid = candidates.filter(b => (container.type === 'PAGE' ||
    (b.x + width + IMAGE_GAP <= container.width && b.y + height + IMAGE_GAP <= container.height)) &&
    occupied.every(other => !overlaps(b, other, IMAGE_GAP)));
  valid.sort((a, b) => distance(a) - distance(b) || a.y - b.y || a.x - b.x);
  // A full board expands downward; existing references always stay where they are.
  if (valid.length) return valid[0];
  const fallback = { x: container.type === 'FRAME'
    ? Math.max(IMAGE_GAP, Math.min(anchor.x - width / 2, container.width - width - IMAGE_GAP))
    : anchor.x - width / 2,
    y: Math.max(container.type === 'FRAME' ? container.height : anchor.y,
      ...nearby.map(b => b.y + b.height)) + IMAGE_GAP, width, height };
  // Expansion must also avoid page layers just beyond the board's current edge.
  let blockers = occupied.filter(other => overlaps(fallback, other, IMAGE_GAP));
  while (blockers.length) {
    fallback.y = Math.max(...blockers.map(b => b.y + b.height)) + IMAGE_GAP;
    blockers = occupied.filter(other => overlaps(fallback, other, IMAGE_GAP));
  }
  return fallback;
}

function itemKey(job, imageID) { return `${job.id}.${imageID}`; }
function existingImage(page, job, imageID) {
  return page.findOne(node => node.getPluginData('finderImage') === itemKey(job, imageID));
}

async function importImage(job, imageID, bytes) {
  const { page, container } = await resolveDestination(job);
  const existing = existingImage(page, job, imageID);
  if (existing) return { nodeID: existing.id, reused: true };
  const index = job.images.findIndex(image => image.id === imageID);
  if (index < 0) throw new Error('Image not found in this batch.');
  const metadata = job.images[index];
  const image = figma.createImage(new Uint8Array(bytes));
  const dimensions = await image.getSizeAsync();
  // Validate again after asynchronous decoding: the user may have changed the frame.
  validateContainer(container);
  const availableWidth = container.type === 'FRAME' ? Math.max(40, container.width - 2 * IMAGE_GAP) : 320;
  const displayWidth = Math.min(320, availableWidth);
  const displayHeight = Math.max(1, displayWidth * dimensions.height / dimensions.width);
  const placement = findPlacement(container, displayWidth, displayHeight);
  const rectangle = figma.createRectangle();
  rectangle.name = metadata.name;
  rectangle.resize(displayWidth, displayHeight);
  rectangle.fills = [{ type: 'IMAGE', imageHash: image.hash, scaleMode: 'FIT' }];
  container.appendChild(rectangle);
  rectangle.x = placement.x;
  rectangle.y = placement.y;
  rectangle.setPluginData('finderBatch', job.id);
  rectangle.setPluginData('finderImage', itemKey(job, imageID));
  if (container.type === 'FRAME') {
    container.resize(Math.max(container.width, rectangle.x + rectangle.width + IMAGE_GAP),
      Math.max(container.height, rectangle.y + rectangle.height + IMAGE_GAP));
  }
  figma.commitUndo();
  return { nodeID: rectangle.id, reused: false };
}

async function handle(message) {
  switch (message.type) {
    case 'bootstrap':
      return { token: await figma.clientStorage.getAsync('connectionKey') || '', fileKey: figma.fileKey || null, name: figma.currentPage.selection[0]?.name || figma.currentPage.name };
    case 'resize':
      figma.ui.resize(360, message.height === 460 ? 460 : 350);
      return {};
    case 'configure':
      if (!/^[A-Fa-f0-9]{64}$/.test(message.token)) throw new Error('Copy the connection key from the macOS app.');
      await figma.clientStorage.setAsync('connectionKey', message.token);
      return { token: message.token };
    case 'registration': {
      if (!figma.fileKey) throw new Error('Figma has not exposed this file’s identity. Run this as a local development plugin in a saved Design file.');
      const selection = figma.currentPage.selection;
      if (selection.length > 1 || (selection.length === 1 && selection[0].type !== 'FRAME')) {
        throw new Error('Select one inspiration frame, or deselect everything to use this page.');
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
      return { existing: message.job.images.filter(image => existingImage(page, message.job, image.id)).map(image => image.id) };
    }
    case 'import': return importImage(message.job, message.imageID, message.bytes);
    default: throw new Error('Unknown receiver action.');
  }
}

if (typeof figma !== 'undefined') {
  figma.showUI(__html__, { width: 360, height: 350, themeColors: true });
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

if (typeof module !== 'undefined') module.exports = { validateContainer, importImage, resolveDestination, boundsInContainer, occupiedBounds, findPlacement, overlaps, IMAGE_GAP };
