<p align="center"><img src="assets/staxprint-logo.svg" alt="StaxPrint" width="420"></p>

# StaxPrint

A native macOS app that prints your photos to a **Fujifilm Instax® SHARE SP-2** over Wi-Fi.
It's written in Swift with SwiftUI, Core Image and Metal, so the preview stays smooth while you move,
zoom, tilt and colour-correct a photo.

- **Printer Wi-Fi.** Joins the printer's `INSTAX-xxxxxxxx` network and switches back to your usual Wi-Fi
  afterwards. A light shows whether the printer is reachable.
- **Printer status.** Shows the model, firmware, battery, prints left in the pack ("6 / 10") and lifetime prints.
- **Photo.** Opens or takes a dropped JPEG, PNG, HEIC, TIFF and more.
  - Colours are converted to sRGB, and iPhone HDR photos (Display P3 / PQ) are tone-mapped so they don't come
    out washed out.
  - Fill (crop) or Fit (white border), plus 90° rotate.
  - Trackpad: two-finger scroll moves, pinch zooms, two-finger rotate tilts. Mouse: drag moves, ⌘-scroll zooms.
    Double-click resets.
  - Brightness, contrast, saturation and tilt sliders, all live on the GPU.
- **Print.** Renders exactly what the preview shows at 600×800, asks before using a print, then shows progress.

## Build and run

Needs macOS 14+ and Xcode 15+ (or the Swift 5.10+ toolchain).

```bash
swift run StaxPrint                                  # run from source
./scripts/make-app.sh && open build/StaxPrint.app    # build a release .app (ad-hoc signed)
```

If macOS blocks Wi-Fi switching or local-network access, start it from Terminal.app.

## Using it

1. Turn the SP-2 on, type its network name (printed on the printer, e.g. `INSTAX-12345678`) and press
   **Join printer Wi-Fi**. While you're joined, your Mac has no internet over Wi-Fi, because the printer's
   network is a direct link.
2. Enter the PIN (factory default **1111**) and press **Connect**.
3. Open a photo, frame it, and press **Print photo**.
4. Press **Back to my Wi-Fi** when you're done. The printer also turns itself off after a few idle minutes.

The log is also written to `~/Library/Logs/StaxPrint.log`.

## Command-line tool

```bash
swift run instax-tool status                         # printer status (uses no film)
swift run instax-tool render photo.heic out.png mode=fit tilt=5   # save the exact 600x800 print as PNG
swift run instax-tool fake-server 18080              # a fake SP-2 on 127.0.0.1 that saves what it receives
INSTAX_HOST=127.0.0.1 INSTAX_PORT=18080 swift run StaxPrint     # point the app at the fake printer
swift run -c release instax-tool bench photo.heic    # preview frame timing
```

## Tests

```bash
swift test                     # packets, image layout, rendering, full print sequence against the fake printer
python3 Tests/crosscheck.py    # byte-for-byte check against the Python reference (needs Pillow)
```

## How it works

The SP-2 is a TCP server at `192.168.0.251:8080` on its own Wi-Fi network. Each command is a big-endian packet:
`24 type len16 session32 pin16 00 00 payload ~sum16 0D 0A`. A picture is sent as 600×800 RGB, turned to
landscape and written column by column, with each column as 600 red, then 600 green, then 600 blue bytes.
That's 1,440,000 bytes in 24 segments of 60,000.

| Path | What's there |
| --- | --- |
| `Sources/InstaxKit` | `Protocol.swift` (packets and replies), `ImageLayout.swift`, `TCPSocket.swift`, `SP2Client.swift` (status and print sequence), `PhotoRenderer.swift` (load, colour-manage, compose, render) |
| `Sources/StaxPrint` | The SwiftUI app; `PreviewView.swift` is the Metal preview and handles the gestures |
| `Sources/InstaxFake` | Fake SP-2 server for tests |
| `Sources/instax-tool` | Command-line tool |
| `assets/` | Logo and app icon; regenerate them with `swift scripts/make-logo.swift` |

## Credits

The protocol comes from [jpwsutton/instax_api](https://github.com/jpwsutton/instax_api) (MIT License,
© 2016 James Sutton). StaxPrint is released under the MIT License.

"Instax" and "SHARE SP-2" are trademarks of FUJIFILM. They're used here only to describe compatibility.
StaxPrint isn't affiliated with or endorsed by FUJIFILM.
