# Security policy

These scripts run as administrator and change machine-wide settings (ACLs, PATH, environment
variables, installed software). Please report security problems **privately** via
[GitHub private vulnerability reporting](../../security/advisories/new) instead of opening a public issue.

Design notes relevant to security:

- Downloads are pinned: uv by version + SHA256, Tesseract language data by commit + SHA256,
  winget packages by version (winget verifies installer hashes), Python packages by `uv.lock` hashes.
- `C:\DevTools` (tools, Python, agent venv, these scripts) is writable only by Administrators/SYSTEM.
- Shared caches under `C:\DevTools\cache` are writable by the `DevTools Writers` group
  (by default every account on the machine). Any member can tamper with cached packages used by
  others — only use shared caches between accounts that trust each other, and never run project
  code elevated.
