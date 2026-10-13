"use strict";
const makeRuntime = require('./rt.js');
const rt = makeRuntime({ verbose: process.argv.includes('-v'), collect: process.argv.includes('-c'), dir: process.argv.includes('-d') ? 'dbuild' : 'build' });
const doom = require(process.argv.includes('-d') ? './dbuild/doom.js' : './build/doom.js')(rt);
doom.setSP(rt.layout.stack_top);
const frames = parseInt(process.argv[2] || '1'), every = parseInt(process.argv[3] || '1');
function fnv(a) { let h = 2166136261; for (let i = 0; i < 64000; i++) { h ^= rt.M[a + i]; h = Math.imul(h, 16777619) >>> 0; } return h.toString(16).padStart(8, '0'); }
rt.setTime(1);
let script = [], ei = 0;
if (process.env.DOOM_SCRIPT) script = require('fs').readFileSync(process.env.DOOM_SCRIPT, 'utf8').trim().split(/\r?\n/).map(l => l.split(' ').map(Number));
doom.bc_doom_init();
const t0 = Date.now();
for (let f = 1; f <= frames; f++) {
  rt.setTime(Math.floor(f * 1000 / 35) + 1);
  while (ei < script.length && script[ei][0] <= f) {
    const e = script[ei++];
    if (e[1] === 0) doom.doom_key_down(e[2]); else if (e[1] === 1) doom.doom_key_up(e[2]);
    else if (e[1] === 2) doom.doom_mouse_move(e[2], e[3] || 0); else if (e[1] === 3) doom.doom_button_down(e[2]); else doom.doom_button_up(e[2]);
  }
  doom.doom_update();
  if (f % every === 0) console.log('frame ' + f + ' hash ' + fnv(doom.bc_get_screen()));
  if (f === parseInt(process.argv[4] || '-1')) {
    const s = doom.bc_get_screen(), p = doom.bc_get_palette(), b = Buffer.alloc(64768);
    for (let i = 0; i < 64000; i++) b[i] = rt.M[s + i];
    for (let i = 0; i < 768; i++) b[64000 + i] = rt.M[p + i];
    require('fs').writeFileSync('js_frame.raw', b);
  }
}
console.error('ms per frame', (Date.now() - t0) / frames);
if (rt.sites.size) console.error('overflow sites', JSON.stringify([...rt.sites]));
