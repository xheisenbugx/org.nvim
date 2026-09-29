"""Synthesises the soundtrack for the promo video: 120 BPM, A minor, with hits
on the scene cuts of composition.html. Everything is generated here, so the
music is free to use anywhere.

    python3 music.py build/music.wav
"""

import sys

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, fftconvolve, sosfilt

SR = 48000
BPM = 120
BEAT = 60 / BPM
BAR = 4 * BEAT
DUR = 92.0
N = int(DUR * SR)
rng = np.random.default_rng(7)

# the timeline, mirrored from composition.html
PILLARS, FEATURES, WALL, STATS, OUTRO = 6, 10, 68, 76, 82
FEATURE_STARTS = [10, 20, 28, 36, 46, 54, 62]
LOGO_HIT = 2.35


def track():
    return np.zeros((N, 2))


def at(t):
    return int(round(t * SR))


def add(buf, sig, t, gain=1.0, pan=0.0):
    """Mixes a mono or stereo signal into buf at time t (pan -1..1)."""
    i = at(t)
    if i >= N:
        return
    if sig.ndim == 1:
        left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
        sig = np.stack([sig * left, sig * right], axis=1) * np.sqrt(2)
    sig = sig[: N - i]
    buf[i : i + len(sig)] += sig * gain


def lp(x, hz, order=2):
    return sosfilt(butter(order, hz, "low", fs=SR, output="sos"), x, axis=0)


def hp(x, hz, order=2):
    return sosfilt(butter(order, hz, "high", fs=SR, output="sos"), x, axis=0)


def bp(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], "band", fs=SR, output="sos"), x, axis=0)


def tt(sec):
    return np.arange(int(sec * SR)) / SR


def saw(freq, sec, phase=0.0):
    return 2 * ((tt(sec) * freq + phase) % 1) - 1


def hz(note):
    """'A3' -> 220.0"""
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    semis = names[note[0]] + (1 if "#" in note else 0) + 12 * (int(note[-1]) - 4)
    return 440 * 2 ** (semis / 12)


def adsr(n, a, d, s, r):
    a, d, r = int(a * SR), int(d * SR), int(r * SR)
    sus = max(0, n - a - d - r)
    env = np.concatenate([np.linspace(0, 1, a, endpoint=False), np.linspace(1, s, d, endpoint=False), np.full(sus, s), np.linspace(s, 0, r)])
    return env[:n] if len(env) >= n else np.pad(env, (0, n - len(env)))


def reverb(x, sec=2.2, mix=0.3):
    n = int(sec * SR)
    ir = rng.standard_normal((n, 2)) * np.exp(-np.linspace(0, 7, n))[:, None]
    ir = lp(ir, 6000)
    wet = np.stack([fftconvolve(x[:, c], ir[:, c])[: len(x)] for c in range(2)], axis=1)
    wet *= np.sqrt(np.mean(x**2) / max(np.mean(wet**2), 1e-12))
    return x * (1 - mix) + wet * mix


def delay(x, sec, fb=0.35, mix=0.3):
    d = int(sec * SR)
    out = x.copy()
    tap = x.copy()
    for k in range(1, 5):
        tap = np.roll(tap, d, axis=0)
        tap[:d] = 0
        tap = tap[:, ::-1] * fb  # ping-pong
        out += tap * mix / fb
    return out


# ------------------------------------------------------------ instruments
def kick(gain=1.0):
    t = tt(0.45)
    f = 45 + 110 * np.exp(-t * 28)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 7)
    click = hp(rng.standard_normal(len(t)), 3000) * np.exp(-t * 300) * 0.3
    return (body + click) * gain


def clap():
    t = tt(0.3)
    env = np.zeros(len(t))
    for off in (0, 0.011, 0.022):
        i = at(off)
        env[i:] += np.exp(-(t[: len(t) - i]) * (90 if off < 0.02 else 18))
    return bp(rng.standard_normal(len(t)), 900, 3500) * env * 0.55


def hat(open_=False):
    t = tt(0.25 if open_ else 0.06)
    return hp(rng.standard_normal(len(t)), 7000) * np.exp(-t * (14 if open_ else 70)) * 0.28


def tick():
    t = tt(0.02)
    return bp(rng.standard_normal(len(t)), 2500, 6000) * np.exp(-t * 400) * 0.5


def blip(freq):
    t = tt(0.25)
    return np.sin(2 * np.pi * freq * t) * np.exp(-t * 16) * 0.4 + np.sin(4 * np.pi * freq * t) * np.exp(-t * 30) * 0.1


def impact(big=1.0):
    t = tt(2.5)
    f = 28 + 90 * np.exp(-t * 9)
    boom = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 2.2)
    crash = hp(rng.standard_normal((len(t), 2)), 4000) * np.exp(-t * 2.5)[:, None] * 0.35
    return (np.stack([boom, boom], 1) + crash) * big


