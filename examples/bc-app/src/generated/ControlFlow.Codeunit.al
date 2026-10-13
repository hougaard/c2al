// c2al example 06: control flow
// Translated from C to AL by c2al - do not edit by hand.
// C memory is emulated by the Mem list (one element per byte), C pointers are indexes into Mem.
// Call Initialize() once before calling any of the C functions.
codeunit 50106 "C2AL Control Flow"
{
    var
        Mem: List of [Integer];
        SP: Integer;
        BZ: BigInteger;
        B31: BigInteger;
        B32: BigInteger;
        SX8: array[256] of Integer;
        Pow2: array[32] of Integer;
        calls: Integer;
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

        SP := 69664;
        Heap := 69680;
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
    
    // control.c:115
    procedure digits_reversed(n: Integer): Integer
    var
        r: Integer;
        guard: Integer;
        tl1: Boolean;
    begin
        r := 0;
        guard := 0;
        while true do begin
            tl1 := n = 0;
            if not tl1 then begin
                guard := guard + 1;
                tl1 := guard > 20;
            end;
            if tl1 then begin
                break;
            end;
            r := (r * 10) + (n mod 10);
            n := n div 10;
        end;
        exit(r);
    end;
    
    // control.c:50
    procedure fallthrough(n: Integer): Integer
    var
        r: Integer;
        sw3: Integer;
    begin
        r := 0;
        case n mod 4 of
            0:
                 begin
                    sw3 := 1;
                end;
            3:
                 begin
                    sw3 := 2;
                end;
            2:
                 begin
                    sw3 := 3;
                end;
            1:
                 begin
                    sw3 := 4;
                end;
            else begin
                sw3 := 5;
            end;
        end;
        repeat
            if sw3 <= 1 then begin
                r := r + 1000;
            end;
            if sw3 <= 2 then begin
                r := r + 100;
            end;
            if sw3 <= 3 then begin
                r := r + 10;
            end;
            if sw3 <= 4 then begin
                r := r + 1;
                break;
            end;
            if sw3 <= 5 then begin
                r := (-1);
            end;
        until true;
        exit(r);
    end;
    
    // control.c:86
    procedure find_pair(target: Integer): Integer
    var
        found: Integer;
        i: Integer;
        j: Integer;
        ti1: Integer;
        ti2: Integer;
    begin
        found := (-1);
        i := 0;
        while (i < 6) and (found < 0) do begin
            j := i + 1;
            while j < 6 do begin
                ti1 := (i * 4) + 4096;
                ti2 := (j * 4) + 4096;
                if ((Mem.Get(ti1 + 1) + 256 * (Mem.Get(ti1 + 2) + 256 * (Mem.Get(ti1 + 3) + 256 * SX8[Mem.Get(ti1 + 4) + 1]))) + (Mem.Get(ti2 + 1) + 256 * (Mem.Get(ti2 + 2) + 256 * (Mem.Get(ti2 + 3) + 256 * SX8[Mem.Get(ti2 + 4) + 1])))) = target then begin
                    found := (i * 10) + j;
                    break;
                end;
                j := j + 1;
            end;
            i := i + 1;
        end;
        exit(found);
    end;
    
    // control.c:25
    local procedure roman_digit(c: Integer): Integer
    begin
        case c of
            73:
                 begin
                    exit(1);
                end;
            86:
                 begin
                    exit(5);
                end;
            88:
                 begin
                    exit(10);
                end;
            76:
                 begin
                    exit(50);
                end;
            67:
                 begin
                    exit(100);
                end;
            68:
                 begin
                    exit(500);
                end;
            77:
                 begin
                    exit(1000);
                end;
        end;
        exit(0);
    end;
    
    // control.c:39
    procedure roman_to_int(s: Integer): Integer
    var
        total: Integer;
        i: Integer;
        v: Integer;
        next: Integer;
        ti1: Integer;
    begin
        total := 0;
        i := 0;
        while SX8[Mem.Get((s + i) + 1) + 1] <> 0 do begin
            v := roman_digit(SX8[Mem.Get((s + i) + 1) + 1]);
            next := roman_digit(SX8[Mem.Get((s + (i + 1)) + 1) + 1]);
            if v < next then begin
                ti1 := -v;
            end else begin
                ti1 := v;
            end;
            total := total + ti1;
            i := i + 1;
        end;
        exit(total);
    end;
    
    // control.c:103
    procedure short_circuit(): Integer
    var
        r: Integer;
        tl1: Boolean;
        ti2: Integer;
    begin
        calls := 0;
        r := 0;
        tl1 := touch(0) <> 0;
        if tl1 then begin
            tl1 := touch(1) <> 0;
        end;
        if tl1 then begin
            r := r + 1;
        end;
        tl1 := touch(1) <> 0;
        if not tl1 then begin
            tl1 := touch(1) <> 0;
        end;
        if tl1 then begin
            r := r + 2;
        end;
        tl1 := touch(1) <> 0;
        if tl1 then begin
            tl1 := touch(0) <> 0;
        end;
        if tl1 then begin
            r := r + 4;
        end;
        if touch(0) <> 0 then begin
            ti2 := touch(5);
        end else begin
            ti2 := touch(7);
        end;
        r := r + ti2;
        exit((r * 100) + calls);
    end;
    
    // control.c:66
    procedure sum_skipping(s: Integer): Integer
    var
        sum: Integer;
        sw3: Integer;
        cont4: Boolean;
        ti1: Integer;
    begin
        sum := 0;
        while SX8[Mem.Get(s + 1) + 1] <> 0 do begin
            case SX8[Mem.Get(s + 1) + 1] of
                32:
                     begin
                        sw3 := 1;
                    end;
                35:
                     begin
                        sw3 := 2;
                    end;
                45:
                     begin
                        sw3 := 3;
                    end;
                else begin
                    sw3 := 4;
                end;
            end;
            cont4 := false;
            repeat
                if sw3 <= 1 then begin
                    cont4 := true;
                    break;
                end;
                if sw3 <= 2 then begin
                    exit(sum);
                end;
                if sw3 <= 3 then begin
                    sum := sum - 1;
                end;
                if sw3 <= 4 then begin
                    if (SX8[Mem.Get(s + 1) + 1] >= 48) and (SX8[Mem.Get(s + 1) + 1] <= 57) then begin
                        ti1 := SX8[Mem.Get(s + 1) + 1] - 48;
                    end else begin
                        ti1 := 0;
                    end;
                    sum := sum + ti1;
                end;
            until true;
            if cont4 then begin
                s := s + 1;
                continue;
            end;
            s := s + 1;
        end;
        exit(sum);
    end;
    
    // control.c:101
    local procedure touch(v: Integer): Integer
    begin
        calls := calls + 1;
        exit(v);
    end;
    
    // control.c:10
    procedure vowel_count(s: Integer): Integer
    var
        n: Integer;
        ti1: Integer;
        ti2: Integer;
    begin
        n := 0;
        while SX8[Mem.Get(s + 1) + 1] <> 0 do begin
            ti1 := SX8[Mem.Get(s + 1) + 1];
            ti2 := ti1 + (32 - (((((ti1 mod 64) + 64) mod 64) div 32) * 32));
            case ti2 of
                97, 101, 105, 111, 117, 121:
                     begin
                        n := n + 1;
                    end;
            end;
            s := s + 1;
        end;
        exit(n);
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
        D.Append('08Z000303Z00030BZ000305Z000307Z000302Z0003');
    end;
}
