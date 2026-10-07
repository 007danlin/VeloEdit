# First-launch artwork

The app icon in `Resources/AppIcon.icns` is unchanged. The introduction uses
`Resources/FirstLaunch/IntroIcon.png` and a 1024 px derivative, tagged sRGB.

`IntroIcon-refined.png` is the selected native 1254 × 1254 RGBA generation.
`IntroIcon-generated.png` is the first, rougher material study. Both were made
with the built-in imagegen tool from `assets/icons/ai-video-editor-app-icon-v3-bright.png`.
The selected generation prompt is in `generation-prompt.txt`.

The background, halo, beams, typography and transition are separate editable
SwiftUI layers in `Sources/VeloEdit/FirstLaunchView.swift`. They are not baked into
the icon. Runtime image decoding occurs off the main actor, once per presentation.
At 1× the 1024 px image covers the largest scene; Retina loads the native image.
The visible size is capped using the image's occupied height and the 1.12 exit
scale so the current bitmap is never enlarged beyond available screen pixels.

## Remaining artwork acceptance work

The tool returned 1254 × 1254 even when explicitly asked for native 4096 × 4096.
No enlarged bitmap is being represented as a detailed 4K master. A native 4K
editable material master, aligned silhouette/lighting masks and its 2048 px
runtime derivative remain to be supplied. The current generated glass has
mostly opaque interior alpha; its physical transparency and edge cleanliness
still need an artist pass. This is a usable implementation asset, not sign-off
on all artwork criteria in the specification.

After replacing the artwork, update `FirstLaunchArtwork`'s native pixel size and
occupied-height ratio, export runtime sizes, inspect dark/light composites and
rebuild the complete app with `./Scripts/build-app.sh`.
