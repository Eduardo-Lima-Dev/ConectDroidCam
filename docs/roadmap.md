# Roadmap

Plano de desenvolvimento do ConectDroidCam, com o estado de cada fase. É a fonte de verdade sobre **o que já foi feito e o que falta**; atualize-o junto com o código.

**Última atualização:** 09/11/2026.

## Objetivo

Usar a câmera do celular (Android e iPhone) como webcam no computador (Linux e macOS), no OBS e em outros programas, por Wi-Fi ou cabo USB. O mesmo app Flutter roda nas duas pontas: o celular é o **emissor** e o computador é o **receptor**.

Requisitos que valem para todas as fases:

- HD (1280×720), Full HD (1920×1080) e 2K (`2K (2560×1440)`), a 30 FPS, mostrando a resolução **real** entregue, nunca só a pedida. Nada abaixo de 720p.
- Microfone desligado por padrão, sem pedir permissão até ser ligado.
- Imagem limpa: sem marca-d'água nem sobreposições no vídeo entregue.
- Tudo na rede local ou por cabo: sem conta, nuvem ou Internet.
- O que não foi medido não é afirmado: documente também o que **não** foi validado.

## Decisões já tomadas

| Tema | Decisão |
|---|---|
| Plataformas | Android, iOS, Linux e macOS |
| Conexão | Wi-Fi e USB na primeira versão |
| Transporte | Protocolo próprio: H.264 e AAC sobre TLS em TCP (ver [protocol-v1.md](protocol-v1.md)) |
| Papéis | O **celular é o servidor** e o computador é o cliente, para o mesmo fluxo servir Wi-Fi e USB (`adb forward`, usbmuxd) |
| Pareamento | Código de 6 dígitos comparado nas duas telas, sem depender de câmera no computador |
| Núcleo do computador | Rust, ligado ao Flutter por `flutter_rust_bridge` |
| Saída no Linux | `v4l2loopback` (vídeo) e PipeWire (microfone virtual) |
| Saída no macOS | Plugin do OBS. A webcam do sistema exige conta Apple Developer paga, que **não há** por enquanto |
| Apple | Há um Mac, sem conta paga: o iPhone só instala por perfil de desenvolvimento (expira em cerca de 7 dias) e não há TestFlight |
| Distribuição | GitHub Releases, sem lojas na primeira versão |
| Repositório | GitHub, privado |

### Desvios da especificação original

A [especificação original](especificacao-original.md) previa só Linux, WebRTC em Browser Source do OBS e um agente Rust sem interface. Mudou porque o escopo cresceu:

- **Protocolo próprio no lugar de WebRTC:** um caminho único para Wi-Fi e USB, e acesso direto aos frames no computador.
- **Código de 6 dígitos no lugar de QR Code:** o computador raramente tem câmera.
- **Webcam virtual deixou de ser pós-MVP:** o objetivo agora é aparecer como câmera em qualquer programa.
- **`MethodChannel` e `EventChannel` no lugar de Pigeon** na ponte com o código nativo do celular, por enquanto.
- **Mensagem `profile.query` acrescentada** ao protocolo.
- **Resoluções vêm do aparelho:** o emissor oferece qualquer tamanho que a câmera e o codificador aceitem acima de 720p. O protocolo ainda nomeia só `hd`, `fullHd` e `qhd`.

## Estado por fase

Legenda: ✅ feito · 🟡 parcial · ⬜ não começou.

| Fase | Assunto | Estado |
|---|---|---|
| 0 | Preparação do ambiente | 🟡 |
| 1 | Spikes e gate G0 | 🟡 |
| 2 | Fundação (protocolo, testes, CI) | ✅ |
| 3 | Emissor móvel | 🟡 (Android em boa parte; iOS não começou) |
| 4 | Núcleo e app do computador | ⬜ |
| 5 | Saídas (webcam virtual, microfone, OBS) | ⬜ |
| 6 | USB | ⬜ |
| 7 | Robustez e segurança | ⬜ |
| 8 | Empacotamento e release | ⬜ |

### Fase 0 — Preparação do ambiente

- [x] Repositório, `.gitignore`, projeto Flutter para as quatro plataformas, CI.
- [x] Repositório privado no GitHub.
- [ ] Linux: dispositivo `v4l2loopback` dedicado (`video_nr=10`, `card_label="ConectDroidCam"`, `exclusive_caps=1`). **Exige `sudo`.** Hoje os testes usam o `/dev/video0` genérico, sem `exclusive_caps`, o que pode impedir navegadores de listá-lo.
- [ ] OBS em Flatpak: acesso a dispositivos (`flatpak override --user --device=all com.obsproject.Studio`), ainda não aplicado nem testado.
- [ ] Mac: Flutter na mesma versão, Xcode, CocoaPods, Rust e instalação do app em um iPhone com Apple ID gratuito.

