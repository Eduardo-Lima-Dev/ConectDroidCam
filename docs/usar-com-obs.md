# Usar a câmera do celular no OBS

Passo a passo para ver a câmera do celular no OBS Studio, no Linux.

> Hoje só funciona no Linux, com o celular Android. As webcams virtuais precisam estar criadas
> (`sudo scripts/setup/linux-webcam-virtual.sh`, com o OBS fechado) e o `ffmpeg` instalado.

## 1. Conectar

1. No celular, abra o ConectDroidCam e toque em **Iniciar transmissão**.
2. No computador, abra o ConectDroidCam. O celular aparece na lista (ou digite o endereço que
   o celular mostra). Na primeira vez, toque em **Conectar**; depois disso ele conecta sozinho.
3. A janela mostra **Conectado a …**, a resolução real, as estatísticas e a **prévia**.

## 2. Escolher o tamanho e o formato da imagem

O app entrega a imagem à webcam virtual num quadro de **tamanho fixo**, que **não acompanha a
resolução do celular**. Assim você pode trocar a resolução do celular (HD, Full HD, 2K...) à
vontade sem o OBS perder a imagem: o vídeo do celular é ajustado ao quadro.

Em **Webcam virtual**:

| Opção | Valores | Para que serve |
|---|---|---|
| **Tamanho da imagem** | HD (1280×720), **Full HD (1920×1080)** (padrão), 2K (2560×1440) | Tamanho do quadro que o OBS recebe. Uma resolução de celular maior que esta é reduzida |
| **Formato da imagem** | **Automático** (padrão), Horizontal, Vertical | Orientação do quadro |

Formato:

| Formato | Quando usar | Resultado (com Full HD) |
|---|---|---|
| **Automático** | Quase sempre | Vertical se o celular estiver em pé ao conectar, horizontal se estiver deitado |
| **Horizontal** | Canvas horizontal no OBS (16:9) | 1920×1080; se o celular estiver em pé, a imagem ganha barras pretas nos lados |
| **Vertical** | Canvas vertical no OBS (9:16) | 1080×1920; se o celular estiver deitado, a imagem ganha barras em cima e embaixo |

O app já gira a imagem para ficar em pé. **Não gire a fonte dentro do OBS**: se você a girar,
a imagem que já chegou em pé fica deitada e pequena.

Trocar o tamanho ou o formato com o celular conectado reconecta o celular.

## 3. Adicionar a fonte no OBS

O script cria **seis webcams**, uma para cada tamanho e formato. Cada uma tem **sempre o mesmo
tamanho**, e é por isso que nada precisa ser reaberto no OBS:

| Webcam | Tamanho |
|---|---|
| ConectDroidCam **FHD** Horizontal (`/dev/video10`) | 1920×1080 |
| ConectDroidCam **FHD** Vertical (`/dev/video11`) | 1080×1920 |
| ConectDroidCam **HD** Horizontal (`/dev/video12`) | 1280×720 |
| ConectDroidCam **HD** Vertical (`/dev/video13`) | 720×1280 |
| ConectDroidCam **2K** Horizontal (`/dev/video14`) | 2560×1440 |
| ConectDroidCam **2K** Vertical (`/dev/video15`) | 1440×2560 |

(O nome da câmera tem no máximo 31 caracteres, por isso "FHD" em vez de "Full HD".)

O app escolhe sozinho a webcam certa, pelo **Tamanho** e pelo **Formato** que você configurou e,
no formato Automático, pela posição do celular ao conectar.

1. **Fontes › + › Dispositivo de Captura de Vídeo (V4L2)**.
2. Em **Dispositivo**, escolha a webcam do tamanho e formato que você usa, por exemplo
   **ConectDroidCam FHD Vertical** para um canvas vertical em Full HD. O celular precisa estar
   conectado: com `exclusive_caps=1`, a webcam só aparece como câmera enquanto alguém escreve nela.
3. Se você alterna entre posições ou tamanhos, adicione também a webcam correspondente. Uma
   webcam sem imagem não aparece no OBS, então várias podem coexistir na cena.

Dentro de uma webcam, **o tamanho nunca muda**: trocar a resolução do celular, girar o celular ou
conectar de novo não embaralha a imagem.

## 4. Se só houver a webcam antiga ("ConectDroidCam")

Versões anteriores criavam **uma só** webcam. Com ela o app funciona, mas o tamanho não pode mudar
com o OBS aberto: trocar o tamanho ou o formato deixa a imagem **embaralhada, em listras
inclinadas**, até o OBS abrir a fonte de novo (esconda e mostre a fonte, ou feche e abra o OBS).
Para ter uma webcam por tamanho e formato, feche o OBS e rode de novo:

```sh
sudo scripts/setup/linux-webcam-virtual.sh
```

Medido nesta máquina: o OBS **nunca solta** a webcam que abriu (ficou com ela antes, durante e 20 s
depois da sessão), e um escritor de outro tamanho não altera o dispositivo.

## Problemas comuns

| Sintoma | Causa e solução |
|---|---|
| A imagem está deitada | Você girou a fonte no OBS. Volte a rotação para 0° |
| A imagem é uma faixa estreita no meio do canvas | O formato não combina com o canvas do OBS. Troque para Vertical (canvas vertical) ou Horizontal |
| A imagem aparece em listras inclinadas | Só existe a webcam antiga e o tamanho mudou. Crie as seis (seção 4) ou esconda e mostre a fonte |
| Nenhuma "ConectDroidCam…" aparece na lista do OBS | O celular não está conectado, ou as webcams não existem. Rode o script de instalação |
| O celular demora a aparecer no computador | Use **Procurar de novo**. O app também procura sozinho a cada 8 s enquanto a lista está vazia |
