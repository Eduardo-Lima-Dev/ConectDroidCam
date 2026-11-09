# Guia de desenvolvimento

Como montar o ambiente, rodar tudo e continuar o trabalho em outra máquina. O que falta fazer está no [roadmap](roadmap.md).

## Retomar em outro computador

```sh
git clone git@github.com:Eduardo-Lima-Dev/ConectDroidCam.git
cd ConectDroidCam
```

O repositório é privado: é preciso estar autenticado no GitHub. Depois:

1. Leia o [roadmap](roadmap.md) (o que está feito, o que falta e a ordem sugerida) e o [registro dos spikes](decisoes/fase1-spikes.md) (o que foi medido e o que **não** está provado).
2. Instale as ferramentas abaixo.
3. Rode as verificações da seção "Rodar tudo" para confirmar que o ambiente está são.

Nada fora do repositório é necessário: não há segredos, chaves nem configuração local a copiar.

## Ferramentas

| Ferramenta | Versão | Para quê |
|---|---|---|
| Flutter | **3.44.4** (fixada em `.flutter-version`; Dart 3.12) | App |
| Rust | estável, edição 2024, mínimo 1.90 (`rust/rust-toolchain.toml`) | Núcleo do receptor, protocolo e ferramentas de teste. **O `cargo` precisa estar no PATH ao compilar o app do Linux**: o CMake o chama para gerar o `libcdc_ffi.so` |
| `flutter_rust_bridge_codegen` | 2.13.0 (`cargo install flutter_rust_bridge_codegen --version 2.13.0`) | Só para regenerar a ponte depois de mudar `rust/crates/cdc-ffi/src/api.rs` (`scripts/gerar-ponte.sh`) |
| FFmpeg (`ffmpeg`, `ffprobe`) | qualquer recente | Testes do Rust e do receptor |
| Android SDK e `adb` | SDK 36 | Compilar e rodar no Android (veja o [guia do ADB](guia-adb.md)) |
| Python 3 com Pillow | | Gerar os ícones ([identidade visual](identidade-visual.md)) |
| `cargo-audit` | | Auditoria de dependências, usada no CI |

Para compilar o app **Linux**, além do Flutter: `clang`, `cmake`, `ninja`, `pkg-config` e as bibliotecas de desenvolvimento do GTK 3. No Arch: `pacman -S clang cmake ninja pkgconf gtk3`; em outras distribuições, os pacotes equivalentes.

Para o caminho de webcam virtual no Linux (opcional, só para testar a saída em V4L2): o módulo `v4l2loopback`, o `v4l2-utils` e, para ver no OBS, o OBS Studio.

Para **iOS e macOS**: um Mac com Xcode, CocoaPods e o mesmo Flutter. Isso ainda não foi montado (veja o roadmap).

## Estrutura

```text
apps/conectdroidcam/     App Flutter único (Android, iOS, Linux, macOS)
  lib/features/sender/     Emissor (celular): tela, estado, canal com o código nativo
  lib/features/receiver/   Receptor (computador): tela, estado, plataforma sobre o Rust
  lib/src/rust/            Ponte Flutter <-> Rust GERADA: não editar
  android/.../sender/      Código nativo do emissor: câmera, codificador, servidor TCP, anúncio mDNS (Kotlin)
rust/                    Workspace Rust
  crates/cdc-protocol/     Frames e mensagens do protocolo v1
  crates/cdc-core/         Núcleo do receptor: descoberta, sessão, rotação, saída de vídeo
  crates/cdc-ffi/          Ponte com o Flutter (vira libcdc_ffi.so)
  crates/cdc-testsender/   Celular simulado
  crates/cdc-testreceiver/ Receptor de linha de comando
scripts/                 Validações da Fase 1, instalação da webcam virtual, gerador da ponte
tools/branding/          Gerador dos ícones
branding/                Logo original
packaging/linux/         Ícones e .desktop para o empacotamento
docs/                    Documentação
```

## Rodar tudo

Estes são os mesmos passos do CI (`.github/workflows/ci.yml`).

```sh
# Rust
cd rust
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace          # precisa do ffmpeg
cargo audit

# Flutter
cd ../apps/conectdroidcam
flutter pub get
flutter analyze
flutter test
```

