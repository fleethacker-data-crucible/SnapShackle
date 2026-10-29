# SnapShackle walkthrough

Capture a window or region, annotate and redact it, read its text, and keep it in a searchable library.

> **Illustrated walkthrough.** These seven screenshots show the Windows studio with a synthetic maintenance note. The images were reviewed for visible sensitive content before inclusion.

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

Choose a window in **Choose application window** at the top, then click **Window** in the left capture toolbar. This example captures a dedicated demo note, not the whole desktop.

![SnapShackle studio after native window capture, with the synthetic demo note selected in Choose application window.](../assets/walkthrough/02-capture-window.png)

### 3. Annotate

Select **Arrow** and drag toward the inspection status. Use **Steps** to add a numbered callout. **Layers** lists the annotations so you can select and adjust them.

![SnapShackle editor with the demo capture, an arrow and a numbered step added, with both annotations listed in Layers.](../assets/walkthrough/03-annotate.png)

### 4. Redact

Select **Redact** and drag a solid box over the value to hide. Here it covers a dummy account value. Share a flattened PNG; an editable project retains the original image and its annotations.

![SnapShackle editor with the demo account line covered by a redaction box.](../assets/walkthrough/04-redact.png)

### 5. Read the text

Open **Workflows** and click **Extract text**. Windows OCR fills **Extracted text**, ready to review and copy. In this example the text contains the equipment and inspection status, while the covered dummy account value is absent. Always review OCR before using it.

![SnapShackle Extracted text panel showing the text read from the demo capture.](../assets/walkthrough/05-extract-text.png)

### 6. Find it later

In **Library**, click **Save current**. Add tags and notes, then **Save details**. Searching for **Training pump** finds this capture through its extracted text, as shown.

![SnapShackle Library tab listing the saved demo capture with its thumbnail and the search box.](../assets/walkthrough/06-library.png)

### 7. Choose session and recording settings

Scroll to **Settings** in **Workflows**. **Keep hotkeys in the tray after this tab closes** controls whether the session stays available after the studio closes. This screenshot also shows recording frame rate, sound off, and the Dark theme. See [Session lifecycle](../../README.md#session-lifecycle) for the exact startup and shutdown options.

![SnapShackle Workflows settings showing the tray option, recording frame rate, sound off and Dark theme.](../assets/walkthrough/07-workflows-settings.png)

## About these images

Captured 29 October 2026 from the Windows application at a 1440x900 browser viewport, 100% browser scale, in the Dark theme. Images are stored in [`docs/assets/walkthrough/`](../assets/walkthrough/). The native source window contains synthetic data only, and the capture library uses an isolated demo profile.

Native window capture, annotation, redaction, Windows OCR, saving and OCR-text search were exercised. Global hotkeys were not registered during this documentation session, and audio/video recording was not exercised. The settings screenshot shows the available choices.
