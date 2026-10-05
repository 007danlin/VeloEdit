# VeloEdit reliability work, 2026-09-28

User requested 11 fixes. Existing uncommitted work was preserved.

## Findings
- Running app was Build/MusicSearch/VeloEdit.app (old QA copy).
- 1231 had five readable original videos, no saved Timeline, and a 22,789-character technical failure in chat. The university project had the same failure pattern.
- Build held 177.7 GiB of disposable QA runs and 15 application bundles. No file URL from 15 non-test projects pointed into them.

## Implemented
- Single main Window and Launch Services single-instance setting; quitting the main window cancels jobs and flushes autosave, even with Settings open.
- Task-owned process activity assertions keep renders, exports, chat work and verification running when the display locks or turns off.
- Composer accepts queued messages during a reply; cancellation releases the composer immediately and preserves unsent queued text. A stop button is available beside Send.
- Independent manual Timeline creation with no AI analysis/model prerequisite.
- New imports prompt to include materials; acceptance requests story reconstruction. The pending prompt is persisted in workspace state. Analysis is no longer a required standalone media action.
- Expanded legacy extension recognition and cancellable FFmpeg compatibility conversion to project-owned Media/Converted; filenames and original files preserved. Explicitly selected unsupported files produce readable messages in the media panel.
- FFmpeg and non-system libraries bundled with relocatable load paths and license metadata by Scripts/bundle-ffmpeg.py.
- Recovery assembly uses available source ranges beyond the AI shortlist while respecting explicit exclusions; recovery does not restart failed evidence mining.
- Legacy technical chat errors are retained under project Logs and shortened in the chat. Quality findings remain in the delivery report instead of flooding chat.
- Progress time remains visible with monotonic elapsed duration; numerical film ETA is withheld until pace/calibration supports it.

## Cleanup
See cleanup.json. Removed paths totalled 186.34 GiB by summed allocated-size accounting, including obsolete compiler caches. Because APFS clones share blocks, the observed physical free-space gain was approximately 47 GiB at that checkpoint, not 186 GiB. Historical test source files were preserved in historical-test-sources.zip; live projects and original media were not removed.

## Validation in progress
- First interaction suite: 7 passed.
- Conversion, recovery, timer and new interaction checks: 22 passed before final UI refinements.
- Full bundle build succeeded via VELOEDIT_BUILD_CLI=1 ./Scripts/build-app.sh; strict deep codesign verification and bundled FFmpeg self-test passed. Spotlight now returns only Build/VeloEdit.app.
- Real 1231 rebuild running on its existing project with the release CLI; analysis finished and variant verification is running. Manifests backed up in project-backups.
- Added cancellable, 60-second bounded Apple speech continuation and a scene-scaled VLM output budget after the real run stalled on an unbounded model response. Interrupted that self-owned CLI run; completed source analysis remains saved.
- Final interaction/core set passed 30 tests before these last changes; speech/vision regressions queued behind the full build.
- Remaining: final tests, full bundle verification and UI smoke checks; confirm 1231 playable output and inspect/recover university project if needed; final temporary test cleanup.

## API references
- https://developer.apple.com/documentation/foundation/processinfo/activityoptions
- https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html
- https://ffmpeg.org/ffmpeg.html

- Speech/vision/timer/format regressions: 19 core + 3 app tests passed, including actual pmset assertion acquisition/release while the Mac was locked.
- Computer Use cannot run because Mac is locked. Asked user to unlock asynchronously; no answer yet. Continue independent project processing.

## Completed project and cancellation checks
- 1231 was restored to a 60-second, 1920×1080 timeline with 16 source fragments and completed autonomous job. Saved Exports/1231-96E069DD.mp4 (HEVC, AAC, 30 fps, 60.000 seconds); a full independent FFmpeg decode passed. Sampled frames contained real source footage.
- Recovery regression with failed vision inference and an obsolete one-second shortlist passed: the four-second film was delivered from available material.
- Shared VLM cache now resumes a cancelled consumer immediately, preserves other consumers, and cancels the producer when its last consumer leaves. Late completion cannot replace a retry or populate the cache. The streaming reader exits at the protocol terminal event.
- Cancellation/cache/AI-mode regression round: 12 tests passed.
- A second full app bundle build is running after the final cancellation changes. The university project continues its original balanced-mode analysis.

## Additional real-project finding
- The university project completed and produced a verified playable 97.067-second film, but its explicit request was 120 seconds. Added final runtime recovery after quality repair: preserve existing clips; append only unused, decodable source windows; exclude forbidden intervals; regenerate soundtrack and invalidate/recheck export evidence.
- Duration recovery and automatic delivery suites: 10 tests passed; the optional external test7 fixture remained disabled.
- Resuming a checkpoint of the saved 97-second edit to apply the repair without rerunning completed model analysis. Previous timeline and a manifest backup are preserved. A complete release bundle build is running.

## Completed
- University runtime repair used the new final recovery path and produced 31 fragments / 120.000 seconds. Saved a 1024×576 HEVC/AAC MP4; full independent decode passed. Actual export duration 119.991667 seconds, within one frame.
- Latest complete release bundle build succeeded (150.40 seconds Swift build), strict deep codesign passed, source hash matches package identity. Release CLI playback frame verified the restored project.
- Archived five old university chat failures; both restored workspaces now show completed film messages with no pending build flag.
- Compiler cache and all task-owned /tmp/veloedit-* data removed after their processes completed; compressed traces retained with the report. Optional CLI uses a symlink to the bundled Rust helper.
- Only limitation: direct UI smoke checks require the Mac to be unlocked. Model, pipeline, conversion, power assertion, playback and export checks passed.
