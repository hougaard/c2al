// c2al example 04: function pointers
// Translated from C to AL by c2al - do not edit by hand.
// C memory is emulated by the Mem list (one element per byte), C pointers are indexes into Mem.
// Call Initialize() once before calling any of the C functions.
codeunit 50104 "C2AL Function Pointers"
{
    var
        Mem: List of [Integer];
        SP: Integer;
        BZ: BigInteger;
        B31: BigInteger;
        B32: BigInteger;
        SX8: array[256] of Integer;
        Pow2: array[32] of Integer;
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

        SP := 69776;
        Heap := 69792;
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
    
    // funcptr.c:8
    local procedure add_2(a: Integer; b: Integer): Integer
    begin
        exit(a + b);
    end;
    
    // funcptr.c:79
    local procedure by_age(a: Integer; b: Integer): Integer
    begin
        exit((Mem.Get(a + 5) + 256 * (Mem.Get(a + 6) + 256 * (Mem.Get(a + 7) + 256 * SX8[Mem.Get(a + 8) + 1]))) - (Mem.Get(b + 5) + 256 * (Mem.Get(b + 6) + 256 * (Mem.Get(b + 7) + 256 * SX8[Mem.Get(b + 8) + 1]))));
    end;
    
    // funcptr.c:78
    local procedure by_name(a: Integer; b: Integer): Integer
    var
        ti1: Integer;
    begin
        ti1 := strcmp((Mem.Get(a + 1) + 256 * (Mem.Get(a + 2) + 256 * (Mem.Get(a + 3) + 256 * SX8[Mem.Get(a + 4) + 1]))), (Mem.Get(b + 1) + 256 * (Mem.Get(b + 2) + 256 * (Mem.Get(b + 3) + 256 * SX8[Mem.Get(b + 4) + 1]))));
        exit(ti1);
    end;
    
    // funcptr.c:74
    local procedure by_value(a: Integer; b: Integer): Integer
    begin
        exit((Mem.Get(a + 1) + 256 * (Mem.Get(a + 2) + 256 * (Mem.Get(a + 3) + 256 * SX8[Mem.Get(a + 4) + 1]))) - (Mem.Get(b + 1) + 256 * (Mem.Get(b + 2) + 256 * (Mem.Get(b + 3) + 256 * SX8[Mem.Get(b + 4) + 1]))));
    end;
    
    // funcptr.c:75
    local procedure by_value_desc(a: Integer; b: Integer): Integer
    begin
        exit((Mem.Get(b + 1) + 256 * (Mem.Get(b + 2) + 256 * (Mem.Get(b + 3) + 256 * SX8[Mem.Get(b + 4) + 1]))) - (Mem.Get(a + 1) + 256 * (Mem.Get(a + 2) + 256 * (Mem.Get(a + 3) + 256 * SX8[Mem.Get(a + 4) + 1]))));
    end;
    
    // funcptr.c:19
    procedure calc(a: Integer; op: Integer; b: Integer): Integer
    var
        i: Integer;
        ti1: Integer;
        ti2: Integer;
    begin
        i := 0;
        while i < 4 do begin
            if SX8[Mem.Get((i * 8) + 4097) + 1] = op then begin
                ti1 := (i * 8) + 4100;
                ti2 := CallFn2((Mem.Get(ti1 + 1) + 256 * (Mem.Get(ti1 + 2) + 256 * (Mem.Get(ti1 + 3) + 256 * SX8[Mem.Get(ti1 + 4) + 1]))), a, b);
                exit(ti2);
            end;
            i := i + 1;
        end;
        exit(0);
    end;
    
    // funcptr.c:28
    procedure eval(s: Integer): Integer
    var
        acc: Integer;
        ti1: Integer;
        op: Integer;
        v: Integer;
    begin
        acc := 0;
        while (SX8[Mem.Get(s + 1) + 1] >= 48) and (SX8[Mem.Get(s + 1) + 1] <= 57) do begin
            ti1 := s;
            s := ti1 + 1;
            acc := (acc * 10) + (SX8[Mem.Get(ti1 + 1) + 1] - 48);
        end;
        while SX8[Mem.Get(s + 1) + 1] <> 0 do begin
            ti1 := s;
            s := ti1 + 1;
            op := SX8[Mem.Get(ti1 + 1) + 1];
            v := 0;
            while (SX8[Mem.Get(s + 1) + 1] >= 48) and (SX8[Mem.Get(s + 1) + 1] <= 57) do begin
                ti1 := s;
                s := ti1 + 1;
                v := (v * 10) + (SX8[Mem.Get(ti1 + 1) + 1] - 48);
            end;
            acc := calc(acc, op, v);
        end;
        exit(acc);
    end;
    
    // funcptr.c:43
    local procedure fold(a: Integer; n: Integer; init: Integer; f: Integer): Integer
    var
        i: Integer;
        ti1: Integer;
    begin
        i := 0;
        while i < n do begin
            ti1 := a + (i * 4);
            init := CallFn2(f, init, (Mem.Get(ti1 + 1) + 256 * (Mem.Get(ti1 + 2) + 256 * (Mem.Get(ti1 + 3) + 256 * SX8[Mem.Get(ti1 + 4) + 1]))));
            i := i + 1;
        end;
        exit(init);
    end;
    
    // funcptr.c:52
    procedure fold_demo(which: Integer): Integer
    var
        fp_: Integer;
        ti1: Integer;
        ti2: Integer;
        ti3: Integer;
        ti4: Integer;
    begin
        fp_ := SP - 12;
        SP := fp_;
        Rt_MemCpy(fp_, 4160, 12);
        if which = 1 then begin
            ti2 := 1;
        end else begin
            if which = 2 then begin
                ti1 := (-1000);
            end else begin
                ti1 := 0;
            end;
            ti2 := ti1;
        end;
        ti3 := fp_ + (which * 4);
        ti4 := fold(4128, 8, ti2, (Mem.Get(ti3 + 1) + 256 * (Mem.Get(ti3 + 2) + 256 * (Mem.Get(ti3 + 3) + 256 * SX8[Mem.Get(ti3 + 4) + 1]))));
        SP := fp_ + 12;
        exit(ti4);
    end;
    
    // funcptr.c:11
    local procedure max_2(a: Integer; b: Integer): Integer
    var
        ti1: Integer;
    begin
        if a > b then begin
            ti1 := a;
        end else begin
            ti1 := b;
        end;
        exit(ti1);
    end;
    
    // funcptr.c:10
    local procedure mul(a: Integer; b: Integer): Integer
    begin
        exit(a * b);
    end;
    
    // funcptr.c:59
    local procedure sort(base: Integer; n: Integer; size: Integer; cmp: Integer)
    var
        fp_: Integer;
        b: Integer;
        i: Integer;
        j: Integer;
        tl1: Boolean;
    begin
        fp_ := SP - 32;
        SP := fp_;
        b := base;
        i := 1;
        while i < n do begin
            Rt_MemCpy(fp_, b + (i * size), size);
            j := i - 1;
            while true do begin
                tl1 := j >= 0;
                if tl1 then begin
                    tl1 := CallFn2(cmp, b + (j * size), fp_) > 0;
                end;
                if not tl1 then begin
                    break;
                end;
                Rt_MemCpy(b + ((j + 1) * size), b + (j * size), size);
                j := j + (-1);
            end;
            Rt_MemCpy(b + ((j + 1) * size), fp_, size);
            i := i + 1;
        end;
        SP := fp_ + 32;
    end;
    
    // funcptr.c:82
    procedure sort_ints(descending: Integer)
    var
        fp_: Integer;
        ti1: Integer;
        i: Integer;
    begin
        fp_ := SP - 32;
        SP := fp_;
        Rt_MemCpy(fp_, 4128, 32);
        if descending <> 0 then begin
            ti1 := 5;
        end else begin
            ti1 := 4;
        end;
        sort(fp_, 8, 4, ti1);
        i := 0;
        while i < 8 do begin
            ti1 := fp_ + (i * 4);
            c2al_print_int((Mem.Get(ti1 + 1) + 256 * (Mem.Get(ti1 + 2) + 256 * (Mem.Get(ti1 + 3) + 256 * SX8[Mem.Get(ti1 + 4) + 1]))));
            if i < 7 then begin
                ti1 := 4172;
            end else begin
                ti1 := 4174;
            end;
            c2al_print(ti1);
            i := i + 1;
        end;
        SP := fp_ + 32;
    end;
    
    // funcptr.c:93
    procedure sort_people(by: Integer)
    var
        fp_: Integer;
        ti1: Integer;
        i: Integer;
    begin
        fp_ := SP - 32;
        SP := fp_;
        Rt_MemCpy(fp_, 4196, 32);
        if by <> 0 then begin
            ti1 := 2;
        end else begin
            ti1 := 3;
        end;
        sort(fp_, 4, 8, ti1);
        i := 0;
        while i < 4 do begin
            ti1 := fp_ + (i * 8);
            c2al_print((Mem.Get(ti1 + 1) + 256 * (Mem.Get(ti1 + 2) + 256 * (Mem.Get(ti1 + 3) + 256 * SX8[Mem.Get(ti1 + 4) + 1]))));
            c2al_print(4228);
            i := i + 1;
        end;
        SP := fp_ + 32;
    end;
    
    // c2al.h:53
    local procedure strcmp(a: Integer; b: Integer): Integer
    begin
        while (SX8[Mem.Get(a + 1) + 1] <> 0) and (SX8[Mem.Get(a + 1) + 1] = SX8[Mem.Get(b + 1) + 1]) do begin
            a := a + 1;
            b := b + 1;
        end;
        exit((((SX8[Mem.Get(a + 1) + 1] mod 256) + 256) mod 256) - (((SX8[Mem.Get(b + 1) + 1] mod 256) + 256) mod 256));
    end;
    
    // funcptr.c:9
    local procedure sub(a: Integer; b: Integer): Integer
    begin
        exit(a - b);
    end;
    
    // call through a C function pointer
    local procedure CallFn2(f: Integer; a0: Integer; a1: Integer): Integer
    begin
        case f of
            1:
                exit(add_2(a0, a1));
            2:
                exit(by_age(a0, a1));
            3:
                exit(by_name(a0, a1));
            4:
                exit(by_value(a0, a1));
            5:
                exit(by_value_desc(a0, a1));
            6:
                exit(max_2(a0, a1));
            7:
                exit(mul(a0, a1));
            8:
                exit(sub(a0, a1));
        end;
        Error('C2AL: bad function pointer %1 in CallFn2', f);
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
        D.Append('2BZ000301Z00032DZ000308Z00032AZ000307Z00034DZ000306Z000303Z0003FFFFFFFF04Z000301Z0003FBFFFFFF09Z000302Z000306Z000301Z000307Z000306Z00032C00004D61647300416E6E61004572696B00426FZ00044F10000029Z0003541000001DZ00035910000034Z00035E10000023Z00032000');
    end;
}
