# Patches PureDOOM.h for translation to AL:
#  - removes all goto statements (AL has no goto)
#  - routes WAD access through bc_* natives (lumps live in a BC table)
#  - makes FixedDiv2 exact integer math (no doubles)
import re, sys

src = open('PureDOOM_orig.h', encoding='latin-1').read()


def find_func(text, header):
    ms = [m for m in re.finditer(re.escape(header) + r'\s*\{', text)]
    if not ms:
        raise Exception('function not found: ' + header)
    if len(ms) > 1:
        raise Exception('function ambiguous: ' + header)
    i = ms[0].start()
    j = text.index('{', i)
    depth = 0
    k = j
    while True:
        c = text[k]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i, k + 1
        k += 1


def replace_func(header, newcode):
    global src
    i, j = find_func(src, header)
    src = src[:i] + newcode.strip('\n') + src[j:]


def patch_in_func(header, pairs):
    global src
    i, j = find_func(src, header)
    body = src[i:j]
    for old, new in pairs:
        n = body.count(old)
        if n == 0:
            raise Exception('pattern not found in %s: %s' % (header, old))
        body = body.replace(old, new)
    src = src[:i] + body + src[j:]


def insert_before_func(header, code):
    global src
    i, j = find_func(src, header)
    src = src[:i] + code + '\n\n' + src[i:]


# ---------------------------------------------------------------- natives
NATIVES = r'''
/* ---- BC natives: implemented directly in AL ---- */
void bc_print(const char* s);
void bc_exit(int code);
void* bc_malloc(int size);
void bc_free(void* p);
int bc_time_ms(void);
int bc_wad_numlumps(void);
int bc_wad_lumpsize(int lump);
void bc_wad_lumpname(int lump, char* dest);
void bc_wad_readlump(int lump, void* dest);
int bc_wad_gamemode(void);
void bc_sound(int kind, int handle, int lump, int vol, int sep, int pitch);
int bc_file_open(const char* name, const char* mode);
void bc_file_close(int handle);
int bc_file_read(int handle, void* buf, int count);
int bc_file_write(int handle, const void* buf, int count);
int bc_file_seek(int handle, int offset, int origin);
int bc_file_tell(int handle);
int bc_file_eof(int handle);
'''
anchor = '#ifndef __DOOM_H__'
assert src.count(anchor) == 1
src = src.replace(anchor, NATIVES + anchor)

# ---------------------------------------------------------------- gotos
patch_in_func('void NetUpdate(void)', [
    ('goto listen;', '{ GetPackets(); return; }'),
    # single tic mode builds its own commands: don't build (unused) ones here, they would eat mouse motion
    ('''        G_BuildTiccmd(&localcmds[maketic % BACKUPTICS]);
        maketic++;''', '''        if (!singletics)
        {
            G_BuildTiccmd(&localcmds[maketic % BACKUPTICS]);
            maketic++;
        }'''),
])

patch_in_func('void F_CastTicker(void)', [
    ('goto stopattack;        // Oh, gross hack!',
     '''{
            castattacking = false;
            castframes = 0;
            caststate = &states[mobjinfo[castorder[castnum].type].seestate];
            casttics = caststate->tics;
            if (casttics == -1)
                casttics = 15;
            return;
        }'''),
    ('stopattack:', ''),
])

patch_in_func('void A_Look(mobj_t* actor)', [
    ('mobj_t* targ;', 'mobj_t* targ;\n    int bc_seen = 0;'),
    ('goto seeyou;', 'bc_seen = 1;'),
    ('if (!P_LookForPlayers(actor, false))', 'if (!bc_seen && !P_LookForPlayers(actor, false))'),
    ('seeyou:', ''),
])

