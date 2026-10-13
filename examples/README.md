# Examples

Each folder is a small C program plus a `c2al.json` project file with tests. The generated AL for
all of them is committed in [bc-app/src/generated](bc-app/src/generated), so you can compare C and AL side by side.

| # | Example | Shows | AL object |
|---|---|---|---|
| 01 | [basics](01-basics) | functions, recursion, loops, globals in AL vars vs Mem, truncating division, narrowing | codeunit 50101 "C2AL Basics" |
| 02 | [strings](02-strings) | `char*`, string literals, static buffers, local arrays on the C stack, `AllocText`/`ReadText` | 50102 "C2AL Strings" |
| 03 | [structs-malloc](03-structs-malloc) | a binary search tree with malloc, nested structs, struct copies and by-value parameters, unions | 50103 "C2AL Structs" |
| 04 | [function-pointers](04-function-pointers) | operator tables, fold with a callback, a qsort-style generic sort | 50104 "C2AL Function Pointers" |
| 05 | [checksums](05-checksums) | CRC-32, Adler-32, FNV-1a: unsigned wrapping, xor, shifts, masks | 50105 "C2AL Checksums" |
| 06 | [control-flow](06-control-flow) | switch → AL case, fall-through switch, continue in switch, short circuit, comma operator | 50106 "C2AL Control Flow" |
| 07 | [sha256](07-sha256) | a real algorithm: SHA-256, all 32-bit bit manipulation | 50107 "C2AL SHA256" |
| 08 | [long-long](08-long-long) | `long long` as BigInteger: factorial, modular exponentiation, Miller-Rabin | 50108 "C2AL Long Long" |
| 09 | [signed-overflow](09-signed-overflow) | the one thing that does not translate for free, and `wrap_all_signed` | 50109 "C2AL Signed Overflow" |
| | [bc-app](bc-app) | a BC extension with all of the above, plus page 50100 "C2AL Examples" that runs every test in AL | |

## Run

```sh
python tests/run_tests.py                 # build all, test JS vs native C vs expected
python tests/run_tests.py examples/05-checksums -v
python -m c2al examples/05-checksums/c2al.json    # just translate
python tests/gen_bc_app.py                # rebuild bc-app (generated codeunits + test runner)
```

## In Business Central

Open `examples/bc-app` in VS Code (AL extension), set up `launch.json` for your sandbox, publish,
and search for **c2al Examples**. *Run all examples* runs the same tests as `run_tests.py`, in AL,
and shows ok/FAIL per call and the time per example.

## Write your own

```sh
mkdir examples/10-mine
```

`examples/10-mine/mine.c`:
```c
#include "c2al.h"
int triple(int x) { return 3 * x; }
```

`examples/10-mine/c2al.json`:
```json
{
  "name": "my example",
  "sources": ["mine.c"],
  "entry_points": ["triple"],
  "object_id": 50110,
  "object_name": "C2AL Mine",
  "out_al": "../bc-app/src/generated/Mine.Codeunit.al",
  "tests": [ {"call": "triple", "args": [14], "expect": 42} ]
}
```

`python tests/run_tests.py examples/10-mine` then checks it. `gen_bc_app.py` picks it up automatically.
See [docs/project-file.md](../docs/project-file.md) for all options.
