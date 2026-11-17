#!/usr/bin/env python3
"""Make a terminal recording fast but readable.

    trim-gif.py in.gif out.gif [--speed 1.5] [--max-hold 1.2] [--end-hold 2.5] [--width 1200]

Long pauses (waiting for a sync, the agent thinking between keys) are cut to
--max-hold seconds, everything else plays --speed times faster, and the last
frame holds for --end-hold seconds so the result can be read. With ffmpeg on
the PATH the GIF is then scaled to --width pixels with a fresh palette.
Standard library only; it rewrites the delay in each frame's graphic control
extension and leaves the pixels alone.
"""
import argparse, os, shutil, subprocess, sys, tempfile


def sub_blocks(data, i):
    while True:
        n = data[i]
        i += 1
        if n == 0:
            return i
        i += n


def frames(data):
    """Yield the byte offset of each frame's delay field."""
    if data[:3] != b"GIF":
        sys.exit("not a GIF")
    i = 13
    if data[10] & 0x80:
        i += 3 * (2 << (data[10] & 7))
    while i < len(data):
        b = data[i]
        if b == 0x3B:
            return
        if b == 0x21:
            label = data[i + 1]
            if label == 0xF9:
                yield i + 4
            i = sub_blocks(data, i + 2)
        elif b == 0x2C:
            flags = data[i + 9]
            i += 10
            if flags & 0x80:
                i += 3 * (2 << (flags & 7))
            i = sub_blocks(data, i + 1)
        else:
            sys.exit(f"unexpected block 0x{b:02x} at {i}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("src")
    p.add_argument("dst")
    p.add_argument("--speed", type=float, default=1.5)
    p.add_argument("--max-hold", type=float, default=1.2)
    p.add_argument("--end-hold", type=float, default=2.5)
    p.add_argument("--width", type=int, default=1200)
    a = p.parse_args()

    data = bytearray(open(a.src, "rb").read())
    offsets = list(frames(data))
    if not offsets:
        sys.exit("no frames with delays")
    before = after = 0
    for n, off in enumerate(offsets):
        cs = data[off] | data[off + 1] << 8
        before += cs
        if n == len(offsets) - 1:
            new = round(a.end_hold * 100)
        else:
            # GIF delays are centiseconds; browsers treat under 2 as 10.
            new = max(2, round(min(cs / 100 / a.speed, a.max_hold) * 100))
        data[off], data[off + 1] = new & 0xFF, new >> 8
        after += new

    tmp = tempfile.NamedTemporaryFile(suffix=".gif", delete=False)
    tmp.write(data)
    tmp.close()
    if shutil.which("ffmpeg") and a.width:
        vf = (f"scale='min({a.width},iw)':-1:flags=lanczos,split[a][b];"
              "[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp.name, "-vf", vf, a.dst], check=True)
        os.unlink(tmp.name)
    else:
        shutil.move(tmp.name, a.dst)
    print(f"{len(offsets)} frames, {before / 100:.1f}s -> {after / 100:.1f}s, "
          f"{os.path.getsize(a.src) // 1024} KB -> {os.path.getsize(a.dst) // 1024} KB")


if __name__ == "__main__":
    main()
