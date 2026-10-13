# Roadmap: from DOOM translator to general tool

Ordered by value. Each item names where in the code it lands.

## Done (this repo, Oct 2026)

- [x] DOOM-specific settings moved into `Config` (`c2al/config.py`). DOOM builds through it with identical output, apart from one rename (`grid` → `g_grid`) caused by the added keywords
- [x] project file + driver + CLI (`c2al.json`, `c2al/driver.py`, `python -m c2al`)
- [x] generic runtime (`runtime/core.al`) + JS mirror (`runtime/rt_core.js`) + `include/c2al.h`
- [x] `wrap_all_signed` option
- [x] check that the runtime implements everything the translation calls
- [x] example programs with three-way tests (`tests/run_tests.py`) and a BC test app (`tests/gen_bc_app.py`)
- [x] fixed: `area` and other page keywords were not reserved (AL compile error in generated code)

## Next: correctness and coverage

1. **Run the examples app in BC** and record the results and timings. This is the first test of
   `runtime/core.al` (`AllocText`, `PokeInt`, overlap-safe `Rt_MemCpy`, `c2al_print_int`).
2. **goto elimination** (`lower.py`, new pass before lowering): forward gotos → flags or blocks,
   backward gotos → loops, irreducible flow → `while` + `case` state machine. This removes the need for patch.py-style edits.
3. **Automatic wrap sites**: make the JS build report `(function, line offset)` directly
   (`emit_js.py` passes `x.line`. Pass the function and offset as well), and add
   `run_tests.py --collect-wrap-sites` to write `wrap_sites.json`.
4. **64-bit memory and bit ops**: `Rt_Load64/Rt_Store64/Rt_Shl64/Rt_Shr64/Rt_UShr64/Rt_And64/Rt_Or64/Rt_Xor64`
   in `core.al` and `rt_core.js` (split into two 32-bit halves). 64-bit wrapping.
5. **Function pointer dispatch by full signature** (`emit_al.py emit_dispatch`, `lower.py call`):
   key on parameter and result kinds, not just argument count.
6. **Struct return** via a hidden destination pointer parameter.
7. **varargs**: callee gets a pointer to a Mem block with the promoted arguments. `va_start/va_arg` as intrinsics.
   Then a small `printf` in C for `c2al.h`.
8. **Floats in memory**: store `double` as IEEE bytes (encode/decode in the runtime, slow), or keep a
   side table of Decimal slots for float-typed memory. Conversion double → int.
9. **A real malloc/free** written in C in `c2al.h` (translated, so tested by both back ends).
10. **Stack overflow check** in the frame prologue (cheap: one compare).

## Usability

- `c2al.json` `"wrappers": true`: generate AL-friendly public procedures: auto `Initialize()`,
  `Text` parameters/results instead of addresses
- better error messages with C source locations for unsupported constructs (`front.err` already has coords. Collect them all, don't stop at the first)
- `python -m c2al new <dir>`: scaffold a project
- unit tests for the lowering itself (`tests/unit/`: small C snippets → expected IR/AL)
- a pip-installable package (`pyproject.toml`, entry point `c2al`)
- share one runtime between several translated codeunits (today each codeunit has its own copy and its own `Mem`)

## Performance

- measure in BC: List vs array for `Mem`, the cost of a procedure call, and `Mem.Get` vs a local
- inline small leaf functions in `lower.py` (C code is call heavy)
- keep more locals out of Mem: today any `&x` forces a frame slot for the whole function
- cheaper 32-bit stores (fewer branches when the sign is known from the type, e.g. unsigned char sources)
- byte copies through `char`: `*a = *b` emits `SX8[...]` + floor mod 256. Storing an `s8` load into a byte
  should use the raw `u8` load (`lower.py store()` only recognises the `XTab` form today, see example 02)
- double normalisation: narrowing to `signed char` and then storing reduces mod 256 twice (`((((t mod 256) + 384) mod 256) - 128) ...`)
- `Rt_And/Or/Xor`: try 16-bit tables, or bit tests for single-bit masks of variables

## Ideas

- other targets for the IR: the JS back end shows the IR is printable to any structured language
- run real C libraries in BC: zlib/miniz (deflate), a QR code generator, a barcode library,
  a PDF writer, a Lua interpreter (Lua in BC!), a regex engine
