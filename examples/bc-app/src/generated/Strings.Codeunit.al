// c2al example 02: strings
// Translated from C to AL by c2al - do not edit by hand.
// C memory is emulated by the Mem list (one element per byte), C pointers are indexes into Mem.
// Call Initialize() once before calling any of the C functions.
codeunit 50102 "C2AL Strings"
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

        SP := 69744;
        Heap := 69760;
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
    
    // c2al.h:100
    local procedure atoi(s: Integer): Integer
    var
        v: Integer;
        neg: Integer;
        ti1: Integer;
    begin
        v := 0;
        neg := 0;
        while c2al_isspace(SX8[Mem.Get(s + 1) + 1]) <> 0 do begin
            s := s + 1;
        end;
        if (SX8[Mem.Get(s + 1) + 1] = 45) or (SX8[Mem.Get(s + 1) + 1] = 43) then begin
            ti1 := s;
            s := ti1 + 1;
            neg := B2I(SX8[Mem.Get(ti1 + 1) + 1] = 45);
        end;
        while c2al_isdigit(SX8[Mem.Get(s + 1) + 1]) <> 0 do begin
            ti1 := s;
            s := ti1 + 1;
            v := (v * 10) + (SX8[Mem.Get(ti1 + 1) + 1] - 48);
        end;
        if neg <> 0 then begin
            ti1 := -v;
        end else begin
            ti1 := v;
        end;
        exit(ti1);
    end;
    
    // c2al.h:95
    local procedure c2al_isdigit(c: Integer): Integer
    begin
        exit(B2I((c >= 48) and (c <= 57)));
    end;
    
    // c2al.h:96
    local procedure c2al_isspace(c: Integer): Integer
    begin
        exit(B2I((((c = 32) or (c = 9)) or (c = 10)) or (c = 13)));
    end;
    
    // strings.c:94
    procedure compare(a: Integer; b: Integer): Integer
    var
        r: Integer;
        ti1: Integer;
        ti2: Integer;
    begin
        r := strcmp(a, b);
        if r < 0 then begin
            ti2 := (-1);
        end else begin
            if r > 0 then begin
                ti1 := 1;
            end else begin
                ti1 := 0;
            end;
            ti2 := ti1;
        end;
        exit(ti2);
    end;
    
    // strings.c:27
    procedure count_words(s: Integer): Integer
    var
        n: Integer;
        in_word: Integer;
    begin
        n := 0;
        in_word := 0;
        while SX8[Mem.Get(s + 1) + 1] <> 0 do begin
            if c2al_isspace(SX8[Mem.Get(s + 1) + 1]) <> 0 then begin
                in_word := 0;
            end else begin
                if in_word = 0 then begin
                    in_word := 1;
                    n := n + 1;
                end;
            end;
            s := s + 1;
        end;
        exit(n);
    end;
    
    // strings.c:85
    procedure greet(name: Integer): Integer
    var
        r: Integer;
    begin
        r := c2al_malloc(Rt_StrLen(name) + 9);
        strcpy(r, 4197);
        strcat(r, name);
        strcat(r, 4205);
        exit(r);
    end;
    
    // strings.c:56
    procedure int_to_text(v: Integer): Integer
    var
        fp_: Integer;
        n: Integer;
        neg: Integer;
        u: Integer;
        ti1: Integer;
        ti2: Integer;
        ti3: Integer;
        p: Integer;
    begin
        fp_ := SP - 16;
        SP := fp_;
        n := 0;
        neg := B2I(v < 0);
        if neg <> 0 then begin
            ti1 := ((((((BZ + 0) - v) + B31) mod B32) + B32) mod B32) - B31;
            ti2 := ti1;
        end else begin
            ti2 := v;
        end;
        u := ti2;
        repeat
            ti2 := n;
            n := ti2 + 1;
            ti1 := ((((((BZ + 48) + Rt_UMod(u, 10)) + B31) mod B32) + B32) mod B32) - B31;
            ti3 := fp_ + ti2;
            Mem.Set(ti3 + 1, ((((((ti1 mod 256) + 384) mod 256) - 128) mod 256) + 256) mod 256);
            u := Rt_UDiv(u, 10);
        until u = 0;
        p := 4096;
        if neg <> 0 then begin
            ti3 := p;
            p := ti3 + 1;
            Mem.Set(ti3 + 1, 45);
        end;
        while n <> 0 do begin
            ti3 := p;
            p := ti3 + 1;
            n := n + (-1);
            Mem.Set(ti3 + 1, ((SX8[Mem.Get((fp_ + n) + 1) + 1] mod 256) + 256) mod 256);
        end;
        Mem.Set(p + 1, 0);
        SP := fp_ + 16;
        exit(4096);
    end;
    
    // strings.c:41
    procedure is_palindrome(s: Integer): Integer
    var
        i: Integer;
        j: Integer;
    begin
        i := 0;
        j := Rt_StrLen(s) - 1;
        while i < j do begin
            if SX8[Mem.Get((s + i) + 1) + 1] <> SX8[Mem.Get((s + j) + 1) + 1] then begin
                exit(0);
            end;
            i := i + 1;
            j := j + (-1);
        end;
        exit(1);
    end;
    
    // strings.c:74
    procedure parse_int(s: Integer): Integer
    var
        ti1: Integer;
    begin
        ti1 := atoi(s);
        exit(ti1);
    end;
    
    // strings.c:7
    procedure reverse(s: Integer): Integer
    var
        a: Integer;
        b: Integer;
        t: Integer;
        ti1: Integer;
    begin
        a := s;
        b := (s + Rt_StrLen(s)) - 1;
        while a < b do begin
            t := SX8[Mem.Get(a + 1) + 1];
            ti1 := a;
            a := ti1 + 1;
            Mem.Set(ti1 + 1, ((SX8[Mem.Get(b + 1) + 1] mod 256) + 256) mod 256);
            ti1 := b;
            b := ti1 - 1;
            Mem.Set(ti1 + 1, ((((((t mod 256) + 384) mod 256) - 128) mod 256) + 256) mod 256);
        end;
        exit(s);
    end;
    
    // c2al.h:73
    local procedure strcat(dst: Integer; src: Integer): Integer
    begin
        strcpy(dst + Rt_StrLen(dst), src);
        exit(dst);
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
    
    // c2al.h:66
    local procedure strcpy(dst: Integer; src: Integer): Integer
    var
        d: Integer;
        ti1: Integer;
        ti2: Integer;
        ti3: Integer;
    begin
        d := dst;
        while true do begin
            ti1 := d;
            d := ti1 + 1;
            ti2 := src;
            src := ti2 + 1;
            ti3 := SX8[Mem.Get(ti2 + 1) + 1];
            Mem.Set(ti1 + 1, ((ti3 mod 256) + 256) mod 256);
            if ti3 = 0 then begin
                break;
            end;
        end;
        exit(dst);
    end;
    
    // strings.c:19
    procedure to_upper(s: Integer): Integer
    var
        p: Integer;
    begin
        p := s;
        while SX8[Mem.Get(p + 1) + 1] <> 0 do begin
            if (SX8[Mem.Get(p + 1) + 1] >= 97) and (SX8[Mem.Get(p + 1) + 1] <= 122) then begin
                Mem.Set(p + 1, ((((((((SX8[Mem.Get(p + 1) + 1] - 97) + 65) mod 256) + 384) mod 256) - 128) mod 256) + 256) mod 256);
            end;
            p := p + 1;
        end;
        exit(s);
    end;
    
    // strings.c:79
    procedure weekday(i: Integer): Integer
    var
        ti1: Integer;
    begin
        ti1 := ((i mod 7) * 4) + 4112;
        exit((Mem.Get(ti1 + 1) + 256 * (Mem.Get(ti1 + 2) + 256 * (Mem.Get(ti1 + 3) + 256 * SX8[Mem.Get(ti1 + 4) + 1]))));
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
        D.Append('Z00102C100000331000003B100000451000004E100000551000005E1000004D6F6E6461790054756573646179005765646E6573646179005468757273646179004672696461790053617475726461790053756E6461790048656C6C6F2C20002100');
    end;
}