Os testes em `apps/conectdroidcam/test/integration/` usam a **ponte de verdade** (carregam o `libcdc_ffi.so`, acham o emissor simulado por mDNS e recebem vídeo dele). Eles precisam do núcleo compilado e do `ffmpeg`, e **são pulados**, não falham, se faltar algo:

```sh
(cd rust && cargo build -p cdc-ffi -p cdc-testsender)
flutter test test/integration
```

Não rodam no CI: dependem de multicast na rede. O teste de descoberta do `cdc-core` também só roda sob demanda: `cargo test -p cdc-core --test descoberta -- --ignored`.

O teste de ponta a ponta do Rust sobe o `ffmpeg` de verdade e leva alguns segundos; se o `ffmpeg` não existir, ele é pulado e avisa.

## Rodar o app

```sh
cd apps/conectdroidcam
flutter run -d linux            # o app do computador (compila o Rust junto; precisa do cargo)
flutter devices                 # lista os aparelhos
flutter run -d <id>             # no celular, com hot reload
```

Para o celular Android, siga o [guia do ADB](guia-adb.md).

## Testar o fluxo de vídeo

**Sem celular**, com o emissor simulado (gera um padrão de teste em tempo real):

```sh
cd rust
cargo run -p cdc-testsender -- --profile fullhd --seconds 10      # um terminal
cargo run -p cdc-testreceiver -- 127.0.0.1:47821 --seconds 10     # outro
```

Para simular um **celular em pé** e vê-lo aparecer sozinho na lista do app do computador:

```sh
cargo run -p cdc-testsender -- --bind 0.0.0.0 --rotation 90 --advertise "Celular de teste" --seconds 120
# --rotate-after 5:0  gira o celular para a posição normal depois de 5 s
```

**Com o celular**: abra o app, escolha a resolução e toque em "Iniciar transmissão". A tela mostra o endereço (por exemplo `192.168.0.7:47821`):

```sh
cd rust
cargo run -p cdc-testreceiver -- 192.168.0.7:47821 --seconds 20
```

O receptor imprime a resolução real, a rotação, os FPS, o bitrate, o atraso da rede e o maior intervalo entre frames. `--canvas vertical` escolhe o formato vertical da saída. Para escrever o vídeo num dispositivo de webcam virtual e ler de volta a prova do que saiu:

```sh
scripts/spikes/s1-android.sh 192.168.0.7:47821 /dev/video0 16
```

O `/dev/videoN` precisa ser um dispositivo do `v4l2loopback` que ninguém mais esteja usando. `CDC_FFMPEG_LOGLEVEL=info` mostra o que o `ffmpeg` do receptor decodifica.

## Scripts de validação (`scripts/`)

| Script | O que faz | Precisa de |
|---|---|---|
| `setup/linux-webcam-virtual.sh` | Cria o dispositivo `/dev/video10` "ConectDroidCam" (`--simular` mostra o que faria; `--remover` desfaz) | root |
| `spikes/verificar-webcam.sh` | Confere se um dispositivo V4L2 serve de webcam para navegadores e OBS | `v4l2-ctl`, `ffmpeg` |
| `spikes/s1-android.sh` | Celular → TCP → receptor → V4L2, lendo o dispositivo de volta | celular transmitindo |
| `spikes/s2-v4l2.sh` | H.264 por TCP até um dispositivo V4L2, com fonte simulada | `ffmpeg`, um dispositivo `v4l2loopback` |
| `spikes/s3-pipewire.sh` | Microfone virtual no PipeWire, com um tom de teste | PipeWire |
| `spikes/s4-adb-forward.sh` | O mesmo fluxo por um túnel `adb forward` (`-d` para USB) | celular transmitindo |
| `spikes/s9-perda.sh` | TCP sob atraso e perda de pacotes, em um namespace sem root | `tc` (iproute2) |

Os resultados e o que cada um **não** prova estão em [decisoes/fase1-spikes.md](decisoes/fase1-spikes.md). Para o Mac, veja [configurar-mac.md](configurar-mac.md).

## Convenções

