# Fase 1 — Spikes e gate G0

Registro de cada validação. Só entra aqui o que foi medido; o resto fica como pendente.

## Estado

| # | Validação | Estado | Resultado |
|---|---|---|---|
| S1 | Android → TCP → Linux | Pendente | Falta celular com depuração USB conectado |
| S2 | Decodificação → dispositivo V4L2 | **Parcial: caminho validado** | Ver abaixo |
| S3 | Microfone virtual PipeWire | Pendente | |
| S4 | USB Android e iPhone | Pendente | Falta celular |
| S5 | iPhone com VideoToolbox e TLS | Pendente | Falta Mac preparado e iPhone |
| S6 | Plugin OBS no Mac sem conta paga | Pendente | Falta Mac |
| S7 | Camera Extension com conta gratuita | Pendente | Falta Mac |
| S8 | Textura Flutter com frames reais | Pendente | |
| S9 | TCP sob perda de pacotes | Pendente | Exige `tc netem` (root) |
| S10 | 1440p em aparelhos reais | Pendente | Falta celular |

## S2 — H.264 por TCP até o V4L2

**Como:** `scripts/spikes/s2-v4l2.sh` simula o celular com um `ffmpeg` que codifica um padrão de teste (libx264, `zerolatency`, GOP de 30) e escuta em TCP. Um segundo `ffmpeg` conecta, decodifica e escreve em um dispositivo `v4l2loopback`. Um terceiro lê o dispositivo e mede.

**Ambiente:** Arch Linux, kernel 7.2.15, `v4l2loopback` 0.15.4, FFmpeg com libav 63. O dispositivo usado foi o `/dev/video0` genérico, sem `exclusive_caps` e sem `card_label`.

| Perfil | Resolução entregue | FPS medido |
|---|---|---|
| HD | 1280×720 | 30 |
| Full HD | 1920×1080 | 30 |
| 2K/QHD | 2560×1440 | 30 |

**Limites do que isso prova:**
- A fonte é sintética e a codificação é por software no mesmo PC; não mede latência real nem o comportamento de um encoder de celular.
- Só confirma resolução e FPS lidos do dispositivo. Ainda não foi aberto no OBS, Chromium ou Firefox.
- Sem `exclusive_caps=1` e `card_label`, navegadores podem não listar o dispositivo. Isso exige o dispositivo dedicado da Fase 0 (root).

## Bloqueios

1. **Celular Android** conectado por USB com depuração ativada (para S1, S4 e S10).
2. **Root** para criar o dispositivo dedicado (`/dev/video10`) e para o `tc netem` do S9.
3. **Mac preparado** (Xcode, Flutter 3.44.4, Rust) e iPhone, para S5, S6 e S7.
