# Protocolo v1

Define o que celular (emissor) e computador (receptor) trocam. A implementação de referência dos frames e das mensagens é o crate [`cdc-protocol`](../rust/crates/cdc-protocol).

> **Estado:** os frames, as mensagens, a descoberta por mDNS, o TLS e o pareamento estão implementados e testados. A seção 6 (controle de fluxo) descreve em parte o que ainda será refinado.

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
| `profile.actual` | Celular | `width`, `height`, `fps`, `bitrateKbps`, `rotation?` | O que o celular realmente entrega. É reenviado quando o FPS ou a rotação mudam com a transmissão ligada |
| `capabilities` | Celular | `modes[]` (`width`, `height`, `available`, `maxFps`, `reason?`), `fpsOptions[]`, `facing` (`front`, `back`), `canSwitch`, `streaming` | O que a câmera em uso oferece e o estado do celular. Vai logo após a conexão e de novo a cada mudança (transmissão ligada ou parada, câmera trocada) |
| `stream.start` | Computador | `width`, `height`, `fps` | Manda o celular transmitir neste tamanho e FPS. Recusado com `error` `COMMAND_FAILED` se a resolução ou o FPS não existem ou se já transmite |
| `stream.stop` | Computador | — | Manda o celular parar de transmitir, mantendo a conexão |
| `fps.set` | Computador | `fps` | Muda o FPS com a transmissão ligada |
| `audio.set` | Computador | `enabled` | Liga ou desliga o microfone |
| `camera.switch` | Computador | `facing?` (`front`, `back`) | Troca de câmera; sem `facing`, alterna |
| `keyframe.request` | Computador | — | Pede um IDR |
| `stats` | Celular | `fps`, `bitrateKbps`, `droppedFrames`, `queueMs` | Estatísticas da sessão |
| `heartbeat` | Ambos | — | Mantém a conexão e detecta queda |
| `session.stop` | Ambos | — | Encerra a sessão |
| `error` | Ambos | `code`, `message` | Erro tipado (seção 4) |

`profile.query` não estava na lista inicial do plano; foi acrescentado para o computador poder perguntar os perfis sem depender de o celular enviá-los por conta própria.

**Perfis:** `hd` (1280×720), `fullHd` (1920×1080), `qhd` (2560×1440). O nome exibido do último é sempre `2K (2560×1440)`. Bitrates iniciais de projeto, em kb/s: 2000–4000, 4000–8000 e 6000–12000. São pontos de partida a validar em aparelhos reais.

**Outras resoluções:** o celular oferece ao usuário qualquer resolução que a câmera e o codificador por hardware aceitem acima do piso de 720p (por exemplo 4K ou 1920×1440), não só os três perfis nomeados. Elas aparecem em `profile.actual`, com a largura e a altura reais. Nesta versão do protocolo, `profile.list` e `profile.set` conhecem apenas `hd`, `fullHd` e `qhd`; estender a escolha de resolução ao computador exigirá um campo para tamanhos arbitrários.

**FPS:** o celular escolhe o FPS (de 15 a 30 neste aparelho) e pode mudá-lo durante a transmissão, sem reiniciar câmera nem codificador. Como o codificador continua configurado para o FPS inicial, o bitrate por frame sobe quando o FPS cai.

**Rotação:** o codificador de um celular entrega os quadros na orientação do sensor, que é sempre horizontal; com o aparelho em pé a imagem chega deitada. `rotation` diz quantos graus, **no sentido horário**, o quadro decodificado precisa girar para ficar em pé: `0`, `90`, `180` ou `270`. Ausente (emissores anteriores a este campo) vale `0`; qualquer outro valor é tratado como `0` pelo receptor. No Android é `(orientação do sensor − rotação da tela) mod 360` para a câmera traseira. Quando o celular gira, o emissor reenvia `profile.actual` com a nova rotação, e o receptor reinicia a saída no próximo keyframe (ele pede um por `keyframe.request`).

O receptor **não muda o tamanho do quadro de saída** durante a sessão, e nem entre sessões, quando a resolução do celular muda: a imagem girada é ajustada a um quadro de tamanho fixo escolhido no receptor (HD, Full HD ou 2K; horizontal ou vertical), com barras pretas nas sobras. Mudar o tamanho de uma webcam virtual faz o OBS e os navegadores perderem o dispositivo.

**Resolução real:** `profile.actual` é a fonte da verdade. A interface mostra o que ele informa, não o que foi pedido, e nunca reduz abaixo de 720p em silêncio.

## 3.0 Quem comanda a transmissão

O celular abre o servidor e anuncia-se na rede **assim que a prévia da câmera abre**, sem esperar uma transmissão. Ao conectar, o computador recebe `capabilities` com `streaming: false` e decide: `stream.start` liga o codificador; `stream.stop` o desliga sem derrubar a conexão; `fps.set` e `camera.switch` valem com a transmissão ligada. O botão do celular continua funcionando e os dois lados mostram o mesmo estado, porque toda mudança gera um novo `capabilities`.

