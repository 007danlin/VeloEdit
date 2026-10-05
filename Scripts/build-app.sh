#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
configuration="${CONFIGURATION:-release}"
output_dir="$repo_dir/Build"
app_dir="$output_dir/VeloEdit.app"
staging_root="$(mktemp -d /tmp/veloedit-app.XXXXXX)"
staging_app="$staging_root/VeloEdit.app"
source_snapshot="$staging_root/source"
publish_new="$output_dir/.VeloEdit.app.publish-$$"
publish_old="$output_dir/.VeloEdit.app.previous-$$"
trap 'rm -rf "$staging_root" "$publish_new" "$publish_old"' EXIT

cd "$repo_dir"
build_cache_root="${VELOEDIT_BUILD_CACHE_ROOT:-$HOME/Library/Caches/VeloEditBuild}"
app_scratch_path="${VELOEDIT_SCRATCH_PATH:-$build_cache_root/swift}"
mkdir -p /tmp/veloedit-build-temp "$app_scratch_path/ModuleCache"
build_package_dir="$repo_dir"
if [[ "$repo_dir" == "$HOME/Documents/"* || "${VELOEDIT_BUILD_SNAPSHOT:-0}" == "1" ]]; then
  # Files in Documents may be rematerialized by File Provider while Swift is
  # compiling them. Use an immutable snapshot only while the repository still
  # lives in that managed folder, or when explicitly requested while other
  # editor tasks are changing sources. Normal builds use the stable path so
  # SwiftPM and Cargo can reuse their caches without conflict copies.
  mkdir -p "$source_snapshot"
  cp "$repo_dir/Package.swift" "$source_snapshot/Package.swift"
  cp -R "$repo_dir/Sources" "$source_snapshot/Sources"
  cp -R "$repo_dir/Tests" "$source_snapshot/Tests"
  cp -R "$repo_dir/Resources" "$source_snapshot/Resources"
  cp -R "$repo_dir/ThirdParty" "$source_snapshot/ThirdParty"
  build_package_dir="$source_snapshot"
fi
# Build with the active Xcode toolchain. The former Swift 6.2 SDK-compatibility
# wrapper is ABI-incompatible with the Swift 6.3 runtime shipped by current
# macOS and can crash inside SwiftUI before a Button action is dispatched.
unset SWIFT_EXEC
export CLANG_MODULE_CACHE_PATH="$app_scratch_path/ModuleCache"
export TMPDIR="/tmp/veloedit-build-temp"

# OVRLEY is an actual vendored GPL Rust component, not a reimplementation.
# Keep disposable compiler data outside Documents and bundle the local JSON
# bridge plus corresponding source/notices with every complete app build.
ovrley_manifest="$build_package_dir/ThirdParty/OVRLEY/src-tauri/ovrley_core/Cargo.toml"
ovrley_target="${VELOEDIT_OVRLEY_TARGET_DIR:-$build_cache_root/ovrley-rust}"
ovrley_cargo_home="${VELOEDIT_CARGO_HOME:-$build_cache_root/cargo-home}"
mkdir -p "$ovrley_target" "$ovrley_cargo_home"
CARGO_HOME="$ovrley_cargo_home" CARGO_TARGET_DIR="$ovrley_target" \
  cargo build --manifest-path "$ovrley_manifest" --locked --release --bin veloedit_ovrley_bridge
ovrley_binary="$ovrley_target/release/veloedit_ovrley_bridge"

scratch_args=(--scratch-path "$app_scratch_path")
binary_path="$(swift build --package-path "$build_package_dir" --disable-sandbox "${scratch_args[@]}" -c "$configuration" --show-bin-path)/VeloEdit"
product_args=(--product VeloEdit)
if [[ "${VELOEDIT_BUILD_CLI:-0}" == "1" ]]; then
  # Both executables belong to one SwiftPM build. Releasing its build lock
  # between app and CLI lets another snapshot replace the shared outputs.
  product_args=()
fi
swift build --package-path "$build_package_dir" --disable-sandbox "${scratch_args[@]}" --jobs "${VELOEDIT_BUILD_JOBS:-2}" -c "$configuration" "${product_args[@]}"
swift build --package-path "$build_package_dir" --disable-sandbox "${scratch_args[@]}" --jobs "${VELOEDIT_BUILD_JOBS:-2}" -c "$configuration" --product VeloEditSpeechWorker
cp "${binary_path:h}/VeloEditSpeechWorker" "$staging_root/VeloEditSpeechWorker"
cp "$binary_path" "$staging_root/VeloEdit"

# Optional acceptance runner built from exactly the same immutable sources.
# Separate scratch paths let concurrent tasks validate without compiler races.
if [[ "${VELOEDIT_BUILD_CLI:-0}" == "1" ]]; then
  mkdir -p "$output_dir"
  # Publish atomically, including while a validation process is running the
  # previous executable. Its mapped binary must remain intact until it exits.
  cp "${binary_path:h}/veloedit-cli" "$output_dir/.veloedit-cli-$$"
  mv -f "$output_dir/.veloedit-cli-$$" "$output_dir/veloedit-cli"