- **Idioma:** português, com acentuação correta, em código comentado, mensagens do app, documentação e mensagens de commit.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/) em português (`feat:`, `fix:`, `docs:`, `chore:`), um assunto por commit, com o corpo explicando o porquê.
- **Autoria:** cada commit é assinado só por quem o escreveu, sem trailers de coautoria.
- **Pull requests:** um por fase ou subfase, com descrição e passos de teste.
- **Testes:** toda mudança de comportamento traz teste. Funcionalidade que depende de aparelho e não pôde ser conferida nele deve dizer isso no commit e na documentação.
- **Honestidade nas medições:** registre só o que foi medido, com o aparelho, a duração e a condição. O que não foi provado vai em "O que NÃO está provado", como no registro dos spikes.
- **Segurança:** nunca versionar chaves de assinatura, `local.properties` nem arquivos `.jks`, `.keystore`, `.p12` ou `.mobileprovision` (o `.gitignore` já os cobre).

## Armadilhas conhecidas

Problemas que já custaram tempo. Vale conhecê-los antes de repetir.

**Vídeo e FFmpeg**

- **Não use `-fflags nobuffer` no `ffmpeg` que recebe o H.264 do celular.** Com o fluxo de um `MediaCodec` ele perdia cerca de 30% dos frames num arquivo e quase todos ao vivo. O emissor simulado não revelava o problema.
- O `-re` do `ffmpeg` **não limita o ritmo** de fontes `lavfi` nem, passado o primeiro segundo, o de arquivos. Para simular tempo real, controle o ritmo no próprio código (é o que o `cdc-testsender` faz, pelo `pts`).
- Um leitor de `/dev/videoN` (`ffmpeg -f v4l2`) **fica preso para sempre** se nenhum escritor entregar frames. Use sempre `timeout -s KILL`.
- Com `v4l2loopback` sem `exclusive_caps=1` e sem `card_label`, navegadores podem não listar o dispositivo.

**Android**

- O Camera2 entrega a textura de **prévia já alinhada à orientação natural** do aparelho (retrato). Ao exibi-la em paisagem é preciso girar de volta, com a rotação do display e a orientação do sensor.
- A imagem do **codificador** segue a orientação do sensor, sem girar. Hoje isso chega deitado ao computador com o celular em pé (veja o roadmap).
- O `MediaCodec` exige largura e altura múltiplas do alinhamento do codificador (em geral 16). 1080 não é, mas todo codificador o aceita; a checagem de disponibilidade arredonda para cima.
- O codificador entrega o SPS/PPS logo ao iniciar: o servidor precisa estar atribuído **antes** de `start()`, senão a configuração se perde. Alguns aparelhos, com `prepend-sps-pps-to-idr-frames`, nem emitem um frame de configuração separado, e o receptor precisa aceitar isso.
- A porta da Depuração por Wi-Fi **muda** e a opção desliga sozinha. Veja a seção 4.4 do [guia do ADB](guia-adb.md).
- Em celulares Xiaomi, `adb shell pm grant` falha sem a opção "Depuração USB (configurações de segurança)". O app pede as permissões na tela e não depende disso.
- O `adb` pode listar o mesmo aparelho duas vezes (uma com `(2)`); use `adb -t <transport_id>`.

**Flutter e testes**

- No Riverpod 3, `ref.read` dentro de `onDispose` é proibido: guarde o que precisar antes.
- Um `ListView` só constrói o que está à vista. Num teste de widget com a tela padrão (800×600), itens abaixo da dobra não são encontrados; use uma tela alta, como a de um celular.
- `debugDefaultTargetPlatformOverride` precisa ser restaurado dentro do teste; use `variant: TargetPlatformVariant.only(...)`.

**Ponte Flutter ↔ Rust**

- Uma função com `StreamSink` **nunca deve devolver `Err`**: a ponte entrega o erro num `Future` interno que ninguém escuta, e ele vira uma exceção solta em vez de chegar ao `Stream`. Mande o erro como evento no próprio fluxo (foi o que o teste com a ponte real revelou).
- `StreamSink<T>::clone` exige `T: Clone`.
- Sem `lints.workspace` no `cdc-ffi`: o código gerado usa `unsafe`, que o resto do projeto proíbe.
- Eventos com campos opcionais são estruturas planas de propósito: enums com dados fariam o gerador exigir `freezed` e `build_runner`.
- Depois de mexer em `api.rs`, rode `scripts/gerar-ponte.sh` e versione o que ele gerar.
- `Shell: Fail to post message to Dart` no fim de um teste é inofensivo: uma thread do Rust enviou algo depois de o Dart fechar o fluxo.

