"""Smoke test for the shared agent env: office, PDF, web parsing, (optionally) browser."""
import sys, tempfile, pathlib, importlib

# Runs with -I (ignores PYTHONUTF8) on machines with a non-UTF-8 code page: always print UTF-8.
sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")

out = pathlib.Path(tempfile.mkdtemp(prefix="agent-smoke-"))
results = []

def step(name, fn):
    try:
        msg = fn()
        results.append((name, "OK", msg or ""))
    except Exception as e:  # noqa: BLE001
        results.append((name, "FAIL", f"{type(e).__name__}: {e}"))

def imports():
    for m in ["docx", "openpyxl", "xlsxwriter", "xlrd", "pptx", "markitdown", "pypdf", "pdfplumber",
              "pypdfium2", "reportlab", "pytesseract", "playwright", "requests", "httpx", "bs4", "lxml", "trafilatura",
              "markdownify", "pandas", "numpy", "PIL", "matplotlib", "yaml", "jinja2", "dateutil", "tabulate"]:
        importlib.import_module(m)

def office():
    import docx, openpyxl, pptx
    d = docx.Document(); d.add_heading("Xin chào", 1); d.add_paragraph("Tiếng Việt OK"); d.save(out / "t.docx")
    wb = openpyxl.Workbook(); ws = wb.active; ws["A1"] = 2; ws["A2"] = 3; ws["A3"] = "=A1*A2"; wb.save(out / "t.xlsx")
    p = pptx.Presentation(); s = p.slides.add_slide(p.slide_layouts[1]); s.shapes.title.text = "Slide"; p.save(out / "t.pptx")

def pdf():
    from reportlab.pdfgen import canvas
    c = canvas.Canvas(str(out / "t.pdf")); c.drawString(72, 720, "Hello PDF 123"); c.save()
    import pypdf, pdfplumber, pypdfium2
    assert "Hello PDF" in pypdf.PdfReader(out / "t.pdf").pages[0].extract_text()
    with pdfplumber.open(out / "t.pdf") as f: assert "123" in f.pages[0].extract_text()
    img = pypdfium2.PdfDocument(out / "t.pdf")[0].render(scale=1).to_pil(); img.save(out / "t.png")

def to_markdown():
    from markitdown import MarkItDown
    md = MarkItDown()
    for f in ["t.docx", "t.xlsx", "t.pptx", "t.pdf"]:
        text = md.convert(str(out / f)).text_content
        assert text.strip(), f"empty markdown for {f}"

def web_parse():
    from bs4 import BeautifulSoup; import trafilatura, markdownify
    html = "<html><body><article><h1>Tiêu đề</h1><p>" + "Nội dung chính. " * 30 + "</p></article></body></html>"
    assert BeautifulSoup(html, "lxml").h1.text == "Tiêu đề"
    assert "Nội dung" in (trafilatura.extract(html) or "")
    assert "# Tiêu đề" in markdownify.markdownify(html, heading_style="ATX")

def charts():
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt, pandas as pd
    pd.DataFrame({"x": [1, 2, 3], "y": [3, 1, 2]}).plot(x="x", y="y"); plt.savefig(out / "c.png")

def browser():
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.launch(); pg = b.new_page()
        pg.set_content("<title>ok</title><h1 id=h>Playwright</h1>")
        assert pg.inner_text("#h") == "Playwright"; pg.screenshot(path=str(out / "s.png")); b.close()

def pandoc_libreoffice():
    import shutil, subprocess
    for tool in ("pandoc", "soffice"):
        if not shutil.which(tool):
            raise RuntimeError(f"{tool} not on PATH")
    (out / "p.md").write_text("# Tiêu đề\n\nXin chào **thế giới**.\n", encoding="utf-8")
    subprocess.run(["pandoc", str(out / "p.md"), "-o", str(out / "p.docx")], check=True, timeout=120)
    # soffice.com (console variant) waits until the conversion is finished
    subprocess.run([shutil.which("soffice"), "--headless", "--norestore", "--convert-to", "pdf",
                    "--outdir", str(out), str(out / "p.docx")], check=True, timeout=300, capture_output=True)
    import pypdf
    text = pypdf.PdfReader(out / "p.pdf").pages[0].extract_text()
    assert "Xin chào" in text, f"converted PDF text: {text!r}"

def ocr_languages():
    import os, pytesseract
    from PIL import Image, ImageDraw, ImageFont
    expected = {"eng", "vie", "jpn", "jpn_vert", "chi_sim", "chi_sim_vert", "chi_tra", "chi_tra_vert"}
    missing = expected - set(pytesseract.get_languages(config=""))
    assert not missing, f"language data missing: {sorted(missing)}"
    fonts = r"C:\Windows\Fonts"
    def font(*names):
        return next((os.path.join(fonts, n) for n in names if os.path.exists(os.path.join(fonts, n))), None)
    arial = os.path.join(fonts, "arial.ttf")
    samples = [("vie", "Tiếng Việt 2026", arial), ("eng", "English text 2026", arial)]
    for lang, text, f in [("jpn", "日本語の文章 2026", font("YuGothM.ttc", "meiryo.ttc", "msgothic.ttc")),
                          ("chi_sim", "简体中文 2026", font("msyh.ttc", "simsun.ttc")),
                          ("chi_tra", "繁體中文 2026", font("msjh.ttc", "mingliub.ttc"))]:
        if f:
            samples.append((lang, text, f))
    got = []
    for lang, text, font in samples:
        img = Image.new("RGB", (1100, 160), "white")
        ImageDraw.Draw(img).text((30, 40), text, fill="black", font=ImageFont.truetype(font, 64))
        res = pytesseract.image_to_string(img, lang=lang).strip()
        assert "2026" in res, f"{lang} OCR result: {res!r}"
        got.append(f"{lang}={res!r}")
    return "-> " + ", ".join(got)

step("imports", imports); step("office docx/xlsx/pptx", office); step("pdf create/read/render", pdf)
step("markitdown office+pdf", to_markdown); step("web parsing", web_parse); step("charts", charts)
if "--browser" in sys.argv:
    step("playwright chromium", browser)
if "--system-tools" in sys.argv:
    step("pandoc md->docx, LibreOffice docx->pdf", pandoc_libreoffice)
    step("tesseract OCR (vie/eng/jpn/chi)", ocr_languages)

import shutil
shutil.rmtree(out, ignore_errors=True)
print(f"python: {sys.executable}")
for name, st, msg in results:
    print(f"[{st:4}] {name} {msg}")
sys.exit(1 if any(st == "FAIL" for _, st, _ in results) else 0)
