# Magic brush replacement and test 7 activity labels

## Reproduction

The user selected approximately 00:40–00:47 in `тест 7.veloedit` and entered `замени этот фрагмент`. The saved checkpoint identifies the clip at 40.2667–47.2333 seconds, from GX010513.MP4 at 393.6667–400.6333 seconds. The old brush only changed EQ to `presence` and added 0.5-second audio fades. Neither its asset nor its source interval changed.

GX010524.MP4 and GX010530.MP4 are two angles of a buggy ride, confirmed by inspection of original frames. Their different compositions kept them in separate source groups, preventing combined motor-vehicle evidence from correcting their `Велопрогулка` headings.

## Changes

- Replacement is a dedicated source-selection operation, preserving timing and other footage. EQ/fade commands from the model cannot stand in for it. The selection is planned atomically and saves an undo checkpoint. A missing suitable alternative leaves the cut intact and reports that replacement was not possible.
- Common replacement wording runs without calling a language model. The fast recognizer handles verb/noun combinations and alternatives such as `подбери другой момент`, `хочу другой дубль`, `этот кусок не подходит, возьми другой`, and `покажи что-нибудь другое`. Tests also cover negation and music, color, title, insertion, and reorder requests.
- Arbitrary wording can use a structured `replace_footage` model action scoped to the brush selection. Text in the assistant's reply alone never replaces footage. This action is disabled outside the brush and in advisory mode; explicit footage-preservation instructions block it in the pipeline. Ollama brush requests have a 20-second timeout; this is not a promise of total UI latency, especially with an Apple-model fallback.
- Replacement searches the selected scene's cached candidates instead of rebuilding archive-wide pairwise shot clusters. It excludes occupied intervals and a margin around the rejected episode, checks measured usable ranges, and prefers a distinct composition. This avoids replacing a rejected shot with its immediate lead-in containing the same person.
- Adjacent, temporally consistent camera files can corroborate buggy labels without merging source groups. Conflicting activities and unrelated dates prevent propagation. The confirmed activity reaches scene labels and automatic chapter headings.

## Applied to the original project

The authorized repair was saved to `/Users/daniellineckij/Downloads/тест 7.veloedit`. The replacement uses GX010513.MP4 at 353.2951–360.2618 seconds, showing the bicycle and riverbank. Eight samples spanning the replacement were inspected; the woman from the rejected shot does not appear in them. A complete 6.97-second video of the replacement was exported from the application's actual playback composition for review. A further audit decoded all 209 frames successfully and ran Vision human detection on every frame: no confident human detections (see `frame-audit.log`). This supplements the visual samples; it is not a universal identity or person-absence guarantee.

All other primary clips are unchanged. Timeline duration remains 300.0 seconds. The two buggy headings at 134.2333 and 173.1333 seconds now read `Багги`, preserving their original IDs and timing. The original manifest was backed up before the atomic write, and a checkpoint containing the complete previous timeline was added. Before committing, the original was compared byte-for-byte with the input used for acceptance validation. See `applied-to-original.json` for hashes and the backup location.

- [Complete replacement clip](replacement-full.mp4)
- [Replacement in the composed preview](replacement.jpg)
- [Buggy side angle with title](buggy-side-title.jpg)
- [Buggy front angle with title](buggy-front-title.jpg)

The previously considered source interval 384.1897–391.1564 was rejected after later frames revealed the same woman. It is not used in the repaired original or the final QA copy.

## Validation

- 70 tests passed in the real-project acceptance run, including exported replacement playback, unchanged outside shots, persistence, activity evidence, chapter titles, and atomic failure (`real-project-tests.log`). Replacement selection plus saving measured **2.26 seconds**; rebuilding the viewer is separate.
- After the final punctuation/negation handling change, seven focused tests passed (`paraphrase-tests.log`).
- The final run passed 71 tests, including reopening the repaired original, loading its original music library, building playback without skipped clips, checking duration, and confirming the undo checkpoint (`verified-tests.log`). Opt-in external-project tests return without external I/O when their environment variables are absent; the two acceptance runs enable their respective real-project checks explicitly.
- An earlier broader run found a pre-existing failure in `sourceTimelineRestoresTest3OrderAndKeepsBuggyFilesTogether`: its story plan has two scenes instead of three. A temporary helper using the exact pre-change `SourceTimelineAnalyzer` reproduced the same result. The helper was removed and the original expectations retained; see `previous-classifier-comparison.log`. This existing failure is excluded from the focused counts above.
- `./Scripts/build-app.sh` completed successfully; the full app bundle passed signature verification. Build `2026.258.081202`. The recorded application source/resource hash was independently recomputed and matches the current workspace.
- `git diff --check` passed.

The installed running instance could not be controlled through the UI automation service: app selection repeatedly timed out. Restart the rebuilt `Build/VeloEdit.app` and reopen the original `тест 7` to use the new implementation. The saved project and actual playback composition were verified directly through the application's core.
