# Preset selection crash — 2026-09-29

## Cause confirmed from the crash report

`VeloEdit-2026-09-29-153424.ips` records `EXC_BAD_ACCESS` at address `0x10`
inside `FigVisualContextGetEarliestSequentialImageTime`, called by
`AVAssetReaderOutput.copyNextSampleBuffer` on a background worker.

The matching release dSYM (UUID `860F69DD-E522-3281-B993-A13395E94760`)
resolves the application frames to:

- Main thread: effects-browser button → `AppModel.applyEffectStackPreset`
  → `editTimelineOptimistically` → task cancellation → `AVAssetReader.cancelReading`.
- Crashed worker: `MediaSampleReader.next(from:reader:)`, line 24 in the old source
  → `AVAssetReaderOutput.copyNextSampleBuffer`.

Applying an effect preset cancels the previous film verification. Its task
cancellation handler tore down the reader while the worker was still using
the decoder's visual context.

## Fix

`MediaSampleReader` now waits asynchronously for its one outstanding sample
read to finish before checking cancellation. The caller then receives
`CancellationError` and its existing `defer` safely cancels the reader.
The reader and output are retained through the synchronous read. Decoding
continues on a dispatch worker, so waiting does not block the UI or a Swift
cooperative executor thread.

Also changed the local `parameters` array in `TransitionEffectCatalog.makePreset`
from `let` to `var`: the current catalog removes inapplicable parameters, and
the immutable declaration prevented the project from compiling.

## Validation

The regression test failed against the old helper: the reader had already
transitioned to `.cancelled` while the sample call remained blocked.
The test holds that call open deterministically without provoking a native
use-after-free. See `regression-before.log`.

After the fix, all 18 selected checks passed:

- 3 sample-reader tests: cancellation during a read, cancellation before a read,
  and normal delivery through end of stream.
- 7 professional effect/preset tests.
- 1 test rendering and exporting every effect and effect-stack preset.
- 7 timeline interaction/persistence tests.

Command:

```sh
./Scripts/dev-test.sh --filter 'MediaSampleReaderCancellationTests|tz16|EditorPreviewParityTests/everyEffectAndStackChangesPreviewAndSurvivesVideoExport|InstantTimelineInteractionTests'
```

See `regression-after.log` for results.

## Complete application bundle

`./Scripts/build-app.sh` succeeded, including complete resource packaging and
code-signature verification. The rebuilt app is `Build/VeloEdit.app`.

Build: `2026.272.125950`. Its recorded source/resource digest matches
the current working tree. See `build-identity.json` and `app-build.log`.
