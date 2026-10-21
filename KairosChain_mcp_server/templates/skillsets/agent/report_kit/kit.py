"""Deck kit: CSS, JS, slide assembly (main / details / appendix) and small helpers.

Set FOOT_TITLE before building. Main slides use keys starting with "m"; End jumps to the last of them.
"""
from html import escape

W, H = 1280, 720

CSS = r"""
:root{--navy:#003c68;--dark:#001428;--orange:#ea6b13;--odark:#a84a0b;--cyan:#0099cc;--lcyan:#4dc9f6;--grey:#545e69;--lgrey:#9aa5b1;--bg:#f5f7fa;--line:#d5dbe2;--tint:#e6f4fa;--otint:#fdf0e6}
*{box-sizing:border-box}
html,body{margin:0;height:100%;overflow:hidden;background:var(--dark)}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"Noto Sans",system-ui,sans-serif;color:var(--dark);-webkit-font-smoothing:antialiased;-webkit-print-color-adjust:exact;print-color-adjust:exact}
#stage{position:absolute;left:50%;top:50%;width:1280px;height:720px;transform:translate(-50%,-50%);transform-origin:50% 50%;background:var(--bg);overflow:hidden}
.slide{position:absolute;left:0;top:0;width:1280px;height:720px;display:none;background:var(--bg);overflow:hidden}
.slide.active{display:block}
.slide::before{content:"";position:absolute;left:0;top:0;right:0;height:5px;background:linear-gradient(90deg,var(--navy) 0 72%,var(--cyan) 72% 90%,var(--orange) 90%)}
h1,h2{margin:0;color:var(--navy);line-height:1.15;font-weight:800;letter-spacing:-.01em}
code,.mono{font-family:ui-monospace,"SFMono-Regular",Menlo,Consolas,monospace}
a{color:inherit}
.mh{position:absolute;left:48px;right:48px;top:22px}
.mh h2{font-size:34px;white-space:nowrap}
.mh .sub{font-size:20px;line-height:1.3;color:var(--grey);margin:6px 0 0;white-space:nowrap}
.mh .sub b{color:var(--navy)}
.mfig{position:absolute;left:0;top:108px;width:1280px;height:536px;display:block;overflow:visible}
.fn{position:absolute;left:48px;right:48px;top:646px;height:26px;font-size:15px;line-height:26px;color:var(--grey);white-space:nowrap;overflow:hidden}
.fn b{color:var(--navy)}
.foot{position:absolute;left:48px;right:48px;bottom:0;height:40px;border-top:1px solid var(--line);display:flex;align-items:center;justify-content:space-between;gap:16px;font-size:14px;color:var(--grey)}
.foot .pg{font-weight:700;color:var(--navy);font-variant-numeric:tabular-nums;white-space:nowrap}
.foot .ft{white-space:nowrap}
.xref,.back{font-size:14px;font-weight:700;text-decoration:none;border-radius:13px;padding:1px 9px;white-space:nowrap;background:#fff;line-height:22px}
.xref{color:var(--odark);border:1.5px solid var(--orange)}
.xref:hover{background:var(--orange);color:#fff}
.back{color:var(--navy);border:1.5px solid var(--cyan)}
.back:hover{background:var(--cyan);color:#fff}
.fl{display:flex;gap:8px;align-items:center}
/* title */
.s-title{background:linear-gradient(140deg,#001428 0%,#002846 55%,#003c68 100%)}
.s-title .mh{top:70px}
.s-title h1{font-size:60px;color:#fff;white-space:nowrap}
.s-title h1 .h1d{display:block;font-size:30px;color:var(--lcyan);font-weight:600;margin-top:12px}
.s-title .sub{font-size:22px;color:#c3ccd6;margin-top:22px}
.s-title .mfig{top:250px;height:390px}
.s-title .foot{color:#c3ccd6;border-top-color:rgba(255,255,255,.2)}
.s-title .foot .pg{color:#fff}
/* svg paint */
.t-n{fill:#003c68}.t-g{fill:#545e69}.t-o{fill:#a84a0b}.t-or{fill:#ea6b13}.t-w{fill:#fff}.t-c{fill:#0077a0}.t-d{fill:#001428}.t-l{fill:#9aa5b1}.t-lc{fill:#4dc9f6}.t-pale{fill:#c3ccd6}
.f-navy{fill:#003c68}.f-cyan{fill:#0099cc}.f-or{fill:#ea6b13}.f-w{fill:#fff}.f-tint{fill:#e6f4fa}.f-otint{fill:#fdf0e6}.f-lg{fill:#eef1f4}.f-grey{fill:#545e69}
.card{fill:#fff;stroke:#d5dbe2;stroke-width:1.5}
.card-n{fill:#fff;stroke:#003c68;stroke-width:2}
.card-o{fill:#fdf0e6;stroke:#ea6b13;stroke-width:2.5}
.card-c{fill:#e6f4fa;stroke:#0099cc;stroke-width:2}
.card-g{fill:#eef1f4;stroke:#9aa5b1;stroke-width:1.5}
.card-d{fill:#fff;stroke:#9aa5b1;stroke-width:1.5;stroke-dasharray:6 5}
.ln-n{stroke:#003c68;stroke-width:2.5;fill:none}
.ln-g{stroke:#9aa5b1;stroke-width:2;fill:none}
.ln-gd{stroke:#9aa5b1;stroke-width:2;fill:none;stroke-dasharray:6 5}
.ln-c{stroke:#0099cc;stroke-width:2.5;fill:none}
.ln-o{stroke:#ea6b13;stroke-width:2.5;fill:none}
.ln-od{stroke:#ea6b13;stroke-width:2.5;fill:none;stroke-dasharray:7 5}
.ln-w{stroke:rgba(255,255,255,.55);stroke-width:2;fill:none}
.chip{fill:#fff;stroke:#0099cc;stroke-width:1.5}
.chip-o{fill:#fff;stroke:#ea6b13;stroke-width:1.5}
.chip-n{fill:#003c68}
.chip-or{fill:#ea6b13}
.chip-g{fill:#fff;stroke:#9aa5b1;stroke-width:1.5}
/* motion: final state is natural; animation only moves from a start offset */
.slide.active .a-up{animation:kUp .55s cubic-bezier(.2,.7,.2,1) both;animation-delay:var(--d,0s)}
.slide.active .a-fade{animation:kFade .55s ease both;animation-delay:var(--d,0s)}
@keyframes kUp{from{opacity:0;transform:translateY(14px)}}
@keyframes kFade{from{opacity:0}}
body.still .slide *{animation:none!important}
body.still .a-fadeout{opacity:.18}
@media (prefers-reduced-motion: reduce){.slide *{animation:none!important}.a-fadeout{opacity:.18}}
/* html bodies (appendix and table slides) */
.hbody{position:absolute;left:48px;right:48px;top:112px;bottom:84px}
.tbl{width:100%;border-collapse:collapse;font-size:15px;line-height:1.35;background:#fff}
.tbl th{background:var(--navy);color:#fff;text-align:left;padding:7px 10px;font-weight:700;vertical-align:bottom}
.tbl td{padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
.tbl tr:nth-child(even) td{background:#f8fafc}
.tbl td b{color:var(--navy)}
.tbl tr.hl td{background:var(--otint)}
.tbl.sm{font-size:13.5px}
.tbl.sm td,.tbl.sm th{padding:5px 8px}
.two{display:grid;grid-template-columns:1fr 1fr;gap:20px}
.box{background:#fff;border:1px solid var(--line);border-radius:8px;padding:12px 16px}
.box h3{margin:0 0 8px;font-size:17px;color:var(--navy)}
.box.o{border:2px solid var(--orange);background:var(--otint)}
.box.c{border:2px solid var(--cyan);background:var(--tint)}
.box ul{margin:0;padding-left:20px;font-size:15px;line-height:1.42}
.box li{margin-bottom:5px}
.box p{margin:0 0 8px;font-size:15px;line-height:1.42}
.note{font-size:14px;color:var(--grey);margin:10px 0 0;line-height:1.4}
.note b{color:var(--navy)}
.lab{display:inline-block;font-size:11.5px;font-weight:800;letter-spacing:.03em;padding:0 5px;border-radius:3px;border:1px solid;line-height:16px;vertical-align:1px;white-space:nowrap}
.l-f{color:#fff;background:var(--navy);border-color:var(--navy)}
.l-s{color:var(--navy);background:var(--tint);border-color:var(--cyan)}
.l-u{color:var(--grey);background:#fff;border-color:var(--lgrey);border-style:dashed}
.l-i{color:var(--odark);background:var(--otint);border-color:var(--orange)}
.src{font-size:12.5px;line-height:1.45;columns:2;column-gap:28px}
.src div{break-inside:avoid;margin-bottom:4px}
.src h4{margin:0 0 4px;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--odark)}

/* visual-first main slides */
.vfig{position:absolute;left:0;top:80px;width:1280px;height:600px;display:block;overflow:visible}
.mh h2.big{font-size:38px}
.slide.active .a-pop{animation:kPop .5s cubic-bezier(.3,1.4,.5,1) both;animation-delay:var(--d,0s)}
.slide.active .a-left{animation:kLeft .6s cubic-bezier(.2,.7,.2,1) both;animation-delay:var(--d,0s)}
.slide.active .a-right{animation:kRight .6s cubic-bezier(.2,.7,.2,1) both;animation-delay:var(--d,0s)}
.slide.active .a-draw{animation:kDraw .9s ease-in-out both;animation-delay:var(--d,0s);stroke-dasharray:1 1}
.slide.active .a-stamp{animation:kStamp .5s cubic-bezier(.3,1.3,.5,1) both;animation-delay:var(--d,0s)}
.slide.active .a-red{animation:kRed .6s ease both;animation-delay:var(--d,0s)}
.slide.active .a-grow{animation:kGrow .9s cubic-bezier(.2,.7,.2,1) both;animation-delay:var(--d,0s)}
.slide.active .a-spin{animation:kSpin 7s linear infinite}
.slide.active .a-spin-r{animation:kSpin 7s linear infinite reverse}
.slide.active .a-spin-slow{animation:kSpin 12s linear infinite}
.slide.active .a-pulse{animation:kPulse 1.8s ease-in-out infinite;animation-delay:var(--d,0s)}
.slide.active .a-march{animation:kMarch 1.2s linear infinite}
.slide.active .a-fadeout{animation:kFadeOut 1.2s ease both;animation-delay:var(--d,0s)}
.a-pop,.a-stamp,.a-spin,.a-spin-r,.a-pulse,.a-grow{transform-box:fill-box;transform-origin:50% 50%}
.a-grow{transform-origin:0 50%}
@keyframes kPop{from{opacity:0;transform:scale(.3)}}
@keyframes kLeft{from{opacity:0;transform:translateX(-50px)}}
@keyframes kRight{from{opacity:0;transform:translateX(50px)}}
@keyframes kDraw{from{stroke-dashoffset:1}to{stroke-dashoffset:0}}
@keyframes kStamp{from{opacity:0;transform:scale(2.4) rotate(-16deg)}}
@keyframes kRed{from{fill:#ffffff;stroke:#003c68}}
@keyframes kGrow{from{transform:scaleX(0)}}
@keyframes kSpin{to{transform:rotate(360deg)}}
@keyframes kPulse{0%,100%{transform:scale(1)}50%{transform:scale(1.12)}}
@keyframes kMarch{to{stroke-dashoffset:-24}}
@keyframes kFadeOut{from{opacity:1}to{opacity:.18}}
.flowdot{opacity:0}
.slide.active .flowdot{opacity:1;animation:kFade .3s ease both;animation-delay:var(--d,0s)}
body.still .flowdot{display:none}
@media (prefers-reduced-motion: reduce){.flowdot{display:none}}
@media print{.flowdot{display:none}}
.foot .det{font-size:13px}
/* Slide index (ArrowUp): find a slide by any word on it, jump with Enter.
   Design notes: L1 html_slide_deck_authoring section 8. */
#idx{position:fixed;inset:0;z-index:60;display:none;flex-direction:column;background:#fff;padding:3vh 3.6vw 2vh;font-family:inherit}
#idx.on{display:flex}
#idx .qq{font-size:2vh;color:var(--dark);padding-bottom:1vh;border-bottom:1px solid var(--line);margin-bottom:1.2vh;display:flex;align-items:center}
#idx .qi{font:inherit;font-size:1.9vh;padding:.4vh .8vw;margin:0 .9vw;border:.18vh solid var(--lgrey);border-radius:.5vh;color:var(--dark);width:26vw;outline:none}
#idx .qi:focus{border-color:var(--orange)}
#idx .cnt{color:var(--orange);font-weight:700;font-size:1.7vh}
#idx .hint{color:var(--grey);font-size:1.6vh;margin-left:auto}
#idx .rows{flex:1;overflow-y:auto;display:grid;grid-template-columns:repeat(3,1fr);gap:.2vh 2vw;align-content:start}
#idx .rows a{display:flex;gap:.7vw;align-items:baseline;font-size:1.7vh;line-height:1.45;padding:.3vh .4vw;border-radius:.4vh;cursor:pointer;color:var(--dark);text-decoration:none}
#idx .rows a.sel{background:var(--otint);box-shadow:inset 0 0 0 .2vh var(--orange)}
#idx .n{flex:0 0 4.6vw;white-space:nowrap;text-align:right;color:var(--navy);font-weight:800;font-variant-numeric:tabular-nums}
#idx a.sub .n{color:var(--lgrey);font-weight:600}
#idx .tt{flex:1;min-width:0}
#idx a.sub .tt{color:var(--grey)}
@media print{#idx{display:none!important}}
@media print{
  @page{size:1280px 720px;margin:0}
  html,body{height:auto;overflow:visible;background:#fff}
  #stage{position:static;transform:none!important;height:auto;overflow:visible}
  .slide{display:block!important;position:relative;break-after:page;page-break-after:always}
  .slide *{animation:none!important}
  .a-fadeout{opacity:.18}
}
"""

