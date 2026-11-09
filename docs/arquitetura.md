# Arquitetura

O mesmo app Flutter roda no celular e no computador. O papel muda conforme a plataforma: Android e iOS abrem o **emissor**; Linux e macOS abrem o **receptor**.

```text
CELULAR (Flutter + nativo)                COMPUTADOR (Flutter + núcleo Rust)
┌────────────────────────────┐            ┌──────────────────────────────────────┐
│ Interface Flutter          │            │ Interface Flutter                    │
│   │ Pigeon                 │            │   │ flutter_rust_bridge              │
│ Câmera e microfone nativos │            │ Núcleo Rust                          │
│ Android: CameraX/MediaCodec│  TLS 1.3   │  descoberta, pareamento, transporte  │
│ iOS: AVFoundation/         │◄──────────►│  decodificação (FFmpeg)              │
│      VideoToolbox          │ Wi-Fi: TCP │  ├─ Prévia: textura Flutter          │
│ Servidor TLS + mDNS        │ USB: túnel │  ├─ Linux: v4l2loopback + PipeWire   │
└────────────────────────────┘            │  └─ macOS: plugin do OBS             │
                                          └──────────────────────────────────────┘
```

## Decisões

| Tema | Decisão | Motivo |
|---|---|---|
| Transporte | Protocolo próprio, H.264 e AAC sobre TLS em TCP | Um caminho único para Wi-Fi e USB e acesso direto aos frames no computador |
| Quem escuta | O celular | Os túneis USB (`adb forward`, usbmuxd) conectam do computador ao aparelho |
| Pareamento | Código de 6 dígitos comparado nas duas telas | O computador raramente tem câmera para ler um QR |
| Núcleo do computador | Rust | Desempenho, segurança de memória e um único código para Linux e macOS |
| Saída no Linux | `v4l2loopback` e nó de áudio PipeWire | Aparece como webcam e microfone em qualquer programa |
| Saída no macOS | Plugin do OBS | A câmera virtual do sistema exige conta paga de desenvolvedor Apple |

O que já está pronto e o que falta está no [roadmap](roadmap.md). Detalhes do protocolo em [protocol-v1.md](protocol-v1.md). Resultados das validações em [decisoes/fase1-spikes.md](decisoes/fase1-spikes.md).

## Código no repositório

| Caminho | Conteúdo |
|---|---|
| `apps/conectdroidcam/` | App Flutter (Android, iOS, Linux, macOS) |
| `apps/conectdroidcam/lib/features/sender/` | Emissor (celular): tela, estado e o canal com o código nativo |
| `apps/conectdroidcam/lib/features/receiver/` | Receptor (computador): tela, estado e a plataforma sobre o núcleo em Rust |
| `apps/conectdroidcam/lib/src/rust/` | Ponte Flutter ↔ Rust **gerada** (não editar; veja `scripts/gerar-ponte.sh`) |
| `apps/conectdroidcam/android/.../sender/` | Código nativo do emissor Android: câmera, codificador, servidor TCP e anúncio mDNS |
| `rust/crates/cdc-protocol/` | Frames e mensagens do protocolo v1 |
| `rust/crates/cdc-security/` | Identidade (certificado) de cada instalação, TLS com impressão digital fixada e código de pareamento |
| `rust/crates/cdc-core/` | Núcleo do receptor: descoberta mDNS, sessão com o celular, rotação e saída de vídeo |
| `rust/crates/cdc-ffi/` | Ponte (`flutter_rust_bridge`) entre o app e o `cdc-core`; vira o `libcdc_ffi.so` do app |
| `rust/crates/cdc-testsender/` | Celular simulado (gira, anuncia-se na rede), para testar o computador sem aparelho |
| `rust/crates/cdc-testreceiver/` | Receptor de linha de comando sobre o `cdc-core` |
| `scripts/` | Validações da Fase 1 e instalação da webcam virtual |

## Como o app do computador funciona

```text
Flutter (UI, Riverpod)
  └─ ReceiverPlatform ── RustReceiverPlatform ── flutter_rust_bridge ── cdc-ffi ── cdc-core
                                                                                   ├─ discovery  (mDNS)
                                                                                   ├─ session    (TCP, protocolo v1, comandos ao celular)
                                                                                   ├─ security   (TLS, pareamento — crate cdc-security)
                                                                                   ├─ filter     (gira e encaixa o quadro)
                                                                                   └─ output     (ffmpeg → /dev/videoN)
```

- A interface só conhece a interface `ReceiverPlatform`, o que permite testá-la com uma versão falsa, sem Rust, rede nem webcam virtual.
- Os eventos da ponte são estruturas planas e **nunca** `Err`: a ponte entrega o erro de uma função com fluxo (`StreamSink`) num `Future` interno que ninguém escuta, então ele viraria uma exceção solta. Erros viajam como evento no próprio fluxo (`Failed`, ou `error` em `PhoneInfo`).
- No Linux o `ffmpeg` do sistema decodifica o H.264 e escreve na webcam virtual. Em vez de uma biblioteca de decodificação própria, o app depende do pacote `ffmpeg`; isso simplifica a primeira versão e deve ser substituído pela decodificação em processo (planejada no roadmap).
- O build do Linux compila o `cdc-ffi` com o `cargo` e empacota o `libcdc_ffi.so` em `lib/`, onde o RPATH do executável o encontra. Por isso o `cargo` precisa estar no PATH ao rodar `flutter build linux` ou `flutter run -d linux`.

## Testando sem celular

```sh
cd rust
cargo run -p cdc-testsender -- --bind 0.0.0.0 --profile fullhd --rotation 90 --advertise "Celular de teste"
```

Simula um celular em pé: entrega quadros na orientação do sensor, anuncia `rotation: 90` e aparece sozinho na lista do app do computador (ou do `cdc-testreceiver`). `--rotate-after 5:0` gira o celular no meio da sessão. Exige o `ffmpeg`.
