# Send panel reference

Source: [DJ Seo — Neuralink telepathy user experience](https://x.com/djseo/status/1976297851576598913), posted 9 October 2025.

The downloaded video is 120 seconds at 1920 × 1080, 60 fps. All 7,200 decoded frames were exported as high-quality JPEGs without sampling or changing their dimensions. The original MP4 is retained. Exact presentation timestamps are in `frames.csv`; the offline viewer supports pausing, single-frame steps, seeking, and jumping to component examples. Exports live under `.build/reference-video/` and are excluded from Git.

## Visible component details

- **00:03–00:05:** pale rounded pairing control, circular arrow, blue progress/focus ring, and a blue success check.
- **00:06:** white content panel, pale rounded illustration area, compact labels, and a quiet circular secondary arrow.
- **00:36–00:37:** black primary text, grey supporting labels, hairline separators, and pale blue active rows.
- **00:43–00:50:** subdued controls become blue during an active action; status is shown beside the control.
- **00:58–01:11:** translucent dark keyboard surfaces, rounded tiles, thin highlights, and clear active-key outlines.
- **01:24–01:28:** very light inset control surfaces, blue/cyan emphasis, quiet secondary actions, and generous spacing.

These are visual observations from the compressed video, not original design tokens or a confirmed font specification.

## Application to this app

Use a white/light adaptive panel, quieter title-bar treatment, regular-to-medium system typography, softly inset preview and destination surfaces, and a blue circular Send arrow with a pale halo. Show a check when Figma acknowledges an import. Keep explicit textual status, native destination menus, keyboard shortcuts, and accessible action names. The file preview is local and bounded in size.

Keep the existing Send, Close, Open Figma, pairing, and queue behavior. Use readable secondary text rather than copying the video's faintest labels. Support macOS dark appearance with corresponding charcoal surfaces. Do not introduce the video's animated cursor effects or background wallpaper into this small utility.
