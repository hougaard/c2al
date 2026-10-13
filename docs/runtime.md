# The runtime template

Every generated codeunit is `generated header + runtime template + translated procedures`.
The template is AL text pasted into the codeunit body, right after the generated global variables.

## Contract

A runtime template must:

1. **Start with variable declarations** (it is pasted into the codeunit's `var` section), then
   procedures. In `runtime/core.al` the split is marked by a line `// ---- procedures ----`, so
   `runtime_extra` files can add their own variables (see below).
2. **Define `InitRuntime()`**, which fills `Mem` (`%MEMSIZE%` bytes), the `SX8` and `Pow2` tables,
   `BZ B31 B32`, the `// %BIGCONSTS%` line, `SP := %STACKTOP%` and `Heap := %HEAPSTART%`.
3. **Call `InitRuntime(); InitData(); InitGlobals();`** before any C code runs (core: `Initialize()`).
4. **Define every procedure the translation calls**: the `Rt_*` intrinsics in use, `B2I`, `DecodeData`,
   and every native. The driver checks this (`check_runtime`) and names what is missing.

Placeholders that `emit_al.py` fills in:

| Placeholder | Value |
|---|---|
| `%MEMSIZE%` | initial `Mem` size (heap start rounded up to 4 KB) |
| `%STACKTOP%` | initial `SP` |
| `%HEAPSTART%` | first heap address |
| `%DATASTART%` | first data segment address (4096) |
| `        // %BIGCONSTS%` (8 spaces) | `Evaluate(BigK<n>, '...')` for 64-bit constants outside Integer range |

Generated names to avoid in a runtime: `Mem SP BZ B31 B32 SX8 Pow2 InitGlobals InitData DataPart<n> CallFn<n> CallFnV<n> BigK<n> fp_`.

## runtime/core.al

| Section | Procedures |
|---|---|
| Host API (public) | `Initialize`, `IsInitialized`, `GetLog`, `ClearLog`, `Alloc`, `AllocText`, `ReadText`, `PeekByte`, `PokeByte`, `PeekInt`, `PokeInt` |
| Runtime | `InitRuntime`, `DecodeData`, `HexVal`, `B2I`, `CStr` |
| Intrinsics | `Rt_MemSet`, `Rt_MemCpy` (overlap safe: also used for `memmove`), `Rt_StrLen` |
| Unsigned / bits | `UBig`, `Rt_UDiv`, `Rt_UMod`, `Rt_And`, `Rt_Or`, `Rt_Xor` (via `BitOp` + lookup tables), `Rt_Shr`, `Rt_UShr` |
| Natives | `c2al_malloc`, `c2al_free`, `c2al_print`, `c2al_print_int`, `c2al_abort` |

Strings cross the boundary as Latin-1 bytes: `AllocText` stores `char mod 256`, `CStr` turns
each byte back into a `Char`. Unicode text outside Latin-1 is not preserved.

## Adding natives for your project

Write the C declaration with the native prefix, and the AL procedure in an extra runtime file:

```c
/* myproject.c */
int c2al_customer_count(void);   /* native: implemented in AL */
```

```al
// natives.al  (listed in "runtime_extra")
        CustomerCache: Integer;
// ---- procedures ----
    local procedure c2al_customer_count(): Integer
    var
        Customer: Record Customer;
    begin
        exit(Customer.Count());
    end;
```

```json
"runtime_extra": ["natives.al"]
```

(Using `Record Customer` makes the app depend on the Base Application. The core runtime has no dependencies.)

Rules for natives:

- parameters and results are `Integer` (pointers too), `BigInteger` for `long long`. A pointer
  argument is a C address. Use `CStr(addr)` to read a string, `Mem.Get(addr + 1)` for bytes
- to return data to C, write into memory the C side allocated, or `c2al_malloc` a block and return its address
- keep them `local`. Public host API procedures (called from your pages) go in the same file

A project can also replace the whole runtime with `"runtime": ["my_runtime.al"]`. DOOM does this,
because its runtime predates core.al and adds frame encoding, WAD access, save games and sound
(see [projects/doom/runtime.al](../projects/doom/runtime.al)).

## The JS mirror

[`runtime/rt_core.js`](../runtime/rt_core.js) implements the same procedures for the JS build.
**It must follow AL semantics, not JS semantics**: overflow throws, stores check their value range,
`div` truncates. A JS version of a new native is needed before the tests can run a program that uses it.

The two runtimes are separate implementations. A bug in an AL-only runtime procedure (one the JS
mirror implements differently) is *not* caught by the JS tests, only by running in BC. The examples
BC app exists for that. Moving runtime procedures into C (translated by c2al, so both back ends share
them) or generating the JS runtime from the AL one would close this gap.
