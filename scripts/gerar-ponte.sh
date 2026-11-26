#!/usr/bin/env bash
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ/apps/conectdroidcam"
flutter_rust_bridge_codegen generate
cargo fmt --manifest-path "$RAIZ/rust/Cargo.toml" --all
