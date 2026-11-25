# Security

These scripts run as administrator and change things machine-wide: file permissions, PATH,
environment variables and installed software. If you find a security problem, please report it
privately through [GitHub's vulnerability reporting](../../security/advisories/new) rather than
opening a public issue.

A bit of background that may help when looking for problems:

- Everything that gets downloaded is pinned. uv is checked against a SHA256, Python packages
  against the hashes in `uv.lock`, and Tesseract language data against a fixed commit and SHA256.
  For winget packages, the version is pinned and winget verifies the installer hash.
- `C:\DevTools` (the tools, Python, the shared venv and these scripts) can only be written by
  Administrators and SYSTEM.
- The shared caches in `C:\DevTools\cache` are the deliberate exception. Members of the
  `DevTools Writers` group (by default, every account on the machine) can write there, which also
  means they could tamper with a cached package someone else uses later. That's the trade-off for
  sharing caches, so only do it between accounts that trust each other.
