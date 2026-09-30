"""The extension video's soundtrack: the instruments of ../music.py in a new
arrangement, with a blip per extension toggle and hits on the chapter cards.

    python3 music.py build/music.wav
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import music as m  # noqa: E402

from music import BAR, BEAT, add, arp, bass, blip, clap, hat, hz, impact, kick, pad, riser, whoosh  # noqa: E402

# mirrors window.TIMELINE in composition.html
CHAPTERS = [8, 38, 68, 105]
CARD, SCENE = 2, 7
FEATURES = [s + CARD + i * SCENE for s, n in zip(CHAPTERS, (4, 4, 5, 3)) for i in range(n)]
WALL = 128
STATS, OUTRO, END = WALL + 8, WALL + 14, WALL + 24
TITLE_HIT = 4.0

m.DUR = float(END)
m.N = int(m.DUR * m.SR)
N = m.N


def groove(drums, music, t0, t1, hats=8):
    music_parts = [(bass(t0, t1), 1.0), (arp(t0, t1, bright=1.2 if hats == 16 else 1.0), 1.0)]
    for part, g in music_parts:
        add(music, part, t0, g)
    for b in np.arange(t0, t1 - 1e-6, BEAT):
        add(drums, kick(), b)
        if round((b - t0) / BEAT) % 2 == 1:
            add(drums, clap(), b, 0.9)
    step = BEAT / (hats // 4)
    for h in np.arange(t0, t1 - 1e-6, step):
        off = round((h - t0) / step) % 2 == 1
        add(drums, hat(open_=hats == 8 and off and m.rng.random() < 0.25), h, 0.9 if off else 0.5, pan=0.25)
    return list(np.arange(t0, t1 - 1e-6, BEAT))


def main(path):
    music, drums, fx = m.track(), m.track(), m.track()
    kicks = []

    # intro: a rising blip for each of the 20 toggles, the title hit, a riser
    add(music, pad(0, CHAPTERS[0]) * np.clip(np.linspace(-0.1, 1.4, m.at(CHAPTERS[0])), 0, 1)[:, None], 0)
    scale = ["A4", "C5", "E5", "G5", "A5"]
    for i in range(20):
        add(fx, blip(hz(scale[i % 5]) * (2 if i >= 10 else 1)), 1.0 + i * 0.1, 0.55, pan=-0.6 + (i % 4) * 0.4)
    add(fx, riser(1.2), TITLE_HIT - 1.2, 0.5)
    add(fx, impact(0.9), TITLE_HIT)
    add(music, arp(TITLE_HIT, CHAPTERS[0], bright=0.7), TITLE_HIT, 0.8)
    add(fx, riser(2.0), CHAPTERS[0] - 2.0, 0.6)

    # chapters: a hit on the card, the groove under its features
    add(music, pad(CHAPTERS[0], WALL + 8), CHAPTERS[0])
    ends = CHAPTERS[1:] + [WALL]
    for c, end in zip(CHAPTERS, ends):
        add(fx, impact(1.0), c)
        add(drums, kick(1.1), c)
        add(music, bass(c, c + CARD, "long"), c)
        kicks.append(c)
        kicks += groove(drums, music, c + CARD, end - (BAR if end == WALL else 0))
        add(fx, riser(1.5), end - 1.5, 0.55)
    for s in FEATURES[1:]:
        if s not in [c + CARD for c in CHAPTERS]:
            add(fx, whoosh(), s - 0.45, 0.9)

    # the wall: sixteenth hats, brighter arp
    add(fx, impact(1.1), WALL)
    kicks += groove(drums, music, WALL, STATS, hats=16)

    # stats: half time, a blip as each number lands
    add(fx, whoosh(0.5), STATS - 0.4, 0.8)
    add(music, pad(STATS, OUTRO), STATS)
    add(music, bass(STATS, OUTRO, "long"), STATS)
    for b in np.arange(STATS, OUTRO - BAR / 2, BEAT * 2):
        add(drums, kick(0.9), b)
    for i, f in enumerate([hz("E5"), hz("A5"), hz("C6"), hz("E6")]):
        add(fx, blip(f), STATS + 0.4 + i * 0.3, 0.9, pan=-0.45 + i * 0.3)
    add(fx, riser(BAR), OUTRO - BAR, 0.7)

    # outro
    add(fx, impact(1.1), OUTRO)
    tail = pad(OUTRO, END)
    tail *= np.clip(np.linspace(1.3, -0.1, len(tail)), 0, 1)[:, None]
    add(music, tail, OUTRO)
    a = arp(OUTRO, OUTRO + 3 * BAR, bright=0.9)
    a *= np.clip(np.linspace(1, 0, len(a)), 0, 1)[:, None] ** 1.5
    add(music, a, OUTRO)
    add(music, bass(OUTRO, OUTRO + BAR, "long"), OUTRO)

    # sidechain, mix and master as in ../music.py
    duck = np.ones(N)
    shape = 1 - 0.55 * np.exp(-m.tt(BEAT) * 9)
    for k in kicks:
        i = m.at(k)
        j = min(N, i + len(shape))
        duck[i:j] = np.minimum(duck[i:j], shape[: j - i])
    music *= duck[:, None]
    mix = m.reverb(music, 2.4, 0.28) * 1.5 + drums * 0.7 + m.reverb(fx, 1.6, 0.2)
    mix = m.hp(mix, 25)
    mix = np.tanh(mix * 1.4) / np.tanh(1.4)
    mix *= 0.89 / np.max(np.abs(mix))
    mix *= np.clip((m.DUR - np.arange(N) / m.SR) / 1.5, 0, 1)[:, None]
    m.wavfile.write(path, m.SR, (mix * 32767).astype(np.int16))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/music.wav")
