"use strict";
const makeRuntime = require('./rt.js');
const rt = makeRuntime({});
const doom = require('./build/doom.js')(rt);
doom.setSP(rt.layout.stack_top);
doom.bc_doom_init();
let t = 0, n = 0;
const kinds = [0, 0, 0];
for (let f = 0; f < 35 * 60; f++) {
  t += 29; rt.setTime(t);
  doom.bc_doom_frame();
  for (const e of rt.takeSounds()) { kinds[e[0]]++; if (n++ < 25) console.log('tic', f, JSON.stringify(e)); }
}
console.log('starts/updates/stops', kinds);
