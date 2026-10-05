# Automatic film delivery — 2026-09-15

Automatic creation and regeneration now retain the best available playable edit when the bounded editorial repair/search finishes with quality findings. Editorial findings, severities, evidence and the strict production-quality grade remain unchanged. A separate render-bound `FilmDeliveryReport` records completion and warnings after final playback verification.

The selector still prefers a passing variant. When all variants fail quality checks it selects an available edit instead of returning no winner. Rendered repairs cannot remove the last primary shot or break an already satisfied duration request. At the atomic commit, creating the film is fulfilled while an unmet secondary instruction is recorded as rejected, with its reason retained.

This policy applies to new films, regeneration and saved-draft recovery. Cancellation, stale project revisions and actual unreadable media are still handled as operational conditions; editorial quality findings no longer discard a playable movie. Failure text no longer invents an existing previous working version.

## Reproduction

The original `тест 7.veloedit` contains a 300-second recovery draft and no committed timelines. Its review has one `unsafeReframe` finding for a 2.3-second shot from GX010505.MP4, at approximately 20.17–22.47 seconds. Validation runs on the cloned project under `Build/AutomaticDeliveryQA/test7.veloedit`.

## Validation

- Initial focused run: 17 tests passed, including persistent framing, occlusion and duplicate findings, recovery, duration preservation, report persistence and invalidation after an edit.
- Real test 7 recovery: passed in 264.6 seconds. The flagged shot was replaced, runtime remained 300.0 seconds, the project committed one timeline and reopened, recovery was cleared and the job finished as completed. Final review and delivery warnings were empty. A fresh control MP4 was encoded and verified.
- Expanded regression run: all 52 tests passed, including fresh creation when every variant has a quality finding, incomplete title requests, strict quality evidence, cancellation, atomic generation, project round trips and recovery.
- Full `VELOEDIT_BUILD_CLI=1 ./Scripts/build-app.sh` succeeded. The complete app and CLI were rebuilt; bundle signature verification passed. Build identity is stored in `build-identity.json`.
- `git diff --check` passed. The original Downloads project was not changed.