JS = r"""
(function(){
  var S=[].slice.call(document.querySelectorAll('.slide')),i=0,stage=document.getElementById('stage');
  if(location.search.indexOf('still')>=0)document.body.classList.add('still');
  function fit(){var k=Math.min(innerWidth/1280,innerHeight/720);stage.style.transform='translate(-50%,-50%) scale('+k+')';}
  function key(n){return S[n].getAttribute('data-key');}
  function show(n){n=Math.max(0,Math.min(S.length-1,n));S[i].classList.remove('active');i=n;S[i].classList.add('active');
    if(history.replaceState)history.replaceState(null,'','#'+key(i));}
  function byKey(k){for(var j=0;j<S.length;j++)if(key(j)===k)return j;return -1;}
  window.goSlide=function(n){show(n);};
  addEventListener('resize',fit);fit();
  var h=location.hash.slice(1),j=byKey(h);show(j>=0?j:0);
  addEventListener('hashchange',function(){var j=byKey(location.hash.slice(1));if(j>=0&&j!==i)show(j);});
  addEventListener('keydown',function(e){
    if(e.key==='ArrowRight'||e.key==='PageDown'||e.key===' '){e.preventDefault();show(i+1);}
    else if(e.key==='ArrowLeft'||e.key==='PageUp'){e.preventDefault();show(i-1);}
    else if(e.key==='Home'){show(0);}else if(e.key==='End'){var lm=-1;for(var j=0;j<S.length;j++)if(/^m/.test(key(j)))lm=j;show(lm>=0?lm:S.length-1);}
  });
  stage.addEventListener('click',function(e){if(e.target.closest('a'))return;show(i+1);});
  /* Slide index: ArrowUp opens it. Registered in the capture phase on document, so while it is
     open no key or click reaches the slide handlers. Filtering listens to the input's 'input'
     event (keydown misses IME composition). It searches each slide's full text, not its title. */
  var idx=document.getElementById('idx');
  if(idx){
    var esc=function(t){return t.replace(/&/g,'&amp;').replace(/</g,'&lt;');};
    var base=S.map(function(s,n){var pgEl=s.querySelector('.foot .pg');return (pgEl?pgEl.textContent:'').split('/')[0].trim()||String(n+1);});
    var items=S.map(function(s,n){
      /* a details page is labelled by the main slide it belongs to ("10 det"), not its internal key (D6) */
      var lab=base[n],bk=s.querySelector('a.back'),t=bk?byKey(bk.getAttribute('href').slice(1)):-1;
      if(/^D/.test(lab)&&t>=0&&/^\d+$/.test(base[t]))lab=base[t]+' det';
      var h=s.querySelector('h2')||s.querySelector('h1'),ttl='';
      if(h){ttl=[].slice.call(h.childNodes).filter(function(x){return !(x.classList&&x.classList.contains('h1d'));}).map(function(x){return x.textContent;}).join('');}
      var kick=s.querySelector('.mh .sub');
      var sub=!/^\d+$/.test(lab);
      return {n:n,lab:lab,sub:sub,title:ttl.replace(/\s+/g,' ').trim(),
        hay:(lab+' '+(s.textContent||'')).replace(/\s+/g,' ').toLowerCase()};});
    idx.innerHTML='<div class="qq"><b>Find a slide</b><input class="qi" type="text" autocomplete="off" spellcheck="false" placeholder="type to filter">'
      +'<span class="cnt"></span><span class="hint">↑↓←→ select · Enter go · Esc back</span></div><div class="rows">'
      +items.map(function(it){return '<a data-n="'+it.n+'"'+(it.sub?' class="sub"':'')+'><span class="n">'+esc(it.lab)+'</span><span class="tt">'+esc(it.title)+'</span></a>';}).join('')+'</div>';
    var qi=idx.querySelector('.qi'),cnt=idx.querySelector('.cnt'),as=[].slice.call(idx.querySelectorAll('.rows a')),sel=0,vis=[];
    function paint(){
      var q=qi.value.trim().toLowerCase();vis=[];
      as.forEach(function(a,k){var ok=!q||items[k].hay.indexOf(q)>=0;a.style.display=ok?'':'none';if(ok)vis.push(k);});
      if(sel>=vis.length)sel=Math.max(0,vis.length-1);
      as.forEach(function(a){a.classList.remove('sel');});
      if(vis.length){as[vis[sel]].classList.add('sel');as[vis[sel]].scrollIntoView({block:'nearest'});}
      cnt.textContent=q?(vis.length+' found'):'';}
    function cols(){if(!vis.length)return 1;var t0=Math.round(as[vis[0]].offsetTop),c=0;
      for(var k=0;k<vis.length;k++){if(Math.round(as[vis[k]].offsetTop)===t0)c++;else break;}return Math.max(1,c);}
    function move(d){sel=Math.max(0,Math.min(sel+d,vis.length-1));paint();}
    function isOpen(){return idx.classList.contains('on');}
    function close(){idx.classList.remove('on');qi.blur();}
    qi.addEventListener('input',function(){sel=0;paint();});
    document.addEventListener('keydown',function(e){
      if(!isOpen()){
        if(e.key==='ArrowUp'&&!e.metaKey&&!e.ctrlKey&&!e.altKey){e.preventDefault();e.stopPropagation();
          idx.classList.add('on');qi.value='';paint();var at=vis.indexOf(i);sel=at>=0?at:0;paint();qi.focus();}
        return;}
      e.stopPropagation();
      if(e.key==='Escape'){e.preventDefault();close();}
      else if(e.key==='ArrowRight'){e.preventDefault();move(1);}
      else if(e.key==='ArrowLeft'){e.preventDefault();move(-1);}
      else if(e.key==='ArrowDown'){e.preventDefault();move(cols());}
      else if(e.key==='ArrowUp'){e.preventDefault();move(-cols());}
      else if(e.key==='Enter'){e.preventDefault();if(vis.length){show(items[vis[sel]].n);close();}}
    },true);
    document.addEventListener('click',function(e){
      if(!isOpen())return;e.stopPropagation();
      var a=e.target.closest('.rows a');if(a){show(+a.getAttribute('data-n'));close();}
    },true);
  }
})();
"""