### Fase 1 — Spikes e gate G0

Detalhes e medições em [decisoes/fase1-spikes.md](decisoes/fase1-spikes.md).

| # | Validação | Estado |
|---|---|---|
| S1 | Celular → TCP → computador → V4L2 | ✅ com ressalvas (falta medir latência e conferir a orientação) |
| S2 | Decodificação → dispositivo V4L2 | 🟡 funciona; falta abrir no OBS, Chromium e Firefox (precisa do dispositivo dedicado) |
| S3 | Microfone virtual no PipeWire | ⬜ |
| S4 | USB: `adb forward` no Android e `iproxy` no iPhone | ⬜ |
| S5 | iPhone com VideoToolbox e TLS | ⬜ (precisa do Mac) |
| S6 | Plugin do OBS no Mac sem conta paga | ⬜ (precisa do Mac) |
| S7 | Extensão de câmera do macOS com conta gratuita | ⬜ (precisa do Mac) |
| S8 | Textura do Flutter com frames reais (`irondash_texture`) | ⬜ |
| S9 | TCP sob perda de pacotes (`tc netem`) | ⬜ (precisa de root) |
| S10 | 1440p em aparelhos reais | 🟡 um aparelho, sessão curta |

**Gate G0** (a arquitetura segue?): exige S1 a S5 e S9. Ainda não foi fechado. S6 define como o macOS será integrado.

### Fase 2 — Fundação

- [x] Workspace Rust, `cdc-protocol` (frames, mensagens, limites, testes de robustez), `cdc-testsender`, `cdc-testreceiver`.
- [x] [protocol-v1.md](protocol-v1.md), [arquitetura.md](arquitetura.md), CI.
- [ ] `flutter_rust_bridge` (adiado para a Fase 4, quando houver código para ligar).
- [ ] Localização pt-BR e en: as cadeias de texto estão escritas direto em português.

### Fase 3 — Emissor móvel

Feito no Android:

- [x] Câmera (Camera2), prévia em textura do Flutter e codificação H.264 por hardware (`MediaCodec`).
- [x] Servidor TCP que fala o protocolo v1, com fila limitada e descarte até o próximo keyframe.
- [x] Resoluções descobertas no aparelho (câmera ∩ codificador, piso de 720p), com o motivo quando indisponíveis. HD, Full HD e 2K sempre visíveis; as demais num seletor.
- [x] FPS (15 a 30 neste aparelho) trocável com a transmissão ligada, sem reiniciar.
- [x] Prévia na orientação certa, rotação da tela, layout em retrato e paisagem, tela cheia com menu sobreposto.
- [x] Permissão de câmera e tela ligada durante a transmissão.

Falta:

- [ ] **Orientação do vídeo enviado:** com o celular em pé, a imagem chega deitada ao computador. Falta informar a rotação no protocolo.
- [ ] Trocar câmera frontal e traseira.
- [ ] **Microfone:** AAC sob demanda, ligando e desligando sem derrubar o vídeo.
- [ ] Anunciar o serviço na rede (mDNS, `_conectdroidcam._tcp`).
- [ ] Transmissão em segundo plano no Android (serviço em primeiro plano com notificação; o ícone `ic_stat_cdc` já existe).
- [ ] Superaquecimento, bateria e interrupções da câmera.
- [ ] Permissão de rede local do Android 17 (`ACCESS_LOCAL_NETWORK`), quando o alvo do app chegar ao SDK 37.
- [ ] Telas de pareamento, diagnóstico e configurações; estados `advertising`, `pairing` e `paired`.
- [ ] **TLS e pareamento** (hoje a conexão é aberta: qualquer aparelho da rede que ache a porta recebe o vídeo).
- [ ] **Emissor iOS:** AVFoundation, VideoToolbox, Network.framework e Bonjour. Depende do Mac e do iPhone.

### Fase 4 — Núcleo e app do computador

Hoje o app do computador é só uma tela provisória; quem recebe o vídeo é o `cdc-testreceiver`, de linha de comando.

- [ ] Ponte Flutter ↔ Rust (`flutter_rust_bridge`).
- [ ] `cdc-discovery`: mDNS com entrada manual de IP.
- [ ] `cdc-transport`: TLS com impressão digital fixada, reconexão com backoff.
- [ ] `cdc-pairing`: código de 6 dígitos, armazenamento seguro, revogação, limite de tentativas e validade de 2 minutos.
- [ ] `cdc-decode`: aceleração por hardware (VA-API no Linux, VideoToolbox no macOS), com decodificação por software de reserva, e relógio único de áudio e vídeo.
- [ ] Interface: aparelhos encontrados, pareamento, prévia, resolução real, saídas e estatísticas. Ícone na bandeja (fechar a janela mantém a transmissão).

### Fase 5 — Saídas

