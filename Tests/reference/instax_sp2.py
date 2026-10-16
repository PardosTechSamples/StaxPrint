"""
Fujifilm Instax SHARE SP-2 client over Wi-Fi.

The SP-2 runs its own Wi-Fi network ("INSTAX-xxxxxxxx") and a TCP server at 192.168.0.251:8080.
Protocol as documented by jpwsutton/instax_api (MIT License, Copyright (c) 2016 James Sutton):

  Command : 24 <type> <len16> <session32> <pin16> 00 00 <payload> <~sum16> 0D 0A
  Reply   : 2A <type> <len16> <session32> 00 00 00 00 <rc> 00 <eject> <batt<<4 | prints_left> <payload> <~sum16> 0D 0A
            (all big-endian; sum16 is the byte sum of everything before it, sent inverted)
  Picture : 600 x 800 RGB, column by column, each column = 600 red, 600 green, 600 blue bytes
            -> 1,440,000 bytes sent as 24 segments of 60,000.

Every reply carries the battery level (0-7) and the number of prints left in the film pack (0-10).
"""
from __future__ import annotations

import socket
import struct
import time

HOST, PORT = "192.168.0.251", 8080
DEFAULT_PIN = 1111

CMD, RESP = 0x24, 0x2A
T_SPECS, T_RESET, T_PREP_IMAGE, T_SEND_IMAGE, T_83 = 79, 80, 81, 82, 83
T_SET_LOCK_STATE, T_LOCK_DEVICE, T_VERSION, T_PRINT_COUNT, T_MODEL, T_195, T_PRE_PRINT = 176, 179, 192, 193, 194, 195, 196

WIDTH, HEIGHT = 600, 800              # portrait, as the photo comes out of the printer
IMAGE_BYTES = WIDTH * HEIGHT * 3      # 1,440,000
SEGMENT = 60000

RETURN_CODES = {
    0: "OK", 248: "Sensor error", 247: "Wrong PIN", 246: "Motor error", 245: "Cam point error",
    244: "Film pack is empty", 243: "Frame error 1", 242: "Frame error 2", 241: "Frame error 3",
    240: "Frame error 4", 224: "Connection error", 180: "Charging", 165: "Testing", 164: "Ejecting",
    163: "Printing", 162: "Battery is empty", 161: "Not image data", 160: "Printer is in use by another device",
    127: "Updating",
}


class InstaxError(Exception):
    pass


def encode_command(cmd_type: int, payload: bytes = b"", session: int = 0, pin: int = DEFAULT_PIN) -> bytes:
    length = 16 + len(payload)
    body = struct.pack(">BBHIHxx", CMD, cmd_type, length, session & 0xFFFFFFFF, pin & 0xFFFF) + payload
    checksum = (~sum(body)) & 0xFFFF
    return body + struct.pack(">H", checksum) + b"\r\n"


def valid_packet(p: bytes) -> bool:
    if len(p) < 16 or p[-2:] != b"\r\n":
        return False
    return (sum(p[:-4]) + struct.unpack(">H", p[-4:-2])[0]) & 0xFFFF == 0xFFFF


class Reply:
    def __init__(self, raw: bytes):
        self.raw = raw
        self.type = raw[1]
        self.return_code = raw[12]
        self.ejecting = raw[14] >> 2
        self.battery = (raw[15] >> 4) & 7
        self.prints_left = raw[15] & 15
        self.payload = raw[16:-4]

    @property
    def ok(self):
        return self.return_code == 0

    @property
    def message(self):
        return RETURN_CODES.get(self.return_code, f"Error {self.return_code}")

    def u16(self, off):
        return struct.unpack(">H", self.raw[off:off + 2])[0]

    def u32(self, off):
        return struct.unpack(">I", self.raw[off:off + 4])[0]


def image_to_bytes(img) -> bytes:
    """600x800 portrait PIL image -> the SP-2 byte layout (column by column, planar R/G/B)."""
    from PIL import Image
    img = img.convert("RGB")
    if img.size != (WIDTH, HEIGHT):
        raise ValueError(f"image must be {WIDTH}x{HEIGHT}, got {img.size}")
    land = img.rotate(-90, expand=True)                       # 800 wide x 600 tall
    # Transposing turns each of the 800 columns into one contiguous 600-byte row.
    planes = [ch.transpose(Image.Transpose.TRANSPOSE).tobytes() for ch in land.split()]
    out = bytearray(IMAGE_BYTES)
    for c in range(800):
        for k, plane in enumerate(planes):
            out[c * 1800 + k * 600:c * 1800 + (k + 1) * 600] = plane[c * 600:(c + 1) * 600]
    return bytes(out)


