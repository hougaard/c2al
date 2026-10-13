# 07 SHA-256

A complete SHA-256 based on Brad Conte's public domain crypto-algorithms, checked against the
standard test vectors: `""`, `"abc"`, and the 448-bit message.

It is the stress test for bit operations. Every `ROTR`, `^`, `&` and `~` in the 64 rounds becomes AL
arithmetic or an `Rt_Xor`/`Rt_And` table lookup, so expect it to be slow in BC. The AL test runner
reports the time per example, which makes this a useful benchmark when optimising `BitOp`
(see [docs/roadmap.md](../../docs/roadmap.md)).

Notes for porting crypto or hash code:

- use `uint32_t` (unsigned). Unsigned arithmetic always wraps correctly in c2al, signed does not by default
- the message length is kept in 32 bits, because 64-bit shifts are not in the runtime yet
