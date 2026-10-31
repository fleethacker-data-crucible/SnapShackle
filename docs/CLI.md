# SnapShackle CLI and API

SnapShackle follows the Fleet CLI parity proposal (`proposals/cli-parity/` in the comms repo): the actions that make sense without a person at the screen have a named command, and the CLI and the local API come from the same registry, so neither can do something the other can't. No new install: the CLI is a script and a `.bat`, like the studio.

```bat
SnapShackle-CLI.bat commands
SnapShackle-CLI.bat <noun> <verb> [--option value ...] [--json] [--out <file>] [--yes] [--dry-run]
```

`SnapShackle-CLI.bat app start` starts SnapShackle headless (no browser, no tray, stays up until stopped); the other commands talk to a running SnapShackle, the studio's or the headless one. The browser studio is unchanged.

## Commands

| Command | What it does | Options |
|---|---|---|
| `app health` | Version, capture and OCR support, DPI mode, lifecycle mode. | |
| `app start` | Start SnapShackle headless and wait until it answers. | `--port` |
| `screen list` | Monitors and their bounds. | |
| `window list` | Visible windows (id and title). | |
| `capture screen` | Whole desktop or one monitor to a PNG. | `--out` (required), `--screen`, `--delay` |
| `capture window` | One window by id with PrintWindow, even where something covers it. | `--window`, `--out` (required), `--delay` |
| `capture rect` | A fixed screen rectangle to a PNG (headless form of drag-to-select). | `--x --y --w --h --out` (all required) |
| `ocr run` | Windows OCR on a PNG: text, lines, word boxes. Clear error where OCR is unavailable. | `--file` or `--name` |
| `library list` | Saved captures with tags and notes; a query also searches the text in the images. | `--q` |
| `library get` | A saved capture to a PNG file. | `--name`, `--out` (required) |
| `library save` | A PNG file into the library. | `--file` (required) |
| `library tag` | Tags and note of a capture. | `--name` (required), `--tags`, `--note` |
| `library delete` | Delete a capture. **Needs `--yes`**, logged. | `--name` (required) |
| `share list` | Where a capture can be shared: the share folders, clipboard, Explorer, default app. | |
| `share send` | Share a saved capture: copy into a share folder (never overwrites), file on the clipboard, show in Explorer, or open in the default app. Local only. | `--capture`, `--kind folder\|clipboard\|reveal\|open` (both required), `--destination` (folder name) |
| `ai status` | AI help state: on or off, router address, key source (never the key), privacy. | |
| `ai describe` | Alt text for a PNG through the Fleet router; needs `aiSuggest` on (see `docs/AI-HELP.md`). | `--file` (required) |
| `ai suggest` | Annotation suggestions for a PNG (positions as fractions of the image); needs `aiSuggest` on. | `--file` (required) |
| `settings show` | The saved preferences. | |
| `settings set` | Change preferences: `--key` with `--value`, or `--file` of JSON. Unknown keys are ignored. | |
| `session stop` | Stop SnapShackle, its tray and hotkeys. **Needs `--yes`**, logged. | |
| `commands list` | The command registry, as served by the running host. | |

`SnapShackle-CLI.bat commands --json` prints the registry (schema `snapshackle.commands/1`) with every option's type, location and whether it is required. The host serves the same document at `GET /api/commands`.

## Flags and results

- `--json` prints one document: `{"schema":"snapshackle.result/1","command":...,"ok":...,"result":...}`, or `error` and `errorType` (`usage`, `failed` or `notrunning`).
- `--out FILE` on a JSON command writes that document to FILE as UTF-8 without a BOM. On a PNG command it is the PNG to write, and the result gives its size and SHA-256.
- `--yes` is required by `library delete` and `session stop`. `--dry-run` shows the route and body without sending anything (the token is never shown).
- Exit codes: `0` success, `1` the command failed, `2` usage error, `3` SnapShackle is not running. Nothing waits on a dialog.

## How the API is locked to you

The CLI and the studio use the same local API on `127.0.0.1`: every request needs the per-session token, the `Host` and `Origin` headers are checked, no CORS headers are sent, and destructive routes need an explicit confirmation (`X-SnapShackle-Confirm: yes` for a delete, an intent header for stopping). Deletes and stops are written to `%LOCALAPPDATA%\SnapShackle\logs\snapshackle-audit.log` (name only, no content).

The CLI finds the port and token in `%LOCALAPPDATA%\SnapShackle\api-session.json`. That file is created empty, locked to your account with an explicit ACL (no inherited permissions), then filled; it is replaced on every start and removed on a clean stop. The token is never taken on the command line, printed, or written to the runtime file in `logs\`.

## What has no command, and why

Annotation, undo, crop, redaction boxes, export and clipboard buttons work on the open image in the browser. Screen and GIF recording, the browser's screen-share prompt and scrolling capture need the browser's media permission prompts, and drag-to-select needs a person at the overlay (`capture rect` is the headless form). Every studio button has either a command or a one-line reason in `modules/Cli.ps1`; `tests/commands_test.ps1` fails when a new button has neither. So CLI parity here is **partial**: capture, OCR, library, settings and lifecycle are covered, editing is not.

A new feature must add its command (or a reason) in the same change.

## Tests

- `tests/commands_test.ps1`: offline parity check. Fails if a host route or a studio button has no command or reason, a command names a missing route, the registry is malformed, a destructive route loses its confirmation, or the lockdown rules change.
- `tests/cli_test.ps1`: end to end on a real headless host in a temporary data folder, with synthetic PNGs and one synthetic window. Covers the session-file ACL, every command group, `--yes` and `--dry-run`, the audit log, usage errors and exit codes, and BOM-free `--out`. It never captures the real desktop. The window-capture case skips itself (and says so) in a session with no interactive desktop, such as a CI runner installed as a service.
