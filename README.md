# ConectDroidCam

Use a câmera do celular (Android ou iPhone) como webcam no computador (Linux ou macOS), por Wi-Fi ou cabo USB, para o OBS Studio e outros programas.

> **Estado:** em desenvolvimento. O emissor Android já transmite vídeo H.264 para o computador por Wi-Fi; o app do computador e a webcam virtual ainda não estão prontos.

## Como vai funcionar

1. Abra o ConectDroidCam no celular e no computador.
2. Pareie os dois confirmando um código de 6 dígitos.
3. Escolha a câmera, a resolução (HD, Full HD ou `2K (2560×1440)`) e se o microfone entra.
4. Use a câmera no OBS ou, no Linux, como webcam de qualquer programa.

## Plataformas

| Plataforma | Papel | Observação |
|---|---|---|
| Android | Emissor (câmera) | Wi-Fi e USB |
| iOS | Emissor (câmera) | Wi-Fi e USB; sem transmissão em segundo plano |
| Linux | Receptor | Webcam virtual `v4l2loopback` e microfone virtual PipeWire |
| macOS | Receptor | Plugin para OBS; webcam do sistema depende de conta Apple Developer paga |

## Princípios

- Tudo na rede local ou por cabo: sem conta, sem nuvem, sem Internet.
- Vídeo limpo: nenhuma marca-d'água ou sobreposição na imagem entregue.
- Microfone desligado por padrão; a permissão só é pedida ao ligar.
- A resolução exibida é a que realmente chega, nunca apenas a solicitada.

## Documentação

- [Arquitetura](docs/arquitetura.md)
- [Protocolo v1](docs/protocol-v1.md)
- [Conectar o celular pelo ADB (Linux e macOS)](docs/guia-adb.md)
- [Resultados dos spikes da Fase 1](docs/decisoes/fase1-spikes.md)
- [Especificação original](docs/especificacao-original.md) (ponto de partida; a arquitetura foi revisada)

## Desenvolvimento

Flutter e Rust. Os detalhes de ambiente e build serão adicionados conforme as fases avançam.
