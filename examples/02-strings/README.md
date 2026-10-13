# 02 strings

C strings are zero-terminated byte arrays in `Mem`. From AL you pass and get back addresses:

```al
Strings.Initialize();
Addr := Strings.reverse(Strings.AllocText('Business Central'));
Message(Strings.ReadText(Addr));   // lartneC ssenisuB
```

```c
char* reverse(char* s)
{
    char* a = s;
    char* b = s + strlen(s) - 1;
    while (a < b) {
        char t = *a;
        *a++ = *b;
        *b-- = t;
    }
    return s;
}
```
```al
procedure reverse(s: Integer): Integer
...
    a := s;
    b := (s + Rt_StrLen(s)) - 1;          // strlen is an intrinsic
    while a < b do begin
        t := SX8[Mem.Get(a + 1) + 1];      // load a (signed) char
        ti1 := a;                           // *a++ : post increment through a temp
        a := ti1 + 1;
        Mem.Set(ti1 + 1, ((SX8[Mem.Get(b + 1) + 1] mod 256) + 256) mod 256);
        ...
```

(The `SX8` + `mod 256` pair is a missed optimisation: a byte copied through a signed `char` could
be copied raw. See [docs/roadmap.md](../../docs/roadmap.md).)

Also in this example:

- string literals in the data segment (`weekdays[]` is an array of pointers to them)
- a local `char tmp[16]` on the C stack (`int_to_text` has a frame: `fp_ := SP - 16`)
- a static result buffer
- `strcpy`/`strcat`/`strcmp`/`atoi` from `c2al.h`, translated together with the program
