//! Shared gauge infrastructure.
//!
//! Gauge renderers share telemetry range derivation, label formatting, and the
//! translated low-fill cap. Arc bodies and ordinary linear RRects retain their
//! own geometry.
//!
//! Module ownership:
//! - `metric` — telemetry selection, range derivation, fill, and labels.
//! - `track_path` — local frames and the translated low-fill cap primitive.
//! - `linear` — rectangular continuous and segmented gauges.
//! - `arc` — continuous arcs, rounded wedge segments, and corner gauges.

pub mod arc;
pub mod linear;
pub(crate) mod metric;
pub(crate) mod track_path;
