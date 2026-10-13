# c2al: C to AL translator

c2al translates C programs into **AL codeunits for Microsoft Dynamics 365 Business Central**.
It was built to run [PureDOOM](https://github.com/Daivuk/PureDOOM) inside BC ("Can BC run DOOM?").
This repository is the compiler pulled out of that project and turned into a stand-alone tool.

```
 C source ──► zig cc -E ──► pycparser AST ──► analysis ──► lowering ──► IR ─┬─► AL codeunit   (runs in BC)
 (+ c2al.h)   (preprocess)                    (reachability,  (C semantics    └─► JavaScript     (runs in node, for testing)
                                               memory layout)  on AL types)
```

The generated codeunit is ordinary AL. C memory is a `List of [Integer]` (one element per byte),
C pointers are indexes into it, and AL procedures stand in for C functions. AL has no
unsigned integers, bit operators, goto, pointers or fall-through `case`, so the lowering step
emulates all of these with integer arithmetic.

## Status

| | |
|---|---|
| **Proven on** | DOOM: 748 functions, 813 globals, 45,000 lines of generated AL, runs in BC |
| **Examples** | 9 example programs, 89 tests. JS output and the native C build agree on every test |
| **BC app** | `examples/bc-app` compiles with alc 18 (runtime 18.0). It has not been run in BC yet |
| **Maturity** | Research prototype. Every feature exists because DOOM needed it (see [docs/limitations.md](docs/limitations.md)) |

## Quick start

Requirements: Python 3.10+, Node.js (for tests), and `pip install -r requirements.txt`
(pycparser, and ziglang, which provides a portable clang for preprocessing and native reference builds).

```sh
# translate one example: writes examples/bc-app/src/generated/Basics.Codeunit.al
python -m c2al examples/01-basics/c2al.json

# run all example tests: translated JS vs native C vs expected values
python tests/run_tests.py

# regenerate the BC examples app (all example codeunits + test runner codeunit)
python tests/gen_bc_app.py
```

Then open `examples/bc-app` in VS Code, publish it, and open the page **c2al Examples** → *Run all examples*.

Calling translated C from AL:

```al
var
    Basics: Codeunit "C2AL Basics";
    Strings: Codeunit "C2AL Strings";
begin
    Basics.Initialize();                       // sets up C memory, once per codeunit instance
    Message('%1', Basics.fib(20));             // 6765
    Strings.Initialize();
    Message(Strings.ReadText(Strings.reverse(Strings.AllocText('Business Central'))));
end;
```

## Repository layout

| Path | What |
|---|---|
| [c2al/](c2al/) | The compiler (Python): front end, analysis, lowering, AL and JS back ends, project driver |
| [runtime/core.al](runtime/core.al) | The generic AL runtime pasted into every codeunit: memory, intrinsics, bit operations, natives |
| [runtime/rt_core.js](runtime/rt_core.js) | JS mirror of the runtime with AL semantics (overflow = error), for testing |
| [include/c2al.h](include/c2al.h) | The C library that translated programs include in place of libc |
| [examples/](examples/) | Example programs, from basics to SHA-256, each with a `c2al.json` and tests |
| [examples/bc-app/](examples/bc-app/) | A BC extension containing all examples plus a page that runs their tests in AL |
| [tests/](tests/) | Test runner (JS vs native vs expected) and the BC app generator |
| [projects/doom/](projects/doom/) | The original DOOM build: PureDOOM patches, BC glue, DOOM runtime, JS harness |
| [docs/](docs/) | How it works, and what to build next |

## Documentation

- [docs/architecture.md](docs/architecture.md): the pipeline, module by module, and the IR
- [docs/memory-model.md](docs/memory-model.md): `Mem`, addresses, data segment, stack frames, heap, globals vs locals
- [docs/arithmetic.md](docs/arithmetic.md): C integer semantics on AL Integer/BigInteger: unsigned, wrapping, bit ops, shifts
- [docs/control-flow.md](docs/control-flow.md): loops, conditions with side effects, switch lowering, removing goto
- [docs/functions.md](docs/functions.md): calling convention, struct parameters, function pointers, natives and intrinsics
- [docs/runtime.md](docs/runtime.md): the runtime template contract and how to write host-specific natives
- [docs/project-file.md](docs/project-file.md): `c2al.json` reference
- [docs/testing.md](docs/testing.md): the three-way test method, and how DOOM was validated
- [docs/limitations.md](docs/limitations.md): what is not supported (yet), and the errors you will see
- [docs/roadmap.md](docs/roadmap.md): the plan for turning this into a general tool
- [projects/doom/README.md](projects/doom/README.md): case study, how DOOM was made to run in BC

## License

Not chosen yet. The compiler and examples are by Erik Hougaard. `projects/doom` contains PureDOOM
(© id Software, GPL v2). `examples/07-sha256` is based on public domain code by Brad Conte.
