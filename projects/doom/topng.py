
import sys, zlib, struct
def png(raw, out):
    pix, pal = raw[:64000], raw[64000:64768]
    rows = b''.join(b'\0' + bytes(c for i in pix[y*320:(y+1)*320] for c in pal[i*3:i*3+3]) for y in range(200))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(out, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 320, 200, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
for f in sys.argv[1:]:
    png(open(f, 'rb').read(), f.replace('.raw', '.png'))
