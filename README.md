# Compositor

Adobe Photoshop costs too much and tools like GIMP don’t feel familiar enough for me to stay in flow. That’s why I built Compositor.

The goal was to create a full-featured image editor that is completely free and open source. I use Photoshop for compositing and post-processing, so Compositor is built around that workflow - with the tools needed to create a pixel-perfect final image.

Because it’s open source, you can download the Xcode project and add, remove, or modify any feature to fit your workflow.

## Features

### Layers
- Layers and folders, with blend modes and opacity — a folder's opacity dims everything inside it
- Layer masks: paint, fill, invert, blur and feather them; link or unlink them to transform a mask on its own
- Clipping masks and folder masks
- Adjustment layers: Hue/Saturation, Levels, Curves, Exposure, Gradient Map, Grain, Black & White, Color Balance, Invert, Gaussian Blur, Motion Blur and Add Noise
- Layer effects: Stroke, Drop Shadow, Color Overlay, Inner Shadow, Outer Glow and Inner Glow, rendered on the GPU, editable at any time, and kept through pixel edits, resizing, cropping and trimming
- Merge Down, Merge Layers and Merge Group (⌘E)
- Duplicate, rename inline, reorder and nest by drag and drop; Option-drag to duplicate
- Drag layers between open projects

### Transform
- Non-destructive move, scale, rotate and flip — images keep their full resolution however small you make them
- Free distort (⌘-drag a handle), with Shift to lock to an axis
- Transform several layers, or a whole folder, together
- Snapping to canvas and layer edges and centers, with guides
- Exact values for position, size, scale and angle, stepped with the arrow keys
- Flip Layer and Flip Canvas, horizontal and vertical

### Selections
- Rectangle and Ellipse Marquee, Freehand and Polygonal Lasso, and the Magic tool — Wand selects by color, Object traces whatever you click (Tab switches)
- Select Subject, and Expand, Contract and Feather on any selection
- Add to and subtract from selections, move the outline, or move and duplicate the pixels inside
- Load a layer's pixels or a mask as a selection
- Content-Aware Fill, which can also extend an image past its edges

### Painting and retouching
- Brush with size, hardness, opacity and smoothing, in Paint or Erase mode (B and E), and Shift for straight lines
- Spot Healing Brush (content-aware)
- Clone Stamp, aligned or not, sampling one layer or all of them
- Blur, Smudge and Liquify (R): soften, drag color along, or push pixels; Blur works on masks too
- Gradient tool and Shape tool (rectangles, rounded rectangles, ellipses and lines), which stay editable rather than being rasterized
- Type tool (T): inline multiline editing in draggable, resizable paragraph boxes; font, size, color, alignment and spacing in the tool header; transform text and use it as a clipping mask
- Eyedropper and a full color picker

### Adjustments and filters
- Levels (with Auto), Curves, Hue/Saturation, Black & White, Color Balance, Exposure, Gradient Map, Grain and Invert
- Camera Raw Filter, in a panel beside the canvas: Light, Color, Effects, Curve, Color Mixer, Color Grading, Detail, Optics, Geometry and Calibration, with a live histogram
- Gaussian Blur and Motion Blur that spread past a layer's edges
- Add Noise, Lens Correction and Remove Background
- Live previews, limited to the selection when there is one

### Canvas and files
- Multiple projects in tabs
- Crash recovery: unsaved projects are snapshotted every 30 seconds and when the app goes to the background, and offered back on the next launch after a crash
- Rulers (⌘R), guides dragged from them, a layout grid, and Snap To for guides, grid, layers and document bounds
- Crop with snapping, and Option for symmetric cropping
- Canvas Size, Image Size, and Trim (away transparent pixels, or the top-left or bottom-right pixel color, from the edges you choose)
- Sharp high-quality downsampling when zoomed out, and a pixel grid when zoomed in
- Import JPEG, PNG, HEIC, TIFF, camera RAW and Photoshop PSD. RAW files (every format macOS can develop, DNG included) open through a develop step for exposure, white balance and tone before they become 8-bit pixels. PSD import is 8-bit RGB only (not PSB or CMYK). PSD folders, masks, a subset of blend modes, and fill rectangles/ellipses stay editable; text and other vectors become pixels. A conversion report is shown before anything is applied.
- Export JPEG with a live preview (⇧⌥⌘S); Copy Merged
- Photoshop-style keyboard shortcuts throughout, remappable in Edit > Keyboard Shortcuts
- Automatic updates, signed and notarized

## Requirements

