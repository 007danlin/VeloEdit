//! Continuous arc reveal-transition tests.
//!
//! The rounded start cap uses a translated clip for very small fills and a
//! partial annular track thereafter. These tests protect the non-empty tiny
//! fill and the geometric handoff between those two representations.

use super::super::gauges::arc::{arc_gauge_geometry, ArcGaugeGeometry, ArcTrackSpec, RevealClip};
use super::super::gauges::track_path::TRACK_PATH_EPSILON;

#[test]
fn reveal_clip_handles_zero_and_tiny_fills() {
    let geometry = arc_gauge_geometry(160.0, 160.0, 180.0, 12.0, 2.0);
    let rounded = ArcTrackSpec::full(geometry, 12.0, 6.0);
    let minimum_positive_fill = 0.000_001;

    assert!(rounded.reveal_clip(0.0).is_none());
    assert!(rounded
        .reveal_clip(minimum_positive_fill)
        .and_then(|clip| clip.path(&rounded))
        .is_some());
    assert!(rounded
        .with_end_corner_radius(0.0)
        .reveal_clip(minimum_positive_fill)
        .and_then(|clip| clip.path(&rounded))
        .is_some());
}

#[test]
fn reveal_clip_translates_below_threshold_and_anchors_above() {
    let geometry = ArcGaugeGeometry {
        center_x: 80.0,
        center_y: 80.0,
        inner_widget_center_x: 80.0,
        inner_widget_center_y: 80.0,
        radius: 64.0,
        start_angle: 180.0,
        sweep_angle: 180.0,
    };
    let source = ArcTrackSpec::full(geometry, 12.0, 6.0);

    match source.reveal_clip(0.001).unwrap() {
        RevealClip::TranslatedCap(cap) => {
            assert!((cap.corner_radius - 6.0).abs() < TRACK_PATH_EPSILON);
            assert!(cap.cap_offset < 0.0 && cap.cap_offset > -12.0);
        }
        clip => panic!("expected translated cap below threshold, got {clip:?}"),
    }

    match source.reveal_clip(0.06).unwrap() {
        RevealClip::Track(spec) => {
            assert!((spec.geometry.start_angle - 174.644).abs() < 0.01);
            assert!((spec.end_corner_radius - 6.0).abs() < TRACK_PATH_EPSILON);
        }
        clip => panic!("expected track above threshold, got {clip:?}"),
    }

    match source.reveal_clip(0.5).unwrap() {
        RevealClip::Track(spec) => {
            assert!((spec.geometry.start_angle - 174.644).abs() < 0.01);
            assert!((spec.sweep_angle - 90.0).abs() < 0.001);
            assert_eq!(spec.end_corner_radius, 6.0);
        }
        clip => panic!("expected track at halfway, got {clip:?}"),
    }
}
