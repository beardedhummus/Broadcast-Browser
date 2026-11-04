# Broadcast Browser

A native macOS web browser that turns browser tabs into video sources. Each tab
renders at an exact broadcast resolution and can feed several outputs at once:

| Output | What it is | Settings |
|---|---|---|
| **SDI Out** | Blackmagic DeckLink / UltraStudio SDI, clocked by the card's hardware | Device, any video mode the card supports (1080i/p, 720p, 2160p, SD …), embedded audio |
| **NDI®** | IP video on the local network (NDI High Bandwidth) | Source name, resolution, frame rate, groups, alpha channel, audio |
| **Syphon** | GPU texture sharing with other apps on this Mac (OBS, Resolume, MadMapper, TouchDesigner…). Built in | Server name, resolution, frame rate |
| **HDMI** | Fullscreen on any connected screen, projector or HDMI/USB-C port | Screen, scaling |
| **Record** | Movie file | H.264 / HEVC with a **bitrate** and keyframe interval, or ProRes 422 / 422 HQ; AAC or PCM audio |

Every output can also **crop** part of the canvas, for example to send only the
scoreboard to one SDI output while NDI gets the full page. Pink guides on the
canvas show the crop regions; they never go to air.

**Audio** is off by default, and each output that supports it has its own
switch. The source is either website audio (the app's mix of all unmuted tabs,
48 kHz stereo) or a 1 kHz −20 dBFS line-up tone. These are set in
*Preferences › Audio*.

**OSC remote control and feedback**: commands come in on UDP 9300 and status
goes out to 127.0.0.1:9301 (both configurable). You can start or stop the
session, a tab, or a single output; change URLs; toggle saved style changes;
and more. Status covers every value on the dashboard, plus `isLive` per tab and
per output. See [docs/OSC.md](docs/OSC.md), also available in the app under
*Help › OSC Reference*.

Frame rates: 23.98, 24, 29.97, 30, 59.94 and 60 (NTSC family) by default; 25 and
50 (PAL) can be turned on in **Preferences › Video**.

## Build & run

Requirements: macOS 14 or later, plus Xcode or the Command Line Tools.

```bash
scripts/build_app.sh
open "build/Broadcast Browser.app"
```

To enable DeckLink and Syphon, see [ThirdParty/README.md](ThirdParty/README.md).

### Permissions

* **Screen & System Audio Recording**: Broadcast Browser captures *only its own
  canvas windows* with ScreenCaptureKit (GPU, up to 60 fps). macOS still asks for
  this permission. Until you grant it, the app falls back to WebKit snapshots
  (about 30 fps, more CPU). Relaunch the app after you allow it.
* **Local Network**: required for NDI on macOS 15 and later.
* The build is ad-hoc signed, which makes macOS forget the Screen Recording
  permission after every rebuild. To avoid that, create a code-signing
  certificate (Keychain Access › Certificate Assistant › Create a Certificate…,
  type *Code Signing*) and build with
  `SIGN_IDENTITY="Your Cert Name" scripts/build_app.sh`.

## How it works

* **Each tab has its own canvas window.** That window holds the tab's web view
  at exactly the canvas resolution, sized so that 1 CSS pixel equals 1 output
  pixel: on a Retina screen a 1920×1080 canvas is a 960×540-pt window at
  `pageZoom = 0.5`, and the page sees `innerWidth = 1920` and
  `devicePixelRatio = 1`.
* **Canvas windows stay off screen.** Each one sits almost entirely off screen;
  only a single point overlaps the main display's top-left corner, under the
  menu bar. That keeps macOS rendering it at full rate, but nothing of it is
  ever visible. Nothing is attached to these windows, and every tab keeps
  rendering whether or not you are looking at it.
* **Capture**: ScreenCaptureKit captures each canvas window on its own, with
  `ignoreGlobalClipSingleWindow` set so the off-screen window isn't clipped. If
  no picture arrives, the app falls back to WebKit snapshots.
* **The browser window shows the captured picture** of the selected tab, scaled
  to fit. It is exactly what the outputs receive.
  * **Input:** clicks, typing, scrolling and hover are passed through to the
    real page. Dropdown lists and the right-click menu are drawn by the app.
  * **Overlays:** picker highlights, crop guides and safe areas are drawn in the
    browser window, so they can never reach an output.
  * **Input lock:** ⌥⌘L, or the lock button, stops stray clicks from changing a
    live page.
