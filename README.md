# ImageSmith

A native macOS screen-capture and markup app, built for the "screenshot it, mark it
up, hand it to an agent" loop.

ImageSmith also records a display, the frontmost window, or a selected region to
MP4. Start from the menu bar or assign shortcuts under Settings → Shortcuts. A
floating timer and Stop button stay visible while recording; pressing any recording
shortcut again also stops. System audio and cursor capture are configurable.

It lives in the menu bar, has no Dock icon until you open the editor, and every
capture lands on the clipboard and on disk at the same time.

## The default flow

| Key | What happens |
| --- | --- |
| `Print Screen` (F13) | Captures the frontmost window |
| `⇧ Print Screen` | Captures the display under the pointer |
| `⌘ Print Screen` | Drag-select a region |
| **Any of them again within 2 seconds** | Opens the shot you just took in the markup editor |
| `⌥ Print Screen` | Select an area and copy its *text* (OCR) instead of pixels |
| `⌃ Print Screen` | Select an area and pin it on top of everything |

A PC keyboard's Print Screen key arrives on macOS as **F13**, which is why F13 is
the default. Mac keyboards without an F13 should rebind these under
**Settings → Shortcuts** — `⌃⇧4` and friends are unclaimed.

The double-tap window is configurable (Settings → Shortcuts). Tapping again inside
it never takes a second screenshot; it re-opens the first one.

## Why the file always gets written

Agents read files, not clipboards. Every capture is saved to
`~/Pictures/ImageSmith/` and a `latest.png` symlink is kept pointing at the newest
one, so a prompt can just say:

> read `~/Pictures/ImageSmith/latest.png`

The editor's **Copy file path** (`⇧⌘C`) and **Copy as markdown** (`⇧⌘M`) put
`/path/to/shot.png` or `![screenshot](/path/to/shot.png)` on the clipboard for
pasting into a chat. Settings → Capture can also make the *clipboard itself* carry
the path instead of the pixels.

## The editor

Opens on a double-tap, from the preview thumbnail, or from the menu bar.

| | Tools |
| --- | --- |
| Shapes | arrow, rectangle, ellipse, line, freehand pen, highlighter |
| Callouts | text, numbered step badges |
| Redaction | gaussian blur, pixelate, solid block |
| Framing | spotlight (dims everything but one region), crop |

Keyboard:

```
V select   A arrow   R rectangle   E ellipse   L line   P pen   H highlighter
T text     N step    B blur        X pixelate  D redact S spotlight  C crop
F fill     [ / ]  stroke width     ⇧-drag constrains to 15° / squares
⌘Z undo    ⇧⌘Z redo   ⌘D duplicate   ⌫ delete   arrows nudge (⇧ = 10px)
↩ copy & close   ⌘S save as   ⇧⌘C copy path   ⇧⌘M copy markdown
⇧⌘O OCR to clipboard   ⌘P pin on top   ⌘0 fit   ⌘+ / ⌘- zoom
⌃-wheel / pinch zooms at the pointer   middle-button drag pans
⌘-click temporarily switches to the select tool
```

The image fits the window and keeps fitting as you resize it, until you zoom by hand;
**Fit** (⌘0) hands control back. The editor also reopens with the tool, colour, stroke,
text size and fill you last used (Settings → Editor → *Remember tool settings*).

Marks stay editable — select, move, resize, restyle or delete any of them until you
copy. Re-saving an edited capture overwrites the file it came from rather than
littering the folder.

## Everything else

- **Region picker** with a frozen screen, 8× pixel loupe, live hex readout, live
  dimensions, and click-a-window-to-grab-it. Space toggles the loupe, Esc cancels.
- **Capture all displays** stitched into one image.
- **Repeat last capture** re-grabs the exact region you took before.
- **OCR** (Vision) including QR/barcode payloads.
- **Colour picker** copies a hex value from anywhere on screen.
- **Pinned windows** float a capture on top; double-click copies it, right-click
  closes it.
- **Preview thumbnail** after each shot: click to edit, drag to drop the file into
  any app, or ignore it and it fades.
- **Presentation options**: padding, drop shadow, gradient/solid backgrounds,
  Retina→1× downscaling, JPEG output, capture delay, cursor inclusion.
