# Fase 1 — Spikes e gate G0

Registro de cada validação. Só entra aqui o que foi medido; o resto fica como pendente.

## Estado

| # | Validação | Estado | Resultado |
|---|---|---|---|
| S1 | Android → TCP → Linux | **Validado, com ressalvas** | Celular → TCP → V4L2 lido de volta a 30 FPS. Ver abaixo o que falta |
| S2 | Decodificação → dispositivo V4L2 | **Validado no OBS; navegadores pendentes** | `/dev/video10` "ConectDroidCam" anuncia só captura, entrega 30 FPS a um leitor e a **imagem do celular aparece no OBS** (Flatpak 33). Falta Firefox e Chromium |
| S3 | Microfone virtual PipeWire | **Parcial: mecanismo validado** | Um tom atravessa o nó. Falta o áudio do celular, a sincronia e o mixer do OBS |
| S4 | USB Android e iPhone | **Parcial** | `adb forward` funciona (pelo transporte Wi-Fi do `adb`). Falta o cabo USB e o iPhone |
| S5 | iPhone com VideoToolbox e TLS | Pendente | Falta Mac preparado e iPhone |
| S6 | Plugin OBS no Mac sem conta paga | Pendente | Falta Mac |
| S7 | Camera Extension com conta gratuita | Pendente | Falta Mac |
| S8 | Textura Flutter com frames reais | Pendente | |
| S9 | TCP sob perda de pacotes | **Parcial** | Medido sem root. TCP puro aguenta até ~1% de perda; acima disso há picos. Falta medir a política de descarte do celular e o Wi-Fi com perda real |
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

## S9 — TCP sob atraso e perda de pacotes

**Como:** `scripts/spikes/s9-perda.sh` roda sem root, dentro de um namespace de usuário e de rede (`unshare -Urn`), onde aplica `tc netem` no loopback. O emissor simulado manda 12 s de vídeo em tempo real e o `cdc-testreceiver` mede o **atraso que a rede acrescenta** a cada frame: a diferença entre quando o frame chegou e quando o relógio de captura (`pts`) previa, descontado o melhor caso observado. Não inclui captura, codificação nem exibição.

| Cenário | FPS | Maior intervalo entre frames | Atraso p50 | p95 | Máx |
|---|---|---|---|---|---|
| HD, sem degradação | 30,0 | 67 ms | 0 ms | 0 ms | 33 ms |
| HD, atraso de 20 ms | 29,9 | 67 ms | 0 ms | 0 ms | 33 ms |
| HD, perda de 1% | 30,0 | 67 ms | 0 ms | 0 ms | 33 ms |
| HD, perda de 3% | 30,0 | 268 ms | 0 ms | 33 ms | 235 ms |
| HD, perda de 5% | 28,6 | 1547 ms | 0 ms | 914 ms | 1514 ms |
| HD, atraso de 30 ms e perda de 2% | 29,8 | 127 ms | 0 ms | 60 ms | 108 ms |
| Full HD, perda de 3% | 30,0 | 624 ms | 0 ms | 104 ms | 624 ms |

**Leitura:** até 1% de perda o TCP não deixa marca. Com 3% há paradas de centenas de milissegundos, e com 5% o atraso chega a 1,5 s: a retransmissão por tempo esgotado do TCP (com recuo exponencial) trava o fluxo inteiro, que é a razão da política de descarte até o próximo keyframe. A decisão de **manter o TCP** por enquanto se apoia nisto e na medição real abaixo; um Wi-Fi doméstico saudável perde bem menos de 1%.

**Medição real, Wi-Fi, 1080p por 30 s, direto ao celular:** 29,8 FPS, atraso p50 12 ms, **p95 41 ms**, máximo 189 ms, maior intervalo entre frames 213 ms.

**O que NÃO está provado:**
- O loopback tem latência quase nula, o que faz o TCP se recuperar mais depressa do que num Wi-Fi com RTT de dezenas de milissegundos. A perda no Wi-Fi vem em rajadas, não aleatória. Os números de perda são um modelo, não o Wi-Fi.
- O emissor simulado **não descarta frames**. A política de descarte (fila de cerca de 200 ms, descarte até o próximo keyframe) está no código do celular e **não foi medida sob perda**.
- Uma só rede, um só aparelho, uma sessão de 30 s. Nada sobre 2,4 GHz, rede congestionada ou distância.

## S3 — Microfone virtual no PipeWire

**Como:** `scripts/spikes/s3-pipewire.sh` cria um par de nós com `pw-loopback`: uma entrada (`Audio/Sink`), onde o app vai escrever o áudio, e uma saída (`Audio/Source`) chamada "ConectDroidCam Microfone", que os programas enxergam como microfone. Toca um tom de 1 kHz na entrada e grava a saída com um cliente independente (`pw-record`). Sem root; o nó é removido no fim.

**Resultado:** o nó aparece no grafo como `Audio/Source` com o nome certo, e a gravação tem o tom de 1 kHz com energia cerca de 22 mil vezes maior que a das outras frequências. Nenhum nó ficou para trás.

**O que NÃO está provado:**
- Não há áudio do celular: o app ainda não captura nem envia áudio.
- Não foi conferido o mixer do OBS nem a sincronia com o vídeo.
- Um `pw-loopback` serve ao spike, mas o app final deve criar o nó por conta própria (`pipewire-rs`), com o ciclo de vida preso ao da sessão.

