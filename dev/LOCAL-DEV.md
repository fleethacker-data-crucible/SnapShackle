# CutterMk — local development (no CAC)

Run `dev\Launch-LocalDev.bat` on your **personal Windows PC**. Do not use it on a managed system to evade organization security controls. The `dev/` folder is left out of release zips.

## What it does

- Prerequisite: Windows PowerShell 5.1 and desktop capture permissions.
- Startup: starts the localhost studio on preferred port 8790 using normal native Windows capture APIs.
- Boundary: the application never required CAC. Capture only personal test images, not sensitive workstation information.
- Diagnostics: `powershell.exe -NoProfile -File Start-CutterMk.ps1 -Port 8790 -Diagnostics`.
- One instance: the dev launcher passes `-Replace`, so it stops any running CutterMk first and says which PID it stopped. Closing the studio tab stops the dev server too; add `--stay` to keep it (and its tray icon) running. `Stop-CutterMk.ps1` stops every instance.

This is **not** an authenticated Navy session. Do not enter CUI, classified material, real credentials or real personnel information during personal-computer testing.
