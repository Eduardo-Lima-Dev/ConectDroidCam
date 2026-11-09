#!/usr/bin/env bash
# Regenera o código da ponte Flutter <-> Rust (crates/cdc-ffi e lib/src/rust).
# Precisa do gerador: cargo install flutter_rust_bridge_codegen --version 2.13.0
# Rode sempre que mudar rust/crates/cdc-ffi/src/api.rs.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ/apps/conectdroidcam"
flutter_rust_bridge_codegen generate
