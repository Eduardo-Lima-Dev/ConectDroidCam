# Protocolo v1

Define o que celular (emissor) e computador (receptor) trocam. A implementação de referência dos frames e das mensagens é o crate [`cdc-protocol`](../rust/crates/cdc-protocol).

> **Estado:** o formato dos frames e das mensagens está implementado e testado. TLS, pareamento e descoberta ainda não existem; as seções 5 e 6 descrevem o que será feito nas fases 3 e 4.

## 1. Papéis e transporte

- O **celular é o servidor** e o **computador é o cliente**. Assim a mesma conexão serve Wi-Fi (`ip:47821`) e USB (`adb forward` no Android, usbmuxd no iPhone), porque os dois túneis só conectam do computador para o aparelho.
- Um único stream TCP, com TLS 1.3 (seção 5). Controle, vídeo e áudio compartilham o mesmo stream.
- Porta padrão: `47821`. Serviço mDNS: `_conectdroidcam._tcp`.

## 2. Frame binário

Cabeçalho de 14 bytes, em big-endian, seguido do payload.

| Offset | Campo | Tamanho | Conteúdo |
|---|---|---|---|
| 0 | `type` | u8 | Tipo do frame (tabela abaixo) |
| 1 | `flags` | u8 | Bit 0: keyframe (só em `type` 2) |
| 2 | `pts_us` | u64 | Relógio de captura, em microssegundos |
| 10 | `length` | u32 | Tamanho do payload |

| `type` | Nome | Payload | Limite |
|---|---|---|---|
| 0 | Controle | JSON UTF-8 (seção 3) | 64 KiB |
| 1 | Configuração de vídeo | SPS e PPS do H.264, em Annex B | 8 MiB |
| 2 | Vídeo | Uma unidade de acesso H.264, em Annex B | 8 MiB |
| 3 | Configuração de áudio | `AudioSpecificConfig` do AAC | 8 MiB |
| 4 | Áudio | Um frame AAC bruto | 8 MiB |

**Regras de validação** (o leitor recusa o frame inteiro, e a conexão deve ser encerrada):

- `type` desconhecido.
- Qualquer bit de `flags` fora do permitido para o tipo. Os demais bits são reservados e precisam ser zero.
- `length` acima do limite do tipo. A checagem acontece só com o cabeçalho, antes de alocar memória para o payload.
- Conexão encerrada no meio de um frame. Encerrar antes do primeiro byte do cabeçalho é um fim limpo.

**Vídeo:** o `pts_us` é o instante de captura e serve de relógio único para sincronizar áudio e vídeo. Cada frame de vídeo é uma unidade de acesso completa. O emissor envia a configuração (tipo 1) antes do primeiro frame de vídeo e a repete se o encoder mudar de parâmetros. O receptor só começa a decodificar em um keyframe.

## 3. Mensagens de controle

Frames de tipo 0 carregam um objeto JSON com o envelope:

```json
{ "protocolVersion": 1, "type": "profile.actual", "width": 1920, "height": 1080, "fps": 30, "bitrateKbps": 5800 }
```

- `protocolVersion` é obrigatório. Qualquer valor diferente de `1` é recusado com `UnsupportedVersion`.
- Os campos usam `camelCase`. Campos desconhecidos são ignorados; campos obrigatórios ausentes são erro.

