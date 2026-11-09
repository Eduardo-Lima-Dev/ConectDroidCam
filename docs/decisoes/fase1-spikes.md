# Fase 1 — Spikes e gate G0

Registro de cada validação. Só entra aqui o que foi medido; o resto fica como pendente.

## Estado

| # | Validação | Estado | Resultado |
|---|---|---|---|
| S1 | Android → TCP → Linux | **Validado, com ressalvas** | Celular → TCP → V4L2 lido de volta a 30 FPS. Ver abaixo o que falta |
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
| Full HD | 1920×1080 | 18 s (537 frames) | 29,8 | ~6,9 Mb/s | 165 ms |
| 2K/QHD | 2560×1440 | 1,1 s (28 frames) | 26,4 | ~7,7 Mb/s | 60 ms |

O 2K só tem uma sessão de 1,1 s, curta demais para concluir qualquer coisa sobre estabilidade. O 720p (20 s) e o Full HD (18 s) são as medições sustentadas.

O fluxo extraído é um H.264 válido: High profile, yuv420p (`ffprobe`).

**Provado de ponta a ponta:** celular (1080p, H.264 por hardware) → Wi-Fi → `cdc-testreceiver` → `ffmpeg` → `/dev/video0`, e um leitor independente obteve **150 frames em 5 s (30 FPS)** do dispositivo, que ficou em 1920×1080 YUYV. Rodada de 16 s: 478 frames, 29,9 FPS médios, 6,9 Mb/s, maior intervalo entre frames de 178 ms.

**O que NÃO está provado:**
- A latência de ponta a ponta não foi medida.
- A orientação da imagem **enviada** não foi conferida. A prévia no celular está correta, mas o fluxo segue a orientação do sensor, então com o celular em pé a imagem no computador pode chegar deitada. Isso exige informar a rotação no protocolo.

**Defeitos encontrados e corrigidos nesta etapa:**
- **O `ffmpeg` perdia frames do celular por causa de uma opção minha.** Com `-fflags nobuffer` ele decodificava só 76 de 106 frames de um trecho real (e quase nenhum ao vivo: 2 de 522, o que deixava o `/dev/video0` parado em 1 frame). Sem essa opção decodifica os 106. O `-flags low_delay` é inofensivo e foi mantido. Isso só aparecia com o fluxo do celular; o emissor simulado não revelava o problema.
- A configuração do codificador (SPS/PPS) se perdia porque o servidor era atribuído depois de iniciar o codificador. Este aparelho, com `prepend-sps-pps-to-idr-frames`, nem emite um frame de configuração separado; o receptor passou a usar o SPS/PPS do próprio keyframe.
- Full HD aparecia como indisponível: o Android exige altura múltipla de 16 e 1080 não é. A checagem agora arredonda para cima. **Validado no aparelho:** o Full HD passou a ser oferecido e transmitiu a 29,8 FPS.
- A prévia aparecia esticada e girada, porque o Camera2 entrega a textura na orientação natural do aparelho. Corrigido com a rotação do display e a orientação do sensor; confirmado pelo usuário no aparelho.

## Capacidades do 2201117SL (câmera traseira)

Extraídas de `adb shell dumpsys media.camera`. São o que o aparelho **declara**; o que realmente sustenta só se sabe medindo.

| Resolução | Proporção | FPS máximo declarado |
|---|---|---|
| 3840×2160 | 16:9 | 30 |
| 2560×1440 | 16:9 | 30 |
| 1920×1080 | 16:9 | 60 |
| 1280×720 | 16:9 | 60 |
| 4000×2256, 3264×1840 | 16:9 | 20 |
| 1920×1440, 1280×960 | 4:3 | 30 |
| 1440×1080 | 4:3 | 60 |

São 37 tamanhos no total, de 160×96 a 4000×3000. O app só oferece os que passam do piso de 720p (lado maior ≥ 1280 e lado menor ≥ 720) e que o codificador H.264 por hardware aceita.

- **FPS:** as faixas de FPS da câmera no modo normal são fixas em 10, 15, 20 e 30 (mais as variáveis 5–30 e 15–20). O app oferece de 15 a 30. Os 60 FPS aparecem na duração mínima de frame de alguns tamanhos, mas **não há faixa de 60 FPS** no modo normal, então o app não os oferece.
- **Alta velocidade:** o aparelho declara 1280×720 a 120 FPS, mas esse é um tipo de sessão separado (câmera em modo de alta velocidade), que não foi avaliado.

## Bloqueios

1. **Celular Android:** já há um (2201117SL, por depuração sem fio, que cai com frequência). Falta repetir S1 com log do celular e testar o USB (S4).
2. **Root** para criar o dispositivo dedicado (`/dev/video10`) e para o `tc netem` do S9.
3. **Mac preparado** (Xcode, Flutter 3.44.4, Rust) e iPhone, para S5, S6 e S7.
