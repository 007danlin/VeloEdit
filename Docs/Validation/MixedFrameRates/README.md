# Mixed frame rates — 2026-10-05

## Delivery contract

The film has one frame rate, shared by editing, preview and default delivery.
Encoding quality and AI mode cannot select a different rate. A manual export
override remains available and never rewrites the saved timeline.

New automatic films (including vlogs) and new manual timelines opt into
`TimelineFrameRatePolicy`. Existing saved timelines without the optional
`automaticallySelectFrameRate` field retain their clock; rebuilding an automatic
film selects its rate using the new policy. This avoids silently reinterpreting
an existing fixed-rate edit. Subsequent edits to opted-in timelines resolve the
clock in both the immediate editor state and persisted project state.

The policy weights the duration of the actual edited primary footage, ignores
unused imports and freeze frames, and uses connected camera footage only when
there are no primary video clips. Repeated cuts do not outvote a longer clip.
The dominant family is 30/60, 25/50 or 24/48, with 30/60 preferred on a tie.
Integer and 1000/1001 variants remain distinct. The high-rate variant is selected
when footage with useful high-rate motion accounts for at least 5% of the moving
video duration. Automatic selection never exceeds 60 fps; explicit delivery
rates up to 240 remain supported.

Motion rate uses source duration / edited duration, matching actual playback,
including the segment means and final scaling used for speed ramps. Thus
30+60 normally chooses 60, 29.97+59.94 chooses 59.94, and 120 slowed to 25%
contributes 30 fps, not 120. When integer/fractional cameras are mixed, actual
high-rate segments decide which high-rate clock to use, weighted by duration.

Rate conversion samples existing source frames. It does not change clip speed,
audio timing or invent motion. A 30 fps insert in a 60 fps film still has only
30 motion samples per second. Incompatible families cannot all map to a single
constant rate without dropping or repeating some frames. Optical-flow synthesis
is deliberately not enabled automatically.

## Timing and interchange

- Composition and edit time use a shared 6 MHz clock, representing standard
  integer and fractional rates without the former 1/600-second accumulation.
- Mixed-rate or retimed 4K preview uses the compositor instead of bypassing
  frame-rate conversion through the native-camera optimization.
- Mixed/retimed footage uses the tweening compositor even without effects.
  The neutral AVFoundation compositor can elide repeated frames: a 30/60/slow
  sequence exposed a variable 40 fps average despite a 60 fps frameDuration.
- Generated photos and title cards use rational frame timestamps. Their cache
  identities distinguish fractional rates and invalidate older rounded assets.
- Generated video explicitly sets both track and movie time scales. A precise
  frame timestamp alone does not prevent rounding in the MOV movie header.
- FCPXML preserves rational sequence and per-source rates and source trim times;
  retiming uses frame sampling, consistent with the local renderer.

## Validation

`MixedFrameRateTests` checks policy, retiming, persistence, fixed-rate project
compatibility, export overrides, FCPXML and accumulation across 1,000 cuts.
Its numbered-video fixtures encode a binary index in every source frame.
Decoded MP4 pixels and timestamps must match the expected sequence for 30/60
and 29.97/59.94, with and without effects, high/low delivery rates, cuts
and 50% slow motion. This detects loss of real high-rate frames even if the MP4
container reports the requested FPS.

The focused regression run passed: **38 tests in 5 suites**, including export
resolution/detail, five transition types, and decoded source-audio comparison
in five mixing configurations. Optional real-GoPro tests were skipped because
no real-source environment variable was supplied. The mixed-rate checks use
generated, timestamp-verified numbered source videos.

```sh
swift test --disable-sandbox --enable-swift-testing --disable-xctest \
  --scratch-path /tmp/veloedit-frame-rate-build --jobs 2 \
  --filter 'MixedFrameRateTests|ExportSettingsTests|TransitionPlaybackRegressionTests|TimelinePlaybackMapTests|SourceAudioMixPolicyTests|mixedMediaFilm|FCPXML|fcpxml|overlappingFadeAndDuckingRampsDoNotCrashPlaybackBuild|exportGeometryPreservesPortraitAndLandscapeAspectRatios'
```

Evidence is saved under `Build/Validation/MixedFrameRates`: `tests.log` and
`bundle-source-hashes.json`. The full application bundle build is validated
separately below.

Full bundle build succeeded with `./Scripts/build-app.sh` using an isolated
scratch directory and source snapshot. `codesign --verify --deep --strict
Build/VeloEdit.app` also passed. Build identity: `2026.278.170731`, source SHA-256
`b6012b789b5a6347b39225e5e47513169d568e829809ea7fffe64a3d35bfa59e`.
The validation directory also contains `build-app.log`, `BuildInfo.json` and
`app-binary.sha256`. No application UI controls were added or redesigned by
this change.
