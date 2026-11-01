# AI help through the Fleet router

Optional and off by default. It adds two things for the open image: **Describe image** (alt text) and **Suggest annotations** (a list you tick before anything is added). It follows the Fleet relationship contracts: one address for every model call, and each app's own key installed by Fairlead.

## How it works

1. Under Workflows, Settings, set **AI help** to On and Save. **AI privacy** stays on *Local models only* unless you change it: SnapShackle then sends `X-Fairlead-Privacy: local`, and the router keeps the image on local models.
2. The studio sends the open image (annotations included) to SnapShackle's own host, `/api/ai/alt-text` or `/api/ai/suggest`. The **host** calls the router, so the key never reaches the page. Images over 1568 px on the long side are scaled down first. For suggestions the host also reads the image's text with Windows OCR (when available) and gives it to the model as a hint.
3. The host calls `POST /v1/chat/completions` on the router with `model: auto` (the router picks a vision-capable model), SnapShackle's Bearer client key, and `X-Fairlead-Label: SnapShackle`.
4. Alt text appears in a box: copy it, or put it in the capture's note field. Suggestions appear as a checklist; **Add checked** adds them as normal annotations, and one Undo removes them together. Nothing is added without that click.

## Settings and environment

| Name | Meaning | Default |
|---|---|---|
| `aiSuggest` (setting) | `off` or `on` | `off` |
| `aiPrivacy` (setting) | `local` or `any` | `local` |
| `SNAPSHACKLE_FAIRLEAD_URL` | Router address. Only `http://127.0.0.1:<port>`, `localhost` or `[::1]` is accepted | `http://127.0.0.1:8776` |

The key is read only from Windows Credential Manager: the generic credential `Fairlead/SnapShackle`, which Fairlead writes when you install a key for the app. There is no environment variable or vault item for it. With no key installed, a call stops with "Open Fairlead and install a key for SnapShackle." The key is held in memory only: never in settings, files, logs, API answers or the page. (`SNAPSHACKLE_FAIRLEAD_TARGET` exists for tests; it can only name another `Fairlead/SnapShackle-<name>` credential.)

## What leaves the host

Only the PNG (scaled), a fixed instruction, and (for suggestions) the OCR text, and only to the router address above. An error from the router is shown in plain words; the key is never part of one.

## Command line

`SnapShackle-CLI.bat ai status`, `ai describe --file shot.png` and `ai suggest --file shot.png` call the same routes (`--json` for the document). Turn AI help on first: `settings set --key aiSuggest --value on`.

## Tests

`tests/ai_router_test.ps1` runs against `tests/fake_router.ps1` (no real router, no network): address rules, the key read from Credential Manager, suggestion clean-up, a refused key, a router that is down, off by default, headers and image reaching the router, the key kept out of settings, files and answers. `tests/aisuggest_test.js` and `tests/ai_ui_test.py` cover the panel. A live check against a real Fairlead is not part of the automated tests.
