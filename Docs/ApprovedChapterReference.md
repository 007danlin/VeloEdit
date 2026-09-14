# Approved chapter references

Automatic chapter headings use the approved compact presentation: Avenir Next,
72 pt, weight 0.88, left aligned, white, position (0.36, 0.78), background
#111111 / 0.75, shadow 0.25, static hold of at least 3.5 seconds. They belong to
the chapter rather than an individual shot. The prior automatic Helvetica
style migrates during regeneration; manual typography and OCR repairs survive.

`veloedit-cli use-title-reference <project.veloedit> <reference.veloedit> <name>`
saves an approved chapter reference into the target project's preferences.
Subsequent normal film builds and recovered builds apply it automatically.
Uniform chapter typography, timing and names come from the reference. Source
labels bind by content hash, so reimporting or renaming a file preserves them;
unrelated footage receives fresh activity labels. Ambiguous source files that
span multiple reference chapters do not receive a blanket label. The reference
does not import the montage's selected shots, in/out points, or durations.

The finishing pass applies approved source labels before automatic ordering and
duration allocation. Plans persist these bindings for render review, safety
repairs and recovery. A named reference never bypasses the measured-range and
rendered verification gates.

Soundtrack suitability is separate from tempo/energy. Unrequested aggressive,
abrasive or funereal moods are excluded before online, cached, local fallback
and adaptive-section selection. Energy no longer disables this check. Explicit
track requests remain authoritative. Positive bright/groove/warm descriptors
improve travel/action matching; bass instrumentation alone is not a defect.
When novelty exhausts suitable music, a suitable repeat wins over an unsuitable
unused recording. No suitable track produces an explicit unavailable result.

Validation covers pixel equality to an independent reference at 1080p/720p
and 0/1/3.3 seconds, legacy migration, source-label rebinding and fresh shot
assembly, same-tempo positive/negative music fixtures, explicit requests, and
offline novelty exhaustion. These checks do not certify subjective musical
quality for every recording; the approved current film uses the reference song.
