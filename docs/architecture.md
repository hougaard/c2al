# Architecture

c2al is a whole-program compiler. It reads one preprocessed C translation unit and writes one AL
codeunit containing every reachable function, plus a hand-written runtime.

```
c2al.json ──► driver.py
                │ 1. preprocess   zig cc -E -m32 -target x86-windows-gnu -nostdinc -I include   (unity.c → program.i)
                │ 2. parse        pycparser.CParser                                              (program.i → AST)
                │ 3. front.py     Program: typedefs, struct layouts, enums, globals, functions, constant folding
                │ 4. analysis.py  Analysis: reachability from entry points, address-taken, Mem residency, names
                │ 5. lower.py     Compiler.layout_globals: data segment image; FL(func).lower(): C → IR
                │ 6. emit_al.py   ALEmitter: IR + runtime template → codeunit text
                └ 7. emit_js.py   JSEmitter: IR → node module (same semantics, used by the tests)
```

## Modules

| File | Responsibility |
|---|---|
| `config.py` | `Config`: entry points, intrinsics, native prefixes, runtime text, wrap settings. Everything project specific |
| `driver.py` | Reads `c2al.json`, runs the pipeline, computes the memory layout, writes the outputs |
| `main.py` | `build(ifile, cfg)`: parse → analyse → lower, collects per-function errors |
| `ctypes_.py` | C type model (ILP32): `TInt TFloat TPtr TArr TStruct TFunc TVoid`, promotions, usual arithmetic conversions |
| `front.py` | `Program`: declarations → types, struct layout, enum values, `const_eval` (integer constant expressions with C semantics) |
| `analysis.py` | Reachability, address-taken scan (`RefScanner`), which globals live in `Mem`, function ids, AL-safe names |
| `ir.py` | The IR node classes and small algebra helpers (`add`, `mul`, `rng` value ranges) |
| `lower.py` | The core: C expressions/statements → IR with exact C integer semantics. ~1,700 lines |
| `emit_al.py` | Prints IR as AL; inlines `Mem` loads and stores; function pointer dispatch; RLE-encoded data segment |
| `emit_js.py` | Prints IR as JS with checked arithmetic (every AL trap is a JS exception) |

## Stage details

### 1. Preprocessing

c2al does not preprocess itself. clang (shipped as the `ziglang` pip package, so no install is
needed) runs with `-E` for a 32-bit x86 target, so `sizeof` and `#if` see the same ILP32 model
as c2al. `-nostdinc` keeps system headers out: they contain extensions pycparser cannot parse.
Programs include [`c2al.h`](../include/c2al.h) instead. All `sources` are `#include`d into one
`unity.c` file, so the whole program is a single translation unit.

### 2-3. Front end (`front.py`, `ctypes_.py`)

`Program.collect()` walks the top-level declarations:

- **typedefs** → `CType`; **structs/unions** get a real layout (offsets, padding, alignment, ILP32 rules)
- **enums** → integer constants in `prog.enums`
- **globals** → `GVar` (type, initializer, `static`, defined vs `extern`)
- **functions** → `Func` (type, body node); static locals become globals named `<func>_<name>`

`const_eval_t` folds integer constant expressions *with C semantics* (wrap to type width, C
division, sizeof). The lowering calls it first on every expression, so constant code never
reaches the IR.

### 4. Analysis (`analysis.py`)

- **Reachability**: a worklist from `cfg.entry_points` across calls, function addresses and global
  initializers. Only reachable code is translated, which is why a huge header like `c2al.h` or PureDOOM
  costs nothing for unused parts. An unreachable function may contain unsupported constructs.
- **Address-taken**: `RefScanner` records globals, locals and functions whose address is used
  (`&x`, arrays decaying, struct member access). This decides where a variable lives:
  - scalar, address never taken → a real AL variable (fast)
  - array, struct, or address taken → a slot in `Mem` (global: data segment, local: stack frame)
- **Function ids**: every reachable function whose address is taken gets a small integer id, which
  is the value of a function pointer (see [functions.md](functions.md)).
- **Natives and intrinsics**: a bodiless function whose name has a native prefix (`c2al_`, or `bc_` for DOOM)
  is implemented in the runtime. Names in `cfg.intrinsics` (`memset`, ...) map to runtime procedures.
- **Naming**: C names become AL names. They are renamed (`name_2`) when they collide with AL keywords
  (`al_keywords.txt`), the runtime's globals and procedures, or each other (AL is case insensitive).

### 5. Lowering (`lower.py`)

