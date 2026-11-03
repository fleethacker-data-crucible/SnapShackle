# SnapShackle CLI and API

Every user-facing action that can run without a person at the screen is `snapshackle <noun> <verb>`. Its id is `snapshackle.<noun>.<verb>`. The studio button, the CLI and the local API call the same PowerShell function (`modules/Actions.ps1`). Discovery is `commands --json`. `help --json` prints the same document.

```bat
SnapShackle-CLI.bat commands --json
SnapShackle-CLI.bat help --json
SnapShackle-CLI.bat <noun> <verb> [--option value ...] [--json] [--out file] [--yes] [--dry-run]
SnapShackle-CLI.bat --job examples\training-course-handoff.json --json
```

`--yes` is `-Confirmed` for a destructive action. `--dry-run` previews and changes nothing. `--json` prints one result document. Job files are JSON only (`fleet.action.job/1`). The session token is read from `%LOCALAPPDATA%\SnapShackle\api-session.json`. It is never a command argument, never printed, and never put in the page markup.

The host already listens on `http://127.0.0.1:<port>/`. These routes call the same functions:

- `GET /api/actions` — the action catalog
- `POST /api/actions/<id>` — run one action. JSON body is the arguments. Destructive actions need `X-SnapShackle-Confirm: yes`. `session stop` also needs `X-SnapShackle-Intent: end-session`.

The older routes (`/api/library`, `/api/capture`, and the rest) are still there and call the same functions. Replace `<token>` and `<port>` from the session file. Do not paste a real token into a script that gets logged.

## What stays in the studio

These need a person or a browser permission, so they are not actions. `capture rect` is the headless form of drag-to-select.

| Control | Why it is not an action |
|---|---|
| Capture region, scrolling capture, browser tab, record, GIF | The browser share prompt, the selection overlay, or MediaRecorder |
| Annotation tools, undo, crop, layers, project JSON | The open canvas in the browser |
| Voice notes, camera and microphone lists | Browser permission prompts |
| Copy, export PNG or JPEG | The browser clipboard or a download of the open canvas |
| Redaction boxes | OCR boxes drawn on the open image. `evidence run` is the headless redaction path for synthetic windows |

`evidence run` still needs Windows, Windows OCR (unless `skipredact` is true) and an interactive desktop, because it draws its own windows. It is an action so a job can call it. The script `tools/evidence-capture.ps1` is unchanged and does not ask for `--yes`; the action does, because it replaces files in the output folder.

## Actions

### app health

Version, capture and OCR support, DPI mode, lifecycle.

```bat
SnapShackle-CLI.bat app health --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.app.health", "args": {} }
```

```bat
curl -s -H "X-SnapShackle-Token: <token>" http://127.0.0.1:<port>/api/actions/snapshackle.app.health
```

