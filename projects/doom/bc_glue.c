// Glue between PureDOOM and the Business Central host.
// Everything in this file is translated to AL together with PureDOOM.
#define DOOM_IMPLEMENTATION
#include "doom_patched.h"

static void bcg_print(const char* s) { bc_print(s); }
static void* bcg_malloc(int size) { return bc_malloc(size); }
static void bcg_free(void* p) { bc_free(p); }
static void bcg_exit(int code) { bc_exit(code); }
static void bcg_gettime(int* sec, int* usec)
{
    int ms = bc_time_ms();
    *sec = ms / 1000;
    *usec = (ms % 1000) * 1000;
}

// File access (save games) goes to the host: handles are small integers, 0 = could not open.
static void* bcg_open(const char* filename, const char* mode) { return (void*)bc_file_open(filename, mode); }
static void bcg_close(void* handle) { bc_file_close((int)handle); }
static int bcg_read(void* handle, void* buf, int count) { return bc_file_read((int)handle, buf, count); }
static int bcg_write(void* handle, const void* buf, int count) { return bc_file_write((int)handle, buf, count); }
static int bcg_seek(void* handle, int offset, doom_seek_t origin) { return bc_file_seek((int)handle, offset, (int)origin); }
static int bcg_tell(void* handle) { return bc_file_tell((int)handle); }
static int bcg_eof(void* handle) { return bc_file_eof((int)handle); }

static char* bcg_argv[] = { "doom", 0 };

// The settings (the config file, written by M_SaveDefaults) are stored by the host whenever one of
// them changed: volumes, mouse sensitivity, screen size, gamma, ... A hash of all values detects that.
static int bcg_settings_hash(void)
{
    int i;
    int h = 0;
    for (i = 0; i < numdefaults; i++)
        h = (h % 1000003) * 31 + (*defaults[i].location % 1000003);
    return h;
}
static int bcg_settings = 0;
static int bcg_last_time = 0;
extern doom_boolean is_wiping_screen;
void D_UpdateWipe(void);
void D_DoAdvanceDemo(void);
extern doom_boolean advancedemo;

void bc_doom_init(void)
{
    doom_set_print(bcg_print);
    doom_set_malloc(bcg_malloc, bcg_free);
    doom_set_gettime(bcg_gettime);
    doom_set_exit(bcg_exit);
    doom_set_file_io(bcg_open, bcg_close, bcg_read, bcg_write, bcg_seek, bcg_tell, bcg_eof);

    // Modern key bindings
    doom_set_default_int("key_up", DOOM_KEY_W);
    doom_set_default_int("key_down", DOOM_KEY_S);
    doom_set_default_int("key_strafeleft", DOOM_KEY_A);
    doom_set_default_int("key_straferight", DOOM_KEY_D);
    doom_set_default_int("key_use", DOOM_KEY_E);
    doom_set_default_int("mouse_move", 0);

    doom_init(1, bcg_argv, 0);
    bcg_last_time = I_GetTime();
    bcg_settings = bcg_settings_hash();
}

// One displayed frame: run all game tics that are due, then render once.
// Single player only, so every tic builds its command from the input received just before it
// (TryRunTics would keep up to 5 tics of prebuilt commands queued = extra input lag), and the
// frame is rendered once at the end (doom_update renders after every tic).
void bc_doom_frame(void)
{
    int now = I_GetTime();
    int dt = now - bcg_last_time;
    if (dt <= 0)
        return; // no tic is due yet
    bcg_last_time = now;
    while (is_wiping_screen && dt > 0)
    {
        D_UpdateWipe();
        dt--;
    }
    if (dt <= 0)
        return;
    I_StartFrame();
    while (dt-- > 0)
    {
        I_StartTic();
        D_ProcessEvents();
        maketic = gametic; // drop commands prebuilt by the network code
        G_BuildTiccmd(&netcmds[consoleplayer][gametic % BACKUPTICS]);
        if (advancedemo)
            D_DoAdvanceDemo();
        M_Ticker();
        G_Ticker();
        gametic++;
        maketic++;
    }
    // a setting changed (and the menu is closed again): store the config file
    if (!menuactive && bcg_settings_hash() != bcg_settings)
    {
        bcg_settings = bcg_settings_hash();
        M_SaveDefaults();
    }
    S_UpdateSounds(players[consoleplayer].mo);
    D_Display();
}

unsigned char* bc_get_screen(void) { return screens[0]; }
unsigned char* bc_get_palette(void) { return screen_palette; }

// Input latency inside DOOM: ticcmds that were built from input but not run yet
int bc_tic_lag(void) { return maketic - gametic; }
