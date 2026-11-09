#!/usr/bin/env bash
# Spike S3: microfone virtual no PipeWire.
#
# Cria um par de nós com `pw-loopback`: uma entrada (Audio/Sink), onde o app vai escrever o
# áudio vindo do celular, e uma saída (Audio/Source), que aparece como microfone para o
# OBS, o navegador e qualquer programa. Toca um tom de 1 kHz na entrada e grava a saída
# com um cliente independente, para provar que o áudio atravessa o nó.
#
# Não precisa de root. O nó existe só enquanto o script roda e é removido no fim.
#
# NÃO prova: o áudio do celular (ainda não há captura de áudio no app), a sincronia com o
# vídeo nem a presença do microfone no mixer do OBS, que precisa ser conferida à mão.
#
# Uso: scripts/spikes/s3-pipewire.sh
set -euo pipefail

for ferramenta in pw-loopback pw-cat pw-record pw-dump ffmpeg python3; do
  command -v "$ferramenta" >/dev/null || { echo "falta: $ferramenta" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$TMP"' EXIT

ENTRADA="cdc_mic_entrada"
SAIDA="cdc_mic"

echo "== criando o microfone virtual"
pw-loopback -m '[ FL FR ]' \
  --capture-props="media.class=Audio/Sink node.name=$ENTRADA node.description=\"ConectDroidCam Microfone (entrada)\"" \
  --playback-props="media.class=Audio/Source node.name=$SAIDA node.description=\"ConectDroidCam Microfone\"" \
  >"$TMP/loopback.log" 2>&1 &
sleep 2

echo "== o nó aparece como microfone para os programas?"
pw-dump >"$TMP/dump.json"
python3 - "$TMP/dump.json" "$SAIDA" <<'EOF'
import json, sys
nos = [o for o in json.load(open(sys.argv[1])) if o.get("type") == "PipeWire:Interface:Node"]
achados = [n["info"]["props"] for n in nos if n["info"]["props"].get("node.name") == sys.argv[2]]
if not achados:
    sys.exit("FALHA: o nó não apareceu no grafo do PipeWire")
p = achados[0]
print(f"   node.name        = {p.get('node.name')}")
print(f"   media.class      = {p.get('media.class')}")
print(f"   node.description = {p.get('node.description')}")
if p.get("media.class") != "Audio/Source":
    sys.exit("FALHA: o nó não é um Audio/Source, então não aparece como microfone")
EOF

echo "== tocando um tom de 1 kHz na entrada e gravando a saída"
ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=1000:duration=4:sample_rate=48000" \
  -ac 2 -c:a pcm_s16le "$TMP/tom.wav"
timeout -s INT 5 pw-record --target "$SAIDA" --rate 48000 --channels 2 --format s16 "$TMP/gravado.wav" \
  >"$TMP/record.log" 2>&1 &
sleep 1
pw-cat --playback --target "$ENTRADA" "$TMP/tom.wav" >"$TMP/cat.log" 2>&1 || true
sleep 1
wait %2 2>/dev/null || true

echo "== o tom chegou?"
python3 - "$TMP/gravado.wav" <<'EOF'
import math, struct, sys, wave

with wave.open(sys.argv[1], "rb") as w:
    taxa, canais, largura, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
    bruto = w.readframes(n)
if largura != 2 or n == 0:
    sys.exit(f"FALHA: gravação vazia ou em formato inesperado ({n} amostras)")
amostras = struct.unpack("<%dh" % (len(bruto) // 2), bruto)[::canais]

def goertzel(xs, freq, taxa):
    k = 2 * math.cos(2 * math.pi * freq / taxa)
    s1 = s2 = 0.0
    for x in xs:
        s1, s2 = x + k * s1 - s2, s1
    return math.sqrt(s1 * s1 + s2 * s2 - k * s1 * s2) / len(xs)

# Só a parte em que o tom toca de fato: a maior janela de 1 s com sinal.
janela = taxa
melhor, pico = None, 0.0
for ini in range(0, max(1, len(amostras) - janela), janela // 4):
    trecho = amostras[ini : ini + janela]
    rms = math.sqrt(sum(x * x for x in trecho) / len(trecho))
    if rms > pico:
        pico, melhor = rms, trecho
if melhor is None or pico < 100:
    sys.exit(f"FALHA: sem sinal na gravação (RMS máximo {pico:.0f})")

alvo = goertzel(melhor, 1000, taxa)
outros = [goertzel(melhor, f, taxa) for f in (300, 440, 2500, 5000)]
razao = alvo / (max(outros) + 1e-9)
print(f"   {n / taxa:.1f} s gravados a {taxa} Hz, {canais} canais, RMS do trecho {pico:.0f}")
print(f"   energia em 1 kHz: {alvo:.0f}; maior energia em outras frequências: {max(outros):.1f}")
print(f"   o tom de 1 kHz é {razao:.0f}x mais forte que o ruído em torno")
if razao < 50:
    sys.exit("FALHA: o tom não se destaca; o áudio não atravessou o nó direito")
print("RESULTADO: o áudio atravessa o microfone virtual e chega a um cliente independente")
EOF
