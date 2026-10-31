# SnapShackle capture format (contract, version 1)

Other Fleet apps read SnapShackle's captures: Bowerbird renames screenshots from their text, and Capstan and Scrimshaw import them. This page is the contract they can rely on. `tests/capture_format_test.ps1` saves a real capture through a real host and checks its sidecar against the field list below, so this page and the code cannot drift apart.

## Where captures live

```
%LOCALAPPDATA%\SnapShackle\Captures\
    SnapShackle-20261031-141502-123-1a2b3c4d.png
    SnapShackle-20261031-141502-123-1a2b3c4d.png.meta.json     (optional)
```

- One folder, no sub-folders. If `%LOCALAPPDATA%` is not set, `captures\` next to the app.
- Earlier names are still read: `CutterMk-`, `Lasso-` and `SnipHero-` (from `%LOCALAPPDATA%\CutterMk` and the older ones, copied forward on first start, never moved).
- A capture is **two files that belong together**: the PNG, and a sidecar named exactly `<png file name>.meta.json` (the full PNG name, `.png` included, then `.meta.json`).

## The PNG

- File name `SnapShackle-<yyyyMMdd>-<HHmmss>-<fff>-<8 hex>.png`: local time, millisecond, then a random suffix, so names never collide. The library lists only names matching `(SnapShackle|CutterMk|Lasso|SnipHero)-[A-Za-z0-9_.-]+.png`.
- Standard lossless PNG at the screen's physical pixels (the host runs per-monitor DPI aware). No transparency is promised. SnapShackle never edits a saved PNG in place; the annotated version is exported or saved as a new capture.
- Saved as-is from the capture, so it carries no SnapShackle-specific chunks. Do not rely on any metadata inside the PNG; use the sidecar.

## The sidecar `<name>.png.meta.json`

UTF-8 without a byte-order mark, one JSON object. **Optional**: a capture with no tags, no note and no recognised text may have none. Readers must treat a missing sidecar as `tags: []`, `note: ""`, `ocr: ""`.

| Field | Type | Meaning |
|---|---|---|
| `schema` | string | `snapshackle.capture/1`. Absent in sidecars written before this page existed: read those as version 1. |
| `tags` | array of strings | Labels the person gave. At most 20, each at most 40 characters. |
| `note` | string | Free text, at most 2000 characters. |
| `ocr` | string | The text Windows OCR found in the image, lines joined by the OCR engine's own line breaks, at most 20000 characters. Empty when OCR is unavailable (not installed, or no language pack), when the image holds no text, or until the background indexing after a save has finished. |

The machine-readable form of that table (the test reads this block):

```json capture-sidecar
{
  "schema": "snapshackle.capture/1",
  "fields": {
    "schema": { "type": "string", "value": "snapshackle.capture/1" },
    "tags":   { "type": "string[]", "maxItems": 20, "maxLength": 40 },
    "note":   { "type": "string", "maxLength": 2000 },
    "ocr":    { "type": "string", "maxLength": 20000 }
  }
}
```

### Rules for readers

- Ignore fields you do not know; a future minor change may add some. A change to a field above, or removing one, changes the number after the `/` in `schema`; read only versions you know, and fall back to the PNG alone for the rest.
- Do not parse positions out of `ocr`: it is plain text. Word and line boxes are not stored. `POST /api/ocr` returns them for a PNG on demand.
- `ocr` may contain recognition errors and can hold sensitive text from the screen. Treat the sidecar like the PNG.

### Rules for writers (other apps)

- **Rename or move a capture only by moving both files together**, keeping the sidecar name equal to the PNG name plus `.meta.json`. SnapShackle's library lists only names that match the pattern above, so a capture renamed to a name outside it stays on disk but no longer shows in the library. Keep the `SnapShackle-` prefix (for example `SnapShackle-quarterly-report-1a2b3c4d.png`) if it should stay listed.
- **Do not add fields to a sidecar.** SnapShackle rewrites the whole file when a person edits tags or a note, and writes only the four fields above. Keep your own data in your own file.
- Writing a new capture from outside: put a PNG in the folder under a valid name. `POST /api/library` with the session token does this and also indexes the text.
- Deleting a capture removes the PNG and its sidecar.

## Versioning

`schema` is `snapshackle.capture/<major>`. Version 1 is this page. Adding an optional field does not change the number; anything that would break a version 1 reader does, and then this page keeps the version 1 text alongside the new one.
