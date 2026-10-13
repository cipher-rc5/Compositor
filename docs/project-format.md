# Compositor project format, versions 1–9

A `.comp` file is a macOS document package containing `manifest.json` and an `images/` directory of `<layer UUID>.png` assets.

The manifest identifies `com.compositor.project`, version `9` for new saves (versions `1`–`8` remain readable; anything else is refused with a message naming the version), and the sRGB working space. It stores document UUID, pixel dimensions, active layer UUID, optional guides, and layers in bottom-to-top order. Each layer stores its UUID, name, visibility, transform (origin, size, clockwise rotation, flips, sampling), and optional image filename (`<layer UUID>.png`). Blank layers, folders and adjustment layers have no image asset. Layer names must not be blank and are limited to 16 KiB (16,384 bytes of UTF-8).

Embedded PNGs preserve source pixels and transparency; transforms remain separate. Every asset must be a single-image PNG of at most 8 bits per component. Projects survive moving or deleting imported source photos. Saving uses a coordinated atomic package replacement. Unsupported versions, invalid metadata, missing assets, unsafe paths (anything resolving outside the package, or a symbolic link), and oversized data are rejected before replacing the live document.

Limits: 30,000 pixels per canvas/image side, 100 million total source pixels (plus a separate 100 million for masks), 10,000 layers, 1,000 guides, 4 MiB manifest, 512 MiB per encoded asset. See `Compositor/IO/ProjectStore.swift` for validation.

The manifest is written as compact JSON with sorted keys and unescaped slashes; builds up to 1.2.2 pretty-printed it, and readers accept either. The 4 MiB limit applies to the whole file, and the per-field limits together allow far more (10,000 layers with 16 KiB names alone come to 160 MiB), so validation also encodes the manifest exactly as Save would and refuses one over 4 MiB with its own error naming the cause. A document that validates can therefore always be saved, and imports are held to the same check.

Undo history and viewport are session-only. Opening fits the canvas, restores selection, and starts with clean history. Future editable features must extend the schema and round-trip tests. PNG export is a flattened derivative and does not mark project edits saved.

Image Size adds optional `resolution` (pixels/inch, 1–9600). Older manifests without it default to 72. This additive field retains version 1 compatibility. Both PNG and JPEG exports include document resolution metadata. Resampling stores the new layer pixels and bounds; undo retains the prior sources only during the current session.

## Version history

Version 2 adds optional `parentID` and `isGroup` on layer records. A group has no image file. Root nodes have no parent; children refer to an existing group. Array order defines bottom-to-top sibling order; renderers traverse each group as a contiguous subtree. Visibility is inherited without changing child flags. Cycles, missing/non-group parents, image-bearing groups, and nesting beyond 64 ancestor levels are rejected. Group ancestors permit room for leaf nodes at the deepest level. Group metadata survives image/canvas resizing and cropping. Older app builds reject version 2 rather than misrender grouped documents. Collapse state is not serialized.

Version 3 adds optional per-layer `opacity` (finite 0–1) and `blendMode`. Missing fields default to full opacity and Normal. The blend mode is stored by its menu name: Normal; Darken, Multiply, Color Burn, Linear Burn; Lighten, Screen, Color Dodge, Linear Dodge (Add); Overlay, Soft Light, Hard Light, Vivid Light, Linear Light, Pin Light, Hard Mix; Difference, Exclusion, Subtract, Divide; Hue, Saturation, Color, Luminosity. Version 3 shipped with Normal, Multiply, Screen, Overlay, Darken, Lighten, Difference, Color Dodge and Color Burn; the others were added later without a version change, so a build that predates them rejects a file using them as invalid. Group records required the defaults until version 8, which lets a folder carry its own opacity; a folder's opacity multiplies into every layer inside it, while its blend mode stays Normal because folders are pass-through. Files declaring older versions cannot contain non-default appearance values.

Version 4 adds optional `maskFile` and `maskEnabled` fields to individual layers. Mask filenames must be `<layer UUID>.mask.png` under `images/`; enabled defaults to true when a mask exists. Records without masks omit both fields. Groups cannot carry masks in this version. Files declaring versions 1–3 cannot contain mask metadata.

