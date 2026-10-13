# 05 checksums

CRC-32, Adler-32 and FNV-1a on unsigned 32-bit values. AL has no unsigned type and no bit operators,
so this example exercises most of [docs/arithmetic.md](../../docs/arithmetic.md).

```c
c = crc_table[(c ^ *p) & 0xFF] ^ (c >> 8);
```
```al
// & 0xFF -> floor mod 256; index * 4 + table address
ti1 := ((((Rt_Xor(c, Mem.Get(p + 1)) mod 256) + 256) mod 256) * 4) + 4096;
// unsigned >> 8 via BigInteger
ti2 := (((BZ + c) + B32) mod B32) div 256;
// xor: lookup tables
c := Rt_Xor((Mem.Get(ti1 + 1) + 256 * (...)), ti2);
```

FNV-1a's multiply overflows 32 bits on purpose. That is fine for `unsigned` in C, and c2al wraps it:

```al
ti1 := ((((((BZ + h) * 16777619) + B31) mod B32) + B32) mod B32) - B31;
```

The tests use the standard check values (`crc32("123456789")` = `cbf43926`).
`crc32` itself returns the CRC as an AL Integer, so values ≥ 2^31 come back negative
(-873187034 = 0xcbf43926). These are the same bits as C's `uint32_t`.
