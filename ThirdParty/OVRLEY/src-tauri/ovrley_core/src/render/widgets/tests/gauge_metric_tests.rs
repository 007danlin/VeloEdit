//! Gauge fill-quantization tests.
//!
//! These cases protect range clamping and exact bar activation boundaries.
//! Label formatting is intentionally omitted because it is a thin formatting
//! expression with no meaningful branching contract.

use super::super::gauges::metric::{bar_fill_count, fill_percentage};

#[test]
fn fill_percentage_clamps_and_handles_degenerate_ranges() {
    assert_eq!(fill_percentage(50.0, 0.0, 100.0), 0.5);
    assert_eq!(fill_percentage(-20.0, 0.0, 100.0), 0.0);
    assert_eq!(fill_percentage(120.0, 0.0, 100.0), 1.0);
    assert_eq!(fill_percentage(42.0, 10.0, 10.0), 0.0);
}

#[test]
fn whole_bar_bucket_boundaries_are_discrete() {
    assert_eq!(bar_fill_count(0.0, 5), 0);
    assert_eq!(bar_fill_count(0.1999, 5), 0);
    assert_eq!(bar_fill_count(0.2, 5), 1);
    assert_eq!(bar_fill_count(0.9999, 5), 4);
    assert_eq!(bar_fill_count(1.0, 5), 5);
    assert_eq!(bar_fill_count(1.5, 5), 5);
}