patch_in_func('void A_Chase(mobj_t* actor)', [
    ('''        if (gameskill < sk_nightmare
            && !fastparm && actor->movecount)
        {
            goto nomissile;
        }

        if (!P_CheckMissileRange(actor))
            goto nomissile;

        P_SetMobjState(actor, actor->info->missilestate);
        actor->flags |= MF_JUSTATTACKED;
        return;''',
     '''        if (!(gameskill < sk_nightmare
            && !fastparm && actor->movecount))
        {
            if (P_CheckMissileRange(actor))
            {
                P_SetMobjState(actor, actor->info->missilestate);
                actor->flags |= MF_JUSTATTACKED;
                return;
            }
        }'''),
    ('nomissile:', ''),
])

insert_before_func('doom_boolean PTR_SlideTraverse(intercept_t* in)', r'''
doom_boolean PTR_SlideTraverse_isblocking(intercept_t* in, line_t* li)
{
    if (in->frac < bestslidefrac)
    {
        secondslidefrac = bestslidefrac;
        secondslideline = bestslideline;
        bestslidefrac = in->frac;
        bestslideline = li;
    }

    return false; // stop
}''')
patch_in_func('doom_boolean PTR_SlideTraverse(intercept_t* in)', [
    ('goto isblocking;', 'return PTR_SlideTraverse_isblocking(in, li);'),
    ('isblocking:', ''),
])

replace_func('void P_SlideMove(mobj_t* mo)', r'''
void P_SlideMove_stairstep(mobj_t* mo)
{
    if (!P_TryMove(mo, mo->x, mo->y + mo->momy))
        P_TryMove(mo, mo->x + mo->momx, mo->y);
}

void P_SlideMove(mobj_t* mo)
{
    fixed_t leadx;
    fixed_t leady;
    fixed_t trailx;
    fixed_t traily;
    fixed_t newx;
    fixed_t newy;
    int hitcount;

    slidemo = mo;
    hitcount = 0;

    for (;;)
    {
        if (++hitcount == 3)
        {
            P_SlideMove_stairstep(mo); // don't loop forever
            return;
        }

        // trace along the three leading corners
        if (mo->momx > 0)
        {
            leadx = mo->x + mo->radius;
            trailx = mo->x - mo->radius;
        }
        else
        {
            leadx = mo->x - mo->radius;
            trailx = mo->x + mo->radius;
        }

        if (mo->momy > 0)
        {
            leady = mo->y + mo->radius;
            traily = mo->y - mo->radius;
        }
        else
        {
            leady = mo->y - mo->radius;
            traily = mo->y + mo->radius;
        }

        bestslidefrac = FRACUNIT + 1;

        P_PathTraverse(leadx, leady, leadx + mo->momx, leady + mo->momy,
                       PT_ADDLINES, PTR_SlideTraverse);
        P_PathTraverse(trailx, leady, trailx + mo->momx, leady + mo->momy,
                       PT_ADDLINES, PTR_SlideTraverse);
        P_PathTraverse(leadx, traily, leadx + mo->momx, traily + mo->momy,
                       PT_ADDLINES, PTR_SlideTraverse);

        // move up to the wall
        if (bestslidefrac == FRACUNIT + 1)
        {
            // the move most have hit the middle, so stairstep
            P_SlideMove_stairstep(mo);
            return;
        }

        // fudge a bit to make sure it doesn't hit
        bestslidefrac -= 0x800;
        if (bestslidefrac > 0)
        {
            newx = FixedMul(mo->momx, bestslidefrac);
            newy = FixedMul(mo->momy, bestslidefrac);

            if (!P_TryMove(mo, mo->x + newx, mo->y + newy))
            {
                P_SlideMove_stairstep(mo);
                return;
            }
        }

        // Now continue along the wall.
        // First calculate remainder.
        bestslidefrac = FRACUNIT - (bestslidefrac + 0x800);

        if (bestslidefrac > FRACUNIT)
            bestslidefrac = FRACUNIT;

        if (bestslidefrac <= 0)
            return;

        tmxmove = FixedMul(mo->momx, bestslidefrac);
        tmymove = FixedMul(mo->momy, bestslidefrac);

        P_HitSlideLine(bestslideline); // clip the moves

        mo->momx = tmxmove;
        mo->momy = tmymove;

        if (!P_TryMove(mo, mo->x + tmxmove, mo->y + tmymove))
            continue; // retry
        return;
    }
}''')