fi

mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
cp "$staging_root/VeloEdit" "$staging_app/Contents/MacOS/VeloEdit"
cp "$ovrley_binary" "$staging_app/Contents/MacOS/VeloEditOVRLEY"
cp "$staging_root/VeloEditSpeechWorker" "$staging_app/Contents/MacOS/VeloEditSpeechWorker"
cp -R "$build_package_dir/Resources/Speech" "$staging_app/Contents/Resources/Speech"
if [[ -f "$repo_dir/Build/SpeechPackage/package.json" ]]; then
  cp -R "$repo_dir/Build/SpeechPackage" "$staging_app/Contents/Resources/Speech/ModelsPackage"
fi
cp -R "$build_package_dir/ThirdParty/ArgmaxOSS" "$staging_app/Contents/Resources/ArgmaxOSS-Source"
if [[ -f "$app_scratch_path/checkouts/onnxruntime-swift-package-manager/LICENSE" ]]; then
  cp "$app_scratch_path/checkouts/onnxruntime-swift-package-manager/LICENSE" "$staging_app/Contents/Resources/Speech/ONNX-Runtime-LICENSE"
  chmod u+w "$staging_app/Contents/Resources/Speech/ONNX-Runtime-LICENSE"
fi
cp "$build_package_dir/Resources/Info.plist" "$staging_app/Contents/Info.plist"
cp "$build_package_dir/Resources/AppIcon.icns" "$staging_app/Contents/Resources/AppIcon.icns"
cp -R "$build_package_dir/Resources/Backgrounds" "$staging_app/Contents/Resources/Backgrounds"
cp -R "$build_package_dir/Resources/TransitionPreviews" "$staging_app/Contents/Resources/TransitionPreviews"
cp -R "$build_package_dir/Resources/Music" "$staging_app/Contents/Resources/Music"
cp -R "$build_package_dir/Resources/Ollama" "$staging_app/Contents/Resources/Ollama"
cp -R "$build_package_dir/ThirdParty/OVRLEY" "$staging_app/Contents/Resources/OVRLEY-Source"
python3 "$repo_dir/Scripts/bundle-ffmpeg.py" "$staging_app"
python3 "$repo_dir/Scripts/bundle-legal.py" "$build_package_dir" "$staging_app" "$app_scratch_path"
python3 "$repo_dir/Scripts/write-build-identity.py" "$build_package_dir" "$staging_app"
if [[ "$configuration" == "release" ]]; then
  /usr/bin/strip -x "$staging_app/Contents/MacOS/VeloEdit"
  /usr/bin/strip -x "$staging_app/Contents/MacOS/VeloEditOVRLEY"
  /usr/bin/strip -x "$staging_app/Contents/MacOS/VeloEditSpeechWorker"
fi
xattr -cr "$staging_app"

python3 "$repo_dir/Scripts/sign-app.py" "$staging_app"

# Documents may be managed by File Provider. Removing VeloEdit.app and then
# copying a directory with the same public name leaves a race in which the old
# package can be materialized again. Prepare and validate a hidden sibling,
# then publish it with same-volume renames so old and new bundle contents can
# never be mixed.
rm -rf "$publish_new" "$publish_old"
cp -R "$staging_app" "$publish_new"
xattr -cr "$publish_new"
cmp "$staging_app/Contents/MacOS/VeloEdit" "$publish_new/Contents/MacOS/VeloEdit"
codesign --verify --deep "$publish_new"
if [[ -e "$app_dir" ]]; then
  mv "$app_dir" "$publish_old"
fi
if ! mv "$publish_new" "$app_dir"; then
  if [[ -e "$publish_old" ]]; then mv "$publish_old" "$app_dir"; fi
  exit 1
fi
# Give File Provider a moment to attach its package marker, then remove that
# marker before strict verification. Clearing it immediately after `cp` races
# the asynchronous metadata write on managed Documents folders.
sleep 1
# Some APFS/File Provider combinations return EINVAL for individual copied
# resource xattrs even though the bundle itself has no invalid attributes.
# The explicit removals and signature verification below remain authoritative.
xattr -cr "$app_dir" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$app_dir" 2>/dev/null || true
if ! cmp "$staging_app/Contents/MacOS/VeloEdit" "$app_dir/Contents/MacOS/VeloEdit"; then
  rm -rf "$app_dir"
  if [[ -e "$publish_old" ]]; then mv "$publish_old" "$app_dir"; fi
  exit 1
fi
# Strict verification already succeeded in staging. File Provider may make the
# copied package non-strict by re-attaching Finder metadata, while the embedded
# signature and sealed resources remain valid.
codesign --verify --deep "$app_dir"
rm -rf "$publish_old"

echo "$app_dir"
