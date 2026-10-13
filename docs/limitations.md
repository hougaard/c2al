# Limitations

c2al supports what PureDOOM needed, plus the small generic layer added for the examples.
Each unsupported construct is reported with a message, but only when it is in **reachable** code.

## Not supported (with the error you get)

| Construct | Error | Workaround / plan |
|---|---|---|
| `goto` | `goto not supported` | rewrite by hand ([control-flow.md](control-flow.md)); automatic elimination is planned |
| variadic function definitions | `varargs not supported` | fixed argument versions; planned `va_list` in Mem |
| struct return values | `struct return not supported` | pass an output pointer; planned hidden-pointer return |
| bitfields | `bitfields not supported` | masks and shifts by hand |
| `float`/`double` in memory, float globals | `float load not supported`, `float data not supported`, `unsupported global type` | fixed point; planned IEEE encode/decode (slow) or Decimal slots |
| `double` → int conversion | `float to int conversion not supported` | |
| 64-bit values in memory, 64-bit shifts and bit ops | `the runtime does not implement: Rt_Load64 ...` | keep `long long` in locals; planned runtime procedures |
| `unsigned long long` ≥ 2^63 | wrong results | |
| 64-bit overflow wrapping | AL BigInteger overflow error | |
| non-constant global initializers | `non-constant initializer` | initialise in an init function |
| aggregate initializers that copy structs in globals | `unsupported aggregate initializer` | |
| unsized arrays without initializer | `unsized array` | give a size |
| VLAs, `alloca`, `setjmp/longjmp`, threads, signals | various | none in AL |
| system headers (`<stdio.h>` ...) | preprocessor: file not found (`-nostdinc`) | use `c2al.h`, add natives |
| K&R style functions, compound literals, `_Generic` | depends on pycparser | |

## Semantics to be aware of

- **Signed overflow** is an AL error unless wrapped ([arithmetic.md](arithmetic.md)). This is the
  most likely way for new code to fail in BC. Use `wrap_all_signed` until you have wrap sites.
- **One unit**: all sources are a single translation unit. Two `static` functions with the same name in
  different files collide.
- **Function pointers** are dispatched by argument count only. Pointers to functions returning
  `long long`/`double` or taking `long long` parameters are not handled correctly yet.
- **No stack overflow check**: deep recursion that exceeds `stack` silently overwrites the data segment.
  AL's own call depth limit has not been measured.
- **Memory is never freed** (bump allocator).
- **Strings** cross into AL as Latin-1 bytes.
- **Uninitialised locals are 0** (AL initialises variables), and in Mem they are whatever the frame held before.
  Code that relies on garbage values behaves differently from native code.
- **Pointer comparisons between unrelated objects** behave like integer compares (fine in practice).
- **Unaligned access** works (Mem is byte addressed), which can hide bugs a native build would show.

## Performance

Translated code is much slower than native, and slower than hand-written AL:

- every memory access is one `Mem.Get`/`Mem.Set` per byte. A 32-bit store is 4 `Mem.Set` calls and arithmetic
- `& | ^` with non-constant masks cost a BigInteger split and 4 table lookups
- unsigned arithmetic that may overflow goes through BigInteger
- AL procedure calls are relatively expensive, and C code is call heavy

What helps: keep hot variables scalar (no `&x`), so they become AL variables. Use constant masks
and shifts. Prefer signed arithmetic that cannot overflow. Map hot library functions to intrinsics.
Measure with the JS profiler first (`--profile`, see `projects/doom/prof.js`). Hot paths often have
a few dominant functions, and an intrinsic or a C rewrite of those pays most.
