# Evidence capture: repeatable, redacted demo screenshots

`tools/evidence-capture.ps1` makes the evidence screenshots for a demo or a submission the same way every time.
It draws a list of **named synthetic windows**, captures each with `PrintWindow`, finds sensitive text with Windows
OCR, covers it with opaque black boxes, reads the result again to prove nothing is left, and writes the PNGs and an
`evidence-index.json`.

It only captures windows it draws itself. It never copies the screen, so nothing from the real desktop can end up
in the evidence. Windows PowerShell 5.1, no admin, no installs, nothing uploaded.

## Run it

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File tools\evidence-capture.ps1 `
  -Manifest tools\evidence-manifest.sample.json -OutDir evidence-out
```

Each window flashes on screen for about a second while it is captured. Do not type into other apps meanwhile.

| Option | What it does |
| --- | --- |
| `-Manifest` | JSON file listing the windows (below). |
| `-OutDir` | Where `NAME.png` and `evidence-index.json` go. Same names are replaced. |
| `-KeepRaw` | Also keep `NAME-raw.png`, the unredacted synthetic window. Off by default. |
| `-SkipRedact` | Capture only, no OCR. The index says `redacted: false`; do not use those files as evidence. |
| `-Json` | Print the index on stdout instead of a summary. |

Exit code 0 means every window was captured and redacted. Exit code 1 means a problem, listed as `PROBLEM:` lines
and in the index (`ok: false`): OCR unavailable, a manifest error, an **expected** finding that OCR did not make, or
text still readable after redaction.

## Manifest

```json
{
  "redactTerms": ["Starling"],
  "windows": [
    {
      "name": "02-contact-card",
      "title": "Fleet Demo - Contact card",
      "width": 900, "height": 460, "fontSize": 24,
      "lines": ["Contact: John Smith", "Phone: 757-555-0142", "SSN: 123-45-6789"],
      "expect": ["phone", "ssn"],
      "redactTerms": ["John Smith"],
      "boxes": [{ "x": 30, "y": 300, "w": 200, "h": 30 }]
    }
  ]
}
```

* `name`: file name, letters, digits, `.`, `-`, `_`. Unique (any case). Up to 40 windows.
* `lines`: the text in the window. Use **synthetic** data only (`example.com`, `555` phone numbers, test card numbers).
* `expect`: kinds that must be found (`email`, `ssn`, `card`, `dodid`, `phone`, `ip`). If OCR misses one, the run fails.
  Always set this for windows that are meant to contain sensitive-looking text.
* `redactTerms` (top level or per window): extra words or phrases to cover, ignoring case.
* `boxes`: fixed boxes in pixels of the captured image (the title bar is part of it), for text OCR is known to miss.
* `title`, `width`/`height` (200-1800 by 120-1200), `fontSize` (12-48) are optional.

## What the index holds

`evidence-index.json` has, per file: name, size, SHA-256, capture method, whether it was redacted, counts per kind of
what was covered, the number of fixed boxes, and what was still readable afterwards (should be 0). It never holds the
text that was covered.

## Known limits

* **OCR can silently miss text.** On the machine this was built on, Windows OCR returned nothing for any line that held
  the well-known `4111 1111 1111 1111` test card number (the rest of the window read fine), and read `5500 0000 0000
  0004` normally. The cause is not confirmed. The verification pass cannot catch text OCR never reads, so always set
  `expect` for what the window is meant to contain, look at the PNGs, and use `boxes` where OCR is unreliable. The
  sample manifest uses the second card number for that reason.
* The check reads the result with the same OCR that found the text, so it proves the OCR-visible text is gone, not
  that no human could read anything.
* Pixelation and blur are never used; only opaque boxes.
* Run it on the target machine (OCR language pack, display scaling) before relying on it for a submission; the
  studio's own *Find sensitive info* uses the same patterns (`assets/redact.js` and `modules/Redact.ps1` are kept in step).

## Tests

* `powershell -NoProfile -File tests\redact_ps_test.ps1`: the detection patterns and box drawing, no OCR needed.
* `powershell -NoProfile -STA -File tests\evidence_capture_test.ps1`: end to end on synthetic windows with real OCR
  (skips where OCR is missing; `-RequireOcr` fails instead).
* `python tests/redact_flow_test.py`: the studio's redaction messages with a mocked OCR.