## S4 — USB (Android)

**Como:** `scripts/spikes/s4-adb-forward.sh` encaminha uma porta do computador para a 47821 do app com `adb forward`, e o receptor conecta em `127.0.0.1`. Como o celular é o servidor, o receptor nem sabe se o caminho é Wi-Fi ou USB.

| Caminho (1080p, 30 s) | FPS | Atraso p50 | p95 | Máx |
|---|---|---|---|---|
| Direto pelo Wi-Fi | 29,8 | 12 ms | 41 ms | 189 ms |
| `adb forward` | 29,9 | 14 ms | 42 ms | 228 ms |

**O que NÃO está provado:** a medição usou o transporte **Wi-Fi do `adb`** (o celular não estava no cabo). Prova que o mecanismo de túnel funciona e não degrada o fluxo, mas **não** que o USB entrega o mesmo, nem mede o ganho de latência que o cabo deveria dar. Para isso: ligue o cabo e rode `scripts/spikes/s4-adb-forward.sh -d`. O iPhone (`iproxy`) depende do Mac.

## Dispositivo de webcam virtual (S2)

O `/dev/video0` genérico **anuncia captura e saída** ao mesmo tempo (`Device Caps = 0x05200003`), e `scripts/spikes/verificar-webcam.sh` o aponta como problema: Chromium, Firefox e Zoom costumam não listar câmeras assim. A solução é um dispositivo dedicado com `exclusive_caps=1`, que exige root. O script `scripts/setup/linux-webcam-virtual.sh` o cria sem mexer no que já existia (`/dev/video0` e o módulo `v4l2loopback_dc` do Droidcam ficaram como estavam):

```sh
sudo scripts/setup/linux-webcam-virtual.sh              # cria /dev/video10 "ConectDroidCam"
scripts/spikes/verificar-webcam.sh /dev/video10         # confere o que os programas esperam
sudo scripts/setup/linux-webcam-virtual.sh --remover    # desfaz
```

**Resultado (Arch Linux, kernel 7.2.15, `v4l2loopback` 0.15.4):**

- O script rodou com sucesso: o módulo foi recarregado (ninguém o usava) e `/dev/video10` apareceu com o nome "ConectDroidCam".
- Com uma fonte alimentando o dispositivo, ele anuncia **só captura** (`Device Caps = 0x05200001`), como navegadores e Zoom esperam. Sem escritor, anuncia só saída (`0x05200002`): é o comportamento normal do `exclusive_caps=1`, que só passa a anunciar captura depois que alguém escreve.
- Um leitor independente (`ffmpeg -f v4l2`) obteve **90 frames em 3 s (30 FPS)** nas rodadas seguintes à primeira, com e sem o `v4l2-ctl` abrindo o dispositivo no meio.
- Ao vivo, o `cdc-testreceiver` escreveu o 1080p do celular nele a cerca de 30 FPS (427 frames, bitrate de 6 a 7 Mb/s), sem erro do `ffmpeg`.

**Anomalia sem causa conhecida:** na primeira execução do verificador, logo depois de criar o dispositivo, o leitor **não recebeu nenhum frame**. Nas rodadas seguintes passou, de primeira, em todas. Uma hipótese é um efeito da primeira abertura depois de recarregar o módulo, mas ela **não foi verificada**. O verificador agora tenta duas vezes e diz em qual tentativa passou.

**No OBS (Flatpak 33, conferido pelo usuário, com captura de tela):** com o celular transmitindo e o `cdc-testreceiver` escrevendo em `/dev/video10`, o dispositivo "ConectDroidCam" foi adicionado como fonte de **Dispositivo de Captura de Vídeo (V4L2)** e a imagem da câmera do celular apareceu na prévia, em movimento. É a primeira prova do **caminho inteiro: celular → Wi-Fi → computador → OBS**.

**O que NÃO está provado:**
- Que o **Firefox e o Chromium** listam e mostram a imagem. O Chromium não está instalado nesta máquina e o Firefox (Flatpak) não foi testado.
- A **orientação** da imagem no OBS: o canvas estava configurado em retrato e não se sabe como o celular estava posicionado, então o print não permite afirmar se a imagem chegou na orientação certa.
- O áudio no mixer do OBS (o app ainda não envia áudio).
- O comportamento depois de reiniciar o computador: a configuração fica em `/etc/modprobe.d/`, mas o boot ainda não foi testado.

Outro achado: o **OBS em Flatpak já vem com acesso a dispositivos** (`devices=all`), então o `flatpak override` previsto na Fase 0 é desnecessário.

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

1. **Firefox e Chromium** para fechar o S2: o dispositivo `/dev/video10` já existe, está validado e funciona no OBS.
2. **Cabo USB** no celular, para provar o S4 de verdade (`scripts/spikes/s4-adb-forward.sh -d`).
3. **Mac preparado** (veja [../configurar-mac.md](../configurar-mac.md)) e iPhone, para S5, S6, S7 e o `iproxy` do S4.
4. **S8** (textura do Flutter com frames reais) não depende de nada externo, mas é um trabalho próprio, ligado à ponte Flutter ↔ Rust da Fase 4.
5. **1440p sustentado** (S10): exige escolher 2K no app e transmitir por alguns minutos.
