// Runs the tests of one c2al project against its JS build and prints one result line per test.
//   node tests/run_js.js <project dir>
// Output format (shared with the native build, see run_tests.py):
//   R <value>   result of the call: integer, JSON string for {"text"} results, decimal for {"big"} results
//   L <json>    the log printed by the call (only for tests with "expect_log")
//   - void call
"use strict";
const fs = require('fs');
const path = require('path');
const { load } = require('../runtime/rt_core.js');

const dir = process.argv[2];
const proj = JSON.parse(fs.readFileSync(path.join(dir, 'c2al.json')));
const { rt, c } = load(path.join(dir, 'build'), { collect: process.argv.includes('--collect') });
const alNames = JSON.parse(fs.readFileSync(path.join(dir, 'build', 'entry_names.json')));

function arg(a) {
  if (typeof a === 'number') return a | 0;
  if (a.text !== undefined) return rt.allocText(a.text);
  if (a.big !== undefined) return BigInt(a.big);
  throw new Error('bad argument ' + JSON.stringify(a));
}

for (const t of proj.tests) {
  const fn = c[alNames[t.call]];
  if (!fn) throw new Error('no public function ' + t.call + ' (is it in entry_points?)');
  const logStart = rt.getLog().length;
  let r;
  try {
    r = fn(...t.args.map(arg));
  } catch (e) {
    console.log('E ' + JSON.stringify(e.message));
    continue;
  }
  if (t.expect_log !== undefined) console.log('L ' + JSON.stringify(rt.getLog().slice(logStart)));
  else if (t.expect === undefined) console.log('-');
  else if (typeof t.expect === 'object' && t.expect.text !== undefined) console.log('R ' + JSON.stringify(rt.readText(r)));
  else console.log('R ' + String(r));
}
if (rt.sites.size) console.error('signed overflow sites (source line: count): ' + JSON.stringify([...rt.sites]));
