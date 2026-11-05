---
description: Stream an Android phone or emulator into the browser and drive it — touch, keys, text, Back / Home — over adb and the official scrcpy server. Use when you want an Android device beside your simulators, or to script one over HTTP and WebSocket.
---

# Android

An Android phone, emulator or Wi-Fi-connected device appears beside the
simulators: listed on `/simulators`, opened at `/android/<serial>`, its
screen live in the browser and fully controllable — tap, drag, pinch,
scroll, type, paste, and the system keys.

Baguette runs the **official, unmodified [scrcpy](https://github.com/Genymobile/scrcpy)
server** (v3.3.3, Apache-2.0) on the device. The phone encodes H.264
itself; the Mac passes it to the browser without decoding or
re-encoding it.

## Quick start

1. Install `adb` (Android platform-tools): `brew install android-platform-tools`.
2. Enable **USB debugging** on the phone, plug it in, accept the prompt.
   Check it shows as `device`: `adb devices`.
3. Serve and open it:
   ```bash
   baguette serve
   open http://127.0.0.1:8421/simulators      # the phone is listed under Android
   ```

The first stream pushes the server jar and starts it, which takes a few
seconds. Later opens of the same phone share the running session; it
stops five seconds after the last viewer leaves.

Wi-Fi debugging works the same once `adb connect <ip>:5555` has run.

## On the page

| Do | Result |
|---|---|
| Click / drag the screen | one finger |
| `Alt`-drag | two-finger pinch (the second finger mirrors the first) |
| Touch screen, two fingers | real multi-touch |
| Right-click / middle-click | Back / Home |
| Mouse wheel | scroll |
| Type with the screen focused | key presses (US layout) |
| `⌘V` / `Ctrl+V` | the clipboard is typed into the phone, Unicode included |
| Toolbar | Back, Home, Recents, Power, Wake, volume, notification shade, quick settings, rotate, screenshot |
| Stream → Size / Bitrate / Frame rate | restarts the stream with the new settings |

## HTTP and WebSocket

```text
GET  /android.json                  phones adb lists, or why none (adb missing)
GET  /android/:serial               the page
GET  /android/:serial/screenshot.png   one PNG via `adb exec-out screencap`
POST /android/:serial/input         one gesture envelope → its ack
WS   /android/:serial/stream        video down, gestures up
       ?maxSize=1600&bitrate=8000000&fps=60&restart=1
```

`:serial` is the adb serial, URL-encoded (`192.168.1.9:5555` carries a
colon). The stream options apply when this connection starts the phone's
session; `restart=1` replaces a running one. `maxSize=0` keeps the
native resolution. Bit rate is clamped to 0.5–40 Mbit/s and frame rate to
1–120.

Video is the AVCC message framing of the [simulator stream](../../serve.md#one-websocket-per-stream)
(`0x01` description, `0x02` keyframe, `0x03` delta), so any client of the
simulator's `avcc` stream can play it. Text frames back are `{"ok":false,"error":…}`
when the phone cannot be streamed — `adb` missing, device `unauthorized`
or `offline`, the server failed to start.

### Gestures

The shared gestures of [wire.md](../../wire.md) work on Android (`tap`,
`swipe`, `touch1-*`, `touch2-*`, `pinch`, `pan`, `button`, `key`, `type`,
`scroll`), with coordinates in the units of the `width` × `height` you
send — the pixel size of the decoded frame. Three are Android-only:

```json
{"type":"pointer-down","id":0,"x":360,"y":640,"width":720,"height":1280,"pressure":1}
{"type":"nav","action":"back"}
{"type":"text","text":"你好, world"}
```

- `pointer-down` / `pointer-move` / `pointer-up` — one finger by `id`;
  keep several ids down for multi-touch.
- `nav` — `back`, `home`, `recents`, `notifications`, `settings`,
  `collapse`, `rotate`, `wake`.
- `text` — short ASCII is typed as key events; anything else goes through
  the phone's clipboard and a paste.

`button` accepts `home`, `power`, `lock`, `volume-up`, `volume-down`,
`app-switcher` and `pull-down-to-notification-center`; the other iOS
buttons answer `ok:false`. `force_idr` and `snapshot` on the stream ask
for a fresh keyframe; `set_bitrate`, `set_fps` and `set_scale` are
ignored — reconnect with `?restart=1` and new options instead.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "adb was not found" | Install platform-tools, or set `BAGUETTE_ADB=/path/to/adb`. Looked up: `BAGUETTE_ADB`, `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, Android Studio's SDK, Homebrew, `PATH`. |
| Listed but "Unauthorized" | Unlock the phone and accept the USB debugging prompt. |
| "device said: … version mismatch" | `BAGUETTE_SCRCPY_SERVER` points at a jar that is not v3.3.3. |
| Black screen, secure app | Some apps (banking, DRM) block capture; scrcpy shows black for them. |
| Input does nothing on Xiaomi / some Android skins | Enable **USB debugging (Security settings)** in Developer options. |

Why it works this way — protocol, ids and the decisions behind them:
[design.md](design.md).
