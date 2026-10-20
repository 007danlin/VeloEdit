# RNNoise in VeloEdit

The inference sources and default model are copied unchanged from the official
RNNoise 0.2 release. `UPSTREAM.json` pins the release archive, revision, model and
SHA-256 of every copied file. `COPYING` contains the upstream license.

SwiftPM builds the explicit inference-only `CRNNoise` target. No upstream build
scripts, training scripts, runtime downloads or external model paths are used.
ARM64 uses the upstream NEON implementation; Intel uses baseline SSE2 without
requiring AVX2. The default weights are compiled into the executable.
`compat/os_support.h` supplies the missing Opus `OPUS_CLEAR` alias referenced by
the upstream ARM/generic vector code; upstream sources and weights are unchanged.

`SpeechNoiseReducer` supplies 480-sample frames at 48 kHz, scaled to signed
16-bit PCM amplitude units, with one recurrent state per channel. It compensates
RNNoise 0.2's two-hop delay, flushes the tail, and mixes the aligned dry/wet
signals according to the existing strength control. Processing precedes EQ,
effects and normalization. Audio intermediates use float PCM, never AAC.

The app bundle includes the license and provenance in `Resources/Legal`.
This is speech enhancement, not speaker separation or music restoration.
