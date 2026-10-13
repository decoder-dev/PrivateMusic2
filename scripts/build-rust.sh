#!/bin/bash
# Builds the Rust native core (native/pm-native) into libpm_native.a for the
# platform and architectures Xcode is currently building, and leaves the
# archive where the app target's linker settings expect it:
#   $PROJECT_TEMP_DIR/rust/$PLATFORM_NAME/libpm_native.a
#
# Run from an Xcode build phase (SRCROOT, PLATFORM_NAME, ARCHS, PROJECT_TEMP_DIR
# are provided by Xcode) or by hand for a quick check:
#   PLATFORM_NAME=iphoneos ARCHS=arm64 PROJECT_TEMP_DIR=/tmp/pm scripts/build-rust.sh
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PLATFORM="${PLATFORM_NAME:-iphoneos}"
ARCH_LIST="${ARCHS:-arm64}"
TEMP="${PROJECT_TEMP_DIR:-$ROOT/build/rust-temp}"
OUT_DIR="$TEMP/rust/$PLATFORM"
export CARGO_TARGET_DIR="$TEMP/rust-target"

# Xcode runs build phases with a minimal PATH.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found; installing a minimal Rust toolchain"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain stable
  export PATH="$HOME/.cargo/bin:$PATH"
fi

targets=()
for arch in $ARCH_LIST; do
  case "$PLATFORM/$arch" in
    iphoneos/arm64)             targets+=(aarch64-apple-ios) ;;
    iphonesimulator/arm64)      targets+=(aarch64-apple-ios-sim) ;;
    iphonesimulator/x86_64)     targets+=(x86_64-apple-ios) ;;
    *) echo "error: unsupported platform/arch for the Rust core: $PLATFORM/$arch" >&2; exit 1 ;;
  esac
done

installed="$(rustup target list --installed 2>/dev/null || true)"
for target in "${targets[@]}"; do
  if ! grep -qx "$target" <<<"$installed"; then
    rustup target add "$target"
  fi
done

# Match the app's deployment target so the archive links without warnings.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
# Xcode's own compiler/linker variables must not steer cargo.
unset SDKROOT CC CXX LD LDFLAGS CFLAGS CXXFLAGS OTHER_LDFLAGS 2>/dev/null || true

archives=()
for target in "${targets[@]}"; do
  cargo build --release --locked \
    --manifest-path "$ROOT/native/Cargo.toml" \
    --target "$target"
  archives+=("$CARGO_TARGET_DIR/$target/release/libpm_native.a")
done

mkdir -p "$OUT_DIR"
if [ "${#archives[@]}" -eq 1 ]; then
  cp -f "${archives[0]}" "$OUT_DIR/libpm_native.a"
else
  lipo -create "${archives[@]}" -output "$OUT_DIR/libpm_native.a"
fi
echo "Rust core ready: $OUT_DIR/libpm_native.a"
