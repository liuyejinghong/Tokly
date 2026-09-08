#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK=$(xcrun --sdk macosx --show-sdk-path)
export SQLITE3_LIB_DIR="$SDK/usr/lib"
export SQLITE3_INCLUDE_DIR="$SDK/usr/include"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_HOME="$ROOT/.build/cargo-home"
export CARGO_TARGET_DIR="$ROOT/.build/store-collector-target"
export CARGO_NET_OFFLINE=true
export CARGO_BUILD_JOBS=4
export RAYON_NUM_THREADS=4
export TOKIO_WORKER_THREADS=2
cargo test --manifest-path "$ROOT/Collector/Cargo.toml" --no-default-features -- --test-threads=1
cargo clippy --manifest-path "$ROOT/Collector/Cargo.toml" --no-default-features --all-targets -- -D warnings
cargo build --release --manifest-path "$ROOT/Collector/Cargo.toml" --no-default-features
otool -L "$CARGO_TARGET_DIR/release/tokens-collector"
