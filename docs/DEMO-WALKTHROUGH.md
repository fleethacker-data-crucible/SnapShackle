# Demo walkthrough (for a screen recording)

A script for a short demo video that shows SnapShackle capturing, annotating, redacting, finding and sharing, **without touching your real captures, settings or windows**. About six minutes. Everything on screen is synthetic.

## 0. Before you record

1. **Stop your real SnapShackle** (End session in the studio, or `Stop-SnapShackle.ps1`). A second copy would fight it for the hotkeys. Note that `Stop-SnapShackle.ps1` stops every SnapShackle on the computer, so do this *before* the demo copy starts, never after.
2. **Make a fresh data folder name** that does not exist yet, for example `C:\Demo\SnapShackle-run1`. SnapShackle will create it. Nothing is read from or written to `%LOCALAPPDATA%\SnapShackle`, and the CutterMk/Lasso/SnipHero migration is skipped because the folder is empty.
3. **Close private windows and apps.** The studio's *Capture window* list shows the title of every open window, and *Capture screen* shows the whole desktop. For a clean take, use the import path below and keep other apps closed.
4. Turn on Windows **Do not disturb** (so no notification lands in the recording) and use a browser profile with no personal bookmarks bar.
5. Make the synthetic screenshots:

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File tools\evidence-capture.ps1 `
  -Manifest tools\evidence-manifest.sample.json -OutDir C:\Demo\shots
```

The windows it draws flash on screen for about a second each, so run this *before* you start recording. The PNGs in `C:\Demo\shots` already have the sensitive text covered; add `-KeepRaw` if you want the unredacted ones to demonstrate redaction live (they contain only made-up data such as jane.doe@example.com).

## 1. Start with a data folder of its own

```bat
Launch-SnapShackle.bat --data-dir C:\Demo\SnapShackle-run1
```

or `powershell -NoProfile -STA -ExecutionPolicy Bypass -File Start-SnapShackle.ps1 -DataDir C:\Demo\SnapShackle-run1`. The console prints `Data folder: C:\Demo\SnapShackle-run1\SnapShackle (not %LOCALAPPDATA%)` in yellow: check it before you press record. `SNAPSHACKLE_DATA_DIR` does the same from the environment; the option wins. The folder must be a full path. Stop the demo copy with *End session* in the studio, which leaves your real SnapShackle untouched.

## 2. Scenes

| # | Say | Do |
|---|---|---|
| 1 | "SnapShackle runs on this computer; nothing is uploaded." | Show the studio. Point at the status bar and the *End session* button. |
| 2 | "Bring in a screenshot." | Drag `C:\Demo\shots\01-sign-in.png` into the studio (or *Import*). |
| 3 | "Annotate." | Draw a box (R), an arrow (A), add numbered steps (N) and a text note (T). Undo (Ctrl+Z) once to show it is reversible. |
| 4 | "Redact before you share." | Import `02-contact-card-raw.png` if you kept raw files. *Workflows, Smart redaction, Find sensitive text*: the email, phone, SSN and card appear as a checklist. Untick one, apply the rest, then Export to show the black boxes are in the pixels. |
| 5 | "Find it later." | Save to the library. Add tags and a note. Search for a word that is only *inside* the image: the library finds it by its OCR text. |
| 6 | "Share it." | Under Settings add a share folder, `Demo = C:\Demo\outbox` (create the folder first). In the Library choose the capture, destination *Demo (folder)*, Share. Show the file in Explorer. |
| 7 | "One more thing." | Optional, if the build has them: *Describe image* (needs a router, see `docs/AI-HELP.md`), a voice note on an annotation, a webcam corner on a screen recording. Skip anything that opens a permission prompt you have not rehearsed. |
| 8 | "Done." | *End session*. Show that the tray icon is gone. |

## 3. What not to do on camera

- Do not use *Capture screen*, *Capture window* or the browser's *Share your screen* picker unless the desktop holds only the synthetic windows: they show whatever is really open.
- Do not open the library of your real SnapShackle, your real `settings.json` or `%LOCALAPPDATA%`.
- Do not paste real tokens, emails or names into notes. The sample data uses `example.com` and the 555 phone range on purpose.

## 4. Clean up

Delete `C:\Demo\SnapShackle-run1` and `C:\Demo\shots` when you are done. Your own captures were never in them.

## Checks that back this page

`tests/data_dir_test.ps1` starts real hosts whose `LOCALAPPDATA` is an empty folder and proves that, with `-DataDir` or `--data-dir=`, the capture, its sidecar, the settings and the logs all land in the data folder and nothing is written to `LOCALAPPDATA`. Not tested automatically: the recording itself, the permission prompts, and the optional scenes in row 7.
