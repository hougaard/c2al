# Control flow

AL has `if`, `while`, `repeat..until`, `for`, `case`, `break`, `continue` and `exit`
(the generated code uses `continue`, so it needs a runtime version that has it. The examples use runtime 18.0). It has no `goto`, no fall-through `case`, and no expressions
with side effects. Everything below comes from `lower.py` (`st_*` methods).

## Conditions with side effects

A C condition may contain calls, `++` or assignments: `while ((c = *p++) != 0)`. `cond(e)` returns an
AL Boolean expression and may emit statements first. When it does, the loop is rewritten so the
statements run before every test:

```
while (cond) body          →  while <cond> do begin body end;                       (no statements needed)
                           →  while true do begin <pre>; if not <cond> then break; body end;
for (init; cond; step)     →  init; while ... do begin ... body; step end;
do body while (cond)       →  repeat body until not <cond>;                         (or while true + tail)
```

`continue` in a `for` loop must still run `step`. `LoopCtx.cont` holds the step statements, and
`continue` emits a copy of them before the AL `continue`.

## Short circuit `&&` / `||`

AL `and`/`or` evaluate both sides, so they are only used when the right side is `eager_safe`: no
calls (or only pure ones), no division by a non-constant, no memory loads that could fault.
Otherwise:

```al
t := <left>;
if t then begin
    <statements of right>;
    t := <right>;
end;
```

`examples/06-control-flow`, `short_circuit()`, checks that the right side's calls do not happen.

The ternary `?:` becomes an `if` that assigns a temp, so only the chosen side is evaluated.

## switch

`st_Switch` groups the body into arms (labels + statements). It then picks one of two strategies.

### 1. AL `case` (`switch_case`)

It is used when every arm ends in `break`, `return` or `continue`, and no `break` is nested deeper inside an arm.
Grouped labels become `1, 2, 3:` and `default` becomes `else`. This is the common case and costs nothing extra.

### 2. Wrapped (`switch_wrapped`)

Fall-through or a nested `break` needs real C semantics. The `case` only computes the arm index,
and the arms run in a `repeat ... until true` block where each arm is guarded by `idx <= k`.
Falling through just means running into the next guard. `break` is the AL `break` of the
`repeat` (from `examples/06-control-flow`):

```c
switch (n % 4) {
case 0: r += 1000;  /* fall through */
case 3: r += 100;
case 2: r += 10;
case 1: r += 1; break;
default: r = -1;
}
```
```al
case n mod 4 of
    0: begin sw3 := 1; end;
    3: begin sw3 := 2; end;
    2: begin sw3 := 3; end;
    1: begin sw3 := 4; end;
    else begin sw3 := 5; end;
end;
repeat
    if sw3 <= 1 then begin r := r + 1000; end;
    if sw3 <= 2 then begin r := r + 100; end;
    if sw3 <= 3 then begin r := r + 10; end;
    if sw3 <= 4 then begin r := r + 1; break; end;
    if sw3 <= 5 then begin r := -1; end;
until true;
```

`continue` inside a wrapped switch has to leave the `repeat` and then continue the
enclosing loop. It sets a flag (`cont<n>`), breaks, and after the `repeat` does `if cont then continue`.

## break / continue / return

- `break` in a loop → AL `break`. The trailing `break` of an AL `case` arm is dropped.
- `return` → `SFrameRestore` (`SP := fp_ + size` when the function has a frame) + `exit(value)`.
- Code after the last statement gets an implicit `exit(0)` for non-void functions (C allows falling off the end).

## goto: not supported

`RefScanner.visit_Goto` stops with `goto not supported`. That happens only for *reachable* functions,
so a goto in unused code does no harm. Rewrite gotos in the C source first. `projects/doom/patch.py` shows
the patterns used for PureDOOM's gotos. Each was replaced by hand with one of these:

| Pattern | Rewrite | DOOM example |
|---|---|---|
| `goto` to a label just before a short tail that returns | copy the tail into a block at the goto: `{ tail; return; }` | `NetUpdate`, `R_AddLine`, `F_CastTicker` |
| `goto` forward, skipping code | a flag: `skip = 1;` and `if (!skip) { ... }` | `A_Look`, `A_Chase` |
| `goto` out of a loop | `flag = 1; break;` then `if (!flag)` after the loop | `R_ClipSolidWallSegment` |
| `goto` into shared code at the end of a big function | move the shared code to a new function: `return helper(args);` | `PTR_ShootTraverse` |
| retry loop built from `goto` | restructure as a loop | `P_SlideMove` (rewritten whole) |

Automatic goto elimination (Erosa & Hendren style, or a loop + switch state machine for
irreducible cases) is the biggest single item on the [roadmap](roadmap.md).
