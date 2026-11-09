#!/usr/bin/env bash
# Spike S2 (metade desktop): H.264 por TCP -> decodificacao -> dispositivo V4L2.
# O "celular" e simulado por um ffmpeg que codifica um padrao de teste e escuta na
# porta TCP, como o emissor real fara. O "receptor" conecta, decodifica e escreve
# no dispositivo. Um terceiro ffmpeg le o dispositivo e mede o que realmente saiu.
#
# Uso: scripts/spikes/s2-v4l2.sh <dispositivo> <perfil: 720|1080|1440> [segundos]
set -euo pipefail

DEV="${1:?informe o dispositivo, ex.: /dev/video10}"
PERFIL="${2:?informe o perfil: 720, 1080 ou 1440}"
SEGUNDOS="${3:-6}"
PORTA="${CDC_PORTA:-47821}"

case "$PERFIL" in
  720)  W=1280; H=720;  BR=3000k ;;
  1080) W=1920; H=1080; BR=6000k ;;
  1440) W=2560; H=1440; BR=9000k ;;
  *) echo "perfil invalido: $PERFIL" >&2; exit 2 ;;
esac

LOG="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$LOG"' EXIT

echo "== emissor simulado ${W}x${H}@30 ${BR}"
ffmpeg -hide_banner -loglevel error -re \
  -f lavfi -i "testsrc2=size=${W}x${H}:rate=30" \
  -c:v libx264 -preset ultrafast -tune zerolatency -profile:v high \
  -b:v "$BR" -maxrate "$BR" -bufsize "$BR" -g 30 -pix_fmt yuv420p \
  -t "$((SEGUNDOS + 6))" -f h264 "tcp://127.0.0.1:${PORTA}?listen=1" &
sleep 1

echo "== receptor -> ${DEV}"
ffmpeg -hide_banner -loglevel error -fflags nobuffer -flags low_delay \
  -f h264 -i "tcp://127.0.0.1:${PORTA}" \
  -pix_fmt yuyv422 -f v4l2 "$DEV" &
sleep 2

echo "== medicao lendo ${DEV} por ${SEGUNDOS}s"
ffmpeg -hide_banner -f v4l2 -i "$DEV" -t "$SEGUNDOS" -f null - 2>&1 \
  | grep -E 'Stream #|frame=' | tail -3 | tee "$LOG/medicao.txt"

grep -q "${W}x${H}" "$LOG/medicao.txt" \
  && echo "RESULTADO: ${W}x${H} entregue em ${DEV}" \
  || { echo "RESULTADO: resolucao ${W}x${H} NAO confirmada" >&2; exit 1; }
