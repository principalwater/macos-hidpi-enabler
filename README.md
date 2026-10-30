# macos-hidpi-enabler

Switch a Mac display to HiDPI resolutions that macOS already generates but hides.
One command, nothing left running. On Intel Macs, which do not generate them, one more
command adds them.

## Why

A HiDPI mode renders the desktop at twice its size and scales it to the panel, which keeps
text sharp at sizes between native and pixel-doubled. For many external displays,
WindowServer generates these modes but marks part of them as valid for mirroring only
(IOKit `kDisplayModeValidForMirroringFlag`), so System Settings never offers them.

For example, a 2560 × 1440 Apple Thunderbolt Display on a MacBook Pro with M4 Pro offers
HiDPI only up to 1280 × 720, while WindowServer keeps hidden HiDPI modes up to
2560 × 1440. The same display on an M2 Max Mac Studio lists 2048 × 1152 HiDPI openly.

## How it works

`hidpi` reads the complete mode list through the private CoreGraphics display-mode
functions, marks the modes that public APIs hide, and switches to the one you choose with
`kCGConfigurePermanently`. WindowServer stores that choice for the current set of
displays and applies it again whenever the same set connects. There is no daemon, login
item, menu bar icon or kernel extension. On a Mac that has hidden modes for the display
there is no display override file either, and no admin rights are needed.

### Intel Macs

An Intel Mac usually has nothing to reveal. macOS builds scaled modes from a built-in list
that stops at the panel size, and it builds larger ones only from the `scale-resolutions`
list in a display's override file. Most external displays have no such list, so `hidpi`
reports no HiDPI modes above half the panel size.

`sudo hidpi add DISPLAY` writes the list once, for sizes above half of the panel up to its
full size, to
`/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-*/DisplayProductID-*`. It
never replaces an existing file. After the display reconnects, macOS generates those modes
and hides them as described above, so list and select them with `hidpi`, without admin
rights and with nothing left running. `sudo hidpi remove DISPLAY` deletes the file again.

## Usage

Requires the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/principalwater/macos-hidpi-enabler
cd macos-hidpi-enabler
swift hidpi.swift               # list displays and their HiDPI modes
swift hidpi.swift 2 2048x1152   # switch display 2 to 2048 × 1152 HiDPI and keep it
```

On an Intel Mac, build the binary and add the modes first. Then reconnect the display or
restart so that macOS reads the new file, and list them:

```sh
swiftc -O hidpi.swift -o hidpi
sudo ./hidpi add 2              # make macOS generate larger HiDPI modes for display 2
./hidpi                         # after reconnecting the display: list them
```

To keep a binary instead, build it once with `swiftc -O hidpi.swift -o hidpi`.

`DISPLAY` is an ID from the list or `main`. Append `@HZ` to pick a refresh rate;
otherwise the fastest one is used. To undo, choose any resolution in
System Settings > Displays. Abridged list for the Thunderbolt Display above:

```text
Display 2: Thunderbolt Display (main)
  current: 2048 x 1152 LoDPI, 60 Hz
  HiDPI modes:
    1024 x 576   60 Hz
    1280 x 720   60 Hz
    1600 x 900   60 Hz  hidden
    1920 x 1080  60 Hz  hidden
    2048 x 1152  60 Hz  hidden
    2560 x 1440  60 Hz  hidden
```

## Good to know

- Only modes that WindowServer generates can be selected. On M4 and M5 Macs the display
  engine limits a single-stream display to a 6720-pixel-wide frame, so a 4K display gets
  no 3840 × 2160 HiDPI mode ([details](https://smcleod.net/2026/03/new-apple-silicon-m4-m5-hidpi-limitation-on-4k-external-displays/)).
  Sizes that are missing from the list need an app that creates a virtual display, or
  `hidpi add` on an Intel Mac.
- macOS stores one setting per set of connected displays. Run the command in each
  arrangement where you want the mode, for example with the laptop lid open and closed.
- Choosing a resolution in System Settings replaces the stored mode; run the command again
  to return to it.
- The private functions are not part of Apple's SDK. If a future macOS removes them, the
  tool exits with a message and your display settings stay as they are.

## Tested

On a MacBook Pro (M4 Pro) with macOS 27.2 and an Apple Thunderbolt Display connected
through a Dell WD22TB4 dock:

- The tool switched between hidden HiDPI modes (1920 × 1080 and 2048 × 1152), and macOS
  stored the last one.
- After the display was unplugged and connected again, WindowServer restored the hidden
  2048 × 1152 HiDPI mode by itself.
- After a remote-desktop session that turned the panel off and on again, the panel came
  back in the same mode.
- On the built-in display, listing, selection and error handling work as well.

On a Mac Pro 6,1 (AMD FirePro D700) with macOS 15.7.9 through OpenCore Legacy Patcher and
an Apple Thunderbolt Display:

- macOS listed no HiDPI modes for the display at first.
- After `sudo hidpi add` and reconnecting the display, it listed hidden HiDPI modes from
  1440 × 810 to 2560 × 1440. Asking WindowServer to detect displays was not enough.
- The tool switched to 2048 × 1152 HiDPI with a 4096 × 2304 frame, and the color depth stayed
  at 30 bits. macOS stored the mode.
- Whether the mode returns after a reconnect, sleep or restart has not been tested on this
  Mac. `hidpi remove` has been tested only on a scratch folder, not with a live display.

Reports from other Macs and displays are welcome.

## Credits and license

The private mode-description layout matches the one documented by
[displayplacer](https://github.com/jakehilborn/displayplacer); no code is copied from it.
This project is not affiliated with Apple. Apple, Mac and macOS are trademarks of
Apple Inc.

MIT License, see [LICENSE](LICENSE).
