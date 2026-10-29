# SnapShackle walkthrough

Capture a window or region, annotate and redact it, read its text, and keep it in a searchable library.

> **Draft walkthrough.** The screenshots below have not been added yet. They must use demo data and be reviewed before publication. The image links will resolve when those screenshots are included.

## Before you start

- Windows PowerShell 5.1 (part of Windows). No administrator rights and no installer.
- Microsoft Edge or Google Chrome.
- Launch: Double-click `Launch-SnapShackle.bat` (opens the studio on `127.0.0.1`, port 8765 or the next free one).
- Closing the last studio tab normally stops the server, tray icon and hotkeys. See [Session lifecycle](../../README.md#session-lifecycle) for keeping hotkeys in the tray and ending a session.

## Steps

### 1. First launch

The studio opens with the capture toolbar and an empty **Library** tab.

![SnapShackle studio on first launch, with the capture toolbar and an empty Library tab.](../assets/walkthrough/01-first-launch.png)

### 2. Capture a window

Open **Capture**, choose **application window** and pick the window you want.

![SnapShackle Capture menu with Choose application window open and the demo Notepad window selected.](../assets/walkthrough/02-capture-window.png)

### 3. Annotate

Use the annotation tools to add arrows, shapes and text.

![SnapShackle editor with the demo capture, an arrow and a text label added with the annotation tools.](../assets/walkthrough/03-annotate.png)

### 4. Redact

Cover anything sensitive with a redaction box before you share the image.

![SnapShackle editor with the demo account line covered by a redaction box.](../assets/walkthrough/04-redact.png)

### 5. Read the text

**Extracted text** shows the text read from the capture, ready to copy.

![SnapShackle Extracted text panel showing the text read from the demo capture.](../assets/walkthrough/05-extract-text.png)

### 6. Find it later

**Library** keeps your captures, searchable by their text.

![SnapShackle Library tab listing the saved demo capture with its thumbnail and the search box.](../assets/walkthrough/06-library.png)

### 7. Set hotkeys

**Workflows** holds the hotkeys and the option to keep them in the tray after the tab closes.

![SnapShackle Workflows tab with the hotkey and tray settings.](../assets/walkthrough/07-workflows-settings.png)

## About these images

Screenshots will be stored in [`docs/assets/walkthrough/`](../assets/walkthrough/), named `NN-<screen>.png` after their step. Capture them at 1440x900, 100% scale, in the Dark theme, using demo data only. Review them for sensitive content before adding them.