Masks store 8-bit grayscale coverage without alpha (white reveals, black hides). Their normalized extent matches the image’s local rectangle, so the same layer transform applies to both. A uniform 1×1 mask is valid and avoids allocating full-resolution pixels before painting. Nonuniform mask pixels and a thumbnail are immutable assets shared by history. Image Size resamples them with the image transform; Canvas Size and Crop preserve their pixels. Up to 100 million mask pixels may be stored in addition to the existing 100 million image pixels; per-side and per-file limits also apply to masks. Disabled masks remain embedded and editable but do not affect compositing. Image-versus-mask target selection is session-only and reopens on image pixels.

Version 5 adds optional `maskSourceID`: the UUID of a non-group layer supplying live alpha in document coordinates. It multiplies the target’s alpha alongside its enabled raster mask. Source pixels, transform, opacity, raster mask and upstream live masks contribute coverage; visibility and RGB color do not. Sources remain independent layers. Missing references, self-links, cycles, group endpoints and chains over 256 nodes are rejected. Deletion can bake the live coverage into dependent image pixels (retaining their raster masks) or remove the links, as one undoable operation. Links survive image/canvas resize and crop. Older versions default to no live mask; older app builds reject v5.

UI terminology: these alpha links are clipping masks. Option-click assigns the lower sibling’s base or releases the connection. Multiple clipped layers share one base, show indented above it, and release when moved outside the contiguous stack. The underlying `maskSourceID` representation is unchanged.

Version 6 allows `maskFile` and `maskEnabled` on group records. A folder has no image, so its mask covers the folder's own transform rectangle (the canvas size when the folder was created); Image Size resamples it through that transform, and Canvas Size and Crop preserve its pixels, exactly as for layer masks. Groups are pass-through, so an enabled folder mask multiplies the coverage of every descendant layer, together with that layer's own mask and any enclosing folders' masks; clipping-mask coverage is unaffected. Files declaring versions 1–5 cannot give a group a mask, and older app builds reject v6.

