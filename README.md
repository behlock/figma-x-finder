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

These steps are implemented. A subsequent fix commit covers the localhost domain and sandbox reply handling discovered during the live Figma test.

## Install

Requires Xcode or the Swift command-line toolchain. Node.js is needed only to run the receiver tests; the app has no Node.js runtime dependency.

```sh
bash scripts/install.sh
```

This installs into your personal Applications folder. Pass an alternative application directory as the first argument if needed. The development build is signed locally, rather than notarized for public distribution.

Installation quits running copies before updating and unregisters the build-folder copy from Finder Services. If a second copy is opened later, it gracefully replaces the running copy before loading the shared queue and opening the local connection.

1. Open **Figma Finder Bridge.app**. Choose **Show receiver plugin**.
2. In Figma Desktop, choose **Plugins → Development → Import plugin from manifest…** and select that `manifest.json`.
3. Open your inspiration file, select a freeform frame or deselect everything for a page destination, and run **Figma Finder Bridge**.
4. Copy the connection key from the macOS app into the receiver and choose **Connect**. This is a local pairing key, not a Figma access token.
5. Name the destination and choose **Save destination**.

Select images in Finder → **Services → Send to Figma…** → choose the destination → **Send**.

Keep the receiver running in that file while collecting. If you close it, images remain queued. The app exits after two minutes without a visible window or authenticated receiver requests; reopen it to resume a pending queue. **Open Figma** opens the saved destination using the system’s Figma link handler, which may use Figma Desktop, Beta, or your browser.

If the Service is missing, open the installed app once and check **System Settings → Keyboard → Keyboard Shortcuts → Services**. You can assign a keyboard shortcut there. The picker remembers your last destination.

During development, use `bash scripts/build-app.sh` and import `receiver/manifest.json` directly from this repository. Reimport the manifest if Figma keeps using old plugin code after a change.

## Placement and limits

Images use a maximum display width of 320 pixels, up to four columns, and 24-pixel spacing. Each batch gets a transparent auto-layout frame; new batches append below existing content. Source filenames become layer names. Figma destination frames grow as needed so their clipping does not hide the new images.

The receiver rejects locked, hidden, rotated, or auto-layout destination frames, and frames inside components, auto-layout parents, or clipping parents. It does not alter those layouts automatically. A missing destination keeps its batch queued; this first version has no queue retargeting UI.

Up to 100 files per batch. ImageIO decodes the first image of supported formats, corrects orientation, resizes to at most 4096 pixels per dimension, and encodes PNG. Detailed images are automatically resized further to fit the 10 MB limit. Originals stay unchanged and transparency is preserved. Animated and multi-page files become still images.

The local server binds to `127.0.0.1:17847`; the development plugin connects through the `localhost` domain permitted by Figma. Image reads, registration, and acknowledgements require the pairing key. The app stores its key, destinations, and pending images in `~/Library/Application Support/Figma Finder Bridge/`, with private directory/file permissions. Completed image copies are removed after the receiver acknowledges them. No original file paths are sent to Figma.

## Verification

```sh
bash scripts/test.sh
bash scripts/build-app.sh
```

Six Swift tests cover persistence, deletion of originals, pixel and byte limits, mixed selections, destination identity, authentication, and HTTP parsing. Six Node tests cover image layout, retries, destination guards, page imports, the startup handshake, and authenticated registration.

The live macOS/Figma test verified the Service in Finder’s context menu, receipt of all ten selected PNGs, pairing, frame registration, ten image layers in three rows, preserved landscape/portrait/square proportions, and a cleared queue after acknowledgement. The generated test batch was removed afterward; the destination’s original dimensions and contents were restored.

## Assumptions

- macOS 13 or newer; personal use with a locally imported Figma development plugin.
- Existing editable Figma Design files; FigJam is outside this version.
- Images are copied, never moved or continuously synchronized.
- JPEG and PNG first; other formats supported by macOS ImageIO can be flattened and converted to PNG.
- Imported image bytes are limited to 4096 pixels per dimension; originals stay unchanged.
- Destinations are registered from the actual Figma page/frame and identified by IDs, not names.
- Auto-layout, rotated, or locked frames require a freeform destination. Clipping destination frames are supported by growing their bounds.
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

