# Arithmetic: C integers on AL types

## Value kinds

| C type | AL type | IR kind |
|---|---|---|
| `char short int long`, pointers, `unsigned` variants, `_Bool` | `Integer` | `I` |
| `long long`, `unsigned long long` | `BigInteger` | `B` |
| `float double` (limited) | `Decimal` | `D` |
| conditions | `Boolean` | `L` |

Unsigned 32-bit values are stored in `Integer` with the same bit pattern as C:
`0xFFFFFFFFu` is `-1`. The lowering knows the C type, so it emits unsigned semantics where they
differ: division, modulo, comparison, right shift, and conversion to 64 bits.

## The central problem: AL traps on overflow

C (in practice) wraps on overflow. AL raises a runtime error. For every `+ - *` the lowering
decides between three forms:

1. **Plain AL**, when the result provably fits: constant folding, or `rng()` value ranges (a byte load
   is 0..255, `x mod 16` is -15..15, and so on). Also used for all signed arithmetic by default (see below).
2. **Wrapped through BigInteger**, for unsigned arithmetic that may overflow:
   ```al
   // FNV-1a, examples/05-checksums:  h *= 16777619u;
   ti1 := ((((((BZ + h) * 16777619) + B31) mod B32) + B32) mod B32) - B31;
   ```
   `BZ` is a BigInteger zero (it forces BigInteger evaluation), `B31` = 2^31 and `B32` = 2^32. `wrap32()` maps
   any 64-bit value back into the signed Integer range, using a double `mod` because AL `mod`
   truncates toward zero.
3. **Wrapped signed**, the same form, only for signed operations that are known to overflow
   (wrap sites) or for every signed operation (`wrap_all_signed`).

### Signed overflow: wrap sites

Signed overflow is undefined in C, but real code depends on it (hashes, PRNGs, DOOM's fixed point
math). Wrapping every signed operation is correct but slow, so c2al wraps only where needed:

- `"wrap_all_signed": true` in `c2al.json` wraps every signed `+ - *`. Simple and always right.
  [examples/09-signed-overflow](../examples/09-signed-overflow) uses it.
- `"wrap_sites": "wrap_sites.json"` lists `[function, line offset from the function's first line]`
  pairs. Only those operations are wrapped. Keying on the offset inside the function means unrelated edits
  elsewhere in the file don't invalidate the list. DOOM needs 9 sites.

**Finding wrap sites.** The JS build checks every signed operation. With `collect: true`
([rt_core.js](../runtime/rt_core.js)) it records the overflowing source lines instead of
throwing. For DOOM, `run2.js -c` replays a long scripted game and prints
`overflow sites [[line, count], ...]`. The lines were then turned into (function, offset) pairs by hand.
Automating that step is on the [roadmap](roadmap.md). A site that is never hit in testing is never
found, so the safe default for new code is `wrap_all_signed`.

## Conversions (`FL.conv`)

| From → To | Lowering |
|---|---|
| int → narrower (`char`, `short`) | `narrow()`: floor-mod into range, or nothing when `rng()` proves it fits |
| int → `_Bool` | `x <> 0` |
| signed int → `long long` | `BZ + x` |
| unsigned int → `long long` | `((BZ + x) + B32) mod B32` (zero extension) unless known non-negative |
| `long long` → int | `wrap32()` then assign to an Integer temp |
| int → `double` | `0.0 + x` (Decimal) |
| `double` → int | **not supported** |

## Division and modulo

C and AL both truncate toward zero, so signed `/ %` map directly to `div mod`.
Unsigned division of values that may be negative (≥ 2^31) calls `Rt_UDiv`/`Rt_UMod`, which work on
`UBig(a)` (the value as unsigned in BigInteger).

## Bit operations

AL has no bitwise operators on Integer. The lowering avoids the general case wherever it can:

| C | When | AL |
|---|---|---|
| `x & (2^k - 1)` | low mask, k ≤ 30 | `((x mod 2^k) + 2^k) mod 2^k` (floor mod, cheaper when x ≥ 0) |
| `x & mask` | contiguous mask of bits lo..hi ≤ 29 | floor mod, then `div`/`*` 2^lo |
| `x & ~mask` | clearing a contiguous run | `x - (x & mask)` |
| `x & 0xFFFF0000` style | high bits only | `x - floormod(x, 2^lo)` |
| `x \| 2^k` | single bit | add the bit if it is not set |
| `(x & mask) != 0` in a condition | `bit_test` | a range compare, no and at all |
| anything else | | `Rt_And / Rt_Or / Rt_Xor` |

`Rt_And/Or/Xor` (runtime) split both operands into 4 bytes and use 64K-entry lookup tables
(`AndTab`, `OrTab`, `XorTab`, built on first use, about 200K table entries per codeunit instance). That costs
4 table lookups plus BigInteger arithmetic, so it is the slowest common operation in translated code.
SHA-256 ([example 07](../examples/07-sha256)) is almost entirely this.

`~x` is `-1 - x`, which needs no table.

## Shifts

| C | AL |
|---|---|
| `x << k` constant, result provably fits | `x * 2^k` |
| `x << k` constant, may overflow | `wrap32((BZ + x) * 2^k)` |
| `x << n` variable | `wrap32((BZ + x) * Pow2[n + 1])` |
| signed `x >> k` constant, x ≥ 0 | `x div 2^k` |
| signed `x >> k` constant | `(x - floormod(x, 2^k)) div 2^k` (floor division = arithmetic shift) |
| unsigned `x >> k` constant | `(((BZ + x) + B32) mod B32) div 2^k` |
| variable right shift | `Rt_Shr(x, n)` / `Rt_UShr(x, n)` |

## Comparisons

Signed and equality comparisons map directly. An unsigned `<` on values that may be negative is
rewritten without BigInteger (`ult()` in lower.py):

```
a <u b   ≡   (a < b) xor ((a < 0) xor (b < 0))
```

with special cases for constant operands (`x <u 10` → `(x >= 0) and (x < 10)`).

## 64-bit (`long long`)

64-bit values are `BigInteger`: `+ - * / %` and comparisons work. Not implemented in the runtime
yet: 64-bit values in memory (`Rt_Load64`/`Rt_Store64`), 64-bit shifts and bit operations
(`Rt_Shl64`, `Rt_And64`, ...). The lowering already emits calls to these. The driver stops with
`the runtime does not implement: Rt_Load64 ...` instead of producing AL that does not compile.
64-bit wrapping is not emulated: a BigInteger overflow is an AL error. `unsigned long long` values
≥ 2^63 cannot be represented.

## Floating point

`float`/`double` map to AL `Decimal` (a decimal type, not IEEE binary floating point). Arithmetic,
constants and int → double conversions work in registers. Floats in memory, float globals,
and double → int conversion are not supported. DOOM needed none of it (it uses fixed point).
See [limitations.md](limitations.md).
