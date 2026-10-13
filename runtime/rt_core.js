// JS mirror of runtime/core.al. The JS back end (c2al/emit_js.py) prints the same IR as the AL back end,
// so running it under node tests the C -> IR lowering without Business Central.
// Every AL trap (Integer overflow, bad store value, division by zero) is a thrown Error here.
"use strict";
const fs = require('fs');
const path = require('path');

// opts.dir: build directory with layout.json, image.bin and program.js
// opts.collect: record signed overflows by source line instead of throwing (used to find wrap sites)
function makeRuntime(opts) {
  const layout = JSON.parse(fs.readFileSync(path.join(opts.dir, 'layout.json')));
  const image = fs.readFileSync(path.join(opts.dir, 'image.bin'));
  const M = [];  // grows like the AL Mem list
  const grow = (n) => { while (M.length < n) M.push(0); };
  grow(layout.memsize);
  for (let i = 0; i < image.length; i++) M[layout.data_start + i] = image[i];
  const SX8 = new Int32Array(257);
  for (let i = 0; i < 256; i++) SX8[i + 1] = i < 128 ? i : i - 256;
  const Pow2 = new Int32Array(33);
  for (let i = 0; i < 32; i++) Pow2[i + 1] = (2 ** i) | 0;
  let heap = layout.heap_start;
  let log = '';

  const sites = new Map();
  function ovf(line, v) {
    if (!opts.collect) throw new Error('Integer overflow ' + v + ' at line ' + line);
    sites.set(line, (sites.get(line) || 0) + 1);
  }
  function ck(v, line) {
    if (v > 2147483647 || v < -2147483648) { ovf(line, v); return v | 0; }
    return v;
  }
  function ckm(a, b, line) {
    const v = a * b;
    if (v > 2147483647 || v < -2147483648) { ovf(line, v); return Math.imul(a, b); }
    return v;
  }
  function ck64(v) {
    if (v > 9223372036854775807n || v < -9223372036854775808n) throw new Error('BigInteger overflow');
    return v;
  }
  function idiv(a, b) { if (b === 0) throw new Error('div by zero'); return ck(Math.trunc(a / b)); }
  function imod(a, b) { if (b === 0) throw new Error('mod by zero'); return (a % b) | 0; }
  function bdiv(a, b) { if (b === 0n) throw new Error('div by zero'); return a / b; }
  function bmod(a, b) { if (b === 0n) throw new Error('mod by zero'); return a % b; }
  function toI(b) { if (b > 2147483647n || b < -2147483648n) throw new Error('BigInteger->Integer overflow ' + b); return Number(b); }
  function addr(a) { if (a < 4096 || a >= M.length) throw new Error('bad address ' + a); }
  function st8(a, v) {
    if (!(v >= 0 && v <= 255)) throw new Error('st8 bad value ' + v + ' at ' + a);
    addr(a);
    M[a] = v;
  }
  function st16(a, v) {
    if (!(v >= 0 && v <= 65535)) throw new Error('st16 bad value ' + v);
    addr(a);
    M[a] = v % 256; M[a + 1] = (v / 256) | 0;
  }
  function st32(a, x) {
    addr(a);
    // same formula as the AL inline expansion
    if (x >= 0) {
      M[a] = x % 256; M[a + 1] = Math.trunc(x / 256) % 256; M[a + 2] = Math.trunc(x / 65536) % 256; M[a + 3] = Math.trunc(x / 16777216);
    } else {
      const y = -1 - x;
      M[a] = 255 - y % 256; M[a + 1] = 255 - Math.trunc(y / 256) % 256; M[a + 2] = 255 - Math.trunc(y / 65536) % 256; M[a + 3] = 255 - Math.trunc(y / 16777216);
    }
  }
  function ld32(a) { return M[a] + 256 * (M[a + 1] + 256 * (M[a + 2] + 256 * SX8[M[a + 3] + 1])); }
  function cstr(a) { let s = ''; while (M[a]) s += String.fromCharCode(M[a++]); return s; }
  function malloc(size) {
    const a = heap;
    heap = Math.floor((heap + size + 15) / 16) * 16;
    if (heap >= M.length) grow(Math.ceil((heap + 1) / 4096) * 4096);
    return a;
  }

  const rt = {
    prof: {},
    M, SX8, Pow2, ck, ckm, sites, ck64, idiv, imod, bdiv, bmod, toI, st8, st16, st32, layout,
    // host API (same names as the public procedures in core.al)
    getLog() { return log; },
    alloc: malloc,
    allocText(s) { const a = malloc(s.length + 1); for (let i = 0; i < s.length; i++) M[a + i] = s.charCodeAt(i) & 255; return a; },
    readText: cstr,
    peekByte(a) { return M[a]; },
    peekInt: ld32,
    pokeInt: st32,
    // natives
    c2al_malloc: malloc,
    c2al_free(p) { },
    c2al_print(s) { log += cstr(s); },
    c2al_print_int(v) { log += String(v); },
    c2al_abort(s) { throw new Error(cstr(s)); },
    // intrinsics
    Rt_MemSet(d, v, n) { v = ((v % 256) + 256) % 256; for (let i = 0; i < n; i++) M[d + i] = v; return d; },
    Rt_MemCpy(d, s, n) {
      if (d <= s) { for (let i = 0; i < n; i++) M[d + i] = M[s + i]; }
      else { for (let i = n - 1; i >= 0; i--) M[d + i] = M[s + i]; }
      return d;
    },
    Rt_StrLen(s) { let n = 0; while (M[s + n]) n++; return n; },
    Rt_UDiv(a, b) { if (b === 0) throw new Error('div by zero'); return ((a >>> 0) / (b >>> 0)) | 0; },
    Rt_UMod(a, b) { if (b === 0) throw new Error('mod by zero'); return ((a >>> 0) % (b >>> 0)) | 0; },
    Rt_And(a, b) { return a & b; },
    Rt_Or(a, b) { return a | b; },
    Rt_Xor(a, b) { return a ^ b; },
    Rt_Shr(a, n) { return n <= 0 ? a : n >= 31 ? (a < 0 ? -1 : 0) : a >> n; },
    Rt_UShr(a, n) { return n <= 0 ? a : n >= 32 ? 0 : (a >>> n) | 0; },
  };
  return rt;
}

// loads a c2al build: returns { rt, c } where c holds the public C functions
function load(dir, opts) {
  const rt = makeRuntime(Object.assign({ dir }, opts || {}));
  const c = require(path.resolve(dir, 'program.js'))(rt);
  c.setSP(rt.layout.stack_top);
  return { rt, c };
}

module.exports = { makeRuntime, load };