def esc(s):
    return escape(s, quote=True)


def tx(x, y, lines, cls="t-d", size=18, anchor="start", weight=400, lh=1.28, extra=""):
    """Multi-line SVG text. `lines` is a str or list of str. Inline <b>..</b> becomes bold tspans."""
    if isinstance(lines, str):
        lines = [lines]
    out = [f'<text x="{x}" y="{y}" class="{cls}" font-size="{size}" text-anchor="{anchor}" font-weight="{weight}" {extra}>']
    for k, ln in enumerate(lines):
        dy = 0 if k == 0 else round(size * lh, 1)
        out.append(f'<tspan x="{x}" dy="{dy}">{_rich(ln)}</tspan>')
    out.append("</text>")
    return "".join(out)


def _rich(s):
    # minimal markup: **bold** and `mono`
    parts, out, bold, mono = s.split("`"), [], False, False
    res = []
    for pi, seg in enumerate(parts):
        mono = pi % 2 == 1
        bsegs = seg.split("**")
        for bi, b in enumerate(bsegs):
            if bi > 0:
                bold = not bold
            if not b:
                continue
            attrs = []
            if bold:
                attrs.append('font-weight="800"')
            if mono:
                attrs.append('font-family="ui-monospace,Menlo,Consolas,monospace"')
            t = esc(b)
            res.append(f'<tspan {" ".join(attrs)}>{t}</tspan>' if attrs else t)
    return "".join(res)


