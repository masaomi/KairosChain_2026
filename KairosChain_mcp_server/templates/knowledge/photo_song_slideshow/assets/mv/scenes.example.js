// scenes.example.js — a scene list for mv_engine.js. Copy to the project as scenes.js and rewrite it for the song.
// Lyric prefixes below are placeholders: replace each with the first words of a line in your lyrics.
// Keys are names from assets/manifest.json (photos: file name without extension; bg1..bgN; name_01 stickers;
// video keys from mv_project.json) — the ones used here match assets/mv/mv_project.example.json.
// One entry = [cut time, scene, crossfade seconds centred on the cut]. Cut times are numbers in seconds; put a cut
// ~0.3 s before the line it serves. Inside scene options, a time may also be a lyric-line prefix (or [prefix, n]).
"use strict";
(() => {
const { P, PB, PR, V, S, lib, line, sticker, floatingHearts, glowText, SCRIPT, sstep } = MV;

const SEQ = [
  // intro (instrumental): blurred picture comes into focus under the title
  [0, lib.titleIntro({ bg: "bg1", title: "Song Title", subtitle: "a song for Someone", date: "1 · 1 · 2027" }), 0],
  // a line about living apart: two lives side by side (a video on one side is fine)
  [11.3, lib.splitScreen({ left: { img: "bg2", f: [0.36, 0.45] }, right: { video: "clip_evening", f: [0.6, 0.5], rate: 0.9 }, labels: ["your morning", "my evening"] }), 1.0],
  // a line about time zones: two clocks out of step, then a sun and a moon
  [18.2, lib.twinClocks({ left: { img: "photo_day", zoom: [1.3, 1.36], f: [0.5, 0.6] }, right: { img: "bg3", zoom: 1.15, f: [0.8, 0.42] }, offsetMinutes: -360 }), 1.0],
  // a generated picture with a character popping in on a line
  [25.1, P("bg4", { z: [1.0, 1.14], f0: [0.4, 0.42], f1: [0.36, 0.36], after(c, t) {
    sticker(c, "her_01", 1500, 400, 240, t, line("<first words of a lyric line>").start); } }), 1.0],
  // real photos: Ken Burns (zoom/pan), portrait prints, a video clip
  [40.1, PR("photo_portrait", { r0: -0.035, r1: -0.015, h: 880 }), 1.2],
  [43.3, P("photo_02", { f0: [0.42, 0.42], f1: [0.47, 0.4] }), 0.9],
  [74.0, V("clip_river", { rate: 0.92, z: [1.0, 1.08] }), 1.0],
  // instrumental: slowed clip with a place/date caption
  [84.6, V("clip_evening", { rate: 0.72, after(c, t, s) { glowText(c, "Place · Month Year", 960, 520, `80px ${SCRIPT}`, "#fff2dc",
    sstep(s.cut + 1.2, s.cut + 2.6, t) * (1 - sstep(s.cut + 8, s.cut + 9.6, t)), 26, "rgba(0,0,0,0.6)"); } }), 1.4],
  // a line about calls or messages: a phone receiving a voice message and photos
  [95.5, lib.phoneChat({ bg: "bg4", name: "Name", bubbles: [{ type: "voice", at: 0.45 }, { type: "typing", from: 2.6, to: 3.9, y: 246 },
    { type: "photo", key: "photo_dog", at: 3.9, y: 246, heartAt: 5.0 }] }), 1.2],
  // a line about small everyday moments: polaroids dropping on the beat, captioned with the capture date
  [102.4, lib.polaroidDrop({ bg: "photo_food", items: [["photo_food", 470, 370, -0.12, "12 May"], ["photo_cake", 930, 330, 0.07, "13 May"]] }), 1.0],
  // generated picture whose faces sit high: keep it inside the letterbox window
  [108.9, PB("bg5", { z: [1.0, 1.08], f0: [0.46, 0.40], f1: [0.46, 0.36] }), 1.4],
  [115.9, lib.cloudDrift({ key: "photo_wide_view" }), 1.4],
  // loud instrumental: three portrait clips side by side, kicking on the beat
  [168.24, lib.videoPanels({ keys: ["clip_a", "clip_b", "clip_c"] }), 0.3],
  // bridge: lights blur into one; notes rise; then a heart crosses the distance and two characters meet
  [180.0, lib.lightsBlur({ key: "bg3", blurAt: "<line where the lights blur>", notesAt: "<line about the song itself>" }), 1.8],
  [190.0, lib.distance({ arcAt: "<line about distance>", meetAt: "<line where they meet>", warmAt: "<line about warmth>",
    stickers: { left: ["her_03", 330], right: ["him_09", 340] } }), 1.4],
  // last chorus: two prints, a heart-shaped window over two faces, a party, a candle
  [209.2, lib.printPair({ first: "photo_portrait_2", second: "photo_portrait_3", secondAt: "<line for the second print>", tint: "#7a5cff" }), 0.5],
  [218.8, lib.heartIris({ key: "photo_two_faces", faces: [[0.19, 0.48], [0.59, 0.375]] }), 1.0],
  [225.9, lib.party({ polaroid: "photo_dog", stickers: [["pet_05", 300, 300], ["her_06", 610, 330, 12], ["him_05", 1310, 360, 12]] }), 0.6],
  [228.8, lib.candle({ key: "bg6", flame: [0.503, 0.603] }), 1.0],
  // outro and the birthday
  [242.3, lib.clocksMerge({}), 1.8],
  [248.6, lib.nightToDawn({ key: "photo_dusk" }), 1.8],
  [256.9, lib.notesGlow({ key: "photo_two_of_us", glowAt: "<line about the music fading>" }), 1.6],
  [266.6, lib.ember(), 2.0],
  [271.6, lib.writeOnTitle({ bg: "bg6", line1: "Happy Birthday", name: "Name", at: "Happy Birthday", stickers: [["her_02", 250, 340, 2.6], ["him_01", 1650, 380, 2.9]] }), 0.8],
  [279.8, lib.photoHeart({ keys: ["photo_01", "photo_02", "photo_03"] }), 0.9],
  [294.2, lib.finale({ key: "photo_two_of_us", title: "Happy Birthday, Name", signature: "with love, Me · date", at: ["Happy Birthday", 1] }), 2.0],
];

// duration = the song's length in seconds (the fade-out is placed from it; the MP4 ends where the song ends);
// audio = the song's path relative to mv.html. A video clip must last at least as long as its scene times its rate,
// or its last frame freezes: V("clip_river", {rate: 0.92}) from 74.0 to 84.6 (+ half the next crossfade) needs ~10.5 s.
MV.start({
  duration: 314.4, audio: "song.mp3", title: "Song Title", subtitle: "a song for Someone", seq: SEQ,
  lyrics: { hide: /^Happy Birthday/, hook: /^<chorus first words>/ },   // hide: lines a scene draws itself; hook: chorus line shown larger
  looks: {   // [time, value] keyframes, eased between
    letterbox: [[0, 1], [54.4, 1], [55.6, 0], [83.9, 0], [85.2, 1], [314.4, 1]],         // bars in verses, open in choruses
    bokeh: [[0, 0.9], [11, 0.45], [55, 0.28], [96, 0], [108.5, 0.7], [168, 0], [181, 0.75], [229, 0.95], [314.4, 0.5]],
    bloom: [[0, 0.22], [55, 0.17], [180, 0.28], [294, 0.3]],
    leaks: [[40.1, 1.0], [55.1, 0.9], [108.9, 0.9], [207.5, 1.3], [279.8, 1.0]],         // warm light sweeping at section changes
    flashes: [[168.24, 0.75], [209.2, 0.9]],                                               // a white bloom on a hard cut
  },
});
})();
