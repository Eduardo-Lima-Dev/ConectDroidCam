//! Ponte Flutter ↔ Rust do app do computador. A API pública está em [`api`]; o arquivo
//! `frb_generated.rs` é gerado por `flutter_rust_bridge_codegen generate` (veja
//! `scripts/gerar-ponte.sh`) e não deve ser editado à mão.

pub mod api;
mod frb_generated;