def rect(x, y, w, h, cls="card", r=10, extra=""):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" class="{cls}" {extra}/>'


def arrow(x1, y1, x2, y2, cls="ln-n", head=10):
    import math
    a = math.atan2(y2 - y1, x2 - x1)
    hx1 = x2 - head * math.cos(a - 0.45)
    hy1 = y2 - head * math.sin(a - 0.45)
    hx2 = x2 - head * math.cos(a + 0.45)
    hy2 = y2 - head * math.sin(a + 0.45)
    col = {"ln-n": "#003c68", "ln-c": "#0099cc", "ln-o": "#ea6b13", "ln-od": "#ea6b13", "ln-g": "#9aa5b1", "ln-gd": "#9aa5b1", "ln-w": "rgba(255,255,255,.55)"}.get(cls, "#003c68")
    return (f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" class="{cls}"/>'
            f'<polygon points="{x2},{y2} {hx1:.1f},{hy1:.1f} {hx2:.1f},{hy2:.1f}" fill="{col}"/>')


def g(content, cls="a-up", d=0.0):
    return f'<g class="{cls}" style="--d:{d}s">{content}</g>'


def svg(body, vb_h=536):
    return f'<svg class="mfig" viewBox="0 0 1280 {vb_h}" xmlns="http://www.w3.org/2000/svg" role="img">{body}</svg>'


