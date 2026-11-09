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
| Distribuição | GitHub Releases no início; **Flatpak no Flathub** como instalador principal do Linux (veja "Distribuição no Flathub" abaixo). Sem outras lojas na primeira versão |
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
| 4 | Núcleo e app do computador | 🟡 (primeira versão no Linux; sem pareamento, TLS nem prévia) |
| 5 | Saídas (webcam virtual, microfone, OBS) | ⬜ |
| 6 | USB | ⬜ |
| 7 | Robustez e segurança | ⬜ |
| 8 | Empacotamento e release | ⬜ |

### Fase 0 — Preparação do ambiente

- [x] Repositório, `.gitignore`, projeto Flutter para as quatro plataformas, CI.
- [x] Repositório privado no GitHub.
- [x] Linux: dispositivo `v4l2loopback` dedicado (`/dev/video10`, "ConectDroidCam", `exclusive_caps=1`), criado com `sudo scripts/setup/linux-webcam-virtual.sh` e validado: anuncia só captura e entrega 30 FPS a um leitor. Falta conferir o comportamento depois de reiniciar.
- [x] OBS em Flatpak: **nada a fazer**; ele já vem com acesso a dispositivos (`devices=all`).
- [ ] Mac: Flutter na mesma versão, Xcode, CocoaPods, Rust e instalação do app em um iPhone com Apple ID gratuito. **Guia escrito (sem teste)** em [configurar-mac.md](configurar-mac.md); falta o Mac.

### Fase 1 — Spikes e gate G0

Detalhes e medições em [decisoes/fase1-spikes.md](decisoes/fase1-spikes.md).

| # | Validação | Estado |
|---|---|---|
| S1 | Celular → TCP → computador → V4L2 | ✅ com ressalvas (falta medir latência e conferir a orientação) |
| S2 | Decodificação → dispositivo V4L2 | ✅ no OBS (a imagem do celular aparece); 🟡 Firefox e Chromium não testados |
| S3 | Microfone virtual no PipeWire | 🟡 mecanismo validado (tom atravessa o nó); falta áudio do celular, sincronia e mixer do OBS |
| S4 | USB: `adb forward` no Android e `iproxy` no iPhone | 🟡 `adb forward` funciona (pelo transporte Wi-Fi do `adb`); falta o cabo USB e o iPhone |
| S5 | iPhone com VideoToolbox e TLS | ⬜ (precisa do Mac) |
| S6 | Plugin do OBS no Mac sem conta paga | ⬜ (precisa do Mac) |
| S7 | Extensão de câmera do macOS com conta gratuita | ⬜ (precisa do Mac) |
| S8 | Textura do Flutter com frames reais (`irondash_texture`) | ⬜ |
| S9 | TCP sob perda de pacotes (`tc netem`) | 🟡 medido sem root: TCP puro aguenta até ~1% de perda, com picos acima disso; falta medir o descarte do celular |
| S10 | 1440p em aparelhos reais | 🟡 um aparelho, sessão curta |

**Gate G0** (a arquitetura segue?): exige S1 a S5 e S9. Ainda não foi fechado. S6 define como o macOS será integrado.

### Fase 2 — Fundação

- [x] Workspace Rust, `cdc-protocol` (frames, mensagens, limites, testes de robustez), `cdc-testsender`, `cdc-testreceiver`.
- [x] [protocol-v1.md](protocol-v1.md), [arquitetura.md](arquitetura.md), CI.
- [x] `flutter_rust_bridge`: ponte gerada (`scripts/gerar-ponte.sh`), ligada ao build do Linux.
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

