#!/usr/bin/env bash
set -euo pipefail

CONF=/etc/modprobe.d/conectdroidcam.conf
NUMERO=10
MODO="aplicar"
case "${1:-}" in
  --remover) MODO="remover" ;;
  --simular) MODO="simular" ;;
  "") ;;
  *) echo "argumento desconhecido: $1 (use --remover ou --simular)" >&2; exit 2 ;;
esac

NOMES="ConectDroidCam FHD Horizontal,ConectDroidCam FHD Vertical,ConectDroidCam HD Horizontal,ConectDroidCam HD Vertical,ConectDroidCam 2K Horizontal,ConectDroidCam 2K Vertical"
CONTEUDO="# ConectDroidCam: uma webcam virtual por tamanho e formato (criado por scripts/setup/linux-webcam-virtual.sh).
options v4l2loopback devices=7 video_nr=10,11,12,13,14,15,0 card_label=\"${NOMES}\" exclusive_caps=1,1,1,1,1,1,0
"

acao() { if [ "$MODO" = "simular" ]; then echo "   [simulação] $*"; else "$@"; fi; }

if [ "$MODO" != "simular" ] && [ "$(id -u)" -ne 0 ]; then
  echo "Este script precisa de root. Rode: sudo $0 ${1:-}" >&2
  exit 1
fi

modulo_em_uso() {
  lsmod | awk '$1=="v4l2loopback"{print $3}'
}

recarregar() {
  if ! lsmod | grep -q '^v4l2loopback '; then
    echo "-- o módulo não estava carregado; carregando"
    acao modprobe v4l2loopback
    return
  fi
  local uso
  uso="$(modulo_em_uso)"
  if [ "${uso:-0}" != "0" ]; then
    echo "!! o módulo v4l2loopback está em uso (${uso}). Feche o OBS e qualquer programa que use"
    echo "   câmera virtual e rode este script de novo, ou reinicie o computador."
    echo "   A configuração já foi gravada: ela vale no próximo boot."
    exit 3
  fi
  echo "-- recarregando o módulo (ninguém o estava usando)"
  acao modprobe -r v4l2loopback
  acao modprobe v4l2loopback
}

if [ "$MODO" = "remover" ]; then
  echo "== removendo ${CONF}"
  acao rm -f "$CONF"
  recarregar
  echo "Pronto. O módulo voltou à configuração padrão."
  exit 0
fi

echo "== configuração a gravar em ${CONF}"
printf '%s' "$CONTEUDO" | sed 's/^/   | /'
if [ -e "$CONF" ] && [ "$MODO" != "simular" ]; then
  if cmp -s <(printf '%s' "$CONTEUDO") "$CONF"; then
    echo "-- o arquivo já está assim; nada a regravar"
  else
    acao cp -a "$CONF" "${CONF}.bak"
    echo "-- já existia um arquivo diferente; cópia em ${CONF}.bak"
  fi
fi
if [ "$MODO" = "simular" ]; then
  echo "   [simulação] gravaria o arquivo acima"
else
  printf '%s' "$CONTEUDO" >"$CONF"
fi

echo "== recarregando o módulo"
recarregar

if [ "$MODO" = "simular" ]; then
  echo "== (simulação) depois disso, /dev/video10 a /dev/video15 apareceriam com os nomes acima"
  exit 0
fi

echo "== conferindo"
for _ in 1 2 3 4 5; do [ -e "/dev/video15" ] && break; sleep 1; done
for n in 10 11 12 13 14 15; do
  if [ ! -e "/dev/video${n}" ]; then
    echo "FALHA: /dev/video${n} não apareceu. Veja: dmesg | tail" >&2
    exit 1
  fi
  printf '   /dev/video%s  %s\n' "$n" "$(v4l2-ctl -d "/dev/video${n}" --info 2>/dev/null | awk -F': ' '/Card type/{print $2}')"
done
echo
echo "Pronto. Para conferir se navegadores e o OBS vão enxergar um deles:"
echo "   scripts/spikes/verificar-webcam.sh /dev/video10"
