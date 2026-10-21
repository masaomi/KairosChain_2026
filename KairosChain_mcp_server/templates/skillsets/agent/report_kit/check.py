"""Layout check: HTML text-box overflow, details-body overflow, SVG text beyond x 40..1236, and SVG text
outside a >=150 px rect in the same <g>. Not seen: the cover h1, narrow pills, text in transformed groups."""
import sys, asyncio, pathlib
from playwright.async_api import async_playwright
JS = r"""
() => { const out=[]; const S=[...document.querySelectorAll('.slide')]; let nText=0;
 S.forEach((s,i)=>{ goSlide(i);
  const k=s.getAttribute('data-key');
  s.querySelectorAll('.fn,.mh h2,.mh .sub,.foot .ft').forEach(e=>{ if(e.scrollWidth>e.clientWidth+1) out.push(k+': overflow in '+e.className+' ('+e.scrollWidth+'>'+e.clientWidth+')'); });
  const hb=s.querySelector('.hbody'); if(hb && hb.scrollHeight>hb.clientHeight+1) out.push(k+': hbody overflow '+hb.scrollHeight+'>'+hb.clientHeight);
  s.querySelectorAll('svg g').forEach(gg=>{ const r=gg.querySelector(':scope > rect'); if(!r) return; const rb=r.getBBox(); if(rb.width<150) return;
    gg.querySelectorAll(':scope > text').forEach(t=>{ const b=t.getBBox(); if(b.width===0) return; const inside=b.y>=rb.y-2&&b.y+b.height<=rb.y+rb.height+2; if(inside && (b.x+b.width>rb.x+rb.width-6||b.x<rb.x)) out.push(k+': text exceeds its card "'+t.textContent.slice(0,40)+'" ('+Math.round(b.x+b.width)+'>'+Math.round(rb.x+rb.width-6)+')'); }); });
  s.querySelectorAll('svg text').forEach(t=>{ nText++; const b=t.getBBox(); if(b.width>0&&(b.x+b.width>1236||b.x<40)) out.push(k+': svg text out of margin x='+Math.round(b.x)+' w='+Math.round(b.width)+' "'+t.textContent.slice(0,40)+'"'); });
 }); goSlide(0); return {slides:S.length, texts:nText, issues:out}; }
"""
async def main(path):
    async with async_playwright() as p:
        b=await p.chromium.launch(); pg=await b.new_page(viewport={"width":1280,"height":720})
        await pg.goto(pathlib.Path(path).resolve().as_uri()+"?still"); await pg.wait_for_timeout(300)
        r=await pg.evaluate(JS); await b.close()
    print(f"slides={r['slides']} svg_texts_measured={r['texts']} issues={len(r['issues'])}")
    for x in r['issues']: print("  ", x)
asyncio.run(main(sys.argv[1]))
