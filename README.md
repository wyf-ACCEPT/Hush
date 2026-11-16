# Hush

A small ad-free macOS video player for personal use. libmpv does the playback; Hush is a thin AppKit shell (about 900 lines of Swift). It was built as a replacement for OmniPlayer, which locks ad removal and custom speed behind a VIP subscription.

## Build & run

```bash
brew install mpv          # libmpv 0.42+, with MoltenVK/ffmpeg deps
./build.sh                # -> build/Hush.app (ad-hoc signed)
open build/Hush.app
build/Hush.app/Contents/MacOS/Hush video.mkv   # CLI also works
```

The app links `/opt/homebrew/lib/libmpv.dylib` dynamically, so it only runs on a Mac with Homebrew mpv installed. Run `./build.sh` again after `brew upgrade mpv` if the libmpv major version changes.

## Features

- Plays anything mpv can. VideoToolbox hardware decoding is on (`hwdec=auto-safe`).
- **Multiple windows**: each window is an independent player with its own mpv instance, so several videos can play at once.
  - Open a new window from the Dock icon's right-click menu ("新建窗口"), from File → 新建窗口, or with ⌘N.
  - Files opened from Finder go to an idle window, or to a new window if every window is already playing.
  - ⌘O and Open Recent replace the video in the current window.
  - `q` closes the current window. The app keeps running after the last window closes; clicking the Dock icon opens a new one.
- **OmniPlayer-style native UI with an orange theme.** mpv's OSC is turned off.
  - Bottom frosted control bar: a progress line along its top edge (hover it to see the time under the cursor), then previous / rewind / play / forward / next, a volume slider, the time in the centre, and speed / subtitles / settings / pin-on-top / full screen on the right.
  - The controls and title hide 2 s after the mouse stops moving and stay visible while paused.
  - Idle screen: a dashed "+" drop zone in the middle and a "最近播放" strip of Quick Look thumbnails along the bottom.
- **Speed**: the panel offers a slider from 0.25x to 4x, eight presets, ±0.05 buttons and a free input box (0.1–8). Keys: `[` / `]` change speed by ±0.05, `{` / `}` by ±0.25, and Backspace resets to 1.0. The speed button turns orange whenever speed is not 1x. The last speed is remembered across launches.
- Subtitles and audio: the subtitle button lists subtitle tracks, loads an external file, and shows or hides subtitles. The audio-track menu sits under settings. Subtitles in the same folder load automatically (fuzzy match) with GBK/Big5 codepage detection.
- Remembers the playback position per file (`watch_later` lives in `~/Library/Application Support/Hush/`).
- Scroll vertically for volume and horizontally to seek. Right-click pauses, double-click toggles full screen, and dragging the picture moves the window. Screenshots (`s`) go to the Desktop.

## Layout

| File | Role |
|---|---|
| `Sources/Hush/AppDelegate.swift` | Owns the player windows; open routing, Dock menu, recents menu, debug snapshot hook |
| `Sources/Hush/PlayerWindowController.swift` | One window = one player: content view, actions, auto-hide, track menus, speed popover |
| `Sources/Hush/ControlBar.swift` | Bottom bar, time bubble, title overlay |
| `Sources/Hush/IdleView.swift` | Drop zone + recent-files strip |
| `Sources/Hush/SpeedPanel.swift` | Speed popover |
| `Sources/Hush/Theme.swift` | Colours, `IconButton`, `TrackSlider`, `ChipButton`, `RecentFiles` |
| `Sources/Hush/MPVController.swift` | mpv handle, options, observed state, render API calls |
| `Sources/Hush/VideoLayer.swift` | `CAOpenGLLayer` that mpv renders into |
| `Sources/Hush/VideoView.swift` | Forwards keyboard / mouse buttons / wheel to mpv; window drag |
| `Sources/Hush/Menu.swift` | Main menu (Chinese); player commands go through the responder chain |
| `Resources/input.conf` | Key overrides on top of mpv defaults |
| `tools/ipc.py` | Talks to a running Hush started with `HUSH_IPC=/tmp/hush.sock` |
| `Sources/Hush/Thumbnailer.swift` | Seek-bar previews: hidden second mpv per window, software renderer, keyframe then exact refine |
| `tools/make_icon.swift` | Regenerates `Resources/AppIcon.icns` (sliced play triangle) |
| `tools/set_default.swift` | Makes `/Applications/Hush.app` the default for 18 video extensions plus mp3 (webm stays with Chrome) |

## Design notes

- OmniPlayer, inspected with `nm` and `strings`, uses a patched mpv 0.37 with `vo=gpu-next`, `gpu-context=darwinvk`, and a `CAMetalLayer` passed as `wid`. Upstream and Homebrew mpv have no `darwinvk`: their `macvk` always creates its own window. So Hush uses the render API with OpenGL instead, the same approach as IINA and mpv's own cocoa-cb.
- Rendering follows mpv's cocoa-cb `gl_layer.swift`. Each mpv update triggers `display()` on a dedicated serial queue. If Core Animation declines to draw (it throttles windows that are hidden or covered), the frame is still consumed with `MPV_RENDER_PARAM_SKIP_RENDERING`. Without that, mpv waits for the frame and then counts it as dropped. While the window is fully occluded, Hush skips `display()` entirely and only consumes frames. Once the window is visible again, it repaints once.
- `BLOCK_FOR_TARGET_TIME=0`: the layer's vsync already paces frames, and also sleeping inside `render()` pushed every frame past its deadline.
- Measured on a 1080p30 H.264 file with VideoToolbox: 30 draws/s at about 1–3 ms each, `frame-drop-count` 0, and avsync about 0, including through a hide/show cycle.
- In the idle state `force-window` makes mpv report a placeholder 640x360 video size. Hush ignores it, otherwise the window would shrink.
- The system recent-documents list ignores apps that don't use NSDocument, so recent files are kept in UserDefaults (`recentFiles`).
- Debug switches:
  - `HUSH_DEBUG=1` prints visibility, draws/s, skips/s and render time to stderr. In this mode, `kill -USR1 <pid>` also renders each window's UI layers to `/tmp/hush-snap-N.png` and the speed panel to `/tmp/hush-snap-speed.png`. The video and the blur are not captured, but it works while the screen is locked.
  - `HUSH_IPC=<sock>` opens mpv JSON IPC: window 1 uses `<sock>`, window N uses `<sock>.N`.
