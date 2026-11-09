#!/usr/bin/env bash
# Spike S4 (Android): o mesmo fluxo de vídeo, mas por um túnel do `adb forward`.
#
# O celular é o servidor, então basta o `adb` encaminhar uma porta do computador para a
# porta 47821 do app. O receptor conecta em 127.0.0.1 e nem sabe se o caminho é Wi-Fi ou USB.
#
# Para provar o USB de verdade, ligue o celular por cabo e use -d (a opção do adb que escolhe
# o dispositivo USB). Com a depuração por Wi-Fi ligada ao mesmo tempo, o adb enxerga dois
# transportes do mesmo aparelho e é preciso escolher um.
#
# Uso: scripts/spikes/s4-adb-forward.sh [-d | -e | -s SERIAL] [segundos]
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