- Uma transmissão ligada por `stream.start` acaba sozinha quando o computador desconecta (ninguém assiste). Uma ligada pelo botão do celular continua.
- Sem `stream.start`, o celular não envia `profile.actual` nem vídeo; o receptor ignora `profile.actual` com largura ou altura zero.
- Trocar a resolução é parar e iniciar de novo; o receptor mantém o quadro de saída com o tamanho fixo, então a webcam virtual e o OBS não percebem.
- `camera.switch` com a transmissão ligada só é aceito se a câmera nova oferece o tamanho e o FPS em uso; senão o celular responde `error` `COMMAND_FAILED` e nada muda.

## 3.1 Descoberta na rede

O celular anuncia o servidor por mDNS enquanto transmite: serviço `_conectdroidcam._tcp`, nome `ConectDroidCam <modelo>`, porta `47821`, TXT `version` e `protocol`. O computador procura esse serviço e só lista celulares que tenham um endereço IPv4 utilizável. Se o anúncio falhar (algumas redes bloqueiam multicast), o app do celular diz o motivo e o computador ainda conecta pelo endereço digitado.

## 4. Erros

`error.code`, sempre em `SCREAMING_SNAKE_CASE`:

`PERMISSION_DENIED_CAMERA` · `PERMISSION_DENIED_MIC` · `LAN_PERMISSION_DENIED` · `RECEIVER_NOT_FOUND` · `PAIRING_EXPIRED` · `AUTH_FAILED` · `UNSUPPORTED_RESOLUTION` · `CODEC_INCOMPATIBLE` · `NETWORK_INTERRUPTED` · `THERMAL_LIMIT` · `TLS_FINGERPRINT_MISMATCH` · `USB_TUNNEL_FAILED` · `VIRTUAL_CAMERA_UNAVAILABLE` · `DECODER_FAILED` · `COMMAND_FAILED`

## 5. Segurança

Implementada no crate [`cdc-security`](../rust/crates/cdc-security) (computador) e em `PhoneSecurity.kt` / `StreamServer.kt` (celular Android).

**Transporte.** Toda conexão é TLS (1.3, ou 1.2 em Androids antigos) sobre o TCP. Cada lado tem um certificado P-256 autoassinado, criado na primeira vez: no celular, com a chave no Keystore do Android; no computador, num arquivo só do dono (`~/.config/conectdroidcam/identidade`, modo 0600). **O cliente também apresenta certificado**, e a identidade de cada lado é a impressão digital (SHA-256 do certificado, 64 caracteres hexadecimais). Não há autoridade certificadora. As assinaturas do handshake são sempre verificadas: quem copia um certificado público mas não tem a chave não passa.

**Quem é aceito.**

- O computador só aceita o celular cuja impressão digital ficou registrada no pareamento. Se o certificado mudar, a conexão é recusada com a explicação de que pode ser outro aparelho.
- O celular só obedece (comandos, vídeo, `capabilities`) o computador cuja impressão digital está na lista de pareados. Um computador novo recebe apenas `hello` e `error` `AUTH_FAILED`, e só `pair.request`, `pair.confirm` e `session.stop` são lidos; o resto é ignorado.

**Pareamento** (na primeira conexão, ou depois de o usuário remover o pareamento):

1. O celular responde ao computador desconhecido com `error` `AUTH_FAILED`.
2. O computador gera um `nonce` e manda `pair.request`.
3. Os dois calculam o mesmo código de 6 dígitos: SHA-256 de `"conectdroidcam-pairing-v1\0"` e, para cada um de (impressão do celular, impressão do computador, `nonce`), o tamanho em 4 bytes big-endian seguido do texto; os 4 primeiros bytes do resultado, como inteiro, módulo 1 000 000, com seis dígitos. Quem se põe no meio apresenta certificados diferentes a cada lado, e os códigos divergem.
4. O usuário compara o código nas duas telas e confirma em cada uma. O computador envia `pair.confirm` com `confirmed`. O celular só responde `pair.confirm` `confirmed: true` quando **os dois** confirmaram; é o sinal de pareamento concluído. Recusa de qualquer lado encerra a conexão (`pair.denied` quando é o celular).
5. Cada lado guarda a impressão digital do outro. O computador reenvia `profile.query` e `keyframe.request`, que o celular ignorou antes.

O pedido vale 2 minutos. Depois de 5 pareamentos que falham em 10 minutos, o celular recusa novos pedidos por um tempo. O handshake tem prazo de 10 s. Remover o pareamento no celular desconecta o computador na hora; no computador, o app esquece a impressão do celular.

**Limites conhecidos.** O código de 6 dígitos protege contra quem intermedia a conexão porque o usuário o compara; se ele confirmar sem comparar, o pareamento de um intruso vale. A lista de pareados fica em armazenamento privado do app, mas não é cifrada. A conexão automática do app só reconecta a celulares pareados. Logs não trazem impressões digitais completas.

## 6. Controle de fluxo (a implementar)

A prioridade é a latência, não a completude.

- O emissor mantém uma fila de saída limitada por tempo (cerca de 100 ms).
- Se a fila estourar: descarta frames de vídeo até o próximo keyframe, pede um IDR ao encoder e reduz o bitrate. Quando a fila se estabiliza, o bitrate sobe devagar.
- Controle e áudio têm prioridade sobre vídeo.
- O piso de 720p vale também aqui.

## 7. Evolução

Mudanças que quebram a compatibilidade incrementam `protocolVersion`. Acrescentar tipos de mensagem ou campos opcionais não incrementa, mas só vale se o receptor antigo puder ignorá-los sem prejuízo.
