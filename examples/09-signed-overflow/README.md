# 09 signed overflow

Java's `String.hashCode` and the C standard's `rand()` LCG both rely on signed int overflow
wrapping. In AL, Integer overflow is a runtime error, so this project sets

```json
"wrap_all_signed": true
```

and every signed `+ - *` is computed in BigInteger and wrapped:

```c
h = 31 * h + *s;
```
```al
ti1 := ((((((BZ + 31) * h) + B31) mod B32) + B32) mod B32) - B31;
ti2 := ((((((BZ + ti1) + SX8[Mem.Get(s + 1) + 1]) + B31) mod B32) + B32) mod B32) - B31;
```

Without the setting, the AL code is `h := 31 * h + ...`. That is fast, but it fails in BC as soon as the hash
exceeds 2^31. `plain_sum` never overflows but is wrapped anyway, which is the cost of `wrap_all_signed`.
The alternative is `wrap_sites`: wrap only the operations the JS build sees overflowing. See
[docs/arithmetic.md](../../docs/arithmetic.md).

`lcg_next` gives 16838, 5758, 10113, ...: the sequence of the example `rand()` in the C standard.