def riser(sec):
    n = int(sec * SR)
    noise = rng.standard_normal((n, 2))
    out = np.zeros_like(noise)
    chunks = 40
    for k in range(chunks):
        a, b = k * n // chunks, (k + 1) * n // chunks
        c = 300 * (40 ** (k / chunks))
        out[a:b] = bp(noise[a:b], c, min(c * 2.2, 20000))
    env = np.linspace(0, 1, n) ** 2.2
    sweep = np.sin(2 * np.pi * np.cumsum(200 * 8 ** np.linspace(0, 1, n)) / SR) * 0.15
    return (out * 0.5 + sweep[:, None]) * env[:, None]


def whoosh(sec=0.55):
    n = int(sec * SR)
    x = np.linspace(0, 1, n)
    env = np.sin(np.pi * x) ** 2
    noise = bp(rng.standard_normal(n), 600, 5000) * env * 0.5
    pan_l, pan_r = np.cos(x * np.pi / 2), np.sin(x * np.pi / 2)
    return np.stack([noise * pan_l, noise * pan_r], 1)


CHORDS = [  # one per bar: Am9, Fmaj7, C(add9), G(add9)
    (["A3", "C4", "E4", "B4"], "A1"),
    (["F3", "A3", "C4", "E4"], "F1"),
    (["C4", "E4", "G4", "D5"], "C2"),
    (["G3", "B3", "D4", "A4"], "G1"),
]


