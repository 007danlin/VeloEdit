# Automatic editorial finishing

The plain generated video storyline now receives a final assembly pass after
P6. Both Create Film and Regenerate use it through `finishFilmBuild`.

- Explicit duration capacity includes independently measured, novel atmospheric
  ranges. The automatic duration recommendation can still limit their share.
- The final edit allocates frame-aligned, non-overlapping source intervals.
  Dynamic shots are bounded to eight seconds; neighbouring shots from the
  same setup share a twelve-second limit before duration allocation. Complete speech/action phrases
  retain their evidence contract. Balanced allocation varies shot lengths.
- Capture date/time orders the source files, then source time orders their
  selected ranges. The final pass never alternates recordings for variety or
  regroups distant returns to the same activity. ISO-BMFF movie clocks cover
  cameras whose dates are not exposed as AVMetadataItem; camera numbering is
  a fallback when capture metadata is unavailable. Copy/mtime clocks never
  divide that fallback into artificial days. Camera clock offsets are not
  guessed from similar scenes or nearby GPS coordinates.
- Chapters and beats are rebuilt from the final candidate list, including P6
  additions. Only contiguous chapters in the same source activity group with the same supported label merge. Labels
  use analyzed scene/activity evidence and conservative visual descriptions.
- Chapter headings use small static typography and are anchored to the actual
  part start, independently of the length of its first shot.
- A complete preview review repairs unsafe framing and removes failed shots
  before control export. The assembly can refill with unused measured footage;
  exclusions and the repaired draft are saved for recovery.
- Independent export/frame/audio verification remains required for publication.

This policy does not own manually locked, connected or retimed storylines. It
cannot promise a requested length when non-repeating safe material is absent.
It never uses source file names, project names or manually curated movie IDs to
make editorial decisions.

The 2026-09-30 revision also orders preliminary automatic variants and accepts
mixed photo/video assemblies. Full action/speech bounds are not clamped to an
already cropped candidate. An explicit runtime cannot be padded from an
unmeasured raw recording. Every delivery report includes source-time mapping
and distinguishes confirmed reversals from uncertain clocks/order. These
checks do not certify semantic continuity or artistic quality.

`EditingDecisionRanker` is an optional, shared selector for all power modes.
`VELOEDIT_EDIT_RANKER=/absolute/path/model.json` enables a schema-validated
pairwise linear model; removing the variable restores the legacy tournament.
Models cannot bypass admission/Pareto/fresh-cut gates or increase absolute
measured technical defects relative to the legacy winner. The study model is
not enabled by default; its automatic technical labels are not human taste
judgments and do not constitute Qwen fine-tuning.

The earlier delivered “тест 5” included manual shot sequencing, duration
allocation and chapter names. Its result is a reference, not evidence that the
old app produced that edit automatically. Validate future behavior by creating
a fresh project run with no saved timeline, story plan or recovery draft.
