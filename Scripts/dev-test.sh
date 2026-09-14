#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
build_cache_root="${VELOEDIT_BUILD_CACHE_ROOT:-$HOME/Library/Caches/VeloEditBuild}"
scratch_path="${VELOEDIT_DEV_SCRATCH_PATH:-$build_cache_root/swift}"
mkdir -p /tmp/veloedit-build-temp "$scratch_path/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$scratch_path/ModuleCache"
export TMPDIR="/tmp/veloedit-build-temp"
# An isolated Swift cache need not contain a second Rust toolchain build. Use
# the actual bundled bridge for integration tests when no override is provided.
if [[ -z "${VELOEDIT_OVRLEY_BRIDGE:-}" && -x "$repo_dir/Build/VeloEdit.app/Contents/MacOS/VeloEditOVRLEY" ]]; then
  export VELOEDIT_OVRLEY_BRIDGE="$repo_dir/Build/VeloEdit.app/Contents/MacOS/VeloEditOVRLEY"
fi
cd "$repo_dir"
swift test --disable-sandbox --enable-swift-testing --disable-xctest --scratch-path "$scratch_path" "$@"