def chord_at(t):
    return CHORDS[int(t // BAR) % len(CHORDS)]


def pad(t0, t1):
    out = np.zeros((at(t1) - at(t0), 2))
    t = t0
    while t < t1 - 1e-6:
        bar_end = min((np.floor(t / BAR) + 1) * BAR, t1)
        sec = bar_end - t
        notes, _ = chord_at(t)
        n = int(round(sec * SR))
        seg = np.zeros((n, 2))
        for note in notes:
            f = hz(note)
            for c, cents in enumerate((-8, 8)):
                seg[:, c] += saw(f * 2 ** (cents / 1200), sec, rng.random())[:n] + saw(f * 2 ** (-cents / 2400), sec, rng.random())[:n] * 0.6
        seg *= adsr(n, 0.25, 0.3, 0.8, 0.35)[:, None]
        i = at(t) - at(t0)
        out[i : i + n] += seg[: len(out) - i]
        t = bar_end
    return lp(out, 1400) * 0.05


def bass(t0, t1, pattern="eighths"):
    out = np.zeros((at(t1) - at(t0), 2))
    step = BEAT / 2 if pattern == "eighths" else BEAT * 2
    t = t0
    while t < t1 - 1e-6:
        _, root = chord_at(t)
        f = hz(root)
        sec = step * 0.9
        x = tt(sec)
        tone = lp(saw(f * 2, sec), 520) * 0.6 + np.sin(2 * np.pi * f * x) * 0.8
        tone *= adsr(len(x), 0.005, 0.1, 0.7, 0.05)
        i = at(t) - at(t0)
        out[i : i + len(x)] += tone[: len(out) - i, None]
        t += step
    return out * 0.32


def arp(t0, t1, bright=1.0):
    out = np.zeros((at(t1) - at(t0), 2))
    step = BEAT / 4
    k = 0
    t = t0
    order = [0, 1, 2, 3, 2, 1, 3, 2]
    while t < t1 - 1e-6:
        notes, _ = chord_at(t)
        f = hz(notes[order[k % 8]]) * 2
        x = tt(step * 1.8)
        tone = (np.sign(np.sin(2 * np.pi * f * x)) * 0.5 + saw(f, len(x) / SR)) * np.exp(-x * 14)
        tone = lp(tone, 2200 * bright)
        i = at(t) - at(t0)
        out[i : i + len(x)] += tone[: len(out) - i, None] * (0.8 if k % 4 else 1.0)
        t += step
        k += 1
    return delay(out * 0.07, BEAT * 0.75, fb=0.4, mix=0.35)


# ------------------------------------------------------------ arrangement
def main(path):
    music = track()  # pads, bass, arps: ducked by the kick
    drums = track()
    fx = track()

    # intro: typing ticks under a swelling pad, the logo hit, then a riser
    for i in range(34):
        add(fx, tick(), 0.35 + i * (1.4 / 34) + rng.random() * 0.012, 0.7 + rng.random() * 0.3, pan=rng.uniform(-0.3, 0.3))
    p = pad(0, PILLARS)
    p *= np.clip(np.linspace(-0.2, 1.2, len(p)), 0, 1)[:, None]
    add(music, p, 0)
    add(fx, riser(LOGO_HIT - 1.2), 1.2, 0.5)
    add(fx, impact(0.9), LOGO_HIT)
    add(music, arp(LOGO_HIT, PILLARS, bright=0.6), LOGO_HIT, 0.8)
    add(fx, riser(1.6), PILLARS - 1.6, 0.6)

    # pillars: a slam on each word
    add(music, pad(PILLARS, FEATURES), PILLARS)
    for i in range(4):
        t = PILLARS + i
        add(drums, kick(1.1), t)
        add(drums, clap(), t, 0.8)
        add(fx, impact(0.35), t)
        add(music, bass(t, t + 0.9, "long"), t)
    add(fx, riser(1.0), FEATURES - 1.0, 0.6)

    # features + wall: the full groove
    add(fx, impact(1.0), FEATURES)
    groove_end = WALL - BAR  # a breakdown bar before the wall
    add(music, pad(FEATURES, STATS), FEATURES)
    add(music, bass(FEATURES, groove_end), FEATURES)
    add(music, arp(FEATURES, groove_end), FEATURES)
    for b in np.arange(FEATURES, groove_end, BEAT):
        add(drums, kick(), b)
        beat = round((b - FEATURES) / BEAT) % 4
        if beat in (1, 3):
            add(drums, clap(), b, 0.9)
    for h in np.arange(FEATURES, groove_end, BEAT / 2):
        off = round((h - FEATURES) / (BEAT / 2)) % 2 == 1
        add(drums, hat(open_=off and rng.random() < 0.25), h, 1.0 if off else 0.6, pan=0.25)
    for s in FEATURE_STARTS[1:]:
        add(fx, whoosh(), s - 0.45, 0.9)
    add(fx, riser(BAR), WALL - BAR, 0.7)
    add(fx, impact(1.1), WALL)
    add(music, bass(WALL, STATS), WALL)
    add(music, arp(WALL, STATS, bright=1.5), WALL)
    for b in np.arange(WALL, STATS, BEAT):
        add(drums, kick(), b)
        if round((b - WALL) / BEAT) % 4 in (1, 3):
            add(drums, clap(), b, 0.9)
    for h in np.arange(WALL, STATS, BEAT / 4):
        add(drums, hat(), h, 0.35 + 0.35 * (round((h - WALL) / (BEAT / 4)) % 2), pan=-0.2)

    # stats: half time, a blip as each number lands
    add(fx, whoosh(0.5), STATS - 0.4, 0.8)
    add(music, pad(STATS, OUTRO), STATS)
    add(music, bass(STATS, OUTRO, "long"), STATS)
    for b in np.arange(STATS, OUTRO - BAR / 2, BEAT * 2):
        add(drums, kick(0.9), b)
    for i, f in enumerate([hz("E5"), hz("A5"), hz("C6"), hz("E6")]):
        add(fx, blip(f), STATS + 0.4 + i * 0.3, 0.9, pan=-0.45 + i * 0.3)
    add(fx, riser(BAR), OUTRO - BAR, 0.7)

    # outro: the last hit, then the pad rings out
    add(fx, impact(1.1), OUTRO)
    tail = pad(OUTRO, DUR)
    tail *= np.clip(np.linspace(1.3, -0.1, len(tail)), 0, 1)[:, None]
    add(music, tail, OUTRO)
    a = arp(OUTRO, OUTRO + 3 * BAR, bright=0.9)
    a *= np.clip(np.linspace(1, 0, len(a)), 0, 1)[:, None] ** 1.5
    add(music, a, OUTRO)
    add(music, bass(OUTRO, OUTRO + BAR, "long"), OUTRO)

    # sidechain: the kick pumps the music bus
    duck = np.ones(N)
    kicks = [PILLARS + i for i in range(4)] + list(np.arange(FEATURES, groove_end, BEAT)) + list(np.arange(WALL, STATS, BEAT))
    shape = 1 - 0.55 * np.exp(-tt(BEAT) * 9)
    for k in kicks:
        i = at(k)
        j = min(N, i + len(shape))
        duck[i:j] = np.minimum(duck[i:j], shape[: j - i])
    music *= duck[:, None]

    mix = reverb(music, 2.4, 0.28) * 1.5 + drums * 0.7 + reverb(fx, 1.6, 0.2)
    mix = hp(mix, 25)
    mix = np.tanh(mix * 1.4) / np.tanh(1.4)  # soft clip glue
    mix *= 0.89 / np.max(np.abs(mix))
    fade = np.clip((DUR - np.arange(N) / SR) / 1.5, 0, 1)
    mix *= fade[:, None]
    wavfile.write(path, SR, (mix * 32767).astype(np.int16))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/music.wav")