insert_before_func('doom_boolean PTR_ShootTraverse(intercept_t* in)', r'''
doom_boolean PTR_ShootTraverse_hitline(intercept_t* in, line_t* li)
{
    fixed_t x;
    fixed_t y;
    fixed_t z;
    fixed_t frac;

    // position a bit closer
    frac = in->frac - FixedDiv(4 * FRACUNIT, attackrange);
    x = trace.x + FixedMul(trace.dx, frac);
    y = trace.y + FixedMul(trace.dy, frac);
    z = shootz + FixedMul(aimslope, FixedMul(frac, attackrange));

    if (li->frontsector->ceilingpic == skyflatnum)
    {
        // don't shoot the sky!
        if (z > li->frontsector->ceilingheight)
            return false;

        // it's a sky hack wall
        if (li->backsector && li->backsector->ceilingpic == skyflatnum)
            return false;
    }

    // Spawn bullet puffs.
    P_SpawnPuff(x, y, z);

    // don't go any farther
    return false;
}''')
patch_in_func('doom_boolean PTR_ShootTraverse(intercept_t* in)', [
    ('goto hitline;', 'return PTR_ShootTraverse_hitline(in, li);'),
    ('hitline:', ''),
])

patch_in_func('void R_ClipSolidWallSegment(int first, int last)', [
    ('    next = start;\n    while', '    next = start;\n    bc_crunch = 0;\n    while'),
    ('            goto crunch;', '            bc_crunch = 1;\n            break;'),
    ('''    R_StoreWallRange(next->last + 1, last);
    // Adjust the clip size.
    start->last = last;''', '''    if (!bc_crunch)
    {
        R_StoreWallRange(next->last + 1, last);
        // Adjust the clip size.
        start->last = last;
    }'''),
    ('crunch:', ''),
    ('cliprange_t* start;', 'cliprange_t* start;\n    int bc_crunch;'),
])

patch_in_func('void R_AddLine(seg_t* line)', [
    ('goto clipsolid;', '{ R_ClipSolidWallSegment(x1, x2 - 1); return; }'),
    ('goto clippass;', '{ R_ClipPassWallSegment(x1, x2 - 1); return; }'),
    ('clippass:', ''),
    ('clipsolid:', ''),
])

# ---------------------------------------------------------------- fixed point
replace_func('fixed_t FixedDiv2(fixed_t a, fixed_t b)', r'''
fixed_t FixedDiv2(fixed_t a, fixed_t b)
{
    return (fixed_t)((((long long)a) << 16) / (long long)b);
}''')

# ---------------------------------------------------------------- WAD from BC table
replace_func('void W_AddFile(char* filename)', r'''
void W_AddFile(char* filename)
{
    lumpinfo_t* lump_p;
    int i;
    int n;
    int startlump;
    void* new_lumpinfo;

    doom_print(" adding WAD lumps from Business Central table\n");
    startlump = numlumps;
    n = bc_wad_numlumps();
    numlumps += n;

    new_lumpinfo = doom_malloc(numlumps * sizeof(lumpinfo_t));
    if (startlump)
        doom_memcpy(new_lumpinfo, lumpinfo, startlump * sizeof(lumpinfo_t));
    lumpinfo = new_lumpinfo;

    lump_p = &lumpinfo[startlump];
    for (i = 0; i < n; i++, lump_p++)
    {
        lump_p->handle = (void*)1;
        lump_p->position = i;
        lump_p->size = bc_wad_lumpsize(i);
        bc_wad_lumpname(i, lump_p->name);
    }
}''')

