//! Segmented arc wedge-geometry tests.
//!
//! These regressions ensure rounded bars remain annular wedges rather than
//! becoming rounded rectangles, and that configured bar extents are not
//! shortened while converting linear track lengths into angular spans.

use super::super::gauges::arc::{
    rounded_segment_geometry, rounded_segment_path, segment_geometries, ArcGaugeGeometry,
};
use super::super::gauges::track_path::TRACK_PATH_EPSILON;
use crate::normalize::ResolvedBarGeometry;

fn test_geometry() -> ArcGaugeGeometry {
    ArcGaugeGeometry {
        center_x: 80.0,
        center_y: 80.0,
        inner_widget_center_x: 80.0,
        inner_widget_center_y: 80.0,
        radius: 64.0,
        start_angle: 180.0,
        sweep_angle: 12.0,
    }
}

#[test]
fn rounded_segment_retains_annular_outer_and_inner_arcs() {
    let geometry = rounded_segment_geometry(test_geometry(), 12.0, 6.0);

    assert!(geometry.outer_arc.sweep_angle > 1.0);
    assert!(geometry.inner_arc.sweep_angle < -1.0);
    assert!((geometry.outer_arc.radius - 70.0).abs() < TRACK_PATH_EPSILON);
    assert!((geometry.inner_arc.radius - 58.0).abs() < TRACK_PATH_EPSILON);
    assert!(rounded_segment_path(test_geometry(), 12.0, 6.0).is_some());
}

#[test]
fn segments_use_the_full_resolved_bar_extent() {
    let track = ArcGaugeGeometry {
        sweep_angle: 180.0,
        radius: 50.0,
        ..test_geometry()
    };
    let bars = ResolvedBarGeometry {
        count: 4,
        gap: 3.0,
        extent: 10.0,
    };
    let segments = segment_geometries(track, bars);

    assert_eq!(segments.len(), 4);
    assert!((segments[0].start_angle - track.start_angle).abs() < f32::EPSILON);
    assert!(
        (segments[0].sweep_angle - (bars.extent / track.radius).to_degrees()).abs() < f32::EPSILON
    );
}