- [x] **Orientação do vídeo enviado:** `profile.actual` ganhou `rotation`; o receptor gira a imagem para ficar em pé e a encaixa num quadro de tamanho fixo. Validado de ponta a ponta com um celular **simulado** até o `/dev/video10`; **falta validar com o celular de verdade** (a fórmula do Android só foi conferida na teoria).
- [x] **Trocar câmera frontal e traseira** pelo botão do celular (painel e tela cheia), também com a transmissão ligada: o codificador não para, o vídeo congela por cerca de 1 s e a rotação enviada ao computador é refeita. A troca só é aceita se a câmera nova oferecer a resolução e o FPS em uso; senão aparece um aviso e nada muda. A prévia da frontal sai espelhada, o vídeo enviado não. Testes do app passam e foi **validado no celular de verdade** (prévia, troca com a transmissão ligada e imagem no OBS). Falta o botão no computador, que depende do controle pelo PC (`camera.switch` já existe no protocolo).
- [ ] **Microfone:** AAC sob demanda, ligando e desligando sem derrubar o vídeo. A permissão só é pedida quando o usuário liga; `audio.set` liga e desliga pelo computador. No PC vira um microfone virtual do PipeWire (`pipewire-rs`; o mecanismo foi validado no spike S3).
- [x] Anunciar o serviço na rede (mDNS, `_conectdroidcam._tcp`) pelo `NsdManager`. **Falta validar no celular de verdade**; o lado do computador foi validado com um emissor simulado.
- [ ] Transmissão em segundo plano no Android (serviço em primeiro plano com notificação; o ícone `ic_stat_cdc` já existe).
- [ ] Superaquecimento, bateria e interrupções da câmera.
- [ ] Permissão de rede local do Android 17 (`ACCESS_LOCAL_NETWORK`), quando o alvo do app chegar ao SDK 37.
- [ ] Telas de pareamento, diagnóstico e configurações; estados `advertising`, `pairing` e `paired`.
- [ ] **TLS e pareamento** (hoje a conexão é aberta: qualquer aparelho da rede que ache a porta recebe o vídeo). Desenho: TLS 1.3 com certificado P-256 autoassinado por instalação; no primeiro contato os dois lados mostram o mesmo código de 6 dígitos (hash das duas impressões digitais e dos nonces) e o usuário confirma nas duas telas; depois só vale a impressão digital fixada. Código válido por 2 minutos, com limite de tentativas; impressões digitais em armazenamento seguro; revogação nos dois lados. A "conexão automática" de hoje não é segurança.
- [ ] **Emissor iOS:** AVFoundation, VideoToolbox, Network.framework e Bonjour. Depende do Mac e do iPhone.

### Fase 4 — Núcleo e app do computador

O app do Linux já recebe o vídeo: acha o celular na rede, conecta, gira a imagem e escreve na webcam virtual. Ainda não tem prévia, pareamento nem TLS, e depende do `ffmpeg` do sistema para decodificar. O macOS ainda não tem receptor.

- [x] Ponte Flutter ↔ Rust (`flutter_rust_bridge`) e crate `cdc-core`, que o app e o `cdc-testreceiver` compartilham.
- [x] Descoberta por mDNS com entrada manual de IP (módulo `discovery` do `cdc-core`).
- [ ] Transporte com TLS e impressão digital fixada, e reconexão com backoff. Hoje é TCP aberto, e uma queda encerra a sessão.
- [ ] `cdc-pairing`: código de 6 dígitos, armazenamento seguro, revogação, limite de tentativas e validade de 2 minutos.
- [ ] `cdc-decode`: aceleração por hardware (VA-API no Linux, VideoToolbox no macOS), com decodificação por software de reserva, e relógio único de áudio e vídeo.
- [x] Interface (v1): celulares encontrados, endereço manual, resolução real, rotação aplicada, estatísticas e escolha da webcam virtual e do formato.
- [x] **Prévia** no app: o mesmo `ffmpeg` gera quadros JPEG de 480 px a 10 por segundo (sem textura do Flutter; o S8 deixou de ser necessário para a prévia). Validada com o celular de verdade em uma execução.
- [x] **Seis webcams virtuais** (uma por tamanho e formato), escolhidas sozinhas pelo app, para trocar de resolução, tamanho, formato ou posição do celular sem o OBS reabrir a fonte. **Falta o usuário rodar o script com `sudo` e validar no OBS**; o núcleo e o app estão testados só com dispositivos simulados.
- [x] Celulares lembrados e **conexão automática** (não é segurança; veja o aviso na tela), formato da imagem **Automático/Horizontal/Vertical** e tamanho da saída **HD/Full HD/2K** (fixo, independente da resolução do celular), ambos salvos entre execuções, redescoberta a cada 8 s com a lista vazia e botão "Procurar de novo".
- [ ] **Controle pelo PC**: escolher resolução e FPS e iniciar/parar a transmissão pelo computador, sem mexer no celular. Exige que o servidor do celular fique ligado desde a abertura do app e mensagens novas no protocolo (tamanho arbitrário em `profile.set`, `stream.start` e `stream.stop`, além de `camera.switch` e `audio.set`, que já existem). O computador passa a mandar comandos ao celular pelo canal da sessão. **Próximo item; ainda não feito.**
- [ ] Interface: pareamento e ícone na bandeja (fechar a janela mantém a transmissão).
- [ ] Receptor para macOS (hoje só Linux).

### Fase 5 — Saídas

