// c2al example 08: long long
// Translated from C to AL by c2al - do not edit by hand.
// C memory is emulated by the Mem list (one element per byte), C pointers are indexes into Mem.
// Call Initialize() once before calling any of the C functions.
codeunit 50108 "C2AL Long Long"
{
    var
        Mem: List of [Integer];
        SP: Integer;
        BZ: BigInteger;
        B31: BigInteger;
        B32: BigInteger;
        SX8: array[256] of Integer;
        Pow2: array[32] of Integer;
        total: BigInteger;
        // ---- c2al core runtime state (runtime/core.al) ----
        Heap: Integer;
        Initialized: Boolean;
        LogText: TextBuilder;
        AndTab: array[65536] of Integer;
        OrTab: array[65536] of Integer;
        XorTab: array[65536] of Integer;
        BitTabsReady: Boolean;

    // =====================================================================
    //  Host API - called from AL
    //  C addresses are 0-based, Mem is 1-based: byte at C address A is Mem.Get(A + 1).
    // =====================================================================

    /// <summary>Sets up C memory (data segment, stack, heap) and C globals. Call once before any C function.</summary>
    procedure Initialize()
    begin
        if Initialized then
            exit;
        InitRuntime();
        InitData();
        InitGlobals();
        Initialized := true;
    end;

    procedure IsInitialized(): Boolean
    begin
        exit(Initialized);
    end;

    /// <summary>Text printed by the C code with c2al_print / c2al_print_int.</summary>
    procedure GetLog(): Text
    begin
        exit(LogText.ToText());
    end;

    procedure ClearLog()
    begin
        Clear(LogText);
    end;

    /// <summary>Allocates Size zeroed bytes on the C heap and returns the C address.</summary>
    procedure Alloc(Size: Integer): Integer
    begin
        exit(c2al_malloc(Size));
    end;

    /// <summary>Copies an AL text into a new zero terminated C string (one byte per character, Latin-1) and returns its address.</summary>
    procedure AllocText(Value: Text): Integer
    var
        Addr: Integer;
        i: Integer;
        c: Integer;
    begin
        Addr := c2al_malloc(StrLen(Value) + 1);
        for i := 1 to StrLen(Value) do begin
            c := Value[i];
            Mem.Set(Addr + i, c mod 256);
        end;
        exit(Addr);
    end;

    /// <summary>Reads the zero terminated C string at Addr.</summary>
    procedure ReadText(Addr: Integer): Text
    begin
        exit(CStr(Addr));
    end;

    procedure PeekByte(Addr: Integer): Integer
    begin
        exit(Mem.Get(Addr + 1));
    end;

    procedure PokeByte(Addr: Integer; Value: Integer)
    begin
        Mem.Set(Addr + 1, ((Value mod 256) + 256) mod 256);
    end;

    /// <summary>Reads a little endian signed 32 bit int.</summary>
    procedure PeekInt(Addr: Integer): Integer
    begin
        exit(Mem.Get(Addr + 1) + 256 * (Mem.Get(Addr + 2) + 256 * (Mem.Get(Addr + 3) + 256 * SX8[Mem.Get(Addr + 4) + 1])));
    end;

    /// <summary>Writes a little endian 32 bit int.</summary>
    procedure PokeInt(Addr: Integer; Value: Integer)
    var
        n: Integer;
    begin
        if Value >= 0 then begin
            Mem.Set(Addr + 1, Value mod 256);
            Mem.Set(Addr + 2, (Value div 256) mod 256);
            Mem.Set(Addr + 3, (Value div 65536) mod 256);
            Mem.Set(Addr + 4, Value div 16777216);
        end else begin
            n := -1 - Value;
            Mem.Set(Addr + 1, 255 - n mod 256);
            Mem.Set(Addr + 2, 255 - (n div 256) mod 256);
            Mem.Set(Addr + 3, 255 - (n div 65536) mod 256);
            Mem.Set(Addr + 4, 255 - n div 16777216);
        end;
    end;

    // =====================================================================
    //  Runtime
    // =====================================================================

    local procedure InitRuntime()
    var
        Zeros: List of [Integer];
        i: Integer;
    begin
        Clear(Mem);
        for i := 1 to 4096 do
            Zeros.Add(0);
        for i := 1 to (73728 div 4096) do
            Mem.AddRange(Zeros);
        for i := 0 to 255 do
            if i < 128 then
                SX8[i + 1] := i
            else
                SX8[i + 1] := i - 256;
        Pow2[1] := 1;
        for i := 2 to 31 do
            Pow2[i] := Pow2[i - 1] * 2;
        Pow2[32] := -2147483647 - 1;
        BZ := 0;
        B31 := 2147483647;
        B31 := B31 + 1;
        B32 := B31 * 2;

        SP := 69648;
        Heap := 69664;
    end;

    local procedure DecodeData(D: Text; Addr: Integer)
    var
        i: Integer;
        n: Integer;
        c: Integer;
        Run: Integer;
    begin
        i := 1;
        n := StrLen(D);
        while i <= n do begin
            c := D[i];
            if c = 90 then begin // 'Z' + 4 hex digits: run of zero bytes
                Run := HexVal(D[i + 1]) * 4096 + HexVal(D[i + 2]) * 256 + HexVal(D[i + 3]) * 16 + HexVal(D[i + 4]);
                Addr += Run;
                i += 5;
            end else begin
                Mem.Set(Addr + 1, HexVal(c) * 16 + HexVal(D[i + 1]));
                Addr += 1;
                i += 2;
            end;
        end;
    end;

    local procedure HexVal(c: Integer): Integer
    begin
        if c <= 57 then
            exit(c - 48);
        exit(c - 55);
    end;

    local procedure B2I(b: Boolean): Integer
    begin
        if b then
            exit(1);
        exit(0);
    end;

    local procedure CStr(Addr: Integer): Text
    var
        TB: TextBuilder;
        c: Integer;
        ch: Char;
    begin
        c := Mem.Get(Addr + 1);
        while c <> 0 do begin
            ch := c;
            TB.Append(ch);
            Addr += 1;
            c := Mem.Get(Addr + 1);
        end;
        exit(TB.ToText());
    end;

    // ---- memory / string intrinsics -------------------------------------

    local procedure Rt_MemSet(Dst: Integer; Value: Integer; Count: Integer): Integer
    var
        i: Integer;
    begin
        Value := ((Value mod 256) + 256) mod 256;
        for i := Dst + 1 to Dst + Count do
            Mem.Set(i, Value);
        exit(Dst);
    end;

    // memcpy and memmove: copies backwards when the ranges overlap with Dst above Src
    local procedure Rt_MemCpy(Dst: Integer; Src: Integer; Count: Integer): Integer
    var
        i: Integer;
        d: Integer;
    begin
        d := Dst - Src;
        if (d > 0) and (d < Count) then begin
            for i := Src + Count downto Src + 1 do
                Mem.Set(i + d, Mem.Get(i));
            exit(Dst);
        end;
        for i := Src + 1 to Src + Count do
            Mem.Set(i + d, Mem.Get(i));
        exit(Dst);
    end;

    local procedure Rt_StrLen(Addr: Integer): Integer
    var
        n: Integer;
    begin
        while Mem.Get(Addr + n + 1) <> 0 do
            n += 1;
        exit(n);
    end;

    // ---- unsigned and bitwise helpers ------------------------------------

    local procedure UBig(a: Integer): BigInteger
    begin
        if a >= 0 then
            exit(BZ + a);
        exit(BZ + a + B32);
    end;

    local procedure Rt_UDiv(a: Integer; b: Integer): Integer
    var
        q: BigInteger;
    begin
        q := UBig(a) div UBig(b);
        if q >= B31 then
            q := q - B32;
        exit(q);
    end;

    local procedure Rt_UMod(a: Integer; b: Integer): Integer
    var
        q: BigInteger;
    begin
        q := UBig(a) mod UBig(b);
        if q >= B31 then
            q := q - B32;
        exit(q);
    end;

    local procedure InitBitTabs()
    var
        a: Integer;
        b: Integer;
        k: Integer;
        bit: Integer;
        x: Integer;
        y: Integer;
        r1: Integer;
        r2: Integer;
        r3: Integer;
    begin
        // 8 bit x 8 bit lookup tables for and / or / xor
        for a := 0 to 255 do
            for b := 0 to 255 do begin
                r1 := 0;
                r2 := 0;
                r3 := 0;
                x := a;
                y := b;
                bit := 1;
                for k := 1 to 8 do begin
                    if (x mod 2 = 1) and (y mod 2 = 1) then
                        r1 += bit;
                    if (x mod 2 = 1) or (y mod 2 = 1) then
                        r2 += bit;
                    if (x mod 2) <> (y mod 2) then
                        r3 += bit;
                    x := x div 2;
                    y := y div 2;
                    bit := bit * 2;
                end;
                AndTab[a * 256 + b + 1] := r1;
                OrTab[a * 256 + b + 1] := r2;
                XorTab[a * 256 + b + 1] := r3;
            end;
        BitTabsReady := true;
    end;

    local procedure BitOp(a: Integer; b: Integer; Op: Integer): Integer
    var
        ua: BigInteger;
        ub: BigInteger;
        r: BigInteger;
        m: BigInteger;
        k: Integer;
        x: Integer;
    begin
        if not BitTabsReady then
            InitBitTabs();
        ua := UBig(a);
        ub := UBig(b);
        m := 1;
        for k := 1 to 4 do begin
            x := (ua mod 256) * 256 + (ub mod 256) + 1;
            case Op of
                0:
                    r += AndTab[x] * m;
                1:
                    r += OrTab[x] * m;
                2:
                    r += XorTab[x] * m;
            end;
            ua := ua div 256;
            ub := ub div 256;
            m := m * 256;
        end;
        if r >= B31 then
            r := r - B32;
        exit(r);
    end;

    local procedure Rt_And(a: Integer; b: Integer): Integer
    begin
        exit(BitOp(a, b, 0));
    end;

    local procedure Rt_Or(a: Integer; b: Integer): Integer
    begin
        exit(BitOp(a, b, 1));
    end;

    local procedure Rt_Xor(a: Integer; b: Integer): Integer
    begin
        exit(BitOp(a, b, 2));
    end;

    local procedure Rt_Shr(a: Integer; n: Integer): Integer
    var
        m: Integer;
    begin
        if n <= 0 then
            exit(a);
        if n >= 31 then begin
            if a < 0 then
                exit(-1);
            exit(0);
        end;
        m := Pow2[n + 1];
        exit((a - ((a mod m) + m) mod m) div m);
    end;

    local procedure Rt_UShr(a: Integer; n: Integer): Integer
    var
        r: BigInteger;
    begin
        if n <= 0 then
            exit(a);
        if n >= 32 then
            exit(0);
        if n = 31 then
            r := UBig(a) div B31
        else
            r := UBig(a) div Pow2[n + 1];
        exit(r);
    end;

    // =====================================================================
    //  Natives: C functions declared in include/c2al.h, implemented here
    // =====================================================================

    local procedure c2al_malloc(size: Integer): Integer
    var
        a: Integer;
        Zeros: List of [Integer];
        i: Integer;
    begin
        // bump allocator: memory is never reused, Mem grows in 4 KB steps
        a := Heap;
        Heap := (Heap + size + 15) div 16 * 16;
        if Heap >= Mem.Count then begin
            for i := 1 to 4096 do
                Zeros.Add(0);
            while Heap >= Mem.Count do
                Mem.AddRange(Zeros);
        end;
        exit(a);
    end;

    local procedure c2al_free(p: Integer)
    begin
    end;

    local procedure c2al_print(s: Integer)
    begin
        LogText.Append(CStr(s));
    end;

    local procedure c2al_print_int(v: Integer)
    begin
        LogText.Append(Format(v, 0, 9));
    end;

    local procedure c2al_abort(s: Integer)
    begin
        Error('%1', CStr(s));
    end;

    // =====================================================================
    //  Translated C code
    // =====================================================================
    
    // longlong.c:72
    procedure add_total(v: BigInteger): BigInteger
    begin
        total := total + v;
        exit(total);
    end;
    
    // longlong.c:8
    procedure factorial(n: Integer): BigInteger
    var
        r: BigInteger;
        i: Integer;
    begin
        r := 1;
        i := 2;
        while i <= n do begin
            r := r * (BZ + i);
            i := i + 1;
        end;
        exit(r);
    end;
    
    // longlong.c:36
    procedure is_prime_mr(n: Integer): Integer
    var
        d: Integer;
        r: Integer;
        i: Integer;
        a: Integer;
        ti1: Integer;
        x: Integer;
        composite: Integer;
        k: Integer;
    begin
        if n < 2 then begin
            exit(0);
        end;
        if (n mod 2) = 0 then begin
            exit(B2I(n = 2));
        end;
        d := n - 1;
        r := 0;
        while (d mod 2) = 0 do begin
            d := d div 2;
            r := r + 1;
        end;
        i := 0;
        while i < 3 do begin
            ti1 := (i * 4) + 4096;
            a := (Mem.Get(ti1 + 1) + 256 * (Mem.Get(ti1 + 2) + 256 * (Mem.Get(ti1 + 3) + 256 * SX8[Mem.Get(ti1 + 4) + 1])));
            if (a mod n) = 0 then begin
                i := i + 1;
                continue;
            end;
            x := powmod(a, d, n);
            if (x = 1) or (x = (n - 1)) then begin
                i := i + 1;
                continue;
            end;
            composite := 1;
            k := 1;
            while k < r do begin
                x := mulmod(x, x, n);
                if x = (n - 1) then begin
                    composite := 0;
                    break;
                end;
                k := k + 1;
            end;
            if composite <> 0 then begin
                exit(0);
            end;
            i := i + 1;
        end;
        exit(1);
    end;
    
    // longlong.c:79
    procedure low32(v: BigInteger): Integer
    var
        ti1: Integer;
    begin
        ti1 := ((((v + B31) mod B32) + B32) mod B32) - B31;
        exit(ti1);
    end;
    
    // longlong.c:17
    local procedure mulmod(a: Integer; b: Integer; m: Integer): Integer
    var
        ti1: Integer;
    begin
        ti1 := (((((((BZ + a) * (BZ + b)) mod (BZ + m)) + B31) mod B32) + B32) mod B32) - B31;
        exit(ti1);
    end;
    
    // longlong.c:22
    procedure powmod(base: Integer; exp: Integer; m: Integer): Integer
    var
        result: Integer;
    begin
        result := 1 mod m;
        base := base mod m;
        while exp > 0 do begin
            if (exp mod 2) <> 0 then begin
                result := mulmod(result, base, m);
            end;
            base := mulmod(base, base, m);
            exp := exp div 2;
        end;
        exit(result);
    end;
    
    local procedure InitGlobals()
    begin
    end;
    
    local procedure InitData()
    var
        D: TextBuilder;
    begin
        DataPart0(D);
        DecodeData(D.ToText(), 4096);
    end;
    
    local procedure DataPart0(var D: TextBuilder)
    begin
        D.Append('02Z000307Z00033DZ0003');
    end;
}