`app health` is a GET on the older route. The action route is POST:

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{}" http://127.0.0.1:<port>/api/actions/snapshackle.app.health
```

### app start

Start SnapShackle headless (no browser, no tray) and wait until it answers.

```bat
SnapShackle-CLI.bat app start --port 8765 --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.app.start", "args": { "port": 8765 } }
```

There is no curl for start: nothing is listening until it is up. Then use `app health`.

### screen list

```bat
SnapShackle-CLI.bat screen list --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.screen.list", "args": {} }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{}" http://127.0.0.1:<port>/api/actions/snapshackle.screen.list
```

### window list

```bat
SnapShackle-CLI.bat window list --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.window.list", "args": {} }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{}" http://127.0.0.1:<port>/api/actions/snapshackle.window.list
```

### capture screen

```bat
SnapShackle-CLI.bat capture screen --screen 0 --delay 0 --out C:\Fleet\desktop.png --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.capture.screen", "args": { "screen": 0, "delay": 0 } }
```

```bat
curl -s -H "X-SnapShackle-Token: <token>" "http://127.0.0.1:<port>/api/capture?screen=0" -o desktop.png
```

### capture window

```bat
SnapShackle-CLI.bat capture window --window 12345 --out C:\Fleet\window.png --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.capture.window", "args": { "window": 12345 } }
```

```bat
curl -s -H "X-SnapShackle-Token: <token>" "http://127.0.0.1:<port>/api/capture?window=12345" -o window.png
```

### capture rect

The headless form of drag-to-select.

```bat
SnapShackle-CLI.bat capture rect --x 0 --y 0 --w 800 --h 600 --out C:\Fleet\rect.png --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.capture.rect", "args": { "x": 0, "y": 0, "w": 800, "h": 600 } }
```

```bat
curl -s -H "X-SnapShackle-Token: <token>" "http://127.0.0.1:<port>/api/capture?x=0&y=0&w=800&h=600" -o rect.png
```

### ocr run

```bat
SnapShackle-CLI.bat ocr run --file C:\Fleet\desktop.png --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.ocr.run", "args": { "file": "C:\\Fleet\\desktop.png" } }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: image/png" --data-binary "@C:\Fleet\desktop.png" http://127.0.0.1:<port>/api/ocr
```

### library list

```bat
SnapShackle-CLI.bat library list --q course --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.library.list", "args": { "q": "course" } }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{\"q\":\"course\"}" http://127.0.0.1:<port>/api/actions/snapshackle.library.list
```

### library get

```bat
SnapShackle-CLI.bat library get --name SnapShackle-example.png --out C:\Fleet\got.png --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.library.get", "args": { "name": "SnapShackle-example.png" } }
```

```bat
curl -s -H "X-SnapShackle-Token: <token>" http://127.0.0.1:<port>/api/library/SnapShackle-example.png -o got.png
```

### library save

```bat
SnapShackle-CLI.bat library save --file C:\Fleet\desktop.png --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.library.save", "args": { "file": "C:\\Fleet\\desktop.png" } }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{\"file\":\"C:\\\\Fleet\\\\desktop.png\"}" http://127.0.0.1:<port>/api/actions/snapshackle.library.save
```

### library tag

```bat
SnapShackle-CLI.bat library tag --name SnapShackle-example.png --tags training,course --note "Lesson 1" --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.library.tag", "args": { "name": "SnapShackle-example.png", "tags": "training,course", "note": "Lesson 1" } }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{\"name\":\"SnapShackle-example.png\",\"tags\":\"training,course\",\"note\":\"Lesson 1\"}" http://127.0.0.1:<port>/api/actions/snapshackle.library.tag
```

### library delete

Destructive. Needs `--yes` or `X-SnapShackle-Confirm: yes`.

```bat
SnapShackle-CLI.bat library delete --name SnapShackle-example.png --yes --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.library.delete", "confirmed": true, "args": { "name": "SnapShackle-example.png" } }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "X-SnapShackle-Confirm: yes" -H "Content-Type: application/json" -d "{\"name\":\"SnapShackle-example.png\"}" http://127.0.0.1:<port>/api/actions/snapshackle.library.delete
```

### share list

```bat
SnapShackle-CLI.bat share list --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.share.list", "args": {} }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{}" http://127.0.0.1:<port>/api/actions/snapshackle.share.list
```

### share send

`kind` is `folder`, `clipboard`, `reveal` or `open`. Nothing is uploaded.

```bat
SnapShackle-CLI.bat share send --capture SnapShackle-example.png --kind folder --destination Lessons --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.share.send", "args": { "capture": "SnapShackle-example.png", "kind": "folder", "destination": "Lessons" } }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{\"capture\":\"SnapShackle-example.png\",\"kind\":\"folder\",\"destination\":\"Lessons\"}" http://127.0.0.1:<port>/api/actions/snapshackle.share.send
```

### ai status

Reports whether AI help is on, the router address, and where the key comes from. Never the key.

```bat
SnapShackle-CLI.bat ai status --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.ai.status", "args": {} }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{}" http://127.0.0.1:<port>/api/actions/snapshackle.ai.status
```

### ai describe

```bat
SnapShackle-CLI.bat ai describe --file C:\Fleet\desktop.png --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.ai.describe", "args": { "file": "C:\\Fleet\\desktop.png" } }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: image/png" --data-binary "@C:\Fleet\desktop.png" http://127.0.0.1:<port>/api/ai/alt-text
```

### ai suggest

```bat
SnapShackle-CLI.bat ai suggest --file C:\Fleet\desktop.png --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.ai.suggest", "args": { "file": "C:\\Fleet\\desktop.png" } }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: image/png" --data-binary "@C:\Fleet\desktop.png" http://127.0.0.1:<port>/api/ai/suggest
```

### settings show

```bat
SnapShackle-CLI.bat settings show --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.settings.show", "args": {} }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{}" http://127.0.0.1:<port>/api/actions/snapshackle.settings.show
```

### settings set

```bat
SnapShackle-CLI.bat settings set --key theme --value dark --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.settings.set", "args": { "key": "theme", "value": "dark" } }
```

```bat
curl -s -X PUT -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{\"theme\":\"dark\"}" http://127.0.0.1:<port>/api/settings
```

### session stop

Destructive. Needs `--yes` and, on the API, `X-SnapShackle-Intent: end-session`.

```bat
SnapShackle-CLI.bat session stop --yes --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.session.stop", "confirmed": true, "args": {} }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "X-SnapShackle-Confirm: yes" -H "X-SnapShackle-Intent: end-session" -H "Content-Type: application/json" -d "{}" http://127.0.0.1:<port>/api/actions/snapshackle.session.stop
```

### commands list

The registry the running host is serving.

```bat
SnapShackle-CLI.bat commands list --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.commands.list", "args": {} }
```

```bat
curl -s -H "X-SnapShackle-Token: <token>" http://127.0.0.1:<port>/api/commands
```

`commands --json` without `list` prints the same kind of document from this copy of the CLI, and does not need SnapShackle to be running.

### handoff list

Reads the capture folder for Bowerbird, Capstan and Scrimshaw. SnapShackle does not have to be running.

```bat
SnapShackle-CLI.bat handoff list --tag training --query course --includetext true --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.handoff.list", "args": { "tag": "training", "query": "course", "includetext": true } }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{\"tag\":\"training\",\"includetext\":true}" http://127.0.0.1:<port>/api/actions/snapshackle.handoff.list
```

The curl form uses the running host's library. The CLI can pass `--library` and does not need the host.

### handoff export

Copies PNGs and `handoff.json` into a folder. Never overwrites a file. `includetext` puts OCR text in the manifest so Capstan can name a lesson and Scrimshaw can import the slides. `dryrun` true writes nothing. The sample job is [examples/training-course-handoff.json](../examples/training-course-handoff.json).

```bat
SnapShackle-CLI.bat handoff export --tag training --query course --includetext true --outdir C:\Fleet\course-captures --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.handoff.export", "args": { "tag": "training", "query": "course", "includetext": true, "outdir": "C:\\Fleet\\course-captures", "dryrun": false } }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "Content-Type: application/json" -d "{\"tag\":\"training\",\"includetext\":true,\"outdir\":\"C:\\\\Fleet\\\\course-captures\",\"dryrun\":true}" http://127.0.0.1:<port>/api/actions/snapshackle.handoff.export
```

### evidence run

Destructive (it replaces files in the output folder). Needs `--yes`.

```bat
SnapShackle-CLI.bat evidence run --manifest tools\evidence-manifest.sample.json --outdir C:\Fleet\evidence --yes --json
```

```json
{ "schema": "fleet.action.job/1", "action": "snapshackle.evidence.run", "confirmed": true, "args": { "manifest": "C:\\Fleet\\SnapShackle\\tools\\evidence-manifest.sample.json", "outdir": "C:\\Fleet\\evidence", "skipredact": false } }
```

```bat
curl -s -X POST -H "X-SnapShackle-Token: <token>" -H "X-SnapShackle-Confirm: yes" -H "Content-Type: application/json" -d "{\"manifest\":\"C:\\\\Fleet\\\\SnapShackle\\\\tools\\\\evidence-manifest.sample.json\",\"outdir\":\"C:\\\\Fleet\\\\evidence\"}" http://127.0.0.1:<port>/api/actions/snapshackle.evidence.run
```

## Training to course

Capstan builds the lesson. Scrimshaw reviews it. SnapShackle's part is the captures. Tag them `training`, then run the sample job. With `dryrun` true it only reports what it would copy. Set `dryrun` to false, and point `outdir` at the folder Capstan and Scrimshaw import, when you want the files written.

```bat
SnapShackle-CLI.bat --job examples\training-course-handoff.json --json
```
