// Runs the JS translation of DOOM and compares against the C reference
"use strict";
const fs = require('fs');
const makeRuntime = require('./rt.js');
const rt = makeRuntime({ verbose: process.argv.includes('-v') });
const doom = require('./build/doom.js')(rt);
doom.setSP(rt.layout.stack_top);
const frames = parseInt(process.argv[2] || '1');
function fnv(a) { let h = 2166136261; for (let i = 0; i < 64000; i++) { h ^= rt.M[a + i]; h = Math.imul(h, 16777619) >>> 0; } return h.toString(16).padStart(8, '0'); }
let t0 = Date.now();
try { doom.bc_doom_init(); } catch (e) { console.log("ERRBUF:", JSON.stringify(rt.cstr(4096))); throw e; }
console.log('init ok', Date.now() - t0, 'ms');
for (let f = 0; f < frames; f++) {
  t0 = Date.now();
  doom.doom_force_update();
  const scr = doom.bc_get_screen();
  console.log('frame', f, 'hash', fnv(scr), (Date.now() - t0) + 'ms');
}
// compare with test framebuffer (RGBA)
const scr = doom.bc_get_screen(), pal = doom.bc_get_palette();
const ref = fs.readFileSync('../PureDOOM/test_framebuffer.raw');
let bad = 0;
for (let i = 0; i < 64000; i++) {
  const k = rt.M[scr + i] * 3;
  for (let c = 0; c < 3; c++) if (rt.M[pal + k + c] !== ref[i * 4 + c]) bad++;
}
console.log('mismatching channels vs test fb:', bad);
