# Generates a deterministic random gameplay input script: lines "frame type key" (0=down 1=up, 3/4 mouse button, 2 mouse dx dy)
import random, sys
seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
frames = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
random.seed(seed)
ev = []
def tap(f, k, hold=2):
    ev.append((f, 0, k)); ev.append((f + hold, 1, k))
def typ(f, s):
    for i, ch in enumerate(s):
        tap(f + i * 4, ord(ch))
    return f + len(s) * 4 + 4
ESC, ENTER, UP, DOWN, LEFT, RIGHT, CTRL, SHIFT, TAB = 27, 13, 0xad, 0xaf, 0xac, 0xae, 0x9d, 0xb6, 9
f = 60
tap(f, ESC); f += 15
tap(f, ENTER); f += 15   # new game
tap(f, ENTER); f += 15   # episode 1
tap(f, ENTER); f += 40   # skill
f = typ(f, 'iddqd')
f = typ(f, 'idkfa')
level = 1
next_warp = f + 1500
while f < frames - 100:
    if f >= next_warp:
        level += 1
        if level > 9: level = 1
        f = typ(f, 'idclev1%d' % level)
        f += 60
        f = typ(f, 'iddqd') if random.random() < 0.3 else f
        next_warp = f + random.randint(1000, 2000)
        continue
    r = random.random()
    if r < 0.30:
        k = random.choice([ord('w'), ord('w'), ord('s'), ord('a'), ord('d')])
        hold = random.randint(5, 60)
        ev.append((f, 0, k)); ev.append((f + hold, 1, k))
        if random.random() < 0.5:
            t = random.choice([LEFT, RIGHT]); th = random.randint(3, 30)
            ev.append((f + 2, 0, t)); ev.append((f + 2 + th, 1, t))
        f += random.randint(1, hold)
    elif r < 0.45:
        tap(f, CTRL, random.randint(2, 30)); f += random.randint(1, 10)
    elif r < 0.55:
        tap(f, ord('e')); f += random.randint(2, 10)
    elif r < 0.62:
        tap(f, ord(str(random.randint(1, 7)))); f += 5
    elif r < 0.65:
        tap(f, TAB); f += random.randint(10, 60); tap(f, TAB); f += 5
    elif r < 0.70:
        ev.append((f, 2, random.randint(-40, 40), random.randint(-10, 10))); f += 1
    elif r < 0.72:
        tap(f, SHIFT, 40); ev.append((f, 0, ord('w'))); ev.append((f + 40, 1, ord('w'))); f += 30
    elif r < 0.73:
        tap(f, ESC); f += 20; tap(f, DOWN); f += 6; tap(f, ESC); f += 10
    else:
        f += random.randint(1, 8)
ev.sort(key=lambda e: e[0])
with open('script.txt', 'w') as o:
    for e in ev:
        o.write(' '.join(str(x) for x in e) + '\n')
print(len(ev), 'events')