- **History** of the last N captures, with thumbnails, in the menu bar.
- **Screen recordings** share the save folder, clipboard, preview thumbnail,
  recent history, file-path actions and CLI. Click a recording preview to edit it.
  `latest.mp4` points to the newest recording when latest links are enabled.
- **Launch at login**, toggled from the menu bar or Settings → General. It reports
  what macOS actually did, so the toggle never claims to be on when the system is
  still waiting for approval under Login Items.

## Driving it from a script or an agent

```bash
Scripts/imagesmith screen        # or window | region | all | repeat | text | color | pin
Scripts/imagesmith latest        # prints the newest capture's path
Scripts/imagesmith wait 30       # blocks until the next capture, then prints its path
Scripts/imagesmith edit latest
Scripts/imagesmith record screen    # or window | region; run record stop to finish
Scripts/imagesmith tap screen    # exactly what the hotkey does, double-tap rule included
open -g imagesmith://login/enable   # or disable — launch at login
```

`screen`/`window`/`region` always take a fresh shot, which is what a script wants.
`tap` goes through the hotkey path instead, so a second `tap` inside the two-second
window opens the editor rather than capturing again.

Copy `Scripts/imagesmith` somewhere on your `PATH` to use it as a bare command. It
drives the app's `imagesmith://` URL scheme, so it works whether or not the app is
already running.

The recording editor plays MP4s, lets you select a range by dragging on the
timeline, trim to that range, remove it from the middle, undo/redo edits, mute
audio, split at the playhead, change playback speed, and export a new MP4.
The source recording stays intact. Use **Open
Recording…** from the menu bar to edit an existing movie. Still-image markup
tools apply to screenshots.

## Install and updates

Download the latest `ImageSmith-x.y.z.dmg` from
[Releases](https://github.com/newtro/ImageSmith/releases) and drag ImageSmith to
Applications. After that it updates itself: Sparkle checks daily, and **Check for
Updates…** in the menu-bar menu checks now and installs with one click.

## Releasing

```bash
Scripts/release.sh 1.2.0
```

From a clean, pushed `main`: runs the tests, builds with that version (the build
number is the commit count), signs with Developer ID and notarizes through the
Apple ID signed in to Xcode (Settings ▸ Accounts), then publishes a GitHub Release
with a zip and a DMG and pushes `appcast.xml`. Installed copies see the update as
soon as that push lands. `--draft` publishes a draft release without updating the
feed.

Updates are signed with an EdDSA key kept in the login keychain (account
`imagesmith`, created with Sparkle's `generate_keys --account imagesmith`). Back it
up with `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account imagesmith -x <file>`:
without it, installed copies can't verify future updates.

## Build from source

```bash
Scripts/install.sh
```

Builds, signs with Developer ID (like a release, so permissions carry over),
installs to `/Applications`, and launches. `Scripts/build-app.sh` alone produces
`.dist/ImageSmith.app` without installing.

Requires macOS 14+ and Xcode. Run `swift test` for the unit tests covering the
annotation geometry, the Retina-safe render pipeline, file naming, the
double-tap window and the video edit plan.

### Screen Recording permission

macOS asks once, and the grant is tied to the app's signature. Releases and
`Scripts/install.sh` both sign with Developer ID, so updates and rebuilds keep it.
If Xcode can't reach Apple (offline), `install.sh` falls back to a local
signature and macOS will ask again; `Scripts/create-signing-identity.sh` creates
that stable local identity. Keep only one copy of `ImageSmith.app` on disk: two
copies sharing a bundle ID can also cause a permission loop.

## Layout

```
Sources/ImageSmith/
  App/            NSApplication delegate, main menu, URL scheme
  Capture/        ScreenCaptureKit wrapper, region picker, capture coordinator
  Editor/         annotation model, renderer, canvas view, editor window
  Services/       preferences, hotkeys, capture store, image utilities, OCR
  UI/             menu bar, settings, thumbnail overlay, pinned windows
```

`CaptureCoordinator` is the piece that ties a hotkey to a capture, the clipboard,
the thumbnail and the double-tap-to-edit rule.
