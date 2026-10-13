const makeRuntime = require('./rt.js');
const rt = makeRuntime({});
const doom = require('./build/doom.js')(rt);
doom.setSP(rt.layout.stack_top);
rt.setTime(1); doom.bc_doom_init();
const N = parseInt(process.argv[2]), K = parseInt(process.argv[3]);
for (let f = 1; f <= N; f++) { rt.setTime(Math.floor(f * 1000 / 35) + 1); doom.doom_update(); if (f == N - K) for (const k in rt.prof) rt.prof[k] = 0; }
const e = Object.entries(rt.prof).filter(x => x[1]).sort((a, b) => b[1] - a[1]);
let tot = 0; for (const [k, v] of e) tot += v;
console.log('calls per frame', (tot / K).toFixed(0));
for (const [k, v] of e.slice(0, 25)) console.log(k.padEnd(28), (v / K).toFixed(0));
