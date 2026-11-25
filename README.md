# windows-devtools-setup

[![CI](https://github.com/honghuy127/windows-devtools-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/honghuy127/windows-devtools-setup/actions/workflows/ci.yml)

A few PowerShell scripts that give a Windows machine one shared development environment, used by
everyone who logs into it — people and AI coding agents alike.

## Why

On a machine shared by several people who all run Claude Code or Codex, things get messy fast.
Every account ends up with its own Python, its own copy of the same packages, its own Playwright
browsers and model downloads. Agents `pip install` into whatever interpreter they find first, and
before long nobody is sure which version of anything is actually being used — while the disk
quietly fills up.

So instead of letting each account build its own toolchain, these scripts install a single one
for the whole machine, pin every version, and make sure every user and agent picks it up
automatically.

## What you end up with

Everything lives under `C:\DevTools` and is read-only for normal users:

- **Python 3.13 via [uv](https://github.com/astral-sh/uv).** The default `python` is a shared venv
  that already has the packages agents keep reaching for: Word, Excel and PowerPoint libraries,
  PDF tools, OCR, Playwright with Chromium, requests/httpx, BeautifulSoup, pandas, matplotlib.
  Projects still get their own `.venv` through uv as usual.
- **Shared caches** for uv, Hugging Face, torch and Playwright, so a package or model downloaded
  by one account is reused by everyone else.
- **Common tools from winget**, installed machine-wide: Git, Node.js, GitHub CLI, VS Code,
  CMake, Ninja, FFmpeg, ripgrep, jq, LibreOffice, Pandoc and Tesseract (with English, Vietnamese,
  Japanese and Chinese data).
- **The Claude and Codex desktop apps for every account.** They're provisioned machine-wide, so
  each person gets them at sign-in, including accounts created later.
- **Instructions for the agents themselves**, so Claude Code and Codex know the environment is
  there and don't start installing their own copies.

All downloads are pinned to a version, and checked against a hash wherever one is available.

## Getting started

You need Windows 10 or 11 (x64), an administrator account and `winget`.

First, turn off **Smart App Control** if it's on (Windows Security → App & browser control).
It blocks the unsigned `python.exe` that uv installs. The setup checks for this and stops before
changing anything.

Then, in an administrator PowerShell:

```powershell
git clone https://github.com/honghuy127/windows-devtools-setup.git
cd windows-devtools-setup
powershell -ExecutionPolicy Bypass -File .\Install-DevTools.ps1
```

If you grab the ZIP instead of cloning, run `Unblock-File` on it before extracting, or Windows
won't let the scripts run.

When it's done, everyone should sign out and back in so the new PATH and environment variables
take effect. Then each person can check their own account with:

```powershell
C:\DevTools\setup\Test-DevTools.ps1
```

It's worth asking each agent (Codex, for example) to run it once too, since agents sometimes
execute commands under their own sandbox accounts.

## Options

By default every account on the machine can write to the shared caches. If you'd rather limit
that to specific people:

```powershell
.\Install-DevTools.ps1 -Writers Members -WriterMembers alice,bob
```

A few other switches you might want:

- `-PrivateCaches` keeps caches per user and shares only Python itself.
- `-SharedRepoRoots D:\Projects` marks a folder of shared repos as a git `safe.directory`.
- `-InstallBuildTools` adds the Visual Studio C++ build tools.
- `-SkipAgentEnv`, `-SkipAgentInstructions` and `-SkipDesktopApps` skip those parts of the install.

## How it's organized

`Install-DevTools.ps1` is the only script you normally run. It calls four others:

- `Setup-DevTools.ps1` does the heavy lifting: uv, Python, the shared caches and their
  permissions, environment variables, winget packages and a few Windows and Git settings. Every
  version it installs is listed in the `$Pinned` table at the top of the file.
- `Install-AgentEnv.ps1` builds the shared venv from `agent-env/uv.lock` and makes it the default
  `python`. Pass `-NoDefault` if you'd rather keep it off the PATH; it's always reachable as
  `agent-python`.
- `Install-AgentInstructions.ps1` copies `agent-instructions.md` into Claude Code's machine-wide
  `CLAUDE.md` and into the `AGENTS.md` of every user who uses Codex. It only touches its own
  marked block, so anything people wrote there themselves stays put.
- `Install-DesktopApps.ps1` downloads the Claude and Codex MSIX packages through winget and
  provisions them for all accounts. These apps keep themselves up to date, so it installs the
  latest version rather than a pinned one. `-Remove` stops provisioning them for new accounts.

`Test-DevTools.ps1` checks a single account, including a quick end-to-end run that creates Office
files and PDFs, runs OCR, converts documents with LibreOffice and opens a page in Chromium.

## Changing versions

- Tools, uv, Python or OCR data: edit `$Pinned` in `Setup-DevTools.ps1`.
- Python packages for agents: edit `agent-env/pyproject.toml`, run
  `Install-AgentEnv.ps1 -Relock` (or `-Upgrade` to bump everything), and commit the new `uv.lock`.
- What agents are told about the machine: edit `agent-instructions.md`.

To roll a change out, pull the repo on each machine and run `Install-DevTools.ps1` again as
administrator. It's safe to rerun, and it refreshes the copy in `C:\DevTools\setup` from the repo,
so don't edit that copy directly.

## Things worth knowing

- **The default Python is read-only.** That's on purpose: `pip install` fails there, which nudges
  people and agents towards `uv add` or `uv run --with`. Note that `uv run --with` creates a
  separate environment that does *not* include the default packages.
- **Shared caches come down to trust.** Anyone who can write to them could, in principle, tamper
  with a cached package that someone else uses later. Share caches only between accounts that
  trust each other, and never run project code as administrator.
- **Encoding.** On machines with a non-UTF-8 locale (Japanese Windows uses cp932, for example),
  Python defaults to that code page and mangles Vietnamese or Chinese text. The setup turns on
  Python's UTF-8 mode machine-wide.
- **Claude's Cowork can't be shared.** The app is shared, but Cowork runs a small VM whose disk
  (several GB, in `%LOCALAPPDATA%\Claude-Data`) is created per user the first time they turn it
  on, and holds that person's own session data. Users who never use Cowork never pay for it.
- **Tesseract data.** For Vietnamese, the standard models were noticeably more accurate than the
  "fast" ones. For Japanese and Chinese it was the other way round, so each language uses the
  variant that did better in testing.

## License

[MIT](LICENSE)
