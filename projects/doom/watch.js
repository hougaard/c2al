"use strict";
const makeRuntime = require('./rt.js');
const rt = makeRuntime({ collect: true });
const N = parseInt(process.argv[2]), X = parseInt(process.argv[3]), Y = parseInt(process.argv[4]);
let watch = -1;
const st8o = rt.st8;
rt.st8 = function (a, v) { if (a === watch) console.log('write', v, new Error().stack.split('\n').slice(2, 6).map(s => s.trim().split(' ')[1]).join(' < ')); st8o(a, v); };
const doom = require('./build/doom.js')(rt);
doom.setSP(rt.layout.stack_top);
rt.setTime(1);
doom.bc_doom_init();
for (let f = 1; f <= N; f++) {
  rt.setTime(Math.floor(f * 1000 / 35) + 1);
  if (f === N) watch = doom.bc_get_screen() + Y * 320 + X;
  doom.doom_update();
}
console.log('final', rt.M[watch]);
