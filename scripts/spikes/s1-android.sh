#!/usr/bin/env bash
# Spike S1: celular Android -> TCP -> receptor de teste -> dispositivo V4L2.
#
# Conecta ao servidor do app no celular, escreve o vídeo no dispositivo e lê o
# dispositivo de volta para provar o que realmente saiu (resolução e FPS).
#
# Uso: scripts/spikes/s1-android.sh <host:porta> <dispositivo> [segundos]
# Ex.:  scripts/spikes/s1-android.sh 192.168.0.7:47821 /dev/video10 20
set -euo pipefail

ADDR="${1:?informe host:porta do celular, ex.: 192.168.0.7:47821}"
DEV="${2:?informe o dispositivo V4L2, ex.: /dev/video10}"
SEGUNDOS="${3:-15}"

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
(cd "$RAIZ/rust" && cargo build -q -p cdc-testreceiver)
BIN="$RAIZ/rust/target/debug/cdc-testreceiver"

LOG="$(mktemp)"
trap 'rm -f "$LOG"; kill $(jobs -p) 2>/dev/null || true' EXIT

echo "== receptor: ${ADDR} -> ${DEV} por ${SEGUNDOS}s (CDC_FFMPEG_LOGLEVEL=info mostra o escritor)"
"$BIN" "$ADDR" --seconds "$SEGUNDOS" --v4l2 "$DEV" --quiet >"$LOG" 2>&1 &
RECEPTOR=$!
sleep 4

echo "== lendo ${DEV} de volta"
# O leitor trava se nenhum frame chegar ao dispositivo; o prazo evita prender o script.
timeout -s KILL 15 ffmpeg -hide_banner -f v4l2 -i "$DEV" -t 5 -f null - 2>&1 \
  | tr '\r' '\n' | grep -E 'Stream #|frame=|rror' | tail -3 || true

wait "$RECEPTOR" || true
echo "== relatório do receptor"
cat "$LOG"