replace_func('void W_ReadLump(int lump, void* dest)', r'''
void W_ReadLump(int lump, void* dest)
{
    if (lump >= numlumps)
        I_Error("Error: W_ReadLump: lump >= numlumps");
    bc_wad_readlump(lumpinfo[lump].position, dest);
}''')

replace_func('void IdentifyVersion(void)', r'''
void IdentifyVersion(void)
{
    doom_strcpy(basedefault, "./.doomrc");
    switch (bc_wad_gamemode())
    {
        case 1: gamemode = registered; break;
        case 2: gamemode = commercial; break;
        case 3: gamemode = retail; break;
        default: gamemode = shareware; break;
    }
    D_AddFile("doom.wad");
}''')

# ---------------------------------------------------------------- sound
# Mixing 11 kHz audio in AL is far too slow. Instead, starting, changing and stopping a sound is
# reported to the host with bc_sound(kind, handle, lump, vol, sep, pitch) and the control add-in
# plays the WAD's DS* lumps itself (kind 0 = start, 1 = volume/separation changed, 2 = stop).
insert_before_func('int I_StartSound(int id, int vol, int sep, int pitch, int priority)', r'''
#define BCS_CHANNELS 16
static int bcs_handle[BCS_CHANNELS];  // 0 = slot unused
static int bcs_sfx[BCS_CHANNELS];
static int bcs_end[BCS_CHANNELS];     // gametic when the sound has finished playing
static int bcs_vol[BCS_CHANNELS];
static int bcs_sep[BCS_CHANNELS];
static int bcs_next_handle = 1;

static int bcs_find(int handle)
{
    int i;
    for (i = 0; i < BCS_CHANNELS; i++)
        if (handle && bcs_handle[i] == handle)
            return i;
    return -1;
}

static void bcs_stop_slot(int i)
{
    if (bcs_handle[i] && gametic < bcs_end[i])
        bc_sound(2, bcs_handle[i], 0, 0, 0, 0);
    bcs_handle[i] = 0;
}''')

replace_func('void I_InitSound()', r'''
void I_InitSound()
{
    int i;
    // The sound data is never loaded by the engine, the host plays the lumps.
    // data only has to be set so S_StartSoundAtVolume does not complain.
    for (i = 1; i < NUMSFX; i++)
        S_sfx[i].data = (void*)1;
    doom_print("I_InitSound: sounds are played by the host\n");
}''')

replace_func('int I_StartSound(int id, int vol, int sep, int pitch, int priority)', r'''
int I_StartSound(int id, int vol, int sep, int pitch, int priority)
{
    int i;
    int slot = -1;
    int tics;
    int lump = S_sfx[id].lumpnum;

    // Chainsaw troubles: as in the original mixer, these play only one at a time.
    if (id == sfx_sawup || id == sfx_sawidl || id == sfx_sawful
        || id == sfx_sawhit || id == sfx_stnmov || id == sfx_pistol)
    {
        for (i = 0; i < BCS_CHANNELS; i++)
            if (bcs_handle[i] && bcs_sfx[i] == id)
                bcs_stop_slot(i);
    }

    // a free slot, otherwise the sound that ends first is cut off
    for (i = 0; i < BCS_CHANNELS; i++)
    {
        if (!bcs_handle[i] || gametic >= bcs_end[i])
        {
            slot = i;
            break;
        }
    }
    if (slot < 0)
    {
        slot = 0;
        for (i = 1; i < BCS_CHANNELS; i++)
            if (bcs_end[i] < bcs_end[slot])
                slot = i;
        bcs_stop_slot(slot);
    }

    // length in tics: 8 byte header, 11025 samples per second, faster when pitched up
    tics = ((W_LumpLength(lump) - 8) * 35 / 11025 + 1) * 65536 / steptable[pitch] + 1;

    bcs_handle[slot] = bcs_next_handle++;
    bcs_sfx[slot] = id;
    bcs_end[slot] = gametic + tics;
    bcs_vol[slot] = vol;
    bcs_sep[slot] = sep;
    bc_sound(0, bcs_handle[slot], lump, vol, sep, pitch);
    return bcs_handle[slot];
}''')