FOOT_TITLE = "Deck title · Venue · Date"  # set by the deck script: kit.FOOT_TITLE = "..."


def slide(key, title, sub, fig, fn="", cls="", page="", links=""):
    sub_html = f'<p class="sub">{sub}</p>' if sub else ""
    fn_html = f'<div class="fn">{fn}</div>' if fn else ""
    return (f'<section class="slide {cls}" data-key="{key}">'
            f'<div class="mh"><h2>{title}</h2>{sub_html}</div>{fig}{fn_html}'
            f'<div class="foot"><span class="ft">{FOOT_TITLE}</span><span class="fl">{links}<span class="pg">{page}</span></span></div>'
            f'</section>')


def hslide(key, kicker, title, body, page="", back=""):
    back_html = f'<a class="back" href="#{back}">back to main</a>' if back else ""
    return (f'<section class="slide" data-key="{key}">'
            f'<div class="mh"><h2 style="font-size:28px">{title}</h2><p class="sub" style="font-size:16px;color:#a84a0b;font-weight:700;letter-spacing:.06em;text-transform:uppercase">{kicker}</p></div>'
            f'<div class="hbody">{body}</div>'
            f'<div class="foot"><span class="ft">{FOOT_TITLE}</span><span class="fl">{back_html}<span class="pg">{page}</span></span></div>'
            f'</section>')