Version 7 adds adjustment layers: an optional `adjustment` record on a layer that has no image file and is not a group (see [Adjustment layers](#adjustment-layers)). Files declaring versions 1–6 cannot contain one.

Version 8 adds document `guides` (see [Guides](#guides)) and lets a folder carry an opacity other than 1. Files declaring versions 1–7 must not contain guides.

Version 9 adds the Gaussian Blur, Motion Blur and Add Noise adjustment kinds. Files declaring versions 7–8 may contain adjustment layers, but none of those three kinds.

## Adjustment layers

An `adjustment` record makes a layer an adjustment layer, which changes the look of what lies beneath it rather than adding pixels of its own. It requires version 7 or later, a layer without `imageFile`, and `isGroup` absent or false; it cannot be combined with `text`. Its `kind` is stored by name: `Hue/Saturation`, `Levels`, `Curves`, `Exposure`, `Gradient Map`, `Grain`, `Add Noise`, `Gaussian Blur`, `Motion Blur`, `Invert`, `Black & White` or `Color Balance`. `Add Noise`, `Gaussian Blur` and `Motion Blur` require version 9. `Black & White` and `Color Balance` were added without a version change, so a build that predates them rejects a file using them as invalid.

The record holds every kind's settings; only those of its `kind` take effect, and settings fields added after version 7 are optional, so older records decode unchanged:

- Hue/Saturation: `hue` (±360), `saturation` and `lightness` (±100), `colorize`, and optional `hsvSettings` with per-range adjustments and band handles (when absent, the four plain fields are used).
- Levels: `levels`, four channel ranges, each already normalized.
- Curves: `curves`, four channels of 2–32 points with x strictly increasing from 0 to 255 and y within 0–255.
- Exposure, Gradient Map, Grain, Black & White, Color Balance: optional `exposureSettings`, `gradientMapSettings`, `grainSettings`, `blackWhiteSettings`, `colorBalanceSettings`; a missing record means that adjustment's defaults.
- Gaussian Blur: optional `blurRadius` (0.1–250 px, default 10).
- Motion Blur: optional `motionAngle` (−90–90°, default 0) and `motionDistance` (1–2000 px, default 10).
- Add Noise: optional `noiseAmount` (0.1–400, default 10), `noiseGaussian` and `noiseMonochromatic` (default false), and `noiseSeed` (UInt32, default 0), so the same file always draws the same noise.

Out-of-range values make the project invalid. Adjustment layers survive Canvas Size, Image Size, Crop and Trim unchanged.

## Guides

Version 8 adds an optional document-level `guides` array (omitted when there are none). Each guide has a UUID `id`, an `axis` of `horizontal` or `vertical`, and a `position` in document pixels (Y for a horizontal guide, X for a vertical one), which must be finite and within ±1,000,000; positions may lie outside the canvas. IDs must be unique and there may be at most 1,000. Canvas Size, Crop and Trim shift guides with the content, Image Size scales them, and Flip Canvas mirrors the ones perpendicular to the flip. Guide locking, visibility, the layout grid and Snap To settings are app preferences, not part of the file.

## Mask placement and linking

A layer mask normally covers the layer's own rectangle and follows its transform. Two optional fields, readable by any version that allows the mask, record a mask moved apart from its layer:

- `maskPlacement`: a full transform (origin, size, rotation, flips, sampling) giving where the mask sits on the document. It requires `maskFile` and must itself be a valid transform. Absent means the mask covers the layer.
- `maskLinked`: whether moving or transforming the layer carries the mask along. Absent (as in older files) means linked. An unlinked mask stays where it is on the document while the layer moves.

Canvas Size, Crop and Trim move a placement with the content, and Image Size scales it.

## Shape layers

Pixel layers drawn with the Shape tool may include optional `shape` metadata so they can be redrawn sharply when scaled: `kind` (`Rectangle`, `Ellipse` or `Line`), RGB fill color (`red`, `green`, `blue`, 0–1), `cornerRadius` in document pixels (rectangles round by at most half their shorter side; ellipses ignore it), and, for lines only, `lineWidth` and `start`/`end` points as fractions (0–1) of the layer's box. The PNG remains the display and export fallback, and older readers ignore the field and keep the pixels. Canvas Size, Crop and Trim keep the metadata; Image Size and any edit that replaces the pixels drop it, leaving an ordinary pixel layer. The shape is only honored while it still describes the saved pixels.

## Editable text

Pixel layer records may include optional `text` metadata: content (up to 100,000 UTF-16 units), PostScript font name, font size in pixels (1–2000), RGB color, alignment, tracking (−100–1000), line spacing (0–5000; 0 means automatic) and optional `boxSize` paragraph bounds (16–30,000 px per side). Text wraps inside these bounds; changing them reflows the text without scaling the font. A text record requires an image file and cannot appear on a folder or adjustment layer. The PNG remains the display and export fallback. Older readers ignore this metadata. Transforms, duplication, masks, Canvas Size, Crop and Trim preserve it; Image Size and destructive pixel operations rasterize text and omit the metadata on the next save. Missing fonts use the system font when edited, while the saved PNG preserves the original appearance until then.

## Layer effects

An optional `effects` record contains independent `stroke`, `shadow` (drop shadow), `colorOverlay`, `innerShadow`, `outerGlow` and `innerGlow` records. Colors are `red`, `green`, `blue` in 0–1 and opacities are 0–1.

- Stroke: `size` (0–500 layer pixels), color, opacity, and `inside` choosing which side of the edge it sits on.
- Drop shadow and inner shadow: `angle` (−360–360°), `distance` (0–5000), `blur` (0–500), color and opacity.
- Color overlay: color and opacity.
- Outer glow and inner glow: `size` (0–500 layer pixels), color and opacity. An inner glow lights the layer's edges from the inside.

Each supports optional `enabled` visibility (missing means visible); hidden effects keep all parameters and remain listed under their layer. Effects, including their visibility, are saved and participate in document undo. Effects are kept apart from pixels, so they survive edits that replace a layer's pixels (painting, filters, adjustments) as well as Canvas Size, Image Size, Crop and Trim. Canvas previews run on a serial background worker with a shared pixel budget; exports render the full-resolution effects. A record omitting an effect means that layer does not have it, so older readers see the effects they understand and ignore the rest. Effect values are checked when a project opens and when it is saved: an `effects` record with an out-of-range value, or an `effects` or `shape` record on a folder, makes the whole project invalid, so it is refused rather than opening with effects that could not be drawn or exported.
