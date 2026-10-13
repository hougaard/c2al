// C implementation of the bc_* natives, used to validate the patched C code natively.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned char* wad; static int numl; static int* dir;
static void loadwad(void) {
    if (wad) return;
    FILE* f = fopen("doom1.wad", "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    wad = malloc(n); fread(wad, 1, n, f); fclose(f);
    numl = *(int*)(wad + 4); dir = (int*)(wad + *(int*)(wad + 8));
}
void bc_print(const char* s) { fputs(s, stdout); }
void bc_exit(int code) { printf("EXIT %d\n", code); exit(1); }
void* bc_malloc(int size) { return calloc(1, size); }
void bc_free(void* p) { }
int fake_ms = 0;
int bc_time_ms(void) { return fake_ms; }
int bc_wad_numlumps(void) { loadwad(); return numl; }
int bc_wad_lumpsize(int l) { loadwad(); return dir[l * 4 + 1]; }
void bc_wad_lumpname(int l, char* d) { loadwad(); memcpy(d, (char*)&dir[l * 4 + 2], 8); }
void bc_wad_readlump(int l, void* d) { loadwad(); memcpy(d, wad + dir[l * 4], dir[l * 4 + 1]); }
int bc_wad_gamemode(void) { return 0; }
/* natives added after the reference build was first written: no sound, no files (like a fresh BC company) */
void bc_sound(int kind, int handle, int lump, int vol, int sep, int pitch) { }
int bc_file_open(const char* name, const char* mode) { return 0; }
void bc_file_close(int handle) { }
int bc_file_read(int handle, void* buf, int count) { return 0; }
int bc_file_write(int handle, const void* buf, int count) { return count; }
int bc_file_seek(int handle, int offset, int origin) { return 0; }
int bc_file_tell(int handle) { return 0; }
int bc_file_eof(int handle) { return 1; }
