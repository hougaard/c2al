// c2al example 07: SHA-256
// SHA-256 based on the public domain implementation by Brad Conte (github.com/B-Con/crypto-algorithms).
// Translated from C to AL by c2al - do not edit by hand.
// C memory is emulated by the Mem list (one element per byte), C pointers are indexes into Mem.
// Call Initialize() once before calling any of the C functions.
codeunit 50107 "C2AL SHA256"
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

        SP := 69984;
        Heap := 70000;
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
    
    // sha256.c:101
    local procedure sha256_final(ctx: Integer; hash: Integer)
    var
        i: Integer;
        ti1: Integer;
        ti2: Integer;
        ti3: Integer;
        w: Integer;
        ti4: Integer;
        ti5: Integer;
    begin
        i := (Mem.Get(ctx + 65) + 256 * (Mem.Get(ctx + 66) + 256 * (Mem.Get(ctx + 67) + 256 * SX8[Mem.Get(ctx + 68) + 1])));
        ti1 := (Mem.Get(ctx + 65) + 256 * (Mem.Get(ctx + 66) + 256 * (Mem.Get(ctx + 67) + 256 * SX8[Mem.Get(ctx + 68) + 1])));
        if (ti1 >= 0) and (ti1 < 56) then begin
            ti1 := i;
            ti2 := ((((((BZ + ti1) + 1) + B31) mod B32) + B32) mod B32) - B31;
            i := ti2;
            ti3 := ctx + ti1;
            Mem.Set(ti3 + 1, 128);
            while (i >= 0) and (i < 56) do begin
                ti3 := i;
                ti2 := ((((((BZ + ti3) + 1) + B31) mod B32) + B32) mod B32) - B31;
                i := ti2;
                ti1 := ctx + ti3;
                Mem.Set(ti1 + 1, 0);
            end;
        end else begin
            ti1 := i;
            ti2 := ((((((BZ + ti1) + 1) + B31) mod B32) + B32) mod B32) - B31;
            i := ti2;
            ti3 := ctx + ti1;
            Mem.Set(ti3 + 1, 128);
            while (i >= 0) and (i < 64) do begin
                ti3 := i;
                ti2 := ((((((BZ + ti3) + 1) + B31) mod B32) + B32) mod B32) - B31;
                i := ti2;
                ti1 := ctx + ti3;
                Mem.Set(ti1 + 1, 0);
            end;
            transform(ctx, ctx);
            Rt_MemSet(ctx, 0, 56);
        end;
        ti1 := ((((((BZ + (Mem.Get(ctx + 65) + 256 * (Mem.Get(ctx + 66) + 256 * (Mem.Get(ctx + 67) + 256 * SX8[Mem.Get(ctx + 68) + 1])))) * 8) + B31) mod B32) + B32) mod B32) - B31;
        ti2 := ((((((BZ + (Mem.Get(ctx + 69) + 256 * (Mem.Get(ctx + 70) + 256 * (Mem.Get(ctx + 71) + 256 * SX8[Mem.Get(ctx + 72) + 1])))) + ti1) + B31) mod B32) + B32) mod B32) - B31;
        if ti2 >= 0 then begin
            Mem.Set(ctx + 69, ti2 mod 256);
            Mem.Set(ctx + 70, (ti2 div 256) mod 256);
            Mem.Set(ctx + 71, (ti2 div 65536) mod 256);
            Mem.Set(ctx + 72, ti2 div 16777216);
        end else begin
            Mem.Set(ctx + 69, 255 - (-1 - ti2) mod 256);
            Mem.Set(ctx + 70, 255 - ((-1 - ti2) div 256) mod 256);
            Mem.Set(ctx + 71, 255 - ((-1 - ti2) div 65536) mod 256);
            Mem.Set(ctx + 72, 255 - (-1 - ti2) div 16777216);
        end;
        Mem.Set(ctx + 64, (((Mem.Get(ctx + 69) + 256 * (Mem.Get(ctx + 70) + 256 * (Mem.Get(ctx + 71) + 256 * SX8[Mem.Get(ctx + 72) + 1]))) mod 256) + 256) mod 256);
        ti2 := (((BZ + (Mem.Get(ctx + 69) + 256 * (Mem.Get(ctx + 70) + 256 * (Mem.Get(ctx + 71) + 256 * SX8[Mem.Get(ctx + 72) + 1])))) + B32) mod B32) div 256;
        Mem.Set(ctx + 63, ((ti2 mod 256) + 256) mod 256);
        ti2 := (((BZ + (Mem.Get(ctx + 69) + 256 * (Mem.Get(ctx + 70) + 256 * (Mem.Get(ctx + 71) + 256 * SX8[Mem.Get(ctx + 72) + 1])))) + B32) mod B32) div 65536;
        Mem.Set(ctx + 62, ((ti2 mod 256) + 256) mod 256);
        ti2 := (((BZ + (Mem.Get(ctx + 69) + 256 * (Mem.Get(ctx + 70) + 256 * (Mem.Get(ctx + 71) + 256 * SX8[Mem.Get(ctx + 72) + 1])))) + B32) mod B32) div 16777216;
        Mem.Set(ctx + 61, ((ti2 mod 256) + 256) mod 256);
        Mem.Set(ctx + 57, 0);
        Mem.Set(ctx + 58, 0);
        Mem.Set(ctx + 59, 0);
        Mem.Set(ctx + 60, 0);
        transform(ctx, ctx);
        i := 0;
        while (i >= 0) and (i < 4) do begin
            w := 0;
            while w < 8 do begin
                ti2 := ((((((BZ + i) + (w * 4)) + B31) mod B32) + B32) mod B32) - B31;
                ti1 := (ctx + 72) + (w * 4);
                ti3 := ((((((BZ + i) * 8) + B31) mod B32) + B32) mod B32) - B31;
                ti4 := ((((((BZ + 24) - ti3) + B31) mod B32) + B32) mod B32) - B31;
                ti5 := hash + ti2;
                Mem.Set(ti5 + 1, ((Rt_UShr((Mem.Get(ti1 + 1) + 256 * (Mem.Get(ti1 + 2) + 256 * (Mem.Get(ti1 + 3) + 256 * SX8[Mem.Get(ti1 + 4) + 1]))), ti4) mod 256) + 256) mod 256);
                w := w + 1;
            end;
            ti2 := ((((((BZ + i) + 1) + B31) mod B32) + B32) mod B32) - B31;
            i := ti2;
        end;
    end;
    
    // sha256.c:136
    procedure sha256_hex(s: Integer): Integer
    var
        fp_: Integer;
        i: Integer;
        ti1: Integer;
    begin
        fp_ := SP - 136;
        SP := fp_;
        sha256_init(fp_);
        sha256_update(fp_, s, Rt_StrLen(s));
        sha256_final(fp_, fp_ + 104);
        i := 0;
        while i < 32 do begin
            ti1 := (i * 2) + 4352;
            Mem.Set(ti1 + 1, ((SX8[Mem.Get((Mem.Get(((fp_ + 104) + i) + 1) div 16) + 4421) + 1] mod 256) + 256) mod 256);
            ti1 := (i * 2) + 4353;
            Mem.Set(ti1 + 1, ((SX8[Mem.Get((Mem.Get(((fp_ + 104) + i) + 1) mod 16) + 4421) + 1] mod 256) + 256) mod 256);
            i := i + 1;
        end;
        Mem.Set(4417, 0);
        SP := fp_ + 136;
        exit(4352);
    end;
    
    // sha256.c:74
    local procedure sha256_init(ctx: Integer)
    begin
        Mem.Set(ctx + 65, 0);
        Mem.Set(ctx + 66, 0);
        Mem.Set(ctx + 67, 0);
        Mem.Set(ctx + 68, 0);
        Mem.Set(ctx + 69, 0);
        Mem.Set(ctx + 70, 0);
        Mem.Set(ctx + 71, 0);
        Mem.Set(ctx + 72, 0);
        Mem.Set(ctx + 73, 103);
        Mem.Set(ctx + 74, 230);
        Mem.Set(ctx + 75, 9);
        Mem.Set(ctx + 76, 106);
        Mem.Set(ctx + 77, 133);
        Mem.Set(ctx + 78, 174);
        Mem.Set(ctx + 79, 103);
        Mem.Set(ctx + 80, 187);
        Mem.Set(ctx + 81, 114);
        Mem.Set(ctx + 82, 243);
        Mem.Set(ctx + 83, 110);
        Mem.Set(ctx + 84, 60);
        Mem.Set(ctx + 85, 58);
        Mem.Set(ctx + 86, 245);
        Mem.Set(ctx + 87, 79);
        Mem.Set(ctx + 88, 165);
        Mem.Set(ctx + 89, 127);
        Mem.Set(ctx + 90, 82);
        Mem.Set(ctx + 91, 14);
        Mem.Set(ctx + 92, 81);
        Mem.Set(ctx + 93, 140);
        Mem.Set(ctx + 94, 104);
        Mem.Set(ctx + 95, 5);
        Mem.Set(ctx + 96, 155);
        Mem.Set(ctx + 97, 171);
        Mem.Set(ctx + 98, 217);
        Mem.Set(ctx + 99, 131);
        Mem.Set(ctx + 100, 31);
        Mem.Set(ctx + 101, 25);
        Mem.Set(ctx + 102, 205);
        Mem.Set(ctx + 103, 224);
        Mem.Set(ctx + 104, 91);
    end;
    
    // sha256.c:88
    local procedure sha256_update(ctx: Integer; data: Integer; len: Integer)
    var
        i: Integer;
        ti1: Integer;
    begin
        i := 0;
        while (i < len) xor ((i < 0) xor (len < 0)) do begin
            ti1 := ctx + (Mem.Get(ctx + 65) + 256 * (Mem.Get(ctx + 66) + 256 * (Mem.Get(ctx + 67) + 256 * SX8[Mem.Get(ctx + 68) + 1])));
            Mem.Set(ti1 + 1, Mem.Get((data + i) + 1));
            ti1 := ((((((BZ + (Mem.Get(ctx + 65) + 256 * (Mem.Get(ctx + 66) + 256 * (Mem.Get(ctx + 67) + 256 * SX8[Mem.Get(ctx + 68) + 1])))) + 1) + B31) mod B32) + B32) mod B32) - B31;
            if ti1 >= 0 then begin
                Mem.Set(ctx + 65, ti1 mod 256);
                Mem.Set(ctx + 66, (ti1 div 256) mod 256);
                Mem.Set(ctx + 67, (ti1 div 65536) mod 256);
                Mem.Set(ctx + 68, ti1 div 16777216);
            end else begin
                Mem.Set(ctx + 65, 255 - (-1 - ti1) mod 256);
                Mem.Set(ctx + 66, 255 - ((-1 - ti1) div 256) mod 256);
                Mem.Set(ctx + 67, 255 - ((-1 - ti1) div 65536) mod 256);
                Mem.Set(ctx + 68, 255 - (-1 - ti1) div 16777216);
            end;
            if (Mem.Get(ctx + 65) + 256 * (Mem.Get(ctx + 66) + 256 * (Mem.Get(ctx + 67) + 256 * SX8[Mem.Get(ctx + 68) + 1]))) = 64 then begin
                transform(ctx, ctx);
                ti1 := ((((((BZ + (Mem.Get(ctx + 69) + 256 * (Mem.Get(ctx + 70) + 256 * (Mem.Get(ctx + 71) + 256 * SX8[Mem.Get(ctx + 72) + 1])))) + 512) + B31) mod B32) + B32) mod B32) - B31;
                if ti1 >= 0 then begin
                    Mem.Set(ctx + 69, ti1 mod 256);
                    Mem.Set(ctx + 70, (ti1 div 256) mod 256);
                    Mem.Set(ctx + 71, (ti1 div 65536) mod 256);
                    Mem.Set(ctx + 72, ti1 div 16777216);
                end else begin
                    Mem.Set(ctx + 69, 255 - (-1 - ti1) mod 256);
                    Mem.Set(ctx + 70, 255 - ((-1 - ti1) div 256) mod 256);
                    Mem.Set(ctx + 71, 255 - ((-1 - ti1) div 65536) mod 256);
                    Mem.Set(ctx + 72, 255 - (-1 - ti1) div 16777216);
                end;
                Mem.Set(ctx + 65, 0);
                Mem.Set(ctx + 66, 0);
                Mem.Set(ctx + 67, 0);
                Mem.Set(ctx + 68, 0);
            end;
            ti1 := ((((((BZ + i) + 1) + B31) mod B32) + B32) mod B32) - B31;
            i := ti1;
        end;
    end;
    
    // sha256.c:33
    local procedure transform(ctx: Integer; data: Integer)
    var
        fp_: Integer;
        a: Integer;
        b: Integer;
        c: Integer;
        d: Integer;
        e: Integer;
        f: Integer;
        g: Integer;
        h: Integer;
        i: Integer;
        j: Integer;
        t1: Integer;
        t2: Integer;
        ti1: Integer;
        ti2: Integer;
        ti3: Integer;
        ti4: Integer;
        ti5: Integer;
        ti6: Integer;
        ti7: Integer;
        ti8: Integer;
        ti9: Integer;
        ti10: Integer;
        ti11: Integer;
        ti12: Integer;
        ti13: Integer;
        ti14: Integer;
        ti15: Integer;
        ti16: Integer;
        ti17: Integer;
        ti18: Integer;
        ti19: Integer;
        ti20: Integer;
        ti21: Integer;
        ti22: Integer;
        ti23: Integer;
        ti24: Integer;
        ti25: Integer;
        ti26: Integer;
        ti27: Integer;
        ti28: Integer;
        ti29: Integer;
        ti30: Integer;
        ti31: Integer;
        ti32: Integer;
        ti33: Integer;
        ti34: Integer;
        ti35: Integer;
        ti36: Integer;
        ti37: Integer;
        ti38: Integer;
    begin
        fp_ := SP - 256;
        SP := fp_;
        i := 0;
        j := 0;
        while (i >= 0) and (i < 16) do begin
            ti2 := ((((((BZ + Mem.Get((data + j) + 1)) * 16777216) + B31) mod B32) + B32) mod B32) - B31;
            ti1 := ((((((BZ + j) + 1) + B31) mod B32) + B32) mod B32) - B31;
            ti3 := ((((((BZ + j) + 2) + B31) mod B32) + B32) mod B32) - B31;
            ti4 := ((((((BZ + j) + 3) + B31) mod B32) + B32) mod B32) - B31;
            ti5 := fp_ + (i * 4);
            ti6 := Rt_Or(Rt_Or(Rt_Or(ti2, Mem.Get((data + ti1) + 1) * 65536), Mem.Get((data + ti3) + 1) * 256), Mem.Get((data + ti4) + 1));
            if ti6 >= 0 then begin
                Mem.Set(ti5 + 1, ti6 mod 256);
                Mem.Set(ti5 + 2, (ti6 div 256) mod 256);
                Mem.Set(ti5 + 3, (ti6 div 65536) mod 256);
                Mem.Set(ti5 + 4, ti6 div 16777216);
            end else begin
                Mem.Set(ti5 + 1, 255 - (-1 - ti6) mod 256);
                Mem.Set(ti5 + 2, 255 - ((-1 - ti6) div 256) mod 256);
                Mem.Set(ti5 + 3, 255 - ((-1 - ti6) div 65536) mod 256);
                Mem.Set(ti5 + 4, 255 - (-1 - ti6) div 16777216);
            end;
            ti1 := ((((((BZ + i) + 1) + B31) mod B32) + B32) mod B32) - B31;
            i := ti1;
            ti2 := ((((((BZ + j) + 4) + B31) mod B32) + B32) mod B32) - B31;
            j := ti2;
        end;
        while (i >= 0) and (i < 64) do begin
            ti6 := ((((((BZ + i) - 2) + B31) mod B32) + B32) mod B32) - B31;
            ti5 := fp_ + (ti6 * 4);
            ti4 := (((BZ + (Mem.Get(ti5 + 1) + 256 * (Mem.Get(ti5 + 2) + 256 * (Mem.Get(ti5 + 3) + 256 * SX8[Mem.Get(ti5 + 4) + 1])))) + B32) mod B32) div 131072;
            ti3 := ((((((BZ + i) - 2) + B31) mod B32) + B32) mod B32) - B31;
            ti1 := fp_ + (ti3 * 4);
            ti2 := ((((((BZ + (Mem.Get(ti1 + 1) + 256 * (Mem.Get(ti1 + 2) + 256 * (Mem.Get(ti1 + 3) + 256 * SX8[Mem.Get(ti1 + 4) + 1])))) * 32768) + B31) mod B32) + B32) mod B32) - B31;
            ti7 := ((((((BZ + i) - 2) + B31) mod B32) + B32) mod B32) - B31;
            ti8 := fp_ + (ti7 * 4);
            ti9 := (((BZ + (Mem.Get(ti8 + 1) + 256 * (Mem.Get(ti8 + 2) + 256 * (Mem.Get(ti8 + 3) + 256 * SX8[Mem.Get(ti8 + 4) + 1])))) + B32) mod B32) div 524288;
            ti10 := ((((((BZ + i) - 2) + B31) mod B32) + B32) mod B32) - B31;
            ti11 := fp_ + (ti10 * 4);
            ti12 := ((((((BZ + (Mem.Get(ti11 + 1) + 256 * (Mem.Get(ti11 + 2) + 256 * (Mem.Get(ti11 + 3) + 256 * SX8[Mem.Get(ti11 + 4) + 1])))) * 8192) + B31) mod B32) + B32) mod B32) - B31;
            ti13 := ((((((BZ + i) - 2) + B31) mod B32) + B32) mod B32) - B31;
            ti14 := fp_ + (ti13 * 4);
            ti15 := (((BZ + (Mem.Get(ti14 + 1) + 256 * (Mem.Get(ti14 + 2) + 256 * (Mem.Get(ti14 + 3) + 256 * SX8[Mem.Get(ti14 + 4) + 1])))) + B32) mod B32) div 1024;
            ti16 := ((((((BZ + i) - 7) + B31) mod B32) + B32) mod B32) - B31;
            ti17 := fp_ + (ti16 * 4);
            ti18 := ((((((BZ + Rt_Xor(Rt_Xor(Rt_Or(ti4, ti2), Rt_Or(ti9, ti12)), ti15)) + (Mem.Get(ti17 + 1) + 256 * (Mem.Get(ti17 + 2) + 256 * (Mem.Get(ti17 + 3) + 256 * SX8[Mem.Get(ti17 + 4) + 1])))) + B31) mod B32) + B32) mod B32) - B31;
            ti19 := ((((((BZ + i) - 15) + B31) mod B32) + B32) mod B32) - B31;
            ti20 := fp_ + (ti19 * 4);
            ti21 := (((BZ + (Mem.Get(ti20 + 1) + 256 * (Mem.Get(ti20 + 2) + 256 * (Mem.Get(ti20 + 3) + 256 * SX8[Mem.Get(ti20 + 4) + 1])))) + B32) mod B32) div 128;
            ti22 := ((((((BZ + i) - 15) + B31) mod B32) + B32) mod B32) - B31;
            ti23 := fp_ + (ti22 * 4);
            ti24 := ((((((BZ + (Mem.Get(ti23 + 1) + 256 * (Mem.Get(ti23 + 2) + 256 * (Mem.Get(ti23 + 3) + 256 * SX8[Mem.Get(ti23 + 4) + 1])))) * 33554432) + B31) mod B32) + B32) mod B32) - B31;
            ti25 := ((((((BZ + i) - 15) + B31) mod B32) + B32) mod B32) - B31;
            ti26 := fp_ + (ti25 * 4);
            ti27 := (((BZ + (Mem.Get(ti26 + 1) + 256 * (Mem.Get(ti26 + 2) + 256 * (Mem.Get(ti26 + 3) + 256 * SX8[Mem.Get(ti26 + 4) + 1])))) + B32) mod B32) div 262144;
            ti28 := ((((((BZ + i) - 15) + B31) mod B32) + B32) mod B32) - B31;
            ti29 := fp_ + (ti28 * 4);
            ti30 := ((((((BZ + (Mem.Get(ti29 + 1) + 256 * (Mem.Get(ti29 + 2) + 256 * (Mem.Get(ti29 + 3) + 256 * SX8[Mem.Get(ti29 + 4) + 1])))) * 16384) + B31) mod B32) + B32) mod B32) - B31;
            ti31 := ((((((BZ + i) - 15) + B31) mod B32) + B32) mod B32) - B31;
            ti32 := fp_ + (ti31 * 4);
            ti33 := (((BZ + (Mem.Get(ti32 + 1) + 256 * (Mem.Get(ti32 + 2) + 256 * (Mem.Get(ti32 + 3) + 256 * SX8[Mem.Get(ti32 + 4) + 1])))) + B32) mod B32) div 8;
            ti34 := ((((((BZ + ti18) + Rt_Xor(Rt_Xor(Rt_Or(ti21, ti24), Rt_Or(ti27, ti30)), ti33)) + B31) mod B32) + B32) mod B32) - B31;
            ti35 := ((((((BZ + i) - 16) + B31) mod B32) + B32) mod B32) - B31;
            ti36 := fp_ + (ti35 * 4);
            ti37 := ((((((BZ + ti34) + (Mem.Get(ti36 + 1) + 256 * (Mem.Get(ti36 + 2) + 256 * (Mem.Get(ti36 + 3) + 256 * SX8[Mem.Get(ti36 + 4) + 1])))) + B31) mod B32) + B32) mod B32) - B31;
            ti38 := fp_ + (i * 4);
            if ti37 >= 0 then begin
                Mem.Set(ti38 + 1, ti37 mod 256);
                Mem.Set(ti38 + 2, (ti37 div 256) mod 256);
                Mem.Set(ti38 + 3, (ti37 div 65536) mod 256);
                Mem.Set(ti38 + 4, ti37 div 16777216);
            end else begin
                Mem.Set(ti38 + 1, 255 - (-1 - ti37) mod 256);
                Mem.Set(ti38 + 2, 255 - ((-1 - ti37) div 256) mod 256);
                Mem.Set(ti38 + 3, 255 - ((-1 - ti37) div 65536) mod 256);
                Mem.Set(ti38 + 4, 255 - (-1 - ti37) div 16777216);
            end;
            ti6 := ((((((BZ + i) + 1) + B31) mod B32) + B32) mod B32) - B31;
            i := ti6;
        end;
        a := (Mem.Get(ctx + 73) + 256 * (Mem.Get(ctx + 74) + 256 * (Mem.Get(ctx + 75) + 256 * SX8[Mem.Get(ctx + 76) + 1])));
        b := (Mem.Get(ctx + 77) + 256 * (Mem.Get(ctx + 78) + 256 * (Mem.Get(ctx + 79) + 256 * SX8[Mem.Get(ctx + 80) + 1])));
        c := (Mem.Get(ctx + 81) + 256 * (Mem.Get(ctx + 82) + 256 * (Mem.Get(ctx + 83) + 256 * SX8[Mem.Get(ctx + 84) + 1])));
        d := (Mem.Get(ctx + 85) + 256 * (Mem.Get(ctx + 86) + 256 * (Mem.Get(ctx + 87) + 256 * SX8[Mem.Get(ctx + 88) + 1])));
        e := (Mem.Get(ctx + 89) + 256 * (Mem.Get(ctx + 90) + 256 * (Mem.Get(ctx + 91) + 256 * SX8[Mem.Get(ctx + 92) + 1])));
        f := (Mem.Get(ctx + 93) + 256 * (Mem.Get(ctx + 94) + 256 * (Mem.Get(ctx + 95) + 256 * SX8[Mem.Get(ctx + 96) + 1])));
        g := (Mem.Get(ctx + 97) + 256 * (Mem.Get(ctx + 98) + 256 * (Mem.Get(ctx + 99) + 256 * SX8[Mem.Get(ctx + 100) + 1])));
        h := (Mem.Get(ctx + 101) + 256 * (Mem.Get(ctx + 102) + 256 * (Mem.Get(ctx + 103) + 256 * SX8[Mem.Get(ctx + 104) + 1])));
        i := 0;
        while (i >= 0) and (i < 64) do begin
            ti38 := (((BZ + e) + B32) mod B32) div 64;
            ti37 := ((((((BZ + e) * 67108864) + B31) mod B32) + B32) mod B32) - B31;
            ti36 := (((BZ + e) + B32) mod B32) div 2048;
            ti35 := ((((((BZ + e) * 2097152) + B31) mod B32) + B32) mod B32) - B31;
            ti34 := (((BZ + e) + B32) mod B32) div 33554432;
            ti33 := ((((((BZ + e) * 128) + B31) mod B32) + B32) mod B32) - B31;
            ti32 := ((((((BZ + h) + Rt_Xor(Rt_Xor(Rt_Or(ti38, ti37), Rt_Or(ti36, ti35)), Rt_Or(ti34, ti33))) + B31) mod B32) + B32) mod B32) - B31;
            ti31 := ((((((BZ + ti32) + Rt_Xor(Rt_And(e, f), Rt_And((-1) - e, g))) + B31) mod B32) + B32) mod B32) - B31;
            ti30 := (i * 4) + 4096;
            ti29 := ((((((BZ + ti31) + (Mem.Get(ti30 + 1) + 256 * (Mem.Get(ti30 + 2) + 256 * (Mem.Get(ti30 + 3) + 256 * SX8[Mem.Get(ti30 + 4) + 1])))) + B31) mod B32) + B32) mod B32) - B31;
            ti28 := fp_ + (i * 4);
            ti27 := ((((((BZ + ti29) + (Mem.Get(ti28 + 1) + 256 * (Mem.Get(ti28 + 2) + 256 * (Mem.Get(ti28 + 3) + 256 * SX8[Mem.Get(ti28 + 4) + 1])))) + B31) mod B32) + B32) mod B32) - B31;
            t1 := ti27;
            ti27 := (((BZ + a) + B32) mod B32) div 4;
            ti28 := ((((((BZ + a) * 1073741824) + B31) mod B32) + B32) mod B32) - B31;
            ti29 := (((BZ + a) + B32) mod B32) div 8192;
            ti30 := ((((((BZ + a) * 524288) + B31) mod B32) + B32) mod B32) - B31;
            ti31 := (((BZ + a) + B32) mod B32) div 4194304;
            ti32 := ((((((BZ + a) * 1024) + B31) mod B32) + B32) mod B32) - B31;
            ti33 := ((((((BZ + Rt_Xor(Rt_Xor(Rt_Or(ti27, ti28), Rt_Or(ti29, ti30)), Rt_Or(ti31, ti32))) + Rt_Xor(Rt_Xor(Rt_And(a, b), Rt_And(a, c)), Rt_And(b, c))) + B31) mod B32) + B32) mod B32) - B31;
            t2 := ti33;
            h := g;
            g := f;
            f := e;
            ti33 := ((((((BZ + d) + t1) + B31) mod B32) + B32) mod B32) - B31;
            e := ti33;
            d := c;
            c := b;
            b := a;
            ti33 := ((((((BZ + t1) + t2) + B31) mod B32) + B32) mod B32) - B31;
            a := ti33;
            ti38 := ((((((BZ + i) + 1) + B31) mod B32) + B32) mod B32) - B31;
            i := ti38;
        end;
        ti33 := ((((((BZ + (Mem.Get(ctx + 73) + 256 * (Mem.Get(ctx + 74) + 256 * (Mem.Get(ctx + 75) + 256 * SX8[Mem.Get(ctx + 76) + 1])))) + a) + B31) mod B32) + B32) mod B32) - B31;
        if ti33 >= 0 then begin
            Mem.Set(ctx + 73, ti33 mod 256);
            Mem.Set(ctx + 74, (ti33 div 256) mod 256);
            Mem.Set(ctx + 75, (ti33 div 65536) mod 256);
            Mem.Set(ctx + 76, ti33 div 16777216);
        end else begin
            Mem.Set(ctx + 73, 255 - (-1 - ti33) mod 256);
            Mem.Set(ctx + 74, 255 - ((-1 - ti33) div 256) mod 256);
            Mem.Set(ctx + 75, 255 - ((-1 - ti33) div 65536) mod 256);
            Mem.Set(ctx + 76, 255 - (-1 - ti33) div 16777216);
        end;
        ti33 := ((((((BZ + (Mem.Get(ctx + 77) + 256 * (Mem.Get(ctx + 78) + 256 * (Mem.Get(ctx + 79) + 256 * SX8[Mem.Get(ctx + 80) + 1])))) + b) + B31) mod B32) + B32) mod B32) - B31;
        if ti33 >= 0 then begin
            Mem.Set(ctx + 77, ti33 mod 256);
            Mem.Set(ctx + 78, (ti33 div 256) mod 256);
            Mem.Set(ctx + 79, (ti33 div 65536) mod 256);
            Mem.Set(ctx + 80, ti33 div 16777216);
        end else begin
            Mem.Set(ctx + 77, 255 - (-1 - ti33) mod 256);
            Mem.Set(ctx + 78, 255 - ((-1 - ti33) div 256) mod 256);
            Mem.Set(ctx + 79, 255 - ((-1 - ti33) div 65536) mod 256);
            Mem.Set(ctx + 80, 255 - (-1 - ti33) div 16777216);
        end;
        ti33 := ((((((BZ + (Mem.Get(ctx + 81) + 256 * (Mem.Get(ctx + 82) + 256 * (Mem.Get(ctx + 83) + 256 * SX8[Mem.Get(ctx + 84) + 1])))) + c) + B31) mod B32) + B32) mod B32) - B31;
        if ti33 >= 0 then begin
            Mem.Set(ctx + 81, ti33 mod 256);
            Mem.Set(ctx + 82, (ti33 div 256) mod 256);
            Mem.Set(ctx + 83, (ti33 div 65536) mod 256);
            Mem.Set(ctx + 84, ti33 div 16777216);
        end else begin
            Mem.Set(ctx + 81, 255 - (-1 - ti33) mod 256);
            Mem.Set(ctx + 82, 255 - ((-1 - ti33) div 256) mod 256);
            Mem.Set(ctx + 83, 255 - ((-1 - ti33) div 65536) mod 256);
            Mem.Set(ctx + 84, 255 - (-1 - ti33) div 16777216);
        end;
        ti33 := ((((((BZ + (Mem.Get(ctx + 85) + 256 * (Mem.Get(ctx + 86) + 256 * (Mem.Get(ctx + 87) + 256 * SX8[Mem.Get(ctx + 88) + 1])))) + d) + B31) mod B32) + B32) mod B32) - B31;
        if ti33 >= 0 then begin
            Mem.Set(ctx + 85, ti33 mod 256);
            Mem.Set(ctx + 86, (ti33 div 256) mod 256);
            Mem.Set(ctx + 87, (ti33 div 65536) mod 256);
            Mem.Set(ctx + 88, ti33 div 16777216);
        end else begin
            Mem.Set(ctx + 85, 255 - (-1 - ti33) mod 256);
            Mem.Set(ctx + 86, 255 - ((-1 - ti33) div 256) mod 256);
            Mem.Set(ctx + 87, 255 - ((-1 - ti33) div 65536) mod 256);
            Mem.Set(ctx + 88, 255 - (-1 - ti33) div 16777216);
        end;
        ti33 := ((((((BZ + (Mem.Get(ctx + 89) + 256 * (Mem.Get(ctx + 90) + 256 * (Mem.Get(ctx + 91) + 256 * SX8[Mem.Get(ctx + 92) + 1])))) + e) + B31) mod B32) + B32) mod B32) - B31;
        if ti33 >= 0 then begin
            Mem.Set(ctx + 89, ti33 mod 256);
            Mem.Set(ctx + 90, (ti33 div 256) mod 256);
            Mem.Set(ctx + 91, (ti33 div 65536) mod 256);
            Mem.Set(ctx + 92, ti33 div 16777216);
        end else begin
            Mem.Set(ctx + 89, 255 - (-1 - ti33) mod 256);
            Mem.Set(ctx + 90, 255 - ((-1 - ti33) div 256) mod 256);
            Mem.Set(ctx + 91, 255 - ((-1 - ti33) div 65536) mod 256);
            Mem.Set(ctx + 92, 255 - (-1 - ti33) div 16777216);
        end;
        ti33 := ((((((BZ + (Mem.Get(ctx + 93) + 256 * (Mem.Get(ctx + 94) + 256 * (Mem.Get(ctx + 95) + 256 * SX8[Mem.Get(ctx + 96) + 1])))) + f) + B31) mod B32) + B32) mod B32) - B31;
        if ti33 >= 0 then begin
            Mem.Set(ctx + 93, ti33 mod 256);
            Mem.Set(ctx + 94, (ti33 div 256) mod 256);
            Mem.Set(ctx + 95, (ti33 div 65536) mod 256);
            Mem.Set(ctx + 96, ti33 div 16777216);
        end else begin
            Mem.Set(ctx + 93, 255 - (-1 - ti33) mod 256);
            Mem.Set(ctx + 94, 255 - ((-1 - ti33) div 256) mod 256);
            Mem.Set(ctx + 95, 255 - ((-1 - ti33) div 65536) mod 256);
            Mem.Set(ctx + 96, 255 - (-1 - ti33) div 16777216);
        end;
        ti33 := ((((((BZ + (Mem.Get(ctx + 97) + 256 * (Mem.Get(ctx + 98) + 256 * (Mem.Get(ctx + 99) + 256 * SX8[Mem.Get(ctx + 100) + 1])))) + g) + B31) mod B32) + B32) mod B32) - B31;
        if ti33 >= 0 then begin
            Mem.Set(ctx + 97, ti33 mod 256);
            Mem.Set(ctx + 98, (ti33 div 256) mod 256);
            Mem.Set(ctx + 99, (ti33 div 65536) mod 256);
            Mem.Set(ctx + 100, ti33 div 16777216);
        end else begin
            Mem.Set(ctx + 97, 255 - (-1 - ti33) mod 256);
            Mem.Set(ctx + 98, 255 - ((-1 - ti33) div 256) mod 256);
            Mem.Set(ctx + 99, 255 - ((-1 - ti33) div 65536) mod 256);
            Mem.Set(ctx + 100, 255 - (-1 - ti33) div 16777216);
        end;
        ti33 := ((((((BZ + (Mem.Get(ctx + 101) + 256 * (Mem.Get(ctx + 102) + 256 * (Mem.Get(ctx + 103) + 256 * SX8[Mem.Get(ctx + 104) + 1])))) + h) + B31) mod B32) + B32) mod B32) - B31;
        if ti33 >= 0 then begin
            Mem.Set(ctx + 101, ti33 mod 256);
            Mem.Set(ctx + 102, (ti33 div 256) mod 256);
            Mem.Set(ctx + 103, (ti33 div 65536) mod 256);
            Mem.Set(ctx + 104, ti33 div 16777216);
        end else begin
            Mem.Set(ctx + 101, 255 - (-1 - ti33) mod 256);
            Mem.Set(ctx + 102, 255 - ((-1 - ti33) div 256) mod 256);
            Mem.Set(ctx + 103, 255 - ((-1 - ti33) div 65536) mod 256);
            Mem.Set(ctx + 104, 255 - (-1 - ti33) div 16777216);
        end;
        SP := fp_ + 256;
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
        D.Append('982F8A4291443771CFFBC0B5A5DBB5E95BC25639F111F159A4823F92D55E1CAB98AA07D8015B8312BE853124C37D0C55745DBE72FEB1DE80A706DC9B74F19BC1C1699BE48647BEEFC69DC10FCCA10C246F2CE92DAA84744ADCA9B05CDA88F97652513E986DC631A8C82703B0C77F59BFF30BE0C64791A7D55163CA0667292914850AB72738211B2EFC6D2C4D130D385354730A65BB0A6A762EC9C281852C7292A1E8BFA24B661AA8708B4BC2A3516CC719E892D1240699D685350EF470A06A1016C1A419086C371E4C774827B5BCB034B30C1C394AAAD84E4FCA9C5BF36F2E68EE828F746F63A5781478C8840802C78CFAFFBE90EB6C50A4F7A3F9BEF27871C6Z00443031323334353637383961626364656600');
    end;
}
