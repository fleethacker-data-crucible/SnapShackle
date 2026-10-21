# SnipHero Studio — expanded Windows/Browser implementation

SnipHero is a local-only screenshot capture and editing workstation. The host is **Windows PowerShell 5.1 or PowerShell 7 on Windows** with Windows Forms and System.Drawing; the editor runs in a modern browser. No Node, Python, package manager, cloud service, or CDN is needed to run the app. No privilege escalation, execution-policy bypass, or administrator rights are built in. Use only on authorized workstations.

## Start

Extract the complete folder. In an authorized PowerShell console, run `./Start-SnipHero.ps1`. Open `http://localhost:8765/` if the browser does not launch. Stop the PowerShell process with Ctrl+C. Captures are stored in `%LOCALAPPDATA%/SnipHero/Captures`. The server binds only to localhost and uses a random session token for its API routes. **Anyone with local access to the server/browser session can still interact with it; it is not designed as a multi-user or network service.**

## Implemented source

- **Windows desktop capture:** virtual desktop, individual displays, enumerated visible window rectangles, coordinate capture and a genuine topmost drag-to-select native region overlay with Escape to cancel. Window capture uses `CopyFromScreen` over the window rectangle, not protected-window or minimized-window capture. DPI awareness requested where available.
- **Browser editor:** selectable, draggable object annotations (arrows, lines, rectangles, ellipses, text, numbered steps, freehand pen, highlighter), layer ordering, duplication, delete, editing text, history, zoom, color/width/font options, blur, pixelation and opaque redaction. Save/load editable JSON projects, flatten to PNG/JPEG, clipboard copy and image import/paste.
- **Capture library:** locally saved PNGs, searchable filename/tags/notes, delete and metadata editing. Settings persist in browser localStorage. Captures can auto-save.
- **Recording:** browser `getDisplayMedia` + `MediaRecorder` to WebM (requires supported browser and explicit user screen-share permission); custom offline JavaScript GIF encoder with bounded 640×480 / 120-frame output. The GIF encoder is intentionally constrained to prevent excessive memory usage.
- **Long capture:** manual vertical tile stitching; you capture/scroll/add successive screenshots. Does not yet align overlaps or automatically scroll external applications.
- **OCR:** browser `TextDetector` if supported; most desktop browsers do not expose this API. OCR is *not universally functional* and no bundled Windows OCR implementation is claimed.
- **Workflow:** naming prefix, auto-library save, keyboard shortcuts within focused browser tab, and project save/load.

## Technical limitations

This is **not feature-complete**. Automatic scrolling in arbitrary Windows applications, native system-wide hotkeys, universally supported OCR, high-fidelity audio recording, MP4 encoding, sophisticated object handles/resize, and enterprise packaging/signing are not implemented. GIF export is limited by browser memory. Captures of protected content may be blank. Browser capture permission is mandatory. The PowerShell region overlay may appear behind a foreground UAC secure desktop and cannot capture that desktop. `CopyFromScreen` is not a replacement for Windows Graphics Capture or DXGI desktop duplication.

**Privacy:** blur and pixelation are not secure redaction. For sensitive data, use opaque redaction, export flattened PNG and inspect. Editable project files contain the original unredacted background. Do not use a saved project as proof of irreversible sanitization.

## Verification

`python tests/static_check.py` runs offline static assertions on the source archive (development-time only, Python is not needed on the workstation). Windows runtime and browser interaction tests are not available in the Linux build environment. Before production deployment, test each feature on an authorized Windows machine and review local security policy.

## Third-party references

ShareX, Flameshot, Excalidraw and Fabric.js were consulted conceptually for feature direction. No third-party source was incorporated or vendored. The runtime is original PowerShell/C#/JavaScript source.