- [x] Linux, vídeo: tamanho fixo por sessão, com escala e letterbox, para a saída não mudar quando o celular gira (`cdc-core::filter`). Girar no meio da sessão reinicia o `ffmpeg`; **não foi medido** o que o OBS faz nesse instante com um celular de verdade.
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
- [ ] **Linux: Flatpak para o Flathub** (instalador principal). Plano, pré-requisitos e riscos na seção "Distribuição no Flathub" abaixo.
- [ ] Linux, secundário: um `.tar.gz` do pacote de release (já compila e roda fora da pasta do projeto), PKGBUILD para Arch, `.deb` e AppImage (os ícones e o `.desktop` já estão em `packaging/linux/`).
- [ ] macOS: `.dmg` com assinatura ad-hoc, com o plugin do OBS.
- [ ] iOS: instalação pelo Mac, documentada.
- [ ] Release com tag SemVer e checksums; guia do OBS, firewall, solução de problemas, matriz de compatibilidade e política de privacidade.
- [ ] CI no macOS (um runner próprio no Mac, porque os minutos de macOS do GitHub rendem pouco em repositório privado).

## Distribuição no Flathub

Objetivo: instalar o receptor do Linux por `flatpak install flathub <id>`. **Nada disto foi feito**; esta seção é o plano, com o que já foi verificado e o que ainda precisa ser pesquisado.

### Verificado nesta máquina
- `flatpak` 1.18.4 está instalado; o **`flatpak-builder` não**.
- O runtime `org.freedesktop.Platform` está em 25.08 e 26.08. O OBS em Flatpak usa o **26.08**.
- O app do Linux compila em release e o pacote (28 MB, sem bibliotecas faltando) roda fora da pasta do projeto, com o `libcdc_ffi.so` ao lado do executável.
- O repositório é **privado** e **não há arquivo de licença**.
- O identificador atual do app no Linux é `dev.eduardolima.conectdroidcam`.

### Decisões suas que bloqueiam
| Decisão | Por quê |
|---|---|
| **Licença de código aberto** (MIT, Apache-2.0, GPL-3.0...) | O Flathub só aceita software livre; hoje não há `LICENSE`. A escolha também afeta o FFmpeg que o app embarca (o FFmpeg em si é LGPL ou GPL conforme a compilação) |
| **Repositório público** | O Flathub compila a partir de uma fonte pública (tag ou arquivo). Um repositório privado não serve; pode ser público só o código, depois de revisar o que não deve vazar |
| **Identificador do app** | O Flathub exige um ID que o autor comprove: um domínio que você controle (`dev.eduardolima.…` exige ser dono de `eduardolima.dev`) ou, sem domínio, `io.github.Eduardo-Lima-Dev.ConectDroidCam`. Trocar o ID mexe no `.desktop`, nos ícones e no `APPLICATION_ID` do CMake |

### O que o Flatpak precisa resolver
1. **O módulo `v4l2loopback` é do kernel e não cabe num Flatpak.** O app depende das seis webcams virtuais, criadas com `sudo` no sistema. O Flatpak **não consegue** instalar o módulo nem rodar `sudo`. Caminho provável: o usuário instala o `v4l2loopback` pelo pacote da distribuição e roda o script de instalação no host (ou um pacote pequeno do host, como PKGBUILD ou `.deb`, que faça isso). O app precisa **detectar a falta e explicar** o que fazer, como já faz. Em máquinas com Secure Boot, o módulo ainda precisa ser assinado. **A aceitação disso pelo Flathub precisa ser confirmada na política atual.**
2. **Escrever em `/dev/videoN`** exige a permissão `--device=all`, a mesma que o OBS em Flatpak já usa. O Flathub costuma pedir justificativa para ela.
3. **`ffmpeg`.** O app chama o `ffmpeg` como programa e precisa do decodificador H.264. O runtime base não traz o programa, e os codecs com patentes ficam em extensão à parte. É preciso **embarcar um `ffmpeg` próprio** (construído só com o que o app usa) ou usar a extensão de codecs, e confirmar que o decodificador H.264 está incluído. **Ainda não pesquisei qual é o caminho aceito no Flathub.**
4. **Compilar sem rede.** O Flathub compila sem acesso à internet: as dependências do Rust (`cargo`) precisam estar vendorizadas e as do Flutter (SDK e `pub`) precisam estar num cache offline. Há ferramentas da comunidade para isso (geradores de fontes para `cargo` e para Flutter); **precisam ser avaliadas**. Hoje o CMake chama o `cargo` durante o build do Flutter, o que terá de funcionar dentro do sandbox de build.
5. **Rede.** `--share=network` para o TCP com o celular e para o mDNS. Falta **confirmar que o mDNS (multicast) funciona dentro do sandbox**.
6. **Configurações.** O arquivo de configurações cai em `~/.var/app/<id>/config/` sozinho, pois usa `XDG_CONFIG_HOME`. Deve funcionar sem mudança; precisa de teste.
7. **Janela:** `--socket=wayland`, `--socket=fallback-x11`, `--device=dri`.

