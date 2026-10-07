# First-launch implementation validation

Date: 2026-10-06.

## Implemented

- A root-level graphite scene covers the content, sidebar and model-setup banner.
  Editor hit testing, toolbar controls and accessibility are suppressed while it
  is presented. Window buttons remain native.
- Time-based appearance, four feathered beams, one settling movement, exact
  Russian copy, and a 0.70 s light transition. Skip uses a 0.12 s dissolve.
- Return and Escape are handled from the first frame, scoped to this window.
  Duplicate actions are ignored. Project commands immediately preempt the scene.
- Completion persists at action acceptance. Interrupted first launches take
  precedence over autosaved geometry. Existing projects/geometry migrate before
  the window registers its autosave name.
- “Настройки” → “Основные” → “Посмотреть вступление” preserves the current workspace
  and restores the previous responder. No extra project is created.
- Reduce Motion presents a settled scene; backgrounding settles entrance motion
  or completes an exit. Artwork decoding, timers and keyboard monitors have
  cancellation/cleanup paths. Missing artwork falls back to the system icon.
- One native haptic request occurs for a pointer activation of “Начнём”. Keyboard
  activation, skipping and automatic entrance do not request haptics. No audio.

## Automated verification

`./Scripts/dev-test.sh --filter 'FirstLaunchTests|DirectorModelSetupTests|SettingsPersistenceTests|InstantTimelineInteractionTests'`

35 tests in 4 suites passed. First-launch tests cover migration, interruption,
completion persistence, early input, duplicate actions, cancelling stale tasks,
project-command priority, replay context, Reduce Motion, backgrounding, timing,
raster sampling budget and missing-resource fallback. The optional frame-render
test does no work unless its two review environment variables are provided.

The final scene was additionally rendered and inspected at 980 × 700 pt and
1440 × 900 pt with 2× backing. The resulting PNGs are in this directory; the
`-1x` PNG is a downsampled review copy. A hard halo edge found during this review
was replaced with a gradient that reaches full transparency before its bounds.
The 13 first-launch tests passed with frame rendering enabled. Seven distribution
packaging tests also passed. The final `./Scripts/build-app.sh` completed with
exit code 0 after the visual corrections, producing the complete universal app.
Its ad-hoc signatures verified. The control-frame test also passed using the
resources from `Build/VeloEdit.app`.
The built executable passed `--self-check`, contains both arm64 and x86_64, and
its two bundled PNGs are byte-identical to the inspected source resources.

Review frames can be produced from the packaged assets and actual SwiftUI scene:

```sh
VELOEDIT_INTRO_REVIEW_DIR="$PWD/Docs/Validation/FirstLaunch" \
VELOEDIT_INTRO_APP_BUNDLE="$PWD/Build/VeloEdit.app" \
./Scripts/dev-test.sh --filter FirstLaunchTests.renderControlFrames
```

## Environment and limits

MacBook Air (Mac16,13), Apple M4, 32 GB RAM; macOS 27.0.1 (26A434).
Built-in 2880 × 1864 Retina display. Background model preparation is not disabled
by the introduction; downloads still follow the existing consent state.

The native UI automation service returned timeoutReached on both connection
attempts. Consequently physical first/repeat launch, VoiceOver navigation,
Force Touch feel, live focus restoration, video capture, displayed-frame timing
and measured process-memory delta are not signed off by this report. Offscreen
control frames do not substitute for a 60 Hz on-device performance recording.

Artwork is about 2.8 MiB in the bundle, below the 20 MiB resource budget. The
4K layered master, 2048 px derivative and proper glass interior alpha remain
open; see `assets/first-launch/README.md`. The 100 MiB memory target and 95% of
displayed intervals ≤20 ms target require measurement, not inference from file
size or unit-test timing.