class SP2:
    def __init__(self, host=HOST, port=PORT, pin=DEFAULT_PIN, timeout=5.0):
        self.host, self.port, self.pin, self.timeout = host, port, pin, timeout
        self.session = int(time.time() * 1000) & 0xFFFFFFFF
        self.sock = None

    # ---- connection ----
    def open(self):
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.sock.settimeout(self.timeout)

    def close(self):
        if self.sock:
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.sock.close()
            self.sock = None

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, *exc):
        self.close()

    def _recv(self, n):
        data = bytearray()
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise InstaxError("printer closed the connection")
            data += chunk
        return bytes(data)

    def command(self, cmd_type, payload=b"", timeout=None) -> Reply:
        if timeout:
            self.sock.settimeout(timeout)
        self.sock.sendall(encode_command(cmd_type, payload, self.session, self.pin))
        head = self._recv(4)
        length = struct.unpack(">H", head[2:4])[0]
        raw = head + self._recv(length - 4)
        if timeout:
            self.sock.settimeout(self.timeout)
        if raw[0] != RESP or not valid_packet(raw):
            raise InstaxError(f"bad reply: {raw[:16].hex(' ')}")
        rep = Reply(raw)
        if rep.return_code == 247:
            raise InstaxError("The printer rejected the PIN (default is 1111).")
        return rep

    # ---- queries ----
    def info(self) -> dict:
        """Model, firmware, battery, prints left and lifetime prints (one TCP session)."""
        with self:
            ver = self.command(T_VERSION)
            model = self.command(T_MODEL)
            specs = self.command(T_SPECS)
            count = self.command(T_PRINT_COUNT)
        fmt = lambda v: f"{v >> 8:02X}.{v & 0xFF:02X}"
        return {
            "model": model.raw[16:20].decode("ascii", "replace"),
            "firmware": fmt(ver.u16(18)), "hardware": fmt(ver.u16(20)),
            "battery": ver.battery, "prints_left": ver.prints_left,
            "lifetime_prints": count.u32(16),
            "max_size": (specs.u16(16), specs.u16(18)),
            "status": ver.message,
        }

    # ---- printing ----
    def print_image(self, img, progress=lambda pct, msg: None):
        """Print a 600x800 PIL image. Follows the official app's sequence, one TCP session per phase."""
        data = image_to_bytes(img)
        progress(2, "Checking printer…")
        with self:
            st = self.command(T_VERSION)
        if st.prints_left == 0:
            raise InstaxError("No prints left: load a new film pack.")
        if st.return_code not in (0,):
            raise InstaxError(f"Printer not ready: {st.message}")

        progress(5, "Preparing printer…")
        with self:
            for n in range(1, 9):
                self.command(T_PRE_PRINT, struct.pack(">xxH", n))
        time.sleep(1)
        with self:
            rep = self.command(T_LOCK_DEVICE, bytes([1, 0, 0, 0]))
            if not rep.ok:
                raise InstaxError(f"Could not lock the printer: {rep.message}")
        time.sleep(1)
        with self:
            self.command(T_RESET)
        time.sleep(1)

        progress(10, "Sending picture…")
        with self:
            rep = self.command(T_PREP_IMAGE, struct.pack(">BBIHHH", 16, 0, IMAGE_BYTES, 0, 0, 0))
            if not rep.ok:
                raise InstaxError(f"Printer refused the picture: {rep.message}")
            for seg in range(IMAGE_BYTES // SEGMENT):
                chunk = data[seg * SEGMENT:(seg + 1) * SEGMENT]
                rep = self.command(T_SEND_IMAGE, struct.pack(">I", seg) + chunk, timeout=15)
                if not rep.ok:
                    raise InstaxError(f"Transfer failed at part {seg + 1}: {rep.message}")
                progress(10 + int(70 * (seg + 1) / 24), f"Sending picture… {seg + 1}/24")
            self.command(T_83)

        progress(82, "Printing…")
        time.sleep(1)
        with self:
            self.command(T_SET_LOCK_STATE)
            self.command(T_VERSION)
            self.command(T_MODEL)
            for _ in range(45):
                rep = self.command(T_195)
                if rep.return_code == 0:
                    progress(100, "Done! Wait for the photo to develop.")
                    return rep.prints_left
                progress(85, f"Printing… ({rep.message})")
                time.sleep(1)
        raise InstaxError("Timed out waiting for the print to finish.")
