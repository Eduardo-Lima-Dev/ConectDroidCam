#!/usr/bin/env bash
set -euo pipefail

ADB_ARGS=()
case "${1:-}" in
  -d | -e) ADB_ARGS=("$1"); shift ;;
  -s) ADB_ARGS=("$1" "$2"); shift 2 ;;
esac
SEGUNDOS="${1:-20}"
LOCAL=47851

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
(cd "$RAIZ/rust" && cargo build -q -p cdc-testreceiver)

adb "${ADB_ARGS[@]}" get-state >/dev/null
echo "== transporte: $(adb "${ADB_ARGS[@]}" shell getprop ro.product.model) via $(adb "${ADB_ARGS[@]}" get-serialno | cut -c1-40)"

adb "${ADB_ARGS[@]}" forward "tcp:$LOCAL" tcp:47821 >/dev/null
trap 'adb "${ADB_ARGS[@]}" forward --remove "tcp:$LOCAL" >/dev/null 2>&1 || true' EXIT

echo "== receptor em 127.0.0.1:$LOCAL (encaminhado para o celular) por ${SEGUNDOS}s"
"$RAIZ/rust/target/debug/cdc-testreceiver" "127.0.0.1:$LOCAL" --seconds "$SEGUNDOS" --quiet 2>&1 \
  | grep -E 'emissor|perfil real|resumo|média|atraso|erro|nenhum'
