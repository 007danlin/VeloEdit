#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
build_cache_root="${VELOEDIT_BUILD_CACHE_ROOT:-$HOME/Library/Caches/VeloEditBuild}"
scratch_path="${VELOEDIT_DEV_SCRATCH_PATH:-$build_cache_root/swift}"
mkdir -p /tmp/veloedit-build-temp "$scratch_path/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$scratch_path/ModuleCache"
export TMPDIR="/tmp/veloedit-build-temp"
cd "$repo_dir"
swift test --disable-sandbox --enable-swift-testing --disable-xctest --scratch-path "$scratch_path" "$@"
