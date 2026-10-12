# Figma Finder Bridge

Send downloaded images from Finder to a saved Figma Design page or frame. Inspired by [Gentle Systems’ GDrive Finder Service](https://github.com/gentle-systems/gdrive-finder-service).

Select images → **Services → Send to Figma…** → choose a destination → send.

The app is a small native macOS Service with a destination picker. A tiny Figma plugin registers destinations and receives images. Pending images are copied into a local queue so you can move or delete the originals after sending. Imports preserve proportions and append beneath existing content.

## App outline

- One macOS app, no menu bar utility or separate server installation.
- One Finder Service, with a remembered destination.
- One setup window for connecting the receiver.
- One development plugin for Figma Design, with page and frame destinations.
- A private local queue and authenticated loopback connection.

The receiver must run in the destination file. When it is closed, images remain queued. Opening a file does not automatically launch its plugin. Figma permits one active plugin at a time; this receiver occupies that slot in its file.

## Implementation steps

Each step is a separate, reviewable commit:

1. Record the app outline and acceptance checks.
2. Build the native app bundle, Finder Service, and destination picker.
3. Add image preparation, persistent queueing, and the authenticated local connection.
4. Add the Figma receiver, destination registration, and retry-safe placement.
5. Verify the complete local flow and document installation and the Figma smoke test.

## Assumptions

- macOS 13 or newer; personal use with a locally imported Figma development plugin.
- Existing editable Figma Design files; FigJam is outside this version.
- Images are copied, never moved or continuously synchronized.
- JPEG and PNG first; other formats supported by macOS ImageIO can be flattened and converted to PNG.
- Imported image bytes are limited to 4096 pixels per dimension; originals stay unchanged.
- Destinations are registered from the actual Figma page/frame and identified by IDs, not names.
- Arbitrary auto-layout, clipped, rotated, or locked frames may require a simpler destination frame.
- No cloud intermediary, folder watching, account browser, or AI processing per import.

## Delivery decision

Figma’s remote MCP tools support canvas writes and asset uploads, but [new MCP clients require approval](https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/). This standalone app uses the documented Plugin API rather than borrowing another client’s identity or credentials. The small HTTP protocol can later be replaced if supported remote access becomes available.

[Figma plugin lifecycle](https://help.figma.com/hc/en-us/articles/360042532714-Use-plugins-in-files) · [Image API](https://developers.figma.com/docs/plugins/api/properties/figma-createimage/) · [Plugin networking](https://developers.figma.com/docs/plugins/making-network-requests/)

## Acceptance checks

- Finder supplies the entire selection, including paths containing spaces and Unicode.
- A batch of ten images goes to the exact saved page/frame without cropping.
- Later batches append without rearranging earlier images.
- Queued bytes survive app relaunch and deletion of the original files.
- Interrupted delivery retries without duplicating an already-created image.
- Missing or invalid destinations retain pending images and explain the problem.
- Unauthenticated local requests cannot inspect destinations or read queued images.
- “Queued” means locally retained; “Added” means the plugin acknowledged insertion, not proof of Figma cloud synchronization.

