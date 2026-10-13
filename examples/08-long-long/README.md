# 08 long long

`long long` is AL `BigInteger`:

```c
static int mulmod(int a, int b, int m) { return (int)((long long)a * b % m); }
```
```al
local procedure mulmod(a: Integer; b: Integer; m: Integer): Integer
...
    ti1 := (((((((BZ + a) * (BZ + b)) mod (BZ + m)) + B31) mod B32) + B32) mod B32) - B31;
```

`(int)` of a 64-bit value keeps the low 32 bits (the `wrap32` part).

From AL, `long long` parameters and results are BigInteger: `LongLong.factorial(20)` returns
2432902008176640000.

Not supported yet: `long long` in memory (struct fields, arrays), and 64-bit shifts and bit operations.
For those the build stops with `the runtime does not implement: Rt_Load64 ...`.
