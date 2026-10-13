# Testing

You cannot step through a 45,000-line generated codeunit to find a lowering bug. c2al is
tested by running the *same IR* outside BC and comparing it against the original C.

```
           ┌─► AL codeunit ─────────────► BC (examples/bc-app, the DOOM page)        slow, the real target
C ─► IR ───┤
           └─► JS module + rt_core.js ──► node: checked AL semantics                fast, every test run
C ─────────────► zig cc native build ────► the reference ("what C actually does")
```

## Why JS catches AL bugs

The JS back end prints exactly the same IR as the AL back end, and in checked mode it enforces
AL's rules:

- every Integer `+ - *` goes through `ck()` / `ckm()` and throws on overflow (AL: runtime error)
- `idiv`/`imod` throw on division by zero and truncate like AL `div`/`mod`
- `toI()` throws when a BigInteger does not fit an Integer
- `st8/st16/st32` throw when the value is out of range for the store or the address is below 4096

So a mistake in the lowering, such as a missing wrap, a wrong sign extension or an off-by-one address, shows up as a
wrong result or an exception with a JS stack trace, and the AL code has the same bug. What JS does
*not* test: the AL printer itself (syntax, which alc checks) and the AL runtime procedures, which
`rt_core.js` re-implements (see [runtime.md](runtime.md)).

## Running

```sh
python tests/run_tests.py                       # all examples
python tests/run_tests.py examples/07-sha256 -v # one example, show every result
python tests/run_tests.py --no-native           # skip the zig native build
```

For each project it:

1. builds it (`c2al.driver.build_project`): AL + `build/program.js`
2. runs `node tests/run_js.js <project>`, which calls each test against the JS build
3. generates `build/native_main.c` (calls the same tests on the original C), compiles it with
   `tests/native_shim.c` as a 32-bit program (`-fwrapv` so signed overflow wraps), and runs it
4. compares line by line: expected (from `c2al.json`) = JS = native

Writing a test: give the expected value from an independent source when there is one (a published
CRC or SHA value, the ANSI C `rand()` sequence). The native build catches a wrong expectation,
and the JS build catches a wrong translation.

## Checking the AL

```sh
python tests/gen_bc_app.py
alc /project:examples/bc-app /packagecachepath:<folder with Microsoft_System*.app> /out:examples.app
```

`gen_bc_app.py` writes `ExampleTests.Codeunit.al` from the same tests, so publishing the app and
pressing *Run all examples* on page **c2al Examples** runs every test in AL. Each example reports
its run time. That is the only check of `runtime/core.al` itself.

The alc that ships with the AL VS Code extension works for compiling
(`%USERPROFILE%\.vscode\extensions\ms-dynamics-smb.al-<version>\bin\alc.exe`). It needs only the System
symbols (any `Microsoft_System_*.app`), because the generated code uses no base application objects.

## How DOOM was validated (projects/doom)

DOOM has no unit tests, but it is deterministic: the same input at the same tics gives the same frames.
The DOOM harness used that:

| Tool | What it does |
|---|---|
| `ref_main3.c` + `ref_natives.c` | native C build of the *patched* DOOM, prints an FNV hash of the frame buffer every N frames |
| `run2.js` | the same loop on the JS build: `node run2.js <frames> <every> [dump frame]` prints the same hashes |
| `genscript.py` | a deterministic random input script: menu, IDDQD/IDKFA, warping through all levels, moving, shooting |
| `DOOM_SCRIPT=script.txt` | replays it in both, so the gameplay covers most of the code |
| `run2.js -c` | collect mode: report the overflowing signed operations (the wrap sites) instead of failing |
| `dbg.py` + `traces.json` | inject `bc_trace("tag", value)` calls at anchors in the C, build native + JS from that, and diff the traces to find the first divergence |
| `watch.js` | which code writes pixel (x, y) in frame N: a data watchpoint on `Mem` |
| `prof.js` | calls per frame per function (JS build with `--profile`): what to optimise |
| `topng.py` | turns dumped frames (`*.raw`) into PNGs to look at |

When the hashes match for thousands of scripted frames, the translation is right for all the code
those frames run. The remaining risk is code the script never reaches.

The native reference currently crashes after `ST_Init` (it was written before the sound and save game
patches, see [projects/doom/README.md](../projects/doom/README.md)). The JS harness runs.
