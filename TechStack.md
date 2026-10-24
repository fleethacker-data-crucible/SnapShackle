# Tech stack for local web apps

Local web apps: PowerShell 5.1 serves a browser UI on `127.0.0.1` (Edge/Chrome).

## Use

| Layer | Choice |
| --- | --- |
| Launcher | `.bat` → `powershell.exe -File` |
| Local server | PowerShell 5.1 + `TcpListener` on `127.0.0.1` |
| UI | React 19 + TypeScript, or Svelte 5 |
| Styling | Tailwind CSS 4 + shadcn-style (CVA, Radix, Lucide) |
| Charts / diagrams / motion | Apache ECharts, React Flow, Motion |
| Browser compute | Rust → WebAssembly |
| Storage | IndexedDB (data), localStorage (settings) |
| Offline | Service workers, Web Workers |
| Encryption | Web Crypto (AES-GCM) in browser; DPAPI from PowerShell for secrets at rest |
| Native Windows | C# via `Add-Type` (.NET 4.8.1); WinForms/WPF from PowerShell if needed |

## Build rules

- Build off-workstation; ship compiled JS/CSS/WASM only
- Bundle all deps — no CDNs or runtime network calls
- No admin, installers, or services on the workstation

## Lasso: how it applies

Lasso follows this stack with these choices and exceptions.

| Area | Lasso choice | Why |
| --- | --- | --- |
| UI framework | React 19 + TypeScript | Radix (shadcn-style) is React-only; shares components with ARC |
| Canvas editor | Framework-free TypeScript on `OffscreenCanvas` | React drives panels only, never pointer-move rendering |
| Browser compute | `lasso-core` Rust crate → WASM | Stitching, GIF quantization, perceptual hashing |
| Capture storage | PNG files under `%LOCALAPPDATA%\Lasso\Captures` (**exception**: not IndexedDB) | Real files survive browser resets and open in any tool |
| Settings | Server-side settings file (**exception**: not only `localStorage`) | Origin includes the port; a port fallback would otherwise reset settings |
| CSP | `script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'` | Required for WASM compilation and workers |
| Native | C# via `Add-Type`: WinForms overlay and tray, `PrintWindow`, DWM, `RegisterHotKey` | No installer, no admin |

Until the React/WASM build lands (roadmap Phase 2), the studio ships as plain browser JavaScript with no build step.
