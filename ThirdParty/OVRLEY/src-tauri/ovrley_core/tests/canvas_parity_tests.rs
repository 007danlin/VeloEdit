#![cfg(feature = "canvas-parity")]

#[test]
fn canvas_parity_test_harness_is_available() {
    // The feature-gated integration target must exist so Cargo can parse the
    // vendored manifest even when the parity suite is not part of this build.
}