- [ ] Linux, vídeo: tamanho fixo por sessão, com escala e letterbox, para a saída não mudar quando o celular gira.
- [ ] Linux, áudio: nó `ConectDroidCam Microphone` no PipeWire.
- [ ] Linux: assistente que detecta o módulo `v4l2loopback`, o Secure Boot e o OBS em Flatpak.
- [ ] macOS: plugin do OBS (memória compartilhada e socket Unix) e instalador.
- [ ] macOS: extensão de câmera, atrás de um gate (só compila com conta paga).
- [ ] Quadro neutro, sem texto nem marca, quando não há sinal.

### Fase 6 — USB

- [ ] Android: localizar o `adb` (SDK, PATH ou empacotado), `adb forward`, detectar plugar e desplugar. O encaminhamento está descrito no [guia-adb.md](guia-adb.md), mas **nunca foi testado** com o app.
- [ ] iPhone: cliente `usbmux` no próprio Rust, sem o `iproxy`.
- [ ] Mesma camada de TLS e sessão do Wi-Fi; a interface indica o caminho em uso, com USB preferido quando houver.
- [ ] Linux: regra udev e `usbmuxd`; macOS: `usbmuxd` do sistema.

### Fase 7 — Robustez e segurança

- [ ] Testes negativos: sem pareamento, impressão digital trocada, repetição, excesso de conexões, frame malformado.
- [ ] `docs/security.md` com a análise de ameaças; logs sem mídia, chaves nem impressões digitais completas.
- [ ] Reconexão em até 15 s após queda curta; troca entre USB e Wi-Fi.
- [ ] **Medições que ainda não existem:** latência de ponta a ponta (p50 e p95, filmando um relógio), sessões de 60 minutos três vezes por aparelho, consumo de bateria e temperatura.

### Fase 8 — Empacotamento e release

- [ ] Android: APK assinado com chave própria, fora do repositório.
- [ ] Linux: AppImage, `.deb` e PKGBUILD para Arch (os ícones e o `.desktop` já estão em `packaging/linux/`).
- [ ] macOS: `.dmg` com assinatura ad-hoc, com o plugin do OBS.
- [ ] iOS: instalação pelo Mac, documentada.
- [ ] Release com tag SemVer e checksums; guia do OBS, firewall, solução de problemas, matriz de compatibilidade e política de privacidade.
- [ ] CI no macOS (um runner próprio no Mac, porque os minutos de macOS do GitHub rendem pouco em repositório privado).

## Ordem recomendada

1. **Validar o dispositivo `/dev/video10` no OBS, no Chromium e no Firefox.** É curto e prova que o caminho inteiro serve ao objetivo.
2. **Fase 4 (app do Linux)**, para o computador e o celular abrirem juntos, já com mDNS.
3. **Pareamento e TLS**, antes de qualquer uso fora de uma rede de confiança.
4. **Microfone e orientação do vídeo.**
5. **USB do Android.**
6. Tudo que depende do Mac, em bloco, quando ele estiver preparado: iPhone, plugin do OBS e CI de macOS.

## Depende de pessoa ou de equipamento

| Preciso de | Libera |
|---|---|
| `sudo` na máquina Linux | Dispositivo `v4l2loopback` dedicado e `tc netem` (S2 completo, S9) |
| Mac com Xcode e um iPhone | S5, S6, S7, emissor iOS, CI de macOS |
| Celular Android conectado | Qualquer teste no aparelho (veja o [guia-adb.md](guia-adb.md)) |
| Conta Apple Developer paga (opcional) | Webcam do sistema no macOS e TestFlight |

## Estimativas originais

Do plano inicial, para uma pessoa a 20 h por semana. **Não foram recalibradas** com o que já foi feito e valem só como ordem de grandeza.

| Fase | Horas |
|---|---|
| 0 | 4–6 |
| 1 | 20–35 |
| 2 | 16–28 |
| 3 | 50–85 |
| 4 | 40–65 |
| 5 | 35–60 |
| 6 | 15–30 |
| 7 | 30–50 |
| 8 | 20–35 |
| **Total** | **230–394** (12 a 20 semanas) |

## Riscos principais

| Risco | Mitigação |
|---|---|
| TCP em Wi-Fi ruim causa picos de latência | S9; descarte até o próximo keyframe; USB; SRT ou UDP como alternativa |
| TLS com identidade no iOS é trabalhoso | S5, logo no começo da parte de iOS |
| Plugin do OBS no Mac bloqueado | S6; alternativa só de vídeo com Syphon |
| `irondash_texture` sem versão nova desde 2023 | S8; textura própria se falhar |
| `v4l2loopback` varia com kernel e programa | Assistente de instalação, formato fixo, matriz de testes |
| Sem conta Apple paga: iPhone expira e não há webcam no Mac | Limitação documentada; conta paga destrava sem reescrita |
| Atualização do OBS em Flatpak quebra o acesso a dispositivos | Documentar o `override` e testar por versão |
