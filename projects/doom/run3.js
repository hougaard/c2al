// frame-at-a-time host loop like the BC page: 86ms per frame
const makeRuntime = require('./rt.js');
const rt = makeRuntime({});
const doom = require('./build/doom.js')(rt);
doom.setSP(rt.layout.stack_top);
rt.setTime(1); doom.bc_doom_init();
let t = 1; const t0 = Date.now();
for (let f = 1; f <= 2000; f++) { t += 86; rt.setTime(t); doom.bc_doom_frame(); }
console.log('2000 frames ok', (Date.now() - t0) / 2000, 'ms/frame, log tail:', rt.log.slice(-2).join('').trim());
