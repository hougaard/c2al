# Memory model

## One list of bytes

All C memory is a single AL `List of [Integer]` called `Mem`, one element per byte (value 0..255).
A C pointer is an AL `Integer`: the 0-based byte address. Because AL lists are 1-based,
the byte at address `a` is `Mem.Get(a + 1)`.

```
address 0          4096 = data_start       data_end          stack_top  heap_start                Mem.Count
        │ unused    │ globals, arrays,      │ stack (grows ◄──) │          │ heap (bump allocator ──►)
        │ (NULL)    │ string literals       │ STACK bytes       │  16      │ grows Mem in 4 KB steps
```

- Addresses below 4096 are never used, so NULL (0) and small garbage pointers are invalid.
  The JS runtime throws on any store there.
- `memsize` (initial `Mem.Count`) is `heap_start` rounded up to 4 KB. `InitRuntime` fills `Mem`
  with zeros using `AddRange` of a 4096-element list, which is much faster than `Add` in a loop.
- Little endian, 2's complement. `int` and pointers are 4 bytes, `long long` 8 (ILP32, as on 32-bit x86).

Why a `List` and not an `array`? An AL array's size is fixed at compile time, while the list can
grow when the heap needs more memory. The original DOOM work also had probe codeunits that timed
`array[1000000] of Integer` against `List of [Integer]` reads and writes in BC. They are not
in this repo, and their numbers were not recorded. Measuring again is on the [roadmap](roadmap.md).

## Loads and stores

A typed load reads its bytes and combines them. Sign extension of the top byte uses the
`SX8` table (`SX8[b + 1]` = b as signed char):

| C | AL (inlined by `emit_al.py`) |
|---|---|
| `unsigned char` | `Mem.Get(a + 1)` |
| `signed char` | `SX8[Mem.Get(a + 1) + 1]` |
| `unsigned short` | `(Mem.Get(a + 1) + 256 * Mem.Get(a + 2))` |
| `int`, pointer | `(Mem.Get(a+1) + 256 * (Mem.Get(a+2) + 256 * (Mem.Get(a+3) + 256 * SX8[Mem.Get(a+4) + 1])))` |

The nesting keeps every intermediate value inside Integer range, so no BigInteger is needed for loads.

Stores split the value into bytes with `div`/`mod`. A 32-bit store of a value that may be negative
becomes a two-branch statement (from `examples/01-basics`, `history[count % 16] = v;`):

```al
ti1 := ((count mod 16) * 4) + 4096;
if v >= 0 then begin
    Mem.Set(ti1 + 1, v mod 256);
    Mem.Set(ti1 + 2, (v div 256) mod 256);
    Mem.Set(ti1 + 3, (v div 65536) mod 256);
    Mem.Set(ti1 + 4, v div 16777216);
end else begin
    Mem.Set(ti1 + 1, 255 - (-1 - v) mod 256);
    ...
```

When `rng()` proves the value is non-negative, only the first branch is emitted. Byte stores
reduce the value to 0..255 with a floor-mod unless the range is already known.

## Globals

| Global | Lives in | Why |
|---|---|---|
| scalar (`int`, pointer, `long long`), address never taken | an AL global variable | fastest; `count` in example 01 |
| array, struct, union | data segment in `Mem` | needs an address |
| scalar whose address is taken (`&x`) | data segment in `Mem` | needs an address |

The data segment is built at compile time (`Compiler.alloc`, `init_data`): initializers are
evaluated, including address constants (`&table[3]`, string literals, function ids), and written into
`image`. At runtime `InitData()` decodes it into `Mem`. String literals are pooled: identical
literals share one address.

## Locals and the C stack

| Local | Lives in |
|---|---|
| scalar, address never taken | an AL local variable |
| array, struct, or address taken | a slot in the function's **frame** in `Mem` |

`SP` is an AL global holding the C stack pointer, which starts at `stack_top` and grows down. A function
with a frame does:

```al
fp_ := SP - <framesize>;   // prologue
SP := fp_;
...                        // locals at fp_ + offset
SP := fp_ + <framesize>;   // before every exit (SFrameRestore)
exit(...);
```

Frame-less functions (the majority) emit no frame code at all.

Parameters arrive as AL `Integer`/`BigInteger` parameters. A parameter whose address is taken, or a
struct passed by value, is copied into the frame in the prologue (see [functions.md](functions.md)).

The stack size is `stack` in `c2al.json` (default 64 KB, DOOM uses 256 KB). Nothing checks for
stack overflow in AL yet: a too-deep recursion with big frames would write into the data segment.

## Heap

`c2al_malloc` (DOOM: `bc_malloc`) is a bump allocator: it returns `Heap`, advances it rounded up
to 16 bytes, and grows `Mem` with 4 KB zero blocks. `free` does nothing. That is fine for programs
that allocate at startup (DOOM has its own zone allocator on top of one big block) and wrong for
programs that churn memory. A real allocator (free lists, written in C and translated) is on the
[roadmap](roadmap.md).

## Codeunit instances

All state (`Mem`, `SP`, `Heap`, globals) is codeunit global state, so each instance of the codeunit
is an independent C "process". Keep the instance alive (a page global, a single instance codeunit)
to keep the C program's state between calls. DOOM's page holds one `Codeunit "DOOM Engine"`
variable for the whole session.
