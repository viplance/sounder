# Sounder app icon

The active master is `Sounder-master.png`: the original lime, mint and cyan folded S artwork with an opaque midnight navy background. The background is part of every rendition so Spotlight and Dock display the same dark fill. `Sounder-master-transparent.png` is retained as a transparent reference.

Run `npm run build:icons` on macOS to regenerate `Sounder/Assets.xcassets/AppIcon.appiconset`. Every slot is resized directly from the master with macOS `sips`, never from a smaller derivative.

The catalog includes 16, 32, 128, 256 and 512 point icons at both 1× and 2×: 10 images in total. `Sounder-AppStore-1024.png` beside the master is a separate lossless 1024 × 1024 PNG for App Store use. The 64, 128, 256, 512 and 1024 pixel catalog renditions use HEIC at quality 85; the 16 and 32 pixel renditions retain PNG. Each rendition is resized directly from the PNG master before encoding. All current catalog renditions use the opaque dark-background master, including HEIC variants. HEIC inputs were verified with the installed Xcode 27.1 asset compiler for the macOS 14 deployment target. The catalog is included in the Sounder target's Resources phase and selected by `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in Debug and Release.

This supplies app icon artwork, not App Store submission or signing configuration.

Apple references: [Configure an app icon](https://developer.apple.com/documentation/xcode/configuring-your-app-icon) and [Add an App Store icon](https://help.apple.com/xcode/mac/current/en.lproj/dev4b0ebb1bb.html).

## Generation prompt

### Transparent-background edit (built-in imagegen)

Use case: background-extraction. Clean up the transparent Sounder S icon in image 1 using image 2 as the precise shape and color reference. The first transparent cutout has ragged, noisy edges and loose colored speckles; fix all of them. Return one smooth continuous folded S ribbon with perfectly clean vector-quality antialiased contours. Remove ALL detached speckles, edge chatter, fringing, stray pixels and dark outlines. Preserve the exact S shape, interior blue folds and lime-to-mint-to-cyan shading from the reference. The external background AND the two open internal negative spaces must be genuine transparent alpha, not black. Keep generous existing margins and centered placement on a square canvas. No redesign, no texture, no checkerboard, no new shadow.

### Original artwork

Use case: logo-brand. Create a single finished square app icon master artwork for Sounder, a premium minimalist macOS audio recorder and multitrack editor. An unusual bold memorable abstract sound-wave S: one oversized continuous thick folded ribbon flowing into an S-shaped waveform with two generous open curves and smooth rounded ends. Extremely simple silhouette, strong negative space, centered, fills about 76 percent of canvas; readable at 16 pixels. Electric acid-lime and luminous mint ribbon, subtle cyan shaded underside, on a completely solid very deep midnight navy full-bleed square background. Crisp precision, contemporary editorial tech identity, restrained subtle sculptural depth. No microphone, headphones, equalizer bars, music note, play triangle. No text, no border, no outer rounded-square container, no cast shadow outside the symbol, no watermark, no mockup, no presentation sheet, no grid. Exactly one icon, perfectly square, 1024x1024 or higher, fully opaque, edge-to-edge background.
