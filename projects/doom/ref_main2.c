#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void bc_doom_init(void);
unsigned char* bc_get_screen(void);
void doom_force_update(void);
const unsigned char* doom_get_framebuffer(int channels);
extern int fake_ms;
int main(int argc, char** argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 1;
    bc_doom_init();
    for (int f = 0; f < frames; f++) {
        doom_force_update();
        const unsigned char* fb = bc_get_screen();
        unsigned int h = 2166136261u;
        for (int i = 0; i < 64000; i++) { h ^= fb[i]; h *= 16777619u; }
        printf("frame %d hash %08x\n", f, h);
    }
    const unsigned char* fb4 = doom_get_framebuffer(4);
    FILE* t = fopen("../PureDOOM/test_framebuffer.raw", "rb"); unsigned char* buf = malloc(256000); fread(buf, 1, 256000, t);
    printf("match test fb: %d\n", memcmp(buf, fb4, 256000) == 0);
    return 0;
}
