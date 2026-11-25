# windows-devtools-setup

[![CI](https://github.com/honghuy127/windows-devtools-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/honghuy127/windows-devtools-setup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

PowerShell scripts that install **one shared, version-pinned developer toolchain per Windows machine**,
used by every user and every AI coding agent (Claude Code, Codex, …) on it. One copy of Python, packages,
browsers and models instead of one per user saves disk space and keeps everyone on the same versions.
Nothing is tied to a particular user or machine.

## What you get

| Area | Details |
|---|---|
| Python | [uv](https://github.com/astral-sh/uv) + CPython 3.13 in `C:\DevTools` (read-only for users, Python downloads disabled) |
| Default `python` | A shared, read-only venv `C:\DevTools\envs\agent` with Office (python-docx, openpyxl, python-pptx, markitdown), PDF (pypdf, pdfplumber, pypdfium2, reportlab), OCR (pytesseract), web (Playwright + Chromium, requests, httpx, BeautifulSoup, trafilatura) and data (pandas, numpy, matplotlib) packages, locked in `agent-env/uv.lock` |
| Shared caches | uv, Hugging Face (hub + xet), torch, Playwright browsers, models — under `C:\DevTools\cache` with SID-based ACLs |
| Tools (winget, machine scope) | Git, Node.js LTS, CMake, Ninja, FFmpeg, ripgrep, jq, GitHub CLI, VS Code (System), LibreOffice, Pandoc, Tesseract with eng/vie/jpn/chi data; optional VS Build Tools |
| Windows / Git settings | Long paths, Developer Mode (unprivileged symlinks), `PYTHONUTF8=1`, `PIP_REQUIRE_VIRTUALENV=1`, `core.longpaths`, optional `safe.directory` |
| Agent instructions | Written to Claude Code's managed `C:\Program Files\ClaudeCode\CLAUDE.md` (all users) and each Codex user's `~\.codex\AGENTS.md` |

Every download is pinned: uv by version + SHA256, Python packages by `uv.lock` hashes, winget packages
by version (winget verifies installer hashes), Tesseract language data by commit + SHA256.

## Install on a new machine

Requirements: Windows 10/11 x64, an administrator account, `winget` (App Installer), internet access.

1. **Turn off Smart App Control** if it is on (Windows Security → App & browser control →
   Smart App Control). It blocks the unsigned `python.exe`; setup stops early if SAC is on.
2. In **PowerShell (Run as administrator)**:
   ```powershell
   git clone https://github.com/honghuy127/windows-devtools-setup.git
   cd windows-devtools-setup
   powershell -ExecutionPolicy Bypass -File .\Install-DevTools.ps1
   ```
   - No git yet? Download the ZIP and run `Unblock-File .\windows-devtools-setup-main.zip` before
     extracting, otherwise Windows blocks scripts downloaded from the internet.
   - `-ExecutionPolicy Bypass` only applies to this run (Windows doesn't run `.ps1` files by default).

   The kit copies itself to `C:\DevTools\setup` (writable by administrators only).
3. Every user **signs out and back in**, then runs (normal, non-elevated PowerShell):
   ```powershell
   C:\DevTools\setup\Test-DevTools.ps1
   ```
   Also run it once from inside each agent (e.g. Codex) to check its sandbox accounts.

### Options (`Install-DevTools.ps1`)

| Option | Effect |
|---|---|
| *(default)* | Shared caches, writable by **every account** on the machine (incl. new users and agent sandbox accounts) |
| `-Writers Members -WriterMembers alice,bob` | Only these accounts (and whoever an admin adds to the `DevTools Writers` group) may write the caches |
| `-PrivateCaches` | No shared caches; only Python itself is shared |
| `-SharedRepoRoots D:\Projects` | Add to `git safe.directory` (repos shared between users) |
| `-InstallBuildTools` | Install VS Build Tools (C++) via winget |
| `-NoDeveloperMode` | Don't enable Developer Mode (Hugging Face then can't use symlinks) |
| `-SkipAgentEnv`, `-SkipAgentInstructions` | Skip step 2 / 3 below |

## Components

| File | Purpose |
|---|---|
| `Install-DevTools.ps1` | Entry point: runs the three scripts below in order |
| `Setup-DevTools.ps1` | uv + Python, shared caches and ACLs, machine environment variables, winget tools, Tesseract data, Windows and Git settings. All versions live in the `$Pinned` table at the top |
| `Install-AgentEnv.ps1` | Builds `C:\DevTools\envs\agent` from `agent-env/uv.lock`, installs Chromium, makes it the default `python` (`-NoDefault` to opt out), adds `agent-python` |
| `Install-AgentInstructions.ps1` | Writes `agent-instructions.md` into Claude Code / Codex instruction files inside a BEGIN/END block (user text is preserved; `-Remove` to undo) |
| `Test-DevTools.ps1` | Per-user verification, including an Office/PDF/OCR/web/browser smoke test (`agent-env/smoke_agent_env.py`) |

## Changing versions or packages

- Tools, uv, Python, OCR data: edit `$Pinned` at the top of `Setup-DevTools.ps1`.
- Agent Python packages: edit `agent-env/pyproject.toml`, then `Install-AgentEnv.ps1 -Relock`
  (or `-Upgrade` to bump everything) and commit the updated `uv.lock`.
- Agent instructions: edit `agent-instructions.md`.

## Updating machines

Change things in this repo (CI checks every push), then on each machine, in an elevated PowerShell:

```powershell
cd windows-devtools-setup; git pull
powershell -ExecutionPolicy Bypass -File .\Install-DevTools.ps1
```

The copy in `C:\DevTools\setup` is overwritten from the repo; don't edit it in place.

## Security notes

Setup runs as administrator and changes machine-wide settings. Shared caches are writable by the
`DevTools Writers` group (by default every account), so any of those accounts can tamper with cached
packages used by the others — share caches only between accounts that trust each other, and never run
project code elevated. See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

[MIT](LICENSE)
