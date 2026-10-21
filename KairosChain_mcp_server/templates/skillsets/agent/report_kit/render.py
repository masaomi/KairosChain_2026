"""Render slides to PNG for visual checking: render.py <html> [slide indices...]"""
import sys, asyncio, pathlib
from playwright.async_api import async_playwright

async def main(path, idx):
    url = pathlib.Path(path).resolve().as_uri() + "?still"
    out = pathlib.Path("shots"); out.mkdir(exist_ok=True)
    async with async_playwright() as p:
        b = await p.chromium.launch()
        pg = await b.new_page(viewport={"width": 1280, "height": 720})
        await pg.goto(url); await pg.wait_for_timeout(300)
        n = await pg.evaluate("document.querySelectorAll('.slide').length")
        for i in (idx or range(n)):
            await pg.evaluate(f"goSlide({i})"); await pg.wait_for_timeout(120)
            await pg.screenshot(path=str(out / f"{pathlib.Path(path).stem}_{i+1:02d}.png"))
        await b.close()
    print("rendered", len(idx or range(n)))

asyncio.run(main(sys.argv[1], [int(x) - 1 for x in sys.argv[2:]]))