replace_func('void I_StopSound(int handle)', r'''
void I_StopSound(int handle)
{
    int i = bcs_find(handle);
    if (i >= 0)
        bcs_stop_slot(i);
}''')

replace_func('int I_SoundIsPlaying(int handle)', r'''
int I_SoundIsPlaying(int handle)
{
    int i = bcs_find(handle);
    return i >= 0 && gametic < bcs_end[i];
}''')

# The pitch is not updated: S_UpdateSounds passes NORM_PITCH, not the random pitch the sound started with.
replace_func('void I_UpdateSoundParams(int handle, int vol, int sep, int pitch)', r'''
void I_UpdateSoundParams(int handle, int vol, int sep, int pitch)
{
    int i = bcs_find(handle);
    if (i < 0 || (bcs_vol[i] == vol && bcs_sep[i] == sep))
        return;
    bcs_vol[i] = vol;
    bcs_sep[i] = sep;
    bc_sound(1, handle, 0, vol, sep, 0);
}''')

# Music: the host plays the MUS lumps too. The song handle is the lump number and the lump is never
# loaded by the engine (kind 3 = play lump, 4 = stop, 5 = pause, 6 = resume, 7 = volume 0..15).
patch_in_func('void S_ChangeMusic(int musicnum, int looping)', [
    ('''    music->data = (void*)W_CacheLumpNum(music->lumpnum, PU_MUSIC);
    music->handle = I_RegisterSong(music->data);''', '''    music->data = (void*)1;
    music->handle = music->lumpnum;'''),
])
patch_in_func('void S_StopMusic(void)', [
    ('        Z_ChangeTag(mus_playing_s_sound->data, PU_CACHE);\n', ''),
])
replace_func('void I_PlaySong(int handle, int looping)', r'''
void I_PlaySong(int handle, int looping)
{
    bc_sound(3, 0, handle, 0, 0, looping ? 1 : 0);
}''')
replace_func('void I_StopSong(int handle)', r'''
void I_StopSong(int handle)
{
    bc_sound(4, 0, 0, 0, 0, 0);
}''')
replace_func('void I_UnRegisterSong(int handle)', r'''
void I_UnRegisterSong(int handle)
{
}''')
replace_func('void I_PauseSong(int handle)', r'''
void I_PauseSong(int handle)
{
    bc_sound(5, 0, 0, 0, 0, 0);
}''')
replace_func('void I_ResumeSong(int handle)', r'''
void I_ResumeSong(int handle)
{
    bc_sound(6, 0, 0, 0, 0, 0);
}''')
replace_func('void I_SetMusicVolume(int volume)', r'''
void I_SetMusicVolume(int volume)
{
    snd_MusicVolume = volume;
    bc_sound(7, 0, 0, volume, 0, 0);
}''')

# pointers are 32 bits in the AL memory model: no need for 64 bit pointer casts
for old in ['(int)(long long)&', '(long long)save_p', '(long long)players[i]', '(long long)mobj->', '(long long)ceiling->',
            '(long long)door->', '(long long)floor->', '(long long)plat->', '(long long)flash->', '(long long)strobe->',
            '(long long)glow->', '(unsigned long long)colormaps', '(unsigned long long)translationtables',
            '(unsigned long long)block->user']:
    n = src.count(old)
    assert n > 0, old
    src = src.replace(old, old.replace('unsigned long long', 'unsigned int').replace('(int)(long long)', '(int)').replace('long long', 'int'))

assert 'goto ' not in re.sub(r'//.*', '', src).replace('goto stairstep', ''), [m.start() for m in re.finditer(r'\bgoto\b', src)]
open('doom_patched.h', 'w', encoding='latin-1').write(src)
print('patched ok')
