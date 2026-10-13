# 06 control flow

| Function | Shows |
|---|---|
| `vowel_count`, `roman_digit` | switches where every arm ends in `break`/`return` become an AL `case` |
| `fallthrough` | a fall-through switch, lowered to an arm index + `repeat ... until true` (the AL is shown in [docs/control-flow.md](../../docs/control-flow.md)) |
| `sum_skipping` | `continue` and `return` inside a fall-through switch inside a loop |
| `find_pair` | leaving nested loops with a flag and `break` |
| `short_circuit` | `&&`, `\|\|` and `?:` skip the right side's calls (906 = result 9 and 6 calls) |
| `digits_reversed` | `while (1)`, `\|\|` with `++` on the right, the comma operator |

`goto` is not supported. Rewrite it first: the patterns are in [docs/control-flow.md](../../docs/control-flow.md).
