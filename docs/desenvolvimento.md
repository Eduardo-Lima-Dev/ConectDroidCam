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
| Rust | estável, edição 2024, mínimo 1.90 (`rust/rust-toolchain.toml`) | Protocolo e ferramentas de teste |
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
  lib/features/receiver/   Receptor (computador): hoje só uma tela provisória
  android/.../sender/      Código nativo do emissor: câmera, codificador e servidor TCP (Kotlin)
rust/                    Workspace Rust
  crates/cdc-protocol/     Frames e mensagens do protocolo v1
  crates/cdc-testsender/   Celular simulado
  crates/cdc-testreceiver/ Receptor de linha de comando (mede o fluxo, escreve em V4L2)
scripts/spikes/          Scripts das validações da Fase 1
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

O teste de ponta a ponta do Rust sobe o `ffmpeg` de verdade e leva alguns segundos; se o `ffmpeg` não existir, ele é pulado e avisa.

## Rodar o app

```sh
cd apps/conectdroidcam
flutter run -d linux            # o app do computador (tela provisória)
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

**Com o celular**: abra o app, escolha a resolução e toque em "Iniciar transmissão". A tela mostra o endereço (por exemplo `192.168.0.7:47821`):

```sh
cd rust
cargo run -p cdc-testreceiver -- 192.168.0.7:47821 --seconds 20
```

O receptor imprime a resolução real, os FPS, o bitrate e o maior intervalo entre frames. Para escrever o vídeo num dispositivo de webcam virtual e ler de volta a prova do que saiu:

```sh
scripts/spikes/s1-android.sh 192.168.0.7:47821 /dev/video0 16
```

O `/dev/videoN` precisa ser um dispositivo do `v4l2loopback` que ninguém mais esteja usando. `CDC_FFMPEG_LOGLEVEL=info` mostra o que o `ffmpeg` do receptor decodifica.

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

**Rede**

- Fechar um socket TCP com dados ainda não lidos faz o sistema enviar `RST`, e o outro lado perde os últimos frames. O emissor simulado drena o que recebe e fecha de forma graciosa; o receptor trata o reset como fim de sessão.

## Aviso de segurança (estado atual)

O servidor do celular **ainda não tem TLS nem pareamento**: qualquer aparelho da rede que alcance a porta 47821 recebe o vídeo. Use só em rede de confiança até as fases 3 e 4 entregarem o pareamento. A tela do app mostra esse aviso.
