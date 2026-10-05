# Effects and transition audit — 2026-09-29

Glitch now uses deterministic, discrete horizontal tears and a cut between shots, with channel separation around the cut. Digital distortion uses displaced pixel blocks; RGB Split remains a channel-separated dissolve. RGB recombination preserves the source alpha instead of adding two opaque alpha channels.

Other fixes: whip motion blur; triangular shatter pieces; distinct sinusoidal wave and radial ripple; radial/iris/geometric masks; corrected vertical wipe directions; opaque push seams and pixelation edges; real rotational blur; sufficient automatic camera overscan; inspector rotation applied once. Transition controls with no rendering behavior were removed; retained controls are exercised at different settings.

## Director setup

The opening survey and film settings offer **Без / Нормально / Много**. The choice is saved in `DirectorBrief.effectsPolicy`. Old projects without the field preserve previous behavior.

- Без: no decorative clip effects, transitions, photo motion, or ending picture fade.
- Нормально: up to two automatic video accents per minute, spaced at least 18 seconds apart, on at most 20% of primary clips; transitions at least 12 seconds apart.
- Много: up to six automatic video accents per minute, spaced at least six seconds apart, on at most 50% of primary clips; transitions at least five seconds apart.

Automatic accents avoid locked, short, unstable, and speech-containing clips. Explicit bans on transitions and exact duration handling still apply. Review does not add another set of effects.

## Verification

The targeted run completed successfully: 48 tests across five suites, including parameterized preview/export tests for fade-through-black, glitch, RGB split, digital distortion, and shatter. The opt-in real 4K camera playback test was skipped because no fixture path was supplied.

All transition styles were checked at five intermediate points, in landscape and offset portrait bounds, for opaque pixels. Tests also cover endpoints, meaningful parameters, glitch timing, wipe directions, camera coverage, disabled effects, old-project decoding, level-dependent composition and idempotent final review.

The real composition/export fixture exercises 61 effects and 5 effect stacks. Maximum normalized RGB mean error between preview and exported frames: 0.02432 (threshold 0.055). See `preview-export.csv` and `tests.log`.

Full application bundle built with `./Scripts/build-app.sh`; build identity is in `Build/VeloEdit.app/Contents/Resources/BuildInfo.json`.
