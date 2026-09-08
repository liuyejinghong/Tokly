#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export CARGO_HOME="$ROOT/.build/cargo-home"
export CARGO_TARGET_DIR="$ROOT/.build/collector-target"
export CARGO_NET_OFFLINE=true
export CARGO_BUILD_JOBS=4
export RAYON_NUM_THREADS=4
export TOKIO_WORKER_THREADS=2
cargo test --manifest-path "$ROOT/Collector/Cargo.toml" -- --test-threads=1
cargo clippy --manifest-path "$ROOT/Collector/Cargo.toml" --all-targets -- -D warnings
cargo build --release --manifest-path "$ROOT/Collector/Cargo.toml"
