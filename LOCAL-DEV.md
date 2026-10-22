# SNIPHERO — local development (no CAC)

Run `Launch-LocalDev.bat` on your **personal Windows PC** after checking out the feature branch. Do not run on a managed system to evade organization security controls.

## What it does

- Prerequisite: Windows PowerShell 5.1 and desktop capture permissions.
- Startup: Starts localhost screenshot studio using normal native Windows capture APIs.
- Boundary: The application never required CAC. Capture only personal test images, not sensitive workstation information.
- Diagnostics / manual check: `powershell.exe -NoProfile -File Start-SnipHero.ps1 -Port 8790 -Diagnostics`.

## Workflow

```powershell
git fetch origin
git switch feature/local-dev-no-cac-launcher
.\Launch-LocalDev.bat
```

Normal launchers and production authentication remain unchanged. This is **not** an authenticated Navy session. Do not enter CUI, classified material, real credentials or real personnel information during personal-computer testing.

For release, delete the local development launcher from the release branch or leave it out of the release package. Real connections must continue to require approved credentials and authorization.
