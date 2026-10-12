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

function layoutFrame(name, direction) {
  const frame = figma.createFrame();
  frame.name = name;
  frame.fills = [];
  frame.clipsContent = false;
  frame.layoutMode = direction;
  frame.primaryAxisSizingMode = 'AUTO';
  frame.counterAxisSizingMode = 'AUTO';
  frame.itemSpacing = 24;
  return frame;
}

function bottomInParent(node) {
  const t = node.relativeTransform;
  if (!t) return node.y + node.height;
  return Math.max(...[[0, 0], [node.width, 0], [0, node.height], [node.width, node.height]]
    .map(([x, y]) => t[1][0] * x + t[1][1] * y + t[1][2]));
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
  let batch = container.children.find(node => node.type === 'FRAME' && node.getPluginData('finderBatch') === job.id);
  if (!batch) {
    const bottom = Math.max(0, ...container.children.map(bottomInParent));
    batch = layoutFrame('Finder imports', 'VERTICAL');
    container.appendChild(batch);
    batch.x = container.type === 'FRAME' ? 24 : 0;
    batch.y = bottom + 24;
    batch.setPluginData('finderBatch', job.id);
  }
  const availableWidth = container.type === 'FRAME' ? Math.max(40, container.width - 48) : 1352;
  const displayWidth = Math.min(320, availableWidth);
  const columns = Math.max(1, Math.min(4, Math.floor((availableWidth + 24) / (displayWidth + 24))));
  const rowIndex = Math.floor(index / columns);
  let row = batch.children.find(node => node.type === 'FRAME' && node.getPluginData('finderRow') === String(rowIndex));
  if (!row) {
    row = layoutFrame('References', 'HORIZONTAL');
    row.counterAxisAlignItems = 'MIN';
    batch.appendChild(row);
    row.setPluginData('finderRow', String(rowIndex));
  }
  const rectangle = figma.createRectangle();
  rectangle.name = metadata.name;
  rectangle.resize(displayWidth, Math.max(1, displayWidth * dimensions.height / dimensions.width));
  rectangle.fills = [{ type: 'IMAGE', imageHash: image.hash, scaleMode: 'FIT' }];
  row.appendChild(rectangle);
  rectangle.setPluginData('finderImage', itemKey(job, imageID));
  // Grow the destination so a clipping frame still shows all imported content.
  if (container.type === 'FRAME') {
    container.resize(Math.max(container.width, batch.x + batch.width + 24), Math.max(container.height, batch.y + batch.height + 24));
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

if (typeof module !== 'undefined') module.exports = { validateContainer, importImage, resolveDestination, bottomInParent };
