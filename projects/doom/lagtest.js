// how many tics does DOOM itself lag behind input in the BC frame loop?
const makeRuntime = require('./rt.js');
const rt = makeRuntime({});
const doom = require('./build/doom.js')(rt);
doom.setSP(rt.layout.stack_top);
rt.setTime(1); doom.bc_doom_init();
let t = 1; const step = parseInt(process.argv[2] || '86'); const lags = {};
for (let f = 1; f <= 1500; f++) { t += step; rt.setTime(t); doom.bc_doom_frame(); const l = doom.bc_tic_lag(); lags[l] = (lags[l] || 0) + 1; }
console.log('frame step', step, 'ms: tic lag histogram', JSON.stringify(lags));
