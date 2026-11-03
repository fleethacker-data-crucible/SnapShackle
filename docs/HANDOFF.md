# Hand-off to Bowerbird, Capstan and Scrimshaw

`tools/handoff.ps1` lists SnapShackle captures, or copies chosen ones to a folder with a manifest. It reads the capture folder directly (`%LOCALAPPDATA%\SnapShackle\Captures`), so SnapShackle does not have to be running, and it never changes a capture. No network.

```powershell
# What is there? (table, or one JSON document with -Json)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\handoff.ps1 -Mode list -Tag q3 -Since 2026-10-01 -Json

# Copy chosen captures to a hand-off folder
powershell -NoProfile -ExecutionPolicy Bypass -File tools\handoff.ps1 -Mode export -OutDir C:\handoff -Query "readiness" -IncludeText
```

Filters (both modes): `-Query` (name, tags, note and the text in the image), `-Tag`, `-Since`, `-Name a.png,b.png`, `-Max` (default 200, at most 250). `-IncludeText` adds each capture's OCR text. `-DryRun` shows what export would copy and writes nothing. Exit codes: 0 done, 1 failed (for example no capture folder), 2 wrong arguments.

## What export writes

- Each PNG, unchanged, and its `.png.meta.json` sidecar when it has one (no sidecar is invented).
- `handoff.json` (UTF-8, no byte-order mark), schema `snapshackle.handoff/1`:

```json
{ "schema": "snapshackle.handoff/1", "source": "SnapShackle", "createdAt": "2026-10-31T14:02:11.0000000-04:00", "count": 1,
  "captures": [ { "name": "SnapShackle-20261031-100000-001-aaaaaaaa.png", "file": "SnapShackle-20261031-100000-001-aaaaaaaa.png",
    "bytes": 48213, "modified": "2026-10-31T10:00:00.0000000-04:00", "sha256": "...", "tags": ["ops"], "note": "first",
    "sidecar": true, "ocrChars": 26, "ocr": "Quarterly readiness report" } ],
  "skipped": [] }
```

`ocr` is present only with `-IncludeText`; `ocrChars` always is. A file already in the output folder is never overwritten: it is listed under `skipped`. The output folder cannot be the capture folder or inside it. The manifest holds no folder paths.

## For the receiving apps

- **Bowerbird:** propose a name from `ocr` (export with `-IncludeText`), and rename the PNG and its sidecar together (the sidecar name is the PNG name plus `.meta.json`). Keep the `SnapShackle-` prefix if the capture should stay in SnapShackle's library.
- **Capstan, Scrimshaw:** import the PNGs listed in `captures`; check `sha256` if you want to be sure a file is the one listed. `tags` and `note` are the person's labels.

The sidecar fields are `tags` (array of strings), `note` and `ocr` (strings), plus `schema` in newer files; unknown fields should be ignored.
