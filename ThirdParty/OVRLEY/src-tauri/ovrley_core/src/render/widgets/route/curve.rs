//! Smooth route reconstruction for sparse GPS geometry.
//!
//! Builds centripetal Catmull-Rom segments through the source samples, converts
//! them to cubic Bezier curves, then adaptively flattens those curves back into
//! the canonical route sample model used by rendering and marker placement.

use super::super::types::RouteSample;

const MAX_SUBDIVISION_DEPTH: u8 = 12;
const MIN_KNOT_INTERVAL: f64 = 1e-6;

#[derive(Clone, Copy)]
struct CubicSegment {
    start: (f64, f64),
    control1: (f64, f64),
    control2: (f64, f64),
    end: (f64, f64),
    start_fraction: f64,
    end_fraction: f64,
}

/// Reconstructs a smooth route while preserving every source sample and its
/// progress value.
pub(crate) fn curve_route_samples(
    samples: &[RouteSample],
    flatness_tolerance_px: f64,
) -> Vec<RouteSample> {
    if samples.len() < 3 {
        return samples.to_vec();
    }

    let mut curved = Vec::with_capacity(samples.len());
    curved.push(samples[0]);

    for segment_index in 0..samples.len() - 1 {
        let start = samples[segment_index];
        let end = samples[segment_index + 1];
        if start.point == end.point {
            curved.push(end);
            continue;
        }

        let previous = if segment_index == 0 {
            extrapolate_before(start.point, end.point)
        } else {
            samples[segment_index - 1].point
        };
        let following = if segment_index + 2 < samples.len() {
            samples[segment_index + 2].point
        } else {
            extrapolate_after(start.point, end.point)
        };
        let (control1, control2) =
            catmull_rom_controls(previous, start.point, end.point, following);
        let mut flattened = Vec::new();
        flatten_cubic(
            CubicSegment {
                start: start.point,
                control1,
                control2,
                end: end.point,
                start_fraction: 0.0,
                end_fraction: 1.0,
            },
            flatness_tolerance_px,
            0,
            &mut flattened,
        );
        curved.extend(
            flattened
                .into_iter()
                .map(|(point, segment_fraction)| RouteSample {
                    point,
                    progress01: start.progress01
                        + (end.progress01 - start.progress01) * segment_fraction as f32,
                }),
        );
    }

    curved
}

fn catmull_rom_controls(
    point0: (f64, f64),
    point1: (f64, f64),
    point2: (f64, f64),
    point3: (f64, f64),
) -> ((f64, f64), (f64, f64)) {
    let interval01 = knot_interval(point0, point1);
    let interval12 = knot_interval(point1, point2);
    let interval23 = knot_interval(point2, point3);
    let tangent1 = scale(
        add(
            subtract(
                divide(subtract(point1, point0), interval01),
                divide(subtract(point2, point0), interval01 + interval12),
            ),
            divide(subtract(point2, point1), interval12),
        ),
        interval12,
    );
    let tangent2 = scale(
        add(
            subtract(
                divide(subtract(point2, point1), interval12),
                divide(subtract(point3, point1), interval12 + interval23),
            ),
            divide(subtract(point3, point2), interval23),
        ),
        interval12,
    );

    (
        add(point1, scale(tangent1, 1.0 / 3.0)),
        subtract(point2, scale(tangent2, 1.0 / 3.0)),
    )
}

fn flatten_cubic(
    segment: CubicSegment,
    flatness_tolerance_px: f64,
    depth: u8,
    output: &mut Vec<((f64, f64), f64)>,
) {
    if depth == MAX_SUBDIVISION_DEPTH
        || cubic_is_flat_enough(
            segment.start,
            segment.control1,
            segment.control2,
            segment.end,
            flatness_tolerance_px,
        )
    {
        output.push((segment.end, segment.end_fraction));
        return;
    }

    let start_control_midpoint = midpoint(segment.start, segment.control1);
    let control_midpoint = midpoint(segment.control1, segment.control2);
    let control_end_midpoint = midpoint(segment.control2, segment.end);
    let left_control_midpoint = midpoint(start_control_midpoint, control_midpoint);
    let right_control_midpoint = midpoint(control_midpoint, control_end_midpoint);
    let curve_midpoint = midpoint(left_control_midpoint, right_control_midpoint);
    let middle_fraction = (segment.start_fraction + segment.end_fraction) * 0.5;

    flatten_cubic(
        CubicSegment {
            start: segment.start,
            control1: start_control_midpoint,
            control2: left_control_midpoint,
            end: curve_midpoint,
            start_fraction: segment.start_fraction,
            end_fraction: middle_fraction,
        },
        flatness_tolerance_px,
        depth + 1,
        output,
    );
    flatten_cubic(
        CubicSegment {
            start: curve_midpoint,
            control1: right_control_midpoint,
            control2: control_end_midpoint,
            end: segment.end,
            start_fraction: middle_fraction,
            end_fraction: segment.end_fraction,
        },
        flatness_tolerance_px,
        depth + 1,
        output,
    );
}

fn cubic_is_flat_enough(
    start: (f64, f64),
    control1: (f64, f64),
    control2: (f64, f64),
    end: (f64, f64),
    tolerance: f64,
) -> bool {
    point_to_line_distance(control1, start, end).max(point_to_line_distance(control2, start, end))
        <= tolerance
}

fn point_to_line_distance(point: (f64, f64), start: (f64, f64), end: (f64, f64)) -> f64 {
    let line = subtract(end, start);
    let line_length = distance(start, end);
    if line_length == 0.0 {
        return distance(point, start);
    }
    ((point.0 - start.0) * line.1 - (point.1 - start.1) * line.0).abs() / line_length
}

fn knot_interval(start: (f64, f64), end: (f64, f64)) -> f64 {
    distance(start, end).sqrt().max(MIN_KNOT_INTERVAL)
}

fn distance(start: (f64, f64), end: (f64, f64)) -> f64 {
    let delta = subtract(end, start);
    (delta.0 * delta.0 + delta.1 * delta.1).sqrt()
}

fn extrapolate_before(start: (f64, f64), end: (f64, f64)) -> (f64, f64) {
    (start.0 * 2.0 - end.0, start.1 * 2.0 - end.1)
}

fn extrapolate_after(start: (f64, f64), end: (f64, f64)) -> (f64, f64) {
    (end.0 * 2.0 - start.0, end.1 * 2.0 - start.1)
}

fn midpoint(left: (f64, f64), right: (f64, f64)) -> (f64, f64) {
    ((left.0 + right.0) * 0.5, (left.1 + right.1) * 0.5)
}

fn add(left: (f64, f64), right: (f64, f64)) -> (f64, f64) {
    (left.0 + right.0, left.1 + right.1)
}

fn subtract(left: (f64, f64), right: (f64, f64)) -> (f64, f64) {
    (left.0 - right.0, left.1 - right.1)
}

fn scale(point: (f64, f64), factor: f64) -> (f64, f64) {
    (point.0 * factor, point.1 * factor)
}

fn divide(point: (f64, f64), divisor: f64) -> (f64, f64) {
    (point.0 / divisor, point.1 / divisor)
}
