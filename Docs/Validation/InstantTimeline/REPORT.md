# Instant timeline interactions

Date: 2026-09-15

## Behavior

Direct timeline edits now publish their result synchronously, including deletion,
cut/paste, duplication, video/audio splitting, audio detachment, clip settings,
transition settings, and effect/telemetry duplication. Undo and Redo use the same
visible timeline. Persistence and preview composition run in the background.

Rapid edits coalesce into the latest save and preview. Refresh preserves a pending
visible edit. An AI operation that overlaps a manual edit does not publish its
older result into the editor or Undo history; the manual result is committed
before the existing AI retry/rebase mechanism continues. Deleting the final clip
clears the old player immediately. Saving drains any edit queued during a save.

Video/audio splitting and audio detachment share synchronous mutation functions
with the pipeline. Splitting accelerated audio preserves the correct source
window. Clip locking also updates the analysis candidate during persistence.

## Validation

- Complete release bundle rebuilt with `VELOEDIT_BUILD_SNAPSHOT=1 ./Scripts/build-app.sh`.
  Build identity matches `source-identity.json`; `codesign --verify --deep` passed.
  Logs and final identity are saved in `app-build.log` and `build-identity.json`.
- `focused-tests.log`: 66 tests passed on a fixed source snapshot, including preview/export parity,
  timeline objects, AI comments, and interaction regressions.
- Six new integration tests exercise synchronous state updates, immediate
  Undo/Redo, consecutive delete/cut/paste/duplicate operations, refresh during
  autosave, reopening the saved result, clearing the final clip and its linked
  objects, clip/transition settings, independent effect copies, and accelerated audio splitting.
- Recorded deletion state-update time: **1.52 ms** with 120 timeline clips.
  This measures the command's synchronous state update, not the display's next
  refresh or completion of video composition.

Media generation, AI interpretation, saving, and preview rendering can still
take time. The direct edit appears before that background work completes.
