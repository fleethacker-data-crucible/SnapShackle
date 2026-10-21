# SnipHero Studio v0.5

A **local-first Windows screenshot and annotation studio** using native Windows capture, a built-in PowerShell HTTP host, and an offline browser UI. Designed to run without Node, Python, npm, CDN, a package installer, or administrator rights on an authorized Windows workstation.

**Status:** An expanding prototype with a tested browser editor; **not production-hardened or feature-complete**. A genuine Windows desktop run and security review are required before use with sensitive work data.

![Studio smoke-test preview](docs/studio-preview.png)

## Run on Windows

1. Extract all files while preserving `assets/` and `modules/`.
2. From a regular, authorized PowerShell session, change to the extracted directory and run `./Start-SnipHero.ps1` (Windows PowerShell 5.1 is recommended). If your organization blocks script execution, follow your approved IT procedures; SnipHero does **not** need policy bypasses or elevated privileges.
3. The browser should open `http://localhost:8765/` automatically. If it does not, open that address manually. Keep the PowerShell console running; press Ctrl+C to stop the local server.
4. Captures are stored under `%LOCALAPPDATA%\SnipHero\Captures`. Preferences stay in the browser profile (`localStorage`); nothing is uploaded to the cloud by SnipHero.

The PowerShell host uses `HttpListener` bound to `localhost`, randomly generated session tokens for API requests, and origin/host checks. This is **single-user local software**, not an enterprise network service or authentication boundary against programs already running as your user. Port is configurable with `-Port 8766` and browser auto-launch can be disabled with `-NoBrowser`.

## Implemented functionality

| Area | What works | Caveats |
|---|---|---|
| Desktop screenshot | Entire desktop, selected monitor, selected visible window, native drag-to-select region | Standard `CopyFromScreen`; not minimized/occluded windows or DRM-protected content |
| Browser screenshot | Browser screen/window/tab capture after user permission | Browser support and permission required |
| Editor | Arrows, boxes, ellipses, lines, pen, highlighter, text, numbered steps, opaque redaction, pixelate, blur; layer reordering; drag and corner resizing; object duplication/deletion | Some object transforms remain simplified; complex multi-object grouping not available |
| History/project | Undo/redo, editable JSON project, crop, image import/paste/drag-drop, PNG/JPEG, clipboard, zoom | Save editable JSON **only for trusted local use**, since it includes the original pixels |
| Library | Save PNGs locally, browse thumbnails, search names/tags/notes, edit tags/notes, delete | No cloud sync or SQLite, limited to newest 250 search hits |
| Screen video | WebM via browser MediaRecorder | No system audio/MP4 without additional codecs; recording window/tab requires browser permission |
| Animated GIF | Offline dependency-free encoder; 640×480 max, 100 frames | 3-3-2 limited palette, unoptimized file sizes; tested for valid GIF decoding |
| Long screenshots | Automatic overlap-aware stitching of multiple screenshots; optional browser shared-screen sampling while **you scroll the target** | Not an autonomous scroll driver for arbitrary Windows apps; sticky headers/transitions can reduce stitching quality |
| OCR | Attempts Windows.Media.Ocr on PowerShell 5.1 where WinRT is available; tries browser TextDetector otherwise | Windows integration is **experimental and untested on a real Windows system**; browser API often missing |
| UI | Offline red/black workspace, Library/Layers/Workflows tabs, editable layers, status diagnostics, common focused-tab keyboard shortcuts | Not yet a fully audited accessible enterprise desktop application |

### Redaction safety

Pixelation and blur are **visual effects, not secure sanitization**. Opaque redaction hides annotated regions in flattened exported images, but editable `.sniphero.json` projects retain the unredacted original. Imported original files and other copies are unaffected. Inspect flattened exports and follow your organization's data handling policy.

### Known gaps

- No reliable **native global hotkeys** when the browser is unfocused; browser shortcuts work in the active studio tab.
- No universal autonomous scrolling through arbitrary external applications.
- No guaranteed OCR on every locked-down workstation.
- No signed installer, MSI, policy-managed settings, centralized telemetry, update service, multi-user permissions, or full enterprise accessibility certification.
- Not supported: panoramic capture, camera/PIP recording, timeline video editing, audio mixing, MP4 export, enterprise managed deployment, or share-destination integrations.

## Testing and development

Only development/testing requires Python, Pillow, Chromium/Playwright or Node. **Runtime has no dependency on these tools.**

- `node --check assets/editor.js` (also check `studio.js`, `gif.js`, and `stitch.js`)
- `python tests/static_check.py` checks source structure/routes and UI wiring.
- `python tests/browser_smoke.py` runs actual Chromium editor interactions against a simulated local capture API.
- `python tests/stitch_test.py` tests seam detection with overlapping synthetic screenshots.
- `node tests/gif_test.js` followed by `python tests/verify_gif.py` validates animated GIF decoding in Pillow.

Automated Chromium tests **do not** verify the native Windows capture/WinRT OCR integrations, or enterprise Nautilus compatibility. Test on a machine with the correct Windows desktop, PowerShell version, browser, and organization-approved policies.

## Project structure

```text
Start-SnipHero.ps1          Local HTTP host, capture API and library
modules/Native.ps1         Windows Forms region overlay and Win32 enumeration
modules/Ocr.ps1            Optional Windows 10+ OCR bridge
index.html                 Studio layout
assets/styles.css          Standalone responsive theme
assets/editor.js           Editable non-destructive object engine
assets/studio.js           App/controller, recording, library, workflows
assets/gif.js              Offline GIF89a encoder
assets/stitch.js           Overlap-aware long screenshot stitching
scripts/                   Optional development helpers
samples/                   (future) example projects
tests/                     Development-time browser and static tests
```

The runtime contains **original source code**; ShareX, Flameshot, Excalidraw, and Fabric.js were only feature/design references and are not bundled dependencies.