---
description: Why baguette streams Android through the official scrcpy server over adb — the protocol bytes, the connection order, and what was deliberately left out.
---

# Android — design

User guide: [README.md](README.md).

## Why the official scrcpy server

baguette's iOS path is private-API work. Android has a public, stable
route: `adb` plus the scrcpy server that Genymobile ships. Using the
**unmodified release jar** means no fork to maintain; the server version
and the first argument baguette passes must match, so they live together
(`ScrcpyLaunch.serverVersion`, `Resources/Android/scrcpy-server-v3.3.3`,
SHA-256 `7e70323b…54be0`, the value in scrcpy's own `install_release.sh`).

The older ws-scrcpy project runs a *modified* v1.19 server that speaks
WebSocket on the device. That is why it was not used: the fork stopped at
a 2021 scrcpy and the official protocol is a plain TCP pipe.

## Connection order

```text
adb push scrcpy-server-v3.3.3  /data/local/tmp/baguette-scrcpy-<scid>.jar
adb forward tcp:0 localabstract:scrcpy_<scid>        # prints a local port
adb shell CLASSPATH=… app_process / com.genymobile.scrcpy.Server 3.3.3 scid=… tunnel_forward=true …
connect(port)  → read 1 dummy byte            # video socket; retried until it arrives
connect(port)                                  # control socket
```

`tunnel_forward=true` makes the **device** listen and the host connect.
`adb forward` accepts the host's TCP connection before the device is
listening, so a connection that yields no dummy byte is retried — exactly
what scrcpy's own client does. `cleanup=false` because baguette changes no
device setting that would need restoring, and the jar is removed when the
session stops.

## Video socket (device → host)

```text
64 bytes   device name, NUL padded
12 bytes   codec id (0x68323634 "h264"), width, height          (big-endian u32)
repeat:    8 bytes  pts | flags     bit 63 = config (SPS+PPS), bit 62 = key frame
           4 bytes  size
           size bytes  Annex-B H.264
```

`ScrcpyVideoParser` is incremental and pure. A size above 16 MiB fails
the stream rather than allocating it. Only H.264 is requested; any other
codec id fails the stream with a message.

The browser decodes with WebCodecs through `frame-decoder.js`, which wants
AVCC: `H264AnnexB` builds the `avcC` description from the SPS/PPS and
rewrites each access unit's start codes as 4-byte lengths. Nothing is
decoded on the Mac.

A phone rotation restarts scrcpy's encoder; the stream carries a *new*
config packet (new SPS) and no new codec header. `H264SPS` reads the
picture size from it, and `AndroidScreen` makes every viewer wait for the
next keyframe before decoding on the new description.

## Late viewers

`AndroidScreen` caches the description. A viewer that joins gets it at
once, then only frames from the next keyframe on; attaching also sends
scrcpy's `RESET_VIDEO` so the next keyframe is immediate rather than up to
ten seconds away. A reset is visible to every viewer as a brief hitch.

## Control socket (host → device)

Big-endian. Types used: `0` keycode, `1` text, `2` touch, `3` scroll,
`4` back-or-screen-on, `5/6/7` expand notifications / settings / collapse,
`9` set clipboard, `11` rotate, `17` reset video.

A touch is `type, action, pointerId(8), x(4), y(4), width(2), height(2),
pressure(u16 fixed), actionButton(4), buttons(4)` — 32 bytes. scrcpy folds
DOWN / MOVE / UP of different pointer ids into one multi-touch event, so
two fingers are two ids. The **screen size is part of every message**:
the server drops an event whose size disagrees with the live video size.
That is why the page sends the decoded frame's size and not the CSS size.

Wheel: `AXIS_VSCROLL` is positive *up*, the browser's `deltaY` positive
*down*; `ScrcpyInput` flips it and takes 50 points as one notch.

## Text

`inject text` only types what the device's key map can produce and is
limited to 300 bytes. Short ASCII uses it (no side effects); anything
else sets the device clipboard and pastes, which clobbers the clipboard —
the trade for Unicode working at all.

## Not done

- **Audio**, camera mirroring, and recording on the Android side.
- **Gestures with no Android meaning**: iOS side buttons, edge swipes,
  the Watch crown answer `ok:false`.
- **Runtime bit-rate / frame-rate change.** scrcpy fixes them at start;
  the page reconnects with `restart=1` instead.
- **Bezels and 3D.** There is no DeviceKit chrome for an Android phone.
