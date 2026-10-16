#!/usr/bin/env python3
"""
Cross-checks the Swift encoder against the Python reference (Tests/reference/instax_sp2.py, from the
original Python app): command packets and the 1,440,000-byte image layout must be byte-identical.

Run from the repo root after `swift build` (needs Pillow: pip install pillow):
    python3 Tests/crosscheck.py
"""
import os
import random
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "reference"))
import instax_sp2 as sp2  # noqa: E402
from PIL import Image  # noqa: E402

TOOL = os.path.join(ROOT, ".build", "debug", "instax-tool")


def swift_cmd(t, payload, session, pin):
    out = subprocess.run([TOOL, "encode-command", str(t), payload.hex() or "-", str(session), str(pin)],
                         capture_output=True, text=True, check=True).stdout.strip()
    return bytes.fromhex(out)


rng = random.Random(1234)
cases = [(t, b"", 0, 1111) for t in (79, 80, 83, 176, 192, 193, 194, 195)]
cases += [(196, struct.pack(">xxH", n), 0x12345678, 1111) for n in range(1, 9)]
cases += [(179, bytes([1, 0, 0, 0]), 0xFFFFFFFF, 9999)]
cases += [(81, struct.pack(">BBIHHH", 16, 0, sp2.IMAGE_BYTES, 0, 0, 0), 1760000000, 1111)]
cases += [(82, struct.pack(">I", 7) + bytes(rng.randrange(256) for _ in range(2000)), rng.getrandbits(32), 0)]
cases += [(rng.randrange(256), bytes(rng.randrange(256) for _ in range(rng.randrange(64))), rng.getrandbits(32),
           rng.randrange(65536)) for _ in range(40)]

bad = 0
for t, payload, session, pin in cases:
    ref = sp2.encode_command(t, payload, session, pin)
    got = swift_cmd(t, payload, session, pin)
    if ref != got:
        bad += 1
        print(f"MISMATCH type {t}: ref {ref[:24].hex()} got {got[:24].hex()}")
print(f"commands: {len(cases) - bad}/{len(cases)} identical")

# Full 60,000-byte segment through the CLI would be a huge argv; check a real one via the image test instead.

with tempfile.TemporaryDirectory() as d:
    raw = bytes(rng.randrange(256) for _ in range(600 * 800 * 3))
    img = Image.frombytes("RGB", (600, 800), raw)
    ref = sp2.image_to_bytes(img)
    src, dst = os.path.join(d, "in.rgb"), os.path.join(d, "out.bin")
    open(src, "wb").write(raw)
    subprocess.run([TOOL, "encode-image", src, dst], check=True)
    got = open(dst, "rb").read()
    same = ref == got
    if not same:
        first = next(i for i in range(len(ref)) if ref[i] != got[i])
        print(f"image MISMATCH at byte {first}")
    print(f"image layout: {'identical' if same else 'DIFFERENT'} ({len(got)} bytes)")
    bad += 0 if same else 1

sys.exit(1 if bad else 0)
