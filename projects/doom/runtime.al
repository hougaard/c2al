        // ---- runtime state (hand written) ----
        Heap: Integer;
        VirtualTimeMs: Integer;
        Initialized: Boolean;
        LogText: TextBuilder;
        LumpSizes: List of [Integer];
        LumpNames: List of [Text];
        LumpsLoaded: Boolean;
        B64Pair: array[4096] of Text[2];
        B64Chars: Text[64];
        LastPalette: Text;
        AndTab: array[65536] of Integer;
        OrTab: array[65536] of Integer;
        XorTab: array[65536] of Integer;
        BitTabsReady: Boolean;
        PrevFrame: array[64000] of Integer;
        SoundEvents: TextBuilder;
        MusicLump: Integer;
        MusicLooping: Integer;
        MusicPaused: Boolean;
        MusicVolume: Integer;
        // files (one open file at a time): save games and the config file
        GameWad: Text;
        SaveGame: Record "DOOM Save Game";
        UserSettings: Record "DOOM Settings";
        FileKind: Integer;
        QuitPending: Boolean;
        FileWriting: Boolean;
        FileSlot: Integer;
        FilePos: Integer;
        FileSize: Integer;
        FileStreamPos: Integer;
        FileIn: InStream;
        FileOut: OutStream;
        FileWriteBlob: Codeunit "Temp Blob";
        FileHeader: array[43] of Integer;

    // =====================================================================
    //  Host API - called by the DOOM page
    // =====================================================================

    /// <summary>The game (WAD file) that save games are stored for. Call before Initialize.</summary>
    procedure SetGame(WadFile: Text)
    begin
        GameWad := WadFile;
    end;

    /// <summary>True when the player quit DOOM from the menu: the page should close.</summary>
    procedure IsQuitRequested(): Boolean
    begin
        exit(QuitPending);
    end;

    /// <summary>Starts DOOM. The WAD lumps must already be imported into table "DOOM WAD Lump".</summary>
    procedure Initialize()
    begin
        if Initialized then
            exit;
        InitRuntime();
        InitData();
        InitGlobals();
        bc_doom_init();
        Initialized := true;
    end;

    procedure IsInitialized(): Boolean
    begin
        exit(Initialized);
    end;

    /// <summary>Advances DOOM by the given wall clock time and runs the game/renderer.</summary>
    procedure Tick(ElapsedMs: Integer)
    begin
        if ElapsedMs < 0 then
            ElapsedMs := 0;
        VirtualTimeMs += ElapsedMs;
        bc_doom_frame();
    end;

    /// <summary>Game tics that were built from input but have not been run yet (DOOM's own input lag).</summary>
    procedure GetTicLag(): Integer
    begin
        exit(bc_tic_lag());
    end;

    procedure KeyDown(DoomKey: Integer)
    begin
        doom_key_down(DoomKey);
    end;

    procedure KeyUp(DoomKey: Integer)
    begin
        doom_key_up(DoomKey);
    end;

    procedure MouseButtonDown(Button: Integer)
    begin
        doom_button_down(Button);
    end;

    procedure MouseButtonUp(Button: Integer)
    begin
        doom_button_up(Button);
    end;

    procedure MouseMove(DeltaX: Integer; DeltaY: Integer)
    begin
        doom_mouse_move(DeltaX, DeltaY);
    end;

    /// <summary>The 320x200 frame as palette indices, base64 encoded.</summary>
    procedure GetFrame(): Text
    begin
        exit(EncodeBase64(bc_get_screen(), 64000));
    end;

    /// <summary>
    /// The rows of the 320x200 frame that changed since the previous call, base64 encoded.
    /// Each changed row is 321 bytes: the row number followed by 320 palette indexes.
    /// </summary>
    procedure GetFrameDelta(): Text
    var
        TB: TextBuilder;
        Row: array[321] of Integer;
        Scr: Integer;
        y: Integer;
        x: Integer;
        i: Integer;
        v: Integer;
        Base: Integer;
        Changed: Boolean;
    begin
        Scr := bc_get_screen();
        for y := 0 to 199 do begin
            Base := y * 320;
            Changed := false;
            for x := 1 to 320 do begin
                v := Mem.Get(Scr + Base + x);
                Row[x + 1] := v;
                if v <> PrevFrame[Base + x] then
                    Changed := true;
            end;
            if Changed then begin
                Row[1] := y;
                i := 1;
                while i <= 321 do begin
                    v := Row[i] * 65536 + Row[i + 1] * 256 + Row[i + 2];
                    TB.Append(B64Pair[v div 4096 + 1]);
                    TB.Append(B64Pair[v mod 4096 + 1]);
                    i += 3;
                end;
                for x := 1 to 320 do
                    PrevFrame[Base + x] := Row[x + 1];
            end;
        end;
        exit(TB.ToText());
    end;

    /// <summary>Makes the next GetFrameDelta / GetPaletteIfChanged send everything (e.g. after the screen was reloaded).</summary>
    procedure ResetFrameDelta()
    var
        i: Integer;
    begin
        for i := 1 to 64000 do
            PrevFrame[i] := -1;
        LastPalette := '';
    end;

    /// <summary>The 256 color palette (RGB), base64 encoded.</summary>
    procedure GetPalette(): Text
    begin
        exit(EncodeBase64(bc_get_palette(), 768));
    end;

    /// <summary>Returns the palette only when it changed since the last call, otherwise empty text.</summary>
    procedure GetPaletteIfChanged(): Text
    var
        Pal: Text;
    begin
        Pal := GetPalette();
        if Pal = LastPalette then
            exit('');
        LastPalette := Pal;
        exit(Pal);
    end;

    /// <summary>Times the basic operations the translated code is made of (for performance tuning).</summary>
    procedure RunBenchmark(): Text
    var
        Arr: array[100000] of Integer;
        Start: DateTime;
        i: Integer;
        j: Integer;
        s: Integer;
        b: BigInteger;
        Result: TextBuilder;
    begin
        Start := CurrentDateTime;
        for j := 1 to 10 do
            for i := 1 to 100000 do
                s := Mem.Get(i);
        Result.Append(StrSubstNo('1M Mem.Get %1', CurrentDateTime - Start));
        Start := CurrentDateTime;
        // writes back what is already there: must not change DOOM's memory
        for j := 1 to 10 do
            for i := 1 to 100000 do
                Mem.Set(i, Mem.Get(i));
        Result.Append(StrSubstNo(' | 1M Mem.Get+Set %1', CurrentDateTime - Start));
        Start := CurrentDateTime;
        for j := 1 to 10 do
            for i := 1 to 100000 do
                s := Arr[i];
        Result.Append(StrSubstNo(' | 1M array read %1', CurrentDateTime - Start));
        Start := CurrentDateTime;
        for j := 1 to 10 do
            for i := 1 to 100000 do
                Arr[i] := s;
        Result.Append(StrSubstNo(' | 1M array write %1', CurrentDateTime - Start));
        Start := CurrentDateTime;
        for j := 1 to 10 do
            for i := 1 to 100000 do
                s := ((i mod 8388608) + 8388608) mod 8388608 div 65536;
        Result.Append(StrSubstNo(' | 1M mod/div expr %1', CurrentDateTime - Start));
        Start := CurrentDateTime;
        for i := 1 to 100000 do
            s := B2I(i > 5);
        Result.Append(StrSubstNo(' | 100k calls %1', CurrentDateTime - Start));
        Start := CurrentDateTime;
        for i := 1 to 100000 do
            s := Rt_FixedMul(i, 65536 + i);
        Result.Append(StrSubstNo(' | 100k FixedMul %1', CurrentDateTime - Start));
        Start := CurrentDateTime;
        for j := 1 to 10 do
            for i := 1 to 100000 do
                b := (BZ + i) * 3;
        Result.Append(StrSubstNo(' | 1M BigInteger mul %1', CurrentDateTime - Start));
        Start := CurrentDateTime;
        for j := 1 to 10 do
            for i := 1 to 100000 do begin
            end;
        Result.Append(StrSubstNo(' | 1M empty loop %1', CurrentDateTime - Start));
        exit(Result.ToText());
    end;

    procedure GetLog(): Text
    begin
        exit(LogText.ToText());
    end;

    /// <summary>
    /// The sound events since the previous call, separated by '|':
    /// s,handle,lump,volume,separation,pitch = start | u,handle,volume,separation = changed | x,handle = stop.
    /// Volume is 0..15, separation 0 (left) .. 255 (right), pitch 128 = normal.
    /// Music: m,lump,looping = play the MUS lump | mx = stop | mp = pause | mr = resume | mv,volume = volume 0..15.
    /// </summary>
    procedure GetSoundEvents(): Text
    var
        Events: Text;
    begin
        Events := SoundEvents.ToText();
        Clear(SoundEvents);
        exit(Events);
    end;

    /// <summary>The music that should be playing now, as sound events (for a screen that was just loaded).</summary>
    procedure GetMusicState(): Text
    var
        State: Text;
    begin
        State := 'mv,' + Format(MusicVolume, 0, 9);
        if MusicLump > 0 then begin
            State += '|m,' + Format(MusicLump, 0, 9) + ',' + Format(MusicLooping, 0, 9);
            if MusicPaused then
                State += '|mp';
        end;
        exit(State);
    end;

    // =====================================================================
    //  Runtime
    // =====================================================================

    local procedure InitRuntime()
    var
        Zeros: List of [Integer];
        i: Integer;
        v: Integer;
    begin
        Clear(Mem);
        for i := 1 to 4096 do
            Zeros.Add(0);
        for i := 1 to (%MEMSIZE% div 4096) do
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
        // %BIGCONSTS%
        SP := %STACKTOP%;
        Heap := %HEAPSTART%;
        VirtualTimeMs := 1;
        B64Chars := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        for v := 0 to 4095 do
            B64Pair[v + 1] := CopyStr(B64Chars, v div 64 + 1, 1) + CopyStr(B64Chars, v mod 64 + 1, 1);
    end;

    local procedure DecodeData(D: Text; Addr: Integer)
    var
        i: Integer;
        n: Integer;
        k: Integer;
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

    local procedure EncodeBase64(Addr: Integer; Len: Integer): Text
    var
        TB: TextBuilder;
        i: Integer;
        v: Integer;
        Full: Integer;
    begin
        Full := Len div 3 * 3;
        i := Addr + 1;
        while i <= Addr + Full do begin
            v := Mem.Get(i) * 65536 + Mem.Get(i + 1) * 256 + Mem.Get(i + 2);
            TB.Append(B64Pair[v div 4096 + 1]);
            TB.Append(B64Pair[v mod 4096 + 1]);
            i += 3;
        end;
        case Len - Full of
            1:
                begin
                    v := Mem.Get(i) * 65536;
                    TB.Append(B64Pair[v div 4096 + 1]);
                    TB.Append('==');
                end;
            2:
                begin
                    v := Mem.Get(i) * 65536 + Mem.Get(i + 1) * 256;
                    TB.Append(B64Pair[v div 4096 + 1]);
                    TB.Append(CopyStr(B64Pair[v mod 4096 + 1], 1, 1) + '=');
                end;
        end;
        exit(TB.ToText());
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

    local procedure Rt_MemCpy(Dst: Integer; Src: Integer; Count: Integer): Integer
    var
        i: Integer;
        d: Integer;
    begin
        d := Dst - Src;
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

    // ---- fixed point ------------------------------------------------------

    local procedure Rt_FixedMul(a: Integer; b: Integer): Integer
    var
        p: BigInteger;
    begin
        p := BZ + a;
        p := p * b;
        // arithmetic shift right by 16 (floor division)
        if p >= 0 then
            p := p div 65536
        else
            p := -((-p + 65535) div 65536);
        if (p >= -B31) and (p < B31) then
            exit(p);
        exit(((p + B31) mod B32 + B32) mod B32 - B31);
    end;

    local procedure Rt_FixedDiv(a: Integer; b: Integer): Integer
    var
        aa: BigInteger;
        ab: BigInteger;
        q: BigInteger;
    begin
        aa := BZ + a;
        if aa < 0 then
            aa := -aa;
        ab := BZ + b;
        if ab < 0 then
            ab := -ab;
        if aa div 16384 >= ab then begin
            if (a < 0) <> (b < 0) then
                exit(-2147483647 - 1);
            exit(2147483647);
        end;
        q := BZ + a;
        q := q * 65536;
        q := q div b;
        exit(((q + B31) mod B32 + B32) mod B32 - B31);
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
    //  Natives called by the translated C code
    // =====================================================================

    local procedure bc_print(s: Integer)
    begin
        LogText.Append(CStr(s));
        if LogText.Length > 20000 then
            LogText.Remove(1, LogText.Length - 10000);
    end;

    local procedure bc_exit(code: Integer)
    begin
        if code = 0 then begin
            // quit from the menu (the config file is already stored): the page closes
            QuitPending := true;
            exit;
        end;
        Error('DOOM exited with code %1.\%2', code, CopyStr(LogText.ToText(), MaxInt(1, LogText.Length - 500)));
    end;

    local procedure bc_sound(kind: Integer; handle: Integer; lump: Integer; vol: Integer; sep: Integer; pitch: Integer)
    begin
        if SoundEvents.Length > 0 then
            SoundEvents.Append('|');
        case kind of
            0:
                SoundEvents.Append('s,' + Format(handle, 0, 9) + ',' + Format(lump, 0, 9) + ',' + Format(vol, 0, 9) + ',' + Format(sep, 0, 9) + ',' + Format(pitch, 0, 9));
            1:
                SoundEvents.Append('u,' + Format(handle, 0, 9) + ',' + Format(vol, 0, 9) + ',' + Format(sep, 0, 9));
            2:
                SoundEvents.Append('x,' + Format(handle, 0, 9));
            3:
                begin
                    MusicLump := lump;
                    MusicLooping := pitch;
                    MusicPaused := false;
                    SoundEvents.Append('m,' + Format(lump, 0, 9) + ',' + Format(pitch, 0, 9));
                end;
            4:
                begin
                    MusicLump := 0;
                    SoundEvents.Append('mx');
                end;
            5:
                begin
                    MusicPaused := true;
                    SoundEvents.Append('mp');
                end;
            6:
                begin
                    MusicPaused := false;
                    SoundEvents.Append('mr');
                end;
            7:
                begin
                    MusicVolume := vol;
                    SoundEvents.Append('mv,' + Format(vol, 0, 9));
                end;
        end;
    end;

    local procedure MaxInt(a: Integer; b: Integer): Integer
    begin
        if a > b then
            exit(a);
        exit(b);
    end;

    local procedure bc_malloc(size: Integer): Integer
    var
        a: Integer;
        Zeros: List of [Integer];
        i: Integer;
    begin
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

    local procedure bc_free(p: Integer)
    begin
    end;

    local procedure bc_time_ms(): Integer
    begin
        exit(VirtualTimeMs);
    end;

    local procedure LoadLumpDirectory()
    var
        Lump: Record "DOOM WAD Lump";
    begin
        if LumpsLoaded then
            exit;
        Clear(LumpSizes);
        Clear(LumpNames);
        Lump.SetLoadFields("Lump No.", Name, Size);
        if Lump.FindSet() then
            repeat
                if Lump."Lump No." <> LumpSizes.Count then
                    Error('DOOM: WAD lump table is not contiguous at lump %1.', Lump."Lump No.");
                LumpSizes.Add(Lump.Size);
                LumpNames.Add(Lump.Name);
            until Lump.Next() = 0;
        if LumpSizes.Count = 0 then
            Error('No WAD has been imported. Import doom1.wad first.');
        LumpsLoaded := true;
    end;

    local procedure bc_wad_numlumps(): Integer
    begin
        LoadLumpDirectory();
        exit(LumpSizes.Count);
    end;

    local procedure bc_wad_lumpsize(lump: Integer): Integer
    begin
        LoadLumpDirectory();
        exit(LumpSizes.Get(lump + 1));
    end;

    local procedure bc_wad_lumpname(lump: Integer; dest: Integer)
    var
        Name: Text;
        i: Integer;
        c: Integer;
    begin
        LoadLumpDirectory();
        Name := LumpNames.Get(lump + 1);
        for i := 1 to 8 do begin
            c := 0;
            if i <= StrLen(Name) then
                c := Name[i];
            Mem.Set(dest + i, c);
        end;
    end;

    local procedure bc_wad_readlump(lump: Integer; dest: Integer)
    var
        WadLump: Record "DOOM WAD Lump";
        InS: InStream;
        b: Byte;
        i: Integer;
        n: Integer;
    begin
        WadLump.Get(lump);
        if WadLump.Size = 0 then
            exit;
        WadLump.CalcFields(Data);
        WadLump.Data.CreateInStream(InS);
        n := WadLump.Size;
        for i := dest + 1 to dest + n do begin
            InS.Read(b);
            Mem.Set(i, b);
        end;
    end;

    // ---- files: DOOM's save game slots doomsav0.dsg .. doomsav9.dsg are records in "DOOM Save Game"
    // for the current game and user, the config file ./.doomrc is the record in "DOOM Settings" for the game and user.
    // Other files don't exist.

    local procedure bc_file_open(name: Integer; mode: Integer): Integer
    var
        FileName: Text;
        Slot: Integer;
    begin
        FileName := LowerCase(CStr(name));
        FilePos := 0;
        FileStreamPos := 0;
        FileWriting := CStr(mode).StartsWith('w');
        if FileName = './.doomrc' then begin
            FileKind := 2;
            if FileWriting then
                exit(StartWriting());
            if not UserSettings.Get(GameWad, UserId()) then
                exit(0);
            UserSettings.CalcFields(Config);
            FileSize := UserSettings.Size;
            UserSettings.Config.CreateInStream(FileIn);
            exit(1);
        end;
        if (StrLen(FileName) <> 12) or not FileName.StartsWith('doomsav') or not FileName.EndsWith('.dsg') then
            exit(0);
        if not Evaluate(Slot, CopyStr(FileName, 8, 1)) then
            exit(0);
        FileKind := 1;
        FileSlot := Slot;
        if FileWriting then
            exit(StartWriting());
        if not SaveGame.Get(GameWad, UserId(), Slot) then
            exit(0);
        SaveGame.CalcFields(Data);
        SaveGame.Data.CreateInStream(FileIn);
        FileSize := SaveGame.Size;
        exit(1);
    end;

    local procedure StartWriting(): Integer
    begin
        Clear(FileWriteBlob);
        FileWriteBlob.CreateOutStream(FileOut);
        exit(1);
    end;

    local procedure bc_file_close(handle: Integer)
    begin
        if FileWriting then
            case FileKind of
                1:
                    StoreSaveGame();
                2:
                    StoreSettings();
            end;
        FileWriting := false;
        FileKind := 0;
    end;

    local procedure bc_file_read(handle: Integer; buf: Integer; count: Integer): Integer
    var
        b: Byte;
        n: Integer;
    begin
        if FilePos < FileStreamPos then begin
            // seek backwards: start reading from the beginning again
            if FileKind = 2 then
                UserSettings.Config.CreateInStream(FileIn)
            else
                SaveGame.Data.CreateInStream(FileIn);
            FileStreamPos := 0;
        end;
        while (FileStreamPos < FilePos) and (FileStreamPos < FileSize) do begin
            FileIn.Read(b);
            FileStreamPos += 1;
        end;
        while (n < count) and (FilePos < FileSize) do begin
            FileIn.Read(b);
            Mem.Set(buf + n + 1, b);
            n += 1;
            FilePos += 1;
        end;
        FileStreamPos := FilePos;
        exit(n);
    end;

    local procedure bc_file_write(handle: Integer; buf: Integer; count: Integer): Integer
    var
        b: Byte;
        i: Integer;
    begin
        for i := 1 to count do begin
            b := Mem.Get(buf + i);
            FileOut.Write(b);
            if FilePos < 43 then
                FileHeader[FilePos + 1] := b;
            FilePos += 1;
        end;
        exit(count);
    end;

    local procedure bc_file_seek(handle: Integer; offset: Integer; origin: Integer): Integer
    begin
        case origin of
            0:
                FilePos := offset;
            1:
                FilePos += offset;
            2:
                FilePos := FileSize + offset;
        end;
        exit(0);
    end;

    local procedure bc_file_tell(handle: Integer): Integer
    begin
        exit(FilePos);
    end;

    local procedure bc_file_eof(handle: Integer): Integer
    begin
        exit(B2I(FilePos >= FileSize));
    end;

    /// <summary>Stores the save game that was just written. Its header: description (24 bytes), version (16), skill, episode, map.</summary>
    local procedure StoreSaveGame()
    var
        SaveIn: InStream;
        SaveOut: OutStream;
        Description: Text;
        Ch: Char;
        Exists: Boolean;
        i: Integer;
    begin
        Exists := SaveGame.Get(GameWad, UserId(), FileSlot);
        if not Exists then begin
            SaveGame.Init();
            SaveGame.Game := CopyStr(GameWad, 1, MaxStrLen(SaveGame.Game));
            SaveGame."User ID" := CopyStr(UserId(), 1, MaxStrLen(SaveGame."User ID"));
            SaveGame."Slot No." := FileSlot;
        end;
        i := 1;
        while (i <= 24) and (FileHeader[i] <> 0) do begin
            Ch := FileHeader[i];
            Description += Format(Ch);
            i += 1;
        end;
        SaveGame.Description := CopyStr(Description, 1, MaxStrLen(SaveGame.Description));
        SaveGame.Skill := FileHeader[41];
        LoadLumpDirectory();
        if LumpNames.Contains('MAP01') then
            SaveGame.Level := StrSubstNo('MAP%1', Format(FileHeader[43], 0, '<Integer,2><Filler Character,0>'))
        else
            SaveGame.Level := StrSubstNo('E%1M%2', FileHeader[42], FileHeader[43]);
        SaveGame."Saved At" := CurrentDateTime;
        SaveGame.Size := FilePos;
        SaveGame.Data.CreateOutStream(SaveOut);
        FileWriteBlob.CreateInStream(SaveIn);
        CopyStream(SaveOut, SaveIn);
        if Exists then
            SaveGame.Modify()
        else
            SaveGame.Insert();
    end;

    /// <summary>Stores the config file that was just written (DOOM's settings, as text).</summary>
    local procedure StoreSettings()
    var
        SettingsIn: InStream;
        SettingsOut: OutStream;
        Exists: Boolean;
    begin
        Exists := UserSettings.Get(GameWad, UserId());
        if not Exists then begin
            UserSettings.Init();
            UserSettings.Game := CopyStr(GameWad, 1, MaxStrLen(UserSettings.Game));
            UserSettings."User ID" := CopyStr(UserId(), 1, MaxStrLen(UserSettings."User ID"));
        end;
        UserSettings.Size := FilePos;
        UserSettings."Modified At" := CurrentDateTime;
        UserSettings.Config.CreateOutStream(SettingsOut);
        FileWriteBlob.CreateInStream(SettingsIn);
        CopyStream(SettingsOut, SettingsIn);
        if Exists then
            UserSettings.Modify()
        else
            UserSettings.Insert();
    end;

    local procedure bc_wad_gamemode(): Integer
    begin
        LoadLumpDirectory();
        if LumpNames.Contains('MAP01') then
            exit(2);
        if LumpNames.Contains('E4M1') then
            exit(3);
        if LumpNames.Contains('E3M1') then
            exit(1);
        exit(0);
    end;

    // =====================================================================
    //  Translated PureDOOM
    // =====================================================================
