#!/usr/bin/env python3
"""Record the demos that show images, in a real kitty window.

VHS can't record them: its terminal (xterm.js) has no Kitty graphics
protocol, so `vim.ui.img` draws nothing there. This script opens kitty
with docs/media/kitty/kitty.conf, drives Neovim through kitty's remote
control, captures the window a few times a second with `screencapture`
and turns the frames into a GIF with ffmpeg.

macOS only. Needs kitty, ffmpeg, swiftc (Xcode command line tools),
Neovim 0.13+ on $PATH, and Screen Recording permission for the terminal
that runs it. From the repository root:

    python3 docs/media/kitty/record.py             # every demo
    python3 docs/media/kitty/record.py images      # one of them
"""

import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
HERE = os.path.dirname(os.path.abspath(__file__))
MEDIA = os.path.join(ROOT, "docs", "media")
SOCK = "/tmp/org-nvim-kitty.sock"
FPS = 6  # frames per second captured (screencapture is not faster)


# Steps: "text" types text; ("key", "ctrl+c ctrl+c") presses keys;
# ("cap", keys, what) / ("do", keys, what) run the demo init's :Cap / :Do
# (a key caption, and for :Do also the keys); ("sleep", seconds).
DEMOS = {
    "images": (
        "images.org",
        [
            "/offsite", ("key", "enter"), ("key", "0"),
            ("sleep", 1.5),
            ("cap", "<leader>oxv", "preview the images of this entry"),
            " oxv",
            ("sleep", 2.5),
            ("cap", "4<leader>oxv", "hide them (C-u C-c C-x C-v)"),
            "4 oxv",
            ("sleep", 1.5),
            ("cap", "16<leader>oxv", "preview the whole buffer"),
            "16 oxv",
            ("sleep", 3),
            ("cap", "<C-e>", "they follow scrolling"),
            *[("key", "ctrl+e"), ("sleep", 0.35)] * 8,
            ("sleep", 1.5),
            *[("key", "ctrl+y"), ("sleep", 0.3)] * 8,
            ("sleep", 1.2),
            ("cap", "<S-Tab>", "and folding"),
            ("key", "shift+tab"),
            ("sleep", 2),
            ("key", "shift+tab"), ("sleep", 0.3), ("key", "shift+tab"),
            ("sleep", 2.5),
        ],
    ),
    "latex": (
        "math.org",
        [
            ("sleep", 1.5),
            ("cap", "<leader>oxl", "preview the LaTeX of this entry"),
            "/Euler", ("key", "enter"), ("sleep", 0.5),
            " oxl",
            ("sleep", 3),
            ("cap", "16<leader>oxl", "preview every fragment"),
            "16 oxl",
            ("sleep", 5),
            ("cap", "<leader>oxl", "on a fragment: hide it"),
            "/Gaussian", ("key", "enter"), ("key", "j"), ("sleep", 0.5),
            " oxl",
            ("sleep", 2),
            " oxl",
            ("sleep", 3),
        ],
    ),
}


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def kitty(*args):
    subprocess.run(["kitty", "@", "--to", "unix:" + SOCK, *args], check=False, capture_output=True)


def window_id(helper):
    for _ in range(50):
        out = run(helper, "kitty").strip()
        if out:
            return out.splitlines()[-1].split("\t")[0]
        time.sleep(0.2)
    sys.exit("kitty window not found")


def record(name, helper, workdir):
    file, steps = DEMOS[name]
    frames = os.path.join(workdir, name)
    shutil.rmtree(frames, ignore_errors=True)
    os.makedirs(frames)
    if os.path.exists(SOCK):
        os.remove(SOCK)
    env = dict(os.environ, ORG_DEMO_DIR="/tmp/org-demo-kitty-" + name)
    # a kitty started from tmux inherits these; image plugins then think
    # they run inside tmux
    for var in ("TMUX", "TMUX_PANE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"):
        env.pop(var, None)
    proc = subprocess.Popen(
        [
            "kitty", "--config", os.path.join(HERE, "kitty.conf"), "--listen-on", "unix:" + SOCK,
            "-d", ROOT, "nvim", "-u", "docs/media/demo/init.lua", env["ORG_DEMO_DIR"] + "/" + file,
        ],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    wid = window_id(helper)
    time.sleep(2.5)

    stamps = []
    stop = threading.Event()

    def capture():
        i = 0
        while not stop.is_set():
            t = time.time()
            path = os.path.join(frames, "f%05d.png" % i)
            subprocess.run(["screencapture", "-x", "-o", "-l", wid, path], capture_output=True)
            if os.path.exists(path):
                stamps.append((path, t))
                i += 1
            time.sleep(max(0, 1 / FPS - (time.time() - t)))

    th = threading.Thread(target=capture)
    th.start()
    for st in steps:
        if isinstance(st, str):
            kitty("send-text", st)
            time.sleep(0.25)
        elif st[0] == "key":
            for k in st[1].split():
                kitty("send-key", k)
                time.sleep(0.08)
        elif st[0] in ("cap", "do"):
            cmd = "Cap" if st[0] == "cap" else "Do"
            kitty("send-key", "ctrl+g")
            kitty("send-text", "%s %s %s\r" % (cmd, st[1], st[2]))
            time.sleep(0.3)
        elif st[0] == "sleep":
            time.sleep(st[1])
    stop.set()
    th.join()
    kitty("send-text", "\x1b:qa!\r")
    time.sleep(1)
    proc.terminate()

    # identical frames (nothing moved) become one longer frame
    kept = []
    last = None
    for path, t in stamps:
        with open(path, "rb") as f:
            data = f.read()
        if data != last:
            kept.append((path, t))
            last = data
    stamps = kept

    # frames with their real durations -> palette GIF
    concat = os.path.join(frames, "list.txt")
    with open(concat, "w") as f:
        for (path, t), nxt in zip(stamps, stamps[1:] + [(None, stamps[-1][1] + 1.5)]):
            f.write("file '%s'\nduration %.3f\n" % (path, nxt[1] - t))
        f.write("file '%s'\n" % stamps[-1][0])
    out = os.path.join(MEDIA, name + ".gif")
    scale = "scale=1280:-1:flags=lanczos"
    subprocess.run(
        [
            "ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", concat,
            "-vf", scale + ",split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];"
            "[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
            out,
        ],
        check=True,
    )
    if shutil.which("gifsicle"):
        subprocess.run(["gifsicle", "-b", "-O3", "--lossy=40", out], check=True)
    print("wrote", os.path.relpath(out, ROOT), "(%d frames, %d KB)" % (len(stamps), os.path.getsize(out) // 1024))


def main():
    names = sys.argv[1:] or list(DEMOS)
    workdir = tempfile.mkdtemp(prefix="org-nvim-kitty-")
    helper = os.path.join(workdir, "winid")
    run("swiftc", "-O", os.path.join(HERE, "winid.swift"), "-o", helper)
    for name in names:
        record(name, helper, workdir)
    shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