* **Outputs** pull the latest frame on their own clocks:
  * a drift-free thread clock for NDI, Syphon and Record
  * the card's hardware clock for DeckLink
  * the screen's refresh for Display

  Each output scales and converts the frame with VideoToolbox (BGRA → UYVY/4:2:0,
  Rec.709). Outputs with different frame rates and sizes never block each other.

### Known limits of the pass-through canvas

* **CSS hover:** `:hover` styles don't react to the pointer, because hover is
  simulated inside the page. Pages that use JavaScript hover events
  (mouseenter/mouseover) do work.
* **Date and color pickers, tooltips and the IME candidate window** open next
  to the hidden canvas window. Typing in other languages works, but the
  candidate list isn't visible.

## Customizing sites ("Customize" inspector)

All editing happens in **Edit Mode** (⌘E, or the *Edit* button). Edit Mode turns
on the element picker, style editing and the Web Inspector.

* **On a tab that's live**, entering Edit Mode makes its outputs **hold their
  last clean frame** until you click *Done*. Nothing from editing reaches air:
  no inspector highlights, no half-typed values. You can change this in
  *Preferences › Capture*.
* **Going live always leaves Edit Mode first**, which also closes the Web
  Inspector.

* **Pick Element** (⇧⌘C), or right-click › *Customize This Element*.
* Edit font family, size, weight and style, color, background, alignment, case,
  line height, letter spacing, text shadow presets, opacity, padding, corner
  radius, or hide the element. You can also add any CSS property.
* Apply a change to *this element*, to *all elements like it*, or to a custom
  selector.
* Fonts: add Google Fonts by name, or import .ttf/.otf/.woff files. Imported
  fonts are embedded into the page, so they work on any site.
* **Isolate**: show only one element and hide everything else. Useful for
  scoreboards and tickers, especially with a transparent background for
  keying.
* Custom CSS and custom JavaScript, both re-applied on every load.
* Every change is saved with the tab in the session and re-applied
  automatically.
* **Web Inspector** (⌥⌘I) opens WebKit's full developer tools in a separate
  window. Edits made there are temporary, and its hover highlights are drawn
  inside the page.

## Sessions & preferences (JSON)

* **Sessions** (`~/Documents/Broadcast Browser Sessions/*.json`) store each
  tab's:
  * URL, name and canvas size
  * zoom and transparency
  * style rules, fonts, custom CSS/JS, auto-reload and user agent
  * every output's configuration

  They also store the window layout and the *Go Live When Session Opens* flag.
* **Preferences**: `~/Library/Application Support/Broadcast Browser/preferences.json`
* **Bookmarks**: `bookmarks.json` in the same folder. Use *Window › Bookmarks*
  to import or export.

## Keyboard shortcuts

| | |
|---|---|
| ⌘T / ⌘W | New tab / close tab |
| ⌘L | Address bar |
| ⌘R | Reload |
| ⌘= / ⌘- / ⌘0 | Zoom in / out / actual size |
| ⌘↩ / ⇧⌘↩ | Go live / stop the selected tab |
| ⌥⌘↩ / ⌥⇧⌘↩ | Go live / stop all tabs |
| ⌘E | Edit Mode |
| ⇧⌘C | Pick an element to customize |
| ⌥⌘I | Web Inspector |
| ⌥⌘L | Lock / unlock canvas input |
| ⌥⌘G | Safe-area guides |
| ⌥⌘D | Dashboard |
| ⌘D | Bookmark the page |
| ⇧⌘] / ⇧⌘[, ⌘1…⌘9 | Switch tabs |

## Self-test

```bash
BB_SELFTEST=1 BB_SELFTEST_OUT=/tmp/bb-test "build/Broadcast Browser.app/Contents/MacOS/BroadcastBrowser"
```

The self-test loads a test scoreboard, applies styles, runs NDI and Record
outputs, switches tabs to confirm that parked tabs keep broadcasting, and then
writes `report.json` plus PNG renders of each window.