| `type` | Quem envia | Campos | Função |
|---|---|---|---|
| `hello` | Ambos | `deviceName`, `platform` (`android`, `ios`, `linux`, `macos`), `appVersion` | Primeira mensagem de cada lado |
| `pair.request` | Computador | `nonce` | Inicia o pareamento |
| `pair.confirm` | Ambos | `nonce`, `confirmed` | Confirma ou recusa o código de 6 dígitos |
| `pair.denied` | Celular | `reason` | Recusa o pareamento |
| `profile.query` | Computador | — | Pergunta quais perfis o celular suporta |
| `profile.list` | Celular | `profiles[]`: `profile`, `available`, `reason?` | Disponibilidade de cada perfil, com o motivo quando indisponível |
| `profile.set` | Computador | `profile`, `bitrateKbps?` | Escolhe o perfil |
| `profile.actual` | Celular | `width`, `height`, `fps`, `bitrateKbps` | O que o celular realmente entrega |
| `audio.set` | Computador | `enabled` | Liga ou desliga o microfone |
| `camera.switch` | Computador | `facing?` (`front`, `back`) | Troca de câmera; sem `facing`, alterna |
| `keyframe.request` | Computador | — | Pede um IDR |
| `stats` | Celular | `fps`, `bitrateKbps`, `droppedFrames`, `queueMs` | Estatísticas da sessão |
| `heartbeat` | Ambos | — | Mantém a conexão e detecta queda |
| `session.stop` | Ambos | — | Encerra a sessão |
| `error` | Ambos | `code`, `message` | Erro tipado (seção 4) |

`profile.query` não estava na lista inicial do plano; foi acrescentado para o computador poder perguntar os perfis sem depender de o celular enviá-los por conta própria.

**Perfis:** `hd` (1280×720), `fullHd` (1920×1080), `qhd` (2560×1440). O nome exibido do último é sempre `2K (2560×1440)`. Bitrates iniciais de projeto, em kb/s: 2000–4000, 4000–8000 e 6000–12000. São pontos de partida a validar em aparelhos reais.

**Resolução real:** `profile.actual` é a fonte da verdade. A interface mostra o que ele informa, não o que foi pedido, e nunca reduz abaixo de 720p em silêncio.

## 4. Erros

`error.code`, sempre em `SCREAMING_SNAKE_CASE`:

`PERMISSION_DENIED_CAMERA` · `PERMISSION_DENIED_MIC` · `LAN_PERMISSION_DENIED` · `RECEIVER_NOT_FOUND` · `PAIRING_EXPIRED` · `AUTH_FAILED` · `UNSUPPORTED_RESOLUTION` · `CODEC_INCOMPATIBLE` · `NETWORK_INTERRUPTED` · `THERMAL_LIMIT` · `TLS_FINGERPRINT_MISMATCH` · `USB_TUNNEL_FAILED` · `VIRTUAL_CAMERA_UNAVAILABLE` · `DECODER_FAILED`

## 5. Segurança (a implementar)

- TLS 1.3 com certificados P-256 autoassinados, um por instalação. Depois do pareamento, cada lado só aceita a impressão digital (fingerprint) do outro que ficou registrada.
- **Pareamento:** o computador conecta sem verificar identidade, apenas nessa etapa. Os dois lados calculam um código de 6 dígitos a partir de um hash das duas impressões digitais e dos nonces, e o exibem. O usuário confirma nas duas telas. Um intermediário que tente se passar por um dos lados gera um código diferente em cada tela.
- O código expira em 2 minutos e há limite de tentativas. As impressões digitais ficam no Keystore/Keychain do celular e no armazenamento seguro do computador, com revogação nos dois lados.
- Logs nunca contêm mídia, chaves nem impressões digitais completas.

## 6. Controle de fluxo (a implementar)

A prioridade é a latência, não a completude.

- O emissor mantém uma fila de saída limitada por tempo (cerca de 100 ms).
- Se a fila estourar: descarta frames de vídeo até o próximo keyframe, pede um IDR ao encoder e reduz o bitrate. Quando a fila se estabiliza, o bitrate sobe devagar.
- Controle e áudio têm prioridade sobre vídeo.
- O piso de 720p vale também aqui.

## 7. Evolução

Mudanças que quebram a compatibilidade incrementam `protocolVersion`. Acrescentar tipos de mensagem ou campos opcionais não incrementa, mas só vale se o receptor antigo puder ignorá-los sem prejuízo.
