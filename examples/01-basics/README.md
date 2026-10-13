# 01 basics

Plain functions, recursion, loops, a global array and a global counter.

```c
int fib(int n)
{
    if (n < 2)
        return n;
    return fib(n - 1) + fib(n - 2);
}
```
```al
// basics.c:6
procedure fib(n: Integer): Integer
var
    ti1: Integer;
begin
    if n < 2 then begin
        exit(n);
    end;
    ti1 := fib(n - 1) + fib(n - 2);
    exit(ti1);
end;
```

Things to look at in [Basics.Codeunit.al](../bc-app/src/generated/Basics.Codeunit.al):

- `count` is an AL global (`count: Integer`), because its address is never taken. `history[16]` is
  an array, so it lives in the data segment, and `push` stores into it with four `Mem.Set` calls.
- C `/` and `%` truncate toward zero, just like AL `div` and `mod`: `div_trunc(-7, 2)` is `-3`.
- `narrow_char(200)` is `-56`: converting to `signed char` wraps.
- Signed arithmetic is not wrapped: `fib_iter(46)` would overflow on its last loop step and raise an
  AL error, so it is not one of the tests. See [09-signed-overflow](../09-signed-overflow).
