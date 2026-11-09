#!/usr/bin/env bash
# Cria a webcam virtual dedicada do ConectDroidCam: /dev/video10, "ConectDroidCam".
#
# Precisa de root, porque configura o módulo `v4l2loopback` do kernel.
#
# Como é feito, sem mexer no que você já tem:
#   - Escreve /etc/modprobe.d/conectdroidcam.conf, um arquivo novo.
#   - Pede dois dispositivos ao módulo: o /dev/video10 (do ConectDroidCam, com o nome certo e
#     `exclusive_caps=1`, que navegadores e Zoom exigem para listar a câmera) e o /dev/video0,
#     que continua como estava (sem nome nem exclusive_caps).
#   - O módulo `v4l2loopback_dc` (do Droidcam) é outro e não é tocado.
#   - Recarrega o módulo só se ninguém estiver usando uma câmera virtual.
#
# Uso:
#   sudo scripts/setup/linux-webcam-virtual.sh              cria e ativa
#   sudo scripts/setup/linux-webcam-virtual.sh --remover    desfaz
#   scripts/setup/linux-webcam-virtual.sh --simular         só mostra o que faria, sem root
set -euo pipefail

CONF=/etc/modprobe.d/conectdroidcam.conf
NUMERO=10
NOME="ConectDroidCam"
MODO="aplicar"
case "${1:-}" in
  --remover) MODO="remover" ;;
  --simular) MODO="simular" ;;
  "") ;;
  *) echo "argumento desconhecido: $1 (use --remover ou --simular)" >&2; exit 2 ;;
esac

CONTEUDO="# ConectDroidCam: webcam virtual dedicada (criado por scripts/setup/linux-webcam-virtual.sh).
# Primeiro dispositivo: /dev/video${NUMERO}, do ConectDroidCam.
# Segundo dispositivo: /dev/video0, que segue com o comportamento padrão de antes.
options v4l2loopback devices=2 video_nr=${NUMERO},0 card_label=\"${NOME}\" exclusive_caps=1,0
"

acao() { if [ "$MODO" = "simular" ]; then echo "   [simulação] $*"; else "$@"; fi; }

if [ "$MODO" != "simular" ] && [ "$(id -u)" -ne 0 ]; then
  echo "Este script precisa de root. Rode: sudo $0 ${1:-}" >&2
  exit 1
fi

modulo_em_uso() {
  # Quantos programas seguram o módulo (coluna "Used by" do lsmod).
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
  echo "== (simulação) depois disso, /dev/video${NUMERO} apareceria com o nome \"${NOME}\""
  exit 0
fi

echo "== conferindo"
for _ in 1 2 3 4 5; do [ -e "/dev/video${NUMERO}" ] && break; sleep 1; done
if [ ! -e "/dev/video${NUMERO}" ]; then
  echo "FALHA: /dev/video${NUMERO} não apareceu. Veja: dmesg | tail" >&2
  exit 1
fi
v4l2-ctl -d "/dev/video${NUMERO}" --info 2>/dev/null | grep -E 'Driver name|Card type' | sed 's/^/   /' || true
echo
echo "Pronto: /dev/video${NUMERO} (\"${NOME}\"). Para conferir se navegadores e o OBS vão enxergá-lo:"
echo "   scripts/spikes/verificar-webcam.sh /dev/video${NUMERO}"