- macOS 26.5 or later
- Xcode 26.5 or later (to build from source; CI builds with Xcode 26.6 and 27.0)

## Development

[`just`](https://github.com/casey/just) (`brew install just`) wraps the common tasks; `just` on its own lists
every recipe. See [CONTRIBUTING.md](CONTRIBUTING.md) for the conventions changes are held to.

- `just hooks` — once per clone: runs the CI gate before every `git push` (`git push --no-verify` skips it once).
- `just ci` — the CI gate (`scripts/ci.sh`): a clean build of the app and tests that fails on any compiler
  warning, then the unit tests.
- `just test-sanitized` — the unit tests under Address and Undefined Behavior Sanitizers, for the C pixel
  kernels in `Compositor/Rendering/*.c` (`scripts/test-sanitized.sh`; slower, so not part of the gate).

### Building

Open `Compositor.xcodeproj` and run the shared **Compositor** scheme. Or `just dev` builds a Debug build and
launches it; `just build`, `just deps`, `just update` and `just clean` do what they say.

### Logging

The app logs to the unified log under the subsystem `com.wonderassembly.compositor` (one category per area:
Recovery, Effects, Adjustments, Tools, Window, Shortcuts). To follow it:

```sh
log stream --predicate 'subsystem == "com.wonderassembly.compositor"' --level info
```

### Testing

`just test` runs the unit suites (`CompositorTests`). These run unattended.

`just test-ui` runs the XCUITest suites, which drive the real app. They need a
logged-in desktop and Xcode Helper allowed under System Settings › Privacy &
Security › Accessibility; without that the runner is killed at startup with
"Timed out while enabling automation mode". `just test-all` runs both.

### Continuous integration

The same gate runs in two places. Locally, `just ci` runs `scripts/ci.sh`, `just hooks` runs it before every
push, and `scripts/release.sh` runs it before building a release. On GitHub, the
[CI workflow](.github/workflows/ci.yml) runs the same `scripts/ci.sh` on every push to `main` and every pull
request, with Xcode 26.6 (macOS 26) and Xcode 27.0 (macOS 27), and keeps the test results of a failed run.
The [Sanitizers workflow](.github/workflows/sanitizers.yml) runs `scripts/test-sanitized.sh` weekly, on demand,
and on pull requests that change the C sources. Dependabot proposes Sparkle and GitHub Actions updates weekly.

## Releasing

`scripts/release.sh` (`just release`) runs the CI gate, builds a Release version, signs it with Developer ID,
notarizes and staples it, and packages it into `dist/Compositor-<version>.dmg`, printing its SHA-256. It
records the commit it built beside the DMG.

It needs, all kept outside this repository:

- a **Developer ID Application** certificate in the login keychain
- notarization credentials saved with `xcrun notarytool store-credentials "compositor-notary" …`
- [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`)

`scripts/publish.sh` (`just publish`) then creates the GitHub Release `v<version>` with `Compositor.dmg`,
`Compositor.dmg.sha256` and `Compositor.spdx.json` (an SPDX bill of materials listing the Swift packages from
`Package.resolved`), and commits and pushes the Sparkle feed, `appcast.xml`, to `main`. It needs the Sparkle
signing key in the login keychain and `gh` signed in. To check a download, run
`shasum -a 256 -c Compositor.dmg.sha256` in the folder holding both files.

### Which repository releases reach

Installed copies look for updates only at the feed URL built into the app: `SUFeedURL` in
`Config/Info.plist`, which is `https://raw.githubusercontent.com/robbietilton/Compositor/main/appcast.xml`,
the original project's feed. Updates must also be signed with the key whose public half is `SUPublicEDKey`.
This repository keeps both as they are, on purpose, so builds of it update from the original project's
releases.

`publish.sh` publishes to the GitHub repository of the `origin` remote (or `REPO=owner/name`), and refuses
unless that repository's feed is the one in `SUFeedURL`, the keychain's Sparkle key matches `SUPublicEDKey`,
it is run on `main` with a clean tree that matches `origin/main`, the DMG was built from exactly that commit,
and the CI workflow passed on it (`SKIP_HOSTED_CI=1` skips only that last check, for a repository without
GitHub Actions). So a fork can't publish a release its users would never be offered, nor one signed with a
key they can't verify. A fork that wants to ship its own updates changes `SUFeedURL` to its own
`appcast.xml` and `SUPublicEDKey` to its own key (`generate_keys`, from Sparkle) in a commit, and only then
releases and publishes; copies installed before that change keep following the old feed.

## License

MIT — see [LICENSE](LICENSE).
