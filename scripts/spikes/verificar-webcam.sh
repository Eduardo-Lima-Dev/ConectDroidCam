#!/usr/bin/env bash
set -euo pipefail

DEV="${1:-/dev/video10}"
[ -e "$DEV" ] || { echo "não existe: $DEV" >&2; exit 1; }
command -v v4l2-ctl >/dev/null || { echo "falta o v4l2-ctl (pacote v4l-utils)" >&2; exit 1; }

echo "== identificação de $DEV"
v4l2-ctl -d "$DEV" --info | grep -E 'Driver name|Card type' | sed 's/^/   /'

ffmpeg -hide_banner -loglevel error -re -t 25 \
  -f lavfi -i "testsrc2=size=1280x720:rate=30" -pix_fmt yuyv422 -f v4l2 "$DEV" &
ESCRITOR=$!
trap 'kill "$ESCRITOR" 2>/dev/null || true' EXIT
sleep 3

echo "== capacidades anunciadas com uma fonte alimentando o dispositivo"
caps="$(v4l2-ctl -d "$DEV" --info | awk '/Device Caps/{print $4}')"
echo "   Device Caps = $caps"
captura=$(( caps & 0x1 ))
saida=$(( caps & 0x2 ))
resultado=0
if [ "$captura" -ne 0 ]; then echo "   [ok] anuncia captura (VIDEO_CAPTURE)"; else echo "   [!!] NÃO anuncia captura"; resultado=1; fi
if [ "$saida" -eq 0 ]; then
  echo "   [ok] não anuncia saída: é o que navegadores e Zoom esperam"
else
  echo "   [!!] anuncia também SAÍDA (VIDEO_OUTPUT): Chromium, Firefox e Zoom podem não listar a"
  echo "        câmera. Falta exclusive_caps=1 neste dispositivo (veja scripts/setup/)."
  resultado=1
fi
card="$(v4l2-ctl -d "$DEV" --info | awk -F': ' '/Card type/{print $2}')"
case "$card" in
  *ConectDroidCam*) echo "   [ok] o nome é \"$card\"" ;;
  *) echo "   [--] o nome é \"$card\" (o app pode ser reconhecido pelo nome \"ConectDroidCam\")" ;;
esac

echo "== um leitor independente recebe frames?"
leitura=""
for tentativa in 1 2; do
  leitura="$(timeout -s KILL 8 ffmpeg -hide_banner -f v4l2 -i "$DEV" -t 3 -f null - 2>&1 | tr '\r' '\n' | grep -E '^frame=' | tail -1 || true)"
  [ -n "$leitura" ] && break
  [ "$tentativa" = 1 ] && { echo "   [--] nenhum frame na 1ª tentativa; tentando de novo"; sleep 2; }
done
if [ -n "$leitura" ]; then
  echo "   [ok] $(echo "$leitura" | sed -E 's/ +/ /g' | cut -c1-70)  (tentativa $tentativa)"
else
  echo "   [!!] nenhum frame lido em duas tentativas"
  resultado=1
fi

wait "$ESCRITOR" 2>/dev/null || true
echo
if [ "$resultado" -eq 0 ]; then
  echo "RESULTADO: $DEV está configurado como uma webcam que os programas devem listar."
else
  echo "RESULTADO: há problemas acima."
fi
cat <<TXT

Falta conferir à mão (o que este script não consegue provar):
  OBS:       Fontes > + > Dispositivo de captura de vídeo (V4L2) > escolha "$card".
  Chromium:  abra uma página de teste de webcam e permita a câmera; a lista deve ter "$card".
  Firefox:   o mesmo. No Flatpak, a câmera chega pelo portal e pelo PipeWire, então a lista
             pode ser diferente da do Chromium.
  Para ver imagem, deixe uma fonte alimentando o dispositivo enquanto testa, por exemplo:
     ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=30 -pix_fmt yuyv422 -f v4l2 $DEV
TXT
exit "$resultado"
