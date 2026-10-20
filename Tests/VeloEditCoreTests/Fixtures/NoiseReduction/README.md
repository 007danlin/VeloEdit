# Speech enhancement fixture

`speech.wav` is a synthetic, mono, 48 kHz PCM recording of this original test
sentence: “The quiet voice should stay clear while background noise is removed.”
Created locally using macOS `say`, Samantha voice, 170 words/minute, then
resampled with `afconvert`. No microphone recording or personal audio is used.

Tests add deterministic noise to this clean reference. They measure noise
attenuation, speech correlation, signal-to-distortion improvement, timing and
channel isolation. This small synthetic fixture is a regression test, not a
claim of equivalent results on every speaker or real recording.
