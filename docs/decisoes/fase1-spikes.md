# Fase 1 — Spikes e gate G0

Registro de cada validação. Só entra aqui o que foi medido; o resto fica como pendente.

## Estado

| # | Validação | Estado | Resultado |
|---|---|---|---|
| S1 | Android → TCP → Linux | **Parcial: rede e codificação validadas** | Ver abaixo. Falta provar a escrita no V4L2 a partir do celular |
| S2 | Decodificação → dispositivo V4L2 | **Parcial: caminho validado** | Ver abaixo |
| S3 | Microfone virtual PipeWire | Pendente | |
| S4 | USB Android e iPhone | Pendente | Falta celular |
| S5 | iPhone com VideoToolbox e TLS | Pendente | Falta Mac preparado e iPhone |
| S6 | Plugin OBS no Mac sem conta paga | Pendente | Falta Mac |
| S7 | Camera Extension com conta gratuita | Pendente | Falta Mac |
| S8 | Textura Flutter com frames reais | Pendente | |
| S9 | TCP sob perda de pacotes | Pendente | Exige `tc netem` (root) |
| S10 | 1440p em aparelhos reais | **Parcial: 1 aparelho** | O 2201117SL anunciou 2560×1440 a 30 FPS e entregou 28 frames em 1,1 s; a sustentação ainda não foi medida |

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

## S1 — Android → TCP → computador

**Aparelho:** 2201117SL (Android 13, API 33, arm64), por Wi-Fi, com o PC em Ethernet na mesma faixa de IP. Codificador H.264 por hardware (`MediaCodec` com entrada por superfície), câmera traseira.

**Medido com `cdc-testreceiver`:**

| Perfil | Resolução anunciada | Duração | FPS médio medido | Bitrate medido | Maior intervalo entre frames |
|---|---|---|---|---|---|
| HD | 1280×720 | 20 s (597 frames) | 29,8 | ~3,6 Mb/s | 68 ms |
| 2K/QHD | 2560×1440 | 1,1 s (28 frames) | 26,4 | ~7,7 Mb/s | 60 ms |

O 2K só tem uma sessão de 1,1 s, curta demais para concluir qualquer coisa sobre estabilidade; o 720p é a única medição sustentada.

O fluxo extraído é um H.264 válido: High profile, yuv420p, 1280×720 (`ffprobe`).

**O que NÃO está provado:**
- A imagem do celular **não foi escrita e relida em um dispositivo V4L2** (o teste automático falhou por defeito do script, e depois a depuração sem fio caiu). O caminho receptor → `ffmpeg` → V4L2 foi validado só com o emissor simulado.
- Uma sessão em 1440p fechou após 1,1 s sem causa conhecida. Uma rodada em 720p teve um intervalo de 4,3 s sem frames. Nenhum dos dois foi reproduzido com log do celular.
- A latência de ponta a ponta não foi medida.
- A orientação da imagem **enviada** não foi conferida. A prévia no celular está correta, mas o fluxo segue a orientação do sensor, então com o celular em pé a imagem no computador pode chegar deitada. Isso exige informar a rotação no protocolo.

**Defeitos encontrados e corrigidos nesta etapa:**
- A configuração do codificador (SPS/PPS) se perdia porque o servidor era atribuído depois de iniciar o codificador. Este aparelho, com `prepend-sps-pps-to-idr-frames`, nem emite um frame de configuração separado; o receptor passou a usar o SPS/PPS do próprio keyframe.
- Full HD aparecia como indisponível: o Android exige altura múltipla de 16 e 1080 não é. A checagem agora arredonda para cima. **Correção ainda não validada no aparelho.**
- A prévia aparecia esticada e girada, porque o Camera2 entrega a textura na orientação natural do aparelho. Corrigido com a rotação do display e a orientação do sensor; confirmado pelo usuário no aparelho.

## Bloqueios

1. **Celular Android:** já há um (2201117SL, por depuração sem fio, que cai com frequência). Falta repetir S1 com log do celular e testar o USB (S4).
2. **Root** para criar o dispositivo dedicado (`/dev/video10`) e para o `tc netem` do S9.
3. **Mac preparado** (Xcode, Flutter 3.44.4, Rust) e iPhone, para S5, S6 e S7.