def page(title, slides):
    return ("<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            f"<title>{esc(title)}</title><style>{CSS}</style></head><body>"
            f"{_sprite()}<div id=\"stage\">{''.join(slides)}</div><div id=\"idx\"></div><script>{JS}</script></body></html>")


def _sprite():
    """Arrow-head markers, once, outside every slide (markers inside a display:none slide do not render)."""
    from viz import defs
    return f'<svg width="0" height="0" style="position:absolute" aria-hidden="true">{defs()}</svg>'



def vslide(key, title, body, page="", detail=None, cls=""):
    """Visual-first slide: title + one full-bleed SVG (viewBox 1280x600), no subtitle, no footnote."""
    det = f'<a class="xref det" href="#{detail}">details</a>' if detail else ""
    return (f'<section class="slide {cls}" data-key="{key}">'
            f'<div class="mh"><h2 class="big">{title}</h2></div>'
            f'<svg class="vfig" viewBox="0 0 1280 600" xmlns="http://www.w3.org/2000/svg" role="img">{body}</svg>'
            f'<div class="foot"><span class="ft">{FOOT_TITLE}</span><span class="fl">{det}<span class="pg">{page}</span></span></div>'
            f'</section>')


def qr_svg(url, size=150, dark="#001428"):
    """QR code as inline SVG (needs the `qrcode` package). Decode the rendered cover before trusting it."""
    import qrcode
    q = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=2)
    q.add_data(url); q.make(fit=True)
    m = q.get_matrix(); n = len(m)
    d = "".join(f"M{x} {y}h1v1h-1z" for y, row in enumerate(m) for x, v in enumerate(row) if v)
    return (f'<svg viewBox="0 0 {n} {n}" width="{size}" height="{size}" shape-rendering="crispEdges">'
            f'<rect width="{n}" height="{n}" fill="#fff"/><path d="{d}" fill="{dark}"/></svg>')


def icon_img(path, x, y, w, h):
    """Embed a small raster icon (e.g. a generated WebP, ~40 KB) inside a slide SVG as base64."""
    import base64
    data = base64.b64encode(open(path, "rb").read()).decode()
    kind = "webp" if path.endswith(".webp") else "png"
    return f'<image href="data:image/{kind};base64,{data}" x="{x}" y="{y}" width="{w}" height="{h}" preserveAspectRatio="xMidYMid meet"/>'
