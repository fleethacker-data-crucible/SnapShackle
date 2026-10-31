# AI help through the Fleet router

Optional and off by default. It adds two things for the open image: **Describe image** (alt text) and **Suggest annotations** (a list you tick before anything is added). It follows the Fleet relationship contracts: one address for every model call, one vault for the key.

## How it works

1. Under Workflows, Settings, set **AI help** to On and Save. **AI privacy** stays on *Local models only* unless you change it: SnapShackle then sends `X-Fairlead-Privacy: local`, and the router keeps the image on local models.
2. The studio sends the open image (annotations included) to SnapShackle's own host, `/api/ai/alt-text` or `/api/ai/suggest`. The **host** calls the router, so the key never reaches the page. Images over 1568 px on the long side are scaled down first. For suggestions the host also reads the image's text with Windows OCR (when available) and gives it to the model as a hint.
3. The host calls `POST /v1/chat/completions` on the router with `model: auto` (the router picks a vision-capable model), a Bearer client key if there is one, and `X-Fairlead-Label: snapshackle`.
4. Alt text appears in a box: copy it, or put it in the capture's note field. Suggestions appear as a checklist; **Add checked** adds them as normal annotations, and one Undo removes them together. Nothing is added without that click.

## Settings and environment

| Name | Meaning | Default |
|---|---|---|
| `aiSuggest` (setting) | `off` or `on` | `off` |
| `aiPrivacy` (setting) | `local` or `any` | `local` |
| `SNAPSHACKLE_AI_ENDPOINT_URL` (or `LLM_URL`) | Router address. Only `http://127.0.0.1:<port>`, `localhost` or `[::1]` is accepted | `http://127.0.0.1:8776` |
| `SNAPSHACKLE_ROUTER_KEY` | The client key (`fl-...`), set by a launcher that already unlocked the vault | none |
| `SNAPSHACKLE_LAZARETTE_ITEM_Router` | Name of the vault item that holds the key | `snapshackle-router-key` |

The key is looked up in this order: the environment variable; then the vault item, **only if** Lazarette's `Get-LazaretteSecret` (or `Get-ArcSecret`) is already loaded and unlocked in the process that runs the host; otherwise no key (the router lets this computer in without one when it is set that way). Lazarette unlocks interactively by design, so a hidden host cannot unlock it by itself. The key is held in memory only: never in settings, files, logs, API answers or the page.

The vault item name is for the Fleet items table in Lazarette (`docs/FLEET-ITEMS.md`): Service `snapshackle-router-key`, secret = the client key from `fairlead clients add`.

## What leaves the host

Only the PNG (scaled), a fixed instruction, and (for suggestions) the OCR text, and only to the router address above. An error from the router is shown in plain words; the key is never part of one.

## Command line

`SnapShackle-CLI.bat ai status`, `ai describe --file shot.png` and `ai suggest --file shot.png` call the same routes (`--json` for the document). Turn AI help on first: `settings set --key aiSuggest --value on`.

## Tests

`tests/ai_router_test.ps1` runs against `tests/fake_router.ps1` (no real router, no network): address rules, key lookup, suggestion clean-up, a refused key, a router that is down, off by default, headers and image reaching the router, the key kept out of settings, files and answers. `tests/aisuggest_test.js` and `tests/ai_ui_test.py` cover the panel. A live check against a real Fairlead is not part of the automated tests.
