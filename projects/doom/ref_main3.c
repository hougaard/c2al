#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void bc_doom_init(void);
unsigned char* bc_get_screen(void);
void doom_update(void);
void doom_key_down(int); void doom_key_up(int); void doom_mouse_move(int, int); void doom_button_down(int); void doom_button_up(int);
static int ev_f[200000], ev_t[200000], ev_a[200000], ev_b[200000], nev = 0;
extern int fake_ms;
int main(int argc, char** argv)
{
    setvbuf(stdout, 0, _IONBF, 0);
    int frames = argc > 1 ? atoi(argv[1]) : 1;
    int every = argc > 2 ? atoi(argv[2]) : 1;
    fake_ms = 1;
    if (getenv("DOOM_SCRIPT")) {
        FILE* s = fopen(getenv("DOOM_SCRIPT"), "r"); char line[100];
        while (fgets(line, 100, s)) { ev_b[nev] = 0; sscanf(line, "%d %d %d %d", &ev_f[nev], &ev_t[nev], &ev_a[nev], &ev_b[nev]); nev++; }
        fclose(s);
    }
    int ei = 0;
    bc_doom_init();
    for (int f = 1; f <= frames; f++) {
        fake_ms = (int)((long long)f * 1000 / 35) + 1;
        while (ei < nev && ev_f[ei] <= f) {
            if (ev_t[ei] == 0) doom_key_down(ev_a[ei]); else if (ev_t[ei] == 1) doom_key_up(ev_a[ei]);
            else if (ev_t[ei] == 2) doom_mouse_move(ev_a[ei], ev_b[ei]); else if (ev_t[ei] == 3) doom_button_down(ev_a[ei]); else doom_button_up(ev_a[ei]);
            ei++;
        }
        doom_update();
        if (f % every == 0) {
            const unsigned char* fb = bc_get_screen();
            unsigned int h = 2166136261u;
            for (int i = 0; i < 64000; i++) { h ^= fb[i]; h *= 16777619u; }
            printf("frame %d hash %08x\n", f, h);
            if (argc > 3 && f == atoi(argv[3])) {
                extern unsigned char screen_palette[];
                FILE* o = fopen("ref_frame.raw", "wb");
                fwrite(fb, 1, 64000, o);
                fwrite(screen_palette, 1, 768, o);
                fclose(o);
            }
        }
    }
    return 0;
}
