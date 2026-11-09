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
| `rust/crates/cdc-protocol/` | Frames e mensagens do protocolo v1 |
| `rust/crates/cdc-testsender/` | Celular simulado, para testar o computador sem aparelho |
| `scripts/spikes/` | Scripts de validação da Fase 1 |

## Testando sem celular

```sh
cd rust
cargo run -p cdc-testsender -- --profile fullhd --seconds 10
```

O comando escuta em `127.0.0.1:47821` e, ao receber uma conexão, envia `hello`, `profile.actual`, a configuração do H.264 e os frames de vídeo de um padrão de teste. Exige o `ffmpeg` instalado.
