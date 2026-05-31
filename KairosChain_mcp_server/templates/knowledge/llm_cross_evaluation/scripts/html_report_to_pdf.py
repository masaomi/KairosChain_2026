#!/usr/bin/env python3
"""
HTML report -> PDF (long document, not slides).

Renders a scrolling report (with Chart.js figures loaded from CDN) to PDF using
Playwright/Chromium, so JavaScript runs and the canvas figures appear. A4 portrait,
backgrounds on, waits for network idle + a beat for chart animation.

Usage:
    python html_report_to_pdf.py <input.html> [output.pdf]

Requirements:
    pip install playwright
    playwright install chromium
"""

import asyncio
import sys
from pathlib import Path

try:
    from playwright.async_api import async_playwright
except ImportError:
    print("Error: Playwright not installed. Run: pip install playwright && playwright install chromium")
    sys.exit(1)


async def convert(input_html: str, output_pdf: str):
    input_path = Path(input_html).resolve()
    output_path = Path(output_pdf).resolve()
    if not input_path.exists():
        print(f"Error: input not found: {input_path}")
        sys.exit(1)

    print(f"Input:  {input_path}\nOutput: {output_path}")
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        page = await browser.new_page(viewport={"width": 1100, "height": 1400})
        await page.goto(f"file://{input_path}", wait_until="networkidle")
        # Chart.js renders on DOMContentLoaded; give animations a beat to settle.
        await page.wait_for_timeout(2500)
        await page.emulate_media(media="screen")  # keep the on-screen styling
        await page.pdf(
            path=str(output_path),
            format="A4",
            print_background=True,
            margin={"top": "12mm", "right": "10mm", "bottom": "12mm", "left": "10mm"},
            prefer_css_page_size=False,
        )
        await browser.close()
    print(f"PDF created: {output_path} ({output_path.stat().st_size / 1024:.1f} KB)")


def main():
    if len(sys.argv) < 2:
        print("usage: python html_report_to_pdf.py <input.html> [output.pdf]")
        sys.exit(1)
    inp = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) >= 3 else str(Path(inp).with_suffix(".pdf"))
    asyncio.run(convert(inp, out))


if __name__ == "__main__":
    main()
