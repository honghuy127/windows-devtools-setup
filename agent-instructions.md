# Shared dev environment on this machine

This Windows machine has one shared toolchain for all users and AI agents, managed by scripts in
`C:\DevTools\setup` (an administrator runs them). Use it; don't install your own copies.

## Python
- `python` / `python3` is the shared venv `C:\DevTools\envs\agent` (Python 3.13) with these packages
  preinstalled — use them directly in one-off scripts:
  - Office: python-docx, openpyxl, xlsxwriter, xlrd, python-pptx, markitdown (Office/PDF/HTML -> Markdown)
  - PDF: pypdf, pdfplumber, pypdfium2 (render pages to images; there is no poppler), reportlab
  - OCR: pytesseract
  - Web: playwright (Chromium already installed), requests, httpx, beautifulsoup4, lxml, trafilatura, markdownify
  - Data/plots: pandas, numpy, pillow, matplotlib; misc: pyyaml, jinja2, python-dateutil, tabulate
- That venv is read-only and has no pip. Do not run `pip install`, `python -m pip`, `playwright install`
  or `uv python install` — they fail by design.
- Need a package that isn't listed:
  - one-off script: `uv run --with <pkg> --with <other> script.py`. The temporary env does NOT include the
    default venv's packages, so list every package the script needs (installs are fast: the uv cache is shared).
  - project: `uv init`, `uv add <pkg>`, `uv run ...` (creates the project's own `.venv`).
- Only Python 3.13 exists and downloads are disabled. If a project requires another version, tell the user.
- `agent-python` (or `$DEVTOOLS_AGENT_PYTHON`) always runs the shared venv, even inside another activated venv.

## Text encoding
The Windows code page may not be UTF-8 (e.g. cp932 on a ja-JP machine), and text is often Vietnamese,
Japanese, Chinese or English. `PYTHONUTF8=1` is set machine-wide, but still always pass `encoding="utf-8"`
when reading/writing text files and in `subprocess.run(..., text=True, encoding="utf-8")`. Don't rely on
the console code page.

## Documents, OCR, browser
- LibreOffice (headless): `soffice --headless --convert-to pdf --outdir <dir> <file>` for docx/xlsx/pptx -> pdf
  and other format conversions.
- Pandoc: `pandoc in.md -o out.docx` (and other formats).
- Tesseract OCR languages: eng, vie, jpn, jpn_vert, chi_sim, chi_sim_vert, chi_tra, chi_tra_vert
  (`_vert` = vertical text). Combine with `+`, e.g. `pytesseract.image_to_string(img, lang="vie+eng")`
  or `lang="jpn+eng"`. For scans, render PDF pages at scale 2-3 with pypdfium2 before OCR.
- Playwright: Chromium is in the shared cache (`PLAYWRIGHT_BROWSERS_PATH`); just use
  `from playwright.sync_api import sync_playwright` and launch headless.

## Other tools on PATH
git, gh, node/npm (Node 26 LTS), rg, jq, ffmpeg, cmake, ninja, VS Build Tools 2026 (C++), VS Code (`code`),
uv/uvx.

## Rules
- Don't install software machine-wide, and don't change PATH or machine/user environment variables.
  If a tool is missing, tell the user (it's added via `C:\DevTools\setup`).
- `C:\DevTools\cache\*` (uv, huggingface, torch, playwright) and `C:\DevTools\models` are shared by every
  account. Don't delete or clean them (`uv cache clean`, removing models/browsers) without asking.
- Never run project code in an elevated (administrator) shell.