**Webcam virtual (v4l2loopback)**

- Com o OBS segurando o dispositivo, o `ffmpeg` escritor **não dá erro** ao escrever um quadro de outro tamanho, mas o dispositivo **continua no tamanho antigo**. Trocar o formato ou a resolução exige que o OBS reabra a fonte. O app avisa na tela, e `docs/usar-com-obs.md` explica.
- **O OBS nunca solta a webcam que abriu** (medido: antes, durante e 20 s depois da sessão), então com um só dispositivo é impossível mudar de tamanho ou de formato sem ele reabrir a fonte. A solução é **um dispositivo por tamanho e formato** (`scripts/setup/linux-webcam-virtual.sh` cria seis: `/dev/video10` a `15`), cada um com tamanho que nunca muda; o núcleo escolhe o dispositivo pelo par resolvido (`SessionOptions::shape_devices`). O nome da câmera tem no máximo 31 caracteres (limite do `v4l2loopback`), por isso "FHD".
- Por isso o tamanho da saída é **fixo** (`OutputSize`, padrão 1920×1080) e **não acompanha a resolução do celular**: quando acompanhava, trocar o celular de Full HD para HD mudava o quadro de 1920×1080 para 1280×720 e o OBS mostrava a imagem embaralhada (foi o que o usuário viu).
- Por isso o formato **Automático** é resolvido uma vez, na primeira informação de perfil da sessão, e não muda quando o celular gira no meio dela.
- Um leitor (`ffmpeg -f v4l2`) não consegue abrir o dispositivo enquanto o OBS o segura (`Device or resource busy`): para ver o que o OBS recebe, use a prévia do app ou o `cdc-testreceiver --preview ARQUIVO.jpg`.

**Depuração do app do Linux**

- A saída do app redirecionada para arquivo fica em buffer pelo motor do Flutter (inclusive com `stdbuf`), então logs não servem para medir tempo. Grave num arquivo com `flush` e carimbo de hora.
- O XTEST (cliques simulados) não chega aos apps Flutter em XWayland. Para ver a janela, abra com `GDK_BACKEND=x11` e capture com `import -window <id>` (ImageMagick), achando o id pela lista `_NET_CLIENT_LIST` do `xprop`. O ambiente do desenvolvedor usa Wayland nativo (`GDK_BACKEND=wayland`), onde essa captura não funciona.
- O Xiaomi bloqueia toques injetados pelo `adb input tap` sem a opção "Depuração USB (configurações de segurança)".

**mDNS**

- O Android em economia de energia do Wi-Fi filtra multicast e o celular pode demorar mais de 15 s a responder às consultas do computador (o app sozinho achou o celular em ~0,5 s em 3 de 3 execuções, e em ~16 s numa quarta). O emissor segura um `MulticastLock` enquanto transmite, e o computador procura de novo a cada 8 s com a lista vazia. **A eficácia do `MulticastLock` ainda não foi medida no celular.**

- O `mdns-sd` entrega o serviço como resolvido **antes** de resolver o endereço IPv4. Listar o celular nesse momento mostra um endereço que não conecta; o núcleo só informa celulares que já têm IPv4 (o evento completo vem logo depois).
- Um emissor que anuncia todas as interfaces (como o simulado, neste PC, com as pontes do Docker) aparece com o menor endereço IPv4. Um celular anuncia só o do Wi-Fi.
- O `--bind` padrão do `cdc-testsender` é o loopback; para ser alcançado pelo endereço anunciado, use `--bind 0.0.0.0`.

**Rede**

- Fechar um socket TCP com dados ainda não lidos faz o sistema enviar `RST`, e o outro lado perde os últimos frames. O emissor simulado drena o que recebe e fecha de forma graciosa; o receptor trata o reset como fim de sessão.

## Aviso de segurança (estado atual)

O servidor do celular **ainda não tem TLS nem pareamento**: qualquer aparelho da rede que alcance a porta 47821 recebe o vídeo. Use só em rede de confiança até as fases 3 e 4 entregarem o pareamento. A tela do app mostra esse aviso.