`Compiler` holds program-wide state: the data segment image (`image`, starting at address 4096),
string literal pool, AL globals, and the set of function-pointer signatures used.

`FL` lowers one function. Its main methods:

| Method | Produces |
|---|---|
| `rv(e)` | rvalue: `(IR expression, C type)`. May emit statements first (temps, calls) |
| `lv(e)` | lvalue: `LVar` (AL variable) or `LMem(addr, type)` |
| `load` / `store` | typed `Mem` access: `XLoad(kind, addr)` / `SStore(bits, addr, value)` |
| `conv(x, from, to)` | C conversions: narrowing, sign/zero extension, int ↔ BigInteger |
| `binop` | C arithmetic, with unsigned wrapping, division, bit operations and shifts |
| `cond(e)` | conditions as AL Boolean, with short circuit evaluation preserved |
| `st_*` | statements: `If`, `While`, `For`, `DoWhile`, `Switch`, `Return`, `Break`, `Continue`, ... |

C expressions can have side effects anywhere. AL expressions can contain calls, but AL has no
`++`, assignment expressions or comma operator. So `rv` may *emit statements* into `self.out`
(for example `SAssign(temp, ...)`) before returning the expression. `capture(fn)` collects those
statements separately. That is how `while (f(x++))` becomes `while true do begin <pre>; if not c then break; ... end`.

### The IR (`ir.py`)

Expressions carry a value kind: `I` Integer, `B` BigInteger, `D` Decimal, `L` Boolean.

| Node | Meaning |
|---|---|
| `XC(v, k)` | constant |
| `XV(name, k)` | AL variable |
| `XB(op, a, b, k)` | binary op in AL terms: `+ - * div mod`, compares `= <> < ...`, `and or xor` (Boolean) |
| `XU(op, a, k)` | `neg`, `not` |
| `XCall(name, args, k, pure)` | call (pure ones may be evaluated eagerly or duplicated) |
| `XLoad(kind, addr)` | `Mem` read: `u8 s8 u16 s16 i32` |
| `XTab(tab, idx)` | lookup in `SX8` (sign extend a byte) or `Pow2` |
| `XBig(a)` | Integer → BigInteger promotion (`BZ + a`) |

Statements: `SAssign SStore SCall SIf SWhile SRepeat SCase SBreak SContinue SExit SFrameRestore SComment`.
These map one to one onto AL statements. The IR is "structured AL": no gotos, no labels.

Helpers in `ir.py` do the small optimisations: `add`/`mul` fold constant offsets
(`p + 4 + 8` → `p + 12`), and `rng(x)` computes a value range. That range lets the lowering skip
wrapping and modulo operations when the result provably fits (a `u8` load + 1 never overflows).

### 6. AL back end (`emit_al.py`)

- the codeunit header: `Mem`, `SP`, BigInteger constants (`BZ`, `B31` = 2^31, `B32` = 2^32), `SX8`, `Pow2`, C globals that are AL variables
- the runtime template with `%MEMSIZE% %STACKTOP% %HEAPSTART% %DATASTART%` and `// %BIGCONSTS%` filled in
- one procedure per lowered function. Entry points are public, everything else is `local`
- `CallFn<n>` / `CallFnV<n>` dispatchers for function pointer calls
- `InitGlobals()` (initial values of AL-variable globals) and `InitData()`, which holds the data segment
  as a run-length-encoded hex string (`Z` + 4 hex digits = run of zero bytes), split into
  `DataPart<n>` procedures so no single procedure gets too large

Loads and stores are inlined as `Mem.Get`/`Mem.Set` expressions. AL lists are 1-based, so
C address `a` is `Mem.Get(a + 1)`, and the emitter folds the `+ 1` into constant offsets.

### 7. JS back end (`emit_js.py`)

It prints the same IR as a node module whose functions take a runtime object
([`runtime/rt_core.js`](../runtime/rt_core.js)). In checked mode, every Integer `+ - *` goes
through `ck()`/`ckm()`, which throw on overflow just as AL does. Every store goes through `st8/st16/st32`,
which reject out-of-range values and addresses. So a lowering bug that would crash in BC crashes in
node first, with a JS stack trace pointing at the C line. See [testing.md](testing.md).

## Outputs of a project build

```
<project>/build/unity.c          all sources #included
<project>/build/program.i        preprocessed C (what pycparser reads)
<project>/build/image.bin        initial data segment (address data_start..)
<project>/build/layout.json      data_start, data_end, stack_top, heap_start, memsize
<project>/build/program.js       JS translation
<project>/build/entry_names.json C entry point → AL procedure name
<out_al>                         the AL codeunit
```