### O que o Flathub exige de um app
- Arquivo **AppStream (`.metainfo.xml`)**: nome, resumo, descrição, licença, capturas de tela, classificação de conteúdo (OARS), URLs, notas de versão.
- Arquivo `.desktop` e ícones nos tamanhos certos com o ID novo (os ícones já são gerados por `tools/branding/gerar_icones.py` e estão em `packaging/linux/`).
- Um manifesto (`<id>.yml`) e um repositório próprio no GitHub do Flathub, depois de uma revisão pela equipe deles.
- Capturas de tela do app (precisam ser tiradas).

### Etapas
- [ ] 1. Escolher a licença, o ID do app e tornar o repositório público (decisões acima).
- [ ] 2. Instalar o `flatpak-builder` e o SDK do runtime; escrever um manifesto local que compile o app (cargo e Flutter offline) e rodar com `flatpak-builder --user --install`.
- [ ] 3. Resolver o `ffmpeg` dentro do Flatpak e provar que decodifica H.264 e escreve numa webcam virtual do host.
- [ ] 4. Provar o mDNS e a escrita em `/dev/videoN` de dentro do sandbox, com o OBS em Flatpak lendo a webcam.
- [ ] 5. Escrever o `.metainfo.xml`, tirar as capturas de tela e validar com `flatpak-builder-lint` e `appstreamcli validate`.
- [ ] 6. Documentar a instalação do `v4l2loopback` no host e, se for o caso, empacotar o pequeno auxiliar do host.
- [ ] 7. CI que monte o Flatpak a cada tag.
- [ ] 8. Enviar para o Flathub e responder à revisão.

### Riscos específicos
| Risco | Mitigação |
|---|---|
| O Flathub não aceitar um app que depende de um módulo do kernel instalado à parte | Pesquisar a política antes de investir; apps de câmera e áudio virtual existem, mas não verifiquei casos iguais a este. Plano B: distribuir um Flatpak próprio em um repositório da própria pessoa, e pacotes nativos (PKGBUILD, `.deb`) |
| O decodificador H.264 ou a licença do `ffmpeg` bloquearem a aceitação | Compilar o `ffmpeg` só com o que o app usa e com a licença LGPL; decidir a licença do projeto com isso em mente |
| Compilar Flutter e Rust offline dar muito trabalho | Avaliar as ferramentas da comunidade cedo, no passo 2 |
| O sandbox bloquear o multicast do mDNS | Testar no passo 4; a conexão por endereço digitado continua valendo |
| Trocar o ID do app quebrar configurações e ícones | Decidir o ID **antes** de gerar o manifesto, não depois |

## Ordem recomendada

1. **Validar o que existe** com o celular de verdade e o OBS: as seis webcams, trocar a resolução, girar o celular, e o APK com o `MulticastLock`. É curto e pode revelar defeitos antes de empilhar mais coisa.
2. **Controle pelo PC**: escolher resolução e FPS e iniciar/parar pelo computador. Muda o fluxo do celular (o servidor fica ligado desde a abertura do app).
3. **Pareamento e TLS**, antes de qualquer uso fora de uma rede de confiança. Hoje qualquer aparelho da rede que ache o celular recebe o vídeo.
4. **Microfone**: captura AAC no celular, ligado e desligado sem derrubar o vídeo, enviada ao microfone virtual do PipeWire.
5. **USB do Android**, transmissão em segundo plano e superaquecimento. (Trocar câmera frontal e traseira já está feito no celular.)
6. **Decisões para o Flathub** (licença, repositório público, identificador do app) e o **Flatpak** (seção "Distribuição no Flathub"). As decisões podem ser tomadas a qualquer momento e destravam o resto; o Flatpak em si é melhor depois de o pareamento e o TLS existirem, porque é o que se entrega ao público.
7. Tudo que depende do Mac, em bloco, quando ele estiver preparado: iPhone, plugin do OBS e CI de macOS.
8. **Medições** (latência de ponta a ponta e sessões de 60 minutos), APK assinado com chave de release e os pacotes nativos.

## Depende de pessoa ou de equipamento

| Preciso de | Libera |
|---|---|
| Conferência no Firefox e no Chromium | Fecha o S2. O OBS já foi conferido; o `tc netem` do S9 não precisa de root |
| Mac com Xcode e um iPhone | S5, S6, S7, emissor iOS, CI de macOS |
| Celular Android conectado | Qualquer teste no aparelho (veja o [guia-adb.md](guia-adb.md)) |
| Conta Apple Developer paga (opcional) | Webcam do sistema no macOS e TestFlight |
| Decisões sobre licença, repositório público e identificador do app | Qualquer passo do Flatpak no Flathub (veja "Distribuição no Flathub") |

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
| O Flatpak não instala o módulo `v4l2loopback`, que é do kernel | O usuário o instala no host; o app detecta a falta e explica (veja "Distribuição no Flathub") |
