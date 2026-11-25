# Capturas de tela para o Flathub

O arquivo [`../io.github.eduardo_lima_dev.ConectDroidCam.metainfo.xml`](../io.github.eduardo_lima_dev.ConectDroidCam.metainfo.xml) referencia:

- `https://raw.githubusercontent.com/Eduardo-Lima-Dev/ConectDroidCam/v0.1.0/flatpak/screenshots/main.png`

Antes de criar a tag `v0.1.0` no GitHub:

1. Rode o app no Linux (`flutter run -d linux` ou `flatpak run io.github.eduardo_lima_dev.ConectDroidCam`), de preferência com um celular conectado ou com a prévia/controles visíveis.
2. Tire uma captura de tela limpa só da janela (PNG, sem fundo da área de trabalho ou com sombra padrão da janela).
3. Salve aqui como `flatpak/screenshots/main.png` e faça commit **antes** de criar a tag `v0.1.0`.

> O Flathub exige que o link da imagem aponte para uma tag ou commit imutável (nunca para `main`), e falha na revisão se o arquivo não existir na tag.
