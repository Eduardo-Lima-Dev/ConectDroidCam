#!/usr/bin/env bash
# Spike S9: como o vídeo em TCP se comporta sob atraso e perda de pacotes.
#
# Roda sem root: o script se reexecuta dentro de um namespace de usuário e de rede
# (`unshare -Urn`), onde pode aplicar `tc netem` no loopback sem tocar na rede real.
# O emissor simulado e o receptor de teste conversam por esse loopback degradado.
#
# O que mede: o atraso que a rede acrescenta aos frames (p50, p95 e máximo), o maior
# intervalo entre frames e o FPS efetivo. NÃO testa a política de descarte do celular
# (ela está no código Kotlin); aqui o emissor simulado escreve sem descartar, então o
# resultado mostra o pior caso do TCP puro.
#
# Uso: scripts/spikes/s9-perda.sh [segundos por cenário, padrão 12]
set -euo pipefail

SEGUNDOS="${1:-12}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TX="$RAIZ/rust/target/debug/cdc-testsender"
RX="$RAIZ/rust/target/debug/cdc-testreceiver"

if [ -z "${CDC_NETNS:-}" ]; then
  (cd "$RAIZ/rust" && cargo build -q -p cdc-testsender -p cdc-testreceiver)
  command -v tc >/dev/null || { echo "falta o 'tc' (pacote iproute2)" >&2; exit 1; }
  exec env CDC_NETNS=1 unshare -Urn "$0" "$@"
fi

ip link set lo up
porta=47900

cenario() {
  local nome="$1" netem="$2" perfil="$3"
  if [ -z "$netem" ]; then
    tc qdisc del dev lo root 2>/dev/null || true
  else
    # shellcheck disable=SC2086
    tc qdisc replace dev lo root netem $netem
  fi
  porta=$((porta + 1))
  "$TX" --port "$porta" --profile "$perfil" --seconds "$SEGUNDOS" >/dev/null 2>&1 &
  local pid=$!
  sleep 1
  local saida
  saida="$(timeout -s KILL $((SEGUNDOS + 40)) "$RX" "127.0.0.1:$porta" --quiet 2>&1 || true)"
  wait "$pid" 2>/dev/null || true
  printf '\n== %s  [%s, perfil %s]\n' "$nome" "${netem:-sem degradação}" "$perfil"
  echo "$saida" | grep -E 'resumo|média|atraso' | sed 's/^/   /'
}

echo "Spike S9: ${SEGUNDOS}s por cenário, loopback degradado com tc netem (sem root)"
cenario "base, sem degradação"            ""                       hd
cenario "atraso de 20 ms"                 "delay 20ms"             hd
cenario "perda de 1%"                     "loss 1%"                hd
cenario "perda de 3%"                     "loss 3%"                hd
cenario "perda de 5%"                     "loss 5%"                hd
cenario "atraso de 30 ms e perda de 2%"   "delay 30ms loss 2%"     hd
cenario "Full HD com perda de 3%"         "loss 3%"                fullhd
echo
