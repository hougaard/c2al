// c2al example 05: checksums
// Translated from C to AL by c2al - do not edit by hand.
// C memory is emulated by the Mem list (one element per byte), C pointers are indexes into Mem.
// Call Initialize() once before calling any of the C functions.
codeunit 50105 "C2AL Checksums"
{
    var
        Mem: List of [Integer];
        SP: Integer;
        BZ: BigInteger;
        B31: BigInteger;
        B32: BigInteger;
        SX8: array[256] of Integer;
        Pow2: array[32] of Integer;
        crc_ready: Integer;
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

        SP := 70688;
        Heap := 70704;
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
    
    // checksums.c:32
    local procedure adler32(s: Integer): Integer
    var
        a: Integer;
        b: Integer;
        ti1: Integer;
    begin
        a := 1;
        b := 0;
        while SX8[Mem.Get(s + 1) + 1] <> 0 do begin
            ti1 := ((((((BZ + a) + (((SX8[Mem.Get(s + 1) + 1] mod 256) + 256) mod 256)) + B31) mod B32) + B32) mod B32) - B31;
            a := Rt_UMod(ti1, 65521);
            ti1 := ((((((BZ + b) + a) + B31) mod B32) + B32) mod B32) - B31;
            b := Rt_UMod(ti1, 65521);
            s := s + 1;
        end;
        ti1 := ((((((BZ + b) * 65536) + B31) mod B32) + B32) mod B32) - B31;
        exit(Rt_Or(ti1, a));
    end;
    
    // checksums.c:68
    procedure adler32_hex(s: Integer): Integer
    var
        ti1: Integer;
    begin
        ti1 := hex32(adler32(s));
        exit(ti1);
    end;
    
    // checksums.c:22
    procedure crc32(s: Integer): Integer
    var
        c: Integer;
        p: Integer;
        ti1: Integer;
        ti2: Integer;
    begin
        if crc_ready = 0 then begin
            crc_init();
        end;
        c := (-1);
        p := s;
        while Mem.Get(p + 1) <> 0 do begin
            ti1 := ((((Rt_Xor(c, Mem.Get(p + 1)) mod 256) + 256) mod 256) * 4) + 4096;
            ti2 := (((BZ + c) + B32) mod B32) div 256;
            c := Rt_Xor((Mem.Get(ti1 + 1) + 256 * (Mem.Get(ti1 + 2) + 256 * (Mem.Get(ti1 + 3) + 256 * SX8[Mem.Get(ti1 + 4) + 1]))), ti2);
            p := p + 1;
        end;
        exit(Rt_Xor(c, (-1)));
    end;
    
    // checksums.c:67
    procedure crc32_hex(s: Integer): Integer
    var
        ti1: Integer;
    begin
        ti1 := hex32(crc32(s));
        exit(ti1);
    end;
    
    // checksums.c:11
    local procedure crc_init()
    var
        i: Integer;
        ti1: Integer;
        c: Integer;
        k: Integer;
        ti2: Integer;
        ti3: Integer;
    begin
        i := 0;
        while (i >= 0) and (i < 256) do begin
            c := i;
            k := 0;
            while k < 8 do begin
                if (((c mod 2) + 2) mod 2) >= 1 then begin
                    ti1 := (((BZ + c) + B32) mod B32) div 2;
                    ti3 := Rt_Xor((-306674912), ti1);
                end else begin
                    ti2 := (((BZ + c) + B32) mod B32) div 2;
                    ti3 := ti2;
                end;
                c := ti3;
                k := k + 1;
            end;
            ti3 := (i * 4) + 4096;
            if c >= 0 then begin
                Mem.Set(ti3 + 1, c mod 256);
                Mem.Set(ti3 + 2, (c div 256) mod 256);
                Mem.Set(ti3 + 3, (c div 65536) mod 256);
                Mem.Set(ti3 + 4, c div 16777216);
            end else begin
                Mem.Set(ti3 + 1, 255 - (-1 - c) mod 256);
                Mem.Set(ti3 + 2, 255 - ((-1 - c) div 256) mod 256);
                Mem.Set(ti3 + 3, 255 - ((-1 - c) div 65536) mod 256);
                Mem.Set(ti3 + 4, 255 - (-1 - c) div 16777216);
            end;
            ti1 := ((((((BZ + i) + 1) + B31) mod B32) + B32) mod B32) - B31;
            i := ti1;
        end;
        crc_ready := 1;
    end;
    
    // checksums.c:43
    local procedure fnv1a(s: Integer): Integer
    var
        h: Integer;
        ti1: Integer;
    begin
        h := (-2128831035);
        while SX8[Mem.Get(s + 1) + 1] <> 0 do begin
            h := Rt_Xor(h, ((SX8[Mem.Get(s + 1) + 1] mod 256) + 256) mod 256);
            ti1 := ((((((BZ + h) * 16777619) + B31) mod B32) + B32) mod B32) - B31;
            h := ti1;
            s := s + 1;
        end;
        exit(h);
    end;
    
    // checksums.c:69
    procedure fnv1a_hex(s: Integer): Integer
    var
        ti1: Integer;
    begin
        ti1 := hex32(fnv1a(s));
        exit(ti1);
    end;
    
    // checksums.c:56
    local procedure hex32(v: Integer): Integer
    var
        i: Integer;
        ti1: Integer;
    begin
        i := 7;
        while i >= 0 do begin
            Mem.Set(i + 5121, ((SX8[Mem.Get((((v mod 16) + 16) mod 16) + 5133) + 1] mod 256) + 256) mod 256);
            ti1 := (((BZ + v) + B32) mod B32) div 16;
            v := ti1;
            i := i + (-1);
        end;
        Mem.Set(5129, 0);
        exit(5120);
    end;
    
    // checksums.c:72
    procedure popcount(v: Integer): Integer
    var
        n: Integer;
        ti1: Integer;
    begin
        n := 0;
        while v <> 0 do begin
            ti1 := ((((((BZ + v) - 1) + B31) mod B32) + B32) mod B32) - B31;
            v := Rt_And(v, ti1);
            n := n + 1;
        end;
        exit(n);
    end;
    
    // checksums.c:82
    procedure rotl(v: Integer; n: Integer): Integer
    var
        ti1: Integer;
    begin
        ti1 := ((((((BZ + v) * Pow2[n + 1]) + B31) mod B32) + B32) mod B32) - B31;
        exit(Rt_Or(ti1, Rt_UShr(v, 32 - n)));
    end;
    
    // checksums.c:84
    procedure unsigned_less(a: Integer; b: Integer): Integer
    begin
        exit(B2I((a < b) xor ((a < 0) xor (b < 0))));
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
        D.Append('Z040C3031323334353637383961626364656600');
    end;
}
