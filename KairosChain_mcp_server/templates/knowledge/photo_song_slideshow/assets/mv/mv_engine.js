// mv_engine.js — canvas music-video engine for photo_song_slideshow (MV mode).
//
// One function draws the whole frame for a time t, so the browser preview and the MP4 (rendered frame by
// frame through headless Chrome by scripts/mv_render.rb) are the same picture. A project supplies:
//   assets/data.js  window.MV_DATA = { lyrics, assets, beat }   (scripts/mv_data.rb)
//   scenes.js       MV.start({ seq, looks, lyrics, ... })        (written per project)
// See assets/mv/scenes.example.js for the scene vocabulary.
(function () {
"use strict";
const D = window.MV_DATA;
const W = 1920, H = 1080, FPS = 30;
const RENDER = new URLSearchParams(location.search).has("render");
if (RENDER) document.body.classList.add("render");
const cv = document.getElementById("c"), ctx = cv.getContext("2d");
const mk = (w, h) => { const c = document.createElement("canvas"); c.width = w; c.height = h; return c; };
const layer = mk(W, H), lctx = layer.getContext("2d");
const small = mk(480, 270), sctx = small.getContext("2d");
const tiny = mk(160, 90), tctx = tiny.getContext("2d");

// ============================================================ utilities
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const lerp = (a, b, p) => a + (b - a) * p;
const sstep = (a, b, x) => { const p = clamp((x - a) / (b - a)); return p * p * (3 - 2 * p); };
const easeIO = p => 0.5 - 0.5 * Math.cos(Math.PI * clamp(p));
const easeOut = p => 1 - Math.pow(1 - clamp(p), 3);
const easeBack = p => { p = clamp(p); const c1 = 1.9, c3 = c1 + 1; return 1 + c3 * Math.pow(p - 1, 3) + c1 * Math.pow(p - 1, 2); };
const bell = (t, t0, rise, fall) => t < t0 ? sstep(t0 - rise, t0, t) : 1 - sstep(t0, t0 + fall, t);
const frac = x => x - Math.floor(x);
const TAU = Math.PI * 2;
function rng(seed) { return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
  t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
function track(pts, t) {
  if (t <= pts[0][0]) return pts[0][1];
  for (let i = 1; i < pts.length; i++) if (t <= pts[i][0]) {
    const [t0, v0] = pts[i - 1], [t1, v1] = pts[i]; return lerp(v0, v1, easeIO((t - t0) / (t1 - t0))); }
  return pts[pts.length - 1][1];
}
const BEAT = D.beat.period, BEAT0 = D.beat.first;
function beatPulse(t, width = 0.12) { const k = Math.round((t - BEAT0) / BEAT); const bt = BEAT0 + k * BEAT;
  const d = t - bt; return d < 0 ? Math.exp(-Math.pow(d / 0.03, 2)) : Math.exp(-d / width); }
const L = D.lyrics;
// line("When the", 1) -> the second lyric line starting with "When the"; at(x) accepts seconds, a prefix, or [prefix, n]
function line(prefix, n = 0) { const hits = L.filter(l => l.text.startsWith(prefix)); if (!hits[n]) throw new Error("no lyric line: " + prefix); return hits[n]; }
const at = x => typeof x === "string" ? line(x).start : Array.isArray(x) ? line(x[0], x[1]).start : x;

const SERIF = '"Hoefler Text", Baskerville, Georgia, serif';
const DIDOT = 'Didot, "Bodoni 72", serif';
const SCRIPT = '"Snell Roundhand", "Savoye LET", cursive';
const SANS = '"Avenir Next", Avenir, sans-serif';

// ============================================================ assets
const IMG = {}, STK = {}, VID = {};
function loadImg(src) { return new Promise((res, rej) => { const i = new Image(), timer = setTimeout(() => rej(new Error("not loaded in 30 s: " + src)), 30000);
  i.onload = () => { clearTimeout(timer); res(i); }; i.onerror = () => { clearTimeout(timer); rej(new Error("cannot load " + src)); }; i.src = src; }); }
async function loadAll(progress) {
  const jobs = [], all = { ...D.assets.photos, ...D.assets.bg };
  for (const [k, v] of Object.entries(all))
    jobs.push(Promise.all([loadImg(v.src), loadImg(v.blur)]).then(([a, b]) => { IMG[k] = { img: a, blur: b, w: a.naturalWidth, h: a.naturalHeight }; }));
  for (const [k, v] of Object.entries(D.assets.stickers || {})) jobs.push(loadImg(v.src).then(a => { STK[k] = a; }));
  for (const [k, v] of Object.entries(D.assets.videos || {})) jobs.push(new Promise((res, rej) => {
    const el = document.createElement("video"); el.muted = true; el.playsInline = true; el.preload = "auto"; el.src = v.src;
    el.addEventListener("loadeddata", () => res(), { once: true }); el.addEventListener("error", () => rej(new Error(v.src)), { once: true });
    VID[k] = el; el.load(); }));
  let done = 0; jobs.forEach(j => j.then(() => progress && progress(++done, jobs.length)));
  await Promise.all(jobs);
  for (const f of [`italic 48px ${SERIF}`, `60px ${SCRIPT}`, `80px ${DIDOT}`, `20px ${SANS}`]) { try { await document.fonts.load(f); } catch (e) {} }
}
const im = k => { const x = IMG[k]; if (!x) throw new Error("missing image " + k); return x; };
const videoDur = k => (D.assets.videos[k] || {}).dur || 0;

// ============================================================ drawing primitives
function dims(src) { return [src.videoWidth || src.naturalWidth || src.width, src.videoHeight || src.naturalHeight || src.height]; }
function coverXf(iw, ih, rx, ry, rw, rh, zoom, fx, fy) {
  const s = Math.max(rw / iw, rh / ih) * zoom, sw = rw / s, sh = rh / s;
  const sx = clamp(fx * iw - sw / 2, 0, iw - sw), sy = clamp(fy * ih - sh / 2, 0, ih - sh);
  return { s, sx, sy, sw, sh, map: (u, v) => [rx + (u * iw - sx) * s, ry + (v * ih - sy) * s] };
}
// Fill a rectangle with the image (cropping, never letterboxing); (fx, fy) = the image point kept near the centre.
function drawCover(c, src, rx, ry, rw, rh, zoom = 1, fx = 0.5, fy = 0.5) {
  const [iw, ih] = dims(src); if (!iw) return null;
  const x = coverXf(iw, ih, rx, ry, rw, rh, zoom, fx, fy);
  c.drawImage(src, x.sx, x.sy, x.sw, x.sh, rx, ry, rw, rh); return x;
}
function drawCoverRot(c, src, zoom, fx, fy, rot) {
  const k = Math.max((W * Math.abs(Math.cos(rot)) + H * Math.abs(Math.sin(rot))) / W, (W * Math.abs(Math.sin(rot)) + H * Math.abs(Math.cos(rot))) / H);
  c.save(); c.translate(W / 2, H / 2); c.rotate(rot); drawCover(c, src, -W * k / 2, -H * k / 2, W * k, H * k, zoom, fx, fy); c.restore();
}
function shade(c, color, a, mode = "source-over") { if (a <= 0) return; c.save(); c.globalCompositeOperation = mode; c.globalAlpha = a; c.fillStyle = color; c.fillRect(0, 0, W, H); c.restore(); }
function heartPath(c, x, y, s) {
  c.beginPath(); c.moveTo(x, y + s * 0.42);
  c.bezierCurveTo(x - s * 0.15, y + s * 0.30, x - s * 0.52, y + s * 0.08, x - s * 0.50, y - s * 0.16);
  c.bezierCurveTo(x - s * 0.48, y - s * 0.40, x - s * 0.18, y - s * 0.48, x, y - s * 0.26);
  c.bezierCurveTo(x + s * 0.18, y - s * 0.48, x + s * 0.48, y - s * 0.40, x + s * 0.50, y - s * 0.16);
  c.bezierCurveTo(x + s * 0.52, y + s * 0.08, x + s * 0.15, y + s * 0.30, x, y + s * 0.42); c.closePath();
}
function drawHeart(c, x, y, s, fill, alpha = 1, glow = 0) {
  c.save(); c.globalAlpha = alpha; if (glow) { c.shadowColor = fill; c.shadowBlur = glow; } c.fillStyle = fill; heartPath(c, x, y, s); c.fill(); c.restore();
}
function sparkle(c, x, y, s, a, color = "#fff6dc") {
  if (a <= 0) return; c.save(); c.globalAlpha = a; c.globalCompositeOperation = "lighter"; c.fillStyle = color;
  c.beginPath(); c.moveTo(x, y - s); c.quadraticCurveTo(x, y, x + s, y); c.quadraticCurveTo(x, y, x, y + s);
  c.quadraticCurveTo(x, y, x - s, y); c.quadraticCurveTo(x, y, x, y - s); c.fill();
  const g = c.createRadialGradient(x, y, 0, x, y, s * 0.9); g.addColorStop(0, color); g.addColorStop(1, "rgba(255,240,200,0)");
  c.fillStyle = g; c.beginPath(); c.arc(x, y, s * 0.9, 0, TAU); c.fill(); c.restore();
}
// A cut-out character popping in at t0 (overshoot), bobbing, optionally leaving at opts.t1.
function sticker(c, key, cx, bottom, h, t, t0, opts = {}) {
  const img = STK[key]; if (!img || t < t0) return;
  const p = easeBack((t - t0) / 0.55), a = clamp((t - t0) / 0.2) * (opts.t1 ? 1 - sstep(opts.t1, opts.t1 + 0.4, t) : 1) * (opts.alpha ?? 1);
  if (a <= 0) return;
  const w = h * img.naturalWidth / img.naturalHeight;
  const bob = Math.sin((t - t0) * (opts.bobSpeed ?? 2.4) + (opts.ph ?? 0)) * (opts.bob ?? 7);
  const tilt = Math.sin((t - t0) * 1.7 + (opts.ph ?? 0)) * (opts.tilt ?? 0.03);
  c.save(); c.globalAlpha = a; c.translate(cx, bottom + bob); c.rotate(tilt); c.scale(p * (opts.flip ? -1 : 1), p);
  c.shadowColor = "rgba(0,0,0,0.35)"; c.shadowBlur = 18; c.shadowOffsetY = 8;
  c.drawImage(img, -w / 2, -h, w, h); c.restore();
}
function print(c, key, cx, cy, h, rot, alpha = 1, border = 16, scale = 1) {
  const x = im(key), w = h * x.w / x.h;
  c.save(); c.globalAlpha = alpha; c.translate(cx, cy); c.rotate(rot); c.scale(scale, scale);
  c.shadowColor = "rgba(0,0,0,0.55)"; c.shadowBlur = 40; c.shadowOffsetY = 14;
  c.fillStyle = "#fbf7ef"; c.fillRect(-w / 2 - border, -h / 2 - border, w + 2 * border, h + 2 * border);
  c.shadowColor = "transparent"; c.drawImage(x.img, -w / 2, -h / 2, w, h); c.restore();
}
function polaroid(c, key, cx, cy, size, rot, alpha, scale, caption) {
  const x = im(key), m = size * 0.06, bottom = size * 0.24;
  c.save(); c.globalAlpha = alpha; c.translate(cx, cy); c.rotate(rot); c.scale(scale, scale);
  const fw = size + 2 * m, fh = size + m + bottom;
  c.shadowColor = "rgba(0,0,0,0.5)"; c.shadowBlur = 30 * scale; c.shadowOffsetY = 10 * scale;
  c.fillStyle = "#fdfbf6"; c.fillRect(-fw / 2, -fh / 2, fw, fh); c.shadowColor = "transparent";
  drawCover(c, x.img, -fw / 2 + m, -fh / 2 + m, size, size, 1, 0.5, 0.45);
  if (caption) { c.fillStyle = "#4a3b33"; c.font = `italic ${Math.round(size * 0.085)}px ${SERIF}`; c.textAlign = "center"; c.fillText(caption, 0, fh / 2 - bottom * 0.38); }
  c.restore();
}
function glowText(c, text, x, y, font, color, alpha, glow = 24, glowColor = "rgba(255,210,150,0.8)", spacing = 0) {
  if (alpha <= 0) return; c.save(); c.globalAlpha = alpha; c.font = font; c.textAlign = "center"; c.textBaseline = "alphabetic";
  c.letterSpacing = spacing + "px"; c.shadowColor = glowColor; c.shadowBlur = glow; c.fillStyle = color; c.fillText(text, x, y);
  c.shadowBlur = 0; c.fillText(text, x, y); c.restore();
}
function floatingHearts(c, t, t0, x, y, opts = {}) {   // a few small hearts rising from (x, y)
  const n = opts.n ?? 5, life = opts.life ?? 3.2, gap = opts.gap ?? 0.55, dt = t - t0;
  if (dt > 0) for (let i = 0; i < n; i++) { const d = dt - i * gap; if (d < 0 || d > life) continue;
    drawHeart(c, x + Math.sin(d * 2 + i) * 40 + d * (opts.dx ?? 60), y - d * 120, 26 + i * 4, opts.color ?? "#ff7f96", (1 - d / life) * 0.9, 18); }
}

// ---- pre-rendered sprites
function bokehSprite(r, g, b) {
  const s = mk(256, 256), c = s.getContext("2d"), gr = c.createRadialGradient(128, 128, 0, 128, 128, 128);
  gr.addColorStop(0, `rgba(${r},${g},${b},0.45)`); gr.addColorStop(0.72, `rgba(${r},${g},${b},0.55)`);
  gr.addColorStop(0.86, `rgba(${r},${g},${b},0.75)`); gr.addColorStop(1, `rgba(${r},${g},${b},0)`);
  c.fillStyle = gr; c.fillRect(0, 0, 256, 256); return s;
}
const BOKEH_SPR = [bokehSprite(255, 196, 120), bokehSprite(255, 150, 110), bokehSprite(255, 170, 200), bokehSprite(200, 170, 255), bokehSprite(255, 230, 180)];
const GLOW_SPR = (() => { const s = mk(256, 256), c = s.getContext("2d"), g = c.createRadialGradient(128, 128, 0, 128, 128, 128);
  g.addColorStop(0, "rgba(255,236,190,1)"); g.addColorStop(0.25, "rgba(255,200,120,0.55)"); g.addColorStop(1, "rgba(255,160,80,0)");
  c.fillStyle = g; c.fillRect(0, 0, 256, 256); return s; })();
const VIGNETTE = (() => { const s = mk(W, H), c = s.getContext("2d"), g = c.createRadialGradient(W / 2, H / 2, H * 0.38, W / 2, H / 2, H * 1.08);
  g.addColorStop(0, "rgba(0,0,0,0)"); g.addColorStop(1, "rgba(8,3,12,0.85)"); c.fillStyle = g; c.fillRect(0, 0, W, H); return s; })();
const GRAIN = (() => { const R = rng(99), out = []; for (let k = 0; k < 6; k++) { const s = mk(384, 384), c = s.getContext("2d"), d = c.createImageData(384, 384);
  for (let i = 0; i < d.data.length; i += 4) { const v = 128 + (R() - 0.5) * 255; d.data[i] = d.data[i + 1] = d.data[i + 2] = v; d.data[i + 3] = 255; }
  c.putImageData(d, 0, 0); out.push(s); } return out; })();
const GRAIN_PAT = GRAIN.map(g => ctx.createPattern(g, "repeat"));
const MOON = (() => { const s = mk(220, 220), c = s.getContext("2d");
  c.fillStyle = "#fff4d6"; c.shadowColor = "rgba(255,240,200,0.9)"; c.shadowBlur = 30; c.beginPath(); c.arc(110, 110, 62, 0, TAU); c.fill();
  c.shadowBlur = 0; c.globalCompositeOperation = "destination-out"; c.beginPath(); c.arc(138, 92, 56, 0, TAU); c.fill(); return s; })();

// ---- particle sets (deterministic: the same frame always draws the same particles)
const R1 = rng(2026);
const BOKEH = Array.from({ length: 64 }, () => ({ x: R1() * W, y: R1() * H, r: 18 + Math.pow(R1(), 2) * 95, vx: (R1() - 0.5) * 14,
  vy: -(3 + R1() * 12), ph: R1() * TAU, col: Math.floor(R1() * BOKEH_SPR.length), sp: 0.4 + R1() * 0.8 }));
const STARS = Array.from({ length: 260 }, () => ({ x: R1() * W, y: Math.pow(R1(), 1.4) * H * 0.78, r: 0.6 + Math.pow(R1(), 3) * 2.4, ph: R1() * TAU, sp: 0.6 + R1() * 2.2 }));
const DUST = Array.from({ length: 120 }, () => ({ x: R1() * W, y: R1() * H, r: 1 + R1() * 3.2, vx: (R1() - 0.5) * 18, vy: -(6 + R1() * 22), ph: R1() * TAU }));

function drawBokeh(c, t, amt, set = BOKEH) {
  if (amt <= 0.01) return; c.save(); c.globalCompositeOperation = "lighter";
  for (const b of set) {
    const span = W + 2 * b.r, spanY = H + 2 * b.r;
    const x = ((b.x + b.vx * t) % span + span) % span - b.r, y = ((b.y + b.vy * t) % spanY + spanY) % spanY - b.r;
    c.globalAlpha = amt * (0.10 + 0.22 * Math.pow(Math.sin(t * b.sp + b.ph), 2));
    c.drawImage(BOKEH_SPR[b.col], x - b.r, y - b.r, 2 * b.r, 2 * b.r);
  }
  c.restore();
}
function drawStars(c, t, amt) {
  if (amt <= 0) return; c.save(); c.fillStyle = "#fffaf0";
  for (const s of STARS) { c.globalAlpha = amt * (0.35 + 0.65 * Math.pow(Math.sin(t * s.sp + s.ph) * 0.5 + 0.5, 2)); c.beginPath(); c.arc(s.x, s.y, s.r, 0, TAU); c.fill(); }
  c.restore();
}
function drawDust(c, t, amt) {
  if (amt <= 0) return; c.save(); c.globalCompositeOperation = "lighter";
  for (const d of DUST) { const x = ((d.x + d.vx * t) % W + W) % W, y = ((d.y + d.vy * t) % H + H) % H;
    c.globalAlpha = amt * (0.3 + 0.7 * Math.pow(Math.sin(t * 1.3 + d.ph), 2)); c.drawImage(GLOW_SPR, x - d.r * 4, y - d.r * 4, d.r * 8, d.r * 8); }
  c.restore();
}
function lightLeak(c, t, amt, seed = 0) {
  if (amt <= 0.01) return; c.save(); c.globalCompositeOperation = "screen";
  const cols = [[255, 132, 50], [255, 82, 110], [255, 196, 110]];
  for (let k = 0; k < 3; k++) {
    const ph = seed * 1.7 + k * 2.1;
    // swing, never wrap: a centre that wraps from one edge to the other would jump in a single frame
    const cx = W * (0.5 + 0.65 * Math.sin(TAU * (0.13 * seed + k * 0.37) + t * 0.28)), cy = H * (0.25 + 0.5 * Math.sin(t * 0.3 + ph));
    const r = 650 + 280 * Math.sin(t * 0.5 + ph), col = cols[k];
    const g = c.createRadialGradient(cx, cy, 0, cx, cy, r);
    g.addColorStop(0, `rgba(${col},${0.62 * amt})`); g.addColorStop(0.5, `rgba(${col},${0.22 * amt})`); g.addColorStop(1, `rgba(${col},0)`);
    c.fillStyle = g; c.fillRect(0, 0, W, H);
  }
  c.restore();
}
function drawSky(c, k, t) {    // k: 0 = deep night, 1 = warm dawn
  const g = c.createLinearGradient(0, 0, 0, H);
  const mix = (a, b) => a.map((v, i) => Math.round(lerp(v, b[i], k)));
  g.addColorStop(0, `rgb(${mix([6, 9, 30], [58, 80, 150])})`); g.addColorStop(0.55, `rgb(${mix([26, 20, 66], [214, 130, 150])})`);
  g.addColorStop(1, `rgb(${mix([52, 30, 80], [255, 196, 140])})`); c.fillStyle = g; c.fillRect(0, 0, W, H);
  const hg = c.createRadialGradient(W / 2, H * 1.05, 0, W / 2, H * 1.05, H * 0.9);
  hg.addColorStop(0, `rgba(255,170,120,${0.25 + 0.4 * k})`); hg.addColorStop(1, "rgba(255,170,120,0)"); c.fillStyle = hg; c.fillRect(0, 0, W, H);
}
// Two places as silhouettes: a city on the left (opts.tower adds a needle tower), mountains on the right.
function drawCities(c, alpha, opts = {}) {
  if (alpha <= 0) return; c.save(); c.globalAlpha = alpha; c.fillStyle = "#0b0716";
  const R = rng(5); let x = 0;
  while (x < 760) { const w = 30 + R() * 60, h = 70 + R() * 150; c.fillRect(x, H - h, w + 1, h); x += w; }
  if (opts.tower) { c.fillRect(402, 690, 16, 400); c.beginPath(); c.ellipse(410, 690, 44, 16, 0, 0, TAU); c.fill(); c.fillRect(392, 668, 36, 22); c.fillRect(408, 610, 4, 60); }
  c.beginPath(); c.moveTo(1120, H); const peaks = [[1180, 930], [1290, 820], [1370, 880], [1480, 760], [1580, 860], [1680, 790], [1790, 870], [1920, 820], [1920, H]];
  for (const [px, py] of peaks) c.lineTo(px, py); c.closePath(); c.fill();
  c.fillStyle = "rgba(255,240,230,0.18)"; c.beginPath(); c.moveTo(1440, 800); c.lineTo(1480, 760); c.lineTo(1520, 800); c.lineTo(1480, 790); c.fill();
  c.beginPath(); c.moveTo(1650, 815); c.lineTo(1680, 790); c.lineTo(1712, 818); c.fill();
  const R2 = rng(11); c.fillStyle = "rgba(255,214,150,0.85)";
  for (let i = 0; i < 90; i++) { const wx = R2() * 740, wy = H - 20 - R2() * 120; c.fillRect(wx, wy, 3, 3); }
  c.restore();
}
function drawClock(c, x, y, r, minutes, alpha, tint = "255,246,230") {
  if (alpha <= 0) return; c.save(); c.globalAlpha = alpha; c.translate(x, y);
  const g = c.createRadialGradient(0, -r * 0.3, r * 0.1, 0, 0, r); g.addColorStop(0, "rgba(255,255,255,0.16)"); g.addColorStop(1, "rgba(255,255,255,0.04)");
  c.fillStyle = g; c.beginPath(); c.arc(0, 0, r, 0, TAU); c.fill();
  c.strokeStyle = `rgba(${tint},0.85)`; c.lineWidth = 2.5; c.shadowColor = `rgba(${tint},0.7)`; c.shadowBlur = 16; c.beginPath(); c.arc(0, 0, r, 0, TAU); c.stroke();
  for (let i = 0; i < 12; i++) { const a = i / 12 * TAU, l = i % 3 === 0 ? 0.16 : 0.08; c.lineWidth = i % 3 === 0 ? 3 : 1.5;
    c.beginPath(); c.moveTo(Math.sin(a) * r * (0.92 - l), -Math.cos(a) * r * (0.92 - l)); c.lineTo(Math.sin(a) * r * 0.92, -Math.cos(a) * r * 0.92); c.stroke(); }
  const hand = (ang, len, wdt, col) => { c.strokeStyle = col; c.lineWidth = wdt; c.lineCap = "round"; c.beginPath(); c.moveTo(-Math.sin(ang) * r * 0.1, Math.cos(ang) * r * 0.1); c.lineTo(Math.sin(ang) * len, -Math.cos(ang) * len); c.stroke(); };
  hand(minutes / 720 * TAU, r * 0.5, 6, `rgba(${tint},0.95)`); hand(minutes / 60 * TAU, r * 0.76, 3.5, `rgba(${tint},0.95)`);
  hand(minutes * TAU, r * 0.84, 1.4, "rgba(243,198,107,0.95)");
  c.fillStyle = "#f3c66b"; c.beginPath(); c.arc(0, 0, 6, 0, TAU); c.fill(); c.restore();
}
function drawSun(c, x, y, r, t, alpha) {
  if (alpha <= 0) return; c.save(); c.globalAlpha = alpha; c.globalCompositeOperation = "lighter";
  c.drawImage(GLOW_SPR, x - r * 4, y - r * 4, r * 8, r * 8);
  c.translate(x, y); c.rotate(t * 0.15); c.fillStyle = "rgba(255,220,150,0.35)";
  for (let i = 0; i < 12; i++) { c.rotate(TAU / 12); c.beginPath(); c.moveTo(-6, r * 1.25); c.lineTo(6, r * 1.25); c.lineTo(0, r * 2.4); c.fill(); }
  c.fillStyle = "#fff3cf"; c.beginPath(); c.arc(0, 0, r, 0, TAU); c.fill(); c.restore();
}
function drawFlame(c, x, y, s, t, alpha) {    // procedural candle flame, base at (x, y)
  if (alpha <= 0) return;
  const fl = 1 + 0.08 * Math.sin(t * 13.1) + 0.05 * Math.sin(t * 7.3 + 1) + 0.04 * Math.sin(t * 21.7);
  const sway = 0.06 * Math.sin(t * 3.1) + 0.03 * Math.sin(t * 8.9);
  c.save(); c.globalAlpha = alpha; c.globalCompositeOperation = "lighter";
  c.drawImage(GLOW_SPR, x - s * 3.2 * fl, y - s * 4.2 * fl, s * 6.4 * fl, s * 6.4 * fl);
  c.translate(x, y); c.rotate(sway); const h = s * 1.9 * fl, w = s * 0.55;
  const g = c.createLinearGradient(0, -h, 0, 0); g.addColorStop(0, "rgba(255,190,90,0)"); g.addColorStop(0.35, "rgba(255,200,110,0.9)"); g.addColorStop(0.75, "rgba(255,246,220,1)"); g.addColorStop(1, "rgba(120,150,255,0.7)");
  c.fillStyle = g; c.beginPath(); c.moveTo(0, -h); c.bezierCurveTo(w * 0.9, -h * 0.45, w, -h * 0.05, 0, 0); c.bezierCurveTo(-w, -h * 0.05, -w * 0.9, -h * 0.45, 0, -h); c.fill();
  c.restore();
}
function confetti(c, t, t0, x0, y0, n, seed, spread = 1) {
  if (t < t0) return; const R = rng(seed), dt = t - t0; if (dt > 7) return;
  const cols = ["#f3c66b", "#ff8fa3", "#ffd6e0", "#c9b6ff", "#ffffff", "#ffb36b"];
  c.save();
  for (let i = 0; i < n; i++) {
    const ang = -Math.PI / 2 + (R() - 0.5) * 2.4 * spread, sp = 500 + R() * 900, drag = 1.6;
    const vx = Math.cos(ang) * sp, vy = Math.sin(ang) * sp, k = (1 - Math.exp(-drag * dt)) / drag;
    const x = x0 + vx * k + Math.sin(dt * 3 + i) * 30, y = y0 + vy * k + 160 * dt * dt * 0.5 + 120 * dt;
    const rot = R() * TAU + dt * (R() - 0.5) * 12, w = 8 + R() * 10, h = 5 + R() * 8;
    c.globalAlpha = 1 - sstep(4.5, 7, dt); c.fillStyle = cols[i % cols.length];
    c.save(); c.translate(x, y); c.rotate(rot); c.scale(1, Math.abs(Math.cos(dt * 6 + i))); c.fillRect(-w / 2, -h / 2, w, h); c.restore();
  }
  c.restore();
}
function musicNotes(c, t, t0, opts = {}) {   // notes rising and fading
  const n = opts.n ?? 14, gap = opts.gap ?? 0.35, life = opts.life ?? 5, R = rng(opts.seed ?? 77);
  c.save(); c.font = `${opts.size ?? 54}px "Apple Symbols", ${SERIF}`;
  for (let i = 0; i < n; i++) { const d = t - t0 - i * gap, rx = R(); if (d < 0 || d > life) continue;
    const x = (opts.x0 ?? 700) + rx * (opts.w ?? 700) + Math.sin(d * (opts.wob ?? 1.8) + i) * (opts.amp ?? 40), y = (opts.y0 ?? 900) - d * (opts.speed ?? 150);
    const fade = opts.fadeFrom ? 1 - sstep(opts.fadeFrom, life, d) : 1 - d / life;
    c.globalAlpha = Math.min(1, d / 0.4) * fade * (opts.alpha ?? 0.9); c.fillStyle = opts.color ?? "#ffe8bf"; c.shadowColor = opts.glowColor ?? "rgba(255,200,120,0.9)"; c.shadowBlur = opts.glow ?? 16;
    c.fillText((opts.glyphs || ["♪", "♫", "♩", "♬"])[i % 4], x, y); }
  c.restore();
}
function titleCanvas(text, w, h, px, font, stops, glow, blur, y, gy0, gy1) {   // pre-render a glowing gradient title once
  const cvs = mk(w, h), c = cvs.getContext("2d"), g = c.createLinearGradient(0, gy0, 0, gy1);
  stops.forEach((s, i) => g.addColorStop(i / (stops.length - 1), s));
  c.textAlign = "center"; c.font = `${px}px ${font}`; c.shadowColor = glow; c.shadowBlur = blur; c.fillStyle = g; c.fillText(text, w / 2, y);
  c.shadowBlur = 0; c.fillText(text, w / 2, y); return cvs;
}

// ============================================================ scene builders
// A scene is { videos, draw(c, t, s) }. In draw, s.cut = its cut time, s.a..s.b = visible window, s.end = next cut.
const P = (key, o = {}) => ({ videos: [], draw(c, t, s) {      // full-frame photo with slow zoom and pan (Ken Burns)
  const p = (t - s.a) / (s.b - s.a), z0 = o.z ? o.z[0] : 1.02, z1 = o.z ? o.z[1] : 1.1;
  const f0 = o.f0 || [0.5, 0.5], f1 = o.f1 || f0, src = o.blur ? im(key).blur : im(key).img;
  const fx = lerp(f0[0], f1[0], p), fy = lerp(f0[1], f1[1], p), z = lerp(z0, z1, p);
  let xf = null;
  if (o.rot) drawCoverRot(c, src, z, fx, fy, lerp(o.rot[0], o.rot[1], p)); else xf = drawCover(c, src, 0, 0, W, H, z, fx, fy);
  if (o.grade) shade(c, o.grade[0], o.grade[1], o.grade[2] || "soft-light");
  if (o.after) o.after(c, t, s, p, xf);
} });
const PB = (key, o = {}) => ({ videos: [], draw(c, t, s) {     // photo fitted inside the letterbox window (faces sit high)
  const p = (t - s.a) / (s.b - s.a), top = o.top ?? 136;
  c.fillStyle = "#000"; c.fillRect(0, 0, W, H);
  drawCover(c, im(key).img, 0, top, W, H - 2 * top, lerp(o.z?.[0] ?? 1.0, o.z?.[1] ?? 1.08, p), lerp((o.f0 || [0.5, 0.4])[0], (o.f1 || o.f0 || [0.5, 0.4])[0], p), lerp((o.f0 || [0.5, 0.4])[1], (o.f1 || o.f0 || [0.5, 0.4])[1], p));
  if (o.after) o.after(c, t, s, p);
} });
const PR = (key, o = {}) => ({ videos: [], draw(c, t, s) {     // portrait photo as a bordered print over its own blur
  const p = (t - s.a) / (s.b - s.a);
  drawCover(c, im(key).blur, 0, 0, W, H, 1.15 + 0.05 * p, 0.5, 0.5); shade(c, "#120a18", 0.35);
  const lt = t - s.cut, slide = o.dx ? (1 - easeOut((lt + 0.5) / 1.3)) * o.dx : 0;
  print(c, key, (o.x ?? 960) + slide, o.y ?? 505, o.h ?? 860, lerp(o.r0 ?? -0.02, o.r1 ?? 0.01, p), 1, 14, lerp(1, 1.045, p));
  if (o.after) o.after(c, t, s, p);
} });
const V = (key, o = {}) => ({ videos: [{ key, rate: o.rate ?? 1, off: o.off ?? 0 }], draw(c, t, s) {   // full-frame video clip
  const p = (t - s.a) / (s.b - s.a);
  drawCover(c, VID[key], 0, 0, W, H, lerp(o.z?.[0] ?? 1.0, o.z?.[1] ?? 1.05, p), 0.5, o.fy ?? 0.5);
  if (o.grade) shade(c, o.grade[0], o.grade[1], o.grade[2] || "soft-light");
  if (o.after) o.after(c, t, s, p);
} });
const S = (fn, videos = []) => ({ videos, draw: fn });          // anything else

// ---- the scene library: each one was built for one lyric moment and parameterised afterwards
const lib = {};
lib.titleIntro = o => S((c, t) => {                // blurred picture comes into focus under the title
  const x = im(o.bg), fo = o.focus || [6.0, 11.0], focus = sstep(fo[0], fo[1], t), z = lerp(1.16, 1.05, clamp(t / 12)), f = o.f || [0.42, 0.45];
  drawCover(c, x.blur, 0, 0, W, H, z, f[0], f[1]);
  c.save(); c.globalAlpha = focus; drawCover(c, x.img, 0, 0, W, H, z, f[0], f[1]); c.restore();
  shade(c, "#0b0614", 0.45 * (1 - focus) + 0.15);
  const out = 1 - sstep(8.6, 10.4, t);
  glowText(c, o.title, 960, 500, `400 104px ${DIDOT}`, "#fbf1e2", sstep(1.4, 3.2, t) * out, 30, "rgba(255,200,140,0.55)", 6);
  const la = sstep(3.0, 4.6, t) * out;
  c.save(); c.globalAlpha = la; c.strokeStyle = "rgba(243,198,107,0.8)"; c.lineWidth = 1.2; c.beginPath(); c.moveTo(960 - 230 * la, 548); c.lineTo(960 + 230 * la, 548); c.stroke(); c.restore();
  if (o.subtitle) glowText(c, o.subtitle, 960, 628, `64px ${SCRIPT}`, "#f6d9a8", sstep(3.6, 5.2, t) * out, 18);
  if (o.date) glowText(c, o.date, 960, 700, `500 24px ${SANS}`, "rgba(250,235,215,0.8)", sstep(4.6, 6.2, t) * out, 0, "transparent", 12);
});
const sideVideos = o => [o.left, o.right].filter(sd => sd && sd.video).map(sd => ({ key: sd.video, rate: sd.rate ?? 1, off: sd.off ?? 0 }));
const side = (c, sd, x, w, p) => {                 // one half of a split: { img | video, f, zoom: n | [a, b] }
  const z = Array.isArray(sd.zoom) ? lerp(sd.zoom[0], sd.zoom[1], p) : (sd.zoom ?? 1.1), f = sd.f || [0.5, 0.5];
  drawCover(c, sd.video ? VID[sd.video] : im(sd.img).img, x, 0, w, H, z, f[0], f[1]);
};
lib.splitScreen = o => S((c, t, s) => {            // two lives side by side; the right half slides in
  const lt = t - s.cut, p = (t - s.a) / (s.b - s.a), open = easeOut((lt + 0.6) / 1.6), hw = W / 2, rx = hw + (1 - open) * hw;
  side(c, { ...o.left, zoom: o.left.zoom ?? [1.08, 1.03] }, 0, W, p);
  c.save(); c.beginPath(); c.rect(rx, 0, hw, H); c.clip(); side(c, o.right, rx, hw, p); c.restore();
  c.save(); c.globalAlpha = open; c.strokeStyle = "rgba(255,226,180,0.9)"; c.shadowColor = "rgba(255,200,140,1)"; c.shadowBlur = 24; c.lineWidth = 2;
  c.beginPath(); c.moveTo(rx, 0); c.lineTo(rx, H); c.stroke(); c.restore();
  const la = sstep(1.0, 2.2, lt);
  (o.labels || []).forEach((lb, i) => glowText(c, lb, i ? hw + hw / 2 : hw / 2, 230, `58px ${SCRIPT}`, "#fff1d8", la, 22, "rgba(0,0,0,0.75)"));
}, sideVideos(o));
lib.twinClocks = o => S((c, t, s) => {             // two clocks out of step over day and night halves, then a sun and a moon
  const lt = t - s.cut, p = (t - s.a) / (s.b - s.a), hw = W / 2, sunAt = o.sunMoonAt ?? 3.5;
  side(c, o.left, 0, hw, p); side(c, o.right, hw, hw, p); shade(c, "#0a0820", 0.25);
  c.save(); c.strokeStyle = "rgba(255,226,180,0.8)"; c.lineWidth = 2; c.shadowColor = "rgba(255,200,140,1)"; c.shadowBlur = 20; c.beginPath(); c.moveTo(hw, 0); c.lineTo(hw, H); c.stroke(); c.restore();
  const mins = (o.startMinutes ?? 14 * 60) + lt * (o.speed ?? 42), ca = sstep(-0.2, 0.9, lt) * (1 - 0.55 * sstep(sunAt - 0.1, sunAt + 0.9, lt));
  drawClock(c, hw / 2, 470, 170, mins, ca);
  drawClock(c, hw + hw / 2, 470, 170, mins + (o.offsetMinutes ?? 0) + Math.sin(lt * 2.3) * 9 - lt * 4, ca);
  const sm = sstep(sunAt, sunAt + 1.1, lt);
  drawSun(c, hw / 2, 190, 46, t, sm);
  c.save(); c.globalAlpha = sm; c.drawImage(MOON, hw + hw / 2 - 110, 80, 220, 220); c.restore();
  c.save(); c.beginPath(); c.rect(hw, 0, hw, H); c.clip(); drawStars(c, t, 0.6 * sm); c.restore();
}, sideVideos(o));
lib.phoneChat = o => S((c, t, s) => {              // a phone receiving a voice message and photos
  const lt = t - s.cut, p = (t - s.a) / (s.b - s.a);
  drawCover(c, im(o.bg).blur, 0, 0, W, H, 1.1, 0.4, 0.5); shade(c, "#120818", 0.35); drawBokeh(c, t, 0.6);
  const sc = lerp(0.9, 0.94, p), pw = 440, ph = 820;
  c.save(); c.translate(960, 540); c.scale(sc, sc); c.translate(-pw / 2, -ph / 2);
  c.shadowColor = "rgba(0,0,0,0.6)"; c.shadowBlur = 60; c.fillStyle = "#16141a"; c.beginPath(); c.roundRect(0, 0, pw, ph, 58); c.fill();
  c.shadowColor = "transparent"; c.strokeStyle = "#3b3640"; c.lineWidth = 4; c.stroke();
  const sx = 14, sy = 14, sw = pw - 28, sh = ph - 28;
  const g = c.createLinearGradient(0, sy, 0, sy + sh); g.addColorStop(0, "#221c2a"); g.addColorStop(1, "#14111a");
  c.fillStyle = g; c.beginPath(); c.roundRect(sx, sy, sw, sh, 46); c.fill();
  c.save(); c.beginPath(); c.roundRect(sx, sy, sw, sh, 46); c.clip();
  c.fillStyle = "#000"; c.beginPath(); c.roundRect(pw / 2 - 60, 26, 120, 30, 15); c.fill();
  c.fillStyle = "#f7ecdf"; c.font = `600 26px ${SANS}`; c.textAlign = "center"; c.fillText(o.name || "", pw / 2 - 10, 106);
  if (o.heart !== false) drawHeart(c, pw / 2 + 34, 97, 22, "#ff7f96", 1);
  c.strokeStyle = "rgba(255,255,255,0.08)"; c.lineWidth = 1; c.beginPath(); c.moveTo(sx, 128); c.lineTo(sx + sw, 128); c.stroke();
  let y = 150;
  for (const b of o.bubbles) {
    if (b.type === "typing") { if (lt > b.from && lt < b.to) { const ty = b.y ?? y; c.fillStyle = "#34303d"; c.beginPath(); c.roundRect(36, ty, 96, 50, 24); c.fill();
      for (let i = 0; i < 3; i++) { c.fillStyle = `rgba(255,255,255,${0.35 + 0.5 * Math.max(0, Math.sin(lt * 7 - i * 0.9))})`; c.beginPath(); c.arc(62 + i * 22, ty + 25, 6, 0, TAU); c.fill(); } } continue; }
    const by = b.y ?? y, bh = b.type === "voice" ? 76 : (b.h ?? 270), a = easeOut((lt - b.at) / 0.45);
    y = by + bh + (b.gap ?? 18);
    if (a <= 0) continue;
    const yy = by + (1 - a) * 40; c.globalAlpha = a;
    if (b.type === "voice") { c.fillStyle = "#34303d"; c.beginPath(); c.roundRect(36, yy, 320, bh, 26); c.fill();
      c.fillStyle = "#f3c66b"; c.beginPath(); c.moveTo(62, yy + 24); c.lineTo(62, yy + 52); c.lineTo(86, yy + 38); c.fill();
      const prog = clamp((lt - b.at - 0.35) / (b.play ?? 5.5));
      for (let i = 0; i < 26; i++) { const amp = 0.25 + 0.75 * Math.abs(Math.sin(i * 1.7 + Math.floor(lt * 8) * 0.9 * (i / 26 < prog ? 1 : 0.2)));
        const hgt = 6 + amp * 30; c.fillStyle = i / 26 < prog ? "#f3c66b" : "rgba(255,255,255,0.45)"; c.fillRect(104 + i * 9, yy + 38 - hgt / 2, 5, hgt); } }
    else { const bw = b.w ?? 270, f = b.f || [0.5, 0.42]; c.save(); c.beginPath(); c.roundRect(36, yy, bw, bh, 24); c.clip();
      drawCover(c, im(b.key).img, 36, yy, bw, bh, b.zoom ?? 1.05, f[0], f[1]); c.restore();
      if (b.heartAt != null && lt > b.heartAt) { const ha = easeBack((lt - b.heartAt) / 0.5); c.save(); c.translate(36 + bw - 6, yy + bh - 4); c.scale(ha, ha);
        c.fillStyle = "#2b2733"; c.beginPath(); c.arc(0, 0, 24, 0, TAU); c.fill(); drawHeart(c, 0, 1, 26, "#ff6f8a", 1); c.restore(); } }
    c.globalAlpha = 1;
  }
  c.restore(); c.restore();
});
lib.polaroidDrop = o => S((c, t, s) => {           // small moments dropping onto a table, one per beat
  const lt = t - s.cut, p = (t - s.a) / (s.b - s.a), size = o.size ?? 300, step = o.step ?? BEAT, t0 = o.start ?? 0.3;
  drawCover(c, im(o.bg).blur, 0, 0, W, H, 1.2, 0.5, 0.5); shade(c, "#1a0d08", 0.4); drawBokeh(c, t * 0.6, 0.5);
  c.save(); c.translate(lerp(20, -20, p), 0);
  o.items.forEach(([k, x, y, r, cap], i) => { const d = lt - (t0 + i * step); if (d < 0) return;
    const a = easeOut(d / 0.35), sc = lerp(1.35, 1, easeOut(d / 0.45)) + 0.02 * Math.exp(-Math.max(0, d - 0.45) * 6) * Math.sin(d * 30);
    polaroid(c, k, x, y - (1 - a) * 50, size, r + (1 - a) * 0.2, a, sc, cap); });
  c.restore();
});
lib.cloudDrift = o => S((c, t, s) => {             // a wide view panning slowly under drifting haze
  const p = (t - s.a) / (s.b - s.a), pan = o.pan || [0.35, 0.65];
  drawCover(c, im(o.key).img, 0, 0, W, H, o.zoom ?? 1.12, lerp(pan[0], pan[1], p), 0.5);
  c.save(); c.globalCompositeOperation = "screen";
  for (let i = 0; i < 5; i++) { const x = ((i * 520 + t * (28 + i * 9)) % (W + 900)) - 450, y = 180 + i * 60;
    const g = c.createRadialGradient(x, y, 0, x, y, 420); g.addColorStop(0, "rgba(255,255,255,0.16)"); g.addColorStop(1, "rgba(255,255,255,0)"); c.fillStyle = g; c.fillRect(0, 0, W, H); }
  c.restore();
});
lib.videoPanels = o => S((c, t, s) => {            // portrait clips side by side, entering one after another, kicking on the beat
  const lt = t - s.cut, n = o.keys.length, pw = W / n; c.fillStyle = "#000"; c.fillRect(0, 0, W, H);
  const delays = o.delays || o.keys.map((_, i) => i * 0.65);
  o.keys.forEach((k, i) => { const x = i * pw, e = easeOut((lt - delays[i]) / 0.6); if (e <= 0) return;
    const kick = 1 + 0.03 * beatPulse(t, 0.18), off = (1 - e) * (i === n - 1 ? 1 : -1) * 260;
    c.save(); c.beginPath(); c.rect(x + 3, 0, pw - 6, H); c.clip(); c.globalAlpha = e;
    drawCover(c, VID[k], x + 3, off, pw - 6, H, 1.04 * kick, 0.5, 0.5); c.restore(); });
  shade(c, "#ffb070", 0.10, "soft-light");
}, o.keys.map(k => ({ key: k, rate: 1, off: 0 })));
lib.lightsBlur = o => P(o.key, { z: o.z || [1.02, 1.1], f0: o.f0 || [0.36, 0.45], f1: o.f1 || [0.33, 0.4], after(c, t) {   // city lights blur and merge into one glow
  const t1 = at(o.blurAt), k = sstep(t1, t1 + 2.6, t), merge = sstep(t1 + 1.2, t1 + 5.5, t), to = o.mergeTo || [1350, 470], spot = o.lights || [980, 250, 900, 520];
  c.save(); c.globalAlpha = k; drawCover(c, im(o.key).blur, 0, 0, W, H, 1.1, 0.35, 0.42); c.restore();
  if (k > 0) { c.save(); c.globalCompositeOperation = "lighter"; const R = rng(31);
    for (let i = 0; i < 26; i++) { const x0 = spot[0] + R() * spot[2], y0 = spot[1] + R() * spot[3], r = 30 + R() * 60;
      const x = lerp(x0, to[0], merge), y = lerp(y0, to[1], merge), rr = lerp(r, 40, merge);
      c.globalAlpha = k * (0.5 - 0.3 * merge); c.drawImage(BOKEH_SPR[i % 2 ? 0 : 4], x - rr, y - rr, rr * 2, rr * 2); }
    c.globalAlpha = merge; c.drawImage(GLOW_SPR, to[0] - 260, to[1] - 260, 520, 520); c.restore(); }
  if (o.notesAt) { const t2 = at(o.notesAt); if (t > t2 - 0.3) musicNotes(c, t, t2); }
} });
lib.distance = o => S((c, t, s) => {               // night sky: a heart crosses the arc between two people, then they meet and it warms
  const tArc = at(o.arcAt), tMeet = at(o.meetAt), tWarm = at(o.warmAt), labels = o.labels || ["you", "me"];
  const warm = sstep(tWarm - 0.5, tWarm + 5.0, t);
  drawSky(c, warm, t); drawStars(c, t, 1 - warm * 0.85); if (o.skyline !== false) drawCities(c, 0.95 - 0.3 * warm, o.skylineOpts || {});
  const A = o.A || [440, 500], B = o.B || [1480, 540], C = o.C || [960, 170];
  const q = u => [lerp(lerp(B[0], C[0], u), lerp(C[0], A[0], u), u), lerp(lerp(B[1], C[1], u), lerp(C[1], A[1], u), u)];
  const prog = easeIO((t - tArc - 0.3) / 4.8), arcA = sstep(tArc - 0.5, tArc + 0.5, t) * (1 - sstep(tMeet - 3.4, tMeet - 2.2, t));
  if (arcA > 0) {
    c.save(); c.globalAlpha = arcA; c.setLineDash([3, 14]); c.lineCap = "round"; c.lineWidth = 3; c.strokeStyle = "rgba(255,230,190,0.85)";
    c.beginPath(); const n = 80; for (let i = 0; i <= n * prog; i++) { const [x, y] = q(i / n); i ? c.lineTo(x, y) : c.moveTo(x, y); } c.stroke(); c.setLineDash([]);
    for (const [P0, lbl] of [[A, labels[0]], [B, labels[1]]]) { c.globalCompositeOperation = "lighter"; c.drawImage(GLOW_SPR, P0[0] - 60, P0[1] - 60, 120, 120);
      c.globalCompositeOperation = "source-over"; c.fillStyle = "#fff4dc"; c.beginPath(); c.arc(P0[0], P0[1], 7, 0, TAU); c.fill();
      glowText(c, lbl, P0[0], P0[1] - 42, `52px ${SCRIPT}`, "#ffeccc", arcA, 14); }
    if (prog > 0 && prog < 1) { const [hx, hy] = q(prog); drawHeart(c, hx, hy, 40, "#ff7f96", 1, 30); }
    const arrive = t - (tArc + 5.1); if (arrive > 0 && arrive < 1.6) { c.strokeStyle = `rgba(255,160,180,${1 - arrive / 1.6})`; c.lineWidth = 3;
      for (let r = 0; r < 3; r++) { c.beginPath(); c.arc(A[0], A[1], 20 + (arrive * 120) + r * 26, 0, TAU); c.stroke(); } }
    c.restore();
  }
  const tSt = tMeet - 3.4;
  if (o.stickers && t > tSt) { const m = easeIO((t - tSt) / 3.4);
    if (t > tMeet - 0.2) { const ga = sstep(tMeet - 0.2, tMeet + 1.2, t), pul = 1 + 0.05 * Math.sin((t - tMeet) * 4);
      c.save(); c.globalCompositeOperation = "lighter"; drawHeart(c, 960, 560, 560 * pul, "rgba(255,120,150,0.35)", ga, 80); c.restore(); }
    const [lk, lh] = o.stickers.left, [rk, rh] = o.stickers.right;
    sticker(c, lk, lerp(260, 850, m), 860, lh, t, tSt, { bob: 6, ph: 0.5 });
    sticker(c, rk, lerp(1680, 1080, m), 860, rh, t, tSt, { bob: 6, ph: 2.0 });
    if (t > tMeet) for (let i = 0; i < 8; i++) { const d = t - tMeet - i * 0.6; if (d < 0 || d > 4) continue;
      drawHeart(c, 960 + Math.sin(i * 2.4) * 160 + Math.sin(d * 2) * 20, 520 - d * 110, 22 + (i % 3) * 8, "#ffb3c1", (1 - d / 4), 14); }
  }
  shade(c, "#ffd9a0", 0.35 * sstep(tWarm + 2.5, tWarm + 6.0, t), "screen");
});
lib.printPair = o => S((c, t, s) => {              // one print, then a second joins from the left on a cue (optional colour tint)
  const lt = t - s.cut, p = (t - s.a) / (s.b - s.a), tv = at(o.secondAt);
  drawCover(c, im(o.bg || o.second).blur, 0, 0, W, H, 1.2, 0.5, 0.5); shade(c, "#1a0b24", 0.3);
  const v = sstep(tv - 0.6, tv + 0.8, t);
  print(c, o.first, lerp(960, 1270, v) + (1 - easeOut((lt + 0.3) / 1.2)) * 500, 500, 800, lerp(0.03, 0.045, p), 1, 14, lerp(1, 1.03, p));
  if (v > 0) print(c, o.second, 650 - (1 - easeOut(v)) * 600, 515, 800, lerp(-0.05, -0.035, p), v, 14, lerp(1, 1.03, p));
  if (o.tint) shade(c, o.tint, 0.16 * v, "soft-light");
});
// Heart-shaped window. faces: [[u, v], [u, v]] = the two faces as fractions of the photo; the photo is scaled so
// the faces are as far apart as the heart's two lobes, then each face lands in one lobe.
lib.heartIris = o => S((c, t, s) => {
  const lt = t - s.cut, p = (t - s.a) / (s.b - s.a), x = im(o.key), [HX, HY] = o.center || [900, 545];
  drawCover(c, x.blur, 0, 0, W, H, 1.2, 0.5, 0.5); shade(c, "#2a0c16", 0.35);
  const open = easeOut((lt + 0.4) / 2.2), size = lerp(180, 1050, open) * (1 + 0.015 * beatPulse(t, 0.25));
  const [[u1, v1], [u2, v2]] = o.faces, mid = o.mid || [(u1 + u2) / 2, (v1 + v2) / 2];
  const pw = (o.photoWidth ?? 577 / Math.abs(u2 - u1)) * lerp(1.04, 1.0, p), ph = pw * x.h / x.w;
  c.save(); heartPath(c, HX, HY, size); c.clip(); c.drawImage(x.img, HX - mid[0] * pw, (o.faceY ?? 360) - mid[1] * ph, pw, ph); c.restore();
  c.save(); c.globalCompositeOperation = "lighter"; c.strokeStyle = "rgba(255,190,200,0.75)"; c.lineWidth = 4; c.shadowColor = "#ff8fa3"; c.shadowBlur = 30;
  heartPath(c, HX, HY, size); c.stroke(); c.restore();
});
lib.party = o => S((c, t, s) => {                  // pastel burst: one polaroid, characters popping in on half beats, confetti
  const lt = t - s.cut;
  const g = c.createLinearGradient(0, 0, W, H); g.addColorStop(0, "#ffcfae"); g.addColorStop(0.5, "#ffb8c6"); g.addColorStop(1, "#d6c0ff");
  c.fillStyle = g; c.fillRect(0, 0, W, H); drawBokeh(c, t, 0.8);
  if (o.polaroid) polaroid(c, o.polaroid, 960, 400, 360, -0.05 + 0.02 * Math.sin(lt * 2), easeOut((lt - 0.1) / 0.4), lerp(1.3, 1, easeOut((lt - 0.1) / 0.5)));
  const b0 = s.cut + 0.2;
  (o.stickers || []).forEach(([k, x, h, bob], i) => sticker(c, k, x, 950, h, t, b0 + BEAT * 0.5 * i, { ph: i, bob: bob ?? 10, bobSpeed: 5 }));
  confetti(c, t, s.cut + 0.15, 960, 700, 90, 3);
});
lib.candle = o => P(o.key, { z: o.z || [1.0, 1.32], f0: o.f0 || [0.46, 0.5], f1: o.f1 || [0.5, 0.6], after(c, t, s, p, xf) {   // flicker, streak and embers on a candle in the picture
  if (!xf) return;
  const [fx, fy] = xf.map(o.flame[0], o.flame[1]), z = xf.s;
  c.save(); c.globalCompositeOperation = "lighter";
  const fl = 0.8 + 0.12 * Math.sin(t * 11.3) + 0.08 * Math.sin(t * 6.1 + 2);
  c.globalAlpha = 0.55 * fl; c.drawImage(GLOW_SPR, fx - 230 * z, fy - 260 * z, 460 * z, 460 * z);
  const lf = c.createLinearGradient(fx - 700, 0, fx + 700, 0); lf.addColorStop(0, "rgba(255,170,90,0)"); lf.addColorStop(0.5, `rgba(255,210,150,${0.35 * fl})`); lf.addColorStop(1, "rgba(255,170,90,0)");
  c.globalAlpha = 1; c.fillStyle = lf; c.fillRect(fx - 700, fy - 6 * z, 1400, 12 * z);
  const R = rng(17); for (let i = 0; i < 26; i++) { const d = ((t * 0.5 + R()) % 1); const ex = fx + (R() - 0.5) * 120 * z + Math.sin(t * 2 + i) * 14, ey = fy - d * 520 * z;
    c.globalAlpha = (1 - d) * 0.8; c.drawImage(GLOW_SPR, ex - 9, ey - 9, 18, 18); }
  c.restore();
} });
lib.clocksMerge = o => S((c, t, s) => {            // two clocks in step glide together into one
  const lt = t - s.cut; drawSky(c, 0.08, t); drawStars(c, t, 1); if (o.skyline !== false) drawCities(c, 0.9, o.skylineOpts || {});
  const m = easeIO((lt - 2.2) / 3.2), mins = (o.startMinutes ?? 22 * 60) + lt * (o.speed ?? 6);
  drawClock(c, lerp(620, 960, m), 450, 180, mins, sstep(-0.5, 0.8, lt));
  drawClock(c, lerp(1300, 960, m), 450, 180, mins, sstep(-0.5, 0.8, lt) * (1 - 0.6 * m));
  if (m > 0.97) { const d = lt - 5.4; c.save(); c.globalCompositeOperation = "lighter"; c.globalAlpha = Math.max(0, 1 - d / 1.5); c.drawImage(GLOW_SPR, 960 - 420, 450 - 420, 840, 840); c.restore(); }
});
lib.nightToDawn = o => P(o.key, { z: o.z || [1.1, 1.0], f0: o.f0 || [0.5, 0.42], after(c, t, s) {   // the picture starts as night and clears
  const k = sstep(s.cut, s.cut + (o.over ?? 6.5), t);
  shade(c, "#060a2a", 0.72 * (1 - k), "multiply"); shade(c, "#7fa7ff", 0.12 * k, "soft-light");
  c.save(); c.beginPath(); c.rect(0, 0, W, H * 0.5); c.clip(); drawStars(c, t, 0.9 * (1 - k)); c.restore();
} });
lib.notesGlow = o => P(o.key, { z: o.z || [1.04, 1.12], f0: o.f0 || [0.5, 0.42], after(c, t, s) {   // notes fly up and the frame warms
  const tGlow = at(o.glowAt);
  musicNotes(c, t, s.cut, { n: 26, gap: 0.32, life: 6, seed: 5150, x0: 960 - 750, w: 1500, y0: 980, speed: 170, wob: 1.3, amp: 50, fadeFrom: 3.5, alpha: 1, color: "#fff0cf", glow: 18, glowColor: "rgba(255,200,120,1)", size: 52, glyphs: ["♪", "♫", "♬", "♩"] });
  drawDust(c, t, 0.4 + 0.8 * sstep(tGlow - 1, tGlow + 3, t));
  shade(c, "#ffcf8f", 0.16 * sstep(tGlow, tGlow + 4, t), "screen");
} });
lib.ember = () => S((c, t, s) => {                 // a single flame in the dark
  const lt = t - s.cut; c.fillStyle = "#06030a"; c.fillRect(0, 0, W, H); drawDust(c, t, 0.35);
  drawFlame(c, 960, 640, 40, t, sstep(0.6, 2.4, lt));
});
// The flame from `ember` rises and writes line1; the name pops in under it; characters wave.
lib.writeOnTitle = o => { const T1 = titleCanvas(o.line1, 1500, 520, 170, SCRIPT, ["#fff4cf", "#f3c66b", "#d99640"], "rgba(255,190,110,0.8)", 30, 300, 120, 460);
  const T2 = o.name ? titleCanvas(o.name, 900, 400, 230, SCRIPT, ["#ffffff", "#ffd8e0", "#ff9fb4"], "rgba(255,140,170,0.9)", 40, 270, 60, 330) : null;
  return S((c, t, s) => {
    const tw = at(o.at);
    drawCover(c, im(o.bg).blur, 0, 0, W, H, 1.15, 0.5, 0.55); shade(c, "#12060c", lerp(0.75, 0.45, sstep(tw, tw + 3, t)));
    drawDust(c, t, 0.6); drawFlame(c, 960, 640 - 260 * easeIO((t - tw + 0.4) / 1.4), 40, t, 1 - sstep(tw + 0.6, tw + 1.4, t));
    const wr = easeIO((t - tw) / 1.9);
    if (wr > 0) { c.save(); c.beginPath(); c.rect(210, 120, 1500 * wr, 520); c.clip(); c.drawImage(T1, 210, 120); c.restore();
      if (wr < 1) sparkle(c, 210 + 1500 * wr - 40, 360 + Math.sin(wr * 18) * 40, 34, 1); }
    const ta = t - (tw + 1.9);
    if (T2 && ta > 0) { const k = easeBack(ta / 0.7); c.save(); c.globalAlpha = clamp(ta / 0.3); c.translate(960, 640); c.scale(k, k); c.drawImage(T2, -450, -200); c.restore();
      const R = rng(272); for (let i = 0; i < 18; i++) { const ph = R() * TAU, sp = 0.8 + R() * 1.4; sparkle(c, 600 + R() * 720, 380 + R() * 420, 8 + R() * 16, 0.9 * Math.pow(Math.sin(t * sp * 3 + ph) * 0.5 + 0.5, 3) * clamp(ta / 0.6)); } }
    (o.stickers || []).forEach(([k, x, h, d], i) => sticker(c, k, x, 1000, h, t, tw + d, { ph: i }));
    confetti(c, t, tw + 1.95, 960, 640, 120, 9, 1.2);
  }); };
// Every photo flies in and becomes one tile of a heart; it pulses on the beat, then scatters.
lib.photoHeart = o => { const T = o.tile ?? 82, sc = o.scale ?? 410, R = rng(1101), tiles = [];
  for (let gy = -8; gy <= 8; gy++) for (let gx = -9; gx <= 9; gx++) {
    const x = gx * T / sc, y = -(gy * T) / sc + 0.08;
    if (Math.pow(x * x + y * y - 1, 3) - x * x * y * y * y <= 0) tiles.push({ x: 960 + gx * T, y: 540 + gy * T });
  }
  tiles.forEach((u, i) => { u.k = o.keys[i % o.keys.length]; u.d = R() * 4.6; u.fx = (R() - 0.5) * 3200 + 960; u.fy = (R() - 0.5) * 2400 + 540; u.r = (R() - 0.5) * 2.4; });
  return S((c, t, s) => {
    const lt = t - s.cut;
    const g = c.createRadialGradient(960, 540, 50, 960, 540, 1100); g.addColorStop(0, "#4a1d3a"); g.addColorStop(1, "#0b0410"); c.fillStyle = g; c.fillRect(0, 0, W, H);
    drawBokeh(c, t, 0.9);
    const pulse = 1 + 0.025 * beatPulse(t, 0.22) * sstep(4.8, 6, lt), zoom = lerp(1.08, 0.92, easeIO((lt - 4) / 9)) * pulse, spin = 0.03 * Math.sin(lt * 0.4);
    const explode = easeIO((lt - (o.scatterAt ?? 12.6)) / 2.2);
    c.save(); c.translate(960, 540); c.rotate(spin); c.scale(zoom, zoom); c.translate(-960, -540);
    c.save(); c.globalCompositeOperation = "lighter"; c.globalAlpha = 0.55 * sstep(4.5, 6.5, lt) * (1 - explode); c.drawImage(GLOW_SPR, 960 - 700, 540 - 700, 1400, 1400); c.restore();
    for (const u of tiles) {
      const e = easeOut((lt - u.d * 0.9) / 1.3); if (e <= 0) continue;
      const ox = (u.x - 960) * (1 + explode * 1.6), oy = (u.y - 540) * (1 + explode * 1.6);
      const x = lerp(u.fx, 960 + ox, e), y = lerp(u.fy, 540 + oy, e), r = u.r * (1 - e) + explode * u.r * 0.4, a = clamp((lt - u.d * 0.9) / 0.4) * (1 - explode);
      c.save(); c.globalAlpha = a; c.translate(x, y); c.rotate(r); c.fillStyle = "#fdf8f0"; c.shadowColor = "rgba(0,0,0,0.5)"; c.shadowBlur = 12;
      c.fillRect(-T / 2 + 2, -T / 2 + 2, T - 4, T - 4); c.shadowColor = "transparent";
      drawCover(c, im(u.k).img, -T / 2 + 6, -T / 2 + 6, T - 12, T - 12, 1, 0.5, 0.42); c.restore();
    }
    c.restore();
    const R2 = rng(280); for (let i = 0; i < 30; i++) { const ph = R2() * TAU; sparkle(c, 300 + R2() * 1320, 80 + R2() * 900, 6 + R2() * 14, 0.8 * Math.pow(Math.sin(t * 2.4 + ph) * 0.5 + 0.5, 4) * sstep(4, 6, lt)); }
    confetti(c, t, s.cut + 5.2, 960, 980, 140, 15, 1.4);
  }); };
lib.finale = o => P(o.key, { z: o.z || [1.0, 1.09], f0: o.f0 || [0.5, 0.45], f1: o.f1 || [0.5, 0.42], after(c, t) {   // last picture, title and signature
  const tt = at(o.at);
  shade(c, "#ffd29a", 0.12, "screen"); drawDust(c, t, 0.5);
  const g = c.createLinearGradient(0, 640, 0, H); g.addColorStop(0, "rgba(10,4,12,0)"); g.addColorStop(1, "rgba(10,4,12,0.75)");
  c.save(); c.globalAlpha = sstep(tt - 1.5, tt, t); c.fillStyle = g; c.fillRect(0, 640, W, H - 640); c.restore();
  const a = sstep(tt - 0.3, tt + 1.4, t);
  glowText(c, o.title, 960, 900, `118px ${SCRIPT}`, "#fff1d6", a, 30, "rgba(255,190,120,0.9)");
  if (o.signature) glowText(c, o.signature, 960, 975, `italic 34px ${SERIF}`, "rgba(255,240,222,0.9)", sstep(tt + 1.6, tt + 3.2, t), 10, "rgba(0,0,0,0.8)");
  if (a > 0) { const R = rng(3026); for (let i = 0; i < 12; i++) { const ph = R() * TAU; sparkle(c, 480 + R() * 960, 790 + R() * 150, 6 + R() * 12, a * Math.pow(Math.sin(t * 2 + ph) * 0.5 + 0.5, 4)); } }
} });

// ============================================================ the frame
let CFG = null, SCENES = [], LYR = [], DUR = 0, frameNo = 0;
function drawLyrics(c, t) {
  const y0 = CFG.lyrics?.y ?? 1022;
  for (const l of LYR) {
    const show = l.words[0].t - 0.35, hide = Math.min(l.next - 0.25, l.end + 1.0);
    if (t < show || t > hide + 0.5) continue;
    const out = sstep(hide, hide + 0.4, t), hook = CFG.lyrics?.hook && CFG.lyrics.hook.test(l.text), fs = hook ? 60 : 48;
    c.save(); c.font = `italic ${fs}px ${SERIF}`; c.textBaseline = "alphabetic";
    const sp = c.measureText(" ").width, ws = l.words.map(w => c.measureText(w.w).width);
    const total = ws.reduce((a, b) => a + b, 0) + sp * (ws.length - 1), scale = Math.min(1, 1700 / total);
    let x = 960 - total * scale / 2; const y = y0 - out * 16 - (hook ? 4 : 0);
    c.translate(x, y); c.scale(scale, scale); x = 0;
    l.words.forEach((w, i) => { const a = sstep(w.t - 0.18, w.t + 0.32, t) * (1 - out), dy = (1 - easeOut((t - w.t + 0.18) / 0.5)) * 12;
      if (a > 0) { c.globalAlpha = a; c.shadowColor = "rgba(0,0,0,0.85)"; c.shadowBlur = 14; c.fillStyle = hook ? "#ffe9c2" : "#fff6ea"; c.fillText(w.w, x, dy);
        if (hook) { c.shadowColor = "rgba(255,190,110,0.85)"; c.shadowBlur = 26; c.fillText(w.w, x, dy); } }
      x += ws[i] + sp; });
    c.restore();
  }
}
function lyricVisibleAt(t) { for (const l of LYR) if (t >= l.words[0].t - 0.35 && t <= Math.min(l.next - 0.25, l.end + 1.0) + 0.4) return 1; return 0; }
function renderAt(t) {
  const lk = CFG.looks || {};
  ctx.globalAlpha = 1; ctx.globalCompositeOperation = "source-over"; ctx.fillStyle = "#000"; ctx.fillRect(0, 0, W, H);
  for (const s of SCENES) {
    if (t < s.a || t >= s.b) continue;
    const al = s.fi > 0 ? sstep(s.a, s.a + s.fi, t) : 1; if (al <= 0) continue;
    if (al >= 0.999) { ctx.save(); s.draw(ctx, t, s); ctx.restore(); }
    else { lctx.save(); lctx.globalAlpha = 1; lctx.globalCompositeOperation = "source-over"; lctx.clearRect(0, 0, W, H); s.draw(lctx, t, s); lctx.restore();
      ctx.save(); ctx.globalAlpha = al; ctx.drawImage(layer, 0, 0); ctx.restore(); }
  }
  shade(ctx, lk.tint || "#ffb878", lk.tintAmount ?? 0.10, "soft-light");
  // each leak keeps its own seed for its whole life and is drawn on its own, so overlapping leaks add up instead of
  // one replacing the other (a seed taken from the clock, or from "the brighter one", would jump mid-glow)
  (lk.leaks || []).forEach(([t0, a], i) => { const v = a * bell(t, t0, 0.7, 1.6); if (v > 0.01) lightLeak(ctx, t, v, i * 3 + 1); });
  if (lk.bokeh) drawBokeh(ctx, t, track(lk.bokeh, t));
  sctx.drawImage(cv, 0, 0, 480, 270); tctx.drawImage(small, 0, 0, 160, 90);     // bloom: a blurred copy of the frame, screened back on
  ctx.save(); ctx.globalCompositeOperation = "screen"; ctx.globalAlpha = lk.bloom ? track(lk.bloom, t) : 0.2; ctx.drawImage(tiny, 0, 0, W, H); ctx.restore();
  ctx.save(); ctx.globalAlpha = lk.vignette ?? 0.85; ctx.drawImage(VIGNETTE, 0, 0); ctx.restore();
  ctx.save(); ctx.globalCompositeOperation = "overlay"; ctx.globalAlpha = lk.grain ?? 0.07; const gp = GRAIN_PAT[frameNo % GRAIN_PAT.length];
  ctx.translate((frameNo * 137) % 384, (frameNo * 251) % 384); ctx.fillStyle = gp; ctx.fillRect(-384, -384, W + 384, H + 384); ctx.restore();
  const lb = lk.letterbox ? track(lk.letterbox, t) : 0, bar = 136 * lb;
  if (bar > 0.5) { ctx.fillStyle = "#000"; ctx.fillRect(0, 0, W, bar); ctx.fillRect(0, H - bar, W, bar); }
  const g = ctx.createLinearGradient(0, 860, 0, H); g.addColorStop(0, "rgba(0,0,0,0)"); g.addColorStop(1, "rgba(0,0,0,0.6)");
  ctx.save(); ctx.globalAlpha = (1 - lb) * lyricVisibleAt(t); ctx.fillStyle = g; ctx.fillRect(0, 860, W, H - 860); ctx.restore();
  drawLyrics(ctx, t);
  let fl = 0; for (const [t0, a] of lk.flashes || []) fl = Math.max(fl, a * bell(t, t0, 0.08, 0.5));
  if (fl > 0) shade(ctx, "#fff1dc", fl, "lighter");
  const black = Math.max(1 - sstep(0, lk.fadeIn ?? 2.6, t), sstep(DUR - (lk.fadeOut ?? 5.4), DUR - 0.4, t));
  if (black > 0) shade(ctx, "#000", black);
  frameNo++;
}

// ============================================================ video sync
// Aim half a clip frame (clips are 30 fps) past the exact time: a seek that lands on a frame boundary shows the previous frame.
const HALF_FRAME = 0.5 / 30;
function activeVideos(t) {
  const want = new Map();
  for (const s of SCENES) if (t >= s.a && t < s.b) for (const v of s.videos || []) want.set(v.key, { vt: clamp(v.off + (t - s.cut) * v.rate + HALF_FRAME, 0, videoDur(v.key) - 0.04), rate: v.rate });
  return want;
}
function syncVideosPlaying(t) {
  const want = activeVideos(t);
  for (const [k, el] of Object.entries(VID)) {
    if (want.has(k)) { const { vt, rate } = want.get(k); el.playbackRate = rate;
      if (Math.abs(el.currentTime - vt) > 0.25) el.currentTime = vt; if (el.paused) el.play().catch(() => {}); }
    else if (!el.paused) el.pause();
  }
}
function seekVideos(t) {   // render mode: wait until every visible clip shows exactly the frame for t
  const waits = [];
  for (const [k, { vt }] of activeVideos(t)) { const el = VID[k]; if (!el.paused) el.pause();
    if (Math.abs(el.currentTime - vt) > 0.002 || el.readyState < 2) waits.push(new Promise((res, rej) => {
      const done = () => { clearTimeout(timer); el.removeEventListener("seeked", ok); el.removeEventListener("error", bad); };
      const ok = () => { done(); res(); }, bad = () => { done(); rej(new Error(`video ${k} failed while seeking`)); };
      const timer = setTimeout(() => { done(); rej(new Error(`video ${k} did not reach ${vt.toFixed(3)} s within 10 s`)); }, 10000);
      el.addEventListener("seeked", ok); el.addEventListener("error", bad); el.currentTime = vt; })); }
  return Promise.all(waits);
}

// ============================================================ start: player in a browser, renderer under ?render
// cfg: { duration, audio, title, subtitle, seq: [[cut, scene, crossfade]], looks: {letterbox, bokeh, bloom, leaks, flashes, ...},
//        lyrics: { hide: /regex of lines drawn by scenes instead/, hook: /regex of lines shown larger/ } }
function start(cfg) {
  CFG = cfg; DUR = cfg.duration; window.MV_DURATION = DUR;
  SCENES = cfg.seq.map((e, i) => { const next = cfg.seq[i + 1], fi = e[2], nfi = next ? next[2] : 0;
    return Object.assign(e[1], { cut: e[0], fi, a: e[0] - fi / 2, b: next ? next[0] + nfi / 2 : DUR, end: next ? next[0] : DUR }); });
  LYR = L.filter(l => !(cfg.lyrics?.hide && cfg.lyrics.hide.test(l.text)));
  const audio = document.getElementById("song"); audio.src = cfg.audio;
  const st = document.getElementById("start");
  if (st) { st.querySelector("h1").textContent = cfg.title || ""; st.querySelector("p").textContent = cfg.subtitle || ""; document.title = cfg.title || "MV"; }
  window.renderFrame = async (t, n) => { frameNo = n ?? Math.round(t * FPS); await seekVideos(t); renderAt(t); return true; };
  (async () => {
    const lo = document.getElementById("load");
    await loadAll((d, n) => { if (lo) lo.textContent = `loading ${d}/${n}`; });
    if (lo) lo.textContent = "ready";
    window.__ready = true;
    if (RENDER) return;
    const ui = document.getElementById("ui"), pp = document.getElementById("pp"), sk = document.getElementById("seek"), tm = document.getElementById("tm");
    sk.max = DUR; document.getElementById("dur").textContent = fmt(DUR);
    let idle = 0;
    const showUI = () => { ui.classList.remove("hide"); clearTimeout(idle); idle = setTimeout(() => { if (!audio.paused) ui.classList.add("hide"); }, 2200); };
    const still = async t => { await window.renderFrame(t); tm.textContent = fmt(t); sk.value = t; };
    // pausing redraws the frame exactly as the renderer would (videos seeked, grain from the frame number)
    const toggle = () => { st.style.display = "none"; if (audio.paused) audio.play(); else { audio.pause(); for (const v of Object.values(VID)) v.pause(); still(audio.currentTime); } showUI(); };
    st.addEventListener("click", toggle); cv.addEventListener("click", toggle); pp.addEventListener("click", toggle);
    document.getElementById("fs").addEventListener("click", () => document.documentElement.requestFullscreen());
    sk.addEventListener("input", () => { audio.currentTime = +sk.value; if (audio.paused) still(+sk.value); });
    addEventListener("mousemove", showUI);
    addEventListener("keydown", e => { if (e.code === "Space") { e.preventDefault(); toggle(); }
      if (e.code === "ArrowRight") audio.currentTime = Math.min(DUR, audio.currentTime + 5);
      if (e.code === "ArrowLeft") audio.currentTime = Math.max(0, audio.currentTime - 5);
      if (e.code === "KeyF") document.documentElement.requestFullscreen();
      if (audio.paused) still(audio.currentTime); showUI(); });
    audio.addEventListener("play", () => { pp.textContent = "❚❚"; }); audio.addEventListener("pause", () => { pp.textContent = "▶"; });
    const m = location.hash.match(/t=([\d.]+)/);
    if (m) { audio.currentTime = +m[1]; st.style.display = "none"; await still(+m[1]); showUI(); } else await still(0);
    const loop = () => { if (!audio.paused) { const t = audio.currentTime; syncVideosPlaying(t); renderAt(t); tm.textContent = fmt(t); sk.value = t; } requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
  })().catch(e => { const lo = document.getElementById("load"); if (lo) lo.textContent = "error: " + e.message; console.error(e); });
}
const fmt = x => `${Math.floor(x / 60)}:${String(Math.floor(x % 60)).padStart(2, "0")}`;

window.MV = { W, H, BEAT, line, at, P, PB, PR, V, S, lib, start,
  clamp, lerp, sstep, easeIO, easeOut, easeBack, rng, beatPulse, TAU, im, STK, VID, SERIF, DIDOT, SCRIPT, SANS,
  drawCover, drawCoverRot, shade, heartPath, drawHeart, sparkle, sticker, print, polaroid, glowText, floatingHearts,
  drawBokeh, drawStars, drawDust, lightLeak, drawSky, drawCities, drawClock, drawSun, drawFlame, confetti, musicNotes };
})();
