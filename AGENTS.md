# Agent notes

- No compatibility aliases. When a name changes, the old name is removed, never kept as a fallback. Local data is renamed by hand once.
- The Fairlead key is read from Windows Credential Manager (`Fairlead/SnapShackle`), then from the first line of `%LOCALAPPDATA%\Fairlead\local-token` when that credential is absent. Do not add environment-variable or vault fallbacks for it.
- Commit only as the configured git identity; no attribution lines or tool names in commit messages or PR text.
- Windows PowerShell 5.1 syntax in `.ps1` files.